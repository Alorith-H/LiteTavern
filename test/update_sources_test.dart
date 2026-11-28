import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/updater.dart';

const _apkUrl =
    'https://github.com/Alorith-H/LiteTavern/releases/download/v9.9.9/app-release.apk';

http.StreamedResponse _ok(List<int> bytes, {int status = 200}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    status,
    contentLength: bytes.length,
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
  });

  group('downloadSourcesFor（候选源）', () {
    test('自动模式：直连在前，后面跟内置镜像，自定义前缀排最前', () {
      final sources = UpdateService.downloadSourcesFor(
        _apkUrl,
        mode: UpdateSourceMode.auto,
        customPrefix: 'https://my-mirror.example/',
      );
      expect(sources.first.label, '自定义源');
      expect(sources.first.url, 'https://my-mirror.example/$_apkUrl');
      expect(sources[1].url, _apkUrl);
      expect(sources.any((s) => s.url == 'https://gh-proxy.com/$_apkUrl'), isTrue);
      expect(sources.any((s) => s.url == 'https://ghfast.top/$_apkUrl'), isTrue);
      expect(sources.length, 2 + UpdateService.mirrorPrefixes.length);
    });

    test('自动模式没填自定义前缀时不出现自定义源', () {
      final sources = UpdateService.downloadSourcesFor(_apkUrl);
      expect(sources.first.url, _apkUrl);
      expect(sources.length, 1 + UpdateService.mirrorPrefixes.length);
    });

    test('只走 GitHub：只有直连一个', () {
      final sources = UpdateService.downloadSourcesFor(
        _apkUrl,
        mode: UpdateSourceMode.githubOnly,
        customPrefix: 'https://ignored.example/',
      );
      expect(sources.length, 1);
      expect(sources.single.url, _apkUrl);
    });

    test('自定义模式：自定义在前，直连兜底', () {
      final sources = UpdateService.downloadSourcesFor(
        _apkUrl,
        mode: UpdateSourceMode.custom,
        customPrefix: 'https://mirror.example',
      );
      expect(sources.map((s) => s.url).toList(),
          ['https://mirror.example/$_apkUrl', _apkUrl]);
    });

    test('空地址返回空列表；前缀带不带斜杠都能拼对', () {
      expect(UpdateService.downloadSourcesFor('  '), isEmpty);
      final a = UpdateService.downloadSourcesFor(_apkUrl,
          mode: UpdateSourceMode.custom, customPrefix: 'https://a.example/');
      final b = UpdateService.downloadSourcesFor(_apkUrl,
          mode: UpdateSourceMode.custom, customPrefix: 'https://a.example');
      expect(a.first.url, b.first.url);
    });
  });

  group('downloadApk（断点续传 / 换源）', () {
    late Directory dir;
    late List<int> payload;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('lt_update_test');
      payload = List<int>.generate(400 * 1024, (i) => i % 251);
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    UpdateInfo info() => UpdateInfo(
          version: '9.9.9',
          tag: 'v9.9.9',
          notes: '',
          apkUrl: _apkUrl,
          apkSize: payload.length,
          pageUrl: '',
          publishedAt: null,
        );

    File partFile() =>
        File('${dir.path}${Platform.pathSeparator}LiteTavern-9.9.9.apk.part');

    test('已经下完的安装包直接复用，不再请求网络', () async {
      final target = File('${dir.path}${Platform.pathSeparator}LiteTavern-9.9.9.apk');
      target.writeAsBytesSync(payload);
      var requests = 0;
      final svc = UpdateService(
        client: MockClient.streaming((request, _) async {
          requests++;
          return _ok(<int>[], status: 500);
        }),
      );
      AppSettings.updateSourceMode = UpdateSourceMode.githubOnly;
      final progress = <int>[];
      final file = await svc.downloadApk(
        info(),
        dir: dir,
        onProgress: (received, _) => progress.add(received),
      );
      expect(file.path, target.path);
      expect(requests, 0);
      expect(progress.last, payload.length);
    });

    test('半成品正好等于目标大小时直接补成正式文件', () async {
      partFile().writeAsBytesSync(payload);
      var requests = 0;
      final svc = UpdateService(
        client: MockClient.streaming((request, _) async {
          requests++;
          return _ok(<int>[], status: 500);
        }),
      );
      AppSettings.updateSourceMode = UpdateSourceMode.githubOnly;
      final file = await svc.downloadApk(info(), dir: dir);
      expect(file.path.endsWith('LiteTavern-9.9.9.apk'), isTrue);
      expect(file.readAsBytesSync().length, payload.length);
      expect(partFile().existsSync(), isFalse);
      expect(requests, 0);
    });

    test('已有 .part 时用 Range 从断点接着下', () async {
      final existing = payload.sublist(0, 100 * 1024);
      partFile().writeAsBytesSync(existing);
      final ranges = <String>[];

      final client = MockClient.streaming((request, _) async {
        final range = request.headers['Range'];
        if (range != null) ranges.add(range);
        if (range == 'bytes=102400-') {
          return _ok(payload.sublist(100 * 1024), status: 206);
        }
        return _ok(payload.sublist(0, 40 * 1024), status: 206);
      });

      AppSettings.updateSourceMode = UpdateSourceMode.githubOnly;
      final service = UpdateService(client: client);
      final file = await service.downloadApk(info(), dir: dir);
      final got = file.readAsBytesSync();
      expect(got.length, payload.length);
      expect(got.sublist(0, 1024), payload.sublist(0, 1024));
      expect(ranges, contains('bytes=102400-'));
      expect(partFile().existsSync(), isFalse);
    });

    test('直连失败会自动换到能用的镜像，并报告来源', () async {
      final reported = <String>[];
      final client = MockClient.streaming((request, _) async {
        final url = request.url.toString();
        if (url.contains('gh-proxy.com') || url.contains('ghfast.top')) {
          final range = request.headers['Range'];
          if (range == null) return _ok(payload);
          if (range == 'bytes=0-65535') {
            return _ok(payload.sublist(0, 40 * 1024), status: 206);
          }
          final start = int.parse(
              RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          return _ok(payload.sublist(start), status: 206);
        }
        return http.StreamedResponse(const Stream<List<int>>.empty(), 500);
      });

      final service = UpdateService(client: client);
      final file = await service.downloadApk(
        info(),
        dir: dir,
        onSource: (source) => reported.add(source.label),
      );
      expect(file.readAsBytesSync().length, payload.length);
      expect(reported.any((label) => label.contains('gh-proxy') || label.contains('ghfast')),
          isTrue);
    });

    test('取消下载时保留 .part，下次能接着下', () async {
      partFile().writeAsBytesSync(payload.sublist(0, 64 * 1024));
      final client = MockClient.streaming((request, _) async => _ok(payload));
      AppSettings.updateSourceMode = UpdateSourceMode.githubOnly;
      final service = UpdateService(client: client);

      await expectLater(
        service.downloadApk(info(), dir: dir, isCancelled: () => true),
        throwsA(isA<UpdateCheckException>()),
      );
      expect(partFile().existsSync(), isTrue);
      expect(partFile().lengthSync(), 64 * 1024);
    });

    test('服务器忽略 Range 直接回 200 时从头重下，不把文件写坏', () async {
      partFile().writeAsBytesSync(payload.sublist(0, 32 * 1024));
      final client = MockClient.streaming((request, _) async => _ok(payload));
      AppSettings.updateSourceMode = UpdateSourceMode.githubOnly;
      final service = UpdateService(client: client);
      final file = await service.downloadApk(info(), dir: dir);
      final got = file.readAsBytesSync();
      expect(got.length, payload.length);
      expect(got, payload);
    });

    test('所有源都失败时报错，且不留下 APK 成品', () async {
      final client = MockClient.streaming(
        (request, _) async => http.StreamedResponse(const Stream<List<int>>.empty(), 502),
      );
      final service = UpdateService(client: client);
      await expectLater(
        service.downloadApk(info(), dir: dir),
        throwsA(isA<UpdateCheckException>()),
      );
      expect(File('${dir.path}${Platform.pathSeparator}LiteTavern-9.9.9.apk').existsSync(),
          isFalse);
    });
  });
}
