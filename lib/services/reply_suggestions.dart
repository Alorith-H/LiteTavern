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

/// 在对话 messages 末尾追加建议指令，产出一次建议请求的 messages。
List<PromptMessage> appendSuggestionInstruction(
  List<PromptMessage> messages,
) {
  return [
    ...messages,
    const PromptMessage(role: 'user', content: kSuggestionInstruction),
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

/// 批量清洗建议：逐条 normalize → 丢弃空串 → 按原文去重（保序）。
List<String> normalizeSuggestions(Iterable<String> raw) {
  final out = <String>[];
  for (final item in raw) {
    final text = normalizeSuggestion(item);
    if (text.isEmpty) continue;
    if (out.contains(text)) continue;
    out.add(text);
  }
  return out;
}
