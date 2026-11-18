import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/character_card.dart';
import '../services/card_downloader.dart';
import '../services/card_importer.dart';
import '../services/card_market.dart';
import '../widgets/common.dart';

/// 角色卡市场（v0.11.0）：搜索公开角色卡库、看图文详情、一键下载入库。
///
/// 交互：顶部搜索（400ms 防抖，空关键词 = 热门）→ 筛选行（排序/标签/长度）
/// → 两列封面网格（滚动到底自动加载下一页）→ 点卡片看详情 → 下载并导入。
/// 入库走 [importCardBytes]（与文件导入/链接下载同一条路径）。
class CardMarketScreen extends StatefulWidget {
  const CardMarketScreen({super.key});

  @override
  State<CardMarketScreen> createState() => _CardMarketScreenState();
}

class _CardMarketScreenState extends State<CardMarketScreen> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _client = CardMarketClient();
  final List<MarketCard> _cards = [];

  Timer? _debounce;

  /// 请求代次：关键词/筛选/刷新会让旧响应作废（防竞态覆盖）。
  int _seq = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _page = 1;
  int _total = 0;
  String _query = '';

  /// 当前筛选条件（排序 / 标签 / token 长度）。
  MarketFilters _filters = MarketFilters.none;

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
    _client.dispose();
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

  Future<void> _pickTopics() async {
    final tags = await showDialog<List<String>>(
      context: context,
      builder: (_) => _TopicFilterDialog(initial: _filters.topics),
    );
    if (tags == null || !mounted) return;
    _applyFilters(_filters.copyWith(topics: tags));
  }

  Future<void> _pickTokenRange() async {
    final range = await showModalBottomSheet<_TokenRange>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) =>
          _TokenRangeSheet(current: _TokenRange.fromFilters(_filters)),
    );
    if (range == null || !mounted) return;
    _applyFilters(
      _filters.copyWith(minTokens: range.minTokens, maxTokens: range.maxTokens),
    );
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
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        if (replace) _cards.clear();
        _cards.addAll(result.cards);
        _total = result.total;
        _page = page;
        _loading = false;
      });
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openDetail(MarketCard card) async {
    final imported = await showModalBottomSheet<CharacterCard>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _CardDetailSheet(card: card, client: _client),
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
            child: TextField(
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
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          _buildFilterBar(scheme),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Icon(Icons.public, size: 13, color: scheme.onSurfaceVariant),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '数据来自 ${_client.source.name} · 仅显示 SFW 内容，'
                    '角色卡与图片版权归原作者所有',
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

  /// 筛选行：排序 ChoiceChip（相关/热门/新上架）+ 标签、长度弹出入口 + 清除。
  Widget _buildFilterBar(ColorScheme scheme) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _sortChip('相关', 'relevance'),
          const SizedBox(width: 6),
          _sortChip('热门', 'popular'),
          const SizedBox(width: 6),
          _sortChip('新上架', 'newest'),
          const SizedBox(width: 10),
          _entryChip(
            scheme: scheme,
            icon: Icons.sell_outlined,
            label: _filters.topics.isEmpty
                ? '标签'
                : '标签：${_filters.topics.join('+')}',
            active: _filters.topics.isNotEmpty,
            onPressed: _pickTopics,
          ),
          const SizedBox(width: 6),
          _entryChip(
            scheme: scheme,
            icon: Icons.straighten_outlined,
            label: _tokenRangeLabel(),
            active: _filters.minTokens != null || _filters.maxTokens != null,
            onPressed: _pickTokenRange,
          ),
          if (_filters.isNotEmpty) ...[
            const SizedBox(width: 2),
            Center(
              child: TextButton(
                onPressed: () => _applyFilters(MarketFilters.none),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: scheme.onSurfaceVariant,
                  textStyle: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(fontSize: 12),
                ),
                child: const Text('清除'),
              ),
            ),
          ],
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _sortChip(String label, String sort) {
    return Center(
      child: ChoiceChip(
        label: Text(label),
        selected: _filters.sort == sort,
        onSelected: (_) => _applyFilters(_filters.copyWith(sort: sort)),
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelStyle: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _entryChip({
    required ColorScheme scheme,
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onPressed,
  }) {
    return Center(
      child: ActionChip(
        avatar: Icon(
          icon,
          size: 15,
          color: active ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
        ),
        label: Text(label, maxLines: 1),
        onPressed: onPressed,
        backgroundColor: active ? scheme.secondaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelStyle: TextStyle(
          fontSize: 12,
          color: active ? scheme.onSecondaryContainer : null,
        ),
      ),
    );
  }

  /// 长度入口文案：不限时只显示「长度」，否则显示当前预设。
  String _tokenRangeLabel() {
    final range = _TokenRange.fromFilters(_filters);
    return range == _TokenRange.any ? '长度' : '长度：${range.shortLabel}';
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
      child: GridView.builder(
        controller: _scrollCtrl,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 12,
          childAspectRatio: 0.62,
        ),
        itemCount: _cards.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _cards.length) {
            return const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          final card = _cards[index];
          return _MarketCardTile(card: card, onTap: () => _openDetail(card));
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
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

/// 网格里的卡片：封面 + 名字 + 作者。
class _MarketCardTile extends StatelessWidget {
  final MarketCard card;
  final VoidCallback onTap;

  const _MarketCardTile({required this.card, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: MarketCover(url: card.thumbnailUrl),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            card.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            card.creator.isEmpty ? '佚名' : '@${card.creator}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
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

/// 卡片详情弹层：封面 + 元信息 + 标签 + 简介 + 下载导入。
class _CardDetailSheet extends StatefulWidget {
  final MarketCard card;
  final CardMarketClient client;

  const _CardDetailSheet({required this.card, required this.client});

  @override
  State<_CardDetailSheet> createState() => _CardDetailSheetState();
}

class _CardDetailSheetState extends State<_CardDetailSheet> {
  bool _downloading = false;
  String? _error;

  Future<void> _import() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      final Uint8List bytes = await widget.client.download(widget.card);
      final imported = await importCardBytes(
        bytes,
        filename: '${widget.card.name}.png',
      );
      if (!mounted) return;
      Navigator.of(context).pop(imported);
    } on CardDownloadException catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = e.message;
        });
      }
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = '卡文件解析失败：${e.message}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = '导入失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = widget.card;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    final description = card.description.isEmpty ? card.summary : card.description;
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
                      Text(
                        card.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
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
                          _Stat(icon: Icons.star_outline, text: '${card.stars}'),
                          _Stat(
                            icon: Icons.text_fields,
                            text: '${card.tokens} tokens',
                          ),
                          _Stat(
                            icon: Icons.forum_outlined,
                            text: '${card.chats} 对话',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (card.topics.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in card.topics.take(10))
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
                        t,
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
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _downloading ? null : _import,
                icon: _downloading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined),
                label: Text(_downloading ? '下载中…' : '下载并导入'),
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

/// 标签筛选对话框：英文逗号分隔，去空、去重，最多 3 个。
class _TopicFilterDialog extends StatefulWidget {
  final List<String> initial;

  const _TopicFilterDialog({required this.initial});

  @override
  State<_TopicFilterDialog> createState() => _TopicFilterDialogState();
}

class _TopicFilterDialogState extends State<_TopicFilterDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial.join(','));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(MarketFilters.parseTopics(_ctrl.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('标签筛选'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          hintText: '英文标签，如 Fantasy,OC',
          helperText: '多个标签用逗号分隔（需同时满足），最多 3 个',
          helperMaxLines: 2,
          isDense: true,
          border: OutlineInputBorder(),
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
}

/// 长度筛选预设（对应卡片 tokens 数）。
enum _TokenRange {
  any('不限', '不限', null, null),
  short('短（<1k tokens）', '短', null, 999),
  medium('中（1k–3k tokens）', '中', 1000, 3000),
  long('长（>3k tokens）', '长', 3001, null);

  const _TokenRange(
    this.label,
    this.shortLabel,
    this.minTokens,
    this.maxTokens,
  );

  /// 弹窗里的完整文案。
  final String label;

  /// 筛选行 chip 上的短文案。
  final String shortLabel;

  final int? minTokens;
  final int? maxTokens;

  /// 由筛选项反推当前预设（不匹配时按「不限」）。
  static _TokenRange fromFilters(MarketFilters filters) {
    for (final range in values) {
      if (range.minTokens == filters.minTokens &&
          range.maxTokens == filters.maxTokens) {
        return range;
      }
    }
    return any;
  }
}

/// 长度筛选底部弹窗：不限 / 短 / 中 / 长。
class _TokenRangeSheet extends StatelessWidget {
  final _TokenRange current;

  const _TokenRangeSheet({required this.current});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '按长度筛选',
              style: TextStyle(
                fontSize: AppType.section,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final range in _TokenRange.values)
            ListTile(
              dense: true,
              leading: Icon(
                range == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: range == current
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              title: Text(range.label, style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(context).pop(range),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
