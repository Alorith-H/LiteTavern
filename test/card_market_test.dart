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
    out.add(<int>[(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF]);
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
      expect(card.pageUrl, 'https://chub.ai/characters/Elefre/tavern-manager-a7f0');
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
      final empty = const ChubSource().parseSearch('{"data":{"count":0,"nodes":[]}}');
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
}
