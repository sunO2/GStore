/// 集中式更新管理服务
///
/// 统一的更新检测入口 + 状态仓库 + 缓存：
/// - 消除启动/更新页/Agent 三处重复检测（锁 + 时间窗）
/// - 检测结果以 Rx 状态暴露，供红点/可更新分区/更新页/Agent 共用
/// - 支持手动强制检测、Agent 单应用查询、安装后状态刷新
/// - 启动恢复缓存结果（重启后立即可展示上次可更新应用）
/// - 检测过程输出详细日志（onLog）与逐应用进度（onProgress），供更新页滚轮/图标/日志展示
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/apk_matcher.dart';
import 'package:gstore/core/update/update_cache.dart';
import 'package:gstore/core/update/update_log.dart';

/// 更新检测状态
class UpdateManagerService {
  static UpdateManagerService? _instance;

  /// 全局访问：模块注册表优先（模块 bind / 测试注入 fake），未注册懒创建单例
  static UpdateManagerService get instance {
    final registered = ModuleManager.instance.get<UpdateManagerService>();
    if (registered != null) return registered;
    return _instance ??= UpdateManagerService();
  }

  /// 测试可自由构造自建实例（行为与 GetX 时代一致）；生产统一走 [instance]
  UpdateManagerService();

  // ===== 共享状态（纯 Dart + broadcast stream，替代旧 GetX Rx）=====
  //
  // 迁移约定：内部写操作一律走 `_xxx` 私有字段然后调用对应 `_notifyXxx()`
  // （统一通知一次）。对外暴露：live getter（读当前值/迭代）+ `xxxStream`
  // （订阅后续变更，broadcast：不重放历史）。

  /// 可更新应用列表（单次检测的完整明细）
  final List<AppUpdateInfo> _updateList = [];
  List<AppUpdateInfo> get updateList => _updateList;
  final _updateListController = StreamController<List<AppUpdateInfo>>.broadcast();
  Stream<List<AppUpdateInfo>> get updateListStream => _updateListController.stream;
  void _notifyUpdateList() => _updateListController.add(List.of(_updateList));

  /// 是否正在检测
  bool _isChecking = false;
  bool get isChecking => _isChecking;
  final _isCheckingController = StreamController<bool>.broadcast();
  Stream<bool> get isCheckingStream => _isCheckingController.stream;
  void _notifyIsChecking() => _isCheckingController.add(_isChecking);

  /// 上次检测时间（内存态；页面副标题/时间窗实时响应）
  DateTime? _lastCheckedAt;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  final _lastCheckedAtController =
      StreamController<DateTime?>.broadcast();
  Stream<DateTime?> get lastCheckedAtStream =>
      _lastCheckedAtController.stream;
  void _notifyLastCheckedAt() => _lastCheckedAtController.add(_lastCheckedAt);

  /// 检测日志（前台/后台检测同源产出，格式一致；持久化缓存，二次进入可查看）
  final List<CheckLogEntry> _checkLog = [];
  List<CheckLogEntry> get checkLog => _checkLog;
  final _checkLogController = StreamController<List<CheckLogEntry>>.broadcast();
  Stream<List<CheckLogEntry>> get checkLogStream => _checkLogController.stream;
  void _notifyCheckLog() => _checkLogController.add(List.of(_checkLog));

  // ===== 检测进度状态（前台/后台检测共享，页面订阅镜像展示）=====

  /// 当前检测进度（逐应用更新）
  UpdateCheckProgress? _currentProgress;
  UpdateCheckProgress? get currentProgress => _currentProgress;
  final _currentProgressController =
      StreamController<UpdateCheckProgress?>.broadcast();
  Stream<UpdateCheckProgress?> get currentProgressStream =>
      _currentProgressController.stream;
  void _notifyCurrentProgress() =>
      _currentProgressController.add(_currentProgress);

  /// 待检测应用名列表（检测前一次性提供，供滚轮预填完整名单）
  final List<String> _checkList = [];
  List<String> get checkList => _checkList;
  final _checkListController = StreamController<List<String>>.broadcast();
  Stream<List<String>> get checkListStream => _checkListController.stream;
  void _notifyCheckList() => _checkListController.add(List.of(_checkList));

  /// 已检测数量
  int _checkedCount = 0;
  int get checkedCount => _checkedCount;
  final _checkedCountController = StreamController<int>.broadcast();
  Stream<int> get checkedCountStream => _checkedCountController.stream;
  void _notifyCheckedCount() => _checkedCountController.add(_checkedCount);

