/// 性能监控页逻辑（Riverpod Notifier + 可注入 Provider）。
///
/// 页面消费两类**互不耦合**的数据源：
/// * 渲染帧时序（纯 Dart）—— [FrameMonitor]，恒可用，不依赖原生模块；
/// * 原生 `perf` 模块（CPU/内存/电池/温度/GPU/网络/进程）—— [PerfModule]，
///   可能尚未随包分发（[PerfModuleUnavailableException] 为**预期状态**）。
///
/// 依赖经 Provider 暴露（[perfModuleProvider] / [perfFrameMonitorProvider] /
/// [perfAvailabilityStreamProvider]），使组件测试可注入假网关与假帧监控，
/// **无需原生模块**。逻辑层只做编排与降级，绝不解析采集数据（采集在 Rust）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/perf/battery_source.dart';
import 'package:gstore/core/perf/cpu_stat_source.dart';
import 'package:gstore/core/perf/device_state.dart';
import 'package:gstore/core/perf/fps_session_recorder.dart';
import 'package:gstore/core/perf/fps_session_store.dart';
import 'package:gstore/core/perf/frame_metrics_source.dart';
import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/perf_auto_export_service.dart';
import 'package:gstore/core/perf/perf_auto_export_settings.dart';
import 'package:gstore/core/perf/perf_history_store.dart';
import 'package:gstore/core/perf/perf_report.dart';
import 'package:gstore/core/perf/perf_report_store.dart';
import 'package:gstore/core/perf/perf_target_store.dart';
import 'package:gstore/core/perf/system_fps_service.dart' hide CommandRunner;
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

import 'state.dart';

// ==================== 可注入 Provider ====================

/// `perf` 模块门面（生产为单例；测试注入假网关构造的实例）。
final perfModuleProvider = Provider<PerfModule>((ref) => PerfModule.instance);

/// 帧时序监控（生产为单例；测试注入自定义累加器构造的实例）。
final perfFrameMonitorProvider =
    Provider<FrameMonitor>((ref) => FrameMonitor.instance);

/// `perf` 模块自举阶段流（测试可覆盖为受控 [Stream]）。
final perfAvailabilityStreamProvider = Provider<Stream<PerfAvailability>>(
  (ref) => ref.watch(perfModuleProvider).watchAvailability(),
);

/// 跨会话滚动历史存储（测试覆盖为临时目录实现）。
final perfHistoryStoreProvider =
    Provider<PerfHistoryStore>((ref) => PerfHistoryStore());

/// 报告 / 基线存储（测试覆盖为临时目录 + 内存基线）。
final perfReportStoreProvider =
    Provider<PerfReportStore>((ref) => PerfReportStore());

/// 最近第三方目标存储（测试覆盖为内存实现）。
final perfTargetStoreProvider =
    Provider<PerfTargetStore>((ref) => const SharedPrefsPerfTargetStore());

/// `/proc/stat` 特权读取器（Android 8+ 普通应用被 SELinux 拒绝，经 Shizuku 兜底）。
///
/// 仅在 Rust 报告的 `perCoreUsage` 为空时使用；测试可覆盖为假 [CommandRunner]。
final perfCpuStatReaderProvider =
    Provider<CpuStatReader>((ref) => CpuStatReader());

/// 系统帧率服务（生产 `SystemFpsService()`；测试注入罐头 [CommandRunner]）。
///
/// 屏幕交付帧率经 SurfaceFlinger `--timestats` 采样，故需要 Shizuku（shell
/// uid 2000）；无 Shizuku 时服务降级为 `null`（UI 显「需 Shizuku / 无数据」）。
final perfSystemFpsServiceProvider =
    Provider<SystemFpsService>((ref) => SystemFpsService());

/// 第三方应用性能服务（生产 `ThirdPartyPerfService()`；测试注入假服务）。
///
/// FPS 卡「第三方」口径**复用**本服务（`watch`），不新建数据通路。
final perfThirdPartyServiceProvider =
    Provider<ThirdPartyPerfService>((ref) => ThirdPartyPerfService());

/// 自动导出设置持久化（测试覆盖为内存实现）。
final perfAutoExportSettingsStoreProvider =
    Provider<PerfAutoExportSettingsStore>(
  (ref) => const SharedPrefsPerfAutoExportSettingsStore(),
);

/// 自动导出设置（默认值起步，异步从磁盘恢复；`save` 立即更新 + 持久化）。
final perfAutoExportSettingsProvider =
    NotifierProvider<PerfAutoExportSettingsNotifier, PerfAutoExportSettings>(
  PerfAutoExportSettingsNotifier.new,
);

