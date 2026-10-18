//! 白名单 sysfs 单路径读取（**只读**）：写回校验用。
//!
//! `perf.sysfs.read` 的采集器。请求 `{path: string}`，**仅当** `path` 精确命中
//! [`SYSFS_ALLOWLIST`]（`*` = 单段通配，不跨 `/`）时才读取，返回
//! `{path, value, exists}`；任何非白名单路径（`/etc/passwd`、`/data/...`、含 `..`
//! 的穿越路径、含 shell 元字符的路径）一律返回结构化 `invalid_arg`，
//! **绝不返回值、绝不 panic**。本采集器**不写任何节点**。
//!
//! ## 为什么写回校验还可能需要特权 shell 回读
//! 本方法以**模块进程（App）自身 uid** 读取节点。而 Wave 4 的写操作经 Shizuku
//! 特权 shell（uid 2000）执行（见 `lib/core/perf/privileged_shell.dart`）。对
//! **非 world-readable** 的节点，App uid 可能无读权限：此时 `exists:false`、
//! `value:null`（不是错误）。要完成写回校验，调用方应**同样经特权 shell 回读**
//! ——读取侧的 uid / 上下文必须与写入侧一致，否则校验结果无意义。
//!
//! 白名单派生自 `perf.tunables` 的输出面：cpufreq `scaling_*` / `cpuinfo_*`、
//! cpuset `cpus` / `mems`、热区 `temp` / `mode`、GPU 频率 / governor / 功耗档位。

use serde::Serialize;

use gstore_contract::error::ModuleError;

use super::util;

/// 允许读取的 sysfs / cpuset 路径白名单（`*` = **单段**通配，不跨 `/`）。
///
/// 派生自 `perf.tunables` 输出面，**绝不**包含 `/data`、`/etc` 等任意路径：
/// - **cpufreq**（`tunables.cpu_clusters`）：每策略簇 `policy*` 与每核 `cpu*` 的
///   `scaling_*` / `cpuinfo_*`；
/// - **cpuset**（`tunables.cpusets`）：`/dev/cpuset/<name>/` 的 `cpus` / `mems`；
/// - **热区**（`tunables.thermal_zones`）：`thermal_zone*/temp` 与 `mode`；
/// - **GPU**（`tunables.gpu` + `collectors::gpu::FREQ_PATHS`）：可用/当前频率、
///   governor、功耗档位（kgsl / devfreq / mali / kernel-gpu 路径表）。
pub const SYSFS_ALLOWLIST: &[&str] = &[
    // ---- cpufreq：策略簇（tunables.cpu_clusters） ----
    "/sys/devices/system/cpu/cpufreq/policy*/scaling_governor",
    "/sys/devices/system/cpu/cpufreq/policy*/scaling_min_freq",
    "/sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq",
    "/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq",
    "/sys/devices/system/cpu/cpufreq/policy*/scaling_available_governors",
    "/sys/devices/system/cpu/cpufreq/policy*/scaling_available_frequencies",
    "/sys/devices/system/cpu/cpufreq/policy*/cpuinfo_min_freq",
    "/sys/devices/system/cpu/cpufreq/policy*/cpuinfo_max_freq",
    // ---- cpufreq：每核（cpu.rs 频率/调速器） ----
    "/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor",
    "/sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq",
    "/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq",
    "/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq",
    "/sys/devices/system/cpu/cpu*/cpufreq/scaling_available_governors",
    "/sys/devices/system/cpu/cpu*/cpufreq/scaling_available_frequencies",
    "/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_min_freq",
    "/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq",
    // ---- cpuset（tunables.cpusets） ----
    "/dev/cpuset/*/cpus",
    "/dev/cpuset/*/mems",
    // ---- 热区（tunables.thermal_zones） ----
    "/sys/class/thermal/thermal_zone*/temp",
    "/sys/class/thermal/thermal_zone*/mode",
    // ---- GPU 频率 / governor / 功耗档位（tunables.gpu + gpu.rs FREQ_PATHS） ----
    "/sys/class/kgsl/kgsl-3d0/gpuclk",
    "/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies",
    "/sys/class/kgsl/kgsl-3d0/num_pwrlevels",
    "/sys/class/kgsl/kgsl-3d0/governor",
    "/sys/class/kgsl/kgsl-3d0/min_gpuclk",
    "/sys/class/kgsl/kgsl-3d0/max_gpuclk",
    "/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq",
    "/sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies",
    "/sys/class/kgsl/kgsl-3d0/devfreq/governor",
    "/sys/class/kgsl/kgsl-3d0/devfreq/min_freq",
    "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq",
    "/sys/kernel/gpu/gpu_clock",
    "/sys/kernel/gpu/gpu_available_frequencies",
    "/sys/class/devfreq/*/cur_freq",
    "/sys/class/devfreq/*/available_frequencies",
    "/sys/class/devfreq/*/governor",
    "/sys/class/devfreq/*/min_freq",
    "/sys/class/devfreq/*/max_freq",
    "/sys/class/mali/misc/gpu_clock",
    "/sys/kernel/debug/mali/clock",
];

