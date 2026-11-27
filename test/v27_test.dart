import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/models/world_info.dart';
import 'package:litetavern/screens/world_book_bindings_screen.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/world_book_files.dart';
import 'package:litetavern/services/world_info_engine.dart';

WorldInfoEntry _entry({
  String? id,
  List<String> keys = const [],
  List<String> secondary = const [],
  String content = '内容',
  int order = 0,
  bool disabled = false,
  bool useProbability = false,
  int probability = 100,
  int position = 0,
  int depth = 4,
  bool recursive = false,
}) {
  return WorldInfoEntry(
    id: id,
    keys: keys,
    keysSecondary: secondary,
    content: content,
    insertionOrder: order,
    disabled: disabled,
    useProbability: useProbability,
    probability: probability,
    position: position,
    depth: depth,
    recursive: recursive,
    scanDepth: 50,
    groupWeight: 100,
  );
}

WorldInfo _book(String name, List<WorldInfoEntry> entries) =>
    WorldInfo(name: name, description: '说明', entries: entries);

Directory _tempDir(String name) =>
    Directory.systemTemp.createTempSync('lt_wb_$name');

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
  });

  group('世界书文件（v0.27.0 导入导出）', () {
    test('buildJson → parseBytes 往返保留条目与关键词', () {
      final book = _book('大陆设定', [
        _entry(id: 'a', keys: ['酒馆', '旅馆'], content: '酒馆里有条龙', order: 2),
        _entry(id: 'b', content: '常驻设定', order: 1),
      ]);
      final json = WorldBookFiles.buildJson(book);
      expect(json, contains('大陆设定'));
      expect(json, contains('酒馆'));

      final parsed = WorldBookFiles.parseBytes(
        Uint8List.fromList(utf8.encode(json)),
        fallbackName: '新建',
      );
      expect(parsed.name, '大陆设定');
      expect(parsed.entries.length, 2);
      final keys = parsed.entries.expand((e) => e.keys).toList();
      expect(keys, containsAll(['酒馆', '旅馆']));
      expect(parsed.entries.any((e) => e.keys.isEmpty), isTrue);
    });

    test('裸条目写法（整份就是 entries map）也能导入', () {
      final raw = jsonEncode({
        '0': {'key': ['城堡'], 'content': '城堡很大'},
        '1': {'content': '常驻'},
      });
      final book = WorldBookFiles.parseBytes(
        Uint8List.fromList(utf8.encode(raw)),
        fallbackName: '匿名书',
      );
      expect(book.name, '匿名书');
      expect(book.entries.length, 2);
      expect(book.entries.first.keys, ['城堡']);
    });

    test('空文件 / 非 JSON / 数组 / 没条目都报 FormatException', () {
      expect(
        () => WorldBookFiles.parseBytes(Uint8List.fromList(const [])),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WorldBookFiles.parseBytes(
          Uint8List.fromList(utf8.encode('不是 json')),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WorldBookFiles.parseBytes(
          Uint8List.fromList(utf8.encode('[1,2]')),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WorldBookFiles.parseBytes(
          Uint8List.fromList(utf8.encode('{"name":"空书","entries":{}}')),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('safeName 去掉路径非法字符并限长', () {
      expect(WorldBookFiles.safeName('艾琳/雨夜: 世界?'), '艾琳_雨夜_世界');
      expect(WorldBookFiles.safeName('   '), '世界书');
      expect(WorldBookFiles.safeName('a' * 60).length, 40);
    });
  });

  group('世界书四范围绑定（v0.27.0）', () {
    test('mountKey 四种范围的键名', () {
      expect(Storage.worldBookMountKey(WorldBookScope.global, null), 'global');
      expect(
        Storage.worldBookMountKey(WorldBookScope.character, 'c1'),
        'char:c1',
      );
      expect(Storage.worldBookMountKey(WorldBookScope.chat, 'x'), 'chat:x');
      expect(
        Storage.worldBookMountKey(WorldBookScope.persona, 'p'),
        'persona:p',
      );
      expect(WorldBookScope.global.needsOwner, isFalse);
      expect(WorldBookScope.chat.needsOwner, isTrue);
    });

    test('按范围保存与读取；角色范围兼容旧键（裸 charId）', () async {
      final dir = _tempDir('mounts');
      Storage.initForTest(dir);

      await Storage.saveWorldBookMountsForScope(
        WorldBookScope.chat,
        'conv1',
        [(id: 'wb1', enabled: true)],
      );
      expect(
        await Storage.worldBookMountsForScope(WorldBookScope.chat, 'conv1'),
        [(id: 'wb1', enabled: true)],
      );

      // 旧版本：直接以 charId 为键
      final file = File(
        '${dir.path}${Platform.pathSeparator}worldbooks'
        '${Platform.pathSeparator}mounts.json',
      );
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({
        'charOld': [
          {'id': 'wb2', 'enabled': true},
        ],
      }));
      final legacy = await Storage.worldBookMountsForScope(
        WorldBookScope.character,
        'charOld',
      );
      expect(legacy, [(id: 'wb2', enabled: true)]);
    });

    test('effective 合并全局 + 人设 + 角色 + 聊天，任一开启即注入', () async {
      final dir = _tempDir('effective');
      Storage.initForTest(dir);
      AppSettings.mountedWorldBookIds = ['wbGlobal'];

      await Storage.saveWorldBookMountsForScope(
        WorldBookScope.persona,
        'p1',
        [(id: 'wbPersona', enabled: true)],
      );
      await Storage.saveWorldBookMountsForScope(
        WorldBookScope.character,
        'c1',
        [
          (id: 'wbShared', enabled: true),
          (id: 'wbOff', enabled: false),
        ],
      );
      await Storage.saveWorldBookMountsForScope(
        WorldBookScope.chat,
        'conv1',
        [
          (id: 'wbShared', enabled: true),
          (id: 'wbChat', enabled: true),
        ],
      );

      final merged = await Storage.effectiveWorldBookMounts(
        charId: 'c1',
        convId: 'conv1',
        personaId: 'p1',
      );
      final ids = merged.map((m) => m.id).toSet();
      expect(ids, {'wbGlobal', 'wbPersona', 'wbShared', 'wbChat'});
      expect(ids.contains('wbOff'), isFalse);

      // 未绑定的人设 / 其它会话不串味
      final other = await Storage.effectiveWorldBookMounts(
        charId: 'c2',
        convId: 'conv2',
        personaId: 'p2',
      );
      expect(other.map((m) => m.id).toSet(), {'wbGlobal'});
    });
  });

  group('世界书命中测试（v0.27.0）', () {
    test('关键词命中 / 常驻 / 未命中都给出原因与位置提示', () {
      final book = _book('测试书', [
        _entry(id: '1', keys: ['酒馆'], content: '酒馆里有一条龙', order: 1),
        _entry(id: '2', content: '常驻设定', order: 2),
        _entry(id: '3', keys: ['城堡'], content: '城堡', order: 3),
        _entry(
          id: '4',
          keys: ['酒馆'],
          content: '深度注入',
          order: 4,
          position: 1,
          depth: 3,
        ),
      ]);
      final result = WorldInfoEngine.inspect(
        books: [book],
        text: '我们走进酒馆坐下',
        charName: '艾琳',
        userName: '你',
      );
      expect(result.length, 4);
      final byId = {for (final r in result) r.entry.id!: r};
      expect(byId['1']!.activated, isTrue);
      expect(byId['1']!.reason, contains('关键词「酒馆」命中'));
      expect(byId['2']!.activated, isTrue);
      expect(byId['2']!.reason, contains('常驻'));
      expect(byId['3']!.activated, isFalse);
      expect(byId['3']!.reason, contains('关键词未命中'));
      expect(byId['4']!.activated, isTrue);
      expect(byId['4']!.reason, contains('深度 3'));
    });

    test('次级关键词 / 已禁用 / 概率 0 的未激活原因', () {
      final book = _book('测试书', [
        _entry(
          id: '1',
          keys: ['酒馆'],
          secondary: ['夜晚'],
          content: '夜晚的酒馆',
        ),
        _entry(id: '2', keys: ['酒馆'], content: '禁用', disabled: true),
        _entry(
          id: '3',
          keys: ['酒馆'],
          content: '概率',
          useProbability: true,
          probability: 0,
        ),
      ]);
      final result = WorldInfoEngine.inspect(
        books: [book],
        text: '酒馆',
        charName: '艾琳',
        userName: '你',
      );
      final byId = {for (final r in result) r.entry.id!: r};
      expect(byId['1']!.activated, isFalse);
      expect(byId['1']!.reason, contains('次级关键词未命中'));
      expect(byId['2']!.activated, isFalse);
      expect(byId['2']!.reason, contains('已禁用'));
      expect(byId['3']!.activated, isFalse);
      expect(byId['3']!.reason, contains('概率'));
    });

    test('递归命中：由其它已激活条目的内容触发', () {
      final book = _book('测试书', [
        _entry(
          id: '1',
          keys: ['酒馆'],
          content: '酒馆的墙壁上刻着一条龙的图案',
          recursive: true,
        ),
        _entry(id: '2', keys: ['龙'], content: '龙族设定', recursive: true),
      ]);
      final result = WorldInfoEngine.inspect(
        books: [book],
        text: '我们去酒馆',
        charName: '艾琳',
        userName: '你',
      );
      final byId = {for (final r in result) r.entry.id!: r};
      expect(byId['1']!.activated, isTrue);
      expect(byId['2']!.activated, isTrue);
      expect(byId['2']!.reason, contains('递归命中'));
    });
  });

  testWidgets('绑定页空态提示先导入世界书', (tester) async {
    Storage.initForTest(_tempDir('screen'));
    await tester.pumpWidget(
      const MaterialApp(home: WorldBookBindingsScreen()),
    );
    await tester.pump();
    // 页面初始化要读磁盘（世界书 + 归属者），让真实 IO 跑完再查断言
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('世界书绑定'), findsOneWidget);
    expect(find.textContaining('还没有世界书'), findsOneWidget);
    expect(find.text('全局'), findsOneWidget);
  });
}
