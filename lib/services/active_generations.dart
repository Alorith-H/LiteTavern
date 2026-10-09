import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'prompt_builder.dart';
import 'sampling_params.dart';
import 'storage.dart';

/// 会话场景（v0.10.0）：单聊/群聊以会话 key 落库，创建器走内存会话。
enum GenKind { chat, creator }

/// 请求执行器：默认走 [ApiClient]；测试可注入假流 —— 返回的 future
/// 完成即视为本次请求结束（成功 / 出错 / 取消都以 future 完成为准），
/// 过程中按需调用 [GenerationJob.emitDelta] / [emitError] / [emitUsage]。
typedef GenerationRunner = Future<void> Function(GenerationJob job);

/// 生成请求快照：发起时从设置读取（与现状"每次请求读取设置"语义一致）。
class GenRequest {
  final String baseUrl;
  final String apiKey;
  final String model;
  final List<PromptMessage> messages;
  final double temperature;
  final double topP;
  final int maxTokens;
  final bool stream;
  final SamplingParams sampling;

  const GenRequest({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.messages,
    required this.temperature,
    required this.topP,
    required this.maxTokens,
    required this.stream,
    required this.sampling,
  });
}

/// 创建器里的一条消息（内存态，不落库；文本可变以便流式追加）。
/// v0.10.0：从 card_creator_screen 移入 —— 后台任务需在页面销毁后
/// 继续持有会话并等待页面重挂载接管。
class CreatorMsg {
  CreatorMsg({required this.isUser, this.text = ''});

  final bool isUser;
  String text;
  String? error;

  bool get isEmpty => text.trim().isEmpty;
}

/// 一次进行中的生成。请求归管理器持有：页面 dispose 只解绑 UI 监听
/// （[detach]），不取消请求；页面重进时 [attach] 接管显示。
class GenerationJob {
  GenerationJob._({
    required this.key,
    required this.kind,
    required this.request,
    required this.fullText,
    this.targetTs,
    this.targetSender,
    this.creatorTarget,
    this.creatorSession,
    required this.genStartLen,
    required this.isContinue,
    this.prompt,
    required this.sentAdvanced,
    this.runner,
  });

  /// 会话 key：单聊 = 角色 id；群聊 = `group_<id>`；创建器 = 'creator'。
  final String key;

  final GenKind kind;

  /// 发起时的请求快照。
  final GenRequest request;

  /// 目标消息的权威完整文本 = 起始文本 + 至今收到的全部增量。
  /// 落库与重进接管都以它为准（页面侧的节流缓冲只是它的镜像）。
  String fullText;

  // ---- 聊天（GenKind.chat）定位目标占位消息 ----

  /// 目标消息时间戳（会话已被清空时落库自动跳过，不复活旧内容）。
  final int? targetTs;

  /// 群聊发言者 id（单聊 null）。
  final String? targetSender;

  // ---- 创建器（GenKind.creator）内存会话 ----

  final CreatorMsg? creatorTarget;
  final List<CreatorMsg>? creatorSession;

  // ---- 接管页面可用的记账信息（与 _runOnce 的页内状态对应） ----

  final int genStartLen;
  final bool isContinue;
  final List<PromptMessage>? prompt;

  /// 本次请求是否带了非默认高级采样字段（v0.9.0 失败提示用）。
  final bool sentAdvanced;

  /// 测试注入的执行器（null = 默认 ApiClient）。
  final GenerationRunner? runner;

  /// 最近一次错误（成功完成后仍保留，供接管页面贴错误气泡）。
  String? error;

  /// provider 返回的 usage（自动继续判断与记账用）。
  int? exactPrompt;
  int? exactCompletion;

  /// 用户在页面内点了停止（管理器执行 cancel，非解绑）。
  bool cancelled = false;

  /// 请求已结束（落库/回调已按规则处理完）。
  bool done = false;

  final Completer<void> _finished = Completer<void>();

