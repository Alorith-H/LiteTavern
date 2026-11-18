import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:litetavern/screens/card_market_screen.dart';
import 'package:litetavern/services/card_export.dart';
import 'package:litetavern/services/card_importer.dart';
import 'package:litetavern/services/card_market.dart';
import 'package:litetavern/services/storage.dart';

/// v0.11.0 角色卡市场：请求地址、响应归一化、下载入库。
/// 网络用 http 自带的 MockClient（不依赖真实网络，测试可离线跑）。

/// Chub 搜索响应样例（字段按 2026-11 实测截取，含一个字段缺失的节点）。
const _searchBody = '''
{
  "data": {
    "count": 8593,
    "nodes": [
      {
        "id": 4337840,
        "name": "Tavern Manager",
        "fullPath": "Elefre/tavern-manager-a7f0",
        "description": "Run a tavern.\\nSecond line.",
        "tagline": "Run a tavern and send heroes on quests",
        "starCount": 95,
        "nTokens": 1350,
        "nChats": 101,
        "topics": ["Fantasy", "OC", ""],
        "nsfw_image": false,
        "avatar_url": "https://avatars.charhub.io/avatars/Elefre/tavern-manager-a7f0/avatar.webp",
        "max_res_url": "https://avatars.charhub.io/avatars/Elefre/tavern-manager-a7f0/chara_card_v2.png"
      },
      {
        "id": 7,
        "name": "Bare Card",
        "fullPath": "Someone/bare-card",
        "description": "",
        "tagline": null,
        "starCount": null,
        "topics": null,
        "nsfw_image": false
      },
      {
        "id": 8,
        "name": "",
        "fullPath": "Nobody/nameless",
        "max_res_url": "https://x/y.png"
      }
    ]
  }
}
''';

/// 最小 PNG（签名 + IHDR + IEND），供 embedCharaInPng 注入 chara 块。
Uint8List _minimalPng() {
  final out = BytesBuilder();
  out.add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final n = data.length;
    out.add(<int>[
      (n >> 24) & 0xFF,
      (n >> 16) & 0xFF,
      (n >> 8) & 0xFF,
      n & 0xFF,
    ]);
    out.add(type.codeUnits);
    out.add(data);
    out.add(const <int>[0, 0, 0, 0]);
  }

  chunk('IHDR', const <int>[0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]);
  chunk('IEND', const <int>[]);
  return out.toBytes();
}

Map<String, dynamic> _cardJson(String name) => <String, dynamic>{
  'spec': 'chara_card V2',
  'spec_version': '2.0',
  'data': <String, dynamic>{
    'name': name,
    'description': '来自市场的简介',
    'personality': '沉稳',
    'scenario': '酒馆',
    'first_mes': '晚上好。',
    'mes_example': '',
    'tags': <String>['Fantasy'],
  },
};

