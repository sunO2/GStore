import 'dart:io';
import 'package:app_installer/app_installer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
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

/// 已安装包的一次观测快照：版本名 + 版本号（任一可为空）。
///
/// 平台通道 `getInstalled` 只返回包当前状态，没有 `last_update_time`，因此
/// 「本次安装是否落地」只能靠安装前后的快照差分判定，而不能拿核心的
/// `version`（对 GitHub release 来源的下载它是 **release tag**，如
/// `Release v3.5.0-20261024.1`）去和安装包的 `version_name`（APK 自身的
/// 版本名，如 `3.4.0`）做字符串相等比较——两者本来就不同，永远匹配不上。
@immutable
class InstalledSnapshot {
  const InstalledSnapshot({this.versionName, this.versionCode});

  final String? versionName;
  final int? versionCode;

  @override
  bool operator ==(Object other) =>
      other is InstalledSnapshot &&
      other.versionName == versionName &&
      other.versionCode == versionCode;

  @override
  int get hashCode => Object.hash(versionName, versionCode);

  @override
  String toString() =>
      'InstalledSnapshot(versionName: $versionName, versionCode: $versionCode)';
}

/// 一次安装发起前的目标包快照。
///
/// [available] 为 false 表示平台读取失败（既不是「不存在」也无法差分），
/// 此时确认退回保守规则：只接受与核心 `version` 精确相等的 `version_name`。
/// 选择保守（宁可继续等/超时，也不误报 installed）是因为把一次未完成的安装
/// 谎报为 `installed` 会让核心行落定、抑制重试，比一次 `timeout` 危害更大。
@immutable
class _PreInstallSnapshot {
  const _PreInstallSnapshot(this.snapshot, {this.available = true});

  /// null = 安装前目标包不存在。
  final InstalledSnapshot? snapshot;
  final bool available;
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

  /// 平台分支发起系统安装器后，等待终端安装事件的上限（deadline）。
  ///
  /// 超过即上报 [InstallReportStatus.timeout]，保证 `pending` 行不会永久挂起。
  /// 默认 90s，明显短于核心 `InstallRules::timeout_secs`（默认 180s）的读驱动
  /// 清扫窗口，确保由前端先给出超时结论（而不是被核心静默清成 `unknown`）。
  @visibleForTesting
  static Duration installPendingDeadline = const Duration(seconds: 90);

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

  /// 平台校验接缝（旧版：仅版本名）。默认 null → 生产走 [_installedSnapshotCheck]。
  ///
  /// 保留给既有测试注入 `(packageName) async => '1.2.3'`；非 null 时读到的
  /// 版本名被包装成只带 [InstalledSnapshot.versionName] 的快照。
  static Future<String?> Function(String packageName)? _installedVersionCheck;

  @visibleForTesting
  static set installedVersionCheckForTest(
    Future<String?> Function(String packageName) check,
  ) =>
      _installedVersionCheck = check;

  /// 平台快照接缝：返回 [packageName] 的 `(version_name, version_code)`；
  /// 未安装 → null；平台异常向上抛出（调用方区分「不存在」与「读取失败」）。
  ///
  /// 生产走 `gstore/platform.getInstalled`（`PlatformChannelClient`），测试可注入
  /// 假件。用于 `pending` 行的终端确认兜底：系统安装器在前台运行时，Android 会
  /// 拦截发往后台应用的隐式 `PACKAGE_ADDED` / `PACKAGE_REPLACED` 广播，
  /// `install_events` 可能永远收不到终端结果（见 [recheckPendingInstalls]）。
  static Future<InstalledSnapshot?> Function(String packageName)
      _installedSnapshotCheck = _defaultInstalledSnapshot;

  @visibleForTesting
  static set installedSnapshotCheckForTest(
    Future<InstalledSnapshot?> Function(String packageName) check,
  ) =>
      _installedSnapshotCheck = check;

  /// 统一读取：优先旧版版本名注入（映射为快照），否则走快照接缝。
  static Future<InstalledSnapshot?> _readInstalledSnapshot(
    String packageName,
  ) async {
    final legacy = _installedVersionCheck;
    if (legacy != null) {
      final version = await legacy(packageName);
      return (version == null || version.isEmpty)
          ? null
          : InstalledSnapshot(versionName: version);
    }
    return _installedSnapshotCheck(packageName);
  }

