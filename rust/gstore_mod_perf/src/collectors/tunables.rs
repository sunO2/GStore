//! 可控面枚举（**只读**）：CPU cpufreq 策略簇、cpuset、热区/散热设备、GPU 频率/功耗档位。
//!
//! 该采集器**只枚举**「有哪些可以控制的旋钮」以及它们的取值范围，绝不写入任何节点：
//! - 每簇 `cpufreq` 策略目录（`policy*`）+ `scaling_available_governors` /
//!   `scaling_available_frequencies` / 当前 governor / min / max；
//! - `/dev/cpuset/` 下的子集（名称 + `cpus` / `mems`）；
//! - `/sys/class/thermal/thermal_zone*`（`type` + 可写 `mode`）与
//!   `cooling_device*`（`type` / `cur_state` / `max_state`）；
//! - GPU 可用频率 / 功耗档位（**路径表风格**，复用 `gpu.rs` 的缩放启发式）。
//!
//! 所有读取均在节点缺失时返回空列表 / `null`，**绝不 panic**。
//! 单位显式：`*_mhz`；GPU 频率复用 `gpu::scale_gpu_freq`（Hz→÷1e6 或启发式）。

use serde::Serialize;

use super::gpu::{self, FreqMode, FreqPath};
use super::{cpu, util};

/// GPU 可用频率探测路径（路径表，按回退顺序；模式与 `gpu.rs` 的 `cur_freq` 列表一致）。
pub const GPU_FREQ_PATHS: &[FreqPath] = &[
    FreqPath {
        path: "/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies",
        mode: FreqMode::Hz,
    },
    FreqPath {
        path: "/sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies",
        mode: FreqMode::Hz,
    },
    FreqPath {
        path: "/sys/kernel/gpu/gpu_available_frequencies",
        mode: FreqMode::Hz,
    },
    FreqPath {
        path: "/sys/class/devfreq/gpufreq/available_frequencies",
        mode: FreqMode::Heuristic,
    },
    FreqPath {
        path: "/sys/class/devfreq/5000000.gpu/available_frequencies",
        mode: FreqMode::Heuristic,
    },
];

/// GPU governor 探测路径（可写旋钮，路径表风格）。
pub const GPU_GOVERNOR_PATHS: &[&str] = &[
    "/sys/class/kgsl/kgsl-3d0/devfreq/governor",
    "/sys/class/kgsl/kgsl-3d0/governor",
    "/sys/class/devfreq/gpufreq/governor",
    "/sys/class/devfreq/5000000.gpu/governor",
];

/// GPU 功耗档位数探测路径（`num_pwrlevels`，整数）。
pub const GPU_POWER_PATHS: &[&str] = &[
    "/sys/class/kgsl/kgsl-3d0/num_pwrlevels",
    "/sys/class/kgsl/kgsl-3d0/devfreq/num_pwrlevels",
];

