//! CPU 采集：`/proc/stat` 增量占用率、cpufreq sysfs 频率、`/proc/loadavg`、`/proc/cpuinfo`。
//!
//! **关键修正**：参考 App 显示的是被丢弃的真实增量算法 + 随机数伪造（PERF_SPEC §3.1/B3）。
//! 本模块只实现可信算法：`usage% = 100 - Δidle*100/Δtotal`（clamp 0..100），
//! 由调用方保存上次样本、两次调用间取增量 —— **绝不 sleep**。

use std::collections::BTreeMap;

use serde::Serialize;

use super::util;

/// 单个 CPU（聚合或某核）的一次 `/proc/stat` 节拍快照。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CpuTick {
    /// `Σfields[1..]`（user..guest_nice）。
    pub total: u64,
    /// `fields[4]`（user,nice,system,**idle**,…）→ 0 基下标 3。
    pub idle: u64,
}

/// `/proc/stat` 解析结果：聚合行 + 各核（按 cpu 编号升序）。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CpuStat {
    pub aggregate: CpuTick,
    pub per_core: Vec<CpuTick>,
}

/// 解析 `/proc/stat`（只关心 `cpu` / `cpuN` 行）。
pub fn parse_proc_stat(content: &str) -> CpuStat {
    let mut stat = CpuStat::default();
    let mut cores: Vec<(usize, CpuTick)> = Vec::new();
    for line in content.lines() {
        if !line.starts_with("cpu") {
            continue;
        }
        let mut it = line.split_whitespace();
        let label = it.next().unwrap_or("");
        let fields: Vec<u64> = it.filter_map(|t| t.parse::<u64>().ok()).collect();
        if fields.len() < 4 {
            continue;
        }
        let tick = CpuTick {
            total: fields.iter().sum(),
            idle: fields[3],
        };
        if label == "cpu" {
            stat.aggregate = tick;
        } else if let Ok(idx) = label[3..].parse::<usize>() {
            cores.push((idx, tick));
        }
    }
    cores.sort_by_key(|(i, _)| *i);
    stat.per_core = cores.into_iter().map(|(_, t)| t).collect();
    stat
}

/// 两次快照的占用率（%）。`Δt <= 0` 或 `Δtotal == 0` 时返回 0。
pub fn usage_delta(prev: CpuTick, cur: CpuTick) -> f64 {
    let dtotal = cur.total.saturating_sub(prev.total);
    let didle = cur.idle.saturating_sub(prev.idle);
    if dtotal == 0 {
        return 0.0;
    }
    util::clamp_percent(100.0 - (didle as f64 * 100.0 / dtotal as f64))
}

/// kHz → MHz。
pub fn freq_khz_to_mhz(khz: i64) -> f64 {
    khz as f64 / 1000.0
}

/// 解析 `/sys/.../available_frequencies`（空格分隔 kHz）→ 去重升序 MHz。
pub fn parse_available_frequencies(content: &str) -> Vec<f64> {
    let mut v: Vec<f64> = content
        .split_whitespace()
        .filter_map(|t| t.parse::<i64>().ok())
        .map(freq_khz_to_mhz)
        .collect();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    v.dedup();
    v
}

/// 解析 `/proc/cpuinfo` 的 `cpu MHz` 行（x86 常见；ARM 通常没有）。
pub fn parse_cpuinfo_mhz(content: &str) -> Vec<f64> {
    content
        .lines()
        .filter_map(|l| {
            let l = l.trim();
            l.strip_prefix("cpu MHz")
                .and_then(|rest| rest.split_once(':').map(|(_, v)| v))
                .and_then(|v| v.trim().parse::<f64>().ok())
        })
        .collect()
}

/// 解析 `/sys/.../scaling_available_governors`（空格分隔）→ 有序列表。
pub fn parse_available_governors(content: &str) -> Vec<String> {
    content
        .split_whitespace()
        .map(|s| s.to_string())
        .collect()
}

