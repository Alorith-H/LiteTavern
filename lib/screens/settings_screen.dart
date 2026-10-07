import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../models/world_info.dart';
import '../services/storage.dart';
import '../widgets/common.dart';
import 'advanced_settings_screen.dart';
import 'api_config_screen.dart';
import 'gen_presets_screen.dart';
import 'onboarding_screen.dart';

/// 设置页。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _maxTokensCtrl;
  late final TextEditingController _contextWindowCtrl;
  late double _temperature;
  late double _topP;
  late double _chatFontSize;
  late int _historyLimit;
  late bool _showTimestamps;
  late bool _showQuickReplies;
  late int _autoContinue;
  late bool _autoSummarize;
  late bool _streaming;

  /// 当前主题色 seed 与自定义 HEX 输入
  late int _seed;
  late final TextEditingController _hexCtrl;
  String? _hexError;

  static final _hexRe = RegExp(r'^#[0-9a-fA-F]{6}$');

  /// 12 色预设（spec 固定顺序）
  static const _themeColors = [
    0xFF2196F3, // 蓝
    0xFF4CAF50, // 绿
    0xFF9C27B0, // 紫
    0xFFFF9800, // 橙
    0xFFF44336, // 红
    0xFF00BCD4, // 青
    0xFFFF69B4, // 粉
    0xFF3F51B5, // 靛
    0xFF009688, // 青绿
    0xFFFFC107, // 琥珀
    0xFFE91E63, // 玫红
    0xFF607D8B, // 蓝灰
  ];

  List<(String, WorldInfo)> _worldBooks = [];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: AppSettings.userName);
    _maxTokensCtrl = TextEditingController(text: '${AppSettings.maxTokens}');
    _contextWindowCtrl =
        TextEditingController(text: '${AppSettings.contextWindow}');
    _temperature = AppSettings.temperature.clamp(0.0, 2.0).toDouble();
    _topP = AppSettings.topP.clamp(0.0, 1.0).toDouble();
    _chatFontSize = AppSettings.chatFontSize;
    _historyLimit = AppSettings.contextHistoryLimit;
    _showTimestamps = AppSettings.showTimestamps;
    _showQuickReplies = AppSettings.showQuickReplies;
    _autoContinue = AppSettings.autoContinueCount;
    _autoSummarize = AppSettings.autoSummarize;
    _streaming = AppSettings.streaming;
    _seed = AppSettings.themeSeed;
    _hexCtrl = TextEditingController(text: _seedToHex(_seed));
    _loadWorldBooks();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _maxTokensCtrl.dispose();
    _contextWindowCtrl.dispose();
    _hexCtrl.dispose();
    super.dispose();
  }

  /// 子页面（配置列表 / 预设列表）返回后同步滑条与输入框
  ///（激活配置或激活预设可能已切换）。
  void _syncFromSettings() {
    if (!mounted) return;
    setState(() {
      _temperature = AppSettings.temperature.clamp(0.0, 2.0).toDouble();
      _topP = AppSettings.topP.clamp(0.0, 1.0).toDouble();
      _maxTokensCtrl.text = '${AppSettings.maxTokens}';
    });
  }

  Future<void> _openApiConfigs() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ApiConfigsScreen()),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openPresets() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const GenPresetsScreen()),
    );
    _syncFromSettings();
  }

  /// 高级设置子页（v0.9.0）：返回后同步预设相关显示（激活预设可能已切换）。
  Future<void> _openAdvanced() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AdvancedSettingsScreen()),
    );
    _syncFromSettings();
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

  /// 0xFF2196F3 → '#2196F3'
  static String _seedToHex(int v) =>
      '#${(v & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// 应用主题色：持久化 + 全局通知（立即生效，无需重启）。
  void _applySeed(int value) {
    if (_seed == value) return;
    _seed = value;
    AppSettings.themeSeed = value;
    themeSeedNotifier.value = Color(value);
    final hex = _seedToHex(value);
    if (_hexCtrl.text.trim().toUpperCase() != hex) _hexCtrl.text = hex;
    setState(() {});
  }

  /// 自定义 HEX 输入：合法（#RRGGBB）即应用，非法红字提示。
  void _onHexChanged(String raw) {
    final v = raw.trim();
    if (v.isEmpty) {
      setState(() => _hexError = null);
      return;
    }
    if (!_hexRe.hasMatch(v)) {
      setState(() => _hexError = '格式应为 #RRGGBB，如 #2196F3');
      return;
    }
    if (_hexError != null) setState(() => _hexError = null);
    _applySeed(int.parse('FF${v.substring(1)}', radix: 16));
  }

  // ------------------------------------------------------------ 构建 --

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // ---------------------------------------------- 模型服务 --
          // 当前配置行：名称 + 模型名副文本 + 切换箭头 → 配置列表（选择/管理）
          const SectionHeader('模型服务'),
          _actionRow(
            title: AppSettings.activeApiConfig.name,
            subtitle: AppSettings.activeApiConfig.model.trim().isEmpty
                ? '未填写模型名 · 点此管理配置'
                : AppSettings.activeApiConfig.model.trim(),
            trailing: Icon(
              Icons.swap_horiz_outlined,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
            onTap: _openApiConfigs,
          ),

          // ---------------------------------------------- 生成参数 --
          const SectionHeader('生成参数'),
          // 当前预设行：名称 + 简要参数 → 预设列表（选择/另存/编辑）
          _actionRow(
            title: '预设 · ${AppSettings.activePreset.name}',
            subtitle:
                't${AppSettings.activePreset.temperature.toStringAsFixed(1)}'
                ' · p${AppSettings.activePreset.topP.toStringAsFixed(1)}'
                '${AppSettings.activePreset.maxTokens > 0 ? ' · 上限 ${AppSettings.activePreset.maxTokens}' : ''}'
                ' · 下方滑条改动即存入此预设',
            trailing: Icon(
              Icons.chevron_right_outlined,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
            onTap: _openPresets,
          ),
          const SizedBox(height: 4),
          _sliderLabel('随机度', _temperature.toStringAsFixed(2)),
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
          const _SubLine('越高回答越发散'),
          const SizedBox(height: 8),
          _sliderLabel('采样范围', _topP.toStringAsFixed(2)),
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
              labelText: '单次回复长度上限',
              helperText: '0 = 不限',
            ),
            onChanged: (v) => AppSettings.maxTokens = int.tryParse(v) ?? 0,
          ),
          const SizedBox(height: 8),
          _sliderLabel('记忆长度', '${_historyLimit.round()} 条'),
          Slider(
            value: _historyLimit.clamp(10, 100).toInt().toDouble(),
            min: 10,
            max: 100,
            divisions: 18,
            label: '${_historyLimit.round()} 条',
            onChanged: (v) {
              setState(() => _historyLimit = v.round());
              AppSettings.contextHistoryLimit = v.round();
            },
          ),
          const _SubLine('每次发送保留最近多少条消息'),
          const SizedBox(height: 8),
          TextField(
            controller: _contextWindowCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '模型上下文窗口',
              helperText: '模型单次能装下的最大 token，超了会自动压缩\n0 = 关闭占用%与自动压缩',
              helperMaxLines: 2,
            ),
            onChanged: (v) => AppSettings.contextWindow = int.tryParse(v) ?? 0,
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          _stepperRow(
            title: '自动继续次数',
            subtitle: '回复达到长度上限时代写续接的次数，0 = 关闭',
            value: _autoContinue,
            onChanged: (v) {
              setState(() => _autoContinue = v);
              AppSettings.autoContinueCount = v;
            },
          ),
          const Divider(height: 1),
          _switchRow(
            title: '流式传输',
            subtitle: '关掉则整段生成完一次性显示',
            value: _streaming,
            onChanged: (v) {
              setState(() => _streaming = v);
              AppSettings.streaming = v;
            },
          ),
          const Divider(height: 1),
          // 高级设置入口（生成参数组末尾）：采样参数、停止词等不常用项
          _actionRow(
            title: '高级设置',
            subtitle: '采样参数、停止词等不常用项',
            trailing: Icon(
              Icons.chevron_right_outlined,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
            onTap: _openAdvanced,
          ),

          // ------------------------------------------------ 世界书 --
          const SectionHeader('世界书'),
          _actionRow(
            title: '导入世界书',
            subtitle: 'SillyTavern 格式，聊天时按关键词自动注入',
            onTap: _importWorldBook,
          ),
          for (final (id, book) in _worldBooks) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.name.isEmpty ? '未命名世界书' : book.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: AppType.body,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${book.entries.length} 条'
                          '${AppSettings.mountedWorldBookIds.contains(id) ? ' · 已启用' : ' · 未启用'}',
                          style: TextStyle(
                            fontSize: AppType.caption,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: AppSettings.mountedWorldBookIds.contains(id),
                    onChanged: (v) => _toggleWorldBook(id, v),
                  ),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.delete_outline,
                        size: 22,
                        color: scheme.error,
                      ),
                      tooltip: '删除',
                      onPressed: () => _deleteWorldBook(id),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // -------------------------------------------------- 聊天 --
          const SectionHeader('聊天'),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '你在对话中的称呼',
              hintText: '你',
              helperText: '对话里对方怎么称呼你',
            ),
            onChanged: (v) => AppSettings.userName = v.isEmpty ? '你' : v,
          ),
          const SizedBox(height: 12),
          const Text(
            '聊天气泡字号',
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: FontWeight.w500,
            ),
          ),
          Slider(
            value: _chatFontSize.round().clamp(13, 20).toDouble(),
            min: 13,
            max: 20,
            divisions: 7,
            label: '${_chatFontSize.round()}sp',
            onChanged: (v) {
              setState(() => _chatFontSize = v.roundToDouble());
              AppSettings.chatFontSize = v;
            },
          ),
          const _SubLine('字号效果预览'),
          Text(
            '这句话用当前字号显示，拖动滑条试试',
            style: TextStyle(fontSize: _chatFontSize, height: 1.5),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          _switchRow(
            title: '消息时间戳',
            value: _showTimestamps,
            onChanged: (v) {
              setState(() => _showTimestamps = v);
              AppSettings.showTimestamps = v;
            },
          ),
          const Divider(height: 1),
          _switchRow(
            title: '显示快捷回复',
            subtitle: '在输入框上方显示一排点按即发的短语',
            value: _showQuickReplies,
            onChanged: (v) {
              setState(() => _showQuickReplies = v);
              AppSettings.showQuickReplies = v;
            },
          ),
          const Divider(height: 1),
          _switchRow(
            title: '长对话自动摘要',
            subtitle: '对话太长时自动把早期内容压成摘要，保证不遗忘',
            value: _autoSummarize,
            onChanged: (v) {
              setState(() => _autoSummarize = v);
              AppSettings.autoSummarize = v;
            },
          ),
          const Divider(height: 1),
          _actionRow(
            title: '快捷回复管理',
            subtitle: '${AppSettings.quickReplies.length} 条 · 常驻入口，可先配置再打开上面的开关',
            trailing: Icon(
              Icons.chevron_right_outlined,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const QuickRepliesScreen()),
              );
              // 返回后刷新条数（页面内自行持久化）
              if (mounted) setState(() {});
            },
          ),

          // -------------------------------------------------- 外观 --
          const SectionHeader('外观'),
          Row(
            children: [
              for (final (i, mode, label) in const [
                (0, 'system', '跟随系统'),
                (1, 'light', '浅色'),
                (2, 'dark', '深色'),
              ]) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _modePreview(mode, label)),
              ],
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SectionHeader('主题色'),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 1.6,
            children: [
              for (final value in _themeColors) _buildColorSwatch(value),
            ],
          ),
          const SizedBox(height: 10),
          const SectionHeader('自定义颜色'),
          TextField(
            controller: _hexCtrl,
            keyboardType: TextInputType.text,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: '#2196F3',
              helperText: '填入合法 HEX 立即应用',
              helperMaxLines: 2,
              errorText: _hexError,
              isDense: true,
            ),
            onChanged: _onHexChanged,
          ),

          // -------------------------------------------------- 帮助 --
          const SectionHeader('帮助'),
          _actionRow(
            title: '重看新手引导',
            trailing: Icon(
              Icons.chevron_right_outlined,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
              );
            },
          ),
          const Divider(height: 1),
          _actionRow(
            title: '关于',
            trailing: Icon(
              Icons.chevron_right_outlined,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
            onTap: _showAbout,
          ),
        ],
      ),
    );
  }

  /// 滑条上方标签行：名称 + 右侧数值（accent）。
  Widget _sliderLabel(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: AppType.caption,
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: AppType.caption,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      ],
    );
  }

  /// 开关行：标题（+ 副说明）直接铺在背景上，右侧 M3 Switch。
  Widget _switchRow({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  /// 步进器行：标题 + 副说明，右侧 − N +（0–5），编辑风无卡片。
  Widget _stepperRow({
    required String title,
    required String subtitle,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 36,
            height: 36,
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.remove_outlined, size: 20),
              onPressed: value <= 0 ? null : () => onChanged(value - 1),
            ),
          ),
          SizedBox(
            width: 26,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.body,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
          SizedBox(
            width: 36,
            height: 36,
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.add_outlined, size: 20),
              onPressed: value >= 5 ? null : () => onChanged(value + 1),
            ),
          ),
        ],
      ),
    );
  }

  /// 行为行（点按执行动作）：标题 + 副说明，无装饰图标。
  Widget _actionRow({
    required String title,
    String? subtitle,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: AppType.body,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing,
            ],
          ],
        ),
      ),
    );
  }

  /// 主题模式迷你预览卡：纯色块 + 两条假文字线；
  /// 点选态 = 1.5px accent 描边。
  Widget _modePreview(String mode, String label) {
    final scheme = Theme.of(context).colorScheme;
    final selected = AppSettings.themeMode == mode;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setTheme(mode),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 56,
            padding: EdgeInsets.all(selected ? 1.5 : 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outline,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _modeThumb(mode),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected
                  ? scheme.onSurface
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeThumb(String mode) {
    switch (mode) {
      case 'light':
        return _thumbBlock(kLightBackground, kLightInk);
      case 'dark':
        return _thumbBlock(kDarkBackground, kDarkInk);
      default:
        // 跟随系统 = 左浅右深分屏，各一条假文字线
        return Row(
          children: [
            Expanded(child: _thumbBlock(kLightBackground, kLightInk, lines: 1)),
            Expanded(child: _thumbBlock(kDarkBackground, kDarkInk, lines: 1)),
          ],
        );
    }
  }

  /// 迷你缩略图：纯色块 + 1–2 条假文字线。
  Widget _thumbBlock(Color bg, Color ink, {int lines = 2}) {
    return Container(
      color: bg,
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < lines; i++) ...[
                Container(
                  width: lines == 1 ? 16 : (i == 0 ? 36 : 22),
                  height: 4,
                  decoration: BoxDecoration(
                    color: ink.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                if (i == 0 && lines > 1) const SizedBox(height: 5),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 主题色：24dp 圆角方块 + 选中 accent 描边。
  Widget _buildColorSwatch(int value) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _seed == value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _applySeed(value),
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Color(value),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: scheme.outline),
            ),
          ),
        ),
      ),
    );
  }

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关于 LiteTavern'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('版本 v0.8.0'),
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

