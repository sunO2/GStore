//! `dumpsys dropbox --print data_app_crash` / `data_app_anr` 崩溃与 ANR 解析
//! （`perf.parse_app_dumps` 的 `crashes` 段）。
//!
//! **纯解析 + best-effort**：输入为宿主经 Shizuku 采集的原始文本，本模块不启动 shell、
//! 不做 JNI、不需要特权，绝不 panic。dropbox 每条记录以时间戳行（`YYYY-MM-DD HH:MM:SS`）
//! 开始；只统计**正文提及目标 `package`** 的记录（正文不含任何包名标识时按 best-effort
//! 计入）。解析不到任何记录 → `None`（JSON `null`）。
//!
//! `recent` 取最新 5 条匹配记录，`summary` 取正文中 `Process:`/`Caused by`/`Exception`
//! 所在行（或首个非空行），截断至约 120 字符。

use serde::Serialize;

use crate::collectors::app_dumps::after_label;

/// 单条崩溃/ANR 摘要。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CrashEntry {
    pub kind: String,
    pub time: String,
    pub summary: String,
}

/// 崩溃 / ANR 汇总。`crash_count`/`anr_count` 为**匹配目标包**的记录数。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CrashStats {
    pub crash_count: u64,
    pub anr_count: u64,
    pub last_crash: Option<String>,
    pub last_anr: Option<String>,
    pub recent: Vec<CrashEntry>,
}

/// 一条 dropbox 记录（时间戳 + 正文行）。
struct RawEntry {
    time: String,
    body: Vec<String>,
}

/// 行首 `YYYY-MM-DD HH:MM:SS`（纯 ASCII，返回前 19 字节）。
fn timestamp_prefix(line: &str) -> Option<&str> {
    let b = line.as_bytes();
    if b.len() < 19 || !b[0..4].iter().all(u8::is_ascii_digit) {
        return None;
    }
    let sep_ok = b[4] == b'-'
        && b[5].is_ascii_digit()
        && b[6].is_ascii_digit()
        && b[7] == b'-'
        && b[8].is_ascii_digit()
        && b[9].is_ascii_digit()
        && b[10] == b' '
        && b[11].is_ascii_digit()
        && b[12].is_ascii_digit()
        && b[13] == b':'
        && b[14].is_ascii_digit()
        && b[15].is_ascii_digit()
        && b[16] == b':'
        && b[17].is_ascii_digit()
        && b[18].is_ascii_digit();
    sep_ok.then(|| &line[..19])
}

/// 按时间戳行切分记录（首个时间戳之前的行忽略）。
fn parse_entries(text: &str) -> Vec<RawEntry> {
    let mut entries: Vec<RawEntry> = Vec::new();
    for line in text.lines() {
        if let Some(ts) = timestamp_prefix(line) {
            entries.push(RawEntry { time: ts.to_string(), body: Vec::new() });
        } else if let Some(cur) = entries.last_mut() {
            cur.body.push(line.to_string());
        }
    }
    entries
}

/// 行内 `label` 之后的首个空白分隔 token（如 `Process: com.x` → `com.x`）。
fn token_after<'a>(line: &'a str, label: &str) -> Option<&'a str> {
    let rest = after_label(line, label)?.trim_start();
    let token = rest.split_whitespace().next().unwrap_or("");
    (!token.is_empty()).then_some(token)
}

/// 正文是否归属目标包：正文含包名 → 是；正文指名了别的包 → 否；无包名标识 → best-effort 计入。
fn body_matches(body: &[String], package: &str) -> bool {
    if body.iter().any(|line| line.contains(package)) {
        return true;
    }
    let names_other = body.iter().any(|line| {
        token_after(line, "Process:").or_else(|| token_after(line, "Cmd line:")).is_some()
    });
    !names_other
}

/// 按字符截断到 `max` 个字符。
fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        s.chars().take(max).collect()
    }
}

/// 正文摘要：`Process:`/`Caused by`/`Exception` 所在行优先，否则首个非空行；截断 ~120 字符。
fn summary_of(body: &[String]) -> String {
    for marker in ["Process:", "Caused by", "Exception"] {
        if let Some(line) = body.iter().find(|l| l.contains(marker)) {
            return truncate(line.trim(), 120);
        }
    }
    body.iter()
        .find(|l| !l.trim().is_empty())
        .map(|l| truncate(l.trim(), 120))
        .unwrap_or_default()
}

