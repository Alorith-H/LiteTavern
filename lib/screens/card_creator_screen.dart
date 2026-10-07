import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/character_card.dart';
import '../services/api_client.dart';
import '../services/generated_card.dart';
import '../services/prompt_builder.dart';
import '../services/storage.dart';
import '../services/stream_throttle.dart';
import '../widgets/common.dart';
import 'character_edit_screen.dart';
import 'settings_screen.dart';

/// 采访式系统提示（v0.8.0 创建器）：出题人/采访者，不是角色扮演 ——
/// 主动追问缺的信息，一次最多问 2 个问题。
const String _kInterviewSystem = r'''
你是角色卡创作的采访者（出题人），不是角色扮演者，进入任何虚构场景。
用户想创建一个 AI 角色卡，你要通过提问把关键信息收集齐：
名字、性格、说话方式、场景、开场白，以及外貌、背景、世界观等有用信息。

规则：
- 每次回复最多问 2 个问题，问题要具体、口语化，便于一句话回答；
- 用户可能一句话回答多个问题：先确认收到，再继续追问仍缺失的信息；
- 信息基本齐了就简短总结已确认的设定，并提示用户：
  聊完可以点右下角「生成角色卡」；
- 始终用中文，保持简洁，不要长篇大论，不要提前进入角色扮演。
''';

/// 生成角色卡的系统提示：要求返回纯 JSON，含 character_book 规范。
const String _kCardJsonSystem = r'''
你是角色卡生成器。根据用户与采访者的对话记录，输出一张角色卡的纯 JSON：
只输出 JSON 本身，不要代码围栏，不要任何解释文字。

JSON 字段（值均为字符串）：
- "name"：角色名字（必填）
- "description"：角色背景与设定（200–400 字）
- "personality"：性格特点（100–200 字）
- "scenario"：故事场景与相遇背景（100–200 字）
- "first_mes"：开场白（角色对用户说的第一段话，可用 \n 换行）
- "mes_example"：对话示例（没有合适的可给空字符串）
- "system_prompt"：给模型的角色指令（可给空字符串）
- "character_book"：内嵌世界书，没有可写的词条时必须为 null

character_book 规范（仅当角色涉及专有名词、地点、世界观规则时才写，
条目 3–8 条，不许编造凑数）：
{
  "name": "<角色名>的世界书",
  "entries": [
    {
      "keys": ["关键词1", "keyword2"],
      "content": "不超过200字的设定说明",
      "enabled": true,
      "insertion_order": 0,
      "position": 0
    }
  ]
}
- keys 为 1–4 个中英文关键词；content ≤200 字；position 固定 0

要求：忠实使用对话里的信息；对话里缺失的关键设定可自行合理补全；
用户在对话中要求修改（如"世界书里把 X 改成 Y"）要体现在输出里。
直接输出 JSON。
''';

/// 「继续生成」追加的系统指令。
const String _kContinueHint = '接着刚才的内容继续输出，不要重复已输出的部分，不要解释。';

/// 创建器里的一条消息（内存态，不落库；文本可变以便流式追加）。
class _CreatorMsg {
  _CreatorMsg({required this.isUser, this.text = ''});

  final bool isUser;
  String text;
  String? error;

  bool get isEmpty => text.trim().isEmpty;
}

/// AI 角色卡创建器（v0.8.0）：采访式对话收集设定 → 一键生成纯 JSON 卡
/// → 打开现有编辑页预览（内存卡、未保存态）→ 复用现有保存入库流程。
///
/// 对话不持久化（退出即弃，顶栏菜单「清空对话」）。
/// 使用激活 API 配置与激活预设参数（temperature/topP/maxTokens）。
class CardCreatorScreen extends StatefulWidget {
  const CardCreatorScreen({super.key});

  @override
  State<CardCreatorScreen> createState() => _CardCreatorScreenState();
}

class _CardCreatorScreenState extends State<CardCreatorScreen> {
  /// 采访对话（仅内存，不写任何存储）
  final List<_CreatorMsg> _msgs = [];

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _inputEmpty = ValueNotifier<bool>(true);
  final _api = ApiClient();

  bool _generating = false; // 采访流式进行中
  bool _building = false; // 生成角色卡（一次性请求）进行中
  bool _stopped = false; // 上次采访被手动停止（可继续）
  bool _followScroll = true;
  int _genToken = 0;

  /// 流式节流：与聊天页同一实现（≥33ms 才落一次 setState）
  late final StreamThrottle _throttle = StreamThrottle(
    minIntervalMs: 33,
    onFlush: _applyDelta,
  );

  bool get _canConfigure => AppSettings.apiConfigured;

