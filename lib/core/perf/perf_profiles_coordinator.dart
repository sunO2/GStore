/// 每应用性能模式的**运行时协调器**（todo 30 装配）。
///
/// 把 23（[ForegroundWatcher] 前台监视器）、24（[PerfProfileAutoEngine] 自动应用
/// 引擎）与 20（共享 [PerfControlSession] 控制会话）**绑定为一个可
/// [start] / [stop] 的单元**，供 [PerfMonitorModule] 的模块生命周期驱动：
///
/// ```text
/// start()
///   → 拉取 perf.tunables（失败 → fail-closed，不启动、零命令）
///   → 探测控制能力（经注入的 [PrivilegedShell]，会话内缓存）
///   → 构造引擎（绑定同一 [PerfControlSession]）
///   → 构造监视器并订阅其 events → engine.onForegroundPackage(event.package)
///   → 订阅监视器 screenEvents → engine.onScreenState(event.screenOn)
///   → watcher.start()
///
/// stop()
///   → 取消 events / screenEvents 订阅
///   → watcher.dispose()（取消轮询定时器）
///   → engine.dispose()（取消去抖定时器）
///   → session.onModuleDisabled()（**有保证还原**：把会话登记的覆盖项写回原值）
/// ```
///
/// ## 不可协商的约束
/// * **OFF 零副作用**：本协调器**只在全局开关 ON 时**被构造；OFF 时根本不存在，
///   故无轮询、无 Shizuku / FFI。
/// * **fail-closed**：`perf.tunables` 加载失败 → 不启动、零命令。
/// * **单会话**：构造时注入的 [PerfControlSession] **必须**是全 App 共享单例
///   （`sharedPerfControlSession` / `perfControlSessionProvider`），与性能页的
///   手动控制（todo 28）共用，避免两个会话登记同一节点后互相踩踏。
/// * **绝不抛出**：[start] / [stop] 内部吞掉异常并降级（模块上下线不得闪退）。
///
/// ## 可测试性
/// store / 会话 / shell / tunables 加载器 / 能力探针 / 监视器工厂 / 开关
/// **全部可注入**；测试注入假 [CommandRunner] 构造的 [PrivilegedShell] +
/// 罐头 tunables + 假监视器，**无需 Shizuku / 真机 / 原生模块**。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/control_thermal.dart';
import 'package:gstore/core/perf/foreground_watcher.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/perf_control_session.dart';
import 'package:gstore/core/perf/perf_profile_auto_engine.dart';
import 'package:gstore/core/perf/perf_profile_store.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 前台监视器与自动应用引擎的运行时绑定单元。
class PerfProfilesCoordinator {
  PerfProfilesCoordinator({
    required PerfProfileStore store,
    required PerfControlSession session,
    required PrivilegedShell shell,
    required Future<TunablesReport> Function() tunablesLoader,
    required bool Function() isGloballyEnabled,
    PerfCapabilityProbe? probe,
    ForegroundWatcher Function()? watcherFactory,
    Duration debounce = PerfProfileAutoEngine.defaultDebounce,
  })  : _store = store,
        _session = session,
        _shell = shell,
        _tunablesLoader = tunablesLoader,
        _isGloballyEnabled = isGloballyEnabled,
        _probe = probe ?? PerfCapabilityProbe(shell: shell),
        _watcherFactory = watcherFactory ?? (() => ForegroundWatcher(shell: shell)),
        _debounce = debounce;

  final PerfProfileStore _store;
  final PerfControlSession _session;
  final PrivilegedShell _shell;
  final Future<TunablesReport> Function() _tunablesLoader;
  final bool Function() _isGloballyEnabled;
  final PerfCapabilityProbe _probe;
  final ForegroundWatcher Function() _watcherFactory;
  final Duration _debounce;

  ForegroundWatcher? _watcher;
  PerfProfileAutoEngine? _engine;
  StreamSubscription<ForegroundEvent>? _eventsSub;
  StreamSubscription<ScreenStateEvent>? _screenSub;
  PerfControlCapabilities? _capabilities;

  /// 是否已启动（监视器存在即视作运行中）。
  bool get isRunning => _watcher != null;

  /// 当前前台监视器；未启动为 `null`。
  ForegroundWatcher? get watcher => _watcher;

  /// 当前自动应用引擎；未启动为 `null`。
  PerfProfileAutoEngine? get engine => _engine;

  /// 最近一次能力探测结果；未启动为 `null`。
  PerfControlCapabilities? get capabilities => _capabilities;

  /// 启动监视器 + 自动应用引擎。
  ///
  /// 返回是否真正启动（`perf.tunables` 加载失败 → `false`，零命令）。幂等。
  Future<bool> start() async {
    if (_watcher != null) return true;

    final TunablesReport tunables;
    try {
      tunables = await _tunablesLoader();
    } catch (error) {
      debugPrint('[PerfProfilesCoordinator] perf.tunables 加载失败 → '
          '不启动（fail-closed，零命令）: $error');
      return false;
    }

    // 探测失败（异常）降级为 null → 引擎 fail-closed（capability_unknown）。
    PerfControlCapabilities? capabilities;
    try {
      capabilities = await _probe.probe(tunables);
    } catch (error) {
      debugPrint('[PerfProfilesCoordinator] 能力探测异常（降级为 unknown）: $error');
      capabilities = null;
    }
    _capabilities = capabilities;

    final engine = PerfProfileAutoEngine(
      store: _store,
      session: _session,
      cpuControl: CpuControl(
        shell: _shell,
        tunables: tunables,
        capabilities: capabilities,
      ),
      gpuControl: GpuControlAction(shell: _shell),
      cpusetControl: CpusetController(shell: _shell),
      thermalControl: ThermalToggleController(shell: _shell),
      tunables: tunables,
      capabilities: () => _capabilities,
      isGloballyEnabled: _isGloballyEnabled,
      debounce: _debounce,
    );

    final watcher = _watcherFactory();
    _eventsSub = watcher.events.listen((event) {
      // 事件处理绝不阻塞监视器轮询；引擎自身串行 + 绝不抛出。
      unawaited(engine.onForegroundPackage(event.package));
    });
    // 熄屏 → sleep / 亮屏 → resume（复用监视器既有屏幕探测，无 manifest 变更）。
    _screenSub = watcher.screenEvents.listen((event) {
      unawaited(engine.onScreenState(event.screenOn));
    });
    _watcher = watcher;
    _engine = engine;

    await watcher.start();
    debugPrint('[PerfProfilesCoordinator] 已启动（monitor + auto-apply）');
    return true;
  }

  /// 停止并释放：取消订阅、停监视器、dispose 引擎、**还原会话**（幂等）。绝不抛出。
  Future<void> stop() async {
    final watcher = _watcher;
    final engine = _engine;
    final sub = _eventsSub;
    final screenSub = _screenSub;
    _watcher = null;
    _engine = null;
    _eventsSub = null;
    _screenSub = null;
    _capabilities = null;

    try {
      if (sub != null) await sub.cancel();
      if (screenSub != null) await screenSub.cancel();
      await watcher?.dispose();
      engine?.dispose();
    } catch (error) {
      debugPrint('[PerfProfilesCoordinator] 停止监视器/引擎异常（已忽略）: $error');
    }

    // 模块下线 → 有保证还原（无待还原项时零命令）。
    try {
      await _session.onModuleDisabled();
    } catch (error) {
      debugPrint('[PerfProfilesCoordinator] 会话还原异常（已忽略）: $error');
    }
    debugPrint('[PerfProfilesCoordinator] 已停止');
  }
}
