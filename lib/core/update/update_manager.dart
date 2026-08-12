/// 集中式更新管理服务
///
/// 统一的更新检测入口 + 状态仓库 + 缓存：
/// - 消除启动/更新页/Agent 三处重复检测（锁 + 时间窗）
/// - 检测结果以 Rx 状态暴露，供红点/可更新分区/更新页/Agent 共用
/// - 支持手动强制检测、Agent 单应用查询、安装后状态刷新
/// - 启动恢复缓存结果（重启后立即可展示上次可更新应用）
/// - 检测过程输出详细日志（onLog）与逐应用进度（onProgress），供更新页滚轮/图标/日志展示
library;

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_cache.dart';
import 'package:gstore/core/update/update_log.dart';

/// 更新检测状态
class UpdateManagerService extends GetxService {
  static UpdateManagerService get instance => Get.find<UpdateManagerService>();

  /// 可更新应用列表（单次检测的完整明细）
  final RxList<AppUpdateInfo> updateList = <AppUpdateInfo>[].obs;

  /// 是否正在检测
  final RxBool isChecking = false.obs;

  /// 上次检测时间（内存态）
  /// 上次检测时间（Rx：页面副标题/时间窗实时响应）
  final Rx<DateTime?> lastCheckedAt = Rx<DateTime?>(null);

  /// 缓存恢复完成标志（页面进入时等待，避免恢复未完成误判"从未检测"）
  late final Future<void> cacheRestored = _restoreCache();

  /// 时间窗（小时）：非强制检测时，距上次检测不足该时长则跳过
  static const int cacheValidHours = 1;

  @override
  void onInit() {
    super.onInit();
    // 启动恢复缓存结果：重启后立即展示上次检测出的可更新应用（后台静默刷新）
    unawaited(cacheRestored);
  }

  /// 从缓存恢复上次检测结果
  Future<void> _restoreCache() async {
    try {
      final cached = await UpdateCache.loadResults();
      if (cached.isNotEmpty) {
        updateList.assignAll(cached);
        appLog.info('UpdateManager: 已恢复缓存结果 ${cached.length} 个可更新应用');
      }
      final last = await UpdateCache.lastCheckedAt();
      if (last != null) lastCheckedAt.value = last;
    } catch (e) {
      appLog.error('UpdateManager: 恢复缓存失败 - $e');
    }
  }

  /// 启动后懒检测（后台静默；时间窗内跳过）
  /// 结果为空时必须检测：时间窗仅用于"已有结果"时的防重，
  /// 不能因时间窗跳过而导致启动后看不到可更新应用
  Future<void> ensureChecked({bool force = false}) async {
    // 锁：检测中直接返回（不重复、不排队）
    if (isChecking.value) return;

    // 时间窗：非强制、已有结果、缓存有效 → 跳过
    if (!force && updateList.isNotEmpty && await _isCacheValid()) return;

    await checkUpdates(force: true);
  }

