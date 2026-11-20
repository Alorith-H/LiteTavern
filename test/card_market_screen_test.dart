import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:litetavern/models/card_translation.dart';
import 'package:litetavern/screens/card_market_screen.dart';
import 'package:litetavern/services/card_downloader.dart';
import 'package:litetavern/services/card_market.dart';
import 'package:litetavern/services/translation_store.dart';
import 'package:litetavern/services/translator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 角色卡市场页（v0.11.x 单列改版）的 widget 测试。
///
/// 全部离线：数据源用 [_FakeSource]（search 返回固定卡片），
/// HTTP 用 http 自带的 [MockClient]，翻译用 [_FakeProvider]，
/// 封面用空 thumbnailUrl 走占位图，避免 Image.network 发请求。

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TranslationStore.resetForTest();
  });

  testWidgets('加载后以单列列表显示角色卡（不再是网格）', (tester) async {
    final source = _FakeSource();
    await _pumpScreen(tester, source);

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(ListView), findsWidgets);
  });

  testWidgets('有缓存译文时列表直接显示译名与译文简介', (tester) async {
    await TranslationStore.saveMarket(
      'writer/alice',
      const MarketCardTranslation(
        name: '爱丽丝',
        description: '缓存的译文简介',
        tags: <String>['奇幻'],
        provider: 'test',
        updatedAt: 1,
      ),
    );
    final source = _FakeSource();
    await _pumpScreen(tester, source);

    expect(find.text('爱丽丝'), findsOneWidget);
    expect(find.text('缓存的译文简介'), findsOneWidget);
    expect(find.text('奇幻'), findsOneWidget);
  });

  testWidgets('筛选弹层改排序后按新的 MarketFilters 重新搜索', (tester) async {
    final source = _FakeSource();
    await _pumpScreen(tester, source);
    expect(source.filters.last.sort, 'relevance');

    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '热门'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '应用'));
    await tester.pumpAndSettle();

    expect(source.filters.last.sort, 'popular');
    expect(source.pages.last, 1);
  });

  testWidgets('点行内「译」后该行显示译名', (tester) async {
    final source = _FakeSource();
    await _pumpScreen(tester, source);
    expect(find.text('译:Alice'), findsNothing);

    await tester.tap(find.text('译').first);
    await tester.pumpAndSettle();

    expect(find.text('译:Alice'), findsOneWidget);
  });

  testWidgets('免费翻译不可用时弹报价确认框', (tester) async {
    final source = _FakeSource();
    final translator = TranslationService(
      freeProviders: <TranslationProvider>[_FakeProvider(failFree: true)],
      llm: _FakeProvider(label: 'Fake LLM'),
    );
    await _pumpScreen(tester, source, translator: translator);

    await tester.tap(find.text('译').first);
    await tester.pumpAndSettle();

    expect(find.text('免费翻译暂不可用'), findsOneWidget);
    expect(find.textContaining('tokens'), findsWidgets);
    expect(find.textContaining('设置中的模型'), findsWidgets);
  });

  testWidgets('空结果显示空态', (tester) async {
    final source = _FakeSource(initialCards: const <MarketCard>[]);
    await _pumpScreen(tester, source);

    expect(find.text('没有找到角色卡'), findsOneWidget);
  });
}

/// 把 [CardMarketScreen] 挂到 MaterialApp 里并等首屏加载完。
Future<void> _pumpScreen(
  WidgetTester tester,
  _FakeSource source, {
  TranslationService? translator,
}) async {
  final service = translator ??
      TranslationService(
        freeProviders: <TranslationProvider>[_FakeProvider()],
        llm: _FakeProvider(label: 'Fake LLM'),
      );
  await tester.pumpWidget(
    MaterialApp(
      home: CardMarketScreen(
        client: CardMarketClient(source: source, httpClient: _mockHttp()),
        translator: service,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 市场搜索的 HTTP 替身：固定 200 + 空 JSON（解析交给 fake source）。
http.Client _mockHttp() => MockClient(
  (_) async => http.Response('{}', 200, headers: const <String, String>{
    'content-type': 'application/json',
  }),
);

MarketCard _card({required String id, required String name}) => MarketCard(
  id: id,
  name: name,
  creator: 'writer',
  fullPath: 'writer/$id',
  tagline: '$name 的一句话简介',
  description: '$name 的详细描述',
  // 空串 → MarketCover 走占位图，widget 测试里不会发网络请求
  thumbnailUrl: '',
  downloadUrl: 'https://example.test/$id.png',
  topics: const <String>['Fantasy', 'OC'],
  stars: 1200,
  tokens: 900,
  chats: 34,
  nsfw: false,
  source: 'Fake',
  pageUrl: 'https://example.test/$id',
);

List<MarketCard> _fakeCards() => <MarketCard>[
  _card(id: 'alice', name: 'Alice'),
  _card(id: 'bob', name: 'Bob'),
];

/// 固定的市场数据源：记录每次查询用到的关键词/页码/筛选条件。
class _FakeSource implements CardMarketSource {
  _FakeSource({List<MarketCard>? initialCards})
    : cards = initialCards ?? _fakeCards();

  final List<MarketCard> cards;

  final List<String> queries = <String>[];
  final List<int> pages = <int>[];
  final List<MarketFilters> filters = <MarketFilters>[];

  @override
  String get name => 'Fake';

  @override
  String get siteUrl => 'https://example.test';

  @override
  int get pageSize => 24;

  @override
  Uri searchUri({
    required String query,
    required int page,
    MarketFilters filters = MarketFilters.none,
  }) {
    queries.add(query);
    pages.add(page);
    this.filters.add(filters);
    return Uri.parse('https://example.test/search?page=$page');
  }

  @override
  MarketSearchPage parseSearch(String body) =>
      MarketSearchPage(total: cards.length, cards: cards);

  @override
  Future<Uint8List> download(
    MarketCard card, {
    DownloadProgressCallback? onProgress,
  }) async => Uint8List(0);

  @override
  Future<List<MarketTag>> fetchTags({int limit = 200}) async =>
      const <MarketTag>[
        MarketTag(name: 'Fantasy', count: 10),
        MarketTag(name: 'Sci-Fi', count: 5),
      ];
}

/// 翻译源替身：成功时给原文加「译:」前缀；[failFree] 时抛「免费不可用」。
class _FakeProvider extends TranslationProvider {
  _FakeProvider({this.failFree = false, this.label = 'Fake（免费）'});

  final bool failFree;

  @override
  final String label;

  @override
  String get id => 'fake';

  @override
  bool get isFree => true;

  @override
  Future<String> translate(String text, {String target = 'zh-CN'}) async {
    if (failFree) {
      throw const TranslationUnavailable(
        '免费翻译暂不可用',
        estimatedTokens: 1234,
      );
    }
    return '译:$text';
  }
}
