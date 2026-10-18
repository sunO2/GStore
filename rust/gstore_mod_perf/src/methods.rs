//! 方法分发表：`ping` 与全部 `perf.*` 方法。
//!
//! 成功一律返回 `{"ok":true,"data":{...}}`；未知方法返回结构化 `METHOD_NOT_FOUND`；绝不 panic。

use gstore_contract::abi::GSTORE_MODULE_ABI_VERSION;
use gstore_contract::error::ModuleError;
use serde_json::Value;

use crate::abi_io::ok_data;
use crate::collectors::app_dumps::{self, AppDumpInput};
use crate::collectors::app_startup;
use crate::collectors::processes::{ProcQuery, ProcSort};
use crate::collectors::util;
use crate::sampler;
use crate::snapshot;
use crate::state::{self, RING_CAP};

/// 全部可分发方法（与 `match` 分支及 README 保持同步）。
#[allow(dead_code)]
pub const DISPATCH_METHODS: &[&str] = &[
    "ping",
    "perf.snapshot",
    "perf.cpu",
    "perf.memory",
    "perf.battery",
    "perf.thermal",
    "perf.gpu",
    "perf.network",
    "perf.processes",
    "perf.device",
    "perf.pressure",
    "perf.cooling",
    "perf.tunables",
    "perf.sysfs.read",
    "perf.battery_health",
    "perf.storage",
    "perf.start",
    "perf.stop",
    "perf.status",
    "perf.history",
    "perf.reset",
    "perf.parse_app_dumps",
    "perf.parse_startup",
];

fn parse_json(payload: &[u8]) -> Option<Value> {
    if payload.is_empty() {
        return None;
    }
    serde_json::from_slice(payload).ok()
}

fn u64_field(v: Option<&Value>, key: &str) -> Option<u64> {
    v.and_then(|v| v.get(key)).and_then(|v| v.as_u64())
}

fn ping(instance_id: u64) -> Result<Vec<u8>, ModuleError> {
    let host_abi = *state::HOST_ABI.get().unwrap_or(&GSTORE_MODULE_ABI_VERSION);
    let mut data = serde_json::json!({
        "pong": true,
        "module": crate::MODULE_NAME,
        "moduleVersion": env!("CARGO_PKG_VERSION"),
        "apiVersion": crate::MODULE_VERSION,
        "minHostAbi": GSTORE_MODULE_ABI_VERSION,
        "hostAbi": host_abi,
        "samplerRunning": sampler::is_running(),
    });
    if let Some(inst) = state::instance_of(instance_id) {
        data["instanceId"] = serde_json::json!(inst.id);
        data["sampleCount"] = serde_json::json!(inst.sample_count());
    }
    ok_data(data)
}

fn start(inst: std::sync::Arc<state::PerfInstance>, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let v = parse_json(payload);
    let interval = match v.as_ref().and_then(|v| v.get("interval_ms")) {
        None => sampler::DEFAULT_INTERVAL_MS,
        Some(_) => u64_field(v.as_ref(), "interval_ms")
            .ok_or_else(|| ModuleError::invalid_arg("interval_ms must be a positive integer"))?,
    };
    let interval = sampler::normalize_interval(interval);
    let instance_id = inst.id;
    let running = sampler::start(inst, interval);
    ok_data(serde_json::json!({
        "running": running,
        "interval_ms": interval,
        "instanceId": instance_id,
    }))
}

fn status() -> Result<Vec<u8>, ModuleError> {
    let (running, interval, instance_id) = match sampler::status() {
        Some((id, interval)) => (sampler::is_running(), Some(interval), Some(id)),
        None => (false, None, None),
    };
    ok_data(serde_json::json!({
        "running": running,
        "interval_ms": interval,
        "instanceId": instance_id,
        "running_count": sampler::running_count(),
    }))
}

