import 'package:flutter/material.dart';

import '../services/whats_new.dart';
import '../widgets/common.dart';

/// 更新说明弹窗：更新后第一次启动，以及「设置 → 帮助与关于 → 更新说明」。
Future<void> showWhatsNewDialog(
  BuildContext context, {
  required WhatsNewEntry entry,
  bool markSeen = true,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final s = Theme.of(ctx).colorScheme;
      return AlertDialog(
        icon: Icon(Icons.auto_awesome_outlined, color: s.primary),
        title: Text(entry.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '版本 ${entry.version}',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: s.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              for (final bullet in entry.bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 6, right: 8),
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: s.primary.withValues(alpha: 0.7),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          bullet,
                          style: const TextStyle(
                            fontSize: AppType.body,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                '以后想再看，可以去 设置 → 帮助与关于 → 更新说明。',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: s.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(markSeen ? '知道了' : '关闭'),
          ),
        ],
      );
    },
  );
  if (markSeen) await markWhatsNewSeen(entry.version);
}

/// 启动时调用：有没看过的新版本就弹一次。
Future<void> maybeShowWhatsNew(BuildContext context) async {
  final entry = pendingWhatsNew();
  if (entry == null || !context.mounted) return;
  await showWhatsNewDialog(context, entry: entry);
}
