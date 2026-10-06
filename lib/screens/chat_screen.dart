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
import '../services/token_estimate.dart';
import '../services/world_info_engine.dart';
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

  /// 最近一次实际发送给 API 的 system 内容（供"查看注入内容"）
  String? _lastSystemText;

  /// 最近一次激活的世界词条目（带来源）
  List<ActivatedEntry> _lastActivated = [];

  /// 最近一次发送的完整 messages（供停止后估算 tokens）
  List<PromptMessage>? _lastPrompt;

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

    // 世界书：卡内嵌 + 该角色挂载且启用的合并
    final books = await _loadWorldBooksFor(card);

    if (!mounted) return;
    setState(() {
      _card = card;
      _messages = msgs;
      _worldBooks = books;
      _loading = false;
    });
    _scrollToBottom();
  }

  /// 该角色参与激活的世界书：卡内嵌 + 挂载配置里 enabled 的。
  /// 挂载配置不存在时回退到全局默认挂载（v0.1 行为）。
  Future<List<WorldInfo>> _loadWorldBooksFor(CharacterCard card) async {
    final books = <WorldInfo>[];
    final embedded = card.characterBook;
    if (embedded != null) {
      // 给内嵌书一个稳定来源名（供"查看注入内容"标注）
      books.add(embedded.name.trim().isEmpty
          ? WorldInfo(
              name: '卡内嵌世界书',
              description: embedded.description,
              entries: embedded.entries,
            )
          : embedded);
    }
    final explicit = await Storage.worldBookMountsFor(card.id);
    final mounts = explicit ??
        [
          for (final id in AppSettings.mountedWorldBookIds)
            (id: id, enabled: true),
        ];
    final enabledIds = {
      for (final m in mounts)
        if (m.enabled) m.id,
    };
    if (enabledIds.isNotEmpty) {
      final all = await Storage.loadWorldBooks();
      for (final (id, wb) in all) {
        if (enabledIds.contains(id)) books.add(wb);
      }
    }
    return books;
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

    final built = PromptBuilder.build(
      card: card,
      history: _messages,
      worldBooks: _worldBooks,
      userName: _macroUserName,
    );
    _lastSystemText = built.systemText;
    _lastActivated = built.activated;
    _lastPrompt = built.messages;

    int? exactPrompt;
    int? exactCompletion;

    await _api.streamChat(
      baseUrl: AppSettings.baseUrl,
      apiKey: AppSettings.apiKey,
      model: AppSettings.model,
      messages: built.messages,
      temperature: AppSettings.temperature,
      topP: AppSettings.topP,
      maxTokens: AppSettings.maxTokens,
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
      onUsage: (p, c) {
        exactPrompt = p;
        exactCompletion = c;
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
    setState(() {
      _generating = false;
      _applyTokens(exactPrompt, exactCompletion);
    });
    _save(force: true);
    _followBottom();
  }

  /// 给最后一条 AI 回复写入 token 数：优先 provider 的 usage，否则本地估算。
  void _applyTokens(int? exactPrompt, int? exactCompletion) {
    final prompt = _lastPrompt;
    if (prompt == null) return;
    final i = _messages.length - 1;
    if (i < 0) return;
    final m = _messages[i];
    if (m.role != 'assistant' || m.error != null || m.promptTokens != null) {
      return;
    }
    if (exactPrompt != null && exactCompletion != null) {
      _messages[i] = m.copyWith(
        promptTokens: exactPrompt,
        completionTokens: exactCompletion,
        tokensEstimated: false,
      );
    } else {
      _messages[i] = m.copyWith(
        promptTokens: estimateTokens(prompt.map((x) => x.content).join('\n')),
        completionTokens: estimateTokens(m.content),
        tokensEstimated: true,
      );
    }
  }

  void _stop() {
    _genToken++;
    _api.cancel();
    if (!mounted) return;
    setState(() {
      _generating = false;
      // 停止时按已生成的部分文本估算
      _applyTokens(null, null);
    });
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
    if (fresh == null || !mounted) return;
    // 编辑页可能调整了世界书挂载，一并刷新
    final books = await _loadWorldBooksFor(fresh);
    if (!mounted) return;
    setState(() {
      _card = fresh;
      _worldBooks = books;
    });
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
              leading: const Icon(Icons.bar_chart_outlined),
              title: const Text('聊天统计'),
              onTap: () {
                Navigator.pop(ctx);
                _showChatStats();
              },
            ),
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: const Text('查看注入内容'),
              onTap: () {
                Navigator.pop(ctx);
                _showInjection();
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

  // ------------------------------------------------------- 统计与注入 --

  /// 聊天统计：消息条数、累计输入/输出 tokens、当前发送上下文估算。
  void _showChatStats() {
    final total = _messages.length;
    var inSum = 0;
    var outSum = 0;
    var hasUsage = false;
    var approx = false;
    for (final m in _messages) {
      final p = m.promptTokens;
      final c = m.completionTokens;
      if (p == null || c == null) continue;
      hasUsage = true;
      inSum += p;
      outSum += c;
      if (m.tokensEstimated) approx = true;
    }

    var contextTokens = 0;
    final card = _card;
    if (card != null) {
      final built = PromptBuilder.build(
        card: card,
        history: _messages,
        worldBooks: _worldBooks,
        userName: _macroUserName,
      );
      contextTokens =
          estimateTokens(built.messages.map((m) => m.content).join('\n'));
    }

    final mark = approx ? '（估算）' : '';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('聊天统计'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statLine('消息条数', '$total'),
            _statLine('累计输入 tokens',
                hasUsage ? '${formatTokenCount(inSum)}$mark' : '0'),
            _statLine('累计输出 tokens',
                hasUsage ? '${formatTokenCount(outSum)}$mark' : '0'),
            _statLine(
                '当前发送上下文', '${formatTokenCount(contextTokens)} tokens（估算）'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }

  Widget _statLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// 查看注入内容：最近一次实际发送的 system 全文 + 激活条目数/来源。
  void _showInjection() {
    final system = _lastSystemText;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        if (system == null) {
          return AlertDialog(
            title: const Text('查看注入内容'),
            content: const Text('还没有发送过消息'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('好的'),
              ),
            ],
          );
        }
        final bySource = <String, int>{};
        for (final a in _lastActivated) {
          bySource.update(a.source, (v) => v + 1, ifAbsent: () => 1);
        }
        final sourceLine =
            bySource.entries.map((e) => '${e.key} ${e.value} 条').join('、');
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('查看注入内容'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '共激活 ${_lastActivated.length} 个世界词条目',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
              if (sourceLine.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '来源：$sourceLine',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: Container(
                  width: double.maxFinite,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      system,
                      style: const TextStyle(fontSize: 13, height: 1.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('好的'),
            ),
          ],
        );
      },
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

    // AI 回复气泡下方的 token 消耗小字（估算值加"约"）
    String? tokenLine;
    if (!isUser && m.promptTokens != null && m.completionTokens != null) {
      final a = m.tokensEstimated ? '约' : '';
      tokenLine = '$a输入 ${formatTokenCount(m.promptTokens!)}'
          ' · $a输出 ${formatTokenCount(m.completionTokens!)} tokens';
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress:
                m.content.isEmpty ? null : () => _showMessageActions(index),
            child: bubble,
          ),
          if (tokenLine != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
              child: Text(
                tokenLine,
                style:
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  /// 长按消息 → 复制 / 编辑 / 重新生成（仅最后一条 AI 回复）。
  void _showMessageActions(int index) {
    if (index < 0 || index >= _messages.length) return;
    final m = _messages[index];
    if (m.content.isEmpty) return;
    final canRegen = index == _messages.length - 1 &&
        m.role == 'assistant' &&
        !_generating &&
        _messages.take(index).any((x) => x.role == 'user');

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
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(ctx);
                _editMessage(index);
              },
            ),
            if (canRegen)
              ListTile(
                leading: const Icon(Icons.refresh_outlined),
                title: const Text('重新生成'),
                onTap: () {
                  Navigator.pop(ctx);
                  _regenerate();
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 编辑某条消息文本，保存写回存储并刷新 UI。
  Future<void> _editMessage(int index) async {
    if (index < 0 || index >= _messages.length) return;
    final ctrl = TextEditingController(text: _messages[index].content);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          controller: ctrl,
          minLines: 3,
          maxLines: 10,
          autofocus: true,
          decoration: const InputDecoration(hintText: '消息内容'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (saved != true || !mounted) return;
    if (index < 0 || index >= _messages.length) return;
    setState(() {
      _messages[index] = _messages[index].copyWith(content: text);
    });
    _save(force: true);
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
