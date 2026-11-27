import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:litetavern/services/apk_installer.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/updater.dart';
import 'package:litetavern/widgets/update_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';

UpdateInfo _info({int size = 1234567, String apk = 'https://example.com/app-release.apk'}) {
  return UpdateInfo(
    version: '0.23.0',
    tag: 'v0.23.0',
    notes: '### 更新\n- 自动更新',
    apkUrl: apk,
    apkSize: size,
    pageUrl: 'https://github.com/Alorith-H/LiteTavern/releases/tag/v0.23.0',
    publishedAt: DateTime.utc(2026, 11, 27),
  );
}

String _releaseJson({
  String tag = 'v0.23.0',
  bool draft = false,
  bool prerelease = false,
  List<Map<String, Object>>? assets,
  String body = '更新说明',
}) {
  return jsonEncode({
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'body': body,
    'html_url': 'https://github.com/Alorith-H/LiteTavern/releases/tag/$tag',
    'published_at': '2026-11-27T09:00:00Z',
    'assets': assets ??
        [
          {
            'name': 'app-release.apk',
            'size': 62123456,
            'browser_download_url': 'https://github.com/x/app-release.apk',
          },
        ],
  });
}

/// 只查版本、不下载的假服务。
class _FakeUpdateService extends UpdateService {
  _FakeUpdateService({this.info, this.error});

  final UpdateInfo? info;
  final String? error;

