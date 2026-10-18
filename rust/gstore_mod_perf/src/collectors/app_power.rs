//! `dumpsys batterystats --charged <pkg>` 电池/唤醒锁归属解析（`perf.parse_app_dumps` 的 `power` 段）。
//!
//! **纯解析 + best-effort**：输入为宿主经 Shizuku 采集的原始文本，本模块不启动 shell、
//! 不做 JNI、不需要特权，绝不 panic。跨 Android 版本格式差异极大，识别不到任何字段时
//! 整体返回 `None`（JSON `null`），单个字段缺失时为 `None`，绝不臆造数值。

use serde::Serialize;

use crate::collectors::app_dumps::{after_label, first_float};

/// 第三方应用的电池 / 唤醒锁归属（best-effort）。任何字段都可能为 `None`。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PowerStats {
    pub mah: Option<f64>,
    pub wake_lock_ms: Option<u64>,
    pub mobile_radio_mah: Option<f64>,
    pub wifi_mah: Option<f64>,
    pub screen_mah: Option<f64>,
    pub cpu_mah: Option<f64>,
}

impl PowerStats {
    fn any(&self) -> bool {
        self.mah.is_some()
            || self.wake_lock_ms.is_some()
            || self.mobile_radio_mah.is_some()
            || self.wifi_mah.is_some()
            || self.screen_mah.is_some()
            || self.cpu_mah.is_some()
    }
}

/// `label` 之后（可跨空白/换行）**紧跟**的数字；后随非数字则视为未命中。
fn number_after_label(text: &str, label: &str) -> Option<f64> {
    let rest = after_label(text, label)?.trim_start();
    if rest.as_bytes().first().is_some_and(|b| b.is_ascii_digit()) {
        first_float(rest)
    } else {
        None
    }
}

/// 请求 uid 可能对应的 `Uid u0aXXX` 标签集合（多用户 uid、原样、旧式 10xxx 应用 id）。
fn uid_labels(uid: i64) -> Vec<String> {
    let mut labels = vec![format!("u0a{}", uid % 100_000), format!("u0a{uid}")];
    if (10_000..100_000).contains(&uid) {
        labels.push(format!("u0a{}", uid % 10_000));
    }
    labels.sort();
    labels.dedup();
    labels
}

/// 从 `Uid u0aXXX: <float>` 行取电量（需请求 uid）。
fn uid_mah(text: &str, uid: Option<i64>) -> Option<f64> {
    let uid = uid?;
    let labels = uid_labels(uid);
    for line in text.lines() {
        for label in &labels {
            let needle = format!("Uid {label}");
            if let Some(pos) = line.find(&needle) {
                let rest = line[pos + needle.len()..].trim_start();
                if let Some(rest) = rest.strip_prefix(':') {
                    if let Some(v) = first_float(rest.trim_start()) {
                        return Some(v);
                    }
                }
            }
        }
    }
    None
}

/// `:` 之后的片段（无冒号则整行）。
fn after_last_colon(line: &str) -> &str {
    match line.rfind(':') {
        Some(i) => &line[i + 1..],
        None => line,
    }
}

/// 扫描 `s` 中的 `<n>h`/`<n>m`/`<n>s`/`<n>ms` 时长片段并求和为毫秒。
///
/// 仅识别数字紧邻单位的情形；`ms` 优先于 `m` 判定，避免毫秒被误读为分钟。
fn parse_durations_ms(s: &str) -> Option<u64> {
    let bytes = s.as_bytes();
    let mut i = 0;
    let mut total: u64 = 0;
    let mut found = false;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            let num: u64 = match s[start..i].parse() {
                Ok(v) => v,
                Err(_) => continue,
            };
            let rest = &s[i..];
            let (unit_ms, consumed) = if rest.starts_with("ms") || rest.starts_with("MS") {
                (num, 2)
            } else if rest.starts_with('h') || rest.starts_with('H') {
                (num.saturating_mul(3_600_000), 1)
            } else if rest.starts_with('m') || rest.starts_with('M') {
                (num.saturating_mul(60_000), 1)
            } else if rest.starts_with('s') || rest.starts_with('S') {
                (num.saturating_mul(1_000), 1)
            } else {
                (0, 0)
            };
            if consumed > 0 {
                total = total.saturating_add(unit_ms);
                found = true;
                i += consumed;
            }
        } else {
            i += 1;
        }
    }
    found.then_some(total)
}

