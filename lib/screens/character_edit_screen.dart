import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/character_card.dart';
import '../models/world_info.dart';
import '../services/storage.dart';
import '../widgets/common.dart';
import 'world_book_entries_screen.dart';

/// 角色编辑页：编辑名字/简介/性格/场景/开场白，管理世界书挂载。
class CharacterEditScreen extends StatefulWidget {
  final String charId;

  const CharacterEditScreen({super.key, required this.charId});

  @override
  State<CharacterEditScreen> createState() => _CharacterEditScreenState();
}

class _CharacterEditScreenState extends State<CharacterEditScreen> {
  CharacterCard? _card;
  bool _loading = true;
  bool _saving = false;

  /// 已导入的全部世界书 (id, 世界书)
  List<(String, WorldInfo)> _worldBooks = [];

  /// 本角色的挂载（含启用状态）
  List<({String id, bool enabled})> _mounts = [];

  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _personalityCtrl;
  late final TextEditingController _scenarioCtrl;
  late final TextEditingController _firstMesCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _descCtrl = TextEditingController();
    _personalityCtrl = TextEditingController();
    _scenarioCtrl = TextEditingController();
    _firstMesCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _personalityCtrl.dispose();
    _scenarioCtrl.dispose();
    _firstMesCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final card = await Storage.loadCharacter(widget.charId);
    if (!mounted) return;
    if (card == null) {
      Navigator.of(context).pop();
      return;
    }
    _nameCtrl.text = card.name;
    _descCtrl.text = card.description;
    _personalityCtrl.text = card.personality;
    _scenarioCtrl.text = card.scenario;
    _firstMesCtrl.text = card.firstMes;

