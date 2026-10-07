import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/models/world_info.dart';
import 'package:litetavern/services/card_export.dart';
import 'package:litetavern/services/card_parser.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/storage.dart';
import 'package:litetavern/services/world_info_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ------------------------------------------------------------ 工厂 --

WorldInfoEntry _entry({
  required List<String> keys,
  List<String> secondary = const [],
  required String content,
  bool disabled = false,
  bool recursive = false,
  int scanDepth = 50,
  int position = 0,
  int depth = 0,
  bool useProbability = false,
  int probability = 100,
  int insertionOrder = 0,
}) =>
    WorldInfoEntry(
      keys: keys,
      keysSecondary: secondary,
      content: content,
      insertionOrder: insertionOrder,
      disabled: disabled,
      probability: probability,
      useProbability: useProbability,
      position: position,
      depth: depth,
      recursive: recursive,
      scanDepth: scanDepth,
      groupWeight: 100,
    );

WorldInfo _book(String name, List<WorldInfoEntry> entries) => WorldInfo(
      name: name,
      description: '',
      entries: entries,
    );

ChatMessage _msg(String role, String content, {int ts = 0}) => ChatMessage(
      role: role,
      content: content,
      timestamp: ts,
    );

/// 角色交替的普通历史。
List<ChatMessage> _history(List<String> contents) => [
        for (var i = 0; i < contents.length; i++)
          _msg(i.isEven ? 'user' : 'assistant', contents[i], ts: i),
      ];

CharacterCard _card(
  String name, {
  String desc = '',
  String pers = '',
  String scenario = '',
  String firstMes = '',
  String mesExample = '',
  String systemPrompt = '',
  WorldInfo? book,
}) =>
    CharacterCard(
      name: name,
      description: desc,
      personality: pers,
      scenario: scenario,
      firstMes: firstMes,
      mesExample: mesExample,
      systemPrompt: systemPrompt,
      alternateGreetings: const [],
      tags: const [],
      creator: '',
      characterBook: book,
    );

List<ActivatedEntry> _activate({
  required List<WorldInfo> books,
  required List<ChatMessage> messages,
  Random? random,
}) =>
    WorldInfoEngine.activate(
      books: books,
      messages: messages,
      charName: '爱丽丝',
      userName: '旅行者',
      random: random,
    );

// ------------------------------------------------------- PNG 测试工具 --

const List<int> _sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// 独立的按位 CRC-32 实现（与实现里的查表法互相验证）。
int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1);
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 造一个格式正确的 chunk（长度大端 + type + data + CRC）。
Uint8List _chunk(String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final body = <int>[...typeBytes, ...data];
  final crc = _crc32(body);
  return Uint8List.fromList([
    (data.length >> 24) & 0xFF,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
    ...body,
    (crc >> 24) & 0xFF,
    (crc >> 16) & 0xFF,
    (crc >> 8) & 0xFF,
    crc & 0xFF,
  ]);
}

/// 逐 chunk 解析 PNG，返回 (type, data, 存储的 CRC)。
List<(String, List<int>, int)> _walk(Uint8List bytes) {
  final out = <(String, List<int>, int)>[];
  var off = 8;
  while (off + 8 <= bytes.length) {
    final len = (bytes[off] << 24) |
        (bytes[off + 1] << 16) |
        (bytes[off + 2] << 8) |
        bytes[off + 3];
    final type = ascii.decode(bytes.sublist(off + 4, off + 8));
    final data = bytes.sublist(off + 8, off + 8 + len);
    final stored = (bytes[off + 8 + len] << 24) |
        (bytes[off + 9 + len] << 16) |
        (bytes[off + 10 + len] << 8) |
        bytes[off + 11 + len];
    out.add((type, data, stored));
    off += 12 + len;
    if (type == 'IEND') break;
  }
  return out;
}

