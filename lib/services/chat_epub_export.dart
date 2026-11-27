// 对话导出为 EPUB（v0.25.0）。
//
// 手写一个最小可用的 EPUB 3 包：mimetype + container.xml + content.opf +
// nav.xhtml + style.css + chapter1.xhtml，用 archive 打成 zip。
// 纯 Dart 实现，便于单测（解包后逐项校验）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/chat_message.dart';

class ChatEpubExport {
  ChatEpubExport._();

  static Uint8List build({
    required String charName,
    required String userName,
    required List<ChatMessage> messages,
    DateTime? exportedAt,
  }) {
    final at = exportedAt ?? DateTime.now();
    final safeTitle = charName.trim().isEmpty ? '对话' : charName.trim();
    final messagesForExport = messages
        .where((m) => m.content.trim().isNotEmpty)
        .toList(growable: false);
    final uuid = 'urn:uuid:litetavern-${at.millisecondsSinceEpoch}';

    final archive = Archive();
    void add(String path, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    // mimetype 必须是第一个条目且不压缩（zip 规范要求），3.6 的 ArchiveFile
    // 没有直接暴露 store 标志，这里仍放在第一位，主流阅读器都能接受。
    add('mimetype', 'application/epub+zip');
    add('META-INF/container.xml', _container);
    add('OEBPS/content.opf', _opf(
      uuid: uuid,
      title: '和 $safeTitle 的对话',
      language: 'zh-CN',
      modified: _isoTime(at),
    ));
    add('OEBPS/nav.xhtml', _nav(title: '和 $safeTitle 的对话'));
    add('OEBPS/style.css', _css);
    add(
      'OEBPS/chapter1.xhtml',
      _chapter(
        title: '和 $safeTitle 的对话',
        charName: safeTitle,
        userName: userName,
        messages: messagesForExport,
        exportedAt: at,
      ),
    );

    final encoded = ZipEncoder().encode(archive) ?? const <int>[];
    return Uint8List.fromList(encoded);
  }

  static String _chapter({
    required String title,
    required String charName,
    required String userName,
    required List<ChatMessage> messages,
    required DateTime exportedAt,
  }) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="utf-8"?>')
      ..writeln(
          '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" '
          '"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">')
      ..writeln(
          '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN">')
      ..writeln('<head>')
      ..writeln('<meta charset="utf-8"/>')
      ..writeln('<title>${_esc(title)}</title>')
      ..writeln('<link rel="stylesheet" type="text/css" href="style.css"/>')
      ..writeln('</head>')
      ..writeln('<body>')
      ..writeln('<h1>${_esc(title)}</h1>')
      ..writeln('<p class="meta">导出于 ${_esc(_isoDate(exportedAt))}'
          ' · 共 ${messages.length} 条</p>');

    for (final m in messages) {
      final fromUser = m.role == 'user';
      final who = fromUser ? userName : (m.senderName ?? charName);
      b
        ..writeln('<div class="msg ${fromUser ? 'user' : 'char'}">')
        ..writeln('<p class="who">${_esc(who)}</p>')
        ..writeln('<p class="text">${_esc(m.content).replaceAll('\n', '<br/>')}</p>')
        ..writeln('</div>');
    }

    b
      ..writeln('</body>')
      ..writeln('</html>');
    return b.toString();
  }

  static const String _container = '''<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

  static String _opf({
    required String uuid,
    required String title,
    required String language,
    required String modified,
  }) =>
      '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="zh-CN">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">$uuid</dc:identifier>
    <dc:title>${_esc(title)}</dc:title>
    <dc:language>$language</dc:language>
    <dc:creator>轻酒馆 LiteTavern</dc:creator>
    <meta property="dcterms:modified">$modified</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter1"/>
  </spine>
</package>
''';

  static String _nav({required String title}) =>
      '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh-CN">
<head><meta charset="utf-8"/><title>${_esc(title)}</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>目录</h1>
    <ol><li><a href="chapter1.xhtml">${_esc(title)}</a></li></ol>
  </nav>
</body>
</html>
''';

  static const String _css = '''
body { font-family: serif; line-height: 1.7; margin: 1.2em; color: #241e1a; }
h1 { font-size: 1.4em; margin: 0.2em 0 0.6em; }
.meta { color: #8b7f78; font-size: 0.85em; margin-bottom: 1.4em; }
.msg { margin: 0 0 1.1em; padding: 0.6em 0.8em; border-radius: 0.6em; }
.msg.char { background: #f2ece7; }
.msg.user { background: #e7d5cb; margin-left: 2.2em; }
.who { font-size: 0.8em; color: #8a5a44; margin: 0 0 0.25em; font-weight: bold; }
.text { margin: 0; white-space: normal; }
''';

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String _p2(int n) => n.toString().padLeft(2, '0');

  static String _isoDate(DateTime d) =>
      '${d.year}-${_p2(d.month)}-${_p2(d.day)} ${_p2(d.hour)}:${_p2(d.minute)}';

  static String _isoTime(DateTime d) =>
      '${d.year}-${_p2(d.month)}-${_p2(d.day)}T'
      '${_p2(d.hour)}:${_p2(d.minute)}:${_p2(d.second)}Z';
}
