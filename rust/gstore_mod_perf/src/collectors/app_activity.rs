//! `dumpsys activity activities` 前台状态解析（`perf.parse_app_dumps` 的 `foreground` 段）。
//!
//! **纯解析 + best-effort**：输入为宿主经 Shizuku 采集的原始文本，本模块不启动 shell、
//! 不做 JNI、不需要特权，绝不 panic。仅当文本中存在 resumed 活动行（`mResumedActivity` /
//! `topResumedActivity` / `ResumedActivity`）时才能判定；无法判定 → `None`（JSON `null`）。

use serde::Serialize;

/// 前台状态。仅当能判定时整体为 `Some`。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ForegroundState {
    pub is_foreground: bool,
}

/// resumed 活动行的判据：`mResumedActivity`/`topResumedActivity` 均含 `ResumedActivity`。
const RESUMED: &str = "ResumedActivity";

/// 解析活动文本；存在 resumed 行时按其中是否提及 `package` 判定，否则 `None`。
pub fn parse_foreground(text: &str, package: &str) -> Option<ForegroundState> {
    let mut seen = false;
    let mut is_foreground = false;
    for line in text.lines() {
        if line.contains(RESUMED) {
            seen = true;
            if line.contains(package) {
                is_foreground = true;
                break;
            }
        }
    }
    seen.then_some(ForegroundState { is_foreground })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ACTIVITY: &str = "\
ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)
  Display #0 (activities from top to bottom):
    * Task{1234 #1 type=home}
      * ActivityRecord{aaa u0 com.other.app/.Home t1}
    * Task{5678 #2 type=standard A=10123:com.x}
      * ActivityRecord{bbb u0 com.x/.MainActivity t2}
  mResumedActivity: ActivityRecord{bbb u0 com.x/.MainActivity t2}
  mFocusedApp=ActivityRecord{bbb u0 com.x/.MainActivity t2}
";

    #[test]
    fn resumed_line_matching_package_is_foreground() {
        let f = parse_foreground(ACTIVITY, "com.x").unwrap();
        assert!(f.is_foreground);
    }

    #[test]
    fn top_resumed_variant_is_detected() {
        let text = "topResumedActivity=ActivityRecord{ccc u0 com.x/.Other t3}\n";
        let f = parse_foreground(text, "com.x").unwrap();
        assert!(f.is_foreground);
    }

    #[test]
    fn resumed_line_for_other_package_is_background() {
        let text = "  mResumedActivity: ActivityRecord{aaa u0 com.other.app/.Home t1}\n";
        let f = parse_foreground(text, "com.x").unwrap();
        assert!(!f.is_foreground);
    }

    #[test]
    fn no_resumed_line_is_undetermined() {
        let text = "ACTIVITY MANAGER ACTIVITIES\n  * Task{1}\n";
        assert_eq!(parse_foreground(text, "com.x"), None);
        assert_eq!(parse_foreground("", "com.x"), None);
    }
}
