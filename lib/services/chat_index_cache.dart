import '../models/chat_message.dart';

/// 一段会话的统计结果（v0.42.0）。
class ChatAggregate {
  final int messageCount;
  final int userCount;
  final int assistantCount;
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;
  final bool hasUsage;
  final bool approx;

  const ChatAggregate({
    required this.messageCount,
    required this.userCount,
    required this.assistantCount,
    required this.promptTokens,
    required this.completionTokens,
    required this.cachedTokens,
    required this.hasUsage,
    required this.approx,
  });

  static const empty = ChatAggregate(
    messageCount: 0,
    userCount: 0,
    assistantCount: 0,
    promptTokens: 0,
    completionTokens: 0,
    cachedTokens: 0,
    hasUsage: false,
    approx: false,
  );
}

/// 会话索引缓存（v0.42.0）。
///
/// 长会话里「搜索对话」「聊天统计」每次都会把全部消息扫一遍：搜索还要
/// 反复 `toLowerCase()`（中文不受影响，但英文长文很贵）。这里按「列表对象 +
/// 条数 + 最后一条时间戳」判断有没有变化，没变就直接复用上次的小写文本与聚合。
class ChatIndexCache {
  ChatIndexCache._();

  static final ChatIndexCache instance = ChatIndexCache._();

  List<ChatMessage>? _owner;
  int _length = -1;
  int _lastTs = -1;
  int _lastLen = -1;
  List<String> _lower = const <String>[];
  ChatAggregate _aggregate = ChatAggregate.empty;

  bool _isSame(List<ChatMessage> messages) {
    if (!identical(_owner, messages)) return false;
    if (_length != messages.length) return false;
    if (messages.isEmpty) return true;
    final last = messages.last;
    return _lastTs == last.timestamp && _lastLen == last.content.length;
  }

  /// 全量小写文本（与 [messages] 下标一一对应），用于搜索。
  List<String> lowerTexts(List<ChatMessage> messages) {
    if (_isSame(messages)) return _lower;
    _rebuild(messages);
    return _lower;
  }

  /// 聊天统计聚合。
  ChatAggregate aggregates(List<ChatMessage> messages) {
    if (_isSame(messages)) return _aggregate;
    _rebuild(messages);
    return _aggregate;
  }

  void _rebuild(List<ChatMessage> messages) {
    final lower = List<String>.filled(messages.length, '');
    var users = 0;
    var assistants = 0;
    var inSum = 0;
    var outSum = 0;
    var cachedSum = 0;
    var hasUsage = false;
    var approx = false;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      lower[i] = m.content.toLowerCase();
      if (m.role == 'user') {
        users++;
      } else if (m.role == 'assistant') {
        assistants++;
      }
      final p = m.promptTokens;
      final c = m.completionTokens;
      if (p == null || c == null) continue;
      hasUsage = true;
      inSum += p;
      outSum += c;
      cachedSum += (m.cachedPromptTokens ?? 0).clamp(0, p);
      if (m.tokensEstimated) approx = true;
    }
    _owner = messages;
    _length = messages.length;
    _lastTs = messages.isEmpty ? -1 : messages.last.timestamp;
    _lastLen = messages.isEmpty ? -1 : messages.last.content.length;
    _lower = lower;
    _aggregate = ChatAggregate(
      messageCount: messages.length,
      userCount: users,
      assistantCount: assistants,
      promptTokens: inSum,
      completionTokens: outSum,
      cachedTokens: cachedSum,
      hasUsage: hasUsage,
      approx: approx,
    );
  }

  /// 会话内容被外部改写（隐藏/删除/导入）时清空。
  void invalidate() {
    _owner = null;
    _length = -1;
    _lastTs = -1;
    _lastLen = -1;
    _lower = const <String>[];
    _aggregate = ChatAggregate.empty;
  }

  /// 测试用：重置（单例状态不能跨用例泄漏）。
  void resetForTest() => invalidate();
}
