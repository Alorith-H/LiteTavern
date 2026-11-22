import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/services/api_presets.dart';
import 'package:litetavern/services/summarize.dart';

void main() {
  group('服务商预设（v0.15.0 跳官网）', () {
    test('每个预设都有可用的官网 / 获取 Key / 文档地址', () {
      expect(kApiPresets, isNotEmpty);
      for (final p in kApiPresets) {
        expect(p.label.trim(), isNotEmpty, reason: '${p.label} 缺 label');
        expect(p.baseUrl.trim(), isNotEmpty, reason: '${p.label} 缺 baseUrl');
        expect(p.model.trim(), isNotEmpty, reason: '${p.label} 缺 model');
        expect(p.siteUrl.trim(), isNotEmpty, reason: '${p.label} 缺官网');
        expect(p.keyUrl.trim(), isNotEmpty, reason: '${p.label} 缺 Key 页');
        expect(p.note.trim(), isNotEmpty, reason: '${p.label} 缺说明');

        final site = Uri.parse(p.siteUrl);
        final key = Uri.parse(p.keyUrl);
        expect(site.hasScheme && site.host.isNotEmpty, isTrue,
            reason: '${p.label} 官网地址不合法：${p.siteUrl}');
        expect(key.hasScheme && key.host.isNotEmpty, isTrue,
            reason: '${p.label} Key 地址不合法：${p.keyUrl}');
        expect(key.scheme, anyOf('http', 'https'),
            reason: '${p.label} Key 地址缺 http(s)');
      }
    });

    test('presetForBaseUrl 忽略尾部斜杠，未知地址返回 null', () {
      expect(presetForBaseUrl('https://api.deepseek.com/v1')?.label, 'DeepSeek');
      expect(presetForBaseUrl('https://api.deepseek.com/v1/')?.label, 'DeepSeek');
      expect(presetForBaseUrl('  https://api.deepseek.com/v1//  ')?.label,
          'DeepSeek');
      expect(presetForBaseUrl('https://example.com/v1'), isNull);
      expect(presetForBaseUrl(''), isNull);
    });
  });

  group('摘要进度提示（v0.15.0）', () {
    test('两种原因的文案不同且带上条数', () {
      final history = summaryProgressText(
        reason: SummaryReason.historyWindow,
        earlyCount: 12,
      );
      final budget = summaryProgressText(
        reason: SummaryReason.contextBudget,
        earlyCount: 12,
      );
      expect(history, contains('12'));
      expect(budget, contains('12'));
      expect(history, isNot(budget));
      expect(history, contains('摘要'));
      expect(budget, contains('上下文'));
    });

    test('副标题都提到本地记录不变 / 继续发送', () {
      for (final reason in SummaryReason.values) {
        final hint = summaryProgressHint(reason: reason);
        expect(hint.trim(), isNotEmpty);
        expect(hint, contains('本地聊天记录不变'));
      }
    });

    test('历史窗口原因的解释包含上限与条数，且说明不是额度问题', () {
      final paragraphs = summaryWhyParagraphs(
        reason: SummaryReason.historyWindow,
        historyLimit: 20,
        earlyCount: 7,
      );
      final all = paragraphs.join('\n');
      expect(all, contains('20'));
      expect(all, contains('7'));
      expect(all, contains('记忆长度'));
      expect(all, contains('不是你的模型额度不够'));
      expect(all, contains('本机的聊天记录'));
      expect(all, contains('长对话自动摘要'));
    });

    test('上下文预算原因的解释包含窗口与估算 token', () {
      final paragraphs = summaryWhyParagraphs(
        reason: SummaryReason.contextBudget,
        historyLimit: 20,
        earlyCount: 7,
        contextWindow: 65536,
        estimatedTokens: 60000,
      );
      final all = paragraphs.join('\n');
      expect(all, contains('60000'));
      expect(all, contains('65536'));
      expect(all, contains('模型上下文窗口'));
    });
  });
}
