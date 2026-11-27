import 'dart:convert';

/// SillyTavern 预设兼容（v0.30.0，第一步：只读解析 + 展示 + 采样参数应用）。
///
/// 设计取舍：
/// * 只解析 ST 导出 JSON 里我们**真正会用**的字段；不认识的一律忽略，并在 `warnings` 里说明，
///   不因为多一个字段就整份失败。
/// * 提示词只做「顺序 + 启用状态」的可视化，本轮**不注入**到实际提示词里
///   （执行阶段留给下一轮的「兼容模式」开关，避免影响现在的对话质量）。
/// * 采样参数可以一键写进当前生成预设：temperature / top_p / max_tokens 是通用字段，
///   top_k / min_p / 各种 penalty / seed 走已有 `SamplingParams`，非默认值才会出现在请求里。
class StPromptItem {
  final String identifier;
  final String name;

  /// system / user / assistant
  final String role;
  final String content;

  /// ST 的占位标记（chatHistory、worldInfoBefore 等），本身没有正文。
  final bool isMarker;

  /// 是否 ST 里那条「主系统提示」（main prompt）。
  final bool isSystemPrompt;

  /// 0 = 相对位置（按顺序），1 = 按深度注入到聊天里。
  final int? injectionPosition;

  /// 仅 injectionPosition == 1 时有意义：0 = 最后一条之后，越大越靠前。
  final int? injectionDepth;

  final bool enabled;

  const StPromptItem({
    required this.identifier,
    required this.name,
    required this.role,
    required this.content,
    this.isMarker = false,
    this.isSystemPrompt = false,
    this.injectionPosition,
    this.injectionDepth,
    this.enabled = true,
  });

  bool get hasContent => !isMarker && content.trim().isNotEmpty;

  bool get injectsInChat => injectionPosition == 1;

  String get roleLabel => switch (role) {
        'system' => '系统',
        'user' => '你',
        'assistant' => '角色',
        _ => role.isEmpty ? '未指定' : role,
      };

  String get orderNote {
    if (isMarker) return '占位';
    if (injectsInChat) return '注入 · 深度 ${injectionDepth ?? 0}';
    return '按顺序';
  }

  String get preview {
    final flat = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '（空）';
    return flat.length <= 70 ? flat : '${flat.substring(0, 70)}…';
  }

  StPromptItem copyWith({bool? enabled}) => StPromptItem(
        identifier: identifier,
        name: name,
        role: role,
        content: content,
        isMarker: isMarker,
        isSystemPrompt: isSystemPrompt,
        injectionPosition: injectionPosition,
        injectionDepth: injectionDepth,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'identifier': identifier,
        'name': name,
        'role': role,
        'content': content,
        'marker': isMarker,
        'systemPrompt': isSystemPrompt,
        if (injectionPosition != null) 'injectionPosition': injectionPosition,
        if (injectionDepth != null) 'injectionDepth': injectionDepth,
        'enabled': enabled,
      };