/// 求和所有 `Wake lock ...: <dur>` 行；无个体行时回退 `Total time ... wake lock` 行。
fn wake_lock_ms(text: &str) -> Option<u64> {
    let mut sum: u64 = 0;
    let mut found_individual = false;
    let mut explicit_total: Option<u64> = None;
    for line in text.lines() {
        let l = line.trim();
        let lower = l.to_ascii_lowercase();
        if lower.starts_with("wake lock") {
            if let Some(ms) = parse_durations_ms(after_last_colon(l)) {
                sum = sum.saturating_add(ms);
                found_individual = true;
            }
        } else if lower.contains("total time") && lower.contains("wake") {
            if let Some(ms) = parse_durations_ms(l) {
                explicit_total = Some(ms);
            }
        }
    }
    if found_individual {
        Some(sum)
    } else {
        explicit_total
    }
}

/// 单条唤醒锁（名称 + 持有毫秒）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WakeLockEntry {
    pub name: String,
    pub ms: u64,
}

/// 逐条列出 `Wake lock <name>: <duration>` 行；名称保留原样（可含 `:` 子进程前缀）。
pub fn parse_wake_locks(text: &str) -> Vec<WakeLockEntry> {
    let mut out = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if !trimmed.to_ascii_lowercase().starts_with("wake lock") {
            continue;
        }
        let rest = trimmed["wake lock".len()..].trim_start();
        let Some(colon) = rest.rfind(':') else {
            continue;
        };
        let name = rest[..colon].trim();
        if name.is_empty() {
            continue;
        }
        if let Some(ms) = parse_durations_ms(&rest[colon + 1..]) {
            out.push(WakeLockEntry { name: name.to_string(), ms });
        }
    }
    out
}

/// 某组件标签（如 `Mobile radio:`）行首之后的首个浮点。
fn component_mah(text: &str, label: &str) -> Option<f64> {
    text.lines()
        .find_map(|line| line.trim_start().strip_prefix(label).and_then(first_float))
}

/// 解析 `batterystats` 文本；识别不到任何字段 → `None`。
pub fn parse_power(text: &str, uid: Option<i64>) -> Option<PowerStats> {
    let stats = PowerStats {
        mah: number_after_label(text, "Estimated power use (mAh):")
            .or_else(|| uid_mah(text, uid)),
        wake_lock_ms: wake_lock_ms(text),
        mobile_radio_mah: component_mah(text, "Mobile radio:"),
        wifi_mah: component_mah(text, "Wifi:"),
        screen_mah: component_mah(text, "Screen:"),
        cpu_mah: component_mah(text, "CPU:"),
    };
    stats.any().then_some(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "expected {b}, got {a}");
    }

    const BATTERYSTATS: &str = "\
Estimated power use (mAh):
  Uid u0a123: 12.34
Wake lock com.example: 1h 2m 3s (5 times) realtime
Wake lock com.example:service: 2m 30s (2 times) realtime
  Mobile radio: 1.2
  Wifi: 0.5
  Screen: 4.0
  CPU: 3.0
