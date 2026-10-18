/// gstore_mod_perf 类型化 Dart 契约（手写，**无 code-gen**）。
///
/// 本文件是 `rust/gstore_mod_perf/README.md` 的 Dart 镜像：
/// * [PerfMethods.all] = 全部可派发方法名（与 Rust `DISPATCH_METHODS` 一致）；
/// * [PerfEvents.all] = 模块经 `emit_event` 上报的事件名（当前仅 `perf.sample`）；
/// * 每个响应/事件都是显式模型，未知 / `null` 字段按 README 规定的默认值**宽容解码**，
///   绝不抛裸异常（部分数据是预期状态：新装/无电池/无 GPU 等）。
///
/// 纯 Dart，无网络 / 无 FFI / 无业务逻辑：Flutter 只展示，采集逻辑在 Rust。
///
/// 单位约定（README §方法 schema）：`*_kb`（KiB）、`*_mhz`（MHz）、`*_c`（°C）、
/// `*_ma`（mA）、`*_bytes`（字节）、`*_percent`（0..100）。
library;

// ==================== 方法 / 事件注册表 ====================

/// 全部可派发方法名（冻结契约，与 Rust `DISPATCH_METHODS` 逐项对应）。
class PerfMethods {
  const PerfMethods._();

  static const String ping = 'ping';
  static const String snapshot = 'perf.snapshot';
  static const String cpu = 'perf.cpu';
  static const String memory = 'perf.memory';
  static const String battery = 'perf.battery';
  static const String thermal = 'perf.thermal';
  static const String gpu = 'perf.gpu';
  static const String network = 'perf.network';
  static const String processes = 'perf.processes';
  static const String device = 'perf.device';
  static const String start = 'perf.start';
  static const String stop = 'perf.stop';
  static const String status = 'perf.status';
  static const String history = 'perf.history';
  static const String reset = 'perf.reset';

  /// 解析第三方应用 dumpsys 文本（`pidof` / `cpuinfo` / `meminfo` / `gfxinfo`）。
  static const String parseAppDumps = 'perf.parse_app_dumps';

  /// 解析 `am start -W` 输出为启动耗时（冷 / 热启动）。
  static const String parseStartup = 'perf.parse_startup';

  /// 从 `dumpsys activity activities` 原文抽取当前前台包名（纯解析）。
  static const String foreground = 'perf.foreground';

  /// `/proc/pressure/*` PSI 压力（CPU / 内存 / IO 的 some/full）。
  static const String pressure = 'perf.pressure';

  /// `/sys/class/thermal/cooling_device*` 散热设备枚举。
  static const String cooling = 'perf.cooling';

  /// 可控面枚举（CPU cpufreq 策略簇 / cpuset / 热区 / 散热设备 / GPU；**只读**）。
  static const String tunables = 'perf.tunables';

  /// 白名单内**单个** sysfs / cpuset 节点读取（写回校验用；**只读**）。
  static const String sysfsRead = 'perf.sysfs.read';

  /// 电池健康深读（充电满电 / 设计容量 / 循环次数等；可为 `null`）。
  static const String batteryHealth = 'perf.battery_health';

  /// 存储卷用量（StatFs / `df`）。
  static const String storage = 'perf.storage';

  /// 全部方法名（顺序与 README 方法表一致）。
  static const List<String> all = <String>[
    ping,
    snapshot,
    cpu,
    memory,
    battery,
    thermal,
    gpu,
    network,
    processes,
    device,
    start,
    stop,
    status,
    history,
    reset,
    parseAppDumps,
    parseStartup,
    pressure,
    cooling,
    tunables,
    sysfsRead,
    batteryHealth,
    storage,
    foreground,
  ];
}

/// 模块事件名（`emit_event` 上报，宿主事件桥路由）。
class PerfEvents {
  const PerfEvents._();

  /// 采样事件：载荷即一次快照 JSON（`{ts_ms, cpu, memory, ...}`）。
  static const String sample = 'perf.sample';

  /// 全部事件名。
  static const List<String> all = <String>[sample];
}

// ==================== 顶层结果模型 ====================

/// `ping` 响应（README §方法 schema）。
class PerfPingResult {
  const PerfPingResult({
    required this.pong,
    required this.module,
    required this.moduleVersion,
    required this.apiVersion,
    required this.minHostAbi,
    required this.hostAbi,
    required this.samplerRunning,
    this.instanceId,
    this.sampleCount,
  });

  factory PerfPingResult.fromJson(Map<String, dynamic> json) => PerfPingResult(
        pong: json['pong'] == true,
        module: _asString(json['module'], fallback: 'perf'),
        moduleVersion: _asString(json['moduleVersion']),
        apiVersion: _asInt(json['apiVersion']),
        minHostAbi: _asInt(json['minHostAbi']),
        hostAbi: _asInt(json['hostAbi']),
        samplerRunning: json['samplerRunning'] == true,
        instanceId: _asIntOrNull(json['instanceId']),
        sampleCount: _asIntOrNull(json['sampleCount']),
      );

  /// 模块存活。
  final bool pong;

  /// 模块名（恒为 `perf`）。
  final String module;

  /// 模块版本。
  final String moduleVersion;

  /// 模块 API 版本。
  final int apiVersion;

  /// 模块要求的最低宿主 ABI。
  final int minHostAbi;

  /// 宿主实际 ABI。
  final int hostAbi;

  /// 采样器当前是否在运行（用于避免自动启动）。
  final bool samplerRunning;

  /// 实例 id（仅带实例调用时出现）。
  final int? instanceId;

  /// 采样环内当前样本数（仅带实例调用时出现）。
  final int? sampleCount;

  /// 宿主 ABI 是否满足模块要求。
  bool get hostCompatible => minHostAbi <= hostAbi;
}

/// `perf.start` 响应。
class PerfStartResult {
  const PerfStartResult({
    required this.running,
    required this.intervalMs,
    this.instanceId,
  });

  factory PerfStartResult.fromJson(Map<String, dynamic> json) =>
      PerfStartResult(
        running: json['running'] == true,
        intervalMs: _asInt(json['interval_ms']),
        instanceId: _asIntOrNull(json['instanceId']),
      );

  final bool running;
  final int intervalMs;
  final int? instanceId;
}

/// `perf.stop` 响应。
class PerfStopResult {
  const PerfStopResult({required this.running, required this.wasRunning});

  factory PerfStopResult.fromJson(Map<String, dynamic> json) => PerfStopResult(
        running: json['running'] == true,
        wasRunning: json['was_running'] == true,
      );

  final bool running;
  final bool wasRunning;
}

/// `perf.status` 响应。
class PerfSamplerStatus {
  const PerfSamplerStatus({
    required this.running,
    required this.runningCount,
    this.intervalMs,
    this.instanceId,
  });

  factory PerfSamplerStatus.fromJson(Map<String, dynamic> json) =>
      PerfSamplerStatus(
        running: json['running'] == true,
        runningCount: _asInt(json['running_count']),
        intervalMs: _asIntOrNull(json['interval_ms']),
        instanceId: _asIntOrNull(json['instanceId']),
      );

  final bool running;

  /// 当前运行的采样器线程数（`stop` 后应为 0）。
  final int runningCount;

  /// 采样间隔（ms；未运行时为 null）。
  final int? intervalMs;

  /// 正在采样的实例 id（未运行时为 null）。
  final int? instanceId;
}

/// `perf.reset` 响应。
class PerfResetResult {
  const PerfResetResult({required this.ok, required this.tsMs});

  factory PerfResetResult.fromJson(Map<String, dynamic> json) =>
      PerfResetResult(
        ok: json['ok'] == true,
        tsMs: _asInt(json['ts_ms']),
      );

  final bool ok;
  final int tsMs;
}

// ==================== 子报告模型 ====================

/// `/proc/loadavg` 负载。
class PerfLoadAvg {
  const PerfLoadAvg({
    this.load1 = 0,
    this.load5 = 0,
    this.load15 = 0,
    this.runnable = 0,
    this.total = 0,
    this.lastPid = 0,
  });

  factory PerfLoadAvg.fromJson(Map<String, dynamic> json) => PerfLoadAvg(
        load1: _asDouble(json['load1']),
        load5: _asDouble(json['load5']),
        load15: _asDouble(json['load15']),
        runnable: _asInt(json['runnable']),
        total: _asInt(json['total']),
        lastPid: _asInt(json['last_pid']),
      );

  final double load1;
  final double load5;
  final double load15;
  final int runnable;
  final int total;
  final int lastPid;
}

/// 单核信息（`cpu.cores[]`）。
class PerfCpuCore {
  const PerfCpuCore({required this.id, this.freqMhz});

  factory PerfCpuCore.fromJson(Map<String, dynamic> json) => PerfCpuCore(
        id: _asInt(json['id']),
        freqMhz: _asDoubleOrNull(json['freq_mhz']),
      );

  final int id;
  final double? freqMhz;
}

/// 单档频率驻留（`cpu.freq_residency[]`）：该频率累计活跃 tick 数。
class PerfFreqResidency {
  const PerfFreqResidency({this.freqMhz = 0, this.ticks = 0});

  factory PerfFreqResidency.fromJson(Map<String, dynamic> json) =>
      PerfFreqResidency(
        freqMhz: _asDouble(json['freq_mhz']),
        ticks: _asInt(json['ticks']),
      );

