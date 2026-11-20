import 'prompt_builder.dart';

/// 让模型以「用户本人」口吻写出下一句发言的元指令。
///
/// 放在对话 messages 末尾（user 角色）：模型通常会把「最后一条 user 消息
/// 当作用户想说的话」，因此要用明确的元指令把它和自我代入区分开。
const String kSuggestionInstruction = '（以下是一条写作指令，不属于对话内容）'
    '请暂时只扮演「用户」这一方：结合上面的对话与用户的人设，'
    '写出用户此刻最可能发出去的一句话。'
    '要求：口语自然、符合当前情境与关系，只输出这句话本身；'
    '不要角色名、不要引号、不要解释、不要加「建议」「回复」之类的前缀。';

/// 三条建议各自的语气/风格，避免生成出来的三条意思差不多。
///
/// 逐条追加到 [kSuggestionInstruction] 后面（见 [appendSuggestionInstruction]），
/// 让同一批建议里既有短促接话、也有情绪互动、还有推进剧情的说法。
const List<String> kSuggestionStyles = <String>[
  '风格 A（简短接话）：一句话直接接话，口语化，尽量不超过 15 个字，不要动作描写。',
  '风格 B（情绪互动）：带一点情绪或关心、玩笑、撒娇，体现和对方的关系，可以稍长一点。',
  '风格 C（推进剧情）：主动做点什么或提出具体行动、问题，把场景往前推进一步。',
];

/// 在对话 messages 末尾追加建议指令，产出一次建议请求的 messages。
///
/// [styleIndex] 用于让同一批的多条建议风格互不相同（取模到
/// [kSuggestionStyles]，默认 0 保持旧行为）。
List<PromptMessage> appendSuggestionInstruction(
  List<PromptMessage> messages, {
  int styleIndex = 0,
}) {
  final style =
      kSuggestionStyles[styleIndex % kSuggestionStyles.length];
  return [
    ...messages,
    PromptMessage(
      role: 'user',
      content: '$kSuggestionInstruction\n$style',
    ),
  ];
}

/// 清洗单条建议：去首尾空白、去前缀与包裹引号、把换行压成单行。
String normalizeSuggestion(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  // 常见前缀：「建议：」「回复：」「用户：」「用户回复：」
  text = text.replaceFirst(RegExp(r'^(建议|回复|用户回复|用户)\s*[:：]\s*'), '');
  // 整句被引号包住时去掉；只处理成对出现的首尾
  const pairs = <List<String>>[
    ['"', '"'],
    ["'", "'"],
    ['“', '”'],
    ['「', '」'],
    ['『', '』'],
  ];
  for (final p in pairs) {
    if (text.length > 2 && text.startsWith(p[0]) && text.endsWith(p[1])) {
      text = text.substring(p[0].length, text.length - p[1].length).trim();
      break;
    }
  }
  // 模型偶尔给多行或带空行：压成一行，便于 chip 单行展示
  text = text.replaceAll(RegExp(r'\s*\n+\s*'), ' ').replaceAll(RegExp(r'[ \t]+'), ' ');
  return text.trim();
}

/// 批量清洗建议：逐条 normalize → 丢弃空串 → 去重（完全相同或高度相似）。
List<String> normalizeSuggestions(Iterable<String> raw) {
  final out = <String>[];
  for (final item in raw) {
    final text = normalizeSuggestion(item);
    if (text.isEmpty) continue;
    if (out.any((kept) => _tooSimilar(kept, text))) continue;
    out.add(text);
  }
  return out;
}

/// 两条建议是否「差不多」：完全一致，或长度相近且字符二元组重合度 ≥ 0.7。
///
/// 太短（< 6 字符）时只看是否完全相同，避免把「嗯」「好呀」这类短句误杀。
bool _tooSimilar(String a, String b) {
  if (a == b) return true;
  if (a.length < 6 || b.length < 6) return false;
  final longer = a.length > b.length ? a.length : b.length;
  final shorter = a.length > b.length ? b.length : a.length;
  if (shorter / longer < 0.6) return false;
  final setA = _bigrams(a);
  final setB = _bigrams(b);
  if (setA.isEmpty || setB.isEmpty) return false;
  final inter = setA.intersection(setB).length;
  final union = setA.union(setB).length;
  return union > 0 && inter / union >= 0.7;
}

Set<String> _bigrams(String s) {
  final cleaned = s.replaceAll(RegExp(r'\s+'), '');
  if (cleaned.length < 2) return {cleaned};
  return {
    for (var i = 0; i < cleaned.length - 1; i++)
      cleaned.substring(i, i + 2),
  };
}
