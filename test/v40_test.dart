import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/widgets/sheet_menu.dart';

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(body: child),
    );

List<SheetMenuGroup> _groups(void Function(String) onTap) => [
      SheetMenuGroup(
        label: '生成',
        icon: Icons.auto_awesome_outlined,
        description: '重新生成 / 继续生成',
        children: [
          SheetMenuItem(
            icon: Icons.refresh_outlined,
            title: '重新生成',
            subtitle: '用同一条你的话再要一次回复',
            onTap: () => onTap('regen'),
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
            onTap: () => onTap('clear'),
          ),
        ],
      ),
    ];

Future<void> _open(WidgetTester tester, void Function(String) onTap) async {
  await tester.pumpWidget(_host(Builder(
    builder: (context) => Center(
      child: TextButton(
        onPressed: () => showGroupedSheetMenu(context, groups: _groups(onTap)),
        child: const Text('打开菜单'),
      ),
    ),
  )));
  await tester.tap(find.text('打开菜单'));
  await tester.pumpAndSettle();
}

void main() {
  group('二级菜单（showGroupedSheetMenu）', () {
    testWidgets('一级只列组名与概括，不显示大标题', (tester) async {
      var tapped = '';
      await _open(tester, (v) => tapped = v);

      expect(find.text('生成'), findsOneWidget);
      expect(find.text('危险操作'), findsOneWidget);
      expect(find.text('重新生成 / 继续生成'), findsOneWidget);
      expect(find.byType(SheetMenuTitle), findsNothing);
      expect(find.text('重新生成'), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsWidgets);
      expect(tapped, '');
    });

    testWidgets('点组进二级，点条目回调并关闭菜单', (tester) async {
      var tapped = '';
      await _open(tester, (v) => tapped = v);

      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      expect(find.text('重新生成'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.text('危险操作'), findsNothing);

      // 二级点条目：回调触发（实际菜单项会自己关闭菜单）
      await tester.tap(find.text('重新生成'));
      await tester.pumpAndSettle();
      expect(tapped, 'regen');
      expect(find.text('重新生成'), findsOneWidget);

      // 点空白先回一级
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('重新生成'), findsNothing);
    });

    testWidgets('二级按返回箭头回到一级，不关闭菜单', (tester) async {
      await _open(tester, (_) {});

      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      expect(find.text('重新生成'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // 回到一级：组还在，条目消失
      expect(find.text('生成'), findsOneWidget);
      expect(find.text('危险操作'), findsOneWidget);
      expect(find.text('重新生成'), findsNothing);
    });

    testWidgets('二级点空白处回到一级，一级点空白处关闭', (tester) async {
      await _open(tester, (_) {});

      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      expect(find.text('重新生成'), findsOneWidget);

      // 点空白（遮罩）→ 回一级
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('重新生成'), findsNothing);
      expect(find.text('生成'), findsOneWidget);

      // 一级再点空白 → 关闭
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('生成'), findsNothing);
    });

    testWidgets('系统返回键在二级回到一级，一级再返回才关闭', (tester) async {
      await _open(tester, (_) {});

      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      expect(find.text('重新生成'), findsOneWidget);

      // 模拟系统返回
      final dynamic widgetsAppState = tester.state(find.byType(WidgetsApp));
      await widgetsAppState.didPopRoute();
      await tester.pumpAndSettle();
      expect(find.text('重新生成'), findsNothing);
      expect(find.text('生成'), findsOneWidget);

      await widgetsAppState.didPopRoute();
      await tester.pumpAndSettle();
      expect(find.text('生成'), findsNothing);
    });
  });
}
