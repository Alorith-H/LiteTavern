import 'package:flutter/material.dart';

import 'common.dart';

/// 候选回复选择器（v0.12.0）。
///
/// 由聊天页在「自动生成回复」开启时弹出：一次给出多个候选，
/// 用户点选一条后以 [int] 下标返回（写入消息并落库）；
/// 关闭 / 返回手势 / 点遮罩 → 返回 null（本次不落库）。
/// [onRegenerate] 非空时提供「换一批」，重新请求一组候选。
Future<int?> showReplyCandidatesSheet(
  BuildContext context, {
  required List<String> candidates,
  required String characterName,
  Future<List<String>> Function()? onRegenerate,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => _ReplyCandidatesSheet(
      candidates: candidates,
      characterName: characterName,
      onRegenerate: onRegenerate,
    ),
  );
}

class _ReplyCandidatesSheet extends StatefulWidget {
  const _ReplyCandidatesSheet({
    required this.candidates,
    required this.characterName,
    required this.onRegenerate,
  });

  final List<String> candidates;
  final String characterName;
  final Future<List<String>> Function()? onRegenerate;

  @override
  State<_ReplyCandidatesSheet> createState() => _ReplyCandidatesSheetState();
}

class _ReplyCandidatesSheetState extends State<_ReplyCandidatesSheet> {
  late List<String> _items = widget.candidates;
  bool _regenerating = false;
  String? _error;

  Future<void> _regenerate() async {
    final regen = widget.onRegenerate;
    if (regen == null || _regenerating) return;
    setState(() {
      _regenerating = true;
      _error = null;
    });
    try {
      final next = await regen();
      if (!mounted) return;
      setState(() {
        _items = next;
        _regenerating = false;
        _error = next.isEmpty ? '这一批没有可用的候选，再换一次试试' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _regenerating = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '选择一条回复',
                        style: TextStyle(
                          fontSize: AppType.page,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.characterName} 生成了 ${_items.length} 个候选，点选一条采用',
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Text(
                _error!,
                style: TextStyle(fontSize: AppType.caption, color: scheme.error),
              ),
            ),
          Flexible(
            child: _regenerating
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (ctx, i) => _CandidateCard(
                      index: i,
                      text: _items[i],
                      onTap: () => Navigator.of(ctx).pop(i),
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Text(
                    '点卡片采用，关闭则不写入',
                    style: TextStyle(
                      fontSize: AppType.meta,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (widget.onRegenerate != null)
                    TextButton.icon(
                      onPressed: _regenerating ? null : _regenerate,
                      icon: const Icon(Icons.refresh_outlined, size: 18),
                      label: const Text('换一批'),
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

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.index,
    required this.text,
    required this.onTap,
  });

  final int index;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '候选 ${index + 1}',
                      style: TextStyle(
                        fontSize: AppType.meta,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.touch_app_outlined,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                text,
                maxLines: 12,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: AppType.body, height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
