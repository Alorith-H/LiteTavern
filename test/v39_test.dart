import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/screens/settings_screen.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/widgets/sheet_menu.dart';

/// v0.39.0：底部菜单统一零件（标题 / 分组 / 条目 / 弹出器）与设置首页图标。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
    Storage.initForTest(Directory.systemTemp.createTempSync('lt_v39_'));
  });

  Widget host(Widget child) => MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF9C4632),
            brightness: Brightness.dark,
          ),
        ),
        home: Scaffold(body: child),
      );

  group('SheetMenuItem', () {
    testWidgets('显示标题、副标题与图标', (tester) async {
      await tester.pumpWidget(host(
        SheetMenuItem(
          icon: Icons.search,
          title: '搜索对话',
          subtitle: '在这段聊天里找关键词',
          onTap: () {},
        ),
      ));

      expect(find.text('搜索对话'), findsOneWidget);
      expect(find.text('在这段聊天里找关键词'), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('点按触发回调', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(
        SheetMenuItem(title: '复制', onTap: () => taps++),
      ));

      await tester.tap(find.text('复制'));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('禁用时点不动且变灰', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(
        SheetMenuItem(title: '继续生成', enabled: false, onTap: () => taps++),
      ));

      await tester.tap(find.text('继续生成'));
      await tester.pump();

      expect(taps, 0);
      final text = tester.widget<Text>(find.text('继续生成'));
      expect(text.style!.color, isNot(Colors.white));
    });

    testWidgets('危险项用错误色', (tester) async {
      await tester.pumpWidget(host(
        SheetMenuItem(
          icon: Icons.delete_outline,
          title: '删除',
          danger: true,
          onTap: () {},
        ),
      ));

      final scheme = Theme.of(tester.element(find.text('删除'))).colorScheme;
      final title = tester.widget<Text>(find.text('删除'));
      expect(title.style!.color, scheme.error);
      final icon = tester.widget<Icon>(find.byIcon(Icons.delete_outline));
      expect(icon.color, scheme.error);
    });
  });

  group('SheetMenuTitle / SheetMenuSection', () {
    testWidgets('标题与说明、分组小标题都能渲染', (tester) async {
      await tester.pumpWidget(host(
        Column(
          children: const [
            SheetMenuTitle(title: '聊天菜单', subtitle: '当前：分支一'),
            SheetMenuSection('这段聊天'),
          ],
        ),
      ));

      expect(find.text('聊天菜单'), findsOneWidget);
      expect(find.text('当前：分支一'), findsOneWidget);
      expect(find.text('这段聊天'), findsOneWidget);
    });
  });

  group('showSheetMenu', () {
    testWidgets('弹出后能点到条目并关闭', (tester) async {
      var picked = 0;
      await tester.pumpWidget(host(
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showSheetMenu<void>(
              context: ctx,
              children: [
                const SheetMenuTitle(title: '导入角色卡'),
                const SheetMenuSection('在线获取'),
                Builder(
                  builder: (itemCtx) => SheetMenuItem(
                    title: '角色卡市场',
                    onTap: () {
                      Navigator.pop(itemCtx);
                      picked++;
                    },
                  ),
                ),
              ],
            ),
            child: const Text('打开'),
          ),
        ),
      ));

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('导入角色卡'), findsOneWidget);
      expect(find.text('在线获取'), findsOneWidget);

      await tester.tap(find.text('角色卡市场'));
      await tester.pumpAndSettle();

      expect(picked, 1);
      expect(find.text('导入角色卡'), findsNothing);
    });
  });

  group('设置首页图标（v0.39.0）', () {
    testWidgets('六个分组入口都带图标', (tester) async {
      await tester.pumpWidget(host(const SettingsScreen()));
      await tester.pumpAndSettle();

      for (final icon in <IconData>[
        Icons.tune,
        Icons.forum_outlined,
        Icons.storefront_outlined,
        Icons.menu_book_outlined,
        Icons.palette_outlined,
        Icons.help_outline,
      ]) {
        expect(find.byIcon(icon), findsOneWidget, reason: '缺图标 $icon');
      }
      expect(find.byType(SheetMenuItem), findsNothing);
    });
  });
}
