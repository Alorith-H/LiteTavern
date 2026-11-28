import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/card_translation.dart';
import '../models/character_card.dart';
import '../services/card_downloader.dart';
import '../services/card_importer.dart';
import '../services/card_localizer.dart';
import '../services/card_market.dart';
import '../services/market_translation.dart';
import '../services/storage.dart';
import '../services/token_estimate.dart';
import '../services/translator.dart';
import '../widgets/common.dart';

/// 角色卡市场（v0.11.x）：搜索公开角色卡库、看图文详情、一键下载入库。
///
/// 交互：顶部搜索（400ms 防抖，空关键词 = 热门）+「筛选」按钮（排序 / 标签 /
/// 排除标签 / 语言 / 长度 / 最少标签数 / 高级开关）→ 单列纵向列表（滚动到底
/// 自动加载下一页）→ 点行看详情 → 下载并导入。
///
/// 译文：列表只读本地缓存（[MarketTranslationService.cached]），点行内「译」
/// 才真正发请求；免费源全挂时报价确认后才动模型额度。导入后若卡不是中文，
/// 再询问是否本地化（[CardLocalizer]），本地化失败不阻断导入。
///
/// 入库走 [importCardBytes]（与文件导入/链接下载同一条路径）。
class CardMarketScreen extends StatefulWidget {
  /// 数据源（测试可注入 fake；默认 Chub.ai）。
  final CardMarketSource? source;

  /// 完整客户端（测试可注入带 MockClient 的实例，优先级高于 [source]）。
  final CardMarketClient? client;

  /// 翻译调度（注入后市场译文与角色卡本地化共用它）。
  final TranslationService? translator;

  /// 角色卡本地化（默认用 [translator] 构造）。
  final CardLocalizer? localizer;

  const CardMarketScreen({
    super.key,
    this.source,
    this.client,
    this.translator,
    this.localizer,
  });

  @override
  State<CardMarketScreen> createState() => _CardMarketScreenState();
}

