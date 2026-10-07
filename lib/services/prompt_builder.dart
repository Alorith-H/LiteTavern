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
///   1. 世界书激活条目中 position=0 的（对话开头注入，按 insertion_order）
///   2. `你是 {角色名}。` + description + personality + scenario（非空才拼）
///   3. card.system_prompt（非空）
///   4. mes_example（非空，前面加 `示例对话：`）
///   5. 世界书激活条目中 position=2 的（角色设定后注入）
///   6. summaryText 非空时末尾追加 `【早期对话摘要】<text>`（v0.6.0）
/// 历史：first_mes 作为 assistant 开头，之后 user/assistant 交替；
/// 最多取最近 [historyLimit] 条历史（system 永远全量）。
/// position=1 的条目以 user 消息「[世界书] 内容」插到历史
/// 倒数 depth+1 条之前（depth=0 = 最新一条前）。
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

    // 1. 世界书激活（引擎内部已做宏替换，附带来源；按 position 分流）
    final activated = WorldInfoEngine.activate(
      books: worldBooks,
      messages: history,
      charName: charName,
      userName: userName,
    );
    final parts = _partitionActivated(activated);

    String macro(String s) =>
        applyMacros(s, charName: charName, userName: userName);

    final sb = StringBuffer();
    if (parts.front.isNotEmpty) {
      sb.writeln(parts.front.map((a) => a.content).join('\n\n'));
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

    // position=2：紧跟角色设定字段之后
    if (parts.after.isNotEmpty) {
      if (sb.isNotEmpty) sb.writeln();
      sb.writeln(parts.after.map((a) => a.content).join('\n\n'));
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
    final rendered = [
      for (final m in hist) PromptMessage(role: m.role, content: macro(m.content)),
    ];
    // position=1：以 user 消息形式按 depth 插入历史
    messages.addAll(_injectDepthEntries(rendered, parts.depth));

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

    // 1. 合并世界书激活（每条标来源；宏用当前发言者的名字替换 {{char}}；
    //    按 position 分流：0 在最前，2 紧跟成员名册后）
    final activated = WorldInfoEngine.activate(
      books: worldBooks,
      messages: history,
      charName: speaker,
      userName: userName,
    );
    final parts = _partitionActivated(activated);

    final sb = StringBuffer();
    void writeEntries(List<ActivatedEntry> list) {
      for (final a in list) {
        sb.writeln('【来自「${a.source}」】');
        sb.writeln(a.content);
        sb.writeln();
      }
    }

    writeEntries(parts.front);

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
    writeEntries(parts.after);

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
    final rendered = <PromptMessage>[];
    for (final m in hist) {
      if (m.role == 'user') {
        final content =
            macroFor('$userName: ${m.content}', defaultName);
        rendered.add(PromptMessage(role: 'user', content: content));
      } else {
        final name = nameOf(m);
        final content = macroFor('$name: ${m.content}', name);
        rendered.add(PromptMessage(role: 'assistant', content: content));
      }
    }
    // position=1：与单聊一致，按 depth 插入（不带名字前缀）
    messages.addAll(_injectDepthEntries(rendered, parts.depth));

    return PromptBuildResult(
      messages: messages,
      systemText: systemText,
      activated: activated,
    );
  }

  /// 激活条目按 position 分流（保持传入的 insertion_order 升序）：
  /// 1 → 历史深度注入；2 → 角色设定后；其余（0 及旧数据缺省）→ system 最前。
  static ({
    List<ActivatedEntry> front,
    List<ActivatedEntry> after,
    List<ActivatedEntry> depth,
  }) _partitionActivated(List<ActivatedEntry> activated) {
    final front = <ActivatedEntry>[];
    final after = <ActivatedEntry>[];
    final depth = <ActivatedEntry>[];
    for (final a in activated) {
      if (a.position == 1) {
        depth.add(a);
      } else if (a.position == 2) {
        after.add(a);
      } else {
        front.add(a);
      }
    }
    return (front: front, after: after, depth: depth);
  }

  /// position=1 条目：以 user 消息「[世界书] 内容」插到
  /// 历史倒数 depth+1 条之前（depth=0 = 最新一条前；
  /// depth 超出历史长度则插到最前）。多个同深度条目按
  /// insertion_order 依次插入，不打乱原历史相对顺序。
  static List<PromptMessage> _injectDepthEntries(
    List<PromptMessage> hist,
    List<ActivatedEntry> depthEntries,
  ) {
    if (depthEntries.isEmpty) return hist;
    // 目标下标基于插入前的原列表，统一在一趟重建中落位
    final at = <int, List<ActivatedEntry>>{};
    for (final e in depthEntries) {
      final idx =
          (hist.length - e.depth - 1).clamp(0, hist.length).toInt();
      at.putIfAbsent(idx, () => []).add(e);
    }
    final out = <PromptMessage>[];
    for (var i = 0; i <= hist.length; i++) {
      for (final e in at[i] ?? const <ActivatedEntry>[]) {
        out.add(PromptMessage(
          role: 'user',
          content: '[世界书] ${e.content}',
        ));
      }
      if (i < hist.length) out.add(hist[i]);
    }
    return out;
  }

  /// 截断到 [max] 字（超出加省略号）。
  static String _clip(String s, int max) =>
      s.length > max ? s.substring(0, max) : s;
}