void main() {
  group('Chub 搜索请求地址', () {
    const source = ChubSource();

    test('带关键词：search/first/page/nsfw，按相关度排序（无 sort）', () {
      final uri = source.searchUri(query: '  love  ', page: 2);
      expect(uri.host, 'api.chub.ai');
      expect(uri.path, '/search');
      expect(uri.queryParameters['search'], 'love');
      expect(uri.queryParameters['first'], '${source.pageSize}');
      expect(uri.queryParameters['page'], '2');
      expect(uri.queryParameters['nsfw'], 'false');
      expect(uri.queryParameters.containsKey('sort'), isFalse);
    });

    test('空关键词（浏览）：带 sort=star_count 拿全站热门', () {
      final uri = source.searchUri(query: '', page: 1);
      expect(uri.queryParameters['search'], '');
      expect(uri.queryParameters['sort'], 'star_count');
    });
  });

  group('筛选条件（MarketFilters）', () {
    const source = ChubSource();

    test('sort 默认 relevance：有词不带 sort，空词仍浏览热门（旧行为不回归）', () {
      final withQuery = source.searchUri(query: '  love  ', page: 1);
      expect(withQuery.queryParameters['search'], 'love');
      expect(withQuery.queryParameters.containsKey('sort'), isFalse);

      final browse = source.searchUri(query: '   ', page: 1);
      expect(browse.queryParameters['sort'], 'star_count');
    });

    test('sort=popular → star_count（有关键词也以指定排序为准）', () {
      final uri = source.searchUri(
        query: 'love',
        page: 1,
        filters: const MarketFilters(sort: 'popular'),
      );
      expect(uri.queryParameters['sort'], 'star_count');
    });

    test('sort=newest → created_at（空关键词也以指定排序为准）', () {
      final uri = source.searchUri(
        query: '',
        page: 3,
        filters: const MarketFilters(sort: 'newest'),
      );
      expect(uri.queryParameters['sort'], 'created_at');
      expect(uri.queryParameters['page'], '3');
      expect(uri.queryParameters['nsfw'], 'false');
    });

    test('topics 逗号拼接（服务端 AND 语义）；无标签不带参数', () {
      final uri = source.searchUri(
        query: '',
        page: 1,
        filters: const MarketFilters(topics: ['Fantasy', 'OC']),
      );
      expect(uri.queryParameters['topics'], 'Fantasy,OC');

      final none = source.searchUri(query: '', page: 1);
      expect(none.queryParameters.containsKey('topics'), isFalse);
    });

    test('min/max tokens 映射 min_tokens / max_tokens（未设则不出现）', () {
      final both = source.searchUri(
        query: 'x',
        page: 1,
        filters: const MarketFilters(minTokens: 1000, maxTokens: 3000),
      );
      expect(both.queryParameters['min_tokens'], '1000');
      expect(both.queryParameters['max_tokens'], '3000');

      final onlyMin = source.searchUri(
        query: 'x',
        page: 1,
        filters: const MarketFilters(minTokens: 3001),
      );
      expect(onlyMin.queryParameters['min_tokens'], '3001');
      expect(onlyMin.queryParameters.containsKey('max_tokens'), isFalse);

      final none = source.searchUri(query: 'x', page: 1);
      expect(none.queryParameters.containsKey('min_tokens'), isFalse);
      expect(none.queryParameters.containsKey('max_tokens'), isFalse);
    });

    test('排序 + 标签 + 长度可叠加，且 nsfw 永远 false', () {
      final uri = source.searchUri(
        query: ' love ',
        page: 2,
        filters: const MarketFilters(
          sort: 'newest',
          topics: ['Fantasy', 'OC'],
          minTokens: 1000,
          maxTokens: 3000,
        ),
      );
      expect(uri.queryParameters['search'], 'love');
      expect(uri.queryParameters['page'], '2');
      expect(uri.queryParameters['first'], '${source.pageSize}');
      expect(uri.queryParameters['sort'], 'created_at');
      expect(uri.queryParameters['topics'], 'Fantasy,OC');
      expect(uri.queryParameters['min_tokens'], '1000');
      expect(uri.queryParameters['max_tokens'], '3000');
      expect(uri.queryParameters['nsfw'], 'false');
    });

    test('MarketFilters：默认值、==/hashCode、copyWith（含清空 tokens）', () {
      expect(const MarketFilters(), MarketFilters.none);
      expect(MarketFilters.none.isEmpty, isTrue);

      const f = MarketFilters(
        sort: 'popular',
        topics: ['Fantasy'],
        minTokens: 1000,
        maxTokens: 3000,
      );
      expect(f.isEmpty, isFalse);
      const same = MarketFilters(
        sort: 'popular',
        topics: ['Fantasy'],
        minTokens: 1000,
        maxTokens: 3000,
      );
      expect(f, same);
      expect(f.hashCode, same.hashCode);

      expect(f.copyWith(sort: 'relevance').sort, 'relevance');
      expect(f.copyWith(sort: 'relevance').topics, ['Fantasy']);
      final cleared = f.copyWith(minTokens: null, maxTokens: null);
      expect(cleared.minTokens, isNull);
      expect(cleared.maxTokens, isNull);
      expect(cleared.topics, ['Fantasy']);
    });

    test('parseTopics：中英文逗号、去空、去重（忽略大小写）、最多 3 个', () {
      expect(MarketFilters.parseTopics(' Fantasy , OC ,, fantasy '), [
        'Fantasy',
        'OC',
      ]);
      expect(MarketFilters.parseTopics('a，b，c，d'), ['a', 'b', 'c']);
      expect(MarketFilters.parseTopics('   '), isEmpty);
      expect(MarketFilters.parseTopics('Fantasy'), ['Fantasy']);
    });
  });

  group('CardMarketClient：筛选条件透传', () {
    /// 返回固定搜索响应，并记录请求 URL。
    (CardMarketClient, List<Uri>) mockClientUnderTest() {
      final seen = <Uri>[];
      final client = CardMarketClient(
        httpClient: MockClient((request) async {
          seen.add(request.url);
          return http.Response.bytes(
            utf8.encode(_searchBody),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      return (client, seen);
    }

    test('filters 被正确带进请求 URL（MockClient 断言，不联网）', () async {
      final (client, seen) = mockClientUnderTest();
      await client.search(
        query: 'tavern',
        page: 2,
        filters: const MarketFilters(
          sort: 'newest',
          topics: ['Fantasy', 'OC'],
          minTokens: 1000,
          maxTokens: 3000,
        ),
      );
      expect(seen, hasLength(1));
      final params = seen.single.queryParameters;
      expect(params['search'], 'tavern');
      expect(params['page'], '2');
      expect(params['sort'], 'created_at');
      expect(params['topics'], 'Fantasy,OC');
      expect(params['min_tokens'], '1000');
      expect(params['max_tokens'], '3000');
      expect(params['nsfw'], 'false');
      client.dispose();
    });

    test('不传 filters 时保持旧行为：无 topics/长度参数、空词热门', () async {
      final (client, seen) = mockClientUnderTest();
      await client.search(query: '', page: 1);
      final params = seen.single.queryParameters;
      expect(params['sort'], 'star_count');
      expect(params.containsKey('topics'), isFalse);
      expect(params.containsKey('min_tokens'), isFalse);
      expect(params.containsKey('max_tokens'), isFalse);
      client.dispose();
    });
  });

  group('搜索响应归一化', () {
    test('字段映射：作者取 fullPath 前缀、tagline/描述、统计数字', () {
      final page = const ChubSource().parseSearch(_searchBody);
      expect(page.total, 8593);
      expect(page.cards, hasLength(2)); // 无名字的节点被跳过
      final card = page.cards.first;
      expect(card.name, 'Tavern Manager');
      expect(card.creator, 'Elefre');
      expect(card.tagline, 'Run a tavern and send heroes on quests');
      expect(card.summary, 'Run a tavern and send heroes on quests');
      expect(card.stars, 95);
      expect(card.tokens, 1350);
      expect(card.chats, 101);
      expect(card.topics, ['Fantasy', 'OC']); // 空标签丢弃
      expect(card.nsfw, isFalse);
      expect(card.source, 'Chub.ai');
      expect(
        card.pageUrl,
        'https://chub.ai/characters/Elefre/tavern-manager-a7f0',
      );
      expect(
        card.downloadUrl,
        'https://avatars.charhub.io/avatars/Elefre/tavern-manager-a7f0/chara_card_v2.png',
      );
    });

    test('缺字段的节点：下载地址按 fullPath 兜底、统计为 0、summary 回退', () {
      final card = const ChubSource().parseSearch(_searchBody).cards[1];
      expect(card.name, 'Bare Card');
      expect(card.tagline, '');
      expect(card.summary, '（暂无简介）');
      expect(card.stars, 0);
      expect(card.tokens, 0);
      expect(card.topics, isEmpty);
      expect(
        card.downloadUrl,
        'https://avatars.charhub.io/avatars/Someone/bare-card/chara_card_v2.png',
      );
    });

    test('坏数据不整体失败：空 body / 非 JSON 抛可展示异常', () {
      expect(
        () => const ChubSource().parseSearch('not json'),
        throwsA(isA<CardMarketException>()),
      );
      final empty = const ChubSource().parseSearch(
        '{"data":{"count":0,"nodes":[]}}',
      );
      expect(empty.cards, isEmpty);
      expect(empty.total, 0);
    });
  });

  group('CardMarketClient：网络错误映射', () {
    test('HTTP 非 200 → 中文可展示异常', () async {
      final client = CardMarketClient(
        httpClient: MockClient((_) async => http.Response('oops', 500)),
      );
      expect(
        () => client.search(query: 'x', page: 1),
        throwsA(
          isA<CardMarketException>().having(
            (e) => e.message,
            'message',
            contains('500'),
          ),
        ),
      );
      client.dispose();
    });

    test('正常响应 → 解析出卡片（走 MockClient，不联网）', () async {
      final client = CardMarketClient(
        httpClient: MockClient((request) async {
          expect(request.url.queryParameters['nsfw'], 'false');
          return http.Response.bytes(
            utf8.encode(_searchBody),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final page = await client.search(query: 'tavern', page: 1);
      expect(page.cards, hasLength(2));
      expect(page.cards.first.name, 'Tavern Manager');
      client.dispose();
    });
  });

  group('下载入库（importCardBytes）', () {
    late Directory docs;

    setUp(() {
      docs = Directory.systemTemp.createTempSync('litetavern_market_test');
      Storage.initForTest(docs);
    });

    tearDown(() {
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });

    test('JSON 卡：解析后入库，出现在角色列表里', () async {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode(_cardJson('市场角色'))),
      );
      final card = await importCardBytes(bytes, filename: 'card.json');
      expect(card.id, isNotEmpty);
      expect(card.name, '市场角色');
      final all = await Storage.loadCharacters();
      expect(all.map((c) => c.name), contains('市场角色'));
    });

    test('PNG 卡（内嵌 chara）：入库同时保存头像原图', () async {
      final json = jsonEncode(_cardJson('PNG 角色'));
      final png = embedCharaInPng(_minimalPng(), json);
      final card = await importCardBytes(png, filename: 'x.png');
      expect(card.name, 'PNG 角色');
      expect(Storage.avatarFile(card.id), isNotNull);
      final all = await Storage.loadCharacters();
      expect(all.map((c) => c.name), contains('PNG 角色'));
    });

    test('无效字节：抛 FormatException（市场页展示解析失败）', () async {
      expect(
        () => importCardBytes(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('市场页筛选 UI（widget）', () {
    /// 首屏会发一次请求：测试环境里 dart:io 被 flutter_test 拦截并立即失败，
    /// 不会联网；筛选行不依赖请求结果，可直接断言。
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('筛选行：默认「相关」，切热门后出现「清除」，清除后复位', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CardMarketScreen()));
      await settle(tester);

      expect(find.text('相关'), findsOneWidget);
      expect(find.text('热门'), findsOneWidget);
      expect(find.text('新上架'), findsOneWidget);
      expect(find.text('标签'), findsOneWidget);
      expect(find.text('长度'), findsOneWidget);
      expect(find.text('清除'), findsNothing);

      final chips = tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .toList();
      expect(chips, hasLength(3));
      expect(chips.first.selected, isTrue);

      await tester.tap(find.widgetWithText(ChoiceChip, '热门'));
      await settle(tester);
      expect(find.text('清除'), findsOneWidget);
      expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .toList()[1]
            .selected,
        isTrue,
      );

      await tester.tap(find.widgetWithText(TextButton, '清除'));
      await settle(tester);
      expect(find.text('清除'), findsNothing);
      expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .toList()[0]
            .selected,
        isTrue,
      );
    });

    testWidgets('标签对话框（去空去重）与长度弹窗：结果回显在 chip 上', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CardMarketScreen()));
      await settle(tester);

      await tester.tap(find.widgetWithText(ActionChip, '标签'));
      await settle(tester);
      expect(find.text('标签筛选'), findsOneWidget);
      expect(find.text('英文标签，如 Fantasy,OC'), findsOneWidget);

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        ' Fantasy , OC ,, fantasy ',
      );
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await settle(tester);
      expect(find.text('标签：Fantasy+OC'), findsOneWidget);

      await tester.tap(find.widgetWithText(ActionChip, '长度'));
      await settle(tester);
      expect(find.text('按长度筛选'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, '中（1k–3k tokens）'));
      await settle(tester);
      expect(find.text('长度：中'), findsOneWidget);
      expect(find.text('清除'), findsOneWidget);
    });
  });
}
