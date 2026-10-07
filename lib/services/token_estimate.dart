// token 估算与格式化（provider 未返回 usage 时的本地兜底）。

/// 估算 token 数：`ceil(CJK 字符数 * 1.0 + 非 CJK 字符数 / 4)`
///（v0.8.0 上下文占用口径，与占用% / 满压缩判断共用同一函数）。
int estimateTokens(String text) {
  var cjk = 0;
  var other = 0;
  for (final r in text.runes) {
    if (_isCjkChar(r)) {
      cjk++;
    } else {
      other++;
    }
  }
  return (cjk + other / 4).ceil();
}

/// 中文（含 CJK 标点 / 全角字符）判定。
bool _isCjkChar(int r) {
  return (r >= 0x3000 && r <= 0x303F) // CJK 符号与标点
      ||
      (r >= 0x3400 && r <= 0x4DBF) // 扩展 A
      ||
      (r >= 0x4E00 && r <= 0x9FFF) // 基本区
      ||
      (r >= 0xF900 && r <= 0xFAFF) // 兼容表意文字
      ||
      (r >= 0xFF00 && r <= 0xFFEF) // 全角形式
      ||
      r >= 0x20000; // 扩展 B 及以上
}

/// 千分位正则（顶层只编译一次，避免每次调用 new）
final _groupRe = RegExp(r'\B(?=(\d{3})+(?!\d))');

/// 千分位格式化：1234567 → "1,234,567"。
String formatTokenCount(int n) {
  return n.toString().replaceAllMapped(_groupRe, (m) => ',');
}
