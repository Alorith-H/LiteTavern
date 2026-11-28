import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/widgets/card_variables_dialog.dart';

Widget _host(ValueChanged<bool?> onResult) => MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final r = await showCardVariablesDialog(context);
                onResult(r);
              },
              child: const Text('生成'),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('弹窗说明变量用途并给出三个选择', (tester) async {
    await tester.pumpWidget(_host((_) {}));
    await tester.tap(find.text('生成'));
    await tester.pumpAndSettle();

    expect(find.text('要加初始变量吗？'), findsOneWidget);
    expect(find.textContaining('好感度、体力'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('不加，直接生成'), findsOneWidget);
    expect(find.text('加上变量'), findsOneWidget);
  });

  testWidgets('点「加上变量」返回 true', (tester) async {
    bool? result;
    await tester.pumpWidget(_host((r) => result = r));
    await tester.tap(find.text('生成'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('加上变量'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('点「不加，直接生成」返回 false', (tester) async {
    bool? result;
    await tester.pumpWidget(_host((r) => result = r));
    await tester.tap(find.text('生成'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('不加，直接生成'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('点「取消」返回 null（不生成）', (tester) async {
    var called = false;
    bool? result;
    await tester.pumpWidget(_host((r) {
      called = true;
      result = r;
    }));
    await tester.tap(find.text('生成'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(called, isTrue);
    expect(result, isNull);
  });
}
