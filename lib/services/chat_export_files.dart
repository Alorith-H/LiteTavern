import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/chat_message.dart';
import 'chat_epub_export.dart';
import 'chat_export.dart';
import 'chat_image_export.dart';

/// 导出格式（v0.25.0 增加长图与 EPUB）。
enum ChatExportFormat {
  text,
  json,
  image,
  epub;

  String get label => switch (this) {
        ChatExportFormat.text => '纯文本 (.txt)',
        ChatExportFormat.json => 'JSON (.json)',
        ChatExportFormat.image => '长图 (.png)',
        ChatExportFormat.epub => '电子书 (.epub)',
      };

  String get hint => switch (this) {
        ChatExportFormat.text => '适合阅读、粘贴到别处',
        ChatExportFormat.json => '保留角色、时间与变体，便于备份',
        ChatExportFormat.image => '所有消息拼成一张图，方便发出去',
        ChatExportFormat.epub => '带排版和目录，可放进阅读器',
      };

  String get extension => switch (this) {
        ChatExportFormat.text => 'txt',
        ChatExportFormat.json => 'json',
        ChatExportFormat.image => 'png',
        ChatExportFormat.epub => 'epub',
      };

  bool get isBinary => this == ChatExportFormat.image || this == ChatExportFormat.epub;
}

/// 对话导出为文件并调起系统分享（v0.16.0，v0.25.0 支持长图 / EPUB）。
///
/// 只做「生成内容 → 写临时文件 → 分享 → 清理」的编排；文本/JSON 由
/// [buildExportText] / [buildExportJson] 生成，长图由 [ChatImageExport]、
/// EPUB 由 [ChatEpubExport] 生成，都便于单测。
class ChatExportFiles {
  ChatExportFiles._();

  /// 生成文本类导出内容（不写文件）。二进制格式请用 [buildBytes]。
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

  /// 生成二进制导出内容（长图 / EPUB）。
  static Future<Uint8List> buildBytes({
    required ChatExportFormat format,
    required String charName,
    required String userName,
    required List<ChatMessage> messages,
    DateTime? exportedAt,
    void Function(double value)? onProgress,
  }) async {
    final at = exportedAt ?? DateTime.now();
    switch (format) {
      case ChatExportFormat.image:
        return ChatImageExport.render(
          charName: charName,
          userName: userName,
          messages: messages,
          exportedAt: at,
          onProgress: onProgress,
        );
      case ChatExportFormat.epub:
        return ChatEpubExport.build(
          charName: charName,
          userName: userName,
          messages: messages,
          exportedAt: at,
        );
      case ChatExportFormat.text:
      case ChatExportFormat.json:
        throw ArgumentError('文本类导出请用 buildContent');
    }
  }

  /// 文本类导出写成临时文件，返回文件（调用方负责分享/清理）。
  static Future<File> writeTempFile({
    required String content,
    required String charName,
    required bool asJson,
    Directory? directory,
    DateTime? now,
  }) async {
    final dir = directory ?? await getTemporaryDirectory();
    final ext = asJson ? 'json' : 'txt';
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      'liteTavern_${safeExportName(charName)}_${_stamp(now)}.$ext',
    );
    await file.writeAsString(content, flush: true);
    return file;
  }

  /// 二进制导出写成临时文件。
  static Future<File> writeTempBytes({
    required Uint8List bytes,
    required String charName,
    required ChatExportFormat format,
    Directory? directory,
    DateTime? now,
  }) async {
    final dir = directory ?? await getTemporaryDirectory();
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      'liteTavern_${safeExportName(charName)}_${_stamp(now)}.${format.extension}',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// 写文件 → 调起分享 → 清理临时文件。返回分享是否成功发起。
  static Future<bool> shareChat({
    required String charName,
    required String userName,
    required List<ChatMessage> messages,
    ChatExportFormat format = ChatExportFormat.text,
    DateTime? now,
    Directory? directory,
    void Function(double value)? onProgress,
  }) async {
    final at = now ?? DateTime.now();
    File? tmp;
    try {
      if (format.isBinary) {
        final bytes = await buildBytes(
          format: format,
          charName: charName,
          userName: userName,
          messages: messages,
          exportedAt: at,
          onProgress: onProgress,
        );
        tmp = await writeTempBytes(
          bytes: bytes,
          charName: charName,
          format: format,
          directory: directory,
          now: at,
        );
      } else {
        final content = buildContent(
          charName: charName,
          userName: userName,
          messages: messages,
          asJson: format == ChatExportFormat.json,
          exportedAt: at,
        );
        tmp = await writeTempFile(
          content: content,
          charName: charName,
          asJson: format == ChatExportFormat.json,
          directory: directory,
          now: at,
        );
      }
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

  static String _stamp(DateTime? d) {
    final at = d ?? DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${at.year}${p2(at.month)}${p2(at.day)}_'
        '${p2(at.hour)}${p2(at.minute)}${p2(at.second)}';
  }
}