  factory StPromptItem.fromJson(Map<String, dynamic> json) => StPromptItem(
        identifier: (json['identifier'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        role: (json['role'] as String?) ?? 'system',
        content: (json['content'] as String?) ?? '',
        isMarker: json['marker'] == true,
        isSystemPrompt: json['systemPrompt'] == true,
        injectionPosition: (json['injectionPosition'] as num?)?.toInt(),
        injectionDepth: (json['injectionDepth'] as num?)?.toInt(),
        enabled: json['enabled'] != false,
      );
}

/// 解析结果：一条 ST 预设里我们关心的全部内容。
class StPresetSnapshot {
  final String name;
  final double? temperature;
  final double? topP;
  final int? topK;
  final double? frequencyPenalty;
  final double? presencePenalty;
  final double? repetitionPenalty;
  final double? minP;
  final int? maxTokens;
  final int? seed;
  final List<String> stop;
  final List<StPromptItem> prompts;
  final List<String> warnings;

  const StPresetSnapshot({
    required this.name,
    this.temperature,
    this.topP,
    this.topK,
    this.frequencyPenalty,
    this.presencePenalty,
    this.repetitionPenalty,
    this.minP,
    this.maxTokens,
    this.seed,
    this.stop = const [],
    this.prompts = const [],
    this.warnings = const [],
  });

  bool get hasSampling =>
      temperature != null ||
      topP != null ||
      topK != null ||
      frequencyPenalty != null ||
      presencePenalty != null ||
      repetitionPenalty != null ||
      minP != null ||
      maxTokens != null ||
      seed != null ||
      stop.isNotEmpty;

  int get samplingCount {
    var n = 0;
    if (temperature != null) n++;
    if (topP != null) n++;
    if (topK != null) n++;
    if (frequencyPenalty != null) n++;
    if (presencePenalty != null) n++;
    if (repetitionPenalty != null) n++;
    if (minP != null) n++;
    if (maxTokens != null) n++;
    if (seed != null) n++;
    if (stop.isNotEmpty) n++;
    return n;
  }

  int get enabledCount => prompts.where((p) => p.enabled && !p.isMarker).length;

  int get markerCount => prompts.where((p) => p.isMarker).length;

  /// 采样参数展示行（值 → 文本），供界面逐行列出。
  List<(String, String)> get samplingRows {
    final rows = <(String, String)>[];
    void add(String label, Object? value) {
      if (value == null) return;
      rows.add((label, '$value'));
    }

    add('temperature（温度）', temperature);
    add('top_p（核采样）', topP);
    add('top_k', topK == 0 ? '关闭' : topK);
    add('frequency_penalty（频率惩罚）', frequencyPenalty);
    add('presence_penalty（存在惩罚）', presencePenalty);
    add('repetition_penalty（重复惩罚）', repetitionPenalty);
    add('min_p', minP);
    add('max_tokens（上限）', maxTokens == 0 ? '不限' : maxTokens);
    add('seed（种子）', seed);
    if (stop.isNotEmpty) rows.add(('stop（停止词）', stop.join(' / ')));
    return rows;
  }

  StPresetSnapshot copyWith({List<StPromptItem>? prompts}) => StPresetSnapshot(
        name: name,
        temperature: temperature,
        topP: topP,
        topK: topK,
        frequencyPenalty: frequencyPenalty,
        presencePenalty: presencePenalty,
        repetitionPenalty: repetitionPenalty,
        minP: minP,
        maxTokens: maxTokens,
        seed: seed,
        stop: stop,
        prompts: prompts ?? this.prompts,
        warnings: warnings,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'topP': topP,
        if (topK != null) 'topK': topK,
        if (frequencyPenalty != null) 'frequencyPenalty': frequencyPenalty,
        if (presencePenalty != null) 'presencePenalty': presencePenalty,
        if (repetitionPenalty != null) 'repetitionPenalty': repetitionPenalty,
        if (minP != null) 'minP': minP,
        if (maxTokens != null) 'maxTokens': maxTokens,
        if (seed != null) 'seed': seed,
        'stop': stop,
        'prompts': [for (final p in prompts) p.toJson()],
        'warnings': warnings,
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory StPresetSnapshot.fromJson(Map<String, dynamic> json) =>
      StPresetSnapshot(
        name: (json['name'] as String?) ?? 'ST 预设',
        temperature: (json['temperature'] as num?)?.toDouble(),
        topP: (json['topP'] as num?)?.toDouble(),
        topK: (json['topK'] as num?)?.toInt(),
        frequencyPenalty: (json['frequencyPenalty'] as num?)?.toDouble(),
        presencePenalty: (json['presencePenalty'] as num?)?.toDouble(),
        repetitionPenalty: (json['repetitionPenalty'] as num?)?.toDouble(),
        minP: (json['minP'] as num?)?.toDouble(),
        maxTokens: (json['maxTokens'] as num?)?.toInt(),
        seed: (json['seed'] as num?)?.toInt(),
        stop: (json['stop'] as List?)?.whereType<String>().toList() ?? const [],
        prompts: [
          for (final raw in (json['prompts'] as List?) ?? const [])
            if (raw is Map<String, dynamic>) StPromptItem.fromJson(raw),
        ],
        warnings:
            (json['warnings'] as List?)?.whereType<String>().toList() ?? const [],
      );

  static StPresetSnapshot? tryParseStored(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return StPresetSnapshot.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}

class StPresetParser {
  /// 解析 ST 预设 JSON。[raw] 既可以是导出的整份预设，也可以是 `{preset: {...}}` 包裹。
  static StPresetSnapshot parse(String raw, {String fallbackName = 'ST 预设'}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) throw const FormatException('JSON 是空的');

    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const FormatException('不是合法的 JSON，检查是不是复制完整了');
    }

    Map<String, dynamic> root;
    if (decoded is Map<String, dynamic>) {
      final nested = decoded['preset'];
      root = nested is Map<String, dynamic>
          ? {...decoded, ...nested}
          : decoded;
    } else {
      throw const FormatException('预设应该是一个 JSON 对象');
    }

    final warnings = <String>[];

    final rawPrompts = root['prompts'];
    if (rawPrompts is! List || rawPrompts.isEmpty) {
      throw const FormatException('没有找到 prompts，可能不是 SillyTavern 预设');
    }

    String? asString(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    double? asDouble(Object? v) => v is num ? v.toDouble() : null;
    int? asInt(Object? v) => v is num ? v.toInt() : null;

    final name = asString(root['name']) ??
        asString(root['preset_name']) ??
        fallbackName;

    final stop = <String>[
      if (root['stop'] is List)
        ...(root['stop'] as List).whereType<String>(),
      if (root['stopstrings'] is List)
        ...(root['stopstrings'] as List).whereType<String>(),
      if (root['stop_strings'] is List)
        ...(root['stop_strings'] as List).whereType<String>(),
    ].map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();

    final items = <StPromptItem>[];
    for (var i = 0; i < rawPrompts.length; i++) {
      final entry = rawPrompts[i];
      if (entry is! Map) continue;
      final map = entry.cast<String, dynamic>();
      final identifier = asString(map['identifier']) ??
          asString(map['id']) ??
          'prompt_$i';
      final marker = map['marker'] == true;
      final roleRaw = asString(map['role'])?.toLowerCase() ?? 'system';
      final role = const {'system', 'user', 'assistant'}.contains(roleRaw)
          ? roleRaw
          : () {
              warnings.add('「${asString(map['name']) ?? identifier}」的 role「$roleRaw」'
                  '不支持，按 system 处理');
              return 'system';
            }();
      items.add(
        StPromptItem(
          identifier: identifier,
          name: asString(map['name']) ?? identifier,
          role: role,
          content: (map['content'] as String?) ?? '',
          isMarker: marker,
          isSystemPrompt: map['system_prompt'] == true,
          injectionPosition: asInt(map['injection_position']),
          injectionDepth: asInt(map['injection_depth']),
        ),
      );
    }

    final ordered = _applyOrder(root['prompt_order'], items, warnings);

    if (root['prompt_order'] == null) {
      warnings.add('这条预设没有 prompt_order：按 prompts 的原顺序展示');
    }

    // ST 里大量字段我们不参与：明确说一声，避免误以为全都生效了。
    const ignored = [
      'injection_trigger',
      'forbid_overrides',
      'squash_system_messages',
      'continue_prefill',
    ];
    final presentIgnored =
        ignored.where((k) => root.containsKey(k)).toList(growable: false);
    if (presentIgnored.isNotEmpty) {
      warnings.add('这些字段本轮不参与（只展示）：${presentIgnored.join('、')}');
    }

    return StPresetSnapshot(
      name: name,
      temperature: asDouble(root['temperature']),
      topP: asDouble(root['top_p']),
      topK: asInt(root['top_k']),
      frequencyPenalty: asDouble(root['frequency_penalty']),
      presencePenalty: asDouble(root['presence_penalty']),
      repetitionPenalty: asDouble(root['repetition_penalty']),
      minP: asDouble(root['min_p']),
      maxTokens: asInt(root['max_tokens']) ?? asInt(root['openai_max_tokens']),
      seed: asInt(root['seed']),
      stop: stop.length > 8 ? stop.sublist(0, 8) : stop,
      prompts: ordered,
      warnings: warnings,
    );
  }

  /// 按 `prompt_order` 重排并带上启用状态。
  ///
  /// ST 会在 `prompt_order` 里为每个 character_id 存一份顺序；我们取第一份
  /// （通常是默认 100000）即可。顺序表里没出现的条目保持原相对顺序追加在后面，
  /// 并视为启用——这样即便顺序表不全也不会丢内容。
  static List<StPromptItem> _applyOrder(
    Object? rawOrder,
    List<StPromptItem> items,
    List<String> warnings,
  ) {
    if (rawOrder is! List || rawOrder.isEmpty) return items;

    Map<String, bool>? enabledById;
    List<String>? orderIds;
    for (final group in rawOrder) {
      if (group is! Map) continue;
      final order = group['order'];
      if (order is! List) continue;
      final map = <String, bool>{};
      final ids = <String>[];
      for (final row in order) {
        if (row is! Map) continue;
        final id = row['identifier'];
        if (id is! String || id.isEmpty) continue;
        map[id] = row['enabled'] != false;
        ids.add(id);
      }
      if (ids.isEmpty) continue;
      enabledById = map;
      orderIds = ids;
      break;
    }

    if (orderIds == null) {
      warnings.add('prompt_order 里没有可用的顺序，按 prompts 原顺序展示');
      return items;
    }

    final byId = {for (final item in items) item.identifier: item};
    final result = <StPromptItem>[];
    final used = <String>{};
    final flags = enabledById ?? const <String, bool>{};
    for (final id in orderIds) {
      final item = byId[id];
      if (item == null) {
        warnings.add('顺序表里的「$id」在 prompts 里找不到，已跳过');
        continue;
      }
      used.add(id);
      result.add(item.copyWith(enabled: flags[id] ?? true));
    }
    for (final item in items) {
      if (used.contains(item.identifier)) continue;
      result.add(item);
    }
    return result;
  }

  /// 把「顺序 + 启用状态」重新编号，供上移/下移后落盘使用。
  static StPresetSnapshot withPrompts(
    StPresetSnapshot snapshot,
    List<StPromptItem> prompts,
  ) =>
      snapshot.copyWith(prompts: prompts);
}
