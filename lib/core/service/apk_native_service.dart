import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';

/// 原生 APK 信息（Android PackageManager.getPackageArchiveInfo）
class NativeApkInfo {
  /// 真实包名
  final String packageName;

  /// 版本名
  final String versionName;

  /// 版本码
  final int versionCode;

  /// 应用名称
  final String appName;

  /// 图标 PNG 字节（可能为空）
  final Uint8List? iconBytes;

  NativeApkInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.appName,
    this.iconBytes,
  });
}

/// Android 原生 APK 解析服务
/// 通过 MethodChannel 调用 PackageManager.getPackageArchiveInfo
/// 比 Rust 解析更原生可靠，且能直接提取图标
class ApkNativeService {
  ApkNativeService._();

  static final ApkNativeService instance = ApkNativeService._();

  static const MethodChannel _channel = MethodChannel('gstore/apk_info');

  /// 是否支持（仅 Android 平台）
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 解析 APK：提取包名/应用名/版本/图标（PNG 字节）
  Future<NativeApkInfo?> parseApk(String apkPath) async {
    if (!isSupported) return null;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'parseApk',
        {'apkPath': apkPath},
      );
      if (result == null) return null;
      final packageName = (result['packageName'] as String?) ?? '';
      if (packageName.isEmpty) return null;

      return NativeApkInfo(
        packageName: packageName,
        versionName: (result['versionName'] as String?) ?? '',
        versionCode: (result['versionCode'] as int?) ?? 0,
        appName: (result['appName'] as String?) ?? '',
        iconBytes: result['iconBytes'] is Uint8List
            ? (result['iconBytes'] as Uint8List)
            : null,
      );
    } catch (e) {
      appLog.error('ApkNativeService: 解析 APK 失败 - $e');
      return null;
    }
  }
}
