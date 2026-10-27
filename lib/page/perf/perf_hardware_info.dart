/// 性能页「硬件」tab 的**静态硬件规格**采集与展示。
///
/// 数据来源（全部 best-effort，任一失败只影响该字段，绝不抛）：
/// * `device_info_plus` `AndroidDeviceInfo` —— 品牌 / 机型 / 主板 / ABI /
///   Build（版本 / API / 安全补丁 / 指纹）/ 物理内存 / 存储 / 屏幕密度 / 系统特性；
/// * 原生 `perf.device` —— 内核版本、SoC `hardware`、可读 CPU 名称、平台；
/// * 原生 `perf.tunables` —— 逐 CPU 策略簇（核编号 / 调速器 / 频率范围 / 档位）与
///   GPU 规格（可用频率 / governor / 功耗档位）；
/// * 原生 `perf.sensors` —— NDK `ASensorManager` 传感器清单（类型 / 厂商 /
///   分辨率 / 最小间隔 / FIFO / 唤醒 / 上报模式；只读元数据）。
///
/// 运行时数值（当前频率 / 负载）仍复用 [perfMonitorProvider]，避免新建采集链路。
library;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

import 'logic.dart';
import 'perf_common.dart';

/// 静态硬件数据快照（各来源均可空；UI 逐字段降级）。
class PerfHardwareData {
  const PerfHardwareData({
    this.android,
    this.device,
    this.tunables,
    this.sensors,
  });

  /// `device_info_plus` 的 Android 设备信息（非 Android / 平台通道不可用 → `null`）。
  final AndroidDeviceInfo? android;

  /// 原生 `perf.device`（模块未就绪 / 失败 → `null`）。
  final DeviceReport? device;

  /// 原生 `perf.tunables`（CPU 簇 / GPU 可控面；失败 → `null`）。
  final TunablesReport? tunables;

  /// 原生 `perf.sensors`（NDK 传感器清单；失败 → `null`）。
  final SensorsReport? sensors;
}

/// 硬件规格（一次性读取后按 Provider 作用域缓存）。
final perfHardwareDataProvider = FutureProvider<PerfHardwareData>((ref) async {
  final module = ref.read(perfModuleProvider);

  AndroidDeviceInfo? android;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      android = await DeviceInfoPlugin().androidInfo;
    } catch (error) {
      debugPrint('[PerfHardwareInfo] device_info_plus 不可用（降级）: $error');
    }
  }

  DeviceReport? device;
  TunablesReport? tunables;
  SensorsReport? sensors;
  if (module.availability == PerfAvailability.ready) {
    try {
      device = await module.device();
    } catch (error) {
      debugPrint('[PerfHardwareInfo] perf.device 不可用（降级）: $error');
    }
    try {
      tunables = await module.tunables();
    } catch (error) {
      debugPrint('[PerfHardwareInfo] perf.tunables 不可用（降级）: $error');
    }
    try {
      sensors = await module.sensors();
    } catch (error) {
      debugPrint('[PerfHardwareInfo] perf.sensors 不可用（降级）: $error');
    }
  }

  return PerfHardwareData(
    android: android,
    device: device,
    tunables: tunables,
    sensors: sensors,
  );
});

// ==================== 设备信息 ====================

/// 设备身份 / 系统构建 / ABI（静态规格）。
class PerfDeviceSpecCard extends ConsumerWidget {
  const PerfDeviceSpecCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(perfHardwareDataProvider);
    final data = async.valueOrNull;
    final android = data?.android;
    final device = data?.device;
    final model = _clean(android?.model) ?? _clean(device?.model);
    final brand = _clean(android?.brand) ?? _clean(android?.manufacturer);
    final subtitle = <String?>[brand, model].whereType<String>().join(' ');

