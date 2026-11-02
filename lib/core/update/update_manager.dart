/// 更新检测共享状态仓库
///
/// 检测由 `UpdateFacade`（core/FRB 通道）负责；本服务只保留响应式状态面：
/// - 检测结果/日志/进度/时间以广播 stream + live getter 暴露，供红点/
///   可更新分区/更新页/Agent 共用
/// - `UpdateFacade` 通过 `beginFacadeCheck`/`adoptFacadeCheck`/`failFacadeCheck`/
///   `removeFacadeUpdated` 把 core 结果回放到本服务
/// - 启动恢复缓存结果（重启后立即可展示上次可更新应用）
///
/// 旧 Dart 检测引擎（`ensureChecked`/`checkUpdates`/`checkApp`/`markUpdated`
/// 及其私有助手）已在核心接管 update 域后删除。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/update/app_update_info.dart';
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
  final _updateListController =
      StreamController<List<AppUpdateInfo>>.broadcast();
  Stream<List<AppUpdateInfo>> get updateListStream =>
      _updateListController.stream;
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
  final _lastCheckedAtController = StreamController<DateTime?>.broadcast();
  Stream<DateTime?> get lastCheckedAtStream => _lastCheckedAtController.stream;
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
  Stream<String> get checkingAppNameStream => _checkingAppNameController.stream;
  void _notifyCheckingAppName() =>
      _checkingAppNameController.add(_checkingAppName);

  /// 当前正在检测的应用图标 URL（loading 叠加展示）
  String? _checkingIconUrl;
  String? get checkingIconUrl => _checkingIconUrl;
  final _checkingIconUrlController = StreamController<String?>.broadcast();
  Stream<String?> get checkingIconUrlStream =>
      _checkingIconUrlController.stream;
  void _notifyCheckingIconUrl() =>
      _checkingIconUrlController.add(_checkingIconUrl);

  /// 缓存恢复完成标志（页面进入时等待，避免恢复未完成误判"从未检测"）
  late final Future<void> cacheRestored = _restoreCache();

  /// Rust 核心缓存读取接缝（由 `UpdateFacade` 注入）；为空时回退旧
  /// SharedPreferences 缓存，保证测试/非 core 环境行为不变。
  Future<CachedUpdateSnapshot?> Function()? cachedStateLoader;

  /// 模块初始化时调用：启动恢复缓存结果（重启后立即展示上次检测出的可更新应用）
  void restoreCacheInBackground() {
    unawaited(cacheRestored);
  }

  /// 从缓存恢复上次检测结果。
  ///
  /// core 通道优先读取 Rust `update_prefs`（重启后立即显示上次结果）；
  /// 旧 SharedPreferences 仅作为测试/非 core 环境的回退。
  Future<void> _restoreCache() async {
    try {
      try {
        final core = await cachedStateLoader?.call();
        if (core != null) {
          _applyRestored(
            updates: core.updates,
            logs: core.logs,
            lastCheckedAt: core.lastCheckedAt,
          );
          return;
        }
      } catch (e) {
        // core 尚未就绪（测试/早期启动）时继续走旧缓存回退，不阻塞首帧。
        appLog.warning('UpdateManager: 读取 Rust 缓存失败，回退本地缓存 - $e');
      }

      final cached = await UpdateCache.loadResults();
      final last = await UpdateCache.lastCheckedAt();
      // 恢复上次检测日志（二次进入检测页直接可见）
      final logs = await UpdateCache.loadLogs();
      _applyRestored(updates: cached, logs: logs, lastCheckedAt: last);
    } catch (e) {
      appLog.error('UpdateManager: 恢复缓存失败 - $e');
    }
  }

  void _applyRestored({
    required List<AppUpdateInfo> updates,
    required List<CheckLogEntry> logs,
    DateTime? lastCheckedAt,
  }) {
    if (updates.isNotEmpty) {
      _updateList
        ..clear()
        ..addAll(updates);
      _notifyUpdateList();
      appLog.info('UpdateManager: 已恢复缓存结果 ${updates.length} 个可更新应用');
    }
    if (lastCheckedAt != null) {
      _lastCheckedAt = lastCheckedAt;
      _notifyLastCheckedAt();
    }
    if (logs.isNotEmpty) {
      _checkLog
        ..clear()
        ..addAll(logs);
      _notifyCheckLog();
      appLog.info('UpdateManager: 已恢复检测日志 ${logs.length} 条');
    }
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

  // ===== Facade/core 通道的共享状态镜像 =====
  //
  // `UpdateFacade` 在 `CoreFlags.update == true` 时由 FRB 执行检测，并通过
  // 以下方法把结果回放到本服务的响应式状态（结果/日志/时间/进度）。页面、
  // 红点、列表与 Agent 因此保持同一套订阅面。这些方法只改内存状态：不访问
  // 渠道、不写缓存（持久化由 Rust core 拥有），所以不是 legacy writer。

  /// 开始一轮由 facade（core 通道）驱动的检测：加锁并清空上一轮日志/进度。
  void beginFacadeCheck() {
    _isChecking = true;
    _notifyIsChecking();
    _checkLog.clear();
    _notifyCheckLog();
    _checkList.clear();
    _notifyCheckList();
    _currentProgress = null;
    _notifyCurrentProgress();
    _checkedCount = 0;
    _notifyCheckedCount();
    _totalCount = 0;
    _notifyTotalCount();
    _checkingAppName = '';
    _notifyCheckingAppName();
    _checkingIconUrl = null;
    _notifyCheckingIconUrl();
  }

  /// 回放 facade/core 检测结果到共享状态并释放检测锁。
  void adoptFacadeCheck({
    required List<AppUpdateInfo> updates,
    required List<CheckLogEntry> logs,
    required DateTime checkedAt,
    int? total,
    List<String>? checkList,
    bool preserveLogs = false,
  }) {
    _updateList
      ..clear()
      ..addAll(updates);
    _notifyUpdateList();
    if (!preserveLogs) {
      _checkLog
        ..clear()
        ..addAll(logs);
      _notifyCheckLog();
    }
    _lastCheckedAt = checkedAt;
    _notifyLastCheckedAt();
    if (total != null) {
      _totalCount = total;
      _notifyTotalCount();
      _checkedCount = total;
      _notifyCheckedCount();
    }
    if (checkList != null) {
      _checkList
        ..clear()
        ..addAll(checkList);
      _notifyCheckList();
    }
    _isChecking = false;
    _notifyIsChecking();
  }

  /// 回放一条 facade/core 流式进度：实时更新应用名/图标/进度/日志。
  void mirrorFacadeProgress({
    required int total,
    required int index,
    required String appId,
    required String appName,
    String? iconUrl,
    String? logLevel,
    String? logText,
    List<String>? checkList,
    bool finished = false,
    bool isResult = false,
  }) {
    if (checkList != null) {
      _checkList
        ..clear()
        ..addAll(checkList);
      _notifyCheckList();
    }
    if (total > 0) {
      _totalCount = total;
      _notifyTotalCount();
    }
    if (appName.isNotEmpty) {
      _checkingAppName = appName;
      _notifyCheckingAppName();
      if (index >= 0 &&
          index < _checkList.length &&
          _checkList[index] != appName) {
        _checkList[index] = appName;
        _notifyCheckList();
      }
    }
    if (appId.isNotEmpty) {
      _checkingIconUrl = iconUrl;
      _notifyCheckingIconUrl();
    }
    if (total > 0 && index >= 0) {
      _currentProgress = UpdateCheckProgress(
        appId: appId,
        appName: appName,
        iconUrl: iconUrl,
        index: index,
        total: total,
        hasResult: finished,
      );
      _notifyCurrentProgress();
    }
    if (logText != null && logText.isNotEmpty) {
      final level = CheckLogLevel.values.firstWhere(
        (value) => value.name == logLevel,
        orElse: () => CheckLogLevel.info,
      );
      _checkLog.add(CheckLogEntry(level: level, text: logText));
      _notifyCheckLog();
      if (isResult && appId.isNotEmpty && total > 0) {
        _checkedCount = (index + 1).clamp(0, total);
        _notifyCheckedCount();
      }
    }
  }

  /// 回放 facade/core 检测失败：写一条 typed 错误日志并释放检测锁。
  void failFacadeCheck(String message) {
    final entry = CheckLogEntry(level: CheckLogLevel.error, text: message);
    _checkLog.add(entry);
    _notifyCheckLog();
    _isChecking = false;
    _notifyIsChecking();
  }

  /// core 通道 markUpdated 成功后同步共享状态（红点/列表立即更新）。
  void removeFacadeUpdated(String appId) {
    final before = _updateList.length;
    _updateList.removeWhere((e) => e.appId == appId);
    if (_updateList.length != before) _notifyUpdateList();
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
