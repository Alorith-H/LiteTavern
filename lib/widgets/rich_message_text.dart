import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/external_links.dart';
import '../services/rich_text.dart';

/// 把 [parseRichText] 的结果排成对话气泡里的样子（v0.47.0）。
///
/// 目标不是做一个全功能 Markdown 渲染器，而是让角色回复里常见的几种写法
/// 有层次：**强调**、*动作*、「台词」、列表、引用、代码块、表格、链接。
class RichMessageText extends StatelessWidget {
  const RichMessageText({
    super.key,
    required this.text,
    required this.style,
    this.showCaret = false,
    this.caretColor,
  });

  final String text;
  final TextStyle style;

  /// 流式生成时在末尾显示闪烁光标。
  final bool showCaret;
  final Color? caretColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocks = parseRichText(text);
    if (blocks.isEmpty) return const SizedBox.shrink();

    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) children.add(const SizedBox(height: 6));
      final block = blocks[i];
      final isLast = i == blocks.length - 1;
      children.add(_buildBlock(
        context,
        scheme,
        block,
        withCaret: showCaret && isLast,
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildBlock(
    BuildContext context,
    ColorScheme scheme,
    RichBlock block, {
    bool withCaret = false,
  }) {
    final base = style;
    switch (block.type) {
      case RichBlockType.heading:
        final scale = switch (block.level) {
          1 => 1.42,
          2 => 1.26,
          3 => 1.14,
          _ => 1.06,
        };
        final headingStyle = base.copyWith(
          fontSize: (base.fontSize ?? 15) * scale,
          fontWeight: FontWeight.w700,
          height: 1.35,
        );
        return _withCaret(_rich(context, scheme, block.spans, headingStyle),
            withCaret);
      case RichBlockType.codeBlock:
        return _withCaret(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outline.withValues(alpha: 0.4)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                block.code,
                style: base.copyWith(
                  fontFamily: 'monospace',
                  fontSize: (base.fontSize ?? 15) - 1.5,
                  height: 1.5,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
          withCaret,
        );
      case RichBlockType.quote:
        return _withCaret(
          Container(
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: scheme.primary.withValues(alpha: 0.5),
                  width: 3,
                ),
              ),
            ),
            child: _rich(
              context,
              scheme,
              block.spans,
              base.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          withCaret,
        );
      case RichBlockType.bullet:
        return _withCaret(
          Padding(
            padding: EdgeInsets.only(left: block.level * 12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 18,
                  child: Text('•',
                      style: base.copyWith(color: scheme.primary, height: 1.5)),
                ),
                Expanded(child: _rich(context, scheme, block.spans, base)),
              ],
            ),
          ),
          withCaret,
        );
      case RichBlockType.numbered:
        return _withCaret(
          Padding(
            padding: EdgeInsets.only(left: block.level * 12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    '${block.prefix}.',
                    style: base.copyWith(color: scheme.primary, height: 1.5),
                  ),
                ),
                Expanded(child: _rich(context, scheme, block.spans, base)),
              ],
            ),
          ),
          withCaret,
        );
      case RichBlockType.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Divider(height: 1, thickness: 0.6, color: scheme.outline),
        );
      case RichBlockType.table:
        final cellStyle = base.copyWith(fontSize: (base.fontSize ?? 15) - 1);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var r = 0; r < block.rows.length; r++)
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: scheme.outline.withValues(alpha: 0.5),
                      width: 0.6,
                    ),
                  ),
                  color: r == 0
                      ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                      : null,
                ),
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final cell in block.rows[r])
                      Expanded(
                        child: _rich(
                          context,
                          scheme,
                          [r == 0 ? cell.withText(cell.text).boldCopy() : cell],
                          cellStyle,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      case RichBlockType.paragraph:
        return _withCaret(_rich(context, scheme, block.spans, base), withCaret);
    }
  }

  Widget _withCaret(Widget child, bool showCaret) {
    if (!showCaret) return child;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: child),
        _BlinkingCaret(color: caretColor),
      ],
    );
  }

  Widget _rich(
    BuildContext context,
    ColorScheme scheme,
    List<RichSpan> spans,
    TextStyle base,
  ) {
    if (spans.isEmpty) return const SizedBox.shrink();
    return SelectableText.rich(
      TextSpan(
        style: base,
        children: [
          for (final span in spans) _span(context, scheme, span, base),
        ],
      ),
    );
  }

  InlineSpan _span(
    BuildContext context,
    ColorScheme scheme,
    RichSpan span,
    TextStyle base,
  ) {
    var style = base.copyWith(
      fontWeight: span.bold ? FontWeight.w600 : null,
      fontStyle: span.italic ? FontStyle.italic : null,
      decoration: span.strike
          ? TextDecoration.lineThrough
          : (span.url != null ? TextDecoration.underline : null),
    );
    if (span.dialogue) style = style.copyWith(color: scheme.primary);
    if (span.italic) style = style.copyWith(color: scheme.onSurfaceVariant);
    if (span.code) {
      style = style.copyWith(
        fontFamily: 'monospace',
        fontSize: (base.fontSize ?? 15) - 1,
        backgroundColor: scheme.surfaceContainerHighest,
      );
    }
    TapGestureRecognizer? recognizer;
    if (span.url != null) {
      final url = span.url!;
      style = style.copyWith(color: scheme.primary);
      recognizer = TapGestureRecognizer()
        ..onTap = () => openExternalLink(context, url, title: '链接');
    }
    return TextSpan(text: span.text, style: style, recognizer: recognizer);
  }
}

class _BlinkingCaret extends StatefulWidget {
  const _BlinkingCaret({this.color});

  final Color? color;

  @override
  State<_BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<_BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return FadeTransition(
      opacity: _controller,
      child: Container(
        key: const ValueKey('rich-text-caret'),
        width: 2.2,
        height: 15,
        margin: const EdgeInsets.only(left: 2, bottom: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}
