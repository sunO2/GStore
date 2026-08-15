import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:gstore/core/logger/LogManager.dart';

/// 应用版本服务：从平台包信息读取实际版本（package_info_plus）
///
/// 惰性加载 + 内存缓存；非 Android/测试环境（MissingPluginException 等）→ null。
/// versionName = pubspec 的 build-name（Android versionName），
/// versionCode = pubspec 的 build-number（Android versionCode）。
class AppVersionService {
  AppVersionService._();

  static String? _versionName;
  static int? _versionCode;

  /// 应用版本名（如 1.0.25）；获取失败（测试环境等）→ null
  static Future<String?> versionName() async {
    if (_versionName != null) return _versionName;
    try {
      final info = await PackageInfo.fromPlatform();
      _versionName = info.version;
      _versionCode = int.tryParse(info.buildNumber);
      return _versionName;
    } catch (e) {
      appLog.error('AppVersionService: 获取版本失败 - $e');
      return null;
    }
  }

  /// 应用版本号（build number）；未获取到时 → null
  static Future<int?> versionCode() async {
    await versionName(); // 触发缓存
    return _versionCode;
  }

  /// 测试重置（清除内存缓存）
  @visibleForTesting
  static void resetForTest() {
    _versionName = null;
    _versionCode = null;
  }
}
