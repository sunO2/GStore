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

/// 图标缓存清理接缝：删除 [keepPackageNames] 之外的孤儿图标文件。
///
/// best-effort：实现不得抛（调用方另有 try/catch 兜底）。
typedef ProxyAppIconCacheCleaner = Future<void> Function(
  Set<String> keepPackageNames,
);

/// `packageName → (label, iconPath)` 的惰性、异步、进程级缓存解析器。
///
/// * **惰性**：首次 [ensureLoaded] 才真正查询已安装应用，且只查一次；
/// * **图标按需 / 批量**：默认只加载元数据（名称），图标经 [resolveIcons] /
///   [resolveIcon] 按需批量落盘，**绝不**在加载循环里逐个同步写盘；
/// * **清理 / 重扫**：[rescan] 重新查询并清理临时缓存，[cleanupIconCache] 可显式清理；
/// * **降级**：非 Android / 插件缺失 / 应用未安装 / 图标落盘失败 —— 全部吞掉，
///   [lookup] 返回 `null` 或 `iconPath == null`，调用方回落到包名 / UID /「未知应用」；
/// * **不抛**：[ensureLoaded] 永不以异常完成；页面可 `unawaited` 后 `setState`。
class ProxyAppIdentityResolver {
  ProxyAppIdentityResolver({
    ProxyInstalledAppsLoader? loader,
    ProxyAppIconSaver? iconSaver,
    ProxyAppIconCacheCleaner? iconCacheCleaner,
    bool? isAndroid,
    int iconBatchSize = 8,
  })  : _loader = loader ?? _defaultLoader,
        _iconSaver = iconSaver ?? _defaultIconSaver,
        _iconCacheCleaner = iconCacheCleaner ?? _defaultIconCacheCleaner,
        _isAndroid = isAndroid ?? Platform.isAndroid,
        _iconBatchSize = iconBatchSize <= 0 ? 1 : iconBatchSize,
        // 仅当使用生产默认图标落盘时，才认为本实例「拥有」磁盘缓存并可自动清理；
        // 注入自定义 saver 的测试 / 宿主自行管理缓存，避免误删。
        _ownsDiskCache = iconSaver == null;

  /// 生产单例（页面直接使用）。
  static final ProxyAppIdentityResolver instance = ProxyAppIdentityResolver();

  final ProxyInstalledAppsLoader _loader;
  final ProxyAppIconSaver _iconSaver;
  final ProxyAppIconCacheCleaner _iconCacheCleaner;
  final bool _isAndroid;
  final int _iconBatchSize;
  final bool _ownsDiskCache;

  /// `packageName → (label, iconPath=null)` 元数据缓存。
  final Map<String, ProxyAppIdentity> _byPackage = <String, ProxyAppIdentity>{};

  /// 已尝试解析的图标结果（存在即「已尝试」，含失败 `null`）。
  final Map<String, String?> _iconPaths = <String, String?>{};

  /// 元数据阶段保留的图标原始字节，供按需落盘（仅加载后需要时使用）。
  final Map<String, Uint8List?> _iconBytes = <String, Uint8List?>{};

  /// 同一包的并发解析去重。
  final Map<String, Future<String?>> _iconFutures = <String, Future<String?>>{};

  Future<void>? _pending;
  bool _loaded = false;

  /// 是否已完成一次加载尝试（无论成功 / 降级）。
  bool get isLoaded => _loaded;

  /// 确保元数据已加载（幂等）。
  ///
  /// [resolveIcons] 为 `true`（默认）时，加载后批量解析全部已安装应用的图标；
  /// 为 `false` 时仅加载名称，图标交由 [resolveIcons] / [resolveIcon] 按需解析。
  Future<void> ensureLoaded({bool resolveIcons = true}) async {
    if (!_loaded) {
      await (_pending ??= _loadMetadata());
    }
    if (resolveIcons) {
      await this.resolveIcons(_byPackage.keys);
    }
  }

  /// 同步查询已缓存的应用身份；未加载 / 未命中 → `null`。
  ProxyAppIdentity? lookup(String packageName) {
    final identity = _byPackage[packageName];
    if (identity == null) return null;
    if (!_iconPaths.containsKey(packageName)) return identity;
    return ProxyAppIdentity(
      packageName: identity.packageName,
      label: identity.label,
      iconPath: _iconPaths[packageName],
    );
  }

  /// 按需解析单个包的图标并落盘（结果缓存；并发去重；失败降级 `null`）。
  Future<String?> resolveIcon(String packageName) {
    if (_iconPaths.containsKey(packageName)) {
      return Future<String?>.value(_iconPaths[packageName]);
    }
    final existing = _iconFutures[packageName];
    if (existing != null) return existing;
    if (!_isAndroid || !_byPackage.containsKey(packageName)) {
      return Future<String?>.value(null);
    }
    final future = _saveIcon(packageName);
    _iconFutures[packageName] = future;
    return future;
  }

