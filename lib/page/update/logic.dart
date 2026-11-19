
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/rust/core_bootstrap.dart';
import 'package:gstore/core/download/strategy/impl/FdroidDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/GitHubDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/HttpDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/LocalDbDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/VivoDownloadStrategy.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/update/apk_matcher.dart';

import 'state.dart';

/// 应用更新检测控制器（Riverpod AutoDisposeNotifier）。
///
/// 检测统一委托 UpdateFacade（flag off → legacy 服务，flag on → Rust core），
/// 页面只做状态镜像与更新操作。结果/日志/进度全部走订阅镜像：
/// 前台/后台检测共享同一服务实例状态。
class UpdateNotifier extends AutoDisposeNotifier<UpdateState> {
  /// 是否已订阅 UpdateManager 结果（避免重复监听）
  bool _subscribed = false;

  /// 是否已释放（async 回调后写 state 前检查）
  bool _disposed = false;

  /// 下载任务流订阅
  final List<StreamSubscription<dynamic>> _subs = [];

  UpdateFacade get _manager => UpdateFacade.instance;

  @override
  UpdateState build() {
    ref.onDispose(_dispose);
    // 首帧初始化（onReady 语义）：订阅服务镜像 + 缓存恢复后决策
    Future.microtask(() {
      if (_disposed) return;
      _initialize();
    });
    return const UpdateState();
  }

  void _dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  Future<void> _initialize() async {
    final manager = _manager;
    _subscribeManager(manager);

    // 缓存优先：等待缓存恢复完成（避免恢复中误判"从未检测"）
    // - 检测进行中（后台触发）→ 直接进入检测中展示（订阅进度/日志，不重新发起）
    // - 已有上次检测记录 → 直接展示缓存结果（不触发耗时检测，手动刷新才检测）
    // - 从未检测过 → 自动检测一次
    await manager.cacheRestored;
    if (_disposed) return;
    if (manager.isChecking) {
      state = state.copyWith(isLoading: true);
      return;
    }
    if (manager.lastCheckedAt != null) {
      state = state.copyWith(
        updateList: List.of(manager.updateList),
        showLog: false,
        // 无更新缓存：展示检测完成页（含历史日志），而非纯空态
        checkFinished: manager.updateList.isEmpty,
      );
    } else {
      await checkUpdates();
    }
  }

  /// 订阅 UpdateManager 结果同步（避免重复监听）
  void _subscribeManager(UpdateFacade manager) {
    if (_subscribed) return;
    _subscribed = true;
    _subs.add(manager.updateListStream.listen((list) {
      if (_disposed) return;
      state = state.copyWith(updateList: List.of(list));
      // 结果同步后计算各应用默认选中（偏好匹配；无偏好不设，视图回退 latestDownload）
      unawaited(_syncDefaultSelections(List.of(list)));
      // 同步红点：检测结果与功能入口红点一致
      BadgeService.instance.setBadge(BadgeKey.appUpdate, list.length);
    }));
    // 检测日志统一由 UpdateManager 产出（前台/后台同源，含持久化恢复）
    _subs.add(manager.checkLogStream.listen((logs) {
      if (_disposed) return;
      state = state.copyWith(checkLog: List.of(logs));
    }));
    // 进度镜像：isLoading 随 isChecking（后台检测中进入页面自动显示检测页）
    _subs.add(manager.isCheckingStream.listen((checking) {
      if (_disposed) return;
      state = state.copyWith(isLoading: checking);
    }));
    _subs.add(manager.checkListStream.listen((list) {
      if (_disposed) return;
      state = state.copyWith(checkList: List.of(list));
    }));
    _subs.add(manager.checkedCountStream.listen((v) {
      if (_disposed) return;
      state = state.copyWith(checkedCount: v);
    }));
    _subs.add(manager.totalCountStream.listen((v) {
      if (_disposed) return;
      state = state.copyWith(totalCount: v);
    }));
    _subs.add(manager.checkingAppNameStream.listen((v) {
      if (_disposed) return;
      state = state.copyWith(checkingAppName: v);
    }));
    _subs.add(manager.checkingIconUrlStream.listen((v) {
      if (_disposed) return;
      state = state.copyWith(checkingIconUrl: v);
    }));
    _subs.add(manager.currentProgressStream.listen((p) {
      if (_disposed) return;
      if (p != null) state = state.copyWith(checkIndex: p.index);
    }));
    // broadcast stream 的 listen 不回调初始值：缓存可能已在订阅前恢复
    // （如启动时 BadgeService 触发恢复），订阅后必须显式同步当前状态
    state = state.copyWith(
      updateList: List.of(manager.updateList),
      checkLog: List.of(manager.checkLog),
      checkList: List.of(manager.checkList),
      checkedCount: manager.checkedCount,
      totalCount: manager.totalCount,
      checkingAppName: manager.checkingAppName,
      checkingIconUrl: manager.checkingIconUrl,
      isLoading: manager.isChecking,
    );
    if (manager.currentProgress != null) {
      state = state.copyWith(checkIndex: manager.currentProgress!.index);
    }
    unawaited(_syncDefaultSelections(List.of(manager.updateList)));
  }

