import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/chat_group.dart';
import '../models/chat_message.dart';
import '../models/character_card.dart';
import '../models/world_info.dart';
import '../services/active_generations.dart';
import '../services/api_client.dart';
import '../services/authors_note.dart';
import '../services/bookmarks.dart';
import '../services/chat_export.dart';
import '../services/chat_export_files.dart';
import '../services/chat_gen_settings.dart';
import '../services/chat_index_cache.dart';
import '../services/chat_index.dart';
import '../services/chat_transcript.dart';
import '../services/chat_layout.dart';
import '../services/display_regex.dart';
import '../services/file_pick.dart';
import '../services/context_usage.dart';
import '../services/hit_stats.dart';
import '../services/impersonate.dart';
import '../services/macros.dart';
import '../services/prompt_audit.dart';
import '../services/prompt_builder.dart';
import '../services/reply_suggestions.dart';
import '../services/sampling_params.dart';
import '../services/st_injection.dart';
import '../services/st_chat_importer.dart';
import '../services/st_preset.dart';
import '../services/storage.dart';
import '../services/stream_throttle.dart';
import '../services/summarize.dart';
import '../services/token_estimate.dart';
import '../services/usage_cost.dart';
import '../services/user_personas.dart';
import '../services/world_info_engine.dart';
import '../widgets/chat_search_sheet.dart';
import '../widgets/import_report_dialog.dart';
import 'chat_tree_screen.dart';
import 'group_host_screen.dart';
import '../widgets/common.dart';
import '../widgets/reply_suggestions_bar.dart';
import '../widgets/sheet_menu.dart';
import 'authors_note_screen.dart';
import 'card_state_screen.dart';
import 'chat_preset_screen.dart';
import 'character_edit_screen.dart';
import 'prompt_audit_screen.dart';
import 'settings_screen.dart';
import 'world_book_bindings_screen.dart';

/// 继续生成时附加在 messages 末尾的 system 指令。
const String kContinueInstruction =
    '接着上一条回复的最后一个字继续输出，不要重复、不要重新开头';

/// 自动跟随阈值：滚动位置在底部 120px 以内才自动跟到底。
const double _kFollowThreshold = 120;

/// 流式刷新最小间隔（ms）：一帧内多个 token 合并成一次 setState。
const int _kStreamFlushMs = 33;

/// 聊天页（核心页面）。单聊与群聊共用一套气泡/流式/变体/菜单机器，
/// 仅 prompt 组装、轮转与标题不同（v0.6.0 群聊）。
class ChatScreen extends StatefulWidget {
  /// 单聊角色 id（群聊模式为空串）
  final String charId;

  /// 群聊群 id（单聊模式为 null）
  final String? groupId;

  /// 具体聊天文件 id（v0.17.0，多聊天）。null = 该角色/群聊的默认会话。
  final String? convId;

  /// 聊天显示名（多聊天时用于标题与列表；null = 角色名 / 群名）。
  final String? chatName;

  const ChatScreen({
    super.key,
    required this.charId,
    this.convId,
    this.chatName,
  }) : groupId = null;

  const ChatScreen.group({
    super.key,
    required this.groupId,
    this.convId,
    this.chatName,
  }) : charId = '';

  bool get isGroup => groupId != null;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  CharacterCard? _card;

  /// 群聊状态（单聊为 null / 空）
  ChatGroup? _group;
  List<CharacterCard> _members = [];

  /// 早期对话摘要（随会话持久化）
  ChatSummary? _summary;

  /// 世界书条目命中率统计（v0.8.0，随会话持久化；null = 旧会话无记录）
  HitStats? _hitStats;

  /// 待记录一次真实发送的命中率（仅 [_doSend] 置位，[_runOnce] 消费一次 ——
  /// 群聊整轮 / 自动继续只算 1 次；预览与重新生成不计）
  bool _statsPending = false;

  /// 上下文占用（v0.8.0）：发送前满压缩的历史条数覆盖（null = 用设置值）
  int? _historyLimitOverride;

  /// 满压缩硬裁剪兜底：组装时不带摘要（历史由 [_historyLimitOverride] 限 10 条）
  bool _ctxHardTrim = false;

  /// 最近一次 API 返回的真实输入 token（上下文占用页「上次实际」）
  int? _lastExactPrompt;

  /// v0.35.0：这次发送按前缀估算能命中缓存多少输入 token（统计页用）
  int _lastCachedEstimate = 0;

  /// 顶部上下文占用条的估算缓存（消息数/末条长度/摘要/历史条数变化时重算）
  int? _ctxBarTotal;
  int? _ctxBarMsgLen;
  int? _ctxBarLastLen;
  int? _ctxBarHistoryLimit;
  ChatSummary? _ctxBarSummary;

  /// 发送准备管线进行中（挡住两次快速连点在微任务间隙重复发送）
  bool _preparing = false;

  /// 正在生成摘要（v0.18.0 起后台静默：不再显示进度条，只用于门禁与停止）
  bool _summarizing = false;

  bool get _isGroup => widget.isGroup;

  /// 会话存储 key：多聊天用显式 id；否则单聊 = 角色 id、群聊 = `group_<群id>`
  String get _convId =>
      widget.convId ??
      (_isGroup ? Storage.groupConvId(widget.groupId!) : widget.charId);

  /// 聊天文件索引的 owner：单聊 = 角色 id；群聊 = `group_<群id>`
  String get _ownerId =>
      ChatIndex.ownerOf(charId: widget.charId, groupId: widget.groupId);

  /// 当前聊天显示名（标题 / 索引里用）
  String get _chatTitle =>
      widget.chatName ?? (_isGroup ? (_group?.name ?? '群聊') : (_card?.name ?? ''));

  /// 能否组装 prompt（统计/生成的前置条件）
  bool get _canBuildPrompt =>
      _isGroup ? _members.isNotEmpty : _card != null;

  List<ChatMessage> _messages = [];
  List<WorldInfo> _worldBooks = [];
  bool _loading = true;

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _api = ApiClient();

  /// 用户侧建议回复（v0.12.1）进行中的独立请求客户端：
  /// 每条建议一条连接（共用会互相 cancel），离开页面时统一释放。
  final List<ApiClient> _suggestClients = [];

  /// 当前一批建议（可直接发送）；空 = 不渲染建议条。
  List<String> _suggestions = const [];

  /// 建议请求进行中（建议条显示行内 loading）。
  bool _suggesting = false;

  /// 建议请求代次：发新消息 / 停止 / 重开时自增，旧响应作废。
  int _suggestSeq = 0;

  bool _generating = false;
  bool _followScroll = true;

  /// 进入聊天的初始定位「收敛完成」标志（settle 方案，见 [_locateInitial]）
  bool _initialLocated = false;

  /// 收敛进行中：期间冻结跟随判定（[_followScroll] 保持 false）
  bool _locating = false;

  /// 本轮收敛上一帧的 maxScrollExtent（相邻两帧差值 ≤1px 即收敛）
  double? _prevMaxExtent;

  /// 本轮收敛已进行的帧数（上限 10 帧防死循环）
  int _locateFrame = 0;

  /// 是否为 300ms 兜底二轮收敛（不再递归调度第三轮）
  bool _isReSettle = false;
  Timer? _reSettleTimer;

  /// 输入框是否为空（只通知发送按钮，打字不触发整页 setState）
  final _inputEmpty = ValueNotifier<bool>(true);

  /// 用户手指正按在列表上拖动：期间冻结跟随判定，绝不与手势抢位置
  bool _userDragging = false;
  int _genToken = 0;
  DateTime _lastSave = DateTime(0);

  /// 流式文本缓冲：≥33ms 才落一次 setState，禁止每个 token 全列表 rebuild
  /// （v0.8.0 抽成共享 StreamThrottle，AI 角色卡创建器复用同一实现）
  late final StreamThrottle _throttle = StreamThrottle(
    minIntervalMs: _kStreamFlushMs,
    onFlush: _applyStreamBuffer,
  );

  /// 本次生成的记账状态
  bool _isContinueGen = false; // 是否"继续生成"（追加到同一变体）
  int _genStartLen = 0; // 生成开始时 content 长度（估算只算新增部分）
  bool _tokensApplied = false; // 本次生成的 token 是否已写入（防重复累计）

  /// 自动继续（v0.6.0）：本轮回复已用掉的自动续接次数 / 最近一次输出 token 数
  int _autoUsed = 0;
  int? _lastCompletion;

  /// 最近一次生成是否出错（群聊轮转据此中断本轮）
  bool _genFailed = false;

  /// 本次请求是否带了非默认高级采样字段（v0.9.0：失败时错误气泡下追加提示）
  bool _sentAdvanced = false;

  /// 最近一次出错的请求是否带了非默认高级字段（提示行显示条件，
  /// 仅页面内存态：重进后旧错误只显示原始错误文本）
  bool _lastErrorAdvanced = false;

  /// 已完成消息的 widget 缓存（含 markdown 渲染结果）。
  /// key 是消息对象本身：内容/身份一变即自然失效；列表结构变化时整体清空。
  final Map<ChatMessage, Widget> _msgCache = {};

  /// 分页加载窗口（v0.42.0）：先渲染最近 [_pageSize] 条，上滑到顶再往前加载。
  static const int _pageSize = 200;
  int _visibleCount = _pageSize;
  int _cacheLen = -1;
  Object? _cacheToken;

  /// 最近一次实际发送给 API 的 system 内容（供"查看注入内容"）
  String? _lastSystemText;

  /// 最近一次激活的世界词条目（带来源）
  List<ActivatedEntry> _lastActivated = [];

  /// 最近一次发送的完整 messages（供停止后估算 tokens）
  List<PromptMessage>? _lastPrompt;
  /// 上一次发送的提示词（v0.28.0 提示词检视用来逐段比对缓存）。
  List<PromptMessage>? _prevPrompt;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    // v0.10.0：只解绑后台生成的 UI 监听，不取消请求 —— 生成在后台跑完，
    // 完成由管理器落库；重进本页时 _load 里的接管逻辑恢复显示。
    ActiveGenerations.instance.of(_convId)?.detach();
    // 已排队的节流快照不再落盘：避免它晚于管理器后台落库执行，
    // 把权威全文回写成部分文本（见 _save）
    _saveAborted = true;
    _throttle.dispose();
    // 建议回复（v0.12.1）：页面私有请求，离开即释放（与后台生成相反）
    _suggestSeq++;
    for (final c in _suggestClients) {
      c.dispose();
    }
    _suggestClients.clear();
    // 替我说一句（v0.16.0）：同样是页面私有请求
    _impersonateClient?.dispose();
    _impersonateClient = null;
    _reSettleTimer?.cancel();
    _api.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _inputCtrl.dispose();
    _inputEmpty.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 加载 --

  Future<void> _load() async {
    if (_isGroup) {
      await _loadGroup();
      return;
    }
    final card = await Storage.loadCharacter(widget.charId);
    if (card == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    // 生成中任务先记一次：读后任务恰好完成落库的竞态由下方第二次查兜底
    final jobBefore = ActiveGenerations.instance.of(_convId);
    final data = await Storage.loadConversationData(_convId);
    var msgs = data.messages;
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
      Storage.saveConversation(_convId, msgs, summary: data.summary);
    }

    // 世界书：卡内嵌 + 该角色挂载且启用的合并
    final books = await _loadWorldBooksFor(card);

    // v0.17.0：老会话补进聊天索引（列表里能看到历史对话）
    if (widget.convId == null) {
      await ChatIndex.ensure(
        _ownerId,
        defaultId: widget.charId,
        defaultName: card.name,
      );
    }

    if (!mounted) return;
    final job = ActiveGenerations.instance.of(_convId);
    if (job != null) {
      // 生成中重进（v0.10.0）：内容以任务缓冲为准 + 接管显示
      msgs = _adoptJob(msgs, job);
    } else if (jobBefore != null) {
      // 任务恰好在读取期间完成并落库 → 重读一次拿最终内容
      final fresh = await Storage.loadConversationData(_convId);
      if (!mounted) return;
      msgs = fresh.messages;
    }
    setState(() {
      _card = card;
      // 防御：无论来源如何都复制成可增长列表（_doSend 会 add）
      _messages = List.of(msgs);
      _visibleCount = _pageSize;
      _summary = data.summary;
      _hitStats = data.hitStats; // 旧会话无记录 = null（不显示命中率）
      _worldBooks = books;
      _authorNote = AuthorNoteStore.load(_convId);
      _loading = false;
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
      _cacheLen = -1;
    });
    _locateInitial();
  }

