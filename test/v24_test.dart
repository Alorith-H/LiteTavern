import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/services/chat_transcript.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/widgets/chat_search_sheet.dart';

ChatMessage _msg(
  String content, {
  String role = 'user',
  bool hidden = false,
  int? ts,
  String? senderName,
}) {
  return ChatMessage(
    role: role,
    content: content,
    timestamp: ts ?? DateTime(2026, 11, 27, 10).millisecondsSinceEpoch,
    hidden: hidden,
    senderName: senderName,
  );
}

CharacterCard _card() => const CharacterCard(
      name: '阿青',
      description: '沉默的剑客',
      personality: '冷静',
      scenario: '雨夜客栈',
      firstMes: '你来了。',
      mesExample: '',
      systemPrompt: '',
      alternateGreetings: [],
      tags: [],
      creator: 'test',
    );

void main() {
  group('ChatMessage.hidden（v0.24.0 对模型隐藏）', () {
    test('默认 false', () {
      expect(_msg('你好').hidden, isFalse);
    });

    test('toJson 只在隐藏时写入标记，fromJson 往返一致', () {
      expect(_msg('可见').toJson().containsKey('hidden'), isFalse);
      final hidden = _msg('隐藏', hidden: true);
      expect(hidden.toJson()['hidden'], isTrue);
      final back = ChatMessage.fromJson(hidden.toJson());
      expect(back.hidden, isTrue);
      expect(back.content, '隐藏');
    });

    test('旧数据缺字段 → false', () {
      final back = ChatMessage.fromJson({
        'role': 'user',
        'content': '旧消息',
        'timestamp': 1,
      });
      expect(back.hidden, isFalse);
    });

    test('copyWith 可以切换隐藏状态，也可以原样保留', () {
      final m = _msg('一条');
      expect(m.copyWith(hidden: true).hidden, isTrue);
      expect(m.copyWith(hidden: true).copyWith(hidden: false).hidden, isFalse);
      expect(m.copyWith(content: '改').hidden, isFalse);
    });
  });

  group('visibleForModel', () {
    test('过滤隐藏消息，保持原顺序', () {
      final list = [
        _msg('一'),
        _msg('二', hidden: true),
        _msg('三'),
        _msg('四', hidden: true),
      ];
      final visible = visibleForModel(list);
      expect(visible.map((m) => m.content), ['一', '三']);
    });

    test('没有隐藏消息时原样返回（不复制）', () {
      final list = [_msg('一'), _msg('二')];
      expect(identical(visibleForModel(list), list), isTrue);
    });

    test('全部隐藏 → 空列表', () {
      expect(
        visibleForModel([_msg('一', hidden: true)]),
        isEmpty,
      );
    });

    test('组 prompt 时隐藏消息不出现在 messages 里', () {
      final history = [
        _msg('你好', role: 'user'),
        _msg('这句不该发给模型', role: 'assistant', hidden: true),
        _msg('继续', role: 'user'),
      ];
      final built = PromptBuilder.build(
        card: _card(),
        history: visibleForModel(history),
        worldBooks: const [],
        userName: '你',
      );
      final all = built.messages.map((m) => m.content).join('\n');
      expect(all.contains('这句不该发给模型'), isFalse);
      expect(all.contains('你好'), isTrue);
      expect(all.contains('继续'), isTrue);
    });
  });

  group('searchMessages（v0.24.0 对话内搜索）', () {
    final messages = [
      _msg('今天想吃苹果派'),
      _msg('苹果派是什么味道', role: 'assistant'),
      _msg('我们去看苹果树吧'),
      _msg('橘子也不错'),
    ];

    test('按消息顺序返回全部命中', () {
      final hits = searchMessages(messages, '苹果');
      expect(hits.map((h) => h.index), [0, 1, 2]);
      expect(hits.first.message.content, contains('苹果'));
    });

    test('大小写不敏感（英文）', () {
      final list = [_msg('Hello World'), _msg('hello again')];
      expect(searchMessages(list, 'HELLO').length, 2);
    });

    test('空关键词 / 纯空白 → 空结果', () {
      expect(searchMessages(messages, ''), isEmpty);
      expect(searchMessages(messages, '   '), isEmpty);
    });

    test('没有命中 → 空', () {
      expect(searchMessages(messages, '香蕉'), isEmpty);
    });

    test('片段包含命中词，长文本两端加省略号', () {
      final long = _msg('${'前' * 60}关键词${'后' * 60}');
      final hit = searchMessages([long], '关键词').single;
      expect(hit.snippet, contains('关键词'));
      expect(hit.snippet.startsWith('…'), isTrue);
      expect(hit.snippet.endsWith('…'), isTrue);
      expect(hit.snippet.length < 200, isTrue);
      expect(hit.matchStart, 60);
    });

    test('隐藏的消息也能被搜到（本地仍然可见）', () {
      final list = [_msg('隐藏的苹果', hidden: true)];
      final hit = searchMessages(list, '苹果').single;
      expect(hit.message.hidden, isTrue);
      expect(hit.index, 0);
    });

    test('max 限制结果条数', () {
      final list = [for (var i = 0; i < 10; i++) _msg('重复的苹果 $i')];
      expect(searchMessages(list, '苹果', max: 3).length, 3);
      expect(searchMessages(list, '苹果', max: 0), isEmpty);
    });

    test('isUser 正确区分发言方', () {
      final hits = searchMessages(messages, '苹果');
      expect(hits[0].isUser, isTrue);
      expect(hits[1].isUser, isFalse);
    });
  });

  group('ChatSearchSheet', () {
    Future<int?> openAndPick(
      WidgetTester tester,
      List<ChatMessage> messages,
      String query,
      int resultIndex,
    ) async {
      int? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  picked = await showChatSearchSheet(
                    ctx,
                    messages: messages,
                    assistantName: '阿青',
                  );
                },
                child: const Text('打开搜索'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开搜索'));
      await tester.pumpAndSettle();
      expect(find.textContaining('只在本机这段聊天里找'), findsOneWidget);
      await tester.enterText(find.byType(TextField), query);
      await tester.pumpAndSettle();
      if (resultIndex >= 0) {
        final tiles = find.byType(ListTile);
        expect(tiles, findsWidgets);
        await tester.tap(tiles.at(resultIndex));
        await tester.pumpAndSettle();
      }
      return picked;
    }

    testWidgets('输入关键词出现结果，点选返回消息下标', (tester) async {
      final messages = [
        _msg('今天想吃苹果派'),
        _msg('苹果派是什么味道', role: 'assistant', senderName: '阿青'),
      ];
      final picked = await openAndPick(tester, messages, '苹果', 1);
      expect(picked, 1);
    });

    testWidgets('没有命中显示提示', (tester) async {
      final messages = [_msg('今天想吃苹果派')];
      await openAndPick(tester, messages, '香蕉', -1);
      expect(find.textContaining('没有找到'), findsOneWidget);
    });
  });
}
