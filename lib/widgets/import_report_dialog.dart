import 'package:flutter/material.dart';

import '../services/import_report.dart';
import 'common.dart';

/// 导入体检报告弹窗（v0.32.0）。
///
/// [report] 为空或没有提醒时不打扰用户（调用方可以先判断 `hasWarnings`）。
Future<void> showImportReportDialog(
  BuildContext context,
  ImportReport report, {
  String title = '导入体检',
  String? subtitle,
}) {
  final scheme = Theme.of(context).colorScheme;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(
            report.hasWarnings
                ? Icons.health_and_safety_outlined
                : Icons.verified_outlined,
            size: 20,
            color: report.hasWarnings ? scheme.tertiary : scheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 17))),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.5,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _fitBadge(scheme, report.fit),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      report.summary,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: AppType.meta,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              for (final f in report.findings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        f.isWarning
                            ? Icons.info_outline
                            : Icons.check_circle_outline,
                        size: 16,
                        color: f.isWarning
                            ? scheme.tertiary
                            : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              f.title,
                              style: const TextStyle(
                                fontSize: AppType.body,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              f.detail,
                              style: TextStyle(
                                fontSize: AppType.caption,
                                height: 1.45,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

Widget _fitBadge(ColorScheme scheme, ImportFit fit) {
  final color = switch (fit) {
    ImportFit.usable => scheme.primary,
    ImportFit.partial => scheme.tertiary,
    ImportFit.preserveOnly => scheme.error,
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      fit.label,
      style: TextStyle(
        fontSize: AppType.meta,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    ),
  );
}
