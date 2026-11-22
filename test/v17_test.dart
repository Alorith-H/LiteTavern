import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/screens/authors_note_screen.dart';
import 'package:litetavern/screens/personas_screen.dart';
import 'package:litetavern/services/authors_note.dart';
import 'package:litetavern/services/chat_export.dart';
import 'package:litetavern/services/impersonate.dart';
import 'package:litetavern/services/macros.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/user_personas.dart';

CharacterCard _card({
  String name = '艾琳',
  String description = '酒馆老板娘',
  String personality = '爽朗',
  String scenario = '雨夜',
  String firstMes = '来一杯？',
  String mesExample = '',
  String systemPrompt = '',
}) =>
    CharacterCard(
      name: name,
      description: description,
      personality: personality,
      scenario: scenario,
      firstMes: firstMes,
      mesExample: mesExample,
      systemPrompt: systemPrompt,
      alternateGreetings: const [],
      tags: const [],
      creator: '',
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
  });

  // ------------------------------------------------ 用户人设（v0.16.0）--
  group('PersonaStore', () {
    test('ensureSeeded：把设置里的称呼包成一条人设并选中', () {
      AppSettings.userName = '阿青';
      final list = PersonaStore.ensureSeeded();
      expect(list.length, 1);
      expect(list.first.name, '阿青');
      expect(PersonaStore.active?.id, list.first.id);
      // 再调一次不会重复追加
      expect(PersonaStore.ensureSeeded().length, 1);
    });

    test('upsert：新对象自动分配 id，已有 id 则原地更新', () {
      final created = PersonaStore.upsert(
        const UserPersona(id: '', name: ' 阿青 ', description: ' 书店店员 '),
      );
      expect(created.id, isNotEmpty);
      expect(created.name, '阿青'); // 前后空白被 trim
      expect(created.description, '书店店员');
      expect(PersonaStore.load().length, 1);

      PersonaStore.upsert(created.copyWith(name: '小青'));
      final list = PersonaStore.load();
      expect(list.length, 1);
      expect(list.first.name, '小青');
    });

    test('setActive：选中后 activeName / activeDescription 生效并同步 userName', () {
      final p = PersonaStore.upsert(
        const UserPersona(id: '', name: '阿青', description: '书店店员'),
      );
      PersonaStore.setActive(p.id);
      expect(PersonaStore.activeName, '阿青');
      expect(PersonaStore.activeDescription, '书店店员');
      expect(AppSettings.userName, '阿青');
    });

    test('未选人设时 activeName 回退 userName，activeDescription 为空', () {
      AppSettings.userName = '你';
      PersonaStore.setActive(null);
      expect(PersonaStore.activeName, '你');
      expect(PersonaStore.activeDescription, '');
    });

    test('remove：删除当前人设只清选中，不把 userName 清空', () {
      final p = PersonaStore.upsert(
        const UserPersona(id: '', name: '阿青', description: ''),
      );
      PersonaStore.setActive(p.id);
      PersonaStore.remove(p.id);
      expect(PersonaStore.load(), isEmpty);
      expect(AppSettings.activePersonaId, isNull);
      expect(AppSettings.userName, '阿青');
    });

    test('load：坏 JSON 回退空列表（不抛）', () {
      AppSettings.personasJson = '{不是数组}';
      expect(PersonaStore.load(), isEmpty);
    });
  });

  // ------------------------------------------------ 作者注释（v0.16.0）--
  group('AuthorNoteStore', () {
    test('保存后能读回，其它会话互不影响', () {
      const note = AuthorNote(
        content: '回复控制在 3 段以内',
        depth: 2,
        role: 'user',
      );
      AuthorNoteStore.save('char_a', note);
      final loaded = AuthorNoteStore.load('char_a');
      expect(loaded.content, '回复控制在 3 段以内');
      expect(loaded.depth, 2);
      expect(loaded.role, 'user');
      expect(AuthorNoteStore.load('char_b').content, isEmpty);
      expect(AuthorNoteStore.hasOwn('char_a'), isTrue);
      expect(AuthorNoteStore.hasOwn('char_b'), isFalse);
    });

    test('没有独立记录时回退默认注释', () {
      AuthorNoteStore.defaultNote =
          const AuthorNote(content: '默认：少用颜文字');
      expect(AuthorNoteStore.load('char_x').content, '默认：少用颜文字');
    });

    test('clear 后重新继承默认；hasOwn 变 false', () {
      AuthorNoteStore.defaultNote = const AuthorNote(content: '默认');
      AuthorNoteStore.save('char_a', const AuthorNote(content: '临时'));
      AuthorNoteStore.clear('char_a');
      expect(AuthorNoteStore.load('char_a').content, '默认');
      expect(AuthorNoteStore.hasOwn('char_a'), isFalse);
    });

    test('fromJson 容错：非法 role/placement/depth 回落安全值', () {
      final note = AuthorNote.fromJson({
        'content': 'x',
        'enabled': false,
        'depth': 99,
        'role': 'admin',
        'placement': 'unknown',
      });
      expect(note.enabled, isFalse);
      expect(note.depth, 20);
      expect(note.role, 'system');
      expect(note.placement, AuthorNotePlacement.inChat);
      expect(note.isActive, isFalse); // enabled=false
    });
  });

  // -------------------------------------------------- 宏增强（v0.16.0）--
  group('applyMacros', () {
    final now = DateTime(2026, 3, 9, 8, 5); // 周一

    String run(String input) => applyMacros(
          input,
          charName: '艾琳',
          userName: '阿青',
          personaText: '书店店员',
          cardFields: const {
            'description': '老板娘',
            'personality': '爽朗',
            'scenario': '雨夜',
          },
          now: now,
        );

    test('角色 / 用户 / 人设 / 卡片字段', () {
      expect(run('{{char}} 和 {{user}}'), '艾琳 和 阿青');
      expect(run('<BOT>'), '艾琳');
      expect(run('{{persona}}'), '书店店员');
      expect(run('{{description}}/{{personality}}/{{scenario}}'), '老板娘/爽朗/雨夜');
    });

    test('{{persona}} 未设置时回退用户名', () {
      final out = applyMacros(
        '{{persona}}',
        charName: '艾琳',
        userName: '阿青',
        personaText: '',
      );
      expect(out, '阿青');
    });

    test('时间类宏使用注入的 now', () {
      expect(run('{{time}}'), '08:05');
      expect(run('{{date}}'), '2026-03-09');
      expect(run('{{weekday}}'), '星期一');
      expect(run('{{isotime}}'), startsWith('2026-03-09T08:05'));
    });

    test('随机宏：单值区间与候选列表', () {
      expect(run('{{random::5::5}}'), '5');
      expect(run('{{random:7,7}}'), '7');
      expect(run('{{pick::甲::甲}}'), '甲');
      // 纯 {{random}} 落在 0–99
      final n = int.parse(run('{{random}}'));
      expect(n, inInclusiveRange(0, 99));
    });

    test('换行 / 清理 / 注释 / 未知宏', () {
      expect(run('a{{newline}}b'), 'a\nb');
      expect(run('  a \n\n\n\n b  {{trim}}'), 'a\n\nb');
      expect(run('a{{// 这段会被删掉}}b'), 'ab');
      expect(run('{{不认识的宏}}'), '{{不认识的宏}}');
      expect(run('a<START>b'), 'a\n\nb');
    });
  });

  // --------------------------------- PromptBuilder 注入（v0.16.0）--
  group('PromptBuilder 人设与作者注释', () {
    test('人设写进 system，且 {{user}} 用宏替换', () {
      final result = PromptBuilder.build(
        card: _card(),
        history: const [],
        worldBooks: const [],
        userName: '阿青',
        personaText: '24 岁的书店店员，和艾琳是大学同学。',
        historyLimit: 40,
      );
      expect(result.systemText, contains('用户「阿青」的设定：'));
      expect(result.systemText, contains('书店店员'));
    });

    test('afterScenario 作者注释出现在 system 里、示例对话之前', () {
      final result = PromptBuilder.build(
        card: _card(mesExample: '艾琳：来一杯？\n阿青：好。'),
        history: const [],
        worldBooks: const [],
        userName: '阿青',
        authorNote: const AuthorNote(
          content: '回复控制在 3 段以内',
          placement: AuthorNotePlacement.afterScenario,
        ),
        historyLimit: 40,
      );
      expect(result.systemText, contains('【作者注释】回复控制在 3 段以内'));
      expect(
        result.systemText.indexOf('【作者注释】'),
        lessThan(result.systemText.indexOf('示例对话：')),
      );
    });

    test('inChat 深度 0 追加在最末尾', () {
      final history = [
        ChatMessage(role: 'user', content: '第一句', timestamp: DateTime(2026).millisecondsSinceEpoch),
        ChatMessage(role: 'assistant', content: '第二句', timestamp: DateTime(2026).millisecondsSinceEpoch),
      ];
      final result = PromptBuilder.build(
        card: _card(firstMes: ''),
        history: history,
        worldBooks: const [],
        userName: '阿青',
        authorNote: const AuthorNote(
          content: '记住左手有伤',
          depth: 0,
          role: 'system',
        ),
        historyLimit: 40,
      );
      final contents = [for (final m in result.messages) m.content];
      final noteIdx = contents.indexOf('记住左手有伤');
      expect(noteIdx, greaterThan(0));
      expect(result.messages[noteIdx].role, 'system');
      // 深度 0 = 最后一条消息之后
      expect(noteIdx, contents.length - 1);
    });

    test('inChat 深度 1 插在最后一条消息之前', () {
      final history = [
        ChatMessage(role: 'user', content: '第一句', timestamp: DateTime(2026).millisecondsSinceEpoch),
        ChatMessage(role: 'assistant', content: '第二句', timestamp: DateTime(2026).millisecondsSinceEpoch),
      ];
      final result = PromptBuilder.build(
        card: _card(firstMes: ''),
        history: history,
        worldBooks: const [],
        userName: '阿青',
        authorNote: const AuthorNote(
          content: '记住左手有伤',
          depth: 1,
          role: 'user',
        ),
        historyLimit: 40,
      );
      final contents = [for (final m in result.messages) m.content];
      final noteIdx = contents.indexOf('记住左手有伤');
      expect(noteIdx, contents.length - 2);
      expect(result.messages[noteIdx].role, 'user');
    });

    test('禁用的作者注释不注入', () {
      final result = PromptBuilder.build(
        card: _card(),
        history: const [],
        worldBooks: const [],
        userName: '阿青',
        authorNote: const AuthorNote(content: '不该出现', enabled: false),
        historyLimit: 40,
      );
      expect(result.systemText, isNot(contains('不该出现')));
    });
  });

  // ---------------------------------------------- 替我说一句（v0.16.0）--
  group('impersonate', () {
    test('指令追加在末尾且不改动原列表', () {
      const original = [
        PromptMessage(role: 'system', content: '设定'),
        PromptMessage(role: 'user', content: '你好'),
      ];
      final out = withImpersonateInstruction(original);
      expect(original.length, 2);
      expect(out.length, 3);
      expect(out.last.role, 'user');
      expect(out.last.content, kImpersonateInstruction);
    });

    test('清洗：去前缀 / 引号 / 代码围栏 / 多余空行', () {
      expect(normalizeImpersonation('用户：你好呀'), '你好呀');
      expect(normalizeImpersonation('我: 走吧'), '走吧');
      expect(normalizeImpersonation('「走吧」'), '走吧');
      expect(normalizeImpersonation('```\n走吧\n```'), '走吧');
      expect(normalizeImpersonation('第一句\n\n\n第二句'), '第一句\n第二句');
      expect(normalizeImpersonation('   '), '');
    });
  });

  // -------------------------------------------------- 对话导出（v0.16.0）--
  group('对话文件导出', () {
    test('buildExportJson 字段与跳过空内容', () {
      final json = buildExportJson(
        charName: '艾琳',
        userName: '阿青',
        messages: [
          ChatMessage(role: 'user', content: '你好', timestamp: DateTime(2026, 1, 2, 3, 4).millisecondsSinceEpoch),
          ChatMessage(role: 'assistant', content: '', timestamp: DateTime(2026).millisecondsSinceEpoch),
          ChatMessage(
            role: 'assistant',
            content: '晚上好',
            timestamp: DateTime(2026, 1, 2, 3, 5).millisecondsSinceEpoch,
            variants: const ['晚上好', '你好呀'],
            variantIndex: 1,
          ),
        ],
        exportedAt: DateTime(2026, 5, 6, 7, 8),
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['format'], 'litetavern-chat');
      expect(decoded['version'], 1);
      expect(decoded['character'], '艾琳');
      expect(decoded['user'], '阿青');
      final messages = decoded['messages'] as List;
      expect(messages.length, 2); // 空内容那条被跳过
      expect((messages[0] as Map)['role'], 'user');
      expect((messages[1] as Map)['variants'], ['晚上好', '你好呀']);
      expect((messages[1] as Map)['variantIndex'], 1);
    });

    test('safeExportName 去掉非法字符并截断', () {
      expect(safeExportName('艾琳/雨夜: v2?'), '艾琳_雨夜_v2');
      expect(safeExportName('   '), 'chat');
      expect(safeExportName('a' * 60).length, lessThanOrEqualTo(40));
    });
  });

  // ------------------------------------------- 人设页 widget（v0.16.0）--
  group('PersonasScreen', () {
    testWidgets('展示已有人设，点新建弹出表单', (tester) async {
      AppSettings.userName = '阿青';
      PersonaStore.ensureSeeded();
      await tester.pumpWidget(const MaterialApp(home: PersonasScreen()));
      await tester.pumpAndSettle();

      expect(find.text('用户人设'), findsOneWidget);
      expect(find.text('阿青'), findsWidgets);
      expect(find.text('使用中'), findsOneWidget);

      await tester.tap(find.text('新建人设'));
      await tester.pumpAndSettle();
      // 弹层标题「新建人设」+ 表单字段
      expect(find.text('新建人设'), findsWidgets);
      expect(find.text('设定（可留空）'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(PersonaStore.load().length, 1);
    });
  });

  // ------------------------------------- 作者注释页 widget（v0.16.0）--
  group('AuthorNoteScreen', () {
    testWidgets('填写内容保存后写入当前会话', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AuthorNoteScreen(convId: 'conv_test', title: '作者注释'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('启用作者注释'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '回复控制在 3 段以内');
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();

      final saved = AuthorNoteStore.load('conv_test');
      expect(saved.content, '回复控制在 3 段以内');
      expect(AuthorNoteStore.hasOwn('conv_test'), isTrue);
    });
  });
}


