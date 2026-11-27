import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app_info.dart';
import '../services/apk_installer.dart';
import '../services/external_links.dart';
import '../services/storage.dart';
import '../services/updater.dart';
import 'common.dart';

/// 手动检查更新（设置 → 帮助与关于 → 检查更新）。
Future<void> checkUpdatesManually(
  BuildContext context, {
  UpdateService? service,
  ApkInstaller? installer,
}) async {
  final installed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => UpdateDialog(
      service: service ?? UpdateService(),
      installer: installer ?? ApkInstaller(),
      autoCheck: true,
    ),
  );
  if (installed == true && context.mounted) {
    _toast(context, '已打开系统安装界面：在弹窗里点「安装」即可覆盖升级');
  }
}

/// 启动时静默检查（HomeScreen 调用）：一天最多一次，有新版才弹窗。
Future<void> maybeAutoCheckUpdates(
  BuildContext context, {
  UpdateService? service,
  ApkInstaller? installer,
}) async {
  if (!AppSettings.autoCheckUpdates) return;
  final now = DateTime.now().millisecondsSinceEpoch;
  const dayMs = 24 * 60 * 60 * 1000; // 24 小时
  if (now - AppSettings.lastUpdateCheckMs < dayMs) return;
  // 先记时间：即使这次失败，也别每次启动都去请求
  AppSettings.lastUpdateCheckMs = now;

  final svc = service ?? UpdateService();
  UpdateInfo? info;
  try {
    info = await svc.checkForUpdate();
  } on UpdateCheckException {
    return; // 静默失败
  }
  if (info == null || !context.mounted) return;
  if (AppSettings.skippedUpdateVersion == info.version) return;

  final installed = await showDialog<bool>(
    context: context,
    builder: (_) => UpdateDialog(
      service: svc,
      installer: installer ?? ApkInstaller(),
      initialInfo: info,
    ),
  );
  if (installed == true && context.mounted) {
    _toast(context, '已打开系统安装界面：在弹窗里点「安装」即可覆盖升级');
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

enum _UpdatePhase { checking, upToDate, failed, available, downloading, installing }

/// 检查更新 / 下载 / 安装的对话框（v0.23.0）。
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.service,
    required this.installer,
    this.autoCheck = false,
    this.initialInfo,
  });

  final UpdateService service;
  final ApkInstaller installer;

  /// true：打开即检查；false 且 initialInfo 为空则显示「已是最新」。
  final bool autoCheck;

  /// 已经查到的更新（静默检查路径）。
  final UpdateInfo? initialInfo;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  late _UpdatePhase _phase;
  UpdateInfo? _info;
  String? _error;
  int _received = 0;
  int? _total;
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    final info = widget.initialInfo;
    if (info != null) {
      _info = info;
      _phase = _UpdatePhase.available;
    } else if (widget.autoCheck) {
      _phase = _UpdatePhase.checking;
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    } else {
      _phase = _UpdatePhase.upToDate;
    }
  }

  Future<void> _check() async {
    setState(() {
      _phase = _UpdatePhase.checking;
      _error = null;
    });
    try {
      final info = await widget.service.checkForUpdate();
      if (!mounted) return;
      AppSettings.lastUpdateCheckMs = DateTime.now().millisecondsSinceEpoch;
      if (info == null) {
        setState(() => _phase = _UpdatePhase.upToDate);
      } else {
        setState(() {
          _info = info;
          _phase = _UpdatePhase.available;
        });
      }
    } on UpdateCheckException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _phase = _UpdatePhase.failed;
      });
    }
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null) return;
    setState(() {
      _phase = _UpdatePhase.downloading;
      _received = 0;
      _total = info.apkSize > 0 ? info.apkSize : null;
      _cancel = false;
      _error = null;
    });
    try {
      final tmp = await getTemporaryDirectory();
      final file = await widget.service.downloadApk(
        info,
        dir: Directory('${tmp.path}${Platform.pathSeparator}updates'),
        onProgress: (received, total) {
          if (!mounted || _cancel) return;
          setState(() {
            _received = received;
            _total = total ?? _total;
          });
        },
        isCancelled: () => _cancel,
      );
      if (!mounted) return;
      setState(() => _phase = _UpdatePhase.installing);
      await widget.installer.install(file);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on UpdateCheckException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdatePhase.available;
        _error = e.message == '已取消下载' ? null : e.message;
      });
    } on ApkInstallException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdatePhase.available;
        _error = '${e.message}\n如果没弹出安装界面，请到 系统设置 → 应用 → 安装未知应用 里允许 LiteTavern';
      });
    }
  }

  void _later() {
    final info = _info;
    if (info != null) AppSettings.skippedUpdateVersion = info.version;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: _content(scheme),
          ),
        ),
      ),
      actions: _actions(scheme),
    );
  }

  String get _title => switch (_phase) {
        _UpdatePhase.checking => '检查更新',
        _UpdatePhase.upToDate => '已是最新版本',
        _UpdatePhase.failed => '检查更新失败',
        _UpdatePhase.available => '发现新版本 v${_info?.version ?? ''}',
        _UpdatePhase.downloading => '正在下载更新',
        _UpdatePhase.installing => '正在打开安装界面',
      };

  List<Widget> _content(ColorScheme scheme) {
    final caption = TextStyle(fontSize: AppType.caption, color: scheme.onSurfaceVariant);
    final body = TextStyle(fontSize: AppType.body, height: 1.45);
    switch (_phase) {
      case _UpdatePhase.checking:
        return const [
          SizedBox(height: 8),
          Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5))),
          SizedBox(height: 14),
          Text('正在检查 GitHub 上的最新版本…', style: TextStyle(fontSize: AppType.body)),
        ];
      case _UpdatePhase.upToDate:
        return [
          Text('当前 v$kAppVersion 已经是最新版本。', style: body),
          const SizedBox(height: 8),
          Text('有新版本时这里会提示，也可以随时回来手动检查。', style: caption),
        ];
      case _UpdatePhase.failed:
        return [
          Text(_error ?? '检查更新失败', style: body.copyWith(color: scheme.error)),
          const SizedBox(height: 8),
          Text('请检查手机网络后重试；如果一直失败，也可以直接去 Release 页面看。', style: caption),
        ];
      case _UpdatePhase.available:
        final info = _info!;
        final notes = info.notes.trim();
        return [
          Row(
            children: [
              Expanded(
                child: Text('当前 v$kAppVersion → 新版 v${info.version}', style: body),
              ),
              if (info.apkSize > 0) Text(info.apkSizeLabel, style: caption),
            ],
          ),
          const SizedBox(height: 10),
          if (notes.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 190),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: Text(notes, style: TextStyle(fontSize: AppType.caption, height: 1.5)),
              ),
            ),
          const SizedBox(height: 10),
          Text(
            info.hasApk
                ? '下载后在系统弹窗里点「安装」即可覆盖升级，聊天记录和角色卡都会保留。'
                : '这个版本没有附带 APK，去 Release 页面查看。',
            style: caption,
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(fontSize: AppType.caption, color: scheme.error)),
          ],
        ];
      case _UpdatePhase.downloading:
        final total = _total;
        final progress = total != null && total > 0 ? (_received / total).clamp(0.0, 1.0) : null;
        return [
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress, minHeight: 6, borderRadius: BorderRadius.circular(4)),
          const SizedBox(height: 12),
          Text(
            total != null && total > 0
                ? '${formatBytes(_received)} / ${formatBytes(total)}（${(progress! * 100).toStringAsFixed(0)}%）'
                : '已下载 ${formatBytes(_received)}',
            style: body,
          ),
          const SizedBox(height: 8),
          Text('下载完成后会自动打开系统安装界面。', style: caption),
        ];
      case _UpdatePhase.installing:
        return const [
          SizedBox(height: 8),
          LinearProgressIndicator(minHeight: 6),
          SizedBox(height: 12),
          Text('正在打开系统安装界面，请稍候…', style: TextStyle(fontSize: AppType.body)),
        ];
    }
  }

  List<Widget> _actions(ColorScheme scheme) {
    switch (_phase) {
      case _UpdatePhase.checking:
        return [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
        ];
      case _UpdatePhase.upToDate:
        return [TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('好'))];
      case _UpdatePhase.failed:
        return [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('关闭')),
          TextButton(
            onPressed: () => openExternalLink(
              context,
              'https://github.com/Alorith-H/LiteTavern/releases',
              title: 'LiteTavern Releases',
            ),
            child: const Text('打开 Release 页面'),
          ),
          FilledButton(onPressed: _check, child: const Text('重试')),
        ];
      case _UpdatePhase.available:
        return [
          TextButton(onPressed: _later, child: const Text('稍后')),
          if (!_info!.hasApk)
            FilledButton(
              onPressed: () => openExternalLink(context, _info!.pageUrl.isEmpty ? 'https://github.com/Alorith-H/LiteTavern/releases' : _info!.pageUrl, title: 'LiteTavern Release'),
              child: const Text('打开页面'),
            )
          else
            FilledButton.icon(
              onPressed: _download,
              icon: const Icon(Icons.system_update_alt, size: 18),
              label: const Text('下载并安装'),
            ),
        ];
      case _UpdatePhase.downloading:
        return [
          TextButton(
            onPressed: () => setState(() => _cancel = true),
            child: const Text('取消下载'),
          ),
        ];
      case _UpdatePhase.installing:
        return const [];
    }
  }
}
