/// 每应用自动刷新率**引擎**（WS-D）。
///
/// 轮询前台包（经可注入 [CommandRunner]，默认 [rustShizukuRunner]：
/// `dumpsys activity activities` 的 `topResumedActivity` / `dumpsys window` 的
/// `mCurrentFocus`），当前台**变化**时按 [RefreshAutoStore] 的配置收敛：
///
/// ```text
/// 有配置且 enabled
///   → 该前台包有配置且与「上次已应用」不同 → controller.apply(min, peak)
///   → 该前台包无配置（含桌面 / launcher）→ 若配置了 defaultMin/defaultPeak
///       且与上次不同 → controller.apply(defaultMin, defaultPeak)
///       否则保持现状（不写）
/// disabled → 不写任何值
/// ```
///
/// ## 不可协商
/// * **只经 [RefreshRateController]**（`settings`），**绝不写 root sysfs**。
/// * **幂等**：同一前台包（同一目标值）**不重复写**；引擎去重键在成功应用后才更新。
/// * **去抖**：单拍单飞（[pollOnce] 未完成时重叠拍直接跳过）；轮询间隔有下限。
/// * **失败静默**：轮询 / 解析 / 应用失败一律 `debugPrint` 并保持现状（绝不抛）。
/// * **dispose 停止**：释放后取消定时器、不再轮询。
///
/// ## 可测试性
/// [RefreshRateController] / [CommandRunner] / 时钟 / 间隔**全部可注入**；测试注入
/// 罐头 `dumpsys` 文本 + 假 shell 构造的 controller，**无需 Shizuku / 真机**。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier, debugPrint;

import 'package:gstore/core/perf/control_refresh_rate.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/perf/refresh_auto_store.dart';
import 'package:gstore/core/shell/rust_shizuku_runner.dart';

/// 时钟（Unix 时间源）；测试注入以便时间可复现。
typedef RefreshAutoClock = DateTime Function();

/// 引擎对 UI 暴露的生命周期驱动接口。
///
/// UI 只依赖此接口（[start] / [stop] / [dispose] + 可观测前台包），测试可注入
/// 假实现，避免真实 [Timer.periodic] 遗留 pending timer。
abstract interface class RefreshAutoDriver {
  /// 启动轮询（幂等：运行中重复调用无操作）。
  void start();

  /// 停止轮询（保留可再次 [start]）。
  void stop();

  /// 释放（取消定时器，关闭通知器）；释放后不可再启动。幂等。
  void dispose();

  /// 是否正在轮询。
  bool get isRunning;

  /// 最近一次判定到的前台包名（`null` = 未判定 / 已离开）。
  ValueListenable<String?> get foregroundPackage;
}

/// 每应用自动刷新率引擎。
///
/// 生产：`RefreshAutoEngine(controller: RefreshRateController(...),
/// store: SharedPrefsRefreshAutoStore())`（默认经 [rustShizukuRunner] 探测前台）。
/// 测试：注入假 [CommandRunner] + 假 shell 构造的 [RefreshRateController]。
class RefreshAutoEngine implements RefreshAutoDriver {
  RefreshAutoEngine({
    required RefreshRateController controller,
    required RefreshAutoStore store,
    CommandRunner? runner,
    Duration interval = defaultInterval,
    RefreshAutoClock? clock,
  })  : _controller = controller,
        _store = store,
        _runner = runner ?? rustShizukuRunner,
        _clock = clock ?? DateTime.now,
        interval = clampInterval(interval);

  /// 默认轮询间隔（2s）。
  static const Duration defaultInterval = Duration(seconds: 2);

  /// 轮询绝对下限（防止注入过小间隔导致忙轮询）。
  static const Duration minPollInterval = Duration(milliseconds: 200);

  /// 前台探测主命令（`dumpsys activity activities`）。
  static const String foregroundCommand = 'dumpsys activity activities';

  /// 前台探测回退命令（`dumpsys window`）。
  static const String focusCommand = 'dumpsys window';

  /// 前台识别行首键名（`dumpsys activity activities` / `dumpsys window`）。
  static const List<String> focusKeys = <String>[
    'topResumedActivity',
    'mCurrentFocus',
    'mFocusedApp',
    'mResumedActivity',
    'ResumedActivity',
    'mFocusedWindow',
  ];

  /// `<pkg>/<activity>` 组件正则（pkg 至少含一个点）。
  static final RegExp componentRe = RegExp(
    r'([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)/[\S]+',
  );

  final RefreshRateController _controller;
  final RefreshAutoStore _store;
  final CommandRunner _runner;
  final RefreshAutoClock _clock;

  /// 有效轮询间隔（已按 [clampInterval] 钳制）。
  final Duration interval;

  final ValueNotifier<String?> _foregroundNotifier = ValueNotifier<String?>(null);
  Timer? _timer;
  bool _running = false;
  bool _inFlight = false;
  bool _disposed = false;

