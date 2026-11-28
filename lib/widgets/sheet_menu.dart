import 'package:flutter/material.dart';

import 'common.dart';

/// 底部菜单的统一零件（v0.39.0）。
///
/// 之前每个菜单各写一套 Column + ListTile，分组、图标、危险色都靠手工凑，
/// 项一多就难扫。这里统一三件事：
/// - [SheetMenuTitle]：菜单顶部标题 + 说明；
/// - [SheetMenuSection]：分组小标题（例如「这段聊天」「导入与导出」）；
/// - [SheetMenuItem]：带图标的条目，`danger` 走错误色，`enabled` 变灰不可点。
class SheetMenuTitle extends StatelessWidget {
  const SheetMenuTitle({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.35,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 菜单分组标题：小字 + 字距，给长菜单分段。
class SheetMenuSection extends StatelessWidget {
  const SheetMenuSection(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppType.meta,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 菜单条目：统一左侧图标、副标题两行截断、危险色与禁用态。
class SheetMenuItem extends StatelessWidget {
  const SheetMenuItem({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.danger = false,
    this.enabled = true,
    this.trailing,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool danger;
  final bool enabled;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = enabled && onTap != null;
    final color = !active
        ? scheme.onSurface.withValues(alpha: 0.38)
        : (danger ? scheme.error : scheme.onSurface);
    final iconColor = !active
        ? scheme.onSurface.withValues(alpha: 0.30)
        : (danger ? scheme.error : scheme.onSurfaceVariant);
    return ListTile(
      enabled: active,
      dense: false,
      minLeadingWidth: 20,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: icon == null ? null : Icon(icon, size: 20, color: iconColor),
      title: Text(
        title,
        style: TextStyle(fontSize: AppType.body, color: color),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.3,
                color: active
                    ? (danger
                        ? scheme.error.withValues(alpha: 0.85)
                        : scheme.onSurfaceVariant)
                    : scheme.onSurface.withValues(alpha: 0.30),
              ),
            ),
      trailing: trailing,
      onTap: active ? onTap : null,
    );
  }
}

/// 统一弹出底部菜单：限高 78% + 可滚动 + 拖拽手柄 + SafeArea。
Future<T?> showSheetMenu<T>({
  required BuildContext context,
  required List<Widget> children,
  double maxHeightFactor = 0.78,
  bool scrollable = true,
}) {
  assert(maxHeightFactor > 0 && maxHeightFactor <= 1);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * maxHeightFactor,
        ),
        child: scrollable
            ? SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
      ),
    ),
  );
}
