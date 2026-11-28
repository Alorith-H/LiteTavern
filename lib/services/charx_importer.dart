import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/character_card.dart';
import 'card_parser.dart';
import 'import_report.dart';

/// CHARX 导入结果（v0.32.0）：角色卡 + 头像字节 + 体检报告。
class CharxImportResult {
  final CharacterCard card;
  final Uint8List? avatarBytes;
  final ImportReport report;
  final int assetCount;

  const CharxImportResult({
    required this.card,
    required this.report,
    this.avatarBytes,
    this.assetCount = 0,
  });
}

class CharxFormatException implements Exception {
  final String message;
  const CharxFormatException(this.message);
  @override
  String toString() => message;
}

/// CHARX（SillyTavern v3 的压缩卡）导入：zip 里通常有 `card.json` 与 `assets/`。
///
/// 只做「能读出来」：挑出卡 JSON、尽量取一张头像与资源数量；
/// 卡内脚本/变量等扩展不执行，交给体检报告提示。
class CharxImporter {
  static const List<String> _preferredCardNames = [
    'card.json',
    'chara_card_v3.json',
    'character.json',
    'data/card.json',
    'data/character.json',
  ];

  /// 按内容判断是不是 zip（CHARX 本质是 zip）。
  static bool looksLikeZip(Uint8List bytes) {
    if (bytes.length < 4) return false;
    return bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);
  }

  /// 防 zip 炸弹（v0.41.0）：条目数与解压后总大小都设上限，
  /// 超过就当成坏文件拒绝，避免一个几 KB 的 zip 把内存吃爆。
  static const int maxEntries = 2000;
  static const int maxUncompressedBytes = 200 * 1024 * 1024;
  static const int maxSingleFileBytes = 100 * 1024 * 1024;

  static bool isCharxName(String filename) =>
      filename.toLowerCase().endsWith('.charx');

  static CharxImportResult parse(Uint8List bytes, {String filename = ''}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const CharxFormatException('这个 .charx 文件解不开（不是有效的 zip）');
    }

    final files = archive.files.where((f) => f.isFile).toList();
    if (files.isEmpty) {
      throw const CharxFormatException('这个 .charx 里没有文件');
    }
    _guardArchive(files);

    Map<String, dynamic>? raw;
    try {
      raw = _findCardJson(files);
    } catch (_) {
      raw = null;
    }
    if (raw == null) {
      throw const CharxFormatException('这个 .charx 里没有找到 card.json');
    }

    final card = CharacterCard.fromJson(raw);
    if (card.name.trim().isEmpty) {
      throw const CharxFormatException('card.json 里没有角色名');
    }

    final avatar = _pickAvatar(files, card);
    final assets = files.where(_isAsset).length;
    final report = ImportAnalyzer.forCard(
      raw,
      card,
      hasAvatar: avatar != null,
      assetCount: assets,
    );
    return CharxImportResult(
      card: card,
      avatarBytes: avatar,
      report: report,
      assetCount: assets,
    );
  }

  /// 优先按约定文件名找，其次在根目录找能解析出角色名的 json。
  /// 条目数 / 解压后总大小 / 单文件大小三重上限（v0.41.0 防 zip 炸弹）。
  static void _guardArchive(List<ArchiveFile> files) {
    if (files.length > maxEntries) {
      throw CharxFormatException(
        '这个 .charx 里文件太多（${files.length} 个），为安全起见已拒绝导入',
      );
    }
    var total = 0;
    for (final f in files) {
      final size = f.size;
      if (size > maxSingleFileBytes) {
        throw CharxFormatException(
          '这个 .charx 里有一个文件解压后超过 100MB（${f.name}），已拒绝导入',
        );
      }
      total += size;
      if (total > maxUncompressedBytes) {
        throw const CharxFormatException(
          '这个 .charx 解压后超过 200MB，为安全起见已拒绝导入',
        );
      }
    }
  }

  static Map<String, dynamic>? _findCardJson(List<ArchiveFile> files) {
    for (final name in _preferredCardNames) {
      for (final f in files) {
        if (f.name.toLowerCase() == name) {
          final map = _decode(f);
          if (map != null) return map;
        }
      }
    }
    // 再退一步：任意 .json，能解出 name 就认
    for (final f in files) {
      final lower = f.name.toLowerCase();
      if (!lower.endsWith('.json')) continue;
      if (lower.contains('assets/')) continue;
      final map = _decode(f);
      if (map != null) {
        final nameMap = map['data'] is Map ? map['data'] as Map : map;
        if ('${nameMap['name'] ?? ''}'.trim().isNotEmpty) return map;
      }
    }
    return null;
  }

  static Map<String, dynamic>? _decode(ArchiveFile file) {
    try {
      final data = List<int>.from(file.content as List<int>);
      final text = utf8.decode(data, allowMalformed: true);
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // 坏 JSON 直接跳过
    }
    return null;
  }

  static bool _isAsset(ArchiveFile f) =>
      !f.name.toLowerCase().endsWith('.json') &&
      !f.name.toLowerCase().endsWith('.md');

  /// 头像：先看卡里声明的 avatar/icon 字段能否在 zip 里找到，
  /// 否则取体积最大的图片（PNG / JPEG / WebP）。
  static Uint8List? _pickAvatar(List<ArchiveFile> files, CharacterCard card) {
    Uint8List? best;
    var bestSize = 0;
    for (final f in files) {
      if (!_isImage(f.name)) continue;
      final data = _bytes(f);
      if (data == null) continue;
      if (data.length > bestSize) {
        bestSize = data.length;
        best = data;
      }
    }
    return best;
  }

  static bool _isImage(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp');
  }

  static Uint8List? _bytes(ArchiveFile file) {
    try {
      return Uint8List.fromList(List<int>.from(file.content as List<int>));
    } catch (_) {
      return null;
    }
  }

  /// 把 CHARX 转成与 [CardParser] 一致的结果，方便复用导入流程。
  static CardParseResult toParseResult(CharxImportResult result) =>
      CardParseResult(card: result.card, pngBytes: result.avatarBytes);
}
