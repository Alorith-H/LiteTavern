// 提示词检视与缓存分析（v0.28.0）。
//
// 目的：把「最近一次实际发送的内容」拆成带 token 的段落，并和上一次发送逐段比对，
// 指出缓存能复用到第几段、从哪一段开始被打断（该段之后每轮都要重付），
// 再根据常见成因给出可操作的省钱建议。纯逻辑，不依赖 Flutter，便于单测。
import 'prompt_builder.dart';
import 'token_estimate.dart';

/// 段落相对上一次发送的变化。
enum PromptPartChange {
  /// 与上次一致（在缓存前缀内可复用）。
  same,

  /// 位置相同但内容变了。
  changed,

  /// 上次没有这一段（新增在末尾 / 中间插入）。
  added,

  /// 上一次有、这一次没有。
  removed,
}

/// 单个段落的检视结果。
class PromptPartAudit {
  final int index;
  final String role;
  final String label;
  final String text;
  final int tokens;
  final PromptPartChange change;

  /// 是否落在缓存可复用的前缀里（含第一个相同段之后连续相同的段）。
  final bool insideCachePrefix;

  const PromptPartAudit({
    required this.index,
    required this.role,
    required this.label,
    required this.text,
    required this.tokens,
    required this.change,
    required this.insideCachePrefix,
  });

  /// 正文前 40 字，用于列表预览。
  String get preview {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 40 ? flat : '${flat.substring(0, 40)}…';
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'role': role,
        'label': label,
        'tokens': tokens,
        'change': change.name,
        'insideCachePrefix': insideCachePrefix,
      };
}

/// 一次提示词检视的完整报告。
class PromptAuditReport {
  final List<PromptPartAudit> parts;

  /// 总 token（估算口径与上下文占用一致）。
  final int totalTokens;

  /// 缓存可复用前缀的 token。
  final int cacheableTokens;

  /// 从第一个变化段之后、原本可复用却要重付的 token（省钱空间）。
  final int repayingTokens;

  /// 第一个变化段的位置；-1 = 全部与上次一致。
  final int firstChangeIndex;

  /// 是否第一次发送（没有上一次可比）。
  final bool firstSend;

  /// 系统提示（第一段 system）的 token。
  final int systemTokens;

  /// 可操作建议，已按重要性排序。
  final List<String> suggestions;

  const PromptAuditReport({
    required this.parts,
    required this.totalTokens,
    required this.cacheableTokens,
    required this.repayingTokens,
    required this.firstChangeIndex,
    required this.firstSend,
    required this.systemTokens,
    required this.suggestions,
  });

  /// 缓存可复用比例（0~1）；第一次发送恒为 0。
  double get cacheHitRatio =>
      totalTokens <= 0 ? 0 : (cacheableTokens / totalTokens).clamp(0.0, 1.0);

  /// 第一个变化段的标签，没有则为空串。
  String get firstChangeLabel {
    final i = firstChangeIndex;
    if (i < 0 || i >= parts.length) return '';
    return parts[i].label;
  }

  /// 美元意义上「大约能省多少」的粗略估算：按整段重付的 token 计。
  String get summaryLine {
    if (firstSend) return '第一次发送：暂无缓存可复用';
    if (firstChangeIndex < 0) return '与上次完全一致：全部可复用（$cacheableTokens token）';
    return '缓存可复用 $cacheableTokens / $totalTokens token'
        '（${(cacheHitRatio * 100).round()}%）；从「$firstChangeLabel」起改动，'
        '其后约 $repayingTokens token 会重付';
  }
}

/// 提示词检视分析器。
class PromptAudit {
  PromptAudit._();

  /// 分析当前提示词，[previous] = 上一次实际发送的提示词（首次发送传 null）。
  static PromptAuditReport analyze({
    required List<PromptMessage> current,
    List<PromptMessage>? previous,
    int? contextWindow,
  }) {
    final parts = <PromptPartAudit>[];
    var total = 0;
    var systemTokens = 0;

    for (var i = 0; i < current.length; i++) {
      final msg = current[i];
      final tokens = estimateTokens(msg.content);
      total += tokens;
      if (i == 0 && msg.role == 'system') systemTokens = tokens;

      var change = PromptPartChange.same;
      if (previous == null) {
        change = PromptPartChange.added;
      } else if (i >= previous.length) {
        change = PromptPartChange.added;
      } else if (previous[i].content != msg.content ||
          previous[i].role != msg.role) {
        change = PromptPartChange.changed;
      }

      parts.add(PromptPartAudit(
        index: i,
        role: msg.role,
        label: _labelOf(msg, i, current.length),
        text: msg.content,
        tokens: tokens,
        change: change,
        insideCachePrefix: false,
      ));
    }

    // 缓存前缀 = 从头开始连续的 same 段（第一次发送没有前缀）
    final firstSend = previous == null;
    var prefixEnd = 0;
    if (!firstSend) {
      while (prefixEnd < parts.length &&
          parts[prefixEnd].change == PromptPartChange.same) {
        prefixEnd++;
      }
    }
    var cacheable = 0;
    for (var i = 0; i < prefixEnd; i++) {
      cacheable += parts[i].tokens;
    }
    final marked = <PromptPartAudit>[
      for (var i = 0; i < parts.length; i++)
        PromptPartAudit(
          index: parts[i].index,
          role: parts[i].role,
          label: parts[i].label,
          text: parts[i].text,
          tokens: parts[i].tokens,
          change: parts[i].change,
          insideCachePrefix: i < prefixEnd,
        ),
    ];

    final firstChangeIndex = firstSend || prefixEnd >= parts.length
        ? (firstSend ? 0 : -1)
        : prefixEnd;

    // 第一个变化点之后、原本可以复用的 token（粗略：变化点之后所有段的 token）
    var repaying = 0;
    if (!firstSend && firstChangeIndex >= 0) {
      for (var i = firstChangeIndex; i < parts.length; i++) {
        repaying += parts[i].tokens;
      }
    }

    final suggestions = _suggestions(
      parts: marked,
      firstChangeIndex: firstChangeIndex,
      firstSend: firstSend,
      cacheable: cacheable,
      total: total,
      systemTokens: systemTokens,
      contextWindow: contextWindow,
      previousCount: previous?.length ?? 0,
    );

    return PromptAuditReport(
      parts: marked,
      totalTokens: total,
      cacheableTokens: cacheable,
      repayingTokens: repaying,
      firstChangeIndex: firstChangeIndex,
      firstSend: firstSend,
      systemTokens: systemTokens,
      suggestions: suggestions,
    );
  }

