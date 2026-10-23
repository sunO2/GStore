import 'dart:io';
import 'package:app_installer/app_installer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/platform/platform_channel.dart';
import 'package:gstore/core/shell/rust_shizuku_runner.dart';
import 'package:shizuku_api/shizuku_api.dart';

/// pm 命令成功判定：输出以 "Success" 开头（pm install/uninstall/clear/disable 等）
/// null（命令未执行）/ "Failure [...]" / 空输出 → false
bool isPmSuccess(String? result) {
  if (result == null) return false;
  return result.trim().startsWith('Success');
}

/// am 命令成功判定：am 类命令（如 force-stop）成功时通常无输出（''）。
/// - null（命令未执行）→ false
/// - 空输出（''）→ true（am 成功无输出，不再依赖非 null 误判）
/// - 输出含 'Failure' / 'Exception' / 'Error' / 'Unknown command' → false
/// - 其它输出 → true
bool _isAmSuccess(String? result) {
  if (result == null) return false;
  final trimmed = result.trim();
  if (trimmed.isEmpty) return true;
  final lower = trimmed.toLowerCase();
  return !(lower.contains('failure') ||
      lower.contains('exception') ||
      lower.contains('error') ||
      lower.contains('unknown command'));
}

/// 安装方式
enum InstallMethod {
  /// 系统安装（弹系统确认框）
  system,

  /// Shizuku 静默安装（需 Shizuku 授权）
  shizuku,

  /// Android PackageInstaller 会话
  packageInstaller,

  /// 系统安装 Intent
  intent,

  /// 跨平台兼容安装钩子
  platform,
}

/// 应用安装管理器
/// 统一管理安装方式：优先 Shizuku 静默安装，未授权时回退系统安装
/// 使用策略模式，可灵活切换安装方式
class InstallManager implements IInstallService {
  static InstallManager? _instance;
  static InstallManager get instance => _instance ??= InstallManager._();
  InstallManager._();

  ShizukuApi _shizukuApi = ShizukuApi();

  /// 执行特权 shell 命令的底层 runner（默认走 Rust 统一门面 [rustShizukuRunner]）。
  ///
  /// 与旧的插件命令执行入口可替身性对应：测试可经 [commandRunnerForTest]
  /// 注入假件，脱离平台通道 / 真机。
  static Future<String?> Function(String command) _commandRunner =
      rustShizukuRunner;

  /// 测试专用：替换安装门面（默认 [InstallFacade.instance]）。
  @visibleForTesting
  static InstallFacade? installFacadeForTest;

  /// 核心安装已返回非终态时的轮询间隔与上限（可被测试缩短）。
  @visibleForTesting
  static Duration installPollInterval = const Duration(milliseconds: 500);
  @visibleForTesting
  static Duration installPollTimeout = const Duration(seconds: 180);

  /// 时钟接缝：上报 `reported_at` 用，测试注入固定值以做精确断言。
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// 系统安装器接缝（生产：[AppInstaller.installApk]），测试可注入假件。
  static Future<void> Function(String path) _appInstaller =
      AppInstaller.installApk;

  @visibleForTesting
  static set appInstallerForTest(
    Future<void> Function(String path) installer,
  ) =>
      _appInstaller = installer;

  static const String _installNoCoreTask = 'CORE_E_INSTALL_NO_CORE_TASK';
  static const Set<String> _terminalInstallStatuses = <String>{
    'installed',
    'failed',
    'denied',
    'timeout',
    'unknown',
  };

  final Map<String, Timer> _installPollers = <String, Timer>{};
  bool _installRecoveryDone = false;

  /// 全仓唯一的 `gstore/install_events` 订阅（`startEventBridge` 幂等建立）。
  StreamSubscription<dynamic>? _installEventsSub;

  /// 测试用：暴露当前订阅以断言幂等/取消（生产代码不读取）。
  @visibleForTesting
  StreamSubscription<dynamic>? get installEventsSubscriptionForTest =>
      _installEventsSub;

  /// 测试用：`StreamController` 驱动的假通道（默认 null → 真实 `EventChannel`）。
  @visibleForTesting
  static Stream<dynamic>? installEventsStreamForTest;

