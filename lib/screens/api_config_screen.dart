import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/api_presets.dart';
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
                              : c.model.trim(),
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
  bool _obscureKey = true;
  bool _testing = false;
  String? _testOk; // 成功提示（模型名 + 耗时）

  final _api = ApiClient();

  bool get _isNew => widget.config == null;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _nameCtrl = TextEditingController(text: c?.name ?? '');
    _urlCtrl = TextEditingController(text: c?.baseUrl ?? '');
    _keyCtrl = TextEditingController(text: c?.key ?? '');
    _modelCtrl = TextEditingController(text: c?.model ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _api.dispose();
    super.dispose();
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

  void _save() {
    final name = _nameCtrl.text.trim().isEmpty
        ? '配置 ${AppSettings.apiConfigs.length + 1}'
        : _nameCtrl.text.trim();
    if (_isNew) {
      final cfg = ApiConfig(
        id: AppSettings.newConfigId(),
        name: name,
        baseUrl: _urlCtrl.text.trim(),
        key: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
      );
      AppSettings.apiConfigs = [...AppSettings.apiConfigs, cfg];
    } else {
      final updated = widget.config!.copyWith(
        name: name,
        baseUrl: _urlCtrl.text.trim(),
        key: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
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
                      _testOk = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
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
            TextField(
              controller: _modelCtrl,
              decoration: const InputDecoration(
                labelText: '模型名',
                hintText: 'deepseek-chat',
                helperText: '服务商的模型标识，照服务商文档填',
                isDense: true,
              ),
            ),
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
