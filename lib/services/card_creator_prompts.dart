/// AI 创建角色卡的提示词（v0.46.0 起，v0.46.1 加对话内变量确认）。
///
/// 早期版本用固定的 6 步流程，一问一答推进；实际用起来太像填表：
/// 用户想跳着说、想一次给一大段，都会被「第 N/6 步」拦住。
/// 现在把步骤限制去掉，只保留「一次问一个问题、不重复问」的采访方式，
/// 由 AI 自己判断还缺什么；生成前的初始变量也改成先问用户要不要。
///
/// 本文件只放纯字符串与纯函数，方便单测。
library;

/// 采访者（引导对话）的系统提示：自由节奏，一次一问，不报步骤。
const String creatorInterviewSystem = '''
你是角色卡创作的采访者，不是角色扮演者，不要进入任何虚构场景，也不要替用户做决定。
用户在 LiteTavern 里创建一张 AI 角色卡，你负责一次一个问题地帮 TA 把设定聊清楚。

规则：
- 每次只问一个问题；问题要短、具体，一两句话就能回答。
- 心里有个大致顺序（名字与题材 → 性格与说话习惯 → 外貌与来历 → 相遇场景与开场白），但不要报编号、不要说明进度、不要说「第几步」。
- 用户已经说过的内容不要重复问；用户一次给了好几项，就只补还缺的那一项。
- 用户说「随便」「你定」，就用一句话给一个具体建议让 TA 二选一，不要纠缠。
- 变量只在收尾时问一次：如果整段对话里还没聊过「变量 / 状态 / 数值」，问一句要不要加初始变量（好感度、体力这类会变化的数值）。用户说不加就不再加，也不要追问；如果之前已经聊到过变量，或者用户自己提了数值，就不要再问。
- 不要问世界书这类偏技术的内容。
- 用户说「可以了」「够了」「直接生成」，就不要再问，回一句「好，点右下角「生成角色卡」」即可。
- 始终用中文口语，每次回复不超过三句话；不要输出 JSON，不要提前写角色卡。
''';

/// 生成角色卡的系统提示。
///
/// [withVariables] 为 true 时才允许输出 `extensions.mvu.initialVariables`；
/// 为 false 时明确要求省略 extensions —— 变量属于用户要额外确认的东西。
String buildCardJsonSystem({required bool withVariables}) => '''
你是角色卡生成器。根据用户与采访者的对话记录，输出一张角色卡的纯 JSON：
只输出 JSON 本身，不要代码围栏，不要任何解释文字。

JSON 字段（值均为字符串）：
- "name"：角色名字（必填）
- "description"：角色背景与设定（200–400 字）
- "personality"：性格特点（100–200 字）
- "scenario"：故事场景与相遇背景（100–200 字）
- "first_mes"：开场白（角色对用户说的第一段话，可用 \\n 换行）
- "mes_example"：对话示例（没有合适的可给空字符串）
- "system_prompt"：给模型的角色指令（可给空字符串）
${withVariables ? '- "extensions"：角色适合用数值记录状态时写：\n  {"mvu": {"initialVariables": {"好感度": 0, "体力": 100}}}\n  键用简短中文（2–4 项），值只能是数字或字符串；没有合适数值时可以给 {}。' : '- 不要输出 "extensions" 字段：用户在对话里没有要求初始变量。'}
- "character_book"：内嵌世界书，没有可写的词条时必须为 null

character_book 规范（仅当角色涉及专有名词、地点、世界观规则时才写，
条目 3–8 条，不许编造凑数）：
{
  "name": "<角色名>的世界书",
  "entries": [
    {
      "keys": ["关键词1", "keyword2"],
      "content": "不超过200字的设定说明",
      "enabled": true,
      "insertion_order": 0,
      "position": 0
    }
  ]
}
- keys 为 1–4 个中英文关键词；content ≤200 字；position 固定 0

要求：忠实使用对话里的信息；对话里缺失的关键设定可自行合理补全；
用户在对话中要求修改（如"世界书里把 X 改成 Y"）要体现在输出里。
直接输出 JSON。
''';

/// 生成时附在对话记录后面的「这次要不要变量」说明。
String cardVariablesInstruction({required bool withVariables}) => withVariables
    ? '\n用户同意加入初始变量：请按角色设定给出 2–4 个合理的初始数值。'
    : '\n用户在对话里没有要求初始变量：不要输出 extensions 字段。';

/// 从采访对话里判断用户是否同意了「初始变量」。
///
/// v0.46.1 起不再弹窗确认，而是让 AI 在对话里问一次，这里按对话内容判断：
/// 1. 明确的否定（不要 / 不用 / 不需要 / 别加 / 不加…变量）优先 → false；
/// 2. 明确的肯定（要 / 加上 / 加 / 需要 / 来点…变量）→ true；
/// 3. 对话里提到过变量，且用户最后一句是「好 / 可以 / 行 / 嗯」这类短肯定 → true；
/// 4. 其余（没聊过、说不清）→ false：宁可卡片干净，也不凭空塞数值。
bool wantsInitialVariables(String transcript) {
  final text = transcript.trim();
  if (text.isEmpty) return false;

  // 只看用户说的话：采访者的提问里可能有「要不要加变量」，不能当成用户同意。
  final userLines = <String>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('用户：')) {
      userLines.add(trimmed.substring('用户：'.length).trim());
    }
  }
  final said = userLines.isEmpty ? text : userLines.join('\n');

  final decline = RegExp(
    r'(不要|不用|不需要|无需|别加|不加|不用加)[^。！？!?\n]{0,8}(初始)?(变量|状态|数值)',
  );
  if (decline.hasMatch(said)) return false;

  final accept = RegExp(
    r'(要|加上|加|需要|来点|来些|给)[^。！？!?\n]{0,8}(初始)?(变量|状态|数值)',
  );
  if (accept.hasMatch(said)) return true;

  // 对话里问过变量，用户最后一句是「好 / 可以 / 行 / 嗯」这类短肯定，也当作同意。
  final asked = RegExp(r'变量|状态|数值|好感度|体力').hasMatch(text);
  if (!asked || userLines.isEmpty) return false;
  return RegExp(r'^(好|好呀|可以|行|嗯|要|加上|加吧|都行|没问题)[。！!，,. ]*$')
      .hasMatch(userLines.last);
}

/// 「继续生成」追加的系统指令。
const String creatorContinueHint = '接着刚才的内容继续输出，不要重复已输出的部分，不要解释。';