  /// 频率（MHz）。
  final double freqMhz;

  /// 该频率累计 tick 数（同一序列内占比即驻留比例）。
  final int ticks;
}

/// `perf.cpu` 响应。
class CpuReport {
  const CpuReport({
    this.usagePercent = 0,
    this.perCoreUsage = const <double>[],
    this.coreCount = 0,
    this.frequenciesMhz = const <double?>[],
    this.governor,
    this.availableFrequenciesMhz = const <double>[],
    this.maxFreqMhz,
    this.minFreqMhz,
    this.loadavg,
    this.cores = const <PerfCpuCore>[],
    this.availableGovernors = const <String>[],
    this.freqResidency = const <PerfFreqResidency>[],
  });

  factory CpuReport.fromJson(Map<String, dynamic> json) => CpuReport(
        usagePercent: _asDouble(json['usage_percent']),
        perCoreUsage: _doubleList(json['per_core_usage']),
        coreCount: _asInt(json['core_count']),
        frequenciesMhz: _nullableDoubleList(json['frequencies_mhz']),
        governor: _asStringOrNull(json['governor']),
        availableFrequenciesMhz: _doubleList(json['available_frequencies_mhz']),
        maxFreqMhz: _asDoubleOrNull(json['max_freq_mhz']),
        minFreqMhz: _asDoubleOrNull(json['min_freq_mhz']),
        loadavg: json['loadavg'] == null
            ? null
            : PerfLoadAvg.fromJson(_asMap(json['loadavg'])),
        cores: _objectList(json['cores'])
            .map(PerfCpuCore.fromJson)
            .toList(growable: false),
        availableGovernors: _stringList(json['available_governors']),
        freqResidency: _objectList(json['freq_residency'])
            .map(PerfFreqResidency.fromJson)
            .toList(growable: false),
      );

  final double usagePercent;
  final List<double> perCoreUsage;
  final int coreCount;

  /// 各核当前频率（MHz）；未知核为 `null`（Rust `Vec<Option<f64>>`）。
  final List<double?> frequenciesMhz;
  final String? governor;
  final List<double> availableFrequenciesMhz;
  final double? maxFreqMhz;
  final double? minFreqMhz;
  final PerfLoadAvg? loadavg;
  final List<PerfCpuCore> cores;

  /// 内核支持的全部调速器（`available_governors`）；缺失为空列表。
  final List<String> availableGovernors;

  /// 频率驻留分布（`freq_residency`）；缺失为空列表。
  final List<PerfFreqResidency> freqResidency;
}

/// `perf.memory` 响应（原始单位 KiB + 人类可读串）。
class MemoryReport {
  const MemoryReport({
    this.totalKb = 0,
    this.freeKb = 0,
    this.availableKb = 0,
    this.buffersKb = 0,
    this.cachedKb = 0,
    this.sreclaimableKb = 0,
    this.shmemKb = 0,
    this.slabKb = 0,
    this.usedKb = 0,
    this.usedPercent = 0,
    this.swapTotalKb = 0,
    this.swapFreeKb = 0,
    this.swapUsedKb = 0,
    this.swapPercent = 0,
    this.swapCachedKb = 0,
    this.dirtyKb = 0,
    this.zramTotalKb = 0,
    this.zramUsedKb = 0,
    this.totalHuman = '',
    this.usedHuman = '',
    this.availableHuman = '',
    this.swapTotalHuman = '',
    this.swapUsedHuman = '',
  });

  factory MemoryReport.fromJson(Map<String, dynamic> json) => MemoryReport(
        totalKb: _asInt(json['total_kb']),
        freeKb: _asInt(json['free_kb']),
        availableKb: _asInt(json['available_kb']),
        buffersKb: _asInt(json['buffers_kb']),
        cachedKb: _asInt(json['cached_kb']),
        sreclaimableKb: _asInt(json['sreclaimable_kb']),
        shmemKb: _asInt(json['shmem_kb']),
        slabKb: _asInt(json['slab_kb']),
        usedKb: _asInt(json['used_kb']),
        usedPercent: _asDouble(json['used_percent']),
        swapTotalKb: _asInt(json['swap_total_kb']),
        swapFreeKb: _asInt(json['swap_free_kb']),
        swapUsedKb: _asInt(json['swap_used_kb']),
        swapPercent: _asDouble(json['swap_percent']),
        swapCachedKb: _asInt(json['swap_cached_kb']),
        dirtyKb: _asInt(json['dirty_kb']),
        zramTotalKb: _asInt(json['zram_total_kb']),
        zramUsedKb: _asInt(json['zram_used_kb']),
        totalHuman: _asString(json['total_human']),
        usedHuman: _asString(json['used_human']),
        availableHuman: _asString(json['available_human']),
        swapTotalHuman: _asString(json['swap_total_human']),
        swapUsedHuman: _asString(json['swap_used_human']),
      );

  final int totalKb;
  final int freeKb;
  final int availableKb;
  final int buffersKb;
  final int cachedKb;
  final int sreclaimableKb;
  final int shmemKb;
  final int slabKb;
  final int usedKb;
  final double usedPercent;
  final int swapTotalKb;
  final int swapFreeKb;
  final int swapUsedKb;
  final double swapPercent;
  final int swapCachedKb;
  final int dirtyKb;
  final int zramTotalKb;
  final int zramUsedKb;
  final String totalHuman;
  final String usedHuman;
  final String availableHuman;
  final String swapTotalHuman;
  final String swapUsedHuman;
}

/// `perf.battery` 响应（无电池时 `present=false` 且其余为 `null`）。
class BatteryReport {
  const BatteryReport({
    this.present = false,
    this.basePath,
    this.capacityPercent,
    this.voltageV,
    this.currentMa,
    this.temperatureC,
    this.status,
    this.health,
    this.technology,
    this.chargeFullUah,
    this.chargeFullDesignUah,
    this.cycleCount,
  });

  factory BatteryReport.fromJson(Map<String, dynamic> json) => BatteryReport(
        present: json['present'] == true,
        basePath: _asStringOrNull(json['base_path']),
        capacityPercent: _asDoubleOrNull(json['capacity_percent']),
        voltageV: _asDoubleOrNull(json['voltage_v']),
        currentMa: _asDoubleOrNull(json['current_ma']),
        temperatureC: _asDoubleOrNull(json['temperature_c']),
        status: _asStringOrNull(json['status']),
        health: _asStringOrNull(json['health']),
        technology: _asStringOrNull(json['technology']),
        chargeFullUah: _asIntOrNull(json['charge_full_uah']),
        chargeFullDesignUah: _asIntOrNull(json['charge_full_design_uah']),
        cycleCount: _asIntOrNull(json['cycle_count']),
      );

  final bool present;
  final String? basePath;
  final double? capacityPercent;
  final double? voltageV;
  final double? currentMa;
  final double? temperatureC;
  final String? status;
  final String? health;
  final String? technology;
  final int? chargeFullUah;
  final int? chargeFullDesignUah;
  final int? cycleCount;
}

/// 单个热区读数。
class ThermalZone {
  const ThermalZone({
    this.source = '',
    this.zone = '',
    this.kind,
    this.tempC = 0,
  });

  factory ThermalZone.fromJson(Map<String, dynamic> json) => ThermalZone(
        source: _asString(json['source']),
        zone: _asString(json['zone']),
        kind: _asStringOrNull(json['kind']),
        tempC: _asDouble(json['temp_c']),
      );

  /// 来源：`thermal_zone` / `hwmon`。
  final String source;

  /// zone 标识（如 `thermal_zone0`）。
  final String zone;

  /// `type`（thermal）或 `name`（hwmon）。
  final String? kind;
  final double tempC;
}

/// `perf.thermal` 响应。
class ThermalReport {
  const ThermalReport({
    this.zoneCount = 0,
    this.maxTempC,
    this.zones = const <ThermalZone>[],
  });

  factory ThermalReport.fromJson(Map<String, dynamic> json) => ThermalReport(
        zoneCount: _asInt(json['zone_count']),
        maxTempC: _asDoubleOrNull(json['max_temp_c']),
        zones: _objectList(json['zones'])
            .map(ThermalZone.fromJson)
            .toList(growable: false),
      );

  final int zoneCount;
  final double? maxTempC;
  final List<ThermalZone> zones;
}

/// `perf.gpu` 响应（字段缺失为 `null`）。
class GpuReport {
  const GpuReport({
    this.name,
    this.freqMhz,
    this.freqSource,
    this.busyPercent,
    this.busySource,
  });

  factory GpuReport.fromJson(Map<String, dynamic> json) => GpuReport(
        name: _asStringOrNull(json['name']),
        freqMhz: _asDoubleOrNull(json['freq_mhz']),
        freqSource: _asStringOrNull(json['freq_source']),
        busyPercent: _asDoubleOrNull(json['busy_percent']),
        busySource: _asStringOrNull(json['busy_source']),
      );

  final String? name;
  final double? freqMhz;
  final String? freqSource;
  final double? busyPercent;
  final String? busySource;
}

