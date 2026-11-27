/// 对话排版（v0.37.0）：气泡 / 小说。
///
/// 只影响**看到的样子**，不改聊天记录、也不影响发给模型的提示词。
library;

/// 对话排版样式。
enum ChatLayout {
  /// 气泡：左右分栏，角色在左、你在右（默认，也是老版本唯一的样子）。
  bubble,

  /// 小说：不分栏、没有气泡底色，像读一段小说；你的话用左侧细线区分。
  novel,
}

/// 排版模式的中文名。
extension ChatLayoutLabel on ChatLayout {
  String get label => switch (this) {
        ChatLayout.bubble => '气泡',
        ChatLayout.novel => '小说',
      };

  String get description => switch (this) {
        ChatLayout.bubble => '左右分栏，像聊天软件',
        ChatLayout.novel => '不分栏、无气泡，像读小说',
      };

  String get id => switch (this) {
        ChatLayout.bubble => 'bubble',
        ChatLayout.novel => 'novel',
      };
}

/// 从存下来的字符串解析，未知值回落气泡。
ChatLayout chatLayoutFromId(String? id) {
  for (final layout in ChatLayout.values) {
    if (layout.id == id) return layout;
  }
  return ChatLayout.bubble;
}

/// 一条消息的排版参数（由 [ChatLayout] 推出来，渲染层直接照着用）。
class MessageLayoutStyle {
  const MessageLayoutStyle({
    required this.bubble,
    required this.alignRight,
    required this.maxWidthFactor,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.verticalMargin,
    required this.showSenderLabel,
    required this.userAccentBar,
  });

  /// 是否画气泡底色/描边。
  final bool bubble;

  /// 是否靠右（只有气泡模式区分左右）。
  final bool alignRight;

  /// 气泡最大宽度占比；小说模式用整行。
  final double maxWidthFactor;

  final double horizontalPadding;
  final double verticalPadding;
  final double verticalMargin;

  /// 群聊里是否显示「谁说的」小标签。
  final bool showSenderLabel;

  /// 是否在你的那段左边画一条细竖线（小说模式用）。
  final bool userAccentBar;

  /// 按模式 + 是不是用户算样式。
  static MessageLayoutStyle of(ChatLayout layout, {required bool isUser}) {
    switch (layout) {
      case ChatLayout.bubble:
        return MessageLayoutStyle(
          bubble: true,
          alignRight: isUser,
          maxWidthFactor: 0.78,
          horizontalPadding: 14,
          verticalPadding: 10,
          verticalMargin: 5,
          showSenderLabel: true,
          userAccentBar: false,
        );
      case ChatLayout.novel:
        return MessageLayoutStyle(
          bubble: false,
          alignRight: false,
          maxWidthFactor: 1.0,
          horizontalPadding: isUser ? 12 : 2,
          verticalPadding: 2,
          verticalMargin: 7,
          showSenderLabel: true,
          userAccentBar: isUser,
        );
    }
  }
}
