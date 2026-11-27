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

  final manifest = archive.manifest;
  if (!context.mounted) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('用这份备份恢复？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('备份时间：${_fmtTime(manifest.createdAt.toLocal())}'),
          Text('来自版本：${manifest.appVersion.isEmpty ? '未知' : 'v${manifest.appVersion}'}'),
          Text('包含：${manifest.fileCount} 个文件、${archive.prefs.length} 项设置'),
          const SizedBox(height: 10),
          const Text(
            '同名的角色卡、聊天记录和设置会被覆盖；恢复后需要重启 App 才能全部生效。',
            style: TextStyle(fontSize: AppType.caption, height: 1.45),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('恢复'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  if (!context.mounted) return;

  _showBusy(context, '正在恢复备份…');
  try {
    final written = await BackupService.restoreBackup(
      archive,
      docs: Storage.docsDir,
    );
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text('已恢复 $written 个文件；请重启 App 让全部数据生效'),
        duration: const Duration(seconds: 6),
      ),
    );
  } catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(SnackBar(content: Text('恢复失败：$e')));
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
