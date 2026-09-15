import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/cache/ReadmeCache.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/image/image_disk_cache.dart';
import 'package:gstore/core/service/apk_info_service.dart';
import 'package:gstore/core/service/app_icon_service.dart';
import 'package:gstore/core/service/it_tools_service.dart';

import 'state.dart';

/// 单个缓存条目的描述与清理动作（不依赖 UI 上下文，便于一键/单项复用）。
class _CacheSpec {
  const _CacheSpec({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.clear,
  });

  final String id;
  final String name;
  final String description;
  final String icon;

  /// 清理动作（同步/异步均转 Future）。
  final Future<void> Function() clear;
}

/// 缓存管理领域服务（无 GetX / Riverpod 依赖的纯能力层）。
///
/// 承载：缓存目录扫描与清理、临时文件治理、下载目录扫描与 APK 信息解析、
/// 批量删除。页面 [CacheManageNotifier] 与 Agent 的 cacheManage 工具共用
/// 本服务，避免同一套清理逻辑双份维护。
///
/// 全局复用 [CacheManageService.instance]；测试可 new 独立实例并注入
/// 临时目录替身（[debugCacheDir]/[debugDownloadsDir]），互不污染。
class CacheManageService {
  CacheManageService();

  /// 全局单例（Agent / 页面等无特殊注入需求的调用方复用）。
  static final CacheManageService instance = CacheManageService();

  // ---------- 目录解析（按需缓存，测试可注入临时目录） ----------

  /// 测试注入：应用缓存目录（getTemporaryDirectory 的替身）。
  @visibleForTesting
  Directory? debugCacheDir;

  /// 测试注入：下载目录（getDownloadsDirectory 的替身）。
  @visibleForTesting
  Directory? debugDownloadsDir;

  Future<Directory> _tmpDir() async {
    if (debugCacheDir != null) return debugCacheDir!;
    return getTemporaryDirectory();
  }

  /// 解析下载目录：优先注入，否则取系统公共下载目录。
  Future<Directory> _downloadsDir() async {
    if (debugDownloadsDir != null) return debugDownloadsDir!;
    final dir = await getDownloadsDirectory();
    if (dir != null) return dir;
    // 个别平台无下载目录时回退文档目录
    return getApplicationDocumentsDirectory();
  }

  // ---------- 缓存项注册表 ----------

  late final List<_CacheSpec> _specs = _buildSpecs();

  List<_CacheSpec> _buildSpecs() {
    return [
      // ---- 图片类 ----
      _CacheSpec(
        id: 'cached_network_image',
        name: '网络图片缓存',
        description: '列表/详情图（CachedNetworkImage 磁盘缓存）',
        icon: 'image',
        clear: _clearDir('libCachedImageData'),
      ),
      _CacheSpec(
        id: 'gstore_image_cache',
        name: '自研图片缓存',
        description: 'README / 详情大图字节缓存（gstore_image_cache）',
        icon: 'image',
        clear: () => ImageDiskCache.instance.clear(),
      ),
      // ---- 文档类 ----
      _CacheSpec(
        id: 'readme_cache',
        name: 'README 缓存',
        description: 'GitHub 仓库 README（ETag 条件缓存）',
        icon: 'article',
        clear: () => ReadmeCache.instance.clear(),
      ),
      // ---- 图标类 ----
      _CacheSpec(
        id: 'app_icons',
        name: '已安装应用图标',
        description: '本机应用图标提取缓存（app_icons）',
        icon: 'android',
        clear: () => AppIconService.instance.clearCache(),
      ),
      // ---- 通用缓存 ----
      _CacheSpec(
        id: 'cache_manager',
        name: '通用缓存',
        description: 'CacheManager 内存 + cache.db 磁盘缓存',
        icon: 'database',
        clear: () => CacheManager().clearAll(),
      ),
      // ---- 内存类 ----
      _CacheSpec(
        id: 'channel_memory',
        name: '渠道内存缓存',
        description: '各渠道在内存中的搜索结果缓存',
        icon: 'memory',
        clear: () => ChannelManager.instance.clearCache(),
      ),
      _CacheSpec(
        id: 'metadata_memory',
        name: '元数据缓存',
        description: '应用元数据（info.json，内存 + 偏好设置）',
        icon: 'memory',
        clear: () => MetadataRepository.instance.clearCache(),
      ),
      // ---- 应用资源（可重新生成的本地资源）----
      _CacheSpec(
        id: 'it_tools_bundle',
        name: '开发者工具箱资源',
        description: 'IT Tools 离线包的解压结果；清理后下次进入该页面会重新从资产解压',
        icon: 'widgets',
        clear: () => ItToolsService.clearExtracted(),
      ),
      // ---- 临时文件（受控清理）----
      _CacheSpec(
        id: 'temp_files',
        name: '临时文件',
        description: '临时目录残留文件（自动跳过下载中 .part/.temp）',
        icon: 'cleaning',
        clear: _clearTempResidual,
      ),
    ];
  }

