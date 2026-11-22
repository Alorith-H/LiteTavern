import 'package:flutter/material.dart';

import '../services/user_personas.dart';
import '../widgets/common.dart';

/// 用户人设管理页（v0.16.0，对齐 SillyTavern 的 Persona）。
///
/// 一套人设 = 你在故事里的名字 + 一段自我介绍。选中的人设会：
/// 1. 作为对话里「我」的称呼（同时写进设置里的 userName）；
/// 2. 在每次生成时注入 system，让角色知道你是谁、和它什么关系。
class PersonasScreen extends StatefulWidget {
  const PersonasScreen({super.key});

  @override
  State<PersonasScreen> createState() => _PersonasScreenState();
}

class _PersonasScreenState extends State<PersonasScreen> {
  late List<UserPersona> _personas;
  String? _activeId;

  @override
  void initState() {
    super.initState();
    // 首次进入：把设置里现有的名字包成一条人设，避免列表空空的
    _personas = PersonaStore.ensureSeeded();
    _activeId = PersonaStore.active?.id;
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _personas = PersonaStore.load();
      _activeId = PersonaStore.active?.id;
    });
  }

  void _select(UserPersona p) {
    PersonaStore.setActive(p.id);
    _reload();
  }

  String _summary(UserPersona p) {
    if (!p.hasDescription) return '只有名字，不注入设定';
    final oneLine = p.promptText.replaceAll(RegExp(r'\s+'), ' ');
    return oneLine.length <= 60 ? oneLine : '${oneLine.substring(0, 60)}…';
  }

  Future<void> _edit([UserPersona? persona]) async {
    final nameCtrl = TextEditingController(text: persona?.name ?? '');
    final descCtrl = TextEditingController(text: persona?.description ?? '');
    String? error;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(persona == null ? '新建人设' : '编辑人设'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: '名字',
                    hintText: '角色会这样称呼你',
                    errorText: error,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: '设定（可留空）',
                    hintText: '例：24 岁的书店店员，说话慢，养了一只黑猫。'
                        '和角色是大学同学。',
                    alignLabelWithHint: true,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '设定会作为背景注入给模型；对话里你的名字会替换成上面填的名字。',
                  style: TextStyle(
                    fontSize: AppType.meta,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) {
                  set(() => error = '名字不能为空');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    final name = nameCtrl.text.trim();
    final desc = descCtrl.text.trim();
    // 不在这里 dispose：弹层关闭动画期间 TextField 还会读一次 controller，
    // 提前释放会触发「used after being disposed」。
    if (saved != true) return;

    PersonaStore.upsert(
      UserPersona(id: persona?.id ?? '', name: name, description: desc),
    );
    // 列表里只有这一套时，保存后顺手选中它
    if (_activeId == null) {
      final list = PersonaStore.load();
      if (list.length == 1) PersonaStore.setActive(list.first.id);
    }
    _reload();
  }

  Future<void> _delete(UserPersona p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除人设'),
        content: Text('确定删除「${p.name}」吗？聊天记录不会受影响。'),
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
    if (ok != true) return;
    PersonaStore.remove(p.id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('用户人设')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text(
            '人设是「你」在故事里的身份。选中后，角色会知道你是谁、和它什么关系，'
            '对话里也会用这个名字称呼你。可以准备多套（比如不同世界用不同身份）随时切换。',
            style: TextStyle(
              fontSize: AppType.caption,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SectionHeader('我的人设'),
          if (_personas.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '还没有人设，点右下角新建一个。',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            for (final p in _personas) ...[
              InkWell(
                onTap: () => _select(p),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      RadioGroup<String>(
                        groupValue: _activeId,
                        onChanged: (_) => _select(p),
                        child: Radio<String>(value: p.id),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: AppType.body,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (p.id == _activeId) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: scheme.primary
                                          .withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '使用中',
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
                              _summary(p),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppType.caption,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.edit_outlined, size: 22),
                          tooltip: '编辑',
                          onPressed: () => _edit(p),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(Icons.delete_outline,
                              size: 22, color: scheme.error),
                          tooltip: '删除',
                          onPressed: () => _delete(p),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
            ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_outlined, size: 20),
        label: const Text('新建人设'),
      ),
    );
  }
}
