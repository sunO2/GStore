//! PSI 压力采集：`/proc/pressure/{cpu,memory,io}`。
//!
//! 每行形如 `some avg10=0.00 avg60=0.00 avg300=0.00 total=0`（`total` 单位为**微秒**，内核定义）；
//! `memory`/`io` 另有一行 `full ...`，`cpu` 通常只有 `some`。缺失（旧内核/未启用 PSI）→
//! 对应资源 `some`/`full` 为 `null`，绝不 panic。

use serde::Serialize;

use super::util;

/// 单条 PSI 记录（`some` 或 `full`）。`total_us` 单位微秒（内核定义，相对分布有意义）。
#[derive(Debug, Clone, PartialEq, Serialize, Default)]
pub struct PressureLine {
    pub avg10: f64,
    pub avg60: f64,
    pub avg300: f64,
    pub total_us: u64,
}

/// 单个资源的 `some`/`full` 记录（缺失为 `null`）。
#[derive(Debug, Clone, PartialEq, Serialize, Default)]
pub struct PressureResource {
    pub some: Option<PressureLine>,
    pub full: Option<PressureLine>,
}

/// PSI 报告：cpu / memory / io 三资源。
#[derive(Debug, Clone, PartialEq, Serialize, Default)]
pub struct PressureReport {
    pub cpu: PressureResource,
    pub memory: PressureResource,
    pub io: PressureResource,
}

/// 解析一段 PSI 文本（`some`/`full` 行）；未知字段/缺失字段从容处理（缺省 0）。
pub fn parse_pressure(content: &str) -> PressureResource {
    let mut res = PressureResource::default();
    for line in content.lines() {
        let mut it = line.split_whitespace();
        let Some(kind) = it.next() else { continue };
        if kind != "some" && kind != "full" {
            continue;
        }
        let mut avg10 = 0.0;
        let mut avg60 = 0.0;
        let mut avg300 = 0.0;
        let mut total_us = 0u64;
        for token in it {
            let Some((k, v)) = token.split_once('=') else {
                continue;
            };
            match k {
                "avg10" => avg10 = v.parse().unwrap_or(0.0),
                "avg60" => avg60 = v.parse().unwrap_or(0.0),
                "avg300" => avg300 = v.parse().unwrap_or(0.0),
                "total" => total_us = v.parse().unwrap_or(0),
                _ => {}
            }
        }
        let rec = PressureLine {
            avg10,
            avg60,
            avg300,
            total_us,
        };
        if kind == "some" {
            res.some = Some(rec);
        } else {
            res.full = Some(rec);
        }
    }
    res
}

fn collect_resource(path: &str) -> PressureResource {
    util::read_file(path)
        .map(|c| parse_pressure(&c))
        .unwrap_or_default()
}

/// 采集全部 PSI 资源。
pub fn collect() -> PressureReport {
    PressureReport {
        cpu: collect_resource("/proc/pressure/cpu"),
        memory: collect_resource("/proc/pressure/memory"),
        io: collect_resource("/proc/pressure/io"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 真实 `/proc/pressure/cpu` 形态：cpu 通常只有 some。
    const CPU_PRESS: &str = "some avg10=1.20 avg60=0.50 avg300=0.20 total=123456\n";
    // 真实 `/proc/pressure/memory` 形态：some + full。
    const MEM_PRESS: &str = "some avg10=2.00 avg60=1.00 avg300=0.50 total=5000000\n\
        full avg10=1.00 avg60=0.40 avg300=0.10 total=2500000\n";
    // 真实 `/proc/pressure/io` 形态（字段顺序固定）。
    const IO_PRESS: &str = "some avg10=0.05 avg60=0.03 avg300=0.01 total=98765\n\
        full avg10=0.02 avg60=0.01 avg300=0.00 total=43210\n";

    #[test]
    fn parse_cpu_only_some_and_full_is_none() {
        let r = parse_pressure(CPU_PRESS);
        let some = r.some.expect("some record");
        assert!((some.avg10 - 1.20).abs() < 1e-9);
        assert!((some.avg60 - 0.50).abs() < 1e-9);
        assert!((some.avg300 - 0.20).abs() < 1e-9);
        assert_eq!(some.total_us, 123_456);
        assert!(r.full.is_none());
    }

    #[test]
    fn parse_memory_some_and_full() {
        let r = parse_pressure(MEM_PRESS);
        let some = r.some.expect("some");
        let full = r.full.expect("full");
        assert_eq!(some.total_us, 5_000_000);
        assert_eq!(full.total_us, 2_500_000);
        assert!((full.avg60 - 0.40).abs() < 1e-9);
    }

    #[test]
    fn parse_io_some_and_full() {
        let r = parse_pressure(IO_PRESS);
        assert_eq!(r.some.unwrap().total_us, 98_765);
        assert_eq!(r.full.unwrap().total_us, 43_210);
    }

    #[test]
    fn parse_empty_and_garbage_is_all_none() {
        let r = parse_pressure("");
        assert!(r.some.is_none() && r.full.is_none());
        let r = parse_pressure("garbage without kind\nother avg10=x\n");
        assert!(r.some.is_none() && r.full.is_none());
    }

    #[test]
    fn parse_tolerates_missing_fields() {
        let r = parse_pressure("some total=42\n");
        let some = r.some.unwrap();
        assert_eq!(some.total_us, 42);
        assert_eq!(some.avg10, 0.0);
    }

    #[test]
    fn collect_never_panics_and_has_three_resources() {
        // 宿主上 /proc/pressure 可能存在也可能不存在 —— 两者都合法，只要不 panic。
        let r = collect();
        // 三资源字段恒存在（Option 可为 none）。
        let _ = (&r.cpu.some, &r.memory.some, &r.io.some);
        if let Some(content) = util::read_file("/proc/pressure/cpu") {
            assert_eq!(r.cpu, parse_pressure(&content));
        }
    }
}