  /// 群聊加载：群定义 + 现存成员卡 + 会话（无开场白，用户先发言）。
  Future<void> _loadGroup() async {
    final group = await Storage.loadGroup(widget.groupId!);
    if (group == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final all = await Storage.loadCharacters();
    // 保持 memberIds 顺序（即群内顺序）；卡已被删除的成员跳过
    final members = <CharacterCard>[];
    for (final id in group.memberIds) {
      for (final c in all) {
        if (c.id == id) {
          members.add(c);
          break;
        }
      }
    }
    final jobBefore = ActiveGenerations.instance.of(_convId);
    final data = await Storage.loadConversationData(_convId);
    final books = await _loadWorldBooksForGroup(members);

    // v0.17.0：群聊老会话补进聊天索引
    if (widget.convId == null) {
      await ChatIndex.ensure(
        _ownerId,
        defaultId: Storage.groupConvId(group.id),
        defaultName: group.name,
      );
    }

    if (!mounted) return;
    var msgs = data.messages;
    final job = ActiveGenerations.instance.of(_convId);
    if (job != null) {
      msgs = _adoptJob(msgs, job);
    } else if (jobBefore != null) {
      final fresh = await Storage.loadConversationData(_convId);
      if (!mounted) return;
      msgs = fresh.messages;
    }
    setState(() {
      _group = group;
      _members = members;
      // 防御：复制成可增长列表，杜绝任何来源的不可变列表
      _messages = List.of(msgs);
      _visibleCount = _pageSize;
      _summary = data.summary;
      _hitStats = data.hitStats; // 旧会话无记录 = null（不显示命中率）
      _worldBooks = books;
      _authorNote = AuthorNoteStore.load(_convId);
      _loading = false;
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
      _cacheLen = -1;
    });
    _locateInitial();
  }

  /// 生成中重进接管（v0.10.0）：目标消息以任务权威缓冲 fullText 整段
  /// 替换（磁盘上可能只是部分文本），随后 [GenerationJob.attach] 绑定
  /// 流式回调继续显示，任务结束由 onDone 收尾（发起页 await finished
  /// 的编排已随页面销毁作废，避免双跑）。
  /// 目标占位消息找不到（会话已被清空）时不接管，与落库同判据。
  List<ChatMessage> _adoptJob(List<ChatMessage> msgs, GenerationJob job) {
    final out = List<ChatMessage>.of(msgs);
    final ts = job.targetTs;
    var idx = -1;
    if (ts != null) {
      for (var i = out.length - 1; i >= 0; i--) {
        final m = out[i];
        if (m.role != 'assistant') continue;
        if (m.timestamp == ts &&
            (job.targetSender == null || m.senderId == job.targetSender)) {
          idx = i;
          break;
        }
      }
    }
    if (idx < 0) return out; // 目标不在 → 不接管
    out[idx] = out[idx].copyWith(content: job.fullText, error: job.error);

    // 记账状态对齐发起页（token 记账、自动继续判断、失败提示沿用任务快照）
    _throttle.reset();
    _generating = true;
    _isContinueGen = job.isContinue;
    _genStartLen = job.genStartLen;
    _tokensApplied = false;
    _genFailed = false;
    _statsPending = false;
    _prevPrompt = _lastPrompt;
    _lastPrompt = job.prompt;
    _sentAdvanced = job.sentAdvanced;
    _lastErrorAdvanced = job.error != null && job.sentAdvanced;

    // 之后到达的增量才进页面镜像（fullText 已含接管前的全部文本）
    final token = ++_genToken;
    job.attach(
      onDelta: (delta) {
        if (!mounted || token != _genToken) return;
        _enqueueDelta(delta);
      },
      onError: (error) {
        if (!mounted || token != _genToken) return;
        _flushStream();
        setState(() {
          final i = _messages.length - 1;
          if (i < 0 || _messages[i].role != 'assistant') return;
          _messages[i] = _messages[i].copyWith(error: error);
        });
        _genFailed = true;
        _lastErrorAdvanced = job.sentAdvanced;
      },
      onDone: (j) {
        if (!mounted || token != _genToken) return;
        _flushStream();
        setState(() {
          _generating = false;
          _applyTokens(j.exactPrompt, j.exactCompletion);
        });
        _save(force: true);
        _followBottom();
      },
    );
    return out;
  }

  /// 群聊合并世界书：各成员 enabled 挂载（跨成员去重）+ 各自卡内嵌。
  /// v0.27.0：四范围（全局 / 人设 / 角色 / 这段聊天）合并后取启用项。
  Future<List<WorldInfo>> _loadWorldBooksForGroup(
      List<CharacterCard> members) async {
    final books = <WorldInfo>[];
    final enabledIds = <String>{};
    final shared = await Storage.effectiveWorldBookMounts(
      convId: _convId,
      personaId: PersonaStore.active?.id,
    );
    for (final m in shared) {
      enabledIds.add(m.id);
    }
    for (final card in members) {
      final embedded = card.characterBook;
      if (embedded != null) {
        books.add(embedded.name.trim().isEmpty
            ? WorldInfo(
                name: '卡内嵌世界书',
                description: embedded.description,
                entries: embedded.entries,
              )
            : embedded);
      }
      final mounts = await Storage.effectiveWorldBookMounts(
        charId: card.id,
        convId: _convId,
        personaId: PersonaStore.active?.id,
      );
      for (final m in mounts) {
        enabledIds.add(m.id);
      }
    }
    if (enabledIds.isNotEmpty) {
      final all = await Storage.loadWorldBooks();
      for (final (id, wb) in all) {
        // 同一本书被多名成员挂载只并入一次（去重）
        if (enabledIds.contains(id)) books.add(wb);
      }
    }
    return books;
  }

  /// 该角色参与激活的世界书：卡内嵌 + 四范围合并后启用的。
  /// v0.27.0：全局 / 人设 / 角色 / 这段聊天，任一范围开启即注入。
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
    final mounts = await Storage.effectiveWorldBookMounts(
      charId: card.id,
      convId: _convId,
      personaId: PersonaStore.active?.id,
    );
    final enabledIds = {for (final m in mounts) m.id};
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

  /// 页面已 dispose：排队中的快照不再写盘（v0.10.0，见 dispose）
  bool _saveAborted = false;

  void _save({bool force = false}) {
    if (!_isGroup && _card == null) return;
    if (_isGroup && _group == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastSave).inMilliseconds < 500) return;
    _lastSave = now;
    final snapshot = List.of(_messages);
    final summary = _summary;
    final hitStats = _hitStats;
    final convId = _convId;
    // 串行写入，避免并发覆盖
    _pendingSave = _pendingSave.then((_) {
      if (_saveAborted) return Future<void>.value();
      return Storage.saveConversation(
        convId,
        snapshot,
        summary: summary,
        hitStats: hitStats,
      ).then((_) async {
        // v0.17.0：同步聊天索引的条数与最近使用时间（失败不影响聊天）
        if (_saveAborted) return;
        await ChatIndex.touch(
          _ownerId,
          convId: convId,
          messageCount: snapshot.length,
          name: _chatTitle,
          updatedAt: _lastSave.millisecondsSinceEpoch,
        );
      });
    });
  }

  // ----------------------------------------------------------- 滚动 --

