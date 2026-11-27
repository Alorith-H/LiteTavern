import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:litetavern/models/chat_message.dart';
import 'package:litetavern/models/character_card.dart';
import 'package:litetavern/services/charx_importer.dart';
import 'package:litetavern/services/import_report.dart';
import 'package:litetavern/services/st_chat_importer.dart';

CharacterCard _card({
  String name = '阿青',
  String description = '一个爱看书的人',
  String firstMes = '你好。',
  String personality = '安静',
  String scenario = '图书馆',
  String systemPrompt = '',
  String mesExample = '你好啊',
  List<String> alternateGreetings = const [],
}) {
  return CharacterCard(
    name: name,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMes: firstMes,
    mesExample: mesExample,
    systemPrompt: systemPrompt,
    alternateGreetings: alternateGreetings,
    tags: const [],
    creator: '',
  );
}

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, content) {
    archive.addFile(ArchiveFile(name, content.length, content));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive) ?? const []);
}

Map<String, dynamic> _cardJson({
  String name = '阿青',
  String description = '一个爱看书的人',
  String firstMes = '你好。',
  Map<String, dynamic>? extensions,
  Map<String, dynamic>? extra,
}) {
  return {
    'name': name,
    'description': description,
    'personality': '安静',
    'scenario': '图书馆',
    'first_mes': firstMes,
    'mes_example': '你好啊',
    'tags': <String>[],
    'creator': '',
    'extensions': ?extensions,
    ...?extra,
  };
}

