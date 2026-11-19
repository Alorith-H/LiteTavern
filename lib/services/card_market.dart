import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'card_downloader.dart';

/// 角色卡市场（v0.11.0）：在线检索 + 一键下载角色卡。
///
/// 设计要点：
/// - 只依赖公开、免鉴权的数据源，不引入账号体系，也不保存任何凭证；
/// - 市场只负责「找到一张卡 → 拿到标准卡文件字节」，入库仍走
///   `CardParser` + `Storage`（PNG 内嵌 chara / JSON 两种格式都支持）；
/// - 目前接入 Chub.ai（`api.chub.ai`）：目录最大、接口免鉴权、
///   每张卡都能拿到 `chara_card_v2.png`（标准 V2 卡文件）；
///   其它来源（Character Tavern / Pygmalion 等）见 docs/card_market_sources.md，
///   新增来源只需实现 [CardMarketSource]。
///
/// 合规：卡片内容与图片版权归各自作者所有；UI 上标注来源与作者，
/// 仅默认浏览 SFW 内容。

/// 市场请求失败（message 为可直接展示的中文原因）。
class CardMarketException implements Exception {
  final String message;
  const CardMarketException(this.message);

  @override
  String toString() => message;
}

/// 市场里的一张卡（只有元信息 + 下载地址，不含卡内容）。
class MarketCard {
  /// 源内 id（Chub 为数字 id 字符串）。
  final String id;
  final String name;

  /// 作者名（Chub 取 fullPath 前缀）。
  final String creator;
  final String fullPath;

  /// 一句话简介（列表用）；为空时由 [summary] 回退到描述首行。
  final String tagline;
  final String description;
  final String thumbnailUrl;

  /// 标准卡文件地址（PNG 内嵌 chara；个别源可能是 JSON）。
  final String downloadUrl;
  final List<String> topics;
  final int stars;
  final int tokens;
  final int chats;
  final bool nsfw;

  /// 展示用来源名，如 `Chub.ai`。
  final String source;

  /// 原站页面地址（仅用于展示/署名，不打开浏览器）。
  final String pageUrl;

  const MarketCard({
    required this.id,
    required this.name,
    required this.creator,
    required this.fullPath,
    required this.tagline,
    required this.description,
    required this.thumbnailUrl,
    required this.downloadUrl,
    required this.topics,
    required this.stars,
    required this.tokens,
    required this.chats,
    required this.nsfw,
    required this.source,
    required this.pageUrl,
  });

  /// 列表副标题：优先 tagline，其次描述第一行。
  String get summary {
    if (tagline.trim().isNotEmpty) return tagline.trim();
    final first = description.trim().split('\n').first;
    return first.isEmpty ? '（暂无简介）' : first;
  }

  /// Chub 搜索结果节点 → 市场卡。
  factory MarketCard.fromChubJson(Map<String, dynamic> json) {
    final fullPath = _str(json['fullPath']);
    final parts = fullPath.split('/');
    final creator = parts.length > 1 ? parts.first : '';
    var downloadUrl = _str(json['max_res_url']);
    if (downloadUrl.isEmpty && fullPath.isNotEmpty) {
      // 兜底：Chub 的卡文件地址固定为 chara_card_v2.png
      downloadUrl = 'https://avatars.charhub.io/avatars/$fullPath/'
          'chara_card_v2.png';
    }
    final topicsRaw = json['topics'];
    final topics = topicsRaw is List
        ? [
            for (final t in topicsRaw)
              if (_str(t).isNotEmpty) _str(t),
          ]
        : const <String>[];
    return MarketCard(
      id: _str(json['id']),
      name: _str(json['name']).trim(),
      creator: creator,
      fullPath: fullPath,
      tagline: _str(json['tagline']).trim(),
      description: _str(json['description']).trim(),
      thumbnailUrl: _str(json['avatar_url']),
      downloadUrl: downloadUrl,
      topics: topics,
      stars: _int(json['starCount']),
      tokens: _int(json['nTokens']),
      chats: _int(json['nChats']),
      nsfw: json['nsfw_image'] == true,
      source: 'Chub.ai',
      pageUrl: fullPath.isEmpty ? 'https://chub.ai' : 'https://chub.ai/characters/$fullPath',
    );
  }

  static String _str(Object? v) => v == null ? '' : v.toString();

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(_str(v)) ?? 0;
  }
}