/// 自动导出服务（生产接线；随 ProviderScope 释放取消定时器）。
///
/// 报告内容复用 [buildPerfReportJson] / [buildPerfReportCsv]（与手动导出同源）。
/// 服务的 start/stop 由本 provider 统一驱动（`ref.listen` 监听监控态与设置），
/// 因此即使报告页未挂载，只要概览页开启「实时刷新 / 后台采样」且设置启用，
/// 服务也会运行——不再依赖任何页面挂载。
final perfAutoExportServiceProvider = Provider<PerfAutoExportService>((ref) {
  final service = PerfAutoExportService(
    store: ref.watch(perfReportStoreProvider),
    settings: () => ref.read(perfAutoExportSettingsProvider),
    buildContent: (timestamp, format) async {
      final state = ref.read(perfMonitorProvider);
      final target = await ref.read(perfTargetStoreProvider).load();
      final stats = state.effectiveFrameStats;
      if (format == PerfReportFormat.json) {
        return const JsonEncoder.withIndent('  ').convert(
          buildPerfReportJson(
            timestamp: timestamp,
            cpu: state.cpu,
            memory: state.memory,
            battery: state.battery,
            thermal: state.thermal,
            gpu: state.gpu,
            network: state.network,
            frameStats: stats,
            targetLabel: target?.label,
          ),
        );
      }
      return buildPerfReportCsv(
        timestamp: timestamp,
        cpu: state.cpu,
        memory: state.memory,
        battery: state.battery,
        thermal: state.thermal,
        gpu: state.gpu,
        network: state.network,
        frameStats: stats,
        targetLabel: target?.label,
      );
    },
  );

  // 服务生命周期由 provider 驱动：`shouldRun = (live || sampling) && enabled`，
  // 签名（enabled|interval|format|maxKeep）变化时重启定时器以应用新间隔。
  bool? appliedRunning;
  String? appliedSignature;

  void sync() {
    final perfState = ref.read(perfMonitorProvider);
    final settings = ref.read(perfAutoExportSettingsProvider);
    final shouldRun =
        (perfState.live || perfState.sampling) && settings.enabled;
    final signature = '${settings.enabled}|${settings.intervalMinutes}'
        '|${settings.format.value}|${settings.maxKeep}';
    if (appliedRunning == shouldRun && appliedSignature == signature) return;
    final restart = appliedSignature != null && appliedSignature != signature;
    appliedRunning = shouldRun;
    appliedSignature = signature;
    if (shouldRun) {
      if (restart) service.stop();
      service.start();
    } else {
      service.stop();
    }
  }

  // 概览页切换「实时刷新 / 后台采样」或设置变更时重新评估运行态。
  ref.listen(perfMonitorProvider, (_, __) => sync());
  ref.listen(perfAutoExportSettingsProvider, (_, __) => sync());
  // 构造时先评估一次（例如设置已持久化为启用）。
  sync();

  ref.onDispose(service.dispose);
  return service;
});

/// FPS 会话录制持久化（生产 `SharedPreferences`；测试覆盖为内存实现）。
final fpsSessionStoreProvider = Provider<FpsSessionStore>(
  (ref) => const SharedPrefsFpsSessionStore(),
);

/// FPS 会话录制器（生产接线系统帧率 + 环境采样；随 ProviderScope 释放取消定时器）。
///
/// * `sampler` 复用 [perfSystemFpsServiceProvider]（**不新建数据通路**）：每拍取
///   `SystemFpsSample.fps`；失败 / 无数据返回 `null`（录制器跳过该拍）。
/// * `environmentSampler`（todo 15）复用 [perfModuleProvider] 的
///   `battery()` / `thermal()` 取温度 / 电压 / 电流；`viewSize` 取主视图逻辑像素
///   （[MediaQuery.size] 等价，见 `_logicalViewSize`）；`mode` 待生效模式运行时
///   接入前为空串（缺省安全值）。模块不可用 / 任一采样失败均软失败（跳过该拍）。
final fpsSessionRecorderProvider = Provider<FpsSessionRecorder>((ref) {
  final recorder = FpsSessionRecorder(
    store: ref.watch(fpsSessionStoreProvider),
    sampler: () async {
      try {
        final sample = await ref.read(perfSystemFpsServiceProvider).sample();
        return sample?.fps;
      } catch (error) {
        debugPrint('[PerfMonitor] FPS 会话采样失败（跳过）: $error');
        return null;
      }
    },
    environmentSampler: () async {
      double? temperatureC;
      double? voltageV;
      double? currentMa;
      try {
        // 多源合并（sysfs → BatteryManager → dumpsys）：仅 sysfs 常缺电流 / 电压。
        final battery = await _readMergedBattery(ref.read(perfModuleProvider));
        if (battery.present) {
          temperatureC = battery.temperatureC;
          voltageV = battery.voltageV;
          currentMa = battery.currentMa;
        }
      } catch (error) {
        debugPrint('[PerfMonitor] FPS 会话电池采样失败（跳过）: $error');
      }
      // 电池无温度时回退到热区最高温（更接近「整机温度」语义）。
      if (temperatureC == null) {
        try {
          temperatureC =
              (await ref.read(perfModuleProvider).thermal()).maxTempC;
        } catch (error) {
          debugPrint('[PerfMonitor] FPS 会话温度采样失败（跳过）: $error');
        }
      }
      return FpsEnvironmentSample(
        temperatureC: temperatureC,
        voltageV: voltageV,
        currentMa: currentMa,
        viewSize: _logicalViewSize(),
        // 生效模式标签（自由字符串）：模式运行时接入前保持空串（缺省安全值）。
        mode: '',
      );
    },
  );
  ref.onDispose(recorder.dispose);
  return recorder;
});

/// 经多源合并读取电池报告：sysfs（[PerfModule.battery]）→ Android `BatteryManager`
/// → `dumpsys battery`（[readBatteryReading]），再把合并后的 [BatteryReading]
/// 转回 [BatteryReport]（保留原始 charge-full / cycle 字段）。
///
/// * [PerfModule.battery] 抛 [PerfModuleUnavailableException] 时**向上冒泡**
///   （保持既有整页降级语义）；
/// * **总是尝试合并**（不再因 sysfs `present=false` 短路）：部分设备 Rust sysfs
///   报 `present=false`，但 BatteryManager 仍能给出真实读数；
/// * 合并走**廉价**路径（`includeDumpsys: false`），热路径不执行 shell；
/// * 合并流程抛异常 / 返回 `null` 时**回退**原始 [PerfModule.battery] 结果；
/// * 绝不因合并本身失败而丢失数据。
Future<BatteryReport> _readMergedBattery(
  PerfModule module, {
  BatteryManagerChannel? channel,
}) async {
  final raw = await module.battery();
  try {
    final reading = await readBatteryReading(
      includeDumpsys: false,
      sysfsReader: () async => batteryReadingFromSysfs(raw),
      channel: channel,
    );
    if (reading == null) return raw;
    return _batteryReportFromReading(reading, fallback: raw);
  } catch (error) {
    debugPrint('[PerfMonitor] 合并电池读数失败（回退原始）: $error');
    return raw;
  }
}