/// 单接口速率（`network.interfaces[]`）。
class NetworkInterface {
  const NetworkInterface({
    this.name = '',
    this.rxBytes = 0,
    this.txBytes = 0,
    this.rxPackets = 0,
    this.txPackets = 0,
    this.rxBytesPerSec = 0,
    this.txBytesPerSec = 0,
    this.rxErrors = 0,
    this.txErrors = 0,
    this.rxDropped = 0,
    this.txDropped = 0,
    this.rxFifo = 0,
    this.txFifo = 0,
    this.rxFrame = 0,
    this.rxCompressed = 0,
    this.txCompressed = 0,
    this.multicast = 0,
  });

  factory NetworkInterface.fromJson(Map<String, dynamic> json) =>
      NetworkInterface(
        name: _asString(json['name']),
        rxBytes: _asInt(json['rx_bytes']),
        txBytes: _asInt(json['tx_bytes']),
        rxPackets: _asInt(json['rx_packets']),
        txPackets: _asInt(json['tx_packets']),
        rxBytesPerSec: _asDouble(json['rx_bytes_per_sec']),
        txBytesPerSec: _asDouble(json['tx_bytes_per_sec']),
        rxErrors: _asInt(json['rx_errors']),
        txErrors: _asInt(json['tx_errors']),
        rxDropped: _asInt(json['rx_dropped']),
        txDropped: _asInt(json['tx_dropped']),
        rxFifo: _asInt(json['rx_fifo']),
        txFifo: _asInt(json['tx_fifo']),
        rxFrame: _asInt(json['rx_frame']),
        rxCompressed: _asInt(json['rx_compressed']),
        txCompressed: _asInt(json['tx_compressed']),
        multicast: _asInt(json['multicast']),
      );

  final String name;
  final int rxBytes;
  final int txBytes;
  final int rxPackets;
  final int txPackets;
  final double rxBytesPerSec;
  final double txBytesPerSec;

  /// 接收 / 发送错误数。
  final int rxErrors;
  final int txErrors;

  /// 接收 / 发送丢包数。
  final int rxDropped;
  final int txDropped;

  /// FIFO 溢出计数。
  final int rxFifo;
  final int txFifo;

  /// 帧对齐错误（仅接收侧）。
  final int rxFrame;

  /// 压缩计数。
  final int rxCompressed;
  final int txCompressed;

  /// 组播计数。
  final int multicast;

  /// 该接口是否存在任意非零错误 / 丢包计数（供 UI 决定是否展示「网卡错误」）。
  bool get hasErrors =>
      rxErrors != 0 ||
      txErrors != 0 ||
      rxDropped != 0 ||
      txDropped != 0 ||
      rxFifo != 0 ||
      txFifo != 0 ||
      rxFrame != 0 ||
      rxCompressed != 0 ||
      txCompressed != 0;

  /// 错误 / 丢包合计（错误 + 丢包 + FIFO + 帧 + 压缩）。
  int get errorTotal =>
      rxErrors +
      txErrors +
      rxDropped +
      txDropped +
      rxFifo +
      txFifo +
      rxFrame +
      rxCompressed +
      txCompressed;
}

/// `perf.network` 响应（顶层为全部接口合计）。
class NetworkReport {
  const NetworkReport({
    this.rxBytes = 0,
    this.txBytes = 0,
    this.rxBytesPerSec = 0,
    this.txBytesPerSec = 0,
    this.interfaces = const <NetworkInterface>[],
  });

  factory NetworkReport.fromJson(Map<String, dynamic> json) => NetworkReport(
        rxBytes: _asInt(json['rx_bytes']),
        txBytes: _asInt(json['tx_bytes']),
        rxBytesPerSec: _asDouble(json['rx_bytes_per_sec']),
        txBytesPerSec: _asDouble(json['tx_bytes_per_sec']),
        interfaces: _objectList(json['interfaces'])
            .map(NetworkInterface.fromJson)
            .toList(growable: false),
      );

  final int rxBytes;
  final int txBytes;
  final double rxBytesPerSec;
  final double txBytesPerSec;
  final List<NetworkInterface> interfaces;
}

/// `perf.pressure` 单资源压力读数（`some` / `full`）。
///
/// 字段直接对应 `/proc/pressure/*` 的 `avg10` / `avg60` / `avg300`
/// （均为 %）；`total_us` 为累计 stall 微秒数。缺失字段宽容为 0。
class PerfPressureSample {
  const PerfPressureSample({
    this.avg10 = 0,
    this.avg60 = 0,
    this.avg300 = 0,
    this.totalUs = 0,
  });

  factory PerfPressureSample.fromJson(Map<String, dynamic> json) =>
      PerfPressureSample(
        avg10: _asDouble(json['avg10']),
        avg60: _asDouble(json['avg60']),
        avg300: _asDouble(json['avg300']),
        totalUs: _asInt(json['total_us']),
      );

  /// 10 秒平均 stall 占比（%）。
  final double avg10;

  /// 60 秒平均 stall 占比（%）。
  final double avg60;

  /// 300 秒平均 stall 占比（%）。
  final double avg300;

  /// 累计 stall 时长（微秒）。
  final int totalUs;
}

/// `perf.pressure` 响应：CPU / 内存 / IO 三类资源各自的 `some` / `full`。
///
/// 内核未开启 PSI（无 `/proc/pressure`）时对应字段为 `null`，UI 展示「不可用」。
class PerfPressureReport {
  const PerfPressureReport({
    this.cpuSome,
    this.cpuFull,
    this.memorySome,
    this.memoryFull,
    this.ioSome,
    this.ioFull,
  });

  factory PerfPressureReport.fromJson(Map<String, dynamic> json) =>
      PerfPressureReport(
        cpuSome: _pressureSample(json['cpu'], 'some'),
        cpuFull: _pressureSample(json['cpu'], 'full'),
        memorySome: _pressureSample(json['memory'], 'some'),
        memoryFull: _pressureSample(json['memory'], 'full'),
        ioSome: _pressureSample(json['io'], 'some'),
        ioFull: _pressureSample(json['io'], 'full'),
      );

  /// CPU `some`（部分任务被 stall）。
  final PerfPressureSample? cpuSome;

  /// CPU `full`（所有任务被 stall；部分内核不提供）。
  final PerfPressureSample? cpuFull;

  /// 内存 `some`。
  final PerfPressureSample? memorySome;

  /// 内存 `full`。
  final PerfPressureSample? memoryFull;

  /// IO `some`。
  final PerfPressureSample? ioSome;

  /// IO `full`。
  final PerfPressureSample? ioFull;
}

/// 单个散热设备（`cooling.devices[]`）。
class PerfCoolingDevice {
  const PerfCoolingDevice({
    this.device = '',
    this.type = '',
    this.curState = 0,
    this.maxState = 0,
  });

  factory PerfCoolingDevice.fromJson(Map<String, dynamic> json) =>
      PerfCoolingDevice(
        device: _asString(json['device']),
        type: _asString(json['type']),
        curState: _asInt(json['cur_state']),
        maxState: _asInt(json['max_state']),
      );

  /// 设备名（如 `cooling_device0`）。
  final String device;

  /// 设备类型（`type`，如 `cpu` / `battery`）。
  final String type;

  /// 当前散热状态档位。
  final int curState;

  /// 最大散热状态档位。
  final int maxState;
}

/// `perf.cooling` 响应。
class PerfCoolingReport {
  const PerfCoolingReport({
    this.count = 0,
    this.devices = const <PerfCoolingDevice>[],
  });

  factory PerfCoolingReport.fromJson(Map<String, dynamic> json) =>
      PerfCoolingReport(
        count: _asInt(json['count']),
        devices: _objectList(json['devices'])
            .map(PerfCoolingDevice.fromJson)
            .toList(growable: false),
      );

  /// 散热设备数量。
  final int count;

  /// 散热设备列表。
  final List<PerfCoolingDevice> devices;
}

/// 单个 cpufreq 策略簇（`tunables.cpu_clusters[]`）。
///
/// 对应 Rust `collectors::tunables::CpuCluster`：字段缺失 / `null` 一律宽容为
/// 空列表 / `null`（节点缺失是预期状态，绝不抛错）。
class PerfCpuCluster {
  const PerfCpuCluster({
    this.policy = '',
    this.relatedCpus = const <int>[],
    this.availableGovernors = const <String>[],
    this.governor,
    this.availableFrequenciesMhz = const <double>[],
    this.minFreqMhz,
    this.maxFreqMhz,
  });

  factory PerfCpuCluster.fromJson(Map<String, dynamic> json) => PerfCpuCluster(
        policy: _asString(json['policy']),
        relatedCpus: _intList(json['related_cpus']),
        availableGovernors: _stringList(json['available_governors']),
        governor: _asStringOrNull(json['governor']),
        availableFrequenciesMhz: _finiteDoubleList(
          json['available_frequencies_mhz'],
        ),
        minFreqMhz: _finiteDoubleOrNull(json['min_freq_mhz']),
        maxFreqMhz: _finiteDoubleOrNull(json['max_freq_mhz']),
      );

  /// 策略目录名（如 `policy0`）。
  final String policy;

  /// `related_cpus` 展开后的核编号（升序去重）。
  final List<int> relatedCpus;

  /// `scaling_available_governors`（有序）。
  final List<String> availableGovernors;

  /// 当前 `scaling_governor`。
  final String? governor;

  /// `scaling_available_frequencies` → MHz（去重升序）。
  final List<double> availableFrequenciesMhz;

  /// 当前下限（`scaling_min_freq`，回退 `cpuinfo_min_freq`）→ MHz。
  final double? minFreqMhz;

