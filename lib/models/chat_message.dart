/// 聊天消息模型。
class ChatMessage {
  /// 'user' 或 'assistant'
  final String role;
  final String content;

  /// 毫秒时间戳
  final int timestamp;

  /// 生成失败时的错误信息（非空表示这条是失败占位）
  final String? error;

  /// 生成这条回复时请求的输入 tokens（provider 返回的 usage，或本地估算）
  final int? promptTokens;

  /// 这条回复的输出 tokens
  final int? completionTokens;

  /// true = 上面两个值是本地估算（provider 未返回 usage）
  final bool tokensEstimated;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.timestamp,
    this.error,
    this.promptTokens,
    this.completionTokens,
    this.tokensEstimated = false,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: (json['role'] as String?) ?? 'user',
      content: (json['content'] as String?) ?? '',
      timestamp: (json['timestamp'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      error: json['error'] as String?,
      promptTokens: (json['promptTokens'] as num?)?.toInt(),
      completionTokens: (json['completionTokens'] as num?)?.toInt(),
      tokensEstimated: json['tokensEstimated'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      'content': content,
      'timestamp': timestamp,
      if (error != null) 'error': error,
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (completionTokens != null) 'completionTokens': completionTokens,
      if (tokensEstimated) 'tokensEstimated': true,
    };
  }

  ChatMessage copyWith({
    String? content,
    String? error,
    int? promptTokens,
    int? completionTokens,
    bool? tokensEstimated,
  }) {
    return ChatMessage(
      role: role,
      content: content ?? this.content,
      timestamp: timestamp,
      error: error,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      tokensEstimated: tokensEstimated ?? this.tokensEstimated,
    );
  }
}
