import 'dart:typed_data';

import '../models/character_card.dart';
import 'card_parser.dart';
import 'storage.dart';

/// 把角色卡文件字节（PNG 内嵌 chara / JSON）解析并入库，返回带新 id 的卡。
///
/// 文件导入、链接下载、角色卡市场三处共用这一条入库路径：
/// - 解析失败抛 [FormatException]（message 可直接展示）；
/// - PNG 卡会同时把原图存为头像。
Future<CharacterCard> importCardBytes(
  Uint8List bytes, {
  String filename = '',
}) async {
  final parsed = CardParser.parse(bytes, filename);
  final card = await Storage.saveCharacter(parsed.card);
  if (parsed.pngBytes != null) {
    await Storage.saveAvatar(card.id, parsed.pngBytes!);
  }
  return card;
}