  /// 检测所有已添加应用是否有更新
  ///
  /// 统一走 UpdateFacade（锁防重 + 状态共享）：
  /// - 页面自动进入：build 后缓存优先/检测中订阅（不重新发起）
  /// - 手动刷新：checkUpdates(force: true) 强制重新检测
  ///
  /// [refreshInventory] 会让核心在检测前重新从 `PackageManager` 读取已安装
  /// 应用并推送新快照。核心只按自己的 `installed_app` 快照判断版本，快照陈旧
  /// 时（详情页/下载页/系统安装器/外部商店完成更新）会一直显示旧版本，因此
  /// 手动刷新必须带上它。
  Future<void> checkUpdates({
    bool force = false,
    bool refreshInventory = false,
  }) async {
    final manager = _manager;
    if (manager.isChecking) return;

    // 幂等订阅（_initialize 已订阅时跳过；直接调用场景兜底）
    _subscribeManager(manager);

    state = state.copyWith(
        isLoading: true, updateList: const [], clearErrorMessage: true);
    _resetCheckProgress();

    try {
      await manager.checkUpdates(
        force: force,
        refreshInventory: refreshInventory,
      );
    } on CoreUpdateException catch (error) {
      // typed core rejection (CORE_E_FACTS_MISSING / CORE_E_INVENTORY_STALE /
      // CORE_E_UPDATE_CUTOVER_ORDER): surface it, never fall back silently.
      if (_disposed) return;
      state = state.copyWith(
        isLoading: false,
        checkFinished: false,
        errorMessage: error.toString(),
      );
      return;
    }

    if (_disposed) return;
    if (manager.updateList.isEmpty) {
      // 无更新：停留检测页展示完整日志（完成提示由 manager 日志统一输出）
      state =
          state.copyWith(checkFinished: true, showLog: false, isLoading: false);
    } else {
      // 有更新：显示更新列表（默认）；checkFinished 保持 false，避免进入完成态检测页
      state = state.copyWith(
          checkFinished: false, showLog: false, isLoading: false);
    }
  }

  void _resetCheckProgress() {
    state = state.copyWith(
      checkedCount: 0,
      totalCount: 0,
      checkList: const [],
      checkIndex: 0,
      checkLog: const [],
    );
  }

  /// 切换"检测日志页"与"更新列表页"（仅在有更新时有效）
  void toggleLogView() {
    state = state.copyWith(showLog: !state.showLog);
  }

