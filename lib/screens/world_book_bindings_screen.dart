import 'package:flutter/material.dart';

import '../models/chat_group.dart';
import '../models/world_info.dart';
import '../services/chat_index.dart';
import '../services/storage.dart';
import '../services/user_personas.dart';
import '../widgets/common.dart';

/// 世界书四范围绑定（v0.27.0）：全局 / 人设 / 角色 / 这段聊天。
///
/// 语义：同一本书可以同时绑定多个范围，只要有一个范围开着就会注入。
/// 关闭某个范围不会关掉其它范围里已开启的同一本书。
class WorldBookBindingsScreen extends StatefulWidget {
  final WorldBookScope initialScope;
  final String? initialOwnerId;

  const WorldBookBindingsScreen({
    super.key,
    this.initialScope = WorldBookScope.global,
    this.initialOwnerId,
  });

  @override
  State<WorldBookBindingsScreen> createState() =>
      _WorldBookBindingsScreenState();
}

/// 范围里的一个「归属者」（全局只有一个）。
class _Owner {
  const _Owner(this.id, this.name, this.hint);

  final String id;
  final String name;
  final String hint;
}

class _WorldBookBindingsScreenState extends State<WorldBookBindingsScreen> {
  late WorldBookScope _scope;
  late String? _ownerId;
  bool _loading = true;
  List<(String, WorldInfo)> _books = const [];
  List<_Owner> _owners = const [];
  final Map<String, bool> _enabled = {};

  @override
  void initState() {
    super.initState();
    _scope = widget.initialScope;
    _ownerId = widget.initialOwnerId;
    _loadAll();
  }

  Future<void> _loadAll() async {
    final books = await Storage.loadWorldBooks();
    final owners = await _loadOwners(_scope);
    if (!mounted) return;
    setState(() {
      _books = books;
      _owners = owners;
      if (_scope == WorldBookScope.global) {
        _ownerId = null;
      } else if (_ownerId == null ||
          !owners.any((o) => o.id == _ownerId)) {
        _ownerId = owners.isEmpty ? null : owners.first.id;
      }
      _loading = false;
    });
    await _loadMounts();
  }

  Future<List<_Owner>> _loadOwners(WorldBookScope scope) async {
    switch (scope) {
      case WorldBookScope.global:
        return const [_Owner('', '全局默认', '所有角色、所有聊天都会带上（可在设置里逐本开关）')];
      case WorldBookScope.character:
        final cards = await Storage.loadCharacters();
        return [
          for (final c in cards)
            _Owner(c.id, c.name, '和「${c.name}」单聊时生效'),
        ];
      case WorldBookScope.persona:
        return [
          for (final p in PersonaStore.load())
            _Owner(p.id, p.name, '使用这套人设时生效'),
        ];
      case WorldBookScope.chat:
        final cards = await Storage.loadCharacters();
        final groups = await Storage.loadGroups();
        final owners = <_Owner>[];
        for (final c in cards) {
          for (final chat in await ChatIndex.load(c.id)) {
            owners.add(_Owner(chat.id, '${c.name} · ${chat.name}',
                '${chat.messageCount} 条消息 · 只对这段聊天生效'));
          }
        }
        for (final ChatGroup g in groups) {
          final convId = Storage.groupConvId(g.id);
          for (final chat in await ChatIndex.load(convId)) {
            owners.add(_Owner(chat.id, '群聊 ${g.name} · ${chat.name}',
                '${chat.messageCount} 条消息 · 只对这段聊天生效'));
          }
        }
        return owners;
    }
  }

  Future<void> _loadMounts() async {
    final scope = _scope;
    final owner = scope == WorldBookScope.global ? null : _ownerId;
    final mounts = await Storage.worldBookMountsForScope(scope, owner);
    if (!mounted || scope != _scope) return;
    final enabled = <String, bool>{
      for (final (id, _) in _books)
        id: scope == WorldBookScope.global
            ? AppSettings.mountedWorldBookIds.contains(id)
            : (mounts ?? const <({String id, bool enabled})>[])
                .where((m) => m.id == id && m.enabled)
                .isNotEmpty,
    };
    setState(() {
      _enabled
        ..clear()
        ..addAll(enabled);
    });
  }

  Future<void> _switchScope(WorldBookScope scope) async {
    setState(() {
      _scope = scope;
      _ownerId = null;
      _loading = true;
    });
    final owners = await _loadOwners(scope);
    if (!mounted) return;
    setState(() {
      _owners = owners;
      _ownerId = owners.isEmpty ? null : owners.first.id;
      _loading = false;
    });
    await _loadMounts();
  }

  Future<void> _pickOwner() async {
    if (_owners.length <= 1) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '选择${_scope.label}',
                    style: const TextStyle(
                      fontSize: AppType.section,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _owners.length,
                  itemBuilder: (ctx, i) {
                    final o = _owners[i];
                    return ListTile(
                      title: Text(o.name),
                      subtitle: Text(o.hint),
                      selected: o.id == _ownerId,
                      trailing: o.id == _ownerId
                          ? const Icon(Icons.check, size: 20)
                          : null,
                      onTap: () => Navigator.pop(ctx, o.id),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _ownerId = picked);
    await _loadMounts();
  }

  Future<void> _toggle(String bookId, bool value) async {
    setState(() => _enabled[bookId] = value);
    final mounts = [
      for (final (id, _) in _books)
        if (_enabled[id] == true) (id: id, enabled: true),
    ];
    if (_scope == WorldBookScope.global) {
      final ids = AppSettings.mountedWorldBookIds.toSet();
      if (value) {
        ids.add(bookId);
      } else {
        ids.remove(bookId);
      }
      AppSettings.mountedWorldBookIds = ids.toList();
    } else {
      await Storage.saveWorldBookMountsForScope(_scope, _ownerId, mounts);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final owner = _scope == WorldBookScope.global
        ? _owners.firstOrNull
        : _owners.where((o) => o.id == _ownerId).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('世界书绑定')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          SegmentedButton<WorldBookScope>(
            segments: [
              for (final s in WorldBookScope.values)
                ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {_scope},
            showSelectedIcon: false,
            onSelectionChanged: (v) => _switchScope(v.first),
          ),
          const SizedBox(height: 12),
          if (owner != null)
            InkWell(
              onTap: _pickOwner,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            owner.name,
                            style: const TextStyle(
                              fontSize: AppType.body,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            owner.hint,
                            style: TextStyle(
                              fontSize: AppType.caption,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_owners.length > 1)
                      Icon(
                        Icons.expand_more,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            '同一本书可以绑定多个范围；只要有一个范围开着就会注入。'
            '关掉某个范围不影响其它范围里已开启的同一本书。',
            style: TextStyle(
              fontSize: AppType.caption,
              height: 1.45,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_books.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  '还没有世界书，先在「设置 → 世界书」里导入一本',
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            for (final (id, book) in _books) ...[
              const Divider(height: 1),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  book.name.trim().isEmpty ? '未命名世界书' : book.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${book.entries.length} 条'),
                value: _enabled[id] ?? false,
                onChanged: (v) => _toggle(id, v),
              ),
            ],
        ],
      ),
    );
  }
}
