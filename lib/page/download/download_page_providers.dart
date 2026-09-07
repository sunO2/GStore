import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/download/manager/download_repository.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/model/download_task_database.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';

import 'download_status_utils.dart';

/// 应用信息数据库（经模块注册表取 DbManager，避免 GetX 服务定位）。
///
/// db 模块经 `context.bindService` 以具体类型注册进 ModuleManager（非 GetX），
/// 模块下线时 null（页面按默认图标处理）。
final downloadAppInfoDbProvider = Provider<AppInfoDatabase?>((ref) {
  return ModuleManager.instance.get<DbManager>()?.dbRepositroies['gstore']?.db;
});

/// 下载任务仓库（读/写下载数据库；watch 流由 service 内部仓库负责，
/// 页面侧实例仅供 CRUD）。
final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  return DownloadRepository();
});

/// 下载管理页聚合状态（不可变）。
class DownloadPageState {
  /// 当前筛选类型
  final DownloadFilter filter;

  /// 筛选后的下载分组数据（按应用分组，view 直接消费）
  final List<List<DownloadTask>> groups;

  /// 原始分组数据（用于筛选切换时重放）
  final List<List<DownloadTask>> latestGroups;

  /// 已标记为"已完成但磁盘文件已被外部删除"的任务 id 集合
  /// （如经缓存管理页删除下载文件后，install 按钮/已完成徽标不应继续显示）。
  final Set<int> missingFileIds;

  /// 应用信息缓存（appId → AppInfo?；避免列表滚动时重复查询数据库）
  final Map<String, AppInfo?> appInfoCache;

  const DownloadPageState({
    this.filter = DownloadFilter.all,
    this.groups = const [],
    this.latestGroups = const [],
    this.missingFileIds = const {},
    this.appInfoCache = const {},
  });

  DownloadPageState copyWith({
    DownloadFilter? filter,
    List<List<DownloadTask>>? groups,
    List<List<DownloadTask>>? latestGroups,
    Set<int>? missingFileIds,
    Map<String, AppInfo?>? appInfoCache,
  }) {
    return DownloadPageState(
      filter: filter ?? this.filter,
      groups: groups ?? this.groups,
      latestGroups: latestGroups ?? this.latestGroups,
      missingFileIds: missingFileIds ?? this.missingFileIds,
      appInfoCache: appInfoCache ?? this.appInfoCache,
    );
  }

  /// 同步读取缓存中的应用信息（缓存未命中返回 null，view 显示默认图标）
  AppInfo? cachedAppInfo(String appId) => appInfoCache[appId];
}

/// 下载管理页控制器（Riverpod 版，替代原 GetxController）。
///
/// 职责：加载/分组/筛选下载任务、订阅 service.watch(id) 实时状态、
/// 已完成文件存在性核对、CRUD（删除/清理/批量操作）、应用信息预取缓存。
class DownloadManagerNotifier extends Notifier<DownloadPageState> {
  final DownloadRepository repository = DownloadRepository();
  final AppInfoDatabase? appInfoDB;

  DownloadManagerNotifier({this.appInfoDB});

  /// 各任务 watch 订阅（service.watch(task.id) 推送 DownloadTask 到 state）
  final Map<int, StreamSubscription<DownloadTask>> _watchSubs = {};

  /// watch 关闭/出错后的延迟重载（debounce，防 onDone 风暴）
  Timer? _reloadTimer;

  IDownloadService? _service;

  /// 应用信息并发加载中集合（防同一应用重复查询）
  final Set<String> _appInfoLoading = {};

  @override
  DownloadPageState build() {
    ref.onDispose(() {
      _reloadTimer?.cancel();
      for (final sub in _watchSubs.values) {
        sub.cancel();
      }
      _watchSubs.clear();
    });
    return const DownloadPageState();
  }

  /// 页面挂载后加载任务（view initState 调用，等价原 onReady）。
  Future<void> load() async {
    _service = ModuleManager.instance.get<IDownloadService>();
    await loadTasks();
  }

  /// 应用筛选条件到分组列表
  List<List<DownloadTask>> _applyFilter(
    List<List<DownloadTask>> groups,
    DownloadFilter filter,
  ) {
    if (filter == DownloadFilter.all) return groups;

    return groups
        .map((group) =>
            group.where((item) => matchesFilter(item, filter)).toList())
        .where((group) => group.isNotEmpty)
        .toList();
  }

