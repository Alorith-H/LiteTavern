import 'package:flutter/material.dart';

import '../models/character_card.dart';
import '../models/chat_group.dart';
import '../widgets/common.dart';

/// 群聊主持（v0.36.0）：挑一个发言名单，只让名单里的角色按顺序轮转。
///
/// 名单为空表示全员参与（老的轮转行为）。@ 点名仍然优先，
/// 但只会点名到名单里的角色。
class GroupHostScreen extends StatefulWidget {
  const GroupHostScreen({
    super.key,
    required this.group,
    required this.members,
    this.onChanged,
  });

  final ChatGroup group;
  final List<CharacterCard> members;

  /// 每次改动都会回调，方便上一页即时生效（不必等返回）。
  final ValueChanged<ChatGroup>? onChanged;

  @override
  State<GroupHostScreen> createState() => _GroupHostScreenState();
}

class _GroupHostScreenState extends State<GroupHostScreen> {
  /// 名单顺序（角色 id）。空 = 全员轮流。
  late List<String> _ids;

  @override
  void initState() {
    super.initState();
    final existing = widget.members.map((m) => m.id).toSet();
    _ids = widget.group.speakerIds
        .where(existing.contains)
        .toList(growable: true);
  }

  bool get _all => _ids.isEmpty;

  /// 展示顺序：名单里的按名单顺序，没进名单的排在后面（方便再勾回来）。
  List<CharacterCard> get _rows {
    final byId = {for (final m in widget.members) m.id: m};
    final picked = <CharacterCard>[
      for (final id in _ids)
        if (byId[id] != null) byId[id]!,
    ];
    final chosen = picked.map((m) => m.id).toSet();
    picked.addAll(widget.members.where((m) => !chosen.contains(m.id)));
    return picked;
  }

  bool _checked(CharacterCard m) => _all || _ids.contains(m.id);

  /// 序号：不在名单里返回 0（不显示）。
  int _numberOf(CharacterCard m) {
    if (_all) return widget.members.indexOf(m) + 1;
    return _ids.indexOf(m.id) + 1;
  }

  bool _canUp(CharacterCard m) {
    if (_all) return widget.members.indexOf(m) > 0;
    return _ids.indexOf(m.id) > 0;
  }

  bool _canDown(CharacterCard m) {
    final list = _all ? widget.members.map((e) => e.id).toList() : _ids;
    final i = list.indexOf(m.id);
    return i >= 0 && i < list.length - 1;
  }

  void _notify() {
    widget.onChanged?.call(widget.group.withSpeakerIds(List<String>.of(_ids)));
  }

  void _toggle(CharacterCard m, bool value) {
    setState(() {
      final ids = _all
          ? widget.members.map((e) => e.id).toList()
          : List<String>.of(_ids);
      if (value) {
        if (!ids.contains(m.id)) ids.add(m.id);
      } else {
        ids.remove(m.id);
        if (ids.isEmpty) {
          // 空名单的语义是「全员」，所以不能靠取消勾选得到
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('至少留一位发言人；想全员轮流请点下面的「恢复全员轮流」'),
            ),
          );
          return;
        }
      }
      _ids = ids;
    });
    _notify();
  }

  void _move(CharacterCard m, int delta) {
    final list =
        _all ? widget.members.map((e) => e.id).toList() : List<String>.of(_ids);
    final i = list.indexOf(m.id);
    final to = i + delta;
    if (i < 0 || to < 0 || to >= list.length) return;
    list.removeAt(i);
    list.insert(to, m.id);
    setState(() => _ids = list);
    _notify();
  }

  void _restoreAll() {
    setState(() => _ids = []);
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    final count = _all ? widget.members.length : _ids.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('群聊主持'),
        actions: [
          if (!_all)
            TextButton(
              onPressed: _restoreAll,
              child: const Text('全部恢复'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              _all
                  ? '现在是全员轮流发言。勾掉谁，谁就不会再自动发言。'
                  : '只让名单里的 $count 位角色发言，按下面的顺序轮转。'
                      '用 @ 点名时，也只会叫到名单里的角色。',
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SectionHeader('发言名单（按顺序）'),
          for (final m in rows)
            _HostRow(
              member: m,
              number: _numberOf(m),
              checked: _checked(m),
              canMoveUp: _canUp(m),
              canMoveDown: _canDown(m),
              onToggle: (v) => _toggle(m, v),
              onUp: () => _move(m, -1),
              onDown: () => _move(m, 1),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: OutlinedButton.icon(
              onPressed: _restoreAll,
              icon: const Icon(Icons.groups_outlined, size: 18),
              label: const Text('恢复全员轮流'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: Text(
              '提示：设置好以后回聊天页，发一条消息就按这个名单轮转；'
              '想让它自己接着聊，用菜单里的「让大家接着说」。',
              style: TextStyle(
                fontSize: AppType.meta,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostRow extends StatelessWidget {
  const _HostRow({
    required this.member,
    required this.number,
    required this.checked,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onToggle,
    required this.onUp,
    required this.onDown,
  });

  final CharacterCard member;
  final int number;
  final bool checked;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<bool> onToggle;
  final VoidCallback onUp;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Checkbox(
        value: checked,
        onChanged: (v) => onToggle(v ?? false),
      ),
      title: Row(
        children: [
          if (number > 0)
            Text(
              '$number. ',
              style: TextStyle(
                color: checked ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: checked ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          Expanded(
            child: Text(
              member.name.isEmpty ? '未命名角色' : member.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: member.description.trim().isEmpty
          ? null
          : Text(
              member.description.trim().replaceAll(RegExp(r'\s+'), ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.meta,
                color: scheme.onSurfaceVariant,
              ),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: canMoveUp ? onUp : null,
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            tooltip: '上移',
          ),
          IconButton(
            onPressed: canMoveDown ? onDown : null,
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            tooltip: '下移',
          ),
        ],
      ),
    );
  }
}
