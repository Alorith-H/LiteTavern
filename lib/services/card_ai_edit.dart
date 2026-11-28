import 'dart:convert';

import '../models/character_card.dart';
import 'prompt_builder.dart';

/// 编辑页「AI 修改角色」能作用的字段。
///
/// 与编辑页的输入框一一对应：名字 / 简介 / 性格 / 场景 / 开场白。
enum CardAiEditScope {
  /// 只改性格
  personality,

  /// 只改开场白
  greeting,

  /// 只改简介与场景（背景设定）
  description,

  /// 五个字段一起润色
  polishAll;

  String get label => switch (this) {
        CardAiEditScope.personality => '只改性格',
        CardAiEditScope.greeting => '只改开场白',
        CardAiEditScope.description => '只改背景',
        CardAiEditScope.polishAll => '整体润色',
      };

  String get hint => switch (this) {
        CardAiEditScope.personality => '例如：性格再冷淡一点，话少一些',
        CardAiEditScope.greeting => '例如：开场白换成一封信',
        CardAiEditScope.description => '例如：背景改到雨夜的旧书店',
        CardAiEditScope.polishAll => '例如：整体收紧，去掉重复的形容',
      };

  /// 允许模型改写的字段（内部键，见 [fieldLabels]）。
  List<String> get fields => switch (this) {
        CardAiEditScope.personality => const ['personality'],
        CardAiEditScope.greeting => const ['firstMes'],
        CardAiEditScope.description => const ['description', 'scenario'],
        CardAiEditScope.polishAll => const [
            'description',
            'personality',
            'scenario',
            'firstMes',
          ],
      };

  static CardAiEditScope fromName(String name) =>
      CardAiEditScope.values.firstWhere(
        (s) => s.name == name,
        orElse: () => CardAiEditScope.polishAll,
      );
}

/// 内部字段键 → 中文名（提示词与对比弹窗共用）。
const Map<String, String> kCardEditFieldLabels = {
  'name': '名字',
  'description': '简介',
  'personality': '性格',
  'scenario': '场景',
  'firstMes': '开场白',
};

/// 模型输出用的字段名（chara_card 规范）↔ 内部键。
const Map<String, String> _kApiToInternal = {
  'name': 'name',
  'description': 'description',
  'personality': 'personality',
  'scenario': 'scenario',
  'first_mes': 'firstMes',
};

const Map<String, String> _kInternalToApi = {
  'name': 'name',
  'description': 'description',
  'personality': 'personality',
  'scenario': 'scenario',
  'firstMes': 'first_mes',
};

/// 一次 AI 修改请求：当前字段内容 + 用户要求 + 作用范围。
class CardAiEditInput {
  final CardAiEditScope scope;
  final String instruction;
  final Map<String, String> fields;

  const CardAiEditInput({
    required this.scope,
    required this.instruction,
    required this.fields,
  });

  /// 从角色卡取当前字段。
  factory CardAiEditInput.fromCard({
    required CharacterCard card,
    required CardAiEditScope scope,
    required String instruction,
    String? name,
    String? description,
    String? personality,
    String? scenario,
    String? firstMes,
  }) =>
      CardAiEditInput(
        scope: scope,
        instruction: instruction,
        fields: {
          'name': name ?? card.name,
          'description': description ?? card.description,
          'personality': personality ?? card.personality,
          'scenario': scenario ?? card.scenario,
          'firstMes': firstMes ?? card.firstMes,
        },
      );
}

/// AI 修改的系统提示：只输出要改字段的 JSON。
const String kCardAiEditSystem = r'''
你是角色卡编辑助手。用户会给出角色卡当前的字段内容和一句修改要求，
你只输出「需要修改的字段」组成的 JSON 对象，不要输出其它内容。

输出规则：
- 只输出 JSON 本身，不要代码围栏（```），不要解释、不要前后缀文字；
- 键只能是：name、description、personality、scenario、first_mes；
- 值是改写后的完整文本（字符串），不是片段；
- 只输出确实需要改动的字段，没改的字段不要出现；
- 用户要求与角色卡无关、或无法理解时，输出 {}；
- 保留原有设定与事实，不新增角色、不新增世界观名词；
- 语言与原字段一致（通常为中文），长度与原文接近，不堆砌形容词；
- 开场白是角色对用户说的第一段话，可以包含动作描写，不要加旁白说明。
''';

/// 拼出一次请求的用户提示。字段按 [CardAiEditScope.fields] 裁剪，
/// 其余字段只给一行摘要，避免上下文过长。
String buildCardAiEditUserPrompt(CardAiEditInput input) {
  final scopeFields = input.scope.fields;
  final buf = StringBuffer()
    ..writeln('角色卡当前内容：')
    ..writeln('名字：${_clip(input.fields['name'] ?? '', 80)}');
  for (final key in const ['description', 'personality', 'scenario', 'firstMes']) {
    final label = kCardEditFieldLabels[key]!;
    final value = (input.fields[key] ?? '').trim();
    if (scopeFields.contains(key)) {
      buf.writeln('$label：');
      buf.writeln(value.isEmpty ? '（空）' : _clip(value, 1600));
    } else {
      buf.writeln('$label（本次不改，仅供参考）：${_clip(value, 160)}');
    }
  }
  buf
    ..writeln()
    ..writeln('修改范围：${input.scope.label}（'
        '${scopeFields.map((k) => kCardEditFieldLabels[k]).join('、')}）')
    ..writeln('修改要求：${input.instruction.trim()}');
  return buf.toString();
}

/// 组装成标准 chat 消息（system + user），供 ApiClient 使用。
List<PromptMessage> buildCardAiEditMessages(CardAiEditInput input) => [
      const PromptMessage(role: 'system', content: kCardAiEditSystem),
      PromptMessage(role: 'user', content: buildCardAiEditUserPrompt(input)),
    ];

/// 解析模型返回的 JSON，返回「内部字段键 → 新文本」，只保留白名单字段。
///
/// 兼容：```json 围栏、{"fields": {...}} 包裹、直接平铺对象。
/// 解析失败或没有可用字段时返回空 Map（调用方提示「没改出来」）。
Map<String, String> parseCardAiEditResult(String raw) {
  final text = _stripFences(raw.trim());
  if (text.isEmpty) return const {};
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return const {};
  Object? decoded;
  try {
    decoded = jsonDecode(text.substring(start, end + 1));
  } catch (_) {
    return const {};
  }
  if (decoded is! Map) return const {};
  final wrapped = decoded['fields'];
  final source = wrapped is Map ? wrapped : decoded;
  final out = <String, String>{};
  source.forEach((key, value) {
    if (value is! String) return;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    final internal = _kApiToInternal[key.toString()];
    if (internal == null) return;
    out[internal] = trimmed;
  });
  return out;
}

/// 模型输入里的 API 字段名（供测试与调试）。
String apiFieldNameOf(String internal) => _kInternalToApi[internal] ?? internal;

String _clip(String s, int max) {
  final t = s.trim();
  if (t.length <= max) return t;
  return '${t.substring(0, max)}…';
}

String _stripFences(String s) {
  if (!s.contains('```')) return s;
  final buf = StringBuffer();
  var inFence = false;
  for (final line in s.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) buf.writeln(line);
  }
  final joined = buf.toString().trim();
  return joined.isEmpty ? s.replaceAll('```', '').trim() : joined;
}
