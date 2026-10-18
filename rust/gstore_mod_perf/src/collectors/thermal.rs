//! 热区采集：枚举 `/sys/class/thermal/thermal_zone*`（`type`/`temp`）与
//! `/sys/class/hwmon/hwmon*/temp*_input`（+`name`）。
//!
//! 相对参考 App（仅读 1–2 个固定 zone）的增强：完整枚举全部热区，返回列表。
//! 缩放：`|raw| > 1000` 视为毫摄氏度 ÷1000，否则原值（PERF_SPEC §0.4）。

use serde::Serialize;

use super::util;

/// 热区读数（`thermal_zone` 或 `hwmon`）。
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ThermalZone {
    /// 来源：`thermal_zone` / `hwmon`。
    pub source: String,
    /// zone 标识（如 `thermal_zone0`、`hwmon3/temp1_input`）。
    pub zone: String,
    /// `type`（thermal）或 `name`（hwmon）。
    pub kind: Option<String>,
    pub temp_c: f64,
}

/// 毫摄氏度 → 摄氏度：`|raw| > 1000` 时 ÷1000。
pub fn scale_thermal_milli(raw: i64) -> f64 {
    let v = raw as f64;
    if v.abs() > 1000.0 {
        v / 1000.0
    } else {
        v
    }
}

/// 热区报告。
#[derive(Debug, Clone, Serialize)]
pub struct ThermalReport {
    pub zone_count: usize,
    pub max_temp_c: Option<f64>,
    pub zones: Vec<ThermalZone>,
}

pub fn report(zones: Vec<ThermalZone>) -> ThermalReport {
    let max_temp_c = zones
        .iter()
        .map(|z| z.temp_c)
        .fold(None, |acc, v| Some(acc.map_or(v, |a: f64| a.max(v))));
    ThermalReport {
        zone_count: zones.len(),
        max_temp_c,
        zones,
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn enumerate_thermal() -> Vec<ThermalZone> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir("/sys/class/thermal") else {
        return out;
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
        .filter(|n| n.starts_with("thermal_zone"))
        .collect();
    names.sort();
    for name in names {
        let base = format!("/sys/class/thermal/{name}");
        let Some(raw) = util::read_i64(&format!("{base}/temp")) else {
            continue;
        };
        out.push(ThermalZone {
            source: "thermal_zone".into(),
            zone: name,
            kind: util::read_trimmed(&format!("{base}/type")),
            temp_c: scale_thermal_milli(raw),
        });
    }
    out
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn enumerate_hwmon() -> Vec<ThermalZone> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir("/sys/class/hwmon") else {
        return out;
    };
    let mut dirs: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
        .filter(|n| n.starts_with("hwmon"))
        .collect();
    dirs.sort();
    for dir in dirs {
        let base = format!("/sys/class/hwmon/{dir}");
        let name = util::read_trimmed(&format!("{base}/name"));
        let Ok(files) = std::fs::read_dir(&base) else {
            continue;
        };
        let mut inputs: Vec<String> = files
            .flatten()
            .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
            .filter(|n| n.starts_with("temp") && n.ends_with("_input"))
            .collect();
        inputs.sort();
        for input in inputs {
            let Some(raw) = util::read_i64(&format!("{base}/{input}")) else {
                continue;
            };
            out.push(ThermalZone {
                source: "hwmon".into(),
                zone: format!("{dir}/{input}"),
                kind: name.clone(),
                temp_c: scale_thermal_milli(raw),
            });
        }
    }
    out
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn enumerate_thermal() -> Vec<ThermalZone> {
    Vec::new()
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn enumerate_hwmon() -> Vec<ThermalZone> {
    Vec::new()
}

/// 采集全部热区（thermal zones + hwmon）。
pub fn collect() -> Vec<ThermalZone> {
    let mut zones = enumerate_thermal();
    zones.extend(enumerate_hwmon());
    zones
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn milli_degree_scaling_threshold() {
        assert_eq!(scale_thermal_milli(35_000), 35.0);
        assert_eq!(scale_thermal_milli(42_500), 42.5);
        // 阈值内视为已是摄氏度（复刻参考启发式）
        assert_eq!(scale_thermal_milli(350), 350.0);
        assert_eq!(scale_thermal_milli(0), 0.0);
        assert_eq!(scale_thermal_milli(-5_000), -5.0);
    }

    fn z(name: &str, temp: f64) -> ThermalZone {
        ThermalZone {
            source: "thermal_zone".into(),
            zone: name.into(),
            kind: Some("cpu".into()),
            temp_c: temp,
        }
    }

    #[test]
    fn report_tracks_max_and_count() {
        let r = report(vec![z("t0", 35.0), z("t1", 61.5), z("t2", 40.0)]);
        assert_eq!(r.zone_count, 3);
        assert_eq!(r.max_temp_c, Some(61.5));
    }

    #[test]
    fn report_of_empty_has_no_max() {
        let r = report(vec![]);
        assert_eq!(r.zone_count, 0);
        assert!(r.max_temp_c.is_none());
    }
}
