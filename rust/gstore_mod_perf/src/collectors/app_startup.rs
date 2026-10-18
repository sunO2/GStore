//! 应用启动耗时解析（`perf.parse_startup`）—— **纯解析，无任何 I/O**。
//!
//! 输入是宿主经 Shizuku 执行 `am start -W [-S] -n <pkg>/<activity>` 捕获到的 stdout；
//! 本模块不启动 shell、不做 JNI、不需要特权。对厂商/版本输出差异与残缺输入完全容错：
//! 解析不到的字段一律 `None`（JSON `null`），绝不 panic。
//!
//! 覆盖的典型输出：
//! ```text
//! Starting: Intent { cmp=com.x/.MainActivity }
//! Status: ok
//! Activity: com.x/.MainActivity
//! ThisTime: 345
//! TotalTime: 345
//! WaitTime: 400
//! LaunchState: COLD
//! ```
//! 失败时 `am` 会打印 `Error: Activity not started ...`；另可见
//! `Warning: Activity not started, intent has been delivered to currently running top-most instance.`。
//!
//! 语义：任何 `Error:` 行 → `status = "Error"`；否则 `status` 取 `Status:` 行的值，
//! 缺省为 `"ok"`（“无 Error 即成功”）。`mode` 原样回显请求（缺省 `"warm"`），
//! 不从 `LaunchState:` 推断（契约要求回显请求）。数值字段容忍尾随文本（如 `345 ms`）。

use serde::Serialize;

use crate::collectors::app_dumps::first_uint;

/// 请求未带 `mode`（或值无法识别）时的缺省模式。
pub const DEFAULT_MODE: &str = "warm";

/// `perf.parse_startup` 的成功 `data`。数字字段解析不到时为 `null`。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StartupReport {
    /// `"ok"` 或 `"Error"`（存在 `Error:` 行时）。恒为字符串。
    pub status: String,
    /// `Activity:` 行的组件名（`com.x/.MainActivity`）；缺失 → `null`。
    pub activity: Option<String>,
    /// `ThisTime:` 毫秒；缺失/不可解析 → `null`。
    pub this_time_ms: Option<u64>,
    /// `TotalTime:` 毫秒；缺失/不可解析 → `null`。
    pub total_time_ms: Option<u64>,
    /// `WaitTime:` 毫秒；缺失/不可解析 → `null`。
    pub wait_time_ms: Option<u64>,
    /// 回显请求的启动模式（`"cold"` / `"warm"`，缺省 `"warm"`）。
    pub mode: String,
}

/// 归一化请求的 `mode`：仅 `cold`（大小写不敏感）视为冷启动，其余（含缺省）为 `warm`。
fn normalize_mode(mode: Option<&str>) -> String {
    match mode.map(str::trim) {
        Some(m) if m.eq_ignore_ascii_case("cold") => "cold".to_string(),
        _ => DEFAULT_MODE.to_string(),
    }
}

/// 取 `line`（已 `trim`）中 `label` 之后的整段值（去首尾空白）；非该标签起始 → `None`。
fn value_after<'a>(line: &'a str, label: &str) -> Option<&'a str> {
    line.strip_prefix(label).map(str::trim)
}

