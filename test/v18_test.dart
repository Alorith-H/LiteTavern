import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/services/bookmarks.dart';
import 'package:litetavern/services/chat_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatIndex.resetForTest();
    BookmarkStore.resetForTest();
  });

  group('ChatIndex', () {
    test('ownerOf：单聊用角色 id，群聊加 group_ 前缀', () {
      expect(ChatIndex.ownerOf(charId: 'c1', groupId: null), 'c1');
      expect(ChatIndex.ownerOf(charId: '', groupId: 'g1'), 'group_g1');
    });

    test('ensure 把旧会话补进索引且不重复', () async {
      final first = await ChatIndex.ensure(
        'c1',
        defaultId: 'c1',
        defaultName: '艾琳',
      );
      expect(first.length, 1);
      expect(first.first.id, 'c1');
      expect(first.first.name, '艾琳');

      final again = await ChatIndex.ensure(
        'c1',
        defaultId: 'c1',
        defaultName: '艾琳',
      );
      expect(again.length, 1);
    });

    test('已有新聊天时 ensure 补的旧会话带「（默认）」后缀', () async {
      await ChatIndex.touch('c1', convId: 'c1~a', messageCount: 3, name: '新聊天');
      final chats = await ChatIndex.ensure(
        'c1',
        defaultId: 'c1',
        defaultName: '艾琳',
      );
      expect(chats.length, 2);
      final legacy =
          chats.firstWhere((c) => c.id == 'c1');
      expect(legacy.name, '艾琳（默认）');
    });

    test('touch 新增与更新条数、按最近使用倒序', () async {
      await ChatIndex.touch(
        'c1',
        convId: 'c1',
        messageCount: 2,
        name: '艾琳',
        updatedAt: 1000,
      );
      await ChatIndex.touch(
        'c1',
        convId: 'c1~b',
        messageCount: 5,
        name: '第二段',
        updatedAt: 2000,
      );
      var chats = await ChatIndex.load('c1');
      expect(chats.length, 2);
      expect(chats.first.id, 'c1~b'); // 最近使用的在前

      await ChatIndex.touch(
        'c1',
        convId: 'c1',
        messageCount: 9,
        updatedAt: 3000,
      );
      chats = await ChatIndex.load('c1');
      expect(chats.first.id, 'c1');
      expect(chats.first.messageCount, 9);
      expect(chats.first.name, '艾琳'); // name 传空保留旧名
    });

    test('touch 未知名用「未命名聊天」兜底', () async {
      await ChatIndex.touch('c1', convId: 'c1~x', messageCount: 0);
      final chats = await ChatIndex.load('c1');
      expect(chats.single.name, '未命名聊天');
    });

    test('rename / remove / find', () async {
      await ChatIndex.touch('c1', convId: 'c1~1', messageCount: 1, name: '旧名');
      await ChatIndex.rename('c1', 'c1~1', '  新名字  ');
      expect((await ChatIndex.find('c1', 'c1~1'))!.name, '新名字');
      // 空名字不改
      await ChatIndex.rename('c1', 'c1~1', '   ');
      expect((await ChatIndex.find('c1', 'c1~1'))!.name, '新名字');
      await ChatIndex.remove('c1', 'c1~1');
      expect(await ChatIndex.load('c1'), isEmpty);
      expect(await ChatIndex.find('c1', 'c1~1'), isNull);
    });

    test('newId 带 owner 前缀且两次不同', () {
      final a = ChatIndex.newId('c1');
      final b = ChatIndex.newId('c1', now: DateTime(2026, 1, 1));
      expect(a.startsWith('c1~'), isTrue);
      expect(b.startsWith('c1~'), isTrue);
      expect(a == b, isFalse);
    });

    test('nextName 自动避开重名', () async {
      expect(await ChatIndex.nextName('c1'), '新聊天');
      await ChatIndex.touch('c1', convId: 'c1~1', messageCount: 0, name: '新聊天');
      expect(await ChatIndex.nextName('c1'), '新聊天 2');
      expect(await ChatIndex.nextName('c1', base: '分支'), '分支');
    });

    test('坏数据当空，不抛异常', () async {
      SharedPreferences.setMockInitialValues({
        'chat_index_c1': 'not-json',
      });
      ChatIndex.resetForTest();
      expect(await ChatIndex.load('c1'), isEmpty);

      SharedPreferences.setMockInitialValues({
        'chat_index_c1': '[{"id":""},{"id":"ok","name":"A","updatedAt":5}]',
      });
      ChatIndex.resetForTest();
      final chats = await ChatIndex.load('c1');
      expect(chats.length, 1);
      expect(chats.single.id, 'ok');
    });
  });

  group('BookmarkStore', () {
    test('toggle 加入与取消，contains 跟踪状态', () async {
      const ts = 1700000000000;
      final b = ChatBookmark(
        timestamp: ts,
        role: 'assistant',
        preview: '一段值得回看的话',
        createdAt: 1,
      );
      expect(await BookmarkStore.contains('conv', ts), isFalse);
      expect(await BookmarkStore.toggle('conv', b), isTrue);
      expect(await BookmarkStore.contains('conv', ts), isTrue);
      expect(await BookmarkStore.toggle('conv', b), isFalse);
      expect(await BookmarkStore.load('conv'), isEmpty);
    });

    test('同一会话多个书签按创建时间排序，不同会话互不影响', () async {
      await BookmarkStore.toggle(
        'a',
        const ChatBookmark(
          timestamp: 2,
          role: 'user',
          preview: 'late',
          createdAt: 20,
        ),
      );
      await BookmarkStore.toggle(
        'a',
        const ChatBookmark(
          timestamp: 1,
          role: 'assistant',
          preview: 'early',
          createdAt: 10,
        ),
      );
      await BookmarkStore.toggle(
        'b',
        const ChatBookmark(
          timestamp: 3,
          role: 'assistant',
          preview: 'other',
          createdAt: 30,
        ),
      );
      final a = await BookmarkStore.load('a');
      expect(a.map((x) => x.timestamp).toList(), [1, 2]);
      expect(a.first.preview, 'early');
      expect((await BookmarkStore.load('b')).length, 1);
      expect(await BookmarkStore.load(''), isEmpty);
    });

    test('remove / clear', () async {
      await BookmarkStore.toggle(
        'a',
        const ChatBookmark(
          timestamp: 7,
          role: 'user',
          preview: 'x',
          createdAt: 1,
        ),
      );
      await BookmarkStore.remove('a', 7);
      expect(await BookmarkStore.load('a'), isEmpty);

      await BookmarkStore.toggle(
        'a',
        const ChatBookmark(
          timestamp: 8,
          role: 'user',
          preview: 'y',
          createdAt: 2,
        ),
      );
      await BookmarkStore.clear('a');
      expect(await BookmarkStore.load('a'), isEmpty);
    });

    test('previewOf 压平空白并截断', () {
      expect(ChatBookmark.previewOf('  你好\n\n世界  '), '你好 世界');
      final long = '很' * 200;
      final cut = ChatBookmark.previewOf(long, max: 20);
      expect(cut.endsWith('…'), isTrue);
      expect(cut.length, 21);
    });

    test('坏 JSON 当空', () async {
      SharedPreferences.setMockInitialValues({
        'chat_bookmarks_conv': 'oops',
      });
      BookmarkStore.resetForTest();
      expect(await BookmarkStore.load('conv'), isEmpty);
    });
  });
}