  /// 当前上限（`scaling_max_freq`，回退 `cpuinfo_max_freq`）→ MHz。
  final double? maxFreqMhz;
}

/// 单个 cpuset（`tunables.cpusets[]`，如 `top-app` / `foreground`）。
class PerfCpuset {
  const PerfCpuset({this.name = '', this.cpus, this.mems});

  factory PerfCpuset.fromJson(Map<String, dynamic> json) => PerfCpuset(
        name: _asString(json['name']),
        cpus: _asStringOrNull(json['cpus']),
        mems: _asStringOrNull(json['mems']),
      );

  /// cpuset 名称。
  final String name;

  /// `cpus`（原始字符串，如 `0-7`）。
  final String? cpus;

  /// `mems`（原始字符串，如 `0`）。
  final String? mems;
}

/// 单个热区的可控面（`tunables.thermal_zones[]`；`type` + 可写 `mode`）。
class PerfThermalTunable {
  const PerfThermalTunable({this.zone = '', this.type, this.mode});

  factory PerfThermalTunable.fromJson(Map<String, dynamic> json) =>
      PerfThermalTunable(
        zone: _asString(json['zone']),
        type: _asStringOrNull(json['type']),
        mode: _asStringOrNull(json['mode']),
      );

  /// zone 标识（如 `thermal_zone0`）。
  final String zone;

  /// `type`（如 `cpu-0-0-0`）。
  final String? type;

  /// 可写 `mode`（如 `enabled` / `disabled` / `step_wise`）。
  final String? mode;
}

/// 单个散热设备的可控面（`tunables.cooling_devices[]`）。
class PerfCoolingTunable {
  const PerfCoolingTunable({
    this.device = '',
    this.type,
    this.curState,
    this.maxState,
  });

  factory PerfCoolingTunable.fromJson(Map<String, dynamic> json) =>
      PerfCoolingTunable(
        device: _asString(json['device']),
        type: _asStringOrNull(json['type']),
        curState: _asIntOrNull(json['cur_state']),
        maxState: _asIntOrNull(json['max_state']),
      );

  /// 设备名（如 `cooling_device0`）。
  final String device;

  /// 设备类型（`type`）。
  final String? type;

  /// 当前散热状态档位。
  final int? curState;

  /// 最大散热状态档位。
  final int? maxState;
}

/// GPU 可控面（`tunables.gpu`；字段缺失为 `null`）。
class PerfGpuTunables {
  const PerfGpuTunables({
    this.availableFrequenciesMhz = const <double>[],
    this.freqSource,
    this.governor,
    this.governorSource,
    this.powerLevels,
    this.powerSource,
  });

  factory PerfGpuTunables.fromJson(Map<String, dynamic> json) =>
      PerfGpuTunables(
        availableFrequenciesMhz: _finiteDoubleList(
          json['available_frequencies_mhz'],
        ),
        freqSource: _asStringOrNull(json['freq_source']),
        governor: _asStringOrNull(json['governor']),
        governorSource: _asStringOrNull(json['governor_source']),
        powerLevels: _asIntOrNull(json['power_levels']),
        powerSource: _asStringOrNull(json['power_source']),
      );

  /// GPU 可用频率（MHz，去重升序）。
  final List<double> availableFrequenciesMhz;

  /// 频率来源路径（命中哪条路径表）。
  final String? freqSource;

  /// 当前 GPU governor。
  final String? governor;

  /// governor 来源路径。
  final String? governorSource;

  /// 功耗档位数（`num_pwrlevels`）。
  final int? powerLevels;

  /// 功耗档位来源路径。
  final String? powerSource;
}

/// `perf.tunables` 响应（**只读**可控面枚举）。
///
/// 节点缺失时各数组为空、[gpu] 各字段为 `null`（预期状态，绝不报错）；
/// 用于 Wave 4 的动作校验与能力探测。
class TunablesReport {
  const TunablesReport({
    this.cpuClusters = const <PerfCpuCluster>[],
    this.cpusets = const <PerfCpuset>[],
    this.thermalZones = const <PerfThermalTunable>[],
    this.coolingDevices = const <PerfCoolingTunable>[],
    this.gpu = const PerfGpuTunables(),
  });

  factory TunablesReport.fromJson(Map<String, dynamic> json) => TunablesReport(
        cpuClusters: _objectList(json['cpu_clusters'])
            .map(PerfCpuCluster.fromJson)
            .toList(growable: false),
        cpusets: _objectList(json['cpusets'])
            .map(PerfCpuset.fromJson)
            .toList(growable: false),
        thermalZones: _objectList(json['thermal_zones'])
            .map(PerfThermalTunable.fromJson)
            .toList(growable: false),
        coolingDevices: _objectList(json['cooling_devices'])
            .map(PerfCoolingTunable.fromJson)
            .toList(growable: false),
        gpu: json['gpu'] == null
            ? const PerfGpuTunables()
            : PerfGpuTunables.fromJson(_asMap(json['gpu'])),
      );

  /// CPU cpufreq 策略簇。
  final List<PerfCpuCluster> cpuClusters;

  /// cpuset 列表。
  final List<PerfCpuset> cpusets;

  /// 热区可控面。
  final List<PerfThermalTunable> thermalZones;

  /// 散热设备可控面。
  final List<PerfCoolingTunable> coolingDevices;

  /// GPU 可控面。
  final PerfGpuTunables gpu;
}

/// `perf.sysfs.read` 响应：白名单内**单个**节点读取结果。
///
/// 节点不存在 / 不可读 / 内容为空时 [value] 为 `null`；[exists] 表示是否可读
/// （存在但内容为空仍为 `true`）。非白名单路径不会走到这里（Rust 侧返回结构化
/// `invalid_arg`）。
class SysfsReadResult {
  const SysfsReadResult({this.path = '', this.value, this.exists = false});

  factory SysfsReadResult.fromJson(Map<String, dynamic> json) =>
      SysfsReadResult(
        path: _asString(json['path']),
        value: _asStringOrNull(json['value']),
        exists: json['exists'] == true,
      );

  /// 读取的绝对路径（回显请求）。
  final String path;

  /// 文件内容（去首尾空白）；不存在 / 不可读 / 空 → `null`。
  final String? value;

  /// 文件是否存在且可读（存在但内容为空仍为 `true`）。
  final bool exists;
}

/// `perf.foreground` 响应：当前前台包名（无法判定时为 `null`）。
///
/// 从 `dumpsys activity activities` 的 resumed 行（`mResumedActivity` /
/// `topResumedActivity` / `ResumedActivity`）抽取；无 resumed 行 / 多窗口歧义 →
/// [package] 为 `null`（**绝不报错、绝不猜测**）。
class ForegroundReport {
  const ForegroundReport({this.package});

  factory ForegroundReport.fromJson(Map<String, dynamic> json) =>
      ForegroundReport(package: _asStringOrNull(json['package']));

  /// 当前前台包名；无法判定时为 `null`。
  final String? package;
}

/// `perf.battery_health` 响应（无电池 / 无 sysfs 数据时 `present=false` 且字段为 null）。
class PerfBatteryHealthReport {
  const PerfBatteryHealthReport({
    this.present = false,
    this.basePath,
    this.chargeFullUah,
    this.chargeFullDesignUah,
    this.cycleCount,
    this.health,
    this.status,
    this.technology,
    this.chargeCounterUah,
    this.capacityPercent,
    this.voltageV,
    this.temperatureC,
  });

  factory PerfBatteryHealthReport.fromJson(Map<String, dynamic> json) =>
      PerfBatteryHealthReport(
        present: json['present'] == true,
        basePath: _asStringOrNull(json['base_path']),
        chargeFullUah: _asIntOrNull(json['charge_full_uah']),
        chargeFullDesignUah: _asIntOrNull(json['charge_full_design_uah']),
        cycleCount: _asIntOrNull(json['cycle_count']),
        health: _asStringOrNull(json['health']),
        status: _asStringOrNull(json['status']),
        technology: _asStringOrNull(json['technology']),
        chargeCounterUah: _asIntOrNull(json['charge_counter_uah']),
        capacityPercent: _asDoubleOrNull(json['capacity_percent']),
        voltageV: _asDoubleOrNull(json['voltage_v']),
        temperatureC: _asDoubleOrNull(json['temperature_c']),
      );

  /// 是否检测到电池。
  final bool present;

  /// sysfs 基路径。
  final String? basePath;

  /// 当前满电容量（µAh）。
  final int? chargeFullUah;

  /// 出厂设计容量（µAh）。
  final int? chargeFullDesignUah;

  /// 循环次数。
  final int? cycleCount;

  /// 健康度（`Good` / `Overheat` …）。
  final String? health;

  /// 状态（`Charging` / `Discharging` …）。
  final String? status;

  /// 材质（`Li-ion` …）。
  final String? technology;

  /// 剩余电量计（µAh）。
  final int? chargeCounterUah;

  /// 电量百分比（0..100）。
  final double? capacityPercent;

  /// 电压（V）。
  final double? voltageV;

  /// 温度（°C）。
  final double? temperatureC;

  /// 健康度（满电容量 / 设计容量 × 100，%）；任一缺失或设计为 0 时返回 `null`。
  double? get healthPercent {
    final full = chargeFullUah;
    final design = chargeFullDesignUah;
    if (full == null || design == null || design <= 0) return null;
    return full / design * 100;
  }
}

