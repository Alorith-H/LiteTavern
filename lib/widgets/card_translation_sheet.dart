// 角色卡翻译弹层：把整张卡翻成简体中文，逐段对照原文/译文。
//
// 只负责展示与触发翻译：译文落库由 [CardLocalizer] 完成，表单回填走
// [onApply]，「保存」仍由编辑页负责（应用译文不会自动保存）。
import 'package:flutter/material.dart';

import '../models/card_translation.dart';
import '../models/character_card.dart';
import '../services/card_localizer.dart';
import '../services/token_estimate.dart';
import '../services/translation_store.dart';
import '../services/translator.dart';
import 'common.dart';

/// 打开角色卡翻译底部弹层。
///
/// [card] 是当前要翻译的卡（编辑页传「屏幕上的表单内容」）；
/// [onApply] 把 5 段可编辑译文回填到表单，由调用方决定落库时机。
Future<void> showCardTranslationSheet(
  BuildContext context, {
  required CharacterCard card,
  required Future<void> Function(
    String name,
    String description,
    String personality,
    String scenario,
    String firstMes,
  ) onApply,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => CardTranslationSheet(card: card, onApply: onApply),
  );
}

/// 翻译弹层内容：空状态 → 翻译中 → 译文对照；失败在弹层内提示。
class CardTranslationSheet extends StatefulWidget {
  /// 当前生效的卡（原文来源，也是翻译的输入）
  final CharacterCard card;

  /// 应用译文/恢复原文的回填回调（只填表单，不落库）
  final Future<void> Function(
    String name,
    String description,
    String personality,
    String scenario,
    String firstMes,
  ) onApply;

  const CardTranslationSheet({
    super.key,
    required this.card,
    required this.onApply,
  });

  @override
  State<CardTranslationSheet> createState() => _CardTranslationSheetState();
}

class _CardTranslationSheetState extends State<CardTranslationSheet> {
  /// 首次读本地译文时的加载态
  bool _loading = true;

  /// 翻译请求进行中（禁用按钮、按钮转圈）
  bool _translating = false;

  /// 回填表单进行中
  bool _applying = false;

  /// 失败提示（弹层内红色错误条；免费源不可用走对话框，不在这里）
  String? _error;

  /// 已有/刚翻完的译文（null = 还没有译文 → 空状态）
  CardTranslation? _translation;

  /// 当前生效卡：原文对照取自这里，重新翻译也以它为输入
  late CharacterCard _card;

  /// 本地是否有翻译前的原文备份（「恢复原文」按钮显隐）
  bool _hasOriginal = false;

  final CardLocalizer _localizer = CardLocalizer();

  @override
  void initState() {
    super.initState();
    _card = widget.card;
    _restoreSaved();
  }

  /// 打开弹层时先看本地是否已存过译文/原文备份。
  Future<void> _restoreSaved() async {
    final id = _card.id;
    CardTranslation? saved;
    var hasOriginal = false;
    if (id.isNotEmpty) {
      saved = await TranslationStore.loadCard(id);
      hasOriginal = await TranslationStore.hasOriginalCard(id);
    }
    if (!mounted) return;
    setState(() {
      _translation = saved;
      _hasOriginal = hasOriginal;
      _loading = false;
    });
  }

  // ---------------------------------------------------------- 翻译 --