  /// 按需 / 批量解析若干包的图标；按 [batchSize]（默认 8）分批并发，避免
  /// 逐个同步写盘与无界并发。
  ///
  /// 返回本次新解析的 `packageName → path`（已解析过的包不在结果中）。
  Future<Map<String, String?>> resolveIcons(
    Iterable<String> packageNames, {
    int? batchSize,
  }) async {
    final size = (batchSize ?? _iconBatchSize) < 1 ? 1 : (batchSize ?? _iconBatchSize);
    final targets = packageNames
        .where((p) =>
            p.isNotEmpty &&
            _byPackage.containsKey(p) &&
            !_iconPaths.containsKey(p))
        .toSet()
        .toList(growable: false);

    final resolved = <String, String?>{};
    for (var i = 0; i < targets.length; i += size) {
      final end = (i + size) > targets.length ? targets.length : i + size;
      final batch = targets.sublist(i, end);
      final paths = await Future.wait(batch.map(resolveIcon));
      for (var j = 0; j < batch.length; j++) {
        resolved[batch[j]] = paths[j];
      }
    }
    return resolved;
  }

  /// 重扫：清空缓存 → 重新查询已安装应用 → （可选）清理临时缓存。
  Future<void> rescan({bool resolveIcons = true, bool cleanCache = true}) async {
    _reset();
    await ensureLoaded(resolveIcons: resolveIcons);
    if (cleanCache) {
      await cleanupIconCache();
    }
  }

  /// 清理临时缓存中的孤儿图标（保留 [keepPackages] 或当前已加载的包集合）。
  ///
  /// best-effort：清理失败不影响主流程，绝不抛出。
  Future<void> cleanupIconCache({Set<String>? keepPackages}) async {
    try {
      await _iconCacheCleaner(keepPackages ?? _byPackage.keys.toSet());
    } catch (error) {
      debugPrint('ProxyAppIdentityResolver: 清理图标缓存失败 - $error');
    }
  }

  /// 测试接缝：直接注入身份缓存（不触发原生加载）。
  @visibleForTesting
  void debugSeed(Map<String, ProxyAppIdentity> identities) {
    _byPackage
      ..clear()
      ..addAll(<String, ProxyAppIdentity>{
        for (final entry in identities.entries)
          entry.key: ProxyAppIdentity(
            packageName: entry.value.packageName,
            label: entry.value.label,
          ),
      });
    _iconPaths
      ..clear()
      ..addAll(<String, String?>{
        for (final entry in identities.entries) entry.key: entry.value.iconPath,
      });
    _iconBytes.clear();
    _iconFutures.clear();
    _loaded = true;
    _pending = null;
  }

  /// 测试接缝：清空缓存并复位加载状态。
  @visibleForTesting
  void debugReset() => _reset();

  void _reset() {
    _byPackage.clear();
    _iconPaths.clear();
    _iconBytes.clear();
    _iconFutures.clear();
    _loaded = false;
    _pending = null;
  }

  Future<String?> _saveIcon(String packageName) async {
    String? path;
    try {
      path = await _iconSaver(packageName, _iconBytes[packageName]);
    } catch (error) {
      debugPrint('ProxyAppIdentityResolver: 图标处理失败 $packageName - $error');
    }
    _iconPaths[packageName] = path;
    _iconFutures.remove(packageName);
    return path;
  }

  Future<void> _loadMetadata() async {
    try {
      if (!_isAndroid) {
        debugPrint('ProxyAppIdentityResolver: 非 Android 平台，跳过应用身份加载');
        return;
      }
      final apps = await _loader();
      for (final app in apps) {
        final packageName = app.packageName;
        if (packageName.isEmpty) continue;
        final name = app.name.trim();
        _byPackage[packageName] = ProxyAppIdentity(
          packageName: packageName,
          label: name.isEmpty ? packageName : name,
        );
        _iconBytes[packageName] = app.icon;
      }
      debugPrint(
        'ProxyAppIdentityResolver: 已加载 ${_byPackage.length} 个应用身份（元数据）',
      );
      // 生产路径：顺带清理上次运行遗留的孤儿图标（注入 saver 的宿主自行管理）。
      if (_ownsDiskCache) {
        await cleanupIconCache();
      }
    } catch (error) {
      debugPrint('ProxyAppIdentityResolver: 加载已安装应用失败，降级为包名 - $error');
    } finally {
      _loaded = true;
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

  /// 生产默认清理器：删除 `proxy_app_icons` 目录下不在 [keep] 中的 `.png`。
  static Future<void> _defaultIconCacheCleaner(Set<String> keep) async {
    if (!Platform.isAndroid) return;
    try {
      final cacheDir = await getTemporaryDirectory();
      final iconDir = Directory('${cacheDir.path}/proxy_app_icons');
      if (!await iconDir.exists()) return;
      await for (final entity in iconDir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        if (name.isEmpty) continue;
        final packageName =
            name.endsWith('.png') ? name.substring(0, name.length - 4) : name;
        if (keep.contains(packageName)) continue;
        try {
          await entity.delete();
        } catch (_) {
          // best-effort：单个文件删除失败不影响其它。
        }
      }
    } catch (error) {
      debugPrint('ProxyAppIdentityResolver: 清理图标缓存目录失败 - $error');
    }
  }
}