  /// 从新管线仓库加载全部任务并重建分组
  Future<void> loadTasks() async {
    List<DownloadTask> tasks;
    try {
      tasks = await repository.all();
    } catch (e) {
      debugPrint('下载列表加载失败: $e');
      return;
    }
    // 按创建时间倒序（与原 DAO createTime DESC 一致）
    tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _buildGroups(tasks);
    _resubscribeWatches(tasks);
    // 预取应用信息（异步，不阻塞 UI）
    unawaited(_prefetchAppInfos(state.latestGroups));
    // 异步核对已完成任务的文件是否仍存在（外部删除后更新缺失标记）
    unawaited(_refreshMissingFiles(tasks));
  }

  /// 检查已完成任务的主文件是否仍存在；缺失的记入 [missingFileIds]。
  Future<void> _refreshMissingFiles(List<DownloadTask> tasks) async {
    final missing = <int>{};
    final checks = <Future<void>>[];
    for (final t in tasks) {
      final id = t.id;
      if (id == null || t.status != DownloadStatusEnum.completed) continue;
      checks.add(() async {
        try {
          final file = File(t.filePath);
          if (!await file.exists()) missing.add(id);
        } catch (_) {
          missing.add(id);
        }
      }());
    }
    await Future.wait(checks);
    // 仅标记 completed 的缺失任务
    final prev = state.missingFileIds;
    final same = prev.length == missing.length && prev.containsAll(missing);
    if (!same) {
      state = state.copyWith(missingFileIds: missing);
    }
  }

  /// 核对单个已完成任务的文件存在性，同步 [missingFileIds]。
  Future<void> _checkSingleFilePresence(DownloadTask task) async {
    final id = task.id;
    if (id == null) return;
    try {
      final exists = await File(task.filePath).exists();
      final next = Set<int>.from(state.missingFileIds);
      if (exists) {
        next.remove(id);
      } else {
        next.add(id);
      }
      state = state.copyWith(missingFileIds: next);
    } catch (_) {
      final next = Set<int>.from(state.missingFileIds)..add(id);
      state = state.copyWith(missingFileIds: next);
    }
  }

  /// 由全量任务构建分组并发布
  void _buildGroups(List<DownloadTask> tasks) {
    var map = <String, List<DownloadTask>>{};
    for (var item in tasks) {
      var key = "${item.appId}_${item.version}";
      var list = map[key] ??= [];
      list.add(item);
    }
    final latest = List<List<DownloadTask>>.from(map.values);
    state = state.copyWith(
      latestGroups: latest,
      groups: _applyFilter(latest, state.filter),
    );
  }

  /// 为每个任务订阅 service.watch(id)，推送更新进 state
  void _resubscribeWatches(List<DownloadTask> tasks) {
    final ids = tasks.map((t) => t.id).whereType<int>().toSet();
    // 取消已不存在任务的订阅
    _watchSubs.removeWhere((id, sub) {
      if (!ids.contains(id)) {
        sub.cancel();
        return true;
      }
      return false;
    });
    for (final id in ids) {
      if (_watchSubs.containsKey(id)) continue;
      final service = _service;
      if (service == null) continue;
      late StreamSubscription<DownloadTask> sub;
      sub = service.watch(id).listen(
            (task) => _onTaskUpdate(task),
            onError: (_) {
              _watchSubs.remove(id)?.cancel();
              _scheduleReload();
            },
            onDone: () {
              _watchSubs.remove(id)?.cancel();
              _scheduleReload();
            },
          );
      _watchSubs[id] = sub;
    }
  }

