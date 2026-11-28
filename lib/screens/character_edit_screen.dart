import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/character_card.dart';
import '../models/world_info.dart';
import '../services/api_client.dart';
import '../services/card_ai_edit.dart';
import '../services/card_export.dart';
import '../services/storage.dart';
import '../widgets/card_translation_sheet.dart';
import '../widgets/common.dart';
import 'settings_screen.dart';
import 'world_book_entries_screen.dart';

/// 角色编辑页：编辑名字/简介/性格/场景/开场白，管理世界书挂载。
///
/// 两种进入方式：
/// - [CharacterEditScreen]：编辑已入库角色（按 [charId] 读存储）
/// - [CharacterEditScreen.draft]：预览编辑一张内存卡（AI 创建器产出，
///   未保存态 —— 点「保存」才走同一套入库流程并生成 id）
class CharacterEditScreen extends StatefulWidget {
  /// 已入库角色 id；draft 模式为空串
  final String charId;

  /// 未保存的内存卡（draft 模式非空，跳过存储读取）
  final CharacterCard? initialCard;

  const CharacterEditScreen({super.key, required this.charId})
      : initialCard = null;

  const CharacterEditScreen.draft({super.key, required CharacterCard card})
      : charId = '',
        initialCard = card;

  bool get isDraft => initialCard != null;

  @override
  State<CharacterEditScreen> createState() => _CharacterEditScreenState();
}

class _CharacterEditScreenState extends State<CharacterEditScreen> {
  CharacterCard? _card;
  bool _loading = true;
  bool _saving = false;

  /// 新选的头像图片（保存时随卡一起落盘；null = 用卡原图/首字占位）
  Uint8List? _pendingAvatar;

  /// 已导入的全部世界书 (id, 世界书)
  List<(String, WorldInfo)> _worldBooks = [];

  /// 本角色的挂载（含启用状态）
  List<({String id, bool enabled})> _mounts = [];

  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _personalityCtrl;
  late final TextEditingController _scenarioCtrl;
  late final TextEditingController _firstMesCtrl;

