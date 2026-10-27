/// Perf 模块 Dart 门面（`gstore_mod_perf`）。
///
/// 纯展示 / 触发层：本文件只做两类翻译，**不含**任何采集或解析逻辑
/// （全部在 Rust 侧，见 `rust/gstore_mod_perf/README.md`）：
/// 1. 信封调用 → `data` → JSON 解码 → 类型化模型（[CpuReport] / [MemoryReport] …）；
/// 2. 模块事件流 → 类型化采样（[PerfSample]，`perf.sample`）。
///
/// 模块为**按需下载 / 尚未随包**（Phase 3 目标；README §构建），故门面经
/// [ModuleBootstrap.run] 走统一自举门：首次使用时确保安装；模块不可安装 /
/// 未安装时抛出结构化的 [PerfModuleUnavailableException]（不崩溃、不是裸错误），
/// 与 analyzer / qr 门面在全新安装上的降级语义一致。
///
/// **绝不自动开启采样**：门面只提供 [startSampling] 显式入口；模块挂载与
/// [prewarm] 都不会启动后台采样线程。默认 [ping] 的 `samplerRunning` 为 false。
///
/// 底层经 [PerfModuleGateway] 隔离，测试可注入假网关，**无需原生模块**。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/contract/GStoreException.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

// ==================== 可用性 ====================

/// 模块可用性（编译期可观测的自举阶段，镜像 [ModuleBootstrapPhase]）。
///
/// 与 [ProxyModule] 的「结构化不可用异常」互补：异常描述**一次调用**为何失败，
/// 本枚举描述**模块产物**处于哪个宏观阶段，供 UI 决定是否展示「准备中」。
enum PerfAvailability {
  /// 尚无任何状态（空闲 / 未触发）。
  absent,

  /// 正在确保产物就绪（必要时远程下载）。
  downloading,

  /// 产物已就绪，正在挂载 / 创建实例。
  initializing,

  /// 实例可用。
  ready,

  /// 本次确保 / 实例化失败（失败不粘滞，后续调用可重试）。
  failed;

  /// 由自举阶段映射（未知一律归 [absent]，绝不抛错）。
  static PerfAvailability fromPhase(ModuleBootstrapPhase phase) =>
      switch (phase) {
        ModuleBootstrapPhase.absent => PerfAvailability.absent,
        ModuleBootstrapPhase.downloading => PerfAvailability.downloading,
        ModuleBootstrapPhase.initializing => PerfAvailability.initializing,
        ModuleBootstrapPhase.ready => PerfAvailability.ready,
        ModuleBootstrapPhase.failed => PerfAvailability.failed,
      };
}

// ==================== 异常 ====================

/// Perf 模块调用失败（信封错误或响应非法）。
class PerfModuleException implements Exception {
  const PerfModuleException({
    required this.code,
    required this.message,
    this.status,
  });

  /// 错误码（如 `METHOD_NOT_FOUND` / `INSTANCE_NOT_FOUND`）。
  final String code;

  /// 人类可读消息。
  final String message;

  /// 信封 HTTP 状态码（非信封路径时为 `null`）。
  final int? status;

  @override
  String toString() =>
      'PerfModuleException($code${status == null ? '' : '/$status'}): $message';
}

/// Perf 模块不可用（未安装 / 无法安装 / 用户取消确认）。
///
/// 模块缺失是**预期状态**而非崩溃（与分析器 / 二维码门面一致）。
class PerfModuleUnavailableException extends PerfModuleException {
  PerfModuleUnavailableException({this.declined = false, this.cause})
      : super(
          code: declined ? 'PERF_MODULE_DECLINED' : 'PERF_MODULE_UNINSTALLED',
          message: declined ? '性能监控模块安装被取消' : '性能监控模块未安装',
        );

  /// 用户是否在安装确认弹层中拒绝。
  final bool declined;

  /// 底层错误（诊断用，可为 `null`）。
  final Object? cause;
}

// ==================== 原始事件 / 网关 ====================

/// 原始 perf 事件（模块 → 宿主）：事件名 + JSON 字节载荷。
class PerfRawEvent {
  const PerfRawEvent({required this.eventType, required this.data});

  /// 事件名（如 `perf.sample`）。
  final String eventType;

  /// JSON 载荷字节。
  final Uint8List data;
}

