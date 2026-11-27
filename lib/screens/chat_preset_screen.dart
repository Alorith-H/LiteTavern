import 'package:flutter/material.dart';

import '../services/chat_gen_settings.dart';
import '../widgets/common.dart';

/// 每聊天生成参数覆盖（v0.34.0）：只影响这一段聊天，留空 = 跟随全局预设。
///
/// 覆盖的是 6 个常用键：temperature / top_p / top_k / max_tokens /
/// frequency_penalty / presence_penalty；其余（重复惩罚、min_p、seed、stop）
/// 继续跟全局预设走。
class ChatPresetScreen extends StatefulWidget {
  const ChatPresetScreen({
    super.key,
    required this.convId,
    this.chatTitle,
  });

  final String convId;
  final String? chatTitle;

  @override
  State<ChatPresetScreen> createState() => _ChatPresetScreenState();
}

class _ChatPresetScreenState extends State<ChatPresetScreen> {
  late final TextEditingController _temperatureCtrl;
  late final TextEditingController _topPCtrl;
  late final TextEditingController _topKCtrl;
  late final TextEditingController _maxTokensCtrl;
  late final TextEditingController _freqCtrl;
  late final TextEditingController _presCtrl;

  ChatPresetOverride _override = ChatPresetOverride.empty;
  final ChatGenSettings _global = ChatGenSettings.global;

  @override
  void initState() {
    super.initState();
    _override = ChatPresetOverrideStore.load(widget.convId);
    _temperatureCtrl = TextEditingController(text: _str(_override.temperature));
    _topPCtrl = TextEditingController(text: _str(_override.topP));
    _topKCtrl = TextEditingController(text: _str(_override.topK));
    _maxTokensCtrl = TextEditingController(text: _str(_override.maxTokens));
    _freqCtrl = TextEditingController(text: _str(_override.frequencyPenalty));
    _presCtrl = TextEditingController(text: _str(_override.presencePenalty));
  }

  @override
  void dispose() {
    _temperatureCtrl.dispose();
    _topPCtrl.dispose();
    _topKCtrl.dispose();
    _maxTokensCtrl.dispose();
    _freqCtrl.dispose();
    _presCtrl.dispose();
    super.dispose();
  }

  static String _str(Object? v) => v == null ? '' : '$v';

  double? _doubleOf(String raw, {double min = 0, double max = 2}) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    if (v == null) return null;
    return v.clamp(min, max);
  }

  int? _intOf(String raw, {int min = 0, int max = 32768}) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final v = int.tryParse(t);
    if (v == null) return null;
    return v.clamp(min, max);
  }

  ChatPresetOverride _collect() {
    return ChatPresetOverride(
      temperature: _doubleOf(_temperatureCtrl.text, max: 2),
      topP: _doubleOf(_topPCtrl.text, max: 1),
      topK: _intOf(_topKCtrl.text, max: 200),
      maxTokens: _intOf(_maxTokensCtrl.text, max: 32768),
      frequencyPenalty: _doubleOf(_freqCtrl.text, max: 2),
      presencePenalty: _doubleOf(_presCtrl.text, max: 2),
    );
  }

  Future<void> _save() async {
    final next = _collect();
    setState(() => _override = next);
    await ChatPresetOverrideStore.save(widget.convId, next);
  }

  Future<void> _resetAll() async {
    _temperatureCtrl.clear();
    _topPCtrl.clear();
    _topKCtrl.clear();
    _maxTokensCtrl.clear();
    _freqCtrl.clear();
    _presCtrl.clear();
    setState(() => _override = ChatPresetOverride.empty);
    await ChatPresetOverrideStore.clear(widget.convId);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已恢复：这段聊天跟随全局预设')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('这段聊天的生成参数'),
        actions: [
          if (_override.isNotEmpty)
            TextButton(
              onPressed: _resetAll,
              child: const Text('全部恢复'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.tune, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      widget.chatTitle == null || widget.chatTitle!.isEmpty
                          ? '只影响这一段聊天'
                          : '只影响「${widget.chatTitle}」',
                      style: TextStyle(
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '留空 = 跟随全局预设；填了就用这里填的值。'
                  '别的聊天、别的角色都不受影响。',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '全局预设现在是：${_global.summary}',
                  style: TextStyle(
                    fontSize: AppType.meta,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SectionHeader('采样参数'),
          _row(
            scheme,
            label: 'temperature｜随机度',
            controller: _temperatureCtrl,
            hint: '全局 ${_global.temperature}',
            helper: '0 – 2，越大越发散',
            onClear: () {
              _temperatureCtrl.clear();
              _save();
            },
          ),
          _row(
            scheme,
            label: 'top_p｜核采样',
            controller: _topPCtrl,
            hint: '全局 ${_global.topP}',
            helper: '0 – 1，越小越保守',
            onClear: () {
              _topPCtrl.clear();
              _save();
            },
          ),
          _row(
            scheme,
            label: 'top_k',
            controller: _topKCtrl,
            hint: '全局 ${_global.sampling.topK}',
            helper: '0 – 200，0 = 关闭',
            onClear: () {
              _topKCtrl.clear();
              _save();
            },
          ),
          _row(
            scheme,
            label: 'max_tokens｜单次上限',
            controller: _maxTokensCtrl,
            hint: _global.maxTokens == 0 ? '全局 不限' : '全局 ${_global.maxTokens}',
            helper: '0 = 不限；填了会限制这条回复的长度',
            onClear: () {
              _maxTokensCtrl.clear();
              _save();
            },
          ),
          _row(
            scheme,
            label: 'frequency_penalty',
            controller: _freqCtrl,
            hint: '全局 ${_global.sampling.frequencyPenalty}',
            helper: '0 – 2，越大越避免重复用词',
            onClear: () {
              _freqCtrl.clear();
              _save();
            },
          ),
          _row(
            scheme,
            label: 'presence_penalty',
            controller: _presCtrl,
            hint: '全局 ${_global.sampling.presencePenalty}',
            helper: '0 – 2，越大越愿意说新话题',
            onClear: () {
              _presCtrl.clear();
              _save();
            },
          ),
          const SizedBox(height: 24),
          Text(
            '只覆盖这 6 个键。重复惩罚、min_p、seed、stop 仍然用全局预设；'
            '这一段聊天里「替我说一句」「重新生成」也会用这里的值。',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    ColorScheme scheme, {
    required String label,
    required TextEditingController controller,
    required String hint,
    required String helper,
    required VoidCallback onClear,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => _save(),
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                helperText: helper,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: '这一项跟随全局',
            onPressed: onClear,
            icon: Icon(Icons.restart_alt, size: 20, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}