  /// 构造删除临时目录子项的清理动作。
  Future<void> Function() _clearDir(String sub) {
    return () async {
      final tmp = await _tmpDir();
      final dir = Directory('${tmp.path}/$sub');
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    };
  }

  /// 清理临时目录残留：跳过正在下载的分片（.part/.temp）与应用私有子目录
  /// （libCachedImageData 等已由各专项负责），避免影响进行中下载。
  Future<void> _clearTempResidual() async {
    final tmp = await _tmpDir();
    if (!await tmp.exists()) return;
    await for (final entity in tmp.list()) {
      final name = entity.path.split('/').last;
      // 正在下载的分片 / 已由专项缓存的子目录 → 跳过
      if (name.endsWith('.part') ||
          name.endsWith('.temp') ||
          name.startsWith('.part') ||
          name.contains('.part')) {
        continue;
      }
      final reserved = {
        ..._reservedDirs,
        'cache.db',
        'cache.db-journal',
      };
      if (reserved.contains(name)) continue;
      try {
        if (entity is Directory) {
          await entity.delete(recursive: true);
        } else if (entity is File) {
          await entity.delete();
        }
      } catch (e) {
        appLog.warning('CacheManage: 清理临时文件失败 $name - $e');
      }
    }
  }

  // ---------- 分组与大小 ----------

  /// 组定义：标题 + 组内 spec id 列表。
  static const _groupsDef = <(String, List<String>)>[
    ('图片缓存', ['cached_network_image', 'gstore_image_cache']),
    ('文档与图标', ['readme_cache', 'app_icons']),
    ('通用缓存', ['cache_manager']),
    ('内存缓存', ['channel_memory', 'metadata_memory']),
    ('应用资源', ['it_tools_bundle']),
    ('临时文件', ['temp_files']),
  ];

  /// 临时目录下由各专项负责的子目录。
  /// 统计「残留」与清理临时文件时都要排除，避免重复计入 / 误删。
  static const _reservedDirs = {
    'libCachedImageData',
    'gstore_image_cache',
    'readme_cache',
    'app_icons',
  };

  /// 统计全部缓存项占用（字节）。
  ///
  /// 目录遍历是 O(文件数) 的活，而 Dart 是单线程：逐文件 `await length()`
  /// 的续体全部落在调用方（主）isolate 上。实测 5000 个文件约 200ms，
  /// 放在首帧附近必然掉帧。这里整批丢给后台 isolate，并在其中改用同步 API
  /// 一次跑完——既不占 UI 线程，本身也快约 10 倍（5000 文件约 20ms）。
  Future<Map<String, int>> _scanAllSizes() async {
    final tmp = await _tmpDir();

    // 离线包解压目录在文档目录；测试环境可能拿不到（缺平台插件），拿不到就跳过该项
    String? itToolsPath;
    try {
      itToolsPath = (await ItToolsService.extractedDir()).path;
    } catch (_) {
      itToolsPath = null;
    }

    final request = _SizeScanRequest(
      dirTargets: {
        'cached_network_image': '${tmp.path}/libCachedImageData',
        'gstore_image_cache': '${tmp.path}/gstore_image_cache',
        'readme_cache': '${tmp.path}/readme_cache',
        'app_icons': '${tmp.path}/app_icons',
        if (itToolsPath != null) 'it_tools_bundle': itToolsPath,
      },
      fileTargets: {
        'cache_manager': '${tmp.path}/cache.db',
      },
      tmpPath: tmp.path,
      reservedDirs: _reservedDirs,
    );

    try {
      return await compute(_scanSizesInIsolate, request);
    } catch (e) {
      appLog.warning('CacheManage: 后台统计缓存占用失败 - $e');
      return const {};
    }
  }

