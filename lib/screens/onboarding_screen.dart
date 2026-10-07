import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/api_presets.dart';
import '../services/card_parser.dart';
import '../services/storage.dart';
import '../widgets/common.dart';
import 'home_screen.dart';

/// 新手引导：三页 PageView（欢迎 / 配模型 / 导入角色）。
/// 第 2 页直接读写激活的 API 配置（AppSettings.baseUrl 等即激活配置，
/// 与多配置列表无感知互通）。
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  int _page = 0;

  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _modelCtrl;
  bool _obscureKey = true;
  bool _testing = false;
  bool _testOk = false;
  String? _testError;

  final _api = ApiClient();

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: AppSettings.baseUrl);
    _keyCtrl = TextEditingController(text: AppSettings.apiKey);
    _modelCtrl = TextEditingController(text: AppSettings.model);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _api.dispose();
    super.dispose();
  }

  void _saveModelConfig() {
    AppSettings.baseUrl = _urlCtrl.text;
    AppSettings.apiKey = _keyCtrl.text;
    AppSettings.model = _modelCtrl.text;
  }

  void _finish() {
    AppSettings.onboardingDone = true;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  Future<void> _testConnection() async {
    _saveModelConfig();
    if (!AppSettings.apiConfigured) {
      setState(() {
        _testError = '请先填写 Base URL 和 API Key';
        _testOk = false;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
      _testOk = false;
    });
    try {
      final model = await _api.testConnection(
        baseUrl: AppSettings.baseUrl,
        apiKey: AppSettings.apiKey,
        model: AppSettings.model,
      );
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = true;
        _testError = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('连接成功，模型：$model')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testError = e.toString();
      });
    }
  }

  Future<void> _importCharacter() async {
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
      final parsed = CardParser.parse(bytes, file.name);
      final card = await Storage.saveCharacter(parsed.card);
      if (parsed.pngBytes != null) {
        await Storage.saveAvatar(card.id, parsed.pngBytes!);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入角色「${card.name}」')),
      );
      _finish();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('导入失败：这不是有效的角色卡文件')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
                child: const Text('跳过'),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  _buildWelcome(scheme),
                  _buildModelConfig(scheme),
                  _buildImport(scheme),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                final selected = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: selected ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary
                        : scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
              child: Row(
                children: [
                  if (_page > 0)
                    OutlinedButton(
                      onPressed: () => _pageController.previousPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      ),
                      child: const Text('上一步'),
                    )
                  else
                    const SizedBox(width: 80),
                  const Spacer(),
                  if (_page < 2)
                    FilledButton(
                      onPressed: () => _pageController.nextPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      ),
                      child: const Text('下一步'),
                    )
                  else
                    FilledButton(
                      onPressed: _finish,
                      child: const Text('进入LiteTavern'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 页 1 --

  Widget _buildWelcome(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 描边图标替代 emoji（禁 emoji、禁装饰圆底）
          Icon(Icons.local_bar_outlined, size: 72, color: scheme.primary),
          const SizedBox(height: 28),
          const Text(
            'LiteTavern',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            '导入角色卡，和喜欢的角色聊天',
            style: TextStyle(
              fontSize: AppType.body,
              color: scheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            '兼容 SillyTavern 角色卡与世界书，三步开始你的故事',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 页 2 --

  Widget _buildModelConfig(ColorScheme scheme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '配置模型服务',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            '选择你用的服务商，填好密钥。之后也可以随时在设置里修改。',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
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
                    _testOk = false;
                    _testError = null;
                    _saveModelConfig();
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://api.deepseek.com/v1',
              helperText: '服务商提供的接口地址',
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) => _saveModelConfig(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keyCtrl,
            obscureText: _obscureKey,
            decoration: InputDecoration(
              labelText: 'API Key',
              helperText: '只保存在本机',
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureKey
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 22,
                ),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
            onChanged: (_) => _saveModelConfig(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              labelText: '模型名',
              hintText: 'deepseek-chat',
            ),
            onChanged: (_) => _saveModelConfig(),
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
                    : Icon(
                        _testOk
                            ? Icons.check_circle_outlined
                            : Icons.wifi_tethering_outlined,
                        size: 20,
                      ),
                label: Text(_testing ? '测试中…' : '测试连接'),
              ),
              if (_testOk) ...[
                const SizedBox(width: 10),
                Icon(
                  Icons.check_circle_outlined,
                  size: 20,
                  color: scheme.primary,
                ),
              ],
            ],
          ),
          if (_testError != null) ...[
            const SizedBox(height: 10),
            Text(
              _testError!,
              style: TextStyle(color: scheme.error),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 页 3 --

  Widget _buildImport(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.badge_outlined, size: 72, color: scheme.primary),
          const SizedBox(height: 24),
          const Text(
            '导入角色',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            '角色卡可以在 chub.ai、类脑 AI 等网站下载，格式 .png 或 .json',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: _importCharacter,
            icon: const Icon(Icons.file_upload_outlined, size: 20),
            label: const Text('从文件导入'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _finish,
            child: const Text('跳过，先进去看看'),
          ),
        ],
      ),
    );
  }
}