/// 解析 CPULIST 形式（`0-3`、`0,2-3`、`0 1 2`）为去重升序核编号。
///
/// 容忍空白、逗号、区间；非法 token 跳过。返回空列表表示不可解析/无值。
pub fn parse_cpu_list(s: &str) -> Vec<u32> {
    let mut out: Vec<u32> = Vec::new();
    for part in s.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if let Some((a, b)) = part.split_once('-') {
            if let (Ok(a), Ok(b)) = (a.trim().parse::<u32>(), b.trim().parse::<u32>()) {
                if a <= b {
                    out.extend(a..=b);
                }
            }
        } else if let Ok(n) = part.parse::<u32>() {
            out.push(n);
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

/// GPU 频率内容（空格分隔原始值）→ 按模式缩放后的 MHz 列表（去重升序）。
pub fn parse_gpu_available_freqs(content: &str, mode: FreqMode) -> Vec<f64> {
    let mut v: Vec<f64> = content
        .split_whitespace()
        .filter_map(|t| t.parse::<i64>().ok())
        .map(|raw| gpu::scale_gpu_freq(raw, mode))
        .collect();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    v.dedup();
    v
}

fn trimmed_nonempty(s: Option<String>) -> Option<String> {
    s.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

/// 一个 cpufreq 策略簇（对应 `/sys/devices/system/cpu/cpufreq/policyN`）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CpuCluster {
    /// 策略目录名（如 `policy0`）。
    pub policy: String,
    /// `related_cpus` 展开后的核编号。
    pub related_cpus: Vec<u32>,
    /// `scaling_available_governors`（有序）。
    pub available_governors: Vec<String>,
    /// 当前 `scaling_governor`。
    pub governor: Option<String>,
    /// `scaling_available_frequencies` → MHz（去重升序）。
    pub available_frequencies_mhz: Vec<f64>,
    /// 当前下限（`scaling_min_freq`，回退 `cpuinfo_min_freq`）→ MHz。
    pub min_freq_mhz: Option<f64>,
    /// 当前上限（`scaling_max_freq`，回退 `cpuinfo_max_freq`）→ MHz。
    pub max_freq_mhz: Option<f64>,
}

/// 由读取闭包构造策略簇（纯函数，可单测）。`read(attr)` 返回该策略目录下的属性内容。
pub fn build_cluster<F>(policy: String, read: F) -> CpuCluster
where
    F: Fn(&str) -> Option<String>,
{
    CpuCluster {
        policy,
        related_cpus: read("related_cpus")
            .map(|s| parse_cpu_list(&s))
            .unwrap_or_default(),
        available_governors: read("scaling_available_governors")
            .map(|s| cpu::parse_available_governors(&s))
            .unwrap_or_default(),
        governor: trimmed_nonempty(read("scaling_governor")),
        available_frequencies_mhz: read("scaling_available_frequencies")
            .map(|s| cpu::parse_available_frequencies(&s))
            .unwrap_or_default(),
        min_freq_mhz: read("scaling_min_freq")
            .or_else(|| read("cpuinfo_min_freq"))
            .and_then(|s| util::first_token_i64(&s))
            .map(cpu::freq_khz_to_mhz),
        max_freq_mhz: read("scaling_max_freq")
            .or_else(|| read("cpuinfo_max_freq"))
            .and_then(|s| util::first_token_i64(&s))
            .map(cpu::freq_khz_to_mhz),
    }
}

/// 一个 cpuset（`/dev/cpuset/<name>`，如 `top-app` / `foreground` / `background`）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Cpuset {
    pub name: String,
    /// `cpus`（原始字符串，如 `0-7`）。
    pub cpus: Option<String>,
    /// `mems`（原始字符串，如 `0`）。
    pub mems: Option<String>,
}

/// 由读取闭包构造 cpuset（纯函数，可单测）。
pub fn build_cpuset<F>(name: String, read: F) -> Cpuset
where
    F: Fn(&str) -> Option<String>,
{
    Cpuset {
        name,
        cpus: trimmed_nonempty(read("cpus")),
        mems: trimmed_nonempty(read("mems")),
    }
}

/// 一个热区（`/sys/class/thermal/thermal_zone*`）的可控面（`type` + 可写 `mode`）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ThermalTunable {
    pub zone: String,
    #[serde(rename = "type")]
    pub kind: Option<String>,
    /// 可写 `mode`（如 `enabled` / `disabled` / `step_wise`）。
    pub mode: Option<String>,
}

/// 由读取闭包构造热区可控项（纯函数，可单测）。
pub fn build_thermal_zone<F>(zone: String, read: F) -> ThermalTunable
where
    F: Fn(&str) -> Option<String>,
{
    ThermalTunable {
        zone,
        kind: trimmed_nonempty(read("type")),
        mode: trimmed_nonempty(read("mode")),
    }
}

/// 一个散热设备（`/sys/class/thermal/cooling_device*`）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CoolingTunable {
    pub device: String,
    #[serde(rename = "type")]
    pub kind: Option<String>,
    pub cur_state: Option<i64>,
    pub max_state: Option<i64>,
}

/// 由读取闭包构造散热设备（纯函数，可单测）。
pub fn build_cooling<F>(device: String, read: F) -> CoolingTunable
where
    F: Fn(&str) -> Option<String>,
{
    CoolingTunable {
        device,
        kind: trimmed_nonempty(read("type")),
        cur_state: read("cur_state").and_then(|s| util::first_token_i64(&s)),
        max_state: read("max_state").and_then(|s| util::first_token_i64(&s)),
    }
}

