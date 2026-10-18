//! 第三方应用 `dumpsys` 文本解析（`perf.parse_app_dumps`）—— **纯解析，无任何 I/O**。
//!
//! 输入是宿主经 Shizuku 采集到的原始 `dumpsys` 文本；本模块不启动 shell、不做 JNI、
//! 不需要特权。对 Android 版本差异与残缺输入完全容错：解析不到的字段一律 `None`
//! （JSON `null`），绝不 panic。
//!
//! 覆盖六类文本：
//! - `dumpsys cpuinfo`：按包名（含 `pkg:service` 子进程）**求和**占用率；包名不匹配时回退按 pid 匹配。
//! - `dumpsys meminfo <pkg>`：优先 `TOTAL PSS:`/`TOTAL RSS:`（含千分位逗号），回退旧式 `TOTAL` 行首整数；
//!   附带 `Java Heap:` / `Native Heap:` / `Private Dirty:`；`App Summary` 段补全
//!   `Code:`/`Stack:`/`Graphics:`/`Private Other:`/`System:` → `mem_summary`；可从 `** MEMINFO in pid N` 补 pid。
//! - `dumpsys gfxinfo <pkg>`（summary，非 framestats）：帧/jank 计数、百分位、各类 slow/vsync 计数。
//! - `ps -A`：按 `NAME == package` 或 `NAME` 以 `package:` 开头筛选进程行 → `processes`。
//! - `cat /proc/<pid>/status`：`Threads:` → `threads`，`Uid:` → uid 回退。
//! - `dumpsys netstats detail`：按 `uid=` 分块累加 `rb=`/`tb=` → `net`（跨版本格式不确定时返回 `null`）。
//! - `dumpsys gfxinfo <pkg> framestats`：`---PROFILEDATA---` 之间的逐帧 CSV，列位置**按表头名**定位
//!   （版本鲁棒）→ `render`（帧数/交付 FPS/jank/总耗时百分位/UI-Draw-GPU 均值）。
//! - `dumpsys batterystats --charged <pkg>`：电量归属（best-effort）→ `power`。
//!
//! **summary 路径不计算 FPS**：`gfxinfo`（非 framestats）的 FPS 仍由调用方对两次 `frame_count`
//! 取增量推导；新增的 `render` 段则直接由 `framestats` 的 `IntendedVsync` 间隔给出交付 FPS。

use serde::Serialize;

pub use crate::collectors::app_activity::{parse_foreground, ForegroundState};
pub use crate::collectors::app_crash::{parse_crashes, CrashStats};
pub use crate::collectors::app_info::{parse_app_info, AppInfo};
pub use crate::collectors::app_power::{parse_power, parse_wake_locks, PowerStats, WakeLockEntry};
pub use crate::collectors::app_render::{parse_render, RenderStats};
pub use crate::collectors::app_smaps::{parse_smaps, SmapsStats};

/// 解析输入（`package` 必填，其余可选）。
#[derive(Debug, Clone, Default)]
pub struct AppDumpInput<'a> {
    pub package: &'a str,
    pub pid: Option<i64>,
    pub uid: Option<i64>,
    pub cpuinfo: Option<&'a str>,
    pub meminfo: Option<&'a str>,
    pub gfxinfo: Option<&'a str>,
    pub ps: Option<&'a str>,
    pub status: Option<&'a str>,
    pub netstats: Option<&'a str>,
    /// `dumpsys gfxinfo <pkg> framestats`。
    pub framestats: Option<&'a str>,
    /// `dumpsys batterystats --charged <pkg>`。
    pub batterystats: Option<&'a str>,
    /// `dumpsys package <pkg>`。
    pub package_info: Option<&'a str>,
    /// `cat /proc/<pid>/smaps_rollup`（可能为多进程块拼接）。
    pub smaps: Option<&'a str>,
    /// `dumpsys dropbox --print data_app_crash`。
    pub crash_log: Option<&'a str>,
    /// `dumpsys dropbox --print data_app_anr`。
    pub anr_log: Option<&'a str>,
    /// `dumpsys activity activities`。
    pub activity: Option<&'a str>,
}

/// `meminfo` 的 `App Summary` 段内存分解（KiB）。缺标签 → `null`。
#[derive(Debug, Clone, Default, Serialize)]
pub struct MemSummary {
    pub java_heap_kb: Option<u64>,
    pub native_heap_kb: Option<u64>,
    pub code_kb: Option<u64>,
    pub stack_kb: Option<u64>,
    pub graphics_kb: Option<u64>,
    pub private_other_kb: Option<u64>,
    pub system_kb: Option<u64>,
    pub total_pss_kb: Option<u64>,
}

/// `ps -A` 中匹配到的进程行。`rss_kb` 为 Android `ps` 的 KB 值。
#[derive(Debug, Clone, Serialize)]
pub struct ProcessEntry {
    pub pid: i64,
    pub ppid: Option<i64>,
    pub rss_kb: Option<u64>,
    pub name: String,
}

/// `netstats` 中某 uid 的累计收发字节。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct NetCounters {
    pub uid: i64,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