  /// 请求结束信号：成功 / 出错 / 取消 / 后台跑完 都会完成。
  /// 发起页 await 它回到原有编排（自动继续、群聊轮转的收尾判断）。
  Future<void> get finished => _finished.future;

  _JobCallbacks? _cb;
  ApiClient? _api;
  bool _finalized = false;

  // ---------------------------------------------------- runner 接口 --

  /// 流式增量：计入权威缓冲，再转发给已绑定的页面。
  void emitDelta(String delta) {
    if (_finalized || delta.isEmpty) return;
    fullText += delta;
    _cb?.onDelta?.call(delta);
  }

  /// 请求错误：记录首个错误并转发（页面贴错误气泡）。
  void emitError(String message) {
    if (_finalized) return;
    error ??= message;
    _cb?.onError?.call(message);
  }

  /// provider usage 回报。
  void emitUsage(int promptTokens, int completionTokens) {
    if (_finalized) return;
    exactPrompt = promptTokens;
    exactCompletion = completionTokens;
  }

  // ---------------------------------------------------- 页面生命周期 --

  /// 页面 dispose 调用：只解绑 UI 监听，请求继续在后台跑。
  void detach() => _cb = null;

  /// 页面 initState 调用：接管进行中的显示（流式增量 / 错误 / 完成）。
  /// [onDone] 仅接管页面注册 —— 发起页用 [finished] 自行收尾，避免双跑。
  void attach({
    required void Function(String delta) onDelta,
    required void Function(String error) onError,
    void Function(GenerationJob job)? onDone,
  }) {
    _cb = _JobCallbacks(onDelta: onDelta, onError: onError, onDone: onDone);
  }

  /// 页面内点停止：管理器执行取消（与现有停止逻辑语义一致）。
  void cancel() {
    cancelled = true;
    _api?.cancel();
  }

  /// 请求结束的统一收尾（由管理器在 runner future 完成后调用）。
  Future<void> _finalize(ActiveGenerations owner) async {
    if (_finalized) return;
    _finalized = true;
    done = true;
    _api?.dispose();

    if (kind == GenKind.chat) {
      // 单聊/群聊：先落库（权威 fullText 替换写，幂等），再移交。
      try {
        await _persist();
      } catch (_) {
        // 落库失败不阻塞移交（页面重进仍可按现有读取逻辑处理）
      }
      owner._removeIfCurrent(this);
      final onDone = _cb?.onDone;
      onDone?.call(this);
    } else if (_cb != null) {
      // 创建器：有绑定页面 → 会话已在此页手里，任务即刻移交。
      owner._removeIfCurrent(this);
      final onDone = _cb?.onDone;
      onDone?.call(this);
    }
    // 创建器无绑定：保留任务（done=true），等待页面重挂载接管会话。

    if (!_finished.isCompleted) _finished.complete();
  }

  /// 后台完成落库：定位目标占位消息，用 fullText 整体替换（不追加、
  /// 不重不漏）；会话已被清空（目标找不到）时不写，避免复活旧内容。
  Future<void> _persist() async {
    final ts = targetTs;
    if (ts == null) return;
    final data = await Storage.loadConversationData(key);
    final msgs = data.messages;
    var idx = -1;
    for (var i = msgs.length - 1; i >= 0; i--) {
      final m = msgs[i];
      if (m.role != 'assistant') continue;
      if (m.timestamp == ts &&
          (targetSender == null || m.senderId == targetSender)) {
        idx = i;
        break;
      }
    }
    if (idx < 0) return; // 目标不在（对话被清空/删除）→ 不写
    msgs[idx] = msgs[idx].copyWith(content: fullText, error: error);
    await Storage.saveConversation(
      key,
      msgs,
      summary: data.summary,
      hitStats: data.hitStats,
    );
  }
}

/// 页面绑定的三路回调（发起页只有 delta/error，done 归发起页的 await）。
class _JobCallbacks {
  const _JobCallbacks({this.onDelta, this.onError, this.onDone});