  /// 主动检测（页面刷新 / 手动触发）
  /// [onProgress] 逐应用进度回调（检测前 appId 占位，检测后携带名称/图标），供更新页滚轮/图标/进度展示
  /// [onLog] 检测过程日志回调（渠道不可用/未安装/版本对比/发现更新等），供更新页日志输出
  /// [onCheckList] 待检测应用名列表回调（检测前一次性提供，供更新页滚轮预填完整名单）
  Future<void> checkUpdates({
    bool force = false,
    void Function(UpdateCheckProgress progress)? onProgress,
    void Function(CheckLogLevel level, String message)? onLog,
    void Function(List<String> appNames)? onCheckList,
  }) async {
    if (isChecking.value) return; // 并发锁
    isChecking.value = true;

    void log(CheckLogLevel level, String msg) {
      appLog.debug('[UpdateManager] $msg');
      onLog?.call(level, msg);
    }

    try {
      final aggregator = AppAggregatorManager.instance;
      final manager = ChannelManager.instance;
      final addedApps = await aggregator.getAllAddedApps();
      final total = addedApps.length;

      // 构建待检测应用名列表（优先聚合真实名，兜底 appId）供滚轮预填
      List<String> appNames;
      try {
        final aggregated = await aggregator.getAggregatedApps();
        final nameById = <String, String>{};
        for (final a in aggregated) {
          final name = a.appInfo.name.trim().isNotEmpty
              ? a.appInfo.name.trim()
              : a.appInfo.appId;
          nameById[a.addedAppInfo.appId] = name;
        }
        appNames = [
          for (final added in addedApps) nameById[added.appId] ?? added.appId,
        ];
      } catch (_) {
        // 聚合获取失败时用 appId 兜底
        appNames = [for (final added in addedApps) added.appId];
      }
      onCheckList?.call(appNames);
      log(CheckLogLevel.info, '已添加应用共 $total 个');

      final newUpdateList = <AppUpdateInfo>[];
      for (var i = 0; i < addedApps.length; i++) {
        final added = addedApps[i];
        // 检测前进度：appId 占位（名称以 onCheckList 预填的滚轮为准）
        onProgress?.call(UpdateCheckProgress(
          appId: added.appId,
          appName: appNames[i],
          index: i,
          total: total,
        ));
        final info = await _checkOneApp(added, manager, log);
        // 检测后进度：携带结果名称/图标
        if (info != null) {
          newUpdateList.add(info);
          onProgress?.call(UpdateCheckProgress(
            appId: info.appId,
            appName: info.appName,
            iconUrl: info.iconUrl,
            index: i,
            total: total,
            hasResult: true,
          ));
        }
      }

      updateList.assignAll(newUpdateList);
      lastCheckedAt.value = DateTime.now();
      // 持久化检测时间 + 结果（跨重启时间窗 + 结果展示）
      await UpdateCache.saveCheckedAt(lastCheckedAt.value!);
      await UpdateCache.saveResults(newUpdateList);
      log(CheckLogLevel.update, '检测完成：发现 ${newUpdateList.length} 个可更新应用');
      if (newUpdateList.isEmpty) {
        log(CheckLogLevel.none, '所有已添加应用均已是最新版本');
      }
    } catch (e) {
      appLog.error('UpdateManager: 检测更新失败 - $e');
      onLog?.call(CheckLogLevel.error, '检测失败: $e');
    } finally {
      isChecking.value = false;
    }
  }

  /// 检测单个应用（复用渠道 checkAppUpdate + 已安装版本比对）
  /// 检测过程输出详细日志（与旧版 UpdateLogic._checkOneApp 等价）
  Future<AppUpdateInfo?> _checkOneApp(
    AddedAppInfo addedApp,
    ChannelManager manager,
    void Function(CheckLogLevel level, String message) log,
  ) async {
    final appId = addedApp.appId;
    if (appId.isEmpty) return null;

    final channelType = ChannelType.fromCode(addedApp.channelId);
    if (channelType == null) return null;
    final channel = manager.getChannel(channelType);
    final channelName = channelType.description;
    if (channel == null) {
      log(CheckLogLevel.skip, '$appId：渠道不可用');
      return null;
    }

    log(CheckLogLevel.info, '$appId（$channelName）：获取渠道信息...');
    try {
      final checkResult = await channel.checkAppUpdate(appId);
      if (!checkResult.success || checkResult.data == null) {
        log(CheckLogLevel.skip, '$appId：${checkResult.error ?? '渠道检测失败'}');
        return null;
      }
      final check = checkResult.data!;
      final displayName = check.name.isNotEmpty ? check.name : appId;

      final packageName = check.packageName.trim().isNotEmpty
          ? check.packageName.trim()
          : appId;
      if (packageName.isEmpty) {
        log(CheckLogLevel.skip, '$displayName：无有效包名');
        return null;
      }

      // 仅检测已安装的应用
      final isInstalled = await InstalledApps.isAppInstalled(packageName);
      if (isInstalled != true) {
        log(CheckLogLevel.skip, '$displayName（$packageName）：未安装，跳过');
        return null;
      }

      final installed = await InstalledApps.getAppInfo(packageName);
      final installedVersion = installed?.versionName;
      if (installedVersion == null || installedVersion.isEmpty) {
        log(CheckLogLevel.skip, '$displayName：已安装但无法获取版本号');
        return null;
      }

      final latestVersion = check.latestVersion;
      if (latestVersion == null || latestVersion.isEmpty) {
        log(CheckLogLevel.skip, '$displayName：渠道无版本信息（已安装 $installedVersion）');
        return null;
      }

      // 最新版本更大则有更新
      final hasUpdate = compareVersion(installedVersion, latestVersion) == 1;
      log(
        hasUpdate ? CheckLogLevel.installed : CheckLogLevel.none,
        '$displayName：已安装 $installedVersion → 渠道最新 $latestVersion',
      );

      if (!hasUpdate) {
        log(CheckLogLevel.none, '$displayName：已是最新版本');
        return null;
      }

      final download = check.latestDownload;
      if (download == null) {
        log(CheckLogLevel.skip, '$displayName：有更新但无可下载文件');
        return null;
      }

      log(CheckLogLevel.update, '$displayName：发现更新 $latestVersion');

      return AppUpdateInfo(
        channelId: addedApp.channelId,
        appId: appId,
        appName: displayName,
        iconUrl: check.icon,
        packageName: packageName,
        installedVersion: installedVersion,
        latestVersion: latestVersion,
        latestDownload: download,
        detail: check.detail,
      );
    } catch (e) {
      log(CheckLogLevel.error, '$appId：检测异常 - $e');
      return null;
    }
  }

