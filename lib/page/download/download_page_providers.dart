import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/download/download_module_unavailable_exception.dart';
import 'package:gstore/core/download/manager/download_repository.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/model/download_task_database.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';

import 'download_status_utils.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

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


  /// 任务列表的数据源统一走服务接口。
  ///
  /// 必须走接口而不是直接读 Floor：Rust 内核的任务写在模块自己的库里，
  /// 直接读 Floor 会导致「切了内核但面板看不到任务」。
  Future<List<DownloadTask>> _allTasks() async {
    final svc = _service ?? ModuleManager.instance.get<IDownloadService>();
    if (svc != null) return svc.listTasks();
    debugPrint('下载列表: IDownloadService 不可用，回落 Floor 仓储');
    return repository.all();
  }

  /// 从新管线仓库加载全部任务并重建分组
  Future<void> loadTasks() async {
    List<DownloadTask> tasks;
    try {
      tasks = await _allTasks();
    } catch (e) {
      debugPrint('下载列表加载失败: $e');
      return;
    }
    // 按创建时间倒序（与原 DAO createTime DESC 一致）
    tasks.sort((a, b) {
      // 方案 B：按「最后一次开始时间」置顶（重试/重新下载会刷新它，且**跨重启保留**）；
      // 从未开始过的回落到创建时间
      // createdAt 是 DateTime，lastStartedAt 是毫秒 → 统一成毫秒再比
      final ta = a.lastStartedAt > 0
          ? a.lastStartedAt
          : a.createdAt.millisecondsSinceEpoch;
      final tb = b.lastStartedAt > 0
          ? b.lastStartedAt
          : b.createdAt.millisecondsSinceEpoch;
      return tb.compareTo(ta);
    });
    // 诊断：打印排序键，用于定位"继续任务被置顶"。
    // last==created → 继续没有改时间（该任务本来就在最前）；
    // last> created → 有路径在刷新"最后开始时间"，据此就能定位。
    debugPrint('下载排序键: ${tasks.take(6).map((t) => '#${t.id} last=${t.lastStartedAt} '
        'created=${t.createdAt.millisecondsSinceEpoch} ${t.status.name}').join(' | ')}');
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

  /// 丢弃某任务的 watch 订阅，使下一次 [loadTasks] 重新建立订阅。
  ///
  /// 内核的 watch 变更检测对**每个订阅**按 id 记住「终态只发一次」：一个
  /// 曾处于 failed/completed 等终态的任务被 retry/restart 复活后，复用的旧
  /// 订阅永远不会再推送它的新进度/完成（见
  /// `rust/gstore_host/src/download_host.rs` 的 `DownloadWatchState`）。
  /// 因此复活类动作必须换一条全新订阅，否则列表会一直停在旧状态。
  void _dropWatch(int id) {
    _watchSubs.remove(id)?.cancel();
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

  /// 统一包一层变更类服务调用：类型化内核不可用 → 用户可见提示，
  /// 其它错误只记日志。返回是否真正执行成功（失败分支不继续刷新/提示成功）。
  Future<bool> _runServiceAction(
    String label,
    Future<void> Function(IDownloadService service) action, {
    IDownloadService? service,
  }) async {
    final target = service ?? ModuleManager.instance.get<IDownloadService>();
    if (target == null) {
      AppDialogs.showWarning('下载模块未启用');
      return false;
    }
    try {
      await action(target);
      return true;
    } on DownloadModuleUnavailableException catch (e) {
      AppDialogs.showError(e.userMessage, title: '下载失败');
      return false;
    } catch (e) {
      appLog.error('下载面板: $label 失败 - $e');
      return false;
    }
  }

  /// 平台判定接缝：默认读真实平台，测试注入以在非 Android 主机上驱动安装分支。
  ///
  /// 生产始终走 `Platform.isAndroid`；这里只为一处副作用（安装）提供可替身点，
  /// 避免测试必须依赖真机 / 平台通道。
  @visibleForTesting
  static bool Function() isAndroidPlatform = () => Platform.isAndroid;

  /// 安装应用（核心安装域优先，回退系统安装）。
  ///
  /// 安装有两条失败通道：`InstallManager.installApk` 返回的 [InstallOutcome]
  /// 结果，以及核心抛出的类型化 [InstallCoreException]（`CORE_E_INSTALL_*`）。
  /// 二者此前都被丢弃 / 未捕获，真机上表现为「点击安装无响应」。这里必须把每条
  /// 失败都转成用户可见提示。
  ///
  /// **诚实契约**：系统安装器 Intent 的"启动"不等于"安装完成"——用户可能取消、
  /// 系统可能因「安装未知应用」权限拒绝、安装器也可能失败。因此 [InstallOutcome.launched]
  /// 只提示「已发起安装，等待系统确认」；真正的终端结果
  /// (installed/denied/failed/timeout) 由 `InstallManager` 的 `install_events`
  /// 订阅或超时截止在到达时提示（见 `_surfaceInstallResult`）。
  Future<void> installApp(DownloadTask downStatus) async {
    // 安装模块下线 → 注册表取不到服务，降级提示不抛
    final manager = ModuleManager.instance.get<InstallManager>();
    if (manager == null) {
      AppDialogs.showWarning('安装模块未启用');
      return;
    }
    if (!isAndroidPlatform()) {
      AppDialogs.showWarning('当前平台不支持安装 APK');
      return;
    }
    // 非 APK 文件明确提示，绝不静默 no-op（此前该分支直接什么都不做）。
    if (!downStatus.fileName.endsWith('.apk')) {
      AppDialogs.showWarning('该文件不是可安装的 APK：${downStatus.fileName}');
      return;
    }

    final name =
        downStatus.appName.isNotEmpty ? downStatus.appName : downStatus.fileName;
    try {
      final (outcome, method) = await manager.installApk(downStatus.filePath);
      switch (outcome) {
        case InstallOutcome.installed:
          appLog.info('下载面板: 安装完成 name=$name method=${method.name}');
          AppDialogs.showSuccess('$name 安装完成');
        case InstallOutcome.alreadyInstalled:
          appLog.info('下载面板: 已安装 name=$name method=${method.name}');
          AppDialogs.showSuccess('$name 已安装');
        case InstallOutcome.launched:
          appLog.info('下载面板: 已发起安装 name=$name method=${method.name}');
          AppDialogs.showSuccess('$name 已发起安装，等待系统确认');
        case InstallOutcome.failed:
          appLog.error('下载面板: 安装失败 name=$name method=${method.name}', data: {
            'filePath': downStatus.filePath,
          });
          AppDialogs.showError('$name 安装失败，请检查系统「安装未知应用」权限后重试',
              title: '安装失败');
      }
    } on InstallCoreException catch (e) {
      appLog.error('下载面板: 安装失败 [${e.code}] - ${e.message}', data: {
        'filePath': downStatus.filePath,
      });
      AppDialogs.showError('$name 安装失败：${e.code}', title: '安装失败');
    } catch (e) {
      appLog.error('下载面板: 安装异常 - $e', data: {
        'filePath': downStatus.filePath,
      });
      AppDialogs.showError('$name 安装失败：$e', title: '安装失败');
    }
  }

  /// 恢复下载（断点续传）
  Future<void> resumeDownload(DownloadTask downStatus) async {
    debugPrint('DownloadPanel.action: 继续 id=${downStatus.id} status=${downStatus.status.name}');
    final id = downStatus.id;
    if (id == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    if (!await _runServiceAction('继续', (service) => service.resume(id))) {
      return;
    }
    await loadTasks();
  }

  /// 重新下载 / 重试失败任务（交由新 manager 断点续传或强制重下）
  Future<void> retryDownload(DownloadTask downStatus) async {
    debugPrint('DownloadPanel.action: 重试/重新下载 id=${downStatus.id} status=${downStatus.status.name}');
    final id = downStatus.id;
    if (id == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    if (!await _runServiceAction('重试', (service) => service.retry(id))) {
      return;
    }
    // 复活的终态任务必须换新订阅，否则旧订阅的终态闩锁会吞掉后续进度/完成。
    _dropWatch(id);
    await loadTasks();
  }

  /// 重新下载：清空已下分段，从 0 开始（区别于"继续/重试"的续传）
  Future<void> restartDownload(DownloadTask downStatus) async {
    debugPrint('DownloadPanel.action: 重新下载 id=${downStatus.id} status=${downStatus.status.name}');
    final id = downStatus.id;
    if (id == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    if (!await _runServiceAction('重新下载', (service) => service.restart(id))) {
      return;
    }
    _dropWatch(id);
    await loadTasks();
  }

  /// 暂停下载
  Future<void> pauseDownload(DownloadTask downStatus) async {
    debugPrint('DownloadPanel.action: 暂停 id=${downStatus.id} status=${downStatus.status.name}');
    final id = downStatus.id;
    if (id == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    if (!await _runServiceAction('暂停', (service) => service.pause(id))) {
      return;
    }
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
    unawaited(_runServiceAction(
      '取消',
      (target) => target.cancel(id),
      service: service,
    ));
    AppDialogs.showSuccess(
      '已取消 ${downStatus.appName} 的下载',
      title: '已取消',
    );
  }

  /// 暂停所有下载中任务
  void pauseAll() async {
    final tasks = await _allTasks();
    final downloading = tasks
        .where((t) =>
            t.status == DownloadStatusEnum.downloading ||
            t.status == DownloadStatusEnum.connecting)
        .toList();
    final service = ModuleManager.instance.get<IDownloadService>();
    for (final item in downloading) {
      final id = item.id;
      if (id != null && service != null) {
        unawaited(_runServiceAction(
          '批量暂停',
          (target) => target.pause(id),
          service: service,
        ));
      }
    }
    AppDialogs.showSuccess('已暂停 ${downloading.length} 个下载');
  }

  /// 取消所有排队任务
  void cancelAllQueued() async {
    final tasks = await _allTasks();
    final queued =
        tasks.where((t) => t.status == DownloadStatusEnum.queued).toList();
    final service = ModuleManager.instance.get<IDownloadService>();
    for (final item in queued) {
      final id = item.id;
      if (id != null && service != null) {
        unawaited(_runServiceAction(
          '批量取消',
          (target) => target.cancel(id),
          service: service,
        ));
      }
    }
    if (queued.isNotEmpty) {
      AppDialogs.showSuccess('已取消 ${queued.length} 个排队任务');
    }
  }

  /// 重试所有失败任务
  void retryAllFailed() async {
    final tasks = await _allTasks();
    final failed =
        tasks.where((t) => t.status == DownloadStatusEnum.failed).toList();
    final service = ModuleManager.instance.get<IDownloadService>();
    var retried = false;
    for (final item in failed) {
      final id = item.id;
      if (id != null && service != null) {
        if (!await _runServiceAction(
          '批量重试',
          (target) => target.retry(id),
          service: service,
        )) {
          continue;
        }
        // 失败任务属于终态：换新订阅，避免旧订阅的终态闩锁吞掉新进度。
        _dropWatch(id);
        retried = true;
      }
    }
    // 批量重试后必须重载：失败任务在列表里是终态，watch 不会主动刷新它们。
    if (retried) await loadTasks();
  }

  /// 删除单个下载记录
  Future<void> deleteDownload(DownloadTask downStatus) async {
    try {
      final id = downStatus.id;

      // 1. 取消正在下载的任务
      final service = ModuleManager.instance.get<IDownloadService>();
      if (downStatus.isActive && id != null && service != null) {
        if (!await _runServiceAction(
          '删除前取消',
          (target) => target.cancel(id),
          service: service,
        )) {
          return;
        }
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

      // 3. 删除任务记录：**必须走服务接口**
      //    Rust 内核的任务存在模块自己的库里，只删 Floor 是删不掉的（列表会"复活"）
      if (id != null) {
        if (service != null) {
          if (!await _runServiceAction(
            '删除记录',
            (target) => target.remove(id),
            service: service,
          )) {
            return;
          }
        } else {
          // 守卫只保护「内核不可用 → 回落 Dart Floor」这条旧写入路径：
          // 内核可用时删除走 service.remove(id)，与旧写入域标记无关，不能被
          // LegacyWriteBlocked 拦下（否则 delete 永远在 try 外抛出、列表不刷新）。
          await LegacyWriteGuard.assertAllowed('download');
          final db = await downloadTaskDatabase;
          await db.database
              .delete('DownloadTaskEntity', where: 'id = ?', whereArgs: [id]);
        }
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
      final service = ModuleManager.instance.get<IDownloadService>();
      if (service != null) {
        final tasks = await _allTasks();
        final ids = tasks
            .where((t) => t.appId == appId)
            .map((t) => t.id)
            .whereType<int>()
            .toList();
        for (final id in ids) {
          if (!await _runServiceAction(
            '删除记录',
            (target) => target.remove(id),
            service: service,
          )) {
            return;
          }
        }
      } else {
        // 守卫只保护内核不可用时的 Dart Floor 回落写入。
        await LegacyWriteGuard.assertAllowed('download');
        final db = await downloadTaskDatabase;
        await db.database.delete('DownloadTaskEntity',
            where: 'appId = ?', whereArgs: [appId]);
      }

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
      final tasks = await _allTasks();
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

      // 删除记录：内核任务在模块自己的库里，只删 Floor 删不掉（列表会"复活"）。
      // 内核可用时逐条走服务接口；不可用时才回落 Floor，并受旧写入守卫保护。
      final service = ModuleManager.instance.get<IDownloadService>();
      if (service != null) {
        final ids = completed.map((t) => t.id).whereType<int>().toList();
        for (final id in ids) {
          if (!await _runServiceAction(
            '清理记录',
            (target) => target.remove(id),
            service: service,
          )) {
            return;
          }
        }
      } else {
        await LegacyWriteGuard.assertAllowed('download');
        final db = await downloadTaskDatabase;
        await db.database.delete(
          'DownloadTaskEntity',
          where: 'status IN (?, ?)',
          whereArgs: [
            DownloadStatusEnum.completed.index,
            DownloadStatusEnum.failed.index,
          ],
        );
      }

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
      final tasks = await _allTasks();

      // 取消所有正在下载的任务
      final service = ModuleManager.instance.get<IDownloadService>();
      for (var item in tasks) {
        if (item.isActive) {
          final id = item.id;
          if (id != null && service != null) {
            if (!await _runServiceAction(
              '清空前取消',
              (target) => target.cancel(id),
              service: service,
            )) {
              return;
            }
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

      // 清空记录：内核任务在模块自己的库里，只清 Floor 清不掉（列表会"复活"）。
      // 内核可用时逐条走服务接口；不可用时才回落 Floor，并受旧写入守卫保护。
      if (service != null) {
        final ids = tasks.map((t) => t.id).whereType<int>().toList();
        for (final id in ids) {
          if (!await _runServiceAction(
            '清空记录',
            (target) => target.remove(id),
            service: service,
          )) {
            return;
          }
        }
      } else {
        await LegacyWriteGuard.assertAllowed('download');
        final db = await downloadTaskDatabase;
        await db.database.delete('DownloadTaskEntity');
      }

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
