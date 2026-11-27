import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/screens/st_preset_screen.dart';
import 'package:litetavern/services/st_preset.dart';
import 'package:litetavern/services/storage.dart';

const _sample = '''
{
  "name": "Test Preset",
  "temperature": 1.25,
  "top_p": 0.9,
  "top_k": 40,
  "frequency_penalty": 0.2,
  "presence_penalty": 0.1,
  "repetition_penalty": 1.1,
  "min_p": 0.05,
  "max_tokens": 512,
  "seed": 42,
  "stop": ["###"],
  "continue_prefill": true,
  "prompts": [
    {"identifier": "main", "name": "Main Prompt", "role": "system",
     "content": "Write {{char}}'s next reply.", "system_prompt": true},
    {"identifier": "worldInfoBefore", "name": "World Info (before)", "marker": true},
    {"identifier": "chatHistory", "name": "Chat History", "marker": true},
    {"identifier": "jailbreak", "name": "Jailbreak", "role": "system",
     "content": "Stay in character.", "injection_position": 1, "injection_depth": 3},
    {"identifier": "nsfw", "name": "NSFW", "role": "assistant", "content": "nsfw prompt"}
  ],
  "prompt_order": [
    {"character_id": 100000, "order": [
      {"identifier": "main", "enabled": true},
      {"identifier": "worldInfoBefore", "enabled": true},
      {"identifier": "chatHistory", "enabled": true},
      {"identifier": "jailbreak", "enabled": false},
      {"identifier": "nsfw", "enabled": false}
    ]}
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: StPresetScreen()));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
  });

  group('ST 预设解析', () {
    test('采样参数与提示词按 prompt_order 排好', () {
      final s = StPresetParser.parse(_sample);
      expect(s.name, 'Test Preset');
      expect(s.temperature, 1.25);
      expect(s.topP, 0.9);
      expect(s.topK, 40);
      expect(s.frequencyPenalty, 0.2);
      expect(s.presencePenalty, 0.1);
      expect(s.repetitionPenalty, 1.1);
      expect(s.minP, 0.05);
      expect(s.maxTokens, 512);
      expect(s.seed, 42);
      expect(s.stop, ['###']);

      expect(
        s.prompts.map((p) => p.identifier).toList(),
        ['main', 'worldInfoBefore', 'chatHistory', 'jailbreak', 'nsfw'],
      );
      expect(s.prompts[0].enabled, isTrue);
      expect(s.prompts[1].isMarker, isTrue);
      expect(s.prompts[3].enabled, isFalse);
      expect(s.prompts[3].injectsInChat, isTrue);
      expect(s.prompts[3].orderNote, '注入 · 深度 3');
      expect(s.markerCount, 2);
      // 只有非占位、且启用的才算「启用提示词」
      expect(s.enabledCount, 1);
    });

    test('数值越界/未知 role/被忽略字段都写进 warnings 而不是抛错', () {
      final s = StPresetParser.parse('''
{
  "name": "W",
  "prompts": [
    {"identifier": "a", "name": "A", "role": "narrator", "content": "x"}
  ],
  "prompt_order": [{"order": [{"identifier": "a", "enabled": true},
                              {"identifier": "ghost", "enabled": true}]}],
  "squash_system_messages": true
}
''');
      expect(s.prompts.single.role, 'system');
      expect(s.warnings.any((w) => w.contains('narrator')), isTrue);
      expect(s.warnings.any((w) => w.contains('ghost')), isTrue);
      expect(s.warnings.any((w) => w.contains('本轮不参与')), isTrue);
      expect(s.hasSampling, isFalse);
    });

    test('没有 prompt_order：保持 prompts 原顺序并提示', () {
      final s = StPresetParser.parse('''
{"name": "NoOrder", "prompts": [
  {"identifier": "a", "name": "A", "role": "system", "content": "1"},
  {"identifier": "b", "name": "B", "role": "user", "content": "2"}
]}
''');
      expect(s.prompts.map((p) => p.identifier), ['a', 'b']);
      expect(s.warnings.any((w) => w.contains('没有 prompt_order')), isTrue);
      expect(s.hasSampling, isFalse);
    });

    test('支持 {preset:{...}} 包裹与 stopstrings', () {
      final s = StPresetParser.parse('''
{"name": "Wrapper", "preset": {
  "temperature": 0.5,
  "stopstrings": ["<END>", " "],
  "prompts": [{"identifier": "a", "name": "A", "role": "system", "content": "x"}]
}}
''');
      expect(s.temperature, 0.5);
      expect(s.stop, ['<END>']);
      expect(s.prompts.single.name, 'A');
    });

    test('坏 JSON / 没有 prompts 抛 FormatException', () {
      expect(() => StPresetParser.parse(''), throwsFormatException);
      expect(() => StPresetParser.parse('not json'), throwsFormatException);
      expect(() => StPresetParser.parse('{"name":"x"}'), throwsFormatException);
      expect(() => StPresetParser.parse('[]'), throwsFormatException);
      expect(() => StPresetParser.parse('{"prompts":[]}'), throwsFormatException);
    });

    test('快照 JSON 往返（供落盘恢复）', () {
      final s = StPresetParser.parse(_sample);
      final restored = StPresetSnapshot.fromJson(
        jsonDecode(s.toJsonString()) as Map<String, dynamic>,
      );
      expect(restored.name, s.name);
      expect(restored.temperature, s.temperature);
      expect(restored.prompts.map((p) => p.identifier),
          s.prompts.map((p) => p.identifier));
      expect(restored.prompts[3].enabled, isFalse);
      expect(restored.prompts[3].injectionDepth, 3);
    });

    test('存储里读回：坏数据返回 null', () {
      expect(StPresetSnapshot.tryParseStored(null), isNull);
      expect(StPresetSnapshot.tryParseStored('  '), isNull);
      expect(StPresetSnapshot.tryParseStored('{oops'), isNull);
      expect(StPresetSnapshot.tryParseStored('[]'), isNull);
      final s = StPresetParser.parse(_sample);
      expect(StPresetSnapshot.tryParseStored(s.toJsonString())?.name,
          'Test Preset');
    });
  });

  group('采样参数套用', () {
    testWidgets('点「套用到当前生成预设」后写进 AppSettings', (tester) async {
      final s = StPresetParser.parse(_sample);
      await AppSettings.setStPresetJson(s.toJsonString());

      await pumpScreen(tester);

      expect(find.text('Test Preset'), findsOneWidget);
      expect(find.text('采样参数'), findsOneWidget);

      await tester.tap(find.text('套用到当前生成预设'));
      await tester.pumpAndSettle();
      expect(find.text('把这些采样参数套到当前生成预设？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '套用'));
      await tester.pumpAndSettle();

      expect(AppSettings.temperature, 1.25);
      expect(AppSettings.topP, 0.9);
      expect(AppSettings.topK, 40);
      expect(AppSettings.frequencyPenalty, 0.2);
      expect(AppSettings.presencePenalty, 0.1);
      expect(AppSettings.repetitionPenalty, 1.1);
      expect(AppSettings.minP, 0.05);
      expect(AppSettings.maxTokens, 512);
      expect(AppSettings.seed, 42);
      expect(AppSettings.stop, ['###']);
      expect(find.text('采样参数已套到当前生成预设'), findsOneWidget);
    });

    testWidgets('越界值会被收敛到本 App 的范围', (tester) async {
      final s = StPresetParser.parse('''
{"name": "OutOfRange",
 "temperature": 5, "top_p": 3, "top_k": 999, "repetition_penalty": 3,
 "min_p": 0.9, "frequency_penalty": -2,
 "prompts": [{"identifier": "a", "name": "A", "role": "system", "content": "x"}]}
