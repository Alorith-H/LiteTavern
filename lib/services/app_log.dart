import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'storage.dart';

/// 轻量诊断日志（v0.41.0 商用加固）。
///
/// 目的：真机崩溃或界面报错后，用户能在「设置 → 帮助与关于 → 诊断日志」里看到
/// 最近发生了什么，而不是只有一个白屏。设计原则：
/// - 永远不抛异常（写日志本身失败必须静默），不能因为日志把 App 弄崩；
/// - 内存里保留最近 [maxLines] 行，文件最多 [maxFileBytes] 字节（超出从头部裁掉）；
/// - 不做网络上报，只在本地，避免隐私问题。
class AppLog {
  AppLog._();

  static const int maxLines = 300;
  static const int maxFileBytes = 256 * 1024;

  static final List<String> _buffer = <String>[];
  static bool _fileReady = false;
  static File? _file;

  /// 当前内存里的日志（旧 → 新），供测试与「诊断日志」页面读取。
  @visibleForTesting
  static List<String> get lines => List<String>.unmodifiable(_buffer);

  /// 记录一条日志；[error]/[stackTrace] 会自动展开。
  static void record(String message, {Object? error, StackTrace? stackTrace}) {
    try {
      final ts = DateTime.now();
      final stamp =
          '${ts.year.toString().padLeft(4, '0')}-${ts.month.toString().padLeft(2, '0')}-'
          '${ts.day.toString().padLeft(2, '0')} '
          '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}:'
          '${ts.second.toString().padLeft(2, '0')}';
      final head = '[$stamp] $message';
      _buffer.add(head);
      if (error != null) {
        _buffer.add('    error: $error');
      }
      if (stackTrace != null) {
        final text = stackTrace.toString().trim();
        if (text.isNotEmpty) {
          _buffer.add('    at: ${text.split('\n').take(6).join('\n        ')}');
        }
      }
      if (_buffer.length > maxLines) {
        _buffer.removeRange(0, _buffer.length - maxLines);
      }
      unawaited(_appendToFile(head, error, stackTrace));
    } catch (_) {
      // 日志失败绝不能影响主流程。
    }
  }

  /// 读取最近的日志（默认 100 行），新的在前。
  ///
  /// 文件里已经落盘的行与内存缓冲会有重叠（同一条既写缓冲又追加文件），
  /// 这里按整行去重，避免「诊断日志」里出现一模一样的重复条目。
  static Future<List<String>> recent({int max = 100}) async {
    final fromFile = await _readFile();
    final all = <String>[];
    final seen = <String>{};
    for (final line in <String>[...fromFile, ..._buffer]) {
      if (seen.add(line)) all.add(line);
    }
    if (all.length <= max) return all.reversed.toList();
    return all.sublist(all.length - max).reversed.toList();
  }

  /// 清空内存与文件。
  static Future<void> clear() async {
    _buffer.clear();
    try {
      final file = await _ensureFile();
      if (file != null && await file.exists()) {
        await file.writeAsString('');
      }
    } catch (_) {}
  }

  /// 把当前内存日志落盘（App 退出/进入后台时可选调用）。
  static Future<void> flush() async {
    try {
      final file = await _ensureFile();
      if (file == null || _buffer.isEmpty) return;
      await _trimFileIfNeeded(file);
      await file.writeAsString('${_buffer.join('\n')}\n', mode: FileMode.append);
    } catch (_) {}
  }

  @visibleForTesting
  static void resetForTest() {
    _buffer.clear();
    _fileReady = false;
    _file = null;
  }

  static Future<File?> _ensureFile() async {
    if (_file != null) return _file;
    try {
      final dir = Storage.docsDir;
      final file = File('${dir.path}/app_log.txt');
      _file = file;
      return file;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _appendToFile(
    String head,
    Object? error,
    StackTrace? stackTrace,
  ) async {
    if (!_fileReady) {
      _fileReady = true;
    }
    final file = await _ensureFile();
    if (file == null) return;
    final buf = StringBuffer(head)..writeln();
    if (error != null) buf.writeln('    error: $error');
    if (stackTrace != null) {
      final text = stackTrace.toString().trim();
      if (text.isNotEmpty) {
        buf.writeln('    at: ${text.split('\n').take(6).join('\n        ')}');
      }
    }
    await _trimFileIfNeeded(file);
    await file.writeAsString(buf.toString(), mode: FileMode.append);
  }

  static Future<void> _trimFileIfNeeded(File file) async {
    try {
      if (!await file.exists()) return;
      final length = await file.length();
      if (length <= maxFileBytes) return;
      final text = await file.readAsString();
      final keep = text.length > maxFileBytes ~/ 2
          ? text.substring(text.length - maxFileBytes ~/ 2)
          : text;
      await file.writeAsString(keep);
    } catch (_) {}
  }

  static Future<List<String>> _readFile() async {
    try {
      final file = await _ensureFile();
      if (file == null || !await file.exists()) return const <String>[];
      final text = await file.readAsString();
      if (text.trim().isEmpty) return const <String>[];
      final all = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (all.length > maxLines) {
        return all.sublist(all.length - maxLines);
      }
      return all;
    } catch (_) {
      return const <String>[];
    }
  }
}
