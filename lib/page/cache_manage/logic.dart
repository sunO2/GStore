import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/cache/ReadmeCache.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/image/image_disk_cache.dart';
import 'package:gstore/core/service/apk_info_service.dart';
import 'package:gstore/core/service/app_icon_service.dart';

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

/// 缓存管理逻辑。
///
/// 以“组”组织缓存项：图片类/文档类/图标类/通用缓存/内存类/临时文件。
/// 全部缓存均可单独清理或一键清理，均为可再生的缓存数据，
/// 不会触碰已下载的 APK 与用户收藏。
class CacheManageLogic extends GetxController {
  final CacheManageState state = CacheManageState();

  @override
  void onInit() {
    super.onInit();
    reload();
    loadDownloads();
  }

  // ---------- 缓存目录解析（按需缓存，测试可注入临时目录） ----------

  /// 测试注入：应用缓存目录（getTemporaryDirectory 的替身）。
  @visibleForTesting
  Directory? debugCacheDir;

  Future<Directory> _tmpDir() async {
    if (debugCacheDir != null) return debugCacheDir!;
    return getTemporaryDirectory();
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
        'libCachedImageData',
        'gstore_image_cache',
        'readme_cache',
        'app_icons',
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
    ('临时文件', ['temp_files']),
  ];

  /// 统计全部缓存项大小并组装分组（loading 置位在调用方）。
  Future<void> reload() async {
    state.loading.value = true;
    try {
      final tmp = await _tmpDir();

      // 并行统计各项大小
      final sizeJobs = <Future<int>>[];
      for (final spec in _specs) {
        sizeJobs.add(_specSize(spec, tmp));
      }
      final sizes = await Future.wait(sizeJobs);
      final sizeById = <String, int>{};
      for (var i = 0; i < _specs.length; i++) {
        sizeById[_specs[i].id] = sizes[i];
      }

      // 组装分组
      final groups = <CacheGroup>[];
      for (final (title, ids) in _groupsDef) {
        final items = <CacheItem>[];
        for (final id in ids) {
          final spec = _specs.firstWhere((s) => s.id == id);
          final item = CacheItem(
            id: spec.id,
            name: spec.name,
            description: spec.description,
            icon: spec.icon,
          )..size = sizeById[id] ?? 0;
          items.add(item);
        }
        if (items.isEmpty) continue;
        groups.add(CacheGroup(title: title, items: items));
      }

      state.groups.value = groups;
      state.totalSize.value =
          groups.fold(0, (sum, g) => sum + g.totalSize);
    } catch (e) {
      appLog.error('CacheManage: 统计缓存大小失败 - $e');
      state.groups.value = [];
      state.totalSize.value = 0;
    } finally {
      state.loading.value = false;
    }
  }

  Future<int> _specSize(_CacheSpec spec, Directory tmp) async {
    try {
      switch (spec.id) {
        case 'cached_network_image':
          return await directorySize(Directory('${tmp.path}/libCachedImageData'));
        case 'gstore_image_cache':
          return await directorySize(Directory('${tmp.path}/gstore_image_cache'));
        case 'readme_cache':
          return await directorySize(Directory('${tmp.path}/readme_cache'));
        case 'app_icons':
          return await directorySize(Directory('${tmp.path}/app_icons'));
        case 'cache_manager':
          final dbFile = File('${tmp.path}/cache.db');
          var total = 0;
          if (await dbFile.exists()) {
            try {
              total += await dbFile.length();
            } catch (_) {}
          }
          return total;
        case 'channel_memory':
        case 'metadata_memory':
          // 内存缓存：不计磁盘大小（展示文案提示），按 0 处理
          return 0;
        case 'temp_files':
          return await _tempResidualSize(tmp);
        default:
          return 0;
      }
    } catch (e) {
      appLog.warning('CacheManage: 统计 ${spec.name} 失败 - $e');
      return 0;
    }
  }

  /// 统计临时目录残留大小（与 _clearTempResidual 相同的排除规则）。
  Future<int> _tempResidualSize(Directory tmp) async {
    if (!await tmp.exists()) return 0;
    var total = 0;
    await for (final entity in tmp.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      final name = path.split('/').last;
      if (name.endsWith('.part') ||
          name.endsWith('.temp') ||
          name.contains('.part')) {
        continue;
      }
      final reservedSubs = {
        'libCachedImageData',
        'gstore_image_cache',
        'readme_cache',
        'app_icons',
      };
      final parts = path.replaceAll('\\', '/').split('/');
      final underReserved = parts.any((p) => reservedSubs.contains(p));
      if (underReserved) continue;
      try {
        total += await entity.length();
      } catch (_) {}
    }
    return total;
  }