  /// 最近一次**成功应用**的去重键（`pkg:...` / `default:...`）。
  String? _appliedKey;

  /// 最近一次成功应用到配置的包（`default` / 未应用 → `null`）。
  String? _appliedPackage;

  /// 最近一次成功应用的 [RefreshRateResult.status]；未应用 → `null`。
  String? _lastStatus;

  // ==================== 可观测状态 ====================

  @override
  bool get isRunning => _running && !_disposed;

  @override
  ValueListenable<String?> get foregroundPackage => _foregroundNotifier;

  /// 最近一次成功应用到配置的包；默认恢复 / 未应用 → `null`。
  String? get appliedPackage => _appliedPackage;

  /// 最近一次成功应用的状态码；未应用 → `null`。
  String? get lastStatus => _lastStatus;

  /// 是否已释放。
  bool get isDisposed => _disposed;

  /// 有效间隔钳制：不得快于 [minPollInterval]。
  static Duration clampInterval(Duration interval) =>
      interval < minPollInterval ? minPollInterval : interval;

  // ==================== 生命周期 ====================

  @override
  void start() {
    if (_disposed || _running) return;
    _running = true;
    // 重新起步：按当前前台重新判定一次（不沿用上一轮的去重键）。
    _appliedKey = null;
    _timer = Timer.periodic(interval, (_) => unawaited(pollOnce()));
    unawaited(pollOnce());
  }

  @override
  void stop() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _foregroundNotifier.dispose();
  }

  // ==================== 轮询 ====================

  /// 执行一次轮询并收敛（公开以便测试 / 手动触发，绕开定时器）。
  ///
  /// 单飞守卫：上一次未完成时本次直接跳过（同拍去抖）。**绝不抛出**。
  Future<void> pollOnce() async {
    if (_disposed || _inFlight) return;
    _inFlight = true;
    try {
      final config = await _store.load();
      if (_disposed) return;

      if (!config.enabled) {
        // 关闭状态：不写任何值；清去重键，使再次启用时按当前前台重新应用。
        _appliedKey = null;
        _appliedPackage = null;
        _lastStatus = null;
        return;
      }

      final pkg = await _resolveForeground();
      if (_disposed) return;
      _foregroundNotifier.value = pkg;
      if (pkg == null) return; // 无法判定 → 保持现状（不写）

      final entry = config.entries[pkg];
      if (entry != null) {
        await _applyKey(
          key: 'pkg:${entry.package}:${entry.min}:${entry.peak}',
          min: entry.min,
          peak: entry.peak,
          appliedPackage: entry.package,
        );
        return;
      }

      // 无配置（含桌面 / launcher）→ 恢复默认（未设置则保持）。
      final defaultMin = config.defaultMin;
      final defaultPeak = config.defaultPeak;
      if (defaultMin == null || defaultPeak == null) return;
      await _applyKey(
        key: 'default:$defaultMin:$defaultPeak',
        min: defaultMin,
        peak: defaultPeak,
        appliedPackage: null,
      );
    } catch (error) {
      // 解析 / 存储 / 应用失败都属于预期降级；静默保持现状，绝不抛。
      debugPrint('[RefreshAutoEngine] 轮询失败（静默）: $error');
    } finally {
      _inFlight = false;
    }
  }

  /// 幂等应用：去重键与上次相同则零写入；成功后才更新去重键。
  Future<void> _applyKey({
    required String key,
    required int min,
    required int peak,
    required String? appliedPackage,
  }) async {
    if (_appliedKey == key) return;
    final result = await _controller.apply(min: min, peak: peak);
    if (_disposed) return;
    if (result.ok) {
      _appliedKey = key;
      _appliedPackage = appliedPackage;
      _lastStatus = result.status;
    } else {
      _lastStatus = result.status;
      debugPrint('[RefreshAutoEngine] 应用 $min/$peak 未成功（'
          '${result.status}）：${result.message ?? ''}');
    }
  }

  /// 依次尝试 `dumpsys activity activities` → `dumpsys window` 解析前台包名。
  Future<String?> _resolveForeground() async {
    for (final command in const <String>[foregroundCommand, focusCommand]) {
      final String? output;
      try {
        output = await _runner(command);
      } catch (error) {
        debugPrint('[RefreshAutoEngine] 前台探测失败（$command）: $error');
        continue;
      }
      final pkg = parseForegroundPackage(output);
      if (pkg != null) return pkg;
    }
    return null;
  }

  /// 从 `dumpsys` 文本解析前台包名（纯函数，**绝不抛**）。
  ///
  /// 识别 [focusKeys] 行中的 `<pkg>/<activity>` 组件；无匹配 / `null` → `null`。
  static String? parseForegroundPackage(String? output) {
    if (output == null) return null;
    for (final line in output.split('\n')) {
      if (!focusKeys.any(line.contains)) continue;
      final match = componentRe.firstMatch(line);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// 时间源（当前仅用于日志；保留以便后续扩展超时判定）。
  DateTime now() => _clock();
}