/// 解析 crash/anr 文本；两路均无记录 → `None`。
pub fn parse_crashes(
    crash_log: Option<&str>,
    anr_log: Option<&str>,
    package: &str,
) -> Option<CrashStats> {
    let crash = crash_log.map(parse_entries).unwrap_or_default();
    let anr = anr_log.map(parse_entries).unwrap_or_default();
    if crash.is_empty() && anr.is_empty() {
        return None;
    }

    let crash_matches: Vec<&RawEntry> =
        crash.iter().filter(|e| body_matches(&e.body, package)).collect();
    let anr_matches: Vec<&RawEntry> =
        anr.iter().filter(|e| body_matches(&e.body, package)).collect();

    let mut recent: Vec<CrashEntry> = crash_matches
        .iter()
        .map(|e| CrashEntry {
            kind: "crash".to_string(),
            time: e.time.clone(),
            summary: summary_of(&e.body),
        })
        .chain(anr_matches.iter().map(|e| CrashEntry {
            kind: "anr".to_string(),
            time: e.time.clone(),
            summary: summary_of(&e.body),
        }))
        .collect();
    recent.sort_by(|a, b| b.time.cmp(&a.time));
    recent.truncate(5);

    Some(CrashStats {
        crash_count: crash_matches.len() as u64,
        anr_count: anr_matches.len() as u64,
        last_crash: crash_matches.iter().map(|e| e.time.clone()).max(),
        last_anr: anr_matches.iter().map(|e| e.time.clone()).max(),
        recent,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const CRASH_LOG: &str = "\
2024-01-02 09:00:00 data_app_crash (text, 1234 bytes)
Process: com.example.app
PID: 12345
Reason: java.lang.RuntimeException: boom
Caused by: java.lang.IllegalStateException: bad state
    at com.example.app.Main.onCreate(Main.java:10)

2024-01-01 12:00:00 data_app_crash (text, 999 bytes)
Process: com.other.app
PID: 999
Caused by: java.lang.NullPointerException

2024-01-03 08:00:00 data_app_crash (text, 800 bytes)
Process: com.example.app
PID: 12346
Exception: divide by zero
";

    const ANR_LOG: &str = "\
2024-01-04 09:00:00 data_app_anr (text, 4321 bytes)
Cmd line: com.example.app
Reason: Input dispatching timed out
    at com.example.app.Main.onCreate(Main.java:20)
";

    #[test]
    fn counts_matching_entries_and_newest_timestamps() {
        let c = parse_crashes(Some(CRASH_LOG), Some(ANR_LOG), "com.example.app").unwrap();
        assert_eq!(c.crash_count, 2); // 非匹配的 com.other.app 被排除
        assert_eq!(c.anr_count, 1);
        assert_eq!(c.last_crash.as_deref(), Some("2024-01-03 08:00:00"));
        assert_eq!(c.last_anr.as_deref(), Some("2024-01-04 09:00:00"));
    }

    #[test]
    fn recent_is_newest_first_and_summarised() {
        let c = parse_crashes(Some(CRASH_LOG), Some(ANR_LOG), "com.example.app").unwrap();
        assert_eq!(c.recent.len(), 3);
        assert_eq!(c.recent[0].time, "2024-01-04 09:00:00");
        assert_eq!(c.recent[0].kind, "anr");
        assert_eq!(c.recent[1].time, "2024-01-03 08:00:00");
        assert_eq!(c.recent[1].kind, "crash");
        assert!(c.recent[1].summary.contains("Process: com.example.app"));
        assert_eq!(c.recent[2].time, "2024-01-02 09:00:00");
        assert!(c.recent[2].summary.contains("Process: com.example.app"));
    }

    #[test]
    fn non_matching_package_yields_zero_counts_but_some_report() {
        let c = parse_crashes(Some(CRASH_LOG), Some(ANR_LOG), "com.absent").unwrap();
        assert_eq!(c.crash_count, 0);
        assert_eq!(c.anr_count, 0);
        assert_eq!(c.last_crash, None);
        assert_eq!(c.last_anr, None);
        assert!(c.recent.is_empty());
    }

    #[test]
    fn entry_without_package_identification_is_counted() {
        let text = "2024-02-01 10:00:00 data_app_crash (text, 10 bytes)\nsome generic failure\n";
        let c = parse_crashes(Some(text), None, "com.x").unwrap();
        assert_eq!(c.crash_count, 1);
        assert_eq!(c.last_crash.as_deref(), Some("2024-02-01 10:00:00"));
        assert_eq!(c.recent[0].summary, "some generic failure");
    }

    #[test]
    fn recent_is_capped_at_five() {
        let mut text = String::new();
        for i in 1..=6 {
            text.push_str(&format!(
                "2024-03-0{i} 10:00:00 data_app_crash (text, 1 bytes)\nProcess: com.x\nPID: {i}\n\n"
            ));
        }
        let c = parse_crashes(Some(&text), None, "com.x").unwrap();
        assert_eq!(c.crash_count, 6);
        assert_eq!(c.recent.len(), 5);
        assert_eq!(c.recent[0].time, "2024-03-06 10:00:00");
    }

    #[test]
    fn summary_is_truncated_to_120_chars() {
        let long = "Exception: ".to_string() + &"x".repeat(300);
        let text = format!("2024-02-01 10:00:00 data_app_crash (text, 10 bytes)\n{long}\n");
        let c = parse_crashes(Some(&text), None, "com.x").unwrap();
        assert_eq!(c.recent[0].summary.chars().count(), 120);
    }

    #[test]
    fn unparsable_or_absent_input_is_none() {
        assert_eq!(parse_crashes(None, None, "com.x"), None);
        assert_eq!(parse_crashes(Some(""), Some("   \n"), "com.x"), None);
        assert_eq!(parse_crashes(Some("garbage\nno timestamps here\n"), None, "com.x"), None);
    }

    #[test]
    fn timestamp_prefix_rejects_non_timestamps() {
        assert_eq!(timestamp_prefix("2024-01-02 09:00:00 data_app_crash"), Some("2024-01-02 09:00:00"));
        assert_eq!(timestamp_prefix("2024-1-2 9:00:00 x"), None);
        assert_eq!(timestamp_prefix("text 2024-01-02 09:00:00"), None);
        assert_eq!(timestamp_prefix(""), None);
    }
}
