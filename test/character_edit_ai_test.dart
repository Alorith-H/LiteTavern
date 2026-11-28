import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/services/card_ai_edit.dart';

CharacterCard _card({
  String name = '阿岚',
  String description = '旧书店的店主。',
  String personality = '冷淡，话少。',
  String scenario = '雨夜的旧书店。',
  String firstMes = '你站在门口，雨水顺着伞尖往下淌。',
}) =>
    CharacterCard(
      name: name,
      description: description,
      personality: personality,
      scenario: scenario,
      firstMes: firstMes,
      mesExample: '',
      systemPrompt: '',
      alternateGreetings: const [],
      tags: const [],
      creator: '',
    );

void main() {
  group('CardAiEditScope', () {
    test('每个范围都有标签、示例与非空字段列表', () {
      for (final scope in CardAiEditScope.values) {
        expect(scope.label, isNotEmpty);
        expect(scope.hint, isNotEmpty);
        expect(scope.fields, isNotEmpty);
      }
    });

    test('只改性格只涉及 personality；整体润色含四个字段', () {
      expect(CardAiEditScope.personality.fields, ['personality']);
      expect(CardAiEditScope.greeting.fields, ['firstMes']);
      expect(CardAiEditScope.description.fields, ['description', 'scenario']);
      expect(
        CardAiEditScope.polishAll.fields,
        containsAll(<String>['description', 'personality', 'scenario', 'firstMes']),
      );
    });

    test('fromName 未知名回落整体润色', () {
      expect(
        CardAiEditScope.fromName('personality'),
        CardAiEditScope.personality,
      );
      expect(CardAiEditScope.fromName('不存在'), CardAiEditScope.polishAll);
    });
  });

  group('buildCardAiEditUserPrompt', () {
    test('包含当前内容、修改范围与用户要求', () {
      final input = CardAiEditInput.fromCard(
        card: _card(),
        scope: CardAiEditScope.personality,
        instruction: '再冷淡一点',
      );
      final prompt = buildCardAiEditUserPrompt(input);
      expect(prompt, contains('性格'));
      expect(prompt, contains('冷淡，话少。'));
      expect(prompt, contains('修改范围：只改性格'));
      expect(prompt, contains('修改要求：再冷淡一点'));
    });

    test('范围外的字段只给摘要并注明本次不改', () {
      final input = CardAiEditInput.fromCard(
        card: _card(),
        scope: CardAiEditScope.personality,
        instruction: '微调',
      );
      final prompt = buildCardAiEditUserPrompt(input);
      expect(prompt, contains('简介（本次不改，仅供参考）：'));
      expect(prompt, contains('开场白（本次不改，仅供参考）：'));
    });

    test('空字段显示（空）', () {
      final input = CardAiEditInput.fromCard(
        card: _card(personality: ''),
        scope: CardAiEditScope.personality,
        instruction: '随便改改',
      );
      expect(buildCardAiEditUserPrompt(input), contains('（空）'));
    });

    test('超长字段被裁剪，正文不超过 2000 字', () {
      final long = '设定' * 1200;
      final input = CardAiEditInput.fromCard(
        card: _card(personality: long),
        scope: CardAiEditScope.personality,
        instruction: '压缩',
      );
      final prompt = buildCardAiEditUserPrompt(input);
      expect(prompt.length, lessThan(2100));
      expect(prompt, contains('…'));
    });

    test('消息列表为 system + user，system 是约定好的提示', () {
      final msgs = buildCardAiEditMessages(
        CardAiEditInput.fromCard(
          card: _card(),
          scope: CardAiEditScope.greeting,
          instruction: '换成一封信',
        ),
      );
      expect(msgs, hasLength(2));
      expect(msgs.first.role, 'system');
      expect(msgs.first.content, kCardAiEditSystem);
      expect(msgs.last.role, 'user');
    });
  });

  group('parseCardAiEditResult', () {
    test('解析平铺 JSON 并把 first_mes 映射成 firstMes', () {
      final out = parseCardAiEditResult(
        '{"personality":"更冷淡","first_mes":"……"}',
      );
      expect(out, {'personality': '更冷淡', 'firstMes': '……'});
    });

    test('兼容 ```json 围栏', () {
      final out = parseCardAiEditResult(
        '```json\n{"description":"新的背景"}\n```',
      );
      expect(out, {'description': '新的背景'});
    });

    test('兼容 {"fields": {...}} 包裹', () {
      final out = parseCardAiEditResult(
        '{"fields":{"scenario":"深夜的便利店"}}',
      );
      expect(out, {'scenario': '深夜的便利店'});
    });

    test('丢掉白名单外的键与空值', () {
      final out = parseCardAiEditResult(
        '{"name":"阿岚","unknown":"x","tags":[],"personality":"  "}',
      );
      expect(out, {'name': '阿岚'});
    });

    test('模型返回 {} 或纯文本时返回空 Map', () {
      expect(parseCardAiEditResult('{}'), isEmpty);
      expect(parseCardAiEditResult('这次没什么要改的'), isEmpty);
      expect(parseCardAiEditResult(''), isEmpty);
    });

    test('数组或非对象 JSON 返回空 Map', () {
      expect(parseCardAiEditResult('[1,2,3]'), isEmpty);
      expect(parseCardAiEditResult('{"personality": 12}'), isEmpty);
    });

    test('apiFieldNameOf 输出 chara_card 规范名', () {
      expect(apiFieldNameOf('firstMes'), 'first_mes');
      expect(apiFieldNameOf('personality'), 'personality');
    });
  });
}