  /// 用户手动选择某应用的下载 APK 候选
  ///
  /// - 更新内存选中（立即生效，卡片勾选跟随）
  /// - 持久化偏好（channelId:appId → 文件名），下次检测/更新优先匹配该文件名
  Future<void> selectApk(AppUpdateInfo info, DownloadInfo download) async {
    final key = updateSelectionKey(info);
    state = state.copyWith(
      selectedApkName: {
        ...state.selectedApkName,
        key: download.name,
      },
    );
    try {
      await _manager.setPreferredApk(
        channelId: info.channelId,
        appId: info.appId,
        fileName: download.name,
      );
    } catch (e) {
      // 持久化失败不影响内存选择（本会话内仍然生效）
      appLog.error('UpdateNotifier: 保存 APK 偏好失败 - $e');
    }
    // 保存完成后重断言：避免并发 _syncDefaultSelections 读到旧偏好覆盖本次选择
    if (!_disposed) {
      state = state.copyWith(
        selectedApkName: {
          ...state.selectedApkName,
          key: download.name,
        },
      );
    }
    // 同步内存镜像：离开/重返更新页时默认勾选仍指向本次选择。
    _manager.adoptPreferredDownload(info.withLatestDownload(download));
  }

  /// 检测结果同步后：修剪失效选择（不在此处计算默认项）。
  ///
  /// 默认项由 core 的 `latestDownload` 承担：Rust 已在 `list()` 中按记忆的
  /// 偏好重新投影，因此这里只需移除不再存在的应用/文件，不复制匹配逻辑。
  Future<void> _syncDefaultSelections(List<AppUpdateInfo> list) async {
    if (_disposed) return;
    final infosByKey = {
      for (final info in list) updateSelectionKey(info): info
    };
    final selected = Map<String, String>.from(state.selectedApkName)
      ..removeWhere((k, _) => !infosByKey.containsKey(k));
    for (final entry in selected.entries.toList()) {
      final current = entry.value;
      if (current.isEmpty) continue;
      final info = infosByKey[entry.key]!;
      final candidates = filterInstallableDownloads(info.downloads);
      if (candidates.isNotEmpty && !candidates.any((d) => d.name == current)) {
        // 候选已变化（版本更新等）：丢弃陈旧文件名，回退 latestDownload
        selected.remove(entry.key);
      }
    }
    if (!_disposed) {
      state = state.copyWith(selectedApkName: selected);
    }
  }

  /// 确定本次更新下载的 APK：用户所选（须在候选列表中） ?? 默认规则结果
  DownloadInfo _resolveDownload(AppUpdateInfo info) {
    final selectedName = state.selectedApkName[updateSelectionKey(info)];
    if (selectedName != null && selectedName.isNotEmpty) {
      final candidates = filterInstallableDownloads(info.downloads);
      for (final candidate in candidates) {
        if (candidate.name == selectedName) return candidate;
      }
    }
    return info.latestDownload;
  }

