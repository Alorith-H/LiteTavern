import '../models/chat_message.dart';

/// 对话导出为纯文本（聊天页「复制对话」用；纯函数便于测试）。
///
/// 格式：
/// ```text
/// # 和{角色名}的对话（导出时间 yyyy-MM-dd HH:mm）
/// [MM-dd HH:mm] {名字}: {内容}
/// ```
/// 变体只导出当前显示的（ChatMessage.content 即当前变体）；
/// 空内容的占位消息（生成中/失败残留）不导出。
String buildExportText({
  required String charName,
  required String userName,
  required List<ChatMessage> messages,
  required DateTime exportedAt,
}) {
  final buf = StringBuffer(
    '# 和$charName的对话（导出时间 ${_fmtFull(exportedAt)}）\n',
  );
  for (final m in messages) {
    if (m.content.trim().isEmpty) continue;
    // 群聊消息带 senderName（单聊无此字段，回退 charName）
    final name = m.role == 'user'
        ? userName
        : (m.senderName?.trim().isNotEmpty == true
            ? m.senderName!.trim()
            : charName);
    buf.writeln('[${_fmtShort(m.timestamp)}] $name: ${m.content}');
  }
  return buf.toString();
}

/// `2026-10-07 15:04`
String _fmtFull(DateTime d) =>
    '${_p2(d.year)}-${_p2(d.month)}-${_p2(d.day)} ${_p2(d.hour)}:${_p2(d.minute)}';

/// `10-07 15:04`
String _fmtShort(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_p2(d.month)}-${_p2(d.day)} ${_p2(d.hour)}:${_p2(d.minute)}';
}

String _p2(int n) => n.toString().padLeft(2, '0');
