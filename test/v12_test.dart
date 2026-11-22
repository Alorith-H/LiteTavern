import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/services/api_presets.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/reply_suggestions.dart';
import 'package:litetavern/services/sampling_params.dart';
import 'package:litetavern/services/storage.dart';

void main() {
  // ---------------------------------------------- 建议采样参数派生 --
  group('SamplingParams.forCandidate', () {
    test('默认参数 + seed 为空：三条建议都是默认参数（请求不带高级字段）', () {
      const base = SamplingParams();
      for (var i = 0; i < 3; i++) {
        final p = base.forCandidate(i);
        expect(p.seed, isNull);
        expect(p.isDefault, isTrue);
      }
    });

    test('seed 已设置时按序号偏移（+0/+1/+2），其它字段原样保留', () {
      const base = SamplingParams(
        frequencyPenalty: 0.5,
        presencePenalty: 0.25,
        repetitionPenalty: 1.1,
        topK: 20,
        minP: 0.05,
        seed: 7,
        stop: ['停'],
      );
      final a = base.forCandidate(0);
      final b = base.forCandidate(1);
      final c = base.forCandidate(2);
      expect([a.seed, b.seed, c.seed], [7, 8, 9]);
      for (final p in [a, b, c]) {
        expect(p.frequencyPenalty, 0.5);
        expect(p.presencePenalty, 0.25);
        expect(p.repetitionPenalty, 1.1);
        expect(p.topK, 20);
        expect(p.minP, 0.05);
        expect(p.stop, ['停']);
        expect(p.isDefault, isFalse);
      }
      // 原对象不受影响
      expect(base.seed, 7);
    });
  });

  // ------------------------------------------------ 输入辅助方式（v0.18.0）--
  group('设置：输入辅助方式（assistMode）', () {
    test('全新安装默认关闭辅助（off）', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      expect(AppSettings.assistMode, AssistMode.off);
      expect(AppSettings.autoReplyCandidates, isFalse);
    });

    test('切到建议回复 / 替我说一句都会落盘并读回', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();

      AppSettings.assistMode = AssistMode.suggestions;
      var sp = await SharedPreferences.getInstance();
      expect(sp.getString('assist_mode'), 'suggestions');
      expect(AppSettings.assistMode, AssistMode.suggestions);
      expect(AppSettings.autoReplyCandidates, isTrue);

      AppSettings.assistMode = AssistMode.impersonate;
      sp = await SharedPreferences.getInstance();
      expect(sp.getString('assist_mode'), 'impersonate');
      expect(AppSettings.assistMode, AssistMode.impersonate);
      // 替我说一句模式下，旧开关语义 = 不建议回复
      expect(AppSettings.autoReplyCandidates, isFalse);

      AppSettings.assistMode = AssistMode.off;
      expect(AppSettings.assistMode, AssistMode.off);
    });

    test('旧数据只有 auto_reply_candidates 时按旧开关映射', () async {
      SharedPreferences.setMockInitialValues({'auto_reply_candidates': true});
      await AppSettings.init();
      expect(AppSettings.assistMode, AssistMode.suggestions);

      SharedPreferences.setMockInitialValues({'auto_reply_candidates': false});
      await AppSettings.init();
      expect(AppSettings.assistMode, AssistMode.off);
    });

    test('旧数据无任何相关键时回落到关闭（不误开自动建议）', () async {
      SharedPreferences.setMockInitialValues({'streaming': false});
      await AppSettings.init();
      expect(AppSettings.autoReplyCandidates, isFalse);
      expect(AppSettings.assistMode, AssistMode.off);
      expect(AppSettings.streaming, isFalse);
    });
  });

  // ------------------------------------------- 上下文长度（v0.20.0 起跟模型走） --
  group('设置：上下文长度按模型自动（v0.20.0）', () {
    test('全新安装按当前模型自动推断', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      expect(AppSettings.contextWindow, contextWindowForModel(AppSettings.model));
    });

    test('显式写入后覆盖自动值，并可读回', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      AppSettings.contextWindow = 32000;
      expect(AppSettings.contextWindow, 32000);
      await AppSettings.init();
      expect(AppSettings.contextWindow, 32000);
    });

    test('切换模型后，自动值跟着模型变', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init();
      AppSettings.contextWindow = 0; // 回到自动
      AppSettings.model = 'glm-4-flash';
      expect(AppSettings.contextWindow, 128000);
      AppSettings.model = 'gpt-4o-mini';
      expect(AppSettings.contextWindow, 128000);
    });

    test('旧的全局键只清理、不影响结果', () async {
      SharedPreferences.setMockInitialValues({
        'model_context_window': 32000,
      });
      await AppSettings.init();
      expect(AppSettings.contextWindow, contextWindowForModel(AppSettings.model));
    });
  });

  // ------------------------------------------ 建议请求的 messages 组装 --
  group('建议请求：appendSuggestionInstruction', () {
    test('在末尾追加一条 user 角色指令，原 messages 不被修改', () {
      const base = [
        PromptMessage(role: 'system', content: '你是助手'),
        PromptMessage(role: 'assistant', content: '你好'),
      ];

      final out = appendSuggestionInstruction(base);

      expect(out.length, base.length + 1);
      expect(out.last.role, 'user');
      // v0.14.0：指令后追加本条建议的语气/风格要求
      expect(out.last.content, startsWith(kSuggestionInstruction));
      expect(out.last.content, contains(kSuggestionStyles[0]));
      // 前两条原样保留、顺序不变
      expect(out[0].role, 'system');
      expect(out[0].content, '你是助手');
      expect(out[1].role, 'assistant');
      // 指令里明确要求「以用户身份」并「只输出这句话」
      expect(kSuggestionInstruction.contains('用户'), isTrue);
      expect(kSuggestionInstruction.contains('只输出'), isTrue);
    });

    test('空对话也能组装出单条指令', () {
      final out = appendSuggestionInstruction(const []);
      expect(out.length, 1);
      expect(out.single.role, 'user');
    });

    // v0.14.0：一批三条要三种风格，避免三条意思雷同
    test('同一批的三条建议使用不同风格指令', () {
      final contents = [
        for (var i = 0; i < kSuggestionStyles.length; i++)
          appendSuggestionInstruction(const [], styleIndex: i).single.content,
      ];
      expect(contents.toSet().length, kSuggestionStyles.length);
      for (var i = 0; i < kSuggestionStyles.length; i++) {
        expect(contents[i], contains(kSuggestionStyles[i]));
      }
    });

    test('styleIndex 越界时取模，始终带风格要求', () {
      final wrapped = appendSuggestionInstruction(
        const [],
        styleIndex: kSuggestionStyles.length,
      ).single.content;
      final first = appendSuggestionInstruction(const []).single.content;
      expect(wrapped, first);
    });
  });

  // ------------------------------------------------ 建议文本清洗 --
  group('建议文本清洗：normalizeSuggestion', () {
    test('去首尾空白、换行压成单行', () {
      expect(normalizeSuggestion('  今晚的酒不错\n\n要不要再来一杯？ '),
          '今晚的酒不错 要不要再来一杯？');
    });

    test('去掉「建议：」「用户回复：」等前缀', () {
      expect(normalizeSuggestion('建议：走吧'), '走吧');
      expect(normalizeSuggestion('用户回复: 我等你'), '我等你');
      expect(normalizeSuggestion('回复：好'), '好');
    });

    test('去掉成对包裹的引号（中英文都处理）', () {
      expect(normalizeSuggestion('"今晚不醉不归"'), '今晚不醉不归');
      expect(normalizeSuggestion('“那就明天见”'), '那就明天见');
      expect(normalizeSuggestion('「再来一杯」'), '再来一杯');
      // 只去掉成对首尾，句中引号保留
      expect(normalizeSuggestion('他说"好"，我笑了'), '他说"好"，我笑了');
    });

    test('空串 / 纯空白返回空', () {
      expect(normalizeSuggestion(''), '');
      expect(normalizeSuggestion('   \n\t '), '');
    });
  });

  group('建议文本清洗：normalizeSuggestions', () {
    test('丢弃空串、按原文去重（保序）', () {
      final out = normalizeSuggestions([
        ' 好 ',
        '',
        '好',
        '建议：走吧',
        '   ',
        '再来一杯',
      ]);
      expect(out, ['好', '走吧', '再来一杯']);
    });

    test('全部无效时返回空列表', () {
      expect(normalizeSuggestions(['', '  ', '\n']), isEmpty);
    });

    // v0.14.0：差不多的两条只留一条，避免三个选项看起来一样
    test('高度相似的长句只保留第一条', () {
      final out = normalizeSuggestions([
        '我觉得我们还是先离开这里吧',
        '我觉得我们还是先离开这里吧。',
        '那我去叫车',
      ]);
      expect(out, ['我觉得我们还是先离开这里吧', '那我去叫车']);
    });

    test('短句只按完全相同去重', () {
      expect(normalizeSuggestions(['嗯', '嗯嗯', '嗯']), ['嗯', '嗯嗯']);
    });
  });
}
