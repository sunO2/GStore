/// 每应用性能档案模型（todo 22）。
///
/// 一个 [PerfProfile] 描述「对某个包（应用）应用哪组性能旋钮」：
/// * 每个 CPU 策略簇（`policy0` / `policy4` …）可选的 governor / 最低 / 最高频率；
/// * GPU 功率档位（`gpu_level`）；
/// * cpuset / 亲和组（`cpuset`）；
/// * thermal 开关标记（`thermalEnabled`）；
/// * 场景性能模式（[PerfProfile.mode]，默认 [PerfMode.balance]）；
/// * 是否启用（[PerfProfile.enabled]，默认 **false** = 不自动应用，fail-closed）。
///
/// ## 设计约束
/// * **宽容解码**：所有字段可选，字段缺失 / 类型不符 / 非有限数（NaN/±Inf）
///   一律退化为安全默认值（`null` / `false` / 空 map / [PerfMode.balance]），
///   **绝不抛异常**。
/// * 模型**纯数据**：不读配置、不执行命令、不依赖控制会话（todo 20）。
/// * JSON 键稳定（snake_case）：`package` / `enabled` / `cpu_clusters` /
///   `gpu_level` / `cpuset` / `thermal_enabled` / `mode`。
///
/// [PerfModePreset]（todo 24）把 [PerfMode] 映射到**既有**旋钮形状
/// （CPU 每簇 / GPU / cpuset / thermal），供后续应用器（todos 26-27）消费；
/// 本文件**只建模**，不读系统、不落盘。
///
/// 持久化见 `perf_profile_store.dart`（配置键 `perf.profiles`）。
library;

/// 单个 CPU 策略簇的可选覆盖（governor / 最低 / 最高频率，MHz）。
class PerfCpuClusterProfile {
  const PerfCpuClusterProfile({
    this.governor,
    this.minFreqMhz,
    this.maxFreqMhz,
  });

  /// governor 名（如 `schedutil`）；`null` = 不管理。
  final String? governor;

  /// 最低频率（MHz）；`null` = 不管理。
  final double? minFreqMhz;

  /// 最高频率（MHz）；`null` = 不管理。
  final double? maxFreqMhz;

  /// 是否没有任何有效旋钮。
  bool get isEmpty =>
      governor == null && minFreqMhz == null && maxFreqMhz == null;

