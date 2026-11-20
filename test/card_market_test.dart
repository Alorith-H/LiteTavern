import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:litetavern/services/card_export.dart';
import 'package:litetavern/services/card_importer.dart';
import 'package:litetavern/services/card_market.dart';
import 'package:litetavern/services/storage.dart';

/// v0.11.0 角色卡市场：请求地址、筛选参数映射、标签目录、响应归一化、下载入库。
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

/// Chub 标签目录响应样例（POST /tags，按热度降序；含缺 count / 空 name 的节点）。
const _tagsBody = '''
{
  "count": 500,
  "tags": [
    {"id": 9, "name": "NSFW", "non_private_projects_count": 516158, "title": "NSFW"},
    {"id": 12, "name": "Fantasy", "non_private_projects_count": 123456, "title": "Fantasy"},
    {"id": 15, "name": "Sci-Fi"},
    {"id": 16, "name": "", "non_private_projects_count": 3}
  ]
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

/// 取请求头（不依赖 http 的 header 大小写归一化行为）。
String _header(Map<String, String> headers, String name) => headers.entries
    .firstWhere(
      (e) => e.key.toLowerCase() == name.toLowerCase(),
      orElse: () => const MapEntry<String, String>('', ''),
    )
    .value;

void main() {
  group('Chub 搜索请求地址', () {
    const source = ChubSource();

    test('带关键词：search/first/page/nsfw=true，按相关度排序（无 sort/asc）', () {
      final uri = source.searchUri(query: '  love  ', page: 2);
      expect(uri.host, 'api.chub.ai');
      expect(uri.path, '/search');
      expect(uri.queryParameters['search'], 'love');
      expect(uri.queryParameters['first'], '${source.pageSize}');
      expect(uri.queryParameters['page'], '2');
      expect(uri.queryParameters['nsfw'], 'true');
      expect(uri.queryParameters.containsKey('sort'), isFalse);
      expect(uri.queryParameters.containsKey('asc'), isFalse);
    });

    test('空关键词（浏览）：不带 search，带 sort=star_count 拿全站热门', () {
      final uri = source.searchUri(query: '   ', page: 1);
      expect(uri.queryParameters.containsKey('search'), isFalse);
      expect(uri.queryParameters['sort'], 'star_count');
      expect(uri.queryParameters['nsfw'], 'true');
    });
  });

  group('筛选条件（MarketFilters → 查询参数）', () {
    const source = ChubSource();

    test('sort 映射：popular/newest/trending/random/name', () {
      const expected = <String, String>{
        'popular': 'star_count',
        'newest': 'created_at',
        'trending': 'trending',
        'random': 'random',
        'name': 'name',
      };
      for (final entry in expected.entries) {
        final uri = source.searchUri(
          query: 'love',
          page: 1,
          filters: MarketFilters(sort: entry.key),
        );
        expect(uri.queryParameters['sort'], entry.value, reason: entry.key);
      }
    });

    test('sort 默认 relevance：有词不带 sort，空词兜底 star_count（浏览不回归）', () {
      final withQuery = source.searchUri(query: '  love  ', page: 1);
      expect(withQuery.queryParameters['search'], 'love');
      expect(withQuery.queryParameters.containsKey('sort'), isFalse);

      final browse = source.searchUri(query: '   ', page: 1);
      expect(browse.queryParameters['sort'], 'star_count');
    });

    test('ascending：只有最终带了 sort 才附 asc=true', () {
      final popular = source.searchUri(
        query: 'love',
        page: 1,
        filters: const MarketFilters(sort: 'popular', ascending: true),
      );
      expect(popular.queryParameters['sort'], 'star_count');
      expect(popular.queryParameters['asc'], 'true');

      // 空关键词浏览 + 升序：兜底 star_count 也算「有 sort」
      final browse = source.searchUri(
        query: '',
        page: 1,
        filters: const MarketFilters(ascending: true),
      );
      expect(browse.queryParameters['sort'], 'star_count');
      expect(browse.queryParameters['asc'], 'true');

      // relevance + 有关键词 = 无 sort，asc 也不该出现
      final relevance = source.searchUri(
        query: 'love',
        page: 1,
        filters: const MarketFilters(ascending: true),
      );
      expect(relevance.queryParameters.containsKey('sort'), isFalse);
      expect(relevance.queryParameters.containsKey('asc'), isFalse);
    });

    test('tags / exclude_tags 逗号拼接（AND / 排除），空列表不带参数', () {
      final uri = source.searchUri(
        query: '',
        page: 1,
        filters: const MarketFilters(
          tags: ['Fantasy', 'OC'],
          excludeTags: ['Horror', 'Gore'],
        ),
      );
      expect(uri.queryParameters['tags'], 'Fantasy,OC');
      expect(uri.queryParameters['exclude_tags'], 'Horror,Gore');

      final none = source.searchUri(query: '', page: 1);
      expect(none.queryParameters.containsKey('tags'), isFalse);
      expect(none.queryParameters.containsKey('exclude_tags'), isFalse);
    });

    test('language：非空才带（trim）', () {
      final zh = source.searchUri(
        query: 'x',
        page: 1,
        filters: const MarketFilters(language: 'zh'),
      );
      expect(zh.queryParameters['language'], 'zh');

      final blank = source.searchUri(
        query: 'x',
        page: 1,
        filters: const MarketFilters(language: '   '),
      );
      expect(blank.queryParameters.containsKey('language'), isFalse);
    });

    test('min/max tokens 与 min_tags：仅在 > 0 时出现', () {
      final all = source.searchUri(
        query: 'x',
        page: 1,
        filters: const MarketFilters(
          minTokens: 1000,
          maxTokens: 3000,
          minTags: 2,
        ),
      );
      expect(all.queryParameters['min_tokens'], '1000');
      expect(all.queryParameters['max_tokens'], '3000');
      expect(all.queryParameters['min_tags'], '2');

      final zeros = source.searchUri(
        query: 'x',
        page: 1,
        filters: const MarketFilters(minTokens: 0, maxTokens: 0, minTags: 0),
      );
      expect(zeros.queryParameters.containsKey('min_tokens'), isFalse);
      expect(zeros.queryParameters.containsKey('max_tokens'), isFalse);
      expect(zeros.queryParameters.containsKey('min_tags'), isFalse);

      final none = source.searchUri(query: 'x', page: 1);
      expect(none.queryParameters.containsKey('min_tokens'), isFalse);
      expect(none.queryParameters.containsKey('max_tokens'), isFalse);
      expect(none.queryParameters.containsKey('min_tags'), isFalse);
    });

    test('require_images / require_lore / require_expressions 开关', () {
      final on = source.searchUri(
        query: 'x',
        page: 1,
        filters: const MarketFilters(
          requireImages: true,
          requireLore: true,
          requireExpressions: true,
        ),
      );
      expect(on.queryParameters['require_images'], 'true');
      expect(on.queryParameters['require_lore'], 'true');
      expect(on.queryParameters['require_expressions'], 'true');

      final off = source.searchUri(query: 'x', page: 1);
      expect(
        off.queryParameters.keys.where((k) => k.startsWith('require_')),
        isEmpty,
      );
    });

    test('全部筛选叠加，且 nsfw 固定 true（含全部内容）', () {
      final uri = source.searchUri(
        query: ' love ',
        page: 2,
        filters: const MarketFilters(
          sort: 'trending',
          ascending: true,
          tags: ['Fantasy', 'OC'],
          excludeTags: ['Horror'],
          language: 'en',
          minTokens: 1000,
          maxTokens: 3000,
          minTags: 2,
          requireImages: true,
          requireLore: true,
          requireExpressions: true,
        ),
      );
      expect(uri.queryParameters['search'], 'love');
      expect(uri.queryParameters['page'], '2');
      expect(uri.queryParameters['first'], '${source.pageSize}');
      expect(uri.queryParameters['sort'], 'trending');
      expect(uri.queryParameters['asc'], 'true');
      expect(uri.queryParameters['tags'], 'Fantasy,OC');
      expect(uri.queryParameters['exclude_tags'], 'Horror');
      expect(uri.queryParameters['language'], 'en');
      expect(uri.queryParameters['min_tokens'], '1000');
      expect(uri.queryParameters['max_tokens'], '3000');
      expect(uri.queryParameters['min_tags'], '2');
      expect(uri.queryParameters['require_images'], 'true');
      expect(uri.queryParameters['require_lore'], 'true');
      expect(uri.queryParameters['require_expressions'], 'true');
      expect(uri.queryParameters['nsfw'], 'true');
    });
  });

  group('MarketFilters：值对象 / 解析', () {
    test('默认值 = none 且 isEmpty；任一字段非默认则 isEmpty=false', () {
      expect(const MarketFilters(), MarketFilters.none);
      expect(MarketFilters.none.isEmpty, isTrue);
      expect(MarketFilters.none.isNotEmpty, isFalse);

      const variants = <MarketFilters>[
        MarketFilters(sort: 'popular'),
        MarketFilters(ascending: true),
        MarketFilters(tags: ['Fantasy']),
        MarketFilters(excludeTags: ['Horror']),
        MarketFilters(language: 'zh'),
        MarketFilters(minTokens: 1),
        MarketFilters(maxTokens: 1),
        MarketFilters(minTags: 1),
        MarketFilters(requireImages: true),
        MarketFilters(requireLore: true),
        MarketFilters(requireExpressions: true),
      ];
      for (final f in variants) {
        expect(f.isEmpty, isFalse);
        expect(f.isNotEmpty, isTrue);
      }
    });

    test('==/hashCode：所有字段参与（列表比较内容，不比较实例）', () {
      const a = MarketFilters(
        sort: 'popular',
        ascending: true,
        tags: ['Fantasy'],
        excludeTags: ['Horror'],
        language: 'en',
        minTokens: 1000,
        maxTokens: 3000,
        minTags: 2,
        requireImages: true,
        requireLore: true,
        requireExpressions: true,
      );
      final b = MarketFilters(
        sort: 'popular',
        ascending: true,
        tags: <String>['Fantasy'],
        excludeTags: <String>['Horror'],
        language: 'en',
        minTokens: 1000,
        maxTokens: 3000,
        minTags: 2,
        requireImages: true,
        requireLore: true,
        requireExpressions: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      for (final changed in <MarketFilters>[
        a.copyWith(sort: 'newest'),
        a.copyWith(ascending: false),
        a.copyWith(tags: ['OC']),
        a.copyWith(excludeTags: ['Gore']),
        a.copyWith(language: 'zh'),
        a.copyWith(minTokens: 1),
        a.copyWith(maxTokens: 1),
        a.copyWith(minTags: 1),
        a.copyWith(requireImages: false),
        a.copyWith(requireLore: false),
        a.copyWith(requireExpressions: false),
      ]) {
        expect(changed == a, isFalse);
      }
    });

    test('copyWith：可空字段用哨兵（不传=保留，显式 null=清空）', () {
      const f = MarketFilters(
        sort: 'popular',
        ascending: true,
        tags: ['Fantasy'],
        excludeTags: ['Horror'],
        language: 'en',
        minTokens: 1000,
        maxTokens: 3000,
        minTags: 2,
        requireImages: true,
      );

      final kept = f.copyWith(sort: 'newest');
      expect(kept.sort, 'newest');
      expect(kept.ascending, isTrue);
      expect(kept.tags, ['Fantasy']);
      expect(kept.excludeTags, ['Horror']);
      expect(kept.language, 'en');
      expect(kept.minTokens, 1000);
      expect(kept.maxTokens, 3000);
      expect(kept.minTags, 2);
      expect(kept.requireImages, isTrue);

      final cleared = f.copyWith(minTokens: null, maxTokens: null, minTags: null);
      expect(cleared.minTokens, isNull);
      expect(cleared.maxTokens, isNull);
      expect(cleared.minTags, isNull);
      expect(cleared.tags, ['Fantasy']); // 其它字段不受影响

      final replaced = f.copyWith(
        tags: ['OC'],
        excludeTags: <String>[],
        language: '',
        ascending: false,
        requireImages: false,
      );
      expect(replaced.tags, ['OC']);
      expect(replaced.excludeTags, isEmpty);
      expect(replaced.language, '');
      expect(replaced.ascending, isFalse);
      expect(replaced.requireImages, isFalse);
      expect(replaced.minTokens, 1000); // 未传的仍保留
    });

    test('topics 旧名兼容：getter 与 copyWith(topics:) 等价 tags', () {
      // 旧名 getter（@Deprecated，仅此处验证兼容性）
      // ignore: deprecated_member_use_from_same_package
      expect(const MarketFilters(tags: ['Fantasy']).topics, ['Fantasy']);
      final f = MarketFilters.none.copyWith(topics: const ['Fantasy', 'OC']);
      expect(f.tags, ['Fantasy', 'OC']);
    });

    test('parseTags：中英文逗号/顿号、去空、去重（忽略大小写）、max 上限', () {
      expect(MarketFilters.parseTags(' Fantasy , OC ,, fantasy '), [
        'Fantasy',
        'OC',
      ]);
      expect(MarketFilters.parseTags('a，b、c'), ['a', 'b', 'c']);
      expect(MarketFilters.parseTags('   '), isEmpty);
      expect(MarketFilters.parseTags('Fantasy'), ['Fantasy']);
      expect(MarketFilters.parseTags('a,b,c,d,e', max: 2), ['a', 'b']);
      // 默认上限 8 个
      expect(
        MarketFilters.parseTags('a,b,c,d,e,f,g,h,i,j'),
        hasLength(8),
      );
    });

    test('parseTopics 旧名保留（默认上限 3）', () {
      expect(MarketFilters.parseTopics(' Fantasy , OC ,, fantasy '), [
        'Fantasy',
        'OC',
      ]);
      expect(MarketFilters.parseTopics('a，b，c，d'), ['a', 'b', 'c']);
      expect(MarketFilters.parseTopics('   '), isEmpty);
      expect(MarketFilters.parseTopics('a,b,c,d,e', max: 5), hasLength(5));
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
          sort: 'trending',
          ascending: true,
          tags: ['Fantasy', 'OC'],
          excludeTags: ['Horror'],
          language: 'ja',
          minTokens: 1000,
          maxTokens: 3000,
          minTags: 2,
          requireImages: true,
          requireLore: true,
          requireExpressions: true,
        ),
      );
      expect(seen, hasLength(1));
      final params = seen.single.queryParameters;
      expect(params['search'], 'tavern');
      expect(params['page'], '2');
      expect(params['sort'], 'trending');
      expect(params['asc'], 'true');
      expect(params['tags'], 'Fantasy,OC');
      expect(params['exclude_tags'], 'Horror');
      expect(params['language'], 'ja');
      expect(params['min_tokens'], '1000');
      expect(params['max_tokens'], '3000');
      expect(params['min_tags'], '2');
      expect(params['require_images'], 'true');
      expect(params['require_lore'], 'true');
      expect(params['require_expressions'], 'true');
      expect(params['nsfw'], 'true');
      client.dispose();
    });

    test('不传 filters 时保持旧行为：无 search/筛选参数、空词热门', () async {
      final (client, seen) = mockClientUnderTest();
      await client.search(query: '', page: 1);
      final params = seen.single.queryParameters;
      expect(params.containsKey('search'), isFalse);
      expect(params['sort'], 'star_count');
      expect(params.containsKey('tags'), isFalse);
      expect(params.containsKey('exclude_tags'), isFalse);
      expect(params.containsKey('language'), isFalse);
      expect(params.containsKey('min_tokens'), isFalse);
      expect(params.containsKey('max_tokens'), isFalse);
      expect(params.containsKey('min_tags'), isFalse);
      expect(params['nsfw'], 'true');
      client.dispose();
    });
  });

  group('标签目录（MarketTag / fetchTags）', () {
    test('POST /tags：method/URL/body 正确，解析 name/count 且保持响应顺序', () async {
      http.Request? seen;
      final source = ChubSource(
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response.bytes(
            utf8.encode(_tagsBody),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

      final tags = await source.fetchTags(limit: 30);

      expect(seen, isNotNull);
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.chub.ai/tags');
      expect(_header(seen!.headers, 'content-type'), contains('application/json'));
      expect(jsonDecode(seen!.body), {'first': 30});
      // name 为空/缺失的节点被跳过；顺序与响应一致
      expect(tags.map((t) => t.name).toList(), ['NSFW', 'Fantasy', 'Sci-Fi']);
      expect(tags.map((t) => t.count).toList(), [516158, 123456, 0]);
    });

    test('默认 limit=200 会写进 body', () async {
      http.Request? seen;
      final source = ChubSource(
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response.bytes(utf8.encode(_tagsBody), 200);
        }),
      );
      await source.fetchTags();
      expect(jsonDecode(seen!.body), {'first': 200});
    });

    test('HTTP 500 → 返回内置兜底列表，不抛异常', () async {
      final source = ChubSource(
        httpClient: MockClient((_) async => http.Response('oops', 500)),
      );
      expect(await source.fetchTags(), ChubSource.fallbackTags);
    });

    test('坏 JSON → 返回内置兜底列表，不抛异常', () async {
      final source = ChubSource(
        httpClient: MockClient((_) async => http.Response('not json', 200)),
      );
      expect(await source.fetchTags(), ChubSource.fallbackTags);
    });

    test('兜底列表：英文原名、count 全 0、无重复、含常见标签', () {
      expect(ChubSource.fallbackTags.length, greaterThanOrEqualTo(30));
      expect(
        ChubSource.fallbackTags.map((t) => t.name),
        containsAll(<String>[
          'Fantasy',
          'Sci-Fi',
          'OC',
          'Anime',
          'RPG',
          'Romance',
          'Roleplay',
          'Isekai',
        ]),
      );
      expect(ChubSource.fallbackTags.every((t) => t.count == 0), isTrue);
      final names = ChubSource.fallbackTags.map((t) => t.name).toList();
      expect(names.toSet(), hasLength(names.length));
    });

    test('MarketTag：值相等（name + count）', () {
      expect(
        const MarketTag(name: 'Fantasy', count: 3),
        const MarketTag(name: 'Fantasy', count: 3),
      );
      expect(
        const MarketTag(name: 'Fantasy'),
        isNot(const MarketTag(name: 'Fantasy', count: 1)),
      );
      expect(const MarketTag(name: 'Fantasy').count, 0);
    });

    test('CardMarketClient.fetchTags 走 source（MockClient），关闭后给兜底', () async {
      final mock = MockClient(
        (_) async => http.Response.bytes(utf8.encode(_tagsBody), 200),
      );
      final client = CardMarketClient(
        source: ChubSource(httpClient: mock),
        httpClient: mock,
      );
      final tags = await client.fetchTags(limit: 5);
      expect(tags.map((t) => t.name).toList(), ['NSFW', 'Fantasy', 'Sci-Fi']);

      client.dispose();
      // 关闭后不抛异常，直接给兜底列表
      expect(await client.fetchTags(), ChubSource.fallbackTags);
    });

    test('CardMarketClient.fetchTags：source 抛异常时给兜底，不抛', () async {
      final client = CardMarketClient(
        source: _ThrowingTagsSource(),
        httpClient: MockClient((_) async => http.Response('', 200)),
      );
      expect(await client.fetchTags(), ChubSource.fallbackTags);
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
          expect(request.url.queryParameters['nsfw'], 'true');
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
}

/// 只用于验证 [CardMarketClient.fetchTags] 的异常兜底：fetchTags 必抛。
class _ThrowingTagsSource implements CardMarketSource {
  @override
  String get name => 'Fake';

  @override
  String get siteUrl => 'https://example.com';

  @override
  int get pageSize => 24;

  @override
  Uri searchUri({
    required String query,
    required int page,
    MarketFilters filters = MarketFilters.none,
  }) => Uri.parse('https://example.com/search');

  @override
  MarketSearchPage parseSearch(String body) =>
      const MarketSearchPage(total: 0, cards: <MarketCard>[]);

  @override
  Future<Uint8List> download(MarketCard card) async => Uint8List(0);

  @override
  Future<List<MarketTag>> fetchTags({int limit = 200}) async =>
      throw const CardMarketException('boom');
}
