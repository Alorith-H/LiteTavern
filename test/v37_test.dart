import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/screens/settings_screen.dart';
import 'package:litetavern/services/chat_layout.dart';
import 'package:litetavern/services/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
    Storage.initForTest(
      Directory.systemTemp.createTempSync('lt_v37_appearance_'),
    );
  });

  group('ChatLayout 值对象', () {
    test('chatLayoutFromId 识别两种模式，未知回落气泡', () {
      expect(chatLayoutFromId('bubble'), ChatLayout.bubble);
      expect(chatLayoutFromId('novel'), ChatLayout.novel);
      expect(chatLayoutFromId(''), ChatLayout.bubble);
      expect(chatLayoutFromId(null), ChatLayout.bubble);
      expect(chatLayoutFromId('some-unknown'), ChatLayout.bubble);
    });

    test('label / description / id 均非空且互不相同', () {
      for (final layout in ChatLayout.values) {
        expect(layout.label, isNotEmpty);
        expect(layout.description, isNotEmpty);
        expect(layout.id, isNotEmpty);
      }
      expect(ChatLayout.bubble.label, '气泡');
      expect(ChatLayout.novel.label, '小说');
      expect(
        ChatLayout.bubble.description,
        isNot(ChatLayout.novel.description),
      );
      expect(ChatLayout.bubble.id, isNot(ChatLayout.novel.id));
    });
  });

  group('MessageLayoutStyle', () {
    test('气泡模式：你的话靠右、最宽 78%、有气泡底色', () {
      final mine =
          MessageLayoutStyle.of(ChatLayout.bubble, isUser: true);
      expect(mine.bubble, isTrue);
      expect(mine.alignRight, isTrue);
      expect(mine.maxWidthFactor, closeTo(0.78, 1e-9));
      expect(mine.horizontalPadding, 14);
      expect(mine.userAccentBar, isFalse);

      final theirs =
          MessageLayoutStyle.of(ChatLayout.bubble, isUser: false);
      expect(theirs.bubble, isTrue);
      expect(theirs.alignRight, isFalse);
      expect(theirs.maxWidthFactor, closeTo(0.78, 1e-9));
    });

    test('小说模式：整行、不靠右、无气泡；你的话带左侧细线', () {
      final mine = MessageLayoutStyle.of(ChatLayout.novel, isUser: true);
      expect(mine.bubble, isFalse);
      expect(mine.alignRight, isFalse);
      expect(mine.maxWidthFactor, closeTo(1.0, 1e-9));
      expect(mine.userAccentBar, isTrue);
      expect(mine.horizontalPadding, greaterThan(0));

      final theirs =
          MessageLayoutStyle.of(ChatLayout.novel, isUser: false);
      expect(theirs.bubble, isFalse);
      expect(theirs.alignRight, isFalse);
      expect(theirs.userAccentBar, isFalse);
      expect(theirs.horizontalPadding, lessThan(mine.horizontalPadding));
    });

    test('小说模式行距更松，读起来像分段', () {
      final bubble = MessageLayoutStyle.of(ChatLayout.bubble, isUser: false);
      final novel = MessageLayoutStyle.of(ChatLayout.novel, isUser: false);
      expect(novel.verticalMargin, greaterThan(bubble.verticalMargin));
      expect(novel.verticalPadding, lessThan(bubble.verticalPadding));
    });
  });

  group('AppSettings.chatLayout', () {
    test('默认是气泡', () {
      expect(AppSettings.chatLayout, ChatLayout.bubble);
    });

    test('写入后读回，落在 chat_layout 键上', () async {
      AppSettings.chatLayout = ChatLayout.novel;
      expect(AppSettings.chatLayout, ChatLayout.novel);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('chat_layout'), 'novel');
    });

    test('旧数据没有这个键时回落气泡', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('chat_layout');
      expect(AppSettings.chatLayout, ChatLayout.bubble);
    });
  });

  group('设置页（外观与显示 → 排版与显示，v0.40.1 起）', () {
    testWidgets('显示对话排版当前值，切换成小说后落盘', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SettingsScreen(section: SettingsSection.appearance),
        ),
      );
      await tester.pumpAndSettle();

      // 「显示」分组在页面下方，先滚到能看见
      await tester.scrollUntilVisible(
        find.text('对话排版'),
        260,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('对话排版'), findsOneWidget);
      expect(find.textContaining('当前 气泡'), findsOneWidget);

      await tester.tap(find.text('对话排版'));
      await tester.pumpAndSettle();
      expect(find.text('小说'), findsOneWidget);

      await tester.tap(find.text('小说'));
      await tester.pumpAndSettle();

      expect(AppSettings.chatLayout, ChatLayout.novel);
      await tester.pumpAndSettle();
      expect(find.textContaining('当前 小说'), findsOneWidget);
    });
  });
}
