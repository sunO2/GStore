/// 集中式更新管理服务
///
/// 统一的更新检测入口 + 状态仓库 + 缓存：
/// - 消除启动/更新页/Agent 三处重复检测（锁 + 时间窗）
/// - 检测结果以 Rx 状态暴露，供红点/可更新分区/更新页/Agent 共用
/// - 支持手动强制检测、Agent 单应用查询、安装后状态刷新
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

/// 更新检测状态
class UpdateManagerService extends GetxService {
  static UpdateManagerService get instance => Get.find<UpdateManagerService>();

  /// 可更新应用列表（单次检测的完整明细）
  final RxList<AppUpdateInfo> updateList = <AppUpdateInfo>[].obs;

  /// 是否正在检测
  final RxBool isChecking = false.obs;

  /// 上次检测时间（内存态）
  DateTime? _lastCheckedAt;

  /// 时间窗（小时）：非强制检测时，距上次检测不足该时长则跳过
  static const int cacheValidHours = 1;

  /// 启动后懒检测（后台静默；时间窗内跳过）
  Future<void> ensureChecked({bool force = false}) async {
    // 锁：检测中直接返回（不重复、不排队）
    if (isChecking.value) return;

    // 时间窗：非强制且缓存有效则跳过
    if (!force && await _isCacheValid()) return;

    await checkUpdates(force: true);
  }

  /// 主动检测（页面刷新 / 手动触发）
  /// [onProgress] 可选进度回调（appId, index, total），供更新页动画展示
  Future<void> checkUpdates({
    bool force = false,
    void Function(String appId, int index, int total)? onProgress,
  }) async {
    if (isChecking.value) return; // 并发锁
    isChecking.value = true;

    try {
      final aggregator = AppAggregatorManager.instance;
      final manager = ChannelManager.instance;
      final addedApps = await aggregator.getAllAddedApps();
      final total = addedApps.length;

      final newUpdateList = <AppUpdateInfo>[];
      for (var i = 0; i < addedApps.length; i++) {
        final added = addedApps[i];
        onProgress?.call(added.appId, i, total);
        final info = await _checkOneApp(added, manager);
        if (info != null) newUpdateList.add(info);
      }

      updateList.assignAll(newUpdateList);
      _lastCheckedAt = DateTime.now();
      // 持久化检测时间（跨重启时间窗）
      await UpdateCache.saveCheckedAt(_lastCheckedAt!);
      appLog.info('UpdateManager: 检测完成，可更新 ${newUpdateList.length}/${total} 个');
    } catch (e) {
      appLog.error('UpdateManager: 检测更新失败 - $e');
    } finally {
      isChecking.value = false;
    }
  }

  /// 检测单个应用（复用渠道 checkAppUpdate + 已安装版本比对）
  Future<AppUpdateInfo?> _checkOneApp(
    AddedAppInfo addedApp,
    ChannelManager manager,
  ) async {
    try {
      final channelType = ChannelType.fromCode(addedApp.channelId);
      if (channelType == null) return null;
      final channel = manager.getChannel(channelType);
      if (channel == null) return null;

      final checkResult = await channel.checkAppUpdate(addedApp.appId);
      if (!checkResult.success || checkResult.data == null) return null;
      final check = checkResult.data!;

      final packageName = check.packageName.trim().isNotEmpty
          ? check.packageName.trim()
          : addedApp.appId;
      if (packageName.isEmpty) return null;

      // 仅检测已安装应用
      final isInstalled = await InstalledApps.isAppInstalled(packageName);
      if (isInstalled != true) return null;

      final installed = await InstalledApps.getAppInfo(packageName);
      final installedVersion = installed?.versionName;
      final latestVersion = check.latestVersion;
      if (installedVersion == null ||
          installedVersion.isEmpty ||
          latestVersion == null ||
          latestVersion.isEmpty) {
        return null;
      }

      // 最新版本更大则有更新
      if (compareVersion(installedVersion, latestVersion) != 1) return null;

      final download = check.latestDownload;
      if (download == null) return null; // 有更新但无可下载文件

      return AppUpdateInfo(
        channelId: addedApp.channelId,
        appId: addedApp.appId,
        appName: check.name.isNotEmpty ? check.name : addedApp.appId,
        iconUrl: check.icon,
        packageName: packageName,
        installedVersion: installedVersion,
        latestVersion: latestVersion,
        latestDownload: download,
        detail: check.detail,
      );
    } catch (e) {
      // 单个应用失败不影响整体
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
    return _checkOneApp(added, ChannelManager.instance);
  }

  /// 指定应用是否有更新
  bool hasUpdate(String appId) =>
      updateList.any((e) => e.appId == appId);

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
        appLog.info('UpdateManager: 应用已更新，移除可更新项 - $appId');
      } else {
        appLog.info('UpdateManager: 应用安装后版本未提升，保留可更新项 - $appId');
      }
    } catch (e) {
      // 复核失败（如插件不可用）→ 直接移除（调用方确已触发安装）
      updateList.removeWhere((e) => e.appId == appId);
    }
  }

  /// 缓存是否有效（距上次检测未超时间窗）
  Future<bool> _isCacheValid() async {
    final last = _lastCheckedAt ?? await UpdateCache.lastCheckedAt();
    if (last == null) return false;
    return DateTime.now().difference(last).inHours < cacheValidHours;
  }

  /// 重置状态（测试用）
  @visibleForTesting
  void resetForTest() {
    updateList.clear();
    isChecking.value = false;
    _lastCheckedAt = null;
  }
}
