/// 单个变体的 token 消耗（供"token 小字跟随当前变体"显示）。
class VariantUsage {
  /// 该变体生成时的输入 tokens（provider usage 或本地估算）
  final int? prompt;

  /// 该变体的输出 tokens
  final int? completion;

  /// true = 本地估算
  final bool estimated;

  const VariantUsage({this.prompt, this.completion, this.estimated = false});

  /// 未写入（生成进行中 / 旧数据）
  static const empty = VariantUsage();

  bool get hasTokens => prompt != null && completion != null;

  factory VariantUsage.fromJson(Map<String, dynamic> json) {
    return VariantUsage(
      prompt: (json['p'] as num?)?.toInt(),
      completion: (json['c'] as num?)?.toInt(),
      estimated: json['e'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        if (prompt != null) 'p': prompt,
        if (completion != null) 'c': completion,
        if (estimated) 'e': true,
      };
}

/// 聊天消息模型。
class ChatMessage {
  /// 'user' 或 'assistant'
  final String role;

  /// 当前显示的文本（始终等于 variants[variantIndex]，variants 为空时独立存在）
  final String content;

  /// 毫秒时间戳
  final int timestamp;

  /// 生成失败时的错误信息（非空表示这条是失败占位）
  final String? error;

  /// 这条回复累计消耗的输入 tokens（所有变体求和 = 真实花销）
  final int? promptTokens;

  /// 这条回复累计消耗的输出 tokens（所有变体求和）
  final int? completionTokens;

  /// true = 累计值里含本地估算（provider 未返回 usage）
  final bool tokensEstimated;

  /// 全部变体文本（含当前显示的那个）；旧数据无此字段 → 空列表
  final List<String> variants;

  /// 当前显示的是第几个变体
  final int variantIndex;

  /// 与 variants 平行的每变体 token 消耗；旧数据为空 → 回退消息级字段
  final List<VariantUsage> variantUsage;

  /// 群聊发言者角色 id（v0.6.0）。单聊不填 = null（兼容旧数据）；
  /// 群聊 assistant 消息必填，user 消息 null 表示"我"。
  final String? senderId;

  /// 群聊发言者名字（v0.6.0），仅群聊 assistant 消息有值。
  final String? senderName;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.timestamp,
    this.error,
    this.promptTokens,
    this.completionTokens,
    this.tokensEstimated = false,
    this.variants = const [],
    this.variantIndex = 0,
    this.variantUsage = const [],
    this.senderId,
    this.senderName,
  });

  /// 当前变体的 token 消耗（旧数据回退到消息级字段）。
  VariantUsage? get currentVariantUsage {
    if (variantIndex >= 0 && variantIndex < variantUsage.length) {
      final u = variantUsage[variantIndex];
      if (u.hasTokens) return u;
    }
    if (variantUsage.isEmpty && promptTokens != null && completionTokens != null) {
      return VariantUsage(
        prompt: promptTokens,
        completion: completionTokens,
        estimated: tokensEstimated,
      );
    }
    return null;
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final content = (json['content'] as String?) ?? '';
    var variants = (json['variants'] as List?)
            ?.whereType<String>()
            .toList() ??
        const <String>[];
    var index = (json['variantIndex'] as num?)?.toInt() ?? 0;
    // 防御：索引越界时钳制；变体与显示文本不一致时把显示文本收编为新变体
    //（覆盖"生成中途被杀、落盘时 variants 未及追加"的恢复场景）
    if (variants.isNotEmpty) {
      if (index < 0 || index >= variants.length) {
        index = index.clamp(0, variants.length - 1);
      }
      if (variants[index] != content) {
        variants = [...variants, content];
        index = variants.length - 1;
      }
    } else {
      index = 0;
    }
    var usage = (json['variantUsage'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(VariantUsage.fromJson)
            .toList() ??
        const <VariantUsage>[];
    if (usage.length > variants.length) {
      usage = usage.sublist(0, variants.length);
    }
    return ChatMessage(
      role: (json['role'] as String?) ?? 'user',
      content: content,
      timestamp: (json['timestamp'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      error: json['error'] as String?,
      promptTokens: (json['promptTokens'] as num?)?.toInt(),
      completionTokens: (json['completionTokens'] as num?)?.toInt(),
      tokensEstimated: json['tokensEstimated'] == true,
      variants: variants,
      variantIndex: index,
      variantUsage: usage,
      senderId: json['senderId'] as String?,
      senderName: json['senderName'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      'content': content,
      'timestamp': timestamp,
      if (error != null) 'error': error,
      if (senderId != null) 'senderId': senderId,
      if (senderName != null) 'senderName': senderName,
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (completionTokens != null) 'completionTokens': completionTokens,
      if (tokensEstimated) 'tokensEstimated': true,
      if (variants.isNotEmpty) 'variants': variants,
      if (variantIndex != 0) 'variantIndex': variantIndex,
      if (variantUsage.isNotEmpty)
        'variantUsage': [for (final u in variantUsage) u.toJson()],
    };
  }

  ChatMessage copyWith({
    String? content,
    int? variantIndex,
    List<String>? variants,
    List<VariantUsage>? variantUsage,
    String? error,
    int? promptTokens,
    int? completionTokens,
    bool? tokensEstimated,
  }) {
    var v = variants != null ? List<String>.of(variants) : this.variants;
    var idx = variantIndex ?? this.variantIndex;
    var c = content;

    // 切换变体：内容跟随索引
    if (variantIndex != null && content == null && v.isNotEmpty) {
      if (idx >= 0 && idx < v.length) c = v[idx];
    }
    c ??= this.content;

    // 同步：当前变体 = 显示文本（variants 非空时维持不变量）
    if (v.isNotEmpty) {
      v = List<String>.of(v);
      if (idx < 0 || idx >= v.length) idx = idx.clamp(0, v.length - 1);
      v[idx] = c;
    } else {
      idx = 0;
    }

    // variantUsage 与 variants 等长对齐
    var u = variantUsage != null
        ? List<VariantUsage>.of(variantUsage)
        : List<VariantUsage>.of(this.variantUsage);
    while (u.length < v.length) {
      u.add(VariantUsage.empty);
    }
    if (u.length > v.length) u = u.sublist(0, v.length);

    return ChatMessage(
      role: role,
      content: c,
      timestamp: timestamp,
      error: error,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      tokensEstimated: tokensEstimated ?? this.tokensEstimated,
      variants: v,
      variantIndex: idx,
      variantUsage: u,
      senderId: senderId,
      senderName: senderName,
    );
  }
}
