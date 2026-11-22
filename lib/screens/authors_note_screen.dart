import 'package:flutter/material.dart';

import '../services/authors_note.dart';
import '../widgets/common.dart';

/// 作者注释编辑页（v0.16.0，对齐 SillyTavern 的 Author's Note）。
///
/// 每个会话一份，只注入给模型、不写进聊天记录。适合临时调整风格或
/// 补充模型该记住、又不该出现在故事正文里的信息。
class AuthorNoteScreen extends StatefulWidget {
  const AuthorNoteScreen({
    super.key,
    required this.convId,
    this.title = '作者注释',
  });

  /// 会话 id（群聊是 `group_<id>`），注释按它存。
  final String convId;

  final String title;

  @override
  State<AuthorNoteScreen> createState() => _AuthorNoteScreenState();
}

class _AuthorNoteScreenState extends State<AuthorNoteScreen> {
  late final TextEditingController _contentCtrl;
  late AuthorNote _note;
  late bool _hasOwn;

  @override
  void initState() {
    super.initState();
    _note = AuthorNoteStore.load(widget.convId);
    _hasOwn = AuthorNoteStore.hasOwn(widget.convId);
    _contentCtrl = TextEditingController(text: _note.content);
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    super.dispose();
  }

  void _set(AuthorNote next) => setState(() => _note = next);

  void _save() {
    final note = _note.copyWith(content: _contentCtrl.text.trim());
    if (note.content.isEmpty) {
      // 清空内容 = 删掉这条会话的注释，回到默认
      AuthorNoteStore.clear(widget.convId);
    } else {
      AuthorNoteStore.save(widget.convId, note);
    }
    Navigator.pop(context, true);
  }

  Future<void> _restoreDefault() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认注释'),
        content: const Text('清掉这个会话自己的作者注释，改用「默认作者注释」。'),
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
    if (ok != true) return;
    AuthorNoteStore.clear(widget.convId);
    setState(() {
      _note = AuthorNoteStore.defaultNote;
      _hasOwn = false;
      _contentCtrl.text = _note.content;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final caption = TextStyle(
      fontSize: AppType.caption,
      height: 1.5,
      color: scheme.onSurfaceVariant,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            '这里的文字会随每条请求一起发给模型，但不会出现在聊天记录里。'
            '适合写「回复控制在 3 段以内」「用书面语」这类临时要求。',
            style: caption,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用作者注释', style: TextStyle(fontSize: AppType.body)),
            subtitle: Text(
              _note.enabled ? '每次生成都会带上下面的内容' : '已关闭，内容保留但不生效',
              style: caption,
            ),
            value: _note.enabled,
            onChanged: (v) => _set(_note.copyWith(enabled: v)),
          ),
          TextField(
            controller: _contentCtrl,
            minLines: 6,
            maxLines: 14,
            decoration: const InputDecoration(
              hintText: '例：回复尽量简短，不要替玩家决定行动。\n'
                  '主角左手有旧伤，别写成正常。',
              border: OutlineInputBorder(),
            ),
          ),
          const SectionHeader('插入位置'),
          SegmentedButton<AuthorNotePlacement>(
            segments: const [
              ButtonSegment(
                value: AuthorNotePlacement.inChat,
                label: Text('聊天内'),
                icon: Icon(Icons.forum_outlined, size: 16),
              ),
              ButtonSegment(
                value: AuthorNotePlacement.afterScenario,
                label: Text('设定之后'),
                icon: Icon(Icons.article_outlined, size: 16),
              ),
            ],
            selected: {_note.placement},
            onSelectionChanged: (s) =>
                _set(_note.copyWith(placement: s.first)),
          ),
          const SizedBox(height: 8),
          Text(
            _note.placement == AuthorNotePlacement.inChat
                ? '按「深度」插进聊天记录：深度 0 = 放在最末尾（最后一条之后），'
                    '数字越大越往前。越靠近最新消息，对下一条回复影响越大。'
                : '写进 system 的角色设定部分（示例对话之前），影响整段对话。',
            style: caption,
          ),
          if (_note.placement == AuthorNotePlacement.inChat) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('深度', style: TextStyle(fontSize: AppType.body)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 34,
                  height: 34,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.remove, size: 18),
                    tooltip: '更靠近最新消息',
                    onPressed: _note.depth <= 0
                        ? null
                        : () => _set(_note.copyWith(depth: _note.depth - 1)),
                  ),
                ),
                SizedBox(
                  width: 28,
                  child: Text(
                    '${_note.depth}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: AppType.body,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(
                  width: 34,
                  height: 34,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.add, size: 18),
                    tooltip: '更靠前',
                    onPressed: _note.depth >= 20
                        ? null
                        : () => _set(_note.copyWith(depth: _note.depth + 1)),
                  ),
                ),
                const SizedBox(width: 16),
                Text('角色', style: TextStyle(fontSize: AppType.caption, color: scheme.onSurfaceVariant)),
                const SizedBox(width: 8),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'system', label: Text('system')),
                    ButtonSegment(value: 'user', label: Text('user')),
                  ],
                  selected: {_note.role},
                  onSelectionChanged: (s) => _set(_note.copyWith(role: s.first)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              if (_hasOwn)
                OutlinedButton(
                  onPressed: _restoreDefault,
                  child: const Text('恢复默认'),
                ),
              if (_hasOwn) const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