/// 测试 seam：与生产相同的合并流程，可注入 [BatteryManagerChannel]。
@visibleForTesting
Future<BatteryReport> readMergedBatteryForTest(
  PerfModule module, {
  BatteryManagerChannel? channel,
}) =>
    _readMergedBattery(module, channel: channel);

/// 合并读数 → [BatteryReport]。缺失字段沿用 [fallback] 既有值（尤其
/// `chargeFullUah` / `chargeFullDesignUah` / `cycleCount` 仅 sysfs 直读可得）。
BatteryReport _batteryReportFromReading(
  BatteryReading reading, {
  required BatteryReport fallback,
}) =>
    BatteryReport(
      present: reading.present,
      basePath: reading.basePath,
      capacityPercent: reading.capacityPercent,
      voltageV: reading.voltageV,
      currentMa: reading.currentMa,
      temperatureC: reading.temperatureC,
      status: reading.statusLabel,
      health: reading.health,
      technology: reading.technology,
      chargeFullUah: fallback.chargeFullUah,
      chargeFullDesignUah: fallback.chargeFullDesignUah,
      cycleCount: fallback.cycleCount,
    );

/// 主视图逻辑像素尺寸串（`MediaQuery.size` 等价，如 `'1080.0x2340.0'`）。
///
/// 录制器为纯 Dart 无法读取 `MediaQuery`，故在接线层经
/// [WidgetsBinding.instance].platformDispatcher 主视图按
/// `物理尺寸 / devicePixelRatio` 换算（逻辑像素即 `MediaQuery.size` 口径）。
/// 无视图 / 非法比例 / 非法尺寸时返回 `null`（录制器降级为空串），绝不抛出。
String? _logicalViewSize() {
  try {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return null;
    final view = views.first;
    final ratio = view.devicePixelRatio;
    if (!ratio.isFinite || ratio <= 0) return null;
    final size = view.physicalSize / ratio;
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      return null;
    }
    return '${size.width}x${size.height}';
  } catch (error) {
    debugPrint('[PerfMonitor] 读取视图尺寸失败（跳过）: $error');
    return null;
  }
}

/// 自动导出设置的加载 / 保存控制器。
class PerfAutoExportSettingsNotifier extends Notifier<PerfAutoExportSettings> {
  bool _disposed = false;

  @override
  PerfAutoExportSettings build() {
    ref.onDispose(() => _disposed = true);
    Future<void>.microtask(_restore);
    return PerfAutoExportSettings.defaults;
  }

  Future<void> _restore() async {
    final store = ref.read(perfAutoExportSettingsStoreProvider);
    final loaded = await store.load();
    if (_disposed || loaded == null) return;
    state = loaded;
  }

  /// 更新并持久化设置（内存态即时生效；持久化失败静默）。
  Future<void> save(PerfAutoExportSettings settings) async {
    if (_disposed) return;
    state = settings;
    await ref.read(perfAutoExportSettingsStoreProvider).save(settings);
  }
}

/// 批量设备状态桥（生产 Rust JNI；测试可覆盖为罐头读取）。
final perfDeviceStateBridgeProvider = Provider<RustJniDeviceStateBridge>(
  (ref) => RustJniDeviceStateBridge(),
);

/// 本应用帧指标桥（生产 Rust JNI；测试可覆盖为罐头读取）。
final perfFrameMetricsBridgeProvider = Provider<RustJniFrameMetricsBridge>(
  (ref) => RustJniFrameMetricsBridge(),
);

/// 性能监控页 Provider。
final perfMonitorProvider =
    NotifierProvider<PerfMonitorNotifier, PerfPageState>(
  PerfMonitorNotifier.new,
);

// ==================== Notifier ====================

/// 性能监控页控制器。
///
/// 职责：
/// * 订阅 [FrameMonitor.valueListenable] → 帧统计；
/// * 订阅 [perfAvailabilityStreamProvider] → 模块阶段，ready 时加载数据；
/// * [refresh] 并行拉取各节报告（任一节失败降级为友好错误，绝不崩溃）；
/// * [retryInstall] 显式触发安装 / 重试（经模块 `ping` 点火），绝不在开页时自动安装；
/// * [toggleSampling] 显式开关后台采样（默认 OFF）；[toggleFrameMonitor] 开关帧采集。
class PerfMonitorNotifier extends Notifier<PerfPageState> {
  bool _disposed = false;
  bool _refreshing = false;

  StreamSubscription<PerfAvailability>? _availabilitySub;
  StreamSubscription<PerfSample>? _sampleSub;
  void Function()? _frameListener;

  /// 实时刷新定时器（2s；仅 [PerfPageState.live] 或采样开启时运行）。
  Timer? _ticker;

  /// 系统帧率轮询定时器（2s；仅 `frameMonitorRunning || live` 时运行）。
  Timer? _systemFpsTimer;

  /// 静默拍复用的最近一次电池合并结果（避免每拍都走 sysfs + 平台通道）。
  BatteryReport? _cachedBattery;
  DateTime? _cachedBatteryAt;

  /// 静默拍电池缓存 TTL（2 个实时拍，约 4s）：过期才重新合并。
  static const Duration _silentBatteryTtl = Duration(seconds: 4);