    return _PerfInfoCard(
      icon: TablerIcons.device_mobile,
      title: '设备信息',
      trailing: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
      child: async.when(
        loading: () => _loadingRow(context, '正在读取设备信息…'),
        error: (_, __) => _muted(context, '设备信息不可用'),
        data: (data) => _content(context, data),
      ),
    );
  }

  Widget _content(BuildContext context, PerfHardwareData data) {
    final android = data.android;
    final device = data.device;
    final rows = <Widget>[];

    void add(String label, String? value) {
      final cleaned = _clean(value);
      if (cleaned != null) rows.add(perfKv(context, label, cleaned));
    }

    add('品牌', android?.brand);
    add('厂商', android?.manufacturer);
    add('机型', android?.model ?? device?.model);
    add('设备代号', android?.device);
    add('产品', android?.product);
    add('主板', android?.board ?? device?.boardPlatform);
    add('硬件', android?.hardware ?? device?.hardware);
    add('SoC', device?.cpuName);
    if (device != null && device.coreCount > 0) {
      add('CPU 核心数', '${device.coreCount}');
    }
    add('ABI', android?.supportedAbis.join(' / '));
    add('64 位 ABI', android?.supported64BitAbis.join(' / '));
    add('32 位 ABI', android?.supported32BitAbis.join(' / '));
    add('引导程序', android?.bootloader);
    if (android != null) {
      add('Android', '${android.version.release}（API ${android.version.sdkInt}）');
    } else {
      add('Android', device?.androidRelease ?? device?.osRelease);
    }
    add('安全补丁', android?.version.securityPatch);
    add('基础系统', android?.version.baseOS);
    add('构建 ID', android?.display ?? android?.id);
    add('增量版本', android?.version.incremental);
    add(
      '构建类型',
      _joinNonEmpty(<String?>[android?.type, android?.tags], ' · '),
    );
    add('内核版本', device?.kernelVersion);
    add('系统指纹', android?.fingerprint);
    if (android != null) {
      add('真机', android.isPhysicalDevice ? '是' : '否（模拟器）');
      add('低内存设备', android.isLowRamDevice ? '是' : '否');
    }

    if (rows.isEmpty) {
      return _muted(context, '暂无可用的设备信息');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }
}

// ==================== CPU 簇 / GPU 规格 ====================

/// CPU 策略簇与 GPU 的静态规格 + 当前频率。
class PerfCpuGpuSpecCard extends ConsumerWidget {
  const PerfCpuGpuSpecCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(perfHardwareDataProvider);
    final cpu = ref.watch(perfMonitorProvider.select((s) => s.cpu));
    final gpu = ref.watch(perfMonitorProvider.select((s) => s.gpu));

