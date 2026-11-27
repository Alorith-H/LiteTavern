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

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive) ?? const <int>[]);
}

BackupArchive _archive() => BackupService.parseBackup(
      _zip({
        'manifest.json': jsonEncode({
          'format': 'litetavern-backup',
          'formatVersion': 1,
          'appVersion': '0.38.0',
          'createdAt': DateTime(2026, 11, 28, 1, 2).toIso8601String(),
          'fileCount': 4,
          'prefCount': 1,
          'prefs': {'user_name': '恢复测试'},
        }),
        'files/characters/c1/card.json': '{"name":"甲"}',
        'files/characters/c1/avatar.png': 'png',
        'files/conversations/c1.json': '[]',
        'files/groups/g1.json': '{}',
      }),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{'user_name': '原名'});
    await AppSettings.init();
    docs = Directory.systemTemp.createTempSync('lt_v38_restore_');
    Storage.initForTest(docs);
  });

  tearDown(() {
    try {
      docs.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('BackupRestoreOptions', () {
    test('默认为全选', () {
      const options = BackupRestoreOptions.all;
      expect(options.characters, isTrue);
      expect(options.conversations, isTrue);
      expect(options.worldBooks, isTrue);
      expect(options.groups, isTrue);
      expect(options.settings, isTrue);
      expect(options.any, isTrue);
    });

    test('copyWith 可以逐项关闭，allowsDir 只放行勾选的目录', () {
      final onlyChats = BackupRestoreOptions.all.copyWith(
        characters: false,
        worldBooks: false,
        groups: false,
        settings: false,
      );
      expect(onlyChats.allowsDir('conversations'), isTrue);
      expect(onlyChats.allowsDir('characters'), isFalse);
      expect(onlyChats.allowsDir('worldbooks'), isFalse);
      expect(onlyChats.allowsDir('groups'), isFalse);
      expect(onlyChats.allowsDir('something-else'), isFalse);
    });

    test('全不选时 any == false', () {
      const none = BackupRestoreOptions(
        characters: false,
        conversations: false,
        worldBooks: false,
        groups: false,
        settings: false,
      );
      expect(none.any, isFalse);
    });

    test('selectedFileCount / summary 按勾选统计', () {
      final archive = _archive();
      expect(BackupRestoreOptions.all.selectedFileCount(archive), 4);
      final onlyChats = BackupRestoreOptions.all.copyWith(
        characters: false,
        worldBooks: false,
        groups: false,
        settings: false,
      );
      expect(onlyChats.selectedFileCount(archive), 1);
      expect(onlyChats.summary(archive), contains('聊天 1'));
      expect(onlyChats.summary(archive), isNot(contains('角色卡')));
      expect(BackupRestoreOptions.all.summary(archive), contains('角色卡 2'));
    });
  });

  group('按范围恢复', () {
    test('只恢复聊天：角色卡与世界书不写、设置不动', () async {
      final archive = _archive();
      final written = await BackupService.restoreBackup(
        archive,
        docs: docs,
        options: BackupRestoreOptions.all.copyWith(
          characters: false,
          worldBooks: false,
          groups: false,
          settings: false,
        ),
      );

      expect(written, 1);
      expect(
        File('${docs.path}/conversations/c1.json').existsSync(),
        isTrue,
      );
      expect(File('${docs.path}/characters/c1/card.json').existsSync(), isFalse);
      expect(AppSettings.userName, '原名');
    });

    test('只恢复设置：不写文件，设置被覆盖', () async {
      final archive = _archive();
      final written = await BackupService.restoreBackup(
        archive,
        docs: docs,
        options: BackupRestoreOptions.all.copyWith(
          characters: false,
          conversations: false,
          worldBooks: false,
          groups: false,
        ),
      );

      expect(written, 0);
      expect(Directory('${docs.path}/characters').existsSync(), isFalse);
      expect(AppSettings.userName, '恢复测试');
    });

    test('全选时和旧行为一致：四个目录的文件都写回', () async {
      final archive = _archive();
      final written =
          await BackupService.restoreBackup(archive, docs: docs);
      expect(written, 4);
      expect(File('${docs.path}/characters/c1/avatar.png').existsSync(), isTrue);
      expect(File('${docs.path}/groups/g1.json').existsSync(), isTrue);
    });

    test('一项都没选时直接报错，不写任何东西', () async {
      final archive = _archive();
      expect(
        () => BackupService.restoreBackup(
          archive,
          docs: docs,
          options: const BackupRestoreOptions(
            characters: false,
            conversations: false,
            worldBooks: false,
            groups: false,
            settings: false,
          ),
        ),
        throwsA(isA<BackupException>()),
      );
      expect(Directory('${docs.path}/characters').existsSync(), isFalse);
    });
  });

  group('恢复范围弹窗', () {
    testWidgets('列出五类数据，全不选时「恢复」不可用', (tester) async {
      final archive = _archive();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<BackupRestoreOptions>(
                  context: context,
                  builder: (_) => _DialogHost(archive: archive),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('恢复哪些内容？'), findsOneWidget);
      expect(find.text('角色卡（含头像）'), findsOneWidget);
      expect(find.text('聊天记录'), findsOneWidget);
      expect(find.text('世界书'), findsOneWidget);
      expect(find.text('群聊'), findsOneWidget);
      expect(find.text('设置（含 API Key、预设）'), findsOneWidget);
      expect(find.textContaining('将恢复：'), findsOneWidget);

      await tester.tap(find.text('全不选'));
      await tester.pumpAndSettle();
      expect(find.text('至少选一项'), findsOneWidget);
      final restore = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '恢复'),
      );
      expect(restore.onPressed, isNull);
    });
  });
}

class _DialogHost extends StatelessWidget {
  const _DialogHost({required this.archive});

  final BackupArchive archive;

  @override
  Widget build(BuildContext context) => RestoreScopeDialog(archive: archive);
}