''');
      await AppSettings.setStPresetJson(s.toJsonString());
      await pumpScreen(tester);
      await tester.tap(find.text('套用到当前生成预设'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '套用'));
      await tester.pumpAndSettle();

      expect(AppSettings.temperature, 2.0);
      expect(AppSettings.topP, 1.0);
      expect(AppSettings.topK, 200);
      expect(AppSettings.repetitionPenalty, 2.0);
      expect(AppSettings.minP, 0.5);
      expect(AppSettings.frequencyPenalty, 0.0);
    });
  });

  group('提示词顺序编辑', () {
    testWidgets('开关与上移会写回存储', (tester) async {
      final s = StPresetParser.parse(_sample);
      await AppSettings.setStPresetJson(s.toJsonString());
      await pumpScreen(tester);

      // 第 1 条 Main Prompt 默认启用；关掉它
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      final afterToggle =
          StPresetSnapshot.tryParseStored(AppSettings.stPresetJson)!;
      expect(afterToggle.prompts.first.enabled, isFalse);

      // 把第 2 条上移到第 1
      await tester.tap(find.byIcon(Icons.keyboard_arrow_up).at(1));
      await tester.pumpAndSettle();
      final afterMove =
          StPresetSnapshot.tryParseStored(AppSettings.stPresetJson)!;
      expect(afterMove.prompts.first.identifier, 'worldInfoBefore');
      expect(afterMove.prompts[1].identifier, 'main');
    });

    testWidgets('清除会删掉存储里的预设', (tester) async {
      final s = StPresetParser.parse(_sample);
      await AppSettings.setStPresetJson(s.toJsonString());
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '清除'));
      await tester.pumpAndSettle();

      expect(AppSettings.stPresetJson, isNull);
      expect(find.text('还没有导入 SillyTavern 预设'), findsOneWidget);
    });
  });
}
