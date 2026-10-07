import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage.dart';
import '../widgets/common.dart';

/// 生成参数预设管理页（v0.7.0）：
/// radio 选中即激活；编辑 / 删除 / 「另存为新预设」；至少保留 1 套。
/// 设置页滑条组编辑的就是激活预设，改动即时写入。
class GenPresetsScreen extends StatefulWidget {
  const GenPresetsScreen({super.key});

  @override
  State<GenPresetsScreen> createState() => _GenPresetsScreenState();
}

class _GenPresetsScreenState extends State<GenPresetsScreen> {
  late List<GenPreset> _presets;
  late String _activeId;

  @override
  void initState() {
    super.initState();
    _presets = AppSettings.genPresets;
    _activeId = AppSettings.activePreset.id;
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _presets = AppSettings.genPresets;
      _activeId = AppSettings.activePreset.id;
    });
  }

  void _select(GenPreset p) {
    AppSettings.activePresetId = p.id;
    _reload();
  }

  /// 简要摘要：`t0.8 · p1.0`（有上限时附带）。
  String _summary(GenPreset p) {
    final base =
        't${p.temperature.toStringAsFixed(1)} · p${p.topP.toStringAsFixed(1)}';
    return p.maxTokens > 0 ? '$base · 上限 ${p.maxTokens}' : base;
  }

  /// 另存为新预设：把当前激活预设（即设置页滑条当前值）存为新名称。
  Future<void> _saveAs() async {
    final ctrl = TextEditingController();
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('另存为新预设'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '新预设名称',
              errorText: error,
              isDense: true,
            ),
            onSubmitted: (_) {
              if (ctrl.text.trim().isEmpty) {
                set(() => error = '名称不能为空');
                return;
              }
              Navigator.pop(ctx, true);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (ctrl.text.trim().isEmpty) {
                  set(() => error = '名称不能为空');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (saved != true) return;
    final cur = AppSettings.activePreset;
    final next = GenPreset(
      id: AppSettings.newConfigId(),
      name: name,
      temperature: cur.temperature,
      topP: cur.topP,
      maxTokens: cur.maxTokens,
    );
    AppSettings.genPresets = [...AppSettings.genPresets, next];
    AppSettings.activePresetId = next.id; // 存完直接用它
    _reload();
  }

  /// 编辑预设（名称 + 三个参数）。
  Future<void> _edit(GenPreset p) async {
    final nameCtrl = TextEditingController(text: p.name);
    final tempCtrl = TextEditingController(
        text: p.temperature.toStringAsFixed(2));
    final topPCtrl = TextEditingController(text: p.topP.toStringAsFixed(2));
    final maxCtrl = TextEditingController(text: '${p.maxTokens}');
    String? error;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('编辑预设'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: '名称',
                    errorText: error,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tempCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: '随机度 temperature',
                    helperText: '0–2，越高越发散',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: topPCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: '采样范围 top-p',
                    helperText: '0–1',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: maxCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '单次回复长度上限',
                    helperText: '0 = 不限',
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) {
                  set(() => error = '名称不能为空');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    final name = nameCtrl.text.trim();
    final temp = (double.tryParse(tempCtrl.text) ?? p.temperature)
        .clamp(0.0, 2.0)
        .toDouble();
    final topP = (double.tryParse(topPCtrl.text) ?? p.topP)
        .clamp(0.0, 1.0)
        .toDouble();
    final maxT = int.tryParse(maxCtrl.text) ?? p.maxTokens;
    nameCtrl.dispose();
    tempCtrl.dispose();
    topPCtrl.dispose();
    maxCtrl.dispose();
    if (saved != true) return;

    final updated = p.copyWith(
      name: name,
      temperature: temp,
      topP: topP,
      maxTokens: maxT < 0 ? 0 : maxT,
    );
    AppSettings.genPresets = [
      for (final x in AppSettings.genPresets) x.id == p.id ? updated : x,
    ];
    _reload();
  }

  Future<void> _delete(GenPreset p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除预设'),
        content: Text('确定删除「${p.name}」吗？'),
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
    AppSettings.deletePreset(p.id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lastOne = _presets.length <= 1;
    return Scaffold(
      appBar: AppBar(title: const Text('生成参数预设')),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
        itemCount: _presets.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final p = _presets[i];
          return InkWell(
            onTap: () => _select(p),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  RadioGroup<String>(
                    groupValue: _activeId,
                    onChanged: (_) => _select(p),
                    child: Radio<String>(value: p.id),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: AppType.body,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _summary(p),
                          style: TextStyle(
                            fontSize: AppType.caption,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.edit_outlined, size: 22),
                      tooltip: '编辑',
                      onPressed: () => _edit(p),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.delete_outline,
                        size: 22,
                        color: lastOne ? scheme.outline : scheme.error,
                      ),
                      tooltip: lastOne ? '至少保留一套' : '删除',
                      onPressed: lastOne ? null : () => _delete(p),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saveAs,
        icon: const Icon(Icons.add_outlined, size: 20),
        label: const Text('另存为新预设'),
      ),
    );
  }
}
