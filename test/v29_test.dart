import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/screens/display_regex_screen.dart';
import 'package:litetavern/services/display_regex.dart';
import 'package:litetavern/services/storage.dart';

DisplayRegex _rx({
  String id = 'r1',
  String name = '测试',
  String pattern = 'foo',
  String flags = '',
  String replacement = 'bar',
  bool enabled = true,
  RegexScope scope = RegexScope.all,
}) =>
    DisplayRegex(
      id: id,
      name: name,
      pattern: pattern,
      flags: flags,
      replacement: replacement,
      enabled: enabled,
      scope: scope,
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    DisplayRegexLibrary.resetForTest();
  });

  group('正则解析（v0.29.0）', () {
    test('SillyTavern 的 findRegex 拆成正则与标志', () {
      expect(DisplayRegex.splitFindRegex('/a+b/gi'), ('a+b', 'i'));
      expect(DisplayRegex.splitFindRegex('/\\n{3,}/s'), ('\\n{3,}', 's'));
      expect(DisplayRegex.splitFindRegex('plain'), ('plain', ''));
      expect(DisplayRegex.splitFindRegex(''), ('', ''));
      // 未知标志会被丢掉，避免正则编译失败
      expect(DisplayRegex.splitFindRegex('/x/gx'), ('x', ''));
    });

    test('fromSillyTavern 读取名称 / 替换 / 禁用 / 作用域', () {
      final regex = DisplayRegex.fromSillyTavern({
        'id': 'abc',
        'scriptName': '  去掉空行  ',
        'findRegex': '/\\n{3,}/s',
        'replaceString': '\n\n',
        'disabled': true,
        'scope': 'assistant',
      });
      expect(regex.id, 'abc');
      expect(regex.name, '去掉空行');
      expect(regex.pattern, '\\n{3,}');
      expect(regex.flags, 's');
      expect(regex.replacement, '\n\n');
      expect(regex.enabled, isFalse);
      expect(regex.scope, RegexScope.assistant);
    });

    test('缺字段时给出安全默认值', () {
      final regex = DisplayRegex.fromSillyTavern({'findRegex': 'x'});
      expect(regex.name, '未命名正则');
      expect(regex.enabled, isTrue);
      expect(regex.scope, RegexScope.all);
      expect(regex.replacement, '');
    });

    test('写回 JSON 后能被再次读成同一条', () {
      final source = _rx(name: '删空行', pattern: '\\n{3,}', flags: 's', replacement: '\n\n');
      final back = DisplayRegex.fromSillyTavern(source.toJson());
      expect(back.name, '删空行');
      expect(back.pattern, '\\n{3,}');
      expect(back.flags, 's');
      expect(back.replacement, '\n\n');
      expect(back.enabled, isTrue);
    });
  });

  group('正则应用（v0.29.0）', () {
    test('普通替换与删除匹配', () {
      expect(_rx(pattern: 'foo', replacement: 'bar').apply('foo foo'), 'bar bar');
      expect(_rx(pattern: r'\s+$', replacement: '').apply('你好   '), '你好');
    });

    test('支持分组引用 \$1 / \${1} / \$&', () {
      final regex = _rx(pattern: r'(\w+)@(\w+)', replacement: r'$2:$1');
      expect(regex.apply('alorith@tavern'), 'tavern:alorith');
      final brace = _rx(pattern: r'(\d+)px', replacement: r'${1}pt');
      expect(brace.apply('12px 与 14px'), '12pt 与 14pt');
      final whole = _rx(pattern: r'\$\d+', replacement: r'<$&>');
      expect(whole.apply(r'价格 $30 起'), r'价格 <$30> 起');
    });

    test('i / s 标志生效', () {
      expect(_rx(pattern: 'FOO', flags: 'i', replacement: 'x').apply('foo Foo'),
          'x x');
      expect(
          _rx(pattern: 'a.b', flags: 's', replacement: 'x').apply('a\nb a b'),
          'x x');
    });

    test('未启用时原样返回', () {
      expect(_rx(pattern: 'foo', replacement: 'bar', enabled: false).apply('foo'),
          'foo');
    });

    test('正则写错时标记错误且不抛异常', () {
      final broken = _rx(pattern: '(');
      expect(broken.hasError, isTrue);
      expect(broken.compile(), isNull);
      expect(broken.apply('abc'), 'abc');
    });

    test('作用范围判断', () {
      expect(_rx(scope: RegexScope.all).matchesScope(isUser: true), isTrue);
      expect(_rx(scope: RegexScope.all).matchesScope(isUser: false), isTrue);
      expect(_rx(scope: RegexScope.user).matchesScope(isUser: true), isTrue);
      expect(_rx(scope: RegexScope.user).matchesScope(isUser: false), isFalse);
      expect(_rx(scope: RegexScope.assistant).matchesScope(isUser: false), isTrue);
      expect(_rx(scope: RegexScope.assistant).matchesScope(isUser: true), isFalse);
    });
  });

  group('正则库（v0.29.0）', () {
    test('保存 / 读取 / 删除走 prefs，且顺序保持', () async {
      await DisplayRegexLibrary.save([
        _rx(id: 'a', name: '一', pattern: '1', replacement: 'x'),
        _rx(id: 'b', name: '二', pattern: '2', replacement: 'y', enabled: false),
      ]);
      DisplayRegexLibrary.resetForTest();
      final loaded = DisplayRegexLibrary.sorted();
      expect(loaded.map((r) => r.name), ['一', '二']);
      expect(loaded[1].enabled, isFalse);

      await DisplayRegexLibrary.remove('a');
      expect(DisplayRegexLibrary.sorted().map((r) => r.id), ['b']);
      expect(AppSettings.displayRegexesJson, isNotNull);
    });

    test('按顺序链式应用，只命中各自作用域', () async {
      await DisplayRegexLibrary.save([
        _rx(id: 'a', pattern: '你', replacement: '我'),
        _rx(id: 'b', pattern: '我', replacement: 'TA', scope: RegexScope.assistant),
      ]);
      // 「你」→「我」；第二条只对角色生效，用户消息不接着变
      expect(DisplayRegexLibrary.apply('你好', isUser: true), '我好');
      expect(DisplayRegexLibrary.apply('你好', isUser: false), 'TA好');
    });

    test('导入 SillyTavern 数组：新增计数与同 id 覆盖', () async {
      final added = await DisplayRegexLibrary.importFromJson('''
      [
        {"id":"s1","scriptName":"A","findRegex":"/a/g","replaceString":"b","disabled":false},
        {"id":"s2","scriptName":"B","findRegex":"/c/i","replaceString":"d","disabled":true}
      ]
      ''');
      expect(added, 2);
      expect(DisplayRegexLibrary.sorted().length, 2);
      expect(DisplayRegexLibrary.sorted()[1].enabled, isFalse);

      final again = await DisplayRegexLibrary.importFromJson(
          '{"id":"s1","scriptName":"A 改名","findRegex":"/a/g","replaceString":"z"}');
      expect(again, 0);
      expect(DisplayRegexLibrary.sorted().length, 2);
      expect(DisplayRegexLibrary.sorted()[0].name, 'A 改名');
      expect(DisplayRegexLibrary.sorted()[0].replacement, 'z');
    });

    test('坏 JSON / 空数据不会崩', () async {
      expect(DisplayRegexLibrary.apply('原文', isUser: true), '原文');
      expect(await DisplayRegexLibrary.importFromJson('{}'), 1);
      expect(DisplayRegexLibrary.sorted().first.pattern, '');
    });
  });

  group('显示正则页面（v0.29.0）', () {
    testWidgets('列表展示、开关落盘、试一下弹层', (tester) async {
      await DisplayRegexLibrary.save([
        _rx(id: 'x1', name: '删空行', pattern: '\\n{3,}', flags: 's', replacement: '\n\n'),
      ]);

      await tester.pumpWidget(const MaterialApp(home: DisplayRegexScreen()));
      await tester.pumpAndSettle();

      expect(find.text('显示正则'), findsOneWidget);
      expect(find.text('删空行'), findsOneWidget);
      expect(find.text('全部消息'), findsOneWidget);

      // 关闭开关 → 落盘
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(DisplayRegexLibrary.sorted().first.enabled, isFalse);

      // 试一下
      await tester.tap(find.byIcon(Icons.science_outlined));
      await tester.pumpAndSettle();
      expect(find.text('试一下'), findsOneWidget);
      expect(find.textContaining('条正则按顺序处理'), findsOneWidget);
    });

    testWidgets('空库显示引导文案', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: DisplayRegexScreen()));
      await tester.pumpAndSettle();
      expect(find.text('还没有显示正则'), findsOneWidget);
      expect(find.text('导入正则 .json'), findsOneWidget);
    });
  });
}
