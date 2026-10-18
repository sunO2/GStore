//! GPU 采集：频率（多路径回退）、忙率、名称。
//!
//! 频率缩放启发式（PERF_SPEC §4.2）：
//! - 列表 A（kgsl gpuclk / kgsl devfreq / `kernel/gpu/gpu_clock`）单位 Hz → ÷1e6；
//! - 列表 B（devfreq gpufreq / mali clock 等）→ `>1e6 → /1e6`，`>1000 → /1000`，否则原值。
//!
//! 忙率路径去掉尾部 `%`。

use serde::Serialize;

use super::util;

/// 频率缩放模式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FreqMode {
    /// 固定按 Hz 解释（÷1e6）。
    Hz,
    /// 启发式（>1e6 → /1e6；>1000 → /1000；否则原值）。
    Heuristic,
}

/// 频率探测路径（按回退顺序）。
pub struct FreqPath {
    pub path: &'static str,
    pub mode: FreqMode,
}

/// 频率回退链：列表 A 在前，列表 B 在后（与参考实现顺序一致）。
pub const FREQ_PATHS: &[FreqPath] = &[
    FreqPath { path: "/sys/class/kgsl/kgsl-3d0/gpuclk", mode: FreqMode::Hz },
    FreqPath { path: "/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq", mode: FreqMode::Hz },
    FreqPath { path: "/sys/kernel/gpu/gpu_clock", mode: FreqMode::Hz },
    FreqPath { path: "/sys/class/devfreq/gpufreq/cur_freq", mode: FreqMode::Heuristic },
    FreqPath { path: "/sys/class/devfreq/5000000.gpu/cur_freq", mode: FreqMode::Heuristic },
    FreqPath { path: "/sys/class/mali/misc/gpu_clock", mode: FreqMode::Heuristic },
    FreqPath { path: "/sys/kernel/debug/mali/clock", mode: FreqMode::Heuristic },
];

/// 忙率探测路径（按回退顺序）。
pub const BUSY_PATHS: &[&str] = &[
    "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage",
    "/sys/class/kgsl/kgsl-3d0/utilization",
    "/sys/kernel/gpu/gpu_busy",
];

/// GPU 频率原始值 → MHz。
pub fn scale_gpu_freq(raw: i64, mode: FreqMode) -> f64 {
    let v = raw as f64;
    match mode {
        FreqMode::Hz => v / 1_000_000.0,
        FreqMode::Heuristic => {
            if v > 1_000_000.0 {
                v / 1_000_000.0
            } else if v > 1000.0 {
                v / 1000.0
            } else {
                v
            }
        }
    }
}

/// 忙率原始值（可能带 `%`）→ 0..100。
pub fn parse_busy_percent(s: &str) -> Option<f64> {
    util::percent_token_i64(s).map(|v| util::clamp_percent(v as f64))
}

/// 回退链：`ro.hardware.gpu` → `ro.board.platform` → `ro.hardware.vulkan`。
pub fn gpu_name() -> Option<String> {
    ["ro.hardware.gpu", "ro.board.platform", "ro.hardware.vulkan"]
        .iter()
        .find_map(|k| util::getprop(k))
}

/// GPU 报告（单位显式：`freq_mhz`、`busy_percent`）。
#[derive(Debug, Clone, Serialize)]
pub struct GpuReport {
    pub name: Option<String>,
    pub freq_mhz: Option<f64>,
    pub freq_source: Option<String>,
    pub busy_percent: Option<f64>,
    pub busy_source: Option<String>,
}

/// 采集 GPU 状态（缺省字段为 null，不报错）。
pub fn collect() -> GpuReport {
    let mut freq_mhz = None;
    let mut freq_source = None;
    for fp in FREQ_PATHS {
        if let Some(raw) = util::read_i64(fp.path).or_else(|| {
            util::read_trimmed(fp.path).and_then(|s| util::first_token_i64(&s))
        }) {
            freq_mhz = Some(scale_gpu_freq(raw, fp.mode));
            freq_source = Some(fp.path.to_string());
            break;
        }
    }

    let mut busy_percent = None;
    let mut busy_source = None;
    for path in BUSY_PATHS {
        if let Some(s) = util::read_trimmed(path) {
            if let Some(p) = parse_busy_percent(&s) {
                busy_percent = Some(p);
                busy_source = Some(path.to_string());
                break;
            }
        }
    }

    GpuReport {
        name: gpu_name(),
        freq_mhz,
        freq_source,
        busy_percent,
        busy_source,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hz_mode_divides_by_million() {
        assert_eq!(scale_gpu_freq(800_000_000, FreqMode::Hz), 800.0);
        assert_eq!(scale_gpu_freq(585_000_000, FreqMode::Hz), 585.0);
    }

    #[test]
    fn heuristic_mode_scales_by_magnitude() {
        assert_eq!(scale_gpu_freq(800_000_000, FreqMode::Heuristic), 800.0);
        assert_eq!(scale_gpu_freq(800_000, FreqMode::Heuristic), 800.0);
        assert_eq!(scale_gpu_freq(585, FreqMode::Heuristic), 585.0);
    }

    #[test]
    fn freq_paths_follow_spec_fallback_order() {
        assert_eq!(FREQ_PATHS[0].path, "/sys/class/kgsl/kgsl-3d0/gpuclk");
        assert_eq!(FREQ_PATHS[0].mode, FreqMode::Hz);
        assert!(FREQ_PATHS.iter().any(|p| p.path == "/sys/kernel/gpu/gpu_clock"));
        assert!(FREQ_PATHS.iter().any(|p| p.path == "/sys/class/mali/misc/gpu_clock"));
    }

    #[test]
    fn busy_percent_strips_suffix_and_clamps() {
        assert_eq!(parse_busy_percent("42%\n"), Some(42.0));
        assert_eq!(parse_busy_percent("100"), Some(100.0));
        assert_eq!(parse_busy_percent("250%"), Some(100.0));
        assert_eq!(parse_busy_percent("n/a"), None);
    }
}
