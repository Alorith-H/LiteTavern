import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/chat_message.dart';
import '../models/character_card.dart';
import '../models/world_info.dart';
import '../services/api_client.dart';
import '../services/macros.dart';
import '../services/prompt_builder.dart';
import '../services/storage.dart';
import '../widgets/common.dart';
import 'character_edit_screen.dart';
import 'settings_screen.dart';

/// 聊天页（核心页面）。
class ChatScreen extends StatefulWidget {
  final String charId;

  const ChatScreen({super.key, required this.charId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  CharacterCard? _card;
  List<ChatMessage> _messages = [];
  List<WorldInfo> _worldBooks = [];
  bool _loading = true;

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _api = ApiClient();

  bool _generating = false;
  bool _followScroll = true;
  int _genToken = 0;
  DateTime _lastSave = DateTime(0);

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _api.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _inputCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 加载 --

  Future<void> _load() async {
    final card = await Storage.loadCharacter(widget.charId);
    if (card == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    var msgs = await Storage.loadConversation(widget.charId);
    if (msgs.isEmpty && card.firstMes.trim().isNotEmpty) {
      msgs = [
        ChatMessage(
          role: 'assistant',
          content: applyMacros(
            card.firstMes,
            charName: card.name,
            userName: AppSettings.userName,
          ),
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      ];
      // 写入开场白（不 await，避免阻塞首帧）
      Storage.saveConversation(card.id, msgs);
    }

    // 世界书：卡内嵌 + 用户挂载的合并
    final books = <WorldInfo>[];
    if (card.characterBook != null) books.add(card.characterBook!);
    final mountedIds = AppSettings.mountedWorldBookIds;
    if (mountedIds.isNotEmpty) {
      final all = await Storage.loadWorldBooks();
      for (final (id, wb) in all) {
        if (mountedIds.contains(id)) books.add(wb);
      }
    }

    if (!mounted) return;
    setState(() {
      _card = card;
      _messages = msgs;
      _worldBooks = books;
      _loading = false;
    });
    _scrollToBottom();
  }

  // ------------------------------------------------------------- 存储 --

  Future<void> _pendingSave = Future.value();

  void _save({bool force = false}) {
    final card = _card;
    if (card == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastSave).inMilliseconds < 500) return;
    _lastSave = now;
    final snapshot = List.of(_messages);
    // 串行写入，避免并发覆盖
    _pendingSave =
        _pendingSave.then((_) => Storage.saveConversation(card.id, snapshot));
  }

  // ----------------------------------------------------------- 滚动 --

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    _followScroll = pos.pixels >= pos.maxScrollExtent - 140;
  }

  void _followBottom() {
    if (!_followScroll || !_scrollCtrl.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  // ------------------------------------------------------------- 生成 --

  String get _macroUserName => AppSettings.userName;

  String _macro(String s) => applyMacros(
        s,
        charName: _card?.name ?? '',
        userName: _macroUserName,
      );

  bool get _canConfigure => AppSettings.apiConfigured;

  void _send() {
    final text = _inputCtrl.text.trim();
    final card = _card;
    if (text.isEmpty || _generating || card == null) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _messages
        ..add(ChatMessage(role: 'user', content: text, timestamp: now))
        ..add(ChatMessage(role: 'assistant', content: '', timestamp: now));
      _generating = true;
      _followScroll = true;
    });
    _inputCtrl.clear();
    _save(force: true);
    _scrollToBottom();
    _generate();
  }

  void _promptConfigureApi() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('还未配置模型'),
        content: const Text('先去设置里配置模型服务（Base URL 和 API Key），然后就能开聊了。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  Future<void> _generate() async {
    final card = _card;
    if (card == null) return;
    final token = ++_genToken;

    final prompt = PromptBuilder.build(
      card: card,
      history: _messages,
      worldBooks: _worldBooks,
      userName: _macroUserName,
    );

    await _api.streamChat(
      baseUrl: AppSettings.baseUrl,
      apiKey: AppSettings.apiKey,
      model: AppSettings.model,
      messages: prompt,
      onDelta: (delta) {
        if (!mounted || token != _genToken) return;
        setState(() {
          final i = _messages.length - 1;
          if (i < 0 || _messages[i].role != 'assistant') return;
          final last = _messages[i];
          _messages[i] = last.copyWith(content: last.content + delta);
        });
        _followBottom();
        _save();
      },
      onError: (error) {
        if (!mounted || token != _genToken) return;
        setState(() {
          final i = _messages.length - 1;
          if (i < 0 || _messages[i].role != 'assistant') return;
          _messages[i] = _messages[i].copyWith(error: error);
        });
      },
      onDone: () {},
    );

    if (!mounted || token != _genToken) return;
    setState(() => _generating = false);
    _save(force: true);
    _followBottom();
  }

  void _stop() {
    _genToken++;
    _api.cancel();
    if (!mounted) return;
    setState(() => _generating = false);
    _save(force: true);
  }

  /// 重新生成：去掉末尾 assistant 占位/回复，再生成。
  Future<void> _regenerate() async {
    if (_generating || _card == null) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    setState(() {
      if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
        _messages.removeLast();
      }
      _messages.add(ChatMessage(
        role: 'assistant',
        content: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
      _generating = true;
      _followScroll = true;
    });
    _save(force: true);
    _followBottom();
    await _generate();
  }

  /// 失败气泡里的重试：移除失败的 assistant 回复，重新生成。
  Future<void> _retry(ChatMessage failed) async {
    if (_generating || _card == null) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    setState(() {
      final idx = _messages.lastIndexWhere((m) =>
          m.role == 'assistant' &&
          m.timestamp == failed.timestamp &&
          m.content == failed.content);
      if (idx >= 0) {
        _messages.removeAt(idx);
      } else if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
        _messages.removeLast();
      }
      _messages.add(ChatMessage(
        role: 'assistant',
        content: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
      _generating = true;
      _followScroll = true;
    });
    _save(force: true);
    _followBottom();
    await _generate();
  }

  // ------------------------------------------------------------- 菜单 --

  Future<void> _editCharacter() async {
    final card = _card;
    if (card == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CharacterEditScreen(charId: card.id)),
    );
    if (changed != true) return;
    final fresh = await Storage.loadCharacter(card.id);
    if (fresh != null && mounted) {
      setState(() => _card = fresh);
    }
  }

  Future<void> _clearConversation() async {
    final card = _card;
    if (card == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空对话'),
        content: const Text('确定清空全部聊天记录，重新开始吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _messages = card.firstMes.trim().isEmpty
          ? <ChatMessage>[]
          : [
              ChatMessage(
                role: 'assistant',
                content: _macro(card.firstMes),
                timestamp: DateTime.now().millisecondsSinceEpoch,
              ),
            ];
    });
    _save(force: true);
    _scrollToBottom();
  }

  void _rotateGreeting() {
    final card = _card;
    if (card == null || card.alternateGreetings.isEmpty) return;
    final candidates = [
      card.firstMes,
      ...card.alternateGreetings,
    ].map(_macro).toList();

    String? current;
    if (_messages.isNotEmpty && _messages.first.role == 'assistant') {
      current = _messages.first.content;
    }
    var idx = current == null ? -1 : candidates.indexOf(current);
    final next = candidates[(idx + 1) % candidates.length];

    setState(() {
      if (_messages.isNotEmpty && _messages.first.role == 'assistant') {
        _messages[0] = ChatMessage(
          role: 'assistant',
          content: next,
          timestamp: _messages.first.timestamp,
        );
      } else {
        _messages.insert(
          0,
          ChatMessage(
            role: 'assistant',
            content: next,
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    });
    _save(force: true);
    _scrollToBottom();
  }

  void _showMenu() {
    final card = _card;
    if (card == null) return;
    final canRegen = !_generating &&
        _messages.isNotEmpty &&
        _messages.any((m) => m.role == 'user');
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('清空对话'),
              onTap: () {
                Navigator.pop(ctx);
                _clearConversation();
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑角色'),
              onTap: () {
                Navigator.pop(ctx);
                _editCharacter();
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh_outlined),
              title: const Text('重新生成最后回复'),
              enabled: canRegen,
              onTap: canRegen
                  ? () {
                      Navigator.pop(ctx);
                      _regenerate();
                    }
                  : null,
            ),
            if (card.alternateGreetings.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: const Text('换开场白'),
                onTap: () {
                  Navigator.pop(ctx);
                  _rotateGreeting();
                },
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 构建 --

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = _card;

    if (_loading || card == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CharacterAvatar(id: card.id, name: card.name, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                card.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多',
            onPressed: _showMenu,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusScope.of(context).unfocus(),
              child: ListView.builder(
                controller: _scrollCtrl,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                itemCount: _messages.length,
                itemBuilder: (context, i) =>
                    _buildMessage(scheme, _messages[i], i),
              ),
            ),
          ),
          _buildInputBar(scheme),
        ],
      ),
    );
  }

  Widget _buildMessage(ColorScheme scheme, ChatMessage m, int index) {
    final isUser = m.role == 'user';
    final isLast = index == _messages.length - 1;
    final thinking = isLast && _generating && m.content.isEmpty;

    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      decoration: BoxDecoration(
        color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(isUser ? 14 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (thinking)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Text('思考中…',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            )
          else
            MarkdownBody(
              data: m.content,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                p: TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: isUser
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface,
                ),
              ),
            ),
          if (m.error != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    m.error!,
                    style: TextStyle(
                        color: scheme.error, fontSize: 13, height: 1.4),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _retry(m),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('重试'),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: m.content.isEmpty ? null : () => _showMessageActions(m),
        child: bubble,
      ),
    );
  }

  /// 长按消息 → 弹出"复制"。
  void _showMessageActions(ChatMessage m) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListBody(
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制'),
              onTap: () async {
                Navigator.pop(ctx);
                await Clipboard.setData(ClipboardData(text: m.content));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(ColorScheme scheme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: '说点什么…',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 10),
            _generating
                ? IconButton(
                    onPressed: _stop,
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.errorContainer,
                      foregroundColor: scheme.onErrorContainer,
                    ),
                    icon: const Icon(Icons.stop),
                    tooltip: '停止',
                  )
                : IconButton(
                    onPressed: _send,
                    style: IconButton.styleFrom(
                      backgroundColor: _inputCtrl.text.trim().isEmpty
                          ? scheme.surfaceContainerHighest
                          : scheme.primary,
                      foregroundColor: _inputCtrl.text.trim().isEmpty
                          ? scheme.onSurfaceVariant
                          : scheme.onPrimary,
                    ),
                    icon: const Icon(Icons.send),
                    tooltip: '发送',
                  ),
          ],
        ),
      ),
    );
  }
}