/// 门面底层网关：把「模块调用」与「事件流」从 [PerfModule] 隔离，
/// 使单元 / 组件测试可注入假实现，**无需原生模块**。
abstract class PerfModuleGateway {
  /// 执行一次信封调用，返回解包后的 JSON 载荷字节（`{ok:true,data:{...}}`）。
  Future<Uint8List> call(String method, [Uint8List? payload]);

  /// perf 模块事件流（已按 `perf.` 前缀过滤）。
  Stream<PerfRawEvent> get events;
}

/// 生产网关：经 [ModuleBootstrap] 自举 + [RustModuleManager] 事件总线。
class _RustPerfGateway implements PerfModuleGateway {
  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) {
    return ModuleBootstrap.instance.run<Uint8List>(
      PerfModule.moduleName,
      (instance) => instance.callModule(method, payload),
      maxAttempts: 1,
    );
  }

  @override
  Stream<PerfRawEvent> get events => RustModuleManager.instance.moduleEvents
      .where(
        (event) => event.eventType.startsWith('${PerfModule.moduleName}.'),
      )
      .map(
        (event) => PerfRawEvent(eventType: event.eventType, data: event.data),
      );
}

// ==================== 门面 ====================

/// Perf 模块门面（单例 [instance]，测试可经构造函数注入 [PerfModuleGateway]）。
class PerfModule {
  PerfModule({PerfModuleGateway? gateway})
      : _gateway = gateway ?? _RustPerfGateway();

  /// 模块名（与 Rust 注册名一致，README §C ABI）。
  static const String moduleName = 'perf';

  /// 模块要求的最低宿主 ABI（README §C ABI：`abi_version >= 3`）。
  static const int minHostAbi = 3;

  static PerfModule? _instance;

  /// 生产单例入口。
  static PerfModule get instance => _instance ??= PerfModule();

  final PerfModuleGateway _gateway;

  StreamController<PerfSample>? _sampleController;
  StreamSubscription<PerfRawEvent>? _samplePump;

  // ---- 可用性 ----

  /// 当前可用性的**廉价**快照（不触达 FFI：缓存实例存在即 ready，否则 absent）。
  ///
  /// 需要精确的实时阶段（含 downloading/failed）时用 [watchAvailability]。
  PerfAvailability get availability =>
      ModuleBootstrap.instance.hasInstance(moduleName)
          ? PerfAvailability.ready
          : PerfAvailability.absent;

  /// 订阅 `perf` 模块的自举阶段流。
  ///
  /// 订阅即同步收到当前缓存阶段；[ModuleBootstrap] 保证「读缓存 + 订阅」在同一
  /// 同步块内完成，不丢事件（详见其 `watch` 文档）。
  Stream<PerfAvailability> watchAvailability() => ModuleBootstrap.instance
      .watch(moduleName)
      .map((state) => PerfAvailability.fromPhase(state.phase));

  /// 预热 `perf` 模块：提前点火安装与挂载，**绝不启动采样**。
  ///
  /// 幂等：与 [ModuleBootstrap] 的两级单飞合流，重复调用不会重复下载。
  /// 已缓存实例（产物必然就绪）时短路，避免把已 ready 的观测阶段翻回 downloading。
  void prewarm() {
    final gate = ModuleBootstrap.instance;
    if (gate.hasInstance(moduleName)) return;
    gate.ensureStarted(moduleName);
    gate.acquire(moduleName).ignore();
  }

  // ---- 类型化方法 ----

  /// `ping`：心跳 / 当前状态快照。
  Future<PerfPingResult> ping() async =>
      PerfPingResult.fromJson(await _call(PerfMethods.ping));

  /// `perf.snapshot`：聚合快照（可选附带进程 Top-N）。
  Future<PerfSnapshot> snapshot({
    bool includeProcesses = false,
    int? processLimit,
  }) =>
      invoke(
        PerfMethods.snapshot,
        PerfSnapshot.fromJson,
        payload: <String, dynamic>{
          'include_processes': includeProcesses,
          if (processLimit != null) 'process_limit': processLimit,
        },
      );

  /// `perf.cpu`：占用率 / 频率 / 负载。
  Future<CpuReport> cpu() => invoke(PerfMethods.cpu, CpuReport.fromJson);

  /// `perf.memory`：内存与 swap 报告。
  Future<MemoryReport> memory() =>
      invoke(PerfMethods.memory, MemoryReport.fromJson);

