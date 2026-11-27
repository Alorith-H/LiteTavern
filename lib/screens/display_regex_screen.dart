import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/display_regex.dart';
import '../services/storage.dart';
import '../widgets/common.dart';

/// 显示正则库（v0.29.0）：导入 SillyTavern 正则、开关、作用范围、替换前后对比。
///
/// 只改「看到的内容」，本地保存的原文不变；导出/备份拿到的还是原文。
class DisplayRegexScreen extends StatefulWidget {
  const DisplayRegexScreen({super.key});

  @override
  State<DisplayRegexScreen> createState() => _DisplayRegexScreenState();
}

class _DisplayRegexScreenState extends State<DisplayRegexScreen> {
  List<DisplayRegex> _regexes = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!AppSettings.initialized) await AppSettings.init();
    if (!mounted) return;
    setState(() => _regexes = DisplayRegexLibrary.sorted());
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _import() async {
    setState(() => _busy = true);
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
      final added = await DisplayRegexLibrary.importFromJson(
        utf8.decode(bytes, allowMalformed: true),
      );
      await _load();
      _toast(added == 0 ? '没有新增正则（同 id 已存在则覆盖）' : '已导入 $added 条正则');
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final created = await showDialog<DisplayRegex>(
      context: context,
      builder: (ctx) => _RegexEditDialog(
        initial: DisplayRegex(
          id: 'rx_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
          name: '',
          pattern: '',
        ),
      ),
    );
    if (created == null) return;
    await DisplayRegexLibrary.upsert(created);
    await _load();
    _toast('已添加「${created.name}」');
  }

  Future<void> _edit(DisplayRegex regex) async {
    final edited = await showDialog<DisplayRegex>(
      context: context,
      builder: (ctx) => _RegexEditDialog(initial: regex),
    );
    if (edited == null) return;
    await DisplayRegexLibrary.upsert(edited);
    await _load();
  }

  Future<void> _toggle(DisplayRegex regex, bool value) async {
    await DisplayRegexLibrary.upsert(regex.copyWith(enabled: value));
    await _load();
  }

  Future<void> _delete(DisplayRegex regex) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条正则？'),
        content: Text('「${regex.name}」删除后聊天内容会恢复成原文显示。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await DisplayRegexLibrary.remove(regex.id);
    await _load();
  }

  Future<void> _export() async {
    final data = jsonEncode([for (final r in _regexes) r.toJson()]);
    await Clipboard.setData(ClipboardData(text: data));
    _toast('已复制正则 JSON 到剪贴板');
  }

  void _openTest() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => _RegexTestSheet(regexes: _regexes),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('显示正则'),
        actions: [
          IconButton(
            tooltip: '导入 SillyTavern 正则（.json）',
            onPressed: _busy ? null : _import,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download_outlined),
          ),
          IconButton(
            tooltip: '导出 / 复制正则 JSON',
            onPressed: _regexes.isEmpty ? null : _export,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '试一下（替换前后对比）',
            onPressed: _regexes.isEmpty ? null : _openTest,
            icon: const Icon(Icons.science_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('新建正则'),
      ),
      body: _regexes.isEmpty ? _empty(scheme) : _list(scheme),
    );
  }

  Widget _empty(ColorScheme scheme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.find_replace, size: 56, color: scheme.primary),
              const SizedBox(height: 16),
              const Text('还没有显示正则', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                '显示正则只改「你看到的内容」，不会改本地保存的原文。\n'
                '可以从 SillyTavern 导出 .json 再导入，也可以手动新建一条。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('导入正则 .json'),
              ),
            ],
          ),
        ),
      );

  Widget _list(ColorScheme scheme) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        itemCount: _regexes.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final regex = _regexes[index];
          final broken = regex.hasError;
          return Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _edit(regex),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            regex.name,
                            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Switch(
                          value: regex.enabled,
                          onChanged: (v) => _toggle(regex, v),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '更多',
                          onSelected: (v) {
                            if (v == 'edit') _edit(regex);
                            if (v == 'delete') _delete(regex);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        _badge(scheme, regex.scope.label),
                        const SizedBox(width: 6),
                        if (regex.flags.isNotEmpty) _badge(scheme, regex.flags),
                        if (broken) ...[
                          const SizedBox(width: 6),
                          _badge(scheme, '正则有误', error: true),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      regex.pattern.isEmpty ? '（空正则）' : regex.pattern,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        fontFamily: 'monospace',
                        color: broken ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                    if (regex.replacement.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '→ ${regex.replacement}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: scheme.primary, height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      );

  Widget _badge(ColorScheme scheme, String text, {bool error = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: (error ? scheme.error : scheme.primary).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: error ? scheme.error : scheme.primary,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
}

/// 新建 / 编辑一条正则。
class _RegexEditDialog extends StatefulWidget {
  const _RegexEditDialog({required this.initial});

  final DisplayRegex initial;

  @override
  State<_RegexEditDialog> createState() => _RegexEditDialogState();
}

class _RegexEditDialogState extends State<_RegexEditDialog> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.initial.name);
  late final TextEditingController _patternCtrl =
      TextEditingController(text: widget.initial.pattern);
  late final TextEditingController _replacementCtrl =
      TextEditingController(text: widget.initial.replacement);
  late final TextEditingController _flagsCtrl =
      TextEditingController(text: widget.initial.flags);
  late RegexScope _scope = widget.initial.scope;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _replacementCtrl.dispose();
    _flagsCtrl.dispose();
    super.dispose();
  }

  DisplayRegex _build() => widget.initial.copyWith(
        name: _nameCtrl.text.trim().isEmpty ? '未命名正则' : _nameCtrl.text.trim(),
        pattern: _patternCtrl.text,
        flags: _flagsCtrl.text.replaceAll(RegExp(r'[^imsu]'), ''),
        replacement: _replacementCtrl.text,
        scope: _scope,
      );

  bool get _valid => _build().compile() != null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.initial.name.isEmpty ? '新建正则' : '编辑正则'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '例如：去掉多余空行',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _patternCtrl,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                labelText: '查找（正则）',
                hintText: r'例如 \n{3,}',
                helperText: _valid ? null : '这个正则写不通，检查一下括号和转义',
                helperStyle: TextStyle(color: scheme.error),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _replacementCtrl,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                labelText: '替换为',
                hintText: r'留空 = 删掉匹配内容；$1 表示第一个括号里的内容',
                helperText: r'支持 $1 / ${1} / $&',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _flagsCtrl,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: '标志（可选）',
                hintText: 'i m s u',
                helperText: 'i 忽略大小写 · m 多行 · s 让 . 匹配换行',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Text('作用范围', style: TextStyle(fontSize: AppType.caption, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            SegmentedButton<RegexScope>(
              showSelectedIcon: false,
              style: ButtonStyle(textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12.5))),
              segments: [
                for (final scope in RegexScope.values)
                  ButtonSegment(value: scope, label: Text(scope.label)),
              ],
              selected: {_scope},
              onSelectionChanged: (v) => setState(() => _scope = v.first),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, _build()) : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 「试一下」：输入一段文字，实时看应用全部正则前后的差别。
class _RegexTestSheet extends StatefulWidget {
  const _RegexTestSheet({required this.regexes});

  final List<DisplayRegex> regexes;

  @override
  State<_RegexTestSheet> createState() => _RegexTestSheetState();
}

class _RegexTestSheetState extends State<_RegexTestSheet> {
  final TextEditingController _inputCtrl = TextEditingController(
    text: '示例：\n\n\n\n这一行有多余空行。',
  );
  bool _isUser = true;

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  String _apply(String text) {
    var out = text;
    for (final regex in widget.regexes) {
      if (!regex.enabled) continue;
      if (!regex.matchesScope(isUser: _isUser)) continue;
      out = regex.apply(out);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final before = _inputCtrl.text;
    final after = _apply(before);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('试一下', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '下面是当前启用的 ${widget.regexes.where((r) => r.enabled).length} 条正则按顺序处理后的效果。',
                style: TextStyle(fontSize: AppType.caption, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: ButtonStyle(textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12.5))),
                segments: const [
                  ButtonSegment(value: true, label: Text('当作「你」的话')),
                  ButtonSegment(value: false, label: Text('当作角色的回复')),
                ],
                selected: {_isUser},
                onSelectionChanged: (v) => setState(() => _isUser = v.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _inputCtrl,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '输入一段文字',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 14),
              Text('替换后', style: TextStyle(fontSize: AppType.caption, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              Expanded(
                child: SingleChildScrollView(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SelectableText(
                      after.isEmpty ? '（空）' : after,
                      style: const TextStyle(fontSize: 14, height: 1.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                before == after ? '这段文字没有命中任何正则。' : '有变化：替换前后可以对照上面的输入。',
                style: TextStyle(fontSize: AppType.caption, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
