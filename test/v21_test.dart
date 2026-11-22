import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/screens/onboarding_screen.dart';
import 'package:litetavern/screens/settings_screen.dart';
import 'package:litetavern/services/storage.dart';

Widget _host(Widget home) => MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF9C4632),
          brightness: Brightness.dark,
        ),
      ),
      home: home,
    );

Future<void> _clearSnackBar(WidgetTester tester) async {
  if (find.byType(SnackBar).evaluate().isNotEmpty) {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }
}

Future<void> _tapPrimary(WidgetTester tester, String label) async {
  final finder = find.widgetWithText(FilledButton, label);
  expect(finder, findsOneWidget, reason: '找不到主按钮「$label」');
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
  await _clearSnackBar(tester);
}

Future<void> _goToStep(WidgetTester tester, int step) async {
  const labels = <String>[
    '我知道了，下一步',
    '已经拿到 Key，下一步',
    '下一步：选择聊天方式',
    '下一步：导入角色',
    '下一步',
    '进入 LiteTavern',
  ];
  for (var current = 1; current < step; current++) {
    await _tapPrimary(tester, labels[current - 1]);
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
    Storage.initForTest(Directory.systemTemp.createTempSync('lt_v21_'));
  });

  group('消息记录模型名（v0.21.0）', () {
    test('ChatMessage.model 序列化往返', () {
      final m = ChatMessage(
        role: 'assistant',
        content: '你好',
        timestamp: DateTime(2026, 11, 22, 22, 30).millisecondsSinceEpoch,
        model: 'glm-4-flash',
      );
      final json = m.toJson();
      expect(json['model'], 'glm-4-flash');

      final back = ChatMessage.fromJson(json);
      expect(back.model, 'glm-4-flash');
      expect(back.content, '你好');
    });

    test('旧数据没有 model 字段 → null，且不写入空值', () {
      final old = ChatMessage.fromJson(<String, dynamic>{
        'role': 'assistant',
        'content': '旧消息',
        'timestamp': 1700000000000,
      });
      expect(old.model, isNull);
      expect(old.toJson().containsKey('model'), isFalse);

      // 空模型名也不落盘
      final noModel = ChatMessage(role: 'assistant', content: 'x', timestamp: 1);
      expect(noModel.toJson().containsKey('model'), isFalse);
    });

    test('copyWith 默认保留模型名，显式传入则覆盖', () {
      final m = ChatMessage(
        role: 'assistant',
        content: 'a',
        timestamp: 1,
        model: 'deepseek-chat',
      );
      expect(m.copyWith(content: 'b').model, 'deepseek-chat');
      expect(m.copyWith(model: 'glm-4-flash').model, 'glm-4-flash');
      expect(m.copyWith().model, 'deepseek-chat');
    });
  });

  group('新手指引：配置另存为新的一套（v0.21.0）', () {
    testWidgets('已有旧配置时，引导里填写会新建配置且不动旧配置', (tester) async {
      AppSettings.apiConfigs = const <ApiConfig>[
        ApiConfig(
          id: 'old',
          name: '旧配置',
          baseUrl: 'https://old.example/v1',
          key: 'sk-old',
          model: 'old-model',
        ),
      ];
      AppSettings.activeApiConfigId = 'old';

      await tester.pumpWidget(_host(const OnboardingScreen()));
      await tester.pumpAndSettle();
      await _goToStep(tester, 3);

      // 第 3 步说明：会新建一套配置
      expect(find.text('这里会新建一套配置'), findsOneWidget);

      final urlField = find.byType(TextField).at(0);
      await tester.ensureVisible(urlField);
      await tester.pumpAndSettle();
      await tester.enterText(urlField, 'https://api.deepseek.com/v1');
      await tester.pump();

      final keyField = find.byType(TextField).at(1);
      await tester.ensureVisible(keyField);
      await tester.pumpAndSettle();
      await tester.enterText(keyField, 'sk-new-123');
      await tester.pump();

      final modelField = find.byType(TextField).at(2);
      await tester.ensureVisible(modelField);
      await tester.pumpAndSettle();
      await tester.enterText(modelField, 'deepseek-chat');
      await tester.pump();

      final configs = AppSettings.apiConfigs;
      expect(configs.length, 2, reason: '应是「旧配置 + 新建的一套」');

      final old = configs.firstWhere((c) => c.id == 'old');
      expect(old.baseUrl, 'https://old.example/v1');
      expect(old.key, 'sk-old');
      expect(old.model, 'old-model');

      final active = AppSettings.activeApiConfig;
      expect(active.id, isNot('old'));
      expect(active.baseUrl, 'https://api.deepseek.com/v1');
      expect(active.key, 'sk-new-123');
      expect(active.model, 'deepseek-chat');
    });
  });

  group('设置页二级菜单（v0.21.0）', () {
    testWidgets('首页列出各分组，点进「生成参数」进入子页', (tester) async {
      await tester.pumpWidget(_host(const SettingsScreen()));
      await tester.pumpAndSettle();

      for (final title in const <String>[
        '生成参数',
        '聊天与上下文',
        '角色卡市场与翻译',
        '世界书',
        '外观',
        '帮助与关于',
      ]) {
        expect(find.text(title), findsWidgets, reason: '首页应有「$title」入口');
      }

      await tester.ensureVisible(find.text('生成参数').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成参数').first);
      await tester.pumpAndSettle();

      expect(find.text('随机度'), findsOneWidget);
      expect(find.text('采样范围'), findsOneWidget);
      expect(find.text('单次回复长度上限'), findsOneWidget);
      expect(find.text('高级设置'), findsOneWidget);
    });

    testWidgets('直接以 section 打开子页', (tester) async {
      await tester.pumpWidget(
        _host(const SettingsScreen(section: SettingsSection.chat)),
      );
      await tester.pumpAndSettle();

      expect(find.text('聊天与上下文'), findsWidgets); // AppBar 标题 + 分节标题
      expect(find.textContaining('记忆与上下文'), findsOneWidget);
      expect(find.text('输入栏辅助按钮'), findsOneWidget);
    });
  });
}