  /// 第三方目标帧率订阅（复用 `ThirdPartyPerfService.watch`）。
  StreamSubscription<ThirdPartySample>? _thirdPartySub;

  /// 当前正在订阅的第三方目标包名（避免同一目标重复订阅）。
  String? _watchingPackage;

  /// build 时捕获的帧监控引用（dispose 阶段 `ref` 已失效，不可再 read）。
  FrameMonitor? _monitorRef;

  /// build 时捕获的系统帧率服务（dispose 阶段 `ref` 已失效，不可再 read）。
  SystemFpsService? _systemFpsServiceRef;

  /// build 时捕获的第三方服务（dispose 阶段 `ref` 已失效）。
  ThirdPartyPerfService? _thirdPartyServiceRef;

  /// build 时捕获的历史存储（dispose 阶段 `ref` 已失效）。
  PerfHistoryStore? _historyStore;

  /// build 时捕获的批量设备状态桥（best-effort；失败不影响刷新）。
  RustJniDeviceStateBridge? _deviceStateBridge;

  /// build 时捕获的本应用帧指标桥（best-effort；失败不影响刷新）。
  RustJniFrameMetricsBridge? _frameMetricsBridge;

  /// build 时捕获的 `/proc/stat` 特权读取器（Android 8+ 逐核占用兜底）。
  CpuStatReader? _cpuStatReader;

  /// 最近一次特权 `/proc/stat` 采样（用于把逐核占用回填到后续模块报告）。
  CpuUsageSample? _lastCoreUsage;

  /// 最近一次特权采样的时间（超过 [CpuStatReader.maxGap] 不再回填，避免陈旧值）。
  DateTime? _lastCoreUsageAt;

  /// CPU 轮询进行中（避免页面定时器重入）。
  bool _cpuPollingBusy = false;

  /// 上次落盘时间（Unix ms），节流历史写入。
  int _lastHistorySaveMs = 0;

  /// 从磁盘恢复的第三方历史（本页不主动更新，仅随历史回填/回写）。
  List<double> _thirdPartyCpu = const <double>[];
  List<double> _thirdPartyMem = const <double>[];
  List<double> _thirdPartyJank = const <double>[];

  PerfModule get _module => ref.read(perfModuleProvider);
  FrameMonitor get _monitor =>
      _monitorRef ?? ref.read(perfFrameMonitorProvider);
  SystemFpsService get _systemFps =>
      _systemFpsServiceRef ?? ref.read(perfSystemFpsServiceProvider);
  ThirdPartyPerfService get _thirdParty =>
      _thirdPartyServiceRef ?? ref.read(perfThirdPartyServiceProvider);

  @override
  PerfPageState build() {
    ref.onDispose(_dispose);

    // 帧统计：监听节流发布的 ValueListenable。
    final monitor = _monitor;
    _monitorRef = monitor;
    // 捕获服务引用（dispose 阶段 ref 已失效，不可再 read）。
    _systemFpsServiceRef = ref.read(perfSystemFpsServiceProvider);
    _thirdPartyServiceRef = ref.read(perfThirdPartyServiceProvider);
    void onFrames() {
      if (_disposed) return;
      final stats = monitor.latestStats;
      var next = state.copyWith(frameStats: stats);
      // FPS 历史由帧流驱动：与原生模块无关，恒可累积。
      if (stats.sampledFrames > 0) {
        next = next.copyWith(
          fpsHistory: _pushHistory(next.fpsHistory, stats.fps),
        );
      }
      state = next;
      _maybeSaveHistory();
    }

    _frameListener = onFrames;
    monitor.valueListenable.addListener(onFrames);

    // 模块阶段流：ready 时加载数据；非 ready 时降级展示（不自动安装）。
    _availabilitySub =
        ref.watch(perfAvailabilityStreamProvider).listen(_onAvailability);

    // 首帧后尝试加载（若模块已就绪）。
    Future<void>.microtask(refresh);

    // 跨会话历史：异步恢复磁盘上的滚动序列（失败静默降级）。
    _historyStore = ref.read(perfHistoryStoreProvider);
    _deviceStateBridge = ref.read(perfDeviceStateBridgeProvider);
    _frameMetricsBridge = ref.read(perfFrameMetricsBridgeProvider);
    _cpuStatReader = ref.read(perfCpuStatReaderProvider);
    Future<void>.microtask(_restoreHistories);

    // 若帧监控已在运行（单例），首帧后启动系统帧率 / 第三方口径轮询。
    Future<void>.microtask(_syncAuxFps);

    final initialStats = monitor.latestStats;
    return PerfPageState(
      loading: true,
      availability: _module.availability,
      frameStats: initialStats,
      frameMonitorRunning: monitor.isRunning,
      // 已有帧快照时种子化 FPS 历史，使图表首帧即可见。
      fpsHistory: initialStats.sampledFrames > 0
          ? <double>[initialStats.fps]
          : const <double>[],
    );
  }

  void _dispose() {
    _disposed = true;
    _stopTicker();
    _stopSystemFps();
    _thirdPartySub?.cancel();
    _thirdPartySub = null;
    _watchingPackage = null;
    // best-effort 关闭系统帧率采集（失败静默）。
    unawaited(_systemFpsServiceRef?.disable() ?? Future<void>.value());
    final monitor = _monitorRef;
    if (_frameListener != null && monitor != null) {
      monitor.valueListenable.removeListener(_frameListener!);
    }
    _frameListener = null;
    _availabilitySub?.cancel();
    _availabilitySub = null;
    _sampleSub?.cancel();
    _sampleSub = null;
  }

