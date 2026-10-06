/// 聊天消息模型。
class ChatMessage {
  /// 'user' 或 'assistant'
  final String role;
  final String content;

  /// 毫秒时间戳
  final int timestamp;

  /// 生成失败时的错误信息（非空表示这条是失败占位）
  final String? error;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.timestamp,
    this.error,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: (json['role'] as String?) ?? 'user',
      content: (json['content'] as String?) ?? '',
      timestamp: (json['timestamp'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      error: json['error'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      'content': content,
      'timestamp': timestamp,
      if (error != null) 'error': error,
    };
  }

  ChatMessage copyWith({String? content, String? error}) {
    return ChatMessage(
      role: role,
      content: content ?? this.content,
      timestamp: timestamp,
      error: error,
    );
  }
}
