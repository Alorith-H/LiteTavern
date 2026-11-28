import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/services/chat_image_export.dart';
import 'package:litetavern/services/chat_index_cache.dart';
import 'package:litetavern/services/chat_transcript.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/summarize.dart';

/// v0.42.0：会话增量保存（快照 + 日志）、搜索/统计索引缓存、长图进度。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
    docs = Directory.systemTemp.createTempSync('lt_v42_');
    Storage.initForTest(docs);
    ChatIndexCache.instance.resetForTest();
  });

  tearDown(() {
    try {
      docs.deleteSync(recursive: true);
    } catch (_) {}
  });

  ChatMessage msg(String role, String content, {int ts = 0, bool hidden = false}) =>
      ChatMessage(role: role, content: content, timestamp: ts, hidden: hidden);

  File convFile(String id) => File('${docs.path}/conversations/$id.json');
  File journalFile(String id) => File('${docs.path}/conversations/$id.journal');

  group('会话增量保存', () {
    test('第一次保存仍是旧数组格式（字节兼容）', () async {
      await Storage.saveConversation('c1', [msg('user', 'hi', ts: 1)]);
      final raw = jsonDecode(await convFile('c1').readAsString());
      expect(raw, isA<List>());
      expect(await journalFile('c1').exists(), isFalse);
    });

    test('第二次保存只写日志，快照文件保持不变', () async {
      await Storage.saveConversation('c2', [msg('user', 'a', ts: 1)]);
      final before = await convFile('c2').readAsString();
      await Storage.saveConversation('c2', [
        msg('user', 'a', ts: 1),
        msg('assistant', 'b', ts: 2),
      ]);
      expect(await convFile('c2').readAsString(), before);
      final lines = await journalFile('c2').readAsLines();
      expect(lines.where((l) => l.trim().isNotEmpty).length, 1);
      expect(jsonDecode(lines.first)['o'], 'a');
    });

    test('重载时重放日志，内容与写入一致', () async {
      await Storage.saveConversation('c3', [msg('user', 'a', ts: 1)]);
      final two = [msg('user', 'a', ts: 1), msg('assistant', 'b', ts: 2)];
      await Storage.saveConversation('c3', two);
      // 清掉进程内缓存，强制从磁盘（快照 + 日志）恢复
      Storage.initForTest(docs);
      final data = await Storage.loadConversationData('c3');
      expect(data.messages.map((m) => m.content), ['a', 'b']);
    });

    test('编辑已有消息写成 upsert，重放后文本更新', () async {
      await Storage.saveConversation('c4', [msg('user', 'a', ts: 1)]);
      await Storage.saveConversation('c4', [msg('user', 'a2', ts: 1)]);
      Storage.initForTest(docs);
      final data = await Storage.loadConversationData('c4');
      expect(data.messages.single.content, 'a2');
    });

    test('删除尾部消息写成截断，重放后条数变少', () async {
      await Storage.saveConversation('c5', [
        msg('user', 'a', ts: 1),
        msg('assistant', 'b', ts: 2),
      ]);
      await Storage.saveConversation('c5', [msg('user', 'a', ts: 1)]);
      Storage.initForTest(docs);
      final data = await Storage.loadConversationData('c5');
      expect(data.messages, hasLength(1));
    });

    test('摘要变化与统计变化也进日志', () async {
      await Storage.saveConversation('c6', [msg('user', 'a', ts: 1)]);
      await Storage.saveConversation(
        'c6',
        [msg('user', 'a', ts: 1)],
        summary: const ChatSummary(text: '前情', updatedAt: 3),
      );
      Storage.initForTest(docs);
      final data = await Storage.loadConversationData('c6');
      expect(data.summary?.text, '前情');
      expect(data.summary?.updatedAt, 3);
    });

    test('日志超过阈值自动合并：快照带 gen、日志被清空、重载内容正确', () async {
      final all = <ChatMessage>[];
      for (var i = 0; i < 405; i++) {
        all.add(msg(i.isEven ? 'user' : 'assistant', 'm$i', ts: i + 1));
        await Storage.saveConversation('c7', all);
      }
      // 合并后仍是对象格式并带 gen；合并之后的新改动会继续写日志（条数已回落）
      final raw = jsonDecode(await convFile('c7').readAsString());
      expect(raw, isA<Map<String, dynamic>>());
      expect(raw['gen'], greaterThanOrEqualTo(1));
      final lines = (await journalFile('c7').readAsLines())
          .where((l) => l.trim().isNotEmpty)
          .length;
      expect(lines, lessThan(400));
      Storage.initForTest(docs);
      final data = await Storage.loadConversationData('c7');
      expect(data.messages, hasLength(405));
      expect(data.messages.last.content, 'm404');
    });

    test('损坏的日志行被跳过，其余行仍生效', () async {
      await Storage.saveConversation('c8', [msg('user', 'a', ts: 1)]);
      await Storage.saveConversation('c8', [
        msg('user', 'a', ts: 1),
        msg('assistant', 'b', ts: 2),
      ]);
      await journalFile('c8').writeAsString(
        '{坏行\n${jsonEncode({'o': 'a', 'g': 0, 'm': msg('assistant', 'c', ts: 3).toJson()})}\n',
        mode: FileMode.append,
      );
      Storage.initForTest(docs);
      final data = await Storage.loadConversationData('c8');
      expect(data.messages.map((m) => m.content), ['a', 'b', 'c']);
    });

    test('删除会话同时清掉日志文件', () async {
      await Storage.saveConversation('c9', [msg('user', 'a', ts: 1)]);
      await Storage.saveConversation('c9', [
        msg('user', 'a', ts: 1),
        msg('assistant', 'b', ts: 2),
      ]);
      expect(await journalFile('c9').exists(), isTrue);
      await Storage.deleteConversation('c9');
      expect(await convFile('c9').exists(), isFalse);
      expect(await journalFile('c9').exists(), isFalse);
    });
  });

  group('会话索引缓存', () {
    test('小写索引与统计只算一次，内容变化后会重建', () {
      final cache = ChatIndexCache.instance;
      final list = [
        msg('user', 'Hello', ts: 1),
        msg('assistant', 'WORLD', ts: 2),
      ];
      final lower = cache.lowerTexts(list);
      expect(lower, ['hello', 'world']);
      expect(identical(cache.lowerTexts(list), lower), isTrue);

      // 追加会改变条数 → 重新构建
      list.add(msg('user', 'Again', ts: 3));
      expect(cache.lowerTexts(list).last, 'again');
    });

    test('聚合统计：条数、角色计数与 token 合计', () {
      final agg = ChatIndexCache.instance.aggregates([
        ChatMessage(
          role: 'user',
          content: 'hi',
          timestamp: 1,
          promptTokens: 10,
          completionTokens: 5,
          cachedPromptTokens: 4,
        ),
        ChatMessage(role: 'assistant', content: 'yo', timestamp: 2),
        ChatMessage(
          role: 'assistant',
          content: 'hey',
          timestamp: 3,
          promptTokens: 20,
          completionTokens: 7,
          cachedPromptTokens: 999, // 超过 promptTokens，会被 clamp
          tokensEstimated: true,
        ),
      ]);
      expect(agg.messageCount, 3);
      expect(agg.userCount, 1);
      expect(agg.assistantCount, 2);
      expect(agg.promptTokens, 30);
      expect(agg.completionTokens, 12);
      expect(agg.cachedTokens, 24);
      expect(agg.hasUsage, isTrue);
      expect(agg.approx, isTrue);
    });

    test('invalidate 后统计归零，并支持 resetForTest', () {
      final cache = ChatIndexCache.instance;
      cache.aggregates([msg('user', 'x', ts: 1)]);
      cache.invalidate();
      cache.resetForTest();
      expect(cache.aggregates(const []).messageCount, 0);
    });
  });

  group('搜索用缓存索引', () {
    test('传入 lowerTexts 与内部转换结果一致', () {
      final messages = [
        msg('user', 'Hello World', ts: 1),
        msg('assistant', '没有命中', ts: 2),
        msg('user', 'hello again', ts: 3),
      ];
      final withIndex = searchMessages(
        messages,
        'hello',
        lowerTexts: ChatIndexCache.instance.lowerTexts(messages),
      );
      final without = searchMessages(messages, 'hello');
      expect(withIndex.map((h) => h.index), without.map((h) => h.index));
      expect(withIndex, hasLength(2));
    });

    test('长度不匹配的 lowerTexts 会被忽略（回退到实时转换）', () {
      final messages = [msg('user', 'Hello', ts: 1)];
      final hits = searchMessages(messages, 'hello', lowerTexts: const []);
      expect(hits, hasLength(1));
    });
  });

  group('长图导出进度', () {
    test('render 通过 onProgress 汇报进度，最后到 1.0', () async {
      final messages = [
        for (var i = 0; i < 120; i++)
          msg(i.isEven ? 'user' : 'assistant', '第 $i 条消息内容，测试长图进度', ts: i + 1),
      ];
      final values = <double>[];
      final bytes = await ChatImageExport.render(
        charName: '角色',
        userName: '你',
        messages: messages,
        onProgress: values.add,
      );
      expect(bytes.length, greaterThan(1000));
      expect(values, isNotEmpty);
      expect(values.last, 1.0);
      for (var i = 1; i < values.length; i++) {
        expect(values[i], greaterThanOrEqualTo(values[i - 1]));
      }
    });
  });
}
