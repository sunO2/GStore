//! 电池采集：`/sys/class/power_supply/{battery,...}/*`，含参考 App 的缩放阈值。
//!
//! 单位与缩放（沿 PERF_SPEC §0.4）：
//! - 电流 `current_now` µA → mA，**仅当 `|v| > 10000` 时 ÷1000**（参考实现原样保留）；
//! - 电压 `voltage_now` µV → V：`>1e6 → /1e6`，`>1000 → /1000`，否则原值；
//! - 温度 `temp` 为十分之一摄氏度 → ÷10；
//! - 无电池（台式机/模拟器）→ `present=false` 的部分数据，不报错。

use serde::Serialize;

use super::util;

/// 电流 µA → mA：`|raw| > 10000` 时 ÷1000。
pub fn scale_current_ua(raw: i64) -> f64 {
    let v = raw as f64;
    if v.abs() > 10_000.0 {
        v / 1000.0
    } else {
        v
    }
}

/// 电压 µV/mV → V 的启发式缩放。
pub fn scale_voltage_uv(raw: i64) -> f64 {
    let v = raw as f64;
    let a = v.abs();
    if a > 1_000_000.0 {
        v / 1_000_000.0
    } else if a > 1000.0 {
        v / 1000.0
    } else {
        v
    }
}

/// 十分之一摄氏度 → 摄氏度。
pub fn scale_temp_deci(raw: i64) -> f64 {
    raw as f64 / 10.0
}

/// 电池报告（缺省字段为 `null`，`present=false` 表示无电池）。
#[derive(Debug, Clone, Serialize)]
pub struct BatteryReport {
    pub present: bool,
    pub base_path: Option<String>,
    pub capacity_percent: Option<f64>,
    pub voltage_v: Option<f64>,
    pub current_ma: Option<f64>,
    pub temperature_c: Option<f64>,
    pub status: Option<String>,
    pub health: Option<String>,
    pub technology: Option<String>,
    pub charge_full_uah: Option<i64>,
    pub charge_full_design_uah: Option<i64>,
    pub cycle_count: Option<i64>,
}

fn attr_i64<F: Fn(&str) -> Option<String>>(read: &F, names: &[&str]) -> Option<i64> {
    for n in names {
        if let Some(v) = read(n).and_then(|s| util::first_token_i64(&s)) {
            return Some(v);
        }
    }
    None
}

fn attr_str<F: Fn(&str) -> Option<String>>(read: &F, names: &[&str]) -> Option<String> {
    for n in names {
        if let Some(v) = read(n) {
            let t = v.trim().to_string();
            if !t.is_empty() {
                return Some(t);
            }
        }
    }
    None
}

/// 由读取闭包构造报告（纯函数；`base` 仅回显来源路径）。
pub fn build_report<F>(base: Option<String>, read: F) -> BatteryReport
where
    F: Fn(&str) -> Option<String>,
{
    let present = base.is_some();
    BatteryReport {
        present,
        base_path: base,
        capacity_percent: attr_i64(&read, &["capacity"]).map(|v| util::clamp_percent(v as f64)),
        voltage_v: attr_i64(&read, &["voltage_now"]).map(scale_voltage_uv),
        current_ma: attr_i64(&read, &["current_now", "batt_current", "batt_current_now", "current_avg"])
            .map(scale_current_ua),
        temperature_c: attr_i64(&read, &["temp", "temperature"]).map(scale_temp_deci),
        status: attr_str(&read, &["status"]),
        health: attr_str(&read, &["health"]),
        technology: attr_str(&read, &["technology"]),
        charge_full_uah: attr_i64(&read, &["charge_full", "charge_full_design"]),
        charge_full_design_uah: attr_i64(&read, &["charge_full_design"]),
        cycle_count: attr_i64(&read, &["cycle_count"]),
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn pick_base() -> Option<String> {
    const ROOT: &str = "/sys/class/power_supply";
    let preferred = format!("{ROOT}/battery");
    if std::path::Path::new(&preferred).is_dir() {
        return Some(preferred);
    }
    let mut entries: Vec<String> = std::fs::read_dir(ROOT)
        .ok()?
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            if p.is_dir() {
                p.file_name().and_then(|n| n.to_str()).map(|n| format!("{ROOT}/{n}"))
            } else {
                None
            }
        })
        .collect();
    entries.sort();
    entries.into_iter().next()
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn pick_base() -> Option<String> {
    None
}

/// 采集当前电池状态。
pub fn collect() -> BatteryReport {
    let base = pick_base();
    let source = base.clone();
    let read = |name: &str| {
        source
            .as_ref()
            .and_then(|b| util::read_trimmed(&format!("{b}/{name}")))
    };
    build_report(base, read)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_scaling_threshold_is_10000_ua() {
        assert_eq!(scale_current_ua(500_000), 500.0);
        assert_eq!(scale_current_ua(-850_000), -850.0);
        assert_eq!(scale_current_ua(12_000), 12.0);
        // 阈值内原样返回（复刻参考实现语义）
        assert_eq!(scale_current_ua(9_000), 9_000.0);
        assert_eq!(scale_current_ua(-10_000), -10_000.0);
    }

    #[test]
    fn voltage_scaling_thresholds() {
        assert_eq!(scale_voltage_uv(3_800_000), 3.8);
        assert_eq!(scale_voltage_uv(3800), 3.8);
        assert_eq!(scale_voltage_uv(500), 500.0);
    }

    #[test]
    fn temperature_is_tenths_of_degree() {
        assert_eq!(scale_temp_deci(350), 35.0);
        assert_eq!(scale_temp_deci(-50), -5.0);
    }

    #[test]
    fn build_report_reads_fixture_attrs() {
        let read = |name: &str| -> Option<String> {
            match name {
                "capacity" => Some("76\n".into()),
                "voltage_now" => Some("3800000".into()),
                "current_now" => Some("-550000".into()),
                "temp" => Some("329".into()),
                "status" => Some("Discharging".into()),
                "health" => Some("Good".into()),
                "technology" => Some("Li-ion".into()),
                "charge_full" => Some("4400000".into()),
                "cycle_count" => Some("123".into()),
                _ => None,
            }
        };
        let r = build_report(Some("/sys/class/power_supply/battery".into()), read);
        assert!(r.present);
        assert_eq!(r.capacity_percent, Some(76.0));
        assert_eq!(r.voltage_v, Some(3.8));
        assert_eq!(r.current_ma, Some(-550.0));
        assert_eq!(r.temperature_c, Some(32.9));
        assert_eq!(r.status.as_deref(), Some("Discharging"));
        assert_eq!(r.cycle_count, Some(123));
    }

    #[test]
    fn absent_battery_is_graceful() {
        let r = build_report(None, |_| None);
        assert!(!r.present);
        assert!(r.base_path.is_none());
        assert!(r.capacity_percent.is_none());
        assert!(r.current_ma.is_none());
    }
}