/// `perf.parse_app_dumps` 的成功 `data`。数字字段解析不到时为 `null`。
#[derive(Debug, Clone, Default, Serialize)]
pub struct AppDumpReport {
    pub package: String,
    pub pid: Option<i64>,
    pub running: bool,
    pub cpu_percent: Option<f64>,
    pub mem_pss_kb: Option<u64>,
    pub mem_rss_kb: Option<u64>,
    pub mem_java_heap_kb: Option<u64>,
    pub mem_native_heap_kb: Option<u64>,
    pub mem_private_dirty_kb: Option<u64>,
    pub frame_count: Option<u64>,
    pub janky_frames: Option<u64>,
    pub janky_percent: Option<f64>,
    pub p50_ms: Option<f64>,
    pub p90_ms: Option<f64>,
    pub p95_ms: Option<f64>,
    pub p99_ms: Option<f64>,
    pub missed_vsync: Option<u64>,
    pub high_input_latency: Option<u64>,
    pub slow_ui_thread: Option<u64>,
    pub slow_bitmap_uploads: Option<u64>,
    pub slow_draw: Option<u64>,
    pub uid: Option<i64>,
    pub threads: Option<u64>,
    pub mem_summary: MemSummary,
    pub processes: Vec<ProcessEntry>,
    pub net: Option<NetCounters>,
    /// `gfxinfo framestats` 逐帧渲染统计；无数据 → `null`。
    pub render: Option<RenderStats>,
    /// `batterystats` 电量/唤醒锁归属（best-effort）；无数据 → `null`。
    pub power: Option<PowerStats>,
    /// `dumpsys package` 包信息；无数据 → `null`。
    pub app_info: Option<AppInfo>,
    /// `smaps_rollup` 精确内存分项；无数据 → `null`。
    pub smaps: Option<SmapsStats>,
    /// dropbox 崩溃 / ANR 汇总；无数据 → `null`。
    pub crashes: Option<CrashStats>,
    /// 活动前台状态；无法判定 → `null`。
    pub foreground: Option<ForegroundState>,
    /// `batterystats` 逐条唤醒锁；无数据 → `[]`。
    pub wake_locks: Vec<WakeLockEntry>,
}

impl AppDumpReport {
    /// 是否有任意指标解析成功（`running` 的另一半判据，另一半是 `pid > 0`）。
    fn any_metric(&self) -> bool {
        [
            self.cpu_percent.is_some(),
            self.mem_pss_kb.is_some(),
            self.mem_rss_kb.is_some(),
            self.mem_java_heap_kb.is_some(),
            self.mem_native_heap_kb.is_some(),
            self.mem_private_dirty_kb.is_some(),
            self.frame_count.is_some(),
            self.janky_frames.is_some(),
            self.janky_percent.is_some(),
            self.p50_ms.is_some(),
            self.p90_ms.is_some(),
            self.p95_ms.is_some(),
            self.p99_ms.is_some(),
            self.missed_vsync.is_some(),
            self.high_input_latency.is_some(),
            self.slow_ui_thread.is_some(),
            self.slow_bitmap_uploads.is_some(),
            self.slow_draw.is_some(),
        ]
        .into_iter()
        .any(|present| present)
    }
}

// ==================== 通用 token 扫描（无 regex 依赖） ====================

/// 取 `s` 中第一个无符号整数（允许千分位逗号，如 `1,234,567`）。
pub(crate) fn first_uint(s: &str) -> Option<u64> {
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let start = i;
            while i < bytes.len() && (bytes[i].is_ascii_digit() || bytes[i] == b',') {
                i += 1;
            }
            let token: String = s[start..i].chars().filter(|c| *c != ',').collect();
            if let Ok(v) = token.parse::<u64>() {
                return Some(v);
            }
        } else {
            i += 1;
        }
    }
    None
}

/// 取 `s` 中第一个浮点数（数字 + 可选小数点，如 `12.3`）。
pub(crate) fn first_float(s: &str) -> Option<f64> {
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let start = i;
            while i < bytes.len() && (bytes[i].is_ascii_digit() || bytes[i] == b'.') {
                i += 1;
            }
            if let Ok(v) = s[start..i].parse::<f64>() {
                return Some(v);
            }
        } else {
            i += 1;
        }
    }
    None
}

/// `label` 之后的子串（`label` 不存在返回 `None`）。
pub(crate) fn after_label<'a>(s: &'a str, label: &str) -> Option<&'a str> {
    let idx = s.find(label)?;
    Some(&s[idx + label.len()..])
}

/// `label` 之后的第一个整数（用于 `TOTAL PSS: 1,234` 之类）。
fn uint_after(s: &str, label: &str) -> Option<u64> {
    first_uint(after_label(s, label)?)
}

/// 仅取 `s` **开头**连续的数字（允许千分位逗号），非数字起始返回 `None`。
/// 用于 `uid=123`、`rb=4,096` 这类必须紧跟 `=` 的定界取值（避免误抓行内其它数字）。
fn leading_uint(s: &str) -> Option<u64> {
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() && (bytes[i].is_ascii_digit() || bytes[i] == b',') {
        i += 1;
    }
    if i == 0 {
        return None;
    }
    s[..i]
        .chars()
        .filter(|c| *c != ',')
        .collect::<String>()
        .parse()
        .ok()
}

// ==================== cpuinfo ====================

#[derive(Debug, Clone, Default)]
struct CpuInfo {
    cpu_percent: Option<f64>,
    pid: Option<i64>,
}

/// 单行形如 `  12.3% 12345/com.x: 5% user + 7% kernel ...`（百分比前可能有 `+`）。
struct CpuLine<'a> {
    percent: f64,
    pid: i64,
    name: &'a str,
}

fn parse_cpuinfo_line(line: &str) -> Option<CpuLine<'_>> {
    let pct_idx = line.find('%')?;
    let percent = first_float(&line[..pct_idx])?;
    let rest = line[pct_idx + 1..].trim_start();
    let rest = rest.strip_prefix('+').unwrap_or(rest).trim_start();
    let pid_end = rest.find(|c: char| !c.is_ascii_digit())?;
    let pid: i64 = rest[..pid_end].parse().ok()?;
    let after_slash = rest[pid_end..].strip_prefix('/')?;
    // 进程名是 `/` 之后到空白为止的 token，去掉结尾的 `:`（如 `com.x:service:` → `com.x:service`）。
    let end = after_slash.find(char::is_whitespace).unwrap_or(after_slash.len());
    let token = &after_slash[..end];
    let name = token.strip_suffix(':').unwrap_or(token);
    if name.is_empty() {
        return None;
    }
    Some(CpuLine { percent, pid, name })
}

