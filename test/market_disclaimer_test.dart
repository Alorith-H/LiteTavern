import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:litetavern/screens/card_market_screen.dart';
import 'package:litetavern/screens/settings_screen.dart';
import 'package:litetavern/services/card_downloader.dart';
import 'package:litetavern/services/card_market.dart';
import 'package:litetavern/services/market_disclaimer.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/translator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 角色卡市场第三方内容免责声明（v0.45.0）的测试。
///
/// 覆盖三件事：
/// 1. 确认状态的存储语义（版本号、重启后仍在、reset、版本升级后重新提示）；
/// 2. 市场页首次进入的行为（先弹说明、同意才加载、不同意退出、已同意不再弹）；
/// 3. 设置二级页的入口（只读说明、没有「我了解并继续」、「重新确认」清状态）。
///
/// 全部离线：数据源用 [_FakeSource]，HTTP 用 [MockClient]，封面空串走占位图。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MarketDisclaimer.resetForTest();
    await AppSettings.init();
    Storage.initForTest(
      Directory.systemTemp.createTempSync('lt_market_disclaimer_'),
    );
  });

  group('MarketDisclaimer 存储', () {
    test('默认未确认', () async {
      expect(await MarketDisclaimer.hasAccepted(), isFalse);
      expect(await MarketDisclaimer.acceptedVersion(), 0);
      expect(await MarketDisclaimer.acceptedAt(), isNull);
    });

    test('确认后记下版本号与时间，重启后仍有效', () async {
      await MarketDisclaimer.accept();

      expect(await MarketDisclaimer.hasAccepted(), isTrue);
      expect(
        await MarketDisclaimer.acceptedVersion(),
        MarketDisclaimer.currentVersion,
      );
      expect(await MarketDisclaimer.acceptedAt(), isNotNull);

      // 模拟重启：清掉缓存句柄后重新读
      MarketDisclaimer.resetForTest();
      expect(await MarketDisclaimer.hasAccepted(), isTrue);
    });

    test('reset 后回到未确认', () async {
      await MarketDisclaimer.accept();
      await MarketDisclaimer.reset();

      expect(await MarketDisclaimer.hasAccepted(), isFalse);
      expect(await MarketDisclaimer.acceptedVersion(), 0);
      expect(await MarketDisclaimer.acceptedAt(), isNull);
    });

    test('只确认过旧版本说明的用户会重新看到提示', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        MarketDisclaimer.ackKey,
        MarketDisclaimer.currentVersion - 1,
      );

      expect(await MarketDisclaimer.hasAccepted(), isFalse);
    });

    test('确认版本高于当前版本时仍算已确认', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        MarketDisclaimer.ackKey,
        MarketDisclaimer.currentVersion + 1,
      );

      expect(await MarketDisclaimer.hasAccepted(), isTrue);
    });
  });

  group('首次进入角色卡市场', () {
    testWidgets('未确认时先弹说明，且还没加载列表', (tester) async {
      await tester.pumpWidget(_marketHost());
      await _openMarket(tester);

      expect(find.text('角色卡市场使用提示'), findsOneWidget);
      expect(find.text('我了解并继续'), findsOneWidget);
      expect(find.text('不同意'), findsOneWidget);
      expect(find.text('Alice'), findsNothing, reason: '同意前不加载数据');
    });

    testWidgets('说明文案覆盖第三方来源、免责与替代方案', (tester) async {
      await tester.pumpWidget(_marketHost());
      await _openMarket(tester);

      expect(find.textContaining('Chub.ai'), findsWidgets);
      expect(find.textContaining('由其他用户自行上传'), findsOneWidget);
      expect(find.textContaining('与本软件及其开发者无关'), findsOneWidget);
      expect(find.textContaining('不审核'), findsWidgets);
      expect(find.textContaining('AI 生成角色卡'), findsOneWidget);
      expect(find.textContaining('自行承担'), findsWidgets);
    });

    testWidgets('点「不同意」退出市场页，且不写确认状态', (tester) async {
      await tester.pumpWidget(_marketHost());
      await _openMarket(tester);

      await tester.tap(find.text('不同意'));
      await tester.pumpAndSettle();

      expect(find.byType(CardMarketScreen), findsNothing);
      expect(find.text('打开市场'), findsOneWidget);
      expect(await MarketDisclaimer.hasAccepted(), isFalse);
    });

    testWidgets('点「我了解并继续」后写确认状态并加载列表', (tester) async {
      await tester.pumpWidget(_marketHost());
      await _openMarket(tester);

      await tester.tap(find.text('我了解并继续'));
      await tester.pumpAndSettle();

      expect(await MarketDisclaimer.hasAccepted(), isTrue);
      expect(find.byType(CardMarketScreen), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('角色卡市场使用提示'), findsNothing, reason: '说明层已关闭');
    });

    testWidgets('已经同意过时直接加载，不再弹说明', (tester) async {
      await MarketDisclaimer.accept();

      await tester.pumpWidget(_marketHost());
      await tester.tap(find.text('打开市场'));
      await tester.pumpAndSettle();

      expect(find.text('我了解并继续'), findsNothing);
      expect(find.text('Alice'), findsOneWidget);
    });
  });

  group('设置页入口', () {
    testWidgets('「角色卡市场与翻译」里有免责声明入口，点开是只读说明', (tester) async {
      await tester.pumpWidget(_settingsHost());
      await tester.pumpAndSettle();

      expect(find.text('角色卡市场免责声明'), findsOneWidget);

      await tester.tap(find.text('角色卡市场免责声明'));
      await tester.pumpAndSettle();

      expect(find.text('关闭'), findsOneWidget);
      expect(find.text('重新确认'), findsOneWidget);
      expect(find.text('我了解并继续'), findsNothing, reason: '只读模式不提供同意按钮');
      expect(find.textContaining('当前状态'), findsOneWidget);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(find.text('关闭'), findsNothing);
      expect(await MarketDisclaimer.hasAccepted(), isFalse);
    });

    testWidgets('「重新确认」清掉确认状态，下次进市场会重新提示', (tester) async {
      await MarketDisclaimer.accept();
      await tester.pumpWidget(_settingsHost());
      await tester.pumpAndSettle();

      await tester.tap(find.text('角色卡市场免责声明'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已确认'), findsOneWidget);

      await tester.tap(find.text('重新确认'));
      await tester.pumpAndSettle();

      expect(await MarketDisclaimer.hasAccepted(), isFalse);
      expect(find.textContaining('已清除确认状态'), findsOneWidget);
    });
  });
}

/// 市场页的宿主：首页一个按钮 push 市场页，这样才能验证「不同意退出市场页」。
Widget _marketHost() {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CardMarketScreen(
                  client: CardMarketClient(
                    source: _FakeSource(),
                    httpClient: _mockHttp(),
                  ),
                  translator: TranslationService(
                    freeProviders: <TranslationProvider>[_FakeProvider()],
                    llm: _FakeProvider(label: 'Fake LLM'),
                  ),
                ),
              ),
            ),
            child: const Text('打开市场'),
          ),
        ),
      ),
    ),
  );
}

Widget _settingsHost() => MaterialApp(
  theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
  home: const SettingsScreen(section: SettingsSection.market),
);

/// 点「打开市场」并推进动画。
///
/// 注意不能 `pumpAndSettle`：说明层打开时市场页还在转加载圈（无限动画）。
Future<void> _openMarket(WidgetTester tester) async {
  await tester.tap(find.text('打开市场'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
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
  // 空串 → 封面走占位图，widget 测试里不会发网络请求
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

/// 固定的市场数据源：两张力卡，不发任何网络请求。
class _FakeSource implements CardMarketSource {
  final List<MarketCard> cards = <MarketCard>[
    _card(id: 'alice', name: 'Alice'),
    _card(id: 'bob', name: 'Bob'),
  ];

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
    bool showNsfw = false,
  }) => Uri.parse('https://example.test/search?page=$page');

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

/// 翻译源替身：不联网，原文加「译:」前缀。
class _FakeProvider extends TranslationProvider {
  _FakeProvider({this.label = 'Fake（免费）'});

  @override
  final String label;

  @override
  String get id => 'fake';

  @override
  bool get isFree => true;

  @override
  Future<String> translate(String text, {String target = 'zh-CN'}) async =>
      '译:$text';
}
