//! `dumpsys package <pkg>` 包信息解析（`perf.parse_app_dumps` 的 `app_info` 段）。
//!
//! **纯解析**：输入为宿主经 Shizuku 采集的原始文本，本模块不启动 shell、不做 JNI、
//! 不需要特权，绝不 panic。字段按标签逐行扫描，识别不到任何字段 → `None`（JSON `null`），
//! 单个字段缺失 → 该字段 `null`。时间字段（`firstInstallTime`/`lastUpdateTime`）
//! **按字符串原样保留**。

use serde::Serialize;

use crate::collectors::app_dumps::{after_label, first_uint};

/// `dumpsys package <pkg>` 的包信息摘要。除计数外，字段均可能为 `None`。
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct AppInfo {
    pub version_name: Option<String>,
    pub version_code: Option<u64>,
    pub target_sdk: Option<u64>,
    pub min_sdk: Option<u64>,
    pub first_install: Option<String>,
    pub last_update: Option<String>,
    pub code_path: Option<String>,
    pub data_dir: Option<String>,
    pub is_system: Option<bool>,
    pub enabled: Option<bool>,
    pub requested_permissions: Option<u64>,
    pub granted_permissions: Option<u64>,
    pub activity_count: Option<u64>,
    pub service_count: Option<u64>,
    pub receiver_count: Option<u64>,
    pub provider_count: Option<u64>,
}

/// `key=` 之后的行尾内容（trim 后非空才返回）；取首个命中行。
fn value_after(text: &str, label: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let rest = after_label(line, label)?.trim();
        (!rest.is_empty()).then(|| rest.to_string())
    })
}

/// `key=` 之后的首个整数（取首个命中行）；标签不存在/后无数字 → `None`。
fn uint_after(text: &str, label: &str) -> Option<u64> {
    text.lines()
        .find_map(|line| after_label(line, label).and_then(first_uint))
}

/// 首个 `flags=[ ... ]` 的括号内容；无该标记 → `None`。
fn flags_content(text: &str) -> Option<&str> {
    let start = text.find("flags=[")? + "flags=[".len();
    let rest = &text[start..];
    let end = rest.find(']')?;
    Some(&rest[..end])
}

/// 空格/标点分隔的 flag 是否精确出现（`SYSTEM_UID` 不匹配 `SYSTEM`）。
fn has_flag(flags: &str, name: &str) -> bool {
    flags
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .any(|token| token == name)
}

/// `enabled` 判定：`flags` 含 `DISABLED` → `false`；否则看 `enabled=`（`true`/`false` 或
/// 整数，0/1 视为启用，≥2 视为停用）。均未出现 → `None`。
fn parse_enabled(text: &str) -> Option<bool> {
    if flags_content(text).is_some_and(|f| has_flag(f, "DISABLED")) {
        return Some(false);
    }
    for line in text.lines() {
        let Some(rest) = after_label(line, "enabled=") else {
            continue;
        };
        let token = rest.split_whitespace().next().unwrap_or("");
        if token.eq_ignore_ascii_case("true") {
            return Some(true);
        }
        if token.eq_ignore_ascii_case("false") {
            return Some(false);
        }
        if let Ok(n) = token.parse::<i64>() {
            return Some(n <= 1);
        }
    }
    None
}

/// `header` 行之下缩进更深的连续非空行（下一同级/更浅缩进行截止）。
fn indented_block<'a>(text: &'a str, header: &str) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut header_indent: Option<usize> = None;
    for line in text.lines() {
        let trimmed = line.trim_end();
        let indent = trimmed.len() - trimmed.trim_start().len();
        match header_indent {
            None => {
                if trimmed.trim() == header {
                    header_indent = Some(indent);
                }
            }
            Some(hi) => {
                if trimmed.trim().is_empty() {
                    continue;
                }
                if indent <= hi {
                    break;
                }
                out.push(trimmed);
            }
        }
    }
    out
}