  /// 更新单个应用（下载 + 自动安装）
  Future<void> updateApp(AppUpdateInfo info) async {
    if (state.updatingAppId != null) return;

    state = state.copyWith(updatingAppId: info.appId);

    // 下载模块下线 → 注册表取不到服务，降级提示不抛
    final service = ModuleManager.instance.get<IDownloadService>();
    if (service == null) {
      AppDialogs.showWarning('下载模块未启用');
      state = state.copyWith(clearUpdatingAppId: true);
      return;
    }
    // 在任务开始前订阅全局 watcher，避免下载完成事件早于惰性订阅而漏掉自动安装。
    DownloadTaskWatcher.instance.start(service);

    try {
      // 本次下载 = 用户所选（须匹配 detail.downloads） ?? 现规则结果（latestDownload
      // 已是偏好匹配后的默认项）；缓存恢复 detail=null → 直接用 latestDownload
      final download = _resolveDownload(info);
      final version = download.version ?? info.latestVersion;
      final fileName = download.name;

      // 确保下载策略已注册
      _ensureDownloadStrategies();

      // 尝试使用策略模式下载（含代理处理），失败/缓存恢复无详情时降级到普通下载
      DownloadTask task;
      try {
        task = await _startDownloadTask(
            service, info, download, version, fileName);
      } catch (e) {
        appLog.error('UpdateNotifier: 策略下载失败，降级到普通下载 - $e');
        task = await service.download(
          info.appId,
          info.appName,
          version,
          download.url,
          fileName,
          downloadSize: download.size,
        );
      }

      // 监听进度并等待任务进入终止态（完成/失败/取消/暂停）
      state = state.copyWith(currentDownload: task);
      final done = await _awaitDownloadTerminal(service, task);

      if (done.status != DownloadStatusEnum.completed) {
        throw StateError('下载未完成（状态：${done.status}）');
      }

      // 下载完成后由 watcher/InstallManager 执行安装；安装失败时保留更新项，
      // 不能把“下载完成”当成“已更新”。
      if (ModuleManager.instance.get<InstallManager>() == null) {
        AppDialogs.showWarning('安装模块未启用，已下载但不会自动安装');
        return;
      }
      final installOutcome = await _installDownloadedApk(done);
      if (installOutcome == InstallOutcome.failed) {
        AppDialogs.showError(
          '${info.appName} 下载完成，但安装失败，请重试',
          title: '安装失败',
        );
        return;
      }

      // Shizuku/已安装路径是同步结果；先刷新核心清单，markUpdated 才能看到新版本。
      if (installOutcome == InstallOutcome.installed ||
          installOutcome == InstallOutcome.alreadyInstalled) {
        await CoreBootstrap.refreshInventory();
      }

      // 只有已安装版本真正追平 latestVersion，core 才会返回 true。
      final marked = await _manager.markUpdated(info.appId);
      if (!_disposed) {
        if (marked) {
          _removeUpdated(info);
          AppDialogs.showSuccess('${info.appName} 已更新到 $version',
              title: '更新完成');
        } else {
          AppDialogs.showInfo(
            '${info.appName} 已下载，等待安装完成',
            title: '安装中',
          );
          if (installOutcome != null) {
            unawaited(_pollInstalledThenRemove(info, done));
          }
        }
      }
    } catch (e) {
      appLog.error('UpdateNotifier: 更新 ${info.appName} 失败 - $e');
      if (!_disposed) {
        AppDialogs.showError('${info.appName} 更新失败，请重试', title: '更新失败');
      }
    } finally {
      if (!_disposed) {
        state = state.copyWith(
            clearUpdatingAppId: true, clearCurrentDownload: true);
      }
    }
  }

  /// 下载完成后按任务标记触发安装；安装模块不可用时明确提示并保留更新项。
  Future<InstallOutcome?> _installDownloadedApk(DownloadTask task) async {
    if (!task.installAfterDownload) {
      appLog.warning('UpdateNotifier: 下载任务未标记自动安装，更新页强制安装');
    }
    final installTask = task.installAfterDownload
        ? task
        : task.copyWith(installAfterDownload: true);
    return DownloadTaskWatcher.instance.ensureAutoInstall(
      installTask,
      forceRetry: true,
    );
  }

  void _removeUpdated(AppUpdateInfo info) {
    if (_disposed) return;
    state = state.copyWith(
      updateList: state.updateList
          .where(
              (e) => !(e.channelId == info.channelId && e.appId == info.appId))
          .toList(),
    );
  }

