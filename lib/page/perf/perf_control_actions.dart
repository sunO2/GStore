import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/perf/control_cpu.dart';
import 'package:gstore/core/perf/control_cpuset.dart';
import 'package:gstore/core/perf/control_gpu.dart';
import 'package:gstore/core/perf/control_refresh_rate.dart';
import 'package:gstore/core/perf/control_thermal.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/perf/perf_control_session.dart';
import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/perf/refresh_auto_engine.dart';
import 'package:gstore/core/perf/refresh_auto_store.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

// ==================== 控制 / 调优（Wave 6 · todo 28）====================
//
// 页面经可注入的 [PerfControlActions] 调用 todos 16-19 的动作层，并在动作成功
// 后登记到 [PerfControlSession]（todo 20）以支持还原。所有写入都经
// [AppDialogs.showConfirmSheet]（危险确认）；不可用类别（todo 15 探测）一律
// fail-closed 禁用并显示原因。Provider 就近定义在本文件，使 Section 可被完整
// widget 测试覆盖（镜像 `logic.dart` 的 `perfModuleProvider` 注入模式）。

/// 控制动作接口：包装 todos 16-19 的动作层（**可注入**；测试覆盖为假实现）。
abstract interface class PerfControlActions {
  /// CPU 簇策略（governor / 每簇 min·max 频率）。
  Future<CpuPolicyResult> applyCpu({
    required String cluster,
    String? governor,
    double? minFreqMhz,
    double? maxFreqMhz,
  });

  /// GPU 策略（governor / 频率 / 功耗档位）。
  Future<GpuPolicyResult> applyGpu(GpuPolicy policy);

  /// cpuset / affinity 归属。
  Future<CpusetResult> applyCpuset({
    required String pkgOrPid,
    required String cpuset,
  });

  /// 热控开关（危险方向需 `confirmed:true`）。
  Future<ThermalToggleResult> setThermal(
    bool enabled, {
    required bool confirmed,
  });
}

/// 生产实现：组合 todos 16-19 的动作 + 成功即登记到 [PerfControlSession]。
class DefaultPerfControlActions implements PerfControlActions {
  DefaultPerfControlActions({
    required CpuControl cpu,
    required GpuControlAction gpu,
    required CpusetController cpuset,
    required ThermalToggleController thermal,
    required PerfControlSession session,
    required TunablesReport tunables,
    PerfControlCapabilities? capabilities,
  })  : _cpu = cpu,
        _gpu = gpu,
        _cpuset = cpuset,
        _thermal = thermal,
        _session = session,
        _tunables = tunables,
        _capabilities = capabilities;

  final CpuControl _cpu;
  final GpuControlAction _gpu;
  final CpusetController _cpuset;
  final ThermalToggleController _thermal;
  final PerfControlSession _session;
  final TunablesReport _tunables;
  final PerfControlCapabilities? _capabilities;

  @override
  Future<CpuPolicyResult> applyCpu({
    required String cluster,
    String? governor,
    double? minFreqMhz,
    double? maxFreqMhz,
  }) async {
    final result = await _cpu.applyCpuPolicy(
      cluster: cluster,
      governor: governor,
      minFreqMhz: minFreqMhz,
      maxFreqMhz: maxFreqMhz,
    );
    if (result.ok) await _session.recordCpu(result);
    return result;
  }

  @override
  Future<GpuPolicyResult> applyGpu(GpuPolicy policy) async {
    final result = await _gpu.applyGpuPolicy(policy, tunables: _tunables);
    if (result.applied) await _session.recordGpu(result);
    return result;
  }

  @override
  Future<CpusetResult> applyCpuset({
    required String pkgOrPid,
    required String cpuset,
  }) async {
    final result = await _cpuset.applyCpuset(pkgOrPid: pkgOrPid, cpuset: cpuset);
    if (result.ok) await _session.recordCpuset(result);
    return result;
  }

  @override
  Future<ThermalToggleResult> setThermal(
    bool enabled, {
    required bool confirmed,
  }) async {
    final capabilities = _capabilities;
    if (capabilities == null) {
      return ThermalToggleResult(
        ok: false,
        requestedEnabled: enabled,
        error: ThermalToggleError.unavailable,
        detail: '控制能力未探测（fail-closed）→ 零写入',
      );
    }
    final result = await _thermal.setThermalEnabled(
      enabled,
      confirmed: confirmed,
      tunables: _tunables,
      capabilities: capabilities,
    );
    if (result.ok) await _session.recordThermal(result);
    return result;
  }
}

