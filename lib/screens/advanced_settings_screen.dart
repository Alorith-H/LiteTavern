import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/sampling_params.dart';
import '../services/storage.dart';
import '../widgets/common.dart';

/// 高级设置页（v0.9.0）：采样参数、停止词等不常用项。
///
/// 只含 OpenAI 兼容请求里真实存在的字段；值为默认时请求里绝不出现。
/// 与生成参数滑条同一套"改动即存入激活预设"语义，页顶显示当前预设名。
/// 编辑风：行 + hairline，无 Card。
class AdvancedSettingsScreen extends StatefulWidget {
  const AdvancedSettingsScreen({super.key});

  @override
  State<AdvancedSettingsScreen> createState() => _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState extends State<AdvancedSettingsScreen> {
  late double _freq;
  late double _pres;
  late double _repet;
  late int _topK;
  late double _minP;
  late final TextEditingController _seedCtrl;
  late final TextEditingController _stopCtrl;
  late final TextEditingController _topKCtrl;

  @override
  void initState() {
    super.initState();
    _freq = AppSettings.frequencyPenalty;
    _pres = AppSettings.presencePenalty;
    _repet = AppSettings.repetitionPenalty;
    _topK = AppSettings.topK;
    _minP = AppSettings.minP;
    _seedCtrl = TextEditingController(
      text: AppSettings.seed?.toString() ?? '',
    );
    _topKCtrl = TextEditingController(text: '$_topK');
    _stopCtrl = TextEditingController(
      text: SamplingParams.stopToText(AppSettings.stop),
    );
  }

  @override
  void dispose() {
    _seedCtrl.dispose();
    _stopCtrl.dispose();
    _topKCtrl.dispose();
    super.dispose();
  }

  /// 滑条上方标签行：名称 + 右侧数值（accent）。
  Widget _sliderLabel(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: AppType.caption,
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: AppType.caption,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      ],
    );
  }

  /// 副说明（次要色小字）。
  Widget _subLine(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(fontSize: AppType.caption, color: scheme.onSurfaceVariant),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('高级设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          const SectionHeader('高级采样参数'),
          // 页顶：当前预设名 + 改动即存入的语义说明
          Text(
            '当前预设 · ${AppSettings.activePreset.name}'
            '，下方改动即存入此预设；值为默认时不随请求发送',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),

          // 频率惩罚：0–2 步进 0.05，默认 0 = 不发送
          _sliderLabel('频率惩罚', _freq.toStringAsFixed(2)),
          Slider(
            value: _freq.clamp(0, 2).toDouble(),
            min: 0,
            max: 2,
            divisions: 40,
            label: _freq.toStringAsFixed(2),
            onChanged: (v) {
              setState(() => _freq = v);
              AppSettings.frequencyPenalty = v;
            },
          ),
          _subLine('对常见词降权，压低车轱辘话的概率'),
          const SizedBox(height: 8),
          const Divider(height: 1),

          // 存在惩罚：0–2 步进 0.05，默认 0 = 不发送
          _sliderLabel('存在惩罚', _pres.toStringAsFixed(2)),
          Slider(
            value: _pres.clamp(0, 2).toDouble(),
            min: 0,
            max: 2,
            divisions: 40,
            label: _pres.toStringAsFixed(2),
            onChanged: (v) {
              setState(() => _pres = v);
              AppSettings.presencePenalty = v;
            },
          ),
          _subLine('已经提过的话题，更少再被主动提起'),
          const SizedBox(height: 8),
          const Divider(height: 1),

          // 重复惩罚：1.0–2.0 步进 0.05，默认 1.0 = 不发送
          _sliderLabel('重复惩罚', _repet.toStringAsFixed(2)),
          Slider(
            value: _repet.clamp(1.0, 2.0).toDouble(),
            min: 1.0,
            max: 2.0,
            divisions: 20,
            label: _repet.toStringAsFixed(2),
            onChanged: (v) {
              setState(() => _repet = v);
              AppSettings.repetitionPenalty = v;
            },
          ),
          _subLine('越高压得越狠，1.0 = 不干预；部分后端支持'),
          const SizedBox(height: 8),
          const Divider(height: 1),

          // Top K：数字 0–200，默认 0 = 关闭 = 不发送
          TextField(
            controller: _topKCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Top K',
              helperText: '只从概率前 K 个词里挑，0 = 关闭；部分后端支持',
              helperMaxLines: 2,
            ),
            onChanged: (v) {
              final n = (int.tryParse(v) ?? 0).clamp(0, 200);
              setState(() => _topK = n);
              AppSettings.topK = n;
            },
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),

          // Min P：0–0.5 步进 0.01，默认 0 = 关闭 = 不发送
          _sliderLabel('Min P', _minP.toStringAsFixed(2)),
          Slider(
            value: _minP.clamp(0, 0.5).toDouble(),
            min: 0,
            max: 0.5,
            divisions: 50,
            label: _minP.toStringAsFixed(2),
            onChanged: (v) {
              setState(() => _minP = v);
              AppSettings.minP = v;
            },
          ),
          _subLine('相对最高概率词截断长尾，0 = 关闭；部分后端支持'),
          const SizedBox(height: 8),
          const Divider(height: 1),

          // 随机种子：数字输入，空 = 随机 = 不发送
          TextField(
            controller: _seedCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '随机种子',
              helperText: '固定可复现同一回答，留空 = 随机',
            ),
            onChanged: (v) =>
                AppSettings.seed = int.tryParse(v.trim()),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),

          // 停止词：多行输入（每行一个），≤4 个，空 = 不发送
          TextField(
            controller: _stopCtrl,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '停止词',
              helperText: '每行一个，文本遇到其中之一就停止生成，最多 4 个',
              helperMaxLines: 2,
            ),
            onChanged: (v) => AppSettings.stop = SamplingParams.parseStopText(v),
          ),
          const SizedBox(height: 20),

          // 明确不做清单的说明（次要色）
          Text(
            'DRY、XTC、Mirostat 等依赖本地后端的采样器暂不提供',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
