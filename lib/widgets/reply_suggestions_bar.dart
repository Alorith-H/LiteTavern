import 'package:flutter/material.dart';

import 'common.dart';

/// 输入框上方的「建议回复」条（v0.12.1）。
///
/// 展示模型为「用户本人」生成的若干条可发送消息，点一下即发送，
/// 也可「换一批」重新请求。外观与聊天页的「快捷回复」chips 保持一致，
/// 但多一个 [Icons.auto_awesome] 小图标以示区分。
/// 组件本身不持有状态、不发请求、不做业务判断。
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

  /// true 时显示「正在生成建议…」的小行内 loading，chip 置灰禁用。
  final bool loading;

  /// 点某条建议 → 调用方发送该文本。
  final ValueChanged<String> onSend;

  /// 点「换一批」→ 调用方重新请求。
  final VoidCallback onRefresh;

  /// 单条 chip 的最大宽度：避免一条长文本把整行撑爆。
  static const double _maxChipWidth = 240;

  /// 整条高度（compact，一行）。
  static const double _barHeight = 40;

  @override
  Widget build(BuildContext context) {
    // 防御：没有建议且不在生成中时整条不占位（调用方通常已先判空）。
    if (suggestions.isEmpty && !loading) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: _barHeight,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < suggestions.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxChipWidth),
                child: ActionChip(
                  // 小图标区分「模型生成的建议」与手动的「快捷回复」
                  avatar: Icon(
                    Icons.auto_awesome,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  label: Text(
                    suggestions[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: AppType.caption),
                  ),
                  // 生成中置灰禁用
                  onPressed: loading ? null : () => onSend(suggestions[i]),
                ),
              ),
            ],
            const SizedBox(width: 4),
            // 生成中：按钮左侧 12x12 细 spinner，文案变「生成中…」并禁用
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
      ),
    );
  }
}
