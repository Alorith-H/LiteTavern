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

/// 角色卡数据源抽象：搜索 + 下载。新增来源只需实现这两个能力。
abstract class CardMarketSource {
  /// UI 展示名（如 `Chub.ai`）。
  String get name;

  /// 站点主页（署名用）。
  String get siteUrl;

  /// 默认每页条数。
  int get pageSize;

  /// 搜索第 [page] 页（1 起）。[query] 为空表示「浏览热门」。
  Uri searchUri({required String query, required int page});

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

  @override
  Uri searchUri({required String query, required int page}) {
    final q = query.trim();
    return Uri.https('api.chub.ai', '/search', {
      'search': q,
      'first': '$pageSize',
      'page': '$page',
      // 市场只浏览 SFW（NSFW 版块不在此功能的可用范围内）
      'nsfw': 'false',
      // 空关键词 = 浏览热门；有关键词时交给服务端按相关度排序
      if (q.isEmpty) 'sort': 'star_count',
    });
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
  CardMarketClient({
    this.source = const ChubSource(),
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final CardMarketSource source;
  final http.Client _http;
  bool _closed = false;

  /// 搜索一页。失败抛 [CardMarketException]（中文原因可直接展示）。
  Future<MarketSearchPage> search({
    required String query,
    required int page,
  }) async {
    if (_closed) throw const CardMarketException('市场已关闭');
    final uri = source.searchUri(query: query, page: page);
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
