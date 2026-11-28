import 'package:flutter/material.dart';

import '../models/character_card.dart';
import 'sheet_menu.dart';

/// 长按角色卡弹出的操作菜单（v0.45.1）。
///
/// 只保留两个按钮，不再显示角色名、「角色操作」标题与「编辑 / 危险操作」分组：
/// 长按之后能做的事就这么两件，标题和分组只会把弹层撑高。
Future<void> showCharacterActionsSheet(
  BuildContext context, {
  required CharacterCard card,
  required VoidCallback onEdit,
  required VoidCallback onDelete,
}) {
  return showSheetMenu<void>(
    context: context,
    children: [
      SheetMenuItem(
        icon: Icons.edit_outlined,
        title: '编辑角色',
        subtitle: '设定、开场白、世界书挂载',
        onTap: () {
          Navigator.pop(context);
          onEdit();
        },
      ),
      SheetMenuItem(
        icon: Icons.delete_outline,
        title: '删除角色',
        subtitle: '会一起删掉它的聊天记录与书签，不可恢复',
        danger: true,
        onTap: () {
          Navigator.pop(context);
          onDelete();
        },
      ),
    ],
  );
}