/// 次要说明行（13sp 次要色）。
class _SubLine extends StatelessWidget {
  final String text;

  const _SubLine(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: AppType.caption,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 快捷回复管理：列表页增 / 删 / 改（文本非空校验）。
/// 删到空后聊天页不再显示快捷回复排；从未管理过时预置「继续 / 换个说法」。
class QuickRepliesScreen extends StatefulWidget {
  const QuickRepliesScreen({super.key});

  @override
  State<QuickRepliesScreen> createState() => _QuickRepliesScreenState();
}

class _QuickRepliesScreenState extends State<QuickRepliesScreen> {
  late final List<String> _items;

  @override
  void initState() {
    super.initState();
    _items = List.of(AppSettings.quickReplies);
  }

  void _persist() => AppSettings.quickReplies = _items;

  /// 新增或编辑（index != null 为编辑），文本非空校验在弹窗内完成。
  Future<void> _editItem({int? index}) async {
    final ctrl = TextEditingController(
      text: index == null ? '' : _items[index],
    );
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(index == null ? '新增快捷回复' : '编辑快捷回复'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '点按即发送的文本',
              errorText: error,
              isDense: true,
            ),
            onSubmitted: (_) {
              if (ctrl.text.trim().isEmpty) {
                setDialogState(() => error = '内容不能为空');
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
                  setDialogState(() => error = '内容不能为空');
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
    final text = ctrl.text.trim();
    ctrl.dispose();
    if (saved != true || !mounted) return;
    setState(() {
      if (index == null) {
        _items.add(text);
      } else {
        _items[index] = text;
      }
    });
    _persist();
  }

  Future<void> _deleteItem(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除快捷回复'),
        content: Text('确定删除「${_items[index]}」吗？'),
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
    if (ok != true || !mounted) return;
    setState(() => _items.removeAt(index));
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('快捷回复管理')),
      body: _items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  '还没有快捷回复\n新增后可在设置里打开「显示快捷回复」\n让它们出现在聊天输入框上方',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: scheme.onSurfaceVariant),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => InkWell(
                onTap: () => _editItem(index: i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _items[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontSize: AppType.body),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.edit_outlined, size: 22),
                          tooltip: '编辑',
                          onPressed: () => _editItem(index: i),
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
                            color: scheme.error,
                          ),
                          tooltip: '删除',
                          onPressed: () => _deleteItem(i),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editItem(),
        icon: const Icon(Icons.add_outlined, size: 20),
        label: const Text('新增'),
      ),
    );
  }
}
