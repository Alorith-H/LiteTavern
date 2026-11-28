import 'dart:convert';
import 'dart:typed_data';

import '../models/chat_message.dart';
import 'import_report.dart';

/// SillyTavern 聊天记录导入结果（v0.32.0）。
class StChatImportResult {
  final List<ChatMessage> messages;
  final ImportReport report;
  final int lineCount;
  final int skippedLines;

  const StChatImportResult({
    required this.messages,
    required this.report,
    required this.lineCount,
    required this.skippedLines,
  });
}

class StChatFormatException implements Exception {
  final String message;
  const StChatFormatException(this.message);
  @override
  String toString() => message;
}

/// SillyTavern 的 `.jsonl` 聊天记录：一行一条消息。
///
/// 常见字段：`name`（发言者）、`is_user`、`mes`（正文）、`send_date`
/// （ISO 字符串或毫秒），部分版本用 `role` / `message` / `content`。
class StChatImporter {
  /// 防超大文件 / 超长行把内存与 UI 卡死（v0.41.0）。
  static const int maxBytes = 100 * 1024 * 1024; // 100MB
  static const int maxLines = 200000;
  static const int maxLineChars = 2 * 1024 * 1024; // 单行 2MB

  static bool isJsonlName(String filename) =>
      filename.toLowerCase().endsWith('.jsonl');

  /// 内容探测：每行是 JSON 对象，且至少出现一个消息关键字段。
  static bool looksLikeJsonl(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .take(6);
    var hits = 0;
    for (final line in lines) {
      if (!line.startsWith('{')) continue;
      if (!line.contains('"mes"') &&
          !line.contains('"message"') &&
          !line.contains('"content"') &&
          !line.contains('"is_user"') &&
          !line.contains('"role"')) {
        continue;
      }
      hits++;
    }
    return hits > 0;
  }

  static StChatImportResult parse(
    Uint8List bytes, {
    String charName = '',
    String userName = '你',
  }) {
    if (bytes.length > maxBytes) {
      throw const StChatFormatException('这个聊天记录文件太大了（超过 100MB），已拒绝导入');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final lines = text.split(RegExp(r'\r?\n'));
    if (lines.length > maxLines) {
      throw StChatFormatException(
        '这个聊天记录行数太多（${lines.length} 行，上限 $maxLines 行），已拒绝导入',
      );
    }
    final messages = <ChatMessage>[];
    var skipped = 0;
    int? firstTs;

    for (final rawLine in lines) {
      if (rawLine.length > maxLineChars) {
        skipped++;
        continue;
      }
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      Map<String, dynamic>? json;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {
        json = null;
      }
      if (json == null) {
        skipped++;
        continue;
      }
      final content = _textOf(json);
      if (content.trim().isEmpty) {
        skipped++;
        continue;
      }
      final isUser = _isUser(json, charName: charName, userName: userName);
      final name = '${json['name'] ?? json['sender'] ?? ''}'.trim();
      final ts = _timestampOf(json) ??
          (firstTs ?? DateTime.now().millisecondsSinceEpoch) + messages.length;
      firstTs ??= ts;
      messages.add(ChatMessage(
        role: isUser ? 'user' : 'assistant',
        content: content,
        timestamp: ts,
        senderName: isUser ? null : (name.isEmpty ? null : name),
      ));
    }

    if (messages.isEmpty) {
      throw const StChatFormatException('这个文件里没有可导入的消息（.jsonl 格式不对？）');
    }

    final report = ImportAnalyzer.forChat(
      messages,
      rawLineCount: lines.where((l) => l.trim().isNotEmpty).length,
      skippedLines: skipped,
    );
    return StChatImportResult(
      messages: messages,
      report: report,
      lineCount: messages.length,
      skippedLines: skipped,
    );
  }

  static String _textOf(Map<String, dynamic> json) {
    for (final key in const ['mes', 'message', 'content', 'text']) {
      final v = json[key];
      if (v is String && v.trim().isNotEmpty) return v;
    }
    return '';
  }

  static bool _isUser(
    Map<String, dynamic> json, {
    required String charName,
    required String userName,
  }) {
    final flag = json['is_user'] ?? json['isUser'];
    if (flag is bool) return flag;
    final role = '${json['role'] ?? ''}'.trim().toLowerCase();
    if (role == 'user') return true;
    if (role == 'assistant' || role == 'system') return false;
    final name = '${json['name'] ?? ''}'.trim();
    if (name.isEmpty) return false;
    if (charName.isNotEmpty && name == charName) return false;
    if (name == userName) return true;
    return false;
  }

  static int? _timestampOf(Map<String, dynamic> json) {
    final raw = json['send_date'] ?? json['timestamp'] ?? json['time'];
    if (raw is int) {
      // 秒级时间戳自动换算成毫秒
      return raw > 100000000000 ? raw : raw * 1000;
    }
    if (raw is String && raw.trim().isNotEmpty) {
      final iso = DateTime.tryParse(raw.trim());
      if (iso != null) return iso.millisecondsSinceEpoch;
      final n = int.tryParse(raw.trim());
      if (n != null) return n > 100000000000 ? n : n * 1000;
    }
    return null;
  }
}
