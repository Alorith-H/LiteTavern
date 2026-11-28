/// 消息富文本解析（v0.47.0）。
///
/// 角色卡模型的回复里常见 Markdown：`**强调**`、`*动作*`、`> 引用`、
/// `- 列表`、```代码块```，还有成对的「台词」。早期只交给
/// `flutter_markdown` 渲染，样式是默认的、台词也看不出重点；这一版自己解析，
/// 顺带把对话行文里的「」和 *动作* 做出层次。
///
/// 本文件只做纯字符串 → 结构，方便单测；具体长什么样在
/// `lib/widgets/rich_message_text.dart` 里决定。
library;

/// 块级元素的类型。
enum RichBlockType {
  paragraph,
  heading,
  codeBlock,
  quote,
  bullet,
  numbered,
  divider,
  table,
}

/// 行内片段：一段同一样式的文字。
class RichSpan {
  const RichSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.strike = false,
    this.dialogue = false,
    this.url,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;
  final bool strike;

  /// 「」或“”里的台词，用强调色显示。
  final bool dialogue;

  /// `[文字](url)` 里的链接；有值时可点击。
  final String? url;

  RichSpan withText(String value) => RichSpan(
        value,
        bold: bold,
        italic: italic,
        code: code,
        strike: strike,
        dialogue: dialogue,
        url: url,
      );

  RichSpan boldCopy() => RichSpan(
        text,
        bold: true,
        italic: italic,
        code: code,
        strike: strike,
        dialogue: dialogue,
        url: url,
      );
}

/// 一个块级元素。
class RichBlock {
  const RichBlock(
    this.type, {
    this.spans = const <RichSpan>[],
    this.level = 0,
    this.code = '',
    this.language = '',
    this.prefix = '',
    this.rows = const <List<RichSpan>>[],
  });

  final RichBlockType type;

  /// 段落 / 标题 / 引用 / 列表项的行内内容。
  final List<RichSpan> spans;

  /// 标题级别（1–6）或列表缩进层级。
  final int level;

  /// 代码块原文。
  final String code;

  /// 代码块语言标记。
  final String language;

  /// 有序列表的序号（如 `3.`）。
  final String prefix;

  /// 表格行。
  final List<List<RichSpan>> rows;

  bool get isPlain =>
      type == RichBlockType.paragraph &&
      spans.length == 1 &&
      spans.first.url == null &&
      !spans.first.bold &&
      !spans.first.italic &&
      !spans.first.code &&
      !spans.first.strike &&
      !spans.first.dialogue;
}

/// 解析整段消息文本。
List<RichBlock> parseRichText(String source) {
  final blocks = <RichBlock>[];
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  var i = 0;

  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();

    if (trimmed.isEmpty) {
      i++;
      continue;
    }

    // 代码块 ```lang ... ```
    if (trimmed.startsWith('```')) {
      final language = trimmed.substring(3).trim();
      final buffer = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        buffer.add(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // 跳过结束围栏
      blocks.add(RichBlock(
        RichBlockType.codeBlock,
        code: buffer.join('\n'),
        language: language,
      ));
      continue;
    }

    // 分隔线
    if (RegExp(r'^\s*([-*_])\s*(\1\s*){2,}$').hasMatch(line)) {
      blocks.add(const RichBlock(RichBlockType.divider));
      i++;
      continue;
    }

    // 标题
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (heading != null) {
      blocks.add(RichBlock(
        RichBlockType.heading,
        level: heading.group(1)!.length,
        spans: parseInline(heading.group(2)!),
      ));
      i++;
      continue;
    }

    // 引用（连续多行合并成一个块）
    if (trimmed.startsWith('>')) {
      final buffer = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        buffer.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
        i++;
      }
      blocks.add(RichBlock(
        RichBlockType.quote,
        spans: parseInline(buffer.join('\n')),
      ));
      continue;
    }

    // 表格：连续的 | ... | 行
    if (trimmed.startsWith('|') && trimmed.endsWith('|')) {
      final rows = <List<RichSpan>>[];
      while (i < lines.length) {
        final t = lines[i].trim();
        if (!t.startsWith('|') || !t.endsWith('|')) break;
        i++;
        // 对齐行 |---|---| 只用来分隔表头，不显示
        if (RegExp(r'^\|[\s:|-]+\|$').hasMatch(t) &&
            t.replaceAll(RegExp(r'[\s|:-]'), '').isEmpty) {
          continue;
        }
        final cells = <RichSpan>[];
        for (final cell in t.substring(1, t.length - 1).split('|')) {
          cells.addAll(parseInline(cell.trim()));
        }
        rows.add(cells);
      }
      if (rows.isNotEmpty) {
        blocks.add(RichBlock(RichBlockType.table, rows: rows));
      }
      continue;
    }

    // 无序列表
    final bullet = RegExp(r'^([-*+])\s+(.*)$').firstMatch(trimmed);
    if (bullet != null) {
      blocks.add(RichBlock(
        RichBlockType.bullet,
        level: _indentLevel(line),
        spans: parseInline(bullet.group(2)!),
      ));
      i++;
      continue;
    }

    // 有序列表
    final numbered = RegExp(r'^(\d+)[.)]\s+(.*)$').firstMatch(trimmed);
    if (numbered != null) {
      blocks.add(RichBlock(
        RichBlockType.numbered,
        level: _indentLevel(line),
        prefix: numbered.group(1)!,
        spans: parseInline(numbered.group(2)!),
      ));
      i++;
      continue;
    }

    // 普通段落：吃到空行为止
    final buffer = <String>[];
    while (i < lines.length) {
      final t = lines[i].trim();
      if (t.isEmpty) break;
      if (t.startsWith('```') ||
          t.startsWith('>') ||
          t.startsWith('|') ||
          RegExp(r'^\s*([-*_])\s*(\1\s*){2,}$').hasMatch(lines[i]) ||
          RegExp(r'^(#{1,6})\s').hasMatch(t) ||
          RegExp(r'^[-*+]\s').hasMatch(t) ||
          RegExp(r'^\d+[.)]\s').hasMatch(t)) {
        break;
      }
      buffer.add(lines[i].trimRight());
      i++;
    }
    blocks.add(RichBlock(
      RichBlockType.paragraph,
      spans: parseInline(buffer.join('\n')),
    ));
  }

  return blocks;
}

