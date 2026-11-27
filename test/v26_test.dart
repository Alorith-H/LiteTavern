import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/services/backup_service.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/widgets/backup_sheet.dart';

Directory _tempDir(String name) {
  final dir = Directory.systemTemp.createTempSync('lt_backup_$name');
  for (final sub in BackupService.dataDirs) {
    Directory('${dir.path}${Platform.pathSeparator}$sub')
        .createSync(recursive: true);
  }
  return dir;
}

void _write(Directory root, String rel, String content) {
  final file = File(
    '${root.path}${Platform.pathSeparator}'
    '${rel.replaceAll('/', Platform.pathSeparator)}',
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

Uint8List _zipWithFiles(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive) ?? const <int>[]);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
  });

  group('BackupService.createBackup / parseBackup', () {
    test('打包四个数据目录与设置项，再解析回来内容一致', () async {
      final docs = _tempDir('create');
      _write(docs, 'characters/1001/card.json', '{"name":"阿青"}');
      _write(docs, 'characters/1001/avatar.png', 'PNGDATA');
      _write(docs, 'conversations/1001.json', '[{"content":"你好"}]');
      _write(docs, 'worldbooks/wb1.json', '{"name":"世界观"}');
      _write(docs, 'groups/g1.json', '{"name":"群聊"}');
      // 不属于数据目录的文件不应进备份
      _write(docs, 'other/ignore.txt', 'ignore');

      final prefs = <String, Object?>{
        'user_name': '阿青',
        'auto_check_updates': true,
        'theme_seed': 0xFF9C4632,
        'quick_replies': <String>['嗯', '好'],
      };
      final bytes = await BackupService.createBackup(
        docs: docs,
        prefs: prefs,
        appVersion: '9.9.9',
        now: DateTime.utc(2026, 11, 27, 18, 0),
      );
      expect(bytes.length, greaterThan(100));

      final archive = BackupService.parseBackup(bytes);
      expect(archive.manifest.appVersion, '9.9.9');
      expect(archive.manifest.fileCount, 5);
      expect(archive.files.length, 5);
      expect(archive.files['other/ignore.txt'], isNull);
      expect(
        utf8.decode(archive.files['characters/1001/card.json']!),
        '{"name":"阿青"}',
      );
      expect(archive.prefs['user_name'], '阿青');
      expect(archive.prefs['theme_seed'], 0xFF9C4632);
      expect(archive.prefs['quick_replies'], <String>['嗯', '好']);
    });

    test('空的文档目录也能导出（只是没有文件）', () async {
      final docs = _tempDir('empty');
      final bytes = await BackupService.createBackup(docs: docs, prefs: {});
      final archive = BackupService.parseBackup(bytes);
      expect(archive.files, isEmpty);
      expect(archive.manifest.fileCount, 0);
    });

    test('非 zip 数据 → BackupException', () {
      expect(
        () => BackupService.parseBackup(Uint8List.fromList(utf8.encode('hello'))),
        throwsA(isA<BackupException>()),
      );
    });

    test('zip 里没有清单 → BackupException', () {
      final bytes = _zipWithFiles({'files/characters/a/card.json': '{}'});
      expect(
        () => BackupService.parseBackup(bytes),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('缺少清单'),
          ),
        ),
      );
    });

    test('清单格式不对 → BackupException', () {
      final bytes = _zipWithFiles({
        'manifest.json': jsonEncode({'format': 'other', 'formatVersion': 1}),
      });
      expect(
        () => BackupService.parseBackup(bytes),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('不是 LiteTavern 的备份'),
          ),
        ),
      );
    });

    test('格式版本比当前新 → 提示升级', () {
      final bytes = _zipWithFiles({
        'manifest.json': jsonEncode({
          'format': BackupService.format,
          'formatVersion': BackupService.formatVersion + 1,
        }),
      });
      expect(
        () => BackupService.parseBackup(bytes),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('更新的版本'),
          ),
        ),
      );
    });

    test('路径穿越（../）被拒绝', () {
      final bytes = _zipWithFiles({
        'manifest.json': jsonEncode({
          'format': BackupService.format,
          'formatVersion': 1,
        }),
        'files/characters/../../evil.txt': 'x',
      });
      expect(
        () => BackupService.parseBackup(bytes),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('路径不安全'),
          ),
        ),
      );
    });

    test('绝对路径被拒绝', () {
      final bytes = _zipWithFiles({
        'manifest.json': jsonEncode({
          'format': BackupService.format,
          'formatVersion': 1,
        }),
        'files//etc/passwd': 'x',
      });
      expect(
        () => BackupService.parseBackup(bytes),
        throwsA(isA<BackupException>()),
      );
    });
  });

  group('BackupService.restoreBackup', () {
    test('把备份写回新的文档目录，内容一致', () async {
      final source = _tempDir('restore_src');
      _write(source, 'characters/1001/card.json', '{"name":"阿青"}');
      _write(source, 'conversations/1001.json', '[{"content":"你好"}]');
      final bytes = await BackupService.createBackup(
        docs: source,
        prefs: {'user_name': '阿青'},
      );
      final archive = BackupService.parseBackup(bytes);

      final target = _tempDir('restore_dst');
      final written = await BackupService.restoreBackup(archive, docs: target);
      expect(written, 2);
      final card = File(
        '${target.path}${Platform.pathSeparator}characters'
        '${Platform.pathSeparator}1001${Platform.pathSeparator}card.json',
      );
      expect(card.existsSync(), isTrue);
      expect(card.readAsStringSync(), '{"name":"阿青"}');
      expect(AppSettings.userName, '阿青');
    });

    test('手动改过的 archive 中的不安全路径在写盘前也会被拒绝', () async {
      final docs = _tempDir('restore_bad');
      final archive = BackupArchive(
        manifest: BackupManifest(
          appVersion: '1',
          createdAt: DateTime.now(),
          fileCount: 1,
          prefCount: 0,
        ),
        files: {'characters/../../x.txt': utf8.encode('x')},
        prefs: const {},
      );
      expect(
        () => BackupService.restoreBackup(archive, docs: docs),
        throwsA(isA<BackupException>()),
      );
    });
  });

  group('AppSettings 设置项导出 / 恢复', () {
    test('exportPrefs 包含基础类型，importPrefs 可写回', () async {
      AppSettings.userName = '小桃';
      AppSettings.autoCheckUpdates = false;
      AppSettings.themeSeed = 0xFF123456;
      final exported = AppSettings.exportPrefs();
      expect(exported['user_name'], '小桃');
      expect(exported['auto_check_updates'], false);
      expect(exported['theme_seed'], 0xFF123456);

      SharedPreferences.setMockInitialValues(<String, Object>{});
      await AppSettings.init();
      expect(AppSettings.userName, '你');

      await AppSettings.importPrefs(exported);
      expect(AppSettings.userName, '小桃');
      expect(AppSettings.autoCheckUpdates, false);
      expect(AppSettings.themeSeed, 0xFF123456);
    });
  });

  group('writeTempZip', () {
    test('写成 LiteTavern_backup_<时间戳>.zip', () async {
      final dir = _tempDir('zip');
      final file = await BackupService.writeTempZip(
        Uint8List.fromList([1, 2, 3]),
        directory: dir,
        now: DateTime(2026, 11, 27, 8, 9, 10),
      );
      expect(file.path, endsWith('LiteTavern_backup_20261127_080910.zip'));
      expect(file.readAsBytesSync(), [1, 2, 3]);
    });
  });

  group('备份与恢复弹层', () {
    testWidgets('展示两个入口与安全说明', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showBackupSheet(context),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('备份与恢复'), findsOneWidget);
      expect(find.text('导出备份 (.zip)'), findsOneWidget);
      expect(find.text('从备份恢复'), findsOneWidget);
      expect(
        find.textContaining('备份里包含 API Key'),
        findsOneWidget,
      );
    });
  });
}
