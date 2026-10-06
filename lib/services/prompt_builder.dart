import '../models/chat_message.dart';
import '../models/character_card.dart';
import '../models/world_info.dart';
import 'macros.dart';
import 'storage.dart';
import 'world_info_engine.dart';

/// 一条待发送给 API 的消息。
class PromptMessage {
  final String role;
  final String content;

  const PromptMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// PromptBuilder 的组装结果。
class PromptBuildResult {
  /// 发送给 API 的完整 messages（第一条是 system）
  final List<PromptMessage> messages;

  /// system 的完整文本（即 messages.first.content），供"查看注入内容"展示
  final String systemText;

  /// 本次激活的世界词条目（带来源标注），供统计/展示
  final List<ActivatedEntry> activated;

  const PromptBuildResult({
    required this.messages,
    required this.systemText,
    required this.activated,
  });
}

/// 组装 messages 数组。
///
/// system（单条，按顺序拼接）：
///   1. 世界书激活条目（按 insertion_order）
///   2. `你是 {角色名}。` + description + personality + scenario（非空才拼）
///   3. card.system_prompt（非空）
///   4. mes_example（非空，前面加 `示例对话：`）
/// 历史：first_mes 作为 assistant 开头，之后 user/assistant 交替；
/// 最多取最近 [historyLimit] 条历史（system 永远全量）。
class PromptBuilder {
  /// 兜底默认值（正常走 AppSettings.contextHistoryLimit）
  static const int maxHistory = 40;

  static PromptBuildResult build({
    required CharacterCard card,
    required List<ChatMessage> history,
    required List<WorldInfo> worldBooks,
    required String userName,
    int? historyLimit,
  }) {
    // 上下文保留条数来自设置；SharedPreferences 未初始化（如单元测试）时回退默认 40
    var limit = historyLimit ??
        (AppSettings.initialized ? AppSettings.contextHistoryLimit : maxHistory);
    limit = limit.clamp(10, 100).toInt();
    final charName = card.name;

    // 1. 世界书激活（引擎内部已做宏替换，附带来源）
    final activated = WorldInfoEngine.activate(
      books: worldBooks,
      messages: history,
      charName: charName,
      userName: userName,
    );
    final wbTexts = activated.map((a) => a.content).toList();

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

    final systemText = sb.toString();
    final messages = <PromptMessage>[
      PromptMessage(role: 'system', content: systemText),
    ];

    // 2. first_mes 作为 assistant 开头
    //（若对话记录已以 assistant 开头——首次开场白已写入——则不重复 prepend）
    final firstMes = macro(card.firstMes).trim();
    final needsFirstMes =
        firstMes.isNotEmpty && (history.isEmpty || history.first.role == 'user');
    if (needsFirstMes) {
      messages.add(PromptMessage(role: 'assistant', content: firstMes));
    }

    // 3. 历史：宏替换后渲染，跳过空内容（如生成中的占位消息），最多最近 limit 条
    var hist = history.where((m) => m.content.trim().isNotEmpty).toList();
    if (hist.length > limit) {
      hist = hist.sublist(hist.length - limit);
    }
    for (final m in hist) {
      messages.add(PromptMessage(role: m.role, content: macro(m.content)));
    }

    return PromptBuildResult(
      messages: messages,
      systemText: systemText,
      activated: activated,
    );
  }
}
