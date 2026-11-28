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

/// 二级菜单的一组：一级只显示组名与一句概括，点开才看组里的条目（v0.40.0）。
class SheetMenuGroup {
  const SheetMenuGroup({
    required this.label,
    required this.icon,
    required this.children,
    this.description,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final List<Widget> children;
  final String? description;
  final bool danger;
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

/// 二级菜单：先只列组（图标 + 组名 + 一句概括 + 右侧箭头），点一组再弹这一组的条目。
/// 一级不显示大标题，避免「聊天菜单 / 当前：xxx」这种占地方的块（v0.40.0）。

/// 二级菜单：一级只列组，点开一组进二级；**返回键与点空白处都返回上一级**
/// （一级再返回才关闭），这样误触不会把整个菜单关掉（v0.40.1）。
Future<void> showGroupedSheetMenu(
  BuildContext context, {
  required List<SheetMenuGroup> groups,
  double maxHeightFactor = 0.78,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: '菜单',
    barrierColor: Colors.black.withValues(alpha: 0.32),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (dialogContext, _, _) => _GroupedSheetMenu(
      groups: groups,
      maxHeightFactor: maxHeightFactor,
    ),
    transitionBuilder: (context, animation, secondary, child) {
      final t = Curves.easeOutCubic.transform(animation.value);
      return Opacity(
        opacity: t,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      );
    },
  );
}

class _GroupedSheetMenu extends StatefulWidget {
  const _GroupedSheetMenu({required this.groups, required this.maxHeightFactor});

  final List<SheetMenuGroup> groups;
  final double maxHeightFactor;

  @override
  State<_GroupedSheetMenu> createState() => _GroupedSheetMenuState();
}

class _GroupedSheetMenuState extends State<_GroupedSheetMenu> {
  SheetMenuGroup? _active;

  /// 返回上一级；已经在一级就关掉菜单。
  void _back() {
    if (_active != null) {
      setState(() => _active = null);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final active = _active;
    return PopScope(
      canPop: active == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) setState(() => _active = null);
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _back,
              child: const SizedBox.expand(),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              color: scheme.surface,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              clipBehavior: Clip.antiAlias,
              child: SafeArea(
                top: false,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: size.height * widget.maxHeightFactor,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _SheetDragHandle(),
                        if (active == null)
                          for (final group in widget.groups)
                            SheetMenuItem(
                              icon: group.icon,
                              title: group.label,
                              subtitle: group.description,
                              danger: group.danger,
                              trailing: const Icon(Icons.chevron_right, size: 20),
                              onTap: () => setState(() => _active = group),
                            )
                        else ...[
                          _SheetGroupHeader(
                            title: active.label,
                            onBack: () => setState(() => _active = null),
                          ),
                          ...active.children,
                        ],
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetDragHandle extends StatelessWidget {
  const _SheetDragHandle();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Container(
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _SheetGroupHeader extends StatelessWidget {
  const _SheetGroupHeader({required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 20, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            tooltip: '返回上一级',
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
