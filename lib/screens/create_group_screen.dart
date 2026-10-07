import 'package:flutter/material.dart';

import '../models/chat_group.dart';
import '../models/character_card.dart';
import '../services/storage.dart';
import '../widgets/common.dart';

/// 新建群聊：群名（留空自动编号）+ 已导入角色多选，至少 2 位才能创建。
/// 创建成功 pop 出群 id。
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  List<CharacterCard> _characters = [];
  List<String> _existingNames = [];
  final Set<String> _selected = {};
  final _nameCtrl = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final chars = await Storage.loadCharacters();
    final groups = await Storage.loadGroups();
    if (!mounted) return;
    setState(() {
      _characters = chars;
      _existingNames = [for (final g in groups) g.name];
      _loading = false;
    });
  }

  /// 自动编号：从 1 起找第一个未被占用的「群聊 N」。
  String get _defaultName {
    var n = 1;
    while (_existingNames.contains('群聊 $n')) {
      n++;
    }
    return '群聊 $n';
  }

  bool get _canCreate => _selected.length >= 2;

  Future<void> _create() async {
    if (!_canCreate) return;
    final name = _nameCtrl.text.trim().isEmpty ? _defaultName : _nameCtrl.text.trim();
    // 成员顺序 = 列表展示顺序（即轮转的"群内顺序"），与勾选先后无关
    final memberIds = [
      for (final c in _characters)
        if (_selected.contains(c.id)) c.id,
    ];
    if (memberIds.length < 2) return;
    final group = await Storage.saveGroup(ChatGroup(
      id: '',
      name: name,
      memberIds: memberIds,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    if (!mounted) return;
    Navigator.of(context).pop(group.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_outlined, size: 22),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text(
          '新建群聊',
          style: TextStyle(fontSize: AppType.chatTitle, fontWeight: FontWeight.w700),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
              children: [
                const SectionHeader('群名称'),
                TextField(
                  controller: _nameCtrl,
                  decoration: InputDecoration(
                    hintText: _defaultName,
                    helperText: '留空则自动使用默认名称',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 6),
                SectionHeader('选择成员（至少 2 位）'),
                if (_characters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: Text(
                      '还没有角色，先回首页导入角色卡',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else ...[
                  for (var i = 0; i < _characters.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 84, endIndent: 16),
                    _buildRow(_characters[i]),
                  ],
                ],
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _canCreate ? _create : null,
        icon: const Icon(Icons.check_outlined, size: 20),
        label: Text(_selected.isEmpty ? '创建' : '创建（已选 ${_selected.length}）'),
      ),
    );
  }

  /// 角色勾选行：与首页角色行同构（56dp 圆角方头像 + 名字 + 简介），尾部勾选框。
  Widget _buildRow(CharacterCard c) {
    final scheme = Theme.of(context).colorScheme;
    final checked = _selected.contains(c.id);
    return InkWell(
      onTap: () => setState(() {
        if (checked) {
          _selected.remove(c.id);
        } else {
          _selected.add(c.id);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            CharacterAvatar(
              id: c.id,
              name: c.name,
              size: 56,
              square: true,
              radius: 12,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: AppType.body,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _preview(c),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: AppType.caption,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 40,
              height: 40,
              child: Checkbox(
                value: checked,
                onChanged: (_) => setState(() {
                  if (checked) {
                    _selected.remove(c.id);
                  } else {
                    _selected.add(c.id);
                  }
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _preview(CharacterCard c) {
    final first = c.description.trim().isEmpty
        ? (c.personality.trim().isEmpty ? '（暂无简介）' : c.personality.trim())
        : c.description.trim();
    return first.split('\n').first;
  }
}