/// 先按包名匹配（`pkg` 或 `pkg:*` 子进程）求和；无匹配则回退按 `pid` 匹配。
fn parse_cpuinfo(text: &str, package: &str, pid: Option<i64>) -> CpuInfo {
    let prefix = format!("{package}:");
    let mut sum = 0.0;
    let mut matched = false;
    let mut first_pid = None;

    for line in text.lines() {
        if let Some(c) = parse_cpuinfo_line(line) {
            if c.name == package || c.name.starts_with(&prefix) {
                sum += c.percent;
                matched = true;
                first_pid.get_or_insert(c.pid);
            }
        }
    }
    if !matched {
        if let Some(target) = pid {
            for line in text.lines() {
                if let Some(c) = parse_cpuinfo_line(line) {
                    if c.pid == target {
                        sum += c.percent;
                        matched = true;
                        first_pid.get_or_insert(c.pid);
                    }
                }
            }
        }
    }
    CpuInfo { cpu_percent: matched.then_some(sum), pid: first_pid }
}

// ==================== meminfo ====================

#[derive(Debug, Clone, Default)]
struct MemInfoParsed {
    pss_kb: Option<u64>,
    rss_kb: Option<u64>,
    java_heap_kb: Option<u64>,
    native_heap_kb: Option<u64>,
    private_dirty_kb: Option<u64>,
    code_kb: Option<u64>,
    stack_kb: Option<u64>,
    graphics_kb: Option<u64>,
    private_other_kb: Option<u64>,
    system_kb: Option<u64>,
    pid: Option<i64>,
}

fn parse_meminfo(text: &str) -> MemInfoParsed {
    let mut out = MemInfoParsed::default();
    for line in text.lines() {
        let t = line.trim();
        if let Some(v) = uint_after(t, "TOTAL PSS:") {
            out.pss_kb = Some(v);
        }
        if let Some(v) = uint_after(t, "TOTAL RSS:") {
            out.rss_kb = Some(v);
        }
        if let Some(v) = uint_after(t, "Java Heap:") {
            out.java_heap_kb = Some(v);
        }
        if let Some(v) = uint_after(t, "Native Heap:") {
            out.native_heap_kb = Some(v);
        }
        if let Some(v) = uint_after(t, "Private Dirty:") {
            out.private_dirty_kb = Some(v);
        }
        if let Some(v) = uint_after(t, "Code:") {
            out.code_kb = Some(v);
        }
        if let Some(v) = uint_after(t, "Stack:") {
            out.stack_kb = Some(v);
        }
        if let Some(v) = uint_after(t, "Graphics:") {
            out.graphics_kb = Some(v);
        }
        if let Some(v) = uint_after(t, "Private Other:") {
            out.private_other_kb = Some(v);
        }
        if let Some(v) = uint_after(t, "System:") {
            out.system_kb = Some(v);
        }
        if out.pid.is_none() {
            if let Some(v) = uint_after(t, "MEMINFO in pid") {
                out.pid = Some(v as i64);
            }
        }
    }
    // 旧式 meminfo 无 `TOTAL PSS:`，改从 `TOTAL` 行取首个整数（`TOTAL   98765 ...` / `TOTAL: 123456`）。
    if out.pss_kb.is_none() {
        for line in text.lines() {
            let t = line.trim();
            if t.starts_with("TOTAL")
                && !t.starts_with("TOTAL PSS")
                && !t.starts_with("TOTAL RSS")
            {
                out.pss_kb = first_uint(t);
                break;
            }
        }
    }
    out
}

// ==================== gfxinfo ====================

#[derive(Debug, Clone, Default)]
struct GfxInfoParsed {
    frame_count: Option<u64>,
    janky_frames: Option<u64>,
    janky_percent: Option<f64>,
    p50_ms: Option<f64>,
    p90_ms: Option<f64>,
    p95_ms: Option<f64>,
    p99_ms: Option<f64>,
    missed_vsync: Option<u64>,
    high_input_latency: Option<u64>,
    slow_ui_thread: Option<u64>,
    slow_bitmap_uploads: Option<u64>,
    slow_draw: Option<u64>,
}

fn parse_gfxinfo(text: &str) -> GfxInfoParsed {
    let mut out = GfxInfoParsed::default();
    for line in text.lines() {
        let t = line.trim();
        if let Some(v) = uint_after(t, "Total frames rendered:") {
            out.frame_count = Some(v);
        }
        if let Some(v) = uint_after(t, "Janky frames:") {
            out.janky_frames = Some(v);
            if let Some(rest) = after_label(t, "Janky frames:") {
                if let Some(open) = rest.find('(') {
                    out.janky_percent = first_float(&rest[open + 1..]);
                }
            }
        }
        for (label, slot) in [
            ("50th percentile:", &mut out.p50_ms),
            ("90th percentile:", &mut out.p90_ms),
            ("95th percentile:", &mut out.p95_ms),
            ("99th percentile:", &mut out.p99_ms),
        ] {
            if let Some(v) = uint_after(t, label) {
                *slot = Some(v as f64);
            }
        }
        if let Some(v) = uint_after(t, "Number Missed Vsync:") {
            out.missed_vsync = Some(v);
        }
        if let Some(v) = uint_after(t, "Number High input latency:") {
            out.high_input_latency = Some(v);
        }
        if let Some(v) = uint_after(t, "Number Slow UI thread:") {
            out.slow_ui_thread = Some(v);
        }
        if let Some(v) = uint_after(t, "Number Slow bitmap uploads:") {
            out.slow_bitmap_uploads = Some(v);
        }
        if let Some(v) = uint_after(t, "Number Slow issue draw commands:") {
            out.slow_draw = Some(v);
        }
    }
    out
}

// ==================== status (/proc/<pid>/status) ====================

#[derive(Debug, Clone, Default)]
struct StatusInfo {
    threads: Option<u64>,
    uid: Option<i64>,
}

