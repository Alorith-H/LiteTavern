import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/character_card.dart';

/// 解析结果：角色卡 + （PNG 卡时的）原图字节。
class CardParseResult {
  final CharacterCard card;
  final Uint8List? pngBytes;

  const CardParseResult({required this.card, this.pngBytes});
}

/// 角色卡解析：PNG chunk 手工解析（tEXt/zTXt/iTXt）+ JSON 容错解析。
class CardParser {
  /// 入口：根据内容自动识别 PNG 或 JSON。
  static CardParseResult parse(Uint8List bytes, String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.json') || _looksLikeJson(bytes)) {
      return CardParseResult(card: _parseJsonBytes(bytes));
    }
    if (_isPng(bytes)) {
      final json = _extractJsonFromPng(bytes);
      if (json == null) {
        throw const FormatException('PNG 中未找到角色数据（chara/ccv3）');
      }
      final card = _parseJsonString(json);
      return CardParseResult(card: card, pngBytes: bytes);
    }
    throw const FormatException('这不是有效的角色卡文件');
  }

  static bool _isPng(Uint8List bytes) {
    if (bytes.length < 8) return false;
    const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != sig[i]) return false;
    }
    return true;
  }

  static bool _looksLikeJson(Uint8List bytes) {
    // 跳过 BOM / 前导空白后是 { 或 [
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }
    while (start < bytes.length &&
        (bytes[start] == 0x20 ||
            bytes[start] == 0x09 ||
            bytes[start] == 0x0A ||
            bytes[start] == 0x0D)) {
      start++;
    }
    if (start >= bytes.length) return false;
    return bytes[start] == 0x7B /* { */ || bytes[start] == 0x5B /* [ */;
  }

  // ---------------------------------------------------------------- JSON --

  static CharacterCard _parseJsonBytes(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return _parseJsonString(text);
  }

  static CharacterCard _parseJsonString(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('这不是有效的角色卡文件');
    }
    final card = CharacterCard.fromJson(decoded);
    if (card.name.trim().isEmpty) {
      throw const FormatException('这不是有效的角色卡文件');
    }
    return card;
  }

  // ----------------------------------------------------------------- PNG --

  /// 扫描 PNG chunk，找 chara / ccv3 关键字的 tEXt/zTXt/iTXt，返回 JSON 文本。
  static String? _extractJsonFromPng(Uint8List bytes) {
    if (!_isPng(bytes)) return null;
    String? charaJson;
    String? ccv3Json;

    var offset = 8;
    while (offset + 8 <= bytes.length) {
      final length = (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
      final dataStart = offset + 8;
      final dataEnd = dataStart + length;
      if (dataEnd + 4 > bytes.length) break; // 文件截断

      // IEND 结束；tRNS 之后的辅助数据不再关心
      if (type == 'IEND' || type == 'tRNS') break;

      if (type == 'tEXt') {
        final pair = _parseText(bytes.sublist(dataStart, dataEnd));
        if (pair != null) {
          if (pair.$1 == 'ccv3') ccv3Json ??= pair.$2;
          if (pair.$1 == 'chara') charaJson ??= pair.$2;
        }
      } else if (type == 'zTXt') {
        final pair = _parseZText(bytes.sublist(dataStart, dataEnd));
        if (pair != null) {
          if (pair.$1 == 'ccv3') ccv3Json ??= pair.$2;
          if (pair.$1 == 'chara') charaJson ??= pair.$2;
        }
      } else if (type == 'iTXt') {
        final pair = _parseIText(bytes.sublist(dataStart, dataEnd));
        if (pair != null) {
          if (pair.$1 == 'ccv3') ccv3Json ??= pair.$2;
          if (pair.$1 == 'chara') charaJson ??= pair.$2;
        }
      }
      // 其余 chunk（含 IDAT）按 length 跳过

      offset = dataEnd + 4; // 跳过 CRC
    }

    final raw = ccv3Json ?? charaJson;
    if (raw == null) return null;
    return _tryBase64ToJson(raw);
  }

  /// tEXt: keyword\0 text（Latin-1），text 是 base64 JSON。
  static (String, String)? _parseText(Uint8List data) {
    final z = data.indexOf(0);
    if (z <= 0 || z + 1 >= data.length) return null;
    final keyword = latin1.decode(data.sublist(0, z));
    final value = latin1.decode(data.sublist(z + 1));
    return (keyword, value);
  }

  /// zTXt: keyword\0 compressionMethod(0) zlib(base64 文本)。
  static (String, String)? _parseZText(Uint8List data) {
    final z = data.indexOf(0);
    if (z <= 0 || z + 2 > data.length) return null;
    final keyword = latin1.decode(data.sublist(0, z));
    // data[z+1] 是 compression method（0 = zlib）
    final compressed = data.sublist(z + 2);
    try {
      final inflated = ZLibDecoder().decodeBytes(compressed);
      final value = latin1.decode(inflated);
      return (keyword, value);
    } catch (_) {
      return null;
    }
  }

  /// iTXt: keyword\0 flag method lang\0 translated\0 text（可能 zlib 压缩）。
  static (String, String)? _parseIText(Uint8List data) {
    try {
      var i = 0;
      final z1 = data.indexOf(0);
      if (z1 <= 0) return null;
      final keyword = latin1.decode(data.sublist(0, z1));
      i = z1 + 1;
      if (i + 2 > data.length) return null;
      final compressedFlag = data[i];
      i += 2; // 跳过 compression method
      final z2 = data.indexOf(0, i);
      if (z2 < 0) return null;
      i = z2 + 1;
      final z3 = data.indexOf(0, i);
      if (z3 < 0) return null;
      i = z3 + 1;
      List<int> textBytes = data.sublist(i);
      if (compressedFlag == 1) {
        textBytes = ZLibDecoder().decodeBytes(textBytes);
      }
      final value = utf8.decode(textBytes, allowMalformed: true);
      return (keyword, value);
    } catch (_) {
      return null;
    }
  }

  /// base64 → JSON 文本；本身已是 JSON 的直接返回。
  static String? _tryBase64ToJson(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return trimmed;
    final cleaned = trimmed.replaceAll(RegExp(r'\s+'), '');
    try {
      final bytes = base64.decode(cleaned);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}
