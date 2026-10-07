import 'package:flutter/material.dart';

import '../services/storage.dart';

/// v0.5.0「克制编辑风」排版令牌：系统默认中文字体，靠字重字号做层次。
abstract final class AppType {
  /// 引导页大标题
  static const double hero = 28;

  /// 页面标题（AppBar 默认 20sp w700）
  static const double page = 20;

  /// 聊天顶栏标题
  static const double chatTitle = 17;

  /// 分组标题（12sp w600 字距 +0.5 次要色）
  static const double section = 12;

  /// 正文 / 消息文本
  static const double body = 15;

  /// 说明 / 次要文字
  static const double caption = 13;

  /// 消息 meta（时间 / token）
  static const double meta = 11;
}

/// 编辑风小节标题：12sp w600、字距 +0.5、次要色。
class SectionHeader extends StatelessWidget {
  final String text;

  const SectionHeader(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppType.section,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 角色头像：PNG 卡用原图裁切（圆形或圆角方形）；
/// 无头像用名字首字占位 + 柔和色。
class CharacterAvatar extends StatelessWidget {
  final String id;
  final String name;
  final double size;

  /// true = 圆角方形（首页角色行，圆角 [radius]）；false = 圆形。
  final bool square;

  /// 方形态圆角（首页 56dp 用 12）
  final double radius;

  const CharacterAvatar({
    super.key,
    required this.id,
    required this.name,
    this.size = 48,
    this.square = false,
    this.radius = 12,
  });

  static const _palette = <Color>[
    Color(0xFFEF9A9A),
    Color(0xFFF48FB1),
    Color(0xFFCE93D8),
    Color(0xFFB39DDB),
    Color(0xFF9FA8DA),
    Color(0xFF90CAF9),
    Color(0xFF80CBC4),
    Color(0xFFA5D6A7),
    Color(0xFFFFCC80),
    Color(0xFFFFAB91),
    Color(0xFF80DEEA),
    Color(0xFFBCAAA4),
  ];

  String get _initial {
    final n = name.trim();
    return n.isEmpty ? '？' : n.substring(0, 1);
  }

  /// 解码宽度基准：头像显示尺寸远小于此值，按 ~200 逻辑像素 × dpr 解码，
  /// 避免导入的 4000px 原图全尺寸解码（内存 + 卡顿主因之一）。
  /// 同一文件 + 同一 cacheWidth → ImageCache 键稳定，滚动不重复解码。
  static const double _decodeBase = 200;

  @override
  Widget build(BuildContext context) {
    final avatar = id.isEmpty ? null : Storage.avatarFile(id);
    if (avatar != null) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final img = Image.file(
        avatar,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (_decodeBase * dpr).round(),
        errorBuilder: (_, _, _) => _placeholder(context),
      );
      if (square) {
        return ClipRRect(borderRadius: BorderRadius.circular(radius), child: img);
      }
      return ClipOval(child: img);
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    final color = _palette[(name.isEmpty ? 0 : name.hashCode.abs()) %
        _palette.length];
    final initial = Text(
      _initial,
      style: TextStyle(
        fontSize: size * 0.4,
        fontWeight: FontWeight.w600,
        color: Colors.black.withValues(alpha: 0.75),
      ),
    );
    if (square) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Center(child: initial),
      );
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color,
      child: initial,
    );
  }
}
