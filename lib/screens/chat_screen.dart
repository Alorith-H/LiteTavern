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
import '../services/chat_export.dart';
import '../services/context_usage.dart';
import '../services/hit_stats.dart';
import '../services/macros.dart';
import '../services/prompt_builder.dart';
import '../services/storage.dart';
import '../services/stream_throttle.dart';
import '../services/summarize.dart';
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

/// 聊天页（核心页面）。单聊与群聊共用一套气泡/流式/变体/菜单机器，
/// 仅 prompt 组装、轮转与标题不同（v0.6.0 群聊）。
class ChatScreen extends StatefulWidget {
  /// 单聊角色 id（群聊模式为空串）
  final String charId;

  /// 群聊群 id（单聊模式为 null）
  final String? groupId;

  const ChatScreen({super.key, required this.charId}) : groupId = null;

  const ChatScreen.group({super.key, required this.groupId}) : charId = '';

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

  /// 发送准备管线进行中（挡住两次快速连点在微任务间隙重复发送）
  bool _preparing = false;

  /// 正在生成摘要（输入栏上方进度态）
  bool _summarizing = false;

  bool get _isGroup => widget.isGroup;

  /// 会话存储 key：单聊 = 角色 id；群聊 = `group_<群id>`
  String get _convId =>
      _isGroup ? Storage.groupConvId(widget.groupId!) : widget.charId;

  /// 能否组装 prompt（统计/生成的前置条件）
  bool get _canBuildPrompt =>
      _isGroup ? _members.isNotEmpty : _card != null;