int _indentLevel(String line) {
  final spaces = line.length - line.trimLeft().length;
  return spaces ~/ 2;
}

/// 解析一行（或一段）里的行内格式。
List<RichSpan> parseInline(String text) {
  final spans = <RichSpan>[];
  final buffer = StringBuffer();

  void flush({RichSpan Function(String)? wrap}) {
    if (buffer.isEmpty) return;
    final value = buffer.toString();
    buffer.clear();
    spans.add(wrap == null ? RichSpan(value) : wrap(value));
  }

  var i = 0;
  while (i < text.length) {
    // 行内代码
    if (text[i] == '`') {
      final end = text.indexOf('`', i + 1);
      if (end > i) {
        flush();
        spans.add(RichSpan(text.substring(i + 1, end), code: true));
        i = end + 1;
        continue;
      }
    }

    // 删除线
    if (text.startsWith('~~', i)) {
      final end = text.indexOf('~~', i + 2);
      if (end > i) {
        flush();
        spans.add(RichSpan(text.substring(i + 2, end), strike: true));
        i = end + 2;
        continue;
      }
    }

    // 粗体 + 斜体
    if (text.startsWith('***', i)) {
      final end = text.indexOf('***', i + 3);
      if (end > i) {
        flush();
        spans.add(RichSpan(
          text.substring(i + 3, end),
          bold: true,
          italic: true,
        ));
        i = end + 3;
        continue;
      }
    }

    // 粗体
    if (text.startsWith('**', i)) {
      final end = text.indexOf('**', i + 2);
      if (end > i) {
        flush();
        spans.add(RichSpan(text.substring(i + 2, end), bold: true));
        i = end + 2;
        continue;
      }
    }

    // 链接 [文字](url)
    if (text[i] == '[') {
      final close = text.indexOf('](', i + 1);
      if (close > i) {
        final end = text.indexOf(')', close + 2);
        if (end > close) {
          flush();
          spans.add(RichSpan(
            text.substring(i + 1, close),
            url: text.substring(close + 2, end),
          ));
          i = end + 1;
          continue;
        }
      }
    }

    // 台词：「」与“”
    if (text[i] == '「') {
      final end = text.indexOf('」', i + 1);
      if (end > i) {
        flush();
        spans.add(RichSpan(text.substring(i, end + 1), dialogue: true));
        i = end + 1;
        continue;
      }
    }
    if (text[i] == '“') {
      final end = text.indexOf('”', i + 1);
      if (end > i) {
        flush();
        spans.add(RichSpan(text.substring(i, end + 1), dialogue: true));
        i = end + 1;
        continue;
      }
    }

    // 斜体（动作/旁白）：*文字* 或 _文字_
    if (text[i] == '*' || text[i] == '_') {
      final mark = text[i];
      final end = text.indexOf(mark, i + 1);
      if (end > i + 1 && !text.substring(i + 1, end).contains('\n')) {
        flush();
        spans.add(RichSpan(text.substring(i + 1, end), italic: true));
        i = end + 1;
        continue;
      }
    }

    // 普通换行 → 保留为可断行的字符
    buffer.write(text[i]);
    i++;
  }

  flush();
  if (spans.isEmpty) return const <RichSpan>[RichSpan('')];
  return spans;
}
