import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/chat_group.dart';
import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/services/prompt_builder.dart';
import 'package:litetavern/services/summarize.dart';

CharacterCard _card(String name, {String desc = '', String pers = ''}) =>
    CharacterCard(
      name: name,
      description: desc,
      personality: pers,
      scenario: '',
      firstMes: '',
      mesExample: '',
      systemPrompt: '',
      alternateGreetings: const [],
      tags: const [],
      creator: '',
    );

ChatMessage _msg(
  String role,
  String content, {
  int ts = 0,
  String? senderId,
  String? senderName,
}) =>
    ChatMessage(
      role: role,
      content: content,
      timestamp: ts,
      senderId: senderId,
      senderName: senderName,
    );

void main() {
  // ---------------------------------------------------- sender 序列化 --

  test('senderId/senderName 往返序列化', () {
    final m = _msg('assistant', '你好', senderId: 'c1', senderName: '爱丽丝');
    final json = m.toJson();
    expect(json['senderId'], 'c1');
    expect(json['senderName'], '爱丽丝');
    final back = ChatMessage.fromJson(json);
    expect(back.senderId, 'c1');
    expect(back.senderName, '爱丽丝');
  });

  test('旧数据无 sender 字段 → 为 null（单聊兼容）', () {
    final back = ChatMessage.fromJson({
      'role': 'user',
      'content': 'hi',
      'timestamp': 123,
    });
    expect(back.senderId, isNull);
    expect(back.senderName, isNull);
    // toJson 不写入 null 字段，旧数据字节不变
    expect(back.toJson().containsKey('senderId'), isFalse);
    expect(back.toJson().containsKey('senderName'), isFalse);
  });

  test('copyWith 保留 sender 字段', () {
    final m = _msg('assistant', 'a', senderId: 'c9', senderName: 'Bob');
    final c = m.copyWith(content: 'b');
    expect(c.senderId, 'c9');
    expect(c.senderName, 'Bob');
  });

  // -------------------------------------------------- ChatGroup 存储 --

  test('ChatGroup JSON 往返与指针钳制', () {
    final g = ChatGroup(
      id: 'g1',
      name: '小群',
      memberIds: ['a', 'b', 'c'],
      createdAt: 42,
      turnIndex: 2,
    );
    final back = ChatGroup.fromJson(g.toJson());
    expect(back.turnIndex, 2);
    expect(back.memberIds, ['a', 'b', 'c']);

    // 成员变少后指针越界 → 钳制回合法范围
    final clamped = ChatGroup.fromJson({
      ...g.toJson(),
      'memberIds': ['a', 'b'],
      'turnIndex': 5,
    });
    expect(clamped.turnIndex, 1);
  });

  // ------------------------------------------------------- 轮转规则 --

  test('parseMentions：@ 名字子串命中，无命中返回 null', () {
    const names = ['爱丽丝', '丽丝', '鲍勃'];
    // '@' 锚点防止短名被长名误伤
    expect(parseMentions('喂 @爱丽丝 说话', names), {0});
    expect(parseMentions('@爱丽丝 和 @鲍勃 看这里', names), {0, 2});
    expect(parseMentions('随便说点什么', names), isNull);
  });

  test('turnOrder：全员轮转从指针起绕行一圈', () {
    expect(turnOrder(3, 0, null), [0, 1, 2]);
    expect(turnOrder(3, 1, null), [1, 2, 0]);
    expect(turnOrder(3, 2, null), [2, 0, 1]);
    expect(turnOrder(0, 0, null), isEmpty);
  });

  test('turnOrder：被 @ 成员按群内严格顺序回复（不随指针旋转）', () {
    // 指针在 1，@ 命中 {0,2} → 仍按 [0, 2]
    expect(turnOrder(3, 1, {0, 2}), [0, 2]);
    expect(turnOrder(3, 2, {2}), [2]);
    expect(turnOrder(3, 0, <int>{}), isEmpty);
  });

  test('advanceTurn：停在当前角色、指针不回退', () {
    // 成员 1 发言中被停止 → 指针已推进到 2，下次从 2 继续
    expect(advanceTurn(3, 1), 2);
    expect(turnOrder(3, advanceTurn(3, 1), null), [2, 0, 1]);
    // 最后一位发言后绕回 0
    expect(advanceTurn(3, 2), 0);
    expect(advanceTurn(0, 0), 0);
  });

  // ------------------------------------------------------- 摘要触发 --

  List<ChatMessage> msgs(int n, {int base = 1000}) => [
        for (var i = 0; i < n; i++)
          _msg(i.isEven ? 'user' : 'assistant', 'm$i', ts: base + i),
      ];

  test('summaryIsStale：未超窗不触发', () {
    expect(summaryIsStale(msgs(10), null, 10), isFalse);
    expect(summaryIsStale(msgs(10), null, 40), isFalse);
  });

  test('summaryIsStale：超窗且无摘要 → 触发', () {
    expect(summaryIsStale(msgs(11), null, 10), isTrue);
    expect(
      summaryIsStale(msgs(11), const ChatSummary(text: '', updatedAt: 0), 10),
      isTrue,
    );
  });

  test('summaryIsStale：摘要覆盖点落后于早期窗口 → 过期', () {
    final list = msgs(15); // ts 1000..1014，早期窗口 = 前 5 条 (1000..1004)
    // 摘要只覆盖到 1004 → 不过期
    expect(
      summaryIsStale(
          list, const ChatSummary(text: '早期内容', updatedAt: 1004), 10),
      isFalse,
    );
    // 摘要覆盖点更晚（覆盖了本该在窗口外的消息的后续）→ 也不过期
    expect(
      summaryIsStale(
          list, const ChatSummary(text: '早期内容', updatedAt: 1009), 10),
      isFalse,
    );
    // 有更晚消息滑出窗口（覆盖点 999 < 窗口内 1000）→ 过期
    expect(
      summaryIsStale(
          list, const ChatSummary(text: '早期内容', updatedAt: 999), 10),
      isTrue,
    );
  });

  test('earlyMessages / hasSummarizableHistory', () {
    expect(earlyMessages(msgs(10), 10), isEmpty);
    expect(hasSummarizableHistory(msgs(10), 10), isFalse);
    final early = earlyMessages(msgs(13), 10);
    expect(early.length, 3);
    expect(hasSummarizableHistory(msgs(13), 10), isTrue);
    // 空内容占位不进摘要输入（13 条里的前 3 条 = 占位 + m0 + m1 → 只留 2 条）
    final withBlank = [
      _msg('user', '', ts: 1),
      ...msgs(12),
    ];
    expect(earlyMessages(withBlank, 10).length, 2);
  });

  test('normalizeSummary：去包裹/前缀并截断 300 字', () {
    expect(normalizeSummary('```摘要是这样```'), '摘要是这样');
    expect(normalizeSummary('摘要：一段话'), '一段话');
    expect(normalizeSummary('“引号包裹”'), '引号包裹');
    expect(normalizeSummary('x' * 500).length, 300);
  });

  test('ChatSummary JSON 往返', () {
    const s = ChatSummary(text: '早前他们聊了天气', updatedAt: 456);
    final back = ChatSummary.fromJson(s.toJson());
    expect(back.text, s.text);
    expect(back.updatedAt, 456);
    expect(ChatSummary.fromJson(const {}).isEmpty, isTrue);
  });

  // ------------------------------------------------- 群聊 prompt 规则 --

  test('buildGroup：成员为空抛错', () {
    expect(
      () => PromptBuilder.buildGroup(
        members: const [],
        history: const [],
        worldBooks: const [],
        userName: '你',
      ),
      throwsArgumentError,
    );
  });

  test('buildGroup：system 含角色名册与扮演规则', () {
    final members = [
      _card('爱丽丝', desc: '红发', pers: '活泼'),
      _card('鲍勃', desc: '沉稳', pers: '冷静'),
    ];
    final result = PromptBuilder.buildGroup(
      members: members,
      history: const [],
      worldBooks: const [],
      userName: '旅行者',
      speakerName: '鲍勃',
    );
    final sys = result.systemText;
    expect(sys, contains('以下角色将参加对话：'));
    expect(sys, contains('【爱丽丝】红发'));
    expect(sys, contains('【鲍勃】沉稳'));
    expect(sys, contains('对话规则：你只扮演【鲍勃】并以其口吻发言'));
    expect(sys, contains('每条消息以「名字: 」开头'));
    expect(sys, contains('其他角色由系统扮演，不要替他人发言'));
  });

  test('buildGroup：成员描述超 300 字被截断', () {
    final long = _card('长名', desc: '字' * 400);
    final result = PromptBuilder.buildGroup(
      members: [long, _card('短名')],
      history: const [],
      worldBooks: const [],
      userName: '你',
    );
    expect(result.systemText.contains('字' * 301), isFalse);
    expect(result.systemText, contains('字' * 300));
  });

  test('buildGroup：历史渲染为「名字: 内容」', () {
    final members = [_card('爱丽丝'), _card('鲍勃')];
    final result = PromptBuilder.buildGroup(
      members: members,
      history: [
        _msg('user', '你好'),
        _msg('assistant', '你好呀', senderId: 'b', senderName: '鲍勃'),
        _msg('assistant', '', senderId: 'a', senderName: '爱丽丝'), // 空占位跳过
      ],
      worldBooks: const [],
      userName: '旅行者',
      historyLimit: 40,
    );
    final contents = [for (final m in result.messages) m.content];
    expect(contents, contains('旅行者: 你好'));
    expect(contents, contains('鲍勃: 你好呀'));
    // 空占位不进历史
    expect(contents.any((c) => c.endsWith(': ')), isFalse);
    // 未指定 senderName 的 assistant 回退名册第一位
    final fb = PromptBuilder.buildGroup(
      members: members,
      history: [_msg('assistant', '只有内容')],
      worldBooks: const [],
      userName: '旅行者',
    );
    expect(fb.messages.last.content, '爱丽丝: 只有内容');
  });

  test('buildGroup：摘要非空时追加到 system 末尾', () {
    final result = PromptBuilder.buildGroup(
      members: [_card('爱丽丝'), _card('鲍勃')],
      history: const [],
      worldBooks: const [],
      userName: '你',
      summaryText: '早前他们在森林里冒险',
    );
    expect(result.systemText, contains('【早期对话摘要】早前他们在森林里冒险'));
    expect(
      result.systemText.trim().endsWith('【早期对话摘要】早前他们在森林里冒险'),
      isTrue,
    );
  });
}
