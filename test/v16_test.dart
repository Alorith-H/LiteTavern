import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v0.15.1：设置 - 角色卡市场 - 内容开关（默认关）；v0.44.2 起需先解锁隐藏入口。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.init();
  });

  test('默认关闭：全新安装不显示 NSFW', () {
    expect(AppSettings.showNsfw, isFalse);
  });

  test('开关写入 show_nsfw 键，解锁后重新读取仍保持开启', () async {
    AppSettings.nsfwUnlocked = true;
    AppSettings.showNsfw = true;
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('show_nsfw'), isTrue);

    await AppSettings.init();
    expect(AppSettings.showNsfw, isTrue);
  });

  test('显式关掉后持久化为 false（不是「未设置」）', () async {
    AppSettings.showNsfw = true;
    AppSettings.showNsfw = false;
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('show_nsfw'), isFalse);

    await AppSettings.init();
    expect(AppSettings.showNsfw, isFalse);
  });

  test('旧数据里没有该键时按默认关处理', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'streaming': true,
    });
    await AppSettings.init();
    expect(AppSettings.showNsfw, isFalse);
  });
}