  /// v0.45.0：AI 修改请求进行中（按钮置灰 + 转圈）
  bool _aiEditing = false;
  final ApiClient _api = ApiClient();

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
    // draft：用创建器传入的内存卡，不读存储（保存时才入库生成 id）
    final card =
        widget.initialCard ?? await Storage.loadCharacter(widget.charId);
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
    final saved = await Storage.saveCharacter(updated);
    // 新头像：与保存同一时机落盘（draft 卡此时才有 id）
    final avatar = _pendingAvatar;
    if (avatar != null) {
      await Storage.saveAvatar(saved.id, avatar);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  // --------------------------------------------------------- AI 修改 --
  // v0.45.0：用当前激活的模型按一句话要求改写角色字段。模型只输出
  // 要改的字段 JSON，先给「原文 → 新文」对比，用户确认后才写回输入框
  // （不自动保存，仍然要点右上角「保存」）。

  Future<void> _aiEditCard() async {
    final card = _card;
    if (card == null || _aiEditing) return;
    if (!AppSettings.apiConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('还没配置模型，先去设置里填一个 API Key'),
          action: SnackBarAction(
            label: '去设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ),
      );
      return;
    }
    final plan = await _showAiEditSheet();
    if (plan == null || !mounted) return;
    await _runAiEdit(plan.$1, plan.$2);
  }

  /// 底部弹层：一句话要求 + 修改范围。返回 (要求, 范围)。
  Future<(String, CardAiEditScope)?> _showAiEditSheet() {
    final ctrl = TextEditingController();
    var scope = CardAiEditScope.polishAll;
    return showModalBottomSheet<(String, CardAiEditScope)>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final canRun = ctrl.text.trim().isNotEmpty;
            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                18,
                20,
                20 + MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI 修改角色',
                    style: TextStyle(
                      fontSize: AppType.page,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '说一句想怎么改，改完先给你看对比，确认后才写进输入框。',
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in CardAiEditScope.values)
                        ChoiceChip(
                          label: Text(s.label),
                          selected: scope == s,
                          onSelected: (_) => setSheet(() => scope = s),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 4,
                    onChanged: (_) => setSheet(() {}),
                    decoration: InputDecoration(
                      hintText: scope.hint,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: canRun
                            ? () => Navigator.pop(
                                ctx, (ctrl.text.trim(), scope))
                            : null,
                        child: const Text('开始修改'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(ctrl.dispose);
  }

  Future<void> _runAiEdit(String instruction, CardAiEditScope scope) async {
    final card = _card;
    if (card == null) return;
    setState(() => _aiEditing = true);
    try {
      final input = CardAiEditInput.fromCard(
        card: card,
        scope: scope,
        instruction: instruction,
        name: _nameCtrl.text,
        description: _descCtrl.text,
        personality: _personalityCtrl.text,
        scenario: _scenarioCtrl.text,
        firstMes: _firstMesCtrl.text,
      );
      final raw = await _api
          .summarize(
            baseUrl: AppSettings.baseUrl,
            apiKey: AppSettings.apiKey,
            model: AppSettings.model,
            system: kCardAiEditSystem,
            user: buildCardAiEditUserPrompt(input),
            temperature: 0.7,
            topP: 1.0,
            maxTokens: 2048,
            sampling: AppSettings.activePreset.sampling,
          )
          .timeout(const Duration(seconds: 120));
      if (!mounted) return;
      final changes = parseCardAiEditResult(raw);
      if (changes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这次没改出内容，换个说法再试一次')),
        );
        return;
      }
      final accepted = await _showAiEditPreview(changes);
      if (accepted == true && mounted) _applyAiEdit(changes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('修改失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _aiEditing = false);
    }
  }

  /// 对比弹窗：逐字段「原文 → 新文」，默认全选，确认后写回。
  Future<bool?> _showAiEditPreview(Map<String, String> changes) {
    final selected = <String>{...changes.keys};
    final scheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        final keys = changes.keys.toList();
        return StatefulBuilder(
          builder: (ctx, setDlg) => AlertDialog(
            title: const Text('AI 修改预览'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final key in keys) ...[
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: selected.contains(key),
                        title: Text(
                          kCardEditFieldLabels[key] ?? key,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        onChanged: (v) => setDlg(() {
                          if (v == true) {
                            selected.add(key);
                          } else {
                            selected.remove(key);
                          }
                        }),
                      ),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '原文',
                              style: TextStyle(
                                fontSize: AppType.meta,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _currentTextOf(key).isEmpty
                                  ? '（空）'
                                  : _currentTextOf(key),
                              style: TextStyle(
                                fontSize: AppType.caption,
                                height: 1.45,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '新文',
                              style: TextStyle(
                                fontSize: AppType.meta,
                                color: scheme.primary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              changes[key]!,
                              style: TextStyle(
                                fontSize: AppType.caption,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: Text('应用到 ${selected.length} 项'),
              ),
            ],
          ),
        );
      },
    ).then((ok) {
      if (ok == true) changes.removeWhere((k, _) => !selected.contains(k));
      return ok;
    });
  }

  String _currentTextOf(String key) => switch (key) {
        'name' => _nameCtrl.text,
        'description' => _descCtrl.text,
        'personality' => _personalityCtrl.text,
        'scenario' => _scenarioCtrl.text,
        'firstMes' => _firstMesCtrl.text,
        _ => '',
      };

  void _applyAiEdit(Map<String, String> changes) {
    setState(() {
      for (final e in changes.entries) {
        switch (e.key) {
          case 'name':
            _nameCtrl.text = e.value;
          case 'description':
            _descCtrl.text = e.value;
          case 'personality':
            _personalityCtrl.text = e.value;
          case 'scenario':
            _scenarioCtrl.text = e.value;
          case 'firstMes':
            _firstMesCtrl.text = e.value;
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已写进输入框，确认后点右上角「保存」')),
    );
  }

  /// 点头像 → 选一张图片做头像（仅暂存，随「保存」入库）。
  Future<void> _pickAvatar() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null || bytes.isEmpty) return;
      if (!mounted) return;
      setState(() => _pendingAvatar = bytes);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这张图片读不出来，换一张试试')),
      );
    }
  }

  // ---------------------------------------------------------- 翻译 --

  /// 以当前表单内容为准拼一张卡（翻译和导出都以屏幕上的内容为准）。
  CharacterCard? _cardWithForm() {
    final card = _card;
    if (card == null) return null;
    final name = _nameCtrl.text.trim();
    return card.copyWith(
      name: name.isEmpty ? card.name : name,
      description: _descCtrl.text,
      personality: _personalityCtrl.text,
      scenario: _scenarioCtrl.text,
      firstMes: _firstMesCtrl.text,
    );
  }

  /// 打开翻译弹层：译文在弹层里对照展示，应用后只填表单，点「保存」才落库。
  Future<void> _translateCard() async {
    final card = _cardWithForm();
    if (card == null) return;
    await showCardTranslationSheet(
      context,
      card: card,
      onApply: _applyTranslation,
    );
  }

  /// 弹层回填：只改控制器 + 内部卡状态，不落库（等用户点「保存」）。
  Future<void> _applyTranslation(
    String name,
    String description,
    String personality,
    String scenario,
    String firstMes,
  ) async {
    _nameCtrl.text = name;
    _descCtrl.text = description;
    _personalityCtrl.text = personality;
    _scenarioCtrl.text = scenario;
    _firstMesCtrl.text = firstMes;
    // 与表单保持一致，导出/再次翻译读到的是填好的内容（头像首字也要刷新）。
    setState(() {
      _card = _card?.copyWith(
        name: name,
        description: description,
        personality: personality,
        scenario: scenario,
        firstMes: firstMes,
      );
    });
  }

  // ---------------------------------------------------------- 导出 --

  /// 导出格式选择：JSON 总是可用；PNG 仅当角色有原图卡时提供。
  void _exportSheet() {
    final card = _card;
    if (card == null) return;
    final hasPng = Storage.avatarFile(card.id) != null;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  '导出格式',
                  style: TextStyle(
                    fontSize: AppType.section,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.data_object_outlined),
                title: const Text('JSON'),
                subtitle: const Text('chara_card V2 规范，可再次导入'),
                onTap: () {
                  Navigator.pop(ctx);
                  _export(asPng: false);
                },
              ),
              if (hasPng)
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('PNG'),
                  subtitle: const Text('写回原图卡片，图片本身仍可导入'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _export(asPng: true);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 用当前表单值导出 → 临时文件 → 系统分享面板，用完即删临时文件。
  Future<void> _export({required bool asPng}) async {
    final card = _card;
    if (card == null) return;
    final name =
        _nameCtrl.text.trim().isEmpty ? card.name : _nameCtrl.text.trim();
    final withForm = card.copyWith(
      name: name,
      description: _descCtrl.text,
      personality: _personalityCtrl.text,
      scenario: _scenarioCtrl.text,
      firstMes: _firstMesCtrl.text,
    );
    final json = buildExportJson(withForm);
    File? tmp;
    try {
      final dir = await getTemporaryDirectory();
      final base = safeFileName(withForm.name);
      if (asPng) {
        final avatar = Storage.avatarFile(withForm.id);
        if (avatar == null) return; // 无原图（正常情况已被选择器挡住）
        final out = embedCharaInPng(await avatar.readAsBytes(), json);
        tmp = File('${dir.path}${Platform.pathSeparator}$base.png');
        await tmp.writeAsBytes(out, flush: true);
      } else {
        tmp = File('${dir.path}${Platform.pathSeparator}$base.json');
        await tmp.writeAsString(json, flush: true);
      }
      await SharePlus.instance.share(ShareParams(files: [XFile(tmp.path)]));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    } finally {
      // share_plus 分享前会把文件拷进自己的缓存目录，删掉原件不影响接收方
      final f = tmp;
      if (f != null) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
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

  Future<void> _persistMounts() {
    // draft 卡还没有 id，挂载关系等保存入库后再说（此处不落盘）
    if (widget.isDraft) return Future.value();
    return Storage.saveWorldBookMounts(widget.charId, _mounts);
  }

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
        builder: (_) => WorldBookEntriesScreen(
          bookId: id,
          book: hit.first.$2,
          // 条目页显示「本对话命中率」用的会话 id（draft 无会话 → 不显示）
          convId: widget.isDraft ? null : widget.charId,
        ),
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
          IconButton(
            icon: _aiEditing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high_outlined),
            tooltip: 'AI 修改',
            onPressed: _aiEditing ? null : _aiEditCard,
          ),
          IconButton(
            icon: const Icon(Icons.translate),
            tooltip: '翻译',
            onPressed: _translateCard,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert_outlined),
            onSelected: (v) {
              if (v == 'export') _exportSheet();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'export',
                child: Text('导出角色卡'),
              ),
            ],
          ),
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
                  GestureDetector(
                    onTap: _pickAvatar,
                    child: _pendingAvatar != null
                        ? ClipOval(
                            child: Image.memory(
                              _pendingAvatar!,
                              width: 88,
                              height: 88,
                              fit: BoxFit.cover,
                            ),
                          )
                        : CharacterAvatar(
                            id: card.id,
                            name: _nameCtrl.text,
                            size: 88,
                          ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点头像可选图片作为头像（随保存生效）；无头像时显示名字首字',
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
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
              const SizedBox(height: 16),
              _label('备选开场白（${card.alternateGreetings.length} 条，聊天中可轮换）'),
              const SizedBox(height: 4),
              for (var i = 0; i < card.alternateGreetings.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '#${i + 1}',
                        style: TextStyle(
                          fontSize: AppType.section,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        card.alternateGreetings[i],
                        style: const TextStyle(
                            fontSize: AppType.body, height: 1.5),
                      ),
                    ],
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            _label('世界书'),
            // 无框分节：行直接铺在背景上，细线分隔（不套卡片）
            if (bookCount > 0)
              _worldRow(
                title: '卡内嵌世界书 · $bookCount 条',
                subtitle: '随角色卡自动参与关键词匹配（只读）',
                onTap: _embeddedBookTap,
              ),
            for (var r = 0; r < mountedRows.length; r++) ...[
              if (bookCount > 0 || r > 0) const Divider(height: 1),
              _worldRow(
                title: mountedRows[r].$2,
                subtitle:
                    '${mountedRows[r].$3} 条 · ${mountedRows[r].$4 ? '已启用' : '已禁用'}',
                // 点行进入条目列表页（开关在右侧单独处理）
                onTap: () => _openEntries(mountedRows[r].$1),
                trailing: Switch(
                  value: mountedRows[r].$4,
                  onChanged: (v) => _toggleMount(mountedRows[r].$1, v),
                ),
              ),
            ],
            if (bookCount > 0 || mountedRows.isNotEmpty) const Divider(height: 1),
            _worldRow(
              title: '导入世界书',
              subtitle: '选择 JSON 文件，导入后自动挂载到此角色',
              onTap: _importWorldBook,
            ),
            const Divider(height: 1),
            _worldRow(
              title: '从已导入中挂载',
              onTap: _mountExisting,
            ),
          ],
        ),
      ),
    );
  }

  /// 世界书分节里的一行：标题 + 副说明（+ 可选尾部控件），无装饰图标。
  Widget _worldRow({
    required String title,
    String? subtitle,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppType.body,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  /// 编辑风小节标题（同全局 SectionHeader 样式，多带底部间距贴住字段）。
  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4, top: 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppType.section,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );

  InputDecoration _hint(String hint) =>
      InputDecoration(hintText: hint, isDense: true);
}