  /// `perf.battery`：电池报告（无电池时 `present=false`）。
  Future<BatteryReport> battery() =>
      invoke(PerfMethods.battery, BatteryReport.fromJson);

  /// `perf.thermal`：热区枚举报告。
  Future<ThermalReport> thermal() =>
      invoke(PerfMethods.thermal, ThermalReport.fromJson);

  /// `perf.gpu`：GPU 频率 / 忙率 / 名称。
  Future<GpuReport> gpu() => invoke(PerfMethods.gpu, GpuReport.fromJson);

  /// `perf.network`：网络吞吐与各接口计数器。
  Future<NetworkReport> network() =>
      invoke(PerfMethods.network, NetworkReport.fromJson);

  /// `perf.processes`：按 CPU / RSS 排序的进程 Top-N（`limit` 1..100，默认 10）。
  Future<ProcessReport> processes({int? limit, String? sort}) => invoke(
        PerfMethods.processes,
        ProcessReport.fromJson,
        payload: <String, dynamic>{
          if (limit != null) 'limit': limit,
          if (sort != null) 'sort': sort,
        },
      );

  /// `perf.device`：设备身份报告。
  Future<DeviceReport> device() =>
      invoke(PerfMethods.device, DeviceReport.fromJson);

  /// `perf.pressure`：`/proc/pressure/*` PSI 压力（CPU / 内存 / IO）。
  Future<PerfPressureReport> pressure() =>
      invoke(PerfMethods.pressure, PerfPressureReport.fromJson);

  /// `perf.cooling`：散热设备枚举（`cur_state` / `max_state`）。
  Future<PerfCoolingReport> cooling() =>
      invoke(PerfMethods.cooling, PerfCoolingReport.fromJson);

  /// `perf.tunables`：可控面枚举（CPU 簇 / cpuset / 热区 / 散热 / GPU；只读）。
  Future<TunablesReport> tunables() =>
      invoke(PerfMethods.tunables, TunablesReport.fromJson);

  /// `perf.sensors`：Android NDK 传感器清单（只读元数据；无权限/Looper 依赖）。
  Future<SensorsReport> sensors() =>
      invoke(PerfMethods.sensors, SensorsReport.fromJson);

  /// `perf.sysfs.read`：读取白名单内**单个** sysfs / cpuset 节点（写回校验用）。
  ///
  /// [path] 必须命中 Rust 侧白名单（cpufreq `scaling_*` / cpuset `cpus` / 热区
  /// `temp` 等，见 README 与 `collectors::sysfs_read::SYSFS_ALLOWLIST`），否则
  /// Rust 返回结构化 `invalid_arg`（门面抛 [PerfModuleException]），**永不返回值**。
  /// 节点不存在 / 不可读不是错误：此时 [SysfsReadResult.exists] 为 false、
  /// [SysfsReadResult.value] 为 `null`。
  Future<SysfsReadResult> readSysfs(String path) => invoke(
        PerfMethods.sysfsRead,
        SysfsReadResult.fromJson,
        payload: <String, dynamic>{'path': path},
      );

  /// `perf.battery_health`：电池健康深读（满电 / 设计容量、循环次数等）。
  Future<PerfBatteryHealthReport> batteryHealth() =>
      invoke(PerfMethods.batteryHealth, PerfBatteryHealthReport.fromJson);

  /// `perf.storage`：存储卷用量（总 / 已用 / 可用）。
  Future<PerfStorageReport> storage() =>
      invoke(PerfMethods.storage, PerfStorageReport.fromJson);

  /// `perf.start`：启动后台采样（`interval_ms` 夹取 200..600000，默认 2000）。
  ///
  /// **唯一**会开启采样的入口；务必由用户显式触发，绝不在启动时调用。
  Future<PerfStartResult> startSampling({int? intervalMs}) => invoke(
        PerfMethods.start,
        PerfStartResult.fromJson,
        payload: <String, dynamic>{
          if (intervalMs != null) 'interval_ms': intervalMs,
        },
      );

  /// `perf.stop`：停止后台采样（幂等）。
  Future<PerfStopResult> stopSampling() =>
      invoke(PerfMethods.stop, PerfStopResult.fromJson);

  /// `perf.status`：采样器状态（运行中 / 间隔 / 实例 / 线程数）。
  Future<PerfSamplerStatus> status() =>
      invoke(PerfMethods.status, PerfSamplerStatus.fromJson);

