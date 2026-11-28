import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/widgets/sheet_menu.dart';

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(body: child),
    );

void main() {
  group('二级菜单（showGroupedSheetMenu）', () {
    testWidgets('一级只列组名与概括，不显示大标题，点开才看条目', (tester) async {
      var tapped = '';
      await tester.pumpWidget(_host(Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showGroupedSheetMenu(
              context,
              groups: [
                SheetMenuGroup(
                  label: '生成',
                  icon: Icons.auto_awesome_outlined,
                  description: '重新生成 / 继续生成',
                  children: [
                    SheetMenuItem(
                      icon: Icons.refresh_outlined,
                      title: '重新生成',
                      subtitle: '用同一条你的话再要一次回复',
                      onTap: () {
                        tapped = 'regen';
                        Navigator.pop(context);
                      },
                    ),
                    SheetMenuItem(
                      icon: Icons.play_arrow_outlined,
                      title: '继续生成',
                      onTap: () {
                        tapped = 'continue';
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),
                SheetMenuGroup(
                  label: '危险操作',
                  icon: Icons.warning_amber_outlined,
                  danger: true,
                  description: '清空这段对话',
                  children: [
                    SheetMenuItem(
                      icon: Icons.delete_sweep_outlined,
                      title: '清空对话',
                      danger: true,
                      onTap: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ],
            ),
            child: const Text('打开菜单'),
          ),
        ),
      )));

      await tester.tap(find.text('打开菜单'));
      await tester.pumpAndSettle();

      // 一级：只有组名与概括，没有 SheetMenuTitle，也没有组内条目
      expect(find.text('生成'), findsOneWidget);
      expect(find.text('危险操作'), findsOneWidget);
      expect(find.text('重新生成 / 继续生成'), findsOneWidget);
      expect(find.byType(SheetMenuTitle), findsNothing);
      expect(find.text('重新生成'), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsWidgets);

      // 点「生成」→ 二级：标题是组名，条目出现
      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      expect(find.byType(SheetMenuTitle), findsOneWidget);
      expect(find.text('重新生成'), findsOneWidget);
      expect(find.text('继续生成'), findsOneWidget);
      expect(find.text('危险操作'), findsNothing);

      // 点条目 → 回调触发并关闭
      await tester.tap(find.text('重新生成'));
      await tester.pumpAndSettle();
      expect(tapped, 'regen');
      expect(find.text('重新生成'), findsNothing);
    });

    testWidgets('一级点遮罩关闭，不打开二级', (tester) async {
      await tester.pumpWidget(_host(Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showGroupedSheetMenu(
              context,
              groups: [
                SheetMenuGroup(
                  label: '角色',
                  icon: Icons.person_outline,
                  children: [
                    SheetMenuItem(icon: Icons.edit_outlined, title: '编辑角色'),
                  ],
                ),
              ],
            ),
            child: const Text('打开菜单'),
          ),
        ),
      )));

      await tester.tap(find.text('打开菜单'));
      await tester.pumpAndSettle();
      expect(find.text('角色'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('角色'), findsNothing);
      expect(find.text('编辑角色'), findsNothing);
    });
  });
}
