//! 内存采集：解析 `/proc/meminfo`（单位 KiB），计算已用/占比与人类可读字符串。
//!
//! 修正 PERF_SPEC B5（参考 App 混用 bytes/KiB 导致 GB 显示乱码）：本模块所有原始值
//! 统一 KiB，占比用 `used = MemTotal - MemAvailable`（无 MemAvailable 时回退 MemFree）。

use std::collections::BTreeMap;

use serde::Serialize;

use super::util;

/// 键 → 值（KiB）。
pub type MemInfo = BTreeMap<String, u64>;

/// 解析 `/proc/meminfo`：每行 `Key: value kB`，取第一个数字 token（KiB）。
pub fn parse_meminfo(content: &str) -> MemInfo {
    let mut map = MemInfo::new();
    for line in content.lines() {
        let Some((key, rest)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() {
            continue;
        }
        if let Some(v) = rest.split_whitespace().next().and_then(|t| t.parse::<u64>().ok()) {
            map.insert(key.to_string(), v);
        }
    }
    map
}

fn get(m: &MemInfo, key: &str) -> u64 {
    m.get(key).copied().unwrap_or(0)
}

/// 内存报告（原始单位 `*_kb` + 人类可读 `*_human`）。
#[derive(Debug, Clone, Serialize)]
pub struct MemoryReport {
    pub total_kb: u64,
    pub free_kb: u64,
    pub available_kb: u64,
    pub buffers_kb: u64,
    pub cached_kb: u64,
    pub sreclaimable_kb: u64,
    pub shmem_kb: u64,
    pub slab_kb: u64,
    pub used_kb: u64,
    pub used_percent: f64,
    pub swap_total_kb: u64,
    pub swap_free_kb: u64,
    pub swap_used_kb: u64,
    pub swap_percent: f64,
    pub swap_cached_kb: u64,
    pub dirty_kb: u64,
    pub zram_total_kb: u64,
    pub zram_used_kb: u64,
    pub total_human: String,
    pub used_human: String,
    pub available_human: String,
    pub swap_total_human: String,
    pub swap_used_human: String,
}

/// 由解析后的键值表计算报告（纯函数，可单测）。
pub fn compute(m: &MemInfo) -> MemoryReport {
    let total = get(m, "MemTotal");
    let free = get(m, "MemFree");
    let available = get(m, "MemAvailable");
    // 独立缓存池：优先 MemAvailable（现代内核），否则回退 MemFree。
    let used = total.saturating_sub(if available > 0 { available } else { free });
    let used_percent = if total == 0 {
        0.0
    } else {
        util::clamp_percent(used as f64 * 100.0 / total as f64)
    };
    let swap_total = get(m, "SwapTotal");
    let swap_free = get(m, "SwapFree");
    let swap_used = swap_total.saturating_sub(swap_free);
    let swap_percent = if swap_total == 0 {
        0.0
    } else {
        util::clamp_percent(swap_used as f64 * 100.0 / swap_total as f64)
    };

    MemoryReport {
        total_kb: total,
        free_kb: free,
        available_kb: available,
        buffers_kb: get(m, "Buffers"),
        cached_kb: get(m, "Cached"),
        sreclaimable_kb: get(m, "SReclaimable"),
        shmem_kb: get(m, "Shmem"),
        slab_kb: get(m, "Slab"),
        used_kb: used,
        used_percent,
        swap_total_kb: swap_total,
        swap_free_kb: swap_free,
        swap_used_kb: swap_used,
        swap_percent,
        swap_cached_kb: get(m, "SwapCached"),
        dirty_kb: get(m, "Dirty"),
        zram_total_kb: get(m, "ZramTotal"),
        zram_used_kb: get(m, "ZramUsed"),
        total_human: util::human_kb(total),
        used_human: util::human_kb(used),
        available_human: util::human_kb(available),
        swap_total_human: util::human_kb(swap_total),
        swap_used_human: util::human_kb(swap_used),
    }
}

/// 采集当前内存报告（文件缺失时返回全 0 部分数据，不报错）。
pub fn collect() -> MemoryReport {
    let map = util::read_file("/proc/meminfo")
        .map(|c| parse_meminfo(&c))
        .unwrap_or_default();
    compute(&map)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MEMINFO: &str = "MemTotal:       16384000 kB\n\
        MemFree:         2048000 kB\n\
        MemAvailable:    8192000 kB\n\
        Buffers:          512000 kB\n\
        Cached:          4096000 kB\n\
        SReclaimable:     256000 kB\n\
        Shmem:            128000 kB\n\
        Slab:             384000 kB\n\
        SwapCached:        16000 kB\n\
        SwapTotal:       4096000 kB\n\
        SwapFree:        3072000 kB\n\
        Dirty:             32000 kB\n\
        ZramTotal:       2048000 kB\n\
        ZramUsed:         512000 kB\n";

    #[test]
    fn parse_meminfo_reads_all_keys_in_kib() {
        let m = parse_meminfo(MEMINFO);
        assert_eq!(m.get("MemTotal"), Some(&16_384_000));
        assert_eq!(m.get("MemAvailable"), Some(&8_192_000));
        assert_eq!(m.get("SwapFree"), Some(&3_072_000));
        assert_eq!(m.get("ZramUsed"), Some(&512_000));
    }

    #[test]
    fn compute_uses_available_for_used_and_percent() {
        let r = compute(&parse_meminfo(MEMINFO));
        assert_eq!(r.total_kb, 16_384_000);
        assert_eq!(r.available_kb, 8_192_000);
        // used = total - available = 8_192_000 KiB → 50.0%
        assert_eq!(r.used_kb, 8_192_000);
        assert!((r.used_percent - 50.0).abs() < 1e-9);
        // swap used = 4_096_000 - 3_072_000 = 1_024_000 → 25.0%
        assert_eq!(r.swap_used_kb, 1_024_000);
        assert!((r.swap_percent - 25.0).abs() < 1e-9);
        assert_eq!(r.total_human, "15.62 GB");
    }

    #[test]
    fn compute_falls_back_to_free_without_available() {
        let m = parse_meminfo("MemTotal: 1000 kB\nMemFree: 400 kB\n");
        let r = compute(&m);
        assert_eq!(r.used_kb, 600);
        assert!((r.used_percent - 60.0).abs() < 1e-9);
        assert_eq!(r.swap_percent, 0.0);
    }

    #[test]
    fn compute_handles_empty() {
        let r = compute(&MemInfo::new());
        assert_eq!(r.total_kb, 0);
        assert_eq!(r.used_percent, 0.0);
    }
}
