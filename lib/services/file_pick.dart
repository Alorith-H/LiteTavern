import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// 带扩展名过滤的文件选择（v0.32.0 修复）。
///
/// Android 端 file_picker 对「它不认识的扩展名」（如 .charx / .jsonl）会直接
/// 抛 PlatformException(Unsupported filter)。这里先按扩展名过滤试一次，
/// 失败就退回「任意文件」让用户自己挑——反正导入前都会按内容校验。
Future<FilePickerResult?> pickFilesWithExtensions(
  List<String> extensions, {
  bool allowMultiple = false,
}) async {
  try {
    return await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
      allowMultiple: allowMultiple,
      withData: true,
    );
  } on PlatformException {
    return FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: allowMultiple,
      withData: true,
    );
  }
}