fn parse_status(text: &str) -> StatusInfo {
    let mut out = StatusInfo::default();
    for line in text.lines() {
        let t = line.trim_start();
        if out.threads.is_none() {
            if let Some(v) = uint_after(t, "Threads:") {
                out.threads = Some(v);
            }
        }
        if out.uid.is_none() {
            if let Some(v) = after_label(t, "Uid:").and_then(first_uint) {
                out.uid = Some(v as i64);
            }
        }
    }
    out
}

// ==================== ps -A ====================

/// `ps -A` 默认列 `USER PID PPID VSZ RSS WCHAN ADDR S NAME`；按包名筛选进程行。
fn parse_ps(text: &str, package: &str) -> Vec<ProcessEntry> {
    let prefix = format!("{package}:");
    let mut out = Vec::new();
    for line in text.lines() {
        let t = line.trim().strip_prefix('[').unwrap_or(line.trim());
        let cols: Vec<&str> = t.split_whitespace().collect();
        if cols.len() < 9 {
            continue;
        }
        let pid = match cols[1].parse::<i64>() {
            Ok(v) if v > 0 => v,
            _ => continue,
        };
        let name = cols[8..].join(" ");
        if name == package || name.starts_with(&prefix) {
            out.push(ProcessEntry {
                pid,
                ppid: cols[2].parse::<i64>().ok(),
                rss_kb: cols[4].parse::<u64>().ok(),
                name,
            });
        }
    }
    out
}

// ==================== netstats detail ====================

/// 定位一个词边界处的 `uid=`（避免匹配 `suid=` 等）。
fn find_uid_marker(lower: &str) -> Option<usize> {
    let mut offset = 0;
    while let Some(pos) = lower[offset..].find("uid=") {
        let abs = offset + pos;
        let boundary = abs == 0 || {
            let b = lower.as_bytes()[abs - 1];
            !b.is_ascii_alphanumeric() && b != b'_'
        };
        if boundary {
            return Some(abs);
        }
        offset = abs + 4;
        if offset >= lower.len() {
            break;
        }
    }
    None
}

/// 累加一行内出现的 `rb=`/`tb=`（词边界 + 紧跟整数），设置 `saw` 表示命中过任意标记。
fn add_net_markers(s: &str, rx: &mut u64, tx: &mut u64, saw: &mut bool) {
    for (marker, slot) in [("rb=", &mut *rx), ("tb=", &mut *tx)] {
        let mut offset = 0;
        while let Some(pos) = s[offset..].find(marker) {
            let abs = offset + pos;
            let boundary = abs == 0 || {
                let b = s.as_bytes()[abs - 1];
                !b.is_ascii_alphanumeric() && b != b'_'
            };
            if boundary {
                if let Some(v) = leading_uint(&s[abs + marker.len()..]) {
                    *slot = slot.saturating_add(v);
                    *saw = true;
                }
            }
            offset = abs + marker.len();
            if offset >= s.len() {
                break;
            }
        }
    }
}

/// 按 `uid=` 分块累加 `rb=`/`tb=`，仅返回 `target` 的合计；格式不符返回 `None`。
fn parse_netstats(text: &str, target: i64) -> Option<NetCounters> {
    let mut cur_uid: Option<i64> = None;
    let mut cur_rx = 0u64;
    let mut cur_tx = 0u64;
    let mut cur_marker = false;
    let mut total_rx = 0u64;
    let mut total_tx = 0u64;
    let mut found = false;

    for line in text.lines() {
        let lower = line.to_ascii_lowercase();
        if let Some(pos) = find_uid_marker(&lower) {
            if cur_uid == Some(target) && cur_marker {
                total_rx = total_rx.saturating_add(cur_rx);
                total_tx = total_tx.saturating_add(cur_tx);
                found = true;
            }
            let after = &lower[pos + 4..];
            cur_uid = leading_uint(after).map(|v| v as i64);
            cur_rx = 0;
            cur_tx = 0;
            cur_marker = false;
            add_net_markers(after, &mut cur_rx, &mut cur_tx, &mut cur_marker);
        } else if cur_uid.is_some() {
            add_net_markers(&lower, &mut cur_rx, &mut cur_tx, &mut cur_marker);
        }
    }
    if cur_uid == Some(target) && cur_marker {
        total_rx = total_rx.saturating_add(cur_rx);
        total_tx = total_tx.saturating_add(cur_tx);
        found = true;
    }

    found.then_some(NetCounters {
        uid: target,
        rx_bytes: total_rx,
        tx_bytes: total_tx,
    })
}

// ==================== 顶层 ====================

