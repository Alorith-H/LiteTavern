// 整库备份与恢复入口（v0.26.0）。
//
// 设置 → 帮助与关于 → 备份与恢复：
//   导出备份：打包成一个 .zip（角色卡/头像、聊天、世界书、群聊、全部设置），交给系统分享
//   从备份恢复：选一个 .zip，校验后写回本机，提示重启 App 生效
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/backup_service.dart';
import '../services/storage.dart';
import 'common.dart';

/// 打开「备份与恢复」底部弹层。
Future<void> showBackupSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '备份与恢复',
              style: TextStyle(
                fontSize: AppType.page - 2,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '一个 .zip 带走角色卡、聊天记录、世界书、群聊与全部设置，换手机或重装后可以还原。',
              style: TextStyle(fontSize: AppType.caption, height: 1.45),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _exportBackup(ctx),
              icon: const Icon(Icons.archive_outlined, size: 18),
              label: const Text('导出备份 (.zip)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _importBackup(ctx),
              icon: const Icon(Icons.unarchive_outlined, size: 18),
              label: const Text('从备份恢复'),
            ),
            const SizedBox(height: 10),
            const Text(
              '备份里包含 API Key 等设置，请只保存到你信任的地方。'
              '恢复会覆盖同名的角色卡与聊天记录，不会删除备份里没有的数据。',
              style: TextStyle(fontSize: AppType.meta, height: 1.45),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _exportBackup(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  _showBusy(context, '正在打包备份…');
  try {
    final bytes = await BackupService.createBackup(
      docs: Storage.docsDir,
      prefs: AppSettings.exportPrefs(),
    );
    final file = await BackupService.writeTempZip(bytes);
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // 关掉 busy
    final ok = await _shareFile(file);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('当前设备不支持分享文件，备份已生成在缓存目录')),
      );
    }
  } catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(SnackBar(content: Text('导出备份失败：$e')));
  }
}

Future<bool> _shareFile(File file) async {
  try {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: 'LiteTavern 备份'),
    );
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _importBackup(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['zip'],
    withData: true,
  );
  final bytes = picked?.files.single.bytes;
  if (bytes == null) return;

  final BackupArchive archive;
  try {
    archive = BackupService.parseBackup(Uint8List.fromList(bytes));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return;
  }

  if (!context.mounted) return;
  // v0.38.0：恢复前先挑要恢复哪几类数据
  final options = await showDialog<BackupRestoreOptions>(
    context: context,
    builder: (ctx) => RestoreScopeDialog(archive: archive),
  );
  if (options == null) return;
  if (!context.mounted) return;

  _showBusy(context, '正在恢复备份…');
  try {
    final written = await BackupService.restoreBackup(
      archive,
      docs: Storage.docsDir,
      options: options,
    );
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          written == 0
              ? '设置已恢复；请重启 App 生效'
              : '已恢复 $written 个文件${options.settings ? '与设置' : ''}；请重启 App 让全部数据生效',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  } catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(SnackBar(content: Text('恢复失败：$e')));
  }
}

/// 恢复范围选择（v0.38.0）：勾哪几类就只恢复哪几类。
class RestoreScopeDialog extends StatefulWidget {
  const RestoreScopeDialog({super.key, required this.archive});

  final BackupArchive archive;

  @override
  State<RestoreScopeDialog> createState() => _RestoreScopeDialogState();
}

class _RestoreScopeDialogState extends State<RestoreScopeDialog> {
  BackupRestoreOptions _options = BackupRestoreOptions.all;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final archive = widget.archive;
    final manifest = archive.manifest;
    final nothing = !_options.any;

    Widget row({
      required String title,
      required int count,
      required bool value,
      required BackupRestoreOptions Function(bool) change,
    }) {
      return CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: (v) => setState(() => _options = change(v ?? false)),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        secondary: Text(
          '$count',
          style: TextStyle(fontSize: AppType.caption, color: scheme.onSurfaceVariant),
        ),
      );
    }

    return AlertDialog(
      title: const Text('恢复哪些内容？'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('备份时间：${_fmtTime(manifest.createdAt.toLocal())}'),
            Text(
              '来自版本：${manifest.appVersion.isEmpty ? '未知' : 'v${manifest.appVersion}'}',
            ),
            const SizedBox(height: 6),
            Text(
              '勾选要恢复的部分；没勾的不会被改动。同名的会被覆盖。',
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            row(
              title: '角色卡（含头像）',
              count: archive.fileCountIn('characters'),
              value: _options.characters,
              change: (v) => _options.copyWith(characters: v),
            ),
            row(
              title: '聊天记录',
              count: archive.fileCountIn('conversations'),
              value: _options.conversations,
              change: (v) => _options.copyWith(conversations: v),
            ),
            row(
              title: '世界书',
              count: archive.fileCountIn('worldbooks'),
              value: _options.worldBooks,
              change: (v) => _options.copyWith(worldBooks: v),
            ),
            row(
              title: '群聊',
              count: archive.fileCountIn('groups'),
              value: _options.groups,
              change: (v) => _options.copyWith(groups: v),
            ),
            row(
              title: '设置（含 API Key、预设）',
              count: archive.prefs.length,
              value: _options.settings,
              change: (v) => _options.copyWith(settings: v),
            ),
            const SizedBox(height: 4),
            Text(
              nothing ? '至少选一项' : '将恢复：${_options.summary(archive)}',
              style: TextStyle(
                fontSize: AppType.caption,
                color: nothing ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(
            () => _options = const BackupRestoreOptions(
              characters: false,
              conversations: false,
              worldBooks: false,
              groups: false,
              settings: false,
            ),
          ),
          child: const Text('全不选'),
        ),
        TextButton(
          onPressed: () => setState(() => _options = BackupRestoreOptions.all),
          child: const Text('全选'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              nothing ? null : () => Navigator.of(context).pop(_options),
          child: const Text('恢复'),
        ),
      ],
    );
  }
}

void _showBusy(BuildContext context, String text) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}

String _fmtTime(DateTime t) {
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${p2(t.month)}-${p2(t.day)} ${p2(t.hour)}:${p2(t.minute)}';
}