/// 解析 `/sys/.../cpufreq/stats/time_in_state`（每行 `freq_khz ticks`），
/// 按频率聚合 ticks（调用方跨核求和）。`ticks` 单位由内核定义，相对分布才有意义。
pub fn parse_time_in_state(content: &str) -> Vec<(i64, u64)> {
    let mut map: BTreeMap<i64, u64> = BTreeMap::new();
    for line in content.lines() {
        let mut it = line.split_whitespace();
        let Some(freq) = it.next().and_then(|t| t.parse::<i64>().ok()) else {
            continue;
        };
        let Some(ticks) = it.next().and_then(|t| t.parse::<u64>().ok()) else {
            continue;
        };
        *map.entry(freq).or_insert(0) += ticks;
    }
    map.into_iter().collect()
}

/// 单档频率的驻留计数（跨核求和）。`freq_mhz` 单位 MHz；`ticks` 单位内核定义。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct FreqResidency {
    pub freq_mhz: f64,
    pub ticks: u64,
}

/// `/proc/loadavg`：`0.15 0.10 0.05 1/234 5678`。
#[derive(Debug, Clone, PartialEq, Serialize, Default)]
pub struct LoadAvg {
    pub load1: f64,
    pub load5: f64,
    pub load15: f64,
    pub runnable: u32,
    pub total: u32,
    pub last_pid: u64,
}

pub fn parse_loadavg(s: &str) -> Option<LoadAvg> {
    let mut it = s.split_whitespace();
    let load1 = it.next()?.parse::<f64>().ok()?;
    let load5 = it.next()?.parse::<f64>().ok()?;
    let load15 = it.next()?.parse::<f64>().ok()?;
    let (runnable, total) = it.next()?.split_once('/')?;
    Some(LoadAvg {
        load1,
        load5,
        load15,
        runnable: runnable.parse().ok()?,
        total: total.parse().ok()?,
        last_pid: it.next().and_then(|v| v.parse().ok()).unwrap_or(0),
    })
}

/// 单核信息。
#[derive(Debug, Clone, Serialize)]
pub struct CoreInfo {
    pub id: usize,
    pub freq_mhz: Option<f64>,
}

/// CPU 报告（单位显式：`*_mhz`、`usage_percent`）。
#[derive(Debug, Clone, Serialize)]
pub struct CpuReport {
    pub usage_percent: f64,
    pub per_core_usage: Vec<f64>,
    pub core_count: usize,
    pub frequencies_mhz: Vec<Option<f64>>,
    pub governor: Option<String>,
    pub available_frequencies_mhz: Vec<f64>,
    pub max_freq_mhz: Option<f64>,
    pub min_freq_mhz: Option<f64>,
    pub loadavg: Option<LoadAvg>,
    pub cores: Vec<CoreInfo>,
    pub available_governors: Vec<String>,
    pub freq_residency: Vec<FreqResidency>,
}

fn core_freq_mhz(i: usize, cpuinfo_mhz: &[f64]) -> Option<f64> {
    let base = format!("/sys/devices/system/cpu/cpu{i}/cpufreq");
    if let Some(k) = util::read_i64(&format!("{base}/scaling_cur_freq")) {
        return Some(freq_khz_to_mhz(k));
    }
    if let Some(k) = util::read_i64(&format!("{base}/cpuinfo_cur_freq")) {
        return Some(freq_khz_to_mhz(k));
    }
    cpuinfo_mhz.get(i).copied()
}

