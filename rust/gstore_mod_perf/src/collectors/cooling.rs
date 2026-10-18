//! 散热设备采集：枚举 `/sys/class/thermal/cooling_device*/`（`type`/`cur_state`/`max_state`）。
//!
//! 只读；无设备（桌面/模拟器）→ `count:0, devices:[]`，绝不 panic。

use serde::Serialize;

use super::util;

/// 单个散热设备（`type` 映射为 JSON 键 `type`）。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CoolingDevice {
    pub device: String,
    #[serde(rename = "type")]
    pub kind: Option<String>,
    pub cur_state: Option<i64>,
    pub max_state: Option<i64>,
}

/// 散热设备报告。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CoolingReport {
    pub count: usize,
    pub devices: Vec<CoolingDevice>,
}

/// 由读取闭包构造设备（纯函数，可单测）。
pub fn build_device<F>(device: String, read: F) -> CoolingDevice
where
    F: Fn(&str) -> Option<String>,
{
    CoolingDevice {
        device,
        kind: read("type")
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        cur_state: read("cur_state").and_then(|s| util::first_token_i64(&s)),
        max_state: read("max_state").and_then(|s| util::first_token_i64(&s)),
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn enumerate() -> Vec<CoolingDevice> {
    const ROOT: &str = "/sys/class/thermal";
    let Ok(entries) = std::fs::read_dir(ROOT) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
        .filter(|n| n.starts_with("cooling_device"))
        .collect();
    names.sort();
    names
        .into_iter()
        .map(|name| {
            let base = format!("{ROOT}/{name}");
            build_device(name, |attr| util::read_trimmed(&format!("{base}/{attr}")))
        })
        .collect()
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn enumerate() -> Vec<CoolingDevice> {
    Vec::new()
}

/// 采集全部散热设备。
pub fn collect() -> CoolingReport {
    let devices = enumerate();
    CoolingReport {
        count: devices.len(),
        devices,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_device_reads_sysfs_fixture() {
        let read = |name: &str| -> Option<String> {
            match name {
                "type" => Some("cpu\n".into()),
                "cur_state" => Some("0\n".into()),
                "max_state" => Some("10\n".into()),
                _ => None,
            }
        };
        let d = build_device("cooling_device0".into(), read);
        assert_eq!(d.device, "cooling_device0");
        assert_eq!(d.kind.as_deref(), Some("cpu"));
        assert_eq!(d.cur_state, Some(0));
        assert_eq!(d.max_state, Some(10));
    }

    #[test]
    fn build_device_tolerates_missing_attrs() {
        let d = build_device("cooling_device3".into(), |_| None);
        assert_eq!(d.device, "cooling_device3");
        assert!(d.kind.is_none());
        assert!(d.cur_state.is_none());
        assert!(d.max_state.is_none());
    }

    #[test]
    fn build_device_blank_type_is_none_and_first_token_parsed() {
        let read = |name: &str| -> Option<String> {
            match name {
                "type" => Some("   \n".into()),
                "cur_state" => Some("2 %".into()),
                "max_state" => Some("garbage".into()),
                _ => None,
            }
        };
        let d = build_device("cooling_device1".into(), read);
        assert!(d.kind.is_none());
        assert_eq!(d.cur_state, Some(2));
        assert!(d.max_state.is_none());
    }

    #[test]
    fn collect_tolerates_absence() {
        // 桌面/容器通常没有 cooling_device —— 必须优雅返回 count 与 devices 一致。
        let r = collect();
        assert_eq!(r.count, r.devices.len());
        for d in &r.devices {
            assert!(d.device.starts_with("cooling_device"));
        }
    }
}
