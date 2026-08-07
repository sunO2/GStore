import 'dart:async';

import 'package:get/get.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/download/DownloadStrategyManager.dart';
import 'package:gstore/core/download/strategy/impl/LocalDbDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/VivoDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/GitHubDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/HttpDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/FdroidDownloadStrategy.dart';
import 'package:gstore/core/service/downloadService.dart';import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

import 'state.dart';

/// 应用更新检测逻辑
/// 检测已添加且已安装的应用是否有新版本，支持单个/全部更新
class UpdateLogic extends GetxController {
  final UpdateState state = UpdateState();

  late AppAggregatorManager _aggregator;
  late ChannelManager _channelManager;

  @override
  void onInit() {
    super.onInit();
    _aggregator = AppAggregatorManager.instance;
    _channelManager = ChannelManager.instance;
  }

  @override
  void onReady() {
    super.onReady();
    // 进入页面后自动检测更新
    checkUpdates();
  }

  /// 检测所有已添加应用是否有更新
  Future<void> checkUpdates() async {
    if (state.isLoading.value) return;

    state.isLoading.value = true;
    state.updateList.clear();
    state.resetCheckProgress();
    state.addLog(CheckLogLevel.info, '开始检测应用更新...');

    try {
      final addedApps = await _aggregator.getAllAddedApps();
      state.totalCount.value = addedApps.length;
      state.addLog(CheckLogLevel.info, '已添加应用共 ${addedApps.length} 个');

      // 填充滚轮展示列表（保持检测顺序）
      state.checkList.assignAll(
        addedApps.map((a) => a.appName).toList(),
      );
      state.checkIndex.value = 0;

      // 串行检测，保证滚轮顺序与日志输出一致
      for (var i = 0; i < addedApps.length; i++) {
        await _checkOneApp(addedApps[i], i);
        state.checkedCount.value = i + 1;
      }

      if (state.updateList.isEmpty) {
        // 无更新：停留在检测页展示完整日志，仅切换 loading 为完成态
        state.checkFinished.value = true;
        state.addLog(CheckLogLevel.none, '检测完成：所有应用均已是最新版本');
      } else {
        state.addLog(
          CheckLogLevel.update,
          '检测完成：发现 ${state.updateList.length} 个可更新应用',
        );
      }

      // 同步红点：检测结果与功能入口红点一致
      BadgeService.instance.setBadge(
        BadgeKey.appUpdate,
        state.updateList.length,
      );
    } catch (e) {
      appLog.error('UpdateLogic: 检测更新失败 - $e');
      state.errorMessage.value = '检测更新失败: $e';
      state.addLog(CheckLogLevel.error, '检测失败: $e');
    } finally {
      state.isLoading.value = false;
    }
  }

  /// 检测单个应用是否有更新
  Future<void> _checkOneApp(AddedAppInfo addedApp, int index) async {
    final channelId = addedApp.channelId;
    final appId = addedApp.appId;
    if (channelId.isEmpty || appId.isEmpty) return;

    // 更新滚轮索引和当前检测的应用名
    state.checkIndex.value = index;
    state.checkingAppName.value = addedApp.appName;
    state.checkingIconUrl.value = addedApp.iconUrl;

    final channelName =
        ChannelType.fromCode(channelId)?.description ?? channelId;

    try {
      final channelType = ChannelType.fromCode(channelId);
      if (channelType == null) return;
      final channel = _channelManager.getChannel(channelType);
      if (channel == null) {
        state.addLog(CheckLogLevel.skip, '${addedApp.appName}：渠道不可用');
        return;
      }

      state.addLog(CheckLogLevel.info,
          '${addedApp.appName}（$channelName）：获取渠道信息...');
      // 渠道内部处理更新检测（本地索引 / releases / 数据库等）
      final checkResult = await channel.checkAppUpdate(appId);
      if (!checkResult.success || checkResult.data == null) {
        state.addLog(CheckLogLevel.skip,
            '${addedApp.appName}：${checkResult.error ?? '渠道检测失败'}');
        return;
      }
      final check = checkResult.data!;

      // 确定包名
      final packageName = check.packageName.trim().isNotEmpty
          ? check.packageName.trim()
          : appId;
      if (packageName.isEmpty) {
        state.addLog(CheckLogLevel.skip, '${addedApp.appName}：无有效包名');
        return;
      }

      // 仅检测已安装的应用
      final isInstalled = await InstalledApps.isAppInstalled(packageName);
      if (isInstalled != true) {
        state.addLog(CheckLogLevel.skip,
            '${addedApp.appName}（$packageName）：未安装，跳过');
        return;
      }

      final installed = await InstalledApps.getAppInfo(packageName);
      final installedVersion = installed?.versionName;
      if (installedVersion == null || installedVersion.isEmpty) {
        state.addLog(CheckLogLevel.skip,
            '${addedApp.appName}：已安装但无法获取版本号');
        return;
      }

      final latestVersion = check.latestVersion;
      if (latestVersion == null || latestVersion.isEmpty) {
        state.addLog(CheckLogLevel.skip,
            '${addedApp.appName}：渠道无版本信息（已安装 $installedVersion）');
        return;
      }

      // 对比版本：最新版本更大则有更新
      final hasUpdate = compareVersion(installedVersion, latestVersion) == 1;
      state.addLog(
        hasUpdate ? CheckLogLevel.installed : CheckLogLevel.none,
        '${addedApp.appName}：已安装 $installedVersion → 渠道最新 $latestVersion',
      );

      if (!hasUpdate) {
        state.addLog(CheckLogLevel.none, '${addedApp.appName}：已是最新版本');
        return;
      }

      // 需要可用的下载信息
      final download = check.latestDownload;
      if (download == null) {
        state.addLog(CheckLogLevel.skip,
            '${addedApp.appName}：有更新但无可下载文件');
        return;
      }

      state.addLog(
          CheckLogLevel.update, '${addedApp.appName}：发现更新 $latestVersion');

      state.updateList.add(AppUpdateInfo(
        channelId: channelId,
        appId: appId,
        appName: check.name,
        iconUrl: check.icon,
        packageName: packageName,
        installedVersion: installedVersion,
        latestVersion: latestVersion,
        latestDownload: download,
        detail: check.detail,
      ));
    } catch (e) {
      appLog.error('UpdateLogic: 检测 ${addedApp.appName} 失败 - $e');
      state.addLog(CheckLogLevel.error, '${addedApp.appName}：检测异常 - $e');
    }
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

      // 尝试使用策略模式下载（含代理处理），失败降级到普通下载
      try {
        final context = await DownloadStrategyManager.instance.createContext(
          info.latestDownload,
          info.detail,
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

      // 下载完成（DownloadService 内部已自动安装 APK），从列表移除
      state.updateList.removeWhere((e) => e.appId == info.appId);
      // 更新红点数量
      BadgeService.instance.setBadge(
        BadgeKey.appUpdate,
        state.updateList.length,
      );
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
