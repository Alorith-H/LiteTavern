/// 连续点击解锁（v0.44.2 的隐藏入口用）。
///
/// 规则：在 [window] 时间内累计点满 [required] 下算解锁；间隔超过窗口就重新计数。
/// 把时间源抽出来，方便测试里注入假时钟。
class TapUnlock {
  TapUnlock({
    this.required = 5,
    this.window = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 需要连点几下。
  final int required;

  /// 两次点击之间允许的最大间隔。
  final Duration window;

  final DateTime Function() _clock;

  int _taps = 0;
  DateTime? _last;

  /// 当前已经累计的点击数（测试用）。
  int get taps => _taps;

  /// 记一次点击。累计达到 [required] 时返回 true 并清零。
  bool tap() {
    final now = _clock();
    final last = _last;
    if (last == null || now.difference(last) > window) {
      _taps = 0;
    }
    _last = now;
    _taps += 1;
    if (_taps < required) return false;
    _taps = 0;
    return true;
  }

  void reset() {
    _taps = 0;
    _last = null;
  }
}
