// 上下文占用明细 + 满压缩判断（v0.8.0）。纯逻辑，可单测；
// 占用数据实时计算、不持久化。
import 'dart:math';

import 'prompt_builder.dart';
import 'token_estimate.dart';

/// 触发自动压缩的预算线：估算 > 窗口 × 90%。
const double kContextBudgetRatio = 0.9;

/// 是否超预算（window <= 0 = 关闭占用与压缩，恒不触发）。
bool overContextBudget(int tokens, int window) =>
    window > 0 && tokens > window * kContextBudgetRatio;

/// 占用百分比（整数）；窗口 <= 0 时返回 0。
int contextPercent(int tokens, int window) {
  if (window <= 0) return 0;
  return ((tokens / window) * 100).round().clamp(0, 999999).toInt();
}

/// 压缩第一步：历史条数减半，下限 10 条。
int halveHistoryLimit(int current) => max(10, current ~/ 2);

/// 上下文占用明细。
///
/// 由三次 prompt 组装得到，四个分量之和恒等于 total（= 完整组装估算）：
/// - [systemTokens] 系统提示（裸组装的 system，直接计量）
/// - [historyTokens] 历史（裸组装 system 之后的整段，与 system 严格对分，
///   system 与历史之间的分隔换行归历史）
/// - [worldBookTokens] 世界书（总量减去其余三分量的余量：吸收世界书注入
///   与逐段取整的舍入差，保证严格加和不漂移）
/// - [summaryTokens] 摘要（full 相对 withWb 的新增段直接计量，含前导换行；
///   以两次组装的增量封顶，防止逐段 ceil 累积虚高）
class ContextBreakdown {
  final int systemTokens;
  final int worldBookTokens;
  final int summaryTokens;
  final int historyTokens;

  /// 裸组装的历史消息条数（不含 system；不含世界书深度注入的附加条）
  final int historyCount;

  const ContextBreakdown({
    required this.systemTokens,
    required this.worldBookTokens,
    required this.summaryTokens,
    required this.historyTokens,
    required this.historyCount,
  });

  int get total => systemTokens + worldBookTokens + summaryTokens + historyTokens;

  /// [bare] 无世界书、无摘要；[withWb] 有世界书、无摘要；[full] 完整组装。
  ///
  /// 归账口径（展示与压缩阈值共用同一 total）：
  /// system+history 严格对分裸组装；summary 按新增段直接计量并封顶；
  /// worldBook 取余量 —— 代数上 `total ≡ 完整组装估算`，恒等成立。
  factory ContextBreakdown.of({
    required PromptBuildResult bare,
    required PromptBuildResult withWb,
    required PromptBuildResult full,
  }) {
    final bareTotal = _joinTokens(bare);
    final fullTotal = _joinTokens(full);
    final system = bare.messages.isEmpty
        ? 0
        : estimateTokens(bare.messages.first.content);
    final history = max(0, bareTotal - system);
    // 组装增量（full ⊇ bare 由单调性保证，max 仅防御）
    final growth = max(0, fullTotal - bareTotal);
    final summary =
        min(estimateTokens(_addedText(withWb, full)), growth);
    final worldBook = growth - summary;
    return ContextBreakdown(
      systemTokens: system,
      historyTokens: history,
      worldBookTokens: worldBook,
      summaryTokens: summary,
      historyCount: max(0, bare.messages.length - 1),
    );
  }

  /// [next] 相对 [base] 新增的文本段（含归属的换行分隔符）。
  ///
  /// 覆盖两种形态：真实组装里摘要块追加在 system 文本末尾
  /// （system 是前缀扩展）；合成/异常形态里新增的是独立消息
  /// （join 时消息前带 `\n`，分隔符一并归到新增段）。
  static String _addedText(PromptBuildResult base, PromptBuildResult next) {
    final buf = StringBuffer();
    if (base.messages.isNotEmpty && next.messages.isNotEmpty) {
      final b = base.messages.first.content;
      final n = next.messages.first.content;
      if (n.startsWith(b)) buf.write(n.substring(b.length));
    }
    for (var i = base.messages.length; i < next.messages.length; i++) {
      buf
        ..write('\n')
        ..write(next.messages[i].content);
    }
    return buf.toString();
  }

  static int _joinTokens(PromptBuildResult r) =>
      estimateTokens(r.messages.map((m) => m.content).join('\n'));
}
