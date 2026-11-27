import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/screens/st_preset_screen.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/st_injection.dart';
import 'package:litetavern/services/st_preset.dart';
import 'package:litetavern/services/storage.dart';

const _preset = '''
{
  "name": "Compat 测试",
  "prompts": [
    {"identifier": "a", "name": "主提示", "role": "system", "content": "你是酒馆的叙述者。"},
    {"identifier": "b", "name": "占位", "marker": true},
    {"identifier": "c", "name": "冷的开场", "role": "assistant", "content": "外面下着雪。"},
    {"identifier": "d", "name": "深度提醒", "role": "system",
     "content": "记住：不要跳时间。", "injection_position": 1, "injection_depth": 2},
    {"identifier": "e", "name": "关掉的", "role": "system", "content": "不该出现。"},
    {"identifier": "f", "name": "空的", "role": "system", "content": "   "}
  ],
  "prompt_order": [
    {"character_id": 1, "order": [
      {"identifier": "a", "enabled": true},
      {"identifier": "b", "enabled": true},
      {"identifier": "c", "enabled": true},
      {"identifier": "d", "enabled": true},
      {"identifier": "e", "enabled": false},
      {"identifier": "f", "enabled": true}
    ]}
  ]
}
''';

StPresetSnapshot _snapshot() => StPresetParser.parse(_preset, fallbackName: 'x');

CharacterCard _card() => const CharacterCard(
      name: '阿青',
      description: '酒馆老板',
      personality: '安静',
      scenario: '雪夜',
      firstMes: '',
      mesExample: '',
      systemPrompt: '',
      alternateGreetings: [],
      tags: [],
      creator: 'test',
    );

ChatMessage _msg(String role, String content) => ChatMessage(
      role: role,
      content: content,
      timestamp: role == 'user' ? 1000 : 2000,
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
  });

  group('StInjectionPlan.fromSnapshot', () {
    test('没有预设时为空计划', () {
      expect(StInjectionPlan.fromSnapshot(null).isEmpty, isTrue);
      expect(StInjectionPlan.fromSnapshot(null).summaryLine, contains('没有'));
    });

    test('跳过占位 / 关闭 / 空内容，把 system 拼到开头', () {
      final plan = StInjectionPlan.fromSnapshot(_snapshot());
      expect(plan.systemPrefix, '你是酒馆的叙述者。');
      expect(plan.systemPrefix, isNot(contains('不该出现')));
      expect(plan.injectedCount, 3); // a + c + d
    });

    test('user / assistant 的顺序条目进 preHistory，保持原角色', () {
      final plan = StInjectionPlan.fromSnapshot(_snapshot());
      expect(plan.preHistory.length, 1);
      expect(plan.preHistory.single.role, 'assistant');
      expect(plan.preHistory.single.content, '外面下着雪。');
    });

    test('聊天内注入按深度收进 depthInjections', () {
      final plan = StInjectionPlan.fromSnapshot(_snapshot());
      expect(plan.depthInjections.length, 1);
      expect(plan.depthInjections.single.depth, 2);
      expect(plan.depthInjections.single.message.role, 'system');
      expect(plan.depthInjections.single.message.content, contains('不要跳时间'));
    });

    test('summaryLine 同时点出三种注入方式', () {
      final line = StInjectionPlan.fromSnapshot(_snapshot()).summaryLine;
      expect(line, contains('system 开头'));
      expect(line, contains('历史前'));
      expect(line, contains('按深度注入'));
    });
  });

  group('PromptBuilder 注入（兼容模式）', () {
    test('system 开头是 ST 前缀，角色设定仍在', () {
      final built = PromptBuilder.build(
        card: _card(),
        history: [_msg('user', '你好'), _msg('assistant', '欢迎')],
        worldBooks: const [],
        userName: '我',
        historyLimit: 20,
        stSystemPrefix: 'ST 主提示：你是叙述者。',
      );
      expect(built.messages.first.role, 'system');
      expect(built.systemText, startsWith('ST 主提示：你是叙述者。'));
      expect(built.systemText, contains('阿青'));
    });

    test('preHistory 插在历史前，深度注入按 0/n 语义落位', () {
      final built = PromptBuilder.build(
        card: _card(),
        history: [_msg('user', '你好'), _msg('assistant', '欢迎')],
        worldBooks: const [],
        userName: '我',
        historyLimit: 20,
        stPreHistory: const [
          PromptMessage(role: 'assistant', content: '先来一句开场。'),
        ],
        stDepthInjections: const [
          DepthInjection(
            message: PromptMessage(role: 'system', content: '深度 0'),
            depth: 0,
          ),
          DepthInjection(
            message: PromptMessage(role: 'system', content: '深度 1'),
            depth: 1,
          ),
        ],
      );
      final contents = built.messages.map((m) => m.content).toList();
      expect(contents[1], '先来一句开场。');
      // depth 0 在最后一条之后；depth 1 在倒数第二条之前
      expect(contents.last, '深度 0');
      expect(contents[contents.length - 3], '深度 1');
    });

    test('宏在注入内容里也会被替换', () {
      final built = PromptBuilder.build(
        card: _card(),
        history: const [],
        worldBooks: const [],
        userName: '小林',
        historyLimit: 20,
        stSystemPrefix: '{{user}} 是主角，{{char}} 是老板。',
      );
      expect(built.systemText, contains('小林 是主角'));
      expect(built.systemText, contains('阿青 是老板'));
    });
  });

  group('设置：ST 兼容模式开关', () {
    test('默认关闭且可持久化', () async {
      expect(AppSettings.stCompatEnabled, isFalse);
      AppSettings.stCompatEnabled = true;
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('st_compat_enabled'), isTrue);
      await AppSettings.init();
      expect(AppSettings.stCompatEnabled, isTrue);
    });
  });

  group('StPresetScreen 兼容开关', () {
    Future<void> pumpScreen(WidgetTester tester, {Size? size}) async {
      if (size != null) {
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
      }
      await tester.pumpWidget(const MaterialApp(home: StPresetScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('点上开关就落盘', (tester) async {
      await AppSettings.setStPresetJson(
        jsonEncode(jsonDecode(_preset) as Map<String, dynamic>),
      );
      await pumpScreen(tester, size: const Size(1200, 3000));
      final finder = find.text('兼容模式（真实注入）');
      expect(finder, findsOneWidget);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(AppSettings.stCompatEnabled, isTrue);
      expect(find.textContaining('已开启'), findsOneWidget);
    });
  });
}