/// ``<header>`（表头，0 缩进）到下一 0 缩进行之间的块。
fn resolver_block<'a>(text: &'a str, header: &str) -> Option<Vec<&'a str>> {
    let mut out = Vec::new();
    let mut started = false;
    for line in text.lines() {
        let trimmed = line.trim_end();
        let indent = trimmed.len() - trimmed.trim_start().len();
        if !started {
            if trimmed.trim() == header {
                started = true;
            }
            continue;
        }
        if trimmed.trim().is_empty() {
            continue;
        }
        if indent == 0 {
            break;
        }
        out.push(trimmed);
    }
    started.then_some(out)
}

/// 某 Resolver Table 中归属 `package` 的组件条目数（含 `package/` 的行）；表缺失 → `None`。
fn component_count(text: &str, package: &str, header: &str) -> Option<u64> {
    let needle = format!("{package}/");
    resolver_block(text, header).map(|block| {
        block.iter().filter(|line| line.contains(&needle)).count() as u64
    })
}

/// 解析 `dumpsys package <pkg>` 文本（`package` 为请求包名，用于组件计数）；无任何
/// 可识别字段 → `None`。
pub fn parse_app_info(text: &str, package: &str) -> Option<AppInfo> {
    if text.trim().is_empty() {
        return None;
    }
    let requested = {
        let block = indented_block(text, "requested permissions:");
        (!block.is_empty()).then_some(block.len() as u64)
    };
    let granted = text
        .contains("granted=")
        .then(|| text.lines().filter(|l| l.contains("granted=true")).count() as u64);
    let info = AppInfo {
        version_name: value_after(text, "versionName="),
        version_code: uint_after(text, "versionCode="),
        target_sdk: uint_after(text, "targetSdk="),
        min_sdk: uint_after(text, "minSdk="),
        first_install: value_after(text, "firstInstallTime="),
        last_update: value_after(text, "lastUpdateTime="),
        code_path: value_after(text, "codePath="),
        data_dir: value_after(text, "dataDir="),
        is_system: flags_content(text).map(|f| has_flag(f, "SYSTEM")),
        enabled: parse_enabled(text),
        requested_permissions: requested,
        granted_permissions: granted,
        activity_count: component_count(text, package, "Activity Resolver Table:"),
        service_count: component_count(text, package, "Service Resolver Table:"),
        receiver_count: component_count(text, package, "Receiver Resolver Table:"),
        provider_count: component_count(text, package, "Provider Resolver Table:"),
    };
    let any = info.version_name.is_some()
        || info.version_code.is_some()
        || info.target_sdk.is_some()
        || info.min_sdk.is_some()
        || info.first_install.is_some()
        || info.last_update.is_some()
        || info.code_path.is_some()
        || info.data_dir.is_some()
        || info.is_system.is_some()
        || info.enabled.is_some()
        || info.requested_permissions.is_some()
        || info.granted_permissions.is_some();
    any.then_some(info)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DUMP: &str = "\
Packages:
  Package [com.example.app] (a1b2c3d4):
    userId=10123
    pkg=Package{e5f6 com.example.app}
    codePath=/data/app/~~xyz==/com.example.app-abc==/base.apk
    resourcePath=/data/app/~~xyz==/com.example.app-abc==/base.apk
    versionCode=123 minSdk=24 targetSdk=33
    versionName=1.2.3
    splits=[base, config.en]
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ALLOW_BACKUP ]
    privateFlags=[ PRIVATE_FLAG_ACTIVITIES_RESIZE_MODE_PRESERVE ]
    dataDir=/data/user/0/com.example.app
    firstInstallTime=2023-01-01 12:00:00
    lastUpdateTime=2024-01-01 12:00:00
    requested permissions:
      android.permission.INTERNET
      android.permission.ACCESS_NETWORK_STATE
      android.permission.CAMERA
      android.permission.POST_NOTIFICATIONS
    install permissions:
      android.permission.INTERNET: granted=true
      android.permission.ACCESS_NETWORK_STATE: granted=true
      android.permission.POST_NOTIFICATIONS: granted=true
    User 0: ceDataInode=123 installed=true hidden=false suspended=false enabled=0
      runtime permissions:
        android.permission.CAMERA: granted=false, flags=[ USER_SET ]

