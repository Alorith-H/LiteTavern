import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/models/card_translation.dart';
import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/services/card_localizer.dart';
import 'package:litetavern/services/card_market.dart';
import 'package:litetavern/services/market_translation.dart';
import 'package:litetavern/services/translation_store.dart';
import 'package:litetavern/services/translator.dart';

/// 假翻译源：返回固定前缀译文，可配置抛错。
class _FakeProvider extends TranslationProvider {
  _FakeProvider(
    this.label, {
    this.isFree = true,
    this.prefix = '译:',
    this.fail = false,
  });

  @override
  final String label;
  @override
  final bool isFree;
  final String prefix;
  final bool fail;
  final List<String> calls = <String>[];

  @override
  String get id => label;

  @override
  Future<String> translate(String text, {String target = 'zh-CN'}) async {
    calls.add(text);
    if (fail) throw const TranslationFailure('假源失败');
    return '$prefix$text';
  }
}

CharacterCard _card({
  String name = '',
  String description = '',
  String personality = '',
  String scenario = '',
  String firstMes = '',
  String mesExample = '',
  List<String> tags = const <String>[],
  String id = '',
}) {
  return CharacterCard(
    name: name,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMes: firstMes,
    mesExample: mesExample,
    systemPrompt: '',
    alternateGreetings: const <String>[],
    tags: tags,
    creator: '',
    id: id,
  );
}

MarketCard _market({
  String id = '1',
  String name = '',
  String fullPath = 'a/b',
  String tagline = '',
  String description = '',
  List<String> topics = const <String>[],
}) {
  return MarketCard(
    id: id,
    name: name,
    creator: 'a',
    fullPath: fullPath,
    tagline: tagline,
    description: description,
    thumbnailUrl: '',
    downloadUrl: '',
    topics: topics,
    stars: 0,
    tokens: 0,
    chats: 0,
    nsfw: false,
    source: 'Chub.ai',
    pageUrl: '',
  );
}