  @override
  Future<UpdateInfo?> checkForUpdate({String currentVersion = '0.0.0'}) async {
    if (error != null) throw UpdateCheckException(error!);
    return info;
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
  });

  group('compareVersions（版本比较）', () {
    test('新版 > 旧版、同版相等、带 v 前缀与后缀都能处理', () {
      expect(compareVersions('0.23.0', '0.22.0'), greaterThan(0));
      expect(compareVersions('v0.23.0', '0.23.0'), 0);
      expect(compareVersions('0.23', '0.23.0'), 0);
      expect(compareVersions('1.0.0', '0.99.99'), greaterThan(0));
      expect(compareVersions('0.22.0', '0.23.0'), lessThan(0));
      expect(compareVersions('0.23.0-beta', '0.23.0'), 0);
      expect(compareVersions(' v1.2.3 ', '1.2.2'), greaterThan(0));
    });
  });

  group('formatBytes（体积文案）', () {
    test('常用档位', () {
      expect(formatBytes(0), '未知大小');
      expect(formatBytes(900), '900 B');
      expect(formatBytes(59 * 1024 * 1024), '59.0 MB');
      expect(formatBytes(1024), '1.0 KB');
    });
  });

  group('UpdateService.parseRelease（解析 GitHub Release）', () {
    test('有新版 + APK 附件 → UpdateInfo', () {
      final info = UpdateService.parseRelease(_releaseJson(), currentVersion: '0.22.0')!;
      expect(info.version, '0.23.0');
      expect(info.tag, 'v0.23.0');
      expect(info.hasApk, isTrue);
      expect(info.apkUrl, 'https://github.com/x/app-release.apk');
      expect(info.apkSize, 62123456);
      expect(info.pageUrl, contains('/releases/tag/v0.23.0'));
      expect(info.publishedAt, isNotNull);
    });

    test('同版本或更旧版本 → null', () {
      expect(UpdateService.parseRelease(_releaseJson(), currentVersion: '0.23.0'), isNull);
      expect(UpdateService.parseRelease(_releaseJson(tag: 'v0.21.9'), currentVersion: '0.23.0'), isNull);
    });

    test('草稿 / 预发布 → null', () {
      expect(UpdateService.parseRelease(_releaseJson(draft: true), currentVersion: '0.22.0'), isNull);
      expect(
        UpdateService.parseRelease(_releaseJson(prerelease: true), currentVersion: '0.22.0'),
        isNull,
      );
    });

    test('没有 APK 附件时仍返回信息，但 hasApk=false', () {
      final info = UpdateService.parseRelease(
        _releaseJson(assets: [
          {'name': 'source.zip', 'size': 10, 'browser_download_url': 'https://github.com/x/source.zip'},
        ]),
        currentVersion: '0.22.0',
      )!;
      expect(info.hasApk, isFalse);
      expect(info.apkUrl, isEmpty);
    });

    test('多个 APK 时优先 app-release.apk', () {
      final info = UpdateService.parseRelease(
        _releaseJson(assets: [
          {'name': 'other.apk', 'size': 1, 'browser_download_url': 'https://github.com/x/other.apk'},
          {'name': 'app-release.apk', 'size': 2, 'browser_download_url': 'https://github.com/x/app-release.apk'},
        ]),
        currentVersion: '0.22.0',
      )!;
      expect(info.apkUrl, 'https://github.com/x/app-release.apk');
    });

    test('坏 JSON → UpdateCheckException', () {
      expect(
        () => UpdateService.parseRelease('not-json', currentVersion: '0.22.0'),
        throwsA(isA<UpdateCheckException>()),
      );
    });
  });

  group('UpdateService.checkForUpdate（网络）', () {
    test('200 且版本更新 → 返回 UpdateInfo', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/repos/Alorith-H/LiteTavern/releases/latest');
        expect(request.headers['User-Agent'], contains('LiteTavern'));
        return http.Response.bytes(utf8.encode(_releaseJson()), 200);
      });
      final service = UpdateService(client: client);
      final info = await service.checkForUpdate(currentVersion: '0.22.0');
      expect(info!.version, '0.23.0');
      service.dispose();
    });

    test('404 → 还没有发布过版本', () async {
      final service = UpdateService(client: MockClient((_) async => http.Response('', 404)));
      expect(
        () => service.checkForUpdate(currentVersion: '0.22.0'),
        throwsA(
          isA<UpdateCheckException>().having((e) => e.message, 'message', contains('还没有发布过版本')),
        ),
      );
      service.dispose();
    });

    test('403 限流 → 中文提示', () async {
      final service = UpdateService(client: MockClient((_) async => http.Response('', 403)));
      expect(
        () => service.checkForUpdate(currentVersion: '0.22.0'),
        throwsA(
          isA<UpdateCheckException>().having((e) => e.message, 'message', contains('请求太频繁')),
        ),
      );
      service.dispose();
    });
  });

  group('UpdateService.downloadApk（下载）', () {
    final dir = Directory.systemTemp.createTempSync('lt_update_test_');
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('边下边报进度，落盘内容一致', () async {
      final bytes = List<int>.generate(200000, (i) => i % 251);
      final client = MockClient((_) async => http.Response.bytes(bytes, 200, headers: {
            'content-length': '${bytes.length}',
          }));
      final service = UpdateService(client: client);
      final events = <String>[];
      final file = await service.downloadApk(
        _info(size: bytes.length),
        dir: dir,
        onProgress: (received, total) {
          expect(total, bytes.length);
          expect(received, lessThanOrEqualTo(bytes.length));
          events.add('$received/$total');
        },
      );
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), bytes.length);
      expect(events.first, startsWith('0/'));
      expect(events.last, '${bytes.length}/${bytes.length}');
      expect(file.path, contains('LiteTavern-0.23.0.apk'));
      service.dispose();
    });

    test('取消下载：抛「已取消下载」且不留半成品', () async {
      final bytes = List<int>.generate(4096, (i) => i % 256);
      final client = MockClient((_) async => http.Response.bytes(bytes, 200, headers: {
            'content-length': '${bytes.length}',
          }));
      final service = UpdateService(client: client);
      expect(
        () => service.downloadApk(
          _info(size: bytes.length),
          dir: dir,
          isCancelled: () => true,
        ),
        throwsA(
          isA<UpdateCheckException>().having((e) => e.message, 'message', contains('已取消下载')),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(dir.listSync().whereType<File>(), isEmpty);
      service.dispose();
    });

    test('没有 APK 附件 → 直接失败', () async {
      final service = UpdateService(client: MockClient((_) async => http.Response('', 200)));
      expect(
        () => service.downloadApk(_info(apk: ''), dir: dir),
        throwsA(isA<UpdateCheckException>()),
      );
      service.dispose();
    });
  });

  group('自动更新的设置项', () {
    test('默认开启、从未检查、没有跳过版本', () {
      expect(AppSettings.autoCheckUpdates, isTrue);
      expect(AppSettings.lastUpdateCheckMs, 0);
      expect(AppSettings.skippedUpdateVersion, '');
    });

    test('写入后能读回，空跳过版本会删键', () {
      AppSettings.autoCheckUpdates = false;
      AppSettings.lastUpdateCheckMs = 123456;
      AppSettings.skippedUpdateVersion = '0.23.0';
      expect(AppSettings.autoCheckUpdates, isFalse);
      expect(AppSettings.lastUpdateCheckMs, 123456);
      expect(AppSettings.skippedUpdateVersion, '0.23.0');

      AppSettings.skippedUpdateVersion = '  ';
      expect(AppSettings.skippedUpdateVersion, '');
    });
  });

  group('UpdateDialog（更新对话框）', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(body: Builder(builder: (context) => TextButton(
                onPressed: () => showDialog<void>(context: context, builder: (_) => child),
                child: const Text('open'),
              ))),
        );

    testWidgets('检查到新版：显示版本、体积与「下载并安装」', (tester) async {
      await tester.pumpWidget(host(UpdateDialog(
        service: _FakeUpdateService(info: _info(size: 62123456)),
        installer: ApkInstaller(),
        autoCheck: true,
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('发现新版本 v0.23.0'), findsOneWidget);
      expect(find.textContaining('59.2 MB'), findsOneWidget);
      expect(find.text('下载并安装'), findsOneWidget);
      expect(find.text('稍后'), findsOneWidget);
    });

    testWidgets('已是最新：提示并且不显示下载按钮', (tester) async {
      await tester.pumpWidget(host(UpdateDialog(
        service: _FakeUpdateService(info: null),
        installer: ApkInstaller(),
        autoCheck: true,
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('已是最新版本'), findsOneWidget);
      expect(find.text('下载并安装'), findsNothing);
    });

    testWidgets('检查失败：显示原因并可重试', (tester) async {
      await tester.pumpWidget(host(UpdateDialog(
        service: _FakeUpdateService(error: '检查更新超时，请检查网络后重试'),
        installer: ApkInstaller(),
        autoCheck: true,
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('检查更新超时'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('点「稍后」记住跳过的版本', (tester) async {
      await tester.pumpWidget(host(UpdateDialog(
        service: _FakeUpdateService(info: _info()),
        installer: ApkInstaller(),
        autoCheck: false,
        initialInfo: _info(),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(AppSettings.skippedUpdateVersion, '0.23.0');
    });
  });
}
