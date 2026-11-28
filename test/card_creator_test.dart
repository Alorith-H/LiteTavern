import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/screens/card_creator_screen.dart';
import 'package:litetavern/services/card_creator_flow.dart';
import 'package:litetavern/services/generated_card.dart';
import 'package:litetavern/services/mvu_state.dart';
import 'package:litetavern/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('CardCreatorFlow', () {
    test('从第 1 步开始，进度与标题正确', () {
      final flow = CardCreatorFlow();
      expect(flow.step, CreatorStep.basics);
      expect(flow.stepNumber, 1);
      expect(flow.progressLabel, '第 1/6 步 · 名字与题材');
      expect(flow.progress, 0);
      expect(flow.isEmpty, isTrue);
      expect(flow.isComplete, isFalse);
    });

    test('记录答案后推进，进度与摘要跟着变', () {
      final flow = CardCreatorFlow();
      expect(flow.record('叫林雾，都市奇幻'), isTrue);
      expect(flow.answerFor(CreatorStep.basics), '叫林雾，都市奇幻');
      expect(flow.advance(), isTrue);
      expect(flow.step, CreatorStep.personality);
      expect(flow.progress, closeTo(1 / 6, 1e-9));
      expect(flow.summaryForPrompt(), contains('名字与题材：叫林雾，都市奇幻'));
    });

    test('空白内容不记录也不推进', () {
      final flow = CardCreatorFlow();
      expect(flow.record('   '), isFalse);
      expect(flow.advance(), isTrue);
      expect(flow.answerFor(CreatorStep.basics), isEmpty);
      expect(flow.summaryForPrompt(), isNot(contains('名字与题材')));
    });

    test('跳过某步只前进，不写答案', () {
      final flow = CardCreatorFlow();
      flow.skip();
      expect(flow.step, CreatorStep.personality);
      expect(flow.isEmpty, isTrue);
    });

    test('上一步可回退，最后一步不能再前进', () {
      final flow = CardCreatorFlow();
      expect(flow.back(), isFalse);
      flow.skip();
      expect(flow.back(), isTrue);
      expect(flow.step, CreatorStep.basics);
      for (var i = 0; i < 10; i++) {
        flow.advance();
      }
      expect(flow.step, CreatorStep.worldbook);
      expect(flow.isLast, isTrue);
      expect(flow.advance(), isFalse);
    });

    test('走完最后一步并作答后 isComplete 为 true', () {
      final flow = CardCreatorFlow();
      for (final step in CreatorStep.values) {
        expect(flow.step, step);
        flow.record('答案 ${step.number}');
        flow.advance();
      }
      expect(flow.isComplete, isTrue);
      expect(flow.progress, 1);
      expect(flow.summaryForPrompt(), contains('世界书要点：答案 6'));
    });

    test('reset 回到第一步并清空答案', () {
      final flow = CardCreatorFlow();
      flow.record('x');
      flow.advance();
      flow.reset();
      expect(flow.step, CreatorStep.basics);
      expect(flow.isEmpty, isTrue);
    });

    test('每个步骤都有标题、问题、提示与快速选项', () {
      for (final step in CreatorStep.values) {
        expect(step.label, isNotEmpty);
        expect(step.question, isNotEmpty);
        expect(step.hint, isNotEmpty);
        expect(step.quickOptions, isNotEmpty);
        expect(step.number, step.index + 1);
      }
      expect(kCreatorStepCount, CreatorStep.values.length);
    });
  });

  group('引导提示词', () {
    test('系统提示带当前步号、标题与问题', () {
      final flow = CardCreatorFlow();
      flow.record('林雾');
      flow.advance();
      final prompt = creatorInterviewSystem(flow);
      expect(prompt, contains('第 2/6 步「性格与说话方式」'));
      expect(prompt, contains(CreatorStep.personality.question));
      expect(prompt, contains('已确认'));
      expect(prompt, contains('名字与题材：林雾'));
    });

    test('没有答案时提示「暂无」', () {
      expect(creatorInterviewSystem(CardCreatorFlow()), contains('已确认：暂无'));
    });

    test('步骤切换提示包含新一步的问题', () {
      final flow = CardCreatorFlow();
      flow.advance();
      final hint = creatorStepTransitionHint(flow);
      expect(hint, contains('第 2/6 步「性格与说话方式」'));
      expect(hint, contains(CreatorStep.personality.question));
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
  });

  group('CardCreatorScreen 步骤条', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      Storage.initForTest(
        Directory.systemTemp.createTempSync('lt_creator_flow_'),
      );
      await AppSettings.init();
    });

    testWidgets('首屏显示第 1 步、进度条与快速选项', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: CardCreatorScreen()));
      await tester.pump();
      expect(find.text('第 1/6 步 · 名字与题材'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('跳过这步'), findsOneWidget);
      expect(find.text('都市奇幻'), findsOneWidget);
      expect(find.textContaining('一步一步来'), findsOneWidget);
    });

    testWidgets('点「跳过这步」进入第 2 步并换一组快速选项', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: CardCreatorScreen()));
      await tester.pump();
      await tester.tap(find.text('跳过这步'));
      await tester.pump();
      expect(find.text('第 2/6 步 · 性格与说话方式'), findsOneWidget);
      expect(find.text('简短冷淡'), findsOneWidget);
    });
  });
}