  /// `perf.history`：采样环内最近 `limit` 条（省略 = 全部，上限 300）。
  Future<PerfHistory> history({int? limit}) => invoke(
        PerfMethods.history,
        PerfHistory.fromJson,
        payload: <String, dynamic>{
          if (limit != null) 'limit': limit,
        },
      );

  /// `perf.reset`：清空采样环与全部增量基线。
  Future<PerfResetResult> reset() =>
      invoke(PerfMethods.reset, PerfResetResult.fromJson);

  /// `perf.parse_app_dumps`：把第三方应用的 dumpsys 文本解析为结构化指标。
  ///
  /// 文本由调用方（Shizuku 命令）采集后原样传入；解析全在 Rust 侧。无法解析的
  /// 字段返回 `null`（宽容），`fps` / 网络速率由 Dart 侧按两次采样差值另行推导，
  /// 不在本方法内计算。
  ///
  /// [uid] / [ps] / [status] / [netstats] 为可选扩展输入（契约新增）：分别为
  /// 应用 uid、`ps -A` 文本、`/proc/<pid>/status` 文本、`dumpsys netstats detail`
  /// 文本；缺失时传空串（Rust 侧宽容为空）。
  ///
  /// [framestats] / [batterystats] 为新增可选输入：`dumpsys gfxinfo <pkg>
  /// framestats` 与 `dumpsys batterystats --charged <pkg>` 文本，分别解析为
  /// 响应中的 `render` / `power` 字段；缺失时传空串（Rust 侧宽容为空）。
  ///
  /// [packageInfo] / [smaps] / [crashLog] / [anrLog] / [activity] 为「应用深入」
  /// 批次新增可选输入：`dumpsys package <pkg>`、`/proc/<pid>/smaps_rollup`（多进程
  /// 拼接）、`dumpsys dropbox --print data_app_crash`、`dumpsys dropbox --print
  /// data_app_anr`、`dumpsys activity activities` 文本，分别解析为响应中的
  /// `app_info` / `smaps` / `crashes` / `foreground` / `wake_locks` 字段；缺失时
  /// 传空串（Rust 侧宽容为空）。仍是**单次** [invoke]。
  Future<ThirdPartyAppMetrics> parseAppDumps({
    required String package,
    int? pid,
    int? uid,
    String? cpuinfo,
    String? meminfo,
    String? gfxinfo,
    String? ps,
    String? status,
    String? netstats,
    String? framestats,
    String? batterystats,
    String? packageInfo,
    String? smaps,
    String? crashLog,
    String? anrLog,
    String? activity,
  }) =>
      invoke(
        PerfMethods.parseAppDumps,
        ThirdPartyAppMetrics.fromJson,
        payload: <String, dynamic>{
          'package': package,
          'pid': pid,
          'uid': uid,
          'cpuinfo': cpuinfo ?? '',
          'meminfo': meminfo ?? '',
          'gfxinfo': gfxinfo ?? '',
          'ps': ps ?? '',
          'status': status ?? '',
          'netstats': netstats ?? '',
          'framestats': framestats ?? '',
          'batterystats': batterystats ?? '',
          'package_info': packageInfo ?? '',
          'smaps': smaps ?? '',
          'crash_log': crashLog ?? '',
          'anr_log': anrLog ?? '',
          'activity': activity ?? '',
        },
      );

  /// `perf.parse_startup`：把 `am start -W` 输出解析为冷 / 热启动耗时。
  ///
  /// [output] 为 `am start -W -n <pkg>/<activity>` 的原始文本；[mode] 为
  /// `cold` / `warm`（缺省 `cold`）。数值字段无法解析时返回 `null`（宽容），
  /// 启动测量本身的控制动作（force-stop / start）由调用方经 Shizuku 完成。
  Future<PerfStartupResult> parseStartup({
    required String output,
    String? mode,
  }) =>
      invoke(
        PerfMethods.parseStartup,
        PerfStartupResult.fromJson,
        payload: <String, dynamic>{
          'output': output,
          'mode': mode ?? 'cold',
        },
      );

