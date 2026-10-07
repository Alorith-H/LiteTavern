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
///   5. summaryText 非空时末尾追加 `【早期对话摘要】<text>`（v0.6.0）
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
    String? summaryText,
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

    final summary = summaryText?.trim() ?? '';
    if (summary.isNotEmpty) {
      if (sb.isNotEmpty) sb.writeln();
      sb.writeln('【早期对话摘要】$summary');
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

  /// 群聊组装（v0.6.0）。
  ///
  /// system（按顺序）：
  ///   1. 合并世界书激活条目（各成员 enabled 挂载 + 各自卡内嵌，调用方已去重；每条标来源）
  ///   2. `以下角色将参加对话：` + 每成员 `【名字】` + description/personality（各截 300 字）
  ///   3. 对话规则：只扮演 [speakerName]（当前要生成的成员）、消息以 `名字: ` 开头
  ///   4. summaryText 非空时末尾追加 `【早期对话摘要】`
  /// 历史渲染为 `名字: 内容`（user 用其称呼）；宏 {{char}}→该条发言者名字，{{user}}→用户名字。
  static PromptBuildResult buildGroup({
    required List<CharacterCard> members,
    required List<ChatMessage> history,
    required List<WorldInfo> worldBooks,
    required String userName,
    String? speakerName,
    String? summaryText,
    int? historyLimit,
  }) {
    var limit = historyLimit ??
        (AppSettings.initialized ? AppSettings.contextHistoryLimit : maxHistory);
    limit = limit.clamp(10, 100).toInt();
    if (members.isEmpty) {
      throw ArgumentError('群聊至少需要一名成员');
    }
    // 当前要扮演的角色（统计面板等未指定时回退第一位）
    final speaker = speakerName?.trim().isNotEmpty == true
        ? speakerName!.trim()
        : members.first.name;
    final defaultName = members.first.name;

    String nameOf(ChatMessage m) =>
        (m.role == 'assistant' && (m.senderName ?? '').trim().isNotEmpty)
            ? m.senderName!.trim()
            : defaultName;

    String macroFor(String text, String charName) =>
        applyMacros(text, charName: charName, userName: userName);

    // 1. 合并世界书激活（每条标来源；宏用当前发言者的名字替换 {{char}}）
    final activated = WorldInfoEngine.activate(
      books: worldBooks,
      messages: history,
      charName: speaker,
      userName: userName,
    );

    final sb = StringBuffer();
    for (final a in activated) {
      sb.writeln('【来自「${a.source}」】');
      sb.writeln(a.content);
      sb.writeln();
    }

    // 2. 参加对话的角色
    sb.writeln('以下角色将参加对话：');
    for (final m in members) {
      final desc = _clip(m.description.trim(), 300);
      final pers = _clip(m.personality.trim(), 300);
      sb.write('【${m.name}】');
      sb.write(desc);
      if (desc.isNotEmpty && pers.isNotEmpty) sb.writeln();
      sb.write(pers);
      sb.writeln();
    }
    sb.writeln();

    // 3. 对话规则（扮演当前发言者）
    sb.write(
      '对话规则：你只扮演【$speaker】并以其口吻发言，'
      '每条消息以「名字: 」开头。其他角色由系统扮演，不要替他人发言。',
    );

    // 4. 早期摘要（若有）
    final summary = summaryText?.trim() ?? '';
    if (summary.isNotEmpty) {
      sb.writeln();
      sb.writeln('【早期对话摘要】$summary');
    }

    final systemText = sb.toString();
    final messages = <PromptMessage>[
      PromptMessage(role: 'system', content: systemText),
    ];

    // 历史：`名字: 内容`，跳过空占位，最多最近 limit 条
    var hist = history.where((m) => m.content.trim().isNotEmpty).toList();
    if (hist.length > limit) {
      hist = hist.sublist(hist.length - limit);
    }
    for (final m in hist) {
      if (m.role == 'user') {
        final content =
            macroFor('$userName: ${m.content}', defaultName);
        messages.add(PromptMessage(role: 'user', content: content));
      } else {
        final name = nameOf(m);
        final content = macroFor('$name: ${m.content}', name);
        messages.add(PromptMessage(role: 'assistant', content: content));
      }
    }

    return PromptBuildResult(
      messages: messages,
      systemText: systemText,
      activated: activated,
    );
  }

  /// 截断到 [max] 字（超出加省略号）。
  static String _clip(String s, int max) =>
      s.length > max ? s.substring(0, max) : s;
}
