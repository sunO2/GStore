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

/// 从一条 resumed 活动行中抽取包名：找形如 `<pkg>/<activity>` 的 token，返回其 `<pkg>`。
///
/// 兼容 `ActivityRecord{hash u0 <pkg>/<activity> tN}`（含 `u0` 用户前缀）与
/// `ActivityRecord{hash <pkg>/<activity> tN}`（无前缀）两种形态；`<pkg>` 必须是
/// 合法包名 token（字母开头、仅 `[A-Za-z0-9_.]`），据此排除 `tN}`、`u0`、
/// `ActivityRecord{...}` 等噪声 token。
fn package_from_resumed_line(line: &str) -> Option<&str> {
    line.split_whitespace().find_map(|tok| {
        let (pkg, _activity) = tok.split_once('/')?;
        is_package_token(pkg).then_some(pkg)
    })
}

/// 包名 token 判据：字母开头，其余为 `[A-Za-z0-9_.]`（与 Android 包名约束一致）。
fn is_package_token(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() => {}
        _ => return false,
    }
    s.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
}

/// 从 `dumpsys activity activities` 文本中抽取**当前前台包名**。
///
/// 扫描含 resumed 标记（`mResumedActivity` / `topResumedActivity` / `ResumedActivity`）的行，
/// 取其中 `<pkg>/<activity>` 的 `<pkg>`。**无法判定即 `None`（JSON `null`），绝不报错、绝不猜测**：
/// 无 resumed 行、resumed 行为 `null`、行内无可识别包名 token、或出现**两个不同包**
/// （多窗口/折叠屏歧义）均返回 `None`。仅提取包名，不保留前台活动全文。
pub fn parse_current_package(text: &str) -> Option<String> {
    let mut found: Option<&str> = None;
    for line in text.lines() {
        if !line.contains(RESUMED) {
            continue;
        }
        let Some(pkg) = package_from_resumed_line(line) else {
            continue;
        };
        match found {
            None => found = Some(pkg),
            Some(prev) if prev == pkg => {}
            // 多窗口/异常 dumpsys：两个不同的 resumed 包 → 无法判定，不猜。
            Some(_) => return None,
        }
    }
    found.map(str::to_string)
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

    // Android 12 形态：`mResumedActivity: ActivityRecord{hash u0 <pkg>/<act> tN}`。
    const DUMP_A12: &str = "\
ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)
Display #0 (activities from top to bottom):
  * Task{9d0d8a2 #1 type=home}
    * ActivityRecord{1a2b3c4 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t1}
  * Task{7f6e5d4 #2 type=standard A=10234:com.example.app}
    * ActivityRecord{5c4b3a2 u0 com.example.app/.MainActivity t2}
  mResumedActivity: ActivityRecord{5c4b3a2 u0 com.example.app/.MainActivity t2}
  mFocusedApp=ActivityRecord{5c4b3a2 u0 com.example.app/.MainActivity t2}
";

    // Android 13 形态：`ResumedActivity:` 行。
    const DUMP_A13: &str = "\
ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)
  ResumedActivity: ActivityRecord{3f2e1d0 u0 com.app.thirteen/.HomeActivity t7}
  mFocusedApp=ActivityRecord{3f2e1d0 u0 com.app.thirteen/.HomeActivity t7}
";

    // Android 14 形态：`topResumedActivity=ActivityRecord{hash u0 <pkg>/<pkg>.<act> tN}`（无空格分隔 `/`）。
    const DUMP_A14: &str = "\
ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)
  * Task{f1e2d3c #4 type=standard A=10500:com.app.fourteen}
    * ActivityRecord{a0b1c2d u0 com.app.fourteen/com.app.fourteen.MainActivity t42}
  topResumedActivity=ActivityRecord{a0b1c2d u0 com.app.fourteen/com.app.fourteen.MainActivity t42}
";

    #[test]
    fn current_package_extracts_android12() {
        assert_eq!(
            parse_current_package(DUMP_A12).as_deref(),
            Some("com.example.app")
        );
    }

    #[test]
    fn current_package_extracts_android13() {
        assert_eq!(
            parse_current_package(DUMP_A13).as_deref(),
            Some("com.app.thirteen")
        );
    }

    #[test]
    fn current_package_extracts_android14() {
        assert_eq!(
            parse_current_package(DUMP_A14).as_deref(),
            Some("com.app.fourteen")
        );
    }

    #[test]
    fn current_package_names_a_different_package() {
        let text = "  mResumedActivity: ActivityRecord{aaa u0 com.other.app/.Home t1}\n";
        assert_eq!(
            parse_current_package(text).as_deref(),
            Some("com.other.app")
        );
    }

    #[test]
    fn current_package_without_resumed_line_is_none() {
        let text = "ACTIVITY MANAGER ACTIVITIES\n  * Task{1}\n";
        assert_eq!(parse_current_package(text), None);
        assert_eq!(parse_current_package(""), None);
    }

    #[test]
    fn current_package_null_resumed_line_is_none() {
        assert_eq!(
            parse_current_package("  mResumedActivity: null\n  topResumedActivity=null\n"),
            None
        );
    }

    #[test]
    fn current_package_ambiguous_two_packages_is_none() {
        let text = "\
  mResumedActivity: ActivityRecord{aaa u0 com.a/.Main t1}
  topResumedActivity=ActivityRecord{bbb u0 com.b/.Main t2}
";
        assert_eq!(parse_current_package(text), None);
    }

    #[test]
    fn current_package_duplicate_same_package_is_ok() {
        let text = "\
  mResumedActivity: ActivityRecord{aaa u0 com.a/.Main t1}
  topResumedActivity=ActivityRecord{aaa u0 com.a/.Main t1}
";
        assert_eq!(parse_current_package(text).as_deref(), Some("com.a"));
    }
}
