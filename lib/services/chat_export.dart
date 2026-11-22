import 'dart:convert';

import '../models/chat_message.dart';

/// 对话导出为纯文本（聊天页「复制对话」/「导出 .txt」用；纯函数便于测试）。
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

/// 对话导出为 JSON（v0.16.0「导出对话文件」用）。
///
/// 结构：
/// ```json
/// {
///   "format": "litetavern-chat",
///   "version": 1,
///   "character": "角色名",
///   "user": "用户名",
///   "exportedAt": "2026-11-22T20:00:00.000",
///   "messages": [
///     {"role": "user", "name": "你", "content": "…",
///      "timestamp": 1700000000000, "variants": ["…"], "variantIndex": 0}
///   ]
/// }
/// ```
/// 同样跳过空内容占位；variants 有多条时才输出（方便日后做导入）。
String buildExportJson({
  required String charName,
  required String userName,
  required List<ChatMessage> messages,
  required DateTime exportedAt,
}) {
  final list = <Map<String, dynamic>>[];
  for (final m in messages) {
    if (m.content.trim().isEmpty) continue;
    final name = m.role == 'user'
        ? userName
        : (m.senderName?.trim().isNotEmpty == true
            ? m.senderName!.trim()
            : charName);
    final item = <String, dynamic>{
      'role': m.role,
      'name': name,
      'content': m.content,
      'timestamp': m.timestamp,
    };
    if (m.senderName != null && m.senderName!.trim().isNotEmpty) {
      item['senderName'] = m.senderName;
    }
    if (m.variants.length > 1) {
      item['variants'] = m.variants;
      item['variantIndex'] = m.variantIndex;
    }
    list.add(item);
  }
  return const JsonEncoder.withIndent('  ').convert({
    'format': 'litetavern-chat',
    'version': 1,
    'character': charName,
    'user': userName,
    'exportedAt': exportedAt.toIso8601String(),
    'messages': list,
  });
}

/// 导出文件名用的安全化：去掉路径分隔符与非法字符，限制长度。
String safeExportName(String raw, {String fallback = 'chat'}) {
  var name = raw.trim();
  if (name.isEmpty) return fallback;
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
  // 去掉替换后留下的首尾下划线（如「标题?」→「标题_」）
  name = name.replaceAll(RegExp(r'^_+|_+$'), '');
  if (name.length > 40) name = name.substring(0, 40);
  name = name.replaceAll(RegExp(r'_+$'), '');
  return name.isEmpty ? fallback : name;
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
