/// 场景模式 preset · per-SoC 常量表（todo 27）。
///
/// 把 Scene 的 `assets/powercfg/<soc>/{active,conservative}.sh` 中**仅**
/// `shizuku-writable` 的旋钮，编码为既有 [PerfModePreset]（todo 24）形状的
/// **纯常量表**。本文件**无状态、无 IO、无命令执行**；应用由 todo 26 的既有
/// 应用器消费。
///
/// ## 权威依据（只读取证）
/// * `.omo/evidence/task-3-mode-feasibility.md` §2/§3/§6 —— 静态可达集 = 7 个旋钮类
///   （CPU 每簇 governor + min/max freq；GPU min/max freq + min/max pwrlevel +
///   governor；cpuset masks/membership；thermal `thermal_zone*/mode`）。
///   其余（`sched_*` / `stune` / `cpuctl` / `core_ctl` / `msm_performance` /
///   `cpu_boost` / devfreq-BW / `cpu_online` / `cgroup.procs` / `taskset` / `pm` /
///   `thermal_disguise` / `miuibooster` / `renice`）为 **root-only / unsupported**，
///   **不**在本表编码。
/// * Scene 源脚本（只读引用，值逐字取自其中）：
///   `/tmp/vtools/app/src/main/assets/powercfg/lahaina/{active,conservative}.sh`、
///   `.../kona/{active,conservative}.sh`、`.../powercfg-utils.sh`、
///   `.../powercfg-base.sh`。
///
/// ## 变体规则（todo 3 §4；**在本文件显式声明**）
/// * Scene 每个 SoC 目录含两个**风格变体**：`active`（激进）/ `conservative`（温和）。
/// * 变体是**用户/档案选择**，**绝不**由 SoC 自动推断；默认 = [PerfVariant.conservative]。
/// * lahaina/kona 均无 `*-base.sh`，两变体共用 `powercfg-base.sh`。
///
/// ## 目标 SoC 与回退（todo 3 §5；**显式 fallback**）
/// * owner **未提供**目标 SoC → 本表以 [kFallbackModeProfiles] 为**默认**，
///   lahaina/kona 表**仅作参考**，且**只**由运行时 `ro.board.platform` 命中选择。
/// * 未知 / 空 / 其它平台 → [kFallbackModeProfiles]（设备无关安全回退：
///   仅保留各 Android 通用的 cpuset / thermal 方向，不含 SoC 专属频率）。
/// * 运行时权威门仍是 `PerfCapabilityProbe`（fail-closed）；本表**不**断言真机可写。
///
/// ## 已编码旋钮 → Scene 源动作映射
/// * CPU governor `schedutil`（每簇）← `reset_basic_governor` 的
///   `echo schedutil > policy{0,4,7}/scaling_governor`（`policy0/4/7`）。
/// * CPU 每簇 min/max freq ← `set_cpu_freq A B C D E F`，即
///   `policy0.scaling_{min,max}=A,B`、`policy4=C,D`、`policy7=E,F`（Hz→MHz）。
/// * GPU [PerfModePreset.gpuLevel] ← `gpu_pl_up N` 的偏移 `N`（见下方 GPU 语义偏差）。
/// * cpuset [PerfModePreset.cpuset] ← `cpuset` 动作的**归属组**（`/dev/cpuset/*/tasks`；
///   Scene 写的是共享掩码 `*/cpus`，GStore 应用器写成员表，二者同为 shizuku-writable）。
/// * thermal [PerfModePreset.thermalEnabled] ← Scene 的温控方向；`thermal_disguise`
///   本身为 root-only/unsupported（`board_sensor_temp` 不在白名单），**不编码**，
///   统一退化为安全方向「保持降温」（见下）。
///
/// ## 显式偏差 / 未编码项（治理声明）
/// * **GPU 语义偏差**：Scene `gpu_pl_up N` 写的是 kgsl `min_pwrlevel`
///   （`gpu_min_pl - N`，`gpu_min_pl` 运行时读取，非常量）；既有应用器
///   （`perf_profile_auto_engine.dart`）把 [PerfModePreset.gpuLevel] 映射到
///   `max_pwrlevel`。故本表把 Scene 的**偏移值**原样存入 [PerfModePreset.gpuLevel]
///   以保留参考数据；方向/编号的最终对齐由 todo 26 应用器负责，本表**不**声称等价。
/// * **thermal**：Scene `fast` 用 `thermal_disguise 1`（root-only）绕过温控。该动作
///   **不在**本表编码；本表所有模式 `thermalEnabled=true`（安全方向：保持/恢复降温），
///   绝不把 root-only 的「关温控」编码进常量表。
/// * **未编码**（root-only/unsupported，见证据 §3）：`sched_config`、`sched_limit`、
///   `set_cpu_pl`、`set_hispeed_freq/load`、`core_ctl`(`set_ctl`/`ctl_on/off`)、
///   `set_core_online`、`cpu_boost`(`set_input_boost_freq`)、`msm_performance`、
///   `stune_top_app`、`cpuctl`、devfreq BW(`bw_*`)、`taskset`/affinity、
///   `thermal_disguise`/`disable_migt`、`pm *`、`miuibooster`、`renice`。
library;

