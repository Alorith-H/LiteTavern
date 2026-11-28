import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/widgets/character_actions_sheet.dart';

Widget _host(CharacterCard card, {VoidCallback? onEdit, VoidCallback? onDelete}) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showCharacterActionsSheet(
              context,
              card: card,
              onEdit: onEdit ?? () {},
              onDelete: onDelete ?? () {},
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  const card = CharacterCard(
    id: 'c1',
    name: '测试角色甲',
    description: '简介',
    personality: '',
    scenario: '',
    firstMes: '',
    mesExample: '',
    systemPrompt: '',
    alternateGreetings: [],
    tags: [],
    creator: '',
  );

  testWidgets('长按菜单只有两个按钮，没有标题与分组', (tester) async {
    await tester.pumpWidget(_host(card));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('编辑角色'), findsOneWidget);
    expect(find.text('删除角色'), findsOneWidget);
    // 角色名、「角色操作」标题、分组标题都不再出现
    expect(find.text('测试角色甲'), findsNothing);
    expect(find.text('角色操作'), findsNothing);
    expect(find.text('编辑'), findsNothing);
    expect(find.text('危险操作'), findsNothing);
  });

  testWidgets('点编辑角色回调编辑并关闭弹层', (tester) async {
    var edited = 0;
    await tester.pumpWidget(_host(card, onEdit: () => edited++));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('编辑角色'));
    await tester.pumpAndSettle();
    expect(edited, 1);
    expect(find.text('编辑角色'), findsNothing);
  });

  testWidgets('点删除角色回调删除并关闭弹层', (tester) async {
    var deleted = 0;
    await tester.pumpWidget(_host(card, onDelete: () => deleted++));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除角色'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(find.text('删除角色'), findsNothing);
  });
}