/// 解析一段第三方应用 `dumpsys` 文本集合为结构化报告。
pub fn parse(input: &AppDumpInput<'_>) -> AppDumpReport {
    let cpu = input
        .cpuinfo
        .map(|t| parse_cpuinfo(t, input.package, input.pid))
        .unwrap_or_default();
    let mem = input.meminfo.map(parse_meminfo).unwrap_or_default();
    let gfx = input.gfxinfo.map(parse_gfxinfo).unwrap_or_default();
    let status = input.status.map(parse_status).unwrap_or_default();
    let processes = input
        .ps
        .map(|t| parse_ps(t, input.package))
        .unwrap_or_default();
    let first_proc_pid = processes.first().map(|p| p.pid);

    let uid = input.uid.or(status.uid);
    let net = match input.uid {
        Some(target) => input.netstats.and_then(|t| parse_netstats(t, target)),
        None => None,
    };
    let render = input.framestats.and_then(parse_render);
    let power = input.batterystats.and_then(|t| parse_power(t, input.uid));
    let app_info = input
        .package_info
        .and_then(|t| parse_app_info(t, input.package));
    let smaps = input.smaps.and_then(parse_smaps);
    let crashes = parse_crashes(input.crash_log, input.anr_log, input.package);
    let foreground = input
        .activity
        .and_then(|t| parse_foreground(t, input.package));
    let wake_locks = input.batterystats.map(parse_wake_locks).unwrap_or_default();

    let pid = input.pid.or(mem.pid).or(cpu.pid).or(first_proc_pid);

    let mem_summary = MemSummary {
        java_heap_kb: mem.java_heap_kb,
        native_heap_kb: mem.native_heap_kb,
        code_kb: mem.code_kb,
        stack_kb: mem.stack_kb,
        graphics_kb: mem.graphics_kb,
        private_other_kb: mem.private_other_kb,
        system_kb: mem.system_kb,
        total_pss_kb: mem.pss_kb,
    };

    let mut report = AppDumpReport {
        package: input.package.to_string(),
        pid,
        running: false,
        cpu_percent: cpu.cpu_percent,
        mem_pss_kb: mem.pss_kb,
        mem_rss_kb: mem.rss_kb,
        mem_java_heap_kb: mem.java_heap_kb,
        mem_native_heap_kb: mem.native_heap_kb,
        mem_private_dirty_kb: mem.private_dirty_kb,
        frame_count: gfx.frame_count,
        janky_frames: gfx.janky_frames,
        janky_percent: gfx.janky_percent,
        p50_ms: gfx.p50_ms,
        p90_ms: gfx.p90_ms,
        p95_ms: gfx.p95_ms,
        p99_ms: gfx.p99_ms,
        missed_vsync: gfx.missed_vsync,
        high_input_latency: gfx.high_input_latency,
        slow_ui_thread: gfx.slow_ui_thread,
        slow_bitmap_uploads: gfx.slow_bitmap_uploads,
        slow_draw: gfx.slow_draw,
        uid,
        threads: status.threads,
        mem_summary,
        processes,
        net,
        render,
        power,
        app_info,
        smaps,
        crashes,
        foreground,
        wake_locks,
    };
    report.running = report.pid.is_some_and(|p| p > 0) || report.any_metric();
    report
}

#[cfg(test)]
mod tests {
    use super::*;

    const CPUINFO: &str = "\
Load: 2.10 / 1.95 / 1.80
CPU usage from 2000ms to 0ms ago (2024-05-01 10:00:00.000 to 2024-05-01 10:00:02.000):
  12.3% 12345/com.x: 5% user + 7% kernel + 0.1% iowait + 0.2% irq + 0% softirq
  3.1% 12346/com.x:service: 2% user + 1% kernel + 0.1% iowait
  1.0% 2000/system_server: 0.5% user + 0.5% kernel
  0.5% 3000/com.other: 0.5% user
";

    // 旧式 meminfo：无 `TOTAL PSS:`，只有 `TOTAL` 数据行。
    const MEMINFO_LEGACY: &str = "\
** MEMINFO in pid 12345 [com.x] **
                   Pss  Private  Private  SwapPss      Heap     Heap     Heap
                 Total    Dirty    Clean    Dirty     Size    Alloc     Free
                ------   ------   ------   ------   ------   ------   ------
  Native Heap    12345    12000        0        0    20000    15000     5000
  Dalvik Heap     5000     4000        0        0    10000     8000     2000
       Ashmem        0        0        0        0
    .dex mmap      100      100        0        0
    .so mmap     2000     1000      500        0
        TOTAL    98765    50000     1000        0    30000    23000     7000

 Total PSS by process:
     98765 kB: com.x (pid 12345)
";

    // 新式 meminfo：`TOTAL PSS:`/`TOTAL RSS:` + 千分位逗号 + 冒号式 heap 行。
    const MEMINFO_COMMA: &str = "\
** MEMINFO in pid 4321 [com.big.app] **
                   Pss  Private  Private  SwapPss
                 Total    Dirty    Clean    Dirty
                ------   ------   ------   ------
   Java Heap:      50,000    40,000        0        0
 Native Heap:     120,000   100,000        0        0
Private Dirty:     200,000
                TOTAL PSS: 1,234,567   TOTAL RSS: 1,000,000
";

    const GFXINFO: &str = "\
** Graphics info for pid 12345 [com.x] **

Total frames rendered: 3000
Janky frames: 12 (0.40%)
50th percentile: 6ms
90th percentile: 8ms
95th percentile: 12ms
99th percentile: 20ms
Number Missed Vsync: 0
Number High input latency: 0
Number Slow UI thread: 1
Number Slow bitmap uploads: 2
Number Slow issue draw commands: 3
HISTOGRAM: 5ms=10 6ms=100 7ms=200
";

    const STATUS: &str = "\
Name:\tcom.x
Uid:\t10123\t10123\t10123\t10123
Gid:\t10123\t10123\t10123\t10123
Threads:\t42
VmPeak:\t  2000000 kB
VmRSS:\t   100000 kB
";

    const PS: &str = "\
USER       PID  PPID     VSZ    RSS WCHAN            ADDR S NAME
root         1     0   12345   6789 SyS_epoll         0 S init
u0_a123   1234   900 3000000  98765 0                  0 S com.x
u0_a123   1235   900 2000000  45678 0                  0 S com.x:service
u0_a123   9999   900 1000000  11111 0                  0 S com.other
";

    const MEMINFO_SUMMARY: &str = "\
** MEMINFO in pid 1234 [com.x] **
 App Summary
                       Pss(KB)
                        ------
           Java Heap:     12345
         Native Heap:      6789
                Code:      1234
               Stack:        56
            Graphics:      7890
       Private Other:      4321
              System:      5432
                TOTAL PSS:   98765   TOTAL RSS: 100000
";

    const NETSTATS: &str = "\
Active interfaces:
  iface=wlan0
UID stats:
  uid=10123 rb=123456 tb=654321
  st=0
  uid=1000 rb=1 tb=2
  uid=10123 rb=100 tb=200
";

