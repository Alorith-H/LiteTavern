import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/screens/settings_screen.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/usage_cost.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
    Storage.initForTest(
      Directory.systemTemp.createTempSync('lt_v35_'),
    );
    // shared_preferences 的 mock 实例在同一测试文件内会复用，显式清零避免串场。
    AppSettings.priceInputPerMillion = 0;
    AppSettings.priceOutputPerMillion = 0;
    AppSettings.priceCachedPerMillion = 0;
  });

  group('TokenPrice', () {
    test('没填价格时 configured=false，缓存价回落到输入价', () {
      const p = TokenPrice();
      expect(p.configured, isFalse);
      expect(p.effectiveCachedPrice, 0);
    });

    test('只填输入价也算配置过', () {
      const p = TokenPrice(inputPerMillion: 2);
      expect(p.configured, isTrue);
      expect(p.effectiveCachedPrice, 2);
    });

    test('单独填缓存价时优先生效', () {
      const p = TokenPrice(inputPerMillion: 2, cachedInputPerMillion: 0.2);
      expect(p.effectiveCachedPrice, 0.2);
    });
  });

  group('UsageCost 计算', () {
    test('无缓存：输入 + 输出按各自单价', () {
      const cost = UsageCost(
        inputTokens: 1000000,
        outputTokens: 500000,
        price: TokenPrice(inputPerMillion: 2, outputPerMillion: 4),
      );
      expect(cost.total, 2 + 2);
      expect(cost.cacheSavings, 0);
      expect(cost.cacheHitRatio, 0);
    });

    test('缓存命中按缓存价算，并算出差额', () {
      const cost = UsageCost(
        inputTokens: 1000000,
        outputTokens: 0,
        cachedInputTokens: 600000,
        price: TokenPrice(
          inputPerMillion: 2,
          outputPerMillion: 4,
          cachedInputPerMillion: 0.2,
        ),
      );
      // 400k * 2/M + 600k * 0.2/M = 0.8 + 0.12
      expect(cost.total, closeTo(0.92, 1e-9));
      expect(cost.uncachedInputTokens, 400000);
      expect(cost.cacheHitRatio, closeTo(0.6, 1e-9));
      // 600k * (2 - 0.2)/M
      expect(cost.cacheSavings, closeTo(1.08, 1e-9));
    });

    test('缓存数超过输入数时按输入数收敛', () {
      const cost = UsageCost(
        inputTokens: 100,
        outputTokens: 0,
        cachedInputTokens: 500,
        price: TokenPrice(inputPerMillion: 1),
      );
      expect(cost.uncachedInputTokens, 0);
      expect(cost.cacheHitRatio, 1.0);
    });

    test('没填价格时总价为 0，但有 token 数', () {
      const cost = UsageCost(inputTokens: 5000, outputTokens: 1000);
      expect(cost.total, 0);
      expect(cost.cacheSavings, 0);
    });

    test('merge 累加三组数字', () {
      const a = UsageCost(inputTokens: 100, outputTokens: 10, cachedInputTokens: 40);
      const b = UsageCost(inputTokens: 200, outputTokens: 20, cachedInputTokens: 60);
      final m = a.merge(b);
      expect(m.inputTokens, 300);
      expect(m.outputTokens, 30);
      expect(m.cachedInputTokens, 100);
    });
  });

  group('formatMoney', () {
    test('0 / 极小 / 很小 / 正常', () {
      expect(formatMoney(0), '0');
      expect(formatMoney(0.00001), '<0.0001');
      expect(formatMoney(0.00123), '0.0012');
      expect(formatMoney(1.5), '1.50');
    });
  });

  group('费用设置与统计口径', () {
    test('单价往返持久化，负值按 0 处理由调用方保证', () async {
      AppSettings.priceInputPerMillion = 0.28;
      AppSettings.priceOutputPerMillion = 0.42;
      AppSettings.priceCachedPerMillion = 0.028;
      expect(AppSettings.priceInputPerMillion, 0.28);
      expect(AppSettings.priceOutputPerMillion, 0.42);
      expect(AppSettings.priceCachedPerMillion, 0.028);
    });

    test('ChatMessage 的 cachedPromptTokens 往返，null 不写', () {
      final m = ChatMessage(
        role: 'assistant',
        content: 'hi',
        timestamp: 1,
        promptTokens: 100,
        completionTokens: 20,
        cachedPromptTokens: 60,
      );
      final json = m.toJson();
      expect(json['cachedPromptTokens'], 60);
      final back = ChatMessage.fromJson(json);
      expect(back.cachedPromptTokens, 60);

      final plain = ChatMessage(role: 'user', content: 'x', timestamp: 2);
      expect(plain.toJson().containsKey('cachedPromptTokens'), isFalse);
      expect(ChatMessage.fromJson(plain.toJson()).cachedPromptTokens, isNull);
    });

    test('copyWith 能保留 / 覆盖 cachedPromptTokens', () {
      const m = ChatMessage(
        role: 'assistant',
        content: 'a',
        timestamp: 1,
        promptTokens: 10,
        completionTokens: 5,
        cachedPromptTokens: 4,
      );
      expect(m.copyWith(content: 'b').cachedPromptTokens, 4);
      expect(m.copyWith(cachedPromptTokens: 8).cachedPromptTokens, 8);
    });
  });

  group('设置页：用量与费用', () {
    testWidgets('打开弹窗填单价并保存', (tester) async {
      tester.view.physicalSize = const Size(1200, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: SettingsScreen(section: SettingsSection.chat),
        ),
      );
      await tester.pumpAndSettle();

      final row = find.text('用量与费用');
      await tester.scrollUntilVisible(row, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('输入价格 / 百万 token'), findsOneWidget);

      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(0), '1.2');
      await tester.enterText(fields.at(1), '3.4');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(AppSettings.priceInputPerMillion, 1.2);
      expect(AppSettings.priceOutputPerMillion, 3.4);
    });

    testWidgets('未填单价时行存在并给出提示', (tester) async {
      tester.view.physicalSize = const Size(1200, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: SettingsScreen(section: SettingsSection.chat),
        ),
      );
      await tester.pumpAndSettle();
      expect(AppSettings.priceInputPerMillion, 0);
      await tester.scrollUntilVisible(find.text('用量与费用'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('用量与费用'), findsOneWidget);
      expect(find.textContaining('未填写单价'), findsOneWidget);
    });
  });
}