/// 一页搜索结果。
class MarketSearchPage {
  /// 源报告的总数（用于「加载更多」判断）。
  final int total;
  final List<MarketCard> cards;

  const MarketSearchPage({required this.total, required this.cards});
}

/// 市场标签（标签目录项）：名称 + 使用该标签的公开卡数量。
///
/// `count` 取 Chub 的 `non_private_projects_count`；兜底列表里一律为 0。
class MarketTag {
  /// 标签名（保持英文原文，如 `Science Fiction`）。
  final String name;

  /// 使用该标签的公开卡数量（未知为 0）。
  final int count;

  const MarketTag({required this.name, this.count = 0});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MarketTag && other.name == name && other.count == count;

  @override
  int get hashCode => Object.hash(name, count);

  @override
  String toString() => 'MarketTag($name, $count)';
}

/// 市场筛选条件（不可变值对象）：排序 + 标签包含/排除 + 语言 + 长度 + 其它开关。
///
/// 默认值（[MarketFilters.none]）等价于 v0.11.0 的旧行为：
/// 有关键词按相关度、无关键词浏览热门、不限标签与长度。
class MarketFilters {
  /// 排序方式：
  /// - `relevance`（默认）：不加 `sort` 参数，交给服务端按相关度排；
  /// - `popular`：`sort=star_count`；
  /// - `newest`：`sort=created_at`；
  /// - `trending`：`sort=trending`；
  /// - `random`：`sort=random`；
  /// - `name`：`sort=name`。
  final String sort;

  /// 是否升序（服务端 `asc=true`）；只在实际带了 `sort` 时生效。
  final bool ascending;

  /// 必须包含的标签（英文，如 `Fantasy`）。多个标签**同时满足**（AND 语义）。
  final List<String> tags;

  /// 需要排除的标签（任一命中即排除）。
  final List<String> excludeTags;

  /// 卡片语言（ISO 码，如 `en` / `zh` / `ja` / `ko`）；空串 = 不限。
  final String language;

  /// 最少 tokens；null = 不限。
  final int? minTokens;

  /// 最多 tokens；null = 不限。
  final int? maxTokens;

  /// 最少标签数；null = 不限。
  final int? minTags;

  /// 只出带图片的卡。
  final bool requireImages;

  /// 只出带 lorebook（世界书）的卡。
  final bool requireLore;

  /// 只出带 expressions（表情）的卡。
  final bool requireExpressions;

  const MarketFilters({
    this.sort = 'relevance',
    this.ascending = false,
    this.tags = const <String>[],
    this.excludeTags = const <String>[],
    this.language = '',
    this.minTokens,
    this.maxTokens,
    this.minTags,
    this.requireImages = false,
    this.requireLore = false,
    this.requireExpressions = false,
  });

  /// 无筛选（默认值）。
  static const MarketFilters none = MarketFilters();

  /// 兼容旧名：等价于 [tags]。
  @Deprecated('用 tags 代替')
  List<String> get topics => tags;

  /// 是否未设置任何筛选（用于「清除筛选」按钮显隐）。
  bool get isEmpty =>
      sort == 'relevance' &&
      !ascending &&
      tags.isEmpty &&
      excludeTags.isEmpty &&
      language.isEmpty &&
      minTokens == null &&
      maxTokens == null &&
      minTags == null &&
      !requireImages &&
      !requireLore &&
      !requireExpressions;

  bool get isNotEmpty => !isEmpty;

  /// 解析用户输入的标签串：英文/中文逗号与顿号分隔，去空、去重（忽略大小写，
  /// 保序），最多保留 [max] 个（服务端多标签为 AND 语义，过多会把结果收窄到 0）。
  static List<String> parseTags(String raw, {int max = 8}) {
    final out = <String>[];
    for (final part in raw
        .replaceAll('，', ',')
        .replaceAll('、', ',')
        .split(',')) {
      final tag = part.trim();
      if (tag.isEmpty) continue;
      final lower = tag.toLowerCase();
      if (out.any((t) => t.toLowerCase() == lower)) continue;
      out.add(tag);
      if (out.length >= max) break;
    }
    return out;
  }

  /// 兼容旧名：等价于 [parseTags]（旧默认上限 3）。
  static List<String> parseTopics(String raw, {int max = 3}) =>
      parseTags(raw, max: max);

  static const Object _unset = Object();

