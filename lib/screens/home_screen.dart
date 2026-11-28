import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/chat_group.dart';
import '../models/character_card.dart';
import '../services/active_generations.dart';
import '../services/bookmarks.dart';
import '../services/card_downloader.dart';
import '../services/card_importer.dart';
import '../services/chat_index.dart';
import '../services/file_pick.dart';
import '../services/import_report.dart';
import '../services/storage.dart';
import '../widgets/whats_new_dialog.dart';
import '../widgets/common.dart';
import '../widgets/character_actions_sheet.dart';
import '../widgets/sheet_menu.dart';
import '../widgets/import_report_dialog.dart';
import '../widgets/segmented_toggle.dart';
import '../widgets/update_flow.dart';
import 'card_creator_screen.dart';
import 'card_market_screen.dart';
import 'chat_screen.dart';
import 'character_edit_screen.dart';
import 'create_group_screen.dart';
import 'onboarding_screen.dart';
import 'settings_screen.dart';

/// 首页：单人角色列表 / 群聊列表（顶部分段切换）。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// 单个导入文件的上限（v0.41.0，商用加固）：角色卡正常情况下远小于这个值，
  /// 超过多半是选错了文件（视频、压缩包），直接在读入内存前拦下。
  static const int _maxImportBytes = 50 * 1024 * 1024; // 50MB

  List<CharacterCard> _characters = [];
  List<ChatGroup> _groups = [];
  bool _loading = true;
  String _query = '';

  /// 0 = 单人，1 = 群聊（仅会话内记忆，重启回单人）
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _reload();
    // 启动时静默检查更新（v0.23.0）：一天最多一次，有新版才弹窗。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      maybeAutoCheckUpdates(context);
      // 更新后第一次打开：先说这次改了什么（v0.43.0）。
      maybeShowWhatsNew(context);
    });
  }

  Future<void> _reload() async {
    final list = await Storage.loadCharacters();
    final groups = await Storage.loadGroups();
    if (!mounted) return;
    setState(() {
      _characters = list;
      _groups = groups;
      _loading = false;
      _previewCache.clear(); // 角色可能被编辑，简介缓存整体失效
    });
  }

  /// 成员名字（角色被删除后回退 null，行里只显示现存成员）。
  String? _memberName(String id) {
    for (final c in _characters) {
      if (c.id == id) return c.name;
    }
    return null;
  }

  List<CharacterCard> get _visibleCharacters {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _characters;
    return _characters
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.description.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _openChat(CharacterCard card) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(charId: card.id)),
    );
    // 从聊天/编辑返回后刷新（可能被编辑或删除）
    _reload();
  }

  /// 从文件选择导入（FAB 底部弹窗的"从文件导入"）。
  Future<void> _import() async {
    try {
      final result = await pickFilesWithExtensions(['png', 'json', 'charx']);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) {
        throw const FormatException('读取文件失败');
      }
      // v0.41.0：本地文件先卡上限，避免一次性把超大文件读进内存。
      if (bytes.length > _maxImportBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('这个文件太大了（超过 50MB），请检查是不是选错了文件'),
          ),
        );
        return;
      }
      await _importBytes(bytes, file.name);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这不是有效的角色卡文件')),
      );
    }
  }

  /// 解析 + 入库 + snackbar（文件导入与链接下载共用）。
  /// v0.32.0：识别 CHARX，并在有提醒时先弹「导入体检」。
  Future<void> _importBytes(Uint8List bytes, String name) async {
    final imported = await importCardFile(bytes, filename: name);
    final card = imported.card;
    await _reload();
    if (!mounted) return;
    if (imported.report.hasWarnings || imported.report.fit != ImportFit.usable) {
      await showImportReportDialog(context, imported.report);
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已导入角色「${card.name}」'),
        action: SnackBarAction(
          label: '去聊天',
          onPressed: () => _openChat(card),
        ),
      ),
    );
  }

  /// 从链接下载并导入。成功返回 null，失败返回可展示的中文原因。
  Future<String?> _downloadFromUrl(
    String url, [
    DownloadProgressCallback? onProgress,
  ]) async {
    try {
      // 按内容识别（PNG 魔数 → PNG 卡，否则按 JSON 解析）
      final bytes = await downloadCard(url, onProgress: onProgress);
      await _importBytes(bytes, '');
      return null;
    } on CardDownloadException catch (e) {
      return e.message;
    } on FormatException catch (e) {
      final msg = e.message;
      if (msg == '这不是有效的角色卡文件') {
        return '链接内容不是有效的角色卡（支持 .png / .json）';
      }
      return '解析失败：$msg';
    } catch (e) {
      return '下载失败：$e';
    }
  }

  Future<void> _editCharacter(CharacterCard card) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CharacterEditScreen(charId: card.id)),
    );
    if (changed == true) _reload();
  }

  Future<void> _deleteCharacter(CharacterCard card) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除角色'),
        content: Text('确定删除「${card.name}」吗？对话记录也会一并删除，此操作不可恢复。'),
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
    // 先注销该会话的后台生成任务（若还在跑），再删存储：避免后台完成
    // 回写把刚删掉的会话复活（任务收尾时找不到目标会自动放弃）。
    ActiveGenerations.instance.remove(card.id);
    // v0.17.0：清掉该角色下的全部分段聊天（多聊天）与书签
    final chats = await ChatIndex.load(card.id);
    for (final chat in chats) {
      if (chat.id == card.id) continue;
      ActiveGenerations.instance.remove(chat.id);
      await Storage.deleteConversation(chat.id);
      await BookmarkStore.clear(chat.id);
    }
    await BookmarkStore.clear(card.id);
    await ChatIndex.save(card.id, const []);
    await Storage.deleteCharacter(card.id);
    await _reload();
  }

  Future<void> _openGroupChat(String groupId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen.group(groupId: groupId)),
    );
    // 从聊天返回后刷新（可能被删除或成员变动）
    _reload();
  }

  Future<void> _deleteGroup(ChatGroup group) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除群聊'),
        content: Text('确定删除「${group.name}」吗？聊天记录也会一并删除，此操作不可恢复。'),
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
    // 同角色删除：先注销后台生成任务再删存储，防止收尾回写复活会话。
    ActiveGenerations.instance.remove(Storage.groupConvId(group.id));
    // v0.17.0：清掉群聊下的全部分段聊天与书签
    final owner = ChatIndex.ownerOf(charId: '', groupId: group.id);
    final chats = await ChatIndex.load(owner);
    for (final chat in chats) {
      ActiveGenerations.instance.remove(chat.id);
      await Storage.deleteConversation(chat.id);
      await BookmarkStore.clear(chat.id);
    }
    await ChatIndex.save(owner, const []);
    await Storage.deleteGroup(group.id);
    await _reload();
  }

  Future<void> _createGroup() async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
    );
    if (id == null || !mounted) return;
    // 创建成功直接进入新群聊
    _openGroupChat(id);
  }

  void _showActions(CharacterCard card) {
    // v0.45.1：长按只留两个按钮，不再显示角色名/「角色操作」标题与分组。
    showCharacterActionsSheet(
      context,
      card: card,
      onEdit: () => _editCharacter(card),
      onDelete: () => _deleteCharacter(card),
    );
  }

  /// 简介首行（按 id 缓存，避免列表滚动/搜索时每帧重复切串）
  final Map<String, String> _previewCache = {};

  String _preview(CharacterCard c) => _previewCache.putIfAbsent(c.id, () {
        final firstLine = c.description.trim().isEmpty
            ? (c.personality.trim().isEmpty
                ? '（暂无简介）'
                : c.personality.trim())
            : c.description.trim();
        return firstLine.split('\n').first;
      });

  /// FAB / 空态按钮：底部弹窗四选
  /// "AI 创建角色卡 / 角色卡市场 / 从文件导入 / 从链接下载"。
  // v0.45.0：AI 创建排第一并带「推荐」；角色卡市场退到第二、不再标推荐。
  void _showImportSheet() {
    final scheme = Theme.of(context).colorScheme;
    showSheetMenu<void>(
      context: context,
      children: [
        const SheetMenuTitle(
          title: '导入角色卡',
          subtitle: '支持 .png、.json、.charx，也可以让 AI 陪你写一张。',
        ),
        SheetMenuItem(
          icon: Icons.auto_awesome_outlined,
          title: 'AI 创建角色卡',
          subtitle: '说一句想要的设定，AI 引导你逐步补全',
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '推荐',
              style: TextStyle(fontSize: AppType.meta, color: scheme.primary),
            ),
          ),
          onTap: () {
            Navigator.pop(context);
            _openCardCreator();
          },
        ),
        SheetMenuItem(
          icon: Icons.storefront_outlined,
          title: '角色卡市场',
          subtitle: '浏览公开角色卡，下载后自动导入',
          onTap: () {
            Navigator.pop(context);
            _openMarket();
          },
        ),
        SheetMenuItem(
          icon: Icons.description_outlined,
          title: '从文件导入',
          subtitle: '从手机中选择 .png、.json、.charx 文件',
          onTap: () {
            Navigator.pop(context);
            _import();
          },
        ),
        SheetMenuItem(
          icon: Icons.link_outlined,
          title: '从链接下载',
          subtitle: '粘贴直链，下载后自动导入',
          onTap: () {
            Navigator.pop(context);
            _showDownloadDialog();
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Text(
            '导入后可在主页编辑或删除，也能随时导出或备份。',
            style: TextStyle(
              fontSize: AppType.meta,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 打开 AI 创建器；返回后刷新列表（可能已入库新角色）。
  Future<void> _openCardCreator() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CardCreatorScreen()),
    );
    _reload();
  }

  /// 打开角色卡市场；返回后刷新列表（市场里可能已导入新角色）。
  Future<void> _openMarket() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CardMarketScreen()),
    );
    _reload();
  }

  void _showDownloadDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => _LinkDownloadDialog(onDownload: _downloadFromUrl),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('LiteTavern'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              // 设置里可能重看了引导，回来刷新列表无副作用
              _reload();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 顶部分段切换：单人 | 群聊（胶囊、hairline、滑动指示 v0.9.0）
                _buildSegmented(),
                // 搜索框：下划线式（无边框盒）
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: _tab == 0
                          ? '搜索角色（名字 / 简介）'
                          : '搜索群聊（名字 / 成员）',
                      hintStyle: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.onSurfaceVariant,
                      ),
                      prefixIcon: Icon(
                        Icons.search_outlined,
                        size: 22,
                        color: scheme.onSurfaceVariant,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 22,
                      ),
                      isDense: true,
                      filled: false,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 12),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: scheme.outline),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(
                          color: scheme.primary,
                          width: 1.4,
                        ),
                      ),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                // 单人/群聊切换：内容区 250ms 交叉淡入（easeOutCubic）。
                // child 换 key 触发切换，两份列表不同时构建
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ),
                      child: child,
                    ),
                    child: _buildList(scheme, key: ValueKey(_tab)),
                  ),
                ),
              ],
            ),
      floatingActionButton: _tab == 0
          ? FloatingActionButton.extended(
              onPressed: _showImportSheet,
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              label: const Text('导入'),
            )
          : FloatingActionButton.extended(
              onPressed: _createGroup,
              icon: const Icon(Icons.group_add_outlined, size: 20),
              label: const Text('新建群聊'),
            ),
    );
  }

  /// 分段切换「单人 | 群聊」：胶囊描边 + 自带滑动指示（v0.9.0）。
  /// 胶囊高亮在两段间平滑滑动（280ms easeOutCubic），文字同步渐变；
  /// 内容区的 v0.8 交叉淡入保留。
  Widget _buildSegmented() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SegmentedToggle(
        value: _tab,
        labels: const ['单人', '群聊'],
        onChanged: (i) => setState(() => _tab = i),
      ),
    );
  }

  List<ChatGroup> get _visibleGroups {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _groups;
    return _groups.where((g) {
      if (g.name.toLowerCase().contains(q)) return true;
      for (final id in g.memberIds) {
        final n = _memberName(id);
        if (n != null && n.toLowerCase().contains(q)) return true;
      }
      return false;
    }).toList();
  }

  /// 群聊列表行：群名 w600 + 成员数/成员名 13sp 次要（与角色行同构），
  /// 长按删除（确认框，级联删会话）。
  Widget _buildGroupRow(ChatGroup g, ColorScheme scheme) {
    final names = <String>[];
    for (final id in g.memberIds) {
      final n = _memberName(id);
      if (n != null) names.add(n);
    }
    final subtitle = names.isEmpty
        ? '${g.memberIds.length} 位成员'
        : '${g.memberIds.length} 位成员 · ${names.join('、')}';
    return InkWell(
      onTap: () => _openGroupChat(g.id),
      onLongPress: () => _deleteGroup(g),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.08),
                border: Border.all(color: scheme.outline),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.groups_outlined,
                size: 26,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    g.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: AppType.body,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
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
          ],
        ),
      ),
    );
  }

  Widget _buildGroupList(ColorScheme scheme, {Key? key}) {
    if (_groups.isEmpty) return _buildGroupEmpty(scheme, key: key);
    final list = _visibleGroups;
    if (list.isEmpty) {
      return Center(
        key: key,
        child: Text(
          '没有匹配的群聊',
          style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return RefreshIndicator(
      key: key,
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 88),
        itemCount: list.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, indent: 84, endIndent: 16),
        itemBuilder: (context, i) => _buildGroupRow(list[i], scheme),
      ),
    );
  }

  Widget _buildGroupEmpty(ColorScheme scheme, {Key? key}) {
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.groups_outlined,
              size: 88,
              color: scheme.onSurface.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 20),
            Text(
              '还没有群聊，选两个以上角色开一桌',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _createGroup,
              icon: const Icon(Icons.group_add_outlined, size: 20),
              label: const Text('新建群聊'),
            ),
          ],
        ),
      ),
    );
  }

  /// [key] = AnimatedSwitcher 的切换键（tab 变化 → 换 key → 交叉淡入）。
  Widget _buildList(ColorScheme scheme, {Key? key}) {
    if (_tab == 1) return _buildGroupList(scheme, key: key);
    if (_characters.isEmpty) return _buildEmpty(scheme, key: key);
    final list = _visibleCharacters;
    if (list.isEmpty) {
      return Center(
        key: key,
        child: Text(
          '没有匹配的角色',
          style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
        ),
      );
    }
    // 角色行：56dp 圆角方形头像（圆角 12）+ 名字 15sp w600 + 一行简介
    // 13sp 次要色；行间 hairline divider 左缩进 84 对齐文字。
    return RefreshIndicator(
      key: key,
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 88),
        itemCount: list.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, indent: 84, endIndent: 16),
        itemBuilder: (context, i) {
          final c = list[i];
          return InkWell(
            onTap: () => _openChat(c),
            onLongPress: () => _showActions(c),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
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
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmpty(ColorScheme scheme, {Key? key}) {
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 空状态：大号描边图标（ink 25%）+ 一行次要文案，无 emoji
            Icon(
              Icons.theaters_outlined,
              size: 88,
              color: scheme.onSurface.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 20),
            Text(
              '还没有角色。点右下角「导入角色卡」，挑一张就能开始。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _showImportSheet,
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              label: const Text('导入角色卡'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                );
              },
              icon: const Icon(Icons.help_outline, size: 20),
              label: const Text('看看新手引导'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "从链接下载"弹窗：输入 URL，下载中显示转圈；失败在弹窗内显示原因。
class _LinkDownloadDialog extends StatefulWidget {
  /// 执行下载+导入；成功返回 null，失败返回可展示的中文原因。
  /// [onProgress] 用于展示下载进度。
  final Future<String?> Function(String url, DownloadProgressCallback? onProgress)
  onDownload;

  const _LinkDownloadDialog({required this.onDownload});

  @override
  State<_LinkDownloadDialog> createState() => _LinkDownloadDialogState();
}

class _LinkDownloadDialogState extends State<_LinkDownloadDialog> {
  final _ctrl = TextEditingController();
  bool _downloading = false;
  String? _error;
  int _receivedBytes = 0;
  int? _totalBytes;

  double? get _progress {
    final total = _totalBytes;
    if (total == null || total <= 0) return null;
    return (_receivedBytes / total).clamp(0.0, 1.0);
  }

  String get _downloadLabel {
    final progress = _progress;
    if (progress == null) {
      final kb = _receivedBytes ~/ 1024;
      return kb > 0 ? '下载中 $kb KB' : '下载中…';
    }
    return '下载中 ${(progress * 100).floor()}%';
  }

  void _onProgress(int received, int? total) {
    if (!mounted) return;
    final known = total != null && total > 0 ? total : null;
    setState(() {
      _receivedBytes = received;
      _totalBytes = known;
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final url = _ctrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请输入链接');
      return;
    }
    setState(() {
      _downloading = true;
      _error = null;
      _receivedBytes = 0;
      _totalBytes = null;
    });
    final err = await widget.onDownload(url, _onProgress);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _downloading = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('从链接下载角色卡'),
      content: _downloading
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(width: 14),
                    Text(_downloadLabel),
                  ],
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 5,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _ctrl,
                  keyboardType: TextInputType.url,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'https://example.com/card.png',
                  ),
                  onSubmitted: (_) => _start(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: TextStyle(color: scheme.error, fontSize: 13),
                  ),
                ],
              ],
            ),
      actions: _downloading
          ? null
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _start,
                child: const Text('下载'),
              ),
            ],
    );
  }
}
