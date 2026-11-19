import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'common.dart';

/// 输入框上方的「建议回复」列表（v0.13.0 改为纵向、完整展示）。
///
/// 展示模型为「用户本人」生成的若干条可发送消息：每条占整行、正文不截断
/// （最多显示到 [maxHeight]，超出可滚动），点一下即发送；顶部右侧「换一批」
/// 重新请求。组件本身不持有状态、不发请求、不做业务判断。
class ReplySuggestionsBar extends StatelessWidget {
  const ReplySuggestionsBar({
    super.key,
    required this.suggestions,
    required this.loading,
    required this.onSend,
    required this.onRefresh,
  });

  /// 建议文本（通常 3 条，已 trim、非空；调用方保证非空才渲染本组件）。
  final List<String> suggestions;

  /// true 时显示「生成中…」并禁用所有建议与换一批。
  final bool loading;

  /// 点某条建议 → 调用方发送该文本。
  final ValueChanged<String> onSend;

  /// 点「换一批」→ 调用方重新请求。
  final VoidCallback onRefresh;

  /// 列表最多占多高（超出内部滚动，避免长建议把输入区挤没）。
  static const double maxHeight = 240;

  @override
  Widget build(BuildContext context) {
    // 防御：没有建议且不在生成中时整条不占位（调用方通常已先判空）。
    if (suggestions.isEmpty && !loading) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final limit = math.min(maxHeight, screenHeight * 0.32);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                '建议回复',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (loading) ...[
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              TextButton(
                onPressed: loading ? null : onRefresh,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  loading ? '生成中…' : '换一批',
                  style: const TextStyle(fontSize: AppType.caption),
                ),
              ),
            ],
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: limit),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < suggestions.length; i++)
                    _SuggestionRow(
                      text: suggestions[i],
                      enabled: !loading,
                      showDivider: i > 0,
                      onTap: () => onSend(suggestions[i]),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.text,
    required this.enabled,
    required this.showDivider,
    required this.onTap,
  });

  final String text;
  final bool enabled;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showDivider)
              Divider(height: 9, thickness: 1, color: scheme.outlineVariant),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Icon(
                    Icons.auto_awesome,
                    size: 13,
                    color: enabled ? scheme.primary : scheme.outline,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    // 纵向整行展示：不设 maxLines，正文完整可见
                    style: TextStyle(
                      fontSize: AppType.body,
                      color: enabled ? scheme.onSurface : scheme.outline,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