/// 源 PNG：IHDR + 旧 tEXt chara + 旧 zTXt chara + tRNS + IDAT + IEND。
Uint8List _srcPng(String oldJson) {
  final b64 = base64.encode(utf8.encode(oldJson));
  final text = _chunk(
      'tEXt', <int>[...ascii.encode('chara'), 0, ...ascii.encode(b64)]);
  final ztext = _chunk(
      'zTXt',
      <int>[
        ...ascii.encode('chara'),
        0,
        0, // compression method = zlib
        ...ZLibCodec().encode(utf8.encode(b64)),
      ]);
  return Uint8List.fromList([
    ..._sig,
    ..._chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]),
    ...text,
    ...ztext,
    ..._chunk('tRNS', [0, 0]),
    ..._chunk('IDAT', [1, 2, 3, 4]),
    ..._chunk('IEND', const []),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ================================================ 世界书引擎（5） --

  test('次要关键词 AND：主词命中后还需至少一个次词', () {
    final books = [
      _book('测试书', [
        _entry(
          keys: ['城堡'],
          secondary: ['战斗', '夜袭'],
          content: '城堡守卫词条',
        ),
      ]),
    ];
    // 只有主词 → 不注入
    expect(
      _activate(books: books, messages: _history(['在城堡里闲逛了一下午'])),
      isEmpty,
    );
    // 主词 + 次词 → 注入
    final hit = _activate(
      books: books,
      messages: _history(['夜袭城堡的战斗打响了']),
    );
    expect(hit, hasLength(1));
    expect(hit.first.content, '城堡守卫词条');
    // 次词单独出现（无主词）→ 不注入
    expect(
      _activate(books: books, messages: _history(['野外的战斗与我无关'])),
      isEmpty,
    );
  });

  test('按概率随机注入：0 永不 / 100 必进 / 关闭开关则概率无效', () {
    final books = [
      _book('概率书', [
        _entry(keys: ['苹果'], content: '零概率', useProbability: true, probability: 0),
        _entry(keys: ['苹果'], content: '满概率', useProbability: true, probability: 100),
        _entry(keys: ['苹果'], content: '开关关', useProbability: false, probability: 0),
      ]),
    ];
    final hit = _activate(
      books: books,
      messages: _history(['一个苹果']),
      random: Random(7),
    );
    final contents = hit.map((a) => a.content).toSet();
    expect(contents, isNot(contains('零概率')));
    expect(contents, contains('满概率'));
    expect(contents, contains('开关关'));
  });

  test('递归注入最多 3 层：第四层链不触发', () {
    final books = [
      _book('链书', [
        // 基准：消息直接命中（非递归）
        _entry(keys: ['苹果'], content: '内容里提到香蕉', insertionOrder: 0),
        _entry(
            keys: ['香蕉'],
            content: '内容里提到樱桃',
            recursive: true,
            insertionOrder: 1),
        _entry(
            keys: ['樱桃'],
            content: '内容里提到葡萄',
            recursive: true,
            insertionOrder: 2),
        _entry(
            keys: ['葡萄'],
            content: '内容里提到柠檬',
            recursive: true,
            insertionOrder: 3),
        _entry(
            keys: ['柠檬'],
            content: '第五层内容',
            recursive: true,
            insertionOrder: 4),
      ]),
    ];
    final hit = _activate(books: books, messages: _history(['苹果']));
    final contents = hit.map((a) => a.content).toList();
    // 三层递归（香蕉→樱桃→葡萄）全部进来
    expect(contents, contains('内容里提到香蕉'));
    expect(contents, contains('内容里提到樱桃'));
    expect(contents, contains('内容里提到葡萄'));
    // 第四层（柠檬链）超出 3 层上限 → 不进
    expect(contents, isNot(contains('第五层内容')));
  });

  test('scanDepth：N 只回看最近 N 条，0 = 全程', () {
    final books = [
      _book('深度书', [
        _entry(keys: ['苹果'], content: '看两条', scanDepth: 2),
        _entry(keys: ['苹果'], content: '看全程', scanDepth: 0),
        _entry(keys: ['苹果'], content: '看三条', scanDepth: 3),
      ]),
    ];
    // 苹果在最早一条：回看 2 条够不到，0（全程）和 3 能够到
    final hit = _activate(
      books: books,
      messages: _history(['苹果', '梨', '香蕉']),
    );
    final contents = hit.map((a) => a.content).toSet();
    expect(contents, isNot(contains('看两条')));
    expect(contents, contains('看全程'));
    expect(contents, contains('看三条'));
  });

  test('position / depth 从条目透传到激活结果', () {
    final books = [
      _book('位置书', [
        _entry(keys: ['甲'], content: '深度条目', position: 1, depth: 3),
        _entry(keys: ['乙'], content: '卡后条目', position: 2),
        _entry(keys: ['丙'], content: '开头条目'),
      ]),
    ];
    final hit = _activate(
      books: books,
      messages: _history(['甲', '乙', '丙']),
    );
    final byContent = {for (final a in hit) a.content: a};
    expect(byContent['深度条目']!.position, 1);
    expect(byContent['深度条目']!.depth, 3);
    expect(byContent['卡后条目']!.position, 2);
    expect(byContent['开头条目']!.position, 0);
  });

  // ============================================ PromptBuilder（2） --

  test('position 0/1/2 分流：开头进 system 最前、卡后进示例后、深度进历史', () {
    final card = _card(
      '爱丽丝',
      desc: '一个角色',
      mesExample: '示例对话内容',
    );
    final books = [
      _book('分流书', [
        _entry(keys: ['甲'], content: 'FRONT_MARK', position: 0),
        _entry(keys: ['乙'], content: 'AFTER_MARK', position: 2),
        _entry(keys: ['丙'], content: 'DEPTH_MARK', position: 1, depth: 1),
      ]),
    ];
    final result = PromptBuilder.build(
      card: card,
      history: _history(['包含甲', '包含乙', '包含丙', '一句闲聊']),
      worldBooks: books,
      userName: '旅行者',
      historyLimit: 40,
    );
    final sys = result.systemText;
    // position 0：位于「你是」之前
    expect(sys.indexOf('FRONT_MARK'), isNot(-1));
    expect(sys.indexOf('FRONT_MARK'), lessThan(sys.indexOf('你是')));
    // position 2：位于「示例对话」之后
    expect(sys.indexOf('AFTER_MARK'), greaterThan(sys.indexOf('示例对话')));
    // position 1：不出现在 system，而是作为 user 消息插进历史
    expect(sys.contains('DEPTH_MARK'), isFalse);
    final msgs = result.messages;
    expect(msgs.first.role, 'system');
    // 4 条历史 + 1 条注入；depth=1 → 插到倒数第 2 条（历史 index 2）之前
    expect(msgs.length, 6);
    expect(msgs[3].role, 'user');
    expect(msgs[3].content, '[世界书] DEPTH_MARK');
    expect(msgs[4].content, '包含丙');
  });

  test('depth = 0 → 插到最新一条消息之前', () {
    final card = _card('爱丽丝');
    final books = [
      _book('深度书', [
        _entry(keys: ['乙'], content: 'DEPTH_MARK', position: 1, depth: 0),
      ]),
    ];
    final result = PromptBuilder.build(
      card: card,
      history: _history(['包含甲', '包含乙']),
      worldBooks: books,
      userName: '旅行者',
      historyLimit: 40,
    );
    final msgs = result.messages;
    // [system, h0, h1, WB]？不——depth=0 插到 h1 之前：
    // [system, h0, WB(user), h1]
    expect(msgs.length, 4);
    expect(msgs[2].role, 'user');
    expect(msgs[2].content, '[世界书] DEPTH_MARK');
    expect(msgs[3].content, '包含乙');
  });

  // ================================================ 角色卡导出（3） --

  test('buildExportJson：chara_card V2 结构，世界书有无都正确', () {
    final withBook = _card(
      '爱丽丝',
      desc: '简介',
      pers: '温柔',
      book: _book('内嵌', [
        _entry(keys: ['城堡'], content: '词条内容'),
      ]),
    );
    final decoded = jsonDecode(buildExportJson(withBook));
    expect(decoded['spec'], 'chara_card V2');
    expect(decoded['spec_version'], '2.0');
    final data = decoded['data'] as Map<String, dynamic>;
    expect(data['name'], '爱丽丝');
    expect(data['description'], '简介');
    expect(data['personality'], '温柔');
    expect(data.containsKey('character_book'), isTrue);
    final bookJson = data['character_book'] as Map<String, dynamic>;
    expect(bookJson['name'], '内嵌');
    expect((bookJson['entries'] as Map)['0'], isA<Map<String, dynamic>>());

    final noBook = _card('路人');
    final data2 =
        (jsonDecode(buildExportJson(noBook)) as Map<String, dynamic>)['data']
            as Map<String, dynamic>;
    expect(data2.containsKey('character_book'), isFalse);
  });

  test('safeFileName：非法路径字符替换、空名回退', () {
    expect(safeFileName('我的/角色:名?'), '我的_角色_名_');
    expect(safeFileName('  ..  '), '角色卡');
    expect(safeFileName('正常名字'), '正常名字');
    expect(safeFileName('a<b>c|d"e'), 'a_b_c_d_e');
  });

  test('PNG 导出往返：读回新数据、旧块移除、全 chunk CRC 正确', () {
    final oldJson = jsonEncode({
      'spec': 'chara_card V2',
      'spec_version': '2.0',
      'data': {'name': '旧名字'},
    });
    final src = _srcPng(oldJson);

    final card = _card(
      '新名字',
      desc: '导出的描述',
      book: _book('内嵌书', [
        _entry(keys: ['钥匙'], content: '世界书词条'),
      ]),
    );
    final newJson = buildExportJson(card);
    final out = embedCharaInPng(src, newJson);

    // 1) 所有 chunk 的 CRC 按独立实现复核
    final chunks = _walk(out);
    for (final (type, data, stored) in chunks) {
      final body = <int>[...ascii.encode(type), ...data];
      expect(stored, _crc32(body), reason: 'chunk $type CRC 不对');
    }

    // 2) 旧 zTXt 被移除；tEXt chara 恰好一个且内容是新 JSON
    expect(chunks.map((c) => c.$1).toList(),
        ['IHDR', 'tEXt', 'tRNS', 'IDAT', 'IEND']);
    final text = chunks.firstWhere((c) => c.$1 == 'tEXt').$2;
    final nul = text.indexOf(0);
    expect(ascii.decode(text.sublist(0, nul)), 'chara');
    final decodedText = utf8.decode(base64.decode(
        String.fromCharCodes(text.sublist(nul + 1))));
    expect(jsonDecode(decodedText)['data']['name'], '新名字');

    // 3) CardParser 读回的是新数据（且带世界书）
    final parsed = CardParser.parse(out, 'card.png');
    expect(parsed.card.name, '新名字');
    expect(parsed.card.description, '导出的描述');
    expect(parsed.card.characterBook, isNotNull);
    expect(parsed.card.characterBook!.entries.single.content, '世界书词条');
  });

  // ================================== 迁移与多配置（5，放最后） --

  test('旧单套 API 字段 → 名为「默认」的配置并激活，旧键删除', () async {
    SharedPreferences.setMockInitialValues({
      'api_base_url': 'https://legacy.example.com/v1',
      'api_key': 'sk-legacy',
      'model': 'legacy-model',
    });
    await AppSettings.init();

    expect(AppSettings.apiConfigs, hasLength(1));
    final active = AppSettings.activeApiConfig;
    expect(active.name, '默认');
    expect(active.baseUrl, 'https://legacy.example.com/v1');
    expect(active.key, 'sk-legacy');
    expect(active.model, 'legacy-model');
    // 委托读取：出网调用点走激活配置
    expect(AppSettings.baseUrl, 'https://legacy.example.com/v1');
    expect(AppSettings.apiConfigured, isTrue);

    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('api_base_url'), isNull);
    expect(sp.getString('api_key'), isNull);
    expect(sp.getString('model'), isNull);
  });

  test('重复 init 幂等：不重复迁移、id 与数据不变', () async {
    SharedPreferences.setMockInitialValues({
      'api_base_url': 'https://a.example.com',
    });
    await AppSettings.init();
    final id1 = AppSettings.activeApiConfig.id;
    final count1 = AppSettings.apiConfigs.length;

    await AppSettings.init(); // 第二次：应跳过迁移
    expect(AppSettings.apiConfigs, hasLength(count1));
    expect(AppSettings.activeApiConfig.id, id1);
    expect(AppSettings.baseUrl, 'https://a.example.com');
  });

  test('旧生成参数 → 默认预设；getter/setter 走激活预设，旧键删除', () async {
    SharedPreferences.setMockInitialValues({
      'temperature': 0.9,
      'top_p': 0.95,
      'max_tokens': 512,
    });
    await AppSettings.init();

    expect(AppSettings.genPresets, hasLength(1));
    final p = AppSettings.activePreset;
    expect(p.name, '默认');
    expect(p.temperature, 0.9);
    expect(p.topP, 0.95);
    expect(p.maxTokens, 512);
    expect(AppSettings.temperature, 0.9);

    // setter 写入激活预设
    AppSettings.temperature = 1.1;
    AppSettings.maxTokens = 256;
    expect(AppSettings.activePreset.temperature, 1.1);
    expect(AppSettings.genPresets.first.maxTokens, 256);

    final sp = await SharedPreferences.getInstance();
    expect(sp.getDouble('temperature'), isNull);
    expect(sp.getDouble('top_p'), isNull);
    expect(sp.getInt('max_tokens'), isNull);
  });

  test('全新安装：空「默认」配置 + 预设 0.8/1.0/0', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();

    expect(AppSettings.apiConfigs, hasLength(1));
    expect(AppSettings.activeApiConfig.name, '默认');
    expect(AppSettings.baseUrl, isEmpty);
    expect(AppSettings.apiConfigured, isFalse);

    final p = AppSettings.activePreset;
    expect(p.temperature, 0.8);
    expect(p.topP, 1.0);
    expect(p.maxTokens, 0);
  });

  test('删除配置：删激活项自动激活第一套，最后一套不可删', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    final first = AppSettings.activeApiConfig;

    AppSettings.apiConfigs = [
      first,
      const ApiConfig(id: 'c2', name: '二号', baseUrl: 'https://b.example.com'),
    ];
    AppSettings.activeApiConfigId = 'c2';
    expect(AppSettings.activeApiConfig.id, 'c2');

    AppSettings.deleteApiConfig('c2');
    expect(AppSettings.activeApiConfig.id, first.id);
    expect(AppSettings.apiConfigs, hasLength(1));

    // 只剩一套 → 删不动
    AppSettings.deleteApiConfig(first.id);
    expect(AppSettings.apiConfigs, hasLength(1));
    expect(AppSettings.activeApiConfig.id, first.id);
  });
}
