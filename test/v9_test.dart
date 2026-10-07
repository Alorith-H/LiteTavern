import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/services/api_client.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/sampling_params.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/widgets/segmented_toggle.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<PromptMessage> _msgs() => [
      const PromptMessage(role: 'user', content: '你好'),
    ];

void main() {
  // ---------------------------------------------------- 默认不发送 --
  group('高级采样：默认值 = 请求里完全不出现（对严格端点零影响）', () {
    test('默认 sampling 的 body keys 与 v0.8 完全一致', () {
      final body = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        includeUsage: true,
      );
      expect(
        body.keys.toSet(),
        {
          'model',
          'messages',
          'stream',
          'temperature',
          'top_p',
          'stream_options',
        },
      );
      // 任何高级字段都不允许出现
      for (final k in [
        'frequency_penalty',
        'presence_penalty',
        'repetition_penalty',
        'top_k',
        'min_p',
        'seed',
        'stop',
      ]) {
        expect(body.containsKey(k), isFalse, reason: '默认不应出现 $k');
      }
      expect(const SamplingParams().isDefault, isTrue);
    });

    test('frequency/presence_penalty 非默认才出现，默认 0 不出现', () {
      final on = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        sampling: const SamplingParams(
          frequencyPenalty: 0.5,
          presencePenalty: 1.2,
        ),
      );
      expect(on['frequency_penalty'], 0.5);
      expect(on['presence_penalty'], 1.2);

      final off = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        sampling: const SamplingParams(
          frequencyPenalty: 0,
          presencePenalty: 0,
        ),
      );
      expect(off.containsKey('frequency_penalty'), isFalse);
      expect(off.containsKey('presence_penalty'), isFalse);
    });

    test('repetition_penalty = 1.0 不出现，1.5 出现', () {
      final off = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        sampling: const SamplingParams(repetitionPenalty: 1.0),
      );
      expect(off.containsKey('repetition_penalty'), isFalse);

      final on = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        sampling: const SamplingParams(repetitionPenalty: 1.5),
      );
      expect(on['repetition_penalty'], 1.5);
    });

    test('top_k / min_p = 0 不出现，非 0 出现', () {
      final off = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        sampling: const SamplingParams(topK: 0, minP: 0),
      );
      expect(off.containsKey('top_k'), isFalse);
      expect(off.containsKey('min_p'), isFalse);

      final on = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        sampling: const SamplingParams(topK: 40, minP: 0.12),
      );
      expect(on['top_k'], 40);
      expect(on['min_p'], 0.12);
    });

    test('seed null 不出现，固定种子出现', () {
      final off = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        sampling: const SamplingParams(seed: null),
      );
      expect(off.containsKey('seed'), isFalse);

      final on = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        sampling: const SamplingParams(seed: 42),
      );
      expect(on['seed'], 42);
    });

    test('stop 空列表不出现，非空逐条写入', () {
      final off = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        sampling: const SamplingParams(stop: []),
      );
      expect(off.containsKey('stop'), isFalse);

      final on = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: true,
        temperature: 0.8,
        topP: 1.0,
        sampling: const SamplingParams(stop: ['STOP', '###']),
      );
      expect(on['stop'], ['STOP', '###']);
    });

    test('非流式请求不带 stream_options（流式传输开关关）', () {
      final body = buildChatRequestBody(
        model: 'm',
        messages: _msgs(),
        stream: false,
        temperature: 0.8,
        topP: 1.0,
        includeUsage: true,
      );
      expect(body['stream'], isFalse);
      expect(body.containsKey('stream_options'), isFalse);
    });
  });

  // ---------------------------------------------------- 预设迁移 --
  group('预设迁移：旧 JSON 缺新字段 → 默认补齐', () {
    test('旧三字段 JSON 读取 → 高级字段全为默认值', () {
      final p = GenPreset.fromJson({
        'id': 'p1',
        'name': '旧预设',
        'temperature': 0.9,
        'topP': 0.95,
        'maxTokens': 256,
      });
      expect(p.temperature, 0.9); // 旧字段原样
      expect(p.frequencyPenalty, 0);
      expect(p.presencePenalty, 0);
      expect(p.repetitionPenalty, 1.0);
      expect(p.topK, 0);
      expect(p.minP, 0);
      expect(p.seed, isNull);
      expect(p.stop, isEmpty);
      expect(p.sampling.isDefault, isTrue);
    });

    test('补齐后 toJson 带齐全部新字段，往返不丢', () {
      final old = GenPreset.fromJson({
        'id': 'p1',
        'name': 'n',
        'temperature': 0.7,
        'topP': 1.0,
        'maxTokens': 0,
      });
      final json = old.toJson();
      for (final k in [
        'frequencyPenalty',
        'presencePenalty',
        'repetitionPenalty',
        'topK',
        'minP',
        'seed',
        'stop',
      ]) {
        expect(json.containsKey(k), isTrue, reason: '保存应带 $k');
      }
      final back = GenPreset.fromJson(json);
      expect(back.temperature, 0.7);
      expect(back.sampling.isDefault, isTrue);
    });

    test('AppSettings.init 读旧 gen_presets → 激活预设补齐默认；'
        'setter 改动写入激活预设', () async {
      SharedPreferences.setMockInitialValues({
        'gen_presets': jsonEncode([
          {
            'id': 'p1',
            'name': '旧',
            'temperature': 0.9,
            'topP': 1.0,
            'maxTokens': 0,
          },
        ]),
        'active_preset_id': 'p1',
      });
      await AppSettings.init();

      final p = AppSettings.activePreset;
      expect(p.temperature, 0.9);
      expect(p.frequencyPenalty, 0);
      expect(p.sampling.isDefault, isTrue);

      // 改动即存入激活预设
      AppSettings.frequencyPenalty = 0.5;
      AppSettings.topK = 20;
      AppSettings.seed = 7;
      AppSettings.stop = SamplingParams.parseStopText('  \n第一行\n\n第二行');
      expect(AppSettings.activePreset.frequencyPenalty, 0.5);
      expect(AppSettings.activePreset.topK, 20);
      expect(AppSettings.activePreset.seed, 7);
      expect(AppSettings.activePreset.stop, ['第一行', '第二行']);

      final sp = await SharedPreferences.getInstance();
      final saved = (jsonDecode(sp.getString('gen_presets')!) as List)
          .cast<Map<String, dynamic>>()
          .single;
      expect(saved['frequencyPenalty'], 0.5);
      expect(saved['topK'], 20);
      expect(saved['seed'], 7);
      expect(saved['stop'], ['第一行', '第二行']);

      // seed 清空 = 回到随机（null），走哨兵 copyWith
      AppSettings.seed = null;
      expect(AppSettings.activePreset.seed, isNull);
    });

    test('全新安装：默认预设高级字段全默认 + 流式传输默认开', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      expect(AppSettings.activePreset.sampling.isDefault, isTrue);
      expect(AppSettings.streaming, isTrue);
      AppSettings.streaming = false;
      expect(AppSettings.streaming, isFalse);
    });
  });

  // -------------------------------------------------- 停止词归一化 --
  group('停止词归一化', () {
    test('两端去空白、丢空行、最多 4 条', () {
      final stop = SamplingParams.normalizeStop([
        '  甲  ',
        '',
        '   ',
        '乙',
        '丙',
        '丁',
        '戊', // 第 5 条被截断
      ]);
      expect(stop, ['甲', '乙', '丙', '丁']);
      expect(stop, hasLength(SamplingParams.maxStopCount));
    });

    test('多行文本 ↔ 列表往返', () {
      final list = SamplingParams.parseStopText('  第一行 \n\n第二行\n');
      expect(list, ['第一行', '第二行']);
      expect(SamplingParams.stopToText(list), '第一行\n第二行');
      expect(SamplingParams.parseStopText(SamplingParams.stopToText(list)),
          list);
    });
  });

  // ---------------------------------------------- 分段控件滑动动画 --
  group('单人/群聊分段按钮：胶囊高亮平滑滑动', () {
    Widget host({int initial = 0, ValueChanged<int>? onChanged}) {
      var tab = initial;
      return MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SegmentedToggle(
              value: tab,
              labels: const ['单人', '群聊'],
              onChanged: (i) {
                setState(() => tab = i);
                onChanged?.call(i);
              },
            ),
          ),
        ),
      );
    }

    double indicatorX(WidgetTester tester) => tester
        .getTopLeft(find.byKey(SegmentedToggle.indicatorKey))
        .dx;

    testWidgets('点击后 pump 动画完成，指示器在目标段', (tester) async {
      var tab = 0;
      await tester.pumpWidget(host(initial: 0, onChanged: (i) => tab = i));

      // 初始：指示器贴左（段 0）
      final x0 = indicatorX(tester);
      expect(x0, inInclusiveRange(0, 4));

      // 点击「群聊」→ 动画完成后指示器右移到段 1
      await tester.tap(find.text('群聊'));
      await tester.pump(); // 动画开始
      await tester.pump(const Duration(milliseconds: 400));
      expect(tab, 1);

      final container = tester.getSize(find.byType(SegmentedToggle));
      // 段宽 = (容器宽 - 2×内边距3 - 1×间距6) / 2；目标 left = 3 + 段宽 + 6
      final segW = (container.width - 6 - 6) / 2;
      final target = 3 + segW + 6;
      expect(indicatorX(tester), closeTo(target, 1.0));
      expect(indicatorX(tester), greaterThan(x0 + 100));
    });

    testWidgets('动画中途指示器处于两段之间（平滑滑动，非瞬时跳变）',
        (tester) async {
      await tester.pumpWidget(host(initial: 0));
      final x0 = indicatorX(tester);

      await tester.tap(find.text('群聊'));
      await tester.pump(); // 起步一帧
      await tester.pump(const Duration(milliseconds: 60));

      final mid = indicatorX(tester);
      final container = tester.getSize(find.byType(SegmentedToggle));
      final target = 3 + (container.width - 12) / 2 + 6;
      expect(mid, greaterThan(x0 + 1));
      expect(mid, lessThan(target - 1));

      await tester.pump(const Duration(milliseconds: 400));
      expect(indicatorX(tester), closeTo(target, 1.0));
    });

    testWidgets('点左点右都触发：切回「单人」指示器滑回左侧', (tester) async {
      await tester.pumpWidget(host(initial: 0));
      await tester.tap(find.text('群聊'));
      await tester.pump(); // 起步帧（否则动画在 400ms 帧内才启动，量不到位移）
      await tester.pump(const Duration(milliseconds: 400));
      final xRight = indicatorX(tester);
      expect(xRight, greaterThan(100)); // 已滑到右段

      await tester.tap(find.text('单人'));
      await tester.pump(); // 起步帧
      await tester.pump(const Duration(milliseconds: 400));
      expect(indicatorX(tester), lessThan(xRight - 100));
    });
  });
}