/// 单个存储卷（`storage.volumes[]`）。
class PerfStorageVolume {
  const PerfStorageVolume({
    this.mount = '',
    this.fs = '',
    this.totalKb = 0,
    this.freeKb = 0,
    this.usedKb = 0,
    this.usedPercent = 0,
  });

  factory PerfStorageVolume.fromJson(Map<String, dynamic> json) =>
      PerfStorageVolume(
        mount: _asString(json['mount']),
        fs: _asString(json['fs']),
        totalKb: _asInt(json['total_kb']),
        freeKb: _asInt(json['free_kb']),
        usedKb: _asInt(json['used_kb']),
        usedPercent: _asDouble(json['used_percent']),
      );

  /// 挂载点（如 `/data`）。
  final String mount;

  /// 文件系统类型（如 `ext4` / `f2fs`）。
  final String fs;

  /// 总容量（KiB）。
  final int totalKb;

  /// 可用容量（KiB）。
  final int freeKb;

  /// 已用容量（KiB）。
  final int usedKb;

  /// 已用比例（%）。
  final double usedPercent;
}

/// `perf.storage` 响应。
class PerfStorageReport {
  const PerfStorageReport({this.volumes = const <PerfStorageVolume>[]});

  factory PerfStorageReport.fromJson(Map<String, dynamic> json) =>
      PerfStorageReport(
        volumes: _objectList(json['volumes'])
            .map(PerfStorageVolume.fromJson)
            .toList(growable: false),
      );

  /// 存储卷列表。
  final List<PerfStorageVolume> volumes;
}

/// 单个进程（`processes.processes[]`）。
///
/// 同时被系统级 [`perf.processes`] 与第三方 [`perf.parse_app_dumps`] 的
/// `processes[]` 复用：后者只填 [pid] / [ppid] / [rssKb] / [name]，其余字段
/// 缺失时按默认值宽容解码（[ppid] 为 `null`）。
class PerfProcessInfo {
  const PerfProcessInfo({
    this.pid = 0,
    this.ppid,
    this.name = '',
    this.cmdline,
    this.state = '',
    this.cpuTicks = 0,
    this.cpuPercent = 0,
    this.rssKb = 0,
    this.rssBytes = 0,
  });

  factory PerfProcessInfo.fromJson(Map<String, dynamic> json) =>
      PerfProcessInfo(
        pid: _asInt(json['pid']),
        ppid: _asIntOrNull(json['ppid']),
        name: _asString(json['name']),
        cmdline: _asStringOrNull(json['cmdline']),
        state: _asString(json['state']),
        cpuTicks: _asInt(json['cpu_ticks']),
        cpuPercent: _asDouble(json['cpu_percent']),
        rssKb: _asInt(json['rss_kb']),
        rssBytes: _asInt(json['rss_bytes']),
      );

  final int pid;

  /// 父进程 id（`parse_app_dumps` 提供；系统 `perf.processes` 无则为 `null`）。
  final int? ppid;
  final String name;
  final String? cmdline;
  final String state;
  final int cpuTicks;
  final double cpuPercent;
  final int rssKb;
  final int rssBytes;
}

/// `perf.processes` 响应。
class ProcessReport {
  const ProcessReport({
    this.total = 0,
    this.sort = 'cpu',
    this.processes = const <PerfProcessInfo>[],
  });

  factory ProcessReport.fromJson(Map<String, dynamic> json) => ProcessReport(
        total: _asInt(json['total']),
        sort: _asString(json['sort'], fallback: 'cpu'),
        processes: _objectList(json['processes'])
            .map(PerfProcessInfo.fromJson)
            .toList(growable: false),
      );

  final int total;

  /// 排序维度：`cpu` / `rss`。
  final String sort;
  final List<PerfProcessInfo> processes;
}

/// `perf.device` 响应（缺省字段为 `null`）。
class DeviceReport {
  const DeviceReport({
    this.kernelVersion,
    this.hardware,
    this.cpuName,
    this.model,
    this.androidRelease,
    this.boardPlatform,
    this.coreCount = 0,
    this.loadavg,
    this.osRelease,
  });

  factory DeviceReport.fromJson(Map<String, dynamic> json) => DeviceReport(
        kernelVersion: _asStringOrNull(json['kernel_version']),
        hardware: _asStringOrNull(json['hardware']),
        cpuName: _asStringOrNull(json['cpu_name']),
        model: _asStringOrNull(json['model']),
        androidRelease: _asStringOrNull(json['android_release']),
        boardPlatform: _asStringOrNull(json['board_platform']),
        coreCount: _asInt(json['core_count']),
        loadavg: json['loadavg'] == null
            ? null
            : PerfLoadAvg.fromJson(_asMap(json['loadavg'])),
        osRelease: _asStringOrNull(json['os_release']),
      );

  final String? kernelVersion;
  final String? hardware;
  final String? cpuName;
  final String? model;
  final String? androidRelease;
  final String? boardPlatform;
  final int coreCount;
  final PerfLoadAvg? loadavg;
  final String? osRelease;
}

/// `dumpsys meminfo` App Summary：第三方应用内存细分（全部 KiB，可空）。
class PerfMemSummary {
  const PerfMemSummary({
    this.javaHeapKb,
    this.nativeHeapKb,
    this.codeKb,
    this.stackKb,
    this.graphicsKb,
    this.privateOtherKb,
    this.systemKb,
    this.totalPssKb,
  });

  factory PerfMemSummary.fromJson(Map<String, dynamic> json) => PerfMemSummary(
        javaHeapKb: _asIntOrNull(json['java_heap_kb']),
        nativeHeapKb: _asIntOrNull(json['native_heap_kb']),
        codeKb: _asIntOrNull(json['code_kb']),
        stackKb: _asIntOrNull(json['stack_kb']),
        graphicsKb: _asIntOrNull(json['graphics_kb']),
        privateOtherKb: _asIntOrNull(json['private_other_kb']),
        systemKb: _asIntOrNull(json['system_kb']),
        totalPssKb: _asIntOrNull(json['total_pss_kb']),
      );

  /// Java 堆（KiB）。
  final int? javaHeapKb;

  /// Native 堆（KiB）。
  final int? nativeHeapKb;

  /// 代码（KiB）。
  final int? codeKb;

  /// 栈（KiB）。
  final int? stackKb;

  /// 图形（KiB）。
  final int? graphicsKb;

  /// 私有其他（KiB）。
  final int? privateOtherKb;

  /// 系统（KiB）。
  final int? systemKb;

  /// 合计 PSS（KiB）。
  final int? totalPssKb;
}

/// `dumpsys netstats detail`：第三方应用按 uid 聚合的网络计数器（可空）。
///
/// 部分 ROM / 无 `netstats` 数据时整体为 `null`（[ThirdPartyAppMetrics.net]）；
/// [rxBytes] / [txBytes] 为**累计**字节数，速率由 Dart 侧按两次采样差值推导。
class PerfNetCounters {
  const PerfNetCounters({this.uid, this.rxBytes, this.txBytes});

  factory PerfNetCounters.fromJson(Map<String, dynamic> json) => PerfNetCounters(
        uid: _asIntOrNull(json['uid']),
        rxBytes: _asIntOrNull(json['rx_bytes']),
        txBytes: _asIntOrNull(json['tx_bytes']),
      );

  /// 归属 uid。
  final int? uid;

  /// 累计接收字节数。
  final int? rxBytes;

  /// 累计发送字节数。
  final int? txBytes;
}

/// `dumpsys gfxinfo <pkg> framestats`：逐帧渲染耗时细分（全部可空）。
///
/// 来自 [PerfMethods.parseAppDumps] 的 `render` 字段；部分 ROM / 无 framestats
/// 数据时整体为 `null`（[ThirdPartyAppMetrics.render]）。所有字段宽容解码。
class PerfRenderBreakdown {
  const PerfRenderBreakdown({
    this.frameCount,
    this.fps,
    this.jankCount,
    this.avgTotalMs,
    this.p50TotalMs,
    this.p90TotalMs,
    this.p99TotalMs,
    this.avgUiMs,
    this.avgDrawMs,
    this.avgGpuMs,
  });

  factory PerfRenderBreakdown.fromJson(Map<String, dynamic> json) =>
      PerfRenderBreakdown(
        frameCount: _asIntOrNull(json['frame_count']),
        fps: _asDoubleOrNull(json['fps']),
        jankCount: _asIntOrNull(json['jank_count']),
        avgTotalMs: _asDoubleOrNull(json['avg_total_ms']),
        p50TotalMs: _asDoubleOrNull(json['p50_total_ms']),
        p90TotalMs: _asDoubleOrNull(json['p90_total_ms']),
        p99TotalMs: _asDoubleOrNull(json['p99_total_ms']),
        avgUiMs: _asDoubleOrNull(json['avg_ui_ms']),
        avgDrawMs: _asDoubleOrNull(json['avg_draw_ms']),
        avgGpuMs: _asDoubleOrNull(json['avg_gpu_ms']),
      );

  /// 统计窗口内的帧数。
  final int? frameCount;

  /// 交付帧率（fps）。
  final double? fps;

  /// 卡顿帧数。
  final int? jankCount;

  /// 平均总耗时（ms）。
  final double? avgTotalMs;

  /// P50 总耗时（ms）。
  final double? p50TotalMs;

