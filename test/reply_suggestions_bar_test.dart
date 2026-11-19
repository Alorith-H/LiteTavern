import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:litetavern/widgets/reply_suggestions_bar.dart';

void main() {
  const three = <String>['嗯，我明白了。', '那就按你说的办。', '稍等我一下。'];

  Future<void> pumpBar(
    WidgetTester tester, {
    required List<String> suggestions,
    bool loading = false,
    ValueChanged<String>? onSend,
    VoidCallback? onRefresh,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
        home: Scaffold(
          body: ReplySuggestionsBar(
            suggestions: suggestions,
            loading: loading,
            onSend: onSend ?? (_) {},
            onRefresh: onRefresh ?? () {},
          ),
        ),
      ),
    );
  }

  group('ReplySuggestionsBar 纵向列表渲染', () {
    testWidgets('3 条建议完整展示、纵向排列、「换一批」可见', (tester) async {
      await pumpBar(tester, suggestions: three);

      for (final text in three) {
        expect(find.text(text), findsOneWidget);
      }
      expect(find.text('换一批'), findsOneWidget);
      expect(find.text('建议回复'), findsOneWidget);

      // 纵向：后一条在水平方向对齐、垂直方向在下
      final first = tester.getTopLeft(find.text(three[0]));
      final second = tester.getTopLeft(find.text(three[1]));
      final third = tester.getTopLeft(find.text(three[2]));
      expect(second.dy, greaterThan(first.dy));
      expect(third.dy, greaterThan(second.dy));
      expect(second.dx, closeTo(first.dx, 1.0));
    });

    testWidgets('不再使用横向滚动/ActionChip', (tester) async {
      await pumpBar(tester, suggestions: three);

      expect(find.byType(ActionChip), findsNothing);
      final scrollables = tester.widgetList<Scrollable>(find.byType(Scrollable));
      expect(
        scrollables.every((s) => s.axisDirection == AxisDirection.down),
        isTrue,
      );
    });

    testWidgets('长文本不截断（maxLines 为 null，完整显示）', (tester) async {
      final long = '这是一条很长很长的建议回复，用来确认列表里的文字不会被折叠成一半，'
          '而是会完整换行展示出来。${'继续补充上下文，' * 6}结束。';
      await pumpBar(tester, suggestions: [long]);

      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(find.text(long));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
    });
  });

  group('ReplySuggestionsBar 交互', () {
    testWidgets('点第 2 条 → onSend 收到完全一致的文本', (tester) async {
      String? sent;
      await pumpBar(tester, suggestions: three, onSend: (t) => sent = t);

      await tester.tap(find.text(three[1]));
      await tester.pump();

      expect(sent, three[1]);
    });

    testWidgets('点「换一批」→ onRefresh 恰好一次', (tester) async {
      var calls = 0;
      await pumpBar(tester, suggestions: three, onRefresh: () => calls++);

      await tester.tap(find.text('换一批'));
      await tester.pump();

      expect(calls, 1);
    });

    testWidgets('loading: true → 生成中、12x12 spinner、点击建议与换一批都不触发', (tester) async {
      var sent = 0;
      var refreshed = 0;
      await pumpBar(
        tester,
        suggestions: three,
        loading: true,
        onSend: (_) => sent++,
        onRefresh: () => refreshed++,
      );

      expect(find.text('生成中…'), findsOneWidget);
      expect(find.text('换一批'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final size = tester.getSize(find.byType(CircularProgressIndicator));
      expect(size.width, 12);
      expect(size.height, 12);

      await tester.tap(find.text(three[0]));
      await tester.tap(find.text('生成中…'));
      await tester.pump();

      expect(sent, 0);
      expect(refreshed, 0);
    });

    testWidgets('loading: false 时没有生成中/spinner', (tester) async {
      await pumpBar(tester, suggestions: three);

      expect(find.text('生成中…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('ReplySuggestionsBar 空态', () {
    testWidgets('空列表且非 loading → 完全不占位', (tester) async {
      await pumpBar(tester, suggestions: const []);

      expect(find.byType(ReplySuggestionsBar), findsOneWidget);
      expect(find.text('换一批'), findsNothing);
      expect(find.text('建议回复'), findsNothing);
      expect(tester.getSize(find.byType(ReplySuggestionsBar)).height, 0);
    });

    testWidgets('空列表但 loading → 仍显示生成中', (tester) async {
      await pumpBar(tester, suggestions: const [], loading: true);

      expect(find.text('生成中…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
