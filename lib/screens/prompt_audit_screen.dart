import 'package:flutter/material.dart';

import '../services/prompt_audit.dart';
import '../services/prompt_builder.dart';
import '../widgets/common.dart';

/// 提示词检视（v0.28.0）：逐段 token、缓存断点、省钱建议。
///
/// 传入「这次」和「上次」实际发送的提示词；首次发送时 [previous] 传 null。
class PromptAuditScreen extends StatelessWidget {
  final List<PromptMessage> current;
  final List<PromptMessage>? previous;
  final int? contextWindow;

  const PromptAuditScreen({
    super.key,
    required this.current,
    this.previous,
    this.contextWindow,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final report = PromptAudit.analyze(
      current: current,
      previous: previous,
      contextWindow: contextWindow,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('提示词检视'),
        actions: [
          IconButton(
            tooltip: '省钱排序建议',
            icon: const Icon(Icons.savings_outlined),
            onPressed: () => _showOrderSheet(context, report),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _SummaryCard(report: report, scheme: scheme),
          const SizedBox(height: 12),
          if (report.suggestions.isNotEmpty) ...[
            const SectionHeader('可以省的地方'),
            for (final line in report.suggestions)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.tips_and_updates_outlined,
                      size: 16,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        line,
                        style: TextStyle(
                          fontSize: AppType.caption,
                          height: 1.45,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
          const SectionHeader('逐段明细'),
          for (final part in report.parts) _PartTile(part: part, scheme: scheme),
        ],
      ),
    );
  }

  void _showOrderSheet(BuildContext context, PromptAuditReport report) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.72,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: [
                const Text(
                  '省钱排序建议',
                  style: TextStyle(
                    fontSize: AppType.section,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '按「越稳定越靠前、越常变越靠后」排，模型供应商的前缀缓存才能命中。',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                for (final line in PromptAudit.recommendedOrder(
                  report.totalTokens,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      line,
                      style: const TextStyle(
                        fontSize: AppType.body,
                        height: 1.45,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  '这条建议只做提示，不会自动改你的设定：'
                  '作者注释/世界书的插入位置可在「作者注释」「世界书绑定」里手动调整。',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.report, required this.scheme});

  final PromptAuditReport report;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final ratio = (report.cacheHitRatio * 100).round();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '共 ${report.parts.length} 段 · ${report.totalTokens} token',
            style: const TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: report.firstSend ? 0 : report.cacheHitRatio,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            report.summaryLine,
            style: TextStyle(
              fontSize: AppType.caption,
              height: 1.45,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (!report.firstSend) ...[
            const SizedBox(height: 4),
            Text(
              '缓存可复用 $ratio%',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PartTile extends StatelessWidget {
  const _PartTile({required this.part, required this.scheme});

  final PromptPartAudit part;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (part.change) {
      PromptPartChange.same => ('未变', scheme.primary),
      PromptPartChange.changed => ('已变', scheme.error),
      PromptPartChange.added => ('新增', scheme.tertiary),
      PromptPartChange.removed => ('移除', scheme.onSurfaceVariant),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(
          children: [
            Expanded(
              child: Text(
                part.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppType.body,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (part.insideCachePrefix)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.bolt,
                  size: 14,
                  color: scheme.primary.withValues(alpha: 0.8),
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${part.tokens}',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        subtitle: Text(
          part.preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.caption,
            color: scheme.onSurfaceVariant,
          ),
        ),
        children: [
          Container(
            width: double.maxFinite,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              part.text,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
