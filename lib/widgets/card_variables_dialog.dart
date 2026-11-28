import 'package:flutter/material.dart';

/// 生成角色卡前询问是否加入初始变量（v0.46.0）。
///
/// 返回 true = 加上变量，false = 不加，null = 取消生成。
/// 变量会写进 `extensions.mvu.initialVariables`，在聊天的「变量与状态」里显示；
/// 不想要的话整张卡里就不会出现这一部分。
Future<bool?> showCardVariablesDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('要加初始变量吗？'),
      content: const Text(
        '变量用来记录好感度、体力这类会变化的数值，聊天时会显示，AI 也能更新。'
        '不需要的话，卡片里就不会有这一部分。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('不加，直接生成'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('加上变量'),
        ),
      ],
    ),
  );
}