void main() {
  group('ImportAnalyzer.forCard', () {
    test('字段齐全时判为可用', () {
      final card = _card();
      final report = ImportAnalyzer.forCard(
        _cardJson(),
        card,
        hasAvatar: true,
      );
      expect(report.fit, ImportFit.usable);
      expect(report.summary, contains('完整使用'));
      expect(report.hasWarnings, isFalse);
    });

    test('缺描述和开场白时只能保留', () {
      final card = _card(description: '', firstMes: '');
      final report = ImportAnalyzer.forCard(
        _cardJson(description: '', firstMes: ''),
        card,
      );
      expect(report.fit, ImportFit.preserveOnly);
      expect(report.findings.any((f) => f.title == '没有描述'), isTrue);
      expect(report.findings.any((f) => f.title == '没有开场白'), isTrue);
    });

    test('只有备用开场白时给提示但不是硬缺失', () {
      final card = _card(firstMes: '', alternateGreetings: ['备用一']);
      final report = ImportAnalyzer.forCard(
        _cardJson(firstMes: ''),
        card,
        hasAvatar: true,
      );
      expect(
        report.findings.any((f) => f.title == '只有备用开场白'),
        isTrue,
      );
      // 有备用开场白就算有开场内容，仍可完整使用（只提示一句）
      expect(report.fit, ImportFit.usable);
    });

    test('不支持的扩展会作为提醒列出', () {
      final report = ImportAnalyzer.forCard(
        _cardJson(extensions: {
          'regex_scripts': [1],
          'mvu': {'a': 1},
          'depth_prompt': {'depth': 4},
        }),
        _card(),
        hasAvatar: true,
      );
      final unsupported =
          report.findings.firstWhere((f) => f.title == '不支持的扩展');
      expect(unsupported.isWarning, isTrue);
      expect(unsupported.detail, contains('regex_scripts'));
      expect(unsupported.detail, contains('不执行卡内脚本'));
    });

    test('未知字段只读展示', () {
      final report = ImportAnalyzer.forCard(
        _cardJson(extra: {'my_custom_field': 1, 'another_one': 'x'}),
        _card(),
        hasAvatar: true,
      );
      final unknown =
          report.findings.firstWhere((f) => f.title.contains('未识别的字段'));
      expect(unknown.detail, contains('another_one'));
      expect(unknown.detail, contains('my_custom_field'));
    });

    test('v2 包装（data 内字段）也能读到扩展', () {
      final raw = {
        'spec': 'chara_card_v2',
        'data': _cardJson(extensions: {'st-script': {}}),
      };
      final report = ImportAnalyzer.forCard(raw, _card(), hasAvatar: true);
      expect(
        report.findings.any((f) => f.title == '不支持的扩展'),
        isTrue,
      );
    });
  });

  group('ImportAnalyzer.forChat', () {
    test('空列表判为只能保留', () {
      final report = ImportAnalyzer.forChat(const []);
      expect(report.fit, ImportFit.preserveOnly);
      expect(report.hasWarnings, isTrue);
    });

    test('正常条数给出双方统计', () {
      final msgs = [
        ChatMessage(role: 'user', content: '你好', timestamp: 1),
        ChatMessage(role: 'assistant', content: '在的', timestamp: 2),
        ChatMessage(role: 'user', content: '在吗', timestamp: 3),
      ];
      final report = ImportAnalyzer.forChat(msgs, rawLineCount: 4);
      expect(report.fit, ImportFit.usable);
      expect(report.findings.first.title, '共 3 条消息');
      expect(report.findings.first.detail, contains('你 2 条'));
      expect(report.findings.any((f) => f.title == '文件有额外内容'), isTrue);
    });

    test('跳过行与条数不足都给提醒', () {
      final report = ImportAnalyzer.forChat(
        [ChatMessage(role: 'user', content: '嗨', timestamp: 1)],
        rawLineCount: 3,
        skippedLines: 2,
      );
      expect(report.fit, ImportFit.partial);
      expect(
        report.findings.any((f) => f.title == '跳过 2 行' && f.isWarning),
        isTrue,
      );
    });
  });

  group('CharxImporter', () {
    test('识别 zip 魔数与扩展名', () {
      final bytes = _zip({'a.txt': [1, 2, 3]});
      expect(CharxImporter.looksLikeZip(bytes), isTrue);
      expect(CharxImporter.isCharxName('x.CHARX'), isTrue);
      expect(CharxImporter.isCharxName('x.png'), isFalse);
    });

    test('解析 card.json、取最大图当头像、统计资源', () {
      final big = List<int>.filled(900, 7);
      final small = List<int>.filled(100, 1);
      final bytes = _zip({
        'card.json': utf8.encode(jsonEncode(_cardJson())),
        'assets/icon/small.png': small,
        'assets/big.png': big,
        'assets/note.md': utf8.encode('# note'),
      });
      final result = CharxImporter.parse(bytes, filename: 'demo.charx');
      expect(result.card.name, '阿青');
      expect(result.avatarBytes?.length, big.length);
      expect(result.assetCount, 2);
      expect(result.report.fit, ImportFit.usable);
    });

    test('没有 card.json 时报错', () {
      final bytes = _zip({'readme.md': utf8.encode('nothing')});
      expect(
        () => CharxImporter.parse(bytes),
        throwsA(isA<CharxFormatException>()),
      );
    });

    test('不是 zip 时报错', () {
      expect(
        () => CharxImporter.parse(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<CharxFormatException>()),
      );
    });
  });

  group('StChatImporter', () {
    String jsonl(List<Map<String, dynamic>> rows) =>
        rows.map(jsonEncode).join('\n');

    test('按 is_user 与 name 分角色、读时间戳', () {
      final bytes = Uint8List.fromList(utf8.encode(jsonl([
        {
          'name': '你',
          'is_user': true,
          'mes': '你好',
          'send_date': '2026-01-02T03:04:05.000Z',
        },
        {'name': '阿青', 'is_user': false, 'mes': '在的', 'send_date': 'x'},
      ])));
      final result = StChatImporter.parse(bytes, charName: '阿青', userName: '你');
      expect(result.messages.length, 2);
      expect(result.messages[0].role, 'user');
      expect(result.messages[1].role, 'assistant');
      expect(result.messages[1].senderName, '阿青');
      expect(
        result.messages[0].timestamp,
        DateTime.parse('2026-01-02T03:04:05.000Z').millisecondsSinceEpoch,
      );
    });

    test('秒级时间戳会换算成毫秒', () {
      final bytes = Uint8List.fromList(utf8.encode(jsonl([
        {'name': '阿青', 'is_user': false, 'mes': '嗯', 'send_date': 1700000000},
      ])));
      final result = StChatImporter.parse(bytes, charName: '阿青');
      expect(result.messages.single.timestamp, 1700000000 * 1000);
    });

    test('坏行与空内容计入跳过', () {
      final text = '${jsonEncode({'name': '你', 'is_user': true, 'mes': '嗨'})}\n'
          'not json\n'
          '${jsonEncode({'name': '阿青', 'is_user': false, 'mes': ''})}\n';
      final result = StChatImporter.parse(
        Uint8List.fromList(utf8.encode(text)),
        charName: '阿青',
        userName: '你',
      );
      expect(result.messages.length, 1);
      expect(result.skippedLines, 2);
      expect(result.report.hasWarnings, isTrue);
    });

    test('没有可导入消息时抛错', () {
      final bytes = Uint8List.fromList(utf8.encode('{"foo":1}\n'));
      expect(
        () => StChatImporter.parse(bytes),
        throwsA(isA<StChatFormatException>()),
      );
    });

    test('内容探测认得 jsonl', () {
      final ok = Uint8List.fromList(utf8.encode(
        '${jsonEncode({'is_user': true, 'mes': 'hi'})}\n',
      ));
      final no = Uint8List.fromList(utf8.encode('<html></html>'));
      expect(StChatImporter.looksLikeJsonl(ok), isTrue);
      expect(StChatImporter.looksLikeJsonl(no), isFalse);
      expect(StChatImporter.isJsonlName('a.JSONL'), isTrue);
    });
  });
}
