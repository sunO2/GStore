import 'dart:typed_data';

import 'package:get/get.dart';

/// 单个缓存项（展示数据；清理动作在 logic 层按 id 路由）。
class CacheItem {
  CacheItem({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
  });

  final String id;
  final String name;
  final String description;
  final String icon;

  /// 当前占用字节数（由 logic 统计后写入）。
  int size = 0;

  /// 是否清理失败（单项清理后仍残留时置位，用于提示）。
  bool failed = false;
}

/// 缓存分组（同类型缓存归为一组展示）。
class CacheGroup {
  CacheGroup({required this.title, required this.items});

  final String title;
  final List<CacheItem> items;

  int get totalSize =>
      items.fold(0, (sum, item) => sum + item.size);
}

/// 缓存管理页状态。
class CacheManageState {
  /// 统计加载中。
  final RxBool loading = false.obs;

  /// 正在清理的缓存项 id（为空表示无清理进行中）。
  final RxString clearing = ''.obs;

  /// 全部分组（按注册顺序）。
  final RxList<CacheGroup> groups = <CacheGroup>[].obs;

  /// 缓存总大小。
  final RxInt totalSize = 0.obs;

  // ---------- 已下载文件清理 ----------

  /// 已完成且文件存在的下载任务列表（供二级清理页展示）。
  final RxList<DownloadedFileItem> downloads = <DownloadedFileItem>[].obs;

  /// 已下载文件总占用。
  final RxInt downloadTotalSize = 0.obs;

  /// 下载列表是否在加载。
  final RxBool downloadsLoading = false.obs;

  /// 正在删除中的文件路径集合（多选批量删除期间禁止再次操作）。
  final RxSet<String> deletingIds = <String>{}.obs;
}

/// 已下载文件条目（下载目录中的文件）。
class DownloadedFileItem {
  DownloadedFileItem({
    required this.fileName,
    required this.filePath,
    required this.size,
    required this.modifiedAt,
    this.isApk = false,
    this.apkAppName,
    this.apkPackageName,
    this.apkVersionName,
    this.apkIconBytes,
  });

  final String fileName;

  /// 磁盘文件完整路径。
  final String filePath;

  /// 实际磁盘占用字节。
  final int size;

  /// 文件修改时间（近似下载完成时间）。
  final DateTime modifiedAt;

  /// 是否为 APK（.apk 后缀，可解析出应用信息）。
  final bool isApk;

  /// APK 解析出的应用名（解析失败时为 null，回退文件名）。
  final String? apkAppName;

  /// APK 真实包名。
  final String? apkPackageName;

  /// APK 版本名。
  final String? apkVersionName;

  /// APK 图标 PNG 字节（可能为空）。
  final Uint8List? apkIconBytes;

  /// 展示用标题：APK 优先应用名，否则文件名。
  String get displayName => apkAppName?.isNotEmpty == true
      ? apkAppName!
      : fileName;

  /// 展示用副标题附加段：APK 显示包名+版本。
  String? get apkSubtitle {
    if (!isApk) return null;
    final pkg = apkPackageName?.isNotEmpty == true ? apkPackageName : null;
    final ver = apkVersionName?.isNotEmpty == true ? apkVersionName : null;
    if (pkg == null && ver == null) return null;
    return [pkg, if (ver != null) 'v$ver'].whereType<String>().join(' · ');
  }
}