/// GPU 可控面（可用频率 / governor / 功耗档位；字段缺失为 `null`）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GpuTunables {
    pub available_frequencies_mhz: Vec<f64>,
    pub freq_source: Option<String>,
    pub governor: Option<String>,
    pub governor_source: Option<String>,
    pub power_levels: Option<i64>,
    pub power_source: Option<String>,
}

/// 由读取闭包（键为**绝对路径**）构造 GPU 可控面（纯函数，可单测）。
pub fn gpu_tunables<F>(read: F) -> GpuTunables
where
    F: Fn(&str) -> Option<String>,
{
    let mut available_frequencies_mhz = Vec::new();
    let mut freq_source = None;
    for fp in GPU_FREQ_PATHS {
        if let Some(content) = read(fp.path) {
            let freqs = parse_gpu_available_freqs(&content, fp.mode);
            if !freqs.is_empty() {
                available_frequencies_mhz = freqs;
                freq_source = Some(fp.path.to_string());
                break;
            }
        }
    }

    let mut governor = None;
    let mut governor_source = None;
    for path in GPU_GOVERNOR_PATHS {
        if let Some(v) = trimmed_nonempty(read(path)) {
            governor = Some(v);
            governor_source = Some(path.to_string());
            break;
        }
    }

    let mut power_levels = None;
    let mut power_source = None;
    for path in GPU_POWER_PATHS {
        if let Some(v) = read(path).and_then(|s| util::first_token_i64(&s)) {
            power_levels = Some(v);
            power_source = Some(path.to_string());
            break;
        }
    }

    GpuTunables {
        available_frequencies_mhz,
        freq_source,
        governor,
        governor_source,
        power_levels,
        power_source,
    }
}