  /// 建立全仓唯一的 `gstore/install_events` 订阅。
  ///
  /// 幂等：已有订阅时直接返回，`startEventBridge()` 调用多次也只订阅一次。
  /// 通道只由 Android `MainActivity` 注册，其它平台不订阅（否则会触发
  /// MissingPluginException）；测试经 `setIsAndroidForTest(true)` 走同一条路径。
  void startEventBridge() {
    if (_installEventsSub != null) return;
    final injected = installEventsStreamForTest;
    if (injected == null && !_isAndroid) return;
    final stream = injected ??
        const EventChannel(installEventsChannelName).receiveBroadcastStream();
    _installEventsSub = stream.listen(
      _onInstallEvent,
      onError: (Object error, StackTrace stackTrace) {
        // 通道层错误（解码失败 / 平台异常）只记录，绝不冒泡。
        debugPrint('InstallManager: install_events 通道错误（忽略） - $error');
      },
    );
  }

  /// 取消订阅；幂等，可在未启动/已取消时安全调用。
  Future<void> stopEventBridge() async {
    final sub = _installEventsSub;
    _installEventsSub = null;
    await sub?.cancel();
  }

  void _detachEventBridge() {
    final sub = _installEventsSub;
    _installEventsSub = null;
    if (sub != null) unawaited(sub.cancel());
  }

  /// 一条事件的完整处理：`InstallEvent.fromMap` → `InstallReport` → 核心。
  ///
  /// 空 `sessionId` 忽略；四种终端状态显式映射；其它状态、畸形载荷与核心
  /// 错误一律 `debugPrint` 后吞掉，绝不从流处理器抛出。
  Future<void> _onInstallEvent(Object? raw) async {
    try {
      if (raw is! Map) {
        debugPrint('InstallManager: 忽略非 Map 的安装事件 - $raw');
        return;
      }
      final event = InstallEvent.fromMap(raw);
      if (event.sessionId.isEmpty) return;
      final status = _installEventStatus(event.status);
      if (status == null) {
        debugPrint(
          'InstallManager: 忽略未知安装状态 - ${event.status}'
          '（sessionId=${event.sessionId}）',
        );
        return;
      }
      final ack = await _installFacade.reportResult(
        InstallReport(
          sessionId: event.sessionId,
          status: status,
          method: event.method ?? '',
          installedVersion: event.installedVersion,
          error: event.error,
          reportedAt: clock().millisecondsSinceEpoch,
        ),
      );
      // 去重只依赖核心的 changed:false（已终态 session），客户端不缓存。
      debugPrint(
        'InstallManager: install_events 已上报 '
        'sessionId=${event.sessionId} status=$status changed=${ack.changed}',
      );
    } catch (e) {
      debugPrint('InstallManager: install_events 上报失败（忽略） - $e');
    }
  }

  /// 四种终端状态与核心枚举 1:1 显式映射；非终态/未知返回 null。
  static String? _installEventStatus(String status) {
    switch (status) {
      case InstallReportStatus.installed:
        return InstallReportStatus.installed;
      case InstallReportStatus.failed:
        return InstallReportStatus.failed;
      case InstallReportStatus.denied:
        return InstallReportStatus.denied;
      case InstallReportStatus.timeout:
        return InstallReportStatus.timeout;
      default:
        return null;
    }
  }

  /// Shizuku 是否已运行（Binder 连接）
  bool _binderRunning = false;

  /// Shizuku 是否已授权
  bool _permissionGranted = false;

  /// 是否已检测过
  bool _checked = false;

  /// 测试用：是否将当前平台视为 Android（默认跟随真实平台）
  bool _isAndroidOverride = false;

  /// 测试用：替换 ShizukuApi 实例
  @visibleForTesting
  set shizukuApiForTest(ShizukuApi api) => _shizukuApi = api;

  /// 测试用：替换底层命令 runner（默认 [rustShizukuRunner]）
  @visibleForTesting
  static set commandRunnerForTest(
    Future<String?> Function(String command) runner,
  ) =>
      _commandRunner = runner;

  /// 测试用：直接注入 Shizuku 状态（跳过真实检测）
  @visibleForTesting
  void setShizukuStateForTest({
    required bool binder,
    required bool permission,
  }) {
    _binderRunning = binder;
    _permissionGranted = permission;
    _checked = true;
  }