  /// 停止后可继续：末条是未完成的 AI 回复
  bool get _canContinue =>
      !_generating &&
      !_building &&
      _stopped &&
      _msgs.isNotEmpty &&
      !_msgs.last.isUser &&
      !_msgs.last.isEmpty;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _throttle.dispose();
    _api.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputEmpty.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 滚动 --

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final p = _scrollCtrl.position;
    _followScroll = p.pixels >= p.maxScrollExtent - 48;
  }

  void _followBottom() {
    if (!_followScroll || !_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  // ------------------------------------------------------------- 对话 --

  void _send() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _generating || _building) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    _inputCtrl.clear();
    _inputEmpty.value = true;
    setState(() {
      // 清掉上一轮停止时一个字都没出的空占位
      if (_msgs.isNotEmpty && !_msgs.last.isUser && _msgs.last.isEmpty) {
        _msgs.removeLast();
      }
      _msgs.add(_CreatorMsg(isUser: true, text: text));
      _msgs.add(_CreatorMsg(isUser: false));
      _generating = true;
      _stopped = false;
    });
    _followScroll = true;
    _followBottom();
    _runChat();
  }

  /// 停止后继续：末条 AI 回复追加输出（复用流式管线）。
  void _continue() {
    if (!_canContinue) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    setState(() {
      _generating = true;
      _stopped = false;
    });
    _runChat(isContinue: true);
  }

  /// 失败气泡的重试：丢掉失败的回复重跑这一轮。
  void _retry() {
    if (_generating || _building) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    setState(() {
      if (_msgs.isNotEmpty && !_msgs.last.isUser) _msgs.removeLast();
      _msgs.add(_CreatorMsg(isUser: false));
      _generating = true;
      _stopped = false;
    });
    _runChat();
  }

  /// 一次采访流式请求。对话不落库，只走内存 + 节流刷新。
  Future<void> _runChat({bool isContinue = false}) async {
    final token = ++_genToken;
    _throttle.reset();
    final history = <PromptMessage>[
      for (final m in _msgs)
        if (!m.isEmpty)
          PromptMessage(
            role: m.isUser ? 'user' : 'assistant',
            content: m.text,
          ),
    ];
    if (isContinue) {
      history.add(const PromptMessage(role: 'system', content: _kContinueHint));
    }
    await _api.streamChat(
      baseUrl: AppSettings.baseUrl,
      apiKey: AppSettings.apiKey,
      model: AppSettings.model,
      messages: [
        const PromptMessage(role: 'system', content: _kInterviewSystem),
        ...history,
      ],
      temperature: AppSettings.temperature,
      topP: AppSettings.topP,
      maxTokens: AppSettings.maxTokens,
      onDelta: (delta) {
        if (!mounted || token != _genToken) return;
        _throttle.enqueue(delta);
      },
      onError: (error) {
        if (!mounted || token != _genToken) return;
        _throttle.flush();
        setState(() {
          if (_msgs.isNotEmpty && !_msgs.last.isUser) {
            _msgs.last.error = error;
          }
        });
      },
      onDone: () {},
    );
    _throttle.flush();
    if (!mounted || token != _genToken) return; // 已被停止，_stop 已收尾
    setState(() {
      _generating = false;
      _stopped = false;
    });
    _followBottom();
  }

  void _stop() {
    _genToken++;
    _api.cancel();
    _throttle.flush(); // 并入停止前已到达的文本，不丢字
    if (!mounted) return;
    setState(() {
      _generating = false;
      _stopped = true;
    });
  }

  /// 节流回调：把缓冲文本追加进末条 AI 消息。
  void _applyDelta(String text) {
    if (!mounted) return;
    setState(() {
      if (_msgs.isNotEmpty && !_msgs.last.isUser) {
        _msgs.last.text += text;
      }
    });
    _followBottom();
  }

  void _clearChat() {
    _genToken++;
    _api.cancel();
    _throttle.reset();
    if (!mounted) return;
    setState(() {
      _msgs.clear();
      _generating = false;
      _stopped = false;
    });
  }

  // ------------------------------------------------------- 生成角色卡 --

  /// 一次性调 API 要求纯 JSON → 解析 → 打开现有编辑页（内存卡、未保存态）。
  /// 失败 snackbar + 保留对话，允许再点（或补一句「把 JSON 再输出一遍」）。
  Future<void> _generateCard() async {
    if (_building || _generating) return;
    if (!_canConfigure) {
      _promptConfigureApi();
      return;
    }
    if (_msgs.isEmpty) {
      _toast('先描述一下你想要的角色，或和 AI 聊几句');
      return;
    }
    setState(() => _building = true);
    try {
      // 生成卡需要完整 JSON：预设 max_tokens 过小会被截断，最少给 4096
      final maxT = AppSettings.maxTokens < 4096 ? 4096 : AppSettings.maxTokens;
      final raw = await _api
          .summarize(
            baseUrl: AppSettings.baseUrl,
            apiKey: AppSettings.apiKey,
            model: AppSettings.model,
            system: _kCardJsonSystem,
            user: _transcript(),
            temperature: AppSettings.temperature,
            maxTokens: maxT,
          )
          .timeout(const Duration(seconds: 120));
      if (!mounted) return;
      if (raw.trim().isEmpty) {
        _toast('生成未完成，可以再点一次');
        return;
      }
      final CharacterCard? card = parseGeneratedCard(raw);
      if (card == null) {
        _toast('没解析出可用的角色卡，可以再点一次，'
            '或补一句「把 JSON 再输出一遍」');
        return;
      }
      // 打开现有编辑页预览（draft = 内存卡未保存），保存走既有入库流程
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CharacterEditScreen.draft(card: card)),
      );
    } on TimeoutException {
      _api.cancel();
      if (mounted) _toast('生成超时，请重试');
    } on ApiException catch (e) {
      if (mounted) _toast('生成失败：${e.message}');
    } catch (_) {
      if (mounted) _toast('生成失败，请重试');
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  /// 采访对话转成给生成模型的纯文本记录。
  String _transcript() {
    final buf = StringBuffer('采访对话记录（用户想要创建一个角色卡）：\n\n');
    for (final m in _msgs) {
      if (m.isEmpty) continue;
      buf
        ..writeln('${m.isUser ? '用户' : '采访者'}：${m.text}')
        ..writeln();
    }
    return buf.toString();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

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

  // ------------------------------------------------------------- 构建 --

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 创建角色卡'),
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多',
            onSelected: (_) => _clearChat(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 0,
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 20),
                    SizedBox(width: 10),
                    Text('清空对话'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部说明（人话一句，hairline 分隔）
          Container(
            width: double.maxFinite,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: scheme.outline),
              ),
            ),
            child: Text(
              '描述你想要的角色，或直接和 AI 聊，聊完点右下角生成',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: _buildMessages(scheme)),
          _buildBottomBar(scheme),
        ],
      ),
    );
  }

  Widget _buildMessages(ColorScheme scheme) {
    if (_msgs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            '先告诉 AI 你想要什么样的角色，\n它会追问名字、性格、场景这些细节',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppType.caption,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    final fontSize = AppSettings.chatFontSize;
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: _msgs.length,
      itemBuilder: (context, i) {
        final m = _msgs[i];
        final thinking =
            !m.isUser && i == _msgs.length - 1 && _generating && m.isEmpty;
        // 与聊天页同一套气泡令牌：用户 accent 10% 淡底右侧；
        // AI surface 底 + hairline 描边左侧，圆角 16（下角 4）。
        Widget bubble = Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(
            color: m.isUser
                ? scheme.primary.withValues(alpha: 0.10)
                : scheme.surface,
            border: m.isUser ? null : Border.all(color: scheme.outline),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(m.isUser ? 16 : 4),
              bottomRight: Radius.circular(m.isUser ? 4 : 16),
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
                    Text(
                      '思考中…',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                )
              else
                MarkdownBody(
                  data: m.text,
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
                          color: scheme.error,
                          fontSize: AppType.caption,
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _retry,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        '重试',
                        style: TextStyle(fontSize: AppType.caption),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
        return Align(
          alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: bubble,
        );
      },
    );
  }

  Widget _buildBottomBar(ColorScheme scheme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outline)),
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
                  hintText: '描述你想要的角色…',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onChanged: (_) =>
                    _inputEmpty.value = _inputCtrl.text.trim().isEmpty,
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            // 发送 / 停止 / 继续（40dp 圆钮，与聊天页一致）
            ValueListenableBuilder<bool>(
              valueListenable: _inputEmpty,
              builder: (context, empty, _) => SizedBox(
                width: 40,
                height: 40,
                child: _generating
                    ? IconButton(
                        onPressed: _stop,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 40, minHeight: 40),
                        style: IconButton.styleFrom(
                          backgroundColor: scheme.error,
                          foregroundColor: scheme.onError,
                          shape: const CircleBorder(),
                        ),
                        icon: const Icon(Icons.stop_outlined, size: 20),
                        tooltip: '停止',
                      )
                    : _canContinue
                        ? IconButton(
                            onPressed: _continue,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 40),
                            style: IconButton.styleFrom(
                              backgroundColor: scheme.primary,
                              foregroundColor: scheme.onPrimary,
                              shape: const CircleBorder(),
                            ),
                            icon: const Icon(Icons.play_arrow_outlined,
                                size: 20),
                            tooltip: '继续',
                          )
                        : IconButton(
                            onPressed: empty ? null : _send,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 40),
                            style: IconButton.styleFrom(
                              backgroundColor: empty
                                  ? scheme.surfaceContainerHighest
                                  : scheme.primary,
                              foregroundColor: empty
                                  ? scheme.onSurfaceVariant
                                  : scheme.onPrimary,
                              shape: const CircleBorder(),
                            ),
                            icon: const Icon(Icons.arrow_upward, size: 20),
                            tooltip: '发送',
                          ),
              ),
            ),
            const SizedBox(width: 8),
            // 右下角固定主按钮：生成角色卡（流式/生成中置灰）
            FilledButton.icon(
              onPressed:
                  (_building || _generating) ? null : _generateCard,
              icon: _building
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onPrimary,
                      ),
                    )
                  : const Icon(Icons.auto_awesome_outlined, size: 18),
              label: const Text('生成角色卡'),
            ),
          ],
        ),
      ),
    );
  }
}