import 'package:gstore/core/perf/perf_profile.dart';

/// Scene 风格变体（todo 3 §4）。
///
/// [wireName] 为稳定线格式；[defaultVariant] = [conservative]（更安全）。
enum PerfVariant {
  /// 激进（Scene `active.sh`）。
  active('active'),

  /// 温和（Scene `conservative.sh`；默认）。
  conservative('conservative');

  const PerfVariant(this.wireName);

  /// 稳定线格式名。
  final String wireName;

  /// 默认变体（温和）。
  static const PerfVariant defaultVariant = PerfVariant.conservative;

  /// 宽容解析（线格式名，大小写不敏感）；未知 / 缺失 → [defaultVariant]。绝不抛。
  static PerfVariant fromWire(Object? value) {
    if (value is PerfVariant) return value;
    if (value is String) {
      final lower = value.trim().toLowerCase();
      for (final v in PerfVariant.values) {
        if (v.wireName == lower) return v;
      }
    }
    return defaultVariant;
  }
}

/// Scene 中可用的 SoC 平台名（`ro.board.platform` 取值）。
const String kSocPlatformLahaina = 'lahaina';
const String kSocPlatformKona = 'kona';

/// 已编码的 SoC 平台集合（参考表；回退不在此集合）。
const Set<String> kSceneSocPlatforms = <String>{
  kSocPlatformLahaina,
  kSocPlatformKona,
};

/// Scene `reset_basic_governor` 目标 CPU governor（`policy{0,4,7}` 均写此值）。
const String kSceneCpuGovernor = 'schedutil';

/// cpuset 归属组名（GStore 应用器写 `/dev/cpuset/<name>/tasks`）。
///
/// 与 [PerfModePreset.forMode] 保持一致的语义；Scene 原脚本写的是共享掩码
/// `*/cpus`（见文件头偏差说明）。
const String kCpusetBackground = 'background';
const String kCpusetForeground = 'foreground';
const String kCpusetTopApp = 'top-app';

// ==================== 安全回退（默认表） ====================

/// 未知 / 未提供 SoC 时的**安全回退**（默认）表。
///
/// 仅含**设备无关**旋钮（cpuset 归属组 + thermal 安全方向），不含 SoC 专属频率，
/// 与 todo 24 的 [PerfModePreset.forMode] 逐值与语义一致（测试守护二者不漂移）。
const Map<PerfMode, PerfModePreset> kFallbackModeProfiles =
    <PerfMode, PerfModePreset>{
  PerfMode.powersave: PerfModePreset(
    cpuset: kCpusetBackground,
    thermalEnabled: true,
  ),
  PerfMode.balance: PerfModePreset.empty,
  PerfMode.performance: PerfModePreset(cpuset: kCpusetForeground),
  PerfMode.fast: PerfModePreset(cpuset: kCpusetTopApp),
};

// ==================== lahaina · conservative ====================
// 源：powercfg/lahaina/conservative.sh（`reset_basic_governor` + `set_cpu_freq`
// + `gpu_pl_up` + `cpuset`；`thermal_disguise` 为 root-only，不编码）。