  /// 测试用：强制指定平台是否为 Android（installApk 的平台判断）
  @visibleForTesting
  void setIsAndroidForTest(bool isAndroid) {
    _isAndroidOverride = isAndroid;
  }

  /// 重置单例（仅测试使用）
  @visibleForTesting
  static void resetForTest() {
    _instance?._cancelInstallPollers();
    _instance?._detachEventBridge();
    _instance = null;
    _commandRunner = rustShizukuRunner;
    installFacadeForTest = null;
    installEventsStreamForTest = null;
    installPollInterval = const Duration(milliseconds: 500);
    installPollTimeout = const Duration(seconds: 180);
    clock = DateTime.now;
    _appInstaller = AppInstaller.installApk;
  }

  /// 当前是否视为 Android 平台
  bool get _isAndroid => _isAndroidOverride || Platform.isAndroid;

  /// 当前安装方式偏好（默认系统安装）
  InstallMethod _preferredMethod = InstallMethod.system;

  /// 当前安装方式
  InstallMethod get preferredMethod => _preferredMethod;

  /// Shizuku Binder 是否运行
  bool get isBinderRunning => _binderRunning;

  /// Shizuku 是否已授权
  bool get isPermissionGranted => _permissionGranted;

  /// 是否检测过 Shizuku 状态
  bool get isChecked => _checked;

  /// Shizuku 是否完全可用（运行 + 授权）
  bool get isShizukuAvailable => _binderRunning && _permissionGranted;

  /// 检测 Shizuku 状态（Binder 连接 + 权限）
  Future<void> checkShizuku() async {
    try {
      _binderRunning = await _shizukuApi.pingBinder() ?? false;
      if (_binderRunning) {
        _permissionGranted = await _shizukuApi.checkPermission() ?? false;
      } else {
        _permissionGranted = false;
      }
    } catch (e) {
      appLog.error('InstallManager: 检测 Shizuku 失败 - $e');
      _binderRunning = false;
      _permissionGranted = false;
    }
    _checked = true;
  }

  /// 请求 Shizuku 授权（弹系统授权窗口）
  /// 返回是否授权成功
  Future<bool> requestPermission() async {
    if (!_binderRunning) {
      // 尝试重新检测
      await checkShizuku();
      if (!_binderRunning) return false;
    }
    try {
      final granted = await _shizukuApi.requestPermission() ?? false;
      _permissionGranted = granted;
      _checked = true;
      return granted;
    } catch (e) {
      appLog.error('InstallManager: 请求 Shizuku 授权失败 - $e');
      return false;
    }
  }

  /// 设置安装方式偏好
  void setPreferredMethod(InstallMethod method) {
    _preferredMethod = method;
  }

  /// Shell 单引号包裹路径，转义字符串内的内嵌单引号（用于拼接 sh -c 命令）
  String _shQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

  /// 判断 pm install 结果是否为"用户拒绝安装"（此时不应回退系统安装）
  bool _isUserRejected(String? result) {
    if (result == null) return false;
    final r = result.toLowerCase();
    return r.contains('rejected permissions') ||
        r.contains('install_failed_aborted');
  }

  /// 生成"暂存 APK 到 /data/local/tmp 再安装再清理"的 sh -c 兼容命令。
  /// system_server 无法读取 app 作用域外置存储（Android/data/<pkg>）下的文件，
  /// pm install 会报 "System server has no access to read file ..."，
  /// 故先把 APK 复制到 shell 与 system_server 均可读写的 /data/local/tmp 再安装。
  /// `;` 保证 cp/install 失败时临时文件仍被清理；cp 失败时 `&&` 短路，
  /// 输出不以 "Success" 开头 → isPmSuccess false → 走既有回退路径。
  String _stageAndInstallCommand(String filePath) {
    final stageName = 'gstore_install_'
        '${DateTime.now().millisecondsSinceEpoch}_'
        '${filePath.hashCode.abs()}.apk';
    final stage = '/data/local/tmp/$stageName';
    return "cp ${_shQuote(filePath)} ${_shQuote(stage)} && "
        "pm install -r ${_shQuote(stage)}; "
        "rm -f ${_shQuote(stage)}";
  }

