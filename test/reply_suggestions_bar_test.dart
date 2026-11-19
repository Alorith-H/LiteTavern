import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:litetavern/widgets/reply_suggestions_bar.dart';

void main() {
  // 三条互不相同的短建议：chip 文案不会被 ellipsis 影响断言
  const three = <String>['嗯，我明白了。', '那就按你说的办。', '稍等我一下。'];

  /// 统一用 MaterialApp + Scaffold 包裹，暗色主题同样走 colorScheme
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

  group('ReplySuggestionsBar 渲染', () {
    testWidgets('传入 3 条建议 → 3 个 ActionChip 文案都在、「换一批」可见', (tester) async {
      await pumpBar(tester, suggestions: three);

      expect(find.byType(ActionChip), findsNWidgets(3));
      for (final text in three) {
        expect(find.text(text), findsOneWidget);
      }
      expect(find.text('换一批'), findsOneWidget);
    });

    testWidgets('loading: true → 出现「生成中…」与 CircularProgressIndicator', (
      tester,
    ) async {
      await pumpBar(tester, suggestions: three, loading: true);

      expect(find.text('生成中…'), findsOneWidget);
      expect(find.text('换一批'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // spinner 是 12x12 的小行内指示器
      final size = tester.getSize(find.byType(CircularProgressIndicator));
      expect(size.width, 12);
      expect(size.height, 12);
    });

    testWidgets('loading: false 时不渲染「生成中…」与 spinner', (tester) async {
      await pumpBar(tester, suggestions: three);

      expect(find.text('生成中…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('ReplySuggestionsBar 交互', () {
    testWidgets('点第 2 条 chip → onSend 收到完全一致的文本', (tester) async {
      String? sent;
      await pumpBar(tester, suggestions: three, onSend: (text) => sent = text);

      await tester.tap(find.text(three[1]));
      await tester.pump();

      expect(sent, three[1]);
    });

    testWidgets('点「换一批」→ onRefresh 被调用 1 次', (tester) async {
      var refreshCount = 0;
      await pumpBar(
        tester,
        suggestions: three,
        onRefresh: () => refreshCount++,
      );

      await tester.tap(find.text('换一批'));
      await tester.pump();

      expect(refreshCount, 1);
    });

    testWidgets('loading: true → 点 chip 与「换一批」都不触发回调', (tester) async {
      String? sent;
      var refreshCount = 0;
      await pumpBar(
        tester,
        suggestions: three,
        loading: true,
        onSend: (text) => sent = text,
        onRefresh: () => refreshCount++,
      );

      // 依次点 disabled 的 chip 与按钮（不 pumpAndSettle：spinner 永动）
      await tester.tap(find.text(three[0]));
      await tester.pump();
      await tester.tap(find.text('生成中…'));
      await tester.pump();

      expect(sent, isNull);
      expect(refreshCount, 0);
    });
  });

  group('ReplySuggestionsBar 边界', () {
    testWidgets('空建议且非 loading → 整条消失（只剩 SizedBox.shrink）', (tester) async {
      await pumpBar(tester, suggestions: const []);

      // 「换一批」只有本组件会渲染；它不在即整条消失
      expect(find.text('换一批'), findsNothing);
      expect(find.byType(ActionChip), findsNothing);
      expect(find.byType(SingleChildScrollView), findsNothing);
    });

    testWidgets('空建议但 loading: true → 仍渲染生成中状态', (tester) async {
      await pumpBar(tester, suggestions: const [], loading: true);

      expect(find.text('生成中…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('200 字超长文本 → 单行省略，不抛 overflow', (tester) async {
      final long = '这是一条非常长的回复建议文本，' * 20;
      await pumpBar(tester, suggestions: [long]);

      expect(tester.takeException(), isNull);
      expect(find.text(long), findsOneWidget);
      // chip 宽度受 240dp 上限约束，不会撑爆整行
      final chipWidth = tester.getSize(find.byType(ActionChip)).width;
      expect(chipWidth, lessThanOrEqualTo(240));
    });
  });
}
