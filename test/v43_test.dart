import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/app_info.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/whats_new.dart';
import 'package:litetavern/widgets/whats_new_dialog.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
  });

  test('当前版本有登记的更新说明', () {
    final entry = whatsNewFor(kAppVersion);
    expect(entry, isNotNull);
    expect(entry!.version, kAppVersion);
    expect(entry.title, isNotEmpty);
    expect(entry.bullets, isNotEmpty);
    expect(entry.bullets.length, lessThanOrEqualTo(5));
  });

  test('未知版本返回 null', () {
    expect(whatsNewFor('0.0.0-test'), isNull);
  });

  test('首次启动提示一次，记下版本后不再提示', () async {
    expect(AppSettings.lastSeenVersion, isNull);
    final before = pendingWhatsNew();
    expect(before, isNotNull);
    expect(before!.version, kAppVersion);

    await markWhatsNewSeen(kAppVersion);
    expect(AppSettings.lastSeenVersion, kAppVersion);
    expect(pendingWhatsNew(), isNull);
  });

  test('lastSeenVersion 可以清空', () async {
    await markWhatsNewSeen('0.42.0');
    expect(AppSettings.lastSeenVersion, '0.42.0');
    await markWhatsNewSeen('');
    expect(AppSettings.lastSeenVersion, isNull);
    expect(pendingWhatsNew(), isNotNull);
  });

  testWidgets('弹窗显示标题与要点，点「知道了」记为已读', (tester) async {
    final entry = whatsNewFor(kAppVersion)!;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF9C4632)),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showWhatsNewDialog(ctx, entry: entry),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(entry.title), findsOneWidget);
    expect(find.text('版本 ${entry.version}'), findsOneWidget);
    expect(find.text(entry.bullets.first), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text(entry.title), findsNothing);
    expect(AppSettings.lastSeenVersion, entry.version);
  });

  testWidgets('回看模式不写「已读过」', (tester) async {
    final entry = whatsNewFor(kAppVersion)!;
    await markWhatsNewSeen('0.42.0');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () =>
                    showWhatsNewDialog(ctx, entry: entry, markSeen: false),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('关闭'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(AppSettings.lastSeenVersion, '0.42.0');
  });
}
