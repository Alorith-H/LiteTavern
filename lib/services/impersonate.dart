import 'prompt_builder.dart';

/// 让 AI 替你写一句（v0.16.0，对齐 SillyTavern 的 Impersonate）。
///
/// 把上下文原样发过去，只在末尾追加一条「请以用户口吻写一句」的指令，
/// 生成结果会填进输入框让用户自己改，不会自动发送。
const String kImpersonateInstruction =
    '（临时指令）请暂停扮演角色，改为以用户（{{user}}）的第一人称口吻，'
    '写出用户在这一刻最可能发出的一条消息：贴合当前场景与情绪，'
    '长度一到两句话，可以有动作或心理描写，但不要替我推进太多剧情。'
    '只输出这条消息本身：不要角色名前缀、不要引号、不要解释。';

/// 在上下文末尾追加替身指令（不修改入参）。
List<PromptMessage> withImpersonateInstruction(List<PromptMessage> messages) => [
      ...messages,
      const PromptMessage(role: 'user', content: kImpersonateInstruction),
    ];

/// 清洗替身结果：去掉前缀、引号、多余空行；空结果返回空串。
String normalizeImpersonation(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  // 去掉 ``` 代码块围栏
  text = text.replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '').replaceAll(RegExp(r'\s*```$'), '');
  // 去掉「我：」「用户：」「Me:」之类前缀
  text = text.replaceFirst(
    RegExp(r'^\s*(?:我|用户|user|me|User)\s*[：:]\s*', caseSensitive: false),
    '',
  );
  // 去掉整体包裹的引号
  text = text.replaceFirst(RegExp("^[「『\"“']+"), '');
  text = text.replaceFirst(RegExp("[」』\"”']+\$"), '');
  // 多段压成一段，避免一条消息太长
  text = text.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
  if (text.length > 500) text = text.substring(0, 500).trim();
  return text;
}
