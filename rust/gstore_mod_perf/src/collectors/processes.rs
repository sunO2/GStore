//! 进程采集（增强）：扫描 `/proc/[pid]/{stat,statm,cmdline}`，按 CPU 增量 / RSS 排序返回 Top-N。
//!
//! 参考 App 仅对自身 pid 取一次内存（且实现有 bug），没有系统级进程视图。
//! 本模块对进程消失（读文件失败）与竞态完全容错 —— 永远跳过、绝不 panic。

use std::collections::HashMap;

use serde::Serialize;

use super::util;

/// 排序维度。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcSort {
    Cpu,
    Rss,
}

impl ProcSort {
    pub fn as_str(self) -> &'static str {
        match self {
            ProcSort::Cpu => "cpu",
            ProcSort::Rss => "rss",
        }
    }
}

/// `/proc/[pid]/stat` 关键字段。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatParsed {
    pub pid: i32,
    pub comm: String,
    pub state: char,
    pub utime: u64,
    pub stime: u64,
}

/// 解析 `/proc/[pid]/stat`。`comm` 可能含空格/括号，故用首个 `(` 与末个 `)` 夹取。
pub fn parse_stat(content: &str) -> Option<StatParsed> {
    let open = content.find('(')?;
    let close = content.rfind(')')?;
    if close <= open {
        return None;
    }
    let pid = content[..open].trim().parse::<i32>().ok()?;
    let comm = content[open + 1..close].to_string();
    let fields: Vec<&str> = content[close + 1..].split_whitespace().collect();
    let state = fields.first().and_then(|s| s.chars().next()).unwrap_or('?');
    let utime = fields.get(11).and_then(|v| v.parse().ok()).unwrap_or(0);
    let stime = fields.get(12).and_then(|v| v.parse().ok()).unwrap_or(0);
    Some(StatParsed { pid, comm, state, utime, stime })
}

/// 解析 `/proc/[pid]/statm` → 常驻页数（第 2 个 token）。
pub fn parse_statm(content: &str) -> Option<u64> {
    content.split_whitespace().nth(1)?.parse().ok()
}

/// 解析 `/proc/[pid]/cmdline` 原始字节（NUL 分隔 → 空格分隔）。
pub fn parse_cmdline_bytes(bytes: &[u8]) -> Option<String> {
    if bytes.is_empty() {
        return None;
    }
    let joined = String::from_utf8_lossy(bytes).replace('\0', " ");
    let trimmed = joined.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// 由两次采样间的 tick 差计算单进程 CPU%（相对单核，可 >100）。
pub fn compute_cpu_percent(delta_ticks: u64, dt_sec: f64, hz: u64) -> f64 {
    if dt_sec <= 0.0 || hz == 0 {
        return 0.0;
    }
    (delta_ticks as f64 / hz as f64) / dt_sec * 100.0
}

/// 原始进程快照（一次扫描）。
#[derive(Debug, Clone)]
pub struct ProcRaw {
    pub pid: i32,
    pub name: String,
    pub state: char,
    pub ticks: u64,
    pub rss_pages: u64,
    pub cmdline: Option<String>,
}

/// 一次扫描结果：本次样本 + 原始进程列表。
#[derive(Debug, Clone)]
pub struct ProcSnapshot {
    pub sample: ProcSample,
    pub raw: Vec<ProcRaw>,
}

/// Top-N 查询参数。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProcQuery {
    pub limit: usize,
    pub sort: ProcSort,
}

/// 全系统进程计数样本（供下次差分）。
#[derive(Debug, Clone, Default)]
pub struct ProcSample {
    pub ts_ms: u64,
    pub ticks: HashMap<i32, u64>,
}

/// 单个进程的输出信息。
#[derive(Debug, Clone, Serialize)]
pub struct ProcessInfo {
    pub pid: i32,
    pub name: String,
    pub cmdline: Option<String>,
    pub state: String,
    pub cpu_ticks: u64,
    pub cpu_percent: f64,
    pub rss_kb: u64,
    pub rss_bytes: u64,
}

/// 进程报告。
#[derive(Debug, Clone, Serialize)]
pub struct ProcessReport {
    pub total: usize,
    pub sort: String,
    pub processes: Vec<ProcessInfo>,
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn scan() -> ProcSnapshot {
    let ts_ms = util::now_ms();
    let mut sample = ProcSample { ts_ms, ticks: HashMap::new() };
    let mut raw = Vec::new();
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return ProcSnapshot { sample, raw };
    };
    for entry in entries.flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else {
            continue;
        };
        let Some(stat) = util::read_file(&format!("/proc/{pid}/stat")) else {
            continue;
        };
        let Some(p) = parse_stat(&stat) else {
            continue;
        };
        let ticks = p.utime + p.stime;
        sample.ticks.insert(pid, ticks);
        let rss_pages = util::read_file(&format!("/proc/{pid}/statm"))
            .and_then(|s| parse_statm(&s))
            .unwrap_or(0);
        let cmdline = std::fs::read(format!("/proc/{pid}/cmdline"))
            .ok()
            .and_then(|b| parse_cmdline_bytes(&b));
        raw.push(ProcRaw {
            pid,
            name: p.comm,
            state: p.state,
            ticks,
            rss_pages,
            cmdline,
        });
    }
    ProcSnapshot { sample, raw }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub fn scan() -> ProcSnapshot {
    ProcSnapshot {
        sample: ProcSample::default(),
        raw: Vec::new(),
    }
}