  /// P90 总耗时（ms）。
  final double? p90TotalMs;

  /// P99 总耗时（ms）。
  final double? p99TotalMs;

  /// UI 阶段平均耗时（ms）。
  final double? avgUiMs;

  /// Draw 阶段平均耗时（ms）。
  final double? avgDrawMs;

  /// GPU 阶段平均耗时（ms）。
  final double? avgGpuMs;
}

/// `dumpsys batterystats --charged <pkg>`：应用耗电 / 唤醒归因（全部可空）。
///
/// 来自 [PerfMethods.parseAppDumps] 的 `power` 字段；无电池统计 /
/// batterystats 不可用时整体为 `null`（[ThirdPartyAppMetrics.power]）。
class PerfPowerAttribution {
  const PerfPowerAttribution({
    this.mah,
    this.wakeLockMs,
    this.mobileRadioMah,
    this.wifiMah,
    this.screenMah,
    this.cpuMah,
  });

  factory PerfPowerAttribution.fromJson(Map<String, dynamic> json) =>
      PerfPowerAttribution(
        mah: _asDoubleOrNull(json['mah']),
        wakeLockMs: _asIntOrNull(json['wake_lock_ms']),
        mobileRadioMah: _asDoubleOrNull(json['mobile_radio_mah']),
        wifiMah: _asDoubleOrNull(json['wifi_mah']),
        screenMah: _asDoubleOrNull(json['screen_mah']),
        cpuMah: _asDoubleOrNull(json['cpu_mah']),
      );

  /// 估算总耗电（mAh）。
  final double? mah;

  /// 唤醒锁持有时长（ms）。
  final int? wakeLockMs;

  /// 移动网络耗电（mAh）。
  final double? mobileRadioMah;

  /// Wifi 耗电（mAh）。
  final double? wifiMah;

  /// 屏幕耗电（mAh）。
  final double? screenMah;

  /// CPU 耗电（mAh）。
  final double? cpuMah;
}

/// `dumpsys package <pkg>`：应用包信息（全部字段可空 / 宽容解码）。
///
/// 来自 [PerfMethods.parseAppDumps] 的 `app_info` 字段；`dumpsys package` 不可用
/// 时整体为 `null`（[ThirdPartyAppMetrics.appInfo]）。
class PerfAppInfo {
  const PerfAppInfo({
    this.versionName,
    this.versionCode,
    this.targetSdk,
    this.minSdk,
    this.firstInstall,
    this.lastUpdate,
    this.codePath,
    this.dataDir,
    this.isSystem = false,
    this.enabled = false,
    this.requestedPermissions = const <String>[],
    this.grantedPermissions = const <String>[],
    this.activityCount = 0,
    this.serviceCount = 0,
    this.receiverCount = 0,
    this.providerCount = 0,
  });

  factory PerfAppInfo.fromJson(Map<String, dynamic> json) => PerfAppInfo(
        versionName: _asStringOrNull(json['version_name']),
        versionCode: _asIntOrNull(json['version_code']),
        targetSdk: _asIntOrNull(json['target_sdk']),
        minSdk: _asIntOrNull(json['min_sdk']),
        firstInstall: _asStringOrNull(json['first_install']),
        lastUpdate: _asStringOrNull(json['last_update']),
        codePath: _asStringOrNull(json['code_path']),
        dataDir: _asStringOrNull(json['data_dir']),
        isSystem: json['is_system'] == true,
        enabled: json['enabled'] == true,
        requestedPermissions: _stringList(json['requested_permissions']),
        grantedPermissions: _stringList(json['granted_permissions']),
        activityCount: _asInt(json['activity_count']),
        serviceCount: _asInt(json['service_count']),
        receiverCount: _asInt(json['receiver_count']),
        providerCount: _asInt(json['provider_count']),
      );

  /// 版本名（如 `9.1`）。
  final String? versionName;

  /// 版本号（`versionCode`）。
  final int? versionCode;

  /// targetSdkVersion。
  final int? targetSdk;

  /// minSdkVersion。
  final int? minSdk;

  /// 首次安装时间（展示串，原样透传）。
  final String? firstInstall;

  /// 最近更新时间（展示串，原样透传）。
  final String? lastUpdate;

  /// APK 代码路径。
  final String? codePath;

  /// 数据目录。
  final String? dataDir;

  /// 是否系统应用。
  final bool isSystem;

  /// 是否已启用。
  final bool enabled;

  /// 申请的全部权限。
  final List<String> requestedPermissions;

  /// 已授予的权限。
  final List<String> grantedPermissions;

  /// Activity 数量。
  final int activityCount;

  /// Service 数量。
  final int serviceCount;

  /// BroadcastReceiver 数量。
  final int receiverCount;

  /// ContentProvider 数量。
  final int providerCount;

  /// 已授予权限数 / 申请权限数（申请为 0 时返回 `null`）。
  double? get grantRatio {
    final requested = requestedPermissions.length;
    if (requested <= 0) return null;
    return grantedPermissions.length / requested;
  }
}

/// `/proc/<pid>/smaps_rollup`（多进程拼接）：精确内存占用（全部 KiB，可空）。
///
/// 来自 [PerfMethods.parseAppDumps] 的 `smaps` 字段；无法读取（无 pid / SELinux
/// 拒绝）时整体为 `null`（[ThirdPartyAppMetrics.smaps]）。
class PerfSmaps {
  const PerfSmaps({
    this.pssKb,
    this.rssKb,
    this.sharedCleanKb,
    this.sharedDirtyKb,
    this.privateCleanKb,
    this.privateDirtyKb,
  });

  factory PerfSmaps.fromJson(Map<String, dynamic> json) => PerfSmaps(
        pssKb: _asIntOrNull(json['pss_kb']),
        rssKb: _asIntOrNull(json['rss_kb']),
        sharedCleanKb: _asIntOrNull(json['shared_clean_kb']),
        sharedDirtyKb: _asIntOrNull(json['shared_dirty_kb']),
        privateCleanKb: _asIntOrNull(json['private_clean_kb']),
        privateDirtyKb: _asIntOrNull(json['private_dirty_kb']),
      );

  /// 比例内存 PSS（KiB）。
  final int? pssKb;

  /// 常驻内存 RSS（KiB）。
  final int? rssKb;

  /// 共享干净页（KiB）。
  final int? sharedCleanKb;

  /// 共享脏页（KiB）。
  final int? sharedDirtyKb;

  /// 私有干净页（KiB）。
  final int? privateCleanKb;

  /// 私有脏页（KiB）。
  final int? privateDirtyKb;

  /// 共享合计（clean + dirty，KiB）；两者皆缺时为 `null`。
  int? get sharedKb {
    final clean = sharedCleanKb;
    final dirty = sharedDirtyKb;
    if (clean == null && dirty == null) return null;
    return (clean ?? 0) + (dirty ?? 0);
  }

  /// 私有合计（clean + dirty，KiB）；两者皆缺时为 `null`。
  int? get privateKb {
    final clean = privateCleanKb;
    final dirty = privateDirtyKb;
    if (clean == null && dirty == null) return null;
    return (clean ?? 0) + (dirty ?? 0);
  }
}

/// 单条崩溃 / ANR 记录（`crashes.recent[]`）。
class PerfCrashEntry {
  const PerfCrashEntry({this.kind, this.time, this.summary});

  factory PerfCrashEntry.fromJson(Map<String, dynamic> json) => PerfCrashEntry(
        kind: _asStringOrNull(json['kind']),
        time: _asStringOrNull(json['time']),
        summary: _asStringOrNull(json['summary']),
      );

  /// 类型（`crash` / `anr`）。
  final String? kind;

  /// 发生时间（展示串，原样透传）。
  final String? time;

  /// 摘要（首行 / 异常类型）。
  final String? summary;
}

/// `dumpsys dropbox`：崩溃 / ANR 汇总（计数 + 最近时间 + 近期记录）。
///
/// 来自 [PerfMethods.parseAppDumps] 的 `crashes` 字段；dropbox 不可用时整体为
/// `null`（[ThirdPartyAppMetrics.crashes]）。
class PerfCrashReport {
  const PerfCrashReport({
    this.crashCount = 0,
    this.anrCount = 0,
    this.lastCrash,
    this.lastAnr,
    this.recent = const <PerfCrashEntry>[],
  });

  factory PerfCrashReport.fromJson(Map<String, dynamic> json) =>
      PerfCrashReport(
        crashCount: _asInt(json['crash_count']),
        anrCount: _asInt(json['anr_count']),
        lastCrash: _asStringOrNull(json['last_crash']),
        lastAnr: _asStringOrNull(json['last_anr']),
        recent: _objectList(json['recent'])
            .map(PerfCrashEntry.fromJson)
            .toList(growable: false),
      );

  /// 崩溃次数。
  final int crashCount;

  /// ANR 次数。
  final int anrCount;

  /// 最近一次崩溃时间（展示串）。
  final String? lastCrash;

  /// 最近一次 ANR 时间（展示串）。
  final String? lastAnr;

  /// 近期记录（Rust 侧已截断；UI 再取前 5）。
  final List<PerfCrashEntry> recent;
}

/// `dumpsys activity activities`：目标应用是否处于前台。
///
/// 来自 [PerfMethods.parseAppDumps] 的 `foreground` 字段；解析不到时整体为
/// `null`（[ThirdPartyAppMetrics.foreground]）。
class PerfForeground {
  const PerfForeground({this.isForeground = false});