  // ---------- 清理动作 ----------

  bool get _clearing => state.clearing.value.isNotEmpty;

  /// 清理单项缓存。
  Future<bool> clearOne(String id) async {
    if (_clearing) return false;
    _CacheSpec? spec;
    for (final s in _specs) {
      if (s.id == id) {
        spec = s;
        break;
      }
    }
    if (spec == null) return false;
    state.clearing.value = id;
    try {
      await spec.clear();
      await reload();
      return true;
    } catch (e) {
      appLog.error('CacheManage: 清理 ${spec.name} 失败 - $e');
      return false;
    } finally {
      state.clearing.value = '';
    }
  }

  /// 当前可清理的缓存类别清单（供 Agent 等外部调用方枚举）。
  /// 返回 (id, 展示名, 当前占用字节)。
  Future<List<(String, String, int)>> cacheCategorySizes() async {
    await reload();
    final result = <(String, String, int)>[];
    for (final spec in _specs) {
      var size = 0;
      try {
        final tmp = await _tmpDir();
        size = await _specSize(spec, tmp);
      } catch (_) {}
      result.add((spec.id, spec.name, size));
    }
    return result;
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
    await reload();
    return success;
  }

  /// 一键清理全部缓存（需确认）。
  Future<bool> clearAll() async {
    if (_clearing) return false;
    final dlCount = state.downloads.length;
    final ok = await AppDialogs.showConfirmDialog(
      title: '一键清理',
      message: '将清除全部缓存（网络图片 / README / 图标 / 通用缓存等），\n'
          '${dlCount > 0 ? '并删除已下载的 $dlCount 个安装包文件。\n' : ''}'
          '删除后不可恢复，请确认。',
      confirmText: '全部清理',
      isDangerous: true,
    );
    if (ok != true) return false;

    state.clearing.value = '_all';
    try {
      // 1. 清理可再生缓存
      for (final spec in _specs) {
        try {
          await spec.clear();
        } catch (e) {
          appLog.error('CacheManage: 一键清理 ${spec.name} 失败 - $e');
        }
      }
      // 2. 删除全部已下载文件
      if (dlCount > 0) {
        final paths = state.downloads.map((e) => e.filePath).toList();
        await deleteDownloads(paths);
      }
      await reload();
      await loadDownloads();
      return true;
    } finally {
      state.clearing.value = '';
    }
  }

  /// 格式化字节数（供 UI 展示）。
  String formatSize(int bytes) => byteSize(bytes);

  // ---------- 已下载文件清理 ----------

  /// 测试注入：下载目录（getDownloadsDirectory 的替身）。
  @visibleForTesting
  Directory? debugDownloadsDir;

  /// APK 解析结果缓存（path → (appName, packageName, versionName, iconBytes)）。
  /// 避免列表刷新时对同一 APK 反复走 MethodChannel。
  final Map<String, (String?, String?, String?, Uint8List?)> _apkInfoCache = {};

  /// 解析下载目录：优先注入，否则取系统公共下载目录。
  Future<Directory> _downloadsDir() async {
    if (debugDownloadsDir != null) return debugDownloadsDir!;
    final dir = await getDownloadsDirectory();
    if (dir != null) return dir;
    // 个别平台无下载目录时回退文档目录
    return getApplicationDocumentsDirectory();
  }

  /// 刷新"已下载文件"列表：列出下载目录下的全部文件。
  /// 对 .apk 文件尝试解析应用名/包名/版本/图标（带缓存，失败回退文件名）。
  Future<void> loadDownloads() async {
    if (state.downloadsLoading.value) return;
    state.downloadsLoading.value = true;
    try {
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
      // 按修改时间倒序（最近的下载在前）
      items.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
      state.downloads.value = items;
      state.downloadTotalSize.value = total;
    } catch (e) {
      appLog.error('CacheManage: 加载已下载列表失败 - $e');
      state.downloads.value = [];
      state.downloadTotalSize.value = 0;
    } finally {
      state.downloadsLoading.value = false;
    }
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
    // 锁定正在删除的文件，防止重复点击
    state.deletingIds.addAll(filePaths);
    var success = 0;
    try {
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
      await loadDownloads();
      return success;
    } finally {
      state.deletingIds.removeAll(filePaths);
    }
  }
}
