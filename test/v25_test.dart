import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/services/chat_epub_export.dart';
import 'package:litetavern/services/chat_export_files.dart';
import 'package:litetavern/services/chat_image_export.dart';
import 'package:litetavern/services/chat_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatMessage _msg(String role, String content, {int ts = 1000, String? sender}) =>
    ChatMessage(
      role: role,
      content: content,
      timestamp: ts,
      senderName: sender,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatInfo 分支字段（v0.25.0）', () {
    test('parentId / forkIndex 往返，isBranch 正确', () {
      const info = ChatInfo(
        id: 'c1',
        name: '分支',
        parentId: 'root',
        forkIndex: 3,
      );
      final back = ChatInfo.fromJson(info.toJson());
      expect(back.parentId, 'root');
      expect(back.forkIndex, 3);
      expect(back.isBranch, isTrue);
    });

    test('旧数据没有分支字段 → parentId 为 null、isBranch false', () {
      final back = ChatInfo.fromJson(<String, dynamic>{
        'id': 'old',
        'name': '老聊天',
        'updatedAt': 1,
        'messageCount': 2,
      });
      expect(back.parentId, isNull);
      expect(back.forkIndex, isNull);
      expect(back.isBranch, isFalse);
      expect(back.toJson().containsKey('parentId'), isFalse);
    });

    test('空白 parentId 视为无父节点', () {
      final back = ChatInfo.fromJson(<String, dynamic>{
        'id': 'x',
        'name': 'x',
        'parentId': '   ',
      });
      expect(back.parentId, isNull);
    });
  });

  group('ChatIndex.tree', () {
    ChatInfo c(String id, {String? parent, int at = 0, int? fork}) => ChatInfo(
          id: id,
          name: id,
          parentId: parent,
          forkIndex: parent == null ? null : fork,
          updatedAt: at,
        );

    test('根按最近使用排序，子分支紧跟父节点且深度 +1', () {
      final nodes = ChatIndex.tree([
        c('rootA', at: 100),
        c('rootB', at: 200),
        c('kid1', parent: 'rootA', at: 50),
        c('kid2', parent: 'rootA', at: 60),
        c('grand', parent: 'kid2', at: 70),
      ]);
      expect(nodes.map((n) => n.info.id).toList(),
          ['rootB', 'rootA', 'kid2', 'grand', 'kid1']);
      expect(nodes.map((n) => n.depth).toList(), [0, 0, 1, 2, 1]);
    });

    test('父节点不存在的孤儿当作根', () {
      final nodes = ChatIndex.tree([
        c('orphan', parent: 'missing', at: 10),
        c('root', at: 20),
      ]);
      expect(nodes.map((n) => n.info.id).toList(), ['root', 'orphan']);
      expect(nodes.last.depth, 0);
    });

    test('自己指向自己不会死循环', () {
      final nodes = ChatIndex.tree([c('self', parent: 'self')]);
      expect(nodes, hasLength(1));
      expect(nodes.single.depth, 0);
    });

    test('空列表 → 空树', () {
      expect(ChatIndex.tree(const []), isEmpty);
    });
  });

  group('ChatEpubExport', () {
    Uint8List bytesOf(List<ChatMessage> messages) => ChatEpubExport.build(
          charName: '智子',
          userName: '我',
          messages: messages,
          exportedAt: DateTime(2026, 11, 27, 18, 30),
        );

    test('生成可解包的 EPUB：mimetype / container / opf / nav / chapter', () {
      final bytes = bytesOf([
        _msg('assistant', '你好 & <欢迎>'),
        _msg('user', '第二句'),
      ]);
      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.files.map((f) => f.name).toList();
      expect(names.first, 'mimetype');
      expect(names, contains('META-INF/container.xml'));
      expect(names, contains('OEBPS/content.opf'));
      expect(names, contains('OEBPS/nav.xhtml'));
      expect(names, contains('OEBPS/chapter1.xhtml'));
      expect(names, contains('OEBPS/style.css'));

      final chapter = utf8.decode(
        archive.files.firstWhere((f) => f.name == 'OEBPS/chapter1.xhtml').content,
      );
      expect(chapter, contains('你好 &amp; &lt;欢迎&gt;'));
      expect(chapter, contains('第二句'));
      expect(chapter, contains('class="msg user"'));
      expect(chapter, contains('共 2 条'));
    });

    test('空消息被跳过，正文条数只算非空', () {
      final bytes = bytesOf([
        _msg('user', '   '),
        _msg('assistant', '有内容'),
      ]);
      final archive = ZipDecoder().decodeBytes(bytes);
      final chapter = utf8.decode(
        archive.files.firstWhere((f) => f.name == 'OEBPS/chapter1.xhtml').content,
      );
      expect(chapter, contains('共 1 条'));
      expect(chapter, isNot(contains('class="msg user"')));
    });

    test('content.opf 带书名、语言与 manifest', () {
      final bytes = bytesOf([_msg('user', 'hi')]);
      final archive = ZipDecoder().decodeBytes(bytes);
      final opf = utf8.decode(
        archive.files.firstWhere((f) => f.name == 'OEBPS/content.opf').content,
      );
      expect(opf, contains('和 智子 的对话'));
      expect(opf, contains('zh-CN'));
      expect(opf, contains('chapter1.xhtml'));
      expect(opf, contains('dcterms:modified'));
    });
  });

  group('ChatImageExport', () {
    test('生成 PNG 字节（头部魔数正确）', () async {
      final bytes = await ChatImageExport.render(
        charName: '智子',
        userName: '我',
        messages: [
          _msg('assistant', '这是第一条回复，内容稍微长一点，用来测试自动换行是否正常。'),
          _msg('user', '这是第二条。'),
        ],
        exportedAt: DateTime(2026, 11, 27, 18, 30),
      );
      expect(bytes.length, greaterThan(1024));
      expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    });

    test('消息越多图越高（按高度累加）', () async {
      Future<int> heightOf(int count) async {
        final bytes = await ChatImageExport.render(
          charName: '角色',
          userName: '我',
          messages: [
            for (var i = 0; i < count; i++) _msg('assistant', '第 $i 条消息'),
          ],
          exportedAt: DateTime(2026, 11, 27),
        );
        // PNG IHDR：宽高在 16..24 字节（大端）
        final h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
        return h;
      }

      final h1 = await heightOf(2);
      final h2 = await heightOf(12);
      expect(h2, greaterThan(h1));
    });

    test('隐藏消息也会画出「对模型隐藏」标注', () async {
      final hidden = ChatMessage(
        role: 'assistant',
        content: '这条藏起来了',
        timestamp: 1,
        hidden: true,
      );
      final bytes = await ChatImageExport.render(
        charName: '角色',
        userName: '我',
        messages: [hidden],
        exportedAt: DateTime(2026, 11, 27),
      );
      expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    });
  });

  group('ChatExportFormat', () {
    test('四种格式的标签、扩展名与二进制标记', () {
      expect(ChatExportFormat.values.map((f) => f.extension).toList(),
          ['txt', 'json', 'png', 'epub']);
      expect(ChatExportFormat.image.isBinary, isTrue);
      expect(ChatExportFormat.epub.isBinary, isTrue);
      expect(ChatExportFormat.text.isBinary, isFalse);
      expect(ChatExportFormat.json.isBinary, isFalse);
      expect(ChatExportFormat.epub.label, contains('epub'));
    });
  });

  group('设置/索引落盘', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      ChatIndex.resetForTest();
    });

    test('touch 兼容旧参数，tree 能读到 index 里的父子关系', () async {
      final rootId = ChatIndex.newId('char1', now: DateTime(2026, 11, 27));
      await ChatIndex.touch('char1',
          convId: rootId, messageCount: 3, name: '主线', updatedAt: 100);
      final childId = ChatIndex.newId('char1', now: DateTime(2026, 11, 28));
      await ChatIndex.touch(
        'char1',
        convId: childId,
        messageCount: 2,
        name: '分支',
        updatedAt: 200,
        parentId: rootId,
        forkIndex: 1,
      );
      final chats = await ChatIndex.load('char1');
      final branch = chats.firstWhere((c) => c.id == childId);
      expect(branch.parentId, rootId);
      expect(branch.forkIndex, 1);

      final nodes = ChatIndex.tree(chats);
      expect(nodes.map((n) => n.info.id).toList(), [rootId, childId]);
      expect(nodes.map((n) => n.depth).toList(), [0, 1]);
    });
  });
}