  /// 阶段变化：仅在「变为 ready」时加载；否则保持降级卡片。
  void _onAvailability(PerfAvailability availability) {
    if (_disposed) return;
    final wasReady = state.moduleReady;
    state = state.copyWith(availability: availability);
    if (availability == PerfAvailability.ready && !wasReady) {
      refresh();
    }
  }

  // ==================== 跨会话历史 ====================

  /// 从磁盘恢复滚动历史并合并进当前会话（失败静默）。
  Future<void> _restoreHistories() async {
    final store = _historyStore;
    if (store == null) return;
    final snapshot = await store.load();
    if (_disposed || snapshot.isEmpty) return;
    _thirdPartyCpu = snapshot.thirdPartyCpu;
    _thirdPartyMem = snapshot.thirdPartyMem;
    _thirdPartyJank = snapshot.thirdPartyJank;
    state = state.copyWith(
      fpsHistory: _mergeHistory(snapshot.fps, state.fpsHistory),
      cpuUsageHistory: _mergeHistory(snapshot.cpu, state.cpuUsageHistory),
      memoryUsedHistory:
          _mergeHistory(snapshot.memory, state.memoryUsedHistory),
      thermalMaxHistory:
          _mergeHistory(snapshot.thermal, state.thermalMaxHistory),
    );
  }

  /// 持久化值在前、当前会话值在后，裁剪到容量上限。
  List<double> _mergeHistory(List<double> persisted, List<double> current) {
    final merged = <double>[...persisted, ...current];
    final excess = merged.length - kPerfHistoryCapacity;
    if (excess > 0) merged.removeRange(0, excess);
    return merged;
  }

  /// 节流（≥2s）落盘当前滚动历史，避免高频 I/O。
  void _maybeSaveHistory() {
    if (_disposed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastHistorySaveMs < 2000) return;
    _lastHistorySaveMs = now;
    _saveHistoryNow();
  }

  void _saveHistoryNow() {
    final store = _historyStore;
    if (store == null) return;
    store
        .save(
      PerfHistorySnapshot(
        fps: state.fpsHistory,
        cpu: state.cpuUsageHistory,
        memory: state.memoryUsedHistory,
        thermal: state.thermalMaxHistory,
        thirdPartyCpu: _thirdPartyCpu,
        thirdPartyMem: _thirdPartyMem,
        thirdPartyJank: _thirdPartyJank,
      ),
    )
        .catchError((Object error) {
      debugPrint('[PerfMonitor] 保存历史失败（忽略）: $error');
    });
  }

  // ==================== 数据加载 ====================

  /// 并行刷新全部模块报告。模块未就绪时直接返回（仅结束 loading）。
  ///
  /// [silent] 为真时不切换 loading 态、不覆盖错误卡片（用于 2s 实时轮询，
  /// 避免每次轮询闪烁加载动画）。
  Future<void> refresh({bool silent = false}) async {
    if (_disposed) return;
    if (!state.moduleReady) {
      if (!silent) state = state.copyWith(loading: false);
      return;
    }
    if (_refreshing) return;
    _refreshing = true;
    if (!silent) state = state.copyWith(loading: true, clearError: true);
    final module = _module;
    try {
      // 先点火全部 future，再统一等待：任一失败都被 Future.wait 收口。
      // 深度报告（PSI / 散热 / 电池健康 / 存储）经 [_softFetch] 包裹：个别
      // 方法缺失（旧模块 / 无对应 sysfs）时降级为 `null`，不拖垮其它卡片。
      final results = await Future.wait<Object?>([
        module.cpu(),
        module.memory(),
        _batteryForRefresh(module, silent: silent),
        module.thermal(),
        module.gpu(),
        module.network(),
        module.processes(limit: 10, sort: state.processSort.value),
        _softFetch(module.pressure),
        _softFetch(module.cooling),
        _softFetch(module.batteryHealth),
        _softFetch(module.storage),
        _readDeviceState(),
        _readFrameMetrics(),
      ]);
      if (_disposed) return;
      final CpuReport cpuReport = results[0] as CpuReport;
      state = state.copyWith(
        loading: silent ? null : false,
        cpu: _applyPrivilegedUsage(cpuReport),
        memory: results[1] as MemoryReport,
        battery: results[2] as BatteryReport,
        thermal: results[3] as ThermalReport,
        gpu: results[4] as GpuReport,
        network: results[5] as NetworkReport,
        processes: results[6] as ProcessReport,
        pressure: results[7] as PerfPressureReport?,
        cooling: results[8] as PerfCoolingReport?,
        batteryHealth: results[9] as PerfBatteryHealthReport?,
        storage: results[10] as PerfStorageReport?,
        deviceState: results[11] as DeviceStateReading?,
        frameMetrics: results[12] as FrameMetricsReading?,
      );
      _appendModuleHistories();
      // 预热特权 `/proc/stat` 基线：首拍只建基线，下一次 2s 轮询即可算出逐核占用。
      if (cpuReport.perCoreUsage.isEmpty) unawaited(_primePrivilegedUsage());
    } on PerfModuleUnavailableException catch (error) {
      debugPrint('[PerfMonitor] 模块不可用（降级展示）: ${error.code}');
      if (_disposed) return;
      state = state.copyWith(
        loading: silent ? null : false,
        availability: PerfAvailability.absent,
      );
    } catch (error) {
      debugPrint('[PerfMonitor] 刷新失败（友好提示）: $error');
      if (_disposed) return;
      if (!silent) {
        state = state.copyWith(
          loading: false,
          error: '读取性能数据失败，请稍后重试',
        );
      }
    } finally {
      _refreshing = false;
    }
  }

