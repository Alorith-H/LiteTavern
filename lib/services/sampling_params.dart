/// 高级采样参数（v0.9.0）：只含 OpenAI 兼容请求体里真实存在的字段。
/// 硬规则：值 == 默认 → 请求里完全不出现该字段（对严格端点零影响）。
/// DRY / XTC / Mirostat 等依赖本地后端的采样器一律不实现。
class SamplingParams {
  // 默认值 = 不发送（与 UI 滑条下限/规格表一致）
  static const double defaultFrequencyPenalty = 0;
  static const double defaultPresencePenalty = 0;
  static const double defaultRepetitionPenalty = 1.0;
  static const int defaultTopK = 0;
  static const double defaultMinP = 0;

  /// 停止词最多条数
  static const int maxStopCount = 4;

  final double frequencyPenalty;
  final double presencePenalty;
  final double repetitionPenalty;
  final int topK;
  final double minP;

  /// null = 随机（不发送）
  final int? seed;

  /// 已归一化的停止词；空列表 = 不发送
  final List<String> stop;

  const SamplingParams({
    this.frequencyPenalty = defaultFrequencyPenalty,
    this.presencePenalty = defaultPresencePenalty,
    this.repetitionPenalty = defaultRepetitionPenalty,
    this.topK = defaultTopK,
    this.minP = defaultMinP,
    this.seed,
    this.stop = const [],
  });

  /// 全字段皆默认 → 请求 body 里不会出现任何高级字段。
  bool get isDefault =>
      frequencyPenalty == defaultFrequencyPenalty &&
      presencePenalty == defaultPresencePenalty &&
      repetitionPenalty == defaultRepetitionPenalty &&
      topK == defaultTopK &&
      minP == defaultMinP &&
      seed == null &&
      stop.isEmpty;

  /// 逐字段写入请求体：值 != 默认才出现；stop 空列表不写。
  Map<String, dynamic> toBodyFields() => {
        if (frequencyPenalty != defaultFrequencyPenalty)
          'frequency_penalty': frequencyPenalty,
        if (presencePenalty != defaultPresencePenalty)
          'presence_penalty': presencePenalty,
        if (repetitionPenalty != defaultRepetitionPenalty)
          'repetition_penalty': repetitionPenalty,
        if (topK != defaultTopK) 'top_k': topK,
        if (minP != defaultMinP) 'min_p': minP,
        if (seed != null) 'seed': seed,
        if (stop.isNotEmpty) 'stop': stop,
      };

  /// 停止词归一化：两端去空白、丢空行、最多 [maxStopCount] 条。
  static List<String> normalizeStop(Iterable<String> lines) {
    final result = <String>[];
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      result.add(t);
      if (result.length >= maxStopCount) break;
    }
    return result;
  }

  /// 多行文本（每行一个）→ 停止词列表。
  static List<String> parseStopText(String raw) =>
      normalizeStop(raw.split('\n'));

  /// 停止词列表 → 多行文本（输入框回显）。
  static String stopToText(List<String> stop) => stop.join('\n');
}
