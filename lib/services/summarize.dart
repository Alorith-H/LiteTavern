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

// ---------------------------------------------------------------------------
// 摘要进度提示（v0.15.0）
// 旧文案只有一句「正在总结早期对话…」，用户不知道这是「上下文不够了」还是
// 「token 用光了」。这里把两种触发原因分开，并给出可点开的解释。
// ---------------------------------------------------------------------------

/// 摘要被触发的两种原因。
enum SummaryReason {
  /// 历史消息条数超过「记忆长度」设置（v0.6 摘要管线）。
  historyWindow,

  /// 发送内容预计接近「模型上下文窗口」上限（v0.8 满压缩管线）。
  contextBudget,
}

/// 进度提示的主文案（一行，尽量短，避免挤压输入区）。
String summaryProgressText({
  required SummaryReason reason,
  required int earlyCount,
}) {
  switch (reason) {
    case SummaryReason.historyWindow:
      return '正在把 $earlyCount 条较早的对话压成摘要…';
    case SummaryReason.contextBudget:
      return '上下文快满了，正在压缩 $earlyCount 条早期对话…';
  }
}

/// 进度提示的第二行小字：告诉用户这不是报错、还能继续发。
String summaryProgressHint({required SummaryReason reason}) {
  switch (reason) {
    case SummaryReason.historyWindow:
      return '超出记忆长度的部分会变成摘要发给模型，本地聊天记录不变';
    case SummaryReason.contextBudget:
      return '压缩完成后这条消息会照常发出，本地聊天记录不变';
  }
}

/// 「为什么」弹窗的说明段落（纯文本，便于测试）。
List<String> summaryWhyParagraphs({
  required SummaryReason reason,
  required int historyLimit,
  required int earlyCount,
  int? contextWindow,
  int? estimatedTokens,
}) {
  final trigger = switch (reason) {
    SummaryReason.historyWindow =>
      '触发原因：这个会话的消息条数超过了「记忆长度」上限（当前设置 $historyLimit 条），'
          '有 $earlyCount 条更早的消息需要挪出上下文。',
    SummaryReason.contextBudget =>
      '触发原因：这次要发给模型的内容约 ${estimatedTokens ?? 0} tokens，'
          '已经接近「模型上下文窗口」${contextWindow ?? 0} tokens 的上限。',
  };
  return [
    trigger,
    '不是你的模型额度不够，也不是 token 用光了——只是模型一次能接收的内容有上限，旧对话太多就装不下。',
    '做法：把更早的对话压缩成 300 字以内的摘要，摘要会代替原文发给模型，'
        '所以还能接着聊，而且更省 token。',
    '本机的聊天记录不会被删改，摘要只影响「发给模型的内容」。',
    '不想自动总结：设置 → 长对话自动摘要（可以关掉）；'
        '也可以随时在聊天页右上角 ⋮ 菜单里手动「立即总结早期对话」。',
  ];
}