/// 单路径读取结果（成功信封的 `data`）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SysfsReadResult {
    /// 读取的绝对路径（回显请求）。
    pub path: String,
    /// 文件内容（去首尾空白）；不存在 / 不可读 / 内容为空 → `null`。
    pub value: Option<String>,
    /// 文件是否存在且可读（存在但内容为空仍为 `true`）。
    pub exists: bool,
}

/// 路径形状不安全（空、非绝对、穿越、控制字符 / 空白 / `//` / `\`）。
///
/// 该检查先于白名单匹配：任何可疑形状一律拒绝（fail-closed）。
fn has_unsafe_shape(path: &str) -> bool {
    if path.is_empty() || !path.starts_with('/') {
        return true;
    }
    if path.contains("//") || path.contains('\\') {
        return true;
    }
    if path
        .chars()
        .any(|c| c.is_control() || c == ' ' || c == '\t')
    {
        return true;
    }
    path.split('/').any(|seg| seg == ".." || seg == ".")
}

/// 单段 glob 匹配（`*` 匹配任意字符序列（含空），`?` 匹配单字符）。
fn segment_matches(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let (mut pi, mut ti) = (0usize, 0usize);
    let mut star: Option<usize> = None;
    let mut mark = 0usize;
    while ti < t.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == t[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            mark = ti;
            pi += 1;
        } else if let Some(s) = star {
            pi = s + 1;
            mark += 1;
            ti = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

/// 段数一致且逐段匹配（`*` 不跨 `/`）。
fn glob_match(pattern: &str, path: &str) -> bool {
    let pat: Vec<&str> = pattern.split('/').collect();
    let seg: Vec<&str> = path.split('/').collect();
    pat.len() == seg.len()
        && pat
            .iter()
            .zip(seg.iter())
            .all(|(p, s)| segment_matches(p, s))
}

/// 路径是否命中白名单（形状安全 + 精确段匹配）。
pub fn is_allowlisted(path: &str) -> bool {
    !has_unsafe_shape(path) && SYSFS_ALLOWLIST.iter().any(|p| glob_match(p, path))
}

/// 白名单校验 + 读取（读取闭包可注入，便于单测）。
///
/// 非白名单路径**在校验阶段即返回 `invalid_arg`**，读取闭包**不会被调用**。
pub fn read_allowlisted<F>(path: &str, read: F) -> Result<SysfsReadResult, ModuleError>
where
    F: Fn(&str) -> Option<String>,
{
    if !is_allowlisted(path) {
        return Err(ModuleError::invalid_arg(format!(
            "path is not in the sysfs read allowlist: {path}"
        )));
    }
    let raw = read(path);
    Ok(SysfsReadResult {
        path: path.to_string(),
        value: raw
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string),
        exists: raw.is_some(),
    })
}

/// 采集：以真实文件系统读取白名单内的单个节点（非白名单 → `invalid_arg`）。
pub fn collect(path: &str) -> Result<SysfsReadResult, ModuleError> {
    read_allowlisted(path, util::read_file)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn allowlisted_cpufreq_path_returns_value() {
        let result = read_allowlisted("/sys/devices/system/cpu/cpufreq/policy0/scaling_governor", |p| {
            assert_eq!(p, "/sys/devices/system/cpu/cpufreq/policy0/scaling_governor");
            Some("schedutil\n".to_string())
        })
        .unwrap();
        assert_eq!(result.path, "/sys/devices/system/cpu/cpufreq/policy0/scaling_governor");
        assert_eq!(result.value.as_deref(), Some("schedutil"));
        assert!(result.exists);
    }

    #[test]
    fn allowlisted_thermal_and_cpuset_and_gpu_paths_allowed() {
        assert!(is_allowlisted("/sys/class/thermal/thermal_zone0/temp"));
        assert!(is_allowlisted("/sys/class/thermal/thermal_zone3/mode"));
        assert!(is_allowlisted("/dev/cpuset/top-app/cpus"));
        assert!(is_allowlisted("/dev/cpuset/foreground/mems"));
        assert!(is_allowlisted("/sys/class/kgsl/kgsl-3d0/gpuclk"));
        assert!(is_allowlisted("/sys/class/devfreq/gpufreq/cur_freq"));
        assert!(is_allowlisted("/sys/class/devfreq/5000000.gpu/governor"));
        assert!(is_allowlisted("/sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq"));
    }

    #[test]
    fn non_allowlisted_paths_are_rejected_without_reading() {
        let reads = Cell::new(0);
        let spy = |_p: &str| {
            reads.set(reads.get() + 1);
            Some("SHOULD-NOT-HAPPEN".to_string())
        };
        for path in [
            "/etc/passwd",
            "/data/data/com.x/shared_prefs/secret.xml",
            "/data/local/tmp/x",
            "/proc/self/environ",
        ] {
            let err = read_allowlisted(path, spy).unwrap_err();
            assert_eq!(
                err.status,
                gstore_contract::error::StatusCode::InvalidArgument,
                "{path} must be invalid_arg"
            );
        }
        assert_eq!(reads.get(), 0, "reader must never be invoked for rejected paths");
    }

    #[test]
    fn traversal_and_unsafe_shapes_are_rejected() {
        for path in [
            "/dev/cpuset/../cpus",
            "/sys/devices/system/cpu/cpufreq/policy0/../../../../etc/passwd",
            "/sys/class/thermal/thermal_zone0/temp\n",
            "/sys/class/thermal/thermal_zone0/ temp",
            "relative/sys/path",
            "",
        ] {
            let err = read_allowlisted(path, |_| Some("x".to_string())).unwrap_err();
            assert_eq!(err.status, gstore_contract::error::StatusCode::InvalidArgument);
        }
    }

    #[test]
    fn wildcard_does_not_cross_segments() {
        // `*` 是单段通配：不能跨 `/` 匹配额外层级。
        assert!(!is_allowlisted(
            "/sys/class/thermal/thermal_zone0/extra/temp"
        ));
        assert!(!is_allowlisted("/dev/cpuset/top-app/extra/cpus"));
    }

    #[test]
    fn absent_allowlisted_node_is_ok_but_not_exists() {
        let result =
            read_allowlisted("/sys/class/thermal/thermal_zone9/temp", |_| None).unwrap();
        assert!(!result.exists);
        assert!(result.value.is_none());
        assert_eq!(result.path, "/sys/class/thermal/thermal_zone9/temp");
    }

    #[test]
    fn empty_file_exists_true_value_null() {
        let result =
            read_allowlisted("/sys/class/thermal/thermal_zone0/temp", |_| Some("  \n".to_string()))
                .unwrap();
        assert!(result.exists);
        assert!(result.value.is_none());
    }
}
