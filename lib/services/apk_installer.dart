import 'dart:io';

import 'package:flutter/services.dart';

/// 打开系统安装界面失败。
class ApkInstallException implements Exception {
  const ApkInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 系统还没允许本应用安装 APK（Android 8.0+ 需要在设置里打开一次）。
class ApkInstallPermissionException extends ApkInstallException {
  const ApkInstallPermissionException([super.message = '系统还没允许 LiteTavern 安装应用']);
}

/// 调起 Android 系统安装器（通过 MainActivity 的 `litetavern/installer` 通道）。
///
/// 只用平台通道，不引入 open_filex 之类的依赖；APK 放在缓存目录，
/// 由 FileProvider 授权给系统安装器读取。
class ApkInstaller {
  ApkInstaller({this.channel = const MethodChannel(_channelName)});

  static const String _channelName = 'litetavern/installer';

  final MethodChannel channel;

  /// 当前是否已允许安装 APK。通道不可用时当作允许，让安装器自己报错。
  Future<bool> canInstall() async {
    try {
      return await channel.invokeMethod<bool>('canInstallApk') ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  /// 打开「安装未知应用」里本应用那一页，让用户自己打开开关。
  Future<void> openInstallSettings() async {
    try {
      await channel.invokeMethod<bool>('openInstallSettings');
    } on MissingPluginException {
      throw const ApkInstallException('当前平台不支持这个设置页，请到系统设置里手动允许安装');
    } on PlatformException catch (e) {
      throw ApkInstallException(e.message ?? '打不开安装设置');
    }
  }

  /// 打开系统安装界面。抛 [ApkInstallException]（中文文案）。
  Future<void> install(File apk) async {
    if (!apk.existsSync()) {
      throw const ApkInstallException('安装包不存在，请重新下载');
    }
    try {
      await channel.invokeMethod<bool>('installApk', {'path': apk.path});
    } on MissingPluginException {
      throw const ApkInstallException('当前平台不支持直接安装，请用文件管理器打开 APK');
    } on PlatformException catch (e) {
      if (e.code == 'need_permission') {
        throw ApkInstallPermissionException(
          e.message ?? '系统还没允许 LiteTavern 安装应用',
        );
      }
      throw ApkInstallException(e.message ?? '无法打开系统安装界面');
    }
  }
}