/// 解析 `am start -W` 的 stdout；`mode` 为请求值（`None` → `"warm"`）。绝不 panic。
pub fn parse_startup(output: &str, mode: Option<&str>) -> StartupReport {
    let mut status: Option<String> = None;
    let mut activity: Option<String> = None;
    let mut this_time_ms: Option<u64> = None;
    let mut total_time_ms: Option<u64> = None;
    let mut wait_time_ms: Option<u64> = None;
    let mut has_error = false;

    for line in output.lines() {
        let t = line.trim();
        if t.starts_with("Error:") {
            has_error = true;
        } else if let Some(v) = value_after(t, "Status:") {
            if status.is_none() && !v.is_empty() {
                status = Some(v.to_string());
            }
        } else if let Some(v) = value_after(t, "Activity:") {
            if activity.is_none() && !v.is_empty() {
                activity = Some(v.to_string());
            }
        } else if let Some(v) = value_after(t, "ThisTime:") {
            if this_time_ms.is_none() {
                this_time_ms = first_uint(v);
            }
        } else if let Some(v) = value_after(t, "TotalTime:") {
            if total_time_ms.is_none() {
                total_time_ms = first_uint(v);
            }
        } else if let Some(v) = value_after(t, "WaitTime:") {
            if wait_time_ms.is_none() {
                wait_time_ms = first_uint(v);
            }
        }
        // `LaunchState:`/`Warning:`/其它行原样忽略（契约要求 `mode` 回显请求）。
    }

    let status = if has_error {
        "Error".to_string()
    } else {
        status.unwrap_or_else(|| "ok".to_string())
    };

    StartupReport {
        status,
        activity,
        this_time_ms,
        total_time_ms,
        wait_time_ms,
        mode: normalize_mode(mode),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const COLD: &str = "\
Starting: Intent { cmp=com.x/.MainActivity }
Status: ok
Activity: com.x/.MainActivity
ThisTime: 345
TotalTime: 345
WaitTime: 400
LaunchState: COLD
";

    const WARM: &str = "\
Starting: Intent { cmp=com.x/.MainActivity }
Status: ok
Activity: com.x/.MainActivity
ThisTime: 120
TotalTime: 130
WaitTime: 150
LaunchState: WARM
";

    const ERROR: &str = "\
Starting: Intent { cmp=com.x/.MainActivity }
Error: Activity not started, unable to resolve Intent { act=android.intent.action.MAIN flg=0x10000000 }
";

    #[test]
    fn parses_full_cold_start_output() {
        let r = parse_startup(COLD, Some("cold"));
        assert_eq!(r.status, "ok");
        assert_eq!(r.activity.as_deref(), Some("com.x/.MainActivity"));
        assert_eq!(r.this_time_ms, Some(345));
        assert_eq!(r.total_time_ms, Some(345));
        assert_eq!(r.wait_time_ms, Some(400));
        assert_eq!(r.mode, "cold");
    }

    #[test]
    fn parses_warm_start_output_and_defaults_mode() {
        let r = parse_startup(WARM, None);
        assert_eq!(r.status, "ok");
        assert_eq!(r.activity.as_deref(), Some("com.x/.MainActivity"));
        assert_eq!(r.this_time_ms, Some(120));
        assert_eq!(r.total_time_ms, Some(130));
        assert_eq!(r.wait_time_ms, Some(150));
        assert_eq!(r.mode, "warm");
    }

    #[test]
    fn error_line_forces_error_status() {
        let r = parse_startup(ERROR, Some("cold"));
        assert_eq!(r.status, "Error");
        assert_eq!(r.activity, None); // 无 `Activity:` 行
        assert_eq!(r.this_time_ms, None);
        assert_eq!(r.total_time_ms, None);
        assert_eq!(r.wait_time_ms, None);
        assert_eq!(r.mode, "cold");
    }

    #[test]
    fn error_overrides_a_status_line_regardless_of_order() {
        // 即使 `Status:` 出现在 `Error:` 之后，仍以 Error 为准。
        let r = parse_startup("Error: boom\nStatus: ok\nTotalTime: 42\n", None);
        assert_eq!(r.status, "Error");
        assert_eq!(r.total_time_ms, Some(42));
    }

    #[test]
    fn partial_output_leaves_missing_fields_null() {
        let r = parse_startup("TotalTime: 250 ms\n", Some("warm"));
        assert_eq!(r.status, "ok");
        assert_eq!(r.activity, None);
        assert_eq!(r.total_time_ms, Some(250)); // 容忍尾随文本 ` ms`
        assert_eq!(r.this_time_ms, None);
        assert_eq!(r.wait_time_ms, None);
        assert_eq!(r.mode, "warm");
    }

    #[test]
    fn warning_line_is_tolerated_without_turning_into_error() {
        let text = "\
Warning: Activity not started, intent has been delivered to currently running top-most instance.
Status: ok
Activity: com.x/.MainActivity
WaitTime: 12
";
        let r = parse_startup(text, Some("warm"));
        assert_eq!(r.status, "ok");
        assert_eq!(r.activity.as_deref(), Some("com.x/.MainActivity"));
        assert_eq!(r.wait_time_ms, Some(12));
    }

    #[test]
    fn garbage_input_yields_null_fields_and_never_panics() {
        let r = parse_startup("adb: command not found\n?????\n", Some("cold"));
        assert_eq!(r.status, "ok");
        assert_eq!(r.activity, None);
        assert!(r.this_time_ms.is_none());
        assert!(r.total_time_ms.is_none());
        assert!(r.wait_time_ms.is_none());
        assert_eq!(r.mode, "cold");

        let empty = parse_startup("", None);
        assert_eq!(empty.status, "ok");
        assert_eq!(empty.activity, None);
        assert_eq!(empty.mode, "warm");
    }

    #[test]
    fn mode_normalisation_handles_case_and_unknown_values() {
        assert_eq!(normalize_mode(None), "warm");
        assert_eq!(normalize_mode(Some("")), "warm");
        assert_eq!(normalize_mode(Some("warm")), "warm");
        assert_eq!(normalize_mode(Some("WARM")), "warm");
        assert_eq!(normalize_mode(Some("cold")), "cold");
        assert_eq!(normalize_mode(Some(" COLD ")), "cold");
        assert_eq!(normalize_mode(Some("bogus")), "warm");
    }

    #[test]
    fn explicit_zero_times_are_preserved_not_treated_as_absent() {
        let r = parse_startup("ThisTime: 0\nTotalTime: 0\nWaitTime: 0\n", None);
        assert_eq!(r.this_time_ms, Some(0));
        assert_eq!(r.total_time_ms, Some(0));
        assert_eq!(r.wait_time_ms, Some(0));
    }

    #[test]
    fn first_occurrence_of_each_label_wins() {
        let text = "TotalTime: 1\nTotalTime: 2\nActivity: com.a/.A\nActivity: com.b/.B\n";
        let r = parse_startup(text, None);
        assert_eq!(r.total_time_ms, Some(1));
        assert_eq!(r.activity.as_deref(), Some("com.a/.A"));
    }
}
