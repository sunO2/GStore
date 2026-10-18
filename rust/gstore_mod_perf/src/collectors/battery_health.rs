//! 电池健康深挖：`/sys/class/power_supply/{battery,bms,*}/`。
//!
//! 只读；相对既有 `perf.battery` 补充 `charge_counter_uah`，并单独成方法便于 UI 展示
//! 满充容量 / 设计容量 / 循环次数 / 健康度。电压、温度复用 `battery` 模块的缩放启发式。
//! 无电池（桌面/模拟器）→ `present:false`，各字段独立 `null`，绝不 panic。

use serde::Serialize;

use super::battery::{scale_temp_deci, scale_voltage_uv};
use super::util;

/// 电池健康报告（缺省字段为 `null`，`present=false` 表示无电池）。
#[derive(Debug, Clone, Serialize)]
pub struct BatteryHealthReport {
    pub present: bool,
    pub base_path: Option<String>,
    pub charge_full_uah: Option<i64>,
    pub charge_full_design_uah: Option<i64>,
    pub cycle_count: Option<i64>,
    pub health: Option<String>,
    pub status: Option<String>,
    pub technology: Option<String>,
    pub charge_counter_uah: Option<i64>,
    pub capacity_percent: Option<f64>,
    pub voltage_v: Option<f64>,
    pub temperature_c: Option<f64>,
}

fn attr_i64<F: Fn(&str) -> Option<String>>(read: &F, names: &[&str]) -> Option<i64> {
    names
        .iter()
        .find_map(|n| read(n).and_then(|s| util::first_token_i64(&s)))
}

fn attr_str<F: Fn(&str) -> Option<String>>(read: &F, names: &[&str]) -> Option<String> {
    names.iter().find_map(|n| {
        read(n)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    })
}

/// 由读取闭包构造报告（纯函数；`base` 仅回显来源路径）。
pub fn build_report<F>(base: Option<String>, read: F) -> BatteryHealthReport
where
    F: Fn(&str) -> Option<String>,
{
    BatteryHealthReport {
        present: base.is_some(),
        base_path: base,
        charge_full_uah: attr_i64(&read, &["charge_full"]),
        charge_full_design_uah: attr_i64(&read, &["charge_full_design"]),
        cycle_count: attr_i64(&read, &["cycle_count"]),
        health: attr_str(&read, &["health"]),
        status: attr_str(&read, &["status"]),
        technology: attr_str(&read, &["technology"]),
        charge_counter_uah: attr_i64(&read, &["charge_counter", "charge_counter_uah"]),
        capacity_percent: attr_i64(&read, &["capacity"]).map(|v| util::clamp_percent(v as f64)),
        voltage_v: attr_i64(&read, &["voltage_now"]).map(scale_voltage_uv),
        temperature_c: attr_i64(&read, &["temp", "temperature"]).map(scale_temp_deci),
    }
}

/// 选取电池节点：优先 `battery`，其次 `bms`，最后目录名排序后的第一个。
#[cfg(any(target_os = "linux", target_os = "android"))]
fn pick_base() -> Option<String> {
    const ROOT: &str = "/sys/class/power_supply";
    for preferred in ["battery", "bms"] {
        let p = format!("{ROOT}/{preferred}");
        if std::path::Path::new(&p).is_dir() {
            return Some(p);
        }
    }
    let mut entries: Vec<String> = std::fs::read_dir(ROOT)
        .ok()?
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            if p.is_dir() {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| format!("{ROOT}/{n}"))
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

/// 采集当前电池健康状态。
pub fn collect() -> BatteryHealthReport {
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
    fn build_report_reads_full_fixture() {
        let read = |name: &str| -> Option<String> {
            match name {
                "charge_full" => Some("4000000\n".into()),
                "charge_full_design" => Some("4500000".into()),
                "cycle_count" => Some("123".into()),
                "health" => Some("Good".into()),
                "status" => Some("Charging".into()),
                "technology" => Some("Li-ion".into()),
                "charge_counter" => Some("1234567".into()),
                "capacity" => Some("80".into()),
                "voltage_now" => Some("4200000".into()),
                "temp" => Some("330".into()),
                _ => None,
            }
        };
        let r = build_report(Some("/sys/class/power_supply/battery".into()), read);
        assert!(r.present);
        assert_eq!(r.base_path.as_deref(), Some("/sys/class/power_supply/battery"));
        assert_eq!(r.charge_full_uah, Some(4_000_000));
        assert_eq!(r.charge_full_design_uah, Some(4_500_000));
        assert_eq!(r.cycle_count, Some(123));
        assert_eq!(r.health.as_deref(), Some("Good"));
        assert_eq!(r.status.as_deref(), Some("Charging"));
        assert_eq!(r.technology.as_deref(), Some("Li-ion"));
        assert_eq!(r.charge_counter_uah, Some(1_234_567));
        assert_eq!(r.capacity_percent, Some(80.0));
        assert_eq!(r.voltage_v, Some(4.2));
        assert_eq!(r.temperature_c, Some(33.0));
    }

    #[test]
    fn build_report_falls_back_to_charge_counter_uah_alias() {
        let read = |name: &str| -> Option<String> {
            match name {
                "charge_counter_uah" => Some("7654321".into()),
                _ => None,
            }
        };
        let r = build_report(Some("/sys/class/power_supply/bms".into()), read);
        assert_eq!(r.charge_counter_uah, Some(7_654_321));
    }

    #[test]
    fn build_report_capacity_is_clamped() {
        let read = |name: &str| -> Option<String> {
            match name {
                "capacity" => Some("150".into()),
                _ => None,
            }
        };
        let r = build_report(Some("/x".into()), read);
        assert_eq!(r.capacity_percent, Some(100.0));
    }

    #[test]
    fn absent_battery_is_graceful() {
        let r = build_report(None, |_| None);
        assert!(!r.present);
        assert!(r.base_path.is_none());
        assert!(r.charge_full_uah.is_none());
        assert!(r.charge_counter_uah.is_none());
        assert!(r.cycle_count.is_none());
    }

    #[test]
    fn collect_tolerates_absence() {
        // 宿主无电池时 present=false 且不 panic。
        let r = collect();
        if r.present {
            assert!(r.base_path.is_some());
        } else {
            assert!(r.base_path.is_none());
        }
    }
}
