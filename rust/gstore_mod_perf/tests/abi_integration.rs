//! 集成测试：经真实 C ABI 导出调用模块（register → create → call → destroy），
//! 覆盖全部方法在真实 `/proc`/`/sys` 环境下的端到端行为。

use std::ffi::{c_void, CStr, CString};

use gstore_contract::abi::{
    GStoreModuleApi, GStoreModuleEntry, ABI_ERR_DETAIL, ABI_OK, GSTORE_MODULE_ABI_VERSION,
};
use gstore_mod_perf::{
    call_export, create_export, destroy_export, free_export, gstore_mod_perf_register,
};

fn call(instance: u64, method: &str, payload: &[u8]) -> (i32, Vec<u8>) {
    let method_c = CString::new(method).unwrap();
    let mut out: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    let rc = call_export(
        instance,
        method_c.as_ptr(),
        payload.as_ptr(),
        payload.len(),
        &mut out,
        &mut len,
    );
    let bytes = if out.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(out, len).to_vec() }
    };
    if !out.is_null() {
        free_export(out as *mut c_void);
    }
    (rc, bytes)
}

#[test]
fn register_reports_perf_and_abi_v3() {
    let entry = GStoreModuleEntry {
        abi_version: GSTORE_MODULE_ABI_VERSION,
        entry_size: std::mem::size_of::<GStoreModuleEntry>() as u32,
        log: None,
        alloc: None,
        free: None,
        emit_event: None,
        context: std::ptr::null_mut(),
        protect_fd: None,
    };
    let mut api = std::mem::MaybeUninit::<GStoreModuleApi>::uninit();
    assert_eq!(gstore_mod_perf_register(&entry, api.as_mut_ptr()), ABI_OK);
    let api = unsafe { api.assume_init() };
    assert_eq!(unsafe { CStr::from_ptr(api.name) }.to_str().unwrap(), "perf");
    assert_eq!(api.min_host_abi, GSTORE_MODULE_ABI_VERSION);
}

#[test]
fn every_method_round_trips_over_the_c_abi() {
    let mut instance: u64 = 0;
    assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);

    let simple = [
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
        "perf.battery_health",
        "perf.storage",
        "perf.tunables",
    ];
    for m in simple {
        let (rc, bytes) = call(instance, m, b"");
        assert_eq!(rc, ABI_OK, "{m} failed with rc={rc}");
        let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v["ok"], true, "{m} did not return ok envelope");
    }

    // 采样生命周期：start → status → history → stop。
    let (rc, _) = call(instance, "perf.start", br#"{"interval_ms":200}"#);
    assert_eq!(rc, ABI_OK);
    let (rc, bytes) = call(instance, "perf.status", b"");
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["data"]["running"], true);

    std::thread::sleep(std::time::Duration::from_millis(250));
    let (rc, bytes) = call(instance, "perf.history", b"");
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert!(v["data"]["count"].as_u64().unwrap() >= 1, "sampler produced no history");

    let (rc, bytes) = call(instance, "perf.stop", b"");
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["data"]["running"], false);

    let (rc, _) = call(instance, "perf.reset", b"");
    assert_eq!(rc, ABI_OK);

    assert_eq!(destroy_export(instance), ABI_OK);
}

#[test]
fn processes_report_contains_rss_and_cpu_fields() {
    let mut instance: u64 = 0;
    assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);
    let (rc, bytes) = call(instance, "perf.processes", br#"{"limit":5,"sort":"rss"}"#);
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let list = v["data"]["processes"].as_array().unwrap();
    assert!(!list.is_empty(), "expected at least one process on Linux");
    assert!(list[0]["pid"].is_i64());
    assert!(list[0]["rss_bytes"].is_u64());
    assert_eq!(v["data"]["sort"], "rss");
    assert_eq!(destroy_export(instance), ABI_OK);
}

#[test]
fn unknown_method_returns_structured_error_payload() {
    let mut instance: u64 = 0;
    assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);
    let (rc, bytes) = call(instance, "perf.does_not_exist", b"");
    assert_eq!(rc, ABI_ERR_DETAIL);
    let err = gstore_contract::error::ModuleError::from_payload(&bytes).unwrap();
    assert_eq!(err.code.as_ref(), gstore_contract::error::ERR_METHOD_NOT_FOUND);
    assert_eq!(destroy_export(instance), ABI_OK);
}

#[test]
fn parse_app_dumps_round_trips_over_the_c_abi() {
    let mut instance: u64 = 0;
    assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);

    let payload = br#"{"package":"com.x","gfxinfo":"Total frames rendered: 42\nJanky frames: 2 (4.76%)\n"}"#;
    let (rc, bytes) = call(instance, "perf.parse_app_dumps", payload);
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["data"]["package"], "com.x");
    assert_eq!(v["data"]["frame_count"], 42);
    assert_eq!(v["data"]["running"], true);

    let (rc, bytes) = call(instance, "perf.parse_app_dumps", br#"{}"#);
    assert_eq!(rc, ABI_ERR_DETAIL);
    let err = gstore_contract::error::ModuleError::from_payload(&bytes).unwrap();
    assert_eq!(err.code.as_ref(), gstore_contract::error::ERR_INVALID_ARGUMENT);

    assert_eq!(destroy_export(instance), ABI_OK);
}

