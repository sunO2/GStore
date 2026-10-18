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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/perf_auto_export_service.dart';
import 'package:gstore/core/perf/perf_auto_export_settings.dart';
import 'package:gstore/core/perf/perf_history_store.dart';
import 'package:gstore/core/perf/perf_report.dart';
import 'package:gstore/core/perf/perf_report_store.dart';
import 'package:gstore/core/perf/perf_target_store.dart';
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
    final shouldRun = (perfState.live || perfState.sampling) && settings.enabled;
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

/// 自动导出设置的加载 / 保存控制器。
class PerfAutoExportSettingsNotifier
    extends Notifier<PerfAutoExportSettings> {
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

  /// 实时刷新定时器（1s；仅 [PerfPageState.live] 或采样开启时运行）。
  Timer? _ticker;

  /// build 时捕获的帧监控引用（dispose 阶段 `ref` 已失效，不可再 read）。
  FrameMonitor? _monitorRef;

  /// build 时捕获的历史存储（dispose 阶段 `ref` 已失效）。
  PerfHistoryStore? _historyStore;

  /// 上次落盘时间（Unix ms），节流历史写入。
  int _lastHistorySaveMs = 0;

  /// 从磁盘恢复的第三方历史（本页不主动更新，仅随历史回填/回写）。
  List<double> _thirdPartyCpu = const <double>[];
  List<double> _thirdPartyMem = const <double>[];
  List<double> _thirdPartyJank = const <double>[];

  PerfModule get _module => ref.read(perfModuleProvider);
  FrameMonitor get _monitor => _monitorRef ?? ref.read(perfFrameMonitorProvider);

  @override
  PerfPageState build() {
    ref.onDispose(_dispose);

    // 帧统计：监听节流发布的 ValueListenable。
    final monitor = _monitor;
    _monitorRef = monitor;
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
    Future<void>.microtask(_restoreHistories);

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
      memoryUsedHistory: _mergeHistory(snapshot.memory, state.memoryUsedHistory),
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
  /// [silent] 为真时不切换 loading 态、不覆盖错误卡片（用于 1s 实时轮询，
  /// 避免每秒闪烁加载动画）。
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
        module.battery(),
        module.thermal(),
        module.gpu(),
        module.network(),
        module.processes(limit: 10, sort: state.processSort.value),
        _softFetch(module.pressure),
        _softFetch(module.cooling),
        _softFetch(module.batteryHealth),
        _softFetch(module.storage),
      ]);
      if (_disposed) return;
      state = state.copyWith(
        loading: silent ? null : false,
        cpu: results[0] as CpuReport,
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
      );
      _appendModuleHistories();
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
      final report =
          await _module.processes(limit: 10, sort: sort.value);
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
  }

  /// 清空帧累计统计。
  void resetFrameStats() {
    _monitor.reset();
    state = state.copyWith(frameStats: _monitor.latestStats);
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
      cpu: snap.cpu ?? state.cpu,
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

  /// 开关实时刷新（`Timer.periodic` 1s 轮询模块并累积各指标历史）。
  void setLive(bool on) {
    if (_disposed) return;
    if (on == state.live) return;
    state = state.copyWith(live: on);
    _syncTicker();
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
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
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