  InstallFacade get _installFacade =>
      installFacadeForTest ?? InstallFacade.instance;

  InstallMethod _mapInstallMethod(String? method) {
    switch (method) {
      case 'shizuku':
        return InstallMethod.shizuku;
      case 'package_installer':
        return InstallMethod.packageInstaller;
      case 'intent':
        return InstallMethod.intent;
      case 'platform':
        return InstallMethod.platform;
      default:
        return InstallMethod.system;
    }
  }

  /// Installs a core download task through [InstallFacade] when the install
  /// flag is armed; otherwise delegates to the legacy [installApk] path.
  Future<(bool, InstallMethod)> installTask(
    String moduleTaskId,
    String filePath,
  ) async {
    if (!CoreFlags.install) {
      return installApk(filePath);
    }
    await DownloadFacade.instance.importLegacyOnce();
    return _installCoreTask(moduleTaskId, filePath);
  }

  Future<(bool, InstallMethod)> _installCoreTask(
    String moduleTaskId,
    String filePath,
  ) async {
    try {
      await _ensureInstallRecovered();
      final start = await _installFacade.install(moduleTaskId);
      final request = start.request;
      if (request == null) {
        // The core already settled this row: report it and DO NOT install.
        _maybeStartInstallPoller(moduleTaskId, start.record.status);
        return (
          start.record.isInstalled,
          _mapInstallMethod(start.record.method),
        );
      }
      final result = await _executeInstallRequest(
        request,
        fallbackPath: filePath,
      );
      // `install()` also queues the re-derivable `install.requested` event for
      // this session; drain it so a later drain does not install twice.
      await _drainInstallEvents(skipSessionId: request.sessionId);
      return result;
    } catch (e) {
      appLog.error('InstallManager: 核心安装失败 - $e', data: {
        'moduleTaskId': moduleTaskId,
        'filePath': filePath,
      });
      return (false, InstallMethod.system);
    }
  }

  /// Executes one durable [InstallRequest] and reports the terminal status.
  ///
  /// The staged `pm install` path is unchanged (Shizuku); a failure falls back
  /// to [AppInstaller.installApk] unless the user explicitly denied the install.
  Future<(bool, InstallMethod)> _executeInstallRequest(
    InstallRequest request, {
    String? fallbackPath,
  }) async {
    final method = _mapInstallMethod(request.method);
    final apkPath =
        request.apkPath.isNotEmpty ? request.apkPath : (fallbackPath ?? '');

    if (!_isAndroid) {
      await _reportRequest(
        request,
        status: InstallReportStatus.failed,
        error: 'CORE_E_INSTALL_PLATFORM: install effects need Android',
      );
      return (false, method);
    }
    if (!apkPath.endsWith('.apk') || !File(apkPath).existsSync()) {
      await _reportRequest(
        request,
        status: InstallReportStatus.failed,
        error: 'CORE_E_INSTALL_APK_MISSING: $apkPath',
      );
      return (false, method);
    }

    var ok = false;
    var status = InstallReportStatus.failed;
    String? error;

    if (request.method == 'shizuku') {
      if (!_checked) await checkShizuku();
      if (_binderRunning && _permissionGranted) {
        try {
          final result = await _commandRunner(
            _stageAndInstallCommand(apkPath),
          );
          if (isPmSuccess(result)) {
            ok = true;
            status = InstallReportStatus.installed;
          } else if (_isUserRejected(result)) {
            status = InstallReportStatus.denied;
            error = result;
          } else {
            error = result ?? 'pm install returned no output';
          }
        } on TimeoutException catch (e) {
          status = InstallReportStatus.timeout;
          error = '$e';
        } catch (e) {
          error = '$e';
        }
      }
    }

    if (!ok && status != InstallReportStatus.denied) {
      try {
        await _appInstaller(apkPath);
        ok = true;
        status = InstallReportStatus.installed;
        error = null;
      } catch (e) {
        status = InstallReportStatus.failed;
        error = '$e';
      }
    }

    await _reportRequest(
      request,
      status: status,
      installedVersion: ok ? request.versionName : null,
      error: error,
    );
    return (ok, method);
  }

