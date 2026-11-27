import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/models/chat_group.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/screens/group_host_screen.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/storage.dart';

CharacterCard _card(String id, String name) => CharacterCard(
      id: id,
      name: name,
      description: '角色 $name',
      personality: '',
      scenario: '',
      firstMes: '',
      mesExample: '',
      systemPrompt: '',
      alternateGreetings: const [],
      tags: const [],
      creator: 'test',
    );

ChatGroup _group({List<String> speakers = const [], int turnIndex = 0}) =>
    ChatGroup(
      id: 'g1',
      name: '测试群',
      memberIds: const ['a', 'b', 'c'],
      createdAt: 1000,
      turnIndex: turnIndex,
      speakerIds: speakers,
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
  });

  group('ChatGroup 发言名单', () {
    test('json 往返保留名单与顺序', () {
      final g = _group(speakers: const ['c', 'a']);
      final back = ChatGroup.fromJson(jsonDecode(jsonEncode(g.toJson())));
      expect(back.speakerIds, ['c', 'a']);
      expect(back.speakerIndexes(), [2, 0]);
    });

    test('名单为空时不写进 json，且语义是全员', () {
      final g = _group();
      expect(g.toJson().containsKey('speakerIds'), isFalse);
      expect(g.speakerIndexes(), [0, 1, 2]);
    });

    test('speakerIndexes 过滤已不存在的成员并去重', () {
      final g = _group(speakers: const ['b', 'gone', 'b', 'a']);
      expect(g.speakerIndexes(), [1, 0]);
    });

    test('withSpeakerIds 只换名单，其它字段不变', () {
      final g = _group(turnIndex: 2);
      final next = g.withSpeakerIds(const ['b']);
      expect(next.speakerIds, ['b']);
      expect(next.turnIndex, 2);
      expect(next.memberIds, g.memberIds);
      expect(next.id, g.id);
    });
  });

  group('hostedTurnOrder', () {
    test('名单为空时全员轮转', () {
      expect(hostedTurnOrder(3, const [], 0, null), [0, 1, 2]);
      expect(hostedTurnOrder(3, const [], 2, null), [2, 0, 1]);
    });

    test('按名单顺序，从指针所在成员起轮转', () {
      expect(hostedTurnOrder(3, const [2, 0], 0, null), [0, 2]);
      expect(hostedTurnOrder(3, const [2, 0], 2, null), [2, 0]);
    });

    test('指针不在名单里时从名单第一位开始', () {
      expect(hostedTurnOrder(3, const [2], 0, null), [2]);
      expect(hostedTurnOrder(3, const [1, 2], 99, null), [1, 2]);
    });

    test('@ 点名只取名单内的成员', () {
      expect(hostedTurnOrder(3, const [2, 0], 0, {0, 1, 2}), [2, 0]);
      expect(hostedTurnOrder(3, const [2], 0, {0}), isEmpty);
    });

    test('成员数为 0 时返回空', () {
      expect(hostedTurnOrder(0, const [], 0, null), isEmpty);
    });
  });

  group('advanceHostTurn', () {
    test('名单内下一位，绕回第一位', () {
      expect(advanceHostTurn(3, const [2, 0], 0), 2);
      expect(advanceHostTurn(3, const [2, 0], 2), 0);
    });

    test('名单为空时退回全员轮转', () {
      expect(advanceHostTurn(3, const [], 1), 2);
    });

    test('发言者不在名单里时回到名单第一位', () {
      expect(advanceHostTurn(3, const [1, 2], 0), 1);
    });
  });

  group('PromptBuilder.buildGroup(hostNudge:)', () {
    List<PromptMessage> build(String? nudge) => PromptBuilder.buildGroup(
          members: [_card('a', '阿青'), _card('b', '阿白')],
          history: [
            const ChatMessage(role: 'user', content: '你好', timestamp: 1000),
          ],
          worldBooks: const [],
          userName: '我',
          speakerName: '阿青',
          historyLimit: 20,
          hostNudge: nudge,
        ).messages;

    test('末尾追加一条 user 临时提示', () {
      final messages = build('（没有新的用户发言，接着聊。）');
      expect(messages.last.role, 'user');
      expect(messages.last.content, contains('接着聊'));
    });

    test('提示里的 {{char}} 会按当前发言者替换', () {
      final messages = build('现在由 {{char}} 接着说。');
      expect(messages.last.content, '现在由 阿青 接着说。');
    });

    test('不传/传空时不多加消息', () {
      final plain = build(null);
      final blank = build('   ');
      expect(plain.length, blank.length);
      expect(plain.last.content, endsWith('你好'));
    });
  });

  group('GroupHostScreen', () {
    Finder checkOf(String name) => find.descendant(
          of: find.widgetWithText(ListTile, name),
          matching: find.byType(Checkbox),
        );
    Future<void> pump(WidgetTester tester, List<ChatGroup> captured) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: GroupHostScreen(
          group: _group(),
          members: [_card('a', '阿青'), _card('b', '阿白'), _card('c', '阿玄')],
          onChanged: captured.add,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('默认全员，取消勾选后名单只剩两位', (tester) async {
      final captured = <ChatGroup>[];
      await pump(tester, captured);
      expect(find.text('阿青'), findsOneWidget);
      expect(find.textContaining('全员轮流'), findsWidgets);

      await tester.tap(checkOf('阿白'));
      await tester.pumpAndSettle();
      expect(captured, isNotEmpty);
      expect(captured.last.speakerIds, ['a', 'c']);
    });

    testWidgets('共 3 个成员只允许取消到剩 1 位（空名单是全员语义）', (tester) async {
      final captured = <ChatGroup>[];
      await pump(tester, captured);
      await tester.tap(checkOf('阿青'));
      await tester.pumpAndSettle();
      await tester.tap(checkOf('阿白'));
      await tester.pumpAndSettle();
      expect(captured.last.speakerIds, ['c']);
      await tester.tap(checkOf('阿玄'));
      await tester.pumpAndSettle();
      // 全部取消会被拦下，名单保持
      expect(captured.last.speakerIds, ['c']);
      expect(find.textContaining('至少留一位发言人'), findsOneWidget);
    });

    testWidgets('上移/下移会改顺序', (tester) async {
      final captured = <ChatGroup>[];
      await pump(tester, captured);
      await tester.tap(find.byTooltip('上移').at(1));
      await tester.pumpAndSettle();
      expect(captured.last.speakerIds, ['b', 'a', 'c']);
      await tester.tap(find.byTooltip('下移').at(0));
      await tester.pumpAndSettle();
      expect(captured.last.speakerIds, ['a', 'b', 'c']);
    });
  });
}
