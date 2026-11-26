import 'dart:io';

import 'package:flutter/services.dart';

/// 系统 APK 安装器入口（替代 app_installer 插件）。
///
/// 只负责拉起系统安装界面；安装结果仍由系统的 PACKAGE_ADDED /
/// PACKAGE_REPLACED 广播或 InstallerBridge 事件通道回传。
class AppInstallerChannel {
  AppInstallerChannel._();

  static const MethodChannel _channel = MethodChannel('gstore/app_installer');

  static Future<void> installApk(String path) async {
    // 与旧 app_installer 插件保持一致：测试/桌面宿主无该通道时直接 no-op。
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('installApk', <String, Object?>{
      'path': path,
    });
  }
}