  /// 序列化（省略 `null` 字段）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (governor != null) 'governor': governor,
        if (minFreqMhz != null) 'min_freq_mhz': minFreqMhz,
        if (maxFreqMhz != null) 'max_freq_mhz': maxFreqMhz,
      };

  /// 宽容反序列化。
  factory PerfCpuClusterProfile.fromJson(Map<String, dynamic> json) {
    return PerfCpuClusterProfile(
      governor: _stringOrNull(json['governor']),
      minFreqMhz: _finiteDoubleOrNull(json['min_freq_mhz']),
      maxFreqMhz: _finiteDoubleOrNull(json['max_freq_mhz']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PerfCpuClusterProfile &&
          governor == other.governor &&
          minFreqMhz == other.minFreqMhz &&
          maxFreqMhz == other.maxFreqMhz;

  @override
  int get hashCode => Object.hash(governor, minFreqMhz, maxFreqMhz);

  @override
  String toString() =>
      'PerfCpuClusterProfile(governor: $governor, min: $minFreqMhz, max: $maxFreqMhz)';
}

/// 场景性能模式（Scene 经典四档：省电 / 均衡 / 性能 / 极速）。
///
/// [wireName] 为稳定的 JSON 线格式（小写英文），[label] 为中文展示名。
/// 未知 / 缺失 / 类型不符的线格式值一律退化为 [PerfMode.balance]（默认均衡）。
enum PerfMode {
  /// 省电：保守 governor / 低频 / 更严的散热策略。
  powersave('powersave', '省电'),

  /// 均衡：设备默认（默认值）。
  balance('balance', '均衡'),

  /// 性能：偏高性能 / 前台亲和。
  performance('performance', '性能'),

  /// 极速：最高性能（top-app 亲和、散热放开等）。
  fast('fast', '极速');

  const PerfMode(this.wireName, this.label);

  /// 稳定 JSON 线格式名（小写英文）。
  final String wireName;

  /// 中文展示名（省电 / 均衡 / 性能 / 极速）。
  final String label;

  /// 默认模式（均衡）。
  static const PerfMode defaultMode = PerfMode.balance;

  /// 宽容解析：接受线格式名 / 中文标签 / 枚举序号；无法识别 → [defaultMode]。
  ///
  /// **绝不抛异常**。用于 [PerfProfile.fromJson] 的向后兼容解码。
  static PerfMode fromWire(Object? value) {
    if (value is PerfMode) return value;
    if (value is int) {
      if (value >= 0 && value < PerfMode.values.length) {
        return PerfMode.values[value];
      }
      return defaultMode;
    }
    if (value is String) {
      final trimmed = value.trim();
      final lower = trimmed.toLowerCase();
      for (final mode in PerfMode.values) {
        if (mode.wireName == lower || mode.label == trimmed) return mode;
      }
    }
    return defaultMode;
  }
}

/// 把 [PerfMode] 映射到**既有** [PerfProfile] 旋钮形状的「模式预设」（todo 24）。
///
/// 预设**不含** package / enabled / mode：它只描述「该模式下应当应用的旋钮」，
/// 由应用器（todos 26-27）与具体档案按**逐字段**优先级合并
/// （显式非 null 的簇 / 字段覆盖预设，CPU 每簇、GPU、cpuset、thermal 各自独立）。
///
/// ## 与 todo 27 的分工
/// 本类的 [forMode] 提供**设备无关的安全回退**（仅用各 Android 通用的 cpuset
/// 名与安全 thermal 方向）。按 SoC / variant 细化的目标值表由 todo 27 的
/// `perf_mode_profiles.dart` 提供（仅常量表）。
///
/// ## 宽容解码
/// 与 [PerfProfile] 一致：字段缺失 / 类型不符 → 安全默认，**绝不抛**。
class PerfModePreset {
  const PerfModePreset({
    this.cpuClusters = const <String, PerfCpuClusterProfile>{},
    this.gpuLevel,
    this.cpuset,
    this.thermalEnabled,
  });

  /// 空预设（不管理任何旋钮）。
  static const PerfModePreset empty = PerfModePreset();

  /// 每个 CPU 策略簇的覆盖（键为簇 / 策略目录名，如 `policy0`）。
  final Map<String, PerfCpuClusterProfile> cpuClusters;

  /// GPU 功率档位（`null` = 不管理）。
  final int? gpuLevel;

  /// cpuset / 亲和组名（`null` = 不管理）。
  final String? cpuset;

  /// thermal 开关标记（`null` = 不管理）。
  final bool? thermalEnabled;

  /// 是否没有任何有效旋钮。
  bool get isEmpty =>
      cpuClusters.isEmpty &&
      gpuLevel == null &&
      cpuset == null &&
      thermalEnabled == null;

  /// 设备无关的安全回退预设（按 SoC 细化的表见 todo 27）。
  ///
  /// * 省电：`background` 亲和 + 保持散热管理（安全方向）。
  /// * 均衡：空预设（设备默认，不干预）。
  /// * 性能：`foreground` 亲和。
  /// * 极速：`top-app` 亲和。
  static PerfModePreset forMode(PerfMode mode) => switch (mode) {
        PerfMode.powersave => const PerfModePreset(
            cpuset: 'background',
            thermalEnabled: true,
          ),
        PerfMode.balance => empty,
        PerfMode.performance => const PerfModePreset(cpuset: 'foreground'),
        PerfMode.fast => const PerfModePreset(cpuset: 'top-app'),
      };

  /// 序列化（省略 `null` / 空字段）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (cpuClusters.isNotEmpty)
          'cpu_clusters': <String, dynamic>{
            for (final entry in cpuClusters.entries)
              entry.key: entry.value.toJson(),
          },
        if (gpuLevel != null) 'gpu_level': gpuLevel,
        if (cpuset != null) 'cpuset': cpuset,
        if (thermalEnabled != null) 'thermal_enabled': thermalEnabled,
      };

  /// 宽容反序列化（与 [PerfProfile.fromJson] 同构，**绝不抛**）。
  factory PerfModePreset.fromJson(Map<String, dynamic> json) {
    final clusters = <String, PerfCpuClusterProfile>{};
    final rawClusters = json['cpu_clusters'];
    if (rawClusters is Map) {
      rawClusters.forEach((key, value) {
        if (key is String && key.isNotEmpty && value is Map) {
          try {
            clusters[key] = PerfCpuClusterProfile.fromJson(
              value.map((k, v) => MapEntry(k.toString(), v)),
            );
          } catch (_) {
            // 单个簇损坏 → 跳过该簇（best-effort）
          }
        }
      });
    }
    return PerfModePreset(
      cpuClusters: clusters,
      gpuLevel: _intOrNull(json['gpu_level']),
      cpuset: _stringOrNull(json['cpuset']),
      thermalEnabled: _boolOrNull(json['thermal_enabled']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PerfModePreset &&
          _mapEquals(cpuClusters, other.cpuClusters) &&
          gpuLevel == other.gpuLevel &&
          cpuset == other.cpuset &&
          thermalEnabled == other.thermalEnabled;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(cpuClusters.keys),
        gpuLevel,
        cpuset,
        thermalEnabled,
      );

  @override
  String toString() =>
      'PerfModePreset(clusters: ${cpuClusters.length}, gpuLevel: $gpuLevel, '
      'cpuset: $cpuset, thermalEnabled: $thermalEnabled)';
}

/// 每应用性能档案。
class PerfProfile {
  const PerfProfile({
    required this.package,
    this.enabled = false,
    this.cpuClusters = const <String, PerfCpuClusterProfile>{},
    this.gpuLevel,
    this.cpuset,
    this.thermalEnabled,
    this.mode = PerfMode.balance,
  });

  /// 空档案（安全默认）。
  static const PerfProfile empty = PerfProfile(package: '');

  /// 目标包名（档案身份）。
  final String package;

  /// 是否启用（默认 false = 不自动应用）。
  final bool enabled;

  /// 每个 CPU 策略簇的覆盖，键为簇 / 策略目录名（如 `policy0`）。
  final Map<String, PerfCpuClusterProfile> cpuClusters;

  /// GPU 功率档位（`null` = 不管理）。
  final int? gpuLevel;

  /// cpuset / 亲和组名（`null` = 不管理）。
  final String? cpuset;

  /// thermal 开关标记（`null` = 不管理）。
  final bool? thermalEnabled;

  /// 场景性能模式（默认 [PerfMode.balance]）。
  ///
  /// 模式参与 [operator ==] / [hashCode]，因此**仅 mode 变化**也会被
  /// 自动应用引擎的 `current == target` 变更检测识别（见
  /// `perf_profile_auto_engine.dart`）。
  final PerfMode mode;

  /// 是否未配置任何有效覆盖（默认 [PerfMode.balance] 视为「无有效模式」）。
  bool get isEmpty =>
      package.isEmpty &&
      !enabled &&
      cpuClusters.isEmpty &&
      gpuLevel == null &&
      cpuset == null &&
      thermalEnabled == null &&
      mode == PerfMode.balance;

  /// 复制并覆盖部分字段。
  PerfProfile copyWith({
    String? package,
    bool? enabled,
    Map<String, PerfCpuClusterProfile>? cpuClusters,
    int? gpuLevel,
    bool cpusetClear = false,
    String? cpuset,
    bool? thermalEnabled,
    PerfMode? mode,
  }) {
    return PerfProfile(
      package: package ?? this.package,
      enabled: enabled ?? this.enabled,
      cpuClusters: cpuClusters ?? this.cpuClusters,
      gpuLevel: gpuLevel ?? this.gpuLevel,
      cpuset: cpusetClear ? null : (cpuset ?? this.cpuset),
      thermalEnabled: thermalEnabled ?? this.thermalEnabled,
      mode: mode ?? this.mode,
    );
  }

  /// 序列化（省略 `null` / 空字段；`mode` 始终写出以保证往返）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'package': package,
        'enabled': enabled,
        if (cpuClusters.isNotEmpty)
          'cpu_clusters': <String, dynamic>{
            for (final entry in cpuClusters.entries)
              entry.key: entry.value.toJson(),
          },
        if (gpuLevel != null) 'gpu_level': gpuLevel,
        if (cpuset != null) 'cpuset': cpuset,
        if (thermalEnabled != null) 'thermal_enabled': thermalEnabled,
        'mode': mode.wireName,
      };

  /// 宽容反序列化：任意字段缺失 / 类型不符 → 安全默认，**绝不抛**。
  ///
  /// 缺少 `mode`（旧档案）→ [PerfMode.balance]（向后兼容）。
  factory PerfProfile.fromJson(Map<String, dynamic> json) {
    final clusters = <String, PerfCpuClusterProfile>{};
    final rawClusters = json['cpu_clusters'];
    if (rawClusters is Map) {
      rawClusters.forEach((key, value) {
        if (key is String && key.isNotEmpty && value is Map) {
          try {
            clusters[key] = PerfCpuClusterProfile.fromJson(
              value.map((k, v) => MapEntry(k.toString(), v)),
            );
          } catch (_) {
            // 单个簇损坏 → 跳过该簇（best-effort）
          }
        }
      });
    }
    return PerfProfile(
      package: _stringOrNull(json['package']) ?? '',
      enabled: _boolOrNull(json['enabled']) ?? false,
      cpuClusters: clusters,
      gpuLevel: _intOrNull(json['gpu_level']),
      cpuset: _stringOrNull(json['cpuset']),
      thermalEnabled: _boolOrNull(json['thermal_enabled']),
      mode: PerfMode.fromWire(json['mode']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PerfProfile &&
          package == other.package &&
          enabled == other.enabled &&
          _mapEquals(cpuClusters, other.cpuClusters) &&
          gpuLevel == other.gpuLevel &&
          cpuset == other.cpuset &&
          thermalEnabled == other.thermalEnabled &&
          mode == other.mode;

  @override
  int get hashCode => Object.hash(
        package,
        enabled,
        Object.hashAll(cpuClusters.keys),
        gpuLevel,
        cpuset,
        thermalEnabled,
        mode,
      );

  @override
  String toString() =>
      'PerfProfile(package: $package, enabled: $enabled, '
      'clusters: ${cpuClusters.length}, gpuLevel: $gpuLevel, '
      'cpuset: $cpuset, thermalEnabled: $thermalEnabled, mode: ${mode.wireName})';
}

// ---- 宽容取值 helpers（绝不抛） ----

String? _stringOrNull(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

bool? _boolOrNull(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    final lower = value.trim().toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
  }
  return null;
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) {
    if (value.isFinite) return value.toInt();
    return null;
  }
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? _finiteDoubleOrNull(Object? value) {
  if (value is num) {
    final d = value.toDouble();
    return d.isFinite ? d : null;
  }
  if (value is String) {
    final d = double.tryParse(value.trim());
    if (d == null) return null;
    return d.isFinite ? d : null;
  }
  return null;
}

bool _mapEquals<K, V>(
  Map<K, V> a,
  Map<K, V> b,
) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