  /// 轻量 CPU 轮询：刷新频率 / 逐核占用（性能页挂载期间每 2s 调用）。
  ///
  /// * 实时刷新 / 后台采样开启时，CPU 报告已由既有链路更新，这里只补逐核占用；
  /// * Rust 的 `perCoreUsage` 为空（Android 8+ `/proc/stat` 被 SELinux 拒绝）时，
  ///   经 [CpuStatReader]（Shizuku shell）读取同一文件并回填；
  /// * 无 Shizuku / 读取失败：保持原报告（UI 逐核显示 `—`），绝不伪造 0%。
  Future<void> refreshCpu() async {
    if (_disposed || _cpuPollingBusy || !state.moduleReady) return;
    _cpuPollingBusy = true;
    try {
      final CpuReport? moduleCpu =
          (state.live || state.sampling) ? state.cpu : await _module.cpu();
      if (_disposed || moduleCpu == null) return;

      // 仅在 Rust 拿不到逐核数据时才走特权兜底（避免无谓的 shell 调用）。
      if (moduleCpu.perCoreUsage.isNotEmpty) {
        if (!identical(moduleCpu, state.cpu)) {
          state = state.copyWith(cpu: moduleCpu);
        }
        return;
      }

      final sample = await _cpuStatReader?.sample();
      if (_disposed) return;
      if (sample != null) {
        _lastCoreUsage = sample;
        _lastCoreUsageAt = DateTime.now();
      }
      state = state.copyWith(cpu: _applyPrivilegedUsage(moduleCpu));
    } on PerfModuleUnavailableException {
      // 模块不可用：由既有 availability 流程统一降级，这里静默。
    } catch (error) {
      debugPrint('[PerfMonitor] CPU 轮询失败（忽略）: $error');
    } finally {
      _cpuPollingBusy = false;
    }
  }

  /// 预热特权 `/proc/stat` 基线并立即回填（若已能算出增量）。
  ///
  /// 首拍只建立基线（返回 `null`）；后续轮询即可得到真实逐核占用。
  Future<void> _primePrivilegedUsage() async {
    if (_disposed) return;
    final sample = await _cpuStatReader?.sample();
    if (_disposed || sample == null) return;
    _lastCoreUsage = sample;
    _lastCoreUsageAt = DateTime.now();
    final cpu = state.cpu;
    if (cpu != null && cpu.perCoreUsage.isEmpty) {
      state = state.copyWith(cpu: _mergeCpuUsage(cpu, sample));
    }
  }

  /// 把最近一次特权 `/proc/stat` 采样回填到 [cpu]（仅在 Rust 逐核缺失时）。
  ///
  /// Rust 报告本身可用（`perCoreUsage` 非空）时原样返回，绝不覆盖真实数据。
  CpuReport _applyPrivilegedUsage(CpuReport cpu) {
    if (cpu.perCoreUsage.isNotEmpty) return cpu;
    final sample = _lastCoreUsage;
    final at = _lastCoreUsageAt;
    if (sample == null || at == null) return cpu;
    if (DateTime.now().difference(at) > CpuStatReader.maxGap) return cpu;
    return _mergeCpuUsage(cpu, sample);
  }

  /// 用特权 `/proc/stat` 的增量占用回填 [cpu]（按 CPU 编号对齐 `cores[]`）。
  CpuReport _mergeCpuUsage(CpuReport cpu, CpuUsageSample sample) {
    final List<double> perCore;
    if (cpu.cores.isNotEmpty) {
      perCore = <double>[
        for (final core in cpu.cores) sample.perCoreById[core.id] ?? 0,
      ];
    } else {
      final ids = sample.perCoreById.keys.toList()..sort();
      perCore = <double>[
        for (final id in ids) sample.perCoreById[id] ?? 0,
      ];
    }
    return cpu.copyWith(
      usagePercent: sample.usagePercent,
      perCoreUsage: perCore,
    );
  }

  /// 读取批量设备状态（Rust JNI）：**best-effort**，任何失败 → `null`，
  /// 绝不拖垮并行的模块报告批次。
  Future<DeviceStateReading?> _readDeviceState() async {
    try {
      return await _deviceStateBridge?.read();
    } catch (error) {
      debugPrint('[PerfMonitor] 设备状态读取失败（降级）: $error');
      return null;
    }
  }

  /// 读取本应用帧指标（Rust JNI）：**best-effort**，任何失败 → `null`，
  /// 绝不拖垮并行的模块报告批次。
  Future<FrameMetricsReading?> _readFrameMetrics() async {
    try {
      return await _frameMetricsBridge?.read();
    } catch (error) {
      debugPrint('[PerfMonitor] 帧指标读取失败（降级）: $error');
      return null;
    }
  }

  /// 取本拍电池报告：非静默拍（首屏 / 手动刷新）总是重新合并；静默拍在
  /// [_silentBatteryTtl] 内直接复用最近一次结果，避免每拍都走 sysfs +
  /// `gstore/battery` 平台通道（[readBatteryReading] 自身 2s TTL 之外的额外节流）。
  ///
  /// 缓存仅在合并**成功**后更新，故首次加载语义不变（首拍必取真值）。
  Future<BatteryReport> _batteryForRefresh(
    PerfModule module, {
    required bool silent,
  }) {
    if (silent) {
      final cached = _cachedBattery;
      final at = _cachedBatteryAt;
      if (cached != null &&
          at != null &&
          DateTime.now().difference(at) < _silentBatteryTtl) {
        return Future<BatteryReport>.value(cached);
      }
    }
    return _readMergedBattery(module).then((report) {
      _cachedBattery = report;
      _cachedBatteryAt = DateTime.now();
      return report;
    });
  }