const Map<PerfMode, PerfModePreset> kLahainaConservativeModeProfiles =
    <PerfMode, PerfModePreset>{
  // set_cpu_freq 300000 1708800 710400 1555200 844800 1785600
  PerfMode.powersave: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1708.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 1555.2),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 844.8, maxFreqMhz: 1785.6),
    },
    gpuLevel: 0, // gpu_pl_up 0
    cpuset: kCpusetBackground, // cpuset '0-2' '0-3' '0-3' '0-7'
    thermalEnabled: true, // thermal_disguise 0 → 保持降温
  ),
  // set_cpu_freq 300000 1804800 710400 1881600 844800 2035200
  PerfMode.balance: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 1881.6),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 844.8, maxFreqMhz: 2035.2),
    },
    gpuLevel: 0, // gpu_pl_up 0
    thermalEnabled: true,
  ),
  // set_cpu_freq 300000 1804800 710400 2419200 825600 2841600
  PerfMode.performance: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 2419.2),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 825.6, maxFreqMhz: 2841.6),
    },
    gpuLevel: 0, // gpu_pl_up 0
    cpuset: kCpusetForeground, // cpuset '0-1' '0-3' '0-6' '0-7'
    thermalEnabled: true,
  ),
  // set_cpu_freq 1401600 1804800 1440000 2600000 1555200 3200000
  PerfMode.fast: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1401.6, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1440, maxFreqMhz: 2600),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1555.2, maxFreqMhz: 3200),
    },
    gpuLevel: 2, // gpu_pl_up 2
    cpuset: kCpusetTopApp, // cpuset '0' '0-3' '0-6' '0-7'
    thermalEnabled: true, // Scene fast 的 thermal_disguise 1 为 root-only，不编码
  ),
};

// ==================== lahaina · active ====================
// 源：powercfg/lahaina/active.sh。相对 conservative：balance/performance/fast
// 频率更高、performance 的 gpu_pl_up 由 0→1。

const Map<PerfMode, PerfModePreset> kLahainaActiveModeProfiles =
    <PerfMode, PerfModePreset>{
  // set_cpu_freq 300000 1708800 710400 1555200 844800 1785600
  PerfMode.powersave: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1708.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 1555.2),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 844.8, maxFreqMhz: 1785.6),
    },
    gpuLevel: 0,
    cpuset: kCpusetBackground,
    thermalEnabled: true,
  ),
  // set_cpu_freq 300000 1804800 710400 1996800 844800 2380800
  PerfMode.balance: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 1996.8),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 844.8, maxFreqMhz: 2380.8),
    },
    gpuLevel: 0,
    thermalEnabled: true,
  ),
  // set_cpu_freq 300000 1804800 710400 2419200 825600 2841600
  PerfMode.performance: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 2419.2),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 825.6, maxFreqMhz: 2841.6),
    },
    gpuLevel: 1, // gpu_pl_up 1（active 相对 conservative 的提升）
    cpuset: kCpusetForeground,
    thermalEnabled: true,
  ),
  // set_cpu_freq 1401600 1804800 1766400 2600000 1670400 3200000
  PerfMode.fast: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1401.6, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1766.4, maxFreqMhz: 2600),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1670.4, maxFreqMhz: 3200),
    },
    gpuLevel: 2,
    cpuset: kCpusetTopApp,
    thermalEnabled: true,
  ),
};

// ==================== kona · conservative ====================
// 源：powercfg/kona/conservative.sh。

const Map<PerfMode, PerfModePreset> kKonaConservativeModeProfiles =
    <PerfMode, PerfModePreset>{
  // set_cpu_freq 300000 1708800 710400 1574400 844800 1747200
  PerfMode.powersave: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1708.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 1574.4),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 844.8, maxFreqMhz: 1747.2),
    },
    gpuLevel: 0,
    cpuset: kCpusetBackground,
    thermalEnabled: true,
  ),
  // set_cpu_freq 300000 1804800 710400 1862400 844800 2073600
  PerfMode.balance: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 1862.4),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 844.8, maxFreqMhz: 2073.6),
    },
    gpuLevel: 0,
    thermalEnabled: true,
  ),
  // set_cpu_freq 300000 1804800 710400 2419200 825600 2841600
  PerfMode.performance: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 2419.2),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 825.6, maxFreqMhz: 2841.6),
    },
    gpuLevel: 0,
    cpuset: kCpusetForeground,
    thermalEnabled: true,
  ),
  // set_cpu_freq 1248000 1804800 1478400 2600000 1516800 3200000
  PerfMode.fast: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1248, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1478.4, maxFreqMhz: 2600),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1516.8, maxFreqMhz: 3200),
    },
    gpuLevel: 2,
    cpuset: kCpusetTopApp,
    thermalEnabled: true,
  ),
};

