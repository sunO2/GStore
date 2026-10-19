/// 前台应用监视器（Shizuku 轮询）。
///
/// 单一职责：按固定节拍（默认 5s，可配置，且**不得快于**遥测间隔）经 Todo 10 的
/// [PrivilegedShell] 执行 `dumpsys activity activities`，把原文交给 Rust
/// [PerfModule.foreground]（`perf.foreground`）解析出当前前台包名，并在**变化时**
/// 通过 [events] 广播一条 [ForegroundEvent]。本文件**只做轮询与去重**——不做
/// 采样、不写节点、不应用 profile（自动应用引擎见后续 Todo）。
///
/// ## 硬约束（务必遵守）
/// * **Shizuku 可用性门禁**：[start] 先探测 Shizuku（可注入）；不可用 →
///   [status] 置为 [ForegroundWatcherStatus.disabled] 且
///   [disabledReason] = [ForegroundDisabledReason.shizukuUnavailable]，
///   **零轮询、零命令**（降级而非崩溃）。轮询连续失败达
///   [maxConsecutiveFailures] 次同样降级为 disabled。
/// * **屏幕状态门禁**：每拍先查屏幕（可注入 [ScreenOnProbe]）；熄屏 →
///   [ForegroundWatcherStatus.paused]，**跳过前台轮询（零 `dumpsys activity`）**；
///   亮屏后自动恢复。亮/灭**切换**经 [screenEvents] 广播一条 [ScreenStateEvent]
///   （复用同一探测，无新通路 / 无 manifest 变更），供自动应用引擎 sleep/resume。
/// * **单线程 executor 不饿死控制写**：Shizuku 插件为单线程串行执行；本监视器
///   每拍**至多**发一条特权命令，用 [_pollerInFlight] 单飞守卫避免命令堆叠，且
///   每条命令经 [PrivilegedShell.buildCommand] 自我限时（`timeout n sh -c`）。
///   故一条控制写最多排在**一条**有界的前台命令之后，不会被无限延后。
/// * **绝不忙轮询**：仅 [Timer.periodic]；单飞跳过重叠拍；单次轮询有
///   [maxPollBudget] 上限。
/// * **去重**：前台包名未变化时**不**发事件；首次为 `null`（无法判定）不发噪音
///   事件；已发过包名后变为 `null` 视为「离开前台」发一条清除事件。
///
/// ## 可测试性
/// runner（经 [PrivilegedShell]）、[PerfModule]、屏幕状态、Shizuku 探测、时钟
/// **全部可注入**；单元测试用罐头 `dumpsys` 文本即可，**不需要** Shizuku /
/// 真机 / 原生插件。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shizuku_api/shizuku_api.dart';

import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 时钟（Unix 时间源）；测试注入以便事件时间戳可复现。
typedef Clock = DateTime Function();

/// 屏幕是否点亮：`true` = 亮屏（继续轮询），`false` = 熄屏（暂停轮询）。
typedef ScreenOnProbe = Future<bool> Function();

/// Shizuku 是否可用（Binder 存活 + 已授权）；异常一律视为不可用。
typedef ShizukuAvailabilityProbe = Future<bool> Function();

/// 监视器运行状态。
enum ForegroundWatcherStatus {
  /// 已构造但未启动 / 已 [ForegroundWatcher.stop] 停止（可再次启动）。
  idle,

  /// 正在周期轮询。
  running,

  /// 屏幕熄灭，已暂停轮询（亮屏后自动恢复）。
  paused,

  /// 已禁用（Shizuku 不可用 / 连续轮询失败）；可重试 [ForegroundWatcher.start]。
  disabled,

  /// 已释放，不可再启动。
  disposed,
}

/// 禁用原因（[ForegroundWatcher.disabledReason] 的取值，结构化）。
abstract final class ForegroundDisabledReason {
  /// Shizuku Binder 未运行 / 未授权 / 连续轮询失败。
  static const String shizukuUnavailable = 'shizuku_unavailable';
}

/// 一次前台变化事件（仅在前台包名发生变化时发出）。
class ForegroundEvent {
  const ForegroundEvent({
    required this.package,
    required this.previousPackage,
    required this.tsMs,
  });

  /// 当前前台包名；`null` = 已离开前台 / 无法判定。
  final String? package;

  /// 上一前台包名（首个事件为 `null`）。
  final String? previousPackage;

  /// 事件时间（Unix ms，来自注入时钟）。
  final int tsMs;

  /// 是否有真实的前台包（`false` = 清除事件）。
  bool get hasPackage => package != null;