  factory PerfForeground.fromJson(Map<String, dynamic> json) =>
      PerfForeground(isForeground: json['is_foreground'] == true);

  /// 是否前台。
  final bool isForeground;
}

/// 单条唤醒锁（`wake_locks[]`）。
class PerfWakeLock {
  const PerfWakeLock({this.name, this.ms});

  factory PerfWakeLock.fromJson(Map<String, dynamic> json) => PerfWakeLock(
        name: _asStringOrNull(json['name']),
        ms: _asIntOrNull(json['ms']),
      );

  /// 唤醒锁名称。
  final String? name;

  /// 持有时长（ms）。
  final int? ms;
}

/// `perf.parse_app_dumps` 响应：第三方应用的 dumpsys 解析结果。
///
/// 数值字段可能为 `null`（应用未运行 / 解析不到对应指标），一律**宽容解码**，
/// 绝不抛裸异常（与其它契约模型一致）。
///
/// [fps] / [rxBytesPerSec] / [txBytesPerSec] **不由 Rust 返回**：它们是 Dart 侧
/// 按两次采样差值推导的交付帧率与网络速率，故 [fromJson] 不会填充，需由调用方
/// 经 [withFps] 附加。
class ThirdPartyAppMetrics {
  const ThirdPartyAppMetrics({
    this.package = '',
    this.pid,
    this.uid,
    this.running = false,
    this.threads,
    this.cpuPercent,
    this.memPssKb,
    this.memRssKb,
    this.memJavaHeapKb,
    this.memNativeHeapKb,
    this.memPrivateDirtyKb,
    this.memSummary,
    this.processes = const <PerfProcessInfo>[],
    this.net,
    this.render,
    this.power,
    this.appInfo,
    this.smaps,
    this.crashes,
    this.foreground,
    this.wakeLocks = const <PerfWakeLock>[],
    this.frameCount,
    this.jankyFrames,
    this.jankyPercent,
    this.p50Ms,
    this.p90Ms,
    this.p95Ms,
    this.p99Ms,
    this.missedVsync,
    this.highInputLatency,
    this.slowUiThread,
    this.slowBitmapUploads,
    this.slowDraw,
    this.fps,
    this.rxBytesPerSec,
    this.txBytesPerSec,
  });

  factory ThirdPartyAppMetrics.fromJson(Map<String, dynamic> json) =>
      ThirdPartyAppMetrics(
        package: _asString(json['package']),
        pid: _asIntOrNull(json['pid']),
        uid: _asIntOrNull(json['uid']),
        running: json['running'] == true,
        threads: _asIntOrNull(json['threads']),
        cpuPercent: _asDoubleOrNull(json['cpu_percent']),
        memPssKb: _asIntOrNull(json['mem_pss_kb']),
        memRssKb: _asIntOrNull(json['mem_rss_kb']),
        memJavaHeapKb: _asIntOrNull(json['mem_java_heap_kb']),
        memNativeHeapKb: _asIntOrNull(json['mem_native_heap_kb']),
        memPrivateDirtyKb: _asIntOrNull(json['mem_private_dirty_kb']),
        memSummary: json['mem_summary'] == null
            ? null
            : PerfMemSummary.fromJson(_asMap(json['mem_summary'])),
        processes: _objectList(json['processes'])
            .map(PerfProcessInfo.fromJson)
            .toList(growable: false),
        net: json['net'] == null
            ? null
            : PerfNetCounters.fromJson(_asMap(json['net'])),
        render: json['render'] == null
            ? null
            : PerfRenderBreakdown.fromJson(_asMap(json['render'])),
        power: json['power'] == null
            ? null
            : PerfPowerAttribution.fromJson(_asMap(json['power'])),
        appInfo: json['app_info'] == null
            ? null
            : PerfAppInfo.fromJson(_asMap(json['app_info'])),
        smaps: json['smaps'] == null
            ? null
            : PerfSmaps.fromJson(_asMap(json['smaps'])),
        crashes: json['crashes'] == null
            ? null
            : PerfCrashReport.fromJson(_asMap(json['crashes'])),
        foreground: json['foreground'] == null
            ? null
            : PerfForeground.fromJson(_asMap(json['foreground'])),
        wakeLocks: _objectList(json['wake_locks'])
            .map(PerfWakeLock.fromJson)
            .toList(growable: false),
        frameCount: _asIntOrNull(json['frame_count']),
        jankyFrames: _asIntOrNull(json['janky_frames']),
        jankyPercent: _asDoubleOrNull(json['janky_percent']),
        p50Ms: _asDoubleOrNull(json['p50_ms']),
        p90Ms: _asDoubleOrNull(json['p90_ms']),
        p95Ms: _asDoubleOrNull(json['p95_ms']),
        p99Ms: _asDoubleOrNull(json['p99_ms']),
        missedVsync: _asIntOrNull(json['missed_vsync']),
        highInputLatency: _asIntOrNull(json['high_input_latency']),
        slowUiThread: _asIntOrNull(json['slow_ui_thread']),
        slowBitmapUploads: _asIntOrNull(json['slow_bitmap_uploads']),
        slowDraw: _asIntOrNull(json['slow_draw']),
      );

  /// 目标包名。
  final String package;

  /// 进程 id（未运行 / 解析不到时为 `null`）。
  final int? pid;

  /// 应用 uid（`cmd package list packages -U` 解析；解析不到为 `null`）。
  final int? uid;

  /// 目标进程当前是否在运行。
  final bool running;

  /// 线程数（`/proc/<pid>/status` 的 `Threads:`；未知为 `null`）。
  final int? threads;

  /// 进程 CPU 占用（%，可能 >100 表示多核合计）。
  final double? cpuPercent;

  /// 内存 PSS（KiB）。
  final int? memPssKb;

  /// 内存 RSS（KiB）。
  final int? memRssKb;

  /// Java 堆（KiB）。
  final int? memJavaHeapKb;

  /// Native 堆（KiB）。
  final int? memNativeHeapKb;

  /// 私有脏页（KiB）。
  final int? memPrivateDirtyKb;

  /// 内存细分（App Summary）；解析不到为 `null`。
  final PerfMemSummary? memSummary;

  /// 该应用的进程列表（`ps` 解析；无则空列表）。
  final List<PerfProcessInfo> processes;

  /// 网络累计计数器（`netstats` 解析）；不可用为 `null`。
  final PerfNetCounters? net;

  /// 渲染耗时细分（`gfxinfo ... framestats` 解析）；不可用为 `null`。
  final PerfRenderBreakdown? render;

  /// 耗电 / 唤醒归因（`batterystats --charged` 解析）；不可用为 `null`。
  final PerfPowerAttribution? power;

  /// 应用包信息（`dumpsys package` 解析）；不可用为 `null`。
  final PerfAppInfo? appInfo;

  /// 精确内存占用（`/proc/<pid>/smaps_rollup` 拼接解析）；不可用为 `null`。
  final PerfSmaps? smaps;

  /// 崩溃 / ANR 汇总（`dumpsys dropbox` 解析）；不可用为 `null`。
  final PerfCrashReport? crashes;

  /// 前台状态（`dumpsys activity activities` 解析）；不可用为 `null`。
  final PerfForeground? foreground;

  /// 唤醒锁明细（`wake_locks[]`）；不可用为空列表。
  final List<PerfWakeLock> wakeLocks;

  /// 累计渲染帧数（用于两次采样差值推导 FPS）。
  final int? frameCount;

  /// 卡顿帧数。
  final int? jankyFrames;

  /// 卡顿比例（%）。
  final double? jankyPercent;

  /// 帧耗时 P50（ms）。
  final double? p50Ms;

  /// 帧耗时 P90（ms）。
  final double? p90Ms;

  /// 帧耗时 P95（ms）。
  final double? p95Ms;

  /// 帧耗时 P99（ms）。
  final double? p99Ms;

  /// 掉帧（missed vsync）次数。
  final int? missedVsync;

  /// 高输入延迟次数。
  final int? highInputLatency;

  /// 慢 UI 线程次数。
  final int? slowUiThread;

  /// 慢位图上传次数。
  final int? slowBitmapUploads;

  /// 慢绘制次数。
  final int? slowDraw;

  /// Dart 侧推导的交付 FPS；无法推导时为 `null`。
  final double? fps;

  /// Dart 侧推导的接收速率（字节/秒）；无法推导时为 `null`。
  final double? rxBytesPerSec;

  /// Dart 侧推导的发送速率（字节/秒）；无法推导时为 `null`。
  final double? txBytesPerSec;

