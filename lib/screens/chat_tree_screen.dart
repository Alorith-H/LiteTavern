// 分支树页（v0.25.0）。
//
// 同一角色（或群聊）下的聊天文件会随着「从这里创建分支」长成一棵树；
// 这里把它按层级展开，点一段直接切过去。
import 'package:flutter/material.dart';

import '../services/chat_index.dart';
import '../widgets/common.dart';

class ChatTreeScreen extends StatefulWidget {
  const ChatTreeScreen({
    super.key,
    required this.ownerId,
    required this.currentConvId,
  });

  final String ownerId;
  final String currentConvId;

  @override
  State<ChatTreeScreen> createState() => _ChatTreeScreenState();
}

class _ChatTreeScreenState extends State<ChatTreeScreen> {
  List<ChatTreeNode> _nodes = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final chats = await ChatIndex.load(widget.ownerId);
    if (!mounted) return;
    setState(() {
      _nodes = ChatIndex.tree(chats);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('分支树')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _nodes.isEmpty
              ? const _EmptyTree()
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _nodes.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (ctx, i) => _TreeRow(
                    node: _nodes[i],
                    selected: _nodes[i].info.id == widget.currentConvId,
                    onTap: () => Navigator.of(context).pop(_nodes[i].info),
                    scheme: scheme,
                  ),
                ),
    );
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.node,
    required this.selected,
    required this.onTap,
    required this.scheme,
  });

  final ChatTreeNode node;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final info = node.info;
    final isBranch = node.isBranch;
    final indent = 16.0 + node.depth * 22.0;
    final subtitle = StringBuffer('${info.messageCount} 条消息');
    if (info.updatedAt > 0) {
      subtitle.write(' · ${_fmtTime(info.updatedAt)}');
    }
    if (isBranch && info.forkIndex != null) {
      subtitle.write(' · 从第 ${info.forkIndex! + 1} 条分出');
    }
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(indent, 10, 16, 10),
        child: Row(
          children: [
            if (node.depth > 0)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.subdirectory_arrow_right,
                  size: 16,
                  color: scheme.outline,
                ),
              ),
            Icon(
              isBranch ? Icons.call_split : Icons.chat_bubble_outline,
              size: 18,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          info.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                            color: selected ? scheme.primary : null,
                          ),
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '当前',
                            style: TextStyle(
                              fontSize: AppType.meta,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle.toString(),
                    style: TextStyle(
                      fontSize: AppType.meta,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }

  static String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final sameDay =
        d.year == now.year && d.month == now.month && d.day == now.day;
    String p2(int n) => n.toString().padLeft(2, '0');
    final hm = '${p2(d.hour)}:${p2(d.minute)}';
    return sameDay ? '今天 $hm' : '${d.month}月${d.day}日 $hm';
  }
}

class _EmptyTree extends StatelessWidget {
  const _EmptyTree();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined, size: 40, color: scheme.outline),
          const SizedBox(height: 10),
          Text(
            '还没有分支：长按一条消息，选「从这里创建分支」',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