    const NETSTATS_BLOCK: &str = "\
  uid=10123
    rb=1000
    tb=2000
  uid=1000
    rb=5
    tb=6
";

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "expected {b}, got {a}");
    }

    #[test]
    fn cpuinfo_sums_all_matching_processes() {
        let c = parse_cpuinfo(CPUINFO, "com.x", None);
        approx(c.cpu_percent.unwrap(), 15.4); // 12.3 + 3.1（含 :service 子进程）
        assert_eq!(c.pid, Some(12345));
    }

    #[test]
    fn cpuinfo_falls_back_to_pid_when_package_absent() {
        let c = parse_cpuinfo(CPUINFO, "com.absent", Some(12345));
        approx(c.cpu_percent.unwrap(), 12.3);
        assert_eq!(c.pid, Some(12345));
    }

    #[test]
    fn cpuinfo_yields_none_when_no_match() {
        let c = parse_cpuinfo(CPUINFO, "com.absent", None);
        assert_eq!(c.cpu_percent, None);
        assert_eq!(c.pid, None);
    }

    #[test]
    fn meminfo_reads_legacy_total_row_and_pid() {
        let m = parse_meminfo(MEMINFO_LEGACY);
        assert_eq!(m.pss_kb, Some(98765));
        assert_eq!(m.pid, Some(12345));
        assert_eq!(m.rss_kb, None);
    }

    #[test]
    fn meminfo_reads_comma_separated_totals_and_heaps() {
        let m = parse_meminfo(MEMINFO_COMMA);
        assert_eq!(m.pss_kb, Some(1_234_567));
        assert_eq!(m.rss_kb, Some(1_000_000));
        assert_eq!(m.java_heap_kb, Some(50_000));
        assert_eq!(m.native_heap_kb, Some(120_000));
        assert_eq!(m.private_dirty_kb, Some(200_000));
        assert_eq!(m.pid, Some(4321));
    }

    #[test]
    fn gfxinfo_parses_summary_fields() {
        let g = parse_gfxinfo(GFXINFO);
        assert_eq!(g.frame_count, Some(3000));
        assert_eq!(g.janky_frames, Some(12));
        approx(g.janky_percent.unwrap(), 0.40);
        approx(g.p50_ms.unwrap(), 6.0);
        approx(g.p90_ms.unwrap(), 8.0);
        approx(g.p95_ms.unwrap(), 12.0);
        approx(g.p99_ms.unwrap(), 20.0);
        assert_eq!(g.missed_vsync, Some(0));
        assert_eq!(g.high_input_latency, Some(0));
        assert_eq!(g.slow_ui_thread, Some(1));
        assert_eq!(g.slow_bitmap_uploads, Some(2));
        assert_eq!(g.slow_draw, Some(3));
    }

    #[test]
    fn status_reads_threads_and_uid() {
        let s = parse_status(STATUS);
        assert_eq!(s.threads, Some(42));
        assert_eq!(s.uid, Some(10123));
    }

    #[test]
    fn meminfo_reads_app_summary_breakdown() {
        let m = parse_meminfo(MEMINFO_SUMMARY);
        assert_eq!(m.pss_kb, Some(98765));
        assert_eq!(m.java_heap_kb, Some(12345));
        assert_eq!(m.native_heap_kb, Some(6789));
        assert_eq!(m.code_kb, Some(1234));
        assert_eq!(m.stack_kb, Some(56));
        assert_eq!(m.graphics_kb, Some(7890));
        assert_eq!(m.private_other_kb, Some(4321));
        assert_eq!(m.system_kb, Some(5432));
    }

    #[test]
    fn ps_keeps_only_package_rows() {
        let procs = parse_ps(PS, "com.x");
        assert_eq!(procs.len(), 2);
        assert_eq!(procs[0].pid, 1234);
        assert_eq!(procs[0].ppid, Some(900));
        assert_eq!(procs[0].rss_kb, Some(98765));
        assert_eq!(procs[0].name, "com.x");
        assert_eq!(procs[1].pid, 1235);
        assert_eq!(procs[1].rss_kb, Some(45678));
        assert_eq!(procs[1].name, "com.x:service");
    }

    #[test]
    fn ps_skips_header_and_unparsable_lines() {
        assert!(parse_ps("USER PID PPID VSZ RSS WCHAN ADDR S NAME\n", "com.x").is_empty());
        assert!(parse_ps("garbage\nnot a ps line\n", "com.x").is_empty());
        assert!(parse_ps("", "com.x").is_empty());
    }

    #[test]
    fn netstats_sums_matching_uid_blocks() {
        let n = parse_netstats(NETSTATS, 10123).unwrap();
        assert_eq!(n.uid, 10123);
        assert_eq!(n.rx_bytes, 123_556);
        assert_eq!(n.tx_bytes, 654_521);
    }

    #[test]
    fn netstats_handles_multiline_blocks() {
        let n = parse_netstats(NETSTATS_BLOCK, 10123).unwrap();
        assert_eq!(n.rx_bytes, 1000);
        assert_eq!(n.tx_bytes, 2000);
    }

    #[test]
    fn netstats_is_none_when_uid_absent_or_format_unknown() {
        assert_eq!(parse_netstats(NETSTATS, 555), None);
        assert_eq!(parse_netstats("garbage without markers", 10123), None);
        assert_eq!(parse_netstats("", 10123), None);
    }

    #[test]
    fn parse_new_fields_full_combination() {
        let input = AppDumpInput {
            package: "com.x",
            pid: None,
            uid: Some(10123),
            cpuinfo: Some(CPUINFO),
            meminfo: Some(MEMINFO_SUMMARY),
            gfxinfo: Some(GFXINFO),
            ps: Some(PS),
            status: Some(STATUS),
            netstats: Some(NETSTATS),
            ..Default::default()
        };
        let r = parse(&input);
        assert_eq!(r.pid, Some(1234)); // meminfo 与 ps 都为 1234
        assert_eq!(r.uid, Some(10123));
        assert_eq!(r.threads, Some(42));
        assert_eq!(r.mem_summary.java_heap_kb, Some(12345));
        assert_eq!(r.mem_summary.total_pss_kb, Some(98765));
        assert_eq!(r.processes.len(), 2);
        let net = r.net.unwrap();
        assert_eq!(net.uid, 10123);
        assert_eq!(net.rx_bytes, 123_556);
        assert_eq!(net.tx_bytes, 654_521);
    }

    #[test]
    fn parse_pid_falls_back_to_first_matching_process() {
        let input = AppDumpInput {
            package: "com.x",
            pid: None,
            uid: None,
            cpuinfo: None,
            meminfo: None,
            gfxinfo: None,
            ps: Some(PS),
            status: None,
            netstats: None,
            ..Default::default()
        };
        let r = parse(&input);
        assert_eq!(r.pid, Some(1234));
        assert!(r.running);
    }

    #[test]
    fn net_is_null_when_uid_absent_despite_netstats() {
        let input = AppDumpInput {
            package: "com.x",
            pid: None,
            uid: None,
            cpuinfo: None,
            meminfo: None,
            gfxinfo: None,
            ps: None,
            status: None,
            netstats: Some(NETSTATS),
            ..Default::default()
        };
        assert_eq!(parse(&input).net, None);
    }

    #[test]
    fn uid_derived_from_status_when_request_absent() {
        let input = AppDumpInput {
            package: "com.x",
            pid: None,
            uid: None,
            cpuinfo: None,
            meminfo: None,
            gfxinfo: None,
            ps: None,
            status: Some(STATUS),
            netstats: None,
            ..Default::default()
        };
        assert_eq!(parse(&input).uid, Some(10123));
    }

    #[test]
    fn parse_combines_all_sources_and_sets_running() {
        let input = AppDumpInput {
            package: "com.x",
            pid: None,
            uid: None,
            cpuinfo: Some(CPUINFO),
            meminfo: Some(MEMINFO_LEGACY),
            gfxinfo: Some(GFXINFO),
            ps: None,
            status: None,
            netstats: None,
            ..Default::default()
        };
        let r = parse(&input);
        assert_eq!(r.package, "com.x");
        assert_eq!(r.pid, Some(12345)); // 由 meminfo 补出
        assert!(r.running);
        approx(r.cpu_percent.unwrap(), 15.4);
        assert_eq!(r.mem_pss_kb, Some(98765));
        assert_eq!(r.frame_count, Some(3000));
        assert_eq!(r.janky_frames, Some(12));
        approx(r.p99_ms.unwrap(), 20.0);
        assert_eq!(r.slow_draw, Some(3));
    }

    #[test]
    fn parse_prefers_explicit_pid_over_meminfo() {
        let input = AppDumpInput {
            package: "com.big.app",
            pid: Some(9999),
            uid: None,
            cpuinfo: None,
            meminfo: Some(MEMINFO_COMMA),
            gfxinfo: None,
            ps: None,
            status: None,
            netstats: None,
            ..Default::default()
        };
        let r = parse(&input);
        assert_eq!(r.pid, Some(9999));
        assert_eq!(r.mem_pss_kb, Some(1_234_567));
        assert!(r.running);
    }

    #[test]
    fn parse_partial_input_yields_nulls_and_not_running() {
        let mem_only = AppDumpInput {
            package: "com.big.app",
            pid: None,
            uid: None,
            cpuinfo: None,
            meminfo: Some(MEMINFO_COMMA),
            gfxinfo: None,
            ps: None,
            status: None,
            netstats: None,
            ..Default::default()
        };
        let r = parse(&mem_only);
        assert_eq!(r.mem_pss_kb, Some(1_234_567));
        assert_eq!(r.cpu_percent, None);
        assert_eq!(r.frame_count, None);
        assert_eq!(r.janky_frames, None);
        assert_eq!(r.p99_ms, None);
        assert_eq!(r.pid, Some(4321));
        assert!(r.running);

        let empty = AppDumpInput {
            package: "com.x",
            pid: None,
            uid: None,
            cpuinfo: None,
            meminfo: None,
            gfxinfo: None,
            ps: None,
            status: None,
            netstats: None,
            ..Default::default()
        };
        let r = parse(&empty);
        assert_eq!(r.pid, None);
        assert!(!r.running);
        assert_eq!(r.cpu_percent, None);
        assert_eq!(r.frame_count, None);
        assert_eq!(r.mem_pss_kb, None);
    }

    #[test]
    fn parse_handles_garbage_without_panicking() {
        let input = AppDumpInput {
            package: "com.x",
            pid: None,
            uid: Some(1),
            cpuinfo: Some("not a cpuinfo dump\nrandom text"),
            meminfo: Some("garbage"),
            gfxinfo: Some("???"),
            ps: Some("garbage"),
            status: Some("???"),
            netstats: Some("nope"),
            framestats: Some("???"),
            batterystats: Some("???"),
            package_info: Some("???"),
            smaps: Some("???"),
            crash_log: Some("???"),
            anr_log: Some("???"),
            activity: Some("???"),
        };
        let r = parse(&input);
        assert!(!r.running);
        assert_eq!(r.cpu_percent, None);
        assert_eq!(r.mem_pss_kb, None);
        assert_eq!(r.frame_count, None);
        assert!(r.processes.is_empty());
        assert_eq!(r.threads, None);
        assert_eq!(r.net, None);
        assert_eq!(r.uid, Some(1));
        assert_eq!(r.mem_summary.code_kb, None);
        assert_eq!(r.render, None);
        assert_eq!(r.power, None);
        assert_eq!(r.app_info, None);
        assert_eq!(r.smaps, None);
        assert_eq!(r.crashes, None);
        assert_eq!(r.foreground, None);
        assert!(r.wake_locks.is_empty());
    }

    #[test]
    fn scalar_scanners_tolerate_edges() {
        assert_eq!(first_uint("1,234,567"), Some(1_234_567));
        assert_eq!(first_uint("no digits"), None);
        assert_eq!(first_float("  12.3% rest"), Some(12.3));
        assert_eq!(first_float("+0.5"), Some(0.5));
        assert_eq!(first_float("abc"), None);
        assert_eq!(uint_after("TOTAL PSS: 1,234", "TOTAL PSS:"), Some(1_234));
        assert_eq!(after_label("abc", "zzz"), None);
        assert_eq!(leading_uint("123 abc"), Some(123));
        assert_eq!(leading_uint("1,234x"), Some(1_234));
        assert_eq!(leading_uint("abc123"), None);
        assert_eq!(leading_uint(""), None);
        assert_eq!(find_uid_marker("suid=5"), None);
        assert_eq!(find_uid_marker(" uid=7"), Some(1));
        assert!(parse_cpuinfo_line("").is_none());
        assert!(parse_cpuinfo_line("  12.3% nope").is_none());
    }

    const FRAMESTATS: &str = "\
---PROFILEDATA---
Flags,IntendedVsync,DrawStart,SyncStart,IssueDrawCommandsStart,FrameCompleted
0,1000000000,1005000000,1007000000,1006000000,1010000000
---PROFILEDATA---
";

    const BATTERYSTATS: &str = "\
Estimated power use (mAh): 12.3
Wake lock com.x: 1m
  Wifi: 0.5
