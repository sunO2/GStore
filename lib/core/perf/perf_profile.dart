/// 每应用性能档案模型（todo 22）。
///
/// 一个 [PerfProfile] 描述「对某个包（应用）应用哪组性能旋钮」：
/// * 每个 CPU 策略簇（`policy0` / `policy4` …）可选的 governor / 最低 / 最高频率；
/// * GPU 功率档位（`gpu_level`）；
/// * cpuset / 亲和组（`cpuset`）；
/// * thermal 开关标记（`thermalEnabled`）；
/// * 是否启用（[PerfProfile.enabled]，默认 **false** = 不自动应用，fail-closed）。
///
/// ## 设计约束
/// * **宽容解码**：所有字段可选，字段缺失 / 类型不符 / 非有限数（NaN/±Inf）
///   一律退化为安全默认值（`null` / `false` / 空 map），**绝不抛异常**。
/// * 模型**纯数据**：不读配置、不执行命令、不依赖控制会话（todo 20）。
/// * JSON 键稳定（snake_case）：`package` / `enabled` / `cpu_clusters` /
///   `gpu_level` / `cpuset` / `thermal_enabled`。
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

/// 每应用性能档案。
class PerfProfile {
  const PerfProfile({
    required this.package,
    this.enabled = false,
    this.cpuClusters = const <String, PerfCpuClusterProfile>{},
    this.gpuLevel,
    this.cpuset,
    this.thermalEnabled,
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

  /// 是否未配置任何有效覆盖。
  bool get isEmpty =>
      package.isEmpty &&
      !enabled &&
      cpuClusters.isEmpty &&
      gpuLevel == null &&
      cpuset == null &&
      thermalEnabled == null;

  /// 复制并覆盖部分字段。
  PerfProfile copyWith({
    String? package,
    bool? enabled,
    Map<String, PerfCpuClusterProfile>? cpuClusters,
    int? gpuLevel,
    bool cpusetClear = false,
    String? cpuset,
    bool? thermalEnabled,
  }) {
    return PerfProfile(
      package: package ?? this.package,
      enabled: enabled ?? this.enabled,
      cpuClusters: cpuClusters ?? this.cpuClusters,
      gpuLevel: gpuLevel ?? this.gpuLevel,
      cpuset: cpusetClear ? null : (cpuset ?? this.cpuset),
      thermalEnabled: thermalEnabled ?? this.thermalEnabled,
    );
  }

  /// 序列化（省略 `null` / 空字段）。
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
      };

  /// 宽容反序列化：任意字段缺失 / 类型不符 → 安全默认，**绝不抛**。
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
          thermalEnabled == other.thermalEnabled;

  @override
  int get hashCode => Object.hash(
        package,
        enabled,
        Object.hashAll(cpuClusters.keys),
        gpuLevel,
        cpuset,
        thermalEnabled,
      );

  @override
  String toString() =>
      'PerfProfile(package: $package, enabled: $enabled, '
      'clusters: ${cpuClusters.length}, gpuLevel: $gpuLevel, '
      'cpuset: $cpuset, thermalEnabled: $thermalEnabled)';
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