  /// `perf.foreground`：从 `dumpsys activity activities` 原文抽取当前前台包名。
  ///
  /// [activity] 由调用方经 Shizuku 采集后原样传入（Rust 不跑 shell）；纯解析。
  /// 无法判定（无 resumed 行 / 多窗口歧义）时 [ForegroundReport.package] 为
  /// `null`（**绝不报错、绝不猜测**）；仅回传包名，不保留活动全文。
  Future<ForegroundReport> foreground(String activity) => invoke(
        PerfMethods.foreground,
        ForegroundReport.fromJson,
        payload: <String, dynamic>{'activity': activity},
      );

  // ---- 事件流 ----

  /// 类型化采样广播流（`perf.sample`）。
  ///
  /// 首次访问时**同步**挂载对模块事件总线的单一订阅（`listen` 同步附着），
  /// 因此后续 `listen` / `first` 不会错过紧随其后的 `add`（广播流不缓冲）。
  Stream<PerfSample> get samples {
    final controller = _sampleController ??=
        StreamController<PerfSample>.broadcast(sync: true);
    _samplePump ??= _gateway.events.listen((raw) {
      if (raw.eventType != PerfEvents.sample) return;
      final sample = _decodeSample(raw);
      if (sample != null && !controller.isClosed) {
        controller.add(sample);
      }
    });
    return controller.stream;
  }

  /// 通用类型化调用：信封 → `data` → [decode]。
  ///
  /// 展示层所有方法都经此入口，方法名与响应模型见 [PerfMethods] /
  /// [PerfContract]（README 的 Dart 镜像）。
  Future<T> invoke<T>(
    String method,
    T Function(Map<String, dynamic> json) decode, {
    Map<String, dynamic>? payload,
  }) async {
    final data = await _call(
      method,
      payload == null ? null : _encodePayload(payload),
    );
    return decode(data);
  }

  /// 解析一条 `perf.sample` 原始事件；非 JSON / 非法载荷返回 `null`（静默忽略）。
  PerfSample? _decodeSample(PerfRawEvent raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(raw.data, allowMalformed: true));
    } catch (error) {
      appLog.debug('PerfModule: 事件 ${raw.eventType} 载荷非 JSON - $error');
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    try {
      return PerfSample.fromEventJson(decoded);
    } catch (error) {
      appLog.warning('PerfModule: perf.sample 解析失败 - $error');
      return null;
    }
  }

  /// 调用信封 → 校验 `{ok:true,data:{...}}` → 返回 `data`。
  ///
  /// 错误分层：模块不可用 → [PerfModuleUnavailableException]；
  /// 其余信封 / 业务错误 → [PerfModuleException]。
  Future<Map<String, dynamic>> _call(
    String method, [
    Uint8List? payload,
  ]) async {
    try {
      final bytes = await _gateway.call(method, payload);
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      } catch (error) {
        throw const PerfModuleException(
          code: 'PAYLOAD_DECODE_FAILED',
          message: '性能模块响应不是合法 JSON',
          status: 400,
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw const PerfModuleException(
          code: 'PAYLOAD_DECODE_FAILED',
          message: '性能模块响应不是 JSON 对象',
          status: 400,
        );
      }
      if (decoded['ok'] != true) {
        throw PerfModuleException(
          code: decoded['code']?.toString() ?? 'BAD_REQUEST',
          message: decoded['message']?.toString() ?? '性能模块返回错误',
          status: _asIntOrNull(decoded['status']) ?? 400,
        );
      }
      final data = decoded['data'];
      return data is Map<String, dynamic> ? data : const <String, dynamic>{};
    } on PerfModuleException {
      rethrow;
    } on ModuleInstallFailedException catch (error) {
      throw PerfModuleUnavailableException(cause: error);
    } on ModuleInstallDeclinedException catch (error) {
      throw PerfModuleUnavailableException(declined: true, cause: error);
    } on GStoreException catch (error) {
      throw PerfModuleException(
        code: error.errorCode,
        message: error.message,
        status: error.status.value,
      );
    } catch (error) {
      // 宿主 ModuleHandle.load 的失败值是裸 String；未安装 / 无法加载统一降级为
      // 结构化的「模块未安装」状态，绝不向上抛裸错误。
      appLog.warning('PerfModule: $method 调用失败（按模块不可用处理）- $error');
      throw PerfModuleUnavailableException(cause: error);
    }
  }

  static Uint8List _encodePayload(Map<String, dynamic> payload) =>
      Uint8List.fromList(utf8.encode(jsonEncode(payload)));
}

int? _asIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value == null) return null;
  return int.tryParse(value.toString());
}
