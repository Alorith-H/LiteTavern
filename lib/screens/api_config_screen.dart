import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/api_presets.dart';
import '../services/external_links.dart';
import '../services/storage.dart';
import '../widgets/common.dart';

/// API 配置管理页（v0.7.0 多配置）：
/// radio 选中即激活；编辑 / 新建 / 删除；至少保留 1 套；
/// 删除激活项自动激活第一套。
class ApiConfigsScreen extends StatefulWidget {
  const ApiConfigsScreen({super.key});

  @override
  State<ApiConfigsScreen> createState() => _ApiConfigsScreenState();
}

class _ApiConfigsScreenState extends State<ApiConfigsScreen> {
  late List<ApiConfig> _configs;
  late String _activeId;

  @override
  void initState() {
    super.initState();
    _configs = AppSettings.apiConfigs;
    _activeId = AppSettings.activeApiConfig.id;
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _configs = AppSettings.apiConfigs;
      _activeId = AppSettings.activeApiConfig.id;
    });
  }

  void _select(ApiConfig c) {
    AppSettings.activeApiConfigId = c.id;
    _reload();
  }

  Future<void> _edit(ApiConfig? config) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ApiConfigEditScreen(config: config)),
    );
    _reload();
  }

  Future<void> _delete(ApiConfig c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除「${c.name}」吗？'),
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
    AppSettings.deleteApiConfig(c.id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lastOne = _configs.length <= 1;
    return Scaffold(
      appBar: AppBar(title: const Text('模型服务配置')),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _configs.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final c = _configs[i];
          return InkWell(
            onTap: () => _select(c),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  RadioGroup<String>(
                    groupValue: _activeId,
                    onChanged: (_) => _select(c),
                    child: Radio<String>(value: c.id),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: AppType.body,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          c.model.trim().isEmpty
                              ? (c.baseUrl.trim().isEmpty
                                  ? '未配置'
                                  : c.baseUrl.trim())
                              : '${c.model.trim()} · 上下文 '
                                  '${formatContextWindow(c.contextWindow > 0 ? c.contextWindow : contextWindowForModel(c.model))}'
                                  '${c.contextWindow > 0 ? '' : '（自动）'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                      onPressed: () => _edit(c),
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
                      onPressed: lastOne ? null : () => _delete(c),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add_outlined, size: 20),
        label: const Text('新建配置'),
      ),
    );
  }
}

/// 编辑 / 新建一套 API 配置：
/// 名称、接口地址、API Key（密文 + 眼睛）、模型名 +
/// 服务商预设 chips（只填地址与模型，不动 Key）+ 测试连接。
class ApiConfigEditScreen extends StatefulWidget {
  /// null = 新建。
  final ApiConfig? config;

  const ApiConfigEditScreen({super.key, this.config});

  @override
  State<ApiConfigEditScreen> createState() => _ApiConfigEditScreenState();
}