  /// 统计全部缓存项大小并组装分组。
  ///
  /// 返回 (groups, 总字节)。清理动作不影响内存缓存类目（大小恒 0）。
  Future<(List<CacheGroup>, int)> scanCacheGroups() async {
    final sizeById = await _scanAllSizes();

    // 组装分组
    final groups = <CacheGroup>[];
    for (final (title, ids) in _groupsDef) {
      final items = <CacheItem>[];
      for (final id in ids) {
        final spec = _specs.firstWhere((s) => s.id == id);
        items.add(CacheItem(
          id: spec.id,
          name: spec.name,
          description: spec.description,
          icon: spec.icon,
          size: sizeById[id] ?? 0,
        ));
      }
      if (items.isEmpty) continue;
      groups.add(CacheGroup(title: title, items: items));
    }
    final total = groups.fold(0, (sum, g) => sum + g.totalSize);
    return (groups, total);
  }

  // ---------- 清理动作 ----------

  /// 清理单个缓存项。返回是否找到并执行。
  Future<bool> clearOne(String id) async {
    _CacheSpec? spec;
    for (final s in _specs) {
      if (s.id == id) {
        spec = s;
        break;
      }
    }
    if (spec == null) return false;
    try {
      await spec.clear();
      return true;
    } catch (e) {
      appLog.error('CacheManage: 清理 ${spec.name} 失败 - $e');
      return false;
    }
  }

  /// 清理全部可再生缓存（不含下载文件）。
  Future<void> clearAllCaches() async {
    for (final spec in _specs) {
      try {
        await spec.clear();
      } catch (e) {
        appLog.error('CacheManage: 一键清理 ${spec.name} 失败 - $e');
      }
    }
  }

  /// 当前可清理的缓存类别清单（供 Agent 等外部调用方枚举）。
  /// 返回 (id, 展示名, 当前占用字节)。
  Future<List<(String, String, int)>> cacheCategorySizes() async {
    final sizeById = await _scanAllSizes();
    return [
      for (final spec in _specs) (spec.id, spec.name, sizeById[spec.id] ?? 0),
    ];
  }

  /// 按展示名批量清理缓存（Agent 多选结果回传后调用）。
  /// [names] 用户勾选的缓存类别展示名；返回清理成功的数量。
  Future<int> clearByNames(List<String> names) async {
    if (names.isEmpty) return 0;
    var success = 0;
    for (final spec in _specs) {
      if (!names.contains(spec.name)) continue;
      try {
        await spec.clear();
        success++;
      } catch (e) {
        appLog.error('CacheManage: 清理 ${spec.name} 失败 - $e');
      }
    }
    return success;
  }

  // ---------- 已下载文件清理 ----------

  /// APK 解析结果缓存（path → (appName, packageName, versionName, iconBytes)）。
  /// 避免列表刷新时对同一 APK 反复走 MethodChannel。
  final Map<String, (String?, String?, String?, Uint8List?)> _apkInfoCache = {};

