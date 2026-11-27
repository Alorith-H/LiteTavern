import 'prompt_builder.dart';
import 'st_preset.dart';

/// ST 兼容模式：把导入预设里「启用」的提示词变成实际的注入计划（v0.31.0）。
///
/// 规则（尽量贴近 SillyTavern，但保持「叠加」而不是「替换」）：
/// * `marker` 条目只是位置占位，跳过；
/// * 没有正文的跳过；
/// * `injection_position == 1` → 按 `injection_depth` 注入到历史里
///   （0 = 最后一条之后，n = 倒数第 n 条之前），角色用条目自己的 role；
/// * 其余按顺序成为 system 开头的文本块（role 为 system）或历史前的消息
///   （role 为 user/assistant），保持 ST 里的先后顺序。
///
/// 明确不做：`system_prompt` 覆盖我们自己的角色设定、`forbid_overrides`、
/// `squash_system_messages`、`continue_prefill` —— 这些属于完整 ST 提示词引擎，
/// 本轮只保证「ST 里启用的内容会按顺序出现在请求里」。
class StInjectionPlan {
  /// 顺序提示词里 role = system 的部分，已按顺序拼好；无内容时为空串。
  final String systemPrefix;

  /// 顺序提示词里 role 为 user / assistant 的部分，按顺序放在历史之前。
  final List<PromptMessage> preHistory;

  /// 按深度注入到历史里的条目。
  final List<DepthInjection> depthInjections;

  /// 本次实际注入的条目数（不含 marker 与空内容）。
  final int injectedCount;

  const StInjectionPlan({
    this.systemPrefix = '',
    this.preHistory = const [],
    this.depthInjections = const [],
    this.injectedCount = 0,
  });

  static const StInjectionPlan empty = StInjectionPlan();

  bool get isEmpty =>
      systemPrefix.trim().isEmpty &&
      preHistory.isEmpty &&
      depthInjections.isEmpty;

  /// 一行摘要，给界面与「查看发送内容」用。
  String get summaryLine {
    final parts = <String>[];
    if (systemPrefix.trim().isNotEmpty) parts.add('system 开头 ${systemPrefix.length} 字');
    if (preHistory.isNotEmpty) parts.add('历史前 ${preHistory.length} 条');
    if (depthInjections.isNotEmpty) {
      parts.add('按深度注入 ${depthInjections.length} 条');
    }
    if (parts.isEmpty) return '没有可注入的内容';
    return '注入 $injectedCount 条：${parts.join(' · ')}';
  }

  static StInjectionPlan fromSnapshot(StPresetSnapshot? snapshot) {
    if (snapshot == null) return empty;

    final systemBlocks = <String>[];
    final preHistory = <PromptMessage>[];
    final depth = <DepthInjection>[];
    var injected = 0;

    for (final item in snapshot.prompts) {
      if (!item.enabled || item.isMarker) continue;
      final content = item.content.trim();
      if (content.isEmpty) continue;
      injected++;

      if (item.injectsInChat) {
        depth.add(
          DepthInjection(
            message: PromptMessage(
              role: _normalizeRole(item.role),
              content: content,
            ),
            depth: item.injectionDepth ?? 0,
          ),
        );
        continue;
      }

      if (item.role == 'system') {
        systemBlocks.add(content);
      } else {
        preHistory.add(
          PromptMessage(role: _normalizeRole(item.role), content: content),
        );
      }
    }

    return StInjectionPlan(
      systemPrefix: systemBlocks.join('\n\n'),
      preHistory: List.unmodifiable(preHistory),
      depthInjections: List.unmodifiable(depth),
      injectedCount: injected,
    );
  }

  static String _normalizeRole(String role) =>
      const {'system', 'user', 'assistant'}.contains(role) ? role : 'system';
}