class _CardMarketScreenState extends State<CardMarketScreen> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<MarketCard> _cards = [];

  /// 市场条目译文缓存：fullPath → 译文（列表展示用）。
  final Map<String, MarketCardTranslation> _translations = {};
  final Set<String> _translating = {};

  late final CardMarketClient _client =
      widget.client ?? CardMarketClient(source: widget.source ?? const ChubSource());
  late final TranslationService _translator =
      widget.translator ?? TranslationService();
  late final MarketTranslationService _marketTranslator =
      MarketTranslationService(translator: _translator);
  late final CardLocalizer _localizer =
      widget.localizer ?? CardLocalizer(translator: _translator);

  Timer? _debounce;

  /// 请求代次：关键词/筛选/刷新会让旧响应作废（防竞态覆盖）。
  int _seq = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _page = 1;
  int _total = 0;
  String _query = '';

  /// 当前筛选条件。
  MarketFilters _filters = MarketFilters.none;

  /// 标签目录只拉一次（失败时客户端已回退内置列表）。
  List<MarketTag>? _tagCatalog;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _searchCtrl.addListener(_onQueryChanged);
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollCtrl.removeListener(_onScroll);
    _searchCtrl.removeListener(_onQueryChanged);
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    // 注入的客户端归调用方所有，避免测试里被悄悄关掉。
    if (widget.client == null) _client.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    setState(() {}); // 刷新输入框清除按钮
    final q = _searchCtrl.text.trim();
    if (q == _query) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _query = q;
      _reload();
    });
  }

  Future<void> _reload() => _load(page: 1, replace: true);

  /// 应用新的筛选条件：页码回 1、列表重置（[_seq] 竞态机制沿用）。
  void _applyFilters(MarketFilters next) {
    if (next == _filters) return;
    setState(() {
      _filters = next;
      _page = 1;
    });
    _reload();
  }

  /// 生效中的筛选条件数量（「筛选」按钮上的 badge）。
  int get _activeFilterCount {
    var count = 0;
    if (_filters.sort != 'relevance') count++;
    if (_filters.ascending) count++;
    if (_filters.tags.isNotEmpty) count++;
    if (_filters.excludeTags.isNotEmpty) count++;
    if (_filters.language.isNotEmpty) count++;
    if (_filters.minTokens != null || _filters.maxTokens != null) count++;
    if (_filters.minTags != null) count++;
    if (_filters.requireImages) count++;
    if (_filters.requireLore) count++;
    if (_filters.requireExpressions) count++;
    return count;
  }

  Future<List<MarketTag>> _fetchTagCatalog() async {
    final cached = _tagCatalog;
    if (cached != null) return cached;
    final tags = await _client.fetchTags();
    _tagCatalog = tags;
    return tags;
  }

  Future<void> _openFilterSheet() async {
    final next = await showModalBottomSheet<MarketFilters>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) =>
          _FilterSheet(initial: _filters, loadTags: _fetchTagCatalog),
    );
    if (next == null || !mounted) return;
    _applyFilters(next);
  }

  Future<void> _load({required int page, required bool replace}) async {
    final seq = ++_seq;
    if (replace) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final result = await _client.search(
        query: _query,
        page: page,
        filters: _filters,
        showNsfw: AppSettings.showNsfw,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        if (replace) _cards.clear();
        _cards.addAll(result.cards);
        _total = result.total;
        _page = page;
        _loading = false;
      });
      unawaited(_hydrateTranslations(seq));
    } on CardMarketException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        if (replace) _error = e.message;
      });
      if (!replace) _toast(e.message);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        if (replace) _error = '加载失败：$e';
      });
    }
  }

  /// 并发读当前页每张卡的本地译文缓存（只读，不发网络请求）。
  Future<void> _hydrateTranslations(int seq) async {
    final pending = [
      for (final card in _cards)
        if (!_translations.containsKey(card.fullPath)) card,
    ];
    if (pending.isEmpty) return;
    final found = <String, MarketCardTranslation>{};
    await Future.wait(
      pending.map((card) async {
        try {
          final cached = await _marketTranslator.cached(card);
          if (cached != null) found[card.fullPath] = cached;
        } catch (_) {
          // 读缓存失败：保持原文即可，不要影响列表
        }
      }),
    );
    if (!mounted || seq != _seq || found.isEmpty) return;
    setState(() => _translations.addAll(found));
  }

  /// 点行内「译」：免费优先，免费全挂时报价确认后改用模型额度。
  Future<void> _translateCard(MarketCard card) async {
    if (_translating.contains(card.fullPath)) return;
    setState(() => _translating.add(card.fullPath));
    try {
      final translation = await _marketTranslator.translate(card);
      if (!mounted) return;
      setState(() {
        _translations[card.fullPath] = translation;
        _translating.remove(card.fullPath);
      });
    } on TranslationUnavailable catch (e) {
      if (!mounted) return;
      setState(() => _translating.remove(card.fullPath));
      final tokens = formatTokenCount(
        MarketTranslationService.estimateTokensFor([card]),
      );
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('免费翻译暂不可用'),
          content: Text(
            '${e.message}\n\n用设置中的模型翻译预计约 $tokens tokens，'
            '将使用设置中的模型额度。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('用模型翻译（≈$tokens tokens）'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _translating.add(card.fullPath));
      try {
        final translation = await _marketTranslator.translate(
          card,
          allowLlm: true,
        );
        if (!mounted) return;
        setState(() {
          _translations[card.fullPath] = translation;
          _translating.remove(card.fullPath);
        });
      } catch (err) {
        if (!mounted) return;
        setState(() => _translating.remove(card.fullPath));
        _toast('翻译失败：$err');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _translating.remove(card.fullPath));
      _toast('翻译失败：$e');
    }
  }

  bool get _hasMore => _cards.length < _total;

  void _onScroll() {
    if (!_scrollCtrl.hasClients || _loading || _loadingMore || !_hasMore) {
      return;
    }
    if (_scrollCtrl.position.extentAfter > 500) return;
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      await _load(page: _page + 1, replace: false);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  Future<void> _openDetail(MarketCard card) async {
    final imported = await showModalBottomSheet<CharacterCard>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _CardDetailSheet(
        card: card,
        client: _client,
        localizer: _localizer,
        translation: _translations[card.fullPath],
      ),
    );
    if (imported == null || !mounted) return;
    _toast('已导入「${imported.name}」，返回主页即可开始聊天');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('角色卡市场')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(child: _buildSearchField()),
                const SizedBox(width: 8),
                _buildFilterButton(scheme),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Icon(Icons.public, size: 13, color: scheme.onSurfaceVariant),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    AppSettings.showNsfw
                        ? '角色卡来自 ${_client.source.name}。成人向内容也显示，'
                              '觉得不合适就去 设置 → 角色卡市场 关掉'
                        : '角色卡来自 ${_client.source.name}。现在只显示全年龄内容，'
                              '想看更多可以去 设置 → 角色卡市场 打开',
                    style: TextStyle(
                      fontSize: AppType.meta,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody(scheme)),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _searchCtrl,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) {
        _debounce?.cancel();
        _query = _searchCtrl.text.trim();
        _reload();
      },
      decoration: InputDecoration(
        hintText: '搜索角色卡（英文关键词/标签效果更好）',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searchCtrl.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清除',
                icon: const Icon(Icons.clear),
                onPressed: _searchCtrl.clear,
              ),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// 「筛选」按钮：生效中的条件数以 badge 显示。
  Widget _buildFilterButton(ColorScheme scheme) {
    final count = _activeFilterCount;
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        onPressed: _openFilterSheet,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tune, size: 18),
            const SizedBox(width: 4),
            const Text('筛选', style: TextStyle(fontSize: 13)),
            if (count > 0) ...[
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: scheme.onPrimary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading && _cards.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null && _cards.isEmpty) {
      return _StatusView(
        icon: Icons.cloud_off_outlined,
        title: '加载失败',
        message: error,
        actionLabel: '重试',
        onAction: _reload,
      );
    }
    if (_cards.isEmpty) {
      return _StatusView(
        icon: Icons.travel_explore_outlined,
        title: '没有找到角色卡',
        message: _filters.isNotEmpty
            ? '当前筛选条件下没有结果，试试放宽标签或长度限制'
            : _query.isEmpty
            ? '换个网络再试试，或稍后刷新'
            : '试试更短的关键词，例如角色名、题材或标签',
        actionLabel: '刷新',
        onAction: _reload,
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        controller: _scrollCtrl,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: _cards.length + (_loadingMore ? 1 : 0),
        separatorBuilder: (_, _) => Divider(
          height: 1,
          color: scheme.outlineVariant,
        ),
        itemBuilder: (context, index) {
          if (index >= _cards.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final card = _cards[index];
          return _MarketCardRow(
            card: card,
            translation: _translations[card.fullPath],
            translating: _translating.contains(card.fullPath),
            onTap: () => _openDetail(card),
            onTranslate: () => _translateCard(card),
          );
        },
      ),
    );
  }
}

