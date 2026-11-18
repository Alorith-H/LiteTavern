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
/// 交互：顶部搜索（400ms 防抖，空关键词 = 热门）→ 两列封面网格
/// （滚动到底自动加载下一页）→ 点卡片看详情 → 下载并导入。
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

  /// 请求代次：关键词/刷新会让旧响应作废（防竞态覆盖）。
  int _seq = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _page = 1;
  int _total = 0;
  String _query = '';

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

  Future<void> _load({required int page, required bool replace}) async {
    final seq = ++_seq;
    if (replace) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final result = await _client.search(query: _query, page: page);
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
        message: _query.isEmpty
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
