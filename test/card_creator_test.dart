import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/screens/card_creator_screen.dart';
import 'package:litetavern/services/card_creator_prompts.dart';
import 'package:litetavern/services/generated_card.dart';
import 'package:litetavern/services/mvu_state.dart';
import 'package:litetavern/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('采访提示词（v0.46.0：不再有步骤限制）', () {
    test('不出现步骤编号或「第 N 步」字样', () {
      expect(creatorInterviewSystem, isNot(contains('/6')));
      expect(creatorInterviewSystem, isNot(contains('第 1')));
      expect(creatorInterviewSystem, isNot(contains('步骤：')));
      expect(creatorInterviewSystem, isNot(matches(RegExp(r'第 \d'))));
    });

    test('要求一次只问一个问题，且不重复问已说过的内容', () {
      expect(creatorInterviewSystem, contains('每次只问一个问题'));
      expect(creatorInterviewSystem, contains('不要重复问'));
    });

    test('不追问变量与世界书（留给生成前单独确认）', () {
      expect(creatorInterviewSystem, contains('不要问数值、变量、世界书'));
    });

    test('用户说够了就停止追问并指向生成按钮', () {
      expect(creatorInterviewSystem, contains('直接生成'));
      expect(creatorInterviewSystem, contains('生成角色卡'));
      expect(creatorInterviewSystem, contains('不要输出 JSON'));
    });
  });

  group('生成提示词与变量开关', () {
    test('需要变量时给出 mvu.initialVariables 示例', () {
      final prompt = buildCardJsonSystem(withVariables: true);
      expect(prompt, contains('"extensions"'));
      expect(prompt, contains('initialVariables'));
      expect(prompt, contains('好感度'));
      expect(prompt, isNot(contains('不要输出 "extensions"')));
    });

    test('不需要变量时明确禁止 extensions', () {
      final prompt = buildCardJsonSystem(withVariables: false);
      expect(prompt, contains('不要输出 "extensions"'));
      expect(prompt, isNot(contains('initialVariables')));
      expect(prompt, isNot(contains('"extensions"：')));
    });

    test('两种模式都保留 character_book 规范', () {
      for (final withVars in [true, false]) {
        final prompt = buildCardJsonSystem(withVariables: withVars);
        expect(prompt, contains('character_book'));
        expect(prompt, contains('insertion_order'));
      }
    });

    test('生成时追加的变量说明跟随开关', () {
      expect(
        cardVariablesInstruction(withVariables: true),
        contains('用户同意加入初始变量'),
      );
      expect(
        cardVariablesInstruction(withVariables: false),
        contains('不要输出 extensions'),
      );
    });

    test('不需要变量时清空 extensions', () {
      final card = parseGeneratedCard(
        '{"name":"A","extensions":{"mvu":{"initialVariables":{"hp":1}}}}',
      );
      expect(card!.extensions, isNotEmpty);
      final cleaned = card.copyWith(extensions: const <String, dynamic>{});
      expect(cleaned.extensions, isEmpty);
      // 其它字段不受影响
      expect(cleaned.name, 'A');
    });
  });

  group('generated_card 解析 extensions', () {
    test('保留 mvu.initialVariables 的数字与字符串', () {
      final card = parseGeneratedCard(
        '{"name":"林雾","description":"店主",'
        '"extensions":{"mvu":{"initialVariables":{"好感度":0,"体力":100,"称呼":"店长"}}}}',
      );
      expect(card, isNotNull);
      final mvu = card!.extensions['mvu'] as Map;
      expect(mvu['initialVariables'], {'好感度': 0, '体力': 100, '称呼': '店长'});
      // 变量与状态页能读到
      final snap = MvuStateReader.fromCard(card);
      expect(snap.values['好感度'], '0');
    });

    test('兼容 initial_variables 与嵌套包裹 data', () {
      final card = parseGeneratedCard(
        '{"data":{"name":"A","extensions":{"mvu":{"initial_variables":{"金币":12}}}}}',
      );
      final mvu = card!.extensions['mvu'] as Map;
      expect(mvu['initialVariables'], {'金币': 12});
    });

    test('丢弃嵌套对象、列表与超长键', () {
      final card = parseGeneratedCard(
        '{"name":"A","extensions":{"mvu":{"initialVariables":'
        '{"ok":1,"nested":{"a":1},"list":[1],"${'超' * 45}":2,"":3}}}}',
      );
      final vars = (card!.extensions['mvu'] as Map)['initialVariables'] as Map;
      expect(vars, {'ok': 1});
    });

    test('没有 extensions 或形状不对时为空 Map', () {
      expect(parseGeneratedCard('{"name":"A"}')!.extensions, isEmpty);
      expect(
        parseGeneratedCard('{"name":"A","extensions":"x"}')!.extensions,
        isEmpty,
      );
      expect(
        parseGeneratedCard(
          '{"name":"A","extensions":{"mvu":{"initialVariables":{}}}}',
        )!.extensions,
        isEmpty,
      );
    });

    test('extensions 里的非 mvu 扩展被忽略', () {
      final card = parseGeneratedCard(
        '{"name":"A","extensions":{"regex_scripts":[1],"mvu":{"initialVariables":{"hp":1}}}}',
      );
      expect(card!.extensions.keys, ['mvu']);
    });

    test('CharacterCard.extensions 可与其他字段一起构造', () {
      const card = CharacterCard(
        name: 'A',
        description: 'd',
        personality: '',
        scenario: '',
        firstMes: '',
        mesExample: '',
        systemPrompt: '',
        alternateGreetings: [],
        tags: [],
        creator: '',
        extensions: {'mvu': {'initialVariables': {'hp': 1}}},
      );
      expect(MvuStateReader.fromCard(card).values['hp'], '1');
    });
  });

  group('CardCreatorScreen 空态（v0.46.0）', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      Storage.initForTest(
        Directory.systemTemp.createTempSync('lt_creator_free_'),
      );
      await AppSettings.init();
    });

    testWidgets('没有步骤条与进度条，只有节奏说明和题材快捷入口', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: CardCreatorScreen()));
      await tester.pump();

      expect(find.textContaining('想到什么就说什么'), findsOneWidget);
      expect(find.text('都市奇幻'), findsOneWidget);
      expect(find.text('生成角色卡'), findsOneWidget);
      // 旧的步骤条彻底消失
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('跳过这步'), findsNothing);
      expect(find.text('上一步'), findsNothing);
      expect(find.textContaining('第 1/6 步'), findsNothing);
    });
  });
}
