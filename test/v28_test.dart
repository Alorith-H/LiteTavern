import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:litetavern/screens/prompt_audit_screen.dart';
import 'package:litetavern/services/prompt_audit.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/token_estimate.dart';

List<PromptMessage> _prompt(List<(String, String)> rows) => [
      for (final r in rows) PromptMessage(role: r.$1, content: r.$2),
    ];

void main() {
  group('提示词检视：基础统计（v0.28.0）', () {
    test('第一次发送：没有缓存可复用，全部算新增', () {
      final current = _prompt([
        ('system', '你是艾琳。'),
        ('user', '你好'),
      ]);
      final report = PromptAudit.analyze(current: current);
      expect(report.firstSend, isTrue);
      expect(report.cacheableTokens, 0);
      expect(report.cacheHitRatio, 0);
      expect(report.parts.every((p) => p.change == PromptPartChange.added),
          isTrue);
      expect(report.suggestions.first, contains('第一次发送'));
      expect(report.summaryLine, contains('第一次发送'));
      expect(report.totalTokens,
          estimateTokens('你是艾琳。') + estimateTokens('你好'));
    });

    test('两次完全一致：全部命中，断点 = -1', () {
      final p = _prompt([
        ('system', '你是艾琳。'),
        ('user', '你好'),
        ('assistant', '你好呀'),
      ]);
      final report = PromptAudit.analyze(current: p, previous: p);
      expect(report.firstChangeIndex, -1);
      expect(report.cacheableTokens, report.totalTokens);
      expect(report.repayingTokens, 0);
      expect(report.cacheHitRatio, 1.0);
      expect(report.parts.every((p) => p.insideCachePrefix), isTrue);
      expect(report.summaryLine, contains('完全一致'));
    });

    test('末尾新增消息：前缀保留，新消息记新增', () {
      final prev = _prompt([
        ('system', '你是艾琳。'),
        ('user', '你好'),
        ('assistant', '你好呀'),
      ]);
      final current = [
        ...prev,
        const PromptMessage(role: 'user', content: '今天天气不错'),
      ];
      final report = PromptAudit.analyze(current: current, previous: prev);
      expect(report.firstChangeIndex, 3);
      expect(report.firstChangeLabel, '本轮新消息');
      expect(report.parts[3].change, PromptPartChange.added);
      expect(report.cacheableTokens, report.totalTokens - report.parts[3].tokens);
      expect(report.repayingTokens, report.parts[3].tokens);
      expect(report.suggestions.join(), contains('可复用'));
    });

    test('中间某段变了：其后全部重付', () {
      final prev = _prompt([
        ('system', '你是艾琳。'),
        ('user', '第一句'),
        ('assistant', '第一答'),
        ('user', '第二句'),
      ]);
      final current = _prompt([
        ('system', '你是艾琳。'),
        ('user', '第一句（改过）'),
        ('assistant', '第一答'),
        ('user', '第二句'),
      ]);
      final report = PromptAudit.analyze(current: current, previous: prev);
      expect(report.firstChangeIndex, 1);
      expect(report.parts[0].insideCachePrefix, isTrue);
      expect(report.parts[1].change, PromptPartChange.changed);
      expect(report.parts[1].insideCachePrefix, isFalse);
      expect(report.repayingTokens,
          report.totalTokens - report.parts[0].tokens);
      expect(report.summaryLine, contains('历史 · 你'));
    });

    test('标签：系统提示 / 历史 · 你 / 历史 · 角色回复 / 本轮新消息', () {
      final p = _prompt([
        ('system', '设定'),
        ('user', '你1'),
        ('assistant', '答2'),
        ('user', '本轮'),
      ]);
      final report = PromptAudit.analyze(current: p);
      expect(report.parts[0].label, '系统提示');
      expect(report.parts[1].label, '历史 · 你 #1');
      expect(report.parts[2].label, '历史 · 角色回复 #2');
      expect(report.parts[3].label, '本轮新消息');
    });

    test('预览压平换行并截断', () {
      final p = _prompt([
        ('system', '第一行\n第二行  ${'很长' * 40}'),
      ]);
      final report = PromptAudit.analyze(current: p);
      expect(report.parts.first.preview, isNot(contains('\n')));
      expect(report.parts.first.preview.length, lessThanOrEqualTo(41));
      expect(report.parts.first.preview, endsWith('…'));
    });
  });

  group('提示词检视：省钱建议（v0.28.0）', () {
    test('系统提示含时间宏 → 建议删掉', () {
      final p = _prompt([
        ('system', '现在是 {{time}}，你扮演艾琳。'),
        ('user', '你好'),
      ]);
      final report = PromptAudit.analyze(current: p, previous: p);
      expect(report.suggestions.join(), contains('时间/日期'));
    });

    test('系统提示含实时时钟文字 → 建议删掉', () {
      final p = _prompt([
        ('system', '当前时间是 08:30，你扮演艾琳。'),
        ('user', '你好'),
      ]);
      final report = PromptAudit.analyze(current: p, previous: p);
      expect(report.suggestions.join(), contains('时间/日期'));
    });

    test('摘要写在系统提示里且上次不同 → 提示摘要会作废缓存', () {
      final prev = _prompt([
        ('system', '设定\n【早期对话摘要】旧摘要'),
        ('user', '你好'),
      ]);
      final current = _prompt([
        ('system', '设定\n【早期对话摘要】新摘要'),
        ('user', '你好'),
      ]);
      final report = PromptAudit.analyze(current: current, previous: prev);
      expect(report.firstChangeIndex, 0);
      expect(report.suggestions.join(), contains('摘要'));
      expect(report.suggestions.join(), contains('系统提示'));
    });

    test('中间插入新段 → 建议挪到末尾', () {
      final prev = _prompt([
        ('system', '设定'),
        ('user', '第一句'),
        ('assistant', '第一答'),
      ]);
      final current = _prompt([
        ('system', '设定'),
        ('user', '第一句'),
        ('system', '作者注释：保持轻松'),
        ('assistant', '第一答'),
      ]);
      final report = PromptAudit.analyze(current: current, previous: prev);
      expect(report.suggestions.join(), contains('插在中间'));
      expect(report.suggestions.join(), contains('挪到末尾'));
    });

    test('段落数变化会给出解释', () {
      final prev = _prompt([
        ('system', '设定'),
        ('user', 'a'),
        ('assistant', 'b'),
        ('user', 'c'),
      ]);
      final current = _prompt([
        ('system', '设定'),
        ('user', 'a'),
      ]);
      final report = PromptAudit.analyze(current: current, previous: prev);
      expect(report.suggestions.join(), contains('段落数'));
    });

    test('接近窗口上限时提醒自动摘要', () {
      final p = _prompt([
        ('system', '设定'),
        ('user', '很长的一段话' * 30),
      ]);
      final report = PromptAudit.analyze(
        current: p,
        previous: p,
        contextWindow: 100,
      );
      expect(report.suggestions.join(), contains('自动摘要'));
    });

    test('没有明显问题时也给一句结论', () {
      final p = _prompt([
        ('system', '设定'),
        ('user', '你好'),
      ]);
      final report = PromptAudit.analyze(current: p, previous: p);
      expect(report.suggestions, isNotEmpty);
    });
  });

  group('提示词检视：省钱排序建议（v0.28.0）', () {
    test('推荐顺序覆盖 5 个阶段并带当前 token', () {
      final lines = PromptAudit.recommendedOrder(1234);
      expect(lines.length, 6);
      expect(lines.first, contains('系统提示'));
      expect(lines[3], contains('历史对话'));
      expect(lines[4], contains('最后放'));
      expect(lines.last, contains('1234'));
    });
  });

  group('提示词检视页面（v0.28.0）', () {
    testWidgets('渲染摘要与逐段明细，点开省钱排序', (tester) async {
      final prev = _prompt([
        ('system', '你是艾琳。'),
        ('user', '你好'),
        ('assistant', '你好呀'),
      ]);
      final current = [
        ...prev,
        const PromptMessage(role: 'user', content: '我们去酒馆吧'),
      ];
      await tester.pumpWidget(MaterialApp(
        home: PromptAuditScreen(current: current, previous: prev),
      ));
      expect(find.text('提示词检视'), findsOneWidget);
      expect(find.textContaining('共 4 段'), findsOneWidget);
      expect(find.text('系统提示'), findsOneWidget);
      expect(find.text('本轮新消息'), findsOneWidget);
      expect(find.textContaining('可复用'), findsWidgets);

      await tester.tap(find.byIcon(Icons.savings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('省钱排序建议'), findsOneWidget);
      expect(find.textContaining('越稳定越靠前'), findsOneWidget);
    });

    testWidgets('第一次发送也能打开页面', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: PromptAuditScreen(
          current: _prompt([
            ('system', '你是艾琳。'),
            ('user', '你好'),
          ]),
        ),
      ));
      expect(find.textContaining('第一次发送'), findsWidgets);
      expect(find.text('新增'), findsWidgets);
    });
  });
}
