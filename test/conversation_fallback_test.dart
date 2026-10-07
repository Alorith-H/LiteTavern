import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/summarize.dart';

// 回归测试：loadConversationData 的 fallback 返回 const 空列表时，
// 会话页 _doSend 里 _messages.add() 抛
// "Unsupported operation: Cannot add to an unmodifiable list"
// （新群聊消息发不出去，logcat 已复现）。

ChatMessage _msg(String role, String content, {int ts = 0}) => ChatMessage(
      role: role,
      content: content,
      timestamp: ts,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('litetavern_conv_test');
    Storage.initForTest(docs);
    Directory('${docs.path}/conversations').createSync(recursive: true);
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  Future<void> writeFile(String convId, String content) =>
      File('${docs.path}/conversations/$convId.json').writeAsString(content);

  // ==================== fallback 可增长（根因回归，7） ====================

  group('loadConversationData fallback 必须可 add', () {
    test('会话文件不存在 → 可 add（新群聊发不出消息的根因路径）', () async {
      final data =
          await Storage.loadConversationData(Storage.groupConvId('no_group'));
      expect(data.messages, isEmpty);
      // 模拟 _doSend：user 消息 + assistant 占位，正是崩溃点的两次 add
      data.messages.add(_msg('user', '大家好'));
      data.messages.add(_msg('assistant', ''));
      expect(data.messages, hasLength(2));
    });

    test('会话文件是坏 JSON（解析抛异常）→ 可 add', () async {
      await writeFile('corrupt', '{oops not json');
      final data = await Storage.loadConversationData('corrupt');
      expect(data.messages, isEmpty);
      expect(() => data.messages.add(_msg('user', 'x')), returnsNormally);
      expect(data.messages, hasLength(1));
    });

    test('会话 JSON 是标量（既非数组非对象）→ 可 add', () async {
      await writeFile('scalar', '42');
      final data = await Storage.loadConversationData('scalar');
      expect(data.messages, isEmpty);
      expect(() => data.messages.add(_msg('user', 'x')), returnsNormally);
    });

    test('消息条目内容类型错误（fromJson 抛异常）→ 可 add', () async {
      await writeFile(
          'badentry', jsonEncode([
        {'content': 42},
      ]));
      final data = await Storage.loadConversationData('badentry');
      expect(data.messages, isEmpty);
      expect(() => data.messages.add(_msg('user', 'x')), returnsNormally);
    });

    test('对象格式但 messages 字段不是数组 → 可 add', () async {
      await writeFile('badfield', jsonEncode({'messages': 'oops'}));
      final data = await Storage.loadConversationData('badfield');
      expect(data.messages, isEmpty);
      expect(() => data.messages.add(_msg('user', 'x')), returnsNormally);
    });

    test('deleteConversation 后再读 → 可 add', () async {
      await writeFile('todelete', jsonEncode([
        {'role': 'user', 'content': 'hi', 'timestamp': 1},
      ]));
      await Storage.deleteConversation('todelete');
      final data = await Storage.loadConversationData('todelete');
      expect(data.messages, isEmpty);
      expect(() => data.messages.add(_msg('user', 'x')), returnsNormally);
    });

    test('loadConversation 包装（无文件）→ 可 add', () async {
      final messages = await Storage.loadConversation('never_saved');
      expect(messages, isEmpty);
      expect(() => messages.add(_msg('user', 'x')), returnsNormally);
    });
  });

  // ==================== ConversationData 构造（3） ====================

  group('ConversationData', () {
    test('空 ConversationData 的默认列表可 add', () {
      final data = ConversationData(messages: <ChatMessage>[]);
      data.messages.add(_msg('user', 'x'));
      expect(data.messages, hasLength(1));
    });

    test('每次构造得到独立列表，不共享', () {
      final a = ConversationData(messages: <ChatMessage>[]);
      final b = ConversationData(messages: <ChatMessage>[]);
      a.messages.add(_msg('user', 'x'));
      expect(b.messages, isEmpty);
    });

    test('const 空列表确实不可 add（根因本身，文档化）', () {
      const data = ConversationData(messages: []);
      expect(() => data.messages.add(_msg('user', 'x')), throwsUnsupportedError);
    });
  });

  // ==================== 正常加载同样可增长（4） ====================

  group('正常读写的会话列表也可增长', () {
    test('旧数组格式：保存→读取→可 add，内容往返', () async {
      await Storage.saveConversation('legacy', [
        _msg('assistant', '开场白', ts: 1),
      ]);
      final data = await Storage.loadConversationData('legacy');
      expect(data.messages, hasLength(1));
      expect(data.messages.first.content, '开场白');
      expect(data.summary, isNull);
      data.messages.add(_msg('user', '你好'));
      expect(data.messages, hasLength(2));
    });

    test('新对象格式（带摘要）：保存→读取→可 add，摘要往返', () async {
      const summary = ChatSummary(text: '前情提要', updatedAt: 99);
      await Storage.saveConversation('with_summary', [
        _msg('user', 'hi', ts: 1),
        _msg('assistant', 'hello', ts: 2),
      ], summary: summary);
      final data = await Storage.loadConversationData('with_summary');
      expect(data.messages, hasLength(2));
      expect(data.summary?.text, '前情提要');
      expect(data.summary?.updatedAt, 99);
      data.messages.add(_msg('user', '继续'));
      expect(data.messages, hasLength(3));
    });

    test('空摘要写回旧数组格式（单聊文件字节不变），读取可 add', () async {
      await Storage.saveConversation(
          'empty_summary', [_msg('user', 'hi', ts: 1)],
          summary: const ChatSummary(text: '   ', updatedAt: 1));
      final raw =
          await File('${docs.path}/conversations/empty_summary.json')
              .readAsString();
      expect(jsonDecode(raw), isA<List>()); // 仍是数组格式
      final data = await Storage.loadConversationData('empty_summary');
      expect(() => data.messages.add(_msg('user', 'x')), returnsNormally);
    });

    test('数组格式夹杂非对象条目 → 过滤后仍可 add', () async {
      await writeFile('mixed', jsonEncode([
        {'role': 'user', 'content': 'hi', 'timestamp': 1},
        42,
        'junk',
      ]));
      final data = await Storage.loadConversationData('mixed');
      expect(data.messages, hasLength(1));
      expect(data.messages.first.content, 'hi');
      expect(() => data.messages.add(_msg('user', 'x')), returnsNormally);
    });
  });
}
