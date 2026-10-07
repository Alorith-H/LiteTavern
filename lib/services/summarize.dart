import '../models/chat_message.dart';

/// 长对话早期内容摘要（存会话 JSON 的 `summary` 字段）。
class ChatSummary {
  /// ≤300 字的中文摘要
  final String text;

  /// 覆盖到的最后一条消息的时间戳（毫秒）。
  /// 用它判断过期：只要还有「更晚的消息」滑出记忆窗口，摘要就已过期。
  final int updatedAt;

  const ChatSummary({required this.text, required this.updatedAt});

  bool get isEmpty => text.trim().isEmpty;

  factory ChatSummary.fromJson(Map<String, dynamic> json) => ChatSummary(
        text: (json['text'] as String?) ?? '',
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {'text': text, 'updatedAt': updatedAt};
}

/// 摘要纯逻辑（发送前触发判断 / 超窗消息切片），与 UI 和 API 无关。

/// 是否需要在发送前生成摘要：
/// 开关开（调用方判断）且消息总数 > [limit]，且
/// 摘要为空，或已过期 —— 记忆窗口外又出现了比摘要覆盖点更晚的消息。
bool summaryIsStale(
  List<ChatMessage> messages,
  ChatSummary? summary,
  int limit,
) {
  if (messages.length <= limit) return false; // 未超窗，无需摘要
  if (summary == null || summary.isEmpty) return true;
  final early = messages.sublist(0, messages.length - limit);
  return early.any((m) => m.timestamp > summary.updatedAt);
}

/// 摘要的输入：记忆窗口之外的早期消息（不含空内容占位）。
List<ChatMessage> earlyMessages(List<ChatMessage> messages, int limit) {
  if (messages.length <= limit) return const [];
  return messages
      .sublist(0, messages.length - limit)
      .where((m) => m.content.trim().isNotEmpty)
      .toList();
}

/// 是否存在「可总结历史」（聊天菜单入口的显示条件）。
bool hasSummarizableHistory(List<ChatMessage> messages, int limit) =>
    earlyMessages(messages, limit).isNotEmpty;

/// 把早期消息拼成 `名字: 内容` 文本（摘要请求的输入）。
String buildSummaryTranscript({
  required List<ChatMessage> early,
  required String userName,
  required String Function(ChatMessage m) nameOf,
}) {
  final buf = StringBuffer();
  for (final m in early) {
    final name = m.role == 'user' ? userName : nameOf(m);
    buf.writeln('$name: ${m.content}');
  }
  return buf.toString();
}

/// 清洗模型返回的摘要：去掉包裹引号/前缀，硬截断到 300 字。
String normalizeSummary(String raw) {
  var s = raw.trim();
  // 常见的包裹形式：```…```、"…"、'…'、「…」
  if (s.startsWith('```')) {
    s = s.replaceAll('```', '').trim();
  }
  for (final pair in [
    ('“', '”'),
    ('"', '"'),
    ('「', '」'),
    ("'", "'"),
  ]) {
    if (s.length >= 2 && s.startsWith(pair.$1) && s.endsWith(pair.$2)) {
      s = s.substring(1, s.length - 1).trim();
    }
  }
  // 去掉"摘要："这类模型爱加的前缀
  for (final p in ['摘要：', '摘要:', '早期对话摘要：', '早期对话摘要:']) {
    if (s.startsWith(p)) {
      s = s.substring(p.length).trim();
      break;
    }
  }
  if (s.length > 300) s = s.substring(0, 300);
  return s;
}
