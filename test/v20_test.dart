import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/services/api_client.dart';
import 'package:litetavern/services/api_presets.dart';
import 'package:litetavern/services/storage.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
  });

  // ------------------------------------------------ 预设：GLM-4-Flash 第一 --
  group('API 预设（v0.20.0）', () {
    test('智谱 GLM-4-Flash 排第一，且标记为免费', () {
      expect(kApiPresets, isNotEmpty);
      final first = kApiPresets.first;
      expect(first.model, 'glm-4-flash');
      expect(first.free, isTrue);
      expect(first.baseUrl, contains('bigmodel.cn'));
      expect(first.contextWindow, 128000);
    });

    test('每个预设都有可用的官网与 Key 链接，上下文长度为正', () {
      for (final p in kApiPresets) {
        expect(Uri.tryParse(p.siteUrl)?.hasScheme, isTrue, reason: p.label);
        expect(Uri.tryParse(p.keyUrl)?.hasScheme, isTrue, reason: p.label);
        expect(p.contextWindow, greaterThan(0), reason: p.label);
      }
    });

    test('只有 GLM-4-Flash 是免费预设', () {
      final free = kApiPresets.where((p) => p.free).toList();
      expect(free.map((p) => p.model), ['glm-4-flash']);
    });
  });

  // -------------------------------------------- 上下文长度：按模型推断 --
  group('contextWindowForModel', () {
    test('常见模型各自的窗口', () {
      expect(contextWindowForModel('glm-4-flash'), 128000);
      expect(contextWindowForModel('glm-4-air'), 128000);
      expect(contextWindowForModel('glm-5'), 200000);
      expect(contextWindowForModel('deepseek-chat'), 65536);
      expect(contextWindowForModel('kimi-k2'), 131072);
      expect(contextWindowForModel('gpt-4o-mini'), 128000);
      expect(contextWindowForModel('gpt-5'), 200000);
      expect(contextWindowForModel('gemini-2.5-pro'), 1000000);
      expect(contextWindowForModel('claude-3-7-sonnet'), 200000);
      expect(contextWindowForModel('qwen-plus'), 131072);
      expect(contextWindowForModel('llama3.1'), 32768);
    });

    test('模型名里的 -Nk 后缀优先', () {
      expect(contextWindowForModel('moonshot-v1-8k'), 8192);
      expect(contextWindowForModel('moonshot-v1-128k'), 131072);
      expect(contextWindowForModel('my-model-32k'), 32768);
    });

    test('空模型名回落到 fallback', () {
      expect(contextWindowForModel(''), 65536);
      expect(contextWindowForModel('unknown-model'), 65536);
      expect(contextWindowForModel('unknown-model', fallback: 4096), 4096);
    });

    test('越大越好：同一模型不因大小写失效', () {
      expect(contextWindowForModel('GLM-4-Flash'), 128000);
      expect(contextWindowForModel('DeepSeek-Chat'), 65536);
    });
  });

  group('formatContextWindow', () {
    test('K / M / 原值 / 自动', () {
      expect(formatContextWindow(0), '自动');
      expect(formatContextWindow(-5), '自动');
      expect(formatContextWindow(512), '512');
      expect(formatContextWindow(8192), '8K');
      expect(formatContextWindow(128000), '128K');
      expect(formatContextWindow(131072), '128K');
      expect(formatContextWindow(1000000), '1M');
      expect(formatContextWindow(2000000), '2M');
    });
  });

  // ------------------------------------------------ 模型列表：解析响应 --
  group('ApiClient.extractModelIds', () {
    test('OpenAI 风格 data[].id', () {
      final ids = ApiClient.extractModelIds(jsonEncode({
        'object': 'list',
        'data': [
          {'id': 'glm-4-flash'},
          {'id': 'glm-4-air'},
        ],
      }));
      expect(ids, ['glm-4-air', 'glm-4-flash']);
    });

    test('字符串数组 + 去重 + 排序', () {
      final ids = ApiClient.extractModelIds(
        jsonEncode(['b', 'a', 'b']),
      );
      expect(ids, ['a', 'b']);
    });

    test('models / items / list 各种包装', () {
      expect(
        ApiClient.extractModelIds(jsonEncode({
          'models': [
            {'name': 'x'},
            {'model': 'y'},
          ],
        })),
        ['x', 'y'],
      );
      expect(
        ApiClient.extractModelIds(jsonEncode({
          'data': ['only'],
        })),
        ['only'],
      );
      expect(
        ApiClient.extractModelIds(jsonEncode({
          'list': [
            {'id': 'z'},
          ],
        })),
        ['z'],
      );
    });

    test('坏 JSON / 空对象 → 空列表', () {
      expect(ApiClient.extractModelIds('not json'), isEmpty);
      expect(ApiClient.extractModelIds('{}'), isEmpty);
    });
  });

  // ------------------------------- /models 自报的上下文长度（v0.21.1） --
  group('ApiClient.extractModelInfos', () {
    test('OpenRouter 风格 context_length', () {
      final models = ApiClient.extractModelInfos(jsonEncode({
        'data': [
          {'id': 'openai/gpt-4o', 'context_length': 128000},
          {'id': 'anthropic/claude-3.5', 'context_length': 200000},
        ],
      }));
      expect(models.map((m) => m.id).toList(), [
        'anthropic/claude-3.5',
        'openai/gpt-4o',
      ]);
      expect(models.first.contextWindow, 200000);
      expect(models.last.contextWindow, 128000);
    });

    test('其它常见字段名 / 字符串数字 / 缺字段', () {
      final models = ApiClient.extractModelInfos(jsonEncode({
        'models': [
          {'id': 'a', 'context_window': 65536},
          {'id': 'b', 'max_model_len': '32768'},
          {'id': 'c', 'max_input_tokens': 131072},
          {'id': 'd', 'n_ctx': 8192.0},
          {'id': 'e'},
          {'id': 'f', 'max_tokens': 4096},
        ],
      }));
      final byId = {for (final m in models) m.id: m.contextWindow};
      expect(byId['a'], 65536);
      expect(byId['b'], 32768);
      expect(byId['c'], 131072);
      expect(byId['d'], 8192);
      expect(byId['e'], isNull);
      // max_tokens 通常是「输出上限」，不当上下文用
      expect(byId['f'], isNull);
    });

    test('同 id 出现多次时，后到的自报值补上', () {
      final models = ApiClient.extractModelInfos(jsonEncode([
        {'id': 'x'},
        {'id': 'x', 'context_length': 4096},
      ]));
      expect(models.length, 1);
      expect(models.single.contextWindow, 4096);
    });
  });

  // ---------------------------------------- ApiConfig.contextWindow 持久化 --
  group('ApiConfig.contextWindow（v0.20.0）', () {
    test('默认 0 = 按模型自动；JSON 往返保留', () {
      const cfg = ApiConfig(id: 'a', name: '默认');
      expect(cfg.contextWindow, 0);
      final back = ApiConfig.fromJson(cfg.toJson());
      expect(back.contextWindow, 0);
      expect(back.model, '');
    });

    test('写入 128000 后读回，copyWith 可清回自动', () {
      const cfg = ApiConfig(id: 'a', name: 'n', contextWindow: 128000);
      expect(ApiConfig.fromJson(cfg.toJson()).contextWindow, 128000);
      expect(cfg.copyWith(contextWindow: 0).contextWindow, 0);
    });

    test('脏数据回落 0，超范围被钳制', () {
      expect(
        ApiConfig.fromJson({'id': 'a', 'name': 'n', 'contextWindow': 'many'})
            .contextWindow,
        0,
      );
      expect(
        ApiConfig.fromJson({'id': 'a', 'name': 'n', 'contextWindow': -1})
            .contextWindow,
        0,
      );
    });
  });

  // ----------------------------------- AppSettings 读写：手填覆盖自动 --
  group('AppSettings.contextWindow 与模型联动', () {
    test('手填覆盖后，切模型仍是手填值', () {
      AppSettings.contextWindow = 64000;
      AppSettings.model = 'glm-4-flash';
      expect(AppSettings.contextWindow, 64000);
    });

    test('清空（0）后重新按模型自动', () {
      AppSettings.contextWindow = 64000;
      AppSettings.contextWindow = 0;
      AppSettings.model = 'glm-4-flash';
      expect(AppSettings.contextWindow, 128000);
      expect(AppSettings.autoContextWindowFor('glm-4-flash'), 128000);
    });
  });
}
