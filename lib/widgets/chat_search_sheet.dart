import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../services/chat_transcript.dart';
import 'common.dart';

/// 打开「搜索对话」底部弹层，返回被点中的消息下标（取消返回 null）。
Future<int?> showChatSearchSheet(
  BuildContext context, {
  required List<ChatMessage> messages,
  String assistantName = '角色',
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ChatSearchSheet(
      messages: messages,
      assistantName: assistantName,
    ),
  );
}

/// 对话内搜索（v0.24.0）：本地关键词匹配，点结果跳回那条消息。
class ChatSearchSheet extends StatefulWidget {
  const ChatSearchSheet({
    super.key,
    required this.messages,
    this.assistantName = '角色',
  });

  final List<ChatMessage> messages;
  final String assistantName;

  @override
  State<ChatSearchSheet> createState() => _ChatSearchSheetState();
}

class _ChatSearchSheetState extends State<ChatSearchSheet> {
  final TextEditingController _ctrl = TextEditingController();
  List<ChatSearchHit> _hits = const [];
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() {
      _query = value;
      _hits = searchMessages(widget.messages, value);
    });
  }

  String _timeLabel(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${t.month}月${t.day}日 ${p2(t.hour)}:${p2(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      autofocus: true,
                      onChanged: _onChanged,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        hintText: '搜索聊天记录（关键词）',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    IconButton(
                      tooltip: '清空',
                      icon: Icon(Icons.close, size: 18,
                          color: scheme.onSurfaceVariant),
                      onPressed: () {
                        _ctrl.clear();
                        _onChanged('');
                      },
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            Expanded(child: _buildBody(scheme)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_query.trim().isEmpty) {
      return Center(
        child: Text(
          '输入关键词，只在本机这段聊天里找',
          style: TextStyle(
            fontSize: AppType.caption,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (_hits.isEmpty) {
      return Center(
        child: Text(
          '没有找到「${_query.trim()}」',
          style: TextStyle(
            fontSize: AppType.caption,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: _hits.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: scheme.outlineVariant),
      itemBuilder: (context, i) {
        final hit = _hits[i];
        final who = hit.isUser
            ? '你'
            : (hit.message.senderName?.trim().isNotEmpty == true
                ? hit.message.senderName!.trim()
                : widget.assistantName);
        return ListTile(
          dense: true,
          title: Text(
            hit.snippet,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppType.body, height: 1.35),
          ),
          subtitle: Text(
            '$who · ${_timeLabel(hit.message.timestamp)}'
            '${hit.message.hidden ? ' · 对模型隐藏' : ''}',
            style: TextStyle(
              fontSize: AppType.meta,
              color: scheme.onSurfaceVariant,
            ),
          ),
          onTap: () => Navigator.of(context).pop(hit.index),
        );
      },
    );
  }
}
