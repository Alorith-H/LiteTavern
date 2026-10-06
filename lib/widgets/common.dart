import 'package:flutter/material.dart';

import '../services/storage.dart';

/// 角色头像：PNG 卡用原图裁圆；无头像用名字首字圆形占位 + 柔和色。
class CharacterAvatar extends StatelessWidget {
  final String id;
  final String name;
  final double size;

  const CharacterAvatar({
    super.key,
    required this.id,
    required this.name,
    this.size = 48,
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

  @override
  Widget build(BuildContext context) {
    final avatar = id.isEmpty ? null : Storage.avatarFile(id);
    if (avatar != null) {
      return ClipOval(
        child: Image.file(
          avatar,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _placeholder(context),
        ),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    final color = _palette[(name.isEmpty ? 0 : name.hashCode.abs()) %
        _palette.length];
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color,
      child: Text(
        _initial,
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w600,
          color: Colors.black.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}
