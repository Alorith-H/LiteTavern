import 'package:flutter/material.dart';

/// 编辑风分段切换（v0.9.0）：胶囊描边容器 + 自带滑动指示的高亮胶囊。
///
/// 胶囊形高亮背景在分段间平滑滑动（AnimatedPositioned，280ms easeOutCubic），
/// 文字颜色/字重同步渐变（AnimatedDefaultTextStyle）——不允许瞬时跳变。
/// 点击区域覆盖每一段（点哪段选哪段）；选中 = accent 淡填充 + accent 文字，
/// 未选中 = 次要色文字；无阴影。
class SegmentedToggle extends StatelessWidget {
  final int value;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  /// 段间距（与容器内边距一起决定指示器滑动轨迹）
  final double gap;

  const SegmentedToggle({
    super.key,
    required this.value,
    required this.labels,
    required this.onChanged,
    this.gap = 6,
  });

  /// 指示器的测试/调试键（滑动中的胶囊背景层）。
  static const Key indicatorKey = Key('segment_indicator');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outline),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final n = labels.length;
          // Row 布局：n 段 Expanded + (n-1) 个 gap，与指示器轨迹同一套算术
          final segW = (constraints.maxWidth - gap * (n - 1)) / n;
          return Stack(
            children: [
              // 滑动的胶囊高亮：点左点右都触发位移动画（280ms easeOutCubic）
              AnimatedPositioned(
                key: indicatorKey,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                left: value * (segW + gap),
                width: segW,
                top: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(17),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < n; i++) ...[
                    if (i > 0) SizedBox(width: gap),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (value != i) onChanged(i);
                        },
                        child: SizedBox(
                          height: 34,
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 280),
                              curve: Curves.easeOutCubic,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: value == i
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: value == i
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                              child: Text(labels[i]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
