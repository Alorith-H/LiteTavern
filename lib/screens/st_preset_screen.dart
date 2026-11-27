import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/sampling_params.dart';
import '../services/st_preset.dart';
import '../services/storage.dart';
import '../widgets/common.dart';

/// SillyTavern 预设兼容（v0.30.0，第一步）。
///
/// 能做的事：
/// * 导入 ST 导出的预设 JSON（文件 / 粘贴），解析采样参数与提示词顺序；
/// * 一键把采样参数写进「当前生成预设」（取值范围按本 App 收敛）；
/// * 可视化查看提示词顺序、启用状态、注入位置与深度，可开关、上移下移并保存。
///
/// 本轮**不会**把这些提示词注入到实际对话里——那属于下一步的「兼容模式」。
class StPresetScreen extends StatefulWidget {
  const StPresetScreen({super.key});

  @override
  State<StPresetScreen> createState() => _StPresetScreenState();
}

class _StPresetScreenState extends State<StPresetScreen> {
  StPresetSnapshot? _snapshot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!AppSettings.initialized) await AppSettings.init();
    if (!mounted) return;
    setState(() {
      _snapshot = StPresetSnapshot.tryParseStored(AppSettings.stPresetJson);
    });
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _persist(StPresetSnapshot snapshot) async {
    setState(() => _snapshot = snapshot);
    await AppSettings.setStPresetJson(snapshot.toJsonString());
  }

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final bytes = result.files.first.bytes;
      if (bytes == null) {
        _toast('读不到文件内容，试试重新选一次');
        return;
      }
      await _accept(utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  Future<void> _importFromPaste() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴 ST 预设 JSON'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            minLines: 6,
            maxLines: 12,
            decoration: const InputDecoration(
              hintText: '在 SillyTavern 里导出预设，把整份 JSON 粘进来',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('解析'),
          ),
        ],
      ),
    );
    if (raw == null) return;
    await _accept(raw);
  }

  Future<void> _accept(String raw) async {
    try {
      final snapshot = StPresetParser.parse(raw);
      await _persist(snapshot);
      _toast('已解析「${snapshot.name}」：${snapshot.prompts.length} 条提示词');
    } on FormatException catch (e) {
      _toast('解析失败：${e.message}');
    } catch (e) {
      _toast('解析失败：$e');
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除导入的预设？'),
        content: const Text('只清掉这份展示用的预设，聊天和生成参数都不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppSettings.setStPresetJson(null);
    if (!mounted) return;
    setState(() => _snapshot = null);
    _toast('已清除');
  }

  Future<void> _applySampling() async {
    final s = _snapshot;
    if (s == null) return;
    final rows = s.samplingRows;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('把这些采样参数套到当前生成预设？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('会按本 App 的取值范围收敛，数值超出时会自动夹到边界：'),
              const SizedBox(height: 8),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('· ${row.$1}：${row.$2}',
                      style: TextStyle(
                          fontSize: AppType.caption,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                ),
              const SizedBox(height: 8),
              const Text('只改「设置 → 生成参数」里当前这套预设，不改你的角色卡与聊天。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('套用'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    if (s.temperature != null) {
      AppSettings.temperature = s.temperature!.clamp(0.0, 2.0);
    }
    if (s.topP != null) AppSettings.topP = s.topP!.clamp(0.0, 1.0);
    if (s.maxTokens != null) {
      AppSettings.maxTokens = s.maxTokens!.clamp(0, 200000);
    }
    if (s.frequencyPenalty != null) {
      AppSettings.frequencyPenalty = s.frequencyPenalty!.clamp(0.0, 2.0);
    }
    if (s.presencePenalty != null) {
      AppSettings.presencePenalty = s.presencePenalty!.clamp(0.0, 2.0);
    }
    if (s.repetitionPenalty != null) {
      AppSettings.repetitionPenalty = s.repetitionPenalty!.clamp(1.0, 2.0);
    }
    if (s.topK != null) AppSettings.topK = s.topK!.clamp(0, 200);
    if (s.minP != null) AppSettings.minP = s.minP!.clamp(0.0, 0.5);
    if (s.seed != null) AppSettings.seed = s.seed;
    if (s.stop.isNotEmpty) {
      AppSettings.stop = SamplingParams.normalizeStop(s.stop);
    }
    _toast('采样参数已套到当前生成预设');
  }

  Future<void> _toggle(int index, bool enabled) async {
    final s = _snapshot;
    if (s == null) return;
    final prompts = [...s.prompts];
    prompts[index] = prompts[index].copyWith(enabled: enabled);
    await _persist(s.copyWith(prompts: prompts));
  }

  Future<void> _move(int index, int delta) async {
    final s = _snapshot;
    if (s == null) return;
    final target = index + delta;
    if (target < 0 || target >= s.prompts.length) return;
    final prompts = [...s.prompts];
    final item = prompts.removeAt(index);
    prompts.insert(target, item);
    await _persist(s.copyWith(prompts: prompts));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SillyTavern 预设'),
        actions: [
          IconButton(
            tooltip: '从文件导入（.json）',
            onPressed: _importFromFile,
            icon: const Icon(Icons.file_open_outlined),
          ),
          IconButton(
            tooltip: '粘贴 JSON',
            onPressed: _importFromPaste,
            icon: const Icon(Icons.content_paste),
          ),
          if (snapshot != null)
            IconButton(
              tooltip: '清除',
              onPressed: _clear,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: snapshot == null
          ? _buildEmpty(scheme)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _buildSummary(scheme, snapshot),
                if (snapshot.hasSampling) ...[
                  const SizedBox(height: 12),
                  _buildSampling(scheme, snapshot),
                ],
                if (snapshot.warnings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildWarnings(scheme, snapshot),
                ],
                const SizedBox(height: 8),
                const SectionHeader('提示词顺序'),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '共 ${snapshot.prompts.length} 条 · 启用 ${snapshot.enabledCount} 条'
                    '${snapshot.markerCount > 0 ? ' · 含 ${snapshot.markerCount} 个占位' : ''}。'
                    '本轮只做查看与排序，不会改动实际发给模型的内容。',
                    style: TextStyle(
                        fontSize: AppType.caption,
                        height: 1.5,
                        color: scheme.onSurfaceVariant),
                  ),
                ),
                for (var i = 0; i < snapshot.prompts.length; i++)
                  _buildPromptRow(context, scheme, snapshot, i),
              ],
            ),
    );
  }

  Widget _buildEmpty(ColorScheme scheme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            const Text('还没有导入 SillyTavern 预设',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              '在 SillyTavern 里把预设导出成 .json，然后从文件导入，或直接把整份 JSON 粘进来。\n'
              '导入后可以看到它的采样参数和提示词顺序，采样参数能一键套用到当前生成预设。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: AppType.caption,
                  height: 1.6,
                  color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _importFromFile,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('从文件导入 .json'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _importFromPaste,
              icon: const Icon(Icons.content_paste),
              label: const Text('粘贴 JSON'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummary(ColorScheme scheme, StPresetSnapshot s) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.name,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              '采样参数 ${s.samplingCount} 项 · 提示词 ${s.prompts.length} 条'
              '（启用 ${s.enabledCount} 条）',
              style: TextStyle(
                  fontSize: AppType.caption, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSampling(ColorScheme scheme, StPresetSnapshot s) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('采样参数',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final row in s.samplingRows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text(row.$1,
                          style: TextStyle(
                              fontSize: AppType.caption,
                              color: scheme.onSurfaceVariant)),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(row.$2,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              fontSize: AppType.caption,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: _applySampling,
                icon: const Icon(Icons.playlist_add_check, size: 18),
                label: const Text('套用到当前生成预设'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWarnings(ColorScheme scheme, StPresetSnapshot s) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              const Text('导入说明',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          for (final w in s.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text('· $w',
                  style: TextStyle(
                      fontSize: AppType.caption,
                      height: 1.45,
                      color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }

  Widget _buildPromptRow(
    BuildContext context,
    ColorScheme scheme,
    StPresetSnapshot s,
    int index,
  ) {
    final item = s.prompts[index];
    final marker = item.isMarker;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.only(left: 12, right: 4),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: SizedBox(
            width: 26,
            child: Text('${index + 1}',
                style: TextStyle(
                    fontSize: AppType.caption, color: scheme.onSurfaceVariant)),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: marker ? FontWeight.w500 : FontWeight.w600,
                    color: item.enabled ? null : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _chip(scheme, item.roleLabel),
              if (marker) _chip(scheme, '占位'),
              if (item.injectsInChat) _chip(scheme, '深度 ${item.injectionDepth ?? 0}'),
            ],
          ),
          subtitle: Text(
            item.preview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: AppType.caption, color: scheme.onSurfaceVariant),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '上移',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                onPressed: index == 0 ? null : () => _move(index, -1),
              ),
              IconButton(
                tooltip: '下移',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                onPressed:
                    index == s.prompts.length - 1 ? null : () => _move(index, 1),
              ),
              Switch(
                value: item.enabled,
                onChanged: marker ? null : (v) => _toggle(index, v),
              ),
            ],
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                item.content.isEmpty ? '（这条没有正文）' : item.content,
                style: TextStyle(
                    fontSize: AppType.caption,
                    height: 1.55,
                    color: scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(ColorScheme scheme, String label) => Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 10.5, color: scheme.primary)),
      );
}