fn processes(inst: &state::PerfInstance, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let v = parse_json(payload);
    let sort = match v.as_ref().and_then(|v| v.get("sort")).and_then(|v| v.as_str()) {
        None | Some("cpu") => ProcSort::Cpu,
        Some("rss") => ProcSort::Rss,
        Some(other) => {
            return Err(ModuleError::invalid_arg(format!(
                "sort must be \"cpu\" or \"rss\", got {other}"
            )))
        }
    };
    let limit = u64_field(v.as_ref(), "limit").unwrap_or(10).clamp(1, 100) as usize;
    ok_data(snapshot::processes(inst, ProcQuery { limit, sort }))
}

fn snapshot_method(inst: &state::PerfInstance, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let v = parse_json(payload);
    let include_processes = v
        .as_ref()
        .and_then(|v| v.get("include_processes"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    if include_processes {
        let v_ref = v.as_ref();
        if let Some(field) = v_ref.and_then(|v| v.get("process_limit")) {
            if field.as_u64().is_none() {
                return Err(ModuleError::invalid_arg("process_limit must be an integer"));
            }
        }
    }
    let proc_limit = u64_field(v.as_ref(), "process_limit").unwrap_or(10).clamp(1, 100) as usize;
    ok_data(snapshot::full(inst, include_processes, proc_limit))
}

fn parse_app_dumps(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let v = parse_json(payload);
    let package = v
        .as_ref()
        .and_then(|v| v.get("package"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim();
    if package.is_empty() {
        return Err(ModuleError::invalid_arg(
            "package is required and must be a non-empty string",
        ));
    }
    let pid = match v.as_ref().and_then(|v| v.get("pid")) {
        None | Some(Value::Null) => None,
        Some(x) => Some(
            x.as_i64()
                .ok_or_else(|| ModuleError::invalid_arg("pid must be an integer"))?,
        ),
    };
    let uid = match v.as_ref().and_then(|v| v.get("uid")) {
        None | Some(Value::Null) => None,
        Some(x) => Some(
            x.as_i64()
                .ok_or_else(|| ModuleError::invalid_arg("uid must be an integer"))?,
        ),
    };
    let text = |key: &str| {
        v.as_ref()
            .and_then(|v| v.get(key))
            .and_then(|v| v.as_str())
    };
    let input = AppDumpInput {
        package,
        pid,
        uid,
        cpuinfo: text("cpuinfo"),
        meminfo: text("meminfo"),
        gfxinfo: text("gfxinfo"),
        ps: text("ps"),
        status: text("status"),
        netstats: text("netstats"),
        framestats: text("framestats"),
        batterystats: text("batterystats"),
        package_info: text("package_info"),
        smaps: text("smaps"),
        crash_log: text("crash_log"),
        anr_log: text("anr_log"),
        activity: text("activity"),
    };
    let report = app_dumps::parse(&input);
    let data =
        serde_json::to_value(&report).map_err(|e| ModuleError::internal(e.to_string()))?;
    ok_data(data)
}

/// `perf.parse_startup`：解析 `am start -W` 的 stdout（纯解析，`output`/`mode` 均可缺省）。
fn parse_startup(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let v = parse_json(payload);
    let output = v
        .as_ref()
        .and_then(|v| v.get("output"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let mode = v
        .as_ref()
        .and_then(|v| v.get("mode"))
        .and_then(|v| v.as_str());
    let report = app_startup::parse_startup(output, mode);
    let data =
        serde_json::to_value(&report).map_err(|e| ModuleError::internal(e.to_string()))?;
    ok_data(data)
}

/// `perf.sysfs.read`：只读白名单内的**单个** sysfs / cpuset 节点（写回校验用）。
///
/// 请求 `{path: string}`。仅当 `path` 命中 `collectors::sysfs_read::SYSFS_ALLOWLIST`
/// 时读取，返回 `{path, value, exists}`；非白名单路径（`/etc/passwd`、`/data/...`、
/// 穿越路径）返回结构化 `invalid_arg`，**绝不返回值**。
///
/// **uid 上下文提醒**：本方法以**模块进程（App）自身 uid** 读取。Wave 4 的写操作
/// 经 Shizuku 特权 shell（uid 2000）执行；对**非 world-readable** 的节点，App uid
/// 可能读不到（`exists:false` / `value:null`，这不是错误）——此时应**同样经特权
/// shell 回读**，且读取侧 uid / 上下文必须与写入侧一致，否则写回校验无意义。
fn sysfs_read(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let v = parse_json(payload);
    let path = v
        .as_ref()
        .and_then(|v| v.get("path"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim();
    if path.is_empty() {
        return Err(ModuleError::invalid_arg(
            "path is required and must be a non-empty string",
        ));
    }
    ok_data(snapshot::sysfs_read(path)?)
}

/// 分发一次调用。
pub fn dispatch(instance_id: u64, method: &str, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    match method {
        "ping" => ping(instance_id),
        "perf.snapshot" => {
            let inst = state::require_instance(instance_id)?;
            snapshot_method(&inst, payload)
        }
        "perf.cpu" => {
            let inst = state::require_instance(instance_id)?;
            ok_data(snapshot::cpu(&inst))
        }
        "perf.memory" => {
            state::require_instance(instance_id)?;
            ok_data(snapshot::memory())
        }
        "perf.battery" => {
            state::require_instance(instance_id)?;
            ok_data(snapshot::battery())
        }
        "perf.thermal" => {
            state::require_instance(instance_id)?;
            ok_data(snapshot::thermal())
        }
        "perf.gpu" => {
            state::require_instance(instance_id)?;
            ok_data(snapshot::gpu())
        }
        "perf.network" => {
            let inst = state::require_instance(instance_id)?;
            ok_data(snapshot::network(&inst))
        }
        "perf.processes" => {
            let inst = state::require_instance(instance_id)?;
            processes(&inst, payload)
        }
        "perf.device" => {
            state::require_instance(instance_id)?;
            ok_data(snapshot::device())
        }
        "perf.pressure" => {
            state::require_instance(instance_id)?;
            ok_data(snapshot::pressure())
        }
        "perf.cooling" => {
            state::require_instance(instance_id)?;
            ok_data(snapshot::cooling())
        }
        "perf.tunables" => {
            state::require_instance(instance_id)?;
            ok_data(snapshot::tunables())
        }
        "perf.sysfs.read" => {
            state::require_instance(instance_id)?;
            sysfs_read(payload)
        }
        "perf.battery_health" => {
            state::require_instance(instance_id)?;
            ok_data(snapshot::battery_health())
        }
        "perf.storage" => {
            state::require_instance(instance_id)?;
            ok_data(snapshot::storage())
        }
        "perf.start" => {
            let inst = state::require_instance(instance_id)?;
            start(inst, payload)
        }
        "perf.stop" => {
            state::require_instance(instance_id)?;
            ok_data(serde_json::json!({ "running": false, "was_running": sampler::stop() }))
        }
        "perf.status" => {
            state::require_instance(instance_id)?;
            status()
        }
        "perf.history" => {
            let inst = state::require_instance(instance_id)?;
            let v = parse_json(payload);
            let limit = u64_field(v.as_ref(), "limit")
                .unwrap_or(0)
                .min(RING_CAP as u64) as usize;
            let samples = inst.history(limit);
            ok_data(serde_json::json!({
                "count": samples.len(),
                "capacity": RING_CAP,
                "samples": samples,
            }))
        }
        "perf.reset" => {
            let inst = state::require_instance(instance_id)?;
            inst.reset();
            ok_data(serde_json::json!({ "ok": true, "ts_ms": util::now_ms() }))
        }
        "perf.parse_app_dumps" => {
            state::require_instance(instance_id)?;
            parse_app_dumps(payload)
        }
        "perf.parse_startup" => {
            state::require_instance(instance_id)?;
            parse_startup(payload)
        }
        other => Err(ModuleError::method_not_found(other)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gstore_contract::error::ERR_METHOD_NOT_FOUND;

    #[test]
    fn every_documented_method_is_dispatchable() {
        for m in DISPATCH_METHODS {
            let err = dispatch(u64::MAX, m, b"").err();
            if let Some(e) = err {
                assert_ne!(
                    e.code.as_ref(),
                    ERR_METHOD_NOT_FOUND,
                    "method {m} is documented but not dispatched"
                );
            }
        }
    }

    #[test]
    fn unknown_method_is_method_not_found() {
        let err = dispatch(u64::MAX, "perf.nope", b"").unwrap_err();
        assert_eq!(err.code.as_ref(), ERR_METHOD_NOT_FOUND);
    }

    #[test]
    fn ping_without_instance_still_responds() {
        let bytes = dispatch(u64::MAX, "ping", b"").unwrap();
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["pong"], true);
        assert_eq!(v["data"]["module"], "perf");
    }

    #[test]
    fn missing_instance_is_structured_error() {
        let err = dispatch(424242, "perf.snapshot", b"").unwrap_err();
        assert_eq!(err.status, gstore_contract::error::StatusCode::InstanceNotFound);
    }

    #[test]
    fn invalid_process_sort_is_rejected() {
        let inst = state::PerfInstance::new(1, &gstore_contract::context::ModuleContext::default());
        let err = dispatch_inner(&inst, "perf.processes", br#"{"sort":"bogus"}"#).unwrap_err();
        assert_eq!(err.status, gstore_contract::error::StatusCode::InvalidArgument);
    }

    #[test]
    fn parse_app_dumps_requires_package() {
        let err = parse_app_dumps(br#"{"pid":123}"#).unwrap_err();
        assert_eq!(err.status, gstore_contract::error::StatusCode::InvalidArgument);
        let err = parse_app_dumps(b"not json").unwrap_err();
        assert_eq!(err.status, gstore_contract::error::StatusCode::InvalidArgument);
    }

    #[test]
    fn parse_app_dumps_rejects_non_integer_pid() {
        let err = parse_app_dumps(br#"{"package":"com.x","pid":1.5}"#).unwrap_err();
        assert_eq!(err.status, gstore_contract::error::StatusCode::InvalidArgument);
    }

    #[test]
    fn parse_app_dumps_rejects_non_integer_uid() {
        let err = parse_app_dumps(br#"{"package":"com.x","uid":"10123"}"#).unwrap_err();
        assert_eq!(err.status, gstore_contract::error::StatusCode::InvalidArgument);
    }

    #[test]
    fn parse_app_dumps_surfaces_new_dump_fields() {
        let payload = br#"{"package":"com.x","uid":10123,"ps":"USER PID PPID VSZ RSS WCHAN ADDR S NAME\nua 1234 900 3000000 98765 0 0 S com.x\n","status":"Threads:\t42\nUid:\t10123\t10123\t10123\t10123\n","netstats":"uid=10123 rb=100 tb=200\n"}"#;
        let bytes = parse_app_dumps(payload).unwrap();
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["data"]["uid"], 10123);
        assert_eq!(v["data"]["threads"], 42);
        assert_eq!(v["data"]["processes"][0]["pid"], 1234);
        assert_eq!(v["data"]["processes"][0]["rss_kb"], 98765);
        assert_eq!(v["data"]["processes"][0]["name"], "com.x");
        assert_eq!(v["data"]["net"]["rx_bytes"], 100);
        assert_eq!(v["data"]["net"]["tx_bytes"], 200);
        assert!(v["data"]["mem_summary"]["total_pss_kb"].is_null());
    }

    #[test]
    fn parse_app_dumps_surfaces_render_and_power() {
        let payload = br#"{"package":"com.x","uid":100123,"framestats":"---PROFILEDATA---\nFlags,IntendedVsync,DrawStart,SyncStart,IssueDrawCommandsStart,FrameCompleted\n0,1000000000,1005000000,1007000000,1006000000,1010000000\n---PROFILEDATA---\n","batterystats":"Estimated power use (mAh): 12.3\nUid u0a123: 9.9\n"}"#;
        let bytes = parse_app_dumps(payload).unwrap();
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["data"]["render"]["frame_count"], 1);
        assert_eq!(v["data"]["render"]["avg_total_ms"], 10.0);
        assert_eq!(v["data"]["render"]["avg_ui_ms"], 5.0);
        assert_eq!(v["data"]["power"]["mah"], 12.3);
        assert!(v["data"]["power"]["screen_mah"].is_null());
    }

    #[test]
    fn parse_app_dumps_surfaces_deep_dive_fields() {
        let payload = br#"{"package":"com.x","package_info":"  Package [com.x] (a1):\n    versionCode=9 minSdk=24 targetSdk=33\n    versionName=9.9\n","smaps":"Rss: 1000 kB\nPss: 500 kB\n","crash_log":"2024-01-01 12:00:00 data_app_crash (text, 1 bytes)\nProcess: com.x\nException: boom\n","anr_log":"2024-01-02 09:00:00 data_app_anr (text, 1 bytes)\nCmd line: com.x\n","activity":"  mResumedActivity: ActivityRecord{b u0 com.x/.Main t1}\n","batterystats":"Wake lock WifiLock: 1m 23s (5 times)\n"}"#;
        let bytes = parse_app_dumps(payload).unwrap();
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["data"]["app_info"]["version_name"], "9.9");
        assert_eq!(v["data"]["smaps"]["pss_kb"], 500);
        assert_eq!(v["data"]["crashes"]["crash_count"], 1);
        assert_eq!(v["data"]["crashes"]["anr_count"], 1);
        assert_eq!(v["data"]["foreground"]["is_foreground"], true);
        assert_eq!(v["data"]["wake_locks"][0]["name"], "WifiLock");
        assert_eq!(v["data"]["wake_locks"][0]["ms"], 83_000);
    }

    #[test]
    fn parse_app_dumps_returns_ok_envelope() {
        let payload = br#"{"package":"com.x","gfxinfo":"Total frames rendered: 10\nJanky frames: 1 (10.00%)\n"}"#;
        let bytes = parse_app_dumps(payload).unwrap();
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["package"], "com.x");
        assert_eq!(v["data"]["running"], true);
        assert_eq!(v["data"]["frame_count"], 10);
        assert_eq!(v["data"]["janky_frames"], 1);
        assert!(v["data"]["mem_pss_kb"].is_null());
        assert!(v["data"]["pid"].is_null());
    }

    #[test]
    fn parse_app_dumps_missing_texts_is_not_running() {
        let bytes = parse_app_dumps(br#"{"package":"com.x"}"#).unwrap();
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["running"], false);
        assert!(v["data"]["cpu_percent"].is_null());
        assert!(v["data"]["frame_count"].is_null());
    }

    #[test]
    fn parse_startup_returns_ok_envelope() {
        let payload = br#"{"output":"Starting: Intent { cmp=com.x/.MainActivity }\nStatus: ok\nActivity: com.x/.MainActivity\nThisTime: 345\nTotalTime: 345\nWaitTime: 400\nLaunchState: COLD\n","mode":"cold"}"#;
        let bytes = parse_startup(payload).unwrap();
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["status"], "ok");
        assert_eq!(v["data"]["activity"], "com.x/.MainActivity");
        assert_eq!(v["data"]["this_time_ms"], 345);
        assert_eq!(v["data"]["total_time_ms"], 345);
        assert_eq!(v["data"]["wait_time_ms"], 400);
        assert_eq!(v["data"]["mode"], "cold");
    }

    #[test]
    fn parse_startup_tolerates_empty_and_partial_payload() {
        let empty = parse_startup(b"").unwrap();
        let v: Value = serde_json::from_slice(&empty).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["status"], "ok");
        assert!(v["data"]["activity"].is_null());
        assert!(v["data"]["total_time_ms"].is_null());
        assert_eq!(v["data"]["mode"], "warm");

        let partial = parse_startup(br#"{"output":"TotalTime: 250 ms\n"}"#).unwrap();
        let v: Value = serde_json::from_slice(&partial).unwrap();
        assert_eq!(v["data"]["status"], "ok");
        assert_eq!(v["data"]["total_time_ms"], 250);
        assert!(v["data"]["this_time_ms"].is_null());
    }

    #[test]
    fn parse_startup_error_output_sets_error_status() {
        let bytes = parse_startup(br#"{"output":"Error: Activity not started\n","mode":"cold"}"#)
            .unwrap();
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["status"], "Error");
        assert_eq!(v["data"]["mode"], "cold");
        assert!(v["data"]["activity"].is_null());
    }

    #[test]
    fn parse_startup_requires_instance() {
        let err = dispatch(424242, "perf.parse_startup", b"").unwrap_err();
        assert_eq!(err.status, gstore_contract::error::StatusCode::InstanceNotFound);
    }

    #[test]
    fn sysfs_read_rejects_non_allowlisted_path_never_value() {
        for payload in [
            &br#"{"path":"/etc/passwd"}"#[..],
            &br#"{"path":"/data/data/com.x/secret"}"#[..],
            &br#"{"path":"/proc/self/environ"}"#[..],
        ] {
            let err = sysfs_read(payload).unwrap_err();
            assert_eq!(
                err.status,
                gstore_contract::error::StatusCode::InvalidArgument
            );
        }
    }

    #[test]
    fn sysfs_read_requires_non_empty_path() {
        for payload in [
            &b"{}"[..],
            &br#"{"path":""}"#[..],
            &br#"{"path":123}"#[..],
            &b""[..],
        ] {
            let err = sysfs_read(payload).unwrap_err();
            assert_eq!(
                err.status,
                gstore_contract::error::StatusCode::InvalidArgument
            );
        }
    }

    #[test]
    fn sysfs_read_returns_ok_envelope_for_allowlisted_path() {
        let bytes =
            sysfs_read(br#"{"path":"/sys/class/thermal/thermal_zone0/temp"}"#).unwrap();
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["path"], "/sys/class/thermal/thermal_zone0/temp");
        assert!(v["data"]["exists"].is_boolean());
    }

    #[test]
    fn sysfs_read_requires_instance_via_dispatch() {
        let err = dispatch(u64::MAX, "perf.sysfs.read", br#"{"path":"/etc/passwd"}"#)
            .unwrap_err();
        assert_eq!(
            err.status,
            gstore_contract::error::StatusCode::InstanceNotFound
        );
    }

    #[test]
    fn device_deep_dive_reports_have_expected_shape() {
        let p = snapshot::pressure();
        assert!(p.get("cpu").is_some());
        assert!(p.get("memory").is_some());
        assert!(p.get("io").is_some());

        let c = snapshot::cooling();
        assert!(c.get("count").is_some());
        assert!(c["devices"].is_array());

        let b = snapshot::battery_health();
        assert!(b.get("present").is_some());
        assert!(b.get("charge_full_uah").is_some());
        assert!(b.get("charge_counter_uah").is_some());

        let s = snapshot::storage();
        assert!(s["volumes"].is_array());
    }

    #[test]
    fn cpu_report_includes_governors_and_freq_residency() {
        let inst = state::PerfInstance::new(1, &gstore_contract::context::ModuleContext::default());
        let report = snapshot::cpu(&inst);
        assert!(report["available_governors"].is_array());
        assert!(report["freq_residency"].is_array());
    }

    fn dispatch_inner(
        inst: &state::PerfInstance,
        method: &str,
        payload: &[u8],
    ) -> Result<Vec<u8>, ModuleError> {
        match method {
            "perf.processes" => processes(inst, payload),
            _ => Err(ModuleError::method_not_found(method)),
        }
    }
}