Activity Resolver Table:
  Non-Data Actions:
      android.intent.action.MAIN:
        1a2b3c4 com.example.app/.MainActivity filter 5d6e7f8
          Action: \"android.intent.action.MAIN\"
          Category: \"android.intent.category.LAUNCHER\"

Receiver Resolver Table:
  Non-Data Actions:
      android.intent.action.BOOT_COMPLETED:
        9f8e7d6 com.example.app/.BootReceiver filter 1a2b3c4

Service Resolver Table:
  Non-Data Actions:
      com.example.app.SYNC:
        5d6e7f8 com.example.app/.SyncService filter 9f8e7d6
      com.example.app.ALT:
        6e7f8a9 com.example.app/.AltService filter 2b3c4d5

Provider Resolver Table:
  Authority:
      com.example.app.provider:
        2b3c4d5 com.example.app/.MyProvider filter 6e7f8a9
";

    #[test]
    fn parses_versions_paths_and_times() {
        let a = parse_app_info(DUMP, "com.example.app").unwrap();
        assert_eq!(a.version_name.as_deref(), Some("1.2.3"));
        assert_eq!(a.version_code, Some(123));
        assert_eq!(a.min_sdk, Some(24));
        assert_eq!(a.target_sdk, Some(33));
        assert_eq!(a.first_install.as_deref(), Some("2023-01-01 12:00:00"));
        assert_eq!(a.last_update.as_deref(), Some("2024-01-01 12:00:00"));
        assert_eq!(
            a.code_path.as_deref(),
            Some("/data/app/~~xyz==/com.example.app-abc==/base.apk")
        );
        assert_eq!(a.data_dir.as_deref(), Some("/data/user/0/com.example.app"));
    }

    #[test]
    fn parses_flags_enabled_and_permission_counts() {
        let a = parse_app_info(DUMP, "com.example.app").unwrap();
        assert_eq!(a.is_system, Some(false)); // privateFlags 的 PRIVATE_FLAG... 不误判
        assert_eq!(a.enabled, Some(true)); // enabled=0 → 默认启用
        assert_eq!(a.requested_permissions, Some(4));
        assert_eq!(a.granted_permissions, Some(3));
    }

    #[test]
    fn counts_components_per_resolver_table() {
        let a = parse_app_info(DUMP, "com.example.app").unwrap();
        assert_eq!(a.activity_count, Some(1));
        assert_eq!(a.receiver_count, Some(1));
        assert_eq!(a.service_count, Some(2));
        assert_eq!(a.provider_count, Some(1));
    }

    #[test]
    fn system_flag_and_disabled_state() {
        let text = "\
  Package [com.sys.app] (deadbeef):
    versionCode=1 minSdk=21 targetSdk=30
    versionName=9.9
    flags=[ SYSTEM HAS_CODE ]
    User 0: installed=true enabled=2
";
        let a = parse_app_info(text, "com.example.app").unwrap();
        assert_eq!(a.is_system, Some(true));
        assert_eq!(a.enabled, Some(false)); // enabled=2 → 停用
        // 无 Resolver Table 段 → 组件计数为 null
        assert_eq!(a.activity_count, None);
        assert_eq!(a.service_count, None);
    }

    #[test]
    fn missing_resolver_sections_yield_null_counts() {
        let text = "  Package [com.x] (1):\n    versionCode=2 minSdk=24 targetSdk=33\n";
        let a = parse_app_info(text, "com.example.app").unwrap();
        assert_eq!(a.version_code, Some(2));
        assert_eq!(a.activity_count, None);
        assert_eq!(a.provider_count, None);
    }

    #[test]
    fn empty_or_garbage_input_is_none() {
        assert_eq!(parse_app_info("", "com.x"), None);
        assert_eq!(parse_app_info("   \n\n", "com.x"), None);
        assert_eq!(parse_app_info("random text without any fields", "com.x"), None);
    }
}