  /// 附带 Dart 侧推导出的 [fps] / [rxBytesPerSec] / [txBytesPerSec] 的副本
  /// （其余字段原样保留）。
  ThirdPartyAppMetrics withFps(
    double? fps, {
    double? rxBytesPerSec,
    double? txBytesPerSec,
  }) =>
      ThirdPartyAppMetrics(
        package: package,
        pid: pid,
        uid: uid,
        running: running,
        threads: threads,
        cpuPercent: cpuPercent,
        memPssKb: memPssKb,
        memRssKb: memRssKb,
        memJavaHeapKb: memJavaHeapKb,
        memNativeHeapKb: memNativeHeapKb,
        memPrivateDirtyKb: memPrivateDirtyKb,
        memSummary: memSummary,
        processes: processes,
        net: net,
        render: render,
        power: power,
        appInfo: appInfo,
        smaps: smaps,
        crashes: crashes,
        foreground: foreground,
        wakeLocks: wakeLocks,
        frameCount: frameCount,
        jankyFrames: jankyFrames,
        jankyPercent: jankyPercent,
        p50Ms: p50Ms,
        p90Ms: p90Ms,
        p95Ms: p95Ms,
        p99Ms: p99Ms,
        missedVsync: missedVsync,
        highInputLatency: highInputLatency,
        slowUiThread: slowUiThread,
        slowBitmapUploads: slowBitmapUploads,
        slowDraw: slowDraw,
        fps: fps,
        rxBytesPerSec: rxBytesPerSec,
        txBytesPerSec: txBytesPerSec,
      );
}

/// `perf.parse_startup` 响应：`am start -W` 输出的解析结果（冷 / 热启动）。
///
/// 请求 `{ "output": "<am start -W output>", "mode": "cold"|"warm" }`；响应的
/// [thisTimeMs] / [totalTimeMs] / [waitTimeMs] 数值字段可能为 `null`（输出不完整 /
/// 解析不到），一律**宽容解码**，绝不抛裸异常（与其它契约模型一致）。
class PerfStartupResult {
  const PerfStartupResult({
    this.status,
    this.activity,
    this.thisTimeMs,
    this.totalTimeMs,
    this.waitTimeMs,
    this.mode,
  });

  factory PerfStartupResult.fromJson(Map<String, dynamic> json) =>
      PerfStartupResult(
        status: _asStringOrNull(json['status']),
        activity: _asStringOrNull(json['activity']),
        thisTimeMs: _asIntOrNull(json['this_time_ms']),
        totalTimeMs: _asIntOrNull(json['total_time_ms']),
        waitTimeMs: _asIntOrNull(json['wait_time_ms']),
        mode: _asStringOrNull(json['mode']),
      );

  /// `Status:` 行（如 `ok`）；解析不到为 `null`。
  final String? status;

  /// 启动的 Activity 组件（`pkg/activity`）；解析不到为 `null`。
  final String? activity;

  /// `ThisTime:`（ms）——最后一个 Activity 的启动耗时；解析不到为 `null`。
  final int? thisTimeMs;

  /// `TotalTime:`（ms）——本次启动总耗时；解析不到为 `null`。
  final int? totalTimeMs;

  /// `WaitTime:`（ms）——含系统调度等待的总耗时；解析不到为 `null`。
  final int? waitTimeMs;

  /// 请求回传的测量模式（`cold` / `warm`）；缺省为 `null`。
  final String? mode;

  /// 是否成功解析出状态行（便于 UI 区分「失败」与「数据缺失」）。
  bool get ok => status != null;
}

// ==================== 聚合快照 / 采样 ====================

/// `perf.snapshot` / `perf.sample` 的聚合快照（各节部分数据是预期状态）。
class PerfSnapshot {
  const PerfSnapshot({
    this.tsMs = 0,
    this.cpu,
    this.memory,
    this.battery,
    this.thermal,
    this.gpu,
    this.network,
    this.device,
    this.processes,
  });

  factory PerfSnapshot.fromJson(Map<String, dynamic> json) => PerfSnapshot(
        tsMs: _asInt(json['ts_ms']),
        cpu: json['cpu'] == null
            ? null
            : CpuReport.fromJson(_asMap(json['cpu'])),
        memory: json['memory'] == null
            ? null
            : MemoryReport.fromJson(_asMap(json['memory'])),
        battery: json['battery'] == null
            ? null
            : BatteryReport.fromJson(_asMap(json['battery'])),
        thermal: json['thermal'] == null
            ? null
            : ThermalReport.fromJson(_asMap(json['thermal'])),
        gpu: json['gpu'] == null
            ? null
            : GpuReport.fromJson(_asMap(json['gpu'])),
        network: json['network'] == null
            ? null
            : NetworkReport.fromJson(_asMap(json['network'])),
        device: json['device'] == null
            ? null
            : DeviceReport.fromJson(_asMap(json['device'])),
        processes: json['processes'] == null
            ? null
            : ProcessReport.fromJson(_asMap(json['processes'])),
      );

  final int tsMs;
  final CpuReport? cpu;
  final MemoryReport? memory;
  final BatteryReport? battery;
  final ThermalReport? thermal;
  final GpuReport? gpu;
  final NetworkReport? network;
  final DeviceReport? device;

  /// 仅 `perf.snapshot`（`include_processes=true`）时存在。
  final ProcessReport? processes;
}

/// 一条采样：`perf.sample` 事件载荷 + `perf.history` 记录的统一视图。
///
/// * 事件载荷即快照 JSON 本身（无 `seq`），用 [PerfSample.fromEventJson]；
/// * 历史记录为 `{seq, ts_ms, data}`，用 [PerfSample.fromHistoryEntry]。
class PerfSample {
  const PerfSample({required this.snapshot, this.seq});

  /// 采样事件（`perf.sample`）载荷 → 采样。
  factory PerfSample.fromEventJson(Map<String, dynamic> json) =>
      PerfSample(snapshot: PerfSnapshot.fromJson(json));

  /// `perf.history` 的 `samples[]` 项（`{seq, ts_ms, data}`）→ 采样。
  factory PerfSample.fromHistoryEntry(Map<String, dynamic> json) => PerfSample(
        seq: _asIntOrNull(json['seq']),
        snapshot: PerfSnapshot.fromJson(_asMap(json['data'])),
      );

  /// 采样序号（历史记录有；实时事件无）。
  final int? seq;

  /// 聚合快照。
  final PerfSnapshot snapshot;

  /// 采样时间（Unix ms；取自快照 `ts_ms`）。
  int get tsMs => snapshot.tsMs;
}

/// `perf.history` 响应。
class PerfHistory {
  const PerfHistory({
    this.count = 0,
    this.capacity = 0,
    this.samples = const <PerfSample>[],
  });

  factory PerfHistory.fromJson(Map<String, dynamic> json) => PerfHistory(
        count: _asInt(json['count']),
        capacity: _asInt(json['capacity']),
        samples: _objectList(json['samples'])
            .map(PerfSample.fromHistoryEntry)
            .toList(growable: false),
      );

  /// 本次返回的样本数。
  final int count;

  /// 采样环容量上限（Rust `RING_CAP = 300`）。
  final int capacity;

  /// 样本列表（时间升序）。
  final List<PerfSample> samples;
}

// ==================== JSON 宽容解码工具 ====================

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return const <String, dynamic>{};
}

int _asInt(Object? value) => _asIntOrNull(value) ?? 0;

int? _asIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value == null) return null;
  return int.tryParse(value.toString());
}

double _asDouble(Object? value) => _asDoubleOrNull(value) ?? 0;

double? _asDoubleOrNull(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value == null) return null;
  return double.tryParse(value.toString());
}

String _asString(Object? value, {String fallback = ''}) =>
    _asStringOrNull(value) ?? fallback;

String? _asStringOrNull(Object? value) {
  if (value == null) return null;
  final s = value.toString();
  return s.isEmpty ? null : s;
}

List<double> _doubleList(Object? value) {
  if (value is! List) return const <double>[];
  return value
      .map(_asDoubleOrNull)
      .whereType<double>()
      .toList(growable: false);
}

/// JSON 数组 → 整数列表（跳过缺值项，绝不抛错）。
List<int> _intList(Object? value) {
  if (value is! List) return const <int>[];
  return value.map(_asIntOrNull).whereType<int>().toList(growable: false);
}

/// 非有限值（NaN / ±Infinity）视作缺失：**绝不把坏数据解码为 NaN**。
double? _finiteDoubleOrNull(Object? value) {
  final d = _asDoubleOrNull(value);
  if (d == null || !d.isFinite) return null;
  return d;
}

/// 同上，但用于列表：跳过非有限 / 缺值项。
List<double> _finiteDoubleList(Object? value) {
  if (value is! List) return const <double>[];
  return value
      .map(_finiteDoubleOrNull)
      .whereType<double>()
      .toList(growable: false);
}

/// `Vec<Option<f64>>`：保留 `null` 占位，不丢弃（索引与核编号对齐）。
List<double?> _nullableDoubleList(Object? value) {
  if (value is! List) return const <double?>[];
  return value.map(_asDoubleOrNull).toList(growable: false);
}

/// JSON 数组 → JSON 对象列表（跳过非对象项，绝不抛错）。
List<Map<String, dynamic>> _objectList(Object? value) {
  if (value is! List) return const <Map<String, dynamic>>[];
  return value.whereType<Map>().map(_asMap).toList(growable: false);
}

/// JSON 数组 → 字符串列表（跳过空值，绝不抛错）。
List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.map(_asStringOrNull).whereType<String>().toList(growable: false);
}

/// `{resource}: {some:{...}, full:{...}}` → 指定子节的宽容解码。
///
/// 资源对象缺失 / 子节缺失 / 非对象时返回 `null`（UI 展示「不可用」）。
PerfPressureSample? _pressureSample(Object? resource, String key) {
  final map = _asMap(resource);
  final child = map[key];
  if (child is! Map) return null;
  return PerfPressureSample.fromJson(_asMap(child));
}