/// 生成 Top-N 报告（`prev` 为 `None` 时 CPU% 为 0）。
pub fn report(prev: Option<&ProcSample>, snapshot: &ProcSnapshot, query: ProcQuery) -> ProcessReport {
    let hz = util::clock_ticks_per_sec();
    let dt_sec = prev
        .map(|p| snapshot.sample.ts_ms.saturating_sub(p.ts_ms) as f64 / 1000.0)
        .unwrap_or(0.0);
    let rss_kb_per_page = util::page_size_kb();

    let mut list: Vec<ProcessInfo> = snapshot
        .raw
        .iter()
        .map(|r| {
            let delta = prev
                .and_then(|p| p.ticks.get(&r.pid))
                .map(|pt| r.ticks.saturating_sub(*pt))
                .unwrap_or(0);
            let rss_kb = r.rss_pages.saturating_mul(rss_kb_per_page);
            ProcessInfo {
                pid: r.pid,
                name: r.name.clone(),
                cmdline: r.cmdline.clone(),
                state: r.state.to_string(),
                cpu_ticks: r.ticks,
                cpu_percent: compute_cpu_percent(delta, dt_sec, hz),
                rss_kb,
                rss_bytes: rss_kb.saturating_mul(1024),
            }
        })
        .collect();

    match query.sort {
        ProcSort::Cpu => list.sort_by(|a, b| {
            b.cpu_percent
                .partial_cmp(&a.cpu_percent)
                .unwrap_or(std::cmp::Ordering::Equal)
        }),
        ProcSort::Rss => list.sort_by(|a, b| b.rss_bytes.cmp(&a.rss_bytes)),
    }
    let total = list.len();
    list.truncate(query.limit);
    ProcessReport {
        total,
        sort: query.sort.as_str().to_string(),
        processes: list,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const STAT: &str = "1234 (Web Content) S 1 1234 1234 0 -1 4194560 100 0 0 0 150 50 0 0 20 0 1 0 1000 0 0\n";

    #[test]
    fn parse_stat_handles_spaces_in_comm_and_reads_utime_stime() {
        let p = parse_stat(STAT).unwrap();
        assert_eq!(p.pid, 1234);
        assert_eq!(p.comm, "Web Content");
        assert_eq!(p.state, 'S');
        assert_eq!(p.utime, 150);
        assert_eq!(p.stime, 50);
    }

    #[test]
    fn parse_stat_rejects_garbage() {
        assert!(parse_stat("").is_none());
        assert!(parse_stat("no parens here").is_none());
    }

    #[test]
    fn parse_statm_reads_resident_pages() {
        assert_eq!(parse_statm("4096 512 100 0 0 0 0"), Some(512));
        assert_eq!(parse_statm(""), None);
    }

    #[test]
    fn parse_cmdline_joins_nul_bytes() {
        assert_eq!(parse_cmdline_bytes(b"com.foo.app\0--flag\0x\0").as_deref(), Some("com.foo.app --flag x"));
        assert_eq!(parse_cmdline_bytes(b""), None);
    }

    #[test]
    fn cpu_percent_uses_ticks_over_dt() {
        // 200 ticks @100Hz = 2s CPU over 2s wall → 100%
        assert!((compute_cpu_percent(200, 2.0, 100) - 100.0).abs() < 1e-9);
        assert!((compute_cpu_percent(100, 2.0, 100) - 50.0).abs() < 1e-9);
        assert_eq!(compute_cpu_percent(100, 0.0, 100), 0.0);
    }

    #[test]
    fn report_sorts_by_cpu_delta_and_rss() {
        let prev = ProcSample {
            ts_ms: 1000,
            ticks: HashMap::from([(1, 0), (2, 0), (3, 0)]),
        };
        let snapshot = ProcSnapshot {
            sample: ProcSample {
                ts_ms: 3000, // dt = 2s
                ticks: HashMap::from([(1, 100), (2, 50), (3, 200)]),
            },
            raw: vec![
                ProcRaw { pid: 1, name: "a".into(), state: 'S', ticks: 100, rss_pages: 100, cmdline: None },
                ProcRaw { pid: 2, name: "b".into(), state: 'R', ticks: 50, rss_pages: 400, cmdline: Some("b --x".into()) },
                ProcRaw { pid: 3, name: "c".into(), state: 'S', ticks: 200, rss_pages: 50, cmdline: None },
            ],
        };
        let by_cpu = report(Some(&prev), &snapshot, ProcQuery { limit: 2, sort: ProcSort::Cpu });
        assert_eq!(by_cpu.total, 3);
        assert_eq!(by_cpu.processes.len(), 2);
        assert_eq!(by_cpu.processes[0].pid, 3);
        assert_eq!(by_cpu.processes[1].pid, 1);
        assert!((by_cpu.processes[0].cpu_percent - 100.0).abs() < 1e-9);

        let by_rss = report(Some(&prev), &snapshot, ProcQuery { limit: 1, sort: ProcSort::Rss });
        assert_eq!(by_rss.sort, "rss");
        assert_eq!(by_rss.processes[0].pid, 2);
        assert_eq!(by_rss.processes[0].rss_bytes % 1024, 0);
    }

    #[test]
    fn report_without_prev_yields_zero_cpu() {
        let snapshot = ProcSnapshot {
            sample: ProcSample { ts_ms: 5, ticks: HashMap::new() },
            raw: vec![ProcRaw { pid: 9, name: "x".into(), state: 'S', ticks: 42, rss_pages: 10, cmdline: None }],
        };
        let rep = report(None, &snapshot, ProcQuery { limit: 10, sort: ProcSort::Cpu });
        assert_eq!(rep.processes[0].cpu_percent, 0.0);
        assert!(rep.processes[0].rss_kb > 0);
    }
}
