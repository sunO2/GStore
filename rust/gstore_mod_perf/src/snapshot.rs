//! 采集编排：把纯采集器 + 实例增量基线组合为 JSON 报告。
//!
//! 每次调用更新实例内的上次样本（CPU/网络/进程），从而在两次调用间计算增量，
//! 无需 `sleep`（修正参考 App 的 UI 线程 sleep）。

use gstore_contract::error::ModuleError;
use serde::Serialize;
use serde_json::Value;

use crate::collectors::sysfs_read as sysfs_reader;
use crate::collectors::{
    battery, battery_health, cooling, cpu, device, gpu, memory, network, pressure, processes,
    sensors, storage, thermal, tunables,
};
use crate::collectors::processes::{ProcQuery, ProcSort};
use crate::state::PerfInstance;

fn to_value<T: Serialize>(v: &T) -> Value {
    serde_json::to_value(v).unwrap_or(Value::Null)
}

/// CPU 报告（更新增量基线）。
pub fn cpu(inst: &PerfInstance) -> Value {
    let cur = cpu::sample();
    let mut prev = inst.cpu_prev.lock().unwrap_or_else(|e| e.into_inner());
    let report = cpu::report(prev.as_ref(), &cur);
    *prev = Some(cur);
    to_value(&report)
}

/// 内存报告。
pub fn memory() -> Value {
    to_value(&memory::collect())
}

/// 电池报告。
pub fn battery() -> Value {
    to_value(&battery::collect())
}

/// 热区报告。
pub fn thermal() -> Value {
    to_value(&thermal::report(thermal::collect()))
}

/// GPU 报告。
pub fn gpu() -> Value {
    to_value(&gpu::collect())
}

/// 网络报告（更新速率基线）。
pub fn network(inst: &PerfInstance) -> Value {
    let cur = network::sample();
    let mut prev = inst.net_prev.lock().unwrap_or_else(|e| e.into_inner());
    let report = network::compute_rates(prev.as_ref(), &cur);
    *prev = Some(cur);
    to_value(&report)
}

/// 进程 Top-N 报告（更新 CPU 增量基线）。
pub fn processes(inst: &PerfInstance, query: ProcQuery) -> Value {
    let snapshot = processes::scan();
    let mut prev = inst.proc_prev.lock().unwrap_or_else(|e| e.into_inner());
    let report = processes::report(prev.as_ref(), &snapshot, query);
    *prev = Some(snapshot.sample);
    to_value(&report)
}

/// 设备身份报告。
pub fn device() -> Value {
    to_value(&device::collect())
}

/// PSI 压力报告（`/proc/pressure/*`）。
pub fn pressure() -> Value {
    to_value(&pressure::collect())
}

/// 散热设备报告（`/sys/class/thermal/cooling_device*`）。
pub fn cooling() -> Value {
    to_value(&cooling::collect())
}

/// 电池健康报告（`/sys/class/power_supply/*`）。
pub fn battery_health() -> Value {
    to_value(&battery_health::collect())
}

/// 存储容量报告（`/proc/mounts` + statvfs）。
pub fn storage() -> Value {
    to_value(&storage::collect())
}

/// 可控面枚举报告（只读；CPU 簇 / cpuset / 热区 / 散热设备 / GPU）。
pub fn tunables() -> Value {
    to_value(&tunables::collect())
}

/// 传感器清单（只读元数据；NDK `ASensorManager`）。
pub fn sensors() -> Value {
    to_value(&sensors::report())
}

/// 白名单 sysfs 单路径读取（`perf.sysfs.read` 编排；非白名单 → 结构化 `invalid_arg`）。
pub fn sysfs_read(path: &str) -> Result<Value, ModuleError> {
    let result = sysfs_reader::collect(path)?;
    Ok(to_value(&result))
}

/// 聚合快照。`include_processes` 控制是否附带进程 Top-N（默认关，成本较高）。
pub fn full(inst: &PerfInstance, include_processes: bool, proc_limit: usize) -> Value {
    let mut map = serde_json::Map::new();
    map.insert("ts_ms".into(), Value::from(crate::collectors::util::now_ms()));
    map.insert("cpu".into(), cpu(inst));
    map.insert("memory".into(), memory());
    map.insert("battery".into(), battery());
    map.insert("battery_health".into(), battery_health());
    map.insert("thermal".into(), thermal());
    map.insert("cooling".into(), cooling());
    map.insert("pressure".into(), pressure());
    map.insert("gpu".into(), gpu());
    map.insert("network".into(), network(inst));
    map.insert("storage".into(), storage());
    map.insert("device".into(), device());
    if include_processes {
        map.insert(
            "processes".into(),
            processes(inst, ProcQuery { limit: proc_limit, sort: ProcSort::Cpu }),
        );
    }
    Value::Object(map)
}

/// 采样器定时快照（不含进程，保持低开销）。
pub fn tick_snapshot(inst: &PerfInstance) -> Value {
    full(inst, false, 0)
}