  final void Function(String delta)? onDelta;
  final void Function(String error)? onError;
  final void Function(GenerationJob job)? onDone;
}

/// 后台生成管理器（v0.10.0）：单例，按会话 key 管理进行中的生成。
///
/// - 同 key 防重入：已有进行中任务时 [start] 返回 null；
/// - 页面 dispose 调 [GenerationJob.detach] 只解绑不取消；
/// - 单聊/群聊在完成时由管理器落库（页面没在也一样）；
/// - 创建器的内存会话保留在任务里，等待页面重挂载接管。
class ActiveGenerations {
  ActiveGenerations._();

  static final ActiveGenerations instance = ActiveGenerations._();

  /// 创建器会话的固定 key。
  static const String creatorKey = 'creator';

  final Map<String, GenerationJob> _jobs = <String, GenerationJob>{};

  /// 当前 key 是否有进行中的生成。
  GenerationJob? of(String key) => _jobs[key];

  bool has(String key) => _jobs.containsKey(key);

  /// 显式移除任务（创建器接管后清空对话等特殊路径）。
  void remove(String key) => _jobs.remove(key);

  /// 收尾时的移除：仅当 [job] 仍是该 key 的当前任务。页面停止/清空会先
  /// 显式 remove 再由旧任务异步收尾 —— 旧任务不得误删其间新发起的任务。
  void _removeIfCurrent(GenerationJob job) {
    if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
  }

  /// 发起一次生成。[runner] 仅测试注入（默认 ApiClient 流式请求）。
  /// 返回 null = 同 key 已有进行中的任务（防重入，与现状一致）。
  GenerationJob? start({
    required String key,
    required GenKind kind,
    required GenRequest request,
    String initialText = '',
    int? targetTs,
    String? targetSender,
    List<CreatorMsg>? creatorSession,
    CreatorMsg? creatorTarget,
    int genStartLen = 0,
    bool isContinue = false,
    List<PromptMessage>? prompt,
    bool sentAdvanced = false,
    void Function(String delta)? onDelta,
    void Function(String error)? onError,
    GenerationRunner? runner,
  }) {
    if (_jobs.containsKey(key)) return null;
    final job = GenerationJob._(
      key: key,
      kind: kind,
      request: request,
      fullText: initialText,
      targetTs: targetTs,
      targetSender: targetSender,
      creatorTarget: creatorTarget,
      creatorSession: creatorSession,
      genStartLen: genStartLen,
      isContinue: isContinue,
      prompt: prompt,
      sentAdvanced: sentAdvanced,
      runner: runner,
    );
    job._cb = _JobCallbacks(onDelta: onDelta, onError: onError);
    _jobs[key] = job;
    unawaited(_drive(job));
    return job;
  }

  Future<void> _drive(GenerationJob job) async {
    final run = job.runner ?? _apiRunner;
    try {
      await run(job);
    } catch (e) {
      job.emitError('请求失败：$e');
    }
    await job._finalize(this);
  }

  /// 默认执行器：页面专属的 ApiClient 由任务持有，取消走 [GenerationJob.cancel]。
  static Future<void> _apiRunner(GenerationJob job) {
    final api = ApiClient();
    job._api = api;
    final r = job.request;
    return api.streamChat(
      baseUrl: r.baseUrl,
      apiKey: r.apiKey,
      model: r.model,
      messages: r.messages,
      temperature: r.temperature,
      topP: r.topP,
      maxTokens: r.maxTokens,
      stream: r.stream,
      sampling: r.sampling,
      onDelta: job.emitDelta,
      onError: job.emitError,
      onUsage: job.emitUsage,
      onDone: () {},
    );
  }

  /// 测试用：清空任务表（不取消进行中的假流，测试自行收尾）。
  @visibleForTesting
  void debugReset() => _jobs.clear();
}
