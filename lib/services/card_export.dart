import 'dart:convert';
import 'dart:typed_data';

import '../models/character_card.dart';

/// 角色卡导出（v0.7.0）：
/// - JSON：按 chara_card V2 规范重建（data 全字段 + 内嵌世界书）
/// - PNG：读原图字节，替换/新增 `tEXt chara` chunk（base64 JSON），
///   旧 chara/ccv3 文本块（tEXt/zTXt/iTXt）移除，CRC 正确计算。

/// 按 chara_card V2 规范重建导出 JSON。
/// 角色的全部数据字段都写入 `data`；有内嵌世界书则带 `character_book`。
String buildExportJson(CharacterCard card) {
  final data = <String, dynamic>{
    'name': card.name,
    'description': card.description,
    'personality': card.personality,
    'scenario': card.scenario,
    'first_mes': card.firstMes,
    'mes_example': card.mesExample,
    'system_prompt': card.systemPrompt,
    'alternate_greetings': card.alternateGreetings,
    'tags': card.tags,
    'creator': card.creator,
    'extensions': <String, dynamic>{},
    if (card.characterBook != null)
      'character_book': card.characterBook!.toSTJson(),
  };
  return jsonEncode({
    'spec': 'chara_card V2',
    'spec_version': '2.0',
    'data': data,
  });
}

/// 文件名净化：非法路径字符与控制字符替换为 `_`，空名回退「角色卡」。
String safeFileName(String name) {
  var s = name.replaceAll(RegExp(r'[\\/:*?"\x3C\x3E|]|[\x00-\x1F]'), '_');
  s = s.trim();
  s = s.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  return s.isEmpty ? '角色卡' : s;
}

// ---------------------------------------------------------------- PNG --

const List<int> _pngSig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// CRC-32 查表（PNG chunk 校验用），首次使用时构建。
final List<int> _crcTable = () {
  final t = List.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}();

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 该 chunk 是否为 chara/ccv3 的文本块（导出时移除，
/// 保证重导入读到的是新写入的数据）。
bool _isCardTextChunk(String type, List<int> data) {
  if (type != 'tEXt' && type != 'zTXt' && type != 'iTXt') return false;
  final z = data.indexOf(0);
  if (z <= 0) return false;
  final keyword = latin1.decode(data.sublist(0, z)).toLowerCase();
  return keyword == 'chara' || keyword == 'ccv3';
}

/// 在原图字节上替换/新增 `tEXt chara` chunk 为新 JSON 的 base64：
/// 1. 移除旧 chara/ccv3 文本块（tEXt/zTXt/iTXt，含压缩原文）；
/// 2. 在 IHDR 之后插入新 tEXt（保证在 tRNS/IDAT 之前，解析器必能读到）；
/// 3. 所有 chunk 的 CRC 按规范重新计算。
Uint8List embedCharaInPng(Uint8List src, String json) {
  if (src.length < 8) {
    throw const FormatException('不是有效的 PNG 图片');
  }
  for (var i = 0; i < 8; i++) {
    if (src[i] != _pngSig[i]) throw const FormatException('不是有效的 PNG 图片');
  }
  final b64 = base64.encode(utf8.encode(json));
  final newText = <int>[...'chara'.codeUnits, 0, ...latin1.encode(b64)];

  final out = BytesBuilder();
  void emit(List<int> type, List<int> data) {
    out.add([
      (data.length >> 24) & 0xFF,
      (data.length >> 16) & 0xFF,
      (data.length >> 8) & 0xFF,
      data.length & 0xFF,
    ]);
    out.add(type);
    out.add(data);
    final crc = _crc32([...type, ...data]);
    out.add([
      (crc >> 24) & 0xFF,
      (crc >> 16) & 0xFF,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ]);
  }

  out.add(_pngSig);
  var offset = 8;
  var inserted = false;
  while (offset + 8 <= src.length) {
    final len = (src[offset] << 24) |
        (src[offset + 1] << 16) |
        (src[offset + 2] << 8) |
        src[offset + 3];
    final type = src.sublist(offset + 4, offset + 8);
    final dataStart = offset + 8;
    final dataEnd = dataStart + len;
    if (dataEnd + 4 > src.length) break; // 文件截断
    final typeName = String.fromCharCodes(type);
    final data = src.sublist(dataStart, dataEnd);
    offset = dataEnd + 4;

    if (typeName == 'IEND') {
      if (!inserted) {
        emit('tEXt'.codeUnits, newText);
        inserted = true;
      }
      emit(type, data);
      break;
    }
    if (_isCardTextChunk(typeName, data)) continue; // 旧数据块移除
    emit(type, data);
    if (typeName == 'IHDR' && !inserted) {
      emit('tEXt'.codeUnits, newText);
      inserted = true;
    }
  }
  if (!inserted) emit('tEXt'.codeUnits, newText); // 异常 PNG 兜底
  return out.toBytes();
}
