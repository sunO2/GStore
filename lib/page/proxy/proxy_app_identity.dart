import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:installed_apps/app_info.dart' as ia;
import 'package:installed_apps/installed_apps.dart';
import 'package:path_provider/path_provider.dart';

/// 已安装应用的展示身份：人类可读名称 + 本地图标缓存路径。
///
/// 仅用于「请求域名 / IP」页的应用归属展示；不含业务逻辑，映射失败一律降级。
@immutable
class ProxyAppIdentity {
  const ProxyAppIdentity({
    required this.packageName,
    required this.label,
    this.iconPath,
  });

  /// 包名（原始 key）。
  final String packageName;

  /// 人类可读的应用名（插件缺名时回落包名）。
  final String label;

  /// 已落盘的图标文件路径（不可用 / 未安装 / 非 Android 时为 `null`）。
  final String? iconPath;
}

/// 加载已安装应用列表的测试接缝（默认走 `InstalledApps.getInstalledApps`）。
typedef ProxyInstalledAppsLoader = Future<List<ia.AppInfo>> Function();

/// 图标落盘接缝（返回缓存文件路径；无法落盘返回 `null`，绝不抛）。
typedef ProxyAppIconSaver = Future<String?> Function(
  String packageName,
  Uint8List? iconBytes,
);

/// `packageName → (label, iconPath)` 的惰性、异步、进程级缓存解析器。
///
/// * **惰性**：首次 [ensureLoaded] 才真正查询已安装应用，且只查一次。
/// * **降级**：非 Android / 插件缺失 / 应用未安装 / 图标落盘失败 —— 全部吞掉，
///   [lookup] 返回 `null`，调用方回落到包名 / UID / 「未知应用」。
/// * **不抛**：[ensureLoaded] 永不以异常完成；页面可 `unawaited` 后 `setState`。
class ProxyAppIdentityResolver {
  ProxyAppIdentityResolver({
    ProxyInstalledAppsLoader? loader,
    ProxyAppIconSaver? iconSaver,
    bool? isAndroid,
  })  : _loader = loader ?? _defaultLoader,
        _iconSaver = iconSaver ?? _defaultIconSaver,
        _isAndroid = isAndroid ?? Platform.isAndroid;

  /// 生产单例（页面直接使用）。
  static final ProxyAppIdentityResolver instance = ProxyAppIdentityResolver();

  final ProxyInstalledAppsLoader _loader;
  final ProxyAppIconSaver _iconSaver;
  final bool _isAndroid;

  final Map<String, ProxyAppIdentity> _byPackage = <String, ProxyAppIdentity>{};
  Future<void>? _pending;
  bool _loaded = false;

  /// 是否已完成一次加载尝试（无论成功 / 降级）。
  bool get isLoaded => _loaded;

  /// 确保已加载（幂等）。多次并发调用共享同一次加载。
  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _pending ??= _load();
  }

  /// 同步查询已缓存的应用身份；未加载 / 未命中 → `null`。
  ProxyAppIdentity? lookup(String packageName) => _byPackage[packageName];

  /// 测试接缝：直接注入身份缓存（不触发原生加载）。
  @visibleForTesting
  void debugSeed(Map<String, ProxyAppIdentity> identities) {
    _byPackage
      ..clear()
      ..addAll(identities);
    _loaded = true;
    _pending = null;
  }

  /// 测试接缝：清空缓存并复位加载状态。
  @visibleForTesting
  void debugReset() {
    _byPackage.clear();
    _loaded = false;
    _pending = null;
  }

  Future<void> _load() async {
    try {
      if (!_isAndroid) {
        debugPrint('ProxyAppIdentityResolver: 非 Android 平台，跳过应用身份加载');
        return;
      }
      final apps = await _loader();
      for (final app in apps) {
        final packageName = app.packageName;
        if (packageName.isEmpty) continue;
        String? iconPath;
        try {
          iconPath = await _iconSaver(packageName, app.icon);
        } catch (error) {
          debugPrint(
            'ProxyAppIdentityResolver: 图标处理失败 $packageName - $error',
          );
        }
        final name = app.name.trim();
        _byPackage[packageName] = ProxyAppIdentity(
          packageName: packageName,
          label: name.isEmpty ? packageName : name,
          iconPath: iconPath,
        );
      }
      debugPrint(
        'ProxyAppIdentityResolver: 已加载 ${_byPackage.length} 个应用身份',
      );
    } catch (error) {
      debugPrint('ProxyAppIdentityResolver: 加载已安装应用失败，降级为包名 - $error');
    } finally {
      _loaded = true;
      _pending = null;
    }
  }

  static Future<List<ia.AppInfo>> _defaultLoader() =>
      InstalledApps.getInstalledApps(true, true);

  static Future<String?> _defaultIconSaver(
    String packageName,
    Uint8List? iconBytes,
  ) async {
    if (iconBytes == null || iconBytes.isEmpty) return null;
    try {
      final cacheDir = await getTemporaryDirectory();
      final iconDir = Directory('${cacheDir.path}/proxy_app_icons');
      if (!await iconDir.exists()) {
        await iconDir.create(recursive: true);
      }
      final iconFile = File('${iconDir.path}/$packageName.png');
      await iconFile.writeAsBytes(iconBytes);
      return iconFile.path;
    } catch (error) {
      debugPrint('ProxyAppIdentityResolver: 保存图标失败 $packageName - $error');
      return null;
    }
  }
}
