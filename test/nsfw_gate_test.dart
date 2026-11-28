import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/screens/settings_screen.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/tap_unlock.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内容开关的隐藏入口（v0.44.2）。
///
/// 规则：
/// - `nsfwUnlocked` 默认 false，此时 `showNsfw` 恒为 false（旧数据存了 true 也不生效）；
/// - 设置 → 帮助与关于 底部连点版本号 5 下解锁，开关才出现在「角色卡市场」。

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(body: child),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
    Storage.initForTest(
      Directory.systemTemp.createTempSync('lt_nsfw_gate_'),
    );
  });

  group('AppSettings 门控', () {
    test('默认未解锁，showNsfw 恒为 false', () {
      expect(AppSettings.nsfwUnlocked, isFalse);
      AppSettings.showNsfw = true; // 旧数据/绕过 UI 直接写
      expect(AppSettings.showNsfw, isFalse);
    });

    test('解锁后 showNsfw 才跟随存储值', () {
      AppSettings.showNsfw = true;
      expect(AppSettings.showNsfw, isFalse);

      AppSettings.nsfwUnlocked = true;
      expect(AppSettings.showNsfw, isTrue);

      AppSettings.showNsfw = false;
      expect(AppSettings.showNsfw, isFalse);
    });

    test('解锁状态持久化（prefs 键 nsfw_unlocked）', () async {
      AppSettings.nsfwUnlocked = true;
      // 重新 init 模拟重启
      await AppSettings.init();
      expect(AppSettings.nsfwUnlocked, isTrue);
    });
  });

  group('TapUnlock 计数', () {
    test('3 秒内点满 5 下才解锁，第 5 下返回 true', () {
      var now = DateTime(2026, 11, 28, 12);
      final gate = TapUnlock(clock: () => now);
      for (var i = 0; i < 4; i++) {
        expect(gate.tap(), isFalse);
        now = now.add(const Duration(milliseconds: 300));
      }
      expect(gate.tap(), isTrue);
      expect(gate.taps, 0, reason: '解锁后清零');
    });

    test('间隔超过 3 秒重新计数', () {
      var now = DateTime(2026, 11, 28, 12);
      final gate = TapUnlock(clock: () => now);
      for (var i = 0; i < 4; i++) {
        gate.tap();
        now = now.add(const Duration(milliseconds: 200));
      }
      expect(gate.taps, 4);
      now = now.add(const Duration(seconds: 4));
      expect(gate.tap(), isFalse);
      expect(gate.taps, 1, reason: '超时后从 1 重新数');
    });

    test('reset 清零', () {
      final gate = TapUnlock();
      gate.tap();
      gate.reset();
      expect(gate.taps, 0);
    });
  });

  group('设置页隐藏入口', () {    testWidgets('未解锁时「角色卡市场」没有开关，只有中性说明', (tester) async {
      await tester.pumpWidget(
        _host(const SettingsScreen(section: SettingsSection.market)),
      );
      await tester.pumpAndSettle();

      expect(find.text('显示全部内容'), findsNothing);
      expect(find.textContaining('仅显示全年龄角色卡'), findsOneWidget);
    });

    testWidgets('帮助与关于连点版本号 5 下解锁，市场页出现开关', (tester) async {
      await tester.pumpWidget(
        _host(const SettingsScreen(section: SettingsSection.help)),
      );
      await tester.pumpAndSettle();

      // 版本号在「帮助与关于」页脚，需要滚到底部才能点到。
      final version = find.textContaining('LiteTavern v');
      await tester.scrollUntilVisible(
        version,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(version, findsOneWidget);

      // 前 4 下不解锁
      for (var i = 0; i < 4; i++) {
        await tester.tap(version);
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(AppSettings.nsfwUnlocked, isFalse);

      await tester.tap(version);
      await tester.pump();
      expect(AppSettings.nsfwUnlocked, isTrue);
      expect(find.text('已解锁。'), findsOneWidget);
    });

    testWidgets('已解锁时市场页显示开关，切换写回设置', (tester) async {
      AppSettings.nsfwUnlocked = true;
      await tester.pumpWidget(
        _host(const SettingsScreen(section: SettingsSection.market)),
      );
      await tester.pumpAndSettle();

      expect(find.text('显示全部内容'), findsOneWidget);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(AppSettings.showNsfw, isTrue);
    });
  });
}
