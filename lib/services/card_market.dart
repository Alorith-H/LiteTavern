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

/// 市场筛选条件（不可变值对象）：排序 + 标签 + token 长度区间。
///
/// 默认值（[MarketFilters.none]）等价于 v0.11.0 的旧行为：
/// 有关键词按相关度、无关键词浏览热门、不限标签与长度。
class MarketFilters {
  /// 排序方式：
  /// - `relevance`（默认）：不加 `sort` 参数，交给服务端按相关度排；
  /// - `popular`：`sort=star_count`；
  /// - `newest`：`sort=created_at`。
  final String sort;

  /// 标签（英文，如 `Fantasy`）。多个标签**同时满足**（服务端 AND 语义）。
  final List<String> topics;

  /// 最少 tokens；null = 不限。
  final int? minTokens;

  /// 最多 tokens；null = 不限。
  final int? maxTokens;

  const MarketFilters({
    this.sort = 'relevance',
    this.topics = const <String>[],
    this.minTokens,
    this.maxTokens,
  });

  /// 无筛选（默认值）。
  static const MarketFilters none = MarketFilters();

  /// 是否未设置任何筛选（用于「清除筛选」按钮显隐）。
  bool get isEmpty =>
      sort == 'relevance' &&
      topics.isEmpty &&
      minTokens == null &&
      maxTokens == null;

  bool get isNotEmpty => !isEmpty;

  /// 解析用户输入的标签串：英文/中文逗号分隔，去空、去重（忽略大小写，保序），
  /// 最多保留 [max] 个（服务端多标签为 AND 语义，过多会把结果收窄到 0）。
  static List<String> parseTopics(String raw, {int max = 3}) {
    final out = <String>[];
    for (final part in raw.replaceAll('，', ',').split(',')) {
      final tag = part.trim();
      if (tag.isEmpty) continue;
      final lower = tag.toLowerCase();
      if (out.any((t) => t.toLowerCase() == lower)) continue;
      out.add(tag);
      if (out.length >= max) break;
    }
    return out;
  }

  static const Object _unset = Object();

  /// 复制并替换部分字段；[minTokens]/[maxTokens] 传 null 表示「清空」。
  MarketFilters copyWith({
    String? sort,
    List<String>? topics,
    Object? minTokens = _unset,
    Object? maxTokens = _unset,
  }) {
    return MarketFilters(
      sort: sort ?? this.sort,
      topics: topics ?? this.topics,
      minTokens: identical(minTokens, _unset)
          ? this.minTokens
          : minTokens as int?,
      maxTokens: identical(maxTokens, _unset)
          ? this.maxTokens
          : maxTokens as int?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MarketFilters) return false;
    if (other.sort != sort ||
        other.minTokens != minTokens ||
        other.maxTokens != maxTokens ||
        other.topics.length != topics.length) {
      return false;
    }
    for (var i = 0; i < topics.length; i++) {
      if (other.topics[i] != topics[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(sort, Object.hashAll(topics), minTokens, maxTokens);

  @override
  String toString() =>
      'MarketFilters(sort: $sort, topics: $topics, '
      'minTokens: $minTokens, maxTokens: $maxTokens)';
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
}

/// Chub.ai 数据源。实测（2026-11）：
/// `GET https://api.chub.ai/search?search=&first=24&page=1&nsfw=false`
/// 免鉴权 200；`nsfw=false` 只返回 SFW 卡；空关键词 + `sort=star_count`
/// 返回全站热门；每张卡的 `max_res_url` 即 `chara_card_v2.png`。
class ChubSource implements CardMarketSource {
  const ChubSource();

  @override
  String get name => 'Chub.ai';

  @override
  String get siteUrl => 'https://chub.ai';

  @override
  int get pageSize => 24;

  /// 排序取值 → Chub 的 `sort` 参数。
  static const _sortParams = <String, String>{
    'popular': 'star_count',
    'newest': 'created_at',
  };

  @override
  Uri searchUri({
    required String query,
    required int page,
    MarketFilters filters = MarketFilters.none,
  }) {
    final q = query.trim();
    final params = <String, String>{
      'search': q,
      'first': '$pageSize',
      'page': '$page',
      // 市场只浏览 SFW（NSFW 版块不在此功能的可用范围内）
      'nsfw': 'false',
    };
    // 多标签为 AND 语义（已实测：topics=Fantasy,OC → count 1425）
    if (filters.topics.isNotEmpty) {
      params['topics'] = filters.topics.join(',');
    }
    final minTokens = filters.minTokens;
    if (minTokens != null && minTokens > 0) {
      params['min_tokens'] = '$minTokens';
    }
    final maxTokens = filters.maxTokens;
    if (maxTokens != null && maxTokens > 0) {
      params['max_tokens'] = '$maxTokens';
    }
    // 空关键词 = 浏览热门；显式 popular/newest 时以用户选择为准；
    // 有关键词 + relevance 时不带 sort（交给服务端按相关度排）。
    final sort = _sortParams[filters.sort] ?? (q.isEmpty ? 'star_count' : '');
    if (sort.isNotEmpty) params['sort'] = sort;
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

  /// 下载一张卡的文件字节；失败抛 [CardDownloadException]。
  Future<Uint8List> download(MarketCard card) => source.download(card);

  void dispose() {
    _closed = true;
    _http.close();
  }
}