  /// 总应用数
  int _totalCount = 0;
  int get totalCount => _totalCount;
  final _totalCountController = StreamController<int>.broadcast();
  Stream<int> get totalCountStream => _totalCountController.stream;
  void _notifyTotalCount() => _totalCountController.add(_totalCount);

  /// 当前正在检测的应用名（滚轮展示）
  String _checkingAppName = '';
  String get checkingAppName => _checkingAppName;
  final _checkingAppNameController = StreamController<String>.broadcast();
  Stream<String> get checkingAppNameStream =>
      _checkingAppNameController.stream;
  void _notifyCheckingAppName() =>
      _checkingAppNameController.add(_checkingAppName);

  /// 当前正在检测的应用图标 URL（loading 叠加展示）
  String? _checkingIconUrl;
  String? get checkingIconUrl => _checkingIconUrl;
  final _checkingIconUrlController =
      StreamController<String?>.broadcast();
  Stream<String?> get checkingIconUrlStream =>
      _checkingIconUrlController.stream;
  void _notifyCheckingIconUrl() =>
      _checkingIconUrlController.add(_checkingIconUrl);

  /// 缓存恢复完成标志（页面进入时等待，避免恢复未完成误判"从未检测"）
  late final Future<void> cacheRestored = _restoreCache();

  /// 时间窗（小时）：非强制检测时，距上次检测不足该时长则跳过
  static const int cacheValidHours = 1;

  /// 模块初始化时调用：启动恢复缓存结果（重启后立即展示上次检测出的可更新应用）
  void restoreCacheInBackground() {
    unawaited(cacheRestored);
  }

  /// 从缓存恢复上次检测结果
  Future<void> _restoreCache() async {
    try {
      final cached = await UpdateCache.loadResults();
      if (cached.isNotEmpty) {
        _updateList
          ..clear()
          ..addAll(cached);
        _notifyUpdateList();
        appLog.info('UpdateManager: 已恢复缓存结果 ${cached.length} 个可更新应用');
      }
      final last = await UpdateCache.lastCheckedAt();
      if (last != null) {
        _lastCheckedAt = last;
        _notifyLastCheckedAt();
      }
      // 恢复上次检测日志（二次进入检测页直接可见）
      final logs = await UpdateCache.loadLogs();
      if (logs.isNotEmpty) {
        _checkLog
          ..clear()
          ..addAll(logs);
        _notifyCheckLog();
        appLog.info('UpdateManager: 已恢复检测日志 ${logs.length} 条');
      }
    } catch (e) {
      appLog.error('UpdateManager: 恢复缓存失败 - $e');
    }
  }

  /// 启动后懒检测（后台静默；时间窗内跳过）
  /// 结果为空时必须检测：时间窗仅用于"已有结果"时的防重，
  /// 不能因时间窗跳过而导致启动后看不到可更新应用
  Future<void> ensureChecked({bool force = false}) async {
    // 锁：检测中直接返回（不重复、不排队）
    if (isChecking) return;

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
    if (isChecking) return; // 并发锁
    _isChecking = true;
    _notifyIsChecking();

    void log(CheckLogLevel level, String msg) {
      appLog.debug('[UpdateManager] $msg');
      // 统一收集（前台页面回调 + 内存流 + 持久化，保证前后台格式一致）
      _checkLog.add(CheckLogEntry(level: level, text: msg));
      _notifyCheckLog();
      onLog?.call(level, msg);
    }

    try {
      // 新一轮检测：清空历史日志，开始提示统一由 manager 产出
      _checkLog.clear();
      _notifyCheckLog();
      log(CheckLogLevel.info, '开始检测应用更新...');

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
      // 共享状态：待检测名单/总数（页面订阅镜像，后台检测同样产出）
      _checkList
        ..clear()
        ..addAll(appNames);
      _notifyCheckList();
      _totalCount = total;
      _notifyTotalCount();
      log(CheckLogLevel.info, '已添加应用共 $total 个');

      final newUpdateList = <AppUpdateInfo>[];
      for (var i = 0; i < addedApps.length; i++) {
        final added = addedApps[i];
        // 检测前进度：appId 占位（名称以 onCheckList 预填的滚轮为准）
        final preProgress = UpdateCheckProgress(
          appId: added.appId,
          appName: appNames[i],
          index: i,
          total: total,
        );
        onProgress?.call(preProgress);
        _publishProgress(preProgress);
        final info = await _checkOneApp(added, manager, log);
        // 检测后进度：携带结果名称/图标
        if (info != null) {
          newUpdateList.add(info);
          final postProgress = UpdateCheckProgress(
            appId: info.appId,
            appName: info.appName,
            iconUrl: info.iconUrl,
            index: i,
            total: total,
            hasResult: true,
          );
          onProgress?.call(postProgress);
          _publishProgress(postProgress);
        }
      }

      _updateList
        ..clear()
        ..addAll(newUpdateList);
      _notifyUpdateList();
      _lastCheckedAt = DateTime.now();
      _notifyLastCheckedAt();
      // 持久化检测时间 + 结果 + 日志（跨重启时间窗 + 结果展示 + 日志回看）
      await UpdateCache.saveCheckedAt(_lastCheckedAt!);
      await UpdateCache.saveResults(newUpdateList);
      await UpdateCache.saveLogs(List.of(_checkLog));
      log(CheckLogLevel.update, '检测完成：发现 ${newUpdateList.length} 个可更新应用');
      if (newUpdateList.isEmpty) {
        log(CheckLogLevel.none, '所有已添加应用均已是最新版本');
      }
    } catch (e) {
      appLog.error('UpdateManager: 检测更新失败 - $e');
      onLog?.call(CheckLogLevel.error, '检测失败: $e');
    } finally {
      _isChecking = false;
      _notifyIsChecking();
    }
  }

