import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../models/world_info.dart';
import '../services/api_client.dart';
import '../services/storage.dart';
import 'onboarding_screen.dart';

/// 设置页。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _maxTokensCtrl;
  late double _temperature;
  late double _topP;
  bool _obscureKey = true;
  bool _testing = false;

  final _api = ApiClient();
  List<(String, WorldInfo)> _worldBooks = [];

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: AppSettings.baseUrl);
    _keyCtrl = TextEditingController(text: AppSettings.apiKey);
    _modelCtrl = TextEditingController(text: AppSettings.model);
    _nameCtrl = TextEditingController(text: AppSettings.userName);
    _maxTokensCtrl = TextEditingController(text: '${AppSettings.maxTokens}');
    _temperature = AppSettings.temperature.clamp(0.0, 2.0).toDouble();
    _topP = AppSettings.topP.clamp(0.0, 1.0).toDouble();
    _loadWorldBooks();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _nameCtrl.dispose();
    _maxTokensCtrl.dispose();
    _api.dispose();
    super.dispose();
  }

  void _saveApi() {
    AppSettings.baseUrl = _urlCtrl.text;
    AppSettings.apiKey = _keyCtrl.text;
    AppSettings.model = _modelCtrl.text;
  }

  Future<void> _testConnection() async {
    _saveApi();
    if (!AppSettings.apiConfigured) {
      _toast('请先填写 Base URL 和 API Key');
      return;
    }
    setState(() => _testing = true);
    try {
      final model = await _api.testConnection(
        baseUrl: AppSettings.baseUrl,
        apiKey: AppSettings.apiKey,
        model: AppSettings.model,
      );
      if (!mounted) return;
      _toast('连接成功，模型：$model');
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

  // ---------------------------------------------------------- 世界书 --

  Future<void> _loadWorldBooks() async {
    final list = await Storage.loadWorldBooks();
    if (mounted) setState(() => _worldBooks = list);
  }

  Future<void> _importWorldBook() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) throw const FormatException('读取失败');
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('格式错误');
      }
      final book = WorldInfo.fromJson(decoded);
      if (book.entries.isEmpty) {
        throw const FormatException('没有条目');
      }
      final id = await Storage.saveWorldBook(book);
      // 新导入的世界书默认挂载启用
      final mountedIds = List.of(AppSettings.mountedWorldBookIds)..add(id);
      AppSettings.mountedWorldBookIds = mountedIds;
      await _loadWorldBooks();
      if (!mounted) return;
      _toast('已导入世界书「${book.name.isEmpty ? file.name : book.name}」（${book.entries.length} 条）');
    } catch (_) {
      if (!mounted) return;
      _toast('这不是有效的世界书文件');
    }
  }

  void _toggleWorldBook(String id, bool mountedOn) {
    final ids = List.of(AppSettings.mountedWorldBookIds);
    if (mountedOn) {
      if (!ids.contains(id)) ids.add(id);
    } else {
      ids.remove(id);
    }
    AppSettings.mountedWorldBookIds = ids;
    setState(() {});
  }

  Future<void> _deleteWorldBook(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除世界书'),
        content: const Text('确定删除这个世界书吗？'),
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
    await Storage.deleteWorldBook(id);
    final ids = List.of(AppSettings.mountedWorldBookIds)..remove(id);
    AppSettings.mountedWorldBookIds = ids;
    await _loadWorldBooks();
  }

  // ---------------------------------------------------------- 主题 --

  void _setTheme(String mode) {
    AppSettings.themeMode = mode;
    themeModeNotifier.value = switch (mode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    setState(() {});
  }

  // ------------------------------------------------------------ 构建 --

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _groupHeader('模型服务'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in kApiPresets)
                        ActionChip(
                          label: Text(p.label),
                          onPressed: () => setState(() {
                            _urlCtrl.text = p.baseUrl;
                            _modelCtrl.text = p.model;
                            _saveApi();
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'https://api.deepseek.com/v1',
                    ),
                    keyboardType: TextInputType.url,
                    onChanged: (_) => _saveApi(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _keyCtrl,
                    obscureText: _obscureKey,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      suffixIcon: IconButton(
                        icon: Icon(_obscureKey
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () =>
                            setState(() => _obscureKey = !_obscureKey),
                      ),
                    ),
                    onChanged: (_) => _saveApi(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _modelCtrl,
                    decoration: const InputDecoration(
                      labelText: '模型名',
                      hintText: 'deepseek-chat',
                    ),
                    onChanged: (_) => _saveApi(),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering),
                    label: Text(_testing ? '测试中…' : '测试连接'),
                  ),
                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  Text(
                    '生成参数',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('温度 temperature', style: TextStyle(fontSize: 13)),
                      Text(
                        _temperature.toStringAsFixed(2),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: _temperature,
                    min: 0,
                    max: 2,
                    divisions: 40,
                    label: _temperature.toStringAsFixed(2),
                    onChanged: (v) {
                      setState(() => _temperature = v);
                      AppSettings.temperature = v;
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Top P', style: TextStyle(fontSize: 13)),
                      Text(
                        _topP.toStringAsFixed(2),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: _topP,
                    min: 0,
                    max: 1,
                    divisions: 20,
                    label: _topP.toStringAsFixed(2),
                    onChanged: (v) {
                      setState(() => _topP = v);
                      AppSettings.topP = v;
                    },
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _maxTokensCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '最大回复长度 max_tokens（0 = 不限）',
                    ),
                    onChanged: (v) =>
                        AppSettings.maxTokens = int.tryParse(v) ?? 0,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _groupHeader('世界书'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.add_circle_outline, color: scheme.primary),
                  title: const Text('导入世界书 JSON'),
                  subtitle: const Text('SillyTavern 世界书格式，聊天时按关键词自动注入'),
                  onTap: _importWorldBook,
                ),
                if (_worldBooks.isNotEmpty) const Divider(height: 1),
                for (final (id, book) in _worldBooks)
                  ListTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: Text(
                      book.name.isEmpty ? '未命名世界书' : book.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${book.entries.length} 条'
                        '${AppSettings.mountedWorldBookIds.contains(id) ? ' · 已启用' : ' · 未启用'}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value:
                              AppSettings.mountedWorldBookIds.contains(id),
                          onChanged: (v) => _toggleWorldBook(id, v),
                        ),
                        IconButton(
                          icon: Icon(Icons.delete_outline,
                              color: scheme.error),
                          onPressed: () => _deleteWorldBook(id),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _groupHeader('聊天'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '我的名字（{{user}} 替换值）',
                  hintText: '你',
                ),
                onChanged: (v) => AppSettings.userName =
                    v.isEmpty ? '你' : v,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _groupHeader('通用'),
          Card(
            child: RadioGroup<String>(
              groupValue: AppSettings.themeMode,
              onChanged: (v) {
                if (v != null) _setTheme(v);
              },
              child: Column(
                children: [
                  for (final (value, label) in const [
                    ('system', '跟随系统'),
                    ('light', '浅色'),
                    ('dark', '深色'),
                  ])
                    RadioListTile<String>(
                      value: value,
                      title: Text(label),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _groupHeader('帮助'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.school_outlined),
                  title: const Text('重看新手引导'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const OnboardingScreen()),
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('关于'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showAbout,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
            letterSpacing: 0.5,
          ),
        ),
      );

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关于 轻酒馆'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('版本 v0.2.0'),
            SizedBox(height: 10),
            Text('简洁明了的 AI 角色扮演聊天 App，兼容 SillyTavern 角色卡与世界书。'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }
}
