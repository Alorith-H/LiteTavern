import 'package:flutter/material.dart';

import '../models/world_info.dart';
import '../services/storage.dart';

/// 世界书条目列表页：查看 / 启停 / 编辑 / 新增 / 删除（用户导入的世界书）。
/// 保存写回 `worldbooks/<id>.json`；content 非空校验在编辑弹窗内完成。
class WorldBookEntriesScreen extends StatefulWidget {
  final String bookId;
  final WorldInfo book;

  const WorldBookEntriesScreen({
    super.key,
    required this.bookId,
    required this.book,
  });

  @override
  State<WorldBookEntriesScreen> createState() => _WorldBookEntriesScreenState();
}

class _WorldBookEntriesScreenState extends State<WorldBookEntriesScreen> {
  late final List<WorldInfoEntry> _entries;

  @override
  void initState() {
    super.initState();
    _entries = List.of(widget.book.entries);
  }

  /// 变更后写回原世界书文件。
  Future<void> _persist() {
    return Storage.updateWorldBook(
      widget.bookId,
      WorldInfo(
        name: widget.book.name,
        description: widget.book.description,
        entries: _entries,
      ),
    );
  }

  /// content 前 40 字单行预览。
  String _preview(WorldInfoEntry e) {
    final flat = e.content.replaceAll('\n', ' ').trim();
    return flat.length <= 40 ? flat : '${flat.substring(0, 40)}…';
  }

  String _keysLabel(WorldInfoEntry e) =>
      e.keys.isEmpty ? '（无关键词）' : e.keys.join('、');

  /// 新增 / 编辑条目弹窗；保存 / 删除后立即写回存储。
  Future<void> _showEntryDialog(WorldInfoEntry? current) async {
    final keysCtrl = TextEditingController(
      text: current == null ? '' : current.keys.join(', '),
    );
    final contentCtrl = TextEditingController(text: current?.content ?? '');
    final orderCtrl =
        TextEditingController(text: '${current?.insertionOrder ?? 0}');
    var enabled = current == null || !current.disabled;
    String? error;

    final result = await showDialog<Object>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          return AlertDialog(
            title: Text(current == null ? '新增条目' : '编辑条目'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: keysCtrl,
                    decoration: const InputDecoration(
                      labelText: '主 keys（逗号分隔）',
                      hintText: '城堡, 城镇, 酒馆',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: contentCtrl,
                    minLines: 3,
                    maxLines: 8,
                    decoration: InputDecoration(
                      labelText: 'content',
                      errorText: error,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: orderCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'insertion_order（数字）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Expanded(child: Text('启用此条目')),
                      Switch(
                        value: enabled,
                        onChanged: (v) => set(() => enabled = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              if (current != null)
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'delete'),
                  child: Text(
                    '删除',
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  if (contentCtrl.text.trim().isEmpty) {
                    set(() => error = '内容不能为空');
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );

    final keys = keysCtrl.text;
    final content = contentCtrl.text;
    final order = int.tryParse(orderCtrl.text) ?? 0;
    keysCtrl.dispose();
    contentCtrl.dispose();
    orderCtrl.dispose();

    if (result == 'delete') {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('删除条目'),
          content: const Text('确定删除这个条目吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok == true && mounted) {
        setState(() => _entries.remove(current!));
        await _persist();
      }
      return;
    }

    if (result != true) return;

    final parsedKeys = [
      for (final k in keys.split(RegExp(r'[,，]')))
        if (k.trim().isNotEmpty) k.trim(),
    ];
    final WorldInfoEntry updated;
    if (current == null) {
      updated = WorldInfoEntry(
        keys: parsedKeys,
        keysSecondary: const [],
        content: content,
        insertionOrder: order,
        disabled: !enabled,
        probability: 100,
        useProbability: false,
        position: 0,
        depth: 4,
        recursive: false,
        scanDepth: 50,
        groupWeight: 100,
      );
      setState(() => _entries.add(updated));
    } else {
      updated = WorldInfoEntry(
        keys: parsedKeys,
        keysSecondary: current.keysSecondary,
        content: content,
        insertionOrder: order,
        disabled: !enabled,
        probability: current.probability,
        useProbability: current.useProbability,
        position: current.position,
        depth: current.depth,
        recursive: current.recursive,
        scanDepth: current.scanDepth,
        groupWeight: current.groupWeight,
      );
      setState(() {
        final i = _entries.indexOf(current);
        if (i >= 0) _entries[i] = updated;
      });
    }
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = widget.book.name.trim().isEmpty
        ? '未命名世界书'
        : widget.book.name.trim();
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton.icon(
            onPressed: () => _showEntryDialog(null),
            icon: const Icon(Icons.add),
            label: const Text('新增条目'),
          ),
        ],
      ),
      body: _entries.isEmpty
          ? Center(
              child: Text(
                '还没有条目，点右上角新增',
                style:
                    TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: _entries.length,
              itemBuilder: (context, i) {
                final e = _entries[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(
                      _keysLabel(e),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      _preview(e),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Switch(
                      value: !e.disabled,
                      onChanged: (v) {
                        setState(() => _entries[i] = WorldInfoEntry(
                              keys: e.keys,
                              keysSecondary: e.keysSecondary,
                              content: e.content,
                              insertionOrder: e.insertionOrder,
                              disabled: !v,
                              probability: e.probability,
                              useProbability: e.useProbability,
                              position: e.position,
                              depth: e.depth,
                              recursive: e.recursive,
                              scanDepth: e.scanDepth,
                              groupWeight: e.groupWeight,
                            ));
                        _persist();
                      },
                    ),
                    onTap: () => _showEntryDialog(e),
                  ),
                );
              },
            ),
    );
  }
}
