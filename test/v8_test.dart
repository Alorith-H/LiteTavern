import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/models/world_info.dart';
import 'package:litetavern/services/context_usage.dart';
import 'package:litetavern/services/generated_card.dart';
import 'package:litetavern/services/hit_stats.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/token_estimate.dart';

// v0.8.0 第四批：命中率统计 / 上下文占用与满压缩 / 创建器 JSON 解析。

WorldInfoEntry _entry({
  String? id,
  List<String> keys = const [],
  int insertionOrder = 0,
}) =>
    WorldInfoEntry(
      id: id,
      keys: keys,
      keysSecondary: const [],
      content: '内容',
      insertionOrder: insertionOrder,
      disabled: false,
      probability: 100,
      useProbability: false,
      position: 0,
      depth: 4,
      recursive: false,
      scanDepth: 50,
      groupWeight: 100,
    );

PromptBuildResult _build(List<String> contents) => PromptBuildResult(
      messages: [for (final c in contents) PromptMessage(role: 'system', content: c)],
      systemText: contents.isEmpty ? '' : contents.first,
      activated: const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==================== estimateTokens（占用口径公式） ====================

  group('estimateTokens：CJK×1.0 + 非CJK/4（v0.8.0 口径）', () {
    test('纯 CJK 按 1 字 1 token', () {
      expect(estimateTokens('你好世界'), 4);
      expect(estimateTokens('，。'), 2); // 全角标点算 CJK
    });

    test('纯非 CJK 按 4 字符 1 token（向上取整）', () {
      expect(estimateTokens('abcdefgh'), 2);
      expect(estimateTokens('ab'), 1);
      expect(estimateTokens(''), 0);
    });

    test('混合文本分段计再取整', () {
      // ceil(1 + 1/4) = 2
      expect(estimateTokens('a你'), 2);
      // ceil(2 + 3/4) = 3
      expect(estimateTokens('你好abc'), 3);
    });
  });

  // ==================== 命中率统计 ====================

  group('命中率统计（HitStats / entryKeyOf）', () {
    test('record：每次真实发送 sends+1，激活词条 hits+1，比率正确', () {
      var s = const HitStats();
      s = s.record(const ['a', 'b']);
      expect(s.sends, 1);
      expect(s.hitsOf('a'), 1);
      expect(s.hitsOf('b'), 1);

      s = s.record(const ['a']);
      expect(s.sends, 2);
      expect(s.hitsOf('a'), 2);
      expect(s.hitsOf('b'), 1);
      expect(s.rateLine('a'), '2/2 · 100%');
      expect(s.rateLine('b'), '1/2 · 50%');
      expect(s.rateLine('没命中'), '0/2 · 0%');
    });

    test('无发送记录不显示比率（旧会话迁移策略）', () {
      const s = HitStats();
      expect(s.isEmpty, isTrue);
      expect(s.rateLine('a'), isNull);
      // 有 hits 但 sends 为 0 的异常数据也不显示
      expect(const HitStats(hits: {'a': 3}).rateLine('a'), isNull);
    });

    test('JSON 往返：_sends + 嵌套 hits 结构，兼容简写', () {
      final s = const HitStats(hits: {'k1': 3}, sends: 12)
          .toJson();
      final back = HitStats.fromJson(jsonDecode(jsonEncode(s)));
      expect(back.sends, 12);
      expect(back.hitsOf('k1'), 3);
      expect(back.rateLine('k1'), '3/12 · 25%');

      // 简写容错：key: 3
      final loose =
          HitStats.fromJson(jsonDecode('{"_sends": 4, "x": 3}'));
      expect(loose.hitsOf('x'), 3);
      expect(loose.sends, 4);
    });

    test('entryKeyOf：有 id 用 id，否则 首关键词|插入顺序 兜底', () {
      expect(entryKeyOf(_entry(id: 'obj_7', keys: ['城堡'])), 'obj_7');
      expect(entryKeyOf(_entry(keys: ['城堡'], insertionOrder: 4)), '城堡|4');
      expect(entryKeyOf(_entry(insertionOrder: 0)), '|0'); // 无关键词
    });
  });

  // ==================== 压缩触发条件 ====================

  group('压缩触发条件（overContextBudget / halveHistoryLimit）', () {
    test('窗口 0 = 关闭，永不触发', () {
      expect(overContextBudget(0, 0), isFalse);
      expect(overContextBudget(1000, 0), isFalse);
      expect(overContextBudget(999999, 0), isFalse);
      expect(contextPercent(999, 0), 0);
    });

    test('超过窗口 90% 才触发（边界 90% 本身不触发）', () {
      expect(overContextBudget(900, 1000), isFalse); // 恰好 90%
      expect(overContextBudget(899, 1000), isFalse);
      expect(overContextBudget(901, 1000), isTrue);
      expect(overContextBudget(1001, 1000), isTrue);
    });

    test('历史条数减半且不低于 10 条', () {
      expect(halveHistoryLimit(40), 20);
      expect(halveHistoryLimit(15), 10); // 7 → 下限 10
      expect(halveHistoryLimit(10), 10);
      expect(halveHistoryLimit(4), 10); // 2 → 下限 10
    });

    test('占用百分比按窗口折算', () {
      expect(contextPercent(500, 1000), 50);
      expect(contextPercent(0, 1000), 0);
      expect(contextPercent(1000, 1000), 100);
    });
  });

  group('ContextBreakdown：分量之和恒等于完整组装', () {
    test('三次组装差分拆分', () {
      // 裸组装：system 4 + 历史（\n + 4）= 9
      final bare = _build(const ['你好世界', '早安早安']);
      // 带世界书：system 注入 4 字 → 13
      final withWb = _build(const ['你好世界世界书内容', '早安早安']);
      // 完整：再加摘要消息（\n + 4）→ 18
      final full = _build(const ['你好世界世界书内容', '早安早安', '摘要内容']);

      final bd =
          ContextBreakdown.of(bare: bare, withWb: withWb, full: full);
      expect(bd.systemTokens, 4);
      expect(bd.historyTokens, 5);
      expect(bd.worldBookTokens, 4);
      expect(bd.summaryTokens, 5);
      expect(bd.historyCount, 1);
      expect(bd.total, 18);
      // total 与完整组装的估算同口径（展示与压缩阈值一个数）
      expect(
        bd.total,
        estimateTokens(full.messages.map((m) => m.content).join('\n')),
      );
    });
  });

  // ==================== 创建器 JSON 解析容错 ====================

  group('创建器 JSON 解析（parseGeneratedCard）', () {
    test('剥代码围栏后解析六字段', () {
      const raw = '''
```json
{"name": "测试角色", "description": "介绍", "personality": "温和",
 "scenario": "酒馆", "first_mes": "你好呀", "mes_example": ""}
```
''';
      final card = parseGeneratedCard(raw);
      expect(card, isNotNull);
      expect(card!.name, '测试角色');
      expect(card.description, '介绍');
      expect(card.personality, '温和');
      expect(card.scenario, '酒馆');
      expect(card.firstMes, '你好呀');
      expect(card.mesExample, '');
    });

    test('截断抢救：JSON 不完整时按字段正则捞出（已闭合的字段）', () {
      const raw = '{"name": "艾莉", "description": "边境来的游骑兵", "scenario": "雪夜边';
      final card = parseGeneratedCard(raw);
      expect(card, isNotNull);
      expect(card!.name, '艾莉');
      expect(card.description, '边境来的游骑兵');
      expect(card.scenario, ''); // 未闭合的字段捞不到，可编辑页补齐
    });

    test('data 包裹（chara_card 规范形状）也能解析', () {
      const raw =
          '{"spec": "chara_card V3", "data": {"name": "V3卡", "description": "描述"}}';
      final card = parseGeneratedCard(raw);
      expect(card, isNotNull);
      expect(card!.name, 'V3卡');
    });

    test('character_book 内嵌世界书：有词条才保留，名字缺失按角色名兜底', () {
      const raw = '''
{"name": "领主", "description": "设定", "character_book": {
  "entries": [
    {"keys": ["城堡"], "content": "领地中心", "enabled": true, "insertion_order": 0, "position": 0},
    {"keys": ["封地"], "content": "世袭领地", "enabled": true, "insertion_order": 1, "position": 0}
  ]
}}''';
      final card = parseGeneratedCard(raw);
      expect(card, isNotNull);
      final book = card!.characterBook;
      expect(book, isNotNull);
      expect(book!.name, '领主的世界书'); // 名字缺失 → 按角色名兜底
      expect(book.entries, hasLength(2));
      expect(book.entries.first.keys, ['城堡']);
      expect(book.entries.first.disabled, isFalse); // enabled: true
    });

    test('character_book 空词条 → null（不许编造凑数）', () {
      const raw =
          '{"name": "空书卡", "description": "d", "character_book": {"entries": []}}';
      final card = parseGeneratedCard(raw);
      expect(card, isNotNull);
      expect(card!.characterBook, isNull);
    });

    test('character_book 的 enabled 对齐模型 disabled（false → 禁用）', () {
      const raw = '''
{"name": "哨兵", "description": "d", "character_book": {"entries": [
  {"keys": ["岗哨"], "content": "常驻设定", "enabled": true},
  {"keys": ["密道"], "content": "休眠设定", "enabled": false}
]}}''';
      final card = parseGeneratedCard(raw);
      expect(card, isNotNull);
      final entries = card!.characterBook!.entries;
      expect(entries, hasLength(2));
      expect(entries.first.disabled, isFalse);
      expect(entries.last.disabled, isTrue);
    });

    test('character_book 结构非法（非 map）→ 当 null，不阻塞出卡', () {
      const raw = '{"name": "正常卡", "description": "d", "character_book": "乱码"}';
      final card = parseGeneratedCard(raw);
      expect(card, isNotNull);
      expect(card!.name, '正常卡');
      expect(card.characterBook, isNull);
    });

    test('完全无法解析 → null（调用方 snackbar，保留对话可重试）', () {
      expect(parseGeneratedCard('实在什么都没有'), isNull);
      expect(parseGeneratedCard('{"只有一堆没用的": 1}'), isNull);
    });
  });

  // ==================== 会话 hitStats 持久化 ====================

  group('会话 hitStats 存取', () {
    late Directory docs;

    setUp(() {
      docs = Directory.systemTemp.createTempSync('litetavern_v8_test');
      Storage.initForTest(docs);
      Directory('${docs.path}/conversations').createSync(recursive: true);
    });

    tearDown(() {
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });

    test('saveConversation 带 hitStats → loadConversationData 读回', () async {
      const stats = HitStats(hits: {'城堡|0': 3}, sends: 12);
      await Storage.saveConversation(
        'c1',
        [ChatMessage(role: 'user', content: 'hi', timestamp: 1)],
        hitStats: stats,
      );
      final data = await Storage.loadConversationData('c1');
      expect(data.hitStats, isNotNull);
      expect(data.hitStats!.sends, 12);
      expect(data.hitStats!.rateLine('城堡|0'), '3/12 · 25%');
    });

    test('旧格式（数组、无 hitStats）→ null，不迁移不显示', () async {
      await File('${docs.path}/conversations/old.json').writeAsString(
        jsonEncode([
          ChatMessage(role: 'user', content: 'hi', timestamp: 1).toJson(),
        ]),
      );
      final data = await Storage.loadConversationData('old');
      expect(data.messages, hasLength(1));
      expect(data.hitStats, isNull);
    });

    test('无统计时仍写旧数组格式（字节兼容）', () async {
      await Storage.saveConversation(
        'plain',
        [ChatMessage(role: 'user', content: 'hi', timestamp: 1)],
      );
      final raw =
          await File('${docs.path}/conversations/plain.json').readAsString();
      expect(jsonDecode(raw), isA<List<dynamic>>());
    });
  });
}