  Future<void> _reportRequest(
    InstallRequest request, {
    required String status,
    String? installedVersion,
    String? error,
  }) async {
    if (request.sessionId.isEmpty) return;
    try {
      await _installFacade.reportResult(
        InstallReport(
          sessionId: request.sessionId,
          status: status,
          method: request.method,
          installedVersion: installedVersion,
          error: error,
          reportedAt: clock().millisecondsSinceEpoch,
        ),
      );
      appLog.info('InstallManager: 安装结果已上报', data: {
        'sessionId': request.sessionId,
        'status': status,
        'method': request.method,
      });
    } catch (e) {
      appLog.error('InstallManager: 安装结果上报失败 - $e', data: {
        'sessionId': request.sessionId,
        'status': status,
      });
    }
  }

  /// Drains `install.requested` events and executes every request they carry.
  ///
  /// Called from the existing download-done path (`DownloadTaskWatcher`), so no
  /// new always-on timer is introduced. Returns the number of executed requests.
  Future<int> consumeInstallRequests() async {
    List<String> events;
    try {
      events = await _installFacade.takeEvents();
    } catch (e) {
      appLog.error('InstallManager: 读取安装事件失败 - $e');
      return 0;
    }
    var handled = 0;
    for (final raw in events) {
      final request = parseInstallRequestEvent(raw);
      if (request == null) {
        debugPrint('InstallManager: 忽略无法解析的安装事件');
        continue;
      }
      handled++;
      await _executeInstallRequest(request);
    }
    return handled;
  }

  Future<void> _drainInstallEvents({required String skipSessionId}) async {
    try {
      final events = await _installFacade.takeEvents();
      for (final raw in events) {
        final request = parseInstallRequestEvent(raw);
        if (request == null || request.sessionId == skipSessionId) continue;
        await _executeInstallRequest(request);
      }
    } catch (e) {
      appLog.error('InstallManager: 清理安装事件失败 - $e');
    }
  }

  /// Recovers installs left pending by a previous process exactly once before
  /// the first core install attempt.
  Future<void> _ensureInstallRecovered() async {
    if (_installRecoveryDone) return;
    _installRecoveryDone = true;
    try {
      // `pendingRequests()` runs the read-driven timeout sweep and returns the
      // rows a previous process left pending.
      await _installFacade.pendingRequests();
    } catch (e) {
      appLog.error('InstallManager: 启动安装恢复失败（忽略） - $e');
    }
  }

  void _maybeStartInstallPoller(String moduleTaskId, String status) {
    if (status != 'pending' || _installPollers.containsKey(moduleTaskId)) {
      return;
    }
    final intervalMs = installPollInterval.inMilliseconds;
    final maxTicks = intervalMs <= 0
        ? 0
        : installPollTimeout.inMilliseconds ~/ intervalMs;
    var ticks = 0;
    late final Timer timer;
    timer = Timer.periodic(installPollInterval, (t) {
      ticks++;
      if (ticks > maxTicks) {
        t.cancel();
        _installPollers.remove(moduleTaskId);
        appLog.error('InstallManager: 核心安装结果轮询超时', data: {
          'moduleTaskId': moduleTaskId,
        });
        return;
      }
      unawaited(_pollInstallOnce(moduleTaskId, t));
    });
    _installPollers[moduleTaskId] = timer;
  }

  Future<void> _pollInstallOnce(String moduleTaskId, Timer timer) async {
    try {
      await _installFacade.pendingRequests();
      final record = await _installFacade.get(moduleTaskId);
      final status = record?.status;
      if (status == null || !_terminalInstallStatuses.contains(status)) {
        return;
      }
      timer.cancel();
      _installPollers.remove(moduleTaskId);
      appLog.info('InstallManager: 核心安装结束', data: {
        'moduleTaskId': moduleTaskId,
        'status': status,
        'error': record?.error,
      });
    } catch (e) {
      appLog.error('InstallManager: 核心安装结果轮询失败 - $e', data: {
        'moduleTaskId': moduleTaskId,
      });
    }
  }

  void _cancelInstallPollers() {
    for (final timer in _installPollers.values) {
      timer.cancel();
    }
    _installPollers.clear();
  }

