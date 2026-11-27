import 'dart:typed_data';

import '../models/character_card.dart';
import 'card_parser.dart';
import 'charx_importer.dart';
import 'import_report.dart';
import 'storage.dart';

/// 角色卡导入结果：入库后的卡 + 体检报告（v0.32.0）。
class ImportedCard {
  final CharacterCard card;
  final ImportReport report;

  const ImportedCard({required this.card, required this.report});
}

/// 把角色卡文件字节（PNG 内嵌 chara / JSON / CHARX）解析并入库。
///
/// 文件导入、链接下载、角色卡市场三处共用这一条入库路径：
/// - 解析失败抛 [FormatException]（message 可直接展示）；
/// - PNG 卡会同时把原图存为头像；CHARX 会取包内最大的一张图当头像。
Future<CharacterCard> importCardBytes(
  Uint8List bytes, {
  String filename = '',
}) async {
  final imported = await importCardFile(bytes, filename: filename);
  return imported.card;
}

/// 带体检报告的导入（v0.32.0）：自动识别 PNG / JSON / CHARX。
Future<ImportedCard> importCardFile(
  Uint8List bytes, {
  String filename = '',
}) async {
  if (CharxImporter.isCharxName(filename) || CharxImporter.looksLikeZip(bytes)) {
    final charx = CharxImporter.parse(bytes, filename: filename);
    final card = await Storage.saveCharacter(charx.card);
    if (charx.avatarBytes != null) {
      await Storage.saveAvatar(card.id, charx.avatarBytes!);
    }
    return ImportedCard(card: card, report: charx.report);
  }

  final parsed = CardParser.parse(bytes, filename);
  final card = await Storage.saveCharacter(parsed.card);
  if (parsed.pngBytes != null) {
    await Storage.saveAvatar(card.id, parsed.pngBytes!);
  }
  final report = ImportAnalyzer.forCard(
    parsed.card.toJson(),
    parsed.card,
    hasAvatar: parsed.pngBytes != null,
  );
  return ImportedCard(card: card, report: report);
}
