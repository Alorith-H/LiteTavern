import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_info.dart';
import '../main.dart';
import '../models/world_info.dart';
import '../services/api_presets.dart';
import '../services/chat_layout.dart';
import '../services/external_links.dart';
import '../services/storage.dart';
import '../services/user_personas.dart';
import '../widgets/common.dart';
import '../widgets/backup_sheet.dart';
import '../widgets/update_flow.dart';
import 'advanced_settings_screen.dart';
import 'api_config_screen.dart';
import 'display_regex_screen.dart';
import 'gen_presets_screen.dart';
import 'onboarding_screen.dart';
import 'personas_screen.dart';
import 'st_preset_screen.dart';
import 'world_book_bindings_screen.dart';
import 'world_book_entries_screen.dart';

/// 设置页的二级分组（v0.21.0）。
enum SettingsSection { generation, chat, market, worldBooks, appearance, help }

extension SettingsSectionTitle on SettingsSection {
  String get title => switch (this) {
        SettingsSection.generation => '生成参数',
        SettingsSection.chat => '聊天与上下文',
        SettingsSection.market => '角色卡市场与翻译',
        SettingsSection.worldBooks => '世界书',
        SettingsSection.appearance => '外观',
        SettingsSection.help => '帮助与关于',
      };
}

/// 设置页。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.section});

  /// 二级分组；null = 设置首页。
  final SettingsSection? section;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _azureKeyCtrl;
  late final TextEditingController _azureRegionCtrl;
  late final TextEditingController _libreUrlCtrl;
  late final TextEditingController _libreKeyCtrl;
  late final TextEditingController _maxTokensCtrl;
  late double _temperature;
  late double _topP;
  late double _chatFontSize;
  late int _historyLimit;
  late bool _showTimestamps;
  late bool _showQuickReplies;
  late int _autoContinue;
  late bool _autoSummarize;
  late bool _streaming;
  late AssistMode _assistMode;
  late bool _showNsfw;
  late bool _autoCheckUpdates;

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
    _azureKeyCtrl = TextEditingController(text: AppSettings.azureTranslatorKey);
    _azureRegionCtrl =
        TextEditingController(text: AppSettings.azureTranslatorRegion);
    _libreUrlCtrl = TextEditingController(text: AppSettings.libreTranslateUrl);
    _libreKeyCtrl = TextEditingController(text: AppSettings.libreTranslateKey);
    _maxTokensCtrl = TextEditingController(text: '${AppSettings.maxTokens}');
    _temperature = AppSettings.temperature.clamp(0.0, 2.0).toDouble();
    _topP = AppSettings.topP.clamp(0.0, 1.0).toDouble();
    _chatFontSize = AppSettings.chatFontSize;
    _historyLimit = AppSettings.contextHistoryLimit;
    _showTimestamps = AppSettings.showTimestamps;
    _showQuickReplies = AppSettings.showQuickReplies;
    _autoContinue = AppSettings.autoContinueCount;
    _autoSummarize = AppSettings.autoSummarize;
    _streaming = AppSettings.streaming;
    _assistMode = AppSettings.assistMode;
    _showNsfw = AppSettings.showNsfw;
    _autoCheckUpdates = AppSettings.autoCheckUpdates;
    _seed = AppSettings.themeSeed;
    _hexCtrl = TextEditingController(text: _seedToHex(_seed));
    _loadWorldBooks();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _azureKeyCtrl.dispose();
    _azureRegionCtrl.dispose();
    _libreUrlCtrl.dispose();
    _libreKeyCtrl.dispose();
    _maxTokensCtrl.dispose();
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

  // ---------------------------------------------- 用户人设（v0.16.0）--

  String _personaSummary() {
    final active = PersonaStore.active;
    if (active == null) {
      return '未选择：点进去新建一套「你」的身份（名字 + 设定）';
    }
    final name = active.name.trim();
    return active.hasDescription
        ? '$name · 有设定，会随提示词发给模型'
        : '$name · 只有名字，不注入设定';
  }

  Future<void> _openPersonas() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PersonasScreen()),
    );
    if (!mounted) return;
    // 选中人设会同步 userName，回来刷新称呼输入框与摘要
    setState(() => _nameCtrl.text = AppSettings.userName);
  }

  // ----------------------------------- 自动摘要说明（v0.18.0）--

  /// 把「什么时候触发 / 会不会花 token / 怎么关」讲清楚。
  /// 聊天页已改成后台静默执行，这里就是用户唯一能看到解释的地方。
  Future<void> _showSummaryExplain() async {
    final paragraphs = <String>[
      '什么时候触发：当前这段聊天里、超出「记忆长度」条数（现在 ${AppSettings.contextHistoryLimit} 条）'
          '的早期消息，会在你下次发送时先压成一段不超过 300 字的摘要。'
          '另一个触发点是上下文快满（超过模型窗口的 90%）时的自动压缩。',
      '不是你的模型额度不够，也不是 token 用光了：这是按「消息条数」触发的本地整理，'
          '和账户余额无关。',
      '会消耗 token：摘要是一次额外的模型请求——把早期对话发过去（输入 token），'
          '拿回一段摘要（输出 token）。所以它按服务商的价格单独计费，'
          '和正常聊天一样从你的额度里扣。一次通常只有几千 token，只在触发的那一次发生，不会每条消息都扣。',
      '本机的聊天记录不会被删改：摘要只影响「发给模型的内容」，你手机里的原对话一条都不少。',
      '想省 token 可以关掉：把上面的「长对话自动摘要」开关关掉即可，'
          '代价是长对话里更早的剧情模型可能记不住。也可以在聊天页 ⋮ 菜单里手动点「立即总结早期对话」，只在需要时跑一次。',
    ];
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自动摘要怎么工作'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < paragraphs.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '· ',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: scheme.primary,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        paragraphs[i],
                        style: const TextStyle(
                          fontSize: AppType.caption,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------- 用量与费用（v0.35.0）--

  String _priceSummary() {
    final i = AppSettings.priceInputPerMillion;
    final o = AppSettings.priceOutputPerMillion;
    if (i <= 0 && o <= 0) return '未填写单价：统计页只显示 token';
    return '输入 $i/M · 输出 $o/M · 用于统计页估算';
  }

  Future<void> _showPriceDialog() async {
    final result = await showDialog<({double input, double output, double cached})>(
      context: context,
      builder: (ctx) => const _PriceDialog(),
    );
    if (result == null) return;
    AppSettings.priceInputPerMillion = result.input;
    AppSettings.priceOutputPerMillion = result.output;
    AppSettings.priceCachedPerMillion = result.cached;
    if (mounted) setState(() {});
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

  /// 四范围绑定页（v0.27.0）。
  Future<void> _openWorldBookBindings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WorldBookBindingsScreen()),
    );
    if (!mounted) return;
    setState(() {});
  }

  /// 世界书条目页（v0.27.0 起从设置也能进，可命中测试 / 导出）。
  Future<void> _openWorldBookEntries(String id, WorldInfo book) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorldBookEntriesScreen(bookId: id, book: book),
      ),
    );
    if (!mounted) return;
    await _loadWorldBooks();
    if (mounted) setState(() {});
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
    final section = widget.section;
    if (section != null) {
      return Scaffold(
        appBar: AppBar(title: Text(section.title)),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: _sectionChildren(scheme, section),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // ---------------------------------------- 当前模型（直达） --
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

          // ---------------------------------------------- 二级菜单 --
          const SectionHeader('设置'),
          _actionRow(
            leading: Icons.tune,
            title: '生成参数',
            subtitle: _generationSummary(),
            trailing: _chevron(scheme),
            onTap: () => _openSection(SettingsSection.generation),
          ),
          const Divider(height: 1),
          _actionRow(
            leading: Icons.forum_outlined,
            title: '聊天与上下文',
            subtitle: _chatSummary(),
            trailing: _chevron(scheme),
            onTap: () => _openSection(SettingsSection.chat),
          ),
          const Divider(height: 1),
          _actionRow(
            leading: Icons.storefront_outlined,
            title: '角色卡市场与翻译',
            subtitle: _marketSummary(),
            trailing: _chevron(scheme),
            onTap: () => _openSection(SettingsSection.market),
          ),
          const Divider(height: 1),
          _actionRow(
            leading: Icons.menu_book_outlined,
            title: '世界书',
            subtitle: _worldBookSummary(),
            trailing: _chevron(scheme),
            onTap: () => _openSection(SettingsSection.worldBooks),
          ),
          const Divider(height: 1),
          _actionRow(
            leading: Icons.palette_outlined,
            title: '外观',
            subtitle: _appearanceSummary(),
            trailing: _chevron(scheme),
            onTap: () => _openSection(SettingsSection.appearance),
          ),

          // -------------------------------------------------- 帮助 --
          const SectionHeader('帮助与关于'),
          _actionRow(
            leading: Icons.help_outline,
            title: '帮助与关于',
            subtitle: '版本 v$kAppVersion · 重看新手引导 · 作者 Alorith',
            trailing: _chevron(scheme),
            onTap: () => _openSection(SettingsSection.help),
          ),
        ],
      ),
    );
  }

  Icon _chevron(ColorScheme scheme) => Icon(
        Icons.chevron_right_outlined,
        size: 22,
        color: scheme.onSurfaceVariant,
      );

  Future<void> _openSection(SettingsSection section) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(section: section),
      ),
    );
    // 子页里可能改了称呼 / 预设 / 世界书，回来刷新摘要
    if (mounted) setState(() {});
  }

  String _generationSummary() {
    final p = AppSettings.activePreset;
    final limit = p.maxTokens > 0 ? ' · 上限 ${p.maxTokens}' : '';
    return '预设 · ${p.name} · t${p.temperature.toStringAsFixed(1)}'
        ' · p${p.topP.toStringAsFixed(1)}$limit';
  }

  String _chatSummary() {
    final name = AppSettings.userName.trim().isEmpty
        ? '你'
        : AppSettings.userName.trim();
    return '称呼「$name」· 记忆 ${AppSettings.contextHistoryLimit} 条'
        ' · 摘要${AppSettings.autoSummarize ? '开' : '关'}'
        ' · ${AppSettings.assistMode.label}';
  }

  String _marketSummary() {
    final nsfw = AppSettings.showNsfw ? '显示' : '不显示';
    final azure =
        AppSettings.azureTranslatorKey.trim().isEmpty ? '免费源顺序' : '必应（Azure）';
    return 'NSFW $nsfw · 翻译 $azure';
  }

  String _worldBookSummary() {
    if (_worldBooks.isEmpty) return '还没有导入 · 导入 SillyTavern 世界书';
    final enabled = _worldBooks
        .where((e) => AppSettings.mountedWorldBookIds.contains(e.$1))
        .length;
    return '${_worldBooks.length} 本 · $enabled 本启用';
  }

  String _appearanceSummary() {
    final mode = switch (AppSettings.themeMode) {
      'light' => '浅色',
      'dark' => '深色',
      _ => '跟随系统',
    };
    return '$mode · 主题色 ${_seedToHex(_seed)}'
        ' · 字号 ${AppSettings.chatFontSize.round()}sp';
  }

  List<Widget> _sectionChildren(ColorScheme scheme, SettingsSection section) {
    switch (section) {
      case SettingsSection.generation:
        return _generationChildren(scheme);
      case SettingsSection.chat:
        return _chatChildren(scheme);
      case SettingsSection.market:
        return _marketChildren(scheme);
      case SettingsSection.worldBooks:
        return _worldBookChildren(scheme);
      case SettingsSection.appearance:
        return _appearanceChildren(scheme);
      case SettingsSection.help:
        return _helpChildren(scheme);
    }
  }

  // ------------------------------------------------ 生成参数（二级） --

  List<Widget> _generationChildren(ColorScheme scheme) {
    return [
      const SectionHeader('生成参数'),
      _actionRow(
        title: '预设 · ${AppSettings.activePreset.name}',
        subtitle:
            't${AppSettings.activePreset.temperature.toStringAsFixed(1)}'
            ' · p${AppSettings.activePreset.topP.toStringAsFixed(1)}'
            '${AppSettings.activePreset.maxTokens > 0 ? ' · 上限 ${AppSettings.activePreset.maxTokens}' : ''}'
            ' · 下方滑条改动即存入此预设',
        trailing: _chevron(scheme),
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
      const SizedBox(height: 12),
      // 高级设置入口（生成参数组末尾）：采样参数、停止词等不常用项
      _actionRow(
        title: '高级设置',
        subtitle: '采样参数、停止词等不常用项',
        trailing: _chevron(scheme),
        onTap: _openAdvanced,
      ),
      const Divider(height: 1),
      // SillyTavern 预设兼容（v0.30.0）：导入并查看采样参数与提示词顺序
      _actionRow(
        title: 'SillyTavern 预设',
        subtitle: '导入 ST 预设 JSON：看采样参数与提示词顺序，采样可一键套用（v0.30.0）',
        trailing: _chevron(scheme),
        onTap: _openStPreset,
      ),
      const Divider(height: 1),
    ];
  }

  Future<void> _openStPreset() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const StPresetScreen()),
    );
    // 预设页里可能「套用采样参数」，回来后要把滑条与文本同步成新值
    _syncFromSettings();
  }

  // -------------------------------------------- 聊天与上下文（二级） --

  List<Widget> _chatChildren(ColorScheme scheme) {
    return [
      const SectionHeader('聊天与上下文'),
      _actionRow(
        title: '用户人设',
        subtitle: _personaSummary(),
        trailing: _chevron(scheme),
        onTap: _openPersonas,
      ),
      const Divider(height: 1),
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
      const SectionHeader('记忆与上下文'),
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
      _actionRow(
        title: '模型上下文窗口',
        subtitle:
            '当前 ${formatContextWindow(AppSettings.contextWindow)}（按模型自动）· '
            '在 设置 → 模型服务 → 编辑配置 里改',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const ApiConfigsScreen(),
          ),
        ),
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
      // 交互辅助三选一（v0.18.0）：建议回复 / 替我说一句 / 都关闭。
      // 两者都开会让输入栏左侧挤两个按钮，且都在偷偷花 token，故互斥。
      const Text(
        '输入栏辅助按钮',
        style: TextStyle(
          fontSize: AppType.caption,
          fontWeight: FontWeight.w500,
        ),
      ),
      const _SubLine('「建议回复」和「替我说一句」只能二选一；选「都关闭」则输入栏左侧不显示按钮'),
      const SizedBox(height: 6),
      SegmentedButton<AssistMode>(
        segments: const [
          ButtonSegment(
            value: AssistMode.suggestions,
            label: Text('建议回复', style: TextStyle(fontSize: 12.5)),
          ),
          ButtonSegment(
            value: AssistMode.impersonate,
            label: Text('替我说一句', style: TextStyle(fontSize: 12.5)),
          ),
          ButtonSegment(
            value: AssistMode.off,
            label: Text('都关闭', style: TextStyle(fontSize: 12.5)),
          ),
        ],
        selected: {_assistMode},
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          textStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 12.5),
          ),
        ),
        onSelectionChanged: (selection) {
          final v = selection.first;
          setState(() => _assistMode = v);
          AppSettings.assistMode = v;
        },
      ),
      const SizedBox(height: 6),
      Text(
        _assistMode.summary,
        style: TextStyle(
          fontSize: AppType.caption,
          height: 1.45,
          color: scheme.onSurfaceVariant,
        ),
      ),
      const Divider(height: 1),
      _switchRow(
        title: '长对话自动摘要',
        subtitle: '对话太长时把早期内容压成摘要，后台静默执行'
            '（会额外调用一次模型、消耗 token）',
        value: _autoSummarize,
        onChanged: (v) {
          setState(() => _autoSummarize = v);
          AppSettings.autoSummarize = v;
        },
      ),
      const Divider(height: 1),
      _actionRow(
        title: '自动摘要怎么工作',
        subtitle: '什么时候触发、会不会多花 token、怎么关掉',
        trailing: _chevron(scheme),
        onTap: _showSummaryExplain,
      ),
      const Divider(height: 1),
      _actionRow(
        title: '用量与费用',
        subtitle: _priceSummary(),
        trailing: _chevron(scheme),
        onTap: _showPriceDialog,
      ),

      // -------------------------------------------------- 显示 --
      const SizedBox(height: 8),
      const SectionHeader('显示'),
      _actionRow(
        title: '对话排版',
        subtitle:
            '当前 ${AppSettings.chatLayout.label}：${AppSettings.chatLayout.description}',
        trailing: _chevron(scheme),
        onTap: _openChatLayout,
      ),
      const Divider(height: 1),
      _actionRow(
        title: '聊天气泡字号',
        subtitle: '当前 ${AppSettings.chatFontSize.round()}sp · 点按可调',
        trailing: _chevron(scheme),
        onTap: _openFontSize,
      ),
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
      _actionRow(
        title: '快捷回复管理',
        subtitle: '${AppSettings.quickReplies.length} 条 · 常驻入口，可先配置再打开上面的开关',
        trailing: _chevron(scheme),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const QuickRepliesScreen()),
          );
          // 返回后刷新条数（页面内自行持久化）
          if (mounted) setState(() {});
        },
      ),
      const Divider(height: 1),
      _actionRow(
        title: '显示正则',
        subtitle: '只改看到的内容：导入 ST 正则、开关、替换前后对比（v0.29.0）',
        trailing: _chevron(scheme),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DisplayRegexScreen()),
          );
          if (mounted) setState(() {});
        },
      ),
    ];
  }

  /// 对话排版：气泡 / 小说（v0.37.0，只改显示）。
  void _openChatLayout() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '对话排版',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                '只影响看到的样子：聊天记录、发给模型的提示词都不会变。',
                style: TextStyle(
                  fontSize: AppType.caption,
                  height: 1.45,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              for (final layout in ChatLayout.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: AppSettings.chatLayout == layout
                        ? Theme.of(ctx)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.08)
                        : Theme.of(ctx).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        setState(() => AppSettings.chatLayout = layout);
                        Navigator.of(ctx).pop();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        child: Row(
                          children: [
                            Icon(
                              layout == ChatLayout.bubble
                                  ? Icons.chat_bubble_outline
                                  : Icons.menu_book_outlined,
                              size: 20,
                              color: Theme.of(ctx).colorScheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    layout.label,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    layout.description,
                                    style: TextStyle(
                                      fontSize: AppType.caption,
                                      color: Theme.of(ctx)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (AppSettings.chatLayout == layout)
                              Icon(Icons.check,
                                  size: 18,
                                  color: Theme.of(ctx).colorScheme.primary),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 字号调节放二级页里用滑条（首页只显示当前值）。
  void _openFontSize() {
    var size = _chatFontSize;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '聊天气泡字号',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  Slider(
                    value: size.round().clamp(13, 20).toDouble(),
                    min: 13,
                    max: 20,
                    divisions: 7,
                    label: '${size.round()}sp',
                    onChanged: (v) {
                      setSheet(() => size = v.roundToDouble());
                      setState(() => _chatFontSize = size);
                      AppSettings.chatFontSize = size;
                    },
                  ),
                  Text(
                    '这句话用当前字号显示，拖动滑条试试',
                    style: TextStyle(fontSize: size, height: 1.5),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // -------------------------------------- 角色卡市场与翻译（二级） --

  List<Widget> _marketChildren(ColorScheme scheme) {
    return [
      const SectionHeader('角色卡市场'),
      _switchRow(
        title: '显示 NSFW 内容',
        subtitle: '默认关闭：市场只显示全年龄内容；打开后包含成人向角色卡',
        value: _showNsfw,
        onChanged: (v) {
          setState(() => _showNsfw = v);
          AppSettings.showNsfw = v;
        },
      ),
      const SectionHeader('翻译'),
      _SubLine(
        '角色卡和市场里的「译」按钮会用免费翻译。默认顺序：'
        '必应（Azure Key）→ 本地 LibreTranslate → 必应网页版 → MyMemory → Google。',
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _libreUrlCtrl,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: '本地 LibreTranslate 地址（可留空）',
          hintText: '例如 http://192.168.0.10:5000',
          helperText: '在电脑上跑 LibreTranslate 后填电脑的局域网地址；手机和电脑要连同一个 WiFi',
        ),
        onChanged: (v) => AppSettings.libreTranslateUrl = v,
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _libreKeyCtrl,
        decoration: const InputDecoration(
          labelText: 'LibreTranslate api_key（一般不用填）',
          helperText: '自建实例通常不校验；公共实例可能要求，按实例的配置填',
        ),
        onChanged: (v) => AppSettings.libreTranslateKey = v,
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _azureKeyCtrl,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: '必应翻译 Key（Azure，可留空）',
          hintText: '填了就用它翻译，速度和质量最稳',
          helperText: 'Azure 翻译免费层每月 200 万字符；留空则用免 Key 的免费源',
        ),
        onChanged: (v) => AppSettings.azureTranslatorKey = v,
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _azureRegionCtrl,
        decoration: const InputDecoration(
          labelText: '区域（可选）',
          hintText: '例如 eastasia；有的 Key 需要填',
        ),
        onChanged: (v) => AppSettings.azureTranslatorRegion = v,
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => openExternalLink(
            context,
            'https://portal.azure.com/#create/Microsoft.CognitiveServicesTextTranslation',
            title: '申请 Azure 翻译 Key',
          ),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('去申请必应（Azure）翻译 Key'),
        ),
      ),
    ];
  }

  // -------------------------------------------------- 世界书（二级） --

  List<Widget> _worldBookChildren(ColorScheme scheme) {
    return [
      const SectionHeader('世界书'),
      _actionRow(
        title: '导入世界书',
        subtitle: 'SillyTavern 格式，聊天时按关键词自动注入',
        onTap: _importWorldBook,
      ),
      _actionRow(
        title: '世界书绑定',
        subtitle: '全局 / 人设 / 角色 / 这段聊天，分别绑定（v0.27.0）',
        onTap: _openWorldBookBindings,
      ),
      for (final (id, book) in _worldBooks) ...[
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => _openWorldBookEntries(id, book),
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
    ];
  }

  // ---------------------------------------------------- 外观（二级） --

  List<Widget> _appearanceChildren(ColorScheme scheme) {
    return [
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
    ];
  }

  // ---------------------------------------------------- 帮助（二级） --

  List<Widget> _helpChildren(ColorScheme scheme) {
    return [
      const SectionHeader('帮助与关于'),
      _actionRow(
        title: '检查更新',
        subtitle: '当前 v$kAppVersion · 有新版本时直接下载安装',
        trailing: _chevron(scheme),
        onTap: () => checkUpdatesManually(context),
      ),
      const Divider(height: 1),
      _switchRow(
        title: '启动时自动检查更新',
        subtitle: '每天最多查一次；只在有新版本时提示，不会打断你',
        value: _autoCheckUpdates,
        onChanged: (v) {
          setState(() => _autoCheckUpdates = v);
          AppSettings.autoCheckUpdates = v;
        },
      ),
      const Divider(height: 1),
      _actionRow(
        title: '备份与恢复',
        subtitle: '打包角色卡 / 聊天 / 世界书 / 设置成 .zip，换手机可还原',
        trailing: _chevron(scheme),
        onTap: () => showBackupSheet(context),
      ),
      const Divider(height: 1),
      _actionRow(
        title: '重看新手引导',
        subtitle: '从零开始再过一遍：拿 Key、配模型、导入角色',
        trailing: _chevron(scheme),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const OnboardingScreen()),
          );
        },
      ),
      const Divider(height: 1),
      _actionRow(
        title: '关于',
        subtitle: '版本 v$kAppVersion · 作者 Alorith',
        trailing: _chevron(scheme),
        onTap: _showAbout,
      ),
      const SizedBox(height: 10),
      const _SubLine('聊天记录、角色卡、配置都只存在这台手机里，卸载应用会一起删除。'),
    ];
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
    IconData? leading,
  required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            if (leading != null) ...[
    Icon(leading, size: 20, color: scheme.onSurfaceVariant),
    const SizedBox(width: 12),
    ],
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('版本 v$kAppVersion'),
            const SizedBox(height: 10),
            const Text('简洁明了的 AI 角色扮演聊天 App，兼容 SillyTavern 角色卡与世界书。'),
            const SizedBox(height: 10),
            Text(
              '作者：Alorith',
              style: TextStyle(
                fontSize: AppType.body,
                color: Theme.of(ctx).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'https://github.com/Alorith-H/LiteTavern',
              style: TextStyle(
                fontSize: AppType.caption,
                color: Theme.of(ctx).colorScheme.primary,
              ),
            ),
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

/// 用量与费用弹窗：自己持有控制器，随路由一起销毁，避免「controller used after dispose」。
class _PriceDialog extends StatefulWidget {
  const _PriceDialog();

  @override
  State<_PriceDialog> createState() => _PriceDialogState();
}

class _PriceDialogState extends State<_PriceDialog> {
  late final TextEditingController _iCtrl;
  late final TextEditingController _oCtrl;
  late final TextEditingController _cCtrl;

  @override
  void initState() {
    super.initState();
    String fmt(double v) => v > 0 ? '$v' : '';
    _iCtrl = TextEditingController(text: fmt(AppSettings.priceInputPerMillion));
    _oCtrl = TextEditingController(text: fmt(AppSettings.priceOutputPerMillion));
    _cCtrl = TextEditingController(text: fmt(AppSettings.priceCachedPerMillion));
  }

  @override
  void dispose() {
    _iCtrl.dispose();
    _oCtrl.dispose();
    _cCtrl.dispose();
    super.dispose();
  }

  double _parse(TextEditingController c) {
    final v = double.tryParse(c.text.trim());
    return v == null || v < 0 ? 0 : v;
  }

  void _save() {
    Navigator.pop<({double input, double output, double cached})>(
      context,
      (input: _parse(_iCtrl), output: _parse(_oCtrl), cached: _parse(_cCtrl)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('用量与费用'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '填入服务商的单价（每 100 万 token 的价格），'
              '聊天统计里就会顺带算出估算花费。留空则只显示 token。',
              style: TextStyle(fontSize: 12, height: 1.45),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _iCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: '输入价格 / 百万 token',
                hintText: '例如 0.28',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _oCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: '输出价格 / 百万 token',
                hintText: '例如 0.42',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _cCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: '缓存命中输入价（可选）',
                hintText: '留空 = 跟输入价一样',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