  /// 推荐顺序（v0.28.0「省钱排序」）：稳定、少变的内容在前，每轮变动的在后。
  ///
  /// 返回的是「类别 → 建议位置」的说明列表，不做真正的重排（重排会改变模型看到
  /// 的语义，必须由用户自己决定是否调整）。
  static List<String> recommendedOrder(int totalTokens) => [
        '1. 系统提示（角色设定、世界书常驻条目）：最稳定，放最前',
        '2. 用户人设、作者注释（固定文本）：次稳定',
        '3. 早期对话摘要：变化少，但一改就作废后面全部缓存',
        '4. 历史对话：越靠后的越容易变，天然适合做断点',
        '5. 本轮新消息 + 深度注入（世界书 depth、聊天内作者注释）：最后放',
        if (totalTokens > 0) '当前发送约 $totalTokens token，可按上面的顺序检查有没有提前变动的内容',
      ];

  static List<String> _suggestions({
    required List<PromptPartAudit> parts,
    required int firstChangeIndex,
    required bool firstSend,
    required int cacheable,
    required int total,
    required int systemTokens,
    required int? contextWindow,
    required int previousCount,
  }) {
    final out = <String>[];
    if (parts.isEmpty) {
      return const ['还没有可检视的提示词：先发一条消息'];
    }
    if (firstSend) {
      out.add('这是第一次发送，还没有可复用的缓存；从第二条开始这里会显示命中情况。');
    } else if (firstChangeIndex < 0) {
      out.add('这次发送与上次完全一致，全部 $total token 都能命中缓存。');
    } else {
      final ratio = total <= 0 ? 0.0 : cacheable / total;
      if (firstChangeIndex == 0) {
        out.add('第一段（系统提示）就变了，本次缓存命中为 0：整段都要重付。');
      } else if (ratio < 0.5) {
        out.add('只有前 ${(ratio * 100).round()}% 能复用，'
            '从「${parts[firstChangeIndex].label}」开始变动。');
      } else {
        out.add('前 ${(ratio * 100).round()}% 可复用，'
            '变动从「${parts[firstChangeIndex].label}」开始。');
      }
    }

    // 系统提示里出现易变内容（时间/日期/摘要），会毁掉整段缓存
    if (parts.isNotEmpty && parts.first.role == 'system') {
      final sys = parts.first.text;
      final hasTimeMacro = RegExp(r'\{\{(time|date|weekday|isotime)\}\}').hasMatch(sys);
      final hasClock = RegExp(r'\b\d{1,2}:\d{2}\b').hasMatch(sys) &&
          RegExp(r'(现在|当前时间|time is)').hasMatch(sys);
      if (hasTimeMacro || hasClock) {
        out.add('系统提示里含时间/日期，每轮都会变 → 建议删掉这些宏，'
            '或改成「需要时间就问一句」，可让系统提示整段长期复用。');
      }
      if (sys.contains('【早期对话摘要】') && firstSend == false) {
        out.add('摘要写在系统提示里，摘要一更新就会让系统提示连同后面的历史全部失效；'
            '如果摘要更新频繁，可以考虑放在历史之前、单独一段。');
      }
    }

    // 世界书深度注入 / 聊天内作者注释：插在历史中间会让后面的内容作废
    final injected = parts
        .where((p) =>
            p.index > 0 &&
            p.index < parts.length - 1 &&
            p.role == 'system' &&
            p.change != PromptPartChange.same)
        .toList();
    if (injected.isNotEmpty) {
      final t = injected.fold<int>(0, (s, p) => s + p.tokens);
      out.add('这次有 ${injected.length} 段系统内容插在中间（合计约 $t token），'
          '把「${injected.first.label}」挪到末尾能少作废一段缓存。');
    }

    // 段落数变化提醒
    if (!firstSend && previousCount > 0 && parts.length != previousCount) {
      out.add('段落数从 $previousCount 变成 ${parts.length}：'
          '历史被裁掉或新增了注入段，缓存前缀会自然缩短，属正常波动。');
    }

    if (contextWindow != null && contextWindow > 0 && total > contextWindow * 0.9) {
      out.add('已用掉窗口的 ${(total / contextWindow * 100).round()}%，'
          '再多聊几轮就会触发自动摘要；摘要本身也会消耗 token。');
    }

    if (out.isEmpty) {
      out.add('没有发现明显的缓存浪费点。');
    }
    return out;
  }

  static String _labelOf(PromptMessage msg, int index, int total) {
    if (index == 0 && msg.role == 'system') return '系统提示';
    if (msg.role == 'system') return '系统注入 #$index';
    if (index == total - 1 && msg.role == 'user') return '本轮新消息';
    if (msg.role == 'assistant') return '历史 · 角色回复 #$index';
    if (msg.role == 'user') return '历史 · 你 #$index';
    return '${msg.role} #$index';
  }
}
