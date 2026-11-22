import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/screens/onboarding_screen.dart';
import 'package:litetavern/services/api_presets.dart';
import 'package:litetavern/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 新手指引（5 步版）的 widget 测试。
///
/// 全部离线：只翻页、填表单、点「测试连接」的空值校验分支，
/// 不触发任何真实 HTTP / 文件选择 / 外链跳转。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
    Storage.initForTest(Directory.systemTemp.createTempSync('lt_onboarding_'));
  });

  testWidgets('第 1 步：讲清「本身不带 AI 模型」并给出三步概览', (tester) async {
    await _pump(tester);

    expect(find.text('第 1 / 5 步'), findsOneWidget);
    expect(find.text('欢迎使用 LiteTavern'), findsOneWidget);
    // 关键认知：必须自备 API Key，费用由服务商收取
    expect(find.textContaining('本身不带 AI 模型'), findsOneWidget);
    expect(find.textContaining('API Key'), findsWidgets);
    // 三步概览
    expect(find.text('三步就能开始'), findsOneWidget);
    expect(find.text('配置模型服务'), findsOneWidget);
    expect(find.text('导入角色卡'), findsOneWidget);
    expect(find.text('开始聊天'), findsOneWidget);
    // 跳过入口常驻
    expect(find.text('跳过'), findsOneWidget);
  });

  testWidgets('底部主按钮按步骤给文案，并能一步步翻到第 5 步', (tester) async {
    await _pump(tester);

    await _tapPrimary(tester, '我知道了，下一步');
    expect(find.text('第 2 / 5 步'), findsOneWidget);
    expect(find.text('获取 API Key'), findsOneWidget);

    await _tapPrimary(tester, '已经拿到 Key，下一步');
    expect(find.text('第 3 / 5 步'), findsOneWidget);
    expect(find.text('填写并测试连接'), findsOneWidget);

    await _tapPrimary(tester, '下一步：导入角色');
    await _clearSnackBar(tester);
    expect(find.text('第 4 / 5 步'), findsOneWidget);
    expect(find.text('导入第一个角色卡'), findsOneWidget);

    await _tapPrimary(tester, '下一步');
    expect(find.text('第 5 / 5 步'), findsOneWidget);
    expect(find.text('好了，开始聊天'), findsOneWidget);
    expect(find.text('进入 LiteTavern'), findsOneWidget);
  });

  testWidgets('第 2 步：5 家服务商都列出，并给出选择建议', (tester) async {
    await _pump(tester);
    await _tapPrimary(tester, '我知道了，下一步');

    for (final preset in kApiPresets) {
      expect(find.text(preset.label), findsOneWidget, reason: preset.label);
    }
    // 每张卡片都能打开获取 Key 的帮助入口
    expect(find.text('去官网获取 Key'), findsNWidgets(4));
    expect(find.text('去下载 Ollama'), findsOneWidget);
    expect(find.textContaining('Ollama 是在自己电脑上跑模型'), findsOneWidget);
    expect(find.textContaining('API Key 相当于账号密码'), findsOneWidget);
  });

  testWidgets('第 3 步：点预设只填地址与模型，不动已填的 Key', (tester) async {
    await _pump(tester);
    await _goToStep(tester, 3);

    final keyField = find.byType(TextField).at(1);
    await tester.ensureVisible(keyField);
    await tester.pumpAndSettle();
    await tester.enterText(keyField, 'sk-test-123');
    await tester.pump();
    expect(AppSettings.apiKey, 'sk-test-123');

    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'DeepSeek'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'DeepSeek'));
    await tester.pump();

    expect(AppSettings.baseUrl, 'https://api.deepseek.com/v1');
    expect(AppSettings.model, 'deepseek-chat');
    // Key 不被预设覆盖
    expect(AppSettings.apiKey, 'sk-test-123');
  });

  testWidgets('第 3 步：空表单点测试连接 → 提示先填，并展示常见错误对照', (tester) async {
    await _pump(tester);
    await _goToStep(tester, 3);

    await tester.ensureVisible(find.widgetWithText(FilledButton, '测试连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '测试连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请先填写 Base URL 和 API Key'), findsOneWidget);
    expect(find.text('常见错误对照'), findsOneWidget);
    expect(find.textContaining('401 / Unauthorized'), findsOneWidget);
    expect(find.textContaining('404'), findsWidgets);
  });

  testWidgets('第 3 步：没配好就往前走 → 提示之后可在设置里再配，并落盘已填内容', (tester) async {
    await _pump(tester);
    await _goToStep(tester, 3);

    final urlField = find.byType(TextField).first;
    await tester.enterText(urlField, 'https://api.example.com/v1');
    await tester.pump();

    await _tapPrimary(tester, '下一步：导入角色');

    expect(find.textContaining('设置 → 模型服务 里再配'), findsOneWidget);
    expect(AppSettings.baseUrl, 'https://api.example.com/v1');
    await _clearSnackBar(tester);
  });

  testWidgets('第 4 步：三个导入入口按推荐顺序给出', (tester) async {
    await _pump(tester);
    await _goToStep(tester, 4);

    expect(find.text('从角色卡市场导入'), findsOneWidget);
    expect(find.text('从本地文件导入'), findsOneWidget);
    expect(find.text('先跳过，进去自己逛'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.textContaining('主页右下角「导入」'), findsOneWidget);
  });

  testWidgets('第 5 步：三条使用说明 + 本地数据说明', (tester) async {
    await _pump(tester);
    await _goToStep(tester, 5);

    expect(find.text('点角色进聊天'), findsOneWidget);
    expect(find.textContaining('生成建议回复'), findsOneWidget);
    expect(find.textContaining('想改设置就去「设置」'), findsOneWidget);
    expect(find.text('数据都在你手机里'), findsOneWidget);
  });

  testWidgets('「上一步」回到上一页', (tester) async {
    await _pump(tester);
    await _tapPrimary(tester, '我知道了，下一步');
    expect(find.text('第 2 / 5 步'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '上一步'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 5 步'), findsOneWidget);
  });

  testWidgets('小屏 360×520：五步翻完不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pump(tester);
    expect(tester.takeException(), isNull);

    for (var step = 1; step < 5; step++) {
      await _tapPrimary(tester, _labels[step - 1]);
      await _clearSnackBar(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: '第 ${step + 1} 步出现布局溢出',
      );
    }
    expect(find.text('进入 LiteTavern'), findsOneWidget);
  });
}

/// 与页面底部主按钮一一对应的文案（第 1~5 步）。
const List<String> _labels = <String>[
  '我知道了，下一步',
  '已经拿到 Key，下一步',
  '下一步：导入角色',
  '下一步',
  '进入 LiteTavern',
];

Widget _host() {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF9C4632),
        brightness: Brightness.dark,
      ),
    ),
    home: const OnboardingScreen(),
  );
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.pumpAndSettle();
}

/// 点底部主按钮（必须唯一命中）。
Future<void> _tapPrimary(WidgetTester tester, String label) async {
  final finder = find.widgetWithText(FilledButton, label);
  expect(finder, findsOneWidget, reason: '底部主按钮「$label」');
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 翻到第 [step] 步（1 是初始页，不翻）。
Future<void> _goToStep(WidgetTester tester, int step) async {
  for (var current = 1; current < step; current++) {
    await _tapPrimary(tester, _labels[current - 1]);
    await _clearSnackBar(tester);
  }
}

/// 等当前 SnackBar 自己走完，避免它盖住底部按钮影响后续点击。
Future<void> _clearSnackBar(WidgetTester tester) async {
  if (find.byType(SnackBar).evaluate().isEmpty) return;
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}