";

    #[test]
    fn parse_includes_render_and_power_sections() {
        let input = AppDumpInput {
            package: "com.x",
            framestats: Some(FRAMESTATS),
            batterystats: Some(BATTERYSTATS),
            ..Default::default()
        };
        let r = parse(&input);
        let render = r.render.unwrap();
        assert_eq!(render.frame_count, 1);
        approx(render.avg_total_ms.unwrap(), 10.0);
        approx(render.avg_ui_ms.unwrap(), 5.0);
        approx(render.avg_draw_ms.unwrap(), 1.0);
        approx(render.avg_gpu_ms.unwrap(), 3.0);
        let power = r.power.unwrap();
        approx(power.mah.unwrap(), 12.3);
        assert_eq!(power.wake_lock_ms, Some(60_000));
        approx(power.wifi_mah.unwrap(), 0.5);
    }

    #[test]
    fn parse_render_and_power_are_null_when_absent() {
        let input = AppDumpInput {
            package: "com.x",
            ..Default::default()
        };
        let r = parse(&input);
        assert_eq!(r.render, None);
        assert_eq!(r.power, None);
    }

    const APP_PACKAGE: &str = "\
  Package [com.x] (a1b2c3):
    versionCode=123 minSdk=24 targetSdk=33
    versionName=1.2.3
    flags=[ HAS_CODE ]
    dataDir=/data/user/0/com.x
    codePath=/data/app/com.x/base.apk
    firstInstallTime=2023-01-01 12:00:00
    lastUpdateTime=2024-01-01 12:00:00
    requested permissions:
      android.permission.INTERNET
      android.permission.CAMERA
    install permissions:
      android.permission.INTERNET: granted=true
    User 0: installed=true enabled=0