  void _onScroll() {
    // 上滑到接近顶部 → 往前多加载一页（v0.42.0 分页）。
    if (_scrollCtrl.hasClients &&
        _visibleCount < _messages.length &&
        _scrollCtrl.position.pixels <= 80) {
      setState(() => _visibleCount += _pageSize);
    }
    if (_userDragging) return; // 拖动中不改变跟随状态
    if (_locating) return; // 初始收敛期间跟随判定冻结（完成后再放开）
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

  /// 进入聊天的初始定位 —— settle（逐帧收敛）方案。
  ///
  /// 根因：`ListView.builder` 的变高条目是懒加载的，数据 setState 后的
  /// 第一帧 `maxScrollExtent` 只是估算值（底部条目还没实际构建），
  /// 单次 `jumpTo(估算底)` ≠ 真实底，实测落在中间。
  ///
  /// 收敛流程：每帧 postFrame 内 `jumpTo(position.maxScrollExtent)`，
  /// 记录上一帧的 max；相邻两帧 max 差值 ≤1px 视为收敛停止（上限 10 帧
  /// 防死循环）。收敛期间 `_followScroll = false`（不触发流式跟随逻辑），
  /// 完成后再置 true。期间用户一旦开始拖动（[_userDragging]）立即让位停止。
  /// 收敛完成后 300ms 再跑一轮同样的收敛，兜底字体/异步布局的二次变化。
  void _locateInitial() {
    if (_initialLocated || _locating) return;
    _startSettle(reSettle: false);
  }

  /// 发起一轮收敛（[_reSettleTimer] 到点的兜底轮 [reSettle] 为 true）。
  void _startSettle({required bool reSettle}) {
    _isReSettle = reSettle;
    _prevMaxExtent = null;
    _locateFrame = 0;
    _followScroll = false;
    _locating = true;
    _scheduleLocateFrame();
  }

  void _scheduleLocateFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_locating) return;
      if (!mounted || !_scrollCtrl.hasClients) {
        _locating = false;
        return;
      }
      if (_userDragging) {
        // 用户已开始拖动：立即让位停止（本轮与兜底轮都作废）
        _locating = false;
        _initialLocated = true;
        _reSettleTimer?.cancel();
        _onScroll();
        return;
      }
      final pos = _scrollCtrl.position;
      final max = pos.maxScrollExtent;
      if (pos.pixels != max) _scrollCtrl.jumpTo(max);
      _locateFrame++;
      final settled =
          _prevMaxExtent != null && (max - _prevMaxExtent!).abs() <= 1;
      _prevMaxExtent = max;
      if (settled || _locateFrame >= 10) {
        _finishLocate();
      } else {
        _scheduleLocateFrame();
      }
    });
  }

  void _finishLocate() {
    _locating = false;
    _initialLocated = true;
    _followScroll = true;
    if (_isReSettle) return; // 兜底轮结束，不再递归
    // 兜底：300ms 后再执行一次同样的收敛（防字体/异步布局二次变化）。
    // 用户已拖离底部（_followScroll=false）时不兜底，绝不与用户抢位置。
    _reSettleTimer?.cancel();
    _reSettleTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || !_scrollCtrl.hasClients) return;
      if (_userDragging || !_followScroll) return;
      _startSettle(reSettle: true);
    });
  }

  // ------------------------------------------------------------- 生成 --

  /// 对话里「我」的名字（v0.16.0：优先当前用户人设，否则设置里的 userName）。
  String get _macroUserName => PersonaStore.activeName;

  /// 当前会话的作者注释（v0.16.0）；会话级，没存过回退默认值。
  AuthorNote _authorNote = AuthorNote.empty;

  /// ST 兼容模式注入计划缓存（v0.31.0）：按预设 JSON 缓存，改了就重算。
  String? _stPlanRaw;
  StInjectionPlan? _stPlan;

  String _macro(String s) => applyMacros(
        s,
        charName: _card?.name ?? '',
        userName: _macroUserName,
        personaText: PersonaStore.activeDescription,
      );

  bool get _canConfigure => AppSettings.apiConfigured;

  void _send() => _sendText(_inputCtrl.text);

  /// 发送一条用户消息（输入框发送与快捷回复共用，走正常生成流程）。
  /// 发送前先跑两条准备管线（都不计命中率）：
  /// 1. v0.6 长对话摘要（可取消，成败都不阻塞发送）；
  /// 2. v0.8.0 上下文满压缩（依次降级，绝不允许发送失败）。
  void _sendText(String raw) {
    final text = raw.trim();
    if (text.isEmpty || _generating || _summarizing || _preparing) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    if (_isGroup && _members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('群成员都已被删除，请重建这个群聊')),
      );
      return;
    }
    _prepareAndSend(text);
  }

  /// 摘要管线 → 上下文满压缩 → 真正落消息开跑。
  Future<void> _prepareAndSend(String text) async {
    _preparing = true;
    try {
      if (_summaryNeeded()) {
        setState(() => _summarizing = true);
        await _runSummarize();
        if (mounted) setState(() => _summarizing = false);
      }
      if (mounted && AppSettings.contextWindow > 0) {
        await _compressIfNeeded(text);
      }
    } finally {
      _preparing = false;
    }
    if (!mounted) return;
    _doSend(text);
  }

  /// 发送前满压缩（v0.8.0）：发送上下文估算 > 窗口×90% 时依次降级，
  /// 绝不允许发送失败或超窗硬拼：
  /// 1. 历史条数减半（下限 10 条）重算；
  /// 2. 仍超 → 走现有摘要管线（复用 v0.6 摘要逻辑与 API 配置，
  ///    把已有摘要 + 超记忆长度的更早历史压成新摘要）；
  /// 3. 摘要失败/仍超 → 硬裁剪兜底：仅系统提示+世界书+最近 10 条。
  Future<void> _compressIfNeeded(String pending) async {
    final window = AppSettings.contextWindow;
    if (window <= 0 || !_canBuildPrompt) return;
    if (!overContextBudget(_estimateSendTokens(pending), window)) return;

    // 已是硬裁剪状态还超：系统提示+世界书本身超窗（窗口设置过小），
    // 放行并提示，不重入降级循环
    if (_ctxHardTrim) {
      _toast('上下文已满，已裁剪发送');
      return;
    }

    // 第 1 步：历史条数减半（下限 10 条），按新条数重算
    final halved = halveHistoryLimit(_historyLimit);
    if (halved < _historyLimit) {
      _historyLimitOverride = halved;
      final t = _estimateSendTokens(pending);
      if (!overContextBudget(t, window)) {
        _toastCompressed(t, window);
        return;
      }
    }

    // 第 2 步：现有摘要管线（后台静默执行，输入栏不显示进度）
    setState(() => _summarizing = true);
    await _runSummarize(preamble: _summary?.text);
    if (!mounted) return;
    setState(() => _summarizing = false);
    final t = _estimateSendTokens(pending);
    if (!overContextBudget(t, window)) {
      _toastCompressed(t, window);
      return;
    }

    // 第 3 步：兜底硬裁剪 —— 仅系统提示+世界书+最近 10 条，不带摘要
    _historyLimitOverride = 10;
    _ctxHardTrim = true;
    _toast('上下文已满，已裁剪发送');
  }

  /// 发送上下文估算（当前消息 + 待发送消息，按当前压缩状态组装）。
  /// 与真实发送走同一 [_buildWith]，口径完全一致。
  int _estimateSendTokens(String pending) {
    final history = List<ChatMessage>.of(_messages)
      ..add(ChatMessage(role: 'user', content: pending, timestamp: 0));
    final built = _buildWith(
      history,
      worldBooks: _worldBooks,
      summaryText: _ctxHardTrim ? null : _summary?.text,
    );
    return estimateTokens(built.messages.map((m) => m.content).join('\n'));
  }

  void _toastCompressed(int tokens, int window) {
    _toast('上下文占用过高，已自动压缩（${contextPercent(tokens, window)}%）');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 实际落消息并开跑（摘要管线的下半场也走这里）。
  void _doSend(String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 群聊：计算本轮发言序列（@ 点名 → 仅被点名者按群内顺序；否则全员从指针轮转）
    var targets = const <int>[];
    if (_isGroup) {
      final names = [for (final m in _members) m.name];
      final pointer = _group?.turnIndex ?? 0;
      targets = turnOrder(_members.length, pointer, parseMentions(text, names));
      if (targets.isEmpty) {
        targets = turnOrder(_members.length, pointer, null);
      }
      if (targets.isEmpty) return;
    }
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text, timestamp: now));
      if (_isGroup) {
        final m = _members[targets.first];
        _messages.add(ChatMessage(
          role: 'assistant',
          content: '',
          timestamp: now,
          senderId: m.id,
          senderName: m.name,
        ));
      } else {
        _messages.add(ChatMessage(role: 'assistant', content: '', timestamp: now));
      }
      _generating = true;
      _followScroll = true;
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
    });
    _inputCtrl.clear();
    _inputEmpty.value = true;
    // 发出新消息：上一批建议作废（否则会按旧上下文继续展示）
    _clearSuggestions();
    // 真实发送标记：本次用户消息触发的组装记一次命中率
    // （群聊整轮只在首个成员的组装记 1 次；重新生成/继续生成不置位）
    _statsPending = true;
    _save(force: true);
    _scrollToBottom();
    if (_isGroup) {
      _runGroupRound(targets);
    } else {
      _generateSingle();
    }
  }

  // --------------------------------------------------- 群聊主持（v0.36.0） --

  /// 「让大家接着说」时追加的临时提示（不写进聊天记录）。
  static const String _kGroupContinueNudge =
      '（没有新的用户发言，请让角色们顺着当前剧情接着聊下去，保持各自的语气，不要替用户说话。）';

  /// 本轮是不是「让大家接着说」触发的（只在组装提示词时用一次）。
  bool _continuationNudge = false;

  /// 当前生效的发言名单（成员下标；空 = 全员）。
  List<int> _hostRoster() => _group?.speakerIndexes() ?? const <int>[];

  /// 群聊主持：设置发言名单与顺序。
  Future<void> _openGroupHost() async {
    final g = _group;
    if (g == null) return;
    if (_generating || _summarizing) {
      _toast('等这一轮说完再改发言名单');
      return;
    }
    final updated = await Navigator.of(context).push<ChatGroup>(
      MaterialPageRoute(
        builder: (_) => GroupHostScreen(
          group: g,
          members: _members,
          onChanged: (next) {
            _group = next;
            Storage.saveGroup(next);
          },
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      if (updated != null) _group = updated;
    });
    if (updated != null) await Storage.saveGroup(updated);
  }

  /// 「让大家接着说」：不插用户消息，让名单里的角色自己续一轮。
  Future<void> _continueGroupRound() async {
    if (_generating || _summarizing || !_isGroup) return;
    if (!_canBuildPrompt) {
      _toast('还没有可以聊的角色卡');
      return;
    }
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    final roster = _hostRoster();
    final targets = hostedTurnOrder(
      _members.length,
      roster,
      _group?.turnIndex ?? 0,
      null,
    );
    if (targets.isEmpty) {
      _toast('没有可发言的角色');
      return;
    }
    _statsPending = false; // 不是用户真实发送，不计命中率
    _continuationNudge = true;
    setState(() {
      final m = _members[targets.first];
      _messages.add(ChatMessage(
        role: 'assistant',
        content: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        senderId: m.id,
        senderName: m.name,
      ));
      _generating = true;
      _followScroll = true;
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
    });
    _save(force: true);
    _followBottom();
    try {
      await _runGroupRound(targets);
    } finally {
      _continuationNudge = false;
    }
  }
  // ------------------------------------------------------- 群聊轮转 --

  /// 一轮：按 [targets]（成员下标）逐个生成，每人一条回复。
  /// 轮转指针在每位成员"开始发言"时即推进 —— 中途停止不回退，
  /// 下次发送从下一成员继续；完整一轮跑完指针绕回起点。
  Future<void> _runGroupRound(List<int> targets) async {
    for (var k = 0; k < targets.length; k++) {
      if (!mounted || !_generating) break;
      if (k > 0) {
        // 为下一位成员追加空占位（sender 随消息持久化）
        final m = _members[targets[k]];
        setState(() {
          _messages.add(ChatMessage(
            role: 'assistant',
            content: '',
            timestamp: DateTime.now().millisecondsSinceEpoch,
            senderId: m.id,
            senderName: m.name,
          ));
          _msgCache.clear();
          ChatIndexCache.instance.invalidate();
        });
        _save(force: true);
        _followBottom();
      }
      final g = _group;
      if (g != null) {
        final next = advanceHostTurn(_members.length, _hostRoster(), targets[k]);
        if (next != g.turnIndex) {
          _group = g.withTurnIndex(next);
          Storage.saveGroup(_group!); // 不 await，尽快落盘
        }
      }
      final ok = await _generate();
      if (!ok || !mounted) break; // 停止或失败 → 本轮结束
    }
    _finishGeneration();
  }

  /// 生成收尾：关掉进行中状态并落盘（单次操作与轮转共用）。
  void _finishGeneration() {
    if (!mounted) return;
    // 停止/清空后立刻重发的竞态：同 key 已有新一轮任务时 `_generating`
    // 归新一轮管，本链只负责落盘，不得把新任务的进行中状态关掉。
    final busy = ActiveGenerations.instance.has(_convId);
    if (_generating && !busy) {
      setState(() => _generating = false);
    }
    _save(force: true);
    _followBottom();
    // 回复完成：开着「自动生成回复」时补一批用户侧建议（失败静默）
    _maybeSuggestReplies();
  }

  // ---------------------------------------- 用户侧建议回复（v0.12.1） --

  /// 一批生成几条建议
  static const int _kSuggestionCount = 3;

  /// 生成用户侧「可以发送的下一句」：AI 回复完成后按开关自动触发，
  /// 也可点输入栏左侧的 ✨ 手动触发。只对单聊生效。
  /// 建议属于锦上添花：失败静默、不占用 _generating 状态。
  Future<void> _suggestReplies() async {
    if (_isGroup || _suggesting || _generating || _summarizing) return;
    final seq = ++_suggestSeq;
    setState(() {
      _suggesting = true;
      _suggestions = const <String>[];
    });
    // 输入栏上方多出一行 → 视口变矮，把最后一条气泡重新贴到底部
    _keepBottomVisible();
    final messages = _buildSuggestionMessages();
    final sampling = AppSettings.activePreset.sampling;
    final received = <String>[];
    var remaining = _kSuggestionCount;
    // v0.18.1：三条并行请求，谁先回来就先显示谁 —— 不用等最慢的那条。
    for (var i = 0; i < _kSuggestionCount; i++) {
      unawaited(
        _fetchOneSuggestion(
          // 每条给不同的语气/风格指令，避免三条雷同
          appendSuggestionInstruction(messages, styleIndex: i),
          sampling.forCandidate(i),
        ).then((text) {
          remaining--;
          final t = text.trim();
          if (!mounted || seq != _suggestSeq) return;
          if (t.isNotEmpty) received.add(t);
          setState(() {
            _suggestions = normalizeSuggestions(received);
            if (remaining <= 0) _suggesting = false;
          });
          // 建议行渲染完成后再贴一次底，避免气泡被建议条挡住
          _keepBottomVisible();
        }),
      );
    }
  }

  /// 建议回复只依赖最近的上下文：整段 prompt 太大（世界书 + 摘要 + 全历史），
  /// 会让三条小请求的等待时间明显变长。这里只保留 system + 最近 10 条。
  List<PromptMessage> _buildSuggestionMessages() {
    final all = _buildPrompt().messages;
    const keep = 10;
    if (all.length <= keep + 1) return all;
    return <PromptMessage>[all.first, ...all.sublist(all.length - keep)];
  }

  /// 建议每条最多回多少 token：够一句话就行，别按聊天回复的上限等。
  int get _suggestionMaxTokens {
    final m = AppSettings.activePreset.maxTokens;
    if (m <= 0 || m > 240) return 240;
    return m;
  }

  /// 跟随状态下把最后一条气泡贴到底部（建议条/加载行出现时调用）。
  void _keepBottomVisible() {
    if (!_followScroll) return;
    _scrollToBottom();
  }

  /// 作废当前建议（发新消息 / 停止 / 状态变化时调用）。
  void _clearSuggestions() {
    _suggestSeq++;
    if (_suggestions.isEmpty && !_suggesting) return;
    setState(() {
      _suggesting = false;
      _suggestions = const [];
    });
  }

  /// AI 回复成功后按当前辅助方式自动补一批建议（群聊 / 失败回复不触发）。
  void _maybeSuggestReplies() {
    if (_isGroup || AppSettings.assistMode != AssistMode.suggestions) return;
    if (_generating || _summarizing) return;
    if (_messages.isEmpty) return;
    final last = _messages.last;
    if (last.role != 'assistant' || last.error != null) return;
    if (last.content.trim().isEmpty) return;
    _suggestReplies();
  }

  /// 单条建议：非流式请求。每条独立 ApiClient —— 共用会互相 cancel。
  Future<String> _fetchOneSuggestion(
    List<PromptMessage> messages,
    SamplingParams sampling,
  ) async {
    final client = ApiClient();
    _suggestClients.add(client);
    final buf = StringBuffer();
    try {
      await client.streamChat(
        baseUrl: AppSettings.baseUrl,
        apiKey: AppSettings.apiKey,
        model: AppSettings.model,
        messages: messages,
        temperature: AppSettings.temperature,
        topP: AppSettings.topP,
        maxTokens: _suggestionMaxTokens,
        stream: false,
        sampling: sampling,
        onDelta: buf.write,
        onError: (_) {},
        onDone: () {},
      );
    } catch (_) {
      // 建议失败不打扰用户：少了就少一条
    } finally {
      _suggestClients.remove(client);
      client.dispose();
    }
    return buf.toString();
  }

  /// 点某条建议 = 采用这条作为自己的回复直接发送，并清掉这一批。
  void _sendSuggestion(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _clearSuggestions();
    _sendText(t);
  }

  // ----------------------------------------------------- 长对话摘要 --

  /// 历史条数上限：满压缩降级期间用会话级覆盖，否则用设置值。
  int get _historyLimit =>
      _historyLimitOverride ?? AppSettings.contextHistoryLimit;

  /// 发送前是否需要摘要：开关开（调用方已查）且超窗且摘要为空/已过期。
  bool _summaryNeeded() =>
      AppSettings.autoSummarize &&
      summaryIsStale(_messages, _summary, _historyLimit);

  /// 消息的显示名（摘要/导出共用）。
  String _nameOf(ChatMessage m) {
    final sender = m.senderName?.trim();
    if (m.role == 'assistant' && sender != null && sender.isNotEmpty) {
      return sender;
    }
    if (_isGroup) {
      return _members.isNotEmpty ? _members.first.name : (_group?.name ?? '');
    }
    return _card?.name ?? '';
  }

  /// 跑一次摘要（发送前管线与菜单手动触发共用）。
  /// 成功写入 summary 并返回 true；失败/取消/超时(30s) 返回 false。
  /// [preamble] 非空时（v0.8.0 满压缩第 2 步）：把已有摘要一并交给
  /// 模型，和更早历史压成一份新摘要；否则只总结超记忆长度的早期消息。
  Future<bool> _runSummarize({String? preamble}) async {
    final early = earlyMessages(_messages, _historyLimit);
    if (early.isEmpty) return false;
    final transcript = buildSummaryTranscript(
      early: early,
      userName: _macroUserName,
      nameOf: _nameOf,
    );
    final user = (preamble == null || preamble.trim().isEmpty)
        ? transcript
        : '已有摘要：${preamble.trim()}\n\n'
            '以下是尚未纳入摘要的更早对话，请把两者合并成一份新摘要：\n$transcript';
    try {
      final raw = await _api
          .summarize(
            baseUrl: AppSettings.baseUrl,
            apiKey: AppSettings.apiKey,
            model: AppSettings.model,
            system: '你是对话摘要助手。把用户给出的早期对话压缩成不超过300字的中文摘要，'
                '只保留关键情节、人物关系与未决事项，不要任何前缀或解释，直接输出摘要。',
            user: user,
            // v0.9.0：摘要同样走激活预设的完整参数集（含 top_p）
            temperature: AppSettings.temperature,
            topP: AppSettings.topP,
            sampling: AppSettings.activePreset.sampling,
          )
          .timeout(const Duration(seconds: 30));
      final text = normalizeSummary(raw);
      if (text.isEmpty) return false; // 已取消或空输出
      if (!mounted) return false;
      setState(() {
        // updatedAt = 摘要覆盖到的最后一条早期消息时间戳（过期判断依据）
        _summary = ChatSummary(text: text, updatedAt: early.last.timestamp);
      });
      _save(force: true);
      return true;
    } on TimeoutException {
      _api.cancel();
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 菜单「立即总结早期对话」：同一管线，只总结不发送。
  Future<void> _manualSummarize() async {
    setState(() => _summarizing = true);
    final ok = await _runSummarize();
    if (!mounted) return;
    setState(() => _summarizing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已总结' : '总结未完成')),
    );
  }

  /// 进度条上的取消：掐掉摘要请求，本次跳过摘要（调用方继续原流程）。
  void _cancelSummarize() => _api.cancel();


  void _promptConfigureApi() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('还未配置模型'),
        content: const Text('先去设置里配置模型服务，然后就能开聊了。'),
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
  void _enqueueDelta(String delta) => _throttle.enqueue(delta);

  /// 立即把缓冲刷进最后一条 AI 消息（停止/出错/收尾时保证不丢字）。
  void _flushStream() => _throttle.flush();

  /// 把缓冲文本写进最后一条 AI 消息并刷新一次 UI（一帧多 token 只 setState 一次）。
  void _applyStreamBuffer(String buf) {
    if (!mounted || buf.isEmpty) return;
    setState(() {
      final i = _messages.length - 1;
      if (i < 0 || _messages[i].role != 'assistant') return;
      final m = _messages[i];
      _messages[i] = m.copyWith(content: m.content + buf);
    });
    _followBottom();
    _save();
  }

  /// 单次操作（单聊发送 / 重生成 / 重试 / 继续生成）：
  /// 生成一轮回复并收尾 `_generating`。
  Future<void> _generateSingle({bool isContinue = false}) async {
    // 开新一轮回复：上一批建议已过时，先清掉（回复完成会再自动生成）
    _clearSuggestions();
    await _generate(isContinue: isContinue);
    _finishGeneration();
  }

  /// 为末条 assistant 消息生成一轮回复（含自动继续循环）。
  /// 返回 true = 正常完成；false = 被停止或出错。
  /// 群聊轮转对每位成员各调一次，`_generating` 由轮转持有。
  Future<bool> _generate({bool isContinue = false}) async {
    if (!_canBuildPrompt) return false;
    _autoUsed = 0; // 自动继续次数按"每条回复"计
    var cont = isContinue;
    while (true) {
      if (!mounted) return false;
      setState(() {
        _isContinueGen = cont;
        _genStartLen = cont &&
                _messages.isNotEmpty &&
                _messages.last.role == 'assistant'
            ? _messages.last.content.length
            : 0;
        _throttle.reset();
      });
      final ok = await _runOnce();
      if (!ok || !mounted) return false;
      if (!_shouldAutoContinue()) return true;
      _autoUsed++;
      cont = true;
    }
  }

  /// 自动继续触发（v0.6.0）：`max_tokens > 0` 且本次输出 ≥ 上限×0.98，
  /// 且未达次数上限、用户未停止、上次生成成功且已有正文。
  bool _shouldAutoContinue() {
    if (!mounted || !_generating || _genFailed) return false;
    final maxT = AppSettings.maxTokens;
    if (maxT <= 0) return false;
    if (_autoUsed >= AppSettings.autoContinueCount) return false;
    final c = _lastCompletion;
    if (c == null) return false;
    if (_messages.isEmpty || _messages.last.role != 'assistant') return false;
    if (_messages.last.content.isEmpty) return false;
    return c >= maxT * 0.98;
  }

  /// 单次流式请求（一次 streamChat；`_isContinueGen` 时追加到同一变体）。
  Future<bool> _runOnce() async {
    final token = ++_genToken;
    _tokensApplied = false;
    _genFailed = false;

    final built = _buildPrompt();
    _lastSystemText = built.systemText;
    _lastActivated = built.activated;

    // 命中率记账：只在真实 API 发送的组装点消费一次（_doSend 置位）。
    // 摘要生成、上下文占用预览、统计页/注入页的组装都不走这里，不计数；
    // 群聊整轮首个成员消费后，后续成员与自动继续不再计。
    if (_statsPending) {
      _statsPending = false;
      final stats = (_hitStats ?? const HitStats())
          .record(built.activated.map((a) => a.entryKey));
      setState(() => _hitStats = stats);
      _save(force: true);
    }

    // 继续生成：在现有 messages 末尾附加 system 指令，结果追加到同一消息
    final toSend = List<PromptMessage>.of(built.messages);
    if (_isContinueGen) {
      toSend.add(const PromptMessage(
        role: 'system',
        content: kContinueInstruction,
      ));
    }
    _prevPrompt = _lastPrompt;
    _lastPrompt = toSend;

    // v0.35.0：按「与上次发送的公共前缀」估算这次缓存能命中多少 token，
    // 只用于统计估算（真实命中数取决于服务商，不会影响请求内容）。
    _lastCachedEstimate = _prevPrompt == null
        ? 0
        : PromptAudit.analyze(current: toSend, previous: _prevPrompt)
            .cacheableTokens;

    // v0.34.0：这一段聊天可以有自己的采样参数；留空继续跟全局预设
    final gen = ChatGenSettings.resolve(_convId);
    final sampling = gen.sampling;
    _sentAdvanced = !sampling.isDefault;

    // v0.10.0：请求交给后台生成管理器 —— 页面 dispose 只解绑不取消，
    // 完成后由管理器落库；本页（发起方）await 任务结束走原有收尾编排。
    final target = _messages.last;
    final job = ActiveGenerations.instance.start(
      key: _convId,
      kind: GenKind.chat,
      request: GenRequest(
        baseUrl: AppSettings.baseUrl,
        apiKey: AppSettings.apiKey,
        model: AppSettings.model,
        messages: toSend,
        temperature: gen.temperature,
        topP: gen.topP,
        maxTokens: gen.maxTokens,
        stream: AppSettings.streaming,
        sampling: sampling,
      ),
      initialText: target.content,
      targetTs: target.timestamp,
      targetSender: target.senderId,
      genStartLen: _genStartLen,
      isContinue: _isContinueGen,
      prompt: toSend,
      sentAdvanced: _sentAdvanced,
      onDelta: (delta) {
        if (!mounted || token != _genToken) return;
        _enqueueDelta(delta);
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
        _genFailed = true;
        _lastErrorAdvanced = _sentAdvanced;
      },
    );
    // 同 key 已有进行中的生成（防重入兜底，正常被 _generating 挡住）
    if (job == null) return false;

    await job.finished;

    // usage 在请求结束前已写入任务（与原 onUsage 时序一致）
    final exactPrompt = job.exactPrompt;
    final exactCompletion = job.exactCompletion;
    if (exactPrompt != null) _lastExactPrompt = exactPrompt;

    _flushStream();
    // 被停止：_stop 已完成记账与落盘，这里直接退出
    if (!mounted || token != _genToken) return false;

    // 本次输出 token（自动继续判断用）：优先精确 usage，否则估算新增文本
    if (exactCompletion != null) {
      _lastCompletion = exactCompletion;
    } else {
      final m = _messages.last;
      final start = _genStartLen.clamp(0, m.content.length).toInt();
      _lastCompletion = estimateTokens(m.content.substring(start));
    }

    // 群聊：剥掉模型按规则自发的消息头「名字: 」（渲染时再加回，避免双前缀）
    if (_isGroup && !_isContinueGen) _stripSpeakerPrefix();

    setState(() {
      _applyTokens(exactPrompt, exactCompletion);
    });
    _save(force: true);
    _followBottom();
    return !_genFailed;
  }

  /// 组装本次发送的 prompt（单聊 / 群聊分流），带早期摘要。
  /// 硬裁剪兜底期间不带摘要（历史条数由 [_historyLimitOverride] 限 10）。
  PromptBuildResult _buildPrompt() => _buildWith(
        _messages,
        worldBooks: _worldBooks,
        summaryText: _ctxHardTrim ? null : _summary?.text,
      );

  /// 按指定历史/世界书/摘要组装（实际发送、占用明细与压缩估算共用，
  /// 保证估算口径与真实发送完全一致）。
  PromptBuildResult _buildWith(
    List<ChatMessage> history, {
    required List<WorldInfo> worldBooks,
    required String? summaryText,
  }) {
    // v0.24.0：对模型隐藏的消息不参与组 prompt（本地仍然显示/导出/搜索）。
    final visible = visibleForModel(history);
    // v0.31.0：ST 兼容模式（导入预设里启用的提示词按顺序真实注入）
    final st = _stInjectionPlan();
    if (_isGroup) {
      final last = visible.isEmpty ? null : visible.last;
      final speaker =
          (last != null && last.role == 'assistant') ? last.senderName : null;
      return PromptBuilder.buildGroup(
        members: _members,
        history: visible,
        worldBooks: worldBooks,
        userName: _macroUserName,
        speakerName: speaker,
        summaryText: summaryText,
        historyLimit: _historyLimit,
        personaText: PersonaStore.activeDescription,
        authorNote: _authorNote,
        stSystemPrefix: st.systemPrefix,
        stPreHistory: st.preHistory,
        stDepthInjections: st.depthInjections,
        hostNudge: _continuationNudge ? _kGroupContinueNudge : null,
      );
    }
    return PromptBuilder.build(
      card: _card!,
      history: visible,
      worldBooks: worldBooks,
      userName: _macroUserName,
      summaryText: summaryText,
      historyLimit: _historyLimit,
      personaText: PersonaStore.activeDescription,
      authorNote: _authorNote,
      stSystemPrefix: st.systemPrefix,
      stPreHistory: st.preHistory,
      stDepthInjections: st.depthInjections,
    );
  }

  /// ST 兼容模式的注入计划（v0.31.0）：按导入预设的 JSON 与开关缓存，
  /// 设置里改了内容/开关后自动失效重算。
  StInjectionPlan _stInjectionPlan() {
    final raw = AppSettings.stCompatEnabled ? AppSettings.stPresetJson : null;
    if (raw == null || raw.isEmpty) return StInjectionPlan.empty;
    if (_stPlanRaw == raw && _stPlan != null) return _stPlan!;
    final plan = StInjectionPlan.fromSnapshot(
      StPresetSnapshot.tryParseStored(raw),
    );
    _stPlanRaw = raw;
    _stPlan = plan;
    return plan;
  }

  /// 上下文占用明细：裸组装（仅系统+历史）→ 带世界书 → 完整，差值拆分；
  /// 三段之和恒等于完整组装的估算（展示与压缩阈值同口径）。
  ContextBreakdown? _contextBreakdown() {
    if (!_canBuildPrompt) return null;
    final bare = _buildWith(
      _messages,
      worldBooks: const [],
      summaryText: null,
    );
    final withWb = _buildWith(
      _messages,
      worldBooks: _worldBooks,
      summaryText: null,
    );
    final full = _buildPrompt();
    return ContextBreakdown.of(bare: bare, withWb: withWb, full: full);
  }

  /// 群聊：剥掉内容开头的「名字: 」头（只在首次生成后调用）。
  void _stripSpeakerPrefix() {
    if (_messages.isEmpty) return;
    final i = _messages.length - 1;
    final m = _messages[i];
    if (m.role != 'assistant') return;
    final name = m.senderName?.trim();
    if (name == null || name.isEmpty) return;
    final n = RegExp.escape(name);
    final re = RegExp(
      '^\\s*(?:\\*\\*)?(?:【$n】|\\[?$n\\]?)(?:\\*\\*)?\\s*[:：]\\s*',
    );
    final stripped = m.content.replaceFirst(re, '');
    if (stripped != m.content) {
      _messages[i] = m.copyWith(content: stripped);
    }
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
      // v0.21.0：记下这条回复用的模型名（气泡下方展示）
      model: AppSettings.model.trim().isEmpty
          ? null
          : AppSettings.model.trim(),
      // v0.35.0：按前缀估算这次有多少输入命中提示词缓存（统计页用）
      cachedPromptTokens: _lastCachedEstimate <= 0
          ? m.cachedPromptTokens
          : ((m.cachedPromptTokens ?? 0) + _lastCachedEstimate)
              .clamp(0, (m.promptTokens ?? 0) + p),
    );
  }

  void _stop() {
    _genToken++;
    // 建议回复（v0.12.1）：取消这一批的独立连接并作废结果
    _suggestSeq++;
    for (final c in List<ApiClient>.of(_suggestClients)) {
      c.cancel();
    }
    // 替我说一句（v0.16.0）：停止也把这条临时请求取消
    _impersonateClient?.cancel();
    // 页面内停止 = 管理器执行取消（与 dispose 只解绑相对）。随即显式
    // 释放同 key：取消收尾是异步的，别挡住紧接着的再次发送。
    final job = ActiveGenerations.instance.of(_convId);
    if (job != null) {
      job.cancel();
      ActiveGenerations.instance.remove(_convId);
    }
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
    if (_generating || _summarizing || !_canBuildPrompt) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    if (_messages.isEmpty || _messages.last.role != 'assistant') return;
    _statsPending = false; // 重新生成不算真实发送，不计命中率
    setState(() {
      _messages[_messages.length - 1] = _prepVariantSlot(_messages.last);
      _generating = true;
      _followScroll = true;
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
    });
    _save(force: true);
    _followBottom();
    await _generateSingle();
  }

  /// 失败气泡里的重试。
  Future<void> _retry(ChatMessage failed) async {
    if (_generating || _summarizing || !_canBuildPrompt) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    final idx = _messages.indexOf(failed);
    if (idx < 0) return;
    _statsPending = false; // 重试不算真实发送，不计命中率

    if (idx == _messages.length - 1) {
      // 末条失败：复用空变体槽或追加新变体，原地重试
      setState(() {
        _messages[idx] = _prepVariantSlot(_messages[idx]);
        _generating = true;
        _followScroll = true;
        _msgCache.clear();
        ChatIndexCache.instance.invalidate();
      });
      _save(force: true);
      _followBottom();
      await _generateSingle();
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
      ChatIndexCache.instance.invalidate();
      _save(force: true);
      return;
    }

    setState(() {
      _messages.removeAt(idx);
      _messages.add(ChatMessage(
        role: 'assistant',
        content: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        // 群聊：新占位沿用失败消息的发言者
        senderId: failed.senderId,
        senderName: failed.senderName,
      ));
      _generating = true;
      _followScroll = true;
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
    });
    _save(force: true);
    _followBottom();
    await _generateSingle();
  }

  /// 继续生成：在同一条 AI 消息末尾流式追加文本。
  Future<void> _continueGeneration() async {
    if (_generating || _summarizing || !_canBuildPrompt) return;
    if (_messages.isEmpty || _messages.last.role != 'assistant') return;
    final last = _messages.last;
    if (last.content.isEmpty || last.error != null) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    _statsPending = false; // 继续生成不算真实发送，不计命中率
    setState(() {
      _generating = true;
      _followScroll = true;
    });
    _save(force: true);
    _scrollToBottom();
    await _generateSingle(isContinue: true);
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

  /// 世界书绑定（v0.27.0）：默认定位到「这段聊天」，也可切到全局/人设/角色。
  Future<void> _openWorldBookBindings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorldBookBindingsScreen(
          initialScope: WorldBookScope.chat,
          initialOwnerId: _convId,
        ),
      ),
    );
    if (!mounted) return;
    // 绑定变了，重新算这对这条会话生效的世界书
    final card = _card;
    if (_isGroup) {
      final group = _group;
      if (group == null) return;
      final members = <CharacterCard>[];
      for (final id in group.memberIds) {
        final c = await Storage.loadCharacter(id);
        if (c != null) members.add(c);
      }
      final books = await _loadWorldBooksForGroup(members);
      if (!mounted) return;
      setState(() => _worldBooks = books);
    } else if (card != null) {
      final books = await _loadWorldBooksFor(card);
      if (!mounted) return;
      setState(() => _worldBooks = books);
    }
  }

  /// 变量与状态（v0.33.0）：只读展示卡内变量、对话里的状态更新与卡内脚本提示。
  Future<void> _openCardState() async {
    final cards = _isGroup
        ? _members
        : (_card == null ? <CharacterCard>[] : <CharacterCard>[_card!]);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CardStateScreen(cards: cards, messages: _messages),
      ),
    );
  }

  /// 每聊天的生成参数覆盖（v0.34.0）：留空 = 跟随全局预设。
  Future<void> _openChatPreset() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPresetScreen(
          convId: _convId,
          chatTitle: _chatTitle,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

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
    if (!_isGroup && _card == null) return;
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
    // 生成中清空（v0.10.0）：取消在途任务并立即释放同 key —— 目标占位
    // 已随清空消失，后台收尾不会把旧内容写回（_persist 找不到目标即跳过）；
    // 作废页内回调，杜绝流式文本追加进新开场白。
    final job = ActiveGenerations.instance.of(_convId);
    if (job != null) {
      job.cancel();
      ActiveGenerations.instance.remove(_convId);
    }
    _genToken++;
    _throttle.reset();
    final card = _card;
    setState(() {
      // 群聊没有开场白；单聊回到 first_mes
      if (_isGroup || card == null || card.firstMes.trim().isEmpty) {
        _messages = <ChatMessage>[];
      } else {
        _messages = [
          ChatMessage(
            role: 'assistant',
            content: _macro(card.firstMes),
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
      }
      _summary = null; // 清空即不再需要早期摘要
      _hitStats = null; // 清空对话同时清零本对话命中率
      _historyLimitOverride = null; // 历史已重置，满压缩覆盖一并复位
      _ctxHardTrim = false;
      _generating = false; // 生成已取消，立即恢复可发送
      _isContinueGen = false;
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
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
      ChatIndexCache.instance.invalidate();
    });
    _save(force: true);
    _scrollToBottom();
  }

  void _showMenu() {
    final card = _card;
    if (!_isGroup && card == null) return;
    final canRegen = !_generating &&
        _messages.isNotEmpty &&
        _messages.any((m) => m.role == 'user');
    final last = _messages.isEmpty ? null : _messages.last;
    final canContinue = !_generating &&
        last != null &&
        last.role == 'assistant' &&
        last.content.isNotEmpty &&
        last.error == null;
    // 存在可总结历史时才显示（超窗的早期消息非空）
    final canSummarize = !_generating &&
        !_summarizing &&
        hasSummarizableHistory(_messages, _historyLimit);
    final presetSummary = ChatPresetOverrideStore.load(_convId).summary;
    final hasAltGreetings =
        !_isGroup && card != null && card.alternateGreetings.isNotEmpty;

    // v0.40.0：二级菜单。一级只列几组（图标 + 一句概括 + 箭头），点开才看这一组的条目；
    // 不再显示「聊天菜单 / 当前：xxx」那块标题。
    showGroupedSheetMenu(
      context,
      groups: [
        SheetMenuGroup(
          label: '生成',
          icon: Icons.auto_awesome_outlined,
          description: hasAltGreetings
              ? '重新生成 / 继续生成 / 换开场白'
              : '重新生成 / 继续生成',
          children: [
            SheetMenuItem(
              icon: Icons.refresh_outlined,
              title: '重新生成',
              subtitle: '用同一条你的话再要一次回复',
              enabled: canRegen,
              onTap: () {
                Navigator.pop(context);
                _regenerate();
              },
            ),
            SheetMenuItem(
              icon: Icons.play_arrow_outlined,
              title: '继续生成',
              subtitle: '让角色顺着最后一句往下写',
              enabled: canContinue,
              onTap: () {
                Navigator.pop(context);
                _continueGeneration();
              },
            ),
            if (hasAltGreetings)
              SheetMenuItem(
                icon: Icons.style_outlined,
                title: '换开场白',
                subtitle: '换一张卡里自带的开场',
                onTap: () {
                  Navigator.pop(context);
                  _rotateGreeting();
                },
              ),
          ],
        ),
        SheetMenuGroup(
          label: '这段聊天',
          icon: Icons.forum_outlined,
          description: _isGroup
              ? '聊天列表 / 分支树 / 搜索 / 书签 / 作者注释 / 生成参数 / 世界书 / 变量 / 群聊主持'
              : '聊天列表 / 分支树 / 搜索 / 书签 / 作者注释 / 生成参数 / 世界书 / 变量',
          children: [
            SheetMenuItem(
              icon: Icons.forum_outlined,
              title: '聊天列表',
              subtitle: '同一角色可有多段聊天 · 当前「$_chatTitle」',
              onTap: () {
                Navigator.pop(context);
                _showChatList();
              },
            ),
            SheetMenuItem(
              icon: Icons.account_tree_outlined,
              title: '分支树',
              subtitle: '看看这段聊天分出了哪些岔路',
              onTap: () {
                Navigator.pop(context);
                _openChatTree();
              },
            ),
            SheetMenuItem(
              icon: Icons.search_outlined,
              title: '搜索对话',
              subtitle: '在这段聊天里找关键词，点结果跳过去',
              onTap: () {
                Navigator.pop(context);
                _showSearch();
              },
            ),
            SheetMenuItem(
              icon: Icons.bookmark_border_outlined,
              title: '书签',
              subtitle: '回看收藏的消息片段',
              onTap: () {
                Navigator.pop(context);
                _showBookmarks();
              },
            ),
            SheetMenuItem(
              icon: Icons.sticky_note_2_outlined,
              title: '作者注释',
              subtitle: _authorNote.isActive
                  ? (_authorNote.placement == AuthorNotePlacement.inChat
                      ? '已启用 · 聊天内 深度 ${_authorNote.depth}'
                      : '已启用 · 设定之后')
                  : '未启用 · 临时给模型的额外指令',
              onTap: () {
                Navigator.pop(context);
                _openAuthorNote();
              },
            ),
            SheetMenuItem(
              icon: Icons.tune_outlined,
              title: '这段聊天的生成参数',
              subtitle: presetSummary,
              onTap: () {
                Navigator.pop(context);
                _openChatPreset();
              },
            ),
            SheetMenuItem(
              icon: Icons.menu_book_outlined,
              title: '世界书绑定',
              subtitle: '全局 / 人设 / 角色 / 这段聊天，分别绑定',
              onTap: () {
                Navigator.pop(context);
                _openWorldBookBindings();
              },
            ),
            SheetMenuItem(
              icon: Icons.monitor_heart_outlined,
              title: '变量与状态',
              subtitle: '只读查看卡内变量、状态更新与卡内脚本提示',
              onTap: () {
                Navigator.pop(context);
                _openCardState();
              },
            ),
            if (_isGroup) ...[
              SheetMenuItem(
                icon: Icons.groups_outlined,
                title: '群聊主持',
                subtitle: '只让名单里的角色发言、按这个顺序轮转',
                onTap: () {
                  Navigator.pop(context);
                  _openGroupHost();
                },
              ),
              SheetMenuItem(
                icon: Icons.fast_forward_outlined,
                title: '让大家接着说',
                subtitle: '不用你发言，让角色们自己接着聊一轮',
                onTap: () {
                  Navigator.pop(context);
                  _continueGroupRound();
                },
              ),
            ],
          ],
        ),
        SheetMenuGroup(
          label: '提示词与统计',
          icon: Icons.analytics_outlined,
          description: '查看发送内容 / 提示词检视 / 上下文占用 / 聊天统计 / 总结早期对话',
          children: [
            SheetMenuItem(
              icon: Icons.receipt_long_outlined,
              title: '查看发送内容',
              subtitle: '这一轮实际发给模型的提示词',
              onTap: () {
                Navigator.pop(context);
                _showInjection();
              },
            ),
            SheetMenuItem(
              icon: Icons.manage_search_outlined,
              title: '提示词检视',
              subtitle: '逐段 token、缓存能复用到哪、哪里在浪费',
              onTap: () {
                Navigator.pop(context);
                _openPromptAudit();
              },
            ),
            SheetMenuItem(
              icon: Icons.data_usage_outlined,
              title: '上下文占用',
              subtitle: '这段对话用了多少窗口、还差多少要摘要',
              onTap: () {
                Navigator.pop(context);
                _showContextUsage();
              },
            ),
            SheetMenuItem(
              icon: Icons.bar_chart_outlined,
              title: '聊天统计',
              subtitle: '条数、token、缓存命中与预计花费',
              onTap: () {
                Navigator.pop(context);
                _showChatStats();
              },
            ),
            if (canSummarize)
              SheetMenuItem(
                icon: Icons.compress_outlined,
                title: '立即总结早期对话',
                subtitle: '把较早的内容压成摘要（会额外消耗 token）',
                onTap: () {
                  Navigator.pop(context);
                  _manualSummarize();
                },
              ),
          ],
        ),
        SheetMenuGroup(
          label: '导入与导出',
          icon: Icons.swap_vert,
          description: '复制对话 / 导出文件 / 导入聊天记录',
          children: [
            SheetMenuItem(
              icon: Icons.copy_all_outlined,
              title: '复制对话',
              subtitle: '纯文本复制到剪贴板',
              onTap: () {
                Navigator.pop(context);
                _exportConversation();
              },
            ),
            SheetMenuItem(
              icon: Icons.ios_share_outlined,
              title: '导出对话文件…',
              subtitle: '纯文本 / JSON / 长图 / EPUB',
              onTap: () {
                Navigator.pop(context);
                _exportChatFile();
              },
            ),
            SheetMenuItem(
              icon: Icons.file_download_outlined,
              title: '导入聊天记录',
              subtitle: '从 SillyTavern 的 .jsonl 接进来',
              onTap: () {
                Navigator.pop(context);
                _importChatFile();
              },
            ),
          ],
        ),
        if (card != null)
          SheetMenuGroup(
            label: '角色',
            icon: Icons.person_outline,
            description: '编辑角色设定、开场白、世界书挂载',
            children: [
              SheetMenuItem(
                icon: Icons.edit_outlined,
                title: '编辑角色',
                subtitle: '改设定、开场白、世界书挂载',
                onTap: () {
                  Navigator.pop(context);
                  _editCharacter();
                },
              ),
            ],
          ),
        SheetMenuGroup(
          label: '危险操作',
          icon: Icons.warning_amber_outlined,
          danger: true,
          description: '清空这段对话（不可恢复）',
          children: [
            SheetMenuItem(
              icon: Icons.delete_sweep_outlined,
              title: '清空对话',
              subtitle: '只清空这一段聊天的本地记录，不可恢复',
              danger: true,
              onTap: () {
                Navigator.pop(context);
                _clearConversation();
              },
            ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------- 导出对话 --

  /// 组装纯文本写入系统剪贴板（变体只导出当前显示的）。
  Future<void> _exportConversation() async {
    if (!_isGroup && _card == null) return;
    final title = _isGroup ? (_group?.name ?? '群聊') : _card!.name;
    final text = buildExportText(
      charName: title,
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

  /// v0.16.0：导出成文件（.txt / .json）并交给系统分享。
  Future<void> _exportChatFile() async {
    if (!_isGroup && _card == null) return;
    final format = await showModalBottomSheet<ChatExportFormat>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '导出对话',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            for (final f in ChatExportFormat.values)
              ListTile(
                leading: Icon(switch (f) {
                  ChatExportFormat.text => Icons.description_outlined,
                  ChatExportFormat.json => Icons.data_object,
                  ChatExportFormat.image => Icons.image_outlined,
                  ChatExportFormat.epub => Icons.menu_book_outlined,
                }),
                title: Text(f.label),
                subtitle: Text(f.hint),
                onTap: () => Navigator.pop(ctx, f),
              ),
          ],
        ),
      ),
    );
    if (format == null || !mounted) return;
    final title = _isGroup ? (_group?.name ?? '群聊') : _card!.name;
    // v0.42.0：长图/EPUB 这些耗时导出改成带进度条的对话框（长会话不再干等）。
    final busy = format.isBinary;
    final progress = ValueNotifier<double>(0);
    if (busy) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Text('正在生成${format.label}…'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: value <= 0 ? null : value),
                const SizedBox(height: 10),
                Text(
                  value <= 0
                      ? '准备中…'
                      : '已处理 ${(value * 100).clamp(0, 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }
    try {
      final ok = await ChatExportFiles.shareChat(
        charName: title,
        userName: _macroUserName,
        messages: _messages,
        format: format,
        onProgress: busy ? (v) => progress.value = v : null,
      );
      if (!mounted) return;
      if (busy) Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
      if (!ok) _toast('当前设备不支持分享文件');
    } catch (e) {
      if (mounted && busy) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      progress.dispose();
      if (!mounted) return;
      _toast('导出失败：$e');
    }
  }

  /// v0.32.0：从 SillyTavern 的 `.jsonl` 导入聊天记录，接在当前对话后面。
  Future<void> _importChatFile() async {
    try {
      final result = await pickFilesWithExtensions(['jsonl']);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        _toast('读取文件失败');
        return;
      }
      final charName = _isGroup ? (_group?.name ?? '群聊') : (_card?.name ?? '');
      final parsed = StChatImporter.parse(
        bytes,
        charName: charName,
        userName: _macroUserName,
      );
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入聊天记录'),
          content: Text(
            '要导入 ${parsed.messages.length} 条消息吗？\n会接在当前这段对话的后面。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      setState(() {
        _messages.addAll(parsed.messages);
        _msgCache.clear();
        ChatIndexCache.instance.invalidate();
      });
      _save(force: true);
      _followBottom();
      await showImportReportDialog(
        context,
        parsed.report,
        title: '导入体检 · 聊天记录',
        subtitle: '来自 ${file.name}',
      );
    } on StChatFormatException catch (e) {
      if (mounted) _toast(e.message);
    } on FormatException catch (e) {
      if (mounted) _toast(e.message);
    } catch (e) {
      if (mounted) _toast('导入失败：$e');
    }
  }

  /// v0.16.0：打开当前会话的作者注释编辑页。
  Future<void> _openAuthorNote() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AuthorNoteScreen(convId: _convId, title: '作者注释'),
      ),
    );
    if (!mounted) return;
    setState(() => _authorNote = AuthorNoteStore.load(_convId));
    if (changed == true) _toast('作者注释已保存，下一条回复开始生效');
  }

  // ------------------------------------------------- 替我说一句（v0.16.0）--

  bool _impersonating = false;
  ApiClient? _impersonateClient;

  /// 让模型以「我」的口吻写一句最可能发出去的话，填进输入框由用户决定是否发送。
  Future<void> _impersonate() async {
    if (_impersonating || _generating || _summarizing) return;
    if (!_canConfigure) {
      _toast('先在 设置 → 模型服务 里配置 API');
      return;
    }
    final built = _buildPrompt();
    final client = ApiClient();
    _impersonateClient = client;
    setState(() => _impersonating = true);
    final buf = StringBuffer();
    String? err;
    // v0.34.0：替我说一句同样用这一天聊天的覆盖参数
    final gen = ChatGenSettings.resolve(_convId);
    try {
      await client.streamChat(
        baseUrl: AppSettings.baseUrl,
        apiKey: AppSettings.apiKey,
        model: AppSettings.model,
        messages: withImpersonateInstruction(built.messages),
        temperature: gen.temperature,
        topP: gen.topP,
        maxTokens: gen.maxTokens,
        stream: false,
        sampling: gen.sampling,
        onDelta: buf.write,
        onError: (e) => err = e,
        onDone: () {},
      );
    } catch (e) {
      err ??= '$e';
    }
    _impersonateClient = null;
    client.dispose();
    if (!mounted) return;
    setState(() => _impersonating = false);
    final text = normalizeImpersonation(buf.toString());
    if (text.isEmpty) {
      _toast(err == null ? '模型没有返回内容，再试一次' : '生成失败：$err');
      return;
    }
    _inputCtrl.text = text;
    _inputCtrl.selection = TextSelection.collapsed(offset: text.length);
    _inputEmpty.value = false;
  }

  // ------------------------------------------------------- 统计与注入 --

  /// 聊天统计：消息条数、累计输入/输出 tokens、当前发送上下文估算。
  /// 累计值已含该消息所有变体的消耗（真实花销）。
  void _showChatStats() {
    // v0.42.0：统计走会话索引缓存，长会话重复打开不再每次全量扫描。
    final agg = ChatIndexCache.instance.aggregates(_messages);
    final total = agg.messageCount;
    final inSum = agg.promptTokens;
    final outSum = agg.completionTokens;
    final cachedSum = agg.cachedTokens;
    final hasUsage = agg.hasUsage;
    final approx = agg.approx;

    var contextTokens = 0;
    if (_canBuildPrompt) {
      final built = _buildPrompt();
      contextTokens =
          estimateTokens(built.messages.map((m) => m.content).join('\n'));
    }

    // v0.35.0：费用与缓存命中（价格取设置里的单价，没填就只显示 token）
    final price = TokenPrice(
      inputPerMillion: AppSettings.priceInputPerMillion,
      outputPerMillion: AppSettings.priceOutputPerMillion,
      cachedInputPerMillion: AppSettings.priceCachedPerMillion,
    );
    final usage = UsageCost(
      inputTokens: inSum,
      outputTokens: outSum,
      cachedInputTokens: cachedSum,
      price: price,
    );

    final mark = approx ? '（估算）' : '';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('聊天统计'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _statLine('消息条数', '$total'),
              _statLine(
                  '输入消耗', hasUsage ? '${formatTokenCount(inSum)}$mark' : '0'),
              _statLine(
                  '输出消耗', hasUsage ? '${formatTokenCount(outSum)}$mark' : '0'),
              _statLine(
                '缓存命中',
                hasUsage
                    ? '${formatTokenCount(cachedSum)}（${(usage.cacheHitRatio * 100).toStringAsFixed(0)}%）'
                    : '0',
              ),
              _statLine(
                  '发送前上下文', '${formatTokenCount(contextTokens)}（估算）'),
              if (price.configured && hasUsage) ...[
                const Divider(height: 18),
                _statLine('预计花费', '${formatMoney(usage.total)} 元'),
                if (usage.cacheSavings > 0)
                  _statLine('缓存省下', '${formatMoney(usage.cacheSavings)} 元'),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '按你填的单价估算：输入 ${price.inputPerMillion}/M、'
                    '输出 ${price.outputPerMillion}/M、'
                    '缓存命中 ${price.effectiveCachedPrice}/M。',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ),
              ] else if (hasUsage)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '想估算费用？去 设置 → 聊天与上下文 → 用量与费用 填单价。',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          ),
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

  /// 顶部占用条的合计 token（带缓存；口径与 [_showContextUsage] 一致）。
  int? _ctxBarTokens() {
    if (!_canBuildPrompt) return null;
    final lastLen = _messages.isEmpty ? 0 : _messages.last.content.length;
    if (_ctxBarTotal != null &&
        _ctxBarMsgLen == _messages.length &&
        _ctxBarLastLen == lastLen &&
        _ctxBarHistoryLimit == _historyLimit &&
        identical(_ctxBarSummary, _summary)) {
      return _ctxBarTotal;
    }
    final total = _contextBreakdown()?.total;
    _ctxBarMsgLen = _messages.length;
    _ctxBarLastLen = lastLen;
    _ctxBarHistoryLimit = _historyLimit;
    _ctxBarSummary = _summary;
    _ctxBarTotal = total;
    return total;
  }

  /// 输入框上方的上下文占用提示（v0.14.2）：细进度条 + 百分比。
  /// 刻意做得不显眼（2.5px、低透明度、9.5px 小字），点按打开明细。
  Widget _buildContextHint(ColorScheme scheme) {
    final window = AppSettings.contextWindow;
    if (window <= 0) return const SizedBox.shrink();
    final total = _ctxBarTokens();
    if (total == null || total <= 0) return const SizedBox.shrink();
    final ratio = (total / window).clamp(0.0, 1.0);
    final over = overContextBudget(total, window);
    final color = over ? scheme.error : scheme.primary;
    // 窗口很大（如 1M）时整数百分比会一直是 0%，这里低于 10% 保留一位小数
    final rawPercent = total / window * 100;
    final percentLabel = rawPercent < 10
        ? rawPercent.toStringAsFixed(1)
        : '${contextPercent(total, window)}';
    return InkWell(
      onTap: _showContextUsage,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 2.5,
                  color: color.withValues(alpha: over ? 0.9 : 0.5),
                  backgroundColor:
                      scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '上下文 $percentLabel%',
              style: TextStyle(
                fontSize: 9.5,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 上下文占用（v0.8.0）：明细拆分 + 占用条 + 合计/窗口百分比。
  /// 窗口为 0 时只显示明细（设置里的 0 = 关闭占用%与自动压缩）。
  /// 估算不持久化，每次打开现算；上次 API 返回的真实输入 token 单独展示。
  void _showContextUsage() {
    final window = AppSettings.contextWindow;
    final bd = _contextBreakdown();
    final exact = _lastExactPrompt;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        if (bd == null) {
          return AlertDialog(
            title: const Text('上下文占用'),
            content: const Text('对话还没准备好'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('好的'),
              ),
            ],
          );
        }
        final total = bd.total;
        final over = overContextBudget(total, window);
        final ratio = window > 0 ? (total / window).clamp(0.0, 1.0) : 0.0;
        return AlertDialog(
          title: const Text('上下文占用'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _statLine('系统提示（角色卡+规则）',
                  '≈${formatTokenCount(bd.systemTokens)}'),
              _statLine('世界书', '≈${formatTokenCount(bd.worldBookTokens)}'),
              _statLine('摘要', '≈${formatTokenCount(bd.summaryTokens)}'),
              _statLine('历史 ${bd.historyCount} 条',
                  '≈${formatTokenCount(bd.historyTokens)}'),
              const Divider(height: 18),
              _statLine('合计', '≈${formatTokenCount(total)} tokens'),
              if (window > 0) ...[
                const SizedBox(height: 10),
                // 占用条：主色填充，超 90% 预算转为错误色
                Container(
                  height: 8,
                  width: double.maxFinite,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: ratio,
                    child: Container(
                      decoration: BoxDecoration(
                        color: over ? scheme.error : scheme.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${formatTokenCount(total)} / ${formatTokenCount(window)}'
                  ' = ${contextPercent(total, window)}%',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  '已关闭占用百分比（模型上下文窗口为 0）',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (exact != null) ...[
                const SizedBox(height: 6),
                Text(
                  '上次实际：$exact',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
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

  /// 「本对话命中率」行：只列本对话激活过的条目（从未命中的不列）。
  /// key 与统计一致（entryKeyOf：有 id 用 id，否则 关键词|插入顺序），
  /// 去重防止同一条目在多本书/内嵌+挂载重复出现。
  List<String> _hitRateRows() {
    final stats = _hitStats;
    if (stats == null || stats.sends <= 0) return const [];
    final rows = <String>[];
    final seen = <String>{};
    for (final book in _worldBooks) {
      for (final e in book.entries) {
        final key = entryKeyOf(e);
        if (stats.hitsOf(key) <= 0 || !seen.add(key)) continue;
        rows.add('${entryLabelOf(e)} ${stats.rateLine(key)}');
      }
    }
    return rows;
  }

  /// 查看发送内容：最近一次实际发送的 system 全文 + 激活条目数/来源
  /// + 本对话命中率（仅列出激活过的条目）。
  void _showInjection() {
    final system = _lastSystemText;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        if (system == null) {
          return AlertDialog(
            title: const Text('查看发送内容'),
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
        final hitRows = _hitRateRows();
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('查看发送内容'),
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
              // 本对话命中率：命中过的条目各一行「名字 3/12 · 25%」
              if (hitRows.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  '本对话命中率',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final row in hitRows)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              row,
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: Container(
                  width: double.maxFinite,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).scaffoldBackgroundColor,
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

  /// 提示词检视（v0.28.0）：逐段 token / 缓存断点 / 省钱建议。
  Future<void> _openPromptAudit() async {
    final current = _lastPrompt;
    if (current == null || current.isEmpty) {
      _toast('还没有发送过消息，先聊一句再来看');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PromptAuditScreen(
          current: current,
          previous: _prevPrompt,
          contextWindow: AppSettings.contextWindow,
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 构建 --

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = _card;
    final ready = _isGroup ? _group != null : card != null;

    if (_loading || !ready) {
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
      ChatIndexCache.instance.invalidate();
      _cacheLen = -1;
    }
    // 消息集（长度）变化 → 缓存整体失效
    if (_messages.length != _cacheLen) {
      _cacheLen = _messages.length;
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
    }

    return Scaffold(
      appBar: AppBar(
        // surface 底、无阴影；返回描边箭头；标题 17sp w700（群聊/单聊通用）
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_outlined, size: 22),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Row(
          children: [
            if (_isGroup) ...[
              const Icon(Icons.groups_outlined, size: 26),
              const SizedBox(width: 10),
            ] else ...[
              CharacterAvatar(id: card!.id, name: card.name, size: 34),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _showChatList,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          _chatTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: AppType.chatTitle,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.expand_more_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert_outlined, size: 22),
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
                child: Builder(builder: (context) {
                  final start = _messages.length > _visibleCount
                      ? _messages.length - _visibleCount
                      : 0;
                  final headerCount = start > 0 ? 1 : 0;
                  return ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    itemCount: _messages.length - start + headerCount,
                    itemBuilder: (context, raw) {
                      if (headerCount == 1 && raw == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Center(
                            child: Text(
                              '上面还有 $start 条更早的消息 · 上滑加载',
                              style: TextStyle(
                                fontSize: AppType.caption,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        );
                      }
                      final i = start + raw - headerCount;
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
                  );
                }),
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

    // v0.37.0 对话排版：气泡 / 小说（只影响显示，不改记录与提示词）
    final layout = AppSettings.chatLayout;
    final style = MessageLayoutStyle.of(layout, isUser: isUser);
    final novel = layout == ChatLayout.novel;
    final senderLabel = isUser ? '' : _senderLabelOf(m);

    // 气泡令牌：用户 = accent 10% 淡底、右侧、圆角 16（右下 4）；
    // 角色 = surface 底 + hairline 描边、左侧、圆角 16（左下 4）；无阴影。
    Widget bubble = Container(
      margin: EdgeInsets.symmetric(vertical: style.verticalMargin),
      padding: EdgeInsets.symmetric(
        horizontal: style.horizontalPadding,
        vertical: style.verticalPadding,
      ),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * style.maxWidthFactor,
      ),
      decoration: style.bubble
          ? BoxDecoration(
              color: isUser
                  ? scheme.primary.withValues(alpha: 0.10)
                  : scheme.surface,
              border: isUser ? null : Border.all(color: scheme.outline),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isUser ? 16 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 16),
              ),
            )
          : (style.userAccentBar
              ? BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: scheme.primary.withValues(alpha: 0.35),
                      width: 3,
                    ),
                  ),
                )
              : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 气泡模式：群聊角色气泡显示发言者名字；小说模式每段都标（你 / 角色名）
          if (!novel && _isGroup && senderLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                senderLabel,
                style: TextStyle(
                  fontSize: AppType.section,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          if (novel && senderLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                senderLabel,
                style: TextStyle(
                  fontSize: AppType.section,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          if (novel && isUser)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '你',
                style: TextStyle(
                  fontSize: AppType.section,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary.withValues(alpha: 0.75),
                ),
              ),
            ),
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
              // v0.29.0：显示正则只改看到的内容，本地原文不变
              data: DisplayRegexLibrary.apply(m.content, isUser: isUser),
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                p: TextStyle(
                  fontSize: fontSize,
                  height: 1.5,
                  color: scheme.onSurface,
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
            // v0.9.0：本次带了非默认高级采样参数时的失败提示
            //（只追加提示，不改设置、不吞原始错误）
            if (isLast && _lastErrorAdvanced)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '本次带了高级采样参数，当前后端可能不支持，可到高级设置改回默认',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.caption,
                    height: 1.4,
                  ),
                ),
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
    // v0.24.0：对模型隐藏的消息视觉上淡化，避免误以为还在发给模型。
    if (m.hidden) {
      bubble = Opacity(opacity: 0.45, child: bubble);
    }
    if (!isUser && isLast) {
      bubble = _SwipeVariantWrap(
        enabled: !_generating && m.variants.length > 1,
        onSwipe: (dir) => _switchVariant(m, m.variantIndex + dir),
        child: bubble,
      );
    }

    // 群聊：角色气泡左侧置 36dp 头像首字圆标（横滑只滑气泡，头像作锚点）
    if (!isUser && _isGroup) {
      bubble = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CharacterAvatar(
            id: m.senderId ?? '',
            name: (m.senderName ?? '').trim(),
            size: 36,
          ),
          const SizedBox(width: 8),
          Flexible(child: bubble),
        ],
      );
    }

    // AI：模型名 + token/时间小字行；用户：时间戳开关下的时间行
    String? infoLine;
    if (!isUser) {
      final usage = m.currentVariantUsage;
      String? tokens;
      if (usage != null) {
        final a = usage.estimated ? '约' : '';
        final pin = formatTokenCount(usage.prompt!);
        final cout = formatTokenCount(usage.completion!);
        tokens = showTs
            ? '$a输入 $pin · $a输出 $cout'
            : '$a输入 $pin · $a输出 $cout tokens';
      }
      final modelName = (m.model ?? '').trim();
      final parts = <String>[
        // v0.21.1：顺序为「输入/输出 → 模型名 → 时间」
        ?tokens,
        if (modelName.isNotEmpty) modelName,
        if (showTs) _formatTime(m.timestamp),
      ];
      infoLine = parts.isEmpty ? null : parts.join(' · ');
    }

    return Align(
      alignment: style.alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: style.alignRight
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          bubble,
          if (m.hidden)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.visibility_off_outlined,
                    size: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '对模型隐藏',
                    style: TextStyle(
                      fontSize: AppType.meta,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (infoLine != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
              child: Text(
                infoLine,
                style: TextStyle(
                    fontSize: AppType.meta, color: scheme.onSurfaceVariant),
              ),
            ),
          if (isUser && showTs)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Text(
                _formatTime(m.timestamp),
                style: TextStyle(
                  fontSize: AppType.meta,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 群里取发言者名字，单聊取角色名（小说模式的段落标签用）。
  String _senderLabelOf(ChatMessage m) =>
      (_isGroup ? (m.senderName ?? '') : (_card?.name ?? '')).trim();

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
                        : scheme.onSurfaceVariant.withValues(alpha: 0.4),
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
    final isUser = m.role == 'user';
    final hiddenHint = m.hidden ? '恢复后这条会重新发给模型' : '本地仍然保留并显示，只是不再发给模型';

    // v0.39.0：按「查看与修改 / 剧情 / 给模型 / 危险操作」分组，
    // 删除类统一放最后并标红。
    showSheetMenu<void>(
      context: context,
      children: [
        SheetMenuTitle(
          title: '这条消息',
          subtitle: '${isUser ? '你的话' : '角色回复'} · ${_formatTime(m.timestamp)}',
        ),
        const SheetMenuSection('查看与修改'),
        SheetMenuItem(
          icon: Icons.copy_all_outlined,
          title: '复制',
          subtitle: '把这条内容复制到剪贴板',
          onTap: () async {
            Navigator.pop(context);
            await Clipboard.setData(ClipboardData(text: m.content));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已复制')),
            );
          },
        ),
        SheetMenuItem(
          icon: Icons.edit_outlined,
          title: '编辑',
          subtitle: '只改这一段聊天的本地内容',
          onTap: () {
            Navigator.pop(context);
            _editMessage(m);
          },
        ),
        const SheetMenuSection('剧情'),
        if (canRegen)
          SheetMenuItem(
            icon: Icons.refresh_outlined,
            title: '重新生成',
            subtitle: '用前面的对话再写一版',
            onTap: () {
              Navigator.pop(context);
              _regenerate();
            },
          ),
        if (!_busy)
          SheetMenuItem(
            icon: Icons.call_split_outlined,
            title: '从这里创建分支',
            subtitle: '把这条及之前的对话复制成一段新聊天',
            onTap: () {
              Navigator.pop(context);
              _branchFrom(index);
            },
          ),
        SheetMenuItem(
          icon: Icons.bookmark_border_outlined,
          title: '书签',
          subtitle: '加入或取消这条消息的书签',
          onTap: () {
            Navigator.pop(context);
            _toggleBookmark(m);
          },
        ),
        const SheetMenuSection('给模型'),
        SheetMenuItem(
          icon: m.hidden
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          title: m.hidden ? '取消隐藏' : '对模型隐藏',
          subtitle: hiddenHint,
          onTap: () {
            Navigator.pop(context);
            _toggleHidden(index);
          },
        ),
        const SheetMenuSection('危险操作'),
        SheetMenuItem(
          icon: Icons.delete_outline,
          title: '删除这一条',
          subtitle: '只删这一条，前后对话保持连续',
          danger: true,
          enabled: !_busy,
          onTap: () {
            Navigator.pop(context);
            _deleteMessage(index);
          },
        ),
        SheetMenuItem(
          icon: Icons.delete_sweep_outlined,
          title: '删除这条及以后',
          subtitle: '会一起删掉后面 ${_messages.length - index - 1} 条，不可撤销',
          danger: true,
          enabled: !_busy,
          onTap: () {
            Navigator.pop(context);
            _deleteMessagesFrom(index);
          },
        ),
      ],
    );
  }

  /// 切换「对模型隐藏」（v0.24.0）：只改这一条的标记，不动其它消息。
  void _toggleHidden(int index) {
    if (index < 0 || index >= _messages.length) return;
    final before = _messages[index].hidden;
    setState(() {
      _messages[index] = _messages[index].copyWith(hidden: !before);
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
    });
    _save(force: true);
    _toast(before ? '已取消隐藏，下一条回复会带上这条' : '已对模型隐藏，本地记录仍在');
  }

  /// 删除单条消息（v0.24.0）。
  Future<void> _deleteMessage(int index) async {
    if (index < 0 || index >= _messages.length) return;
    final ok = await _confirmDelete(
      title: '删除这一条消息？',
      body: '只影响这一段聊天的本地记录，删掉后不可恢复。',
      confirmText: '删除',
    );
    if (ok != true || !mounted) return;
    setState(() {
      _messages.removeAt(index);
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
    });
    _save(force: true);
    _toast('已删除 1 条消息');
  }

  /// 删除这条及以后的消息（v0.24.0）。
  Future<void> _deleteMessagesFrom(int index) async {
    if (index < 0 || index >= _messages.length) return;
    final count = _messages.length - index;
    final ok = await _confirmDelete(
      title: '删除这条及以后？',
      body: '会删除 $count 条消息（含这一条），不可恢复。'
          '想保留前面的分支，可以用「从这里创建分支」。',
      confirmText: '删除 $count 条',
    );
    if (ok != true || !mounted) return;
    setState(() {
      _messages.removeRange(index, _messages.length);
      _msgCache.clear();
      ChatIndexCache.instance.invalidate();
    });
    _save(force: true);
    _followBottom();
    _toast('已删除 $count 条消息');
  }

  Future<bool?> _confirmDelete({
    required String title,
    required String body,
    required String confirmText,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  /// 打开对话内搜索（v0.24.0），选中结果后跳到那条消息。
  Future<void> _showSearch() async {
    final name = _isGroup
        ? (_group?.name ?? '群聊')
        : (_card?.name ?? '角色');
    final picked = await showChatSearchSheet(
      context,
      messages: _messages,
      assistantName: name,
    );
    if (picked == null || !mounted) return;
    if (picked < 0 || picked >= _messages.length) return;
    _jumpToMessage(_messages[picked].timestamp);
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

  // ------------------------------------------------ 多聊天 / 分支 / 书签 --
  // v0.17.0：同一角色（或群聊）可以有多段聊天，各自一个会话文件；
  // 标题点一下就能切换/新建/重命名，长按消息可以「从这里创建分支」。

  bool get _busy => _generating || _summarizing;

  /// 聊天文件列表（点标题弹出）
  void _showChatList() {
    if (_busy) {
      _toast('正在生成，先等这次回复结束再切换聊天');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => _ChatListSheet(
        ownerId: _ownerId,
        currentConvId: _convId,
        onOpen: (info) {
          Navigator.pop(ctx);
          _openChat(info);
        },
        onCreate: () async {
          Navigator.pop(ctx);
          await _createChat();
        },
      ),
    );
  }

  /// 分支树（v0.25.0）：按层级列出这段聊天的所有岔路，点一段直接切过去。
  Future<void> _openChatTree() async {
    if (_busy) {
      _toast('正在生成，先等这次回复结束再切换聊天');
      return;
    }
    final picked = await Navigator.of(context).push<ChatInfo>(
      MaterialPageRoute<ChatInfo>(
        builder: (_) => ChatTreeScreen(
          ownerId: _ownerId,
          currentConvId: _convId,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _openChat(picked);
  }

  /// 切换到另一段聊天（替换当前路由，返回键不会回到旧聊天）
  void _openChat(ChatInfo info) {
    if (info.id == _convId) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => _isGroup
          ? ChatScreen.group(
              groupId: widget.groupId!,
              convId: info.id,
              chatName: info.name,
            )
          : ChatScreen(
              charId: widget.charId,
              convId: info.id,
              chatName: info.name,
            ),
    );
    Navigator.of(context).pushReplacement(route);
  }

  /// 新建一段聊天：空会话 + 索引记录，然后直接打开（单聊会写入开场白）
  Future<void> _createChat() async {
    final name = await ChatIndex.nextName(_ownerId);
    final id = ChatIndex.newId(_ownerId);
    await Storage.saveConversation(id, <ChatMessage>[]);
    await ChatIndex.touch(_ownerId, convId: id, messageCount: 0, name: name);
    if (!mounted) return;
    _toast('已新建聊天「$name」');
    _openChat(ChatInfo(id: id, name: name));
  }

  /// 从第 [index] 条消息处分叉：把这之前的对话复制成一段新聊天。
  Future<void> _branchFrom(int index) async {
    if (index < 0 || index >= _messages.length) return;
    if (_busy) {
      _toast('正在生成，先等这次回复结束再创建分支');
      return;
    }
    final source = _messages.take(index + 1);
    final copied = <ChatMessage>[];
    for (final m in source) {
      copied.add(ChatMessage.fromJson(m.toJson()));
    }
    final name = await ChatIndex.nextName(_ownerId, base: '分支');
    final id = ChatIndex.newId(_ownerId);
    await Storage.saveConversation(id, copied);
    await ChatIndex.touch(
      _ownerId,
      convId: id,
      messageCount: copied.length,
      name: name,
      parentId: _convId,
      forkIndex: index,
    );
    if (!mounted) return;
    _toast('已创建分支「$name」（共 ${copied.length} 条）');
    _openChat(ChatInfo(
      id: id,
      name: name,
      messageCount: copied.length,
      parentId: _convId,
      forkIndex: index,
    ));
  }

  /// 加入 / 取消书签
  Future<void> _toggleBookmark(ChatMessage m) async {
    final added = await BookmarkStore.toggle(
      _convId,
      ChatBookmark(
        timestamp: m.timestamp,
        role: m.role,
        preview: ChatBookmark.previewOf(m.content),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _toast(added ? '已加入书签' : '已取消书签');
  }

  /// 书签列表：点一条跳到对应位置，右侧可删除
  Future<void> _showBookmarks() async {
    var list = await BookmarkStore.load(_convId);
    if (!mounted) return;
    if (list.isEmpty) {
      _toast('还没有书签：长按一条消息就能加入');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '书签（${list.length}）',
                    style: const TextStyle(
                      fontSize: AppType.section,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final b = list[i];
                      return ListTile(
                        leading: Icon(
                          b.isUser
                              ? Icons.person_outline
                              : Icons.auto_awesome_outlined,
                          size: 20,
                        ),
                        title: Text(
                          b.preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: AppType.body),
                        ),
                        subtitle: Text(
                          '${b.isUser ? '你' : '角色'} · ${_formatBookmarkTime(b.createdAt)}',
                          style: const TextStyle(fontSize: AppType.caption),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: '删除书签',
                          onPressed: () async {
                            await BookmarkStore.remove(_convId, b.timestamp);
                            if (!ctx.mounted) return;
                            setSheetState(() {
                              list = list
                                  .where((x) => x.timestamp != b.timestamp)
                                  .toList();
                            });
                            if (list.isEmpty && ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _jumpToMessage(b.timestamp);
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 跳到某条消息附近（列表高度不定，按比例定位后提示）
  void _jumpToMessage(int timestamp) {
    final idx = _messages.indexWhere((m) => m.timestamp == timestamp);
    if (idx < 0) {
      _toast('这条消息已经不在当前聊天里了');
      return;
    }
    if (!_scrollCtrl.hasClients) return;
    final max = _scrollCtrl.position.maxScrollExtent;
    final ratio = _messages.length <= 1 ? 1.0 : idx / (_messages.length - 1);
    _followScroll = false;
    _scrollCtrl.animateTo(
      (max * ratio).clamp(0.0, max),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    _onScroll();
  }

  static String _formatBookmarkTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '今天 $hm';
    }
    return '${two(t.month)}-${two(t.day)} $hm';
  }

  Widget _buildInputBar(ColorScheme scheme) {
    final replies = AppSettings.quickReplies;
    // 显示快捷回复开关默认关；关闭时整排完全不渲染（不占位）
    final showQuick = AppSettings.showQuickReplies && replies.isNotEmpty;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outline)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 自动摘要改为后台静默执行（v0.18.0）：不再显示任何进度提示，
            // 触发原因与 token 消耗在 设置 → 聊天 → 自动摘要说明 里解释。
            // 建议回复（v0.12.1）：AI 回复后自动生成 / ✨ 手动生成，
            // 点一条即作为自己的消息发出；生成中显示行内 loading。
            // 只有「建议回复」模式才显示（v0.18.0）。
            if (AppSettings.assistMode == AssistMode.suggestions &&
                (_suggestions.isNotEmpty || _suggesting) &&
                !_generating) ...[
              ReplySuggestionsBar(
                suggestions: _suggestions,
                loading: _suggesting,
                onSend: _sendSuggestion,
                onRefresh: _suggestReplies,
              ),
              const SizedBox(height: 8),
            ],
            // 快捷回复：输入框上方一排横滑 chips，点按立即发送；
            // 管理页删到空则整排隐藏，生成中置灰禁用
            if (showQuick) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < replies.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      ActionChip(
                        label: Text(
                          replies[i],
                          style:
                              const TextStyle(fontSize: AppType.caption),
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
            // 上下文占用提示（v0.14.2）：紧贴输入框上方，低调不抢注意力
            _buildContextHint(scheme),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 「替我说一句」/「生成建议回复」二选一（v0.18.0）：
                // 只渲染当前模式对应的按钮；都关闭时左侧完全不占位
                if (AppSettings.assistMode == AssistMode.impersonate) ...[
                  SizedBox(
                    width: 34,
                    height: 40,
                    child: IconButton(
                      onPressed: (_impersonating || _generating || _summarizing)
                          ? null
                          : _impersonate,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 40),
                      tooltip: '替我说一句',
                      icon: _impersonating
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: scheme.onSurfaceVariant,
                              ),
                            )
                          : Icon(
                              Icons.record_voice_over_outlined,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
                // 手动生成建议：AI 回复后忘了自动生成、或想换一批时点这里
                if (AppSettings.assistMode == AssistMode.suggestions) ...[
                  SizedBox(
                    width: 34,
                    height: 40,
                    child: IconButton(
                      onPressed: (_suggesting || _generating || _summarizing)
                          ? null
                          : _suggestReplies,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 34, minHeight: 40),
                      tooltip: '生成建议回复',
                      icon: Icon(
                        Icons.auto_awesome,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
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
                // 发送钮：40dp 圆形 accent 实心；停止态红色；空输入弱化
                //（摘要进行中也显示停止钮，按下 = 取消摘要）
                ValueListenableBuilder<bool>(
                  valueListenable: _inputEmpty,
                  builder: (context, empty, _) => SizedBox(
                    width: 40,
                    height: 40,
                    child: (_generating || _summarizing)
                        ? IconButton(
                            onPressed:
                                _generating ? _stop : _cancelSummarize,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 40),
                            style: IconButton.styleFrom(
                              backgroundColor: scheme.error,
                              foregroundColor: scheme.onError,
                              shape: const CircleBorder(),
                            ),
                            icon: const Icon(Icons.stop_outlined, size: 20),
                            tooltip: '停止',
                          )
                        : IconButton(
                            onPressed: _send,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 40),
                            style: IconButton.styleFrom(
                              backgroundColor: empty
                                  ? scheme.onSurface.withValues(alpha: 0.06)
                                  : scheme.primary,
                              foregroundColor: empty
                                  ? scheme.onSurfaceVariant
                                  : scheme.onPrimary,
                              shape: const CircleBorder(),
                            ),
                            icon: const Icon(Icons.send_outlined, size: 20),
                            tooltip: '发送',
                          ),
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


/// 聊天文件列表（v0.17.0）：切换 / 新建 / 重命名 / 删除同角色下的多段聊天。
class _ChatListSheet extends StatefulWidget {
  const _ChatListSheet({
    required this.ownerId,
    required this.currentConvId,
    required this.onOpen,
    required this.onCreate,
  });

  final String ownerId;
  final String currentConvId;
  final void Function(ChatInfo info) onOpen;
  final Future<void> Function() onCreate;

  @override
  State<_ChatListSheet> createState() => _ChatListSheetState();
}

class _ChatListSheetState extends State<_ChatListSheet> {
  List<ChatInfo>? _chats;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final chats = await ChatIndex.load(widget.ownerId);
    if (!mounted) return;
    setState(() => _chats = chats);
  }

  Future<void> _rename(ChatInfo info) async {
    final ctrl = TextEditingController(text: info.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名聊天'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '聊天名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (name == null || !mounted) return;
    await ChatIndex.rename(widget.ownerId, info.id, text);
    await _load();
  }

  Future<void> _delete(ChatInfo info) async {
    if (info.id == widget.currentConvId) return;
    final chats = _chats ?? const <ChatInfo>[];
    if (chats.length <= 1) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除聊天「${info.name}」？'),
        content: const Text('这段聊天的消息会被删除，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Storage.deleteConversation(info.id);
    await BookmarkStore.clear(info.id);
    await ChatIndex.remove(widget.ownerId, info.id);
    await _load();
  }

  static String _timeLabel(int ms) {
    if (ms <= 0) return '更早';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '今天 $hm';
    }
    return '${two(t.month)}-${two(t.day)} $hm';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chats = _chats;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    chats == null ? '聊天' : '聊天（${chats.length}）',
                    style: const TextStyle(
                      fontSize: AppType.section,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: widget.onCreate,
                  icon: const Icon(Icons.add_comment_outlined, size: 18),
                  label: const Text('新建聊天'),
                ),
              ],
            ),
          ),
          if (chats == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: chats.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = chats[i];
                  final current = c.id == widget.currentConvId;
                  return ListTile(
                    selected: current,
                    leading: Icon(
                      current
                          ? Icons.chat_bubble_outline
                          : Icons.chat_bubble_outline,
                      size: 20,
                      color: current ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    title: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.body,
                        fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    subtitle: Text(
                      '${c.messageCount} 条消息 · ${_timeLabel(c.updatedAt)}'
                      '${current ? ' · 当前' : ''}',
                      style: const TextStyle(fontSize: AppType.caption),
                    ),
                    trailing: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz, size: 20),
                      onSelected: (v) {
                        if (v == 'rename') _rename(c);
                        if (v == 'delete') {
                          if (c.id == widget.currentConvId) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('先切换到别的聊天，再删除这一段'),
                              ),
                            );
                            return;
                          }
                          if ((chats.length) <= 1) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('至少保留一段聊天；想重来可以用「清空对话」'),
                              ),
                            );
                            return;
                          }
                          _delete(c);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                    onTap: () => widget.onOpen(c),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '每段聊天相互独立：清空、摘要、作者注释都只影响当前这段。',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
