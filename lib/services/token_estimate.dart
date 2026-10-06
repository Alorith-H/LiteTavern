// token 估算与格式化（provider 未返回 usage 时的本地兜底）。

/// 估算 token 数：`ceil(中文字符数 * 0.6 + 其余字符数 * 0.25)`。
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
  return (cjk * 0.6 + other * 0.25).ceil();
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

/// 千分位格式化：1234567 → "1,234,567"。
String formatTokenCount(int n) {
  return n
      .toString()
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
}