  /// 生产平台校验：读取已安装包的版本名 + 版本号；未安装 → null。
  ///
  /// 平台异常不在此吞掉：调用方需要区分「包不存在」与「读取失败」，后者在
  /// 安装前快照里降级为保守规则。
  static Future<InstalledSnapshot?> _defaultInstalledSnapshot(
    String packageName,
  ) async {
    if (packageName.isEmpty) return null;
    final info = await PlatformChannelClient().getInstalled(packageName);
    if (info == null) return null;
    final version = info['version_name']?.toString();
    return InstalledSnapshot(
      versionName: (version == null || version.isEmpty) ? null : version,
      versionCode: _asInt(info['version_code']),
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}');
  }

  /// 发起系统安装器前捕获目标包快照；平台读取失败 → [available]=false。
  static Future<_PreInstallSnapshot> _capturePreInstallSnapshot(
    String packageName,
  ) async {
    if (packageName.isEmpty) {
      return const _PreInstallSnapshot(null, available: false);
    }
    try {
      return _PreInstallSnapshot(await _readInstalledSnapshot(packageName));
    } catch (e) {
      debugPrint('InstallManager: 安装前快照读取失败（保守回退） - $e');
      return const _PreInstallSnapshot(null, available: false);
    }
  }

  static const Set<String> _terminalInstallStatuses = <String>{
    'installed',
    'failed',
    'denied',
    'timeout',
    'unknown',
  };

  /// 核心的"进行中"状态：`_maybeStartInstallPoller` 只对它起轮询/截止计时。
  static const String _pendingInstallStatus = 'pending';

  final Map<String, Timer> _installPollers = <String, Timer>{};
  bool _installRecoveryDone = false;

  /// `pending` 行 → 该行持有中的安装请求（平台校验兜底使用；终态时移除）。
  final Map<String, InstallRequest> _pendingInstallRequests =
      <String, InstallRequest>{};

  /// `pending` 行 → 发起系统安装器前捕获的目标包快照（快照差分确认使用；
  /// 与 [_pendingInstallRequests] 同生命周期，终态时一并移除）。
  final Map<String, _PreInstallSnapshot> _pendingInstallPreSnapshots =
      <String, _PreInstallSnapshot>{};

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
      // The launch path only reports "已发起安装，等待系统确认"; the real terminal
      // result arrives here. Surface it once (the core reports `changed:false`
      // for a duplicate/late event).
      if (ack.changed) {
        _surfaceInstallResult(status, event.packageName, event.error);
      }
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
    installPendingDeadline = const Duration(seconds: 90);
    clock = DateTime.now;
    _appInstaller = AppInstaller.installApk;
    _installedVersionCheck = null;
    _installedSnapshotCheck = _defaultInstalledSnapshot;
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

  /// Installs a core download task through [InstallFacade].
  ///
  /// The install domain is core-owned after the Wave 6B cutover: there is no
  /// flag-off legacy branch. A missing mirror row surfaces as the facade's
  /// typed [InstallCoreException] (`CORE_E_INSTALL_NOT_FOUND`); every other
  /// failure keeps the historical log-and-degrade behaviour.
  ///
  /// [force] requests an OVERWRITE install: when the core row is already
  /// `installed` (the core settles it with no request), the downloaded APK is
  /// re-installed through the direct path instead of reporting
  /// [InstallOutcome.alreadyInstalled]. Defaults to false so the auto-install
  /// watcher keeps today's idempotent behaviour.
  Future<(InstallOutcome, InstallMethod)> installTask(
    String moduleTaskId,
    String filePath, {
    bool force = false,
  }) async {
    await DownloadFacade.instance.importLegacyOnce();
    return _installCoreTask(moduleTaskId, filePath, force: force);
  }