  /// 结构化 JSON（证据 / 日志用）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'package': package,
        'previous': previousPackage,
        'ts_ms': tsMs,
      };

  @override
  String toString() =>
      'ForegroundEvent(package: $package, previous: $previousPackage, '
      'tsMs: $tsMs)';
}

/// 一次**屏幕状态变化**事件（仅在亮/灭**切换**时发出）。
///
/// 复用本监视器每拍已有的屏幕探测（[ScreenOnProbe]，`dumpsys power`），**不**
/// 新建屏幕检测通路、**不**新增 manifest 权限；仅供自动应用引擎在熄屏时
/// sleep（还原）、亮屏时 resume（见 `perf_profile_auto_engine.dart`）。
class ScreenStateEvent {
  const ScreenStateEvent({required this.screenOn, required this.tsMs});

  /// 是否亮屏（`true` = 亮屏；`false` = 熄屏）。
  final bool screenOn;

  /// 事件时间（Unix ms，来自注入时钟）。
  final int tsMs;

  /// 结构化 JSON（证据 / 日志用）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'screen_on': screenOn,
        'ts_ms': tsMs,
      };

  @override
  String toString() => 'ScreenStateEvent(screenOn: $screenOn, tsMs: $tsMs)';
}

/// Shizuku 轮询前台应用监视器。
///
/// 生产：`ForegroundWatcher()`（默认经 [PrivilegedShell] + [PerfModule.instance]）。
/// 测试：注入 runner / module / 屏幕 / Shizuku 探测 / 时钟，无需设备。
///
/// **生命周期**由 [PerfMonitorModule] 拥有（enable → [start]，disable/释放 →
/// [stop]/[dispose]）；本文件**不**接线，仅暴露干净的入口。
class ForegroundWatcher {
  ForegroundWatcher({
    PerfModule? module,
    PrivilegedShell? shell,
    ScreenOnProbe? screenOnProbe,
    ShizukuAvailabilityProbe? shizukuProbe,
    Clock? clock,
    Duration interval = defaultInterval,
    Duration telemetryInterval = defaultTelemetryInterval,
    this.maxPollBudget = const Duration(seconds: 6),
    this.maxConsecutiveFailures = 3,
  })  : _module = module ?? PerfModule.instance,
        _shell = shell ??
            PrivilegedShell(
              timeout: const Duration(seconds: 5),
              inShellTimeoutSeconds: 3,
            ),
        _clock = clock ?? DateTime.now,
        _shizukuProbe = shizukuProbe ?? _defaultShizukuProbe,
        interval = clampInterval(interval, telemetryInterval),
        telemetryInterval = clampInterval(telemetryInterval, telemetryInterval) {
    _screenOnProbe = screenOnProbe ?? _shellScreenOnProbe(_shell);
  }

  /// 默认轮询间隔（5s）。
  static const Duration defaultInterval = Duration(seconds: 5);

  /// 默认遥测间隔（2s，与性能页实时采样默认一致）。
  static const Duration defaultTelemetryInterval = Duration(seconds: 2);

  /// 轮询绝对下限（防止注入过小间隔导致忙轮询）。
  static const Duration minPollInterval = Duration(seconds: 1);

  /// 前台探测命令（经 [PrivilegedShell.buildCommand] 自我限时后执行）。
  static const String dumpsysCommand = 'dumpsys activity activities';

  /// 有效轮询间隔 = `max(interval, telemetryInterval, minPollInterval)`。
  ///
  /// 强制「轮询不得快于遥测间隔」，并保证一个忙轮询下限。
  static Duration clampInterval(Duration interval, Duration telemetryInterval) {
    var effective = interval;
    if (effective < telemetryInterval) effective = telemetryInterval;
    if (effective < minPollInterval) effective = minPollInterval;
    return effective;
  }

  static final ShizukuApi _sharedShizukuApi = ShizukuApi();

  final PerfModule _module;
  final PrivilegedShell _shell;
  final Clock _clock;
  final ShizukuAvailabilityProbe _shizukuProbe;
  late final ScreenOnProbe _screenOnProbe;

  /// 有效轮询间隔（已按 [clampInterval] 钳制）。
  final Duration interval;

  /// 遥测间隔（轮询不得快于此值）。
  final Duration telemetryInterval;

  /// 单次轮询（屏幕探测 + 命令 + 解析）的最大预算。
  final Duration maxPollBudget;

  /// 连续失败达到该次数即降级为 [ForegroundWatcherStatus.disabled]。
  final int maxConsecutiveFailures;

  final StreamController<ForegroundEvent> _controller =
      StreamController<ForegroundEvent>.broadcast(sync: true);

  /// 屏幕状态变化事件流控制器（与前台事件解耦；仅切换时发）。
  final StreamController<ScreenStateEvent> _screenController =
      StreamController<ScreenStateEvent>.broadcast(sync: true);