/// 可控面报告（全部为数组，节点缺失时为空数组）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TunablesReport {
    pub cpu_clusters: Vec<CpuCluster>,
    pub cpusets: Vec<Cpuset>,
    pub thermal_zones: Vec<ThermalTunable>,
    pub cooling_devices: Vec<CoolingTunable>,
    pub gpu: GpuTunables,
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn enumerate_clusters() -> Vec<CpuCluster> {
    const ROOT: &str = "/sys/devices/system/cpu/cpufreq";
    let Ok(entries) = std::fs::read_dir(ROOT) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
        .filter(|n| n.starts_with("policy"))
        .collect();
    names.sort();
    names
        .into_iter()
        .map(|name| {
            let base = format!("{ROOT}/{name}");
            build_cluster(name, |attr| util::read_trimmed(&format!("{base}/{attr}")))
        })
        .collect()
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn enumerate_cpusets() -> Vec<Cpuset> {
    const ROOT: &str = "/dev/cpuset";
    let Ok(entries) = std::fs::read_dir(ROOT) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter(|e| e.path().is_dir())
        .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
        .collect();
    names.sort();
    names
        .into_iter()
        .map(|name| {
            let base = format!("{ROOT}/{name}");
            build_cpuset(name, |attr| util::read_trimmed(&format!("{base}/{attr}")))
        })
        .collect()
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn enumerate_thermal_zones() -> Vec<ThermalTunable> {
    const ROOT: &str = "/sys/class/thermal";
    let Ok(entries) = std::fs::read_dir(ROOT) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
        .filter(|n| n.starts_with("thermal_zone"))
        .collect();
    names.sort();
    names
        .into_iter()
        .map(|name| {
            let base = format!("{ROOT}/{name}");
            build_thermal_zone(name, |attr| util::read_trimmed(&format!("{base}/{attr}")))
        })
        .collect()
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn enumerate_cooling() -> Vec<CoolingTunable> {
    const ROOT: &str = "/sys/class/thermal";
    let Ok(entries) = std::fs::read_dir(ROOT) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
        .filter(|n| n.starts_with("cooling_device"))
        .collect();
    names.sort();
    names
        .into_iter()
        .map(|name| {
            let base = format!("{ROOT}/{name}");
            build_cooling(name, |attr| util::read_trimmed(&format!("{base}/{attr}")))
        })
        .collect()
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn enumerate_clusters() -> Vec<CpuCluster> {
    Vec::new()
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn enumerate_cpusets() -> Vec<Cpuset> {
    Vec::new()
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn enumerate_thermal_zones() -> Vec<ThermalTunable> {
    Vec::new()
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn enumerate_cooling() -> Vec<CoolingTunable> {
    Vec::new()
}

/// 采集全部可控面（只读；节点缺失时各数组为空 / `gpu` 各字段为 `null`）。
pub fn collect() -> TunablesReport {
    TunablesReport {
        cpu_clusters: enumerate_clusters(),
        cpusets: enumerate_cpusets(),
        thermal_zones: enumerate_thermal_zones(),
        cooling_devices: enumerate_cooling(),
        gpu: gpu_tunables(util::read_trimmed),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cpu_list_handles_ranges_commas_and_garbage() {
        assert_eq!(parse_cpu_list("0-3\n"), vec![0, 1, 2, 3]);
        assert_eq!(parse_cpu_list("0-1,3,5-6"), vec![0, 1, 3, 5, 6]);
        assert_eq!(parse_cpu_list("0-1,3,5-6,3"), vec![0, 1, 3, 5, 6]); // 去重
        assert!(parse_cpu_list("").is_empty());
        assert!(parse_cpu_list("garbage").is_empty());
        // 空格分隔非 CPULIST 形式 → 不可解析（实时 `related_cpus` 用逗号形式）
        assert!(parse_cpu_list("2 1 2").is_empty());
        // 反向区间被忽略
        assert!(parse_cpu_list("5-1").is_empty());
    }

    #[test]
    fn build_cluster_reads_cpufreq_fixture() {
        let read = |attr: &str| -> Option<String> {
            match attr {
                "related_cpus" => Some("0-3\n".into()),
                "scaling_available_governors" => Some("schedutil performance powersave\n".into()),
                "scaling_governor" => Some("schedutil\n".into()),
                "scaling_available_frequencies" => Some("300000 1800000 2400000\n".into()),
                "scaling_min_freq" => Some("300000\n".into()),
                "scaling_max_freq" => Some("2400000\n".into()),
                _ => None,
            }
        };
        let c = build_cluster("policy0".into(), read);
        assert_eq!(c.policy, "policy0");
        assert_eq!(c.related_cpus, vec![0, 1, 2, 3]);
        assert_eq!(c.available_governors.len(), 3);
        assert_eq!(c.governor.as_deref(), Some("schedutil"));
        assert_eq!(c.available_frequencies_mhz, vec![300.0, 1800.0, 2400.0]);
        assert_eq!(c.min_freq_mhz, Some(300.0));
        assert_eq!(c.max_freq_mhz, Some(2400.0));
    }

    #[test]
    fn build_cluster_tolerates_missing_attrs_and_falls_back_to_cpuinfo() {
        let read = |attr: &str| -> Option<String> {
            match attr {
                "cpuinfo_min_freq" => Some("300000\n".into()),
                "cpuinfo_max_freq" => Some("1800000\n".into()),
                _ => None,
            }
        };
        let c = build_cluster("policy4".into(), read);
        assert_eq!(c.policy, "policy4");
        assert!(c.related_cpus.is_empty());
        assert!(c.available_governors.is_empty());
        assert!(c.governor.is_none());
        assert!(c.available_frequencies_mhz.is_empty());
        assert_eq!(c.min_freq_mhz, Some(300.0));
        assert_eq!(c.max_freq_mhz, Some(1800.0));
    }

    #[test]
    fn build_cpuset_reads_names_cpus_mems() {
        let read = |attr: &str| -> Option<String> {
            match attr {
                "cpus" => Some("0-7\n".into()),
                "mems" => Some("0\n".into()),
                _ => None,
            }
        };
        let cs = build_cpuset("top-app".into(), read);
        assert_eq!(cs.name, "top-app");
        assert_eq!(cs.cpus.as_deref(), Some("0-7"));
        assert_eq!(cs.mems.as_deref(), Some("0"));

        let empty = build_cpuset("background".into(), |_| None);
        assert!(empty.cpus.is_none());
        assert!(empty.mems.is_none());
    }

    #[test]
    fn build_thermal_zone_exposes_mode() {
        let read = |attr: &str| -> Option<String> {
            match attr {
                "type" => Some("cpu-0-0-0\n".into()),
                "mode" => Some("enabled\n".into()),
                _ => None,
            }
        };
        let z = build_thermal_zone("thermal_zone0".into(), read);
        assert_eq!(z.zone, "thermal_zone0");
        assert_eq!(z.kind.as_deref(), Some("cpu-0-0-0"));
        assert_eq!(z.mode.as_deref(), Some("enabled"));

        let blank = build_thermal_zone("thermal_zone1".into(), |_| Some("   \n".into()));
        assert!(blank.kind.is_none());
        assert!(blank.mode.is_none());
    }

    #[test]
    fn build_cooling_reads_states() {
        let read = |attr: &str| -> Option<String> {
            match attr {
                "type" => Some("cpu\n".into()),
                "cur_state" => Some("1\n".into()),
                "max_state" => Some("10\n".into()),
                _ => None,
            }
        };
        let d = build_cooling("cooling_device0".into(), read);
        assert_eq!(d.kind.as_deref(), Some("cpu"));
        assert_eq!(d.cur_state, Some(1));
        assert_eq!(d.max_state, Some(10));
    }

    #[test]
    fn gpu_freq_paths_follow_gpu_style_table() {
        assert_eq!(
            GPU_FREQ_PATHS[0].path,
            "/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies"
        );
        assert_eq!(GPU_FREQ_PATHS[0].mode, FreqMode::Hz);
        assert!(GPU_FREQ_PATHS
            .iter()
            .any(|p| p.path == "/sys/class/devfreq/gpufreq/available_frequencies"));
        assert!(GPU_FREQ_PATHS
            .iter()
            .any(|p| p.mode == FreqMode::Heuristic));
    }

    #[test]
    fn parse_gpu_available_freqs_scales_per_mode() {
        assert_eq!(
            parse_gpu_available_freqs("800000000 585000000\n", FreqMode::Hz),
            vec![585.0, 800.0]
        );
        assert_eq!(
            parse_gpu_available_freqs("800000 585000\n", FreqMode::Heuristic),
            vec![585.0, 800.0]
        );
        assert!(parse_gpu_available_freqs("", FreqMode::Hz).is_empty());
        assert!(parse_gpu_available_freqs("garbage", FreqMode::Hz).is_empty());
    }

    #[test]
    fn gpu_tunables_picks_first_available_path_and_scales() {
        let read = |path: &str| -> Option<String> {
            match path {
                // 列表 A 首项缺失 → 回退到 A 次项。
                "/sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies" => {
                    Some("800000000 500000000\n".into())
                }
                "/sys/class/kgsl/kgsl-3d0/devfreq/governor" => Some("msm-adreno-tz\n".into()),
                "/sys/class/kgsl/kgsl-3d0/num_pwrlevels" => Some("14\n".into()),
                _ => None,
            }
        };
        let g = gpu_tunables(read);
        assert_eq!(g.available_frequencies_mhz, vec![500.0, 800.0]);
        assert_eq!(
            g.freq_source.as_deref(),
            Some("/sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies")
        );
        assert_eq!(g.governor.as_deref(), Some("msm-adreno-tz"));
        assert_eq!(
            g.governor_source.as_deref(),
            Some("/sys/class/kgsl/kgsl-3d0/devfreq/governor")
        );
        assert_eq!(g.power_levels, Some(14));
        assert_eq!(
            g.power_source.as_deref(),
            Some("/sys/class/kgsl/kgsl-3d0/num_pwrlevels")
        );
    }

    #[test]
    fn gpu_tunables_all_absent_is_empty_not_error() {
        let g = gpu_tunables(|_| None);
        assert!(g.available_frequencies_mhz.is_empty());
        assert!(g.freq_source.is_none());
        assert!(g.governor.is_none());
        assert!(g.governor_source.is_none());
        assert!(g.power_levels.is_none());
        assert!(g.power_source.is_none());
    }

    #[test]
    fn collect_tolerates_node_less_environment() {
        // 容器/桌面通常没有 policy*、/dev/cpuset、thermal —— 必须返回数组而非 panic。
        let r = collect();
        assert!(r
            .cpu_clusters
            .iter()
            .all(|c| c.policy.starts_with("policy")));
        assert!(r.cpusets.iter().all(|c| !c.name.is_empty()));
        assert!(r.cooling_devices.iter().all(|d| d.device.starts_with("cooling_device")));
        assert!(r.thermal_zones.iter().all(|z| z.zone.starts_with("thermal_zone")));
        // GPU 面始终存在（可为空/None）。
        let _ = &r.gpu;
    }
}
