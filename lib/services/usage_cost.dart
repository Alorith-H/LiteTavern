/// 用量费用估算（v0.35.0）。
///
/// 只做「按用户填的单价估算」，不联网查价、不猜服务商定价：
/// 单价留空（0）就不显示金额，只显示 token。
class TokenPrice {
  /// 每 100 万输入 token 的价格。
  final double inputPerMillion;

  /// 每 100 万输出 token 的价格。
  final double outputPerMillion;

  /// 每 100 万「缓存命中」输入 token 的价格（留空则跟输入价一样）。
  final double cachedInputPerMillion;

  const TokenPrice({
    this.inputPerMillion = 0,
    this.outputPerMillion = 0,
    this.cachedInputPerMillion = 0,
  });

  static const TokenPrice free = TokenPrice();

  /// 有没有填过价格（只要输入或输出有一个 > 0 就算）。
  bool get configured => inputPerMillion > 0 || outputPerMillion > 0;

  double get effectiveCachedPrice =>
      cachedInputPerMillion > 0 ? cachedInputPerMillion : inputPerMillion;
}

/// 一次统计范围内的用量与估算费用。
class UsageCost {
  final int inputTokens;
  final int outputTokens;

  /// 其中被缓存命中的输入 token（按前缀估算，可能为 0）。
  final int cachedInputTokens;
  final TokenPrice price;

  const UsageCost({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.price = TokenPrice.free,
  });

  int get uncachedInputTokens =>
      (inputTokens - cachedInputTokens).clamp(0, inputTokens);

  /// 缓存命中占输入的比例（0–1）；没有输入时返回 0。
  double get cacheHitRatio =>
      inputTokens <= 0 ? 0 : (cachedInputTokens / inputTokens).clamp(0.0, 1.0);

  /// 估算总花费（货币单位取决于用户填的价格单位）。
  double get total {
    if (!price.configured) return 0;
    final cachedCost =
        cachedInputTokens / 1000000 * price.effectiveCachedPrice;
    final uncachedCost =
        uncachedInputTokens / 1000000 * price.inputPerMillion;
    final outputCost = outputTokens / 1000000 * price.outputPerMillion;
    return cachedCost + uncachedCost + outputCost;
  }

  /// 如果这些缓存命中的 token 全按未命中价算，要多花多少。
  double get cacheSavings {
    if (!price.configured || cachedInputTokens <= 0) return 0;
    final noCache = cachedInputTokens / 1000000 * price.inputPerMillion;
    final withCache = cachedInputTokens / 1000000 * price.effectiveCachedPrice;
    return (noCache - withCache).clamp(0.0, double.infinity);
  }

  UsageCost merge(UsageCost other) => UsageCost(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
        price: other.price.configured ? other.price : price,
      );
}

/// 金额格式化：很小的时候给 4 位小数，否则 2 位。
String formatMoney(double value) {
  if (value <= 0) return '0';
  // 小于 0.0001 元时不要显示成 0.0000，直接写成「<0.0001」。
  if (value < 0.0001) return '<0.0001';
  if (value < 0.01) return value.toStringAsFixed(4);
  return value.toStringAsFixed(2);
}