/// 采集 `/proc/stat`（轻量，供采样器建立基线）。
pub fn sample() -> CpuStat {
    util::read_file("/proc/stat")
        .map(|c| parse_proc_stat(&c))
        .unwrap_or_default()
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn collect_freq_residency(core_count: usize) -> Vec<FreqResidency> {
    let mut map: BTreeMap<i64, u64> = BTreeMap::new();
    for i in 0..core_count {
        let path = format!("/sys/devices/system/cpu/cpu{i}/cpufreq/stats/time_in_state");
        if let Some(content) = util::read_file(&path) {
            for (freq_khz, ticks) in parse_time_in_state(&content) {
                *map.entry(freq_khz).or_insert(0) += ticks;
            }
        }
    }
    map.into_iter()
        .map(|(khz, ticks)| FreqResidency {
            freq_mhz: freq_khz_to_mhz(khz),
            ticks,
        })
        .collect()
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn collect_freq_residency(_core_count: usize) -> Vec<FreqResidency> {
    Vec::new()
}

/// 由上次样本 + 本次样本生成报告；`prev` 为 `None` 时占用率按 0 处理。
pub fn report(prev: Option<&CpuStat>, cur: &CpuStat) -> CpuReport {
    let usage_percent = prev
        .map(|p| usage_delta(p.aggregate, cur.aggregate))
        .unwrap_or(0.0);
    let per_core_usage = cur
        .per_core
        .iter()
        .enumerate()
        .map(|(i, c)| prev.and_then(|p| p.per_core.get(i)).map(|p| usage_delta(*p, *c)).unwrap_or(0.0))
        .collect();

    let cpuinfo = util::read_file("/proc/cpuinfo").unwrap_or_default();
    let cpuinfo_mhz = parse_cpuinfo_mhz(&cpuinfo);

    let core_count = if cur.per_core.is_empty() {
        std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0)
    } else {
        cur.per_core.len()
    };

    let base0 = "/sys/devices/system/cpu/cpu0/cpufreq".to_string();
    let governor = util::read_trimmed(&format!("{base0}/scaling_governor"));
    let available_frequencies_mhz = util::read_file(&format!("{base0}/available_frequencies"))
        .map(|c| parse_available_frequencies(&c))
        .unwrap_or_default();
    let max_freq_mhz = util::read_i64(&format!("{base0}/cpuinfo_max_freq")).map(freq_khz_to_mhz);
    let min_freq_mhz = util::read_i64(&format!("{base0}/cpuinfo_min_freq")).map(freq_khz_to_mhz);

    let cores: Vec<CoreInfo> = (0..core_count)
        .map(|i| CoreInfo {
            id: i,
            freq_mhz: core_freq_mhz(i, &cpuinfo_mhz),
        })
        .collect();
    let frequencies_mhz = cores.iter().map(|c| c.freq_mhz).collect();

    let loadavg = util::read_file("/proc/loadavg").and_then(|c| parse_loadavg(&c));

    let available_governors = util::read_file(&format!("{base0}/scaling_available_governors"))
        .map(|c| parse_available_governors(&c))
        .unwrap_or_default();
    let freq_residency = collect_freq_residency(core_count);

    CpuReport {
        usage_percent,
        per_core_usage,
        core_count,
        frequencies_mhz,
        governor,
        available_frequencies_mhz,
        max_freq_mhz,
        min_freq_mhz,
        loadavg,
        cores,
        available_governors,
        freq_residency,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 两次真实采集样本（字段: user nice system idle iowait irq softirq steal guest guest_nice）
    const STAT_A: &str = "cpu  100 0 100 800 0 0 0 0 0 0\n\
        cpu0 50 0 50 400 0 0 0 0 0 0\n\
        cpu1 50 0 50 400 0 0 0 0 0 0\n\
        intr 0\nctxt 0\nbtime 0\nprocesses 0\n";
    const STAT_B: &str = "cpu  200 0 150 1150 0 0 0 0 0 0\n\
        cpu0 100 0 75 575 0 0 0 0 0 0\n\
        cpu1 100 0 75 575 0 0 0 0 0 0\n\
        intr 0\n";

    #[test]
    fn parse_proc_stat_sums_total_and_reads_idle_index_3() {
        let s = parse_proc_stat(STAT_A);
        // aggregate: total=100+100+800=1000, idle=800
        assert_eq!(s.aggregate, CpuTick { total: 1000, idle: 800 });
        assert_eq!(s.per_core.len(), 2);
        assert_eq!(s.per_core[0], CpuTick { total: 500, idle: 400 });
        assert_eq!(s.per_core[1], CpuTick { total: 500, idle: 400 });
    }

    #[test]
    fn delta_usage_matches_expected_percentage() {
        let a = parse_proc_stat(STAT_A);
        let b = parse_proc_stat(STAT_B);
        // Δtotal = 500, Δidle = 350 → 100 - 70 = 30.0
        assert!((usage_delta(a.aggregate, b.aggregate) - 30.0).abs() < 1e-9);
        // 每核: Δtotal=250, Δidle=175 → 30.0
        assert!((usage_delta(a.per_core[0], b.per_core[0]) - 30.0).abs() < 1e-9);
    }

    #[test]
    fn delta_usage_zero_when_no_progress() {
        let a = parse_proc_stat(STAT_A);
        assert_eq!(usage_delta(a.aggregate, a.aggregate), 0.0);
    }

    #[test]
    fn report_without_prev_is_zero_usage() {
        let cur = parse_proc_stat(STAT_B);
        let r = report(None, &cur);
        assert_eq!(r.usage_percent, 0.0);
        assert!(r.per_core_usage.iter().all(|v| *v == 0.0));
        assert_eq!(r.core_count, 2);
    }

    #[test]
    fn freq_and_available_frequencies_scale_to_mhz() {
        assert_eq!(freq_khz_to_mhz(1800000), 1800.0);
        let avail = parse_available_frequencies("300000 1800000 2400000 1800000\n");
        assert_eq!(avail, vec![300.0, 1800.0, 2400.0]);
    }

    #[test]
    fn cpuinfo_mhz_lines_are_parsed() {
        let cpuinfo = "processor\t: 0\ncpu MHz\t\t: 2899.998\n\nprocessor\t: 1\ncpu MHz\t\t: 3050.5\n";
        assert_eq!(parse_cpuinfo_mhz(cpuinfo), vec![2899.998, 3050.5]);
    }

    #[test]
    fn loadavg_parsed_fully() {
        let la = parse_loadavg("0.15 0.10 0.05 1/234 5678\n").unwrap();
        assert_eq!(la.load1, 0.15);
        assert_eq!(la.load15, 0.05);
        assert_eq!(la.runnable, 1);
        assert_eq!(la.total, 234);
        assert_eq!(la.last_pid, 5678);
        assert!(parse_loadavg("garbage").is_none());
    }

    #[test]
    fn available_governors_are_parsed_in_order() {
        let g = parse_available_governors(
            "interactive conservative ondemand userspace powersave performance schedutil\n",
        );
        assert_eq!(g.len(), 7);
        assert_eq!(g[0], "interactive");
        assert_eq!(g[6], "schedutil");
        assert!(parse_available_governors("").is_empty());
        assert!(parse_available_governors("   \n").is_empty());
    }

    #[test]
    fn time_in_state_converts_freq_to_mhz() {
        // 真实 `time_in_state` 形态：每行 `freq_khz ticks`。
        let parsed = parse_time_in_state("1800000 12345\n");
        assert_eq!(parsed, vec![(1_800_000, 12_345)]);
        assert_eq!(freq_khz_to_mhz(parsed[0].0), 1800.0);
    }

    #[test]
    fn time_in_state_sums_repeated_freqs_within_content() {
        let content = "300000 100\n1800000 200\n2400000 50\n300000 7\n";
        assert_eq!(
            parse_time_in_state(content),
            vec![(300_000, 107), (1_800_000, 200), (2_400_000, 50)]
        );
    }

    #[test]
    fn time_in_state_skips_garbage_lines() {
        assert!(parse_time_in_state("garbage\n123\nx 5\n").is_empty());
        assert!(parse_time_in_state("").is_empty());
    }
}