/// 空态 / 错误态：图标 + 标题 + 说明 + 按钮。
class _StatusView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _StatusView({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

/// NSFW 标注：市场展示全部内容，敏感卡在列表/详情里明确标出。
class _NsfwBadge extends StatelessWidget {
  const _NsfwBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.error.withValues(alpha: 0.65)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'NSFW',
        style: TextStyle(
          fontSize: 9.5,
          height: 1.2,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: scheme.error,
        ),
      ),
    );
  }
}

/// 单列列表的一行：封面 + 原名/译名 + 简介 + 标签 + 作者/星数/对话数 + 「译」。
class _MarketCardRow extends StatelessWidget {
  final MarketCard card;
  final MarketCardTranslation? translation;
  final bool translating;
  final VoidCallback onTap;
  final VoidCallback onTranslate;

  const _MarketCardRow({
    required this.card,
    required this.translation,
    required this.translating,
    required this.onTap,
    required this.onTranslate,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = translation;
    final translatedName = (t != null && t.name.trim().isNotEmpty)
        ? t.name.trim()
        : null;
    final summary = (t != null && t.description.trim().isNotEmpty)
        ? t.description.trim()
        : card.summary;
    final tags = (t != null && t.tags.isNotEmpty) ? t.tags : card.topics;
    final shown = tags.take(4).toList();
    final extra = tags.length - shown.length;
    final creator = card.creator.isEmpty ? '佚名' : '@${card.creator}';
    final meta =
        '$creator · ★ ${formatTokenCount(card.stars)} · '
        '${formatTokenCount(card.chats)} 对话';

    Widget tagChip(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
      ),
    );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 64,
                height: 86,
                child: MarketCover(url: card.thumbnailUrl),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    card.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (card.nsfw) ...[
                                  const SizedBox(width: 6),
                                  const _NsfwBadge(),
                                ],
                              ],
                            ),
                            if (translatedName != null &&
                                translatedName != card.name) ...[
                              const SizedBox(height: 1),
                              Text(
                                translatedName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      _buildTranslateButton(scheme),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    summary,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (shown.isNotEmpty || extra > 0) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final tag in shown) tagChip(tag),
                        if (extra > 0) tagChip('+$extra'),
                      ],
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.meta,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTranslateButton(ColorScheme scheme) {
    if (translating) {
      return const SizedBox(
        width: 34,
        height: 26,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final hasTranslation = translation != null;
    return TextButton(
      onPressed: onTranslate,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 26),
        padding: const EdgeInsets.symmetric(horizontal: 7),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: hasTranslation
            ? scheme.primary
            : scheme.onSurfaceVariant,
        textStyle: const TextStyle(fontSize: 12),
      ),
      child: const Text('译'),
    );
  }
}