";

    #[test]
    fn parses_uid_power_wakelocks_and_components() {
        let p = parse_power(BATTERYSTATS, Some(100_123)).unwrap();
        approx(p.mah.unwrap(), 12.34);
        assert_eq!(p.wake_lock_ms, Some(3_873_000)); // 1h2m3s + 2m30s
        approx(p.mobile_radio_mah.unwrap(), 1.2);
        approx(p.wifi_mah.unwrap(), 0.5);
        approx(p.screen_mah.unwrap(), 4.0);
        approx(p.cpu_mah.unwrap(), 3.0);
    }

    #[test]
    fn parses_legacy_single_user_uid_label() {
        let p = parse_power("Uid u0a123: 7.7\n", Some(10_123)).unwrap();
        approx(p.mah.unwrap(), 7.7);
    }

    #[test]
    fn parses_estimated_power_use_on_the_same_line() {
        let p = parse_power("Estimated power use (mAh): 7.5\n", None).unwrap();
        approx(p.mah.unwrap(), 7.5);
        assert_eq!(p.wake_lock_ms, None);
        assert_eq!(p.screen_mah, None);
    }

    #[test]
    fn estimated_label_without_adjacent_number_falls_back_to_uid() {
        // `Capacity:` 紧随其后 → 该行不产生 mah（不臆造 Capacity 为耗电）。
        let text = "Estimated power use (mAh):\n  Capacity: 3000, Computed drain: 99\n";
        let without_uid = parse_power(text, None);
        assert!(without_uid.is_none());
        let with_uid = parse_power(&format!("{text}Uid u0a123: 4.2\n"), Some(100_123)).unwrap();
        approx(with_uid.mah.unwrap(), 4.2);
    }

    #[test]
    fn parses_total_time_wake_lock_line_as_fallback() {
        let p = parse_power("Total time spent in wake locks: 1h 30m\n", None).unwrap();
        assert_eq!(p.wake_lock_ms, Some(5_400_000));
    }

    #[test]
    fn returns_none_for_unrecognisable_input() {
        assert_eq!(parse_power("", None), None);
        assert_eq!(
            parse_power("random text\nno power fields here", None),
            None
        );
        // uid 行存在但请求未带 uid → 不匹配。
        assert_eq!(parse_power("Uid u0a123: 9.9\n", None), None);
    }

    #[test]
    fn duration_scanner_handles_h_m_s_ms_and_garbage() {
        assert_eq!(parse_durations_ms("1h 2m 3s"), Some(3_723_000));
        assert_eq!(parse_durations_ms("2m 30s"), Some(150_000));
        assert_eq!(parse_durations_ms("500ms"), Some(500));
        assert_eq!(parse_durations_ms("1H 2M"), Some(3_720_000));
        assert_eq!(parse_durations_ms("no durations"), None);
        assert_eq!(parse_durations_ms("(5 times) realtime"), None);
        assert_eq!(parse_durations_ms(""), None);
    }

    const WAKE_LOCKS: &str = "\
Estimated power use (mAh):
  Uid u0a123: 12.34
Wake lock WifiLock: 1m 23s (5 times) realtime
Wake lock com.example:service: 2m 30s (2 times) realtime
Wake lock *alarm*: 500ms (1 times) realtime
Not a wake lock line
";

    #[test]
    fn lists_each_wake_lock_with_name_and_ms() {
        let locks = parse_wake_locks(WAKE_LOCKS);
        assert_eq!(locks.len(), 3);
        assert_eq!(locks[0].name, "WifiLock");
        assert_eq!(locks[0].ms, 83_000);
        assert_eq!(locks[1].name, "com.example:service"); // 名称内冒号保留
        assert_eq!(locks[1].ms, 150_000);
        assert_eq!(locks[2].name, "*alarm*");
        assert_eq!(locks[2].ms, 500);
    }

    #[test]
    fn wake_lock_list_is_empty_when_absent_or_unparsable() {
        assert!(parse_wake_locks("").is_empty());
        assert!(parse_wake_locks("Uid u0a123: 1.0\nno wake lock rows\n").is_empty());
        assert!(parse_wake_locks("Wake lock NoDuration\n").is_empty());
    }
}