  /// 软获取深度报告：任何失败（方法缺失 / 无对应 sysfs / 旧模块）都返回 `null`，
  /// 只影响该卡片，不拖垮并行批次。模块整体不可用时，既有报告调用仍会抛出并触发
  /// 整页降级，故此处的 `null` 只是冗余兜底。
  Future<T?> _softFetch<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (error) {
      debugPrint('[PerfMonitor] 深度报告不可用（降级为「不可用」）: $error');
      return null;
    }
  }

  /// 显式「安装 / 重试」：经模块 `ping` 点火安装与挂载（幂等，不启动采样）。
  Future<void> retryInstall() async {
    if (_disposed) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      await _module.ping();
      if (_disposed) return;
      state = state.copyWith(availability: PerfAvailability.ready);
      await refresh();
    } on PerfModuleUnavailableException {
      if (_disposed) return;
      state = state.copyWith(
        loading: false,
        availability: PerfAvailability.failed,
      );
      AppDialogs.showError('性能模块尚不可用，请确认已下载对应插件后重试');
    } catch (error) {
      debugPrint('[PerfMonitor] 安装 / 重试失败: $error');
      if (_disposed) return;
      state = state.copyWith(
        loading: false,
        error: '安装性能模块失败，请稍后重试',
      );
    }
  }

  /// 切换进程排行排序维度并重新拉取。
  Future<void> setProcessSort(PerfProcessSort sort) async {
    if (sort == state.processSort) return;
    state = state.copyWith(processSort: sort);
    if (!state.moduleReady) return;
    try {
      final report = await _module.processes(limit: 10, sort: sort.value);
      if (_disposed) return;
      state = state.copyWith(processes: report);
    } on PerfModuleUnavailableException {
      if (_disposed) return;
      state = state.copyWith(availability: PerfAvailability.absent);
    } catch (error) {
      debugPrint('[PerfMonitor] 进程排序切换失败: $error');
    }
  }

  // ==================== 帧监控控制 ====================

  /// 开关帧时序采集（幂等；不涉及原生模块）。
  void toggleFrameMonitor() {
    final monitor = _monitor;
    if (monitor.isRunning) {
      monitor.stop();
    } else {
      monitor.start();
    }
    state = state.copyWith(
      frameMonitorRunning: monitor.isRunning,
      frameStats: monitor.latestStats,
    );
    _syncAuxFps();
  }

  /// 清空帧累计统计。
  void resetFrameStats() {
    _monitor.reset();
    state = state.copyWith(frameStats: _monitor.latestStats);
  }

  // ==================== 系统帧率 / 第三方口径 ====================

  /// 依据当前运行态同步「系统帧率」与「第三方」两条辅助口径。
  ///
  /// * 系统帧率轮询仅在 `frameMonitorRunning || live` 时运行（独立 2s Timer）；
  /// * 第三方订阅仅在 `frameMonitorRunning` 且有持久目标时建立。
  void _syncAuxFps() {
    _syncSystemFps();
    unawaited(_syncThirdPartyFps());
  }

  /// 仅在 `frameMonitorRunning || live` 时保持系统帧率 Timer 运行。
  void _syncSystemFps() {
    if (_disposed) return;
    final shouldRun = state.frameMonitorRunning || state.live;
    if (shouldRun) {
      _startSystemFps();
    } else {
      _stopSystemFps();
    }
  }

  void _startSystemFps() {
    if (_disposed || _systemFpsTimer != null) return;
    // 幂等开启 SurfaceFlinger TimeStats（best-effort）。
    unawaited(_systemFps.enable());
    _systemFpsTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _sampleSystemFps());
    // 立即采一次，避免首秒空白。
    unawaited(_sampleSystemFps());
  }

  void _stopSystemFps() {
    _systemFpsTimer?.cancel();
    _systemFpsTimer = null;
  }

  /// 采样一次系统帧率并写入 `screenFps` / `screenFpsLayer` / `screenFpsHistory`。
  ///
  /// 采样失败 / 无数据时**保留旧值**（不置 `null`），避免趋势图闪烁。
  Future<void> _sampleSystemFps() async {
    if (_disposed) return;
    final sample = await _systemFps.sample();
    if (_disposed) return;
    final fps = sample?.fps;
    if (fps == null) return;
    state = state.copyWith(
      screenFps: fps,
      screenFpsLayer: sample?.layer,
      screenFpsHistory: _pushHistory(state.screenFpsHistory, fps),
    );
  }

  /// 依据「帧监控运行 + 持久目标」建立 / 取消第三方 FPS 订阅。
  ///
  /// 复用 [ThirdPartyPerfService.watch]（**不新建数据通路**）：订阅即采一次，之后
  /// 每 2s 采一次；把 `metrics.fps` 写入 `thirdPartyFps`，目标展示名写入
  /// `thirdPartyFpsLabel`。无目标 / 停止时取消订阅并清空两者。
  Future<void> _syncThirdPartyFps() async {
    if (_disposed) return;
    if (!state.frameMonitorRunning) {
      await _cancelThirdPartyFps();
      return;
    }
    final PerfPinnedTarget? target;
    try {
      target = await ref.read(perfTargetStoreProvider).load();
    } catch (error) {
      debugPrint('[PerfMonitor] 读取第三方目标失败（忽略）: $error');
      await _cancelThirdPartyFps();
      return;
    }
    if (_disposed) return;
    if (target == null || target.package.isEmpty) {
      await _cancelThirdPartyFps();
      return;
    }
    // 已订阅同一目标：仅确保 label 最新。
    if (_watchingPackage == target.package && _thirdPartySub != null) {
      if (state.thirdPartyFpsLabel != target.label) {
        state = state.copyWith(thirdPartyFpsLabel: target.label);
      }
      return;
    }
    await _cancelThirdPartyFps();
    if (_disposed) return;
    _watchingPackage = target.package;
    final label = target.label;
    try {
      _thirdPartySub = _thirdParty
          .watch(target.package, interval: const Duration(seconds: 2))
          .listen((sample) {
        if (_disposed) return;
        state = state.copyWith(
          thirdPartyFps: sample.metrics.fps,
          thirdPartyFpsLabel: label,
        );
      });
    } catch (error) {
      debugPrint('[PerfMonitor] 订阅第三方帧率失败（忽略）: $error');
      _watchingPackage = null;
      return;
    }
    state = state.copyWith(thirdPartyFpsLabel: label);
  }

  Future<void> _cancelThirdPartyFps() async {
    await _thirdPartySub?.cancel();
    _thirdPartySub = null;
    _watchingPackage = null;
    if (_disposed) return;
    if (state.thirdPartyFps != null || state.thirdPartyFpsLabel != null) {
      state = state.copyWith(clearThirdPartyFps: true);
    }
  }

  // ==================== 后台采样控制 ====================

  /// 开关后台实时采样（**默认 OFF**；唯一显式入口）。
  Future<void> toggleSampling(bool on) async {
    if (_disposed) return;
    if (on) {
      try {
        final result = await _module.startSampling();
        if (_disposed) return;
        _sampleSub ??= _module.samples.listen(_onSample);
        state = state.copyWith(sampling: result.running);
      } on PerfModuleUnavailableException {
        if (_disposed) return;
        state = state.copyWith(availability: PerfAvailability.absent);
        AppDialogs.showError('性能模块不可用，无法开启采样');
      } catch (error) {
        debugPrint('[PerfMonitor] 开启采样失败: $error');
        AppDialogs.showError('开启采样失败');
      }
    } else {
      await _sampleSub?.cancel();
      _sampleSub = null;
      try {
        await _module.stopSampling();
      } catch (error) {
        debugPrint('[PerfMonitor] 停止采样失败（忽略）: $error');
      }
      if (_disposed) return;
      state = state.copyWith(sampling: false);
    }
    _syncTicker();
  }

  /// 采样事件：累加计数并用最新快照刷新各节。
  void _onSample(PerfSample sample) {
    if (_disposed) return;
    final snap = sample.snapshot;
    state = state.copyWith(
      sampleCount: state.sampleCount + 1,
      lastSampleTsMs: snap.tsMs,
      cpu: snap.cpu == null
          ? null
          : _applyPrivilegedUsage(snap.cpu!),
      memory: snap.memory ?? state.memory,
      battery: snap.battery ?? state.battery,
      thermal: snap.thermal ?? state.thermal,
      gpu: snap.gpu ?? state.gpu,
      network: snap.network ?? state.network,
      processes: snap.processes ?? state.processes,
    );
    _appendModuleHistories();
  }

  // ==================== 实时刷新（趋势历史） ====================

  /// 开关实时刷新（`Timer.periodic` 2s 轮询模块并累积各指标历史）。
  void setLive(bool on) {
    if (_disposed) return;
    if (on == state.live) return;
    state = state.copyWith(live: on);
    _syncTicker();
    _syncAuxFps();
  }

  /// 仅在 [PerfPageState.live] 或采样开启时保持定时器运行。
  void _syncTicker() {
    if (_disposed) return;
    if (state.live || state.sampling) {
      _startTicker();
    } else {
      _stopTicker();
    }
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _tick() async {
    if (_disposed) return;
    if (state.moduleReady && !_refreshing) {
      // 静默轮询：更新各报告并追加历史，不闪烁 loading。
      await refresh(silent: true);
    }
  }

  /// 把当前各报告值追加进滚动历史（跳过 `null` 与非法值）。
  void _appendModuleHistories() {
    if (_disposed) return;
    var next = state;

    final double? cpu = next.cpu?.usagePercent;
    if (cpu != null) {
      next = next.copyWith(
        cpuUsageHistory: _pushHistory(next.cpuUsageHistory, cpu),
      );
    }

    final double? mem = next.memory?.usedPercent;
    if (mem != null) {
      next = next.copyWith(
        memoryUsedHistory: _pushHistory(next.memoryUsedHistory, mem),
      );
    }

    final double? thermal = next.thermal?.maxTempC;
    if (thermal != null) {
      next = next.copyWith(
        thermalMaxHistory: _pushHistory(next.thermalMaxHistory, thermal),
      );
    }

    final battery = next.battery;
    if (battery != null && battery.present && battery.currentMa != null) {
      next = next.copyWith(
        batteryCurrentHistory:
            _pushHistory(next.batteryCurrentHistory, battery.currentMa!),
      );
    }

    final network = next.network;
    if (network != null) {
      next = next.copyWith(
        networkRxHistory:
            _pushHistory(next.networkRxHistory, network.rxBytesPerSec),
        networkTxHistory:
            _pushHistory(next.networkTxHistory, network.txBytesPerSec),
      );
    }

    if (!identical(next, state)) state = next;
    _maybeSaveHistory();
  }

  /// 有界追加：返回**新**列表（`NaN` / `±Infinity` 原样跳过），超容量裁剪最旧。
  List<double> _pushHistory(List<double> history, double value) {
    if (!value.isFinite) return history;
    final next = List<double>.of(history)..add(value);
    final excess = next.length - kPerfHistoryCapacity;
    if (excess > 0) next.removeRange(0, excess);
    return next;
  }
}