  Future<String?> _findCoreTaskId(String filePath) async {
    try {
      await DownloadFacade.instance.importLegacyOnce();
      for (final dto in await DownloadFacade.instance.list()) {
        if (dto.destPath == filePath) {
          return dto.moduleTaskId ?? dto.id.toString();
        }
      }
    } catch (e) {
      appLog.error('InstallManager: 查询核心下载任务失败 - $e', data: {
        'filePath': filePath,
      });
    }
    return null;
  }

  /// 安装 APK
  /// `CoreFlags.install` 开启时只走核心安装；未命中且显式标记为模块 APK 时
  /// 才保留旧安装路径。返回 (是否成功, 使用的安装方式)
  Future<(bool, InstallMethod)> installApk(
    String filePath, {
    bool moduleInstall = false,
  }) async {
    if (CoreFlags.install) {
      final coreTaskId = await _findCoreTaskId(filePath);
      if (coreTaskId != null) {
        return _installCoreTask(coreTaskId, filePath);
      }
      if (!moduleInstall) {
        appLog.error(
          'InstallManager: $_installNoCoreTask 未找到核心下载任务，拒绝回退旧安装路径',
          data: {'filePath': filePath},
        );
        return (false, InstallMethod.system);
      }
      appLog.info(
        'InstallManager: 模块 APK 不在内核下载任务中，使用模块安装路径: $filePath',
      );
    }
    return _legacyInstallApk(filePath);
  }

  /// 旧 Shizuku/系统安装路径；仅 flag 关闭或显式模块 APK 时使用。
  Future<(bool, InstallMethod)> _legacyInstallApk(String filePath) async {
    if (!_isAndroid || !filePath.endsWith('.apk')) {
      return (false, _preferredMethod);
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return (false, _preferredMethod);
    }

    // 尝试 Shizuku 静默安装（未检测时先检测）
    if (!_checked) {
      await checkShizuku();
    }

    if (_binderRunning && _permissionGranted) {
      // 显示加载框，避免 Shizuku 暂存+安装期间界面无反馈（finally 必 dismiss）
      AppDialogs.showLoading(message: '正在通过 Shizuku 安装...');
      try {
        final result = await _commandRunner(_stageAndInstallCommand(filePath));
        if (isPmSuccess(result)) {
          appLog.info('InstallManager: Shizuku 静默安装成功');
          return (true, InstallMethod.shizuku);
        }
        if (_isUserRejected(result)) {
          // 用户明确拒绝安装：不再回退系统安装
          appLog.error('InstallManager: 用户拒绝安装，停止安装', data: {
            'result': result,
            'filePath': filePath,
          });
          return (false, InstallMethod.shizuku);
        }
        // 失败：记录完整输出（pm 的 Failure [...] 即失败原因），落入回退系统安装
        appLog.error('InstallManager: Shizuku 静默安装失败，回退系统安装', data: {
          'result': result ?? '(命令未执行/无输出)',
          'filePath': filePath,
          'binderRunning': _binderRunning,
          'permissionGranted': _permissionGranted,
        });
      } catch (e) {
        appLog.error('InstallManager: Shizuku 安装异常 - $e，回退系统安装', data: {
          'filePath': filePath,
        });
      } finally {
        AppDialogs.dismissLoading();
      }
    }

    // 回退系统安装
    try {
      await AppInstaller.installApk(filePath);
      return (true, InstallMethod.system);
    } catch (e) {
      appLog.error('InstallManager: 系统安装失败 - $e');
      return (false, InstallMethod.system);
    }
  }

  /// 静默安装（仅 Shizuku，返回是否成功）
  Future<bool> silentInstall(String filePath) async {
    return _runShizukuCommand(_stageAndInstallCommand(filePath));
  }

