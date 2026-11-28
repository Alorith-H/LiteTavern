// 角色卡市场的第三方内容说明（v0.45.0）。
//
// 市场里的角色卡全部来自 Chub.ai 等第三方平台，内容由第三方用户上传，
// 与本软件及作者无关。首次进入市场前必须先看到这份说明并确认；
// 记住的是「说明的版本号」而不是一个 bool —— 以后文案有实质变化时把
// [MarketDisclaimer.currentVersion] 加 1，已确认过的用户会重新看到提示。
import 'package:shared_preferences/shared_preferences.dart';

/// 角色卡市场免责声明的确认状态（本地存储，不上传）。
abstract final class MarketDisclaimer {
  /// 说明文案的版本。改动免责声明实质内容时 +1。
  static const int currentVersion = 1;

  /// 已确认的版本号；没有这个键表示从未确认。
  static const String ackKey = 'market_disclaimer_ack';

  /// 确认时间（毫秒时间戳），仅用于设置页展示与排查问题。
  static const String ackAtKey = 'market_disclaimer_ack_at';

  static SharedPreferences? _sp;

  static Future<SharedPreferences> _prefs() async =>
      _sp ??= await SharedPreferences.getInstance();

  /// 测试用：清掉缓存句柄（配合 SharedPreferences.setMockInitialValues）。
  static void resetForTest() => _sp = null;

  /// 是否已确认过当前（或更新）版本的说明。
  static Future<bool> hasAccepted() async =>
      await acceptedVersion() >= currentVersion;

  /// 已确认的版本号；从未确认返回 0。
  static Future<int> acceptedVersion() async {
    final prefs = await _prefs();
    return prefs.getInt(ackKey) ?? 0;
  }

  /// 确认时间；从未确认返回 null。
  static Future<DateTime?> acceptedAt() async {
    final prefs = await _prefs();
    final ms = prefs.getInt(ackAtKey);
    if (ms == null || ms <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 记下「已阅读并了解当前版本的说明」。
  static Future<void> accept() async {
    final prefs = await _prefs();
    await prefs.setInt(ackKey, currentVersion);
    await prefs.setInt(ackAtKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// 清掉确认状态：下次进入角色卡市场会重新提示。
  static Future<void> reset() async {
    final prefs = await _prefs();
    await prefs.remove(ackKey);
    await prefs.remove(ackAtKey);
  }
}