/// 网络封面图：加载中显示底色，失败显示占位图标；限制解码宽度省内存。
class MarketCover extends StatelessWidget {
  final String url;
  final BoxFit fit;

  const MarketCover({super.key, required this.url, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.image_outlined,
          size: 28,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    if (url.isEmpty) return placeholder;
    return Image.network(
      url,
      fit: fit,
      width: double.infinity,
      height: double.infinity,
      cacheWidth: 480,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(color: scheme.surfaceContainerHighest);
      },
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}

/// 卡片详情弹层：封面 + 元信息 + 标签 + 简介 + 下载导入（含中文卡询问题）。
class _CardDetailSheet extends StatefulWidget {
  final MarketCard card;
  final CardMarketClient client;
  final CardLocalizer localizer;
  final MarketCardTranslation? translation;

  const _CardDetailSheet({
    required this.card,
    required this.client,
    required this.localizer,
    this.translation,
  });

  @override
  State<_CardDetailSheet> createState() => _CardDetailSheetState();
}

class _CardDetailSheetState extends State<_CardDetailSheet> {
  bool _downloading = false;

  /// 下载完之后正在翻译（v0.21.2）：按钮与进度条显示「正在翻译…」。
  bool _translating = false;
  String? _error;
  int _receivedBytes = 0;
  int? _totalBytes;

  /// 已下载百分比（服务端没给 Content-Length 时为 null，展示不确定进度）。
  double? get _progress {
    final total = _totalBytes;
    if (total == null || total <= 0) return null;
    return (_receivedBytes / total).clamp(0.0, 1.0);
  }

  String get _downloadLabel {
    final progress = _progress;
    if (progress == null) {
      final kb = _receivedBytes ~/ 1024;
      return kb > 0 ? '下载中 $kb KB' : '下载中…';
    }
    return '下载中 ${(progress * 100).floor()}%';
  }

  void _onDownloadProgress(int received, int? total) {
    if (!mounted) return;
    final known = total != null && total > 0 ? total : null;
    // 已知总长按 1% 节流；未知总长按 64KB 节流，避免高频 setState。
    if (known != null) {
      final before = _progress;
      if (before != null &&
          (received / known * 100).floor() == (before * 100).floor()) {
        return;
      }
    } else if (received - _receivedBytes < 64 * 1024 && received > 0) {
      return;
    }
    setState(() {
      _receivedBytes = received;
      _totalBytes = known;
    });
  }

  Future<void> _import() async {
    if (_downloading || _translating) return;
    setState(() {
      _downloading = true;
      _translating = false;
      _error = null;
      _receivedBytes = 0;
      _totalBytes = null;
    });
    try {
      final Uint8List bytes = await widget.client.download(
        widget.card,
        onProgress: _onDownloadProgress,
      );
      var imported = await importCardBytes(
        bytes,
        filename: '${widget.card.name}.png',
      );
      if (!mounted) return;
      // 下载 + 解析完成，进度条收起；接下来若翻译，会显示「正在翻译…」。
      setState(() => _downloading = false);
      // 非中文卡：问一下要不要翻成中文（失败不阻断导入，回落原卡）。
      if (!looksChinese('${imported.name} ${imported.description}')) {
        final localized = await _askAndLocalize(imported);
        if (!mounted) return;
        if (localized != null) {
          try {
            // 同 id 覆盖：把入库的卡换成译文版（头像等资源不变）。
            await Storage.saveCharacter(localized);
            imported = localized;
          } catch (_) {
            // 译文版落盘失败：仍按原文卡导入
          }
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(imported);
    } on CardDownloadException catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _translating = false;
          _error = e.message;
        });
      }
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _translating = false;
          _error = '卡文件解析失败：${e.message}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _translating = false;
          _error = '导入失败：$e';
        });
      }
    }
  }

  /// 询问并执行本地化；返回 null 表示「不翻译 / 翻译失败，用原卡」。
  Future<CharacterCard?> _askAndLocalize(CharacterCard card) async {
    final tokens = formatTokenCount(CardLocalizer.estimateTokens(card));
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这张角色卡不是中文'),
        content: Text(
          '可以先用免费翻译翻成简体中文（不消耗模型额度），'
          '也可以用设置中的模型翻译（预计约 $tokens tokens，'
          '将使用设置中的模型额度）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('none'),
            child: const Text('不翻译'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('llm'),
            child: Text('用模型翻译（≈$tokens tokens）'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('free'),
            child: const Text('免费翻译'),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'none' || !mounted) return null;
    setState(() => _translating = true);
    try {
      return await _localizeWithFallback(card, choice: choice, tokens: tokens);
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  /// 真正跑翻译（免费优先，失败再问一次要不要用模型），失败返回 null 用原卡。
  Future<CharacterCard?> _localizeWithFallback(
    CharacterCard card, {
    required String choice,
    required String tokens,
  }) async {
    try {
      return await widget.localizer.localize(card, allowLlm: choice == 'llm');
    } on TranslationUnavailable catch (e) {
      if (!mounted) return null;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('免费翻译暂不可用'),
          content: Text(
            '${e.message}\n\n用设置中的模型翻译预计约 $tokens tokens，'
            '将使用设置中的模型额度。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('用模型翻译（≈$tokens tokens）'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return null;
      try {
        return await widget.localizer.localize(card, allowLlm: true);
      } catch (err) {
        _toast('翻译失败，已按原文导入：$err');
        return null;
      }
    } catch (e) {
      _toast('翻译失败，已按原文导入：$e');
      return null;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = widget.card;
    final t = widget.translation;
    // 下载中 / 翻译中都是「忙」：进度条 + 按钮都跟着变（v0.21.2）。
    final busy = _downloading || _translating;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    final description = (t != null && t.description.trim().isNotEmpty)
        ? t.description.trim()
        : card.description.isEmpty
        ? card.summary
        : card.description;
    final tags = (t != null && t.tags.isNotEmpty) ? t.tags : card.topics;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 104,
                    height: 138,
                    child: MarketCover(url: card.thumbnailUrl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: Text(
                              card.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                              ),
                            ),
                          ),
                          if (card.nsfw) ...[
                            const SizedBox(width: 8),
                            const Padding(
                              padding: EdgeInsets.only(top: 3),
                              child: _NsfwBadge(),
                            ),
                          ],
                        ],
                      ),
                      if (t != null && t.name.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          t.name.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        card.creator.isEmpty ? '佚名' : '@${card.creator}',
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 4,
                        children: [
                          _Stat(
                            icon: Icons.star_outline,
                            text: formatTokenCount(card.stars),
                          ),
                          _Stat(
                            icon: Icons.text_fields,
                            text: '${formatTokenCount(card.tokens)} tokens',
                          ),
                          _Stat(
                            icon: Icons.forum_outlined,
                            text: '${formatTokenCount(card.chats)} 对话',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in tags.take(10))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Text(
              description,
              style: const TextStyle(fontSize: 13.5, height: 1.55),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(fontSize: AppType.caption, color: scheme.error),
              ),
            ],
            const SizedBox(height: 18),
            if (busy) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  // 翻译时长度未知 → 不确定进度条
                  value: _translating ? null : _progress,
                  minHeight: 5,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy ? null : _import,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined),
                label: Text(
                  busy
                      ? (_translating ? '正在翻译…' : _downloadLabel)
                      : '下载并导入',
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                '数据来自 ${card.source} · 版权归原作者所有',
                style: TextStyle(
                  fontSize: AppType.meta,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Stat({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(fontSize: 11.5, color: color)),
      ],
    );
  }
}

/// 长度预设（按卡片 tokens 数）。null = 不限。
enum _TokenRange {
  any('不限', null, null),
  short('短（<1k）', null, 999),
  medium('中（1k–3k）', 1000, 3000),
  long('长（>3k）', 3001, null);

  const _TokenRange(this.label, this.minTokens, this.maxTokens);

  final String label;
  final int? minTokens;
  final int? maxTokens;
}

/// 排序选项：服务端取值 + 中文标签。
class _SortOption {
  final String value;
  final String label;

  const _SortOption(this.value, this.label);
}

const List<_SortOption> _sortOptions = <_SortOption>[
  _SortOption('relevance', '相关'),
  _SortOption('popular', '热门'),
  _SortOption('newest', '新上架'),
  _SortOption('trending', '最新趋势'),
  _SortOption('random', '随机'),
  _SortOption('name', '名称'),
];

/// 语言选项：value 空串 = 不限。
class _LanguageOption {
  final String value;
  final String label;

  const _LanguageOption(this.value, this.label);
}

const List<_LanguageOption> _languageOptions = <_LanguageOption>[
  _LanguageOption('', '全部'),
  _LanguageOption('zh', '中文'),
  _LanguageOption('en', '英文'),
  _LanguageOption('ja', '日文'),
  _LanguageOption('ko', '韩文'),
];

/// 筛选底部弹层：排序 / 标签 / 排除标签 / 语言 / 长度 / 最少标签数 / 高级。
class _FilterSheet extends StatefulWidget {
  final MarketFilters initial;
  final Future<List<MarketTag>> Function() loadTags;

  const _FilterSheet({required this.initial, required this.loadTags});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late MarketFilters _draft;
  late final TextEditingController _excludeCtrl;
  late final TextEditingController _minCtrl;
  late final TextEditingController _maxCtrl;
  int _minTags = 0;

  @override
  void initState() {
    super.initState();
    _draft = widget.initial;
    _excludeCtrl = TextEditingController(
      text: widget.initial.excludeTags.join(', '),
    );
    _minCtrl = TextEditingController(
      text: widget.initial.minTokens?.toString() ?? '',
    );
    _maxCtrl = TextEditingController(
      text: widget.initial.maxTokens?.toString() ?? '',
    );
    _minTags = widget.initial.minTags ?? 0;
  }

  @override
  void dispose() {
    _excludeCtrl.dispose();
    _minCtrl.dispose();
    _maxCtrl.dispose();
    super.dispose();
  }

  int? get _minTokens => int.tryParse(_minCtrl.text.trim());
  int? get _maxTokens => int.tryParse(_maxCtrl.text.trim());

  /// 由两个数字框反推预设；null = 自定义区间。
  _TokenRange? get _range {
    for (final range in _TokenRange.values) {
      if (range.minTokens == _minTokens && range.maxTokens == _maxTokens) {
        return range;
      }
    }
    return null;
  }

  void _selectRange(_TokenRange range) {
    setState(() {
      _minCtrl.text = range.minTokens?.toString() ?? '';
      _maxCtrl.text = range.maxTokens?.toString() ?? '';
    });
  }

  Future<void> _pickTags() async {
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) =>
          _TagPickerDialog(initial: _draft.tags, loadTags: widget.loadTags),
    );
    if (picked == null || !mounted) return;
    setState(() => _draft = _draft.copyWith(tags: picked));
  }

  void _removeTag(String tag) {
    setState(() {
      _draft = _draft.copyWith(
        tags: [
          for (final t in _draft.tags)
            if (t != tag) t,
        ],
      );
    });
  }

  void _reset() {
    setState(() {
      _draft = MarketFilters.none;
      _minTags = 0;
      _excludeCtrl.clear();
      _minCtrl.clear();
      _maxCtrl.clear();
    });
  }

  void _apply() {
    final next = _draft.copyWith(
      excludeTags: MarketFilters.parseTags(_excludeCtrl.text),
      minTokens: _minTokens,
      maxTokens: _maxTokens,
      minTags: _minTags == 0 ? null : _minTags,
    );
    Navigator.of(context).pop(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.86;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
            child: Row(
              children: [
                const Text(
                  '筛选',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '标签与开关会收窄结果',
                  style: TextStyle(
                    fontSize: AppType.meta,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              children: [
                const SectionHeader('排序'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final option in _sortOptions)
                      ChoiceChip(
                        label: Text(option.label),
                        selected: _draft.sort == option.value,
                        onSelected: (_) => setState(
                          () => _draft = _draft.copyWith(sort: option.value),
                        ),
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        labelStyle: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
                const SectionHeader('标签'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _pickTags,
                    icon: const Icon(Icons.sell_outlined, size: 16),
                    label: Text(
                      _draft.tags.isEmpty ? '选择标签' : '修改标签',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
                if (_draft.tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in _draft.tags)
                        InputChip(
                          label: Text(tag, style: const TextStyle(fontSize: 12)),
                          onDeleted: () => _removeTag(tag),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '多个标签需同时满足，最多 8 个',
                    style: TextStyle(
                      fontSize: AppType.meta,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SectionHeader('排除标签'),
                TextField(
                  controller: _excludeCtrl,
                  decoration: const InputDecoration(
                    hintText: '不想看到的标签，逗号分隔',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SectionHeader('语言'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final option in _languageOptions)
                      ChoiceChip(
                        label: Text(option.label),
                        selected: _draft.language == option.value,
                        onSelected: (_) => setState(
                          () => _draft =
                              _draft.copyWith(language: option.value),
                        ),
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        labelStyle: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
                const SectionHeader('长度'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final range in _TokenRange.values)
                      ChoiceChip(
                        label: Text(range.label),
                        selected: _range == range,
                        onSelected: (_) => _selectRange(range),
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        labelStyle: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _minCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: '最少 tokens',
                          hintText: '不限',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _maxCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: '最多 tokens',
                          hintText: '不限',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_range == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '自定义长度',
                      style: TextStyle(
                        fontSize: AppType.meta,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                const SectionHeader('最少标签数'),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _minTags == 0 ? '不限' : '至少 $_minTags 个',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    IconButton(
                      tooltip: '减少',
                      onPressed: _minTags == 0
                          ? null
                          : () => setState(() => _minTags--),
                      icon: const Icon(Icons.remove_circle_outline, size: 20),
                    ),
                    Text(
                      '$_minTags',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    IconButton(
                      tooltip: '增加',
                      onPressed: _minTags >= 5
                          ? null
                          : () => setState(() => _minTags++),
                      icon: const Icon(Icons.add_circle_outline, size: 20),
                    ),
                  ],
                ),
                const SectionHeader('高级'),
                _switchRow(
                  '需要有图',
                  _draft.requireImages,
                  (v) =>
                      setState(() => _draft = _draft.copyWith(requireImages: v)),
                ),
                _switchRow(
                  '需要有世界书',
                  _draft.requireLore,
                  (v) =>
                      setState(() => _draft = _draft.copyWith(requireLore: v)),
                ),
                _switchRow(
                  '需要有表情',
                  _draft.requireExpressions,
                  (v) => setState(
                    () => _draft = _draft.copyWith(requireExpressions: v),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _reset,
                      child: const Text('重置'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _apply,
                      child: const Text('应用'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// 标签二级弹层：先拉标签目录（缓存一次），支持搜索过滤、多选（≤8）与手输。
class _TagPickerDialog extends StatefulWidget {
  final List<String> initial;
  final Future<List<MarketTag>> Function() loadTags;

  const _TagPickerDialog({required this.initial, required this.loadTags});

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
  static const int _maxTags = 8;

  final _searchCtrl = TextEditingController();
  final _manualCtrl = TextEditingController();
  final List<String> _selected = [];

  List<MarketTag>? _catalog;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initial);
    _manualCtrl.text = widget.initial.join(', ');
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final tags = await widget.loadTags();
      if (!mounted) return;
      setState(() {
        _catalog = tags;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '标签目录加载失败：$e';
        _loading = false;
      });
    }
  }

  void _toggle(String tag) {
    setState(() {
      if (_selected.contains(tag)) {
        _selected.remove(tag);
      } else if (_selected.length < _maxTags) {
        _selected.add(tag);
      }
    });
  }

  void _submit() {
    final merged = <String>[..._selected];
    for (final tag in MarketFilters.parseTags(_manualCtrl.text, max: _maxTags)) {
      final exists = merged.any((t) => t.toLowerCase() == tag.toLowerCase());
      if (!exists && merged.length < _maxTags) merged.add(tag);
    }
    Navigator.of(context).pop(merged);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('选择标签（${_selected.length}/$_maxTags）'),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜索标签',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(child: _buildCatalog(scheme)),
            const SizedBox(height: 10),
            TextField(
              controller: _manualCtrl,
              decoration: const InputDecoration(
                hintText: '手动输入，逗号分隔，如 Fantasy, OC',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }

  Widget _buildCatalog(ColorScheme scheme) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Text(
          error,
          style: TextStyle(fontSize: AppType.caption, color: scheme.error),
        ),
      );
    }
    final query = _searchCtrl.text.trim().toLowerCase();
    final tags = [
      for (final tag in _catalog ?? const <MarketTag>[])
        if (query.isEmpty || tag.name.toLowerCase().contains(query)) tag,
    ];
    if (tags.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的标签',
          style: TextStyle(
            fontSize: AppType.caption,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return SingleChildScrollView(
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final tag in tags)
            FilterChip(
              label: Text(tag.name, style: const TextStyle(fontSize: 12)),
              selected: _selected.contains(tag.name),
              onSelected: (_) => _toggle(tag.name),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
        ],
      ),
    );
  }
}
