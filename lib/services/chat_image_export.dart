// 对话导出为「长图」（v0.25.0）。
//
// 纯 Canvas 绘制，不依赖任何插件：先把每条消息量一遍高度，
// 再按总高度开一张图，从顶部往下画。这样长对话也能一张图发出去。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/chat_message.dart';

class ChatImageExport {
  ChatImageExport._();

  static const double width = 1080;
  static const double _margin = 44;
  static const double _bubblePadX = 22;
  static const double _bubblePadY = 16;
  static const double _gap = 16;
  static const double _headerHeight = 150;
  static const double _footerHeight = 54;
  static const double maxHeight = 20000;
  static const double _radius = 18;

  /// 生成对话长图（PNG 字节）。消息很多时按高度截断，并在末尾标注。
  ///
  /// v0.42.0：加 [onProgress]，分块让出事件循环，界面能刷新进度条
  /// （长会话几千条不再整段卡死 UI）。
  static Future<Uint8List> render({
    required String charName,
    required String userName,
    required List<ChatMessage> messages,
    DateTime? exportedAt,
    void Function(double value)? onProgress,
  }) async {
    final at = exportedAt ?? DateTime.now();
    final blocks = <_Block>[];
    var used = _headerHeight + _footerHeight;
    final total = messages.isEmpty ? 1 : messages.length;
    var seen = 0;

    for (final m in messages) {
      if (m.content.trim().isEmpty) continue;
      final fromUser = m.role == 'user';
      final who = fromUser
          ? userName
          : (m.senderName ?? charName);
      final inner = width - _margin * 2 - _bubblePadX * 2;
      final body = _paint(
        m.content,
        const TextStyle(fontSize: 27, height: 1.42, color: Color(0xFF1E1A18)),
        inner,
      );
      final label = fromUser
          ? null
          : _paint(
              who,
              const TextStyle(
                fontSize: 20,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: Color(0xFF8A5A44),
              ),
              inner,
            );
      final hiddenTag = m.hidden;
      final height = _bubblePadY * 2 +
          (label == null ? 0 : label.height + 6) +
          body.height +
          (hiddenTag ? 26 : 0);
      if (used + height + _gap > maxHeight - 40) {
        blocks.add(_Block(
          painter: _paint(
            '（后面还有 ${messages.length - blocks.length} 条未显示，可导出 .txt / .json 查看全部）',
            const TextStyle(fontSize: 22, color: Color(0xFF8B7F78)),
            inner,
          ),
          fromUser: false,
          plain: true,
          label: null,
          heightPadding: 30,
          hidden: false,
        ));
        break;
      }
      blocks.add(_Block(
        painter: body,
        fromUser: fromUser,
        label: label,
        heightPadding: height - body.height,
        hidden: hiddenTag,
      ));
      used += height + _gap;
      seen++;
      // 每 30 条报一次进度并让出事件循环，避免几百条消息把 UI 卡住。
      if (seen % 30 == 0) {
        onProgress?.call((seen / total * 0.55).clamp(0.0, 0.55));
        await Future<void>.delayed(Duration.zero);
      }
    }
    onProgress?.call(0.55);

    final height = (used + _gap).clamp(_headerHeight + _footerHeight + 120, maxHeight);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width, height.toDouble()),
    );
    final bg = Paint()..color = const Color(0xFFF6F1EC);
    canvas.drawRect(Rect.fromLTWH(0, 0, width, height.toDouble()), bg);

    // 顶部标题
    _drawText(
      canvas,
      charName,
      const TextStyle(
        fontSize: 40,
        height: 1.2,
        fontWeight: FontWeight.w700,
        color: Color(0xFF241E1A),
      ),
      _margin,
      40,
      width - _margin * 2,
    );
    final stamp = '${at.year}-${_p2(at.month)}-${_p2(at.day)} ${_p2(at.hour)}:${_p2(at.minute)}';
    _drawText(
      canvas,
      '和 $charName 的对话 · ${messages.where((m) => m.content.trim().isNotEmpty).length} 条 · $stamp',
      const TextStyle(fontSize: 22, height: 1.3, color: Color(0xFF7A6C64)),
      _margin,
      92,
      width - _margin * 2,
    );
    canvas.drawLine(
      Offset(_margin, _headerHeight - 26),
      Offset(width - _margin, _headerHeight - 26),
      Paint()
        ..color = const Color(0xFFD8CCC3)
        ..strokeWidth = 2,
    );

    var y = _headerHeight + 8;
    var drawn = 0;
    for (final b in blocks) {
      final inner = width - _margin * 2;
      final bubbleW = (b.painter.width + _bubblePadX * 2)
          .clamp(150.0, inner)
          .toDouble();
      final bubbleH = b.painter.height + b.heightPadding;
      final left = b.fromUser ? width - _margin - bubbleW : _margin;

      if (b.plain) {
        b.painter.paint(canvas, Offset(_margin, y));
        y += b.painter.height + _gap;
        continue;
      }

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, y, bubbleW, bubbleH),
        const Radius.circular(_radius),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = b.fromUser
              ? const Color(0xFFE7D5CB)
              : const Color(0xFFFFFFFF),
      );
      var ty = y + _bubblePadY;
      if (b.label != null) {
        b.label!.paint(canvas, Offset(left + _bubblePadX, ty));
        ty += b.label!.height + 6;
      }
      b.painter.paint(canvas, Offset(left + _bubblePadX, ty));
      if (b.hidden) {
        _drawText(
          canvas,
          '对模型隐藏',
          const TextStyle(fontSize: 18, color: Color(0xFF9A8C84)),
          left + _bubblePadX,
          ty + b.painter.height + 4,
          bubbleW - _bubblePadX * 2,
        );
      }
      y += bubbleH + _gap;
      drawn++;
      if (drawn % 40 == 0 && blocks.isNotEmpty) {
        onProgress?.call((0.55 + drawn / blocks.length * 0.4).clamp(0.55, 0.95));
        await Future<void>.delayed(Duration.zero);
      }
    }

    final footer = '由 轻酒馆 LiteTavern 导出';
    _drawText(
      canvas,
      footer,
      const TextStyle(fontSize: 20, color: Color(0xFFA2968E)),
      _margin,
      height - 44,
      width - _margin * 2,
    );

    onProgress?.call(0.96);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.ceil());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    onProgress?.call(1.0);
    return data!.buffer.asUint8List();
  }

  static TextPainter _paint(String text, TextStyle style, double maxWidth) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: maxWidth);
    return tp;
  }

  static void _drawText(
    Canvas canvas,
    String text,
    TextStyle style,
    double x,
    double y,
    double maxWidth,
  ) {
    _paint(text, style, maxWidth).paint(canvas, Offset(x, y));
  }

  static String _p2(int n) => n.toString().padLeft(2, '0');
}

class _Block {
  _Block({
    required this.painter,
    required this.fromUser,
    required this.label,
    required this.heightPadding,
    required this.hidden,
    this.plain = false,
  });

  final TextPainter painter;
  final bool fromUser;
  final TextPainter? label;
  final double heightPadding;
  final bool hidden;
  final bool plain;
}