class _ApiConfigEditScreenState extends State<ApiConfigEditScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _ctxCtrl;
  bool _obscureKey = true;
  bool _testing = false;
  bool _loadingModels = false;

  /// 从 /models 拿到的自报上下文长度（v0.21.1）。
  int? _reportedContext;
  String? _testOk; // 成功提示（模型名 + 耗时）

  final _api = ApiClient();

  bool get _isNew => widget.config == null;

  /// 当前地址对应的服务商预设（决定「去官网获取 Key」跳到哪）。
  ApiPreset? get _currentPreset => presetForBaseUrl(_urlCtrl.text);

  void _openKeyHelp() {
    final preset = _currentPreset;
    if (preset == null) {
      showApiKeyProviderPicker(context);
      return;
    }
    showApiKeyHelp(
      context,
      providerLabel: preset.label,
      keyUrl: preset.keyUrl,
      siteUrl: preset.siteUrl,
      docsUrl: preset.docsUrl,
      note: preset.note,
    );
  }

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _nameCtrl = TextEditingController(text: c?.name ?? '');
    _urlCtrl = TextEditingController(text: c?.baseUrl ?? '');
    _keyCtrl = TextEditingController(text: c?.key ?? '');
    _modelCtrl = TextEditingController(text: c?.model ?? '');
    final ctx = c?.contextWindow ?? 0;
    _ctxCtrl = TextEditingController(text: ctx > 0 ? '$ctx' : '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _ctxCtrl.dispose();
    _api.dispose();
    super.dispose();
  }

  /// 表单里填的上下文长度：空 / 0 = 自动（按模型推断）。
  int get _ctxValue {
    final v = int.tryParse(_ctxCtrl.text.trim()) ?? 0;
    return v <= 0 ? 0 : v;
  }

  /// 当前「自动」会算出多少（展示用）。
  int get _autoCtx =>
      _reportedContext ?? contextWindowForModel(_modelCtrl.text);

  /// 选模型后，如果上下文还停在「自动」，就跟着这个模型刷新提示。
  void _onModelChanged() {
    if (_reportedContext != null) {
      setState(() => _reportedContext = null);
    } else if (_ctxValue == 0) {
      setState(() {});
    }
  }

  /// 拉取这个接口的模型列表，点选一个填进「模型名」。
  Future<void> _pickModel() async {
    final url = _urlCtrl.text.trim();
    final key = _keyCtrl.text.trim();
    if (url.isEmpty) {
      _toast('请先填写接口地址');
      return;
    }
    setState(() => _loadingModels = true);
    try {
      final models = await _api.fetchModelInfos(baseUrl: url, apiKey: key);
      if (!mounted) return;
      final picked = await showModalBottomSheet<RemoteModel>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => _ModelPickerSheet(
          models: models,
          current: _modelCtrl.text.trim(),
        ),
      );
      if (picked == null || !mounted) return;
      setState(() {
        _modelCtrl.text = picked.id;
        _testOk = null;
        _reportedContext = picked.contextWindow;
        // 服务商自报了窗口、且用户没手填上下文 → 直接按接口报告填入（最准）
        final reported = picked.contextWindow;
        if (_ctxValue == 0 && reported != null && reported > 0) {
          _ctxCtrl.text = '$reported';
        } else if (_ctxValue == 0) {
          _ctxCtrl.text = '';
        }
      });
    } catch (e) {
      if (mounted) _toast('$e');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  /// 测表单里的值（未保存也生效）：成功显示返回的模型名与耗时。
  Future<void> _testConnection() async {
    final url = _urlCtrl.text.trim();
    final key = _keyCtrl.text.trim();
    if (url.isEmpty || key.isEmpty) {
      _toast('请先填写接口地址和 API Key');
      return;
    }
    setState(() {
      _testing = true;
      _testOk = null;
    });
    final sw = Stopwatch()..start();
    try {
      final model = await _api.testConnection(
        baseUrl: url,
        apiKey: key,
        model: _modelCtrl.text.trim(),
      );
      sw.stop();
      if (!mounted) return;
      setState(() => _testOk = '连接成功 · 模型：$model · 耗时 ${sw.elapsedMilliseconds} ms');
    } catch (e) {
      if (!mounted) return;
      _toast('连接失败：$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _save() {    final name = _nameCtrl.text.trim().isEmpty
        ? '配置 ${AppSettings.apiConfigs.length + 1}'
        : _nameCtrl.text.trim();
    if (_isNew) {
      final cfg = ApiConfig(
        id: AppSettings.newConfigId(),
        name: name,
        baseUrl: _urlCtrl.text.trim(),
        key: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        contextWindow: _ctxValue,
      );
      AppSettings.apiConfigs = [...AppSettings.apiConfigs, cfg];
    } else {
      final updated = widget.config!.copyWith(
        name: name,
        baseUrl: _urlCtrl.text.trim(),
        key: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        contextWindow: _ctxValue,
      );
      AppSettings.apiConfigs = [
        for (final c in AppSettings.apiConfigs)
          c.id == updated.id ? updated : c,
      ];
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建配置' : '编辑配置'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('保存')),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '配置名称',
                hintText: '配置 1',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in kApiPresets)
                  ActionChip(
                    label: Text(p.label),
                    // 只填地址与模型，不清空已填 Key
                    onPressed: () => setState(() {
                      _urlCtrl.text = p.baseUrl;
                      _modelCtrl.text = p.model;
                      _ctxCtrl.text = '${p.contextWindow}';
                      _testOk = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _modelCtrl,
                    onChanged: (_) => _onModelChanged(),
                    decoration: const InputDecoration(
                      labelText: '模型名',
                      hintText: 'deepseek-chat',
                      helperText: '照服务商文档填，或点右边「获取模型列表」挑',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _loadingModels || _urlCtrl.text.trim().isEmpty
                      ? null
                      : _pickModel,
                  child: _loadingModels
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('获取模型列表'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctxCtrl,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '上下文长度（token）',
                hintText: '留空 = 按模型自动（${formatContextWindow(_autoCtx)}）',
                helperText: _ctxValue == 0
                    ? (_reportedContext != null
                        ? '按接口报告的窗口：${formatContextWindow(_autoCtx)}；'
                            '超出会自动压缩早期对话'
                        : '按模型自动：${formatContextWindow(_autoCtx)}；'
                            '超出会自动压缩早期对话')
                    : '手填的值会覆盖自动判断',
                isDense: true,
                suffixIcon: _ctxValue == 0
                    ? null
                    : IconButton(
                        tooltip: '改回按模型自动',
                        icon: const Icon(Icons.autorenew, size: 20),
                        onPressed: () => setState(() => _ctxCtrl.text = ''),
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _openKeyHelp,
                  icon: const Icon(Icons.key_outlined, size: 18),
                  label: const Text('去官网获取 API Key'),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                if (_currentPreset != null) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      _currentPreset!.note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.meta,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '接口地址',
                hintText: 'https://api.deepseek.com/v1',
                helperText: '服务商提供的接口地址',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _keyCtrl,
              obscureText: _obscureKey,
              decoration: InputDecoration(
                labelText: 'API Key',
                helperText: '只保存在本机',
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureKey
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 22,
                  ),
                  onPressed: () =>
                      setState(() => _obscureKey = !_obscureKey),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const SizedBox(height: 20),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering_outlined, size: 20),
                  label: Text(_testing ? '测试中…' : '测试连接'),
                ),
                if (_testOk != null) ...[
                  const SizedBox(width: 12),
                  Icon(Icons.check_circle_outlined, size: 18, color: scheme.primary),
                ],
              ],
            ),
            if (_testOk != null) ...[
              const SizedBox(height: 8),
              Text(
                _testOk!,
                style: TextStyle(fontSize: AppType.caption, color: scheme.primary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 模型列表选择弹层（v0.20.0）：从 `GET /models` 拉回来的模型里挑一个。
class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({required this.models, required this.current});

  final List<RemoteModel> models;
  final String current;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final _searchCtrl = TextEditingController();
  late List<RemoteModel> _filtered = widget.models;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearch(String raw) {
    final q = raw.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? widget.models
          : widget.models
              .where((m) => m.id.toLowerCase().contains(q))
              .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = MediaQuery.of(context).size.height;
    return SafeArea(
      child: SizedBox(
        height: height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择模型（${widget.models.length}）',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: _onSearch,
                decoration: const InputDecoration(
                  hintText: '搜索模型名',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: _filtered.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的模型',
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _filtered.length,
                      itemBuilder: (ctx, i) {
                        final model = _filtered[i];
                        final name = model.id;
                        final selected = name == widget.current;
                        final ctx = model.contextWindow;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: ctx == null || ctx <= 0
                              ? null
                              : Text(
                                  '上下文 ${formatContextWindow(ctx)}',
                                  style: TextStyle(
                                    fontSize: AppType.meta,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                          trailing: selected
                              ? Icon(Icons.check, size: 18, color: scheme.primary)
                              : null,
                          onTap: () => Navigator.of(context).pop(model),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
