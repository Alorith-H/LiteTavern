import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/models/world_info.dart';
import 'package:litetavern/services/card_parser.dart';
import 'package:litetavern/services/chat_export.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/token_estimate.dart';
import 'package:litetavern/services/world_info_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _pngChunk(String type, List<int> data) {
  final out = BytesBuilder();
  final len = data.length;
  out.add([
    (len >> 24) & 0xFF,
    (len >> 16) & 0xFF,
    (len >> 8) & 0xFF,
    len & 0xFF,
  ]);
  out.add(type.codeUnits);
  out.add(data);
  out.add([0, 0, 0, 0]); // CRC（解析器不校验）
  return out.toBytes();
}

void main() {
  test('V1 角色卡归一化', () {
    final card = CharacterCard.fromJson({
      'name': '小明',
      'description': '一个普通的人',
    });
    expect(card.name, '小明');
    expect(card.personality, '');
    expect(card.alternateGreetings, isEmpty);
    expect(card.characterBook, isNull);
  });

  test('V2/V3 角色卡 data 内嵌解析', () {
    final card = CharacterCard.fromJson({
      'spec': 'chara_card V2',
      'data': {
        'name': 'Alice',
        'description': 'desc',
        'first_mes': 'Hi',
        'alternate_greetings': ['Hey'],
        'character_book': {
          'name': 'wb',
          'entries': {
            '0': {'key': ['魔法'], 'content': '魔法世界', 'insertion_order': 2},
          },
        },
      },
    });
    expect(card.name, 'Alice');
    expect(card.firstMes, 'Hi');
    expect(card.alternateGreetings, ['Hey']);
    expect(card.characterBook, isNotNull);
    expect(card.characterBook!.entries, hasLength(1));
    expect(card.characterBook!.entries.first.keys, ['魔法']);
  });

  test('世界书 entries 数组与对象两种形式', () {
    final objBook = WorldInfo.fromJson({
      'name': 'b1',
      'entries': {
        '1': {'key': ['a'], 'content': 'A'},
      },
    });
    final arrBook = WorldInfo.fromJson({
      'name': 'b2',
      'entries': [
        {'keys': ['b'], 'content': 'B', 'insert_order': 5},
      ],
    });
    expect(objBook.entries.single.content, 'A');
    expect(arrBook.entries.single.keys, ['b']);
    expect(arrBook.entries.single.insertionOrder, 5);
  });

  test('世界书关键词激活：primary/secondary/disabled/排序', () {
    final book = WorldInfo.fromJson({
      'name': 'b',
      'entries': [
        {
          'key': ['城堡'],
          'content': '第一',
          'insertion_order': 10,
        },
        {
          'key': ['城堡'],
          'keysecondary': ['战斗'],
          'content': '第二',
          'insertion_order': 5,
        },
        {
          'key': ['城堡'],
          'content': '禁用',
          'disabled': true,
        },
        {
          'key': ['不存在的词'],
          'content': '不激活',
        },
      ],
    });
    final msgs = [
      ChatMessage(
          role: 'user',
          content: '我在城堡里和敌人战斗',
          timestamp: DateTime.now().millisecondsSinceEpoch),
    ];
    final result = WorldInfoEngine.activate(
      books: [book],
      messages: msgs,
      charName: '角色',
      userName: '你',
    );
    // insertion_order 升序：5 在 10 前；disabled 与未命中不出现
    expect(result.map((e) => e.content).toList(), ['第二', '第一']);
    // 来源标注为世界书名
    expect(result.first.source, 'b');
  });

  test('世界书递归激活（3 层内）', () {
    final book = WorldInfo.fromJson({
      'name': 'b',
      'entries': [
        {
          'key': ['苹果'],
          'content': '关键词是香蕉',
          'insertion_order': 1,
        },
        {
          'key': ['香蕉'],
          'content': '递归命中',
          'insertion_order': 2,
          'recursive': true,
        },
      ],
    });
    final msgs = [
      ChatMessage(
          role: 'user',
          content: '我买了一个苹果',
          timestamp: DateTime.now().millisecondsSinceEpoch),
    ];
    final result = WorldInfoEngine.activate(
      books: [book],
      messages: msgs,
      charName: '角色',
      userName: '你',
    );
    expect(result.map((e) => e.content), contains('递归命中'));
  });

  test('PNG tEXt chara 块解析', () {
    const jsonStr =
        '{"spec":"chara_card V2","data":{"name":"测试角色","description":"d"}}';
    final b64 = base64.encode(utf8.encode(jsonStr));
    final keywordAndValue = <int>[
      ...utf8.encode('chara'),
      0,
      ...utf8.encode(b64),
    ];
    final png = BytesBuilder()
      ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      ..add(_pngChunk('tEXt', keywordAndValue))
      ..add(_pngChunk('IEND', []));
    final result = CardParser.parse(png.toBytes(), 'card.png');
    expect(result.card.name, '测试角色');
    expect(result.pngBytes, isNotNull);
  });

  test('无效文件抛出中文错误', () {
    expect(
      () => CardParser.parse(Uint8List.fromList(utf8.encode('just text')),
          'x.json'),
      throwsFormatException,
    );
  });

  test('PromptBuilder 组装顺序与 first_mes', () {
    final card = CharacterCard.fromJson({
      'name': '小艾',
      'description': '一个助手',
      'first_mes': '你好，{{user}}',
      'mes_example': '<START>\n{{user}}: 在吗\n{{char}}: 在',
    });
    final messages = PromptBuilder.build(
      card: card,
      history: [
        ChatMessage(
            role: 'user',
            content: '讲个故事',
            timestamp: DateTime.now().millisecondsSinceEpoch),
      ],
      worldBooks: const [],
      userName: '旅行者',
    ).messages;
    expect(messages.first.role, 'system');
    expect(messages.first.content, contains('你是 小艾。'));
    expect(messages.first.content, contains('一个助手'));
    expect(messages.first.content, contains('示例对话：'));
    expect(messages[1].role, 'assistant');
    expect(messages[1].content, '你好，旅行者');
    expect(messages[2].content, '讲个故事');
  });

  test('token 估算：中文 0.6、其余 0.25', () {
    expect(estimateTokens(''), 0);
    expect(estimateTokens('你好'), 2); // ceil(2 * 0.6) = 2
    expect(estimateTokens('ab'), 1); // ceil(2 * 0.25) = 1
    expect(estimateTokens('a你'), 1); // ceil(0.6 + 0.25) = 1
  });

  test('消息 token 字段随 JSON 持久化', () {
    const m = ChatMessage(
      role: 'assistant',
      content: '回复',
      timestamp: 1,
      promptTokens: 123,
      completionTokens: 45,
      tokensEstimated: true,
    );
    final back = ChatMessage.fromJson(m.toJson());
    expect(back.promptTokens, 123);
    expect(back.completionTokens, 45);
    expect(back.tokensEstimated, isTrue);
    final old = ChatMessage.fromJson({'role': 'user', 'content': 'x', 'timestamp': 2});
    expect(old.promptTokens, isNull);
    expect(old.tokensEstimated, isFalse);
  });

  test('变体字段 JSON 兼容与切换/编辑同步', () {
    const m = ChatMessage(
      role: 'assistant',
      content: 'B',
      timestamp: 1,
      variants: ['A', 'B'],
      variantIndex: 1,
      variantUsage: [
        VariantUsage(prompt: 10, completion: 5),
        VariantUsage(prompt: 12, completion: 6, estimated: true),
      ],
    );
    final back = ChatMessage.fromJson(m.toJson());
    expect(back.variants, ['A', 'B']);
    expect(back.variantIndex, 1);
    expect(back.content, 'B');
    expect(back.currentVariantUsage?.prompt, 12);
    expect(back.currentVariantUsage?.estimated, isTrue);

    // 切换变体 → 显示文本与 token 小字跟随
    final sw = back.copyWith(variantIndex: 0);
    expect(sw.content, 'A');
    expect(sw.currentVariantUsage?.prompt, 10);

    // 编辑当前变体 → variants 同步
    final ed = sw.copyWith(content: 'A2');
    expect(ed.content, 'A2');
    expect(ed.variants, ['A2', 'B']);
    expect(ed.variantIndex, 0);
  });

  test('旧数据无 variants → 空列表且 token 回退消息级', () {
    final old = ChatMessage.fromJson({
      'role': 'assistant',
      'content': 'x',
      'timestamp': 1,
      'promptTokens': 5,
      'completionTokens': 2,
    });
    expect(old.variants, isEmpty);
    expect(old.variantUsage, isEmpty);
    expect(old.currentVariantUsage?.prompt, 5);
    expect(old.toJson().containsKey('variants'), isFalse);

    // 收编：内容与变体不一致时（如中断恢复）文本并入新变体
    final mid = ChatMessage.fromJson({
      'role': 'assistant',
      'content': 'new-partial',
      'timestamp': 1,
      'variants': ['old-reply'],
      'variantIndex': 0,
    });
    expect(mid.variants, ['old-reply', 'new-partial']);
    expect(mid.variantIndex, 1);
    expect(mid.content, 'new-partial');
  });

  test('导出对话纯文本格式（首行标题 + 时间前缀，空占位不导出）', () {
    final text = buildExportText(
      charName: '小艾',
      userName: '旅行者',
      messages: [
        ChatMessage(
          role: 'assistant',
          content: '你好',
          timestamp: DateTime(2026, 10, 7, 14, 5).millisecondsSinceEpoch,
        ),
        ChatMessage(
          role: 'user',
          content: '在吗',
          timestamp: DateTime(2026, 10, 7, 14, 6).millisecondsSinceEpoch,
        ),
        // 生成中的空占位不导出
        ChatMessage(role: 'assistant', content: '', timestamp: 0),
      ],
      exportedAt: DateTime(2026, 10, 7, 15, 30),
    );
    final lines = text.trim().split('\n');
    expect(lines, hasLength(3));
    expect(lines.first, '# 和小艾的对话（导出时间 2026-10-07 15:30）');
    expect(lines[1], '[10-07 14:05] 小艾: 你好');
    expect(lines[2], '[10-07 14:06] 旅行者: 在吗');
  });

  test('快捷回复默认预置两条，主动删空后为空列表', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    expect(AppSettings.quickReplies, ['继续', '换个说法']);
    AppSettings.quickReplies = ['继续'];
    expect(AppSettings.quickReplies, ['继续']);
    AppSettings.quickReplies = [];
    expect(AppSettings.quickReplies, isEmpty);
  });

  test('显示快捷回复开关默认关闭，且不影响已存数据', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    // 无记录 = 关
    expect(AppSettings.showQuickReplies, isFalse);
    AppSettings.showQuickReplies = true;
    expect(AppSettings.showQuickReplies, isTrue);
    // 开关与数据解耦：开开关不改写快捷回复列表
    expect(AppSettings.quickReplies, ['继续', '换个说法']);
    AppSettings.showQuickReplies = false;
    expect(AppSettings.showQuickReplies, isFalse);
  });

  test('从未设置过主题色时默认赤陶酒红，已有选择保留', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    expect(AppSettings.themeSeed, 0xFF9C4632);
    AppSettings.themeSeed = 0xFF2196F3;
    expect(AppSettings.themeSeed, 0xFF2196F3);
    // 重新读取仍保留用户选择
    await AppSettings.init();
    expect(AppSettings.themeSeed, 0xFF2196F3);
  });
}
