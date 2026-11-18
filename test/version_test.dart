import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:litetavern/app_info.dart';

/// 版本号防漂移：关于页展示的 kAppVersion 必须与 pubspec.yaml 的
/// version 一致（发版改一处漏另一处会在此挂掉）。
void main() {
  test('kAppVersion 与 pubspec.yaml 的 version 一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 里找不到 version:');
    expect(kAppVersion, m!.group(1));
  });
}