  /// 翻译整张卡（7 段）；免费源全挂时报价并询问是否改用模型。
  Future<void> _translate({bool allowLlm = false}) async {
    if (_translating) return;
    setState(() {
      _translating = true;
      _error = null;
    });
    try {
      final translated = await _localizer.localize(_card, allowLlm: allowLlm);
      CardTranslation? stored;
      var hasOriginal = _hasOriginal;
      if (_card.id.isNotEmpty) {
        // 落库由 CardLocalizer 完成，重新读一次拿 provider / updatedAt
        stored = await TranslationStore.loadCard(_card.id);
        hasOriginal = await TranslationStore.hasOriginalCard(_card.id);
      }
      if (!mounted) return;
      setState(() {
        _translating = false;
        _translation = stored ?? _translationOf(translated);
        _hasOriginal = hasOriginal;
      });
    } on TranslationUnavailable catch (e) {
      if (!mounted) return;
      setState(() => _translating = false);
      final useLlm = await _confirmLlm(e);
      if (useLlm && mounted) await _translate(allowLlm: true);
    } on TranslationFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _translating = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _translating = false;
        _error = '翻译失败：$e';
      });
    }
  }

  /// 免费源全挂 → 询问是否用设置里的模型翻（按这张卡的全部文本报价）。
  Future<bool> _confirmLlm(TranslationUnavailable e) async {
    final tokens = formatTokenCount(CardLocalizer.estimateTokens(_card));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('免费翻译暂不可用'),
        content: Text(
          '${e.message}\n\n可以用设置里已配置的模型来翻译，'
          '预计消耗约 $tokens tokens（按这张卡的全部文本估算）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('用模型翻译（约 $tokens tokens）'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 没有本地译文时（draft 卡没有 id），用返回卡拼一份译文对象展示。
  CardTranslation _translationOf(CharacterCard card) => CardTranslation(
        name: card.name,
        description: card.description,
        personality: card.personality,
        scenario: card.scenario,
        firstMes: card.firstMes,
        mesExample: card.mesExample,
        tags: card.tags,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

  // ---------------------------------------------------------- 应用 --

  /// 应用译文：5 段回填表单 → 关闭弹层（不自动保存）。
  Future<void> _apply() async {
    final t = _translation;
    if (t == null || _applying || _translating) return;
    setState(() => _applying = true);
    try {
      await widget.onApply(
        t.name,
        t.description,
        t.personality,
        t.scenario,
        t.firstMes,
      );
    } finally {
      if (mounted) setState(() => _applying = false);
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('译文已填入，点保存生效')),
    );
  }

  /// 恢复原文：读翻译前的备份填回表单（只读备份，不删除译文）。
  Future<void> _restoreOriginal() async {
    final id = _card.id;
    if (id.isEmpty || _applying) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复原文'),
        content: const Text('把表单填回翻译前的原文？译文仍保留在本地，可再次应用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final original = await TranslationStore.loadOriginalCard(id);
    if (!mounted) return;
    if (original == null) {
      setState(() => _error = '没有找到原文备份，可能是备份已损坏');
      return;
    }
    setState(() => _applying = true);
    try {
      await widget.onApply(
        original.name,
        original.description,
        original.personality,
        original.scenario,
        original.firstMes,
      );
    } finally {
      if (mounted) setState(() => _applying = false);
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('已填回原文，点保存生效')),
    );
  }

  // ---------------------------------------------------------- 界面 --

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.85;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          _buildHeader(scheme),
          if (_error != null) _buildErrorBar(scheme),
          Expanded(child: _buildBody(scheme)),
          Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
          _buildActions(scheme),
        ],
      ),
    );
  }

  /// 标题「角色卡翻译」+ 译者/时间副标题。
  Widget _buildHeader(ColorScheme scheme) {
    final t = _translation;
    final meta = t == null
        ? ''
        : [
            if (t.provider.trim().isNotEmpty) '译者：${t.provider.trim()}',
            if (t.updatedAt > 0) '时间：${_formatTime(t.updatedAt)}',
          ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '角色卡翻译',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              meta,
              style: TextStyle(
                fontSize: AppType.meta,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 弹层内红色错误条（免费源不可用的对话框之外的所有失败）。
  Widget _buildErrorBar(ColorScheme scheme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.4,
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final t = _translation;
    if (t == null) return _buildEmpty(scheme);
    return _buildResult(t);
  }

  /// 空状态：说明 + 底部主按钮「翻译为中文（免费）」。
  Widget _buildEmpty(ColorScheme scheme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 8, 32, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.translate, size: 36, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            const Text(
              '把这张角色卡翻译成简体中文',
              style: TextStyle(
                fontSize: AppType.body,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '优先使用免费翻译服务（MyMemory），不会消耗你的模型额度',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '名字 / 简介 / 性格 / 场景 / 开场白 / 示例对话 / 标签都会翻译，'
              '应用时只填入本页可编辑的 5 段',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.meta,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 译文对照视图：7 段逐块对照（原文浅色可展开，译文完整显示）。
  Widget _buildResult(CardTranslation t) {
    final rows = <(String, String, String)>[
      ('名字', _card.name, t.name),
      ('简介', _card.description, t.description),
      ('性格', _card.personality, t.personality),
      ('场景', _card.scenario, t.scenario),
      ('开场白', _card.firstMes, t.firstMes),
      ('示例对话', _card.mesExample, t.mesExample),
    ];
    final blocks = <Widget>[];
    for (final (title, original, translated) in rows) {
      if (original.trim().isEmpty && translated.trim().isEmpty) continue;
      blocks.add(
        _FieldBlock(title: title, original: original, translated: translated),
      );
    }
    if (_card.tags.isNotEmpty || t.tags.isNotEmpty) {
      blocks.add(_TagsBlock(original: _card.tags, translated: t.tags));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      itemCount: blocks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, i) => blocks[i],
    );
  }

  /// 底部按钮区：主按钮（应用 / 翻译）+ 重新翻译 + 恢复原文。
  Widget _buildActions(ColorScheme scheme) {
    final hasResult = _translation != null;
    final busy = _translating || _applying;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: hasResult
                  ? FilledButton(
                      onPressed: busy ? null : _apply,
                      child: _applying
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('应用到角色卡'),
                    )
                  : FilledButton(
                      onPressed: _translating ? null : () => _translate(),
                      child: _translating
                          ? const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text('正在翻译…'),
                              ],
                            )
                          : Text(_error == null ? '翻译为中文（免费）' : '重试'),
                    ),
            ),
            if (hasResult) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: busy ? null : () => _translate(),
                  child: _translating
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 10),
                            Text('正在翻译…'),
                          ],
                        )
                      : const Text('重新翻译'),
                ),
              ),
            ],
            if (_hasOriginal)
              TextButton(
                onPressed: busy ? null : _restoreOriginal,
                child: const Text('恢复原文'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 一段字段的原文/译文对照块。
class _FieldBlock extends StatelessWidget {
  final String title;
  final String original;
  final String translated;

  const _FieldBlock({
    required this.title,
    required this.original,
    required this.translated,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasOriginal = original.trim().isNotEmpty;
    final hasTranslated = translated.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: AppType.section,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          if (hasOriginal) ...[
            _OriginalText(
              text: original,
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (hasTranslated) const SizedBox(height: 8),
          ],
          if (hasTranslated)
            Text(
              translated,
              style: const TextStyle(fontSize: AppType.body, height: 1.5),
            )
          else
            Text(
              '（这段没有译文）',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// 标签对照块：原文一排 Chip、译文一排 Chip。
class _TagsBlock extends StatelessWidget {
  final List<String> original;
  final List<String> translated;

  const _TagsBlock({required this.original, required this.translated});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '标签',
            style: TextStyle(
              fontSize: AppType.section,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (original.isNotEmpty) ...[
            const SizedBox(height: 8),
            _tagCaption(scheme, '原文'),
            const SizedBox(height: 4),
            _tagWrap(
              tags: original,
              background: scheme.surfaceContainerHighest,
              foreground: scheme.onSurfaceVariant,
            ),
          ],
          if (translated.isNotEmpty) ...[
            const SizedBox(height: 8),
            _tagCaption(scheme, '译文'),
            const SizedBox(height: 4),
            _tagWrap(
              tags: translated,
              background: scheme.primary.withValues(alpha: 0.10),
              foreground: scheme.onSurface,
            ),
          ],
        ],
      ),
    );
  }

  Widget _tagCaption(ColorScheme scheme, String text) => Text(
        text,
        style: TextStyle(fontSize: AppType.meta, color: scheme.onSurfaceVariant),
      );

  Widget _tagWrap({
    required List<String> tags,
    required Color background,
    required Color foreground,
  }) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in tags)
          Chip(
            label: Text(tag),
            labelStyle: TextStyle(fontSize: AppType.meta, color: foreground),
            backgroundColor: background,
            side: BorderSide.none,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 2),
          ),
      ],
    );
  }
}

/// 浅色原文文本：最多 6 行，超出可展开/收起。
class _OriginalText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _OriginalText({required this.text, required this.style});

  @override
  State<_OriginalText> createState() => _OriginalTextState();
}

class _OriginalTextState extends State<_OriginalText> {
  static const int _collapsedLines = 6;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: _collapsedLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: widget.style,
              maxLines: _expanded ? null : _collapsedLines,
              overflow:
                  _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
            if (overflows)
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _expanded ? '收起原文' : '展开原文',
                    style: TextStyle(
                      fontSize: AppType.meta,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// `11-19 22:30`
String _formatTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${p2(d.month)}-${p2(d.day)} ${p2(d.hour)}:${p2(d.minute)}';
}