  /// 系统安装器返回后安装结果可能延迟落库；后台轮询安装状态/版本追平后移除。
  Future<void> _pollInstalledThenRemove(
    AppUpdateInfo info,
    DownloadTask task,
  ) async {
    final moduleTaskId = task.id?.toString();
    for (var attempt = 0; attempt < 30; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (_disposed) return;

      var installed = false;
      if (moduleTaskId != null) {
        try {
          final record = await InstallFacade.instance.get(moduleTaskId);
          installed = record?.status == 'installed';
          if (record?.status == 'failed' ||
              record?.status == 'denied' ||
              record?.status == 'timeout') {
            if (!_disposed) {
              AppDialogs.showError(
                '${info.appName} 安装失败，请重试',
                title: '安装失败',
              );
            }
            return;
          }
        } catch (_) {
          // 核心尚未就绪：继续轮询到 deadline。
        }
      }

      if (installed) {
        await CoreBootstrap.refreshInventory();
        if (_disposed) return;
      }

      final marked = await _manager.markUpdated(info.appId);
      if (_disposed) return;
      if (!marked) continue;
      _removeUpdated(info);
      AppDialogs.showSuccess(
        '${info.appName} 已更新到 ${info.latestVersion}',
        title: '更新完成',
      );
      return;
    }
  }

  /// 启动一次下载：优先策略模式（含代理处理），无详情/策略不可用时回退普通下载
  Future<DownloadTask> _startDownloadTask(
    IDownloadService service,
    AppUpdateInfo info,
    DownloadInfo download,
    String version,
    String fileName,
  ) async {
    final detail = info.detail;
    if (detail != null) {
      final request = await DownloadStrategyManager.instance.createRequest(
        download,
        detail,
      );
      if (request != null) {
        return service.downloadWithContext(
          request,
          info.appId,
          info.appName,
          version,
          fileName,
        );
      }
    }
    return service.download(
      info.appId,
      info.appName,
      version,
      download.url,
      fileName,
      downloadSize: download.size,
    );
  }

  /// 订阅下载任务流同步进度，并等待任务进入终止态（完成/失败/取消/暂停）
  Future<DownloadTask> _awaitDownloadTerminal(
    IDownloadService service,
    DownloadTask task,
  ) async {
    final id = task.id;
    if (id == null) return task;
    final completer = Completer<DownloadTask>();
    StreamSubscription<DownloadTask>? sub;
    sub = service.watch(id).listen((da) {
      if (_disposed) return;
      state = state.copyWith(currentDownload: da);
      if (_isTerminal(da.status) && !completer.isCompleted) {
        completer.complete(da);
      }
    });
    // 竞态兜底：任务在订阅前已终止（极快完成 / 已有完成态记录）时
    // watch 不再推送，直接读取当前状态终结等待
    final current = await service.getTask(id);
    if (current != null &&
        _isTerminal(current.status) &&
        !completer.isCompleted) {
      completer.complete(current);
    }
    final done = await completer.future;
    await sub.cancel();
    return done;
  }

  /// 是否为下载终止态
  bool _isTerminal(DownloadStatusEnum status) =>
      status == DownloadStatusEnum.completed ||
      status == DownloadStatusEnum.failed ||
      status == DownloadStatusEnum.cancelled ||
      status == DownloadStatusEnum.paused;

  /// 更新所有可更新应用
  Future<void> updateAll() async {
    if (state.updatingAppId != null) return;
    final items = List<AppUpdateInfo>.from(state.updateList);
    for (final info in items) {
      if (state.updateList.isEmpty) break;
      await updateApp(info);
    }
  }

  /// 确保下载策略已注册
  void _ensureDownloadStrategies() {
    final manager = DownloadStrategyManager.instance;
    if (manager.strategyCount == 0) {
      manager.registerAll([
        LocalDbDownloadStrategy(),
        VivoDownloadStrategy(),
        GitHubDownloadStrategy(),
        HttpDownloadStrategy(),
        FdroidDownloadStrategy(),
      ]);
      appLog.info('UpdateNotifier: 已注册 ${manager.strategyCount} 个下载策略');
    }
  }
}

/// 应用更新页 provider（页面级 autoDispose）。
final updateProvider =
    NotifierProvider.autoDispose<UpdateNotifier, UpdateState>(
  UpdateNotifier.new,
);
