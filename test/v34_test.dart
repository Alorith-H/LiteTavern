import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/screens/chat_preset_screen.dart';
import 'package:litetavern/services/chat_gen_settings.dart';
import 'package:litetavern/services/sampling_params.dart';
import 'package:litetavern/services/storage.dart';

Future<void> _pumpScreen(WidgetTester tester, {String convId = 'conv_a'}) async {
  tester.view.physicalSize = const Size(1200, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: ChatPresetScreen(convId: convId)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
  });

  group('ChatPresetOverride 值对象', () {
    test('默认空；empty/isEmpty/count/summary', () {
      const ov = ChatPresetOverride.empty;
      expect(ov.isEmpty, isTrue);
      expect(ov.isNotEmpty, isFalse);
      expect(ov.count, 0);
      expect(ov.summary, '跟随全局预设');
    });

    test('toJson 用 ST 命名，只写非空字段', () {
      const ov = ChatPresetOverride(
        temperature: 1.1,
        topK: 40,
        presencePenalty: 0.5,
      );
      final json = ov.toJson();
      expect(json['temperature'], 1.1);
      expect(json['top_k'], 40);
      expect(json['presence_penalty'], 0.5);
      expect(json.containsKey('top_p'), isFalse);
      expect(json.containsKey('max_tokens'), isFalse);
      expect(ov.count, 3);
    });

    test('fromJson 往返', () {
      const ov = ChatPresetOverride(
        temperature: 0.7,
        topP: 0.9,
        topK: 20,
        maxTokens: 512,
        frequencyPenalty: 0.3,
        presencePenalty: 0.4,
      );
      final back = ChatPresetOverride.fromJson(ov.toJson());
      expect(back.temperature, 0.7);
      expect(back.topP, 0.9);
      expect(back.topK, 20);
      expect(back.maxTokens, 512);
      expect(back.frequencyPenalty, 0.3);
      expect(back.presencePenalty, 0.4);
    });

    test('fromJson 越界值 clamp；字符串数字也能读', () {
      final back = ChatPresetOverride.fromJson(<String, dynamic>{
        'temperature': 9.0,
        'top_p': -3,
        'top_k': 999,
        'max_tokens': '-5',
        'frequency_penalty': '0.25',
        'presence_penalty': 5,
      });
      expect(back.temperature, 2.0);
      expect(back.topP, 0.0);
      expect(back.topK, 200);
      expect(back.maxTokens, 0);
      expect(back.frequencyPenalty, 0.25);
      expect(back.presencePenalty, 2.0);
    });

    test('copyWith：省略保持、传 null 清空、传值覆盖', () {
      const base = ChatPresetOverride(temperature: 1.0, topK: 10);
      final changed = base.copyWith(topK: 30);
      expect(changed.temperature, 1.0);
      expect(changed.topK, 30);
      final cleared = changed.copyWith(temperature: null);
      expect(cleared.temperature, isNull);
      expect(cleared.topK, 30);
    });

    test('summary 列出覆盖项', () {
      const ov = ChatPresetOverride(
        temperature: 1.2,
        topP: 0.8,
        maxTokens: 256,
      );
      expect(ov.summary, contains('覆盖'));
      expect(ov.summary, contains('t1.2'));
      expect(ov.summary, contains('p0.8'));
      expect(ov.summary, contains('上限 256'));
    });
  });

  group('ChatPresetOverrideStore', () {
    test('按 convId 隔离保存与读取', () async {
      await ChatPresetOverrideStore.save(
        'conv_a',
        const ChatPresetOverride(temperature: 1.3),
      );
      await ChatPresetOverrideStore.save(
        'conv_b',
        const ChatPresetOverride(topK: 5),
      );
      expect(ChatPresetOverrideStore.load('conv_a').temperature, 1.3);
      expect(ChatPresetOverrideStore.load('conv_a').topK, isNull);
      expect(ChatPresetOverrideStore.load('conv_b').topK, 5);
      expect(ChatPresetOverrideStore.load('conv_b').temperature, isNull);
      expect(ChatPresetOverrideStore.load('conv_missing').isEmpty, isTrue);
    });

    test('保存空覆盖会删掉这条记录', () async {
      await ChatPresetOverrideStore.save(
        'conv_a',
        const ChatPresetOverride(temperature: 1.3),
      );
      expect(AppSettings.chatPresetOverridesJson, isNotNull);
      await ChatPresetOverrideStore.save('conv_a', ChatPresetOverride.empty);
      expect(ChatPresetOverrideStore.load('conv_a').isEmpty, isTrue);
      expect(AppSettings.chatPresetOverridesJson, isNull);
    });

    test('clear 等于保存空覆盖', () async {
      await ChatPresetOverrideStore.save(
        'conv_a',
        const ChatPresetOverride(topP: 0.5),
      );
      await ChatPresetOverrideStore.clear('conv_a');
      expect(ChatPresetOverrideStore.load('conv_a').isEmpty, isTrue);
    });

    test('坏 JSON 不崩，回退空覆盖', () async {
      await AppSettings.setChatPresetOverridesJson('{不是 json');
      expect(ChatPresetOverrideStore.load('conv_a').isEmpty, isTrue);
    });
  });

  group('ChatGenSettings.resolve', () {
    test('无覆盖 = 跟随全局预设', () {
      AppSettings.temperature = 0.75;
      AppSettings.topP = 0.95;
      AppSettings.maxTokens = 400;
      final gen = ChatGenSettings.resolve('conv_none');
      expect(gen.hasOverride, isFalse);
      expect(gen.temperature, 0.75);
      expect(gen.topP, 0.95);
      expect(gen.maxTokens, 400);
      expect(gen.sampling.isDefault, isTrue);
    });

    test('部分覆盖只替换填了的键，其余跟全局', () async {
      AppSettings.temperature = 0.75;
      AppSettings.topP = 0.95;
      AppSettings.maxTokens = 400;
      await ChatPresetOverrideStore.save(
        'conv_part',
        const ChatPresetOverride(temperature: 1.4, maxTokens: 128),
      );
      final gen = ChatGenSettings.resolve('conv_part');
      expect(gen.hasOverride, isTrue);
      expect(gen.temperature, 1.4);
      expect(gen.topP, 0.95);
      expect(gen.maxTokens, 128);
    });

    test('全量覆盖会重建 sampling，并保留重复惩罚/min_p/seed/stop', () async {
      final base = AppSettings.activePreset.sampling;
      await ChatPresetOverrideStore.save(
        'conv_full',
        const ChatPresetOverride(
          topK: 40,
          frequencyPenalty: 0.6,
          presencePenalty: 0.4,
        ),
      );
      final gen = ChatGenSettings.resolve('conv_full');
      expect(gen.sampling.topK, 40);
      expect(gen.sampling.frequencyPenalty, 0.6);
      expect(gen.sampling.presencePenalty, 0.4);
      expect(gen.sampling.repetitionPenalty, base.repetitionPenalty);
      expect(gen.sampling.minP, base.minP);
      expect(gen.sampling.seed, base.seed);
      expect(gen.sampling.stop, base.stop);
    });

    test('另一段聊天的覆盖不会串到这一段', () async {
      await ChatPresetOverrideStore.save(
        'conv_other',
        const ChatPresetOverride(temperature: 1.9),
      );
      final gen = ChatGenSettings.resolve('conv_mine');
      expect(gen.hasOverride, isFalse);
      expect(gen.temperature, AppSettings.temperature);
    });

    test('summary 用实际生效的值拼', () {
      final gen = ChatGenSettings(
        temperature: 1.2,
        topP: 0.8,
        maxTokens: 0,
        sampling: const SamplingParams(),
      );
      expect(gen.summary, 't1.2 · p0.8 · 上限 不限');
    });
  });

  group('ChatPresetScreen', () {
    testWidgets('渲染六个参数与全局提示', (tester) async {
      AppSettings.temperature = 0.7;
      AppSettings.topP = 0.9;
      await _pumpScreen(tester);
      expect(find.text('这段聊天的生成参数'), findsOneWidget);
      expect(find.text('temperature｜随机度'), findsOneWidget);
      expect(find.text('top_p｜核采样'), findsOneWidget);
      expect(find.text('top_k'), findsOneWidget);
      expect(find.text('max_tokens｜单次上限'), findsOneWidget);
      expect(find.text('frequency_penalty'), findsOneWidget);
      expect(find.text('presence_penalty'), findsOneWidget);
      expect(find.textContaining('全局预设现在是'), findsOneWidget);
      // 没有覆盖时没有「全部恢复」
      expect(find.widgetWithText(TextButton, '全部恢复'), findsNothing);
    });

    testWidgets('填 temperature 会写入覆盖；再全部恢复会清掉', (tester) async {
      await _pumpScreen(tester, convId: 'conv_ui');
      await tester.enterText(find.byType(TextField).first, '1.25');
      await tester.pumpAndSettle();
      expect(
        ChatPresetOverrideStore.load('conv_ui').temperature,
        1.25,
      );

      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '全部恢复'));
      await tester.pumpAndSettle();
      expect(ChatPresetOverrideStore.load('conv_ui').isEmpty, isTrue);
    });

    testWidgets('已保存的覆盖会回填到输入框', (tester) async {
      await ChatPresetOverrideStore.save(
        'conv_back',
        const ChatPresetOverride(temperature: 1.1, topK: 12),
      );
      await _pumpScreen(tester, convId: 'conv_back');
      final fields = tester.widgetList<TextField>(find.byType(TextField))
          .map((f) => f.controller?.text)
          .toList();
      expect(fields.first, '1.1');
      expect(fields[2], '12');
    });
  });
}
