import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/services/sampling_params.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/widgets/reply_candidates_sheet.dart';

void main() {
  // ---------------------------------------------- 候选采样参数派生 --
  group('SamplingParams.forCandidate', () {
    test('默认参数 + seed 为空：三个候选都是默认参数（请求不带高级字段）', () {
      const base = SamplingParams();
      for (var i = 0; i < 3; i++) {
        final p = base.forCandidate(i);
        expect(p.seed, isNull);
        expect(p.isDefault, isTrue);
      }
    });

    test('seed 已设置时按序号偏移（+0/+1/+2），其它字段原样保留', () {
      const base = SamplingParams(
        frequencyPenalty: 0.5,
        presencePenalty: 0.25,
        repetitionPenalty: 1.1,
        topK: 20,
        minP: 0.05,
        seed: 7,
        stop: ['停'],
      );
      final a = base.forCandidate(0);
      final b = base.forCandidate(1);
      final c = base.forCandidate(2);
      expect([a.seed, b.seed, c.seed], [7, 8, 9]);
      for (final p in [a, b, c]) {
        expect(p.frequencyPenalty, 0.5);
        expect(p.presencePenalty, 0.25);
        expect(p.repetitionPenalty, 1.1);
        expect(p.topK, 20);
        expect(p.minP, 0.05);
        expect(p.stop, ['停']);
        expect(p.isDefault, isFalse);
      }
      // 原对象不受影响
      expect(base.seed, 7);
    });
  });

  // ------------------------------------------------ 自动生成回复开关 --
  group('设置：自动生成回复（autoReplyCandidates）', () {
    test('全新安装默认关闭', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      expect(AppSettings.autoReplyCandidates, isFalse);
    });

    test('开启后写入 shared_preferences，重新读取仍为开', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      AppSettings.autoReplyCandidates = true;

      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('auto_reply_candidates'), isTrue);
      expect(AppSettings.autoReplyCandidates, isTrue);

      AppSettings.autoReplyCandidates = false;
      expect(sp.getBool('auto_reply_candidates'), isFalse);
    });

    test('旧数据无该键时回落到关闭（不误开候选模式）', () async {
      SharedPreferences.setMockInitialValues({'streaming': false});
      await AppSettings.init();
      expect(AppSettings.autoReplyCandidates, isFalse);
      expect(AppSettings.streaming, isFalse);
    });
  });

  // -------------------------------------------------- 候选选择器 UI --
  group('候选回复选择器', () {
    Future<ValueNotifier<int?>> openSheet(
      WidgetTester tester, {
      List<String> candidates = const ['甲', '乙', '丙'],
      Future<List<String>> Function()? onRegenerate,
    }) async {
      final picked = ValueNotifier<int?>(null);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked.value = await showReplyCandidatesSheet(
                    ctx,
                    candidates: candidates,
                    characterName: '小酒',
                    onRegenerate: onRegenerate,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('展示全部候选与角色名，点选一条返回下标', (tester) async {
      final picked = await openSheet(tester);
      expect(find.text('选择一条回复'), findsOneWidget);
      expect(find.text('小酒 生成了 3 个候选，点选一条采用'), findsOneWidget);
      expect(find.text('候选 1'), findsOneWidget);
      expect(find.text('候选 3'), findsOneWidget);
      expect(find.text('甲'), findsOneWidget);

      await tester.tap(find.text('乙'));
      await tester.pumpAndSettle();
      // 弹层已关闭，回调返回选中的下标 1
      expect(find.text('选择一条回复'), findsNothing);
      expect(picked.value, 1);
    });

    testWidgets('「换一批」重新请求并替换候选列表', (tester) async {
      var calls = 0;
      await openSheet(
        tester,
        onRegenerate: () async {
          calls++;
          return ['丁', '戊', '己'];
        },
      );
      expect(find.text('甲'), findsOneWidget);
      expect(find.text('换一批'), findsOneWidget);

      await tester.tap(find.text('换一批'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text('丁'), findsOneWidget);
      expect(find.text('甲'), findsNothing);
    });

    testWidgets('换一批失败时展示错误且保留原候选', (tester) async {
      await openSheet(
        tester,
        onRegenerate: () async => throw Exception('网络错误：超时'),
      );
      await tester.tap(find.text('换一批'));
      await tester.pumpAndSettle();

      expect(find.textContaining('网络错误：超时'), findsOneWidget);
      expect(find.text('甲'), findsOneWidget);
    });

    testWidgets('关闭弹层不返回下标（不落正文）', (tester) async {
      await openSheet(tester);
      // 点遮罩关闭
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('选择一条回复'), findsNothing);
    });
  });
}