  Future<(InstallOutcome, InstallMethod)> _installCoreTask(
    String moduleTaskId,
    String filePath, {
    bool force = false,
  }) async {
    try {
      await _ensureInstallRecovered();
      final start = await _installFacade.install(moduleTaskId);
      final request = start.request;
      if (request == null) {
        // The core already settled this row: report it and DO NOT install —
        // unless the caller explicitly asked to overwrite an installed app.
        _maybeStartInstallPoller(moduleTaskId, start.record.status);
        if (force && start.record.isInstalled) {
          // An explicit 安装 tap on an `installed` core row: overwrite-install
          // the downloaded APK through the existing direct path (Shizuku, then
          // the system installer intent) and return ITS outcome. A missing or
          // invalid APK yields a typed [InstallOutcome.failed] there — never a
          // silent no-op and never an [InstallOutcome.alreadyInstalled] lie.
          return _installApkDirect(filePath);
        }
        return (
          start.record.isInstalled
              ? InstallOutcome.alreadyInstalled
              : InstallOutcome.failed,
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
    } on InstallCoreException {
      rethrow;
    } catch (e) {
      appLog.error('InstallManager: 核心安装失败 - $e', data: {
        'moduleTaskId': moduleTaskId,
        'filePath': filePath,
      });
      return (InstallOutcome.failed, InstallMethod.system);
    }
  }

  /// Executes one durable [InstallRequest] and reports the terminal status.
  ///
  /// The staged `pm install` path is unchanged (Shizuku, a REAL synchronous
  /// result). The system-installer fallback only *launches* the installer
  /// intent: that is NOT a completed install, so it is never reported as
  /// `installed` — the core row stays `pending` and the terminal result is
  /// delivered by `install_events` (or [installPendingDeadline] → `timeout`).
  Future<(InstallOutcome, InstallMethod)> _executeInstallRequest(
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
      return (InstallOutcome.failed, method);
    }
    if (!apkPath.endsWith('.apk') || !File(apkPath).existsSync()) {
      await _reportRequest(
        request,
        status: InstallReportStatus.failed,
        error: 'CORE_E_INSTALL_APK_MISSING: $apkPath',
      );
      return (InstallOutcome.failed, method);
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
      // 发起系统安装器前先记录目标包快照：核心 `version` 对 release 来源是
      // release tag，和安装包的 `version_name` 本就不同，只有 pre/post 差分
      // 能可靠判定「本次安装是否落地」（见 [_confirmPendingInstall]）。
      final preSnapshot =
          await _capturePreInstallSnapshot(request.packageName);
      try {
        await _appInstaller(apkPath);
        // Launching the installer intent is NOT a successful install: the user
        // may cancel, the system may block it (unknown-sources permission), or
        // it may fail. Do NOT report a terminal status — leaving the core row
        // `pending` keeps `install()` idempotent-but-retryable so a second tap
        // re-executes instead of silently succeeding (the reported
        // "点击安装无响应"). The terminal result arrives via `install_events`,
        // bounded by the deadline poller below.
        _maybeStartInstallPoller(
          request.moduleTaskId,
          _pendingInstallStatus,
          request: request,
          preSnapshot: preSnapshot,
        );
        return (InstallOutcome.launched, method);
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
    return (ok ? InstallOutcome.installed : InstallOutcome.failed, method);
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

  /// Starts (once per module task) the pending-install watcher.
  ///
  /// Two jobs, one timer:
  /// 1. Poll the core row so a terminal result delivered out-of-band
  ///    (`install_events` → [reportResult]) ends the watcher.
  /// 2. Enforce a DEADLINE: when [installPendingDeadline] elapses with the row
  ///    still `pending`, report [InstallReportStatus.timeout] for [request].
  ///    This is the only mechanism guaranteeing a `pending` row cannot hang
  ///    forever (a launch that never yields an event still terminates).
  ///
  /// `installPollTimeout` remains the outer hard cap: the effective deadline is
  /// the smaller of the two, so a misconfigured deadline still terminates.
  void _maybeStartInstallPoller(
    String moduleTaskId,
    String status, {
    InstallRequest? request,
    _PreInstallSnapshot? preSnapshot,
  }) {
    if (status != _pendingInstallStatus ||
        _installPollers.containsKey(moduleTaskId)) {
      return;
    }
    final interval = installPollInterval;
    if (interval <= Duration.zero) return;
    if (request != null) {
      _pendingInstallRequests[moduleTaskId] = request;
      if (preSnapshot != null) {
        _pendingInstallPreSnapshots[moduleTaskId] = preSnapshot;
      }
    }
    final deadline = installPendingDeadline < installPollTimeout
        ? installPendingDeadline
        : installPollTimeout;
    final maxTicks = deadline.inMilliseconds ~/ interval.inMilliseconds;
    var ticks = 0;
    late final Timer timer;
    timer = Timer.periodic(interval, (t) {
      ticks++;
      if (ticks > maxTicks) {
        t.cancel();
        _installPollers.remove(moduleTaskId);
        unawaited(_finishPendingInstall(
          _pendingInstallRequests.remove(moduleTaskId),
          deadline,
        ));
        return;
      }
      unawaited(_pollInstallOnce(moduleTaskId, t));
    });
    _installPollers[moduleTaskId] = timer;
  }

  /// 截止时的最后处置：先做一次平台校验，确认则报 `installed`，否则报 `timeout`。
  ///
  /// `request == null`（核心行已由其它路径落定）时什么都不做，与旧行为一致。
  Future<void> _finishPendingInstall(
    InstallRequest? request,
    Duration deadline,
  ) async {
    if (request == null) return;
    try {
      // 核心可能已由 `install_events` 落定（前台收到终端广播）：以核心为准，
      // 既不再校验、也不再报 timeout（覆盖终态会丢真相）。
      if (await _coreInstallSettled(request.moduleTaskId)) return;
      // 安装可能恰好在 deadline 前完成，而系统广播仍被拦截（应用在后台）：
      // 这是避免把一次成功安装误报为 timeout 的最后机会。
      if (await _confirmPendingInstall(request)) return;
      appLog.error('InstallManager: 安装结果等待超时（deadline）', data: {
        'moduleTaskId': request.moduleTaskId,
        'deadlineMs': deadline.inMilliseconds,
      });
      unawaited(_reportRequest(
        request,
        status: InstallReportStatus.timeout,
        error: 'CORE_E_INSTALL_TIMEOUT: no install event within '
            '${deadline.inSeconds}s',
      ));
      _surfaceInstallResult(
        InstallReportStatus.timeout,
        request.packageName,
        null,
      );
    } finally {
      // 请求已在计时器回调里从 `_pendingInstallRequests` 移除；快照同生命周期。
      _pendingInstallPreSnapshots.remove(request.moduleTaskId);
    }
  }

  Future<void> _pollInstallOnce(String moduleTaskId, Timer timer) async {
    InstallRecord? record;
    try {
      await _installFacade.pendingRequests();
      record = await _installFacade.get(moduleTaskId);
    } catch (e) {
      appLog.error('InstallManager: 核心安装结果轮询失败 - $e', data: {
        'moduleTaskId': moduleTaskId,
      });
    }
    final status = record?.status;
    if (status != null && _terminalInstallStatuses.contains(status)) {
      // 核心已落定（前台收到终端事件 / 核心清扫）：以核心为准，结束轮询。
      _cancelInstallPoller(moduleTaskId, timer);
      appLog.info('InstallManager: 核心安装结束', data: {
        'moduleTaskId': moduleTaskId,
        'status': status,
        'error': record?.error,
      });
      return;
    }
    // 核心仍 `pending`：终端广播发往后台应用会被 Android 拦截
    // （on-device：`BroadcastQueue: Background execution not allowed`），
    // 包状态查询不依赖前台时机，是这种情况下唯一可靠的确认信号。
    final pending = _pendingInstallRequests[moduleTaskId];
    if (pending != null && await _confirmPendingInstall(pending)) {
      _cancelInstallPoller(moduleTaskId, timer);
    }
  }

  /// 核心行是否已落定（终态）。查询失败按「未落定」处理（保守，仍走校验/超时）。
  Future<bool> _coreInstallSettled(String moduleTaskId) async {
    try {
      final record = await _installFacade.get(moduleTaskId);
      final status = record?.status;
      return status != null && _terminalInstallStatuses.contains(status);
    } catch (e) {
      appLog.error('InstallManager: 核心安装结果查询失败 - $e', data: {
        'moduleTaskId': moduleTaskId,
      });
      return false;
    }
  }

  /// 回到前台时对全部仍 `pending` 的安装做一次平台校验。
  ///
  /// 由 `InstallResumeBridge` 在 `AppLifecycleState.resumed` 时调用：用户从系统
  /// 安装器返回，正是终端结果最可能已产生、而隐式广播最可能被拦截的时刻。
  /// 幂等；无 `pending` 安装时安全 no-op。
  Future<void> recheckPendingInstalls() async {
    final ids = _pendingInstallRequests.keys.toList(growable: false);
    for (final moduleTaskId in ids) {
      final request = _pendingInstallRequests[moduleTaskId];
      if (request == null) continue;
      // 核心已落定则直接清理跟踪，不以平台校验覆盖核心终态。
      if (await _coreInstallSettled(moduleTaskId)) {
        _pendingInstallRequests.remove(moduleTaskId);
        _pendingInstallPreSnapshots.remove(moduleTaskId);
        continue;
      }
      if (await _confirmPendingInstall(request)) {
        final timer = _installPollers[moduleTaskId];
        if (timer != null) {
          _cancelInstallPoller(moduleTaskId, timer);
        } else {
          _pendingInstallRequests.remove(moduleTaskId);
          _pendingInstallPreSnapshots.remove(moduleTaskId);
        }
      }
    }
  }

  /// 平台校验：确认本次安装已落地时上报 `installed`，返回是否已确认。
  ///
  /// 确认规则（任一命中即接受）：
  /// 1. 精确 `version_name` 匹配（保留的附加路径；核心 `version` 恰好就是
  ///    APK 版本名时命中，无害）。
  /// 2. 安装前快照差分：安装前包 **不存在**、现在存在；或安装前已存在、但
  ///    `version_name` **或** `version_code` 发生变化。这对 GitHub release
  ///    来源的下载是唯一可靠的信号——核心 `version` 是 release tag
  ///    （如 `Release v3.5.0-20261024.1`），与安装包的 `version_name`
  ///    （如 `3.4.0`→`3.5.0`）本就不同，字符串比较永远失败。
  ///
  /// 快照未变化 / 安装前快照读取失败（保守回退）→ 不确认，交由 deadline
  /// 报 `timeout`。核心对重复上报返回 `changed:false`，与 `install_events`
  /// 路径天然幂等。
  Future<bool> _confirmPendingInstall(InstallRequest request) async {
    final packageName = request.packageName;
    if (packageName.isEmpty) return false;
    InstalledSnapshot? current;
    try {
      current = await _readInstalledSnapshot(packageName);
    } catch (e) {
      debugPrint('InstallManager: 平台安装校验失败（忽略） - $e');
      return false;
    }
    // 包当前不存在 → 本次安装尚未落地。
    if (current == null) return false;

    final pre = _pendingInstallPreSnapshots[request.moduleTaskId];
    final exactMatch =
        _versionMatches(request.versionName, current.versionName ?? '');
    final changed = _snapshotChanged(pre, current);
    if (!exactMatch && !changed) {
      debugPrint(
        'InstallManager: 包已安装但快照未变化，暂不确认 '
        '（expected=${request.versionName} installed=${current.versionName} '
        'code=${current.versionCode} preAvailable=${pre?.available ?? false}）',
      );
      return false;
    }
    appLog.info('InstallManager: 平台校验确认安装完成', data: {
      'sessionId': request.sessionId,
      'packageName': packageName,
      'installedVersion': current.versionName,
      'confirmedBy': exactMatch ? 'version-name-match' : 'snapshot-changed',
    });
    await _reportRequest(
      request,
      status: InstallReportStatus.installed,
      installedVersion: current.versionName ?? request.versionName,
    );
    _surfaceInstallResult(
      InstallReportStatus.installed,
      request.packageName,
      null,
    );
    return true;
  }

  /// 安装前快照 vs 当前快照是否发生变化。
  ///
  /// - [pre] 为 null 或 [pre.available] 为 false（平台读取失败）：无法差分 →
  ///   返回 false（保守回退：只认精确 `version_name` 匹配）。
  /// - 安装前不存在（[pre].snapshot == null）而现在存在 → 变化。
  /// - 安装前已存在：`version_name` 或 `version_code` 任一变化 → 变化。
  static bool _snapshotChanged(
    _PreInstallSnapshot? pre,
    InstalledSnapshot current,
  ) {
    if (pre == null || !pre.available) return false;
    final before = pre.snapshot;
    if (before == null) return true;
    return before.versionName != current.versionName ||
        before.versionCode != current.versionCode;
  }

  /// 期望版本与平台报告版本的比对。
  ///
  /// 期望版本缺失时只要求包存在；否则要求版本名一致（忽略首尾空白），避免把
  /// 「旧版本仍在」误判为本次安装成功。
  static bool _versionMatches(String expected, String actual) {
    final trimmed = expected.trim();
    if (trimmed.isEmpty) return true;
    return trimmed == actual.trim();
  }

  void _cancelInstallPoller(String moduleTaskId, Timer timer) {
    timer.cancel();
    _installPollers.remove(moduleTaskId);
    _pendingInstallRequests.remove(moduleTaskId);
    _pendingInstallPreSnapshots.remove(moduleTaskId);
  }

  /// Surfaces a terminal install result to the user.
  ///
  /// The download page's `installApp` only reports the immediate launch
  /// ("已发起安装，等待系统确认"); the real terminal result arrives later through
  /// the event bridge or the deadline, and is shown here so it is never
  /// swallowed. [AppDialogs] no-ops when no `ScaffoldMessenger` is mounted, so
  /// this is safe in tests and headless paths.
  void _surfaceInstallResult(String status, String? appName, String? error) {
    final name = (appName == null || appName.isEmpty) ? '应用' : appName;
    switch (status) {
      case InstallReportStatus.installed:
        AppDialogs.showSuccess('$name 安装完成');
      case InstallReportStatus.denied:
        AppDialogs.showWarning(
          '$name 安装被拒绝：请在系统设置中允许「安装未知应用」后重试',
          title: '安装未完成',
        );
      case InstallReportStatus.timeout:
        AppDialogs.showWarning('$name 安装超时，请重试', title: '安装未完成');
      case InstallReportStatus.failed:
        AppDialogs.showError(
          error == null || error.isEmpty ? '$name 安装失败' : '$name 安装失败：$error',
          title: '安装失败',
        );
      default:
        // Non-terminal status: no user-visible message.
        break;
    }
  }

  void _cancelInstallPollers() {
    for (final timer in _installPollers.values) {
      timer.cancel();
    }
    _installPollers.clear();
    _pendingInstallRequests.clear();
    _pendingInstallPreSnapshots.clear();
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
  ///
  /// Splits by core state, not by the flag mirror: a core download row is
  /// resolved by [dest_path], and only when it exists does the install go
  /// through [InstallFacade]. Otherwise this is a direct user-picked APK install
  /// ([_installApkDirect]) that creates no core state.
  ///
  /// [moduleInstall] is retained only for call-site source compatibility; the
  /// split no longer depends on it and the parameter is intentionally unused.
  ///
  /// [force] requests an OVERWRITE install: when the resolved core row is
  /// already `installed` (no request), the APK is re-installed through the
  /// direct path instead of reporting [InstallOutcome.alreadyInstalled].
  /// Defaults to false so every existing auto-install caller keeps today's
  /// behaviour. A user-picked APK with no core row already takes the direct
  /// path, so [force] only affects the core-resolved case.
  /// 返回 ([InstallOutcome], 使用的安装方式)
  Future<(InstallOutcome, InstallMethod)> installApk(
    String filePath, {
    bool moduleInstall = false,
    bool force = false,
  }) async {
    final coreTaskId = await _findCoreTaskId(filePath);
    if (coreTaskId != null) {
      return _installCoreTask(coreTaskId, filePath, force: force);
    }
    return _installApkDirect(filePath);
  }

  /// Direct Shizuku/system install for a user-picked APK.
  ///
  /// Deliberately NOT a legacy core-state writer: it never creates or mutates a
  /// core row, so it is not guarded by `LegacyWriteGuard` (after the cutover the
  /// `install` marker is armed and a guard here would break manual installs).
  Future<(InstallOutcome, InstallMethod)> _installApkDirect(
    String filePath,
  ) async {
    if (!_isAndroid || !filePath.endsWith('.apk')) {
      appLog.error('InstallManager: 直接安装不可用（平台/扩展名）', data: {
        'filePath': filePath,
        'isAndroid': _isAndroid,
      });
      return (InstallOutcome.failed, _preferredMethod);
    }

    final file = File(filePath);
    if (!await file.exists()) {
      appLog.error('InstallManager: 直接安装的 APK 不存在', data: {
        'filePath': filePath,
      });
      return (InstallOutcome.failed, _preferredMethod);
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
          return (InstallOutcome.installed, InstallMethod.shizuku);
        }
        if (_isUserRejected(result)) {
          // 用户明确拒绝安装：不再回退系统安装
          appLog.error('InstallManager: 用户拒绝安装，停止安装', data: {
            'result': result,
            'filePath': filePath,
          });
          return (InstallOutcome.failed, InstallMethod.shizuku);
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

    // 回退系统安装：仅"发起"系统安装器 Intent，真正的结果由系统界面决定。
    try {
      await AppInstaller.installApk(filePath);
      return (InstallOutcome.launched, InstallMethod.system);
    } catch (e) {
      appLog.error('InstallManager: 系统安装失败 - $e');
      return (InstallOutcome.failed, InstallMethod.system);
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
    if (action == 'uninstall') {
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
