import 'dart:io';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';

import 'download_status_utils.dart';
import 'state.dart';

class DownloadManagerLogic extends GetxController with GithubRequestMix {
  final DownloadManagerState state = DownloadManagerState();
  final Future<DownloadDatabase> database = downloadStatusDatabase;
  final AppInfoDatabase appInfoDB = "gstore".repoDB.db;

  /// 应用信息缓存（避免列表滚动时重复查询数据库）
  final Map<String, AppInfo?> _appInfoCache = {};
  final Set<String> _appInfoLoading = {};

  /// 当前筛选类型
  final Rx<DownloadFilter> currentFilter = DownloadFilter.all.obs;

  /// 筛选后的下载分组数据（按应用分组）
  /// 使用 Rx 保证订阅时立即有当前值，避免 broadcast 流数据丢失
  final Rx<List<List<DownloadStatus>>> downloadGroups =
      Rx<List<List<DownloadStatus>>>([]);

  /// 原始分组数据（用于筛选切换时重放）
  List<List<DownloadStatus>> _latestGroups = [];

  @override
  void onReady() async {
    _initDownloadStream();
    super.onReady();
  }

  /// 应用筛选条件到分组列表
  List<List<DownloadStatus>> _applyFilter(
    List<List<DownloadStatus>> groups,
    DownloadFilter filter,
  ) {
    if (filter == DownloadFilter.all) return groups;

    return groups
        .map((group) => group.where((item) => matchesFilter(item, filter)).toList())
        .where((group) => group.isNotEmpty)
        .toList();
  }

  /// 初始化下载流
  void _initDownloadStream() async {
    var db = await database;
    var downloadList = db.downloadStatusDao.getAllDownload();
    downloadList.listen((items) {
      var map = <String, List<DownloadStatus>>{};
      for (var item in items) {
        var key = "${item.appId}_${item.version}";
        var list = map[key] ??= [];
        list.add(item);
      }
      _latestGroups = List.from(map.values);
      downloadGroups.value = _applyFilter(_latestGroups, currentFilter.value);
      // 预取应用信息（异步，不阻塞 UI）
      _prefetchAppInfos(_latestGroups);
    });
  }

  /// 获取应用信息（带缓存）
  Future<AppInfo?> getAppInfo(String appId) async {
    // 命中缓存
    if (_appInfoCache.containsKey(appId)) {
      return _appInfoCache[appId];
    }

    // 防止同一应用并发重复查询
    if (_appInfoLoading.contains(appId)) {
      return null;
    }

    _appInfoLoading.add(appId);
    try {
      final info = await (await appInfoDB).dao.getAppInfo(appId);
      _appInfoCache[appId] = info;
      return info;
    } catch (e) {
      _appInfoCache[appId] = null;
      return null;
    } finally {
      _appInfoLoading.remove(appId);
    }
  }

  /// 同步获取缓存的应用信息
  /// 缓存未命中时返回 null（view 会显示默认图标）
  AppInfo? getCachedAppInfo(String appId) {
    return _appInfoCache[appId];
  }

  /// 预取应用信息到缓存
  Future<void> _prefetchAppInfos(List<List<DownloadStatus>> groups) async {
    var hasNewInfo = false;
    for (final group in groups) {
      if (group.isEmpty) continue;
      final appId = group[0].appId;
      if (!_appInfoCache.containsKey(appId)) {
        await getAppInfo(appId);
        hasNewInfo = true;
      }
    }
    // 预取完成后刷新 UI（让图标显示）
    if (hasNewInfo && downloadGroups.value.isNotEmpty) {
      downloadGroups.value = List.from(downloadGroups.value);
    }
  }

  /// 安装应用（Shizuku 静默安装优先，回退系统安装）
  Future<void> installApp(DownloadStatus downStatus) async {
    if (GetPlatform.isAndroid && downStatus.fileName.endsWith(".apk")) {
      await InstallManager.instance.installApk(downStatus.savePath);
    }
  }

  /// 恢复下载（断点续传）
  void resumeDownload(DownloadStatus downStatus) {
    retryDownload(downStatus, restartCount: downStatus.count);
  }

