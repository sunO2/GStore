import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show compute, debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/download/download_module_unavailable_exception.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/db/apps/AppInfo.dart';

import 'download_status_utils.dart';

/// 目录门面（catalog 归 Rust core：`CatalogFacade` 恒走 `FrbCatalogBackend`）。
///
/// 下载面板的应用信息（图标/名称）读路径与写路径同源，不再直读旧 `apps.db`。
final downloadCatalogFacadeProvider = Provider<CatalogFacade>((ref) {
  return CatalogFacade.instance;
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
  final CatalogFacade? catalogFacade;

  DownloadManagerNotifier({this.catalogFacade});

  /// 单一「列表级」watch 订阅（service.watchAll()）。
  ///
  /// 历史（操作卡顿根因）：曾对每个任务各建一条 `service.watch(id)` 订阅。内核的
  /// `watchAll` 是**每条订阅一个** 500 ms 轮询线程，且每次轮询都跑一遍全量
  /// `reconcile()` + `list_core()`（见 `rust/gstore_host/src/bridge.rs`
  /// `DownloadApi::watch_all` 与 `download_host.rs` `refresh_and_list`）。
  /// N 个任务 → N 条线程、N 份全量 sweep；而 `watch(id)` 只是 `watchAll()` 的
  /// 按 id 过滤，于是每条线程都把全部变更行回灌 UI isolate → 每 tick 有
  /// N×变更数 次事件，每次都整体替换 `state` → 列表反复重建 → 卡顿。
  /// 现改为**一条** `watchAll()` 订阅，事件按任务扇出进 state；重试/复活类动作
  /// 按需重建这一条订阅（拿到全新的内核 watch 状态，见 [_resetWatchSubscription]）。
  StreamSubscription<DownloadTask>? _watchSub;

  /// watch 关闭/出错后的延迟重载（debounce，防 onDone 风暴）
  Timer? _reloadTimer;

  IDownloadService? _service;

  /// loadTasks 合并：进行中再来的请求只标记一次待跑，避免 watch 首帧 + 动作刷新
  /// 叠加成重载风暴。
  bool _loadInFlight = false;
  bool _reloadPending = false;

  /// `_refreshMissingFiles` 上次扫描的「已完成任务签名」；未变化则跳过整轮扫描。
  String? _missingScanKey;

  /// 应用信息并发加载中集合（防同一应用重复查询）
  final Set<String> _appInfoLoading = {};

  @override
  DownloadPageState build() {
    // 打开下载页也是「该把全局 watcher 拉起来」的触发点：它会经 watchAll()
    // 装配通知与自动安装，而不必在冷启动的模块注册阶段就加载下载内核。
    DownloadTaskWatcher.instance.start(RustDownloadService.instance);
    ref.onDispose(() {
      _reloadTimer?.cancel();
      _watchSub?.cancel();
      _watchSub = null;
    });
    return const DownloadPageState();
  }

  /// 页面挂载后加载任务（view initState 调用，等价原 onReady）。
  Future<void> load() async {
    _service = ModuleManager.instance.get<IDownloadService>();
    // 页面每次挂载都强制重扫「已完成文件是否存在」：缓存管理页等外部删除后
    // 回到本页要能立刻显示「已删除」；其后的调用再按签名跳过重复扫描。
    _missingScanKey = null;
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
  /// 直接读 Floor 会导致「切了内核但面板看不到任务」。下载内核只有一个
  /// （`IDownloadService` → `RustDownloadService`）；服务缺失是**类型化失败**，
  /// 绝不静默回落到 Dart Floor。
  Future<List<DownloadTask>> _allTasks() async {
    final svc = _service ?? ModuleManager.instance.get<IDownloadService>();
    if (svc == null) {
      throw DownloadModuleUnavailableException();
    }
    return svc.listTasks();
  }

  /// 从新管线仓库加载全部任务并重建分组
  Future<void> loadTasks() async {
    // 合并并发加载：watch 首帧、动作后刷新、debounce 重载可能同时到达；进行中
    // 只记一次待跑，避免叠加成重载风暴。
    if (_loadInFlight) {
      _reloadPending = true;
      return;
    }
    _loadInFlight = true;
    try {
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
      _ensureWatchSubscription();
      // 预取应用信息（异步，不阻塞 UI）
      unawaited(_prefetchAppInfos(state.latestGroups));
      // 异步核对已完成任务的文件是否仍存在（外部删除后更新缺失标记）
      unawaited(_refreshMissingFiles(tasks));
    } finally {
      _loadInFlight = false;
      if (_reloadPending) {
        _reloadPending = false;
        unawaited(loadTasks());
      }
    }
  }

  /// 检查已完成任务的主文件是否仍存在；缺失的记入 [missingFileIds]。
  ///
  /// 磁盘扫描（每个已完成任务一次 `File.exists`）在独立 isolate 里批量执行，
  /// 不在 UI isolate 上堆叠回调；且当「已完成任务签名」(id + 路径) 与上次一致
  /// 时整轮跳过，避免每次 loadTasks 都重扫磁盘。
  Future<void> _refreshMissingFiles(List<DownloadTask> tasks) async {
    final completed = <DownloadTask>[];
    for (final t in tasks) {
      if (t.id != null && t.status == DownloadStatusEnum.completed) {
        completed.add(t);
      }
    }
    // 变更签名：已完成任务的 (id, filePath) 集合。
    final key =
        (completed.map((t) => '${t.id}:${t.filePath}').toList()..sort()).join('|');
    if (key == _missingScanKey) return;
    _missingScanKey = key;

    if (completed.isEmpty) {
      if (state.missingFileIds.isNotEmpty) {
        state = state.copyWith(missingFileIds: const {});
      }
      return;
    }

    final entries = completed
        .map((t) => (t.id!, t.filePath))
        .toList(growable: false);
    // 磁盘扫描在独立 isolate 批量执行（生产默认），避免 UI isolate 上逐任务
    // File.exists 回调堆叠。测试可注入同步实现，去掉 isolate 调度时序依赖。
    final missing = await DownloadManagerNotifier.scanMissingFiles(entries);
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

  /// 由全量任务构建分组并发布。
  ///
  /// 数据未变化时**不替换 state**：Riverpod 只在 state 引用变化时通知，整体替换
  /// 会让列表每 tick 重建一次。这里先比较分组，内容一致直接返回。
  void _buildGroups(List<DownloadTask> tasks) {
    var map = <String, List<DownloadTask>>{};
    for (var item in tasks) {
      var key = "${item.appId}_${item.version}";
      var list = map[key] ??= [];
      list.add(item);
    }
    final latest = List<List<DownloadTask>>.from(map.values);
    if (_sameGroups(latest, state.latestGroups)) return;
    state = state.copyWith(
      latestGroups: latest,
      groups: _applyFilter(latest, state.filter),
    );
  }

  /// 建立**唯一**的列表级 watch 订阅（`service.watchAll()`）。
  ///
  /// 幂等：已订阅则直接返回。重试/复活类动作需要「全新订阅」以拿到全新的内核
  /// watch 终态闩锁时，先 [_resetWatchSubscription] 再经 [loadTasks] 重建。
  void _ensureWatchSubscription() {
    if (_watchSub != null) return;
    final service = _service;
    if (service == null) return;
    _watchSub = service.watchAll().listen(
          _onTaskUpdate,
          onError: (_) {
            _resetWatchSubscription();
            _scheduleReload();
          },
          onDone: () {
            _resetWatchSubscription();
            _scheduleReload();
          },
        );
  }

  /// 取消当前列表级订阅，使下一次 [loadTasks] 重建一条全新的订阅。
  ///
  /// 内核的 watch 变更检测对**每条订阅**按 id 记住「终态只发一次」：一个曾处于
  /// failed/completed 等终态的任务被 retry/restart 复活后，复用的旧订阅永远不会
  /// 再推送它的新进度/完成（见 `rust/gstore_host/src/download_host.rs` 的
  /// `DownloadWatchState`）。因此复活类动作必须换一条全新订阅，否则列表会一直
  /// 停在旧状态。改为单订阅后，重建整条订阅即重置了全部任务的终态闩锁。
  void _resetWatchSubscription() {
    final sub = _watchSub;
    _watchSub = null;
    if (sub != null) unawaited(sub.cancel());
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
          // 内容未变 → 不替换 state（不触发列表重建）。watch 首帧会重放全部
          // 变更行，其中多数与本地一致，跳过它们避免整列表重建。
          if (_sameTask(group[j], task)) return;
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
          } else if (state.missingFileIds.contains(id)) {
            // 仅当该任务此前被标记为「文件缺失」时才需要清理；否则不替换
            // missingFileIds（否则每次进度更新都会多触发一次 state 通知/重建）。
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
    final CatalogFacade facade =
        catalogFacade ?? ref.read(downloadCatalogFacadeProvider);
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
      // 读路径与 core 同源：走 CatalogFacade（flag on 读 Rust core / flag off
      // 回落旧 backend），不再直读旧 apps.db。
      final summary = await facade.getApp(appId);
      final info = summary == null
          ? null
          : AppInfo(
              summary.appId,
              summary.name,
              summary.user,
              summary.repositories,
              summary.icon,
              summary.des,
              summary.category,
            );
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

  /// 磁盘存在性扫描接缝：生产在独立 isolate（[compute]）批量扫描已完成任务文件，
  /// 避免 UI isolate 上逐任务 `File.exists` 回调堆叠；测试注入同步实现以去掉
  /// isolate 调度时序依赖。
  @visibleForTesting
  static Future<Set<int>> Function(List<(int, String)> entries) scanMissingFiles =
      (entries) async {
    try {
      return await compute(_scanMissingFiles, entries);
    } catch (_) {
      // 受限环境 isolate 不可用 → 回落到 UI isolate 单批扫描。
      return _scanMissingFiles(entries);
    }
  };

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
  ///
  /// 显式点击「安装」意味着"安装/覆盖安装"：即使核心行已是 `installed` 也传
  /// [force] = true，走覆盖安装（Shizuku/系统安装器），不再只提示「已安装」而
  /// 什么都不做（用户需求：点击安装显示已安装，应可覆盖安装）。
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
      final (outcome, method) =
          await manager.installApk(downStatus.filePath, force: true);
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
    _resetWatchSubscription();
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
    _resetWatchSubscription();
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
        // 失败任务属于终态：批量重试后统一换新订阅（见下方 _resetWatchSubscription），
        // 避免旧订阅的终态闩锁吞掉新进度。
        retried = true;
      }
    }
    // 批量重试后必须重载：失败任务在列表里是终态，watch 不会主动刷新它们。
    if (retried) {
      _resetWatchSubscription();
      await loadTasks();
    }
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
      //    Rust 内核的任务存在模块自己的库里，只删 Floor 是删不掉的（列表会"复活"）。
      //    服务缺失时 _runServiceAction 给出类型化提示，绝不回落 Dart Floor。
      if (id != null) {
        if (!await _runServiceAction(
          '删除记录',
          (target) => target.remove(id),
          service: service,
        )) {
          return;
        }
      }

      // 4. 刷新列表
      await loadTasks();

      AppDialogs.showSuccess(
        '已删除 ${downStatus.appName} 的下载记录',
        title: '已删除',
      );
    } on DownloadModuleUnavailableException catch (e) {
      AppDialogs.showError(e.userMessage, title: '删除失败');
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

      await loadTasks();

      AppDialogs.showSuccess(
        '已删除该应用的所有下载记录',
        title: '已删除',
      );
    } on DownloadModuleUnavailableException catch (e) {
      AppDialogs.showError(e.userMessage, title: '删除失败');
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
      // 逐条走服务接口；服务缺失时给出类型化提示，绝不回落 Dart Floor。
      final service = ModuleManager.instance.get<IDownloadService>();
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

      // 刷新列表
      await loadTasks();

      final count = completed.length;
      AppDialogs.showSuccess(
        count > 0 ? '已清理 $count 条已完成记录' : '没有需要清理的记录',
        title: '清理完成',
      );
    } on DownloadModuleUnavailableException catch (e) {
      AppDialogs.showError(e.userMessage, title: '清理失败');
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
      // 逐条走服务接口；服务缺失时给出类型化提示，绝不回落 Dart Floor。
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

      // 刷新列表
      await loadTasks();

      AppDialogs.showSuccess(
        '已清空所有下载记录',
        title: '清空完成',
      );
    } on DownloadModuleUnavailableException catch (e) {
      AppDialogs.showError(e.userMessage, title: '清空失败');
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

/// 批量扫描已完成任务的主文件是否存在，返回缺失文件的 id 集合。
///
/// 顶层函数：供 [compute] 在独立 isolate 中执行，避免 UI isolate 上逐任务
/// `File.exists` 回调堆叠。
Future<Set<int>> _scanMissingFiles(List<(int, String)> entries) async {
  final missing = <int>{};
  for (final (id, path) in entries) {
    try {
      if (!await File(path).exists()) missing.add(id);
    } catch (_) {
      missing.add(id);
    }
  }
  return missing;
}

/// 两个任务在「列表可见字段」上是否等价（用于避免无变化时重建列表）。
///
/// 刻意忽略 createdAt / updatedAt：它们变化不改变列表外观，若纳入比较会让
/// 内核每 tick 的 updated_at 刷新都触发一次整体重建。
bool _sameTask(DownloadTask a, DownloadTask b) {
  if (identical(a, b)) return true;
  if (a.id != b.id ||
      a.appId != b.appId ||
      a.appName != b.appName ||
      a.version != b.version ||
      a.fileName != b.fileName ||
      a.url != b.url ||
      a.filePath != b.filePath ||
      a.total != b.total ||
      a.received != b.received ||
      a.status != b.status ||
      a.speedBps != b.speedBps ||
      a.etaSec != b.etaSec ||
      a.error != b.error ||
      a.installAfterDownload != b.installAfterDownload ||
      a.lastStartedAt != b.lastStartedAt) {
    return false;
  }
  final sa = a.segments;
  final sb = b.segments;
  if (sa == null || sb == null) return sa == sb;
  if (sa.length != sb.length) return false;
  for (var i = 0; i < sa.length; i++) {
    final x = sa[i];
    final y = sb[i];
    if (x.index != y.index ||
        x.startByte != y.startByte ||
        x.endByte != y.endByte ||
        x.received != y.received) {
      return false;
    }
  }
  return true;
}

/// 两组分组在「列表可见字段」上是否等价。
bool _sameGroups(List<List<DownloadTask>> a, List<List<DownloadTask>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final ga = a[i];
    final gb = b[i];
    if (ga.length != gb.length) return false;
    for (var j = 0; j < ga.length; j++) {
      if (!_sameTask(ga[j], gb[j])) return false;
    }
  }
  return true;
}

final downloadManagerProvider =
    NotifierProvider<DownloadManagerNotifier, DownloadPageState>(
  DownloadManagerNotifier.new,
);
