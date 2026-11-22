import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/api_presets.dart';
import '../services/card_parser.dart';
import '../services/external_links.dart';
import '../services/storage.dart';
import '../widgets/common.dart';
import 'card_market_screen.dart';
import 'home_screen.dart';

/// 新手引导（v0.15.0 重做为 5 步「手把手教学」）。
///
/// 前提：默认用户什么都不会。所以第 1 步先把「LiteTavern 本身不带 AI
/// 模型、必须自备模型服务的 API Key、没有网络聊不起来」讲清楚；第 2 步
/// 给出 5 家服务商的官网 / Key 页 / 文档入口；第 3 步填地址与 Key 并测试
/// 连接（附常见错误对照）；第 4 步导入第一张角色卡；第 5 步说明怎么开始
/// 聊天。
///
/// 第 3 步的三个输入框直接读写激活的 API 配置（[AppSettings.baseUrl] 等
/// 即激活配置，与多配置列表无感知互通）。测试连接成功、离开该步、点
/// 「跳过」或 [_finish] 时都会写回，避免新手配到一半丢配置。
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const int _totalSteps = 5;

  /// 底部主按钮文案（按步骤取）。
  static const List<String> _primaryLabels = <String>[
    '我知道了，下一步',
    '已经拿到 Key，下一步',
    '下一步：导入角色',
    '下一步',
    '进入 LiteTavern',
  ];

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

  ColorScheme get _scheme => Theme.of(context).colorScheme;

  /// 成功状态用绿色：深/浅色底各取一档，保证对比度（否则暗色下发灰）。
  Color get _successColor => Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF8FD3A0)
      : const Color(0xFF2E7D4F);

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

  // ------------------------------------------------------------ 流程 --

  void _saveModelConfig() {
    AppSettings.baseUrl = _urlCtrl.text;
    AppSettings.apiKey = _keyCtrl.text;
    AppSettings.model = _modelCtrl.text;
  }

  void _finish() {
    // 进来就点「跳过」也不能丢已填的配置。
    _saveModelConfig();
    AppSettings.onboardingDone = true;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  void _goNext() {
    if (_page >= _totalSteps - 1) {
      _finish();
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _goBack() {
    if (_page == 0) return;
    _pageController.previousPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _onPageChanged(int index) {
    final leftModelStep = _page == 2 && index > 2;
    setState(() => _page = index);
    if (leftModelStep) _afterModelStep();
  }

  /// 离开第 3 步：先落盘，再在没配好时提醒「之后还能补」。
  void _afterModelStep() {
    _saveModelConfig();
    if (AppSettings.apiConfigured && _modelCtrl.text.trim().isNotEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('模型服务还没配好，稍后可以在 设置 → 模型服务 里再配'),
          duration: Duration(seconds: 4),
        ),
      );
  }

  Future<void> _testConnection() async {
    final url = _urlCtrl.text.trim();
    final key = _keyCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    _saveModelConfig();
    if (url.isEmpty || key.isEmpty) {
      setState(() {
        _testOk = false;
        _testError = '请先填写 Base URL 和 API Key';
      });
      return;
    }
    if (model.isEmpty) {
      setState(() {
        _testOk = false;
        _testError = '请先填写模型名（点上面的服务商预设会自动填好）';
      });
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
      _testOk = false;
    });
    try {
      await _api.testConnection(baseUrl: url, apiKey: key, model: model);
      if (!mounted) return;
      _saveModelConfig();
      setState(() {
        _testing = false;
        _testOk = true;
        _testError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testError = e.toString();
      });
    }
  }

  void _applyPreset(ApiPreset preset) {
    setState(() {
      _urlCtrl.text = preset.baseUrl;
      _modelCtrl.text = preset.model;
      _testOk = false;
      _testError = null;
      _saveModelConfig();
    });
  }

  /// 该预设是否就是当前填的地址（决定 chip 选中态）。
  bool _isCurrentPreset(ApiPreset preset) =>
      (presetForBaseUrl(_urlCtrl.text)?.label ?? '') == preset.label;

  void _openProviderHelp(ApiPreset preset) {
    if (preset.note.contains('无需 Key')) {
      // Ollama 是本地模型，没有 Key 可拿，直接给下载页。
      openExternalLink(context, preset.keyUrl, title: '${preset.label} 下载');
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

  /// 从角色卡市场导入：进去挑卡，回来（不管有没有导入）就算完成引导。
  Future<void> _openMarket() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const CardMarketScreen()),
    );
    if (!mounted) return;
    _finish();
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

  // ------------------------------------------------------------ 骨架 --

  @override
  Widget build(BuildContext context) {
    final scheme = _scheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 12, 10),
              child: Row(
                children: [
                  Text(
                    '第 ${_page + 1} / $_totalSteps 步',
                    style: TextStyle(
                      fontSize: AppType.caption,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Visibility(
                    visible: _page < _totalSteps - 1,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: TextButton(
                      onPressed: _finish,
                      child: const Text('跳过'),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: (_page + 1) / _totalSteps,
                  minHeight: 3,
                  backgroundColor: scheme.outline,
                  color: scheme.primary,
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: _onPageChanged,
                children: [
                  _buildWelcome(),
                  _buildGetKey(),
                  _buildModelConfig(),
                  _buildImport(),
                  _buildDone(),
                ],
              ),
            ),
            _buildBottomNav(),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 16),
      child: Row(
        children: [
          if (_page > 0) ...[
            OutlinedButton(onPressed: _goBack, child: const Text('上一步')),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: FilledButton(
              onPressed: _page == _totalSteps - 1 ? _finish : _goNext,
              child: Text(_primaryLabels[_page]),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------- 排版小件 --

  /// 每页统一的可滚动容器（360dp 宽 / 520dp 高的小屏也不会溢出）。
  Widget _pageScroll(List<Widget> children) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _title(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: AppType.hero,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        ),
      );

  Widget _lead(String text) => Text(
        text,
        style: TextStyle(
          fontSize: AppType.body,
          height: 1.55,
          color: _scheme.onSurfaceVariant,
        ),
      );

  Widget _small(String text) => Text(
        text,
        style: TextStyle(
          fontSize: AppType.caption,
          height: 1.5,
          color: _scheme.onSurfaceVariant,
        ),
      );

  Widget _panel(
    Widget child, {
    Color? color,
    Color? borderColor,
    EdgeInsetsGeometry padding = const EdgeInsets.all(14),
  }) {
    final scheme = _scheme;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor ?? scheme.outline),
      ),
      child: child,
    );
  }

  /// 强调块：accent 淡底 + accent 细边（跟随主题色，不硬编码亮底）。
  Widget _highlightPanel({
    required IconData icon,
    required String title,
    required String body,
  }) {
    final scheme = _scheme;
    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              fontSize: AppType.caption,
              height: 1.55,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      color: scheme.primary.withValues(alpha: 0.07),
      borderColor: scheme.primary.withValues(alpha: 0.35),
    );
  }

  /// 带序号的说明行（三步概览 / 三步使用）。
  Widget _bulletRow(int index, String title, String desc) {
    final scheme = _scheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '$index',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 带描边图标的使用要点行。
  Widget _featureRow(IconData icon, String title, String desc) {
    final scheme = _scheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 19, color: scheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String text) {
    final scheme = _scheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }

  Widget _monoLine(String label, String value) {
    final scheme = _scheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 62,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              fontFamily: 'monospace',
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------- 第 1 步：欢迎 --

  Widget _buildWelcome() {
    final scheme = _scheme;
    return _pageScroll([
      Icon(Icons.local_bar_outlined, size: 44, color: scheme.primary),
      const SizedBox(height: 14),
      _title('欢迎使用 LiteTavern'),
      _lead(
        '这是一个本地运行的角色扮演聊天 App：导入一张角色卡，就能和角色一对一聊天，'
        '也可以把几个角色拉进同一个群聊。角色、对话和设置都只存在你手机上。',
      ),
      const SizedBox(height: 18),
      _highlightPanel(
        icon: Icons.info_outline,
        title: '先说清楚：LiteTavern 本身不带 AI 模型',
        body: '聊天时真正说话的是「模型服务商」的大模型，LiteTavern 只负责把你的话、'
            '角色设定和上下文整理好发过去。所以你需要自备一个模型服务的 API Key——'
            '费用由服务商按用量收取，不是付给 LiteTavern；没有 Key 或者没有网络都聊不起来。',
      ),
      const SizedBox(height: 8),
      const SectionHeader('三步就能开始'),
      _bulletRow(1, '配置模型服务', '挑一家服务商，拿到 API Key 填进来（第 2、3 步教）'),
      _bulletRow(2, '导入角色卡', '从角色卡市场挑一张，或用文件导入自己存的卡'),
      _bulletRow(3, '开始聊天', '点角色进聊天页，在输入框发第一句话'),
      _small('别担心，每一步要做什么、去哪里点，都写在后面几页里。'),
    ]);
  }

  // ------------------------------------------- 第 2 步：获取 Key --

  Widget _buildGetKey() {
    return _pageScroll([
      _title('获取 API Key'),
      _lead(
        '下面 5 家都能用。点「去官网获取 Key」，按弹窗里的 4 步走一遍就行——'
        '复制到的 Key 先别关网页，第 3 步要粘贴回来。',
      ),
      const SizedBox(height: 16),
      for (final preset in kApiPresets) _providerCard(preset),
      const SizedBox(height: 4),
      _highlightPanel(
        icon: Icons.lightbulb_outline,
        title: '新手怎么选、要注意什么',
        body: '推荐先用 DeepSeek 或智谱 GLM：有免费额度或价格便宜，注册也简单，'
            '其中智谱需要实名认证。Ollama 是在自己电脑上跑模型，不需要 Key，'
            '但需要电脑一直开着并已下载模型。\n\n'
            'API Key 相当于账号密码：只保存在本机，不要发给别人，也不要截图发到群里。',
      ),
    ]);
  }

  Widget _providerCard(ApiPreset preset) {
    final scheme = _scheme;
    final local = preset.note.contains('无需 Key');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    preset.label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _badge(local ? '本地' : '需 Key'),
              ],
            ),
            if (preset.note.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                preset.note,
                style: TextStyle(
                  fontSize: AppType.caption,
                  height: 1.45,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            _monoLine('Base URL', preset.baseUrl),
            const SizedBox(height: 3),
            _monoLine('推荐模型', preset.model),
            const SizedBox(height: 12),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _openProviderHelp(preset),
                  icon: Icon(
                    local ? Icons.download_outlined : Icons.key_outlined,
                    size: 18,
                  ),
                  label: Text(local ? '去下载 Ollama' : '去官网获取 Key'),
                ),
                if (!local)
                  TextButton(
                    onPressed: () => openExternalLink(
                      context,
                      preset.keyUrl,
                      title: '${preset.label} API Keys',
                    ),
                    child: const Text('直接打开'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------- 第 3 步：填写并测试连接 --

  Widget _buildModelConfig() {
    final scheme = _scheme;
    return _pageScroll([
      _title('填写并测试连接'),
      _lead(
        '把第 2 步复制的 Key 粘贴到第二栏，再点「测试连接」确认能用。'
        '三栏分别是什么、从哪里抄，下面都写清楚了。',
      ),
      const SizedBox(height: 8),
      const SectionHeader('点一下，自动填好地址和模型'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final preset in kApiPresets)
            ChoiceChip(
              label: Text(preset.label),
              selected: _isCurrentPreset(preset),
              onSelected: (_) => _applyPreset(preset),
            ),
        ],
      ),
      const SizedBox(height: 18),
      TextField(
        controller: _urlCtrl,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'Base URL（接口地址）',
          hintText: 'https://api.deepseek.com/v1',
          helperText: '服务商文档里的接口地址，通常以 /v1 结尾；点上面的预设会自动填好。',
          helperMaxLines: 3,
        ),
        onChanged: (_) => setState(() {
          _testOk = false;
          _testError = null;
          _saveModelConfig();
        }),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _keyCtrl,
        obscureText: _obscureKey,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: 'API Key',
          hintText: 'sk-…',
          helperText: '第 2 步复制的密钥。只保存在本机，不会上传到别处。',
          helperMaxLines: 3,
          suffixIcon: IconButton(
            icon: Icon(
              _obscureKey
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 22,
            ),
            tooltip: _obscureKey ? '显示 Key' : '隐藏 Key',
            onPressed: () => setState(() => _obscureKey = !_obscureKey),
          ),
        ),
        onChanged: (_) => setState(() {
          _testOk = false;
          _testError = null;
          _saveModelConfig();
        }),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _modelCtrl,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: '模型名',
          hintText: 'deepseek-chat',
          helperText: '服务商文档里的模型 ID，例如 deepseek-chat、glm-4-flash；点预设会自动填好。',
          helperMaxLines: 3,
        ),
        onChanged: (_) => setState(() {
          _testOk = false;
          _testError = null;
          _saveModelConfig();
        }),
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
          const SizedBox(width: 12),
          Expanded(child: _buildTestStatus()),
        ],
      ),
      if (_testError != null) ...[
        const SizedBox(height: 12),
        Text(
          '失败原因：$_testError',
          style: TextStyle(
            fontSize: AppType.caption,
            height: 1.45,
            color: scheme.error,
          ),
        ),
        const SizedBox(height: 12),
        _buildErrorHelpCard(),
      ],
      const SizedBox(height: 8),
      _small(
        '暂时配不好也没关系：点「下一步」可以先继续，之后随时在 设置 → 模型服务 里再配。',
      ),
    ]);
  }

  Widget _buildTestStatus() {
    if (_testing) {
      return Text(
        '正在连接…',
        style: TextStyle(
          fontSize: AppType.caption,
          color: _scheme.onSurfaceVariant,
        ),
      );
    }
    if (!_testOk) return const SizedBox.shrink();
    return Row(
      children: [
        Icon(Icons.check_circle_outlined, size: 18, color: _successColor),
        const SizedBox(width: 6),
        Text(
          '连接成功',
          style: TextStyle(
            fontSize: AppType.caption,
            fontWeight: FontWeight.w600,
            color: _successColor,
          ),
        ),
      ],
    );
  }

  /// 失败时的常见错误对照（新手 90% 的坑都在这四条里）。
  Widget _buildErrorHelpCard() {
    final scheme = _scheme;
    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.help_outline,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              const Text(
                '常见错误对照',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _errorLine('401 / Unauthorized', 'Key 错了，或者复制时没复制全（前后多了空格也算）'),
          _errorLine('404', 'Base URL 写错了：少了 /v1，或者多了别的路径'),
          _errorLine('402 / 余额不足 / quota', '账户没充值，或者免费额度已经用完'),
          _errorLine(
            '超时 / SocketException / Failed host lookup',
            '网络不通、地址写错，或者当前网络需要代理',
          ),
        ],
      ),
      color: scheme.error.withValues(alpha: 0.06),
      borderColor: scheme.error.withValues(alpha: 0.3),
    );
  }

  Widget _errorLine(String code, String hint) {
    final scheme = _scheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            code,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              color: scheme.error,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            hint,
            style: TextStyle(
              fontSize: AppType.caption,
              height: 1.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------- 第 4 步：导入第一个角色卡 --

  Widget _buildImport() {
    return _pageScroll([
      _title('导入第一个角色卡'),
      _lead(
        '角色卡就是一张图片（或一个文件），里面藏着角色的名字、性格、说话方式和开场白。'
        '常见格式是 .png——设定藏在图片的元数据里——也可能是 .json，'
        '兼容 SillyTavern / chara_card V2。',
      ),
      const SizedBox(height: 18),
      _choiceCard(
        icon: Icons.storefront_outlined,
        badge: '推荐',
        title: '从角色卡市场导入',
        subtitle: '在线浏览 Chub.ai 上的公开角色卡，看到喜欢的点下载就自动入库',
        onTap: _openMarket,
      ),
      const SizedBox(height: 10),
      _choiceCard(
        icon: Icons.file_upload_outlined,
        title: '从本地文件导入',
        subtitle: '已经下载好 .png / .json 角色卡，直接从文件里选',
        onTap: _importCharacter,
      ),
      const SizedBox(height: 10),
      _choiceCard(
        icon: Icons.explore_outlined,
        title: '先跳过，进去自己逛',
        subtitle: '进去之后也能随时添加，不着急',
        onTap: _finish,
      ),
      const SizedBox(height: 6),
      _small('也可以以后在主页右下角「导入」里再添加。'),
    ]);
  }

  Widget _choiceCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    String? badge,
  }) {
    final scheme = _scheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: scheme.outline),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: 22, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                            ),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 6),
                          _badge(badge),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        height: 1.45,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 1, left: 4),
                child: Icon(
                  Icons.chevron_right_outlined,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------- 第 5 步：完成，开始聊天 --

  Widget _buildDone() {
    final scheme = _scheme;
    return _pageScroll([
      Icon(Icons.chat_bubble_outline, size: 44, color: scheme.primary),
      const SizedBox(height: 14),
      _title('好了，开始聊天'),
      _lead('配置和角色卡都准备好了。进去之后可以这样用：'),
      const SizedBox(height: 18),
      _featureRow(
        Icons.person_outline,
        '点角色进聊天',
        '在主页点一个角色 → 进入聊天页 → 在底部输入框发消息，点发送或回车。',
      ),
      _featureRow(
        Icons.auto_awesome_outlined,
        '让 AI 帮你先写一句',
        '输入框旁边有「生成建议回复」按钮，点一下它会按当前剧情给你几句可选的话，'
            '点选就能发。也可以在 设置 → 自动生成回复 打开，让 AI 回复后自动给 3 条。',
      ),
      _featureRow(
        Icons.tune_outlined,
        '想改设置就去「设置」',
        '生成参数（温度、长度）、上下文窗口、聊天字号、主题色都在那里改；'
            '模型服务也能随时换一家。',
      ),
      _highlightPanel(
        icon: Icons.lock_outline,
        title: '数据都在你手机里',
        body: '角色、对话和设置只存在本机，不上传到任何服务器（除了发给模型服务商的聊天内容）。'
            '卸载 App 会一起删掉，重要对话记得先复制出来。',
      ),
      const SizedBox(height: 12),
      _small('想再看一遍这段引导：设置 → 帮助 → 重看新手引导。'),
    ]);
  }
}