  /// 发布进度到共享状态（前台/后台检测同源，页面订阅镜像）
  void _publishProgress(UpdateCheckProgress progress) {
    _currentProgress = progress;
    _notifyCurrentProgress();
    _checkedCount = progress.index + 1;
    _notifyCheckedCount();
    _totalCount = progress.total;
    _notifyTotalCount();
    _checkingAppName = progress.appName;
    _notifyCheckingAppName();
    if (progress.iconUrl != null && progress.iconUrl!.isNotEmpty) {
      _checkingIconUrl = progress.iconUrl;
      _notifyCheckingIconUrl();
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

      final defaultDownload = check.latestDownload;
      if (defaultDownload == null) {
        log(CheckLogLevel.skip, '$displayName：有更新但无可下载文件');
        return null;
      }

      // 用户 APK 选择偏好：存储命中 → 文件名相似度匹配最接近候选；否则现有
      // selectBestDownload 规则（check.latestDownload 即渠道按设备架构选出的最佳）
      final preferred = await UpdateCache.preferredApkName(addedApp.channelId, appId);
      final download = selectDownloadWithPreference(
        fallback: defaultDownload,
        candidates: check.detail.downloads,
        preferred: preferred,
      );

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
        _updateList.removeWhere((e) => e.appId == appId);
        _notifyUpdateList();
        await UpdateCache.saveResults(List.of(_updateList));
        appLog.info('UpdateManager: 应用已更新，移除可更新项 - $appId');
      } else {
        appLog.info('UpdateManager: 应用安装后版本未提升，保留可更新项 - $appId');
      }
    } catch (e) {
      // 复核失败（如插件不可用）→ 直接移除（调用方确已触发安装）
      _updateList.removeWhere((e) => e.appId == appId);
      _notifyUpdateList();
      await UpdateCache.saveResults(List.of(_updateList));
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
    _updateList.clear();
    _notifyUpdateList();
    _isChecking = false;
    _notifyIsChecking();
    _lastCheckedAt = null;
    _notifyLastCheckedAt();
  }

  /// 测试注入：批量设置共享状态并通知（fake UpdateManager 回放用）。
  @visibleForTesting
  void debugSetState({
    List<AppUpdateInfo>? updateList,
    bool? isChecking,
    DateTime? lastCheckedAt,
    List<CheckLogEntry>? checkLog,
    List<String>? checkList,
    int? checkedCount,
    int? totalCount,
    String? checkingAppName,
    String? checkingIconUrl,
  }) {
    if (updateList != null) {
      _updateList
        ..clear()
        ..addAll(updateList);
      _notifyUpdateList();
    }
    if (isChecking != null) {
      _isChecking = isChecking;
      _notifyIsChecking();
    }
    if (lastCheckedAt != null) {
      _lastCheckedAt = lastCheckedAt;
      _notifyLastCheckedAt();
    }
    if (checkLog != null) {
      _checkLog
        ..clear()
        ..addAll(checkLog);
      _notifyCheckLog();
    }
    if (checkList != null) {
      _checkList
        ..clear()
        ..addAll(checkList);
      _notifyCheckList();
    }
    if (checkedCount != null) {
      _checkedCount = checkedCount;
      _notifyCheckedCount();
    }
    if (totalCount != null) {
      _totalCount = totalCount;
      _notifyTotalCount();
    }
    if (checkingAppName != null) {
      _checkingAppName = checkingAppName;
      _notifyCheckingAppName();
    }
    if (checkingIconUrl != null) {
      _checkingIconUrl = checkingIconUrl;
      _notifyCheckingIconUrl();
    }
  }
}
