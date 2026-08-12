import 'dart:async';

import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/download/DownloadStrategyManager.dart';
import 'package:gstore/core/download/strategy/impl/LocalDbDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/VivoDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/GitHubDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/HttpDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/FdroidDownloadStrategy.dart';
import 'package:gstore/core/service/downloadService.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

import 'state.dart';

/// 应用更新检测逻辑
/// 检测已添加且已安装的应用是否有新版本，支持单个/全部更新
/// 检测统一委托 UpdateManager（锁+时间窗防重），页面负责展示与更新操作
class UpdateLogic extends GetxController {
  final UpdateState state = UpdateState();

  /// 是否已订阅 UpdateManager 结果（避免重复监听）
  bool _subscribed = false;

  @override
  void onInit() {
    super.onInit();
  }

  @override
  Future<void> onReady() async {
    super.onReady();
    final manager = UpdateManagerService.instance;
    _subscribeManager(manager);

    // 缓存优先：等待缓存恢复完成（避免恢复中误判"从未检测"）
    // - 检测进行中（后台触发）→ 直接进入检测中展示（订阅进度/日志，不重新发起）
    // - 已有上次检测记录 → 直接展示缓存结果（不触发耗时检测，手动刷新才检测）
    // - 从未检测过 → 自动检测一次
    await manager.cacheRestored;
    if (manager.isChecking.value) {
      state.isLoading.value = true;
      return;
    }
    if (manager.lastCheckedAt.value != null) {
      state.updateList.assignAll(manager.updateList);
      state.showLog.value = false;
    } else {
      checkUpdates();
    }
  }

  /// 订阅 UpdateManager 结果同步（避免重复监听）
  /// 结果/日志/进度全部走订阅镜像：前台/后台检测共享同一实例状态
  void _subscribeManager(UpdateManagerService manager) {
    if (_subscribed) return;
    _subscribed = true;
    manager.updateList.listen((list) {
      state.updateList.assignAll(list);
      // 同步红点：检测结果与功能入口红点一致
      BadgeService.instance.setBadge(BadgeKey.appUpdate, list.length);
    });
    // 检测日志统一由 UpdateManager 产出（前台/后台同源，含持久化恢复）
    manager.checkLog.listen((logs) {
      state.checkLog.assignAll(logs);
    });
    // 进度镜像：isLoading 随 isChecking（后台检测中进入页面自动显示检测页）
    manager.isChecking.listen((checking) {
      state.isLoading.value = checking;
    });
    manager.checkList.listen((list) => state.checkList.assignAll(list));
    manager.checkedCount.listen((v) => state.checkedCount.value = v);
    manager.totalCount.listen((v) => state.totalCount.value = v);
    manager.checkingAppName.listen((v) => state.checkingAppName.value = v);
    manager.checkingIconUrl.listen((v) => state.checkingIconUrl.value = v);
    manager.currentProgress.listen((p) {
      if (p != null) state.checkIndex.value = p.index;
    });
    // RxList/Rx 的 listen 不回调初始值：缓存可能已在订阅前恢复
    // （如启动时 BadgeService 触发恢复），订阅后必须显式同步当前状态
    state.updateList.assignAll(manager.updateList);
    state.checkLog.assignAll(manager.checkLog);
    state.checkList.assignAll(manager.checkList);
    state.checkedCount.value = manager.checkedCount.value;
    state.totalCount.value = manager.totalCount.value;
    state.checkingAppName.value = manager.checkingAppName.value;
    state.checkingIconUrl.value = manager.checkingIconUrl.value;
    state.isLoading.value = manager.isChecking.value;
    if (manager.currentProgress.value != null) {
      state.checkIndex.value = manager.currentProgress.value!.index;
    }
  }