  /// 卸载/停用/启用应用（Shizuku）
  /// [action] uninstall（卸载）/ disable（停用）/ enable（启用）
  /// 返回是否成功
  Future<bool> managePackage(String packageName, String action) async {
    if (action == 'uninstall' && CoreFlags.install) {
      try {
        await _installFacade.uninstall(packageName);
        return true;
      } catch (e) {
        appLog.error('InstallManager: 核心卸载失败 - $e', data: {
          'packageName': packageName,
        });
        return false;
      }
    }
    final command = switch (action) {
      'uninstall' => 'pm uninstall --user 0 "$packageName"',
      'disable' => 'pm disable-user --user 0 "$packageName"',
      'enable' => 'pm enable "$packageName"',
      _ => '',
    };
    if (command.isEmpty) return false;
    return _runShizukuCommand(command);
  }

  /// 清理应用数据（相当于清除全部数据，保留 APK）
  Future<bool> clearAppData(String packageName) async {
    return _runShizukuCommand('pm clear "$packageName"');
  }

  /// 清理应用缓存（仅缓存，不删除数据）
  /// 使用 pm clear --cache-only 只清除缓存目录，速度快不会卡 UI
  /// 注：不要使用 pm trim-caches（会全局扫描极慢导致 ANR）
  Future<bool> clearAppCache(String packageName) async {
    return _runShizukuCommand('pm clear --cache-only "$packageName"');
  }

  /// 强制停止应用
  Future<bool> forceStopApp(String packageName) async {
    return _runShizukuCommand('am force-stop "$packageName"',
        checkPmSuccess: false);
  }

  /// 执行 Shizuku 命令（统一权限检查 + 执行）
  /// [checkPmSuccess] 为 true（默认，pm 类命令）时按输出 "Success" 开头判定成功；
  /// false（am 类命令，成功无输出）时用 [_isAmSuccess] 判定（空输出=成功，
  /// 含 Failure/Exception/Error/Unknown command 关键词=失败）
  Future<bool> _runShizukuCommand(String command,
      {bool checkPmSuccess = true}) async {
    // 每次执行前都确保 Shizuku 状态是最新的：
    // 不依赖 _checked 一次性标记——Shizuku 可能在上次检测后才启动/授权，
    // 也可能之后被用户停止/撤销授权，陈旧状态会导致命令误判不可用或误发。
    // pingBinder/checkPermission 均为轻量调用，重复检测开销可忽略。
    if (!_binderRunning || !_permissionGranted) {
      await checkShizuku();
      if (!_binderRunning || !_permissionGranted) {
        appLog.error('InstallManager: 命令未执行（Shizuku 不可用）', data: {
          'command': command,
        });
        return false;
      }
    }
    try {
      final result = await _commandRunner(command);
      final ok = checkPmSuccess ? isPmSuccess(result) : _isAmSuccess(result);
      if (ok) {
        appLog.info('InstallManager: 命令执行成功', data: {
          'command': command,
          'result': result ?? '(无输出)',
        });
      } else {
        appLog.error('InstallManager: 命令执行失败', data: {
          'command': command,
          'result': result ?? '(无输出)',
          'binderRunning': _binderRunning,
          'permissionGranted': _permissionGranted,
        });
      }
      return ok;
    } catch (e) {
      appLog.error('InstallManager: 命令执行异常 - $e', data: {'command': command});
      return false;
    }
  }

  // ==================== 系统界面回退（无 Shizuku 时使用） ====================

  static const MethodChannel _systemIntentChannel =
      MethodChannel('gstore/system_intent');

  /// 打开系统卸载界面（无 Shizuku 时回退）
  /// 跳转到系统"卸载应用"确认界面，由用户手动确认
  Future<bool> openUninstallInSystem(String packageName) async {
    try {
      final ok =
          await _systemIntentChannel.invokeMethod<bool>('openUninstall', {
        'packageName': packageName,
      });
      return ok ?? false;
    } catch (e) {
      appLog.error('InstallManager: 打开系统卸载界面失败 - $e');
      return false;
    }
  }

  /// 打开系统应用详情页（无 Shizuku 时回退清理数据/缓存）
  /// 用户可在系统详情页手动"清除数据"/"清除缓存"
  Future<bool> openAppDetailsInSystem(String packageName) async {
    try {
      final ok =
          await _systemIntentChannel.invokeMethod<bool>('openAppDetails', {
        'packageName': packageName,
      });
      return ok ?? false;
    } catch (e) {
      appLog.error('InstallManager: 打开系统应用详情失败 - $e');
      return false;
    }
  }
}
