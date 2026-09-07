import 'dart:typed_data';

/// 单个缓存项（展示数据；清理动作在逻辑层按 id 路由）。
class CacheItem {
  CacheItem({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    this.size = 0,
    this.failed = false,
  });

  final String id;
  final String name;
  final String description;
  final String icon;

  /// 当前占用字节数。
  final int size;

  /// 是否清理失败（单项清理后仍残留时置位，用于提示）。
  final bool failed;

  CacheItem copyWith({int? size, bool? failed}) {
    return CacheItem(
      id: id,
      name: name,
      description: description,
      icon: icon,
      size: size ?? this.size,
      failed: failed ?? this.failed,
    );
  }
}

/// 缓存分组（同类型缓存归为一组展示）。
class CacheGroup {
  CacheGroup({required this.title, required this.items});

  final String title;
  final List<CacheItem> items;

  int get totalSize => items.fold(0, (sum, item) => sum + item.size);

  CacheGroup copyWith({List<CacheItem>? items}) {
    return CacheGroup(title: title, items: items ?? this.items);
  }
}

/// 缓存管理页状态（Riverpod 不可变 state）。
class CacheManageState {
  /// 统计加载中。
  final bool loading;

  /// 正在清理的缓存项 id（为空表示无清理进行中）。
  final String clearing;

  /// 全部分组（按注册顺序）。
  final List<CacheGroup> groups;

  /// 缓存总大小。
  final int totalSize;

  // ---------- 已下载文件清理 ----------

  /// 已完成且文件存在的下载任务列表（供二级清理页展示）。
  final List<DownloadedFileItem> downloads;

  /// 已下载文件总占用。
  final int downloadTotalSize;

  /// 下载列表是否在加载。
  final bool downloadsLoading;

  /// 正在删除中的文件路径集合（多选批量删除期间禁止再次操作）。
  final Set<String> deletingIds;

  const CacheManageState({
    this.loading = false,
    this.clearing = '',
    this.groups = const [],
    this.totalSize = 0,
    this.downloads = const [],
    this.downloadTotalSize = 0,
    this.downloadsLoading = false,
    this.deletingIds = const {},
  });

  CacheManageState copyWith({
    bool? loading,
    String? clearing,
    List<CacheGroup>? groups,
    int? totalSize,
    List<DownloadedFileItem>? downloads,
    int? downloadTotalSize,
    bool? downloadsLoading,
    Set<String>? deletingIds,
  }) {
    return CacheManageState(
      loading: loading ?? this.loading,
      clearing: clearing ?? this.clearing,
      groups: groups ?? this.groups,
      totalSize: totalSize ?? this.totalSize,
      downloads: downloads ?? this.downloads,
      downloadTotalSize: downloadTotalSize ?? this.downloadTotalSize,
      downloadsLoading: downloadsLoading ?? this.downloadsLoading,
      deletingIds: deletingIds ?? this.deletingIds,
    );
  }
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