  Timer? _timer;
  bool _running = false;
  bool _pollerInFlight = false;
  bool _disposed = false;
  int _consecutiveFailures = 0;
  String? _disabledReason;
  String? _lastPackage;
  bool _hasEmitted = false;

  /// 最近一次成功探测到的屏幕状态（`null` = 尚未探测）；仅切换时发事件。
  bool? _lastScreenOn;
  int _pollCount = 0;
  int _emitCount = 0;
  int _skippedCount = 0;
  ForegroundWatcherStatus _status = ForegroundWatcherStatus.idle;

  // ==================== 可观测状态 ====================

  /// 前台变化事件流（广播；订阅即收后续事件，不缓冲）。
  Stream<ForegroundEvent> get events => _controller.stream;

  /// 屏幕状态变化事件流（广播；仅在亮/灭**切换**时发出，订阅即收后续事件）。
  ///
  /// 复用本监视器每拍的 [ScreenOnProbe]，**无**新增 manifest 权限 / 检测通路。
  Stream<ScreenStateEvent> get screenEvents => _screenController.stream;

  /// 当前状态。
  ForegroundWatcherStatus get status => _status;

  /// 禁用原因（[ForegroundDisabledReason]）；未禁用为 `null`。
  String? get disabledReason => _disabledReason;

  /// 是否正在运行（已启动且未停止 / 释放）。
  bool get isRunning => _running && !_disposed;

  /// 是否已释放。
  bool get isDisposed => _disposed;

  /// 成功执行的前台探测次数（`dumpsys activity` 成功 + 解析）。
  int get pollCount => _pollCount;

  /// 已发出的事件数。
  int get emittedEventCount => _emitCount;

  /// 被跳过的拍数（熄屏 / 单飞重叠 / 超预算）。
  int get skippedCount => _skippedCount;

  /// 当前连续失败次数。
  int get consecutiveFailures => _consecutiveFailures;

  // ==================== 生命周期 ====================

  /// 启动监视：先探测 Shizuku，不可用则禁用（零命令）；可用则立即轮询一拍并
  /// 周期轮询。幂等（运行中重复调用无操作）。
  Future<void> start() async {
    if (_disposed || _running) return;
    _running = true;
    final available = await _shizukuProbe();
    if (_disposed || !_running) return; // 探测期间被 stop/dispose
    if (!available) {
      _running = false;
      _status = ForegroundWatcherStatus.disabled;
      _disabledReason = ForegroundDisabledReason.shizukuUnavailable;
      debugPrint('[ForegroundWatcher] Shizuku 不可用 → 监视器已禁用（零轮询）');
      return;
    }
    _consecutiveFailures = 0;
    _disabledReason = null;
    _status = ForegroundWatcherStatus.running;
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
    unawaited(_tick());
  }