// ==================== kona · active ====================
// 源：powercfg/kona/active.sh。

const Map<PerfMode, PerfModePreset> kKonaActiveModeProfiles =
    <PerfMode, PerfModePreset>{
  // set_cpu_freq 300000 1708800 710400 1574400 844800 1747200
  PerfMode.powersave: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1708.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 1574.4),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 844.8, maxFreqMhz: 1747.2),
    },
    gpuLevel: 0,
    cpuset: kCpusetBackground,
    thermalEnabled: true,
  ),
  // set_cpu_freq 300000 1804800 710400 2054400 844800 2361600
  PerfMode.balance: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 2054.4),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 844.8, maxFreqMhz: 2361.6),
    },
    gpuLevel: 0,
    thermalEnabled: true,
  ),
  // set_cpu_freq 300000 1804800 710400 2419200 825600 3200000
  PerfMode.performance: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 300, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 710.4, maxFreqMhz: 2419.2),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 825.6, maxFreqMhz: 3200),
    },
    gpuLevel: 1,
    cpuset: kCpusetForeground,
    thermalEnabled: true,
  ),
  // set_cpu_freq 1420800 1804800 1766400 2600000 1977600 3200000
  PerfMode.fast: PerfModePreset(
    cpuClusters: <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1420.8, maxFreqMhz: 1804.8),
      'policy4': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1766.4, maxFreqMhz: 2600),
      'policy7': PerfCpuClusterProfile(
        governor: kSceneCpuGovernor, minFreqMhz: 1977.6, maxFreqMhz: 3200),
    },
    gpuLevel: 2,
    cpuset: kCpusetTopApp,
    thermalEnabled: true,
  ),
};

// ==================== SoC → 变体 → 模式 索引 ====================

/// 参考表的 SoC 索引：`ro.board.platform` → 变体 → 模式 → 预设。
///
/// **仅参考**；未知键由 [modePresetForPlatform] 回退到 [kFallbackModeProfiles]。
const Map<String, Map<PerfVariant, Map<PerfMode, PerfModePreset>>>
    kSocModeProfiles =
    <String, Map<PerfVariant, Map<PerfMode, PerfModePreset>>>{
  kSocPlatformLahaina: <PerfVariant, Map<PerfMode, PerfModePreset>>{
    PerfVariant.active: kLahainaActiveModeProfiles,
    PerfVariant.conservative: kLahainaConservativeModeProfiles,
  },
  kSocPlatformKona: <PerfVariant, Map<PerfMode, PerfModePreset>>{
    PerfVariant.active: kKonaActiveModeProfiles,
    PerfVariant.conservative: kKonaConservativeModeProfiles,
  },
};

/// 回退表（默认）；见 [kFallbackModeProfiles]。
const Map<PerfMode, PerfModePreset> kDefaultModeProfiles = kFallbackModeProfiles;

// ==================== 查表 API（纯函数，常量表） ====================

/// 取 [socPlatform] + [variant] 对应的**整张**模式表；未知 → 回退表。
///
/// [socPlatform] 为运行时 `ro.board.platform`（可为 `null`）；仅
/// [kSceneSocPlatforms] 中的值命中参考表，其余 / 空一律回退。
Map<PerfMode, PerfModePreset> modeProfilesForPlatform(
  String? socPlatform, {
  PerfVariant variant = PerfVariant.defaultVariant,
}) {
  final trimmed = socPlatform?.trim();
  if (trimmed == null || trimmed.isEmpty) return kFallbackModeProfiles;
  final byVariant = kSocModeProfiles[trimmed];
  final table = byVariant?[variant];
  return table ?? kFallbackModeProfiles;
}

/// 取 [socPlatform] + [mode]（+ [variant]）对应的单条预设；未知 → 回退。
///
/// **绝不抛**：未知 SoC / 未知变体 / 未列模式一律返回安全回退预设。
PerfModePreset modePresetForPlatform(
  String? socPlatform,
  PerfMode mode, {
  PerfVariant variant = PerfVariant.defaultVariant,
}) {
  final table = modeProfilesForPlatform(socPlatform, variant: variant);
  return table[mode] ??
      kFallbackModeProfiles[mode] ??
      PerfModePreset.forMode(mode);
}
