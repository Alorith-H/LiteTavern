import 'dart:convert';

import 'sampling_params.dart';
import 'storage.dart';

/// 一段聊天的生成参数覆盖（v0.34.0）。
///
/// 只覆盖「这一段聊天」；留空的字段继续跟全局生成预设。
/// 6 个键与 SillyTavern 的每聊天覆盖一致：
/// temperature / top_p / top_k / max_tokens / frequency_penalty / presence_penalty。
class ChatPresetOverride {
  final double? temperature;
  final double? topP;
  final int? topK;
  final int? maxTokens;
  final double? frequencyPenalty;
  final double? presencePenalty;

  const ChatPresetOverride({
    this.temperature,
    this.topP,
    this.topK,
    this.maxTokens,
    this.frequencyPenalty,
    this.presencePenalty,
  });

  static const ChatPresetOverride empty = ChatPresetOverride();

  bool get isEmpty =>
      temperature == null &&
      topP == null &&
      topK == null &&
      maxTokens == null &&
      frequencyPenalty == null &&
      presencePenalty == null;

  bool get isNotEmpty => !isEmpty;

  int get count => [
        temperature,
        topP,
        topK,
        maxTokens,
        frequencyPenalty,
        presencePenalty,
      ].where((v) => v != null).length;

  static const double _unset = -999999.0;

  /// 传 `null` 表示清空该字段（回到跟随全局），不传表示保持不变。
  ChatPresetOverride copyWith({
    Object? temperature = _unset,
    Object? topP = _unset,
    Object? topK = _unset,
    Object? maxTokens = _unset,
    Object? frequencyPenalty = _unset,
    Object? presencePenalty = _unset,
  }) {
    return ChatPresetOverride(
      temperature: identical(temperature, _unset)
          ? this.temperature
          : temperature as double?,
      topP: identical(topP, _unset) ? this.topP : topP as double?,
      topK: identical(topK, _unset) ? this.topK : topK as int?,
      maxTokens:
          identical(maxTokens, _unset) ? this.maxTokens : maxTokens as int?,
      frequencyPenalty: identical(frequencyPenalty, _unset)
          ? this.frequencyPenalty
          : frequencyPenalty as double?,
      presencePenalty: identical(presencePenalty, _unset)
          ? this.presencePenalty
          : presencePenalty as double?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (topK != null) 'top_k': topK,
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (frequencyPenalty != null) 'frequency_penalty': frequencyPenalty,
        if (presencePenalty != null) 'presence_penalty': presencePenalty,
      };

  factory ChatPresetOverride.fromJson(Map<String, dynamic> json) {
    double? d(Object? v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }

    int? i(Object? v) {
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    final temp = d(json['temperature']);
    final topP = d(json['top_p']);
    final topK = i(json['top_k']);
    final maxTokens = i(json['max_tokens']);
    final freq = d(json['frequency_penalty']);
    final pres = d(json['presence_penalty']);
    return ChatPresetOverride(
      temperature: _clampD(temp, 0, 2),
      topP: _clampD(topP, 0, 1),
      topK: _clampI(topK, 0, 200),
      maxTokens: _clampI(maxTokens, 0, 32768),
      frequencyPenalty: _clampD(freq, 0, 2),
      presencePenalty: _clampD(pres, 0, 2),
    );
  }

  static double? _clampD(double? v, double lo, double hi) {
    if (v == null) return null;
    return v.clamp(lo, hi).toDouble();
  }

  static int? _clampI(int? v, int lo, int hi) {
    if (v == null) return null;
    return v.clamp(lo, hi);
  }

  String get summary {
    if (isEmpty) return '跟随全局预设';
    final parts = <String>[];
    if (temperature != null) parts.add('t$temperature');
    if (topP != null) parts.add('p$topP');
    if (topK != null) parts.add('k$topK');
    if (maxTokens != null) parts.add('上限 $maxTokens');
    if (frequencyPenalty != null) parts.add('freq $frequencyPenalty');
    if (presencePenalty != null) parts.add('pres $presencePenalty');
    return '覆盖 ${parts.join(' · ')}';
  }
}

/// 解析后的「这一段聊天实际会用到的生成参数」。
class ChatGenSettings {
  final double temperature;
  final double topP;
  final int maxTokens;
  final SamplingParams sampling;
  final ChatPresetOverride override;

  const ChatGenSettings({
    required this.temperature,
    required this.topP,
    required this.maxTokens,
    required this.sampling,
    this.override = ChatPresetOverride.empty,
  });

  bool get hasOverride => override.isNotEmpty;

  /// 全局预设当前的值（展示用）。
  static ChatGenSettings get global {
    final preset = AppSettings.activePreset;
    return ChatGenSettings(
      temperature: AppSettings.temperature,
      topP: AppSettings.topP,
      maxTokens: preset.maxTokens,
      sampling: preset.sampling,
    );
  }

  /// 合并「全局预设 + 这段聊天的覆盖」。
  static ChatGenSettings resolve(String convId) {
    final base = global;
    final ov = ChatPresetOverrideStore.load(convId);
    if (ov.isEmpty) return base;
    final s = base.sampling;
    return ChatGenSettings(
      temperature: ov.temperature ?? base.temperature,
      topP: ov.topP ?? base.topP,
      maxTokens: ov.maxTokens ?? base.maxTokens,
      sampling: SamplingParams(
        frequencyPenalty: ov.frequencyPenalty ?? s.frequencyPenalty,
        presencePenalty: ov.presencePenalty ?? s.presencePenalty,
        repetitionPenalty: s.repetitionPenalty,
        topK: ov.topK ?? s.topK,
        minP: s.minP,
        seed: s.seed,
        stop: s.stop,
      ),
      override: ov,
    );
  }

  /// 一行说明，放在设置行副标题里。
  String get summary =>
      't$temperature · p$topP · 上限 ${maxTokens == 0 ? '不限' : maxTokens}';
}

/// 每聊天覆盖的存取（prefs 键 `chat_preset_overrides`，值是 {convId: {...}}）。
class ChatPresetOverrideStore {
  static ChatPresetOverride load(String convId) {
    final raw = AppSettings.chatPresetOverridesJson;
    if (raw == null || raw.trim().isEmpty) return ChatPresetOverride.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return ChatPresetOverride.empty;
      final entry = decoded[convId];
      if (entry is! Map) return ChatPresetOverride.empty;
      return ChatPresetOverride.fromJson(entry.cast<String, dynamic>());
    } catch (_) {
      return ChatPresetOverride.empty;
    }
  }

  static Map<String, dynamic> _all() {
    final raw = AppSettings.chatPresetOverridesJson;
    if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> save(String convId, ChatPresetOverride override) async {
    final all = _all();
    if (override.isEmpty) {
      all.remove(convId);
    } else {
      all[convId] = override.toJson();
    }
    await AppSettings.setChatPresetOverridesJson(
      all.isEmpty ? null : jsonEncode(all),
    );
  }

  static Future<void> clear(String convId) =>
      save(convId, ChatPresetOverride.empty);
}
