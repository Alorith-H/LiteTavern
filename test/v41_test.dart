import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/services/app_log.dart';
import 'package:litetavern/services/api_client.dart';
import 'package:litetavern/services/charx_importer.dart';
import 'package:litetavern/services/display_regex.dart';
import 'package:litetavern/services/st_chat_importer.dart';
import 'package:litetavern/services/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
    Storage.initForTest(
      await Directory.systemTemp.createTemp('lt_v41_'),
    );
    AppLog.resetForTest();
    DisplayRegexLibrary.resetForTest();
  });

  group('上限常量（商用加固）', () {
    test('各服务都声明了合理的上限', () {
      expect(CharxImporter.maxEntries, greaterThan(0));
      expect(CharxImporter.maxUncompressedBytes, greaterThan(0));
      expect(StChatImporter.maxBytes, greaterThan(0));
      expect(StChatImporter.maxLines, greaterThan(0));
      expect(DisplayRegex.maxPatternLength, greaterThan(0));
      expect(DisplayRegex.maxAppliedLength, greaterThan(0));
      expect(ApiClient.maxResponseBytes, greaterThan(0));
      expect(ApiClient.maxStreamChars, greaterThan(0));
    });
  });

  group('CHARX 压缩包守卫', () {
    test('空 zip 报「不是有效的角色卡包」', () {
      // 一个只有目录项的空 zip。
      final bytes = Uint8List.fromList(<int>[80, 75, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(
        () => CharxImporter.parse(bytes, filename: 'x.charx'),
        throwsA(isA<CharxFormatException>()),
      );
    });
  });

  group('SillyTavern .jsonl 上限', () {
    test('超过 maxLines 行直接拒绝', () {
      final lines = List<String>.generate(
        StChatImporter.maxLines + 5,
        (i) => '{"mes":"第 $i 条","is_user":false}',
      );
      final bytes = Uint8List.fromList(utf8.encode(lines.join('\n')));
      expect(
        () => StChatImporter.parse(bytes),
        throwsA(isA<StChatFormatException>()),
      );
    });

    test('超长单行被跳过计入 skipped，不影响其它行', () {
      final long = '{"mes":"${'x' * (StChatImporter.maxLineChars + 10)}"}';
      final body = <String>[
        long,
        '{"mes":"正常一条","is_user":true}',
      ].join('\n');
      final result = StChatImporter.parse(
        Uint8List.fromList(utf8.encode(body)),
      );
      expect(result.messages.length, 1);
      expect(result.messages.single.content, '正常一条');
      expect(result.skippedLines, 1);
    });
  });

  group('显示正则上限', () {
    test('超长 pattern 视为无效，不生效也不抛', () {
      final regex = DisplayRegex(
        id: 'r1',
        name: '太长',
        pattern: 'a' * (DisplayRegex.maxPatternLength + 1),
        flags: '',
        replacement: 'b',
        enabled: true,
        scope: RegexScope.all,
      );
      expect(regex.compile(), isNull);
      expect(regex.hasError, isTrue);
      expect(regex.apply('aaa'), 'aaa');
    });

    test('超长文本跳过正则处理，原样返回', () {
      const regex = DisplayRegex(
        id: 'r2',
        name: '替换',
        pattern: 'a',
        flags: '',
        replacement: 'b',
        enabled: true,
        scope: RegexScope.all,
      );
      final text = 'a' * (DisplayRegex.maxAppliedLength + 1);
      expect(regex.apply(text), same(text));
    });

    test('导入一次最多 maxImportCount 条，超出丢弃', () async {
      final items = List<Map<String, Object?>>.generate(
        DisplayRegexLibrary.maxImportCount + 30,
        (i) => <String, Object?>{
          'scriptName': 'rx$i',
          'findRegex': '/foo$i/g',
          'replaceString': 'bar$i',
        },
      );
      final added = await DisplayRegexLibrary.importFromJson(
        jsonEncode(items),
      );
      expect(added, DisplayRegexLibrary.maxImportCount);
    });

    test('导入时跳过超长 pattern', () async {
      final added = await DisplayRegexLibrary.importFromJson(
        jsonEncode(<Object?>[
          <String, Object?>{
            'scriptName': 'ok',
            'findRegex': '/abc/g',
            'replaceString': 'x',
          },
          <String, Object?>{
            'scriptName': 'too-long',
            'findRegex': '/${'a' * (DisplayRegex.maxPatternLength + 1)}/g',
            'replaceString': 'y',
          },
        ]),
      );
      expect(added, 1);
    });
  });

  group('AppLog 诊断日志', () {
    test('内存里只保留最近 maxLines 行', () {
      for (var i = 0; i < AppLog.maxLines + 60; i++) {
        AppLog.record('第 $i 条');
      }
      expect(AppLog.lines.length, AppLog.maxLines);
      expect(AppLog.lines.first, contains('第 ${60} 条'));
      expect(AppLog.lines.last, contains('第 ${AppLog.maxLines + 59} 条'));
    });

    test('recent 返回新的在前', () async {
      AppLog.record('一');
      AppLog.record('二');
      final recent = await AppLog.recent(max: 2);
      expect(recent.length, 2);
      expect(recent.first, contains('二'));
      expect(recent.last, contains('一'));
    });

    test('clear 清空内存', () async {
      AppLog.record('要删的');
      await AppLog.clear();
      expect(AppLog.lines, isEmpty);
    });

    test('记录异常不会抛', () {
      expect(
        () => AppLog.record(
          '异常',
          error: StateError('boom'),
          stackTrace: StackTrace.current,
        ),
        returnsNormally,
      );
    });
  });
}
