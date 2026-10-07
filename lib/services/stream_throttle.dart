import 'dart:async';

/// 流式文本节流缓冲（v0.8.0 从 chat_screen 抽出，聊天页与 AI 创建器共用）。
///
/// [enqueue] 收流式 delta：距上次刷新 ≥ [minIntervalMs] 立即 flush，
/// 否则合并进一个定时器统一 flush —— 一帧多个 token 只回调一次，
/// 禁止每个 token 全列表 rebuild。
class StreamThrottle {
  StreamThrottle({required this.minIntervalMs, required this.onFlush});

  /// 刷新最小间隔（ms）
  final int minIntervalMs;

  /// flush 时把缓冲文本交给调用方（调用方负责 setState / 落盘）
  final void Function(String text) onFlush;

  String _buf = '';
  Timer? _timer;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  bool get pending => _buf.isNotEmpty;

  void enqueue(String delta) {
    if (_disposed) return;
    _buf += delta;
    final since = DateTime.now().difference(_last).inMilliseconds;
    if (since >= minIntervalMs) {
      flush();
    } else {
      _timer ??= Timer(Duration(milliseconds: minIntervalMs - since), flush);
    }
  }

  /// 立即把缓冲刷给 onFlush（停止 / 流结束时保证不丢字）。
  void flush() {
    _timer?.cancel();
    _timer = null;
    _last = DateTime.now();
    if (_disposed || _buf.isEmpty) return;
    final text = _buf;
    _buf = '';
    onFlush(text);
  }

  /// 丢弃缓冲（重新生成前清场）。
  void reset() {
    _timer?.cancel();
    _timer = null;
    _buf = '';
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _buf = '';
  }
}
