import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/character_card.dart';
import '../services/card_downloader.dart';
import '../services/card_parser.dart';
import '../services/storage.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';
import 'character_edit_screen.dart';
import 'onboarding_screen.dart';
import 'settings_screen.dart';

/// 首页：角色列表。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<CharacterCard> _characters = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await Storage.loadCharacters();
    if (!mounted) return;
    setState(() {
      _characters = list;
      _loading = false;
    });
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
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) {
        throw const FormatException('读取文件失败');
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
  Future<void> _importBytes(Uint8List bytes, String name) async {
    final parsed = CardParser.parse(bytes, name);
    final card = await Storage.saveCharacter(parsed.card);
    if (parsed.pngBytes != null) {
      await Storage.saveAvatar(card.id, parsed.pngBytes!);
    }
    await _reload();
    if (!mounted) return;
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
  Future<String?> _downloadFromUrl(String url) async {
    try {
      // 按内容识别（PNG 魔数 → PNG 卡，否则按 JSON 解析）
      final bytes = await downloadCard(url);
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
    await Storage.deleteCharacter(card.id);
    await _reload();
  }

  void _showActions(CharacterCard card) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(ctx);
                _editCharacter(card);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text('删除',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteCharacter(card);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _preview(CharacterCard c) {
    final firstLine = c.description.trim().isEmpty
        ? (c.personality.trim().isEmpty ? '（暂无简介）' : c.personality.trim())
        : c.description.trim();
    final lines = firstLine.split('\n');
    return lines.first;
  }

  /// FAB：底部弹窗选择"从文件导入 / 从链接下载"。
  void _showImportSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.file_upload_outlined),
              title: const Text('从文件导入'),
              subtitle: const Text('选择本地 .png / .json 角色卡'),
              onTap: () {
                Navigator.pop(ctx);
                _import();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_outlined),
              title: const Text('从链接下载'),
              subtitle: const Text('输入 URL，下载 .png / .json 角色卡'),
              onTap: () {
                Navigator.pop(ctx);
                _showDownloadDialog();
              },
            ),
          ],
        ),
      ),
    );
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
        title: const Text('轻酒馆'),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: '搜索角色（名字 / 简介）',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                Expanded(child: _buildList(scheme)),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showImportSheet,
        icon: const Icon(Icons.file_upload_outlined),
        label: const Text('导入'),
      ),
    );
  }

  Widget _buildList(ColorScheme scheme) {
    if (_characters.isEmpty) return _buildEmpty(scheme);
    final list = _visibleCharacters;
    if (list.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的角色',
          style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final c = list[i];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _openChat(c),
              onLongPress: () => _showActions(c),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    CharacterAvatar(
                      id: c.id,
                      name: c.name,
                      size: 52,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _preview(c),
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: scheme.outline),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmpty(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.theaters_outlined, size: 88, color: scheme.primary),
            const SizedBox(height: 20),
            const Text(
              '还没有角色\n点右下角导入角色卡',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, height: 1.6),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _showImportSheet,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('导入角色卡'),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                );
              },
              icon: const Icon(Icons.help_outline),
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
  final Future<String?> Function(String url) onDownload;

  const _LinkDownloadDialog({required this.onDownload});

  @override
  State<_LinkDownloadDialog> createState() => _LinkDownloadDialogState();
}

class _LinkDownloadDialogState extends State<_LinkDownloadDialog> {
  final _ctrl = TextEditingController();
  bool _downloading = false;
  String? _error;

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
    });
    final err = await widget.onDownload(url);
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
          ? const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                SizedBox(width: 14),
                Text('下载中…'),
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
