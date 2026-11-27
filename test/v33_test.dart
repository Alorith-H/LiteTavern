import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/screens/card_state_screen.dart';
import 'package:litetavern/services/card_scripts.dart';
import 'package:litetavern/services/mvu_state.dart';

CharacterCard _card({
  String name = '测试角色',
  String description = '描述',
  String firstMes = '你好',
  String systemPrompt = '',
  Map<String, dynamic> extensions = const {},
}) {
  return CharacterCard(
    name: name,
    description: description,
    personality: '',
    scenario: '',
    firstMes: firstMes,
    mesExample: '',
    systemPrompt: systemPrompt,
    alternateGreetings: const [],
    tags: const [],
    creator: '',
    extensions: extensions,
  );
}

ChatMessage _msg(String content, {int ts = 1, String role = 'assistant'}) =>
    ChatMessage(role: role, content: content, timestamp: ts);

void main() {
  group('CharacterCard 保留扩展字段', () {
    test('V2 卡里的 extensions 能读出来并写回去', () {
      final card = CharacterCard.fromJson({
        'spec': 'chara_card V3',
        'data': {
          'name': '小明',
          'description': 'd',
          'first_mes': 'hi',
          'extensions': {
            'mvu': {
              'initialVariables': {'好感度': 0},
            },
            'regex_scripts': [
              {'scriptName': 'x'},
            ],
          },
        },
      });
      expect(card.extensions['mvu'], isA<Map>());
      expect((card.extensions['regex_scripts'] as List), hasLength(1));
      final json = card.toJson();
      final data = json['data'] as Map<String, dynamic>;
      expect(data['extensions'], isNotNull);
      expect((data['extensions'] as Map)['mvu'], isNotNull);
    });

    test('没有 extensions 时为空且不写进 JSON', () {
      final card = CharacterCard.fromJson({
        'name': '小明',
        'description': 'd',
        'first_mes': 'hi',
      });
      expect(card.extensions, isEmpty);
      final data = card.toJson()['data'] as Map<String, dynamic>;
      expect(data.containsKey('extensions'), isFalse);
    });

    test('copyWith 与 withId 都保留 extensions', () {
      final card = _card(extensions: {'mvu': {'a': 1}});
      expect(card.copyWith(name: '改').extensions['mvu'], isNotNull);
      expect(card.withId('9').extensions['mvu'], isNotNull);
    });
  });

  group('MvuStateReader.fromCard', () {
    test('读 extensions.mvu.initialVariables，嵌套拍平成点号', () {
      final snap = MvuStateReader.fromCard(_card(extensions: {
        'mvu': {
          'initialVariables': {
            'stats': {'好感度': 5, '体力': 100},
            '章节': '序章',
          },
        },
      }));
      expect(snap.values['stats.好感度'], '5');
      expect(snap.values['stats.体力'], '100');
      expect(snap.values['章节'], '序章');
      expect(snap.initCount, greaterThanOrEqualTo(1));
    });

    test('读 extensions.variables 与开场白里的 [InitVar]', () {
      final snap = MvuStateReader.fromCard(_card(
        extensions: {
          'variables': {'金币': 10},
        },
        firstMes: '开场。[InitVar]{"天气":"晴","金币":20} 然后继续说。',
      ));
      expect(snap.values['金币'], '20'); // 文本里的覆盖扩展
      expect(snap.values['天气'], '晴');
    });

    test('没有变量时为空', () {
      expect(MvuStateReader.fromCard(_card()).isEmpty, isTrue);
    });
  });

  group('MvuStateReader.fromMessages', () {
    test('UpdateVariable 里是 Map：直接合并', () {
      final snap = MvuStateReader.fromMessages([
        _msg('<UpdateVariable>{"stats":{"好感度":10}}</UpdateVariable>'),
      ]);
      expect(snap.updateCount, 1);
      expect(snap.values['stats.好感度'], '10');
    });

    test('JSONPatch 里是操作列表：replace / add / remove 都能用', () {
      final snap = MvuStateReader.fromMessages([
        _msg('<JSONPatch>'
            '[{"op":"add","path":"/stats/好感度","value":3},'
            '{"op":"replace","path":"/章节","value":"第二章"},'
            '{"op":"remove","path":"/临时"}]'
            '</JSONPatch>'),
      ], base: const MvuSnapshot(values: {'临时': 'x', '章节': '第一章'}));
      expect(snap.values['stats.好感度'], '3');
      expect(snap.values['章节'], '第二章');
      expect(snap.values.containsKey('临时'), isFalse);
    });

    test('坏 JSON 不影响其它消息，也不抛异常', () {
      final snap = MvuStateReader.fromMessages([
        _msg('<UpdateVariable>这不是 JSON</UpdateVariable>'),
        _msg('<UpdateVariable>{"体力":50}</UpdateVariable>'),
      ]);
      expect(snap.updateCount, 1); // 只统计解析成功的块
      expect(snap.values['体力'], '50');
    });

    test('多条消息按顺序累积', () {
      final snap = MvuStateReader.fromMessages([
        _msg('<UpdateVariable>{"好感度":1}</UpdateVariable>', ts: 1),
        _msg('<UpdateVariable>{"好感度":9}</UpdateVariable>', ts: 2),
      ]);
      expect(snap.values['好感度'], '9');
    });
  });

  group('CardScriptScanner', () {
    test('识别脚本扩展键', () {
      final scan = CardScriptScanner.scan(_card(extensions: {
        'regex_scripts': [
          {'scriptName': 'a'},
        ],
        'mvu': {'a': 1},
      }));
      expect(scan.hasScript, isTrue);
      expect(scan.extensionKeys, containsAll(['regex_scripts', 'mvu']));
      expect(scan.summary, contains('不会执行'));
    });

    test('识别正文里的 script / iframe 标记', () {
      final scan = CardScriptScanner.scan(_card(
        description: '正常描述 <script>alert(1)</script>',
        firstMes: '开场 <iframe src="x"></iframe>',
      ));
      expect(scan.htmlWarnings, isNotEmpty);
      expect(scan.findings, isNotEmpty);
    });

    test('干净卡片没有任何提示', () {
      final scan = CardScriptScanner.scan(_card(description: '一个普通角色。'));
      expect(scan.hasScript, isFalse);
      expect(scan.findings, isEmpty);
      expect(scan.summary, contains('没有发现'));
    });

    test('群聊合并多张卡', () {
      final scan = CardScriptScanner.scanAll([
        _card(name: 'A', extensions: {'mvu': {'x': 1}}),
        _card(name: 'B', description: '<script>x</script>'),
      ]);
      expect(scan.extensionKeys, contains('mvu'));
      expect(scan.htmlWarnings.first, startsWith('B · '));
    });
  });

  group('CardStateScreen', () {
    testWidgets('展示卡内变量、状态更新与脚本提示', (tester) async {
      final card = _card(
        extensions: {
          'mvu': {
            'initialVariables': {'好感度': 0},
          },
          'regex_scripts': [
            {'scriptName': 'a'},
          ],
        },
      );
      await tester.pumpWidget(MaterialApp(
        home: CardStateScreen(
          cards: [card],
          messages: [
            _msg('<UpdateVariable>{"好感度":12}</UpdateVariable>'),
          ],
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('变量与状态'), findsOneWidget);
      expect(find.textContaining('只读查看'), findsOneWidget);
      expect(find.text('好感度'), findsNWidgets(2)); // 初始表 + 会话合并表各一行
      expect(find.textContaining('找到 1 个状态更新块'), findsOneWidget);
      expect(find.textContaining('卡内脚本扩展'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('没有变量也没有脚本时给出空态', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: CardStateScreen(cards: [], messages: []),
      ));
      await tester.pumpAndSettle();
      expect(find.text('没有角色卡可以读取。'), findsOneWidget);
      expect(find.textContaining('没有发现卡内脚本'), findsOneWidget);
    });
  });
}
