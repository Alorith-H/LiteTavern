import '../models/chat_message.dart';
import '../models/character_card.dart';
import '../models/world_info.dart';
import 'macros.dart';
import 'world_info_engine.dart';

/// 一条待发送给 API 的消息。
class PromptMessage {
  final String role;
  final String content;

  const PromptMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// 组装 messages 数组。
///
/// system（单条，按顺序拼接）：
///   1. 世界书激活条目（按 insertion_order）
///   2. `你是 {角色名}。` + description + personality + scenario（非空才拼）
///   3. card.system_prompt（非空）
///   4. mes_example（非空，前面加 `示例对话：`）
/// 历史：first_mes 作为 assistant 开头，之后 user/assistant 交替；
/// 最多取最近 40 条历史（system 永远全量）。
class PromptBuilder {
  static const int maxHistory = 40;

  static List<PromptMessage> build({
    required CharacterCard card,
    required List<ChatMessage> history,
    required List<WorldInfo> worldBooks,
    required String userName,
  }) {
    final charName = card.name;

    // 1. 世界书激活（引擎内部已做宏替换）
    final wbTexts = WorldInfoEngine.activate(
      books: worldBooks,
      messages: history,
      charName: charName,
      userName: userName,
    );

    String macro(String s) =>
        applyMacros(s, charName: charName, userName: userName);

    final sb = StringBuffer();
    if (wbTexts.isNotEmpty) {
      sb.writeln(wbTexts.join('\n\n'));
      sb.writeln();
    }

    void appendField(String value, {String prefix = ''}) {
      final v = macro(value).trim();
      if (v.isEmpty) return;
      sb.writeln(prefix.isEmpty ? v : '$prefix$v');
    }

    sb.writeln('你是 $charName。');
    appendField(card.description);
    appendField(card.personality);
    appendField(card.scenario);
    appendField(card.systemPrompt);

    final example = macro(card.mesExample).trim();
    if (example.isNotEmpty) {
      sb.write('示例对话：\n$example');
    }

    final messages = <PromptMessage>[
      PromptMessage(role: 'system', content: sb.toString()),
    ];

    // 2. first_mes 作为 assistant 开头
    //（若对话记录已以 assistant 开头——首次开场白已写入——则不重复 prepend）
    final firstMes = macro(card.firstMes).trim();
    final needsFirstMes =
        firstMes.isNotEmpty && (history.isEmpty || history.first.role == 'user');
    if (needsFirstMes) {
      messages.add(PromptMessage(role: 'assistant', content: firstMes));
    }

    // 3. 历史：宏替换后渲染，跳过空内容（如生成中的占位消息），最多最近 40 条
    var hist = history.where((m) => m.content.trim().isNotEmpty).toList();
    if (hist.length > maxHistory) {
      hist = hist.sublist(hist.length - maxHistory);
    }
    for (final m in hist) {
      messages.add(PromptMessage(role: m.role, content: macro(m.content)));
    }

    return messages;
  }
}
