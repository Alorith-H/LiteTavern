import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/services/rich_text.dart';
import 'package:litetavern/widgets/rich_message_text.dart';

void main() {
  group('parseRichText 块级', () {
    test('普通段落只有一个块，保留行内换行', () {
      final blocks = parseRichText('第一行\n第二行\n\n第二段');
      expect(blocks.length, 2);
      expect(blocks[0].type, RichBlockType.paragraph);
      expect(blocks[0].spans.first.text, '第一行\n第二行');
      expect(blocks[1].spans.first.text, '第二段');
    });

    test('空文本没有块', () {
      expect(parseRichText(''), isEmpty);
      expect(parseRichText('   \n\n '), isEmpty);
    });

    test('标题级别', () {
      final blocks = parseRichText('# 一\n## 二\n### 三');
      expect(blocks.length, 3);
      expect(blocks.map((b) => b.level).toList(), [1, 2, 3]);
      expect(blocks.every((b) => b.type == RichBlockType.heading), isTrue);
    });

    test('引用合并连续行', () {
      final blocks = parseRichText('> 引一句\n> 再引一句\n后面');
      expect(blocks.first.type, RichBlockType.quote);
      expect(blocks.first.spans.first.text, '引一句\n再引一句');
      expect(blocks.last.spans.first.text, '后面');
    });

    test('代码块保留原文与语言', () {
      final blocks = parseRichText('```dart\nfinal a = 1;\n\nprint(a);\n```\n尾巴');
      expect(blocks.first.type, RichBlockType.codeBlock);
      expect(blocks.first.language, 'dart');
      expect(blocks.first.code, 'final a = 1;\n\nprint(a);');
      expect(blocks.last.spans.first.text, '尾巴');
    });

    test('分隔线', () {
      final blocks = parseRichText('上\n---\n下');
      expect(blocks[1].type, RichBlockType.divider);
    });

    test('无序列表与缩进层级', () {
      final blocks = parseRichText('- 一\n  - 二\n    - 三');
      expect(blocks.length, 3);
      expect(blocks.every((b) => b.type == RichBlockType.bullet), isTrue);
      expect(blocks.map((b) => b.level).toList(), [0, 1, 2]);
    });

    test('有序列表带序号', () {
      final blocks = parseRichText('1. 甲\n2. 乙');
      expect(blocks.first.type, RichBlockType.numbered);
      expect(blocks.map((b) => b.prefix).toList(), ['1', '2']);
    });

    test('表格跳过对齐行', () {
      final blocks = parseRichText('| 名字 | 心情 |\n| --- | --- |\n| 阿岚 | 平静 |');
      expect(blocks.single.type, RichBlockType.table);
      expect(blocks.single.rows.length, 2);
      expect(blocks.single.rows.first.first.text, '名字');
      expect(blocks.single.rows.last.length, 2);
    });
  });

  group('parseInline 行内', () {
    test('粗体 / 斜体 / 删除线 / 行内代码', () {
      final spans = parseInline('**粗** 和 *斜* 和 ~~删~~ 和 `code`');
      expect(spans.any((s) => s.bold && s.text == '粗'), isTrue);
      expect(spans.any((s) => s.italic && s.text == '斜'), isTrue);
      expect(spans.any((s) => s.strike && s.text == '删'), isTrue);
      expect(spans.any((s) => s.code && s.text == 'code'), isTrue);
    });

    test('粗斜体', () {
      final spans = parseInline('***都要***');
      expect(spans.single.bold, isTrue);
      expect(spans.single.italic, isTrue);
    });

    test('链接', () {
      final spans = parseInline('看[官网](https://example.com)吧');
      final link = spans.firstWhere((s) => s.url != null);
      expect(link.text, '官网');
      expect(link.url, 'https://example.com');
    });

    test('「」与“”识别为台词', () {
      final spans = parseInline('「你好呀」她说，“别走”。');
      final dialogue = spans.where((s) => s.dialogue).toList();
      expect(dialogue.length, 2);
      expect(dialogue.first.text, '「你好呀」');
      expect(dialogue.last.text, '“别走”');
    });

    test('未闭合的标记按原文保留', () {
      final spans = parseInline('**没闭合');
      expect(spans.single.text, '**没闭合');
      expect(spans.single.bold, isFalse);
    });

    test('空字符串返回一个空片段', () {
      final spans = parseInline('');
      expect(spans.length, 1);
      expect(spans.single.text, '');
    });
  });

  group('RichBlock.isPlain', () {
    test('纯文字段落 isPlain，带格式就不是', () {
      expect(parseRichText('只是一句话').single.isPlain, isTrue);
      expect(parseRichText('**重**').single.isPlain, isFalse);
      expect(parseRichText('- 列表').single.isPlain, isFalse);
    });
  });

  group('RichMessageText 渲染', () {
    String plainOf(WidgetTester tester) {
      final texts = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((s) => s.textSpan?.toPlainText() ?? s.data ?? '')
          .toList();
      return texts.join(' ');
    }

    testWidgets('段落、台词、列表都能渲染出来', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RichMessageText(
            text: '# 标题\n「你好」\n- 一条\n- 两条',
            style: TextStyle(fontSize: 15),
          ),
        ),
      ));
      final plain = plainOf(tester);
      expect(plain, contains('标题'));
      expect(plain, contains('「你好」'));
      expect(plain, contains('一条'));
      expect(plain, contains('两条'));
      // 列表圆点与标题不在纯文本里重复出现
      expect(find.text('•'), findsNWidgets(2));
    });

    testWidgets('代码块按等宽显示且保留换行', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RichMessageText(
            text: '```json\n{"a": 1}\n```',
            style: TextStyle(fontSize: 15),
          ),
        ),
      ));
      expect(plainOf(tester), contains('{"a": 1}'));
    });

    testWidgets('showCaret 时出现闪烁光标', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RichMessageText(
            text: '正在写',
            style: TextStyle(fontSize: 15),
            showCaret: true,
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('rich-text-caret')), findsOneWidget);
      expect(plainOf(tester), contains('正在写'));
    });

    testWidgets('不显示光标时没有光标 widget', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RichMessageText(
            text: '写完了',
            style: TextStyle(fontSize: 15),
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('rich-text-caret')), findsNothing);
    });
  });
}
