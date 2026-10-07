import '../models/world_info.dart';

/// 世界书条目「按对话命中率」统计（v0.8.0）。
///
/// 语义：每个对话里，该词条被激活的比例 = `hits / sends`。
/// - `sends`（JSON 里的 `_sends`）= 该对话中用户发一条消息触发的真实
///   prompt 组装次数（群聊轮转整轮只算 1 次；摘要/上下文预览等
///   不发 API 的组装不计；重新生成 / 继续生成 / 自动继续不计）。
/// - `hits` = 该词条在这些组装中被激活的次数。
///
/// 存储：会话 JSON 的 `hitStats` 字段
/// `{ "_sends": int, "<entryKey>": { "hits": int } }`；
/// 旧会话没有该字段 → [HitStats.isEmpty]，界面不显示、不迁移。
class HitStats {
  /// entryKey → 命中次数
  final Map<String, int> hits;

  /// 该对话的真实发送次数
  final int sends;

  const HitStats({this.hits = const {}, this.sends = 0});

  bool get isEmpty => sends <= 0 && hits.isEmpty;

  /// 记录一次真实发送：`sends+1`，本轮激活的词条各自 `hits+1`。
  HitStats record(Iterable<String> activatedKeys) {
    final next = Map<String, int>.of(hits);
    for (final k in activatedKeys) {
      next[k] = (next[k] ?? 0) + 1;
    }
    return HitStats(hits: next, sends: sends + 1);
  }

  /// 单个词条的命中次数（未命中过 = 0）。
  int hitsOf(String entryKey) => hits[entryKey] ?? 0;

  /// 展示行：`3/12 · 25%`；sends 为 0 时返回 null（无发送记录不显示）。
  String? rateLine(String entryKey) {
    if (sends <= 0) return null;
    final h = hitsOf(entryKey);
    final pct = ((h / sends) * 100).round();
    return '$h/$sends · $pct%';
  }

  factory HitStats.fromJson(Map<String, dynamic> json) {
    final sends = json['_sends'];
    final hits = <String, int>{};
    json.forEach((k, v) {
      if (k == '_sends') return;
      if (v is Map && v['hits'] is num) {
        hits[k] = (v['hits'] as num).toInt();
      } else if (v is num) {
        // 容错：也接受 `key: 3` 的简写
        hits[k] = v.toInt();
      }
    });
    return HitStats(
      hits: hits,
      sends: sends is num ? sends.toInt() : 0,
    );
  }

  Map<String, dynamic> toJson() => {
        '_sends': sends,
        for (final e in hits.entries) e.key: {'hits': e.value},
      };
}

/// 条目稳定标识（统计 key）。
///
/// 有 id 用 id（对象形式世界书的 map key / 条目自带 `id`）；
/// 否则用 `首关键词|insertionOrder` 兜底 —— 编辑条目时关键词或
/// 插入顺序变了 key 会随之变化，旧统计自然作废（可接受的近似）。
String entryKeyOf(WorldInfoEntry e) {
  final id = e.id?.trim();
  if (id != null && id.isNotEmpty) return id;
  final first = e.keys.isNotEmpty ? e.keys.first.trim() : '';
  return '$first|${e.insertionOrder}';
}