  /// 停止监视（取消定时器，保留事件流以便再次 [start]）。幂等。
  void stop() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _running = false;
    if (_status == ForegroundWatcherStatus.running ||
        _status == ForegroundWatcherStatus.paused) {
      _status = ForegroundWatcherStatus.idle;
    }
  }

  /// 释放监视器：停止定时器、关闭事件流。幂等；释放后不可再启动。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _status = ForegroundWatcherStatus.disposed;
    _disabledReason = null;
    if (!_controller.isClosed) await _controller.close();
    if (!_screenController.isClosed) await _screenController.close();
  }

  // ==================== 轮询 ====================

  Future<void> _tick() async {
    if (_disposed || !_running) return;
    if (_pollerInFlight) {
      _skippedCount++;
      return;
    }
    await _poll();
  }

  Future<void> _poll() async {
    if (_disposed || !_running || _pollerInFlight) {
      _skippedCount++;
      return;
    }
    _pollerInFlight = true;
    try {
      final screenOn = await _probeScreenOnForBudget();
      if (_disposed || !_running) return;
      // 亮/灭切换经 screenEvents 广播（复用本拍探测，无新通路）。
      _maybeEmitScreen(screenOn);
      if (!screenOn) {
        _status = ForegroundWatcherStatus.paused;
        _skippedCount++;
        return;
      }
      if (_status == ForegroundWatcherStatus.paused) {
        _status = ForegroundWatcherStatus.running;
      }
      final result = await _shell
          .run(_shell.buildCommand(dumpsysCommand))
          .timeout(maxPollBudget);
      if (_disposed || !_running) return;
      if (!result.ok) {
        _registerFailure(result.error ?? 'command_failed');
        return;
      }
      _pollCount++;
      final report =
          await _module.foreground(result.output).timeout(maxPollBudget);
      if (_disposed || !_running) return;
      _consecutiveFailures = 0;
      _maybeEmit(report.package);
    } on TimeoutException {
      _skippedCount++;
      debugPrint('[ForegroundWatcher] 单次轮询超出预算（$maxPollBudget），已跳过');
    } catch (error) {
      // 解析 / 模块不可用都属于预期降级；累计失败，绝不抛出。
      _registerFailure('parse_error');
      debugPrint('[ForegroundWatcher] 轮询失败（跳过）: $error');
    } finally {
      _pollerInFlight = false;
    }
  }

  /// 屏幕探测；任何时候失败 / 超预算一律返回 `true`（无法判定 → 假定亮屏，
  /// fail-open，避免静默停摆）。
  Future<bool> _probeScreenOnForBudget() =>
      _screenOnProbe().timeout(maxPollBudget, onTimeout: () => true);

  void _registerFailure(String reason) {
    _consecutiveFailures++;
    debugPrint('[ForegroundWatcher] 轮询失败（$reason）'
        '$_consecutiveFailures/$maxConsecutiveFailures');
    if (_consecutiveFailures >= maxConsecutiveFailures) {
      _running = false;
      _timer?.cancel();
      _timer = null;
      _status = ForegroundWatcherStatus.disabled;
      _disabledReason = ForegroundDisabledReason.shizukuUnavailable;
      debugPrint('[ForegroundWatcher] 连续失败达上限 → 监视器已禁用');
    }
  }

  /// 屏幕状态变化去重：仅当与上次探测不同时广播一条 [ScreenStateEvent]。
  ///
  /// 首个探测结果也会发（含至初始状态的迁移），使订阅方（协调器 → 自动应用
  /// 引擎）能同步到真实屏幕态；随后持续同态不再发噪音事件。
  void _maybeEmitScreen(bool screenOn) {
    if (_disposed || _screenController.isClosed) return;
    if (_lastScreenOn == screenOn) return;
    _lastScreenOn = screenOn;
    _screenController.add(
      ScreenStateEvent(
        screenOn: screenOn,
        tsMs: _clock().millisecondsSinceEpoch,
      ),
    );
  }

  void _maybeEmit(String? package) {
    if (_disposed || _controller.isClosed) return;
    if (!_hasEmitted) {
      if (package == null) return; // 尚无已知前台：不发噪音事件
    } else if (package == _lastPackage) {
      return; // 前台未变化：去重
    }
    final previous = _lastPackage;
    _lastPackage = package;
    _hasEmitted = true;
    _emitCount++;
    _controller.add(
      ForegroundEvent(
        package: package,
        previousPackage: previous,
        tsMs: _clock().millisecondsSinceEpoch,
      ),
    );
  }

  // ==================== 默认注入实现 ====================

  /// 默认 Shizuku 探测：`pingBinder` → `checkPermission`；异常一律不可用。
  static Future<bool> _defaultShizukuProbe() async {
    try {
      final binderUp = await _sharedShizukuApi.pingBinder() ?? false;
      if (!binderUp) return false;
      return await _sharedShizukuApi.checkPermission() ?? false;
    } catch (error) {
      debugPrint('[ForegroundWatcher] Shizuku 探测异常（按不可用处理）: $error');
      return false;
    }
  }

  /// 默认屏幕探测：经 [PrivilegedShell] 执行 `dumpsys power` 并解析。
  static ScreenOnProbe _shellScreenOnProbe(PrivilegedShell shell) => () async {
        final result = await shell.run(shell.buildCommand('dumpsys power'));
        if (!result.ok) return true; // 无法判定 → 假定亮屏（fail-open）
        return parseScreenOn(result.output);
      };

  /// 解析 `dumpsys power` 输出判断是否亮屏。
  ///
  /// 优先 `mWakefulness=Awake|Asleep|Dozing`，其次 `Display Power: state=ON|OFF`，
  /// 再次 `mScreenOn=true|false`；无法判定返回 `true`（假定亮屏）。
  static bool parseScreenOn(String output) {
    final wake = RegExp(r'mWakefulness\s*=\s*(\w+)').firstMatch(output);
    if (wake != null) {
      switch (wake.group(1)) {
        case 'Awake':
          return true;
        case 'Asleep':
        case 'Dozing':
          return false;
      }
    }
    final display =
        RegExp(r'Display Power:\s*state=(\w+)', caseSensitive: false)
            .firstMatch(output);
    if (display != null) {
      return display.group(1)!.toUpperCase() == 'ON';
    }
    final screen = RegExp(r'mScreenOn\s*=\s*(\w+)').firstMatch(output);
    if (screen != null) return screen.group(1) == 'true';
    return true;
  }
}
