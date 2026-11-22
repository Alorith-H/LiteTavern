import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/chat_message.dart';
import 'chat_export.dart';

/// 对话导出为文件并调起系统分享（v0.16.0）。
///
/// 只做「写临时文件 → 分享 → 清理」的编排；文本/JSON 内容由
/// [buildExportText] / [buildExportJson] 生成，便于单测。
class ChatExportFiles {
  ChatExportFiles._();

  /// 生成导出内容（不写文件）。
  static String buildContent({
    required String charName,
    required String userName,
    required List<ChatMessage> messages,
    required bool asJson,
    DateTime? exportedAt,
  }) {
    final at = exportedAt ?? DateTime.now();
    return asJson
        ? buildExportJson(
            charName: charName,
            userName: userName,
            messages: messages,
            exportedAt: at,
          )
        : buildExportText(
            charName: charName,
            userName: userName,
            messages: messages,
            exportedAt: at,
          );
  }

  /// 导出成文件，返回文件路径（调用方负责分享/清理）。
  static Future<File> writeTempFile({
    required String content,
    required String charName,
    required bool asJson,
    Directory? directory,
    DateTime? now,
  }) async {
    final dir = directory ?? await getTemporaryDirectory();
    final stamp = _stamp(now ?? DateTime.now());
    final ext = asJson ? 'json' : 'txt';
    final base = safeExportName(charName);
    final file = File(
      '${dir.path}${Platform.pathSeparator}liteTavern_${base}_$stamp.$ext',
    );
    await file.writeAsString(content, flush: true);
    return file;
  }

  /// 写文件 → 调起分享 → 清理临时文件。返回分享是否成功发起。
  static Future<bool> shareChat({
    required String charName,
    required String userName,
    required List<ChatMessage> messages,
    required bool asJson,
    DateTime? now,
    Directory? directory,
  }) async {
    final at = now ?? DateTime.now();
    final content = buildContent(
      charName: charName,
      userName: userName,
      messages: messages,
      asJson: asJson,
      exportedAt: at,
    );
    File? tmp;
    try {
      tmp = await writeTempFile(
        content: content,
        charName: charName,
        asJson: asJson,
        directory: directory,
        now: at,
      );
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(tmp.path)],
          subject: '和$charName的对话',
        ),
      );
      return true;
    } finally {
      // share_plus 会先把文件拷进自己的缓存目录，删原件不影响接收方
      final f = tmp;
      if (f != null) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {
          // 清理失败不影响导出结果
        }
      }
    }
  }

  static String _stamp(DateTime d) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${p2(d.month)}${p2(d.day)}_'
        '${p2(d.hour)}${p2(d.minute)}${p2(d.second)}';
  }
}
