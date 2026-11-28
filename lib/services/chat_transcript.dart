import '../models/chat_message.dart';

/// 聊天记录的纯函数工具（v0.24.0）。
///
/// 这里只做「从消息列表算出另一个列表」的事，不碰界面与存储，
/// 方便单测覆盖「对模型隐藏」「对话内搜索」两条行为的边界。

/// 去掉对模型隐藏的消息（`ChatMessage.hidden == true`）。
///
/// 隐藏只影响「发给模型的内容」，本地记录、界面展示、导出都不变，
/// 所以这里只用于组 prompt（以及占用估算），不要拿去写回存储。
List<ChatMessage> visibleForModel(List<ChatMessage> messages) {
  if (!messages.any((m) => m.hidden)) return messages;
  return [for (final m in messages) if (!m.hidden) m];
}

/// 一条搜索命中。
class ChatSearchHit {
  /// 在原始消息列表里的下标（含被隐藏的消息，便于定位）
  final int index;

  final ChatMessage message;

  /// 截取的片段（压平空白、命中处前后各留一段）
  final String snippet;

  /// 命中位置在 [message.content] 里的下标
  final int matchStart;

  const ChatSearchHit({
    required this.index,
    required this.message,
    required this.snippet,
    required this.matchStart,
  });

  bool get isUser => message.role == 'user';
}

/// 在聊天记录里搜索关键词（v0.24.0）。
///
/// - 大小写不敏感；中文按原样包含匹配。
/// - 空关键词 / 全是空白 → 返回空列表（界面显示「输入关键词」）。
/// - 结果按消息顺序返回，最多 [max] 条。
/// - 命中被隐藏的消息也会返回（本地仍能搜到，只是不发给模型）。
List<ChatSearchHit> searchMessages(
  List<ChatMessage> messages,
  String query, {
  int max = 200,
  int snippetRadius = 24,
  List<String>? lowerTexts,
}) {
  final q = query.trim();
  if (q.isEmpty || max <= 0) return const [];
  final needle = q.toLowerCase();
  final lower =
      lowerTexts != null && lowerTexts.length == messages.length ? lowerTexts : null;
  final hits = <ChatSearchHit>[];
  for (var i = 0; i < messages.length && hits.length < max; i++) {
    final m = messages[i];
    final text = m.content;
    if (text.isEmpty) continue;
    final at = (lower != null ? lower[i] : text.toLowerCase()).indexOf(needle);
    if (at < 0) continue;
    hits.add(ChatSearchHit(
      index: i,
      message: m,
      snippet: snippetAround(
        text,
        at,
        needle.length,
        radius: snippetRadius,
      ),
      matchStart: at,
    ));
  }
  return hits;
}

/// 取命中处前后的片段：压平换行与连续空白，两端加省略号。
String snippetAround(
  String text,
  int matchStart,
  int matchLength, {
  int radius = 24,
}) {
  final start = (matchStart - radius).clamp(0, text.length);
  final end = (matchStart + matchLength + radius).clamp(0, text.length);
  var part = text.substring(start, end);
  part = part.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (start > 0) part = '…$part';
  if (end < text.length) part = '$part…';
  return part;
}