#[test]
fn parse_app_dumps_render_and_power_over_the_c_abi() {
    let mut instance: u64 = 0;
    assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);

    let payload = br#"{"package":"com.x","framestats":"---PROFILEDATA---\nFlags,IntendedVsync,DrawStart,SyncStart,IssueDrawCommandsStart,FrameCompleted\n0,1000000000,1005000000,1007000000,1006000000,1010000000\n---PROFILEDATA---\n","batterystats":"Estimated power use (mAh): 12.3\nWake lock com.x: 1m\n"}"#;
    let (rc, bytes) = call(instance, "perf.parse_app_dumps", payload);
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["data"]["render"]["frame_count"], 1);
    assert_eq!(v["data"]["render"]["avg_gpu_ms"], 3.0);
    assert_eq!(v["data"]["power"]["mah"], 12.3);
    assert_eq!(v["data"]["power"]["wake_lock_ms"], 60_000);

    let (rc, bytes) = call(
        instance,
        "perf.parse_app_dumps",
        br#"{"package":"com.x","framestats":"garbage","batterystats":"garbage"}"#,
    );
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert!(v["data"]["render"].is_null());
    assert!(v["data"]["power"].is_null());

    assert_eq!(destroy_export(instance), ABI_OK);
}

#[test]
fn parse_startup_round_trips_over_the_c_abi() {
    let mut instance: u64 = 0;
    assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);

    let payload = br#"{"output":"Starting: Intent { cmp=com.x/.MainActivity }\nStatus: ok\nActivity: com.x/.MainActivity\nThisTime: 345\nTotalTime: 345\nWaitTime: 400\nLaunchState: COLD\n","mode":"cold"}"#;
    let (rc, bytes) = call(instance, "perf.parse_startup", payload);
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["data"]["status"], "ok");
    assert_eq!(v["data"]["activity"], "com.x/.MainActivity");
    assert_eq!(v["data"]["this_time_ms"], 345);
    assert_eq!(v["data"]["total_time_ms"], 345);
    assert_eq!(v["data"]["wait_time_ms"], 400);
    assert_eq!(v["data"]["mode"], "cold");

    let (rc, bytes) = call(instance, "perf.parse_startup", br#"{"output":"garbage"}"#);
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["data"]["status"], "ok");
    assert!(v["data"]["activity"].is_null());
    assert!(v["data"]["total_time_ms"].is_null());

    assert_eq!(destroy_export(instance), ABI_OK);
}

#[test]
fn parse_app_dumps_deep_dive_over_the_c_abi() {
    let mut instance: u64 = 0;
    assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);

    let payload = br#"{"package":"com.x","package_info":"  Package [com.x] (a1):\n    versionCode=9 minSdk=24 targetSdk=33\n    versionName=9.9\n    flags=[ SYSTEM ]\n","smaps":"Rss: 1000 kB\nPss: 500 kB\n","crash_log":"2024-01-01 12:00:00 data_app_crash (text, 1 bytes)\nProcess: com.x\nException: boom\n","anr_log":"2024-01-02 09:00:00 data_app_anr (text, 1 bytes)\nCmd line: com.x\n","activity":"  mResumedActivity: ActivityRecord{b u0 com.x/.Main t1}\n","batterystats":"Wake lock WifiLock: 1m 23s (5 times)\n"}"#;
    let (rc, bytes) = call(instance, "perf.parse_app_dumps", payload);
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(v["data"]["app_info"]["version_name"], "9.9");
    assert_eq!(v["data"]["app_info"]["is_system"], true);
    assert_eq!(v["data"]["smaps"]["pss_kb"], 500);
    assert_eq!(v["data"]["smaps"]["rss_kb"], 1000);
    assert_eq!(v["data"]["crashes"]["crash_count"], 1);
    assert_eq!(v["data"]["crashes"]["anr_count"], 1);
    assert_eq!(v["data"]["foreground"]["is_foreground"], true);
    assert_eq!(v["data"]["wake_locks"][0]["name"], "WifiLock");
    assert_eq!(v["data"]["wake_locks"][0]["ms"], 83_000);

    let (rc, bytes) = call(
        instance,
        "perf.parse_app_dumps",
        br#"{"package":"com.x","package_info":"garbage","smaps":"garbage","crash_log":"garbage","anr_log":"garbage","activity":"garbage"}"#,
    );
    assert_eq!(rc, ABI_OK);
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert!(v["data"]["app_info"].is_null());
    assert!(v["data"]["smaps"].is_null());
    assert!(v["data"]["crashes"].is_null());
    assert!(v["data"]["foreground"].is_null());
    assert_eq!(v["data"]["wake_locks"].as_array().unwrap().len(), 0);

    assert_eq!(destroy_export(instance), ABI_OK);
}