  /// 检测所有已添加应用是否有更新
  ///
  /// 统一走 UpdateManager（锁防重 + 状态共享）：
  /// - 页面自动进入：onReady 缓存优先/检测中订阅（不重新发起）
  /// - 手动刷新：checkUpdates(force: true) 强制重新检测
  Future<void> checkUpdates({bool force = false}) async {
    final manager = UpdateManagerService.instance;
    if (manager.isChecking.value) return;

    // 幂等订阅（onReady 已订阅时跳过；直接调用场景兜底）
    _subscribeManager(manager);

    state.isLoading.value = true;
    state.updateList.clear();
    state.resetCheckProgress();

    await manager.checkUpdates(force: force);

    state.isLoading.value = false;
    if (manager.updateList.isEmpty) {
      // 无更新：停留检测页展示完整日志（完成提示由 manager 日志统一输出）
      state.checkFinished.value = true;
      state.showLog.value = false;
    } else {
      // 有更新：显示更新列表（默认）；checkFinished 保持 false，避免进入完成态检测页
      state.checkFinished.value = false;
      state.showLog.value = false;
    }
  }

  /// 切换"检测日志页"与"更新列表页"（仅在有更新时有效）
  void toggleLogView() {
    state.showLog.value = !state.showLog.value;
  }

  /// 更新单个应用（下载 + 自动安装）
  Future<void> updateApp(AppUpdateInfo info) async {
    if (state.updatingAppId.value != null) return;

    state.updatingAppId.value = info.appId;

    try {
      final version = info.latestDownload.version ?? info.latestVersion;
      final fileName = info.latestDownload.name;

      // 预创建下载状态用于进度监听
      final status = await DownloadStatus.create(
        info.appId,
        info.appName,
        version,
        fileName,
        info.latestDownload.url,
        downloadSize: info.latestDownload.size,
      );
      state.currentDownload.value = status;

      // 监听进度
      StreamSubscription? sub;
      sub = status.observer.listen((da) {
        state.currentDownload.value = da;
      });

      // 确保下载策略已注册
      _ensureDownloadStrategies();

      // 尝试使用策略模式下载（含代理处理），失败/缓存恢复无详情时降级到普通下载
      try {
        final detail = info.detail;
        if (detail != null) {
          final context = await DownloadStrategyManager.instance.createContext(
            info.latestDownload,
            detail,
          );
          if (context != null) {
            await Get.find<DownloadService>().downloadWithContext(
              context,
              info.appId,
              info.appName,
              version,
              fileName,
            );
          } else {
            await Get.find<DownloadService>().download(
              info.appId,
              info.appName,
              version,
              info.latestDownload.url,
              fileName,
              downloadSize: info.latestDownload.size,
            );
          }
        } else {
          // 缓存恢复（detail 未持久化）→ 直接普通下载
          await Get.find<DownloadService>().download(
            info.appId,
            info.appName,
            version,
            info.latestDownload.url,
            fileName,
            downloadSize: info.latestDownload.size,
          );
        }
      } catch (e) {
        appLog.error('UpdateLogic: 策略下载失败，降级到普通下载 - $e');
        await Get.find<DownloadService>().download(
          info.appId,
          info.appName,
          version,
          info.latestDownload.url,
          fileName,
          downloadSize: info.latestDownload.size,
        );
      }

      await sub.cancel();

      // 下载完成（DownloadService 内部已自动安装 APK）：
      // 通知 UpdateManager 刷新状态（复核版本后从可更新列表移除，红点自动更新）
      await UpdateManagerService.instance.markUpdated(info.appId);
      // 同步页面列表（UpdateManager 订阅也会同步，这里双保险）
      state.updateList.removeWhere((e) => e.appId == info.appId);
      Get.snackbar(
        '更新完成',
        '${info.appName} 已更新到 $version',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      appLog.error('UpdateLogic: 更新 ${info.appName} 失败 - $e');
      Get.snackbar(
        '更新失败',
        '${info.appName} 更新失败，请重试',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Get.theme.colorScheme.errorContainer,
        duration: const Duration(seconds: 3),
      );
    } finally {
      state.updatingAppId.value = null;
      state.currentDownload.value = null;
    }
  }

  /// 更新所有可更新应用
  Future<void> updateAll() async {
    if (state.updatingAppId.value != null) return;
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
      appLog.info('UpdateLogic: 已注册 ${manager.strategyCount} 个下载策略');
    }
  }
}