Activity Resolver Table:
  Non-Data Actions:
      android.intent.action.MAIN:
        1a2b3c4 com.x/.Main filter 5d6e7f8

Service Resolver Table:
  Non-Data Actions:
      com.x.S:
        5d6e7f8 com.x/.Svc filter 9f8e7d6
";

    const SMAPS: &str = "\
Rss: 150000 kB
Pss: 123456 kB
Shared_Clean: 1000 kB
Private_Dirty: 50000 kB
";

    const CRASH: &str = "\
2024-01-01 12:00:00 data_app_crash (text, 1 bytes)
Process: com.x
Exception: boom
";

    const ANR: &str = "\
2024-01-02 09:00:00 data_app_anr (text, 1 bytes)
Cmd line: com.x
Reason: timeout
";

    const ACTIVITY: &str = "  mResumedActivity: ActivityRecord{b u0 com.x/.Main t2}\n";

    #[test]
    fn parse_includes_app_deep_dive_sections() {
        let input = AppDumpInput {
            package: "com.x",
            package_info: Some(APP_PACKAGE),
            smaps: Some(SMAPS),
            crash_log: Some(CRASH),
            anr_log: Some(ANR),
            activity: Some(ACTIVITY),
            batterystats: Some(BATTERYSTATS),
            ..Default::default()
        };
        let r = parse(&input);
        let info = r.app_info.unwrap();
        assert_eq!(info.version_name.as_deref(), Some("1.2.3"));
        assert_eq!(info.requested_permissions, Some(2));
        assert_eq!(info.granted_permissions, Some(1));
        assert_eq!(info.activity_count, Some(1));
        assert_eq!(info.service_count, Some(1));
        let smaps = r.smaps.unwrap();
        assert_eq!(smaps.pss_kb, Some(123_456));
        assert_eq!(smaps.rss_kb, Some(150_000));
        let crashes = r.crashes.unwrap();
        assert_eq!(crashes.crash_count, 1);
        assert_eq!(crashes.anr_count, 1);
        assert_eq!(crashes.recent.len(), 2);
        assert!(r.foreground.unwrap().is_foreground);
        assert_eq!(r.wake_locks.len(), 1);
        assert_eq!(r.wake_locks[0].name, "com.x");
        assert_eq!(r.wake_locks[0].ms, 60_000);
    }

    #[test]
    fn parse_app_deep_dive_is_null_when_absent() {
        let input = AppDumpInput {
            package: "com.x",
            ..Default::default()
        };
        let r = parse(&input);
        assert_eq!(r.app_info, None);
        assert_eq!(r.smaps, None);
        assert_eq!(r.crashes, None);
        assert_eq!(r.foreground, None);
        assert!(r.wake_locks.is_empty());
    }
}
