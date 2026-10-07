import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/chat_message.dart';
import '../models/character_card.dart';
import '../models/world_info.dart';
import '../services/api_client.dart';
import '../services/chat_export.dart';
import '../services/macros.dart';
import '../services/prompt_builder.dart';
import '../services/storage.dart';
import '../services/token_estimate.dart';
import '../services/world_info_engine.dart';
import '../widgets/common.dart';
import 'character_edit_screen.dart';
import 'settings_screen.dart';

/// 继续生成时附加在 messages 末尾的 system 指令。
const String kContinueInstruction =
    '接着上一条回复的最后一个字继续输出，不要重复、不要重新开头';

/// 自动跟随阈值：滚动位置在底部 120px 以内才自动跟到底。
const double _kFollowThreshold = 120;

/// 流式刷新最小间隔（ms）：一帧内多个 token 合并成一次 setState。
const int _kStreamFlushMs = 33;

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

  /// 进入聊天的首次定位只执行一次（首帧布局完成 → jumpTo 底部）
  bool _initialLocated = false;

  /// 输入框是否为空（只通知发送按钮，打字不触发整页 setState）
  final _inputEmpty = ValueNotifier<bool>(true);

  /// 用户手指正按在列表上拖动：期间冻结跟随判定，绝不与手势抢位置
  bool _userDragging = false;
  int _genToken = 0;
  DateTime _lastSave = DateTime(0);

  /// 流式文本缓冲：≥33ms 才落一次 setState，禁止每个 token 全列表 rebuild
  String _streamBuf = '';
  Timer? _flushTimer;
  DateTime _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);

  /// 本次生成的记账状态
  bool _isContinueGen = false; // 是否"继续生成"（追加到同一变体）
  int _genStartLen = 0; // 生成开始时 content 长度（估算只算新增部分）
  bool _tokensApplied = false; // 本次生成的 token 是否已写入（防重复累计）

  /// 已完成消息的 widget 缓存（含 markdown 渲染结果）。
  /// key 是消息对象本身：内容/身份一变即自然失效；列表结构变化时整体清空。
  final Map<ChatMessage, Widget> _msgCache = {};
  int _cacheLen = -1;
  Object? _cacheToken;

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
    _flushTimer?.cancel();
    _api.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _inputCtrl.dispose();
    _inputEmpty.dispose();
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
      _msgCache.clear();
      _cacheLen = -1;
    });
    _locateInitial();
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
    if (_userDragging) return; // 拖动中不改变跟随状态
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    _followScroll = pos.pixels >= pos.maxScrollExtent - _kFollowThreshold;
  }

  /// 滚动通知：用户手指一拖动就停止跟随（绝不与手势抢位置）；
  /// 松手（或惯性滚动结束）时按"底部 120px 内"重新判定，
  /// 手动滚回底部即恢复跟随。
  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _userDragging = true;
      _followScroll = false;
    } else if (n is ScrollEndNotification) {
      _userDragging = false;
      _onScroll();
    }
    return false;
  }

  void _followBottom() {
    if (!_followScroll || !_scrollCtrl.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_followScroll || !_scrollCtrl.hasClients) return;
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

  /// 进入聊天：首帧布局完成后一次性 jumpTo(maxScrollExtent)，
  /// 用标志保证只执行一次；不足一屏时 max=0 自然不动。
  /// 只影响进入瞬间，不改动 v0.3 的流式跟随规则。
  void _locateInitial() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_initialLocated || !mounted || !_scrollCtrl.hasClients) return;
      _initialLocated = true;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      _followScroll = true;
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

  void _send() => _sendText(_inputCtrl.text);

  /// 发送一条用户消息（输入框发送与快捷回复共用，走正常生成流程）。
  void _sendText(String raw) {
    final text = raw.trim();
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
      _isContinueGen = false;
      _genStartLen = 0;
      _streamBuf = '';
      _msgCache.clear();
    });
    _inputCtrl.clear();
    _inputEmpty.value = true;
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

  /// 流式 delta 入缓冲：距上次刷新 ≥33ms 立即刷，否则合并到一个定时器里刷。
  void _enqueueDelta(String delta) {
    _streamBuf += delta;
    final since = DateTime.now().difference(_lastFlush).inMilliseconds;
    if (since >= _kStreamFlushMs) {
      _flushStream();
    } else {
      _flushTimer ??= Timer(
        Duration(milliseconds: _kStreamFlushMs - since),
        _flushStream,
      );
    }
  }

  /// 把缓冲文本写进最后一条 AI 消息并刷新一次 UI（一帧多 token 只 setState 一次）。
  void _flushStream() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _lastFlush = DateTime.now();
    if (_streamBuf.isEmpty) return;
    if (!mounted) {
      _streamBuf = '';
      return;
    }
    final buf = _streamBuf;
    _streamBuf = '';
    setState(() {
      final i = _messages.length - 1;
      if (i < 0 || _messages[i].role != 'assistant') return;
      final m = _messages[i];
      _messages[i] = m.copyWith(content: m.content + buf);
    });
    _followBottom();
    _save();
  }

  Future<void> _generate() async {
    final card = _card;
    if (card == null) return;
    final token = ++_genToken;
    _tokensApplied = false;

    final built = PromptBuilder.build(
      card: card,
      history: _messages,
      worldBooks: _worldBooks,
      userName: _macroUserName,
    );
    _lastSystemText = built.systemText;
    _lastActivated = built.activated;

    // 继续生成：在现有 messages 末尾附加 system 指令，结果追加到同一消息
    final toSend = List<PromptMessage>.of(built.messages);
    if (_isContinueGen) {
      toSend.add(const PromptMessage(
        role: 'system',
        content: kContinueInstruction,
      ));
    }
    _lastPrompt = toSend;

    int? exactPrompt;
    int? exactCompletion;

    await _api.streamChat(
      baseUrl: AppSettings.baseUrl,
      apiKey: AppSettings.apiKey,
      model: AppSettings.model,
      messages: toSend,
      temperature: AppSettings.temperature,
      topP: AppSettings.topP,
      maxTokens: AppSettings.maxTokens,
      onDelta: (delta) {
        if (!mounted || token != _genToken) return;
        _enqueueDelta(delta);
      },
      onUsage: (p, c) {
        exactPrompt = p;
        exactCompletion = c;
      },
      onError: (error) {
        if (!mounted || token != _genToken) return;
        // 先并入已收到的文本，再标记错误
        _flushStream();
        setState(() {
          final i = _messages.length - 1;
          if (i < 0 || _messages[i].role != 'assistant') return;
          _messages[i] = _messages[i].copyWith(error: error);
        });
      },
      onDone: () {},
    );

    _flushStream();
    if (!mounted || token != _genToken) return;
    setState(() {
      _generating = false;
      _applyTokens(exactPrompt, exactCompletion);
    });
    _save(force: true);
    _followBottom();
    _isContinueGen = false;
  }

  /// 写入本次生成的 token：
  /// 每变体槽位记这一笔（继续生成则在同一槽位累加），
  /// 消息级字段累计所有变体 = 真实花销（聊天统计直接用）。
  void _applyTokens(int? exactPrompt, int? exactCompletion) {
    if (_tokensApplied) return;
    final sent = _lastPrompt;
    if (sent == null) return;
    final i = _messages.length - 1;
    if (i < 0) return;
    final m = _messages[i];
    if (m.role != 'assistant' || m.error != null) return;
    _tokensApplied = true;

    int p;
    int c;
    bool est;
    if (exactPrompt != null && exactCompletion != null) {
      p = exactPrompt;
      c = exactCompletion;
      est = false;
    } else {
      p = estimateTokens(sent.map((x) => x.content).join('\n'));
      final start = _genStartLen.clamp(0, m.content.length).toInt();
      c = estimateTokens(m.content.substring(start));
      est = true;
    }

    // 首次生成：把显示文本收编为唯一变体；
    // 旧数据的已有 token 记为其槽位初值（继续生成时接得上）
    final v = List<String>.of(m.variants.isEmpty ? [m.content] : m.variants);
    var u = List<VariantUsage>.of(m.variantUsage);
    while (u.length < v.length) {
      u.add(VariantUsage.empty);
    }
    if (u.length > v.length) u = u.sublist(0, v.length);
    if (m.variants.isEmpty &&
        m.promptTokens != null &&
        m.completionTokens != null) {
      u[0] = VariantUsage(
        prompt: m.promptTokens,
        completion: m.completionTokens,
        estimated: m.tokensEstimated,
      );
    }
    final idx = m.variantIndex.clamp(0, v.length - 1).toInt();

    final cur = u[idx];
    final VariantUsage slot;
    if (_isContinueGen && cur.hasTokens) {
      slot = VariantUsage(
        prompt: (cur.prompt ?? 0) + p,
        completion: (cur.completion ?? 0) + c,
        estimated: cur.estimated || est,
      );
    } else {
      slot = VariantUsage(prompt: p, completion: c, estimated: est);
    }
    u[idx] = slot;

    _messages[i] = m.copyWith(
      variants: v,
      variantUsage: u,
      promptTokens: (m.promptTokens ?? 0) + p,
      completionTokens: (m.completionTokens ?? 0) + c,
      tokensEstimated: m.tokensEstimated || est,
    );
  }

  void _stop() {
    _genToken++;
    _api.cancel();
    // 并入停止前已到达的文本，保证不丢字
    _flushStream();
    if (!mounted) return;
    setState(() {
      _generating = false;
      // 停止时按已生成的部分文本估算
      _applyTokens(null, null);
    });
    _save(force: true);
    _isContinueGen = false;
  }

  /// 为最后一条 AI 消息准备一个空变体槽位：
  /// - 旧数据（无 variants）先把现有文本收编为第一个变体
  /// - 清掉空变体（失败/占位尝试不是回复，避免空白气泡堆积；
  ///   对应消耗已计入消息级累计，统计不丢）
  /// - 追加新变体，视图切过去；旧回复不删除
  ChatMessage _prepVariantSlot(ChatMessage m) {
    var v = List<String>.of(m.variants);
    var u = List<VariantUsage>.of(m.variantUsage);
    if (v.isEmpty) {
      v = [m.content];
      u = [
        if (m.promptTokens != null && m.completionTokens != null)
          VariantUsage(
            prompt: m.promptTokens,
            completion: m.completionTokens,
            estimated: m.tokensEstimated,
          )
        else
          VariantUsage.empty,
      ];
    }
    while (u.length < v.length) {
      u.add(VariantUsage.empty);
    }
    if (u.length > v.length) u = u.sublist(0, v.length);

    final nv = <String>[];
    final nu = <VariantUsage>[];
    for (var i = 0; i < v.length; i++) {
      if (v[i].isEmpty) continue;
      nv.add(v[i]);
      nu.add(u[i]);
    }
    nv.add('');
    nu.add(VariantUsage.empty);
    return m.copyWith(
      content: '',
      variants: nv,
      variantUsage: nu,
      variantIndex: nv.length - 1,
      error: null,
    );
  }

  /// 重新生成 = 追加变体（不删除旧回复，生成完自动切到新变体）。
  Future<void> _regenerate() async {
    if (_generating || _card == null) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    if (_messages.isEmpty || _messages.last.role != 'assistant') return;
    setState(() {
      _messages[_messages.length - 1] = _prepVariantSlot(_messages.last);
      _generating = true;
      _followScroll = true;
      _isContinueGen = false;
      _genStartLen = 0;
      _streamBuf = '';
      _msgCache.clear();
    });
    _save(force: true);
    _followBottom();
    await _generate();
  }

  /// 失败气泡里的重试。
  Future<void> _retry(ChatMessage failed) async {
    if (_generating || _card == null) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    final idx = _messages.indexOf(failed);
    if (idx < 0) return;

    if (idx == _messages.length - 1) {
      // 末条失败：复用空变体槽或追加新变体，原地重试
      setState(() {
        _messages[idx] = _prepVariantSlot(_messages[idx]);
        _generating = true;
        _followScroll = true;
        _isContinueGen = false;
        _genStartLen = 0;
        _streamBuf = '';
        _msgCache.clear();
      });
      _save(force: true);
      _followBottom();
      await _generate();
      return;
    }

    // 中间的失败消息无法原地重生成（流式目标固定为末条）：
    // 有非空变体 → 切回最后的非空变体并清除错误（copyWith 默认清 error）；
    // 否则是空失败占位 → 移除后在末尾重新生成（v0.2 行为）
    final v = failed.variants;
    var good = -1;
    for (var i = v.length - 1; i >= 0; i--) {
      if (v[i].isNotEmpty) {
        good = i;
        break;
      }
    }
    if (good >= 0 || failed.content.isNotEmpty) {
      setState(() {
        _messages[idx] = good >= 0
            ? failed.copyWith(variantIndex: good)
            : failed.copyWith();
      });
      _msgCache.clear();
      _save(force: true);
      return;
    }

    setState(() {
      _messages.removeAt(idx);
      _messages.add(ChatMessage(
        role: 'assistant',
        content: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
      _generating = true;
      _followScroll = true;
      _isContinueGen = false;
      _genStartLen = 0;
      _streamBuf = '';
      _msgCache.clear();
    });
    _save(force: true);
    _followBottom();
    await _generate();
  }

  /// 继续生成：在同一条 AI 消息末尾流式追加文本。
  Future<void> _continueGeneration() async {
    if (_generating || _card == null) return;
    if (_messages.isEmpty || _messages.last.role != 'assistant') return;
    final last = _messages.last;
    if (last.content.isEmpty || last.error != null) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    setState(() {
      _isContinueGen = true;
      _genStartLen = last.content.length;
      _generating = true;
      _followScroll = true;
      _streamBuf = '';
    });
    _save(force: true);
    _scrollToBottom();
    await _generate();
  }

  /// 切换某条消息的当前变体（气泡横滑 / 圆点点按）。
  void _switchVariant(ChatMessage m, int index) {
    if (_generating) return;
    final idx = _messages.indexOf(m);
    if (idx < 0) return;
    final cur = _messages[idx];
    if (index < 0 || index >= cur.variants.length) return;
    if (index == cur.variantIndex) return;
    setState(() {
      _messages[idx] = cur.copyWith(variantIndex: index);
    });
    _save(force: true);
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
      _msgCache.clear();
      _cacheLen = -1;
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
      _msgCache.clear();
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
    final last = _messages.isEmpty ? null : _messages.last;
    final canContinue = !_generating &&
        last != null &&
        last.role == 'assistant' &&
        last.content.isNotEmpty &&
        last.error == null;
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
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('复制对话'),
              onTap: () {
                Navigator.pop(ctx);
                _exportConversation();
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward_outlined),
              title: const Text('继续生成'),
              enabled: canContinue,
              onTap: canContinue
                  ? () {
                      Navigator.pop(ctx);
                      _continueGeneration();
                    }
                  : null,
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

  // ------------------------------------------------------- 导出对话 --

  /// 组装纯文本写入系统剪贴板（变体只导出当前显示的）。
  Future<void> _exportConversation() async {
    final card = _card;
    if (card == null) return;
    final text = buildExportText(
      charName: card.name,
      userName: AppSettings.userName,
      messages: _messages,
      exportedAt: DateTime.now(),
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('对话已复制到剪贴板')),
    );
  }

  // ------------------------------------------------------- 统计与注入 --

  /// 聊天统计：消息条数、累计输入/输出 tokens、当前发送上下文估算。
  /// 累计值已含该消息所有变体的消耗（真实花销）。
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

    // 主题（亮度+主题色）/ 宽度 / 字号 / 时间戳开关变化 → 气泡缓存整体失效
    final cacheToken = (
      Theme.of(context).brightness,
      scheme.primary.toARGB32(),
      MediaQuery.sizeOf(context).width,
      AppSettings.chatFontSize,
      AppSettings.showTimestamps,
    );
    if (cacheToken != _cacheToken) {
      _cacheToken = cacheToken;
      _msgCache.clear();
      _cacheLen = -1;
    }
    // 消息集（长度）变化 → 缓存整体失效
    if (_messages.length != _cacheLen) {
      _cacheLen = _messages.length;
      _msgCache.clear();
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
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) {
                    final m = _messages[i];
                    // 流式期间只有末条 AI 气泡随数据更新，不进缓存
                    final streaming = _generating &&
                        i == _messages.length - 1 &&
                        m.role == 'assistant';
                    if (streaming) return _buildMessage(scheme, m, i);
                    final cached = _msgCache[m];
                    if (cached != null) return cached;
                    final w = _buildMessage(scheme, m, i);
                    _msgCache[m] = w;
                    return w;
                  },
                ),
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
    final fontSize = AppSettings.chatFontSize;
    final showTs = AppSettings.showTimestamps;

    Widget bubble = Container(
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
                  fontSize: fontSize,
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
          if (!isUser && m.variants.length > 1) _buildVariantDots(scheme, m),
        ],
      ),
    );

    // 长按 → 消息操作；最后一条 AI 消息再套横滑切换变体
    bubble = GestureDetector(
      onLongPress:
          m.content.isEmpty ? null : () => _showMessageActions(m),
      child: bubble,
    );
    if (!isUser && isLast) {
      bubble = _SwipeVariantWrap(
        enabled: !_generating && m.variants.length > 1,
        onSwipe: (dir) => _switchVariant(m, m.variantIndex + dir),
        child: bubble,
      );
    }

    // AI：token/时间小字行；用户：时间戳开关下的时间行
    String? infoLine;
    if (!isUser) {
      final usage = m.currentVariantUsage;
      if (usage != null) {
        final a = usage.estimated ? '约' : '';
        final pin = formatTokenCount(usage.prompt!);
        final cout = formatTokenCount(usage.completion!);
        infoLine = showTs
            ? '${_formatTime(m.timestamp)} · $a输入 $pin · $a输出 $cout'
            : '$a输入 $pin · $a输出 $cout tokens';
      } else if (showTs) {
        infoLine = _formatTime(m.timestamp);
      }
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          bubble,
          if (infoLine != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
              child: Text(
                infoLine,
                style:
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
          if (isUser && showTs)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Text(
                _formatTime(m.timestamp),
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 变体圆点指示器（可点按切换），变体数 >1 时显示在气泡底部。
  Widget _buildVariantDots(ColorScheme scheme, ChatMessage m) {
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < m.variants.length; i++)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _generating ? null : () => _switchVariant(m, i),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == m.variantIndex
                        ? scheme.primary
                        : scheme.outlineVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// `10-07 00:43`
  String _formatTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${p2(d.month)}-${p2(d.day)} ${p2(d.hour)}:${p2(d.minute)}';
  }

  /// 长按消息 → 复制 / 编辑 / 重新生成（仅最后一条 AI 回复）。
  void _showMessageActions(ChatMessage m) {
    if (m.content.isEmpty) return;
    final index = _messages.indexOf(m);
    if (index < 0) return;
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
                _editMessage(m);
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

  /// 编辑某条消息当前显示的变体，保存写回存储并刷新 UI。
  Future<void> _editMessage(ChatMessage m) async {
    final ctrl = TextEditingController(text: m.content);
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
    // 对话框期间消息可能已被流式替换，此时放弃本次编辑
    final idx = _messages.indexOf(m);
    if (idx < 0) return;
    setState(() {
      _messages[idx] = _messages[idx].copyWith(content: text);
    });
    _save(force: true);
  }

  Widget _buildInputBar(ColorScheme scheme) {
    final replies = AppSettings.quickReplies;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 快捷回复：输入框上方一排横滑 chips，点按立即发送；
            // 管理页删到空则整排隐藏，生成中置灰禁用
            if (replies.isNotEmpty) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < replies.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      ActionChip(
                        label: Text(
                          replies[i],
                          style: const TextStyle(fontSize: 13),
                        ),
                        onPressed:
                            _generating ? null : () => _sendText(replies[i]),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
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
                    // 只在「空 ↔ 非空」翻转时通知发送按钮，打字不整页 setState
                    onChanged: (_) =>
                        _inputEmpty.value = _inputCtrl.text.trim().isEmpty,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 10),
                ValueListenableBuilder<bool>(
                  valueListenable: _inputEmpty,
                  builder: (context, empty, _) => _generating
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
                            backgroundColor: empty
                                ? scheme.surfaceContainerHighest
                                : scheme.primary,
                            foregroundColor: empty
                                ? scheme.onSurfaceVariant
                                : scheme.onPrimary,
                          ),
                          icon: const Icon(Icons.send),
                          tooltip: '发送',
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 最后一条 AI 消息的横滑容器：横滑（|dx| 占优）切换变体，松手回弹。
/// enabled=false（只有 1 个变体 / 正在生成）时横滑无视觉响应，
/// 竖向列表滚动不受影响（手势竞技场按主方向判定）。
class _SwipeVariantWrap extends StatefulWidget {
  const _SwipeVariantWrap({
    required this.enabled,
    required this.onSwipe,
    required this.child,
  });

  final bool enabled;

  /// +1 = 下一个变体（左滑），-1 = 上一个变体（右滑）
  final void Function(int direction) onSwipe;

  final Widget child;

  @override
  State<_SwipeVariantWrap> createState() => _SwipeVariantWrapState();
}

class _SwipeVariantWrapState extends State<_SwipeVariantWrap>
    with SingleTickerProviderStateMixin {
  static const _threshold = 60.0;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Animation<double>? _anim;
  double _dx = 0;

  @override
  void dispose() {
    _anim = null;
    _ctrl.dispose();
    super.dispose();
  }

  void _onTick() {
    final a = _anim;
    if (a == null || !mounted) return;
    setState(() => _dx = a.value);
  }

  void _stopAnim() {
    _anim?.removeListener(_onTick);
    _anim = null;
    _ctrl.stop();
  }

  void _springBack() {
    final start = _dx;
    if (start == 0) return;
    _stopAnim();
    final anim = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );
    _anim = anim;
    anim.addListener(_onTick);
    _ctrl.forward(from: 0).whenComplete(() {
      anim.removeListener(_onTick);
      if (identical(_anim, anim)) _anim = null;
      if (mounted) setState(() => _dx = 0);
    });
  }

  void _onUpdate(DragUpdateDetails d) {
    if (!widget.enabled) return;
    // 新手势打断回弹动画，以当前位置继续
    if (_anim != null) {
      final v = _anim!.value;
      _stopAnim();
      _dx = v;
    }
    setState(() => _dx += d.delta.dx);
  }

  void _onEnd(DragEndDetails d) {
    if (_dx <= -_threshold) {
      widget.onSwipe(1); // 左滑 → 下一个变体
    } else if (_dx >= _threshold) {
      widget.onSwipe(-1); // 右滑 → 上一个变体
    }
    _springBack();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      child: Transform.translate(
        offset: Offset(_dx, 0),
        child: widget.child,
      ),
    );
  }
}
