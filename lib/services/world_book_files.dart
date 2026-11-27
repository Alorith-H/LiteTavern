import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/world_info.dart';

/// 世界书的整本导入 / 导出（v0.27.0）。
///
/// 导出格式与 SillyTavern 一致：`{name, description, entries: {键: 条目}}`，
/// 直接复用 [WorldInfo.toSTJson]；导入同时兼容 Map / List 两种 entries 写法。
class WorldBookFiles {
  /// 生成可保存的 JSON 文本（缩进 2，方便用户用文本编辑器改）。
  static String buildJson(WorldInfo book) {
    return const JsonEncoder.withIndent('  ').convert(book.toSTJson());
  }

  /// 解析导入的字节（UTF-8 JSON）。格式不对抛 [FormatException]。
  static WorldInfo parseBytes(Uint8List bytes, {String fallbackName = ''}) {
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isEmpty) {
      throw const FormatException('文件是空的');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('不是有效的 JSON（世界书应为 .json 文件）');
    }
    if (decoded is! Map) {
      throw const FormatException('世界书 JSON 的最外层应该是对象');
    }
    final map = Map<String, dynamic>.from(decoded);
    // 兼容 ST 的 {entries:{...}} 与"裸条目"写法（整份就是一个 entries map）
    final hasEntries = map['entries'] is Map || map['entries'] is List;
    if (!hasEntries) {
      final looksLikeEntries = map.isNotEmpty &&
          map.values.every(
            (v) =>
                v is Map &&
                (v.containsKey('content') || v.containsKey('key')),
          );
      if (!looksLikeEntries) {
        throw const FormatException('看起来不是世界书文件（缺少 entries）');
      }
      final book = WorldInfo.fromJson({
        'name': fallbackName.isEmpty ? '导入的世界书' : fallbackName,
        'entries': map,
      });
      if (book.entries.isEmpty) {
        throw const FormatException('这个世界书里没有任何条目');
      }
      return book;
    }
    final book = _fromMap(map);
    if (book.entries.isEmpty) {
      throw const FormatException('这个世界书里没有任何条目');
    }
    if (book.name.trim().isEmpty && fallbackName.isNotEmpty) {
      return WorldInfo(
        name: fallbackName,
        description: book.description,
        entries: book.entries,
      );
    }
    return book;
  }

  /// 文件名里的世界书名：去掉路径非法字符。
  static String safeName(String raw, {String fallback = '世界书'}) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final base = cleaned.isEmpty ? fallback : cleaned;
    return base.length <= 40 ? base : base.substring(0, 40);
  }

  /// 写到临时目录（调用方负责分享/清理）。
  static Future<File> writeTempFile({
    required String content,
    required String bookName,
    Directory? directory,
    DateTime? now,
  }) async {
    final dir = directory ?? await getTemporaryDirectory();
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      '${safeName(bookName)}_${_stamp(now)}.json',
    );
    await file.writeAsString(content, flush: true);
    return file;
  }

  /// 分享整本世界书；返回 false 表示分享通道不可用。
  static Future<bool> shareBook(
    WorldInfo book, {
    Directory? directory,
    DateTime? now,
  }) async {
    File? tmp;
    try {
      tmp = await writeTempFile(
        content: buildJson(book),
        bookName: book.name.trim().isEmpty ? '世界书' : book.name,
        directory: directory,
        now: now,
      );
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(tmp.path)],
          subject: '世界书 ${book.name}',
        ),
      );
      return true;
    } finally {
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

  static WorldInfo _fromMap(Map<String, dynamic> map) {
    return WorldInfo.fromJson(map);
  }

  static String _stamp(DateTime? d) {
    final at = d ?? DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${at.year}${p2(at.month)}${p2(at.day)}_'
        '${p2(at.hour)}${p2(at.minute)}${p2(at.second)}';
  }
}