    // 挂载：未单独配置时回退到全局默认（与聊天页一致）
    final explicit = await Storage.worldBookMountsFor(card.id);
    final mounts = explicit ??
        [
          for (final id in AppSettings.mountedWorldBookIds)
            (id: id, enabled: true),
        ];
    final books = await Storage.loadWorldBooks();
    if (!mounted) return;
    setState(() {
      _card = card;
      _loading = false;
      _worldBooks = books;
      _mounts = mounts;
    });
  }

  Future<void> _save() async {
    final card = _card;
    if (card == null || _saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名字不能为空')),
      );
      return;
    }
    setState(() => _saving = true);
    final updated = card.copyWith(
      name: name,
      description: _descCtrl.text,
      personality: _personalityCtrl.text,
      scenario: _scenarioCtrl.text,
      firstMes: _firstMesCtrl.text,
    );
    await Storage.saveCharacter(updated);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  // ---------------------------------------------------------- 世界书 --

  /// 已挂载行：(id, 名称, 条数, 是否启用)；已删除的世界书跳过。
  List<(String, String, int, bool)> _mountedRows() {
    final rows = <(String, String, int, bool)>[];
    for (final m in _mounts) {
      final hit = _worldBooks.where((b) => b.$1 == m.id);
      if (hit.isEmpty) continue;
      final book = hit.first.$2;
      rows.add((
        m.id,
        book.name.trim().isEmpty ? '未命名世界书' : book.name.trim(),
        book.entries.length,
        m.enabled,
      ));
    }
    return rows;
  }

  Future<void> _persistMounts() =>
      Storage.saveWorldBookMounts(widget.charId, _mounts);

  /// 条目页返回后刷新世界书列表（条数可能变化）。
  Future<void> _reloadWorldBooks() async {
    final books = await Storage.loadWorldBooks();
    if (mounted) setState(() => _worldBooks = books);
  }

  /// 点击已挂载的用户导入世界书行 → 条目列表页。
  Future<void> _openEntries(String id) async {
    final hit = _worldBooks.where((b) => b.$1 == id);
    if (hit.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorldBookEntriesScreen(bookId: id, book: hit.first.$2),
      ),
    );
    await _reloadWorldBooks();
  }

  void _embeddedBookTap() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('卡内嵌世界书不可编辑')));
  }

  void _toggleMount(String id, bool enabled) {
    setState(() {
      _mounts = [
        for (final m in _mounts)
          m.id == id ? (id: m.id, enabled: enabled) : m,
      ];
    });
    _persistMounts();
  }

  /// 导入世界书 JSON → 存储 → 自动挂载到当前角色。
  Future<void> _importWorldBook() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) throw const FormatException('读取失败');
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('格式错误');
      }
      final book = WorldInfo.fromJson(decoded);
      if (book.entries.isEmpty) throw const FormatException('没有条目');
      final id = await Storage.saveWorldBook(book);
      final all = await Storage.loadWorldBooks();
      if (!mounted) return;
      setState(() {
        _worldBooks = all;
        if (!_mounts.any((m) => m.id == id)) {
          _mounts = [..._mounts, (id: id, enabled: true)];
        }
      });
      await _persistMounts();
      if (!mounted) return;
      final name = book.name.trim().isEmpty ? '未命名世界书' : book.name.trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入并挂载「$name」（${book.entries.length} 条）')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这不是有效的世界书文件')),
      );
    }
  }

  /// 从已导入的世界书里挑一本挂载到当前角色。
  void _mountExisting() {
    final available = _worldBooks
        .where((b) => !_mounts.any((m) => m.id == b.$1))
        .toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可挂载的世界书，可先在设置里导入')),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  '从已导入的世界书中选择',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final (id, book) in available)
                ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(
                    book.name.trim().isEmpty ? '未命名世界书' : book.name.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${book.entries.length} 条'),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(
                        () => _mounts = [..._mounts, (id: id, enabled: true)]);
                    _persistMounts();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = _card;

    if (_loading || card == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('编辑角色')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final bookCount = card.characterBook?.entries.length ?? 0;
    final mountedRows = _mountedRows(); // 每帧只算一次

    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑角色'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  CharacterAvatar(id: card.id, name: _nameCtrl.text, size: 88),
                  const SizedBox(height: 8),
                  Text(
                    '头像来自角色卡原图（无原图时为名字首字）',
                    style:
                        TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _label('名字'),
            TextField(controller: _nameCtrl, decoration: _hint('角色名字')),
            const SizedBox(height: 16),
            _label('简介'),
            TextField(
              controller: _descCtrl,
              decoration: _hint('角色描述 / 背景设定'),
              maxLines: 5,
              minLines: 2,
            ),
            const SizedBox(height: 16),
            _label('性格'),
            TextField(
              controller: _personalityCtrl,
              decoration: _hint('性格特点'),
              maxLines: 4,
              minLines: 1,
            ),
            const SizedBox(height: 16),
            _label('场景'),
            TextField(
              controller: _scenarioCtrl,
              decoration: _hint('当前场景 / 故事背景'),
              maxLines: 4,
              minLines: 1,
            ),
            const SizedBox(height: 16),
            _label('开场白'),
            TextField(
              controller: _firstMesCtrl,
              decoration: _hint('角色的第一条消息'),
              maxLines: 6,
              minLines: 2,
            ),
            if (card.alternateGreetings.isNotEmpty) ...[
              const SizedBox(height: 20),
              _label('备选开场白（${card.alternateGreetings.length} 条，聊天中可轮换）'),
              const SizedBox(height: 8),
              for (var i = 0; i < card.alternateGreetings.length; i++)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '#${i + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          card.alternateGreetings[i],
                          style: const TextStyle(fontSize: 13, height: 1.5),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 20),
            _label('世界书'),
            Card(
              child: Column(
                children: [
                  if (bookCount > 0)
                    ListTile(
                      leading: const Icon(Icons.menu_book_outlined),
                      title: Text('卡内嵌世界书 · $bookCount 条'),
                      subtitle: const Text('随角色卡自动参与关键词匹配（只读）'),
                      onTap: _embeddedBookTap,
                    ),
                  for (final row in mountedRows)
                    ListTile(
                      leading: const Icon(Icons.public),
                      title: Text(
                        row.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${row.$3} 条 · ${row.$4 ? '已启用' : '已禁用'}'),
                      trailing: Switch(
                        value: row.$4,
                        onChanged: (v) => _toggleMount(row.$1, v),
                      ),
                      // 点行进入条目列表页（开关在右侧单独处理）
                      onTap: () => _openEntries(row.$1),
                    ),
                  if (bookCount > 0 || mountedRows.isNotEmpty)
                    const Divider(height: 1),
                  ListTile(
                    leading:
                        Icon(Icons.add_circle_outline, color: scheme.primary),
                    title: const Text('导入世界书'),
                    subtitle: const Text('选择 JSON 文件，导入后自动挂载到此角色'),
                    onTap: _importWorldBook,
                  ),
                  ListTile(
                    leading: const Icon(Icons.add_link),
                    title: const Text('从已导入中挂载'),
                    onTap: _mountExisting,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  InputDecoration _hint(String hint) =>
      InputDecoration(hintText: hint, isDense: true);
}