/// 动作工厂：由当前 `perf.tunables` + 能力图构造 [PerfControlActions]。
typedef PerfControlActionsFactory = PerfControlActions Function(
  TunablesReport tunables,
  PerfControlCapabilities? capabilities,
);

/// 生产动作工厂（测试覆盖为返回假动作的工厂）。
final perfControlActionsFactoryProvider =
    Provider<PerfControlActionsFactory>((ref) {
  return (tunables, capabilities) => DefaultPerfControlActions(
        cpu: CpuControl(
          shell: PrivilegedShell(),
          tunables: tunables,
          capabilities: capabilities,
        ),
        gpu: GpuControlAction(shell: PrivilegedShell()),
        cpuset: CpusetController(),
        thermal: ThermalToggleController(shell: PrivilegedShell()),
        session: ref.read(perfControlSessionProvider),
        tunables: tunables,
        capabilities: capabilities,
      );
});

/// 控制能力加载器（生产驱动 todo 15 探测；测试覆盖为罐头能力图 / null）。
typedef PerfCapabilitiesLoader = Future<PerfControlCapabilities?> Function({
  bool refresh,
});

/// 生产能力加载器：经 [perfControlCapabilitiesProvider] 驱动探测（失败降级 null）。
final perfControlCapabilitiesLoaderProvider =
    Provider<PerfCapabilitiesLoader>((ref) {
  return ({bool refresh = false}) =>
      ref.read(perfControlCapabilitiesProvider.notifier).probe(refresh: refresh);
});

/// 控制用 `perf.tunables` 加载器（测试覆盖为罐头报告）。
final perfControlTunablesLoaderProvider = Provider<PerfTunablesLoader>(
  (ref) => ref.watch(perfTunablesLoaderProvider),
);

// ==================== 屏幕刷新率（WS-B · scene8-port-fps-refresh）====================
//
// 「屏幕刷新率」组独立于 CPU/GPU/cpuset/thermal 的 [PerfControlActions]：它经
// [PrivilegedShell] 走 `settings get/put system min_refresh_rate|peak_refresh_rate`，
// 不依赖 `perf.tunables` / 能力图。Provider 就近定义，使控制组可被完整 widget
// 测试覆盖（覆盖为罐头 [RefreshRateController] / 假 shell）。

/// 屏幕刷新率控制器（生产经 Shizuku；测试覆盖为罐头 controller / 假 shell）。
final perfRefreshRateControllerProvider = Provider<RefreshRateController>(
  (ref) => RefreshRateController(shell: PrivilegedShell()),
);

// ==================== 每应用自动刷新率（WS-D · scene8-followups）====================
//
// 「按前台自动切换」的配置存储 + 引擎。存储经 SharedPreferences（生产）/ 内存
// （测试）；引擎生命周期由控制组拥有（enabled → 启动，禁用 / dispose → 停止）。
// Provider 就近定义，使控制组可被完整 widget 测试覆盖（覆盖为假 store / 假 driver）。

/// 自动刷新率配置存储（生产 SharedPreferences；测试覆盖为内存实现）。
final perfRefreshAutoStoreProvider = Provider<RefreshAutoStore>(
  (ref) => const SharedPrefsRefreshAutoStore(),
);

/// 自动刷新率引擎工厂（生产构造真实 [RefreshAutoEngine]；测试覆盖为假 driver）。
///
/// 采用**工厂**而非单例：控制组自持引擎实例并在其 dispose 时释放，避免共享实例
/// 被某一 tab 生命周期误释放；测试也可注入不启动定时器的假 driver。
typedef RefreshAutoDriverFactory = RefreshAutoDriver Function({
  required RefreshRateController controller,
  required RefreshAutoStore store,
});

/// 生产引擎工厂（默认经 [rustShizukuRunner] 探测前台）。
final perfRefreshAutoDriverFactoryProvider =
    Provider<RefreshAutoDriverFactory>((ref) {
  return ({
    required RefreshRateController controller,
    required RefreshAutoStore store,
  }) =>
      RefreshAutoEngine(controller: controller, store: store);
});