  /// 重新下载
  /// [restartCount] 起始字节数：
  ///   - 续传时传入当前已下载字节数（downStatus.count）
  ///   - 重新下载时默认 0（从头开始）
  void retryDownload(DownloadStatus downStatus, {int restartCount = 0}) async {
    // 若重新下载，删除旧的临时文件
    if (restartCount == 0) {
      final tempFile = File("${downStatus.savePath}.temp");
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    downStatus.updateDownload(restartCount, downStatus.total);
    // 从头下载时强制重新下载（forceDownload: true），续传时保留已下载部分
    // 注意：不要在此处 markAsDownloading，否则 download() 的防重检查会误判为
    // "正在下载" 而直接跳过，导致点击"继续下载/重试"无效
    // 下载模块下线 → 注册表取不到服务，降级提示不抛
    final service = ModuleManager.instance.get<IDownloadService>();
    if (service == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    await service.download(
        downStatus.appId,
        downStatus.appName,
        downStatus.version,
        downStatus.downloadUrl,
        downStatus.fileName,
        downloadSize: downStatus.total,
        forceDownload: restartCount == 0);
  }

  /// 暂停下载
  void pauseDownload(DownloadStatus downStatus) {
    downStatus.cancelDownload();
    AppDialogs.showSuccess(
      '已暂停 ${downStatus.appName} 的下载',
      title: '已暂停',
    );
  }

  /// 删除单个下载记录
  Future<void> deleteDownload(DownloadStatus downStatus) async {
    try {
      // 1. 取消正在下载的任务
      if (downStatus.status == DownloadStatus.DOWNLOAD_LOADING) {
        downStatus.cancelDownload();
      }

      // 2. 删除已下载的文件
      final file = File(downStatus.savePath);
      final tempFile = File("${downStatus.savePath}.temp");

      if (await file.exists()) {
        await file.delete();
      }
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      // 3. 从数据库删除记录
      if (downStatus.id != null) {
        final db = await database;
        await db.downloadStatusDao.deleteDownload(downStatus.id!);
      }

      // 4. 释放内存资源
      downStatus.dispose();

      AppDialogs.showSuccess(
        '已删除 ${downStatus.appName} 的下载记录',
        title: '已删除',
      );
    } catch (e) {
      AppDialogs.showError(
        '删除下载记录失败: $e',
        title: '删除失败',
      );
    }
  }

  /// 删除指定应用的所有下载记录
  Future<void> deleteDownloadsByAppId(String appId) async {
    try {
      final db = await database;
      await db.downloadStatusDao.deleteDownloadsByAppId(appId);

      AppDialogs.showSuccess(
        '已删除该应用的所有下载记录',
        title: '已删除',
      );
    } catch (e) {
      AppDialogs.showError(
        '删除下载记录失败: $e',
        title: '删除失败',
      );
    }
  }

  /// 清理已完成的下载记录
  Future<void> clearCompleted() async {
    try {
      final db = await database;
      final items = await db.downloadStatusDao.getCompletedItems();

      // 删除文件
      for (var item in items) {
        try {
          final file = File(item.savePath);
          final tempFile = File("${item.savePath}.temp");

          if (await file.exists()) {
            await file.delete();
          }
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (e) {
          // 忽略单个文件删除失败
        }
      }

      // 删除数据库记录
      await db.downloadStatusDao.deleteCompletedDownloads();

      // 释放内存资源
      for (var item in items) {
        item.dispose();
      }

      final count = items.length;
      AppDialogs.showSuccess(
        count > 0 ? '已清理 $count 条已完成记录' : '没有需要清理的记录',
        title: '清理完成',
      );
    } catch (e) {
      AppDialogs.showError(
        '清理下载记录失败: $e',
        title: '清理失败',
      );
    }
  }

  /// 清空所有下载记录
  Future<void> clearAll() async {
    // 显示确认对话框
    final confirmed = await AppDialogs.showDialog(
      title: '确认清空',
      content: '确定要清空所有下载记录吗？此操作不可恢复。',
      confirmText: '确认清空',
      cancelText: '取消',
      isDangerous: true,
    );

    if (confirmed != true) return;

    try {
      final db = await database;
      final items = await db.downloadStatusDao.getAllDownload().first ?? [];

      // 取消所有正在下载的任务
      for (var item in items) {
        if (item.status == DownloadStatus.DOWNLOAD_LOADING) {
          item.cancelDownload();
        }
      }

      // 删除所有文件
      for (var item in items) {
        try {
          final file = File(item.savePath);
          final tempFile = File("${item.savePath}.temp");

          if (await file.exists()) {
            await file.delete();
          }
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (e) {
          // 忽略单个文件删除失败
        }
      }

      // 清空数据库
      await db.downloadStatusDao.deleteAllDownloads();

      // 释放内存资源
      for (var item in items) {
        item.dispose();
      }

      AppDialogs.showSuccess(
        '已清空所有下载记录',
        title: '清空完成',
      );
    } catch (e) {
      AppDialogs.showError(
        '清空下载记录失败: $e',
        title: '清空失败',
      );
    }
  }

  /// 切换筛选类型
  void setFilter(DownloadFilter filter) {
    currentFilter.value = filter;
    // 基于最新数据重新应用筛选
    downloadGroups.value = _applyFilter(_latestGroups, filter);
  }

  /// 获取筛选后的流
  Stream<List<List<DownloadStatus>>> getFilteredStream() {
    return downloadGroups.stream;
  }

  @override
  void onClose() async {
    super.onClose();
  }
}