    return _PerfInfoCard(
      icon: TablerIcons.cpu,
      title: '处理器 / 图形',
      child: async.when(
        loading: () => _loadingRow(context, '正在读取处理器信息…'),
        error: (_, __) => _muted(context, '处理器信息不可用'),
        data: (data) => _content(context, data, cpu: cpu, gpu: gpu),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    PerfHardwareData data, {
    required CpuReport? cpu,
    required GpuReport? gpu,
  }) {
    final theme = Theme.of(context);
    final clusters = data.tunables?.cpuClusters ?? const <PerfCpuCluster>[];
    final gpuTunables = data.tunables?.gpu;
    final devices = _freqsById(cpu);

    final children = <Widget>[];

    if (clusters.isEmpty) {
      children.add(_muted(context, 'CPU 集群信息不可用'));
    } else {
      for (var i = 0; i < clusters.length; i++) {
        final cluster = clusters[i];
        if (i > 0) children.add(const Divider(height: AppSpacing.lg));
        children.add(
          Text(
            '${cluster.policy.isEmpty ? '集群 ${i + 1}' : cluster.policy}'
            ' · CPU ${_cpuIds(cluster.relatedCpus)}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: AppTypography.weightSemiBold,
            ),
          ),
        );
        children.add(const SizedBox(height: AppSpacing.xs));
        children.add(perfKv(context, '调速器', cluster.governor ?? '—'));
        children.add(
          perfKv(context, '当前频率', _clusterCurrentFreq(cluster, devices)),
        );
        children.add(
          perfKv(
            context,
            '策略范围',
            _freqRange(cluster.minFreqMhz, cluster.maxFreqMhz),
          ),
        );
        children.add(
          perfKv(
            context,
            '可用频率',
            _freqCount(cluster.availableFrequenciesMhz),
          ),
        );
        if (cluster.availableGovernors.isNotEmpty) {
          children.add(
            perfKv(context, '可选调速器', cluster.availableGovernors.join(' / ')),
          );
        }
      }
    }

    children
      ..add(const SizedBox(height: AppSpacing.md))
      ..add(
        Text(
          'GPU',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: AppTypography.weightSemiBold,
          ),
        ),
      )
      ..add(const SizedBox(height: AppSpacing.xs))
      ..add(perfKv(context, '型号', gpu?.name ?? '—'))
      ..add(
        perfKv(
          context,
          '当前频率',
          gpu?.freqMhz == null ? '—' : '${gpu!.freqMhz!.toStringAsFixed(0)} MHz',
        ),
      )
      ..add(
        perfKv(
          context,
          '当前负载',
          gpu?.busyPercent == null
              ? '—'
              : '${gpu!.busyPercent!.toStringAsFixed(0)}%',
        ),
      )
      ..add(
        perfKv(
          context,
          '可用频率',
          _freqCount(gpuTunables?.availableFrequenciesMhz ?? const <double>[]),
        ),
      )
      ..add(perfKv(context, '调速器', gpuTunables?.governor ?? '—'));
    if (gpuTunables?.powerLevels != null) {
      children.add(
        perfKv(context, '功耗档位', '${gpuTunables!.powerLevels} 档'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// CPU 编号 → 当前频率（`perf.cpu` 每 2s 轮询更新）。
  Map<int, double> _freqsById(CpuReport? cpu) => <int, double>{
        for (final core in cpu?.cores ?? const <PerfCpuCore>[])
          if (core.freqMhz != null) core.id: core.freqMhz!,
      };

  /// 集群当前频率（相关核的最小 ~ 最大）。
  String _clusterCurrentFreq(PerfCpuCluster cluster, Map<int, double> freqs) {
    final values = <double>[
      for (final id in cluster.relatedCpus)
        if (freqs[id] != null) freqs[id]!,
    ];
    if (values.isEmpty) return '—';
    var min = values.first;
    var max = values.first;
    for (final v in values.skip(1)) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    return min == max
        ? '${min.toStringAsFixed(0)} MHz'
        : '${min.toStringAsFixed(0)} ~ ${max.toStringAsFixed(0)} MHz';
  }
}

// ==================== 屏幕 / 存储 / 系统特性 ====================

/// 屏幕、内存 / 存储总量与系统特性（摄像头 / 传感器 / 无线等）。
class PerfDisplayFeaturesCard extends ConsumerWidget {
  const PerfDisplayFeaturesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(perfHardwareDataProvider);

    return _PerfInfoCard(
      icon: TablerIcons.device_mobile,
      title: '屏幕 / 存储 / 特性',
      child: async.when(
        loading: () => _loadingRow(context, '正在读取屏幕与特性…'),
        error: (_, __) => _muted(context, '屏幕与特性不可用'),
        data: (data) => _content(context, data),
      ),
    );
  }

  Widget _content(BuildContext context, PerfHardwareData data) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final android = data.android;
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final refreshRate = View.of(context).display.refreshRate;

    final children = <Widget>[
      perfKv(
        context,
        '分辨率',
        '${(size.width * dpr).round()} × ${(size.height * dpr).round()} px',
      ),
      perfKv(
        context,
        '逻辑尺寸',
        '${size.width.toStringAsFixed(0)} × ${size.height.toStringAsFixed(0)} dp',
      ),
      perfKv(
        context,
        '像素密度',
        '${dpr.toStringAsFixed(2)}x（${(dpr * 160).round()} dpi）',
      ),
      if (refreshRate > 0)
        perfKv(context, '刷新率', '${refreshRate.toStringAsFixed(0)} Hz'),
      if (android != null) ...[
        perfKv(
          context,
          '物理内存',
          perfBytesHuman(android.physicalRamSize * 1024.0 * 1024.0),
        ),
        perfKv(
          context,
          '可用内存',
          perfBytesHuman(android.availableRamSize * 1024.0 * 1024.0),
        ),
        perfKv(context, '总存储', perfBytesHuman(android.totalDiskSize.toDouble())),
        perfKv(context, '可用存储', perfBytesHuman(android.freeDiskSize.toDouble())),
      ],
    ];

    final features = android?.systemFeatures ?? const <String>[];
    final known = <MapEntry<String, String>>[
      for (final entry in _featureLabels.entries)
        if (features.contains(entry.key)) entry,
    ];

    children.add(const SizedBox(height: AppSpacing.md));
    children.add(
      Text(
        '系统特性',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: AppTypography.weightSemiBold,
        ),
      ),
    );
    children.add(const SizedBox(height: AppSpacing.xs));
    if (known.isEmpty) {
      children.add(_muted(context, '不可用'));
    } else {
      children.add(
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final entry in known)
              Container(
                padding: AppSpacing.horizontalSM_verticalXS,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: AppRadius.allSM,
                ),
                child: Text(
                  entry.value,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      );
      children.add(const SizedBox(height: AppSpacing.xs));
      children.add(
        _muted(
          context,
          '共 ${features.length} 项系统特性，已识别 ${known.length} 项',
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

// ==================== 传感器 ====================

/// 传感器清单（NDK 只读元数据：类型 / 厂商 / 分辨率 / 最小间隔 / FIFO / 唤醒）。
class PerfSensorsCard extends ConsumerWidget {
  const PerfSensorsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(perfHardwareDataProvider);
    final count = async.valueOrNull?.sensors?.sensors.length;
    return _PerfInfoCard(
      icon: TablerIcons.activity,
      title: '传感器',
      trailing: count == null
          ? null
          : Text(
              '$count 个',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
      child: async.when(
        loading: () => _loadingRow(context, '正在读取传感器…'),
        error: (_, __) => _muted(context, '传感器信息不可用'),
        data: (data) {
          final sensors = data.sensors?.sensors ?? const <SensorInfo>[];
          if (sensors.isEmpty) {
            return _muted(context, '不可用（模块未提供传感器清单）');
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var i = 0; i < sensors.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: AppSpacing.sm),
                _sensorTile(context, sensors[i]),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _sensorTile(BuildContext context, SensorInfo sensor) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final type = sensor.typeName.isEmpty ? '传感器' : sensor.typeName;
    final origin = <String?>[sensor.vendor, sensor.stringType]
        .whereType<String>()
        .where((v) => v.trim().isNotEmpty)
        .join(' · ');

    return Container(
      width: double.infinity,
      padding: AppSpacing.allSM,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.allSM,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  type,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
                ),
              ),
              if (sensor.wakeUp)
                Text(
                  '唤醒',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                  ),
                ),
            ],
          ),
          if (sensor.name.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text(
              sensor.name,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (origin.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text(
              origin,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: <Widget>[
              if (sensor.reportingModeName.isNotEmpty)
                _specTag(context, sensor.reportingModeName),
              _specTag(context, _delayLabel(sensor.minDelayUs)),
              _specTag(context, '分辨率 ${_resolutionLabel(sensor.resolution)}'),
              if (sensor.fifoMaxEventCount > 0)
                _specTag(context, 'FIFO ${sensor.fifoMaxEventCount}'),
              if (sensor.typeId >= 0x10000)
                _specTag(context, '厂商类型 0x${sensor.typeId.toRadixString(16)}'),
            ],
          ),
        ],
      ),
    );
  }
}

Widget _specTag(BuildContext context, String text) {
  final theme = Theme.of(context);
  return Container(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.sm,
      vertical: 2,
    ),
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: AppRadius.allSM,
    ),
    child: Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// 最小采样间隔：微秒 / 毫秒。
String _delayLabel(int us) {
  if (us <= 0) return '间隔 —';
  if (us < 1000) return '$us µs';
  final ms = us / 1000.0;
  return ms < 10
      ? '${ms.toStringAsFixed(1)} ms'
      : '${ms.toStringAsFixed(0)} ms';
}

/// 分辨率：极小 / 极大值用科学计数，其余保留 3 位有效数字。
String _resolutionLabel(double value) {
  if (value == 0) return '—';
  final abs = value.abs();
  if (abs < 0.001 || abs >= 10000) return value.toStringAsExponential(2);
  return value.toStringAsPrecision(3);
}

// ==================== 公共骨架 / 工具 ====================

/// 统一的规格卡片骨架（标题 + 内容）。
class _PerfInfoCard extends StatelessWidget {
  const _PerfInfoCard({
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            perfSectionHeader(context, icon, title, trailing: trailing),
            const SizedBox(height: AppSpacing.md),
            child,
          ],
        ),
      ),
    );
  }
}

/// 读取中提示：**不使用无限动画**（避免卡片异步未决时 pumpAndSettle 超时）。
Widget _loadingRow(BuildContext context, String label) => Row(
      children: [
        Icon(
          TablerIcons.hourglass,
          size: AppTypography.iconSM,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );

Widget _muted(BuildContext context, String text) => Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
    );

String? _clean(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

String? _joinNonEmpty(List<String?> values, String separator) {
  final parts = values.map(_clean).whereType<String>().toList(growable: false);
  return parts.isEmpty ? null : parts.join(separator);
}

/// `[0,1,2,4,5]` → `0-2, 4-5`（压缩连续编号）。
String _cpuIds(List<int> ids) {
  if (ids.isEmpty) return '—';
  final sorted = List<int>.of(ids)..sort();
  final parts = <String>[];
  var start = sorted.first;
  var previous = start;
  for (final id in sorted.skip(1)) {
    if (id == previous + 1) {
      previous = id;
      continue;
    }
    parts.add(start == previous ? '$start' : '$start-$previous');
    start = previous = id;
  }
  parts.add(start == previous ? '$start' : '$start-$previous');
  return parts.join(', ');
}

String _freqRange(double? min, double? max) {
  if (min == null && max == null) return '—';
  return '${min?.toStringAsFixed(0) ?? '—'} ~ '
      '${max?.toStringAsFixed(0) ?? '—'} MHz';
}

String _freqCount(List<double> freqs) {
  if (freqs.isEmpty) return '—';
  return '${freqs.length} 档'
      '（${freqs.first.toStringAsFixed(0)} ~ ${freqs.last.toStringAsFixed(0)} MHz）';
}

/// Android `PackageManager` 系统特性 → 中文标签（仅展示已命中的项）。
const Map<String, String> _featureLabels = <String, String>{
  'android.hardware.camera': '摄像头',
  'android.hardware.camera.flash': '闪光灯',
  'android.hardware.camera.autofocus': '自动对焦',
  'android.hardware.camera.front': '前置摄像头',
  'android.hardware.bluetooth': '蓝牙',
  'android.hardware.bluetooth_le': '蓝牙 LE',
  'android.hardware.wifi': 'Wi-Fi',
  'android.hardware.wifi.direct': 'Wi-Fi Direct',
  'android.hardware.nfc': 'NFC',
  'android.hardware.fingerprint': '指纹',
  'android.hardware.location.gps': 'GPS',
  'android.hardware.location.network': '网络定位',
  'android.hardware.telephony': '移动网络',
  'android.hardware.telephony.gsm': 'GSM',
  'android.hardware.touchscreen': '触屏',
  'android.hardware.touchscreen.multitouch': '多点触控',
  'android.hardware.usb.host': 'USB Host',
  'android.hardware.usb.accessory': 'USB 配件',
  'android.hardware.vulkan.version': 'Vulkan',
  'android.hardware.opengles.aep': 'OpenGL ES AEP',
  'android.hardware.sensor.accelerometer': '加速度计',
  'android.hardware.sensor.gyroscope': '陀螺仪',
  'android.hardware.sensor.compass': '磁力计',
  'android.hardware.sensor.proximity': '距离感应',
  'android.hardware.sensor.light': '光线感应',
  'android.hardware.sensor.stepcounter': '计步器',
  'android.hardware.sensor.stepdetector': '步伐检测',
  'android.hardware.sensor.barometer': '气压计',
  'android.hardware.sensor.heartrate': '心率',
  'android.hardware.sensor.hinge_angle': '折叠角度',
  'android.hardware.type.watch': '手表',
  'android.hardware.type.television': '电视',
  'android.software.leanback': 'Android TV',
  'android.hardware.audio.output': '音频输出',
  'android.hardware.audio.low_latency': '低延迟音频',
  'android.hardware.audio.pro': '专业音频',
  'android.hardware.microphone': '麦克风',
};
