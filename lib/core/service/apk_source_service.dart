import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';

/// 已安装应用 APK 路径（sourceDir）获取服务
///
/// installed_apps 插件的 AppInfo 不含 sourceDir/apkPath 字段，
/// 故通过自定义 MethodChannel 调用 PackageManager.getApplicationInfo(...).sourceDir
/// 获取已安装应用的 APK 文件路径（供 SDK 分析使用）。
class ApkSourceService {
  ApkSourceService._();

  static final ApkSourceService instance = ApkSourceService._();

  static const MethodChannel _channel = MethodChannel('gstore/apk_source');

  /// 测试用：注入合成权限列表，跳过平台通道调用。
  /// 传 null 恢复真实通道调用。
  List<String>? _debugPermissions;

  /// 是否支持（仅 Android 平台）
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 获取已安装应用的 sourceDir（APK 路径），失败/不支持时返回 null
  Future<String?> getSourceDir(String packageName) async {
    if (!isSupported || packageName.isEmpty) return null;
    try {
      final result = await _channel.invokeMethod<String>('getSourceDir', {
        'packageName': packageName,
      });
      return (result == null || result.isEmpty) ? null : result;
    } catch (e) {
      appLog.error('ApkSourceService: 获取 sourceDir 失败 - $e');
      return null;
    }
  }

  /// 获取已安装应用声明的权限列表（PackageManager.GET_PERMISSIONS），
  /// 失败/不支持时返回空列表
  Future<List<String>> getPermissions(String packageName) async {
    final debug = _debugPermissions;
    if (debug != null) return debug;
    if (!isSupported || packageName.isEmpty) return const [];
    try {
      final result = await _channel.invokeListMethod<String>('getPermissions', {
        'packageName': packageName,
      });
      return result ?? const [];
    } catch (e) {
      appLog.error('ApkSourceService: 获取权限列表失败 - $e');
      return const [];
    }
  }

  /// 测试用：注入合成权限列表（null 恢复真实通道调用）。
  @visibleForTesting
  void debugSetPermissions(List<String>? permissions) {
    _debugPermissions = permissions;
  }
}
