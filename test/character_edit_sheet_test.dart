import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/screens/character_edit_screen.dart';
import 'package:litetavern/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `CharacterEditScreen.draft` 要求 const 参数，这里用编译期常量卡片。
const CharacterCard _cardDraft = CharacterCard(
  name: '林知夏',
  description: '住在海边小城的旧书店店主。',
  personality: '安静，耐心。',
  scenario: '傍晚的旧书店，外面在下雨。',
  firstMes: '「坐一会儿再走吧，我烧了水。」',
  mesExample: '',
  systemPrompt: '',
  alternateGreetings: <String>[],
  tags: <String>['日常'],
  creator: 'test',
);

/// 编辑页初始化要读世界书等真实文件，必须放行真实异步，否则会卡在加载态。
Future<void> _pumpEditor(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(
      const MaterialApp(home: CharacterEditScreen.draft(card: _cardDraft)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  });
  await tester.pump();
}

Future<void> _tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  });
  await tester.pump();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Storage.initForTest(
      Directory.systemTemp.createTempSync('lt_character_edit_ai_'),
    );
    await AppSettings.init();
    AppSettings.baseUrl = 'https://example.com/v1';
    AppSettings.apiKey = 'sk-test';
    AppSettings.model = 'test-model';
  });

  testWidgets('编辑页有「AI 修改」按钮，且在翻译按钮之前', (tester) async {
    await _pumpEditor(tester);

    expect(find.byIcon(Icons.auto_fix_high_outlined), findsOneWidget);
    expect(find.byTooltip('AI 修改'), findsOneWidget);

    final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
    final aiIndex = icons.indexWhere(
      (i) => i.icon?.codePoint == Icons.auto_fix_high_outlined.codePoint,
    );
    final translateIndex = icons.indexWhere(
      (i) => i.icon?.codePoint == Icons.translate.codePoint,
    );
    expect(aiIndex, isNonNegative);
    expect(translateIndex, isNonNegative);
    expect(aiIndex < translateIndex, isTrue);
  });

  testWidgets('点「AI 修改」打开修改弹层：四个范围与说明', (tester) async {
    await _pumpEditor(tester);

    await _tapAndSettle(tester, find.byIcon(Icons.auto_fix_high_outlined));

    expect(find.text('AI 修改角色'), findsOneWidget);
    expect(find.text('只改性格'), findsOneWidget);
    expect(find.text('只改开场白'), findsOneWidget);
    expect(find.text('只改背景'), findsOneWidget);
    expect(find.text('整体润色'), findsOneWidget);
    expect(find.text('开始修改'), findsOneWidget);
  });

  testWidgets('没配置模型时提示去设置，不打开弹层', (tester) async {
    AppSettings.baseUrl = '';
    AppSettings.apiKey = '';
    await _pumpEditor(tester);

    await _tapAndSettle(tester, find.byIcon(Icons.auto_fix_high_outlined));

    expect(find.text('还没配置模型，先去设置里填一个 API Key'), findsOneWidget);
    expect(find.text('AI 修改角色'), findsNothing);
  });
}