  /// 刷新"已下载文件"列表：列出下载目录下的全部文件。
  /// 对 .apk 文件尝试解析应用名/包名/版本/图标（带缓存，失败回退文件名）。
  ///
  /// 返回 (条目列表, 总字节)。条目按修改时间倒序（最近下载在前）。
  Future<(List<DownloadedFileItem>, int)> scanDownloads() async {
    final dir = await _downloadsDir();
    final items = <DownloadedFileItem>[];
    var total = 0;
    if (await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.split('/').last;
        // 跳过下载残留（.part/.temp/下载中临时文件）
        if (name.endsWith('.part') ||
            name.endsWith('.temp') ||
            name.contains('.part')) {
          continue;
        }
        int size;
        try {
          size = await entity.length();
        } catch (_) {
          continue;
        }
        if (size <= 0) continue;
        total += size;
        final stat = await entity.stat();

        final isApk = name.toLowerCase().endsWith('.apk');
        final apkInfo = isApk ? await _parseApkInfo(entity.path) : null;
        items.add(DownloadedFileItem(
          fileName: name,
          filePath: entity.path,
          size: size,
          modifiedAt: stat.modified,
          isApk: isApk,
          apkAppName: apkInfo?.$1,
          apkPackageName: apkInfo?.$2,
          apkVersionName: apkInfo?.$3,
          apkIconBytes: apkInfo?.$4,
        ));
      }
    }
    items.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return (items, total);
  }

  /// 解析单个 APK（带缓存）。返回 (appName, packageName, versionName, iconBytes)。
  Future<(String?, String?, String?, Uint8List?)?> _parseApkInfo(
    String path,
  ) async {
    final cached = _apkInfoCache[path];
    if (cached != null) return cached;
    try {
      final (info, iconBytes) = await ApkInfoService.instance.parseApk(path);
      if (info == null) return null;
      final result = (
        info.appName,
        info.packageName,
        info.versionName,
        iconBytes,
      );
      _apkInfoCache[path] = result;
      return result;
    } catch (e) {
      appLog.warning('CacheManage: 解析 APK 信息失败 $path - $e');
      return null;
    }
  }

  /// 批量删除选中的下载文件。
  ///
  /// 返回删除成功条数；单条失败（如文件被占用）不影响其余。
  Future<int> deleteDownloads(List<String> filePaths) async {
    if (filePaths.isEmpty) return 0;
    var success = 0;
    for (final path in filePaths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
        _apkInfoCache.remove(path);
        success++;
      } catch (e) {
        appLog.warning('CacheManage: 删除下载文件失败 $path - $e');
      }
    }
    return success;
  }

  /// 格式化字节数（供 UI 展示）。
  String formatSize(int bytes) => byteSize(bytes);
}

/// 后台统计入参（只带可跨 isolate 传递的基础数据）。
class _SizeScanRequest {
  const _SizeScanRequest({
    required this.dirTargets,
    required this.fileTargets,
    required this.tmpPath,
    required this.reservedDirs,
  });

  /// 需要整体统计占用的目录：spec id → 绝对路径
  final Map<String, String> dirTargets;

  /// 需要统计单个文件的项：spec id → 绝对路径
  final Map<String, String> fileTargets;

  /// 临时目录（「残留」统计的根）
  final String tmpPath;

  /// 残留统计要排除的顶层子目录
  final Set<String> reservedDirs;
}

/// 在后台 isolate 中统计全部磁盘占用。
///
/// 刻意用同步 API：本函数跑在独立 isolate 上，不阻塞 UI；
/// 同步遍历免去了「每个文件一次异步往返」，实测比异步版快约 10 倍。
Map<String, int> _scanSizesInIsolate(_SizeScanRequest req) {
  final result = <String, int>{};

  for (final entry in req.dirTargets.entries) {
    result[entry.key] = _directorySizeSync(entry.value);
  }
  for (final entry in req.fileTargets.entries) {
    result[entry.key] = _fileSizeSync(entry.value);
  }
  result['temp_files'] = _tempResidualSizeSync(req.tmpPath, req.reservedDirs);
  return result;
}

int _directorySizeSync(String path) {
  try {
    final dir = Directory(path);
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        total += entity.lengthSync();
      } catch (_) {}
    }
    return total;
  } catch (_) {
    return 0;
  }
}

int _fileSizeSync(String path) {
  try {
    final file = File(path);
    return file.existsSync() ? file.lengthSync() : 0;
  } catch (_) {
    return 0;
  }
}

/// 统计临时目录残留（与 [CacheManageService._clearTempResidual] 相同的排除规则）。
int _tempResidualSizeSync(String tmpPath, Set<String> reservedDirs) {
  try {
    final tmp = Directory(tmpPath);
    if (!tmp.existsSync()) return 0;
    var total = 0;
    for (final entity in tmp.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      final name = path.split('/').last;
      if (name.endsWith('.part') ||
          name.endsWith('.temp') ||
          name.contains('.part')) {
        continue;
      }
      final parts = path.replaceAll('\\', '/').split('/');
      if (parts.any(reservedDirs.contains)) continue;
      try {
        total += entity.lengthSync();
      } catch (_) {}
    }
    return total;
  } catch (_) {
    return 0;
  }
}