  /// 单个任务状态更新：替换到分组中并刷新 UI
  void _onTaskUpdate(DownloadTask task) {
    final id = task.id;
    if (id == null) return;
    final latest = state.latestGroups;
    for (var i = 0; i < latest.length; i++) {
      final group = latest[i];
      for (var j = 0; j < group.length; j++) {
        if (group[j].id == id) {
          final newGroup = List.of(group); // 复制内层，避免原地修改
          newGroup[j] = task;
          final nextLatest = List.of(latest);
          nextLatest[i] = newGroup;
          state = state.copyWith(
            latestGroups: nextLatest,
            groups: List.of(_applyFilter(nextLatest, state.filter)),
          );
          // 状态回到 completed（如重新下载完成）后重新核对文件存在性，
          // 清除旧的"已删除"标记
          if (task.status == DownloadStatusEnum.completed) {
            unawaited(_checkSingleFilePresence(task));
          } else {
            final nextMissing = Set<int>.from(state.missingFileIds)..remove(id);
            state = state.copyWith(missingFileIds: nextMissing);
          }
          return;
        }
      }
    }
    // 任务不在现有分组（如新建下载后 watch 先到）：整体重载兜底
    loadTasks();
  }

  /// watch 关闭/出错后延迟重载全量任务（防止 onDone 风暴）
  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 400), () {
      _service = ModuleManager.instance.get<IDownloadService>();
      loadTasks();
    });
  }

  /// 获取应用信息（带缓存）
  Future<AppInfo?> getAppInfo(String appId) async {
    final db = appInfoDB ?? ref.read(downloadAppInfoDbProvider);
    // 命中缓存
    if (state.appInfoCache.containsKey(appId)) {
      return state.appInfoCache[appId];
    }
    // 防止同一应用并发重复查询
    if (_appInfoLoading.contains(appId)) {
      return null;
    }
    _appInfoLoading.add(appId);
    try {
      final info = await db?.dao.getAppInfo(appId);
      _setAppInfoCache(appId, info);
      return info;
    } catch (e) {
      _setAppInfoCache(appId, null);
      return null;
    } finally {
      _appInfoLoading.remove(appId);
    }
  }

  void _setAppInfoCache(String appId, AppInfo? info) {
    state = state.copyWith(
      appInfoCache: {...state.appInfoCache, appId: info},
    );
  }

  /// 预取应用信息到缓存
  Future<void> _prefetchAppInfos(List<List<DownloadTask>> groups) async {
    for (final group in groups) {
      if (group.isEmpty) continue;
      final appId = group[0].appId;
      if (!state.appInfoCache.containsKey(appId)) {
        await getAppInfo(appId);
      }
    }
  }

  /// 安装应用（Shizuku 静默安装优先，回退系统安装）
  Future<void> installApp(DownloadTask downStatus) async {
    // 安装模块下线 → 注册表取不到服务，降级提示不抛
    final manager = ModuleManager.instance.get<InstallManager>();
    if (manager == null) {
      AppDialogs.showWarning('安装模块未启用');
      return;
    }
    if (Platform.isAndroid && downStatus.fileName.endsWith(".apk")) {
      await manager.installApk(downStatus.filePath);
    }
  }

  /// 恢复下载（断点续传）
  Future<void> resumeDownload(DownloadTask downStatus) async {
    final id = downStatus.id;
    final service = ModuleManager.instance.get<IDownloadService>();
    if (id == null || service == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    await service.resume(id);
    await loadTasks();
  }

  /// 重新下载 / 重试失败任务（交由新 manager 断点续传或强制重下）
  Future<void> retryDownload(DownloadTask downStatus) async {
    final id = downStatus.id;
    final service = ModuleManager.instance.get<IDownloadService>();
    if (id == null || service == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    await service.retry(id);
    await loadTasks();
  }

  /// 暂停下载
  Future<void> pauseDownload(DownloadTask downStatus) async {
    final id = downStatus.id;
    final service = ModuleManager.instance.get<IDownloadService>();
    if (id == null || service == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    await service.pause(id);
    await loadTasks();
    AppDialogs.showSuccess(
      '已暂停 ${downStatus.appName} 的下载',
      title: '已暂停',
    );
  }

  /// 取消下载 / 取消排队
  void cancelDownload(DownloadTask downStatus) {
    final id = downStatus.id;
    final service = ModuleManager.instance.get<IDownloadService>();
    if (id == null || service == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    service.cancel(id);
    AppDialogs.showSuccess(
      '已取消 ${downStatus.appName} 的下载',
      title: '已取消',
    );
  }

  /// 暂停所有下载中任务
  void pauseAll() async {
    final tasks = await repository.all();
    final downloading = tasks
        .where((t) =>
            t.status == DownloadStatusEnum.downloading ||
            t.status == DownloadStatusEnum.connecting)
        .toList();
    final service = ModuleManager.instance.get<IDownloadService>();
    for (final item in downloading) {
      final id = item.id;
      if (id != null && service != null) {
        service.pause(id);
      }
    }
    AppDialogs.showSuccess('已暂停 ${downloading.length} 个下载');
  }

  /// 取消所有排队任务
  void cancelAllQueued() async {
    final tasks = await repository.all();
    final queued =
        tasks.where((t) => t.status == DownloadStatusEnum.queued).toList();
    final service = ModuleManager.instance.get<IDownloadService>();
    for (final item in queued) {
      final id = item.id;
      if (id != null && service != null) {
        service.cancel(id);
      }
    }
    if (queued.isNotEmpty) {
      AppDialogs.showSuccess('已取消 ${queued.length} 个排队任务');
    }
  }

  /// 重试所有失败任务
  void retryAllFailed() async {
    final tasks = await repository.all();
    final failed =
        tasks.where((t) => t.status == DownloadStatusEnum.failed).toList();
    final service = ModuleManager.instance.get<IDownloadService>();
    for (final item in failed) {
      final id = item.id;
      if (id != null && service != null) {
        service.retry(id);
      }
    }
  }

  /// 删除单个下载记录
  Future<void> deleteDownload(DownloadTask downStatus) async {
    try {
      final id = downStatus.id;

      // 1. 取消正在下载的任务
      final service = ModuleManager.instance.get<IDownloadService>();
      if (downStatus.isActive && id != null && service != null) {
        await service.cancel(id);
      }

      // 2. 删除已下载的文件
      final file = File(downStatus.filePath);
      final tempFile = File("${downStatus.filePath}.temp");

      if (await file.exists()) {
        await file.delete();
      }
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      // 删除 .part 分段文件
      int partIndex = 0;
      while (true) {
        final partFile = File('${downStatus.filePath}.part$partIndex');
        if (!await partFile.exists()) break;
        await partFile.delete();
        partIndex++;
      }

      // 3. 从新管线数据库删除记录（DAO 无 delete 方法 → 走底层库）
      if (id != null) {
        final db = await downloadTaskDatabase;
        await db.database
            .delete('DownloadTaskEntity', where: 'id = ?', whereArgs: [id]);
      }

      // 4. 刷新列表
      await loadTasks();

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
      final db = await downloadTaskDatabase;
      await db.database
          .delete('DownloadTaskEntity', where: 'appId = ?', whereArgs: [appId]);

      await loadTasks();

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
      final tasks = await repository.all();
      final completed = tasks
          .where((t) =>
              t.status == DownloadStatusEnum.completed ||
              t.status == DownloadStatusEnum.failed)
          .toList();

      // 删除文件
      for (var item in completed) {
        try {
          final file = File(item.filePath);
          final tempFile = File("${item.filePath}.temp");

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

      // 删除数据库记录（completed/failed）
      final db = await downloadTaskDatabase;
      await db.database.delete(
        'DownloadTaskEntity',
        where: 'status IN (?, ?)',
        whereArgs: [
          DownloadStatusEnum.completed.index,
          DownloadStatusEnum.failed.index,
        ],
      );

      // 刷新列表
      await loadTasks();

      final count = completed.length;
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
      final tasks = await repository.all();

      // 取消所有正在下载的任务
      final service = ModuleManager.instance.get<IDownloadService>();
      for (var item in tasks) {
        if (item.isActive) {
          final id = item.id;
          if (id != null && service != null) {
            await service.cancel(id);
          }
        }
      }

      // 删除所有文件
      for (var item in tasks) {
        try {
          final file = File(item.filePath);
          final tempFile = File("${item.filePath}.temp");

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
      final db = await downloadTaskDatabase;
      await db.database.delete('DownloadTaskEntity');

      // 刷新列表
      await loadTasks();

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
    state = state.copyWith(
      filter: filter,
      // 基于最新数据重新应用筛选
      groups: List.of(_applyFilter(state.latestGroups, filter)),
    );
  }
}

final downloadManagerProvider =
    NotifierProvider<DownloadManagerNotifier, DownloadPageState>(
  DownloadManagerNotifier.new,
);