void main() {
  group('文本工具', () {
    test('looksChinese：纯中文/纯英文/中英混排', () {
      expect(looksChinese('你好，世界'), isTrue);
      expect(looksChinese('Hello world'), isFalse);
      expect(looksChinese('这是一个 English 混排的简介'), isTrue);
      expect(looksChinese(''), isFalse);
      expect(looksChinese('AI'), isFalse);
    });

    test('splitForTranslation：不超长、内容顺序保留、超长句硬切', () {
      final short = '第一句。第二句。';
      expect(splitForTranslation(short), [short]);

      final long = '这是第一句。' * 60; // 每个 6 字 → 360 字
      final chunks = splitForTranslation(long, max: 100);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(100));
        expect(c.trim().isEmpty, isFalse);
      }
      expect(chunks.join(), long);

      final oneShot = 'A' * 1200;
      final hard = splitForTranslation(oneShot, max: 450);
      expect(hard.length, 3);
      expect(hard.every((c) => c.length <= 450), isTrue);
      expect(hard.join(), oneShot);
    });
  });

  group('MyMemoryProvider', () {
    test('解析 translatedText 并解开 HTML 实体', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'api.mymemory.translated.net');
        expect(req.url.queryParameters['langpair'], 'Autodetect|zh-CN');
        final body = jsonEncode({
          'responseData': {'translatedText': '他说&quot;你好&quot; &amp; 再见'},
          'responseStatus': 200,
          'quotaFinished': false,
        });
        return http.Response.bytes(utf8.encode(body), 200);
      });
      final t =
          await MyMemoryProvider(client: client).translate('He said "hi" & bye');
      expect(t, '他说"你好" & 再见');
    });

    test('额度用尽（QUERY LENGTH LIMIT）→ 抛 quotaExceeded', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({
              'responseData': {
                'translatedText':
                    'QUERY LENGTH LIMIT EXCEEDED. MAX ALLOWED QUERY : 500 CHARS',
              },
              'responseStatus': 200,
            }),
            200,
          ));
      await expectLater(
        MyMemoryProvider(client: client).translate('x'),
        throwsA(isA<TranslationFailure>()
            .having((e) => e.quotaExceeded, 'quotaExceeded', isTrue)),
      );
    });

    test('HTTP 500 → TranslationFailure', () async {
      final client = MockClient((req) async => http.Response('err', 500));
      await expectLater(
        MyMemoryProvider(client: client).translate('hello'),
        throwsA(isA<TranslationFailure>()),
      );
    });

    test('长文本按 ≤450 字符分多段请求', () async {
      final seen = <String>[];
      final client = MockClient((req) async {
        seen.add(req.url.queryParameters['q']!);
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'responseData': {'translatedText': '译'},
            'responseStatus': 200,
          })),
          200,
        );
      });
      final text = '长句测试。' * 120; // 600 字
      final out = await MyMemoryProvider(client: client).translate(text);
      expect(seen.length, greaterThan(1));
      expect(seen.every((q) => q.length <= 450), isTrue);
      expect(out.split('\n').length, seen.length);
    });
  });

  group('GoogleFreeProvider', () {
    test('解析嵌套数组', () async {
      final client = MockClient((req) async => http.Response.bytes(
            utf8.encode(jsonEncode([
              [
                ['你好世界', 'Hello world', null, null, 10],
                ['再见', 'Bye', null, null, 3],
              ],
              null,
              'en',
            ])),
            200,
          ));
      final t =
          await GoogleFreeProvider(client: client).translate('Hello world Bye');
      expect(t, '你好世界再见');
    });

    test('429 → quotaExceeded', () async {
      final client = MockClient((req) async => http.Response('too many', 429));
      await expectLater(
        GoogleFreeProvider(client: client).translate('hi'),
        throwsA(isA<TranslationFailure>()
            .having((e) => e.quotaExceeded, 'quotaExceeded', isTrue)),
      );
    });
  });

  group('BingWebProvider', () {
    setUp(BingWebProvider.resetCacheForTest);
    tearDown(BingWebProvider.resetCacheForTest);

    const pageHtml = '<html><script>'
        'var _G={IG:"A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6"};'
        'params_AbusePreventionHelper = [1712000000000,"tok-abc",3600000];'
        '</script></html>';

    test('先取令牌再 POST，解析 translations[0].text', () async {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add('${req.method} ${req.url.host}${req.url.path}');
        if (req.url.path == '/translator') {
          return http.Response.bytes(utf8.encode(pageHtml), 200);
        }
        expect(req.method, 'POST');
        expect(req.url.queryParameters['IG'], 'A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6');
        expect(req.body, contains('text=Hello'));
        expect(req.body, contains('to=zh-Hans'));
        expect(req.body, contains('token=tok-abc'));
        expect(req.body, contains('key=1712000000000'));
        return http.Response.bytes(
          utf8.encode(jsonEncode([
            {
              'detectedLanguage': {'language': 'en', 'score': 1.0},
              'translations': [
                {'text': '你好', 'to': 'zh-Hans'},
              ],
            }
          ])),
          200,
        );
      });
      final t = await BingWebProvider(client: client).translate('Hello');
      expect(t, '你好');
      expect(calls.length, 2);

      // 令牌缓存：第二次只发一次 POST，不再抓页面
      await BingWebProvider(client: client).translate('Hello again');
      expect(calls.length, 3);
      expect(calls.where((c) => c.startsWith('GET')).length, 1);
    });

    test('被要求人机验证 → quotaExceeded', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/translator') {
          return http.Response.bytes(utf8.encode(pageHtml), 200);
        }
        return http.Response.bytes(
          utf8.encode('{"ShowCaptcha":false}'),
          200,
        );
      });
      await expectLater(
        BingWebProvider(client: client).translate('hi'),
        throwsA(isA<TranslationFailure>()
            .having((e) => e.quotaExceeded, 'quotaExceeded', isTrue)),
      );
    });

    test('页面里取不到令牌 → TranslationFailure', () async {
      final client = MockClient(
        (req) async => http.Response.bytes(utf8.encode('<html>nope</html>'), 200),
      );
      await expectLater(
        BingWebProvider(client: client).translate('hi'),
        throwsA(isA<TranslationFailure>()),
      );
    });

    test('默认免费源顺序：Azure → 本地 LibreTranslate → 必应网页 → MyMemory → Google', () {
      final svc = TranslationService();
      expect(svc.freeProviders.map((p) => p.id).toList(),
          ['azure', 'libre', 'bing', 'mymemory', 'google']);
      expect(svc.freeProviders.every((p) => p.isFree), isTrue);
    });
  });

  group('AzureBingProvider', () {
    test('带 Key 请求 Azure 并解析译文', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response.bytes(
          utf8.encode(jsonEncode([
            {
              'translations': [
                {'text': '你好', 'to': 'zh-Hans'},
              ],
            }
          ])),
          200,
        );
      });
      final t = await AzureBingProvider(
        apiKey: 'azure-key',
        region: 'eastasia',
        client: client,
      ).translate('Hello');
      expect(t, '你好');
      expect(seen.method, 'POST');
      expect(seen.url.host, 'api.cognitive.microsofttranslator.com');
      expect(seen.url.queryParameters['to'], 'zh-Hans');
      expect(seen.headers['Ocp-Apim-Subscription-Key'], 'azure-key');
      expect(seen.headers['Ocp-Apim-Subscription-Region'], 'eastasia');
      expect(seen.body, contains('Hello'));
    });

    test('Key 无效（401）→ quotaExceeded', () async {
      final client = MockClient((req) async => http.Response('', 401));
      await expectLater(
        AzureBingProvider(apiKey: 'bad', region: '', client: client).translate('hi'),
        throwsA(isA<TranslationFailure>()
            .having((e) => e.quotaExceeded, 'quotaExceeded', isTrue)),
      );
    });

    test('没填 Key → 立刻失败（换下一个源）', () async {
      await expectLater(
        const AzureBingProvider(apiKey: '').translate('hi'),
        throwsA(isA<TranslationFailure>()),
      );
    });
  });

  group('LibreTranslateProvider', () {
    test('带地址请求 /translate 并解析译文', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response.bytes(
          utf8.encode(jsonEncode({'translatedText': '你好'})),
          200,
        );
      });
      final t = await LibreTranslateProvider(
        baseUrl: 'http://192.168.0.10:5000/',
        client: client,
      ).translate('Hello');
      expect(t, '你好');
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'http://192.168.0.10:5000/translate');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['q'], 'Hello');
      expect(body['source'], 'auto');
      expect(body['target'], 'zh');
      expect(body['format'], 'text');
      expect(body.containsKey('api_key'), isFalse);
    });

    test('填了 api_key 就带上；繁体目标映射成 zt', () async {
      late Map<String, dynamic> body;
      final client = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(
          utf8.encode(jsonEncode({'translatedText': '你好'})),
          200,
        );
      });
      await LibreTranslateProvider(
        baseUrl: 'http://localhost:5000',
        apiKey: 'k123',
        client: client,
      ).translate('Hello', target: 'zh-TW');
      expect(body['api_key'], 'k123');
      expect(body['target'], 'zt');
    });

    test('没填地址 → 立刻失败（换下一个源）', () async {
      await expectLater(
        const LibreTranslateProvider(baseUrl: '').translate('hi'),
        throwsA(isA<TranslationFailure>()),
      );
    });

    test('限流 429 → quotaExceeded', () async {
      final client = MockClient((req) async => http.Response('', 429));
      await expectLater(
        LibreTranslateProvider(baseUrl: 'http://x:5000', client: client)
            .translate('hi'),
        throwsA(isA<TranslationFailure>()
            .having((e) => e.quotaExceeded, 'quotaExceeded', isTrue)),
      );
    });

    test('返回 error 字段时把原因带出来', () async {
      final client = MockClient(
        (req) async => http.Response.bytes(
          utf8.encode(jsonEncode({'error': 'Invalid target language'})),
          200,
        ),
      );
      await expectLater(
        LibreTranslateProvider(baseUrl: 'http://x:5000', client: client)
            .translate('hi'),
        throwsA(isA<TranslationFailure>()
            .having((e) => e.message, 'message', contains('Invalid target'))),
      );
    });
  });

  group('TranslationService 调度', () {
    test('第一个源失败自动换第二个，并记住成功的源', () async {
      final bad = _FakeProvider('bad', fail: true);
      final good = _FakeProvider('good', prefix: 'G:');
      final svc = TranslationService(freeProviders: [bad, good]);

      final r1 = await svc.translateAll(['甲']);
      expect(r1.single.text, 'G:甲');
      expect(r1.single.provider, 'good');

      // 第二轮应优先用上次成功的源（bad 不再被调用）
      bad.calls.clear();
      final r2 = await svc.translateAll(['乙']);
      expect(r2.single.text, 'G:乙');
      expect(bad.calls, isEmpty);
    });

    test('免费全挂且不允许模型 → TranslationUnavailable 带 token 预估', () async {
      final svc = TranslationService(
        freeProviders: [_FakeProvider('bad', fail: true)],
      );
      await expectLater(
        svc.translateAll(['需要翻译的一段文字']),
        throwsA(isA<TranslationUnavailable>().having(
            (e) => e.estimatedTokens, 'estimatedTokens', greaterThan(0))),
      );
    });

    test('allowLlm: true 时免费全挂 → 改用 LLM 源', () async {
      final llm = _FakeProvider('llm', isFree: false, prefix: 'L:');
      final svc = TranslationService(
        freeProviders: [_FakeProvider('bad', fail: true)],
        llm: llm,
      );
      final r = await svc.translateAll(['一句话'], allowLlm: true);
      expect(r.single.text, 'L:一句话');
      expect(llm.calls, ['一句话']);
    });

    test('estimateTranslationTokens：空文本为 0，文本越长越高', () {
      expect(TranslationService.estimateTranslationTokens(['', '  ']), 0);
      final short = TranslationService.estimateTranslationTokens(['hello']);
      final long =
          TranslationService.estimateTranslationTokens(['hello ' * 100]);
      expect(long, greaterThan(short));
    });
  });

  group('TranslationStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TranslationStore.resetForTest();
    });

    test('角色译文读写 / 删除 / 原文备份', () async {
      const t = CardTranslation(
        name: '中文名',
        description: '中文简介',
        provider: 'MyMemory（免费）',
        updatedAt: 1,
      );
      await TranslationStore.saveCard('c1', t);

      final loaded = await TranslationStore.loadCard('c1');
      expect(loaded?.name, '中文名');
      expect(loaded?.provider, 'MyMemory（免费）');

      await TranslationStore.saveOriginalCard('c1', _card(name: 'Original', description: 'English desc', id: 'c1'));
      expect(await TranslationStore.hasOriginalCard('c1'), isTrue);
      final original = await TranslationStore.loadOriginalCard('c1');
      expect(original?.name, 'Original');

      await TranslationStore.removeCard('c1');
      expect(await TranslationStore.loadCard('c1'), isNull);
      expect(await TranslationStore.hasOriginalCard('c1'), isFalse);
    });

    test('市场译文缓存 + 按 updatedAt 淘汰（超过 400 条）', () async {
      expect(await TranslationStore.loadMarket('a/b'), isNull);
      await TranslationStore.saveMarket(
        'a/b',
        const MarketCardTranslation(name: '译名', provider: 'p', updatedAt: 5),
      );
      final cached = await TranslationStore.loadMarket('a/b');
      expect(cached?.name, '译名');

      // 写 450 条 → 触发淘汰，总数 <= 400
      for (var i = 0; i < 450; i++) {
        await TranslationStore.saveMarket(
          'x/$i',
          MarketCardTranslation(name: 'n$i', updatedAt: i),
        );
      }
      var alive = 0;
      for (var i = 0; i < 450; i++) {
        if (await TranslationStore.loadMarket('x/$i') != null) alive++;
      }
      expect(alive, lessThanOrEqualTo(400));
      expect(await TranslationStore.loadMarket('x/449'), isNotNull);
    });

    test('损坏的 JSON 不影响读取', () async {
      SharedPreferences.setMockInitialValues({
        'card_translations': '{not json',
      });
      TranslationStore.resetForTest();
      expect(await TranslationStore.loadCard('c1'), isNull);
    });
  });

  group('CardLocalizer', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TranslationStore.resetForTest();
    });

    test('翻译字段、写译文与原文备份', () async {
      final svc = TranslationService(
        freeProviders: [_FakeProvider('fake', prefix: '【译】')],
      );
      final card = _card(
        name: 'Alice',
        description: 'A friendly AI.',
        personality: 'kind',
        scenario: 'room',
        firstMes: 'Hello!',
        mesExample: 'user: hi\nchar: hi',
        tags: const ['Fantasy', 'OC'],
        id: 'card1',
      );

      final out = await CardLocalizer(translator: svc).localize(card);

      expect(out.name, '【译】Alice');
      expect(out.description, '【译】A friendly AI.');
      expect(out.firstMes, '【译】Hello!');
      // 标签整串翻译（'Fantasy, OC' → '【译】Fantasy, OC'）后按逗号拆回；真实 API 会给出「奇幻, 原创」
      expect(out.tags, ['【译】Fantasy', 'OC']);
      expect(out.id, 'card1');

      final stored = await TranslationStore.loadCard('card1');
      expect(stored?.name, '【译】Alice');
      expect(stored?.provider, 'fake');

      final backup = await TranslationStore.loadOriginalCard('card1');
      expect(backup?.name, 'Alice');
      expect(backup?.description, 'A friendly AI.');
    });

    test('estimateTokens 随文本增长', () {
      final small = _card(name: 'A', description: 'b');
      final big = _card(name: 'A', description: 'x long description ' * 50);
      expect(
        CardLocalizer.estimateTokens(big),
        greaterThan(CardLocalizer.estimateTokens(small)),
      );
    });

    test('空字段不发请求：只有 name 时只请求一次', () async {
      final provider = _FakeProvider('fake');
      final svc = TranslationService(freeProviders: [provider]);
      final out =
          await CardLocalizer(translator: svc).localize(_card(name: 'Zed', id: 'c9'));
      expect(out.name, '译:Zed');
      expect(provider.calls.length, 1);
    });
  });

  group('MarketTranslationService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TranslationStore.resetForTest();
    });

    test('翻译名字/简介/标签并写入缓存', () async {
      final svc = MarketTranslationService(
        translator: TranslationService(
          freeProviders: [_FakeProvider('fake', prefix: '中:')],
        ),
      );
      final card = _market(
        name: 'Elf Queen',
        description: 'An elf queen.',
        topics: const ['Fantasy', 'OC'],
      );

      final t = await svc.translate(card);
      expect(t.name, '中:Elf Queen');
      expect(t.description, '中:An elf queen.');
      expect(t.tags, ['中:Fantasy', 'OC']);
      expect(t.provider, 'fake');

      final cached = await svc.cached(card);
      expect(cached?.name, '中:Elf Queen');
    });

    test('splitTranslatedTags 容忍中英文标点', () {
      expect(splitTranslatedTags('奇幻, 原创、冒险；日常'), ['奇幻', '原创', '冒险', '日常']);
      expect(splitTranslatedTags('  '), isEmpty);
    });

    test('estimateTokensFor 汇总多张卡', () {
      final cards = <MarketCard>[
        _market(name: 'A', description: 'desc', topics: const ['Fantasy']),
      ];
      expect(MarketTranslationService.estimateTokensFor(cards), greaterThan(0));
    });
  });
}
