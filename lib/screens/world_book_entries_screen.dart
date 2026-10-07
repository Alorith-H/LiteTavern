import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/world_info.dart';
import '../services/hit_stats.dart';
import '../services/storage.dart';
import '../widgets/common.dart';

/// 世界书条目列表页：查看 / 启停 / 编辑 / 新增 / 删除（用户导入的世界书）。
/// 保存写回 `worldbooks/<id>.json`；content 非空校验在编辑弹窗内完成。
///
/// [convId] 非空时，每行副文本显示该对话的命中率（`本对话 3/12 · 25%`）；
/// 无发送记录（旧会话无 hitStats）不显示。
class WorldBookEntriesScreen extends StatefulWidget {
  final String bookId;
  final WorldInfo book;

  /// 来源会话 id（单聊 = 角色 id）；null = 不显示命中率
  final String? convId;

  const WorldBookEntriesScreen({
    super.key,
    required this.bookId,
    required this.book,
    this.convId,
  });

  @override
  State<WorldBookEntriesScreen> createState() => _WorldBookEntriesScreenState();
}

class _WorldBookEntriesScreenState extends State<WorldBookEntriesScreen> {
  late final List<WorldInfoEntry> _entries;

  /// 该对话的命中率统计（null = 无记录不显示）
  HitStats? _hitStats;

  @override
  void initState() {
    super.initState();
    _entries = List.of(widget.book.entries);
    _loadHitStats();
  }

  Future<void> _loadHitStats() async {
    final convId = widget.convId;
    if (convId == null || convId.isEmpty) return;
    final data = await Storage.loadConversationData(convId);
    if (!mounted) return;
    setState(() => _hitStats = data.hitStats);
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
  /// v0.7.0：含高级字段——次要关键词、按概率注入、注入位置/深度、递归、回看条数。
  Future<void> _showEntryDialog(WorldInfoEntry? current) async {
    final keysCtrl = TextEditingController(
      text: current == null ? '' : current.keys.join(', '),
    );
    final secondaryCtrl = TextEditingController(
      text: current == null ? '' : current.keysSecondary.join(', '),
    );
    final contentCtrl = TextEditingController(text: current?.content ?? '');
    final orderCtrl =
        TextEditingController(text: '${current?.insertionOrder ?? 0}');
    final scanDepthCtrl =
        TextEditingController(text: '${current?.scanDepth ?? 50}');
    var enabled = current == null || !current.disabled;
    var useProb = current?.useProbability ?? false;
    var prob = (current?.probability ?? 100).clamp(0, 100).toInt();
    // 位置归一到 0/1/2（导入数据可能是别的值）
    var position = current?.position ?? 0;
    if (position != 1 && position != 2) position = 0;
    var depth = (current?.depth ?? 4).clamp(0, 99).toInt();
    var recursive = current?.recursive ?? false;
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
                      labelText: '触发关键词（逗号分隔）',
                      hintText: '城堡, 城镇, 酒馆',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: secondaryCtrl,
                    decoration: const InputDecoration(
                      labelText: '次要关键词（逗号分隔，可留空）',
                      helperText: '主词命中后，还需其中至少一个出现才注入',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: contentCtrl,
                    minLines: 3,
                    maxLines: 8,
                    decoration: InputDecoration(
                      labelText: '内容',
                      errorText: error,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: orderCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '插入顺序（数字，小的在前）',
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
                  const Divider(height: 1),
                  Row(
                    children: [
                      const Expanded(child: Text('按概率随机注入')),
                      Switch(
                        value: useProb,
                        onChanged: (v) => set(() => useProb = v),
                      ),
                    ],
                  ),
                  if (useProb) ...[
                    Slider(
                      value: prob.toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 100,
                      label: '$prob%',
                      onChanged: (v) => set(() => prob = v.toInt()),
                    ),
                    Text(
                      '命中后有 $prob% 的概率注入',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const Divider(height: 1),
                  const Padding(
                    padding: EdgeInsets.only(top: 8, bottom: 2),
                    child: Text(
                      '注入位置',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  RadioGroup<int>(
                    groupValue: position,
                    onChanged: (v) => set(() => position = v ?? 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        RadioListTile<int>(
                          value: 0,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('对话开头注入', style: TextStyle(fontSize: AppType.body)),
                        ),
                        RadioListTile<int>(
                          value: 1,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('对话中按深度注入', style: TextStyle(fontSize: AppType.body)),
                          subtitle: const Text('作为用户消息插进历史里', style: TextStyle(fontSize: AppType.caption)),
                        ),
                        RadioListTile<int>(
                          value: 2,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('角色设定后注入', style: TextStyle(fontSize: AppType.body)),
                        ),
                      ],
                    ),
                  ),
                  if (position == 1) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '插到倒数第 ${depth + 1} 条消息之前',
                            style: TextStyle(
                              fontSize: AppType.caption,
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Text('$depth'),
                      ],
                    ),
                    Slider(
                      value: depth.toDouble(),
                      min: 0,
                      max: 99,
                      divisions: 99,
                      onChanged: (v) => set(() => depth = v.toInt()),
                    ),
                  ],
                  const Divider(height: 1),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('递归匹配'),
                            Text(
                              '用已激活条目的内容继续匹配其它词条',
                              style: TextStyle(
                                fontSize: AppType.caption,
                                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: recursive,
                        onChanged: (v) => set(() => recursive = v),
                      ),
                    ],
                  ),
                  TextField(
                    controller: scanDepthCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '回看消息条数',
                      helperText: '只回看最近 N 条消息找关键词，0 = 全程',
                      isDense: true,
                    ),
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
    final secondary = secondaryCtrl.text;
    final content = contentCtrl.text;
    final order = int.tryParse(orderCtrl.text) ?? 0;
    final scanDepth = int.tryParse(scanDepthCtrl.text) ?? 50;
    keysCtrl.dispose();
    secondaryCtrl.dispose();
    contentCtrl.dispose();
    orderCtrl.dispose();
    scanDepthCtrl.dispose();

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
    final parsedSecondary = [
      for (final k in secondary.split(RegExp(r'[,，]')))
        if (k.trim().isNotEmpty) k.trim(),
    ];
    final updated = WorldInfoEntry(
      id: current?.id, // 保留稳定 id（命中率 key 不因编辑而作废）
      keys: parsedKeys,
      keysSecondary: parsedSecondary,
      content: content,
      insertionOrder: order,
      disabled: !enabled,
      probability: prob,
      useProbability: useProb,
      position: position,
      depth: depth,
      recursive: recursive,
      scanDepth: scanDepth < 0 ? 0 : scanDepth,
      groupWeight: current?.groupWeight ?? 100,
    );
    if (current == null) {
      setState(() => _entries.add(updated));
    } else {
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
            icon: const Icon(Icons.add_outlined, size: 20),
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
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: _entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = _entries[i];
                // 本对话命中率（无发送记录不显示）
                final rate = _hitStats?.rateLine(entryKeyOf(e));
                final preview = _preview(e);
                // 行直接铺在背景上（无卡片）：关键词 + 预览 + 启停开关
                return InkWell(
                  onTap: () => _showEntryDialog(e),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _keysLabel(e),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: AppType.body,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                rate == null
                                    ? preview
                                    : '本对话 $rate · $preview',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppType.caption,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: !e.disabled,
                          onChanged: (v) {
                            setState(() => _entries[i] = WorldInfoEntry(
                                  id: e.id,
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
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