  List<ChatMessage> _messages = [];
  List<WorldInfo> _worldBooks = [];
  bool _loading = true;

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _api = ApiClient();

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
    // v0.10.0：只解绑后台生成的 UI 监听，不取消请求 —— 生成在后台跑完，
    // 完成由管理器落库；重进本页时 _load 里的接管逻辑恢复显示。
    ActiveGenerations.instance.of(_convId)?.detach();
    // 已排队的节流快照不再落盘：避免它晚于管理器后台落库执行，
    // 把权威全文回写成部分文本（见 _save）
    _saveAborted = true;
    _throttle.dispose();
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
    final data = await Storage.loadConversationData(widget.charId);
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
      Storage.saveConversation(card.id, msgs, summary: data.summary);
    }

    // 世界书：卡内嵌 + 该角色挂载且启用的合并
    final books = await _loadWorldBooksFor(card);

    if (!mounted) return;
    final job = ActiveGenerations.instance.of(_convId);
    if (job != null) {
      // 生成中重进（v0.10.0）：内容以任务缓冲为准 + 接管显示
      msgs = _adoptJob(msgs, job);
    } else if (jobBefore != null) {
      // 任务恰好在读取期间完成并落库 → 重读一次拿最终内容
      final fresh = await Storage.loadConversationData(widget.charId);
      if (!mounted) return;
      msgs = fresh.messages;
    }
    setState(() {
      _card = card;
      // 防御：无论来源如何都复制成可增长列表（_doSend 会 add）
      _messages = List.of(msgs);
      _summary = data.summary;
      _hitStats = data.hitStats; // 旧会话无记录 = null（不显示命中率）
      _worldBooks = books;
      _loading = false;
      _msgCache.clear();
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
    final data =
        await Storage.loadConversationData(Storage.groupConvId(group.id));
    final books = await _loadWorldBooksForGroup(members);

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
      _summary = data.summary;
      _hitStats = data.hitStats; // 旧会话无记录 = null（不显示命中率）
      _worldBooks = books;
      _loading = false;
      _msgCache.clear();
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
  Future<List<WorldInfo>> _loadWorldBooksForGroup(
      List<CharacterCard> members) async {
    final books = <WorldInfo>[];
    final enabledIds = <String>{};
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
      final explicit = await Storage.worldBookMountsFor(card.id);
      final mounts = explicit ??
          [
            for (final id in AppSettings.mountedWorldBookIds)
              (id: id, enabled: true),
          ];
      for (final m in mounts) {
        if (m.enabled) enabledIds.add(m.id);
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
      );
    });
  }

  // ----------------------------------------------------------- 滚动 --

  void _onScroll() {
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

  String get _macroUserName => AppSettings.userName;

  String _macro(String s) => applyMacros(
        s,
        charName: _card?.name ?? '',
        userName: _macroUserName,
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

    // 第 2 步：现有摘要管线（_summarizing 进度态可取消）
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
    });
    _inputCtrl.clear();
    _inputEmpty.value = true;
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
        });
        _save(force: true);
        _followBottom();
      }
      final g = _group;
      if (g != null) {
        final next = advanceTurn(_members.length, targets[k]);
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
            temperature: 0.4,
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
    _lastPrompt = toSend;

    // v0.9.0：统一走激活预设的完整参数集（高级字段默认不进 body）
    final sampling = AppSettings.activePreset.sampling;
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
        temperature: AppSettings.temperature,
        topP: AppSettings.topP,
        maxTokens: AppSettings.maxTokens,
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
    if (_isGroup) {
      final last = history.isEmpty ? null : history.last;
      final speaker =
          (last != null && last.role == 'assistant') ? last.senderName : null;
      return PromptBuilder.buildGroup(
        members: _members,
        history: history,
        worldBooks: worldBooks,
        userName: _macroUserName,
        speakerName: speaker,
        summaryText: summaryText,
        historyLimit: _historyLimit,
      );
    }
    return PromptBuilder.build(
      card: _card!,
      history: history,
      worldBooks: worldBooks,
      userName: _macroUserName,
      summaryText: summaryText,
      historyLimit: _historyLimit,
    );
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
    );
  }

  void _stop() {
    _genToken++;
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
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('清空对话'),
              onTap: () {
                Navigator.pop(ctx);
                _clearConversation();
              },
            ),
            if (card != null)
              ListTile(
                title: const Text('编辑角色'),
                onTap: () {
                  Navigator.pop(ctx);
                  _editCharacter();
                },
              ),
            ListTile(
              title: const Text('聊天统计'),
              onTap: () {
                Navigator.pop(ctx);
                _showChatStats();
              },
            ),
            ListTile(
              title: const Text('查看发送内容'),
              onTap: () {
                Navigator.pop(ctx);
                _showInjection();
              },
            ),
            ListTile(
              title: const Text('上下文占用'),
              onTap: () {
                Navigator.pop(ctx);
                _showContextUsage();
              },
            ),
            ListTile(
              title: const Text('复制对话'),
              onTap: () {
                Navigator.pop(ctx);
                _exportConversation();
              },
            ),
            ListTile(
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
              title: const Text('重新生成'),
              enabled: canRegen,
              onTap: canRegen
                  ? () {
                      Navigator.pop(ctx);
                      _regenerate();
                    }
                  : null,
            ),
            if (canSummarize)
              ListTile(
                title: const Text('立即总结早期对话'),
                onTap: () {
                  Navigator.pop(ctx);
                  _manualSummarize();
                },
              ),
            if (card != null && card.alternateGreetings.isNotEmpty)
              ListTile(
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
    if (_canBuildPrompt) {
      final built = _buildPrompt();
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
            _statLine(
                '输入消耗', hasUsage ? '${formatTokenCount(inSum)}$mark' : '0'),
            _statLine(
                '输出消耗', hasUsage ? '${formatTokenCount(outSum)}$mark' : '0'),
            _statLine('发送前上下文', '${formatTokenCount(contextTokens)}（估算）'),
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
      _cacheLen = -1;
    }
    // 消息集（长度）变化 → 缓存整体失效
    if (_messages.length != _cacheLen) {
      _cacheLen = _messages.length;
      _msgCache.clear();
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
              child: Text(
                _isGroup ? _group!.name : card!.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppType.chatTitle,
                  fontWeight: FontWeight.w700,
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

    // 气泡令牌：用户 = accent 10% 淡底、右侧、圆角 16（右下 4）；
    // 角色 = surface 底 + hairline 描边、左侧、圆角 16（左下 4）；无阴影。
    Widget bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      decoration: BoxDecoration(
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
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 群聊：角色气泡左上角显示发言者名字（12sp w600 次要色）
          if (_isGroup &&
              !isUser &&
              (m.senderName ?? '').trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                m.senderName!.trim(),
                style: TextStyle(
                  fontSize: AppType.section,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
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
              data: m.content,
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

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListBody(
          children: [
            ListTile(
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
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(ctx);
                _editMessage(m);
              },
            ),
            if (canRegen)
              ListTile(
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
            // 摘要进度态：输入栏上方细进度 + 文案 + 取消（取消 = 本次跳过直接发）
            if (_summarizing) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
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
                    Expanded(
                      child: Text(
                        '正在总结早期对话…',
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _cancelSummarize,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        '取消',
                        style: TextStyle(fontSize: AppType.caption),
                      ),
                    ),
                  ],
                ),
              ),
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