  /// 单应用查询（Agent 指定 appId；不污染全量缓存）
  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) async {
    // 优先读缓存
    final cached = getByAppId(appId);
    if (cached != null) return cached;

    final channelType = channelCode != null && channelCode.isNotEmpty
        ? ChannelType.fromCode(channelCode)
        : null;
    if (channelType == null) return null;

    final inst = ChannelManager.instance.getChannel(channelType);
    if (inst == null) return null;

    final added = AddedAppInfo(
      channelId: channelType.code,
      appId: appId,
    );
    return _checkOneApp(added, ChannelManager.instance, (_, __) {});
  }

  /// 指定应用是否有更新
  bool hasUpdate(String appId) => updateList.any((e) => e.appId == appId);

  /// 可更新应用列表（供首页分区等）
  List<AppUpdateInfo> get updatableApps => List.unmodifiable(updateList);

  /// 可更新数量（供 Badge）
  int get updateCount => updateList.length;

  /// 按 appId 查找
  AppUpdateInfo? getByAppId(String appId) {
    for (final e in updateList) {
      if (e.appId == appId) return e;
    }
    return null;
  }

  /// 安装更新成功后刷新状态：从可更新列表移除
  /// 防御：若设备版本仍旧（安装未生效）则不移除
  Future<void> markUpdated(String appId) async {
    final info = getByAppId(appId);
    if (info == null) return;
    // 复核已安装版本是否已提升
    try {
      final installed = await InstalledApps.getAppInfo(info.packageName);
      final installedVersion = installed?.versionName;
      if (installedVersion != null &&
          installedVersion.isNotEmpty &&
          compareVersion(installedVersion, info.latestVersion) == 1) {
        // 版本已提升 → 从列表移除
        updateList.removeWhere((e) => e.appId == appId);
        await UpdateCache.saveResults(List.of(updateList));
        appLog.info('UpdateManager: 应用已更新，移除可更新项 - $appId');
      } else {
        appLog.info('UpdateManager: 应用安装后版本未提升，保留可更新项 - $appId');
      }
    } catch (e) {
      // 复核失败（如插件不可用）→ 直接移除（调用方确已触发安装）
      updateList.removeWhere((e) => e.appId == appId);
      await UpdateCache.saveResults(List.of(updateList));
    }
  }

  /// 缓存是否有效（距上次检测未超时间窗）
  Future<bool> _isCacheValid() async {
    final last = lastCheckedAt.value ?? await UpdateCache.lastCheckedAt();
    if (last == null) return false;
    return DateTime.now().difference(last).inHours < cacheValidHours;
  }

  /// 重置状态（测试用）
  @visibleForTesting
  void resetForTest() {
    updateList.clear();
    isChecking.value = false;
    lastCheckedAt.value = null;
  }
}