  /// 复制并替换部分字段。
  ///
  /// 可空字段（[minTokens]/[maxTokens]/[minTags]）用哨兵区分「不改」与「清空」：
  /// 不传 = 保持原值，显式传 null = 清空。
  MarketFilters copyWith({
    String? sort,
    bool? ascending,
    List<String>? tags,
    List<String>? excludeTags,
    String? language,
    Object? minTokens = _unset,
    Object? maxTokens = _unset,
    Object? minTags = _unset,
    bool? requireImages,
    bool? requireLore,
    bool? requireExpressions,
    /// 兼容旧名：等价于 [tags]。
    List<String>? topics,
  }) {
    return MarketFilters(
      sort: sort ?? this.sort,
      ascending: ascending ?? this.ascending,
      tags: tags ?? topics ?? this.tags,
      excludeTags: excludeTags ?? this.excludeTags,
      language: language ?? this.language,
      minTokens: identical(minTokens, _unset)
          ? this.minTokens
          : minTokens as int?,
      maxTokens: identical(maxTokens, _unset)
          ? this.maxTokens
          : maxTokens as int?,
      minTags: identical(minTags, _unset) ? this.minTags : minTags as int?,
      requireImages: requireImages ?? this.requireImages,
      requireLore: requireLore ?? this.requireLore,
      requireExpressions: requireExpressions ?? this.requireExpressions,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MarketFilters) return false;
    if (other.sort != sort ||
        other.ascending != ascending ||
        other.language != language ||
        other.minTokens != minTokens ||
        other.maxTokens != maxTokens ||
        other.minTags != minTags ||
        other.requireImages != requireImages ||
        other.requireLore != requireLore ||
        other.requireExpressions != requireExpressions ||
        other.tags.length != tags.length ||
        other.excludeTags.length != excludeTags.length) {
      return false;
    }
    for (var i = 0; i < tags.length; i++) {
      if (other.tags[i] != tags[i]) return false;
    }
    for (var i = 0; i < excludeTags.length; i++) {
      if (other.excludeTags[i] != excludeTags[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    sort,
    ascending,
    Object.hashAll(tags),
    Object.hashAll(excludeTags),
    language,
    minTokens,
    maxTokens,
    minTags,
    requireImages,
    requireLore,
    requireExpressions,
  );

  @override
  String toString() =>
      'MarketFilters(sort: $sort, ascending: $ascending, tags: $tags, '
      'excludeTags: $excludeTags, language: $language, minTokens: $minTokens, '
      'maxTokens: $maxTokens, minTags: $minTags, requireImages: $requireImages, '
      'requireLore: $requireLore, '
      'requireExpressions: $requireExpressions)';
}

/// 角色卡数据源抽象：搜索 + 下载。新增来源只需实现这两个能力。
abstract class CardMarketSource {
  /// UI 展示名（如 `Chub.ai`）。
  String get name;

  /// 站点主页（署名用）。
  String get siteUrl;

  /// 默认每页条数。
  int get pageSize;

  /// 搜索第 [page] 页（1 起）。[query] 为空表示「浏览热门」。
  ///
  /// [filters] 为筛选条件；默认 [MarketFilters.none] 保持旧行为。
  Uri searchUri({
    required String query,
    required int page,
    MarketFilters filters = MarketFilters.none,
  });

  /// 解析搜索响应体（JSON 文本）为统一结构；坏数据尽量跳过而不是整体失败。
  MarketSearchPage parseSearch(String body);

  /// 下载卡文件字节（PNG/JSON）。
  Future<Uint8List> download(MarketCard card);

  /// 拉取标签目录（按热度降序）。失败时应返回内置兜底列表而不是抛异常。
  Future<List<MarketTag>> fetchTags({int limit = 200});
}

/// Chub.ai 数据源。实测（2026-11）：
/// `GET https://api.chub.ai/search?search=&first=24&page=1&nsfw=false`
/// 免鉴权 200；`nsfw=false` 只返回 SFW 卡；空关键词 + `sort=star_count`
/// 返回全站热门；每张卡的 `max_res_url` 即 `chara_card_v2.png`。
class ChubSource implements CardMarketSource {
  /// 仅用于可测试注入（标签目录需要 POST）；搜索/下载仍走
  /// [CardMarketClient] 自己的 client。不传时按需临时创建并在用完后关闭。
  const ChubSource({this.httpClient});

  final http.Client? httpClient;

  /// 标签目录接口（POST，GET 会 405）。
  static const String tagsUrl = 'https://api.chub.ai/tags';

  /// 标签目录的内置兜底（网络/解析失败时展示，count 一律 0，保持英文原名）。
  static const List<MarketTag> fallbackTags = <MarketTag>[
    MarketTag(name: 'Fantasy'),
    MarketTag(name: 'Sci-Fi'),
    MarketTag(name: 'OC'),
    MarketTag(name: 'Anime'),
    MarketTag(name: 'RPG'),
    MarketTag(name: 'Romance'),
    MarketTag(name: 'Horror'),
    MarketTag(name: 'Mystery'),
    MarketTag(name: 'Slice of Life'),
    MarketTag(name: 'Action'),
    MarketTag(name: 'Adventure'),
    MarketTag(name: 'Comedy'),
    MarketTag(name: 'Drama'),
    MarketTag(name: 'Historical'),
    MarketTag(name: 'Supernatural'),
    MarketTag(name: 'Male'),
    MarketTag(name: 'Female'),
    MarketTag(name: 'Non-Human'),
    MarketTag(name: 'Multiple Characters'),
    MarketTag(name: 'Scenario'),
    MarketTag(name: 'Roleplay'),
    MarketTag(name: 'Sandbox'),
    MarketTag(name: 'Educational'),
    MarketTag(name: 'Philosophy'),
    MarketTag(name: 'Religion'),
    MarketTag(name: 'Politics'),
    MarketTag(name: 'War'),
    MarketTag(name: 'Post-Apocalyptic'),
    MarketTag(name: 'Cyberpunk'),
    MarketTag(name: 'Magic'),
    MarketTag(name: 'Vampire'),
    MarketTag(name: 'Werewolf'),
    MarketTag(name: 'Demon'),
    MarketTag(name: 'Angel'),
    MarketTag(name: 'Monster'),
    MarketTag(name: 'Elf'),
    MarketTag(name: 'Dwarf'),
    MarketTag(name: 'Orc'),
    MarketTag(name: 'Knight'),
    MarketTag(name: 'Royalty'),
    MarketTag(name: 'School'),
    MarketTag(name: 'Office'),
    MarketTag(name: 'Detective'),
    MarketTag(name: 'Time Travel'),
    MarketTag(name: 'Isekai'),
  ];

  @override
  String get name => 'Chub.ai';

  @override
  String get siteUrl => 'https://chub.ai';

  @override
  int get pageSize => 24;

  /// 排序取值 → Chub 的 `sort` 参数。`relevance` 不在此表（= 不传 sort）。
  static const _sortParams = <String, String>{
    'popular': 'star_count',
    'newest': 'created_at',
    'trending': 'trending',
    'random': 'random',
    'name': 'name',
  };

  @override
  Uri searchUri({
    required String query,
    required int page,
    MarketFilters filters = MarketFilters.none,
  }) {
    final q = query.trim();
    final params = <String, String>{
      'first': '$pageSize',
      'page': '$page',
      // 市场只浏览 SFW（NSFW 版块不在此功能的可用范围内）
      'nsfw': 'false',
    };
    // 空关键词 = 浏览，不带 search
    if (q.isNotEmpty) params['search'] = q;
    // 多标签为 AND 语义（已实测：tags=Fantasy,OC → count 1425）
    if (filters.tags.isNotEmpty) params['tags'] = filters.tags.join(',');
    if (filters.excludeTags.isNotEmpty) {
      params['exclude_tags'] = filters.excludeTags.join(',');
    }
    final language = filters.language.trim();
    if (language.isNotEmpty) params['language'] = language;
    final minTokens = filters.minTokens;
    if (minTokens != null && minTokens > 0) {
      params['min_tokens'] = '$minTokens';
    }
    final maxTokens = filters.maxTokens;
    if (maxTokens != null && maxTokens > 0) {
      params['max_tokens'] = '$maxTokens';
    }
    final minTags = filters.minTags;
    if (minTags != null && minTags > 0) params['min_tags'] = '$minTags';
    if (filters.requireImages) params['require_images'] = 'true';
    if (filters.requireLore) params['require_lore'] = 'true';
    if (filters.requireExpressions) params['require_expressions'] = 'true';
    // 空关键词 = 浏览热门；显式排序时以用户选择为准；
    // 有关键词 + relevance 时不带 sort（交给服务端按相关度排）。
    final sort = _sortParams[filters.sort] ?? (q.isEmpty ? 'star_count' : '');
    if (sort.isNotEmpty) {
      params['sort'] = sort;
      // asc 只在确实带了 sort 时有意义
      if (filters.ascending) params['asc'] = 'true';
    }
    return Uri.https('api.chub.ai', '/search', params);
  }

  @override
  MarketSearchPage parseSearch(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const CardMarketException('市场返回数据异常（不是 JSON）');
    }
    if (decoded is! Map) {
      throw const CardMarketException('市场返回数据异常');
    }
    final data = decoded['data'];
    final nodes = data is Map ? data['nodes'] : null;
    final cards = <MarketCard>[];
    if (nodes is List) {
      for (final node in nodes) {
        if (node is! Map) continue;
        final card = MarketCard.fromChubJson(node.cast<String, dynamic>());
        // 没名字或没下载地址的节点无法入库，直接跳过
        if (card.name.isEmpty || card.downloadUrl.isEmpty) continue;
        cards.add(card);
      }
    }
    final total = data is Map ? MarketCard._int(data['count']) : 0;
    return MarketSearchPage(
      total: total > 0 ? total : cards.length,
      cards: cards,
    );
  }

  @override
  Future<Uint8List> download(MarketCard card) => downloadCard(card.downloadUrl);

  @override
  Future<List<MarketTag>> fetchTags({int limit = 200}) async {
    final first = limit < 1 ? 200 : limit;
    final client = httpClient ?? http.Client();
    final ownsClient = httpClient == null;
    try {
      final response = await client
          .post(
            Uri.parse(tagsUrl),
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, Object?>{'first': first}),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return fallbackTags;
      final tags = _parseTagsBody(utf8.decode(response.bodyBytes));
      // 空目录按失败处理：宁可给兜底列表，也不要让筛选面板空白
      return tags.isEmpty ? fallbackTags : tags;
    } on Exception {
      // 标签目录是「锦上添花」：任何失败都不抛，退回内置列表
      return fallbackTags;
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// 解析标签目录响应；坏数据返回空列表（由调用方回退到 [fallbackTags]）。
  static List<MarketTag> _parseTagsBody(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const <MarketTag>[];
    }
    if (decoded is! Map) return const <MarketTag>[];
    final raw = decoded['tags'];
    if (raw is! List) return const <MarketTag>[];
    final tags = <MarketTag>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final name = MarketCard._str(item['name']).trim();
      final title = MarketCard._str(item['title']).trim();
      final label = name.isNotEmpty ? name : title;
      if (label.isEmpty) continue;
      tags.add(
        MarketTag(
          name: label,
          count: MarketCard._int(item['non_private_projects_count']),
        ),
      );
    }
    return tags;
  }
}

/// 市场客户端：搜索/分页/下载。持有 http.Client，页面 dispose 时释放。
class CardMarketClient {
  CardMarketClient({this.source = const ChubSource(), http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final CardMarketSource source;
  final http.Client _http;
  bool _closed = false;

  /// 搜索一页。失败抛 [CardMarketException]（中文原因可直接展示）。
  Future<MarketSearchPage> search({
    required String query,
    required int page,
    MarketFilters filters = MarketFilters.none,
  }) async {
    if (_closed) throw const CardMarketException('市场已关闭');
    final uri = source.searchUri(query: query, page: page, filters: filters);
    try {
      final response = await _http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw CardMarketException('市场请求失败：HTTP ${response.statusCode}');
      }
      return source.parseSearch(utf8.decode(response.bodyBytes));
    } on CardMarketException {
      rethrow;
    } on TimeoutException {
      throw const CardMarketException('请求超时，请检查网络后重试');
    } on http.ClientException catch (e) {
      throw CardMarketException('网络错误：${e.message}');
    } on FormatException {
      throw const CardMarketException('市场返回数据异常');
    }
  }

  /// 拉取标签目录。任何失败都**不抛异常**：退回 [ChubSource.fallbackTags]
  /// （客户端已关闭时同样返回兜底列表）。
  Future<List<MarketTag>> fetchTags({int limit = 200}) async {
    if (_closed) return ChubSource.fallbackTags;
    try {
      final tags = await source.fetchTags(limit: limit);
      return tags.isEmpty ? ChubSource.fallbackTags : tags;
    } on Exception {
      return ChubSource.fallbackTags;
    }
  }

  /// 下载一张卡的文件字节；失败抛 [CardDownloadException]。
  Future<Uint8List> download(MarketCard card) => source.download(card);

  void dispose() {
    _closed = true;
    _http.close();
  }
}
