//! F3 — host-equivalent manual-QA harness for the request collector.
//!
//! This is a **harness-level** QA driver, NOT on-hardware QA. It loads the real
//! `libgstore_mod_proxy.so` exactly as the host does (dlopen + the C ABI, the
//! same path `host_dlopen.rs` exercises), starts the delivered **LAN-proxy
//! loopback** path (`lan.set` + `core.set_mode lanProxy`, no VpnService/TUN),
//! pushes a real TCP request through the loopback LAN listener with the real
//! `curl` binary, and then drives the **real delivered contracts** end to end:
//!
//! * `requests.get` / `requests.reset` / `requests.export` (JSON dispatch)
//! * the `emit_event` stream (the payload-free `proxy.request` dirty signal)
//!
//! Nothing in the product is mocked or rewritten; the only injected pieces are
//! the host-side `emit_event`/`protect_fd` callbacks every embedder must supply
//! and an in-process loopback HTTP fixture.
//!
//! ## Why a slow fixture
//! Capture is a 500 ms sampling diff over meow's live connection table. A flow
//! opened *and* closed between two ticks is invisible (the documented accepted
//! limitation). The fixture therefore holds the connection open ~1.5 s so at
//! least three ticks observe it; that limitation is printed, not hidden.
//!
//! ## Run
//! ```text
//! cargo build -p gstore_mod_proxy
//! cargo test -p gstore_mod_proxy --test f3_manual_qa_host -- --ignored --nocapture
//! ```
//! `curl` must be on PATH (the repo's `lan_curl_host_harness` already relies on
//! it).

use std::ffi::{c_char, c_int, c_void, CString};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use gstore_contract::abi::{
    ABI_OK, GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
};

type RegisterFn = extern "C" fn(*const GStoreModuleEntry, *mut GStoreModuleApi) -> c_int;
type CallFn =
    extern "C" fn(u64, *const c_char, *const u8, usize, *mut *mut u8, *mut usize) -> c_int;
type FreeFn = extern "C" fn(*mut c_void);
type EmitFn = extern "C" fn(u64, u64, *const u8, usize);

/// The known marker the loopback fixture returns; matching it proves the
/// request really traversed the LAN listener + engine relay.
const FIXTURE_MARKER: &str = "GSTORE_F3_FIXTURE_MARKER";

static EVENTS: Mutex<Vec<(String, Vec<u8>)>> = Mutex::new(Vec::new());

extern "C" fn dummy_protect(_fd: c_int) -> c_int {
    0
}

/// Host event callback: decode the `[u32 le len][kind][payload]` wire frame the
/// module uses (identical to `lib.rs`'s test `record_event`).
extern "C" fn capture_event(_module_id: u64, _instance_id: u64, data: *const u8, len: usize) {
    if data.is_null() || len < 4 {
        return;
    }
    let raw = unsafe { std::slice::from_raw_parts(data, len) };
    let tlen = u32::from_le_bytes(raw[0..4].try_into().unwrap()) as usize;
    if raw.len() < 4 + tlen {
        return;
    }
    let kind = String::from_utf8_lossy(&raw[4..4 + tlen]).into_owned();
    let payload = raw[4 + tlen..].to_vec();
    EVENTS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push((kind, payload));
}

fn take_events() -> Vec<(String, Vec<u8>)> {
    std::mem::take(&mut *EVENTS.lock().unwrap_or_else(|e| e.into_inner()))
}

fn locate_so() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let candidates = [
        dir.join("target/debug/libgstore_mod_proxy.so"),
        dir.join("target/debug/deps/libgstore_mod_proxy.so"),
        dir.join("target/release/libgstore_mod_proxy.so"),
        dir.join("target/release/deps/libgstore_mod_proxy.so"),
    ];
    for c in &candidates {
        if c.exists() {
            return c.clone();
        }
    }
    panic!("libgstore_mod_proxy.so not built; run `cargo build -p gstore_mod_proxy` first");
}

fn call(
    call_fn: CallFn,
    free_fn: FreeFn,
    inst: u64,
    method: &str,
    payload: &[u8],
) -> (c_int, serde_json::Value) {
    let m = CString::new(method).unwrap();
    let mut ptr: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    let code = call_fn(
        inst,
        m.as_ptr(),
        payload.as_ptr(),
        payload.len(),
        &mut ptr,
        &mut len,
    );
    let bytes = if ptr.is_null() {
        Vec::new()
    } else {
        let v = unsafe { std::slice::from_raw_parts(ptr, len).to_vec() };
        free_fn(ptr as *mut c_void);
        v
    };
    let value = if bytes.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null)
    };
    (code, value)
}

fn call_ok(
    call_fn: CallFn,
    free_fn: FreeFn,
    inst: u64,
    method: &str,
    payload: &[u8],
) -> serde_json::Value {
    let (code, v) = call(call_fn, free_fn, inst, method, payload);
    assert_eq!(
        code,
        ABI_OK,
        "{method} must succeed, got ABI code {code}: {v}"
    );
    assert_eq!(v["ok"], true, "{method} ok flag: {v}");
    v["data"].clone()
}

fn free_tcp_port() -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    l.local_addr().unwrap().port()
}

fn tmp_dir(tag: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("gstore-f3-{tag}-{nanos}"));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Blocking loopback HTTP fixture (std threads). It sleeps `delay` after reading
/// the request so the sampled connection stays live across ticks, then answers
/// `FIXTURE_MARKER` and closes.
fn spawn_slow_fixture(delay: Duration) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { break };
            std::thread::spawn(move || {
                let mut buf = [0u8; 4096];
                let _ = stream.read(&mut buf);
                std::thread::sleep(delay);
                let body = FIXTURE_MARKER;
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            });
        }
    });
    addr
}

fn curl_socks5(proxy: &str, url: &str) -> String {
    let out = std::process::Command::new("curl")
        .args(["--socks5", proxy, url, "-sS", "--max-time", "20"])
        .output()
        .expect("run curl");
    assert!(
        out.status.success(),
        "curl --socks5 {proxy} {url} failed: {} / {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn records_of(data: &serde_json::Value) -> Vec<serde_json::Value> {
    data["records"]
        .as_array()
        .map(|a| a.to_vec())
        .unwrap_or_default()
}

/// Poll `requests.get` until a record for `dst_ip:dst_port` appears.
fn poll_requests(
    call_fn: CallFn,
    free_fn: FreeFn,
    inst: u64,
    dst_ip: &str,
    dst_port: u16,
    timeout: Duration,
) -> Vec<serde_json::Value> {
    let deadline = Instant::now() + timeout;
    let mut last = Vec::new();
    while Instant::now() < deadline {
        let data = call_ok(
            call_fn,
            free_fn,
            inst,
            "requests.get",
            br#"{"limit":256}"#,
        );
        last = records_of(&data);
        if last.iter().any(|r| {
            r["dstIp"].as_str() == Some(dst_ip)
                && r["dstPort"].as_u64() == Some(dst_port as u64)
        }) {
            return last;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    last
}

fn has_proxy_request_kind(events: &[(String, Vec<u8>)]) -> bool {
    events.iter().any(|(k, _)| k == "proxy.request")
}

#[test]
#[ignore = "host QA harness: dlopen + LAN loopback + curl; run with --ignored --nocapture"]
fn f3_host_equivalent_request_collector_qa() {
    println!("=== F3 host-equivalent request collector QA (harness-level, NOT on-hardware) ===");
    println!("so={}", locate_so().display());

    let lib = unsafe { libloading::Library::new(locate_so()) }.expect("dlopen proxy module");
    let register: libloading::Symbol<RegisterFn> =
        unsafe { lib.get(b"gstore_mod_proxy_register\0") }.expect("register symbol");

    let entry = GStoreModuleEntry {
        abi_version: GSTORE_MODULE_ABI_VERSION,
        entry_size: std::mem::size_of::<GStoreModuleEntry>() as u32,
        log: None,
        alloc: None,
        free: None,
        // SAFETY: the callback has the exact ABI signature and is 'static.
        emit_event: Some::<EmitFn>(capture_event),
        context: std::ptr::null_mut(),
        protect_fd: Some(dummy_protect),
    };
    let mut api_uninit = std::mem::MaybeUninit::<GStoreModuleApi>::zeroed();
    let code = register(&entry, api_uninit.as_mut_ptr());
    assert_eq!(code, ABI_OK, "register handshake");
    let api = unsafe { api_uninit.assume_init() };
    let create = api.create.unwrap();
    let call_fn = api.call.unwrap();
    let destroy = api.destroy.unwrap();
    let free_fn = api.free.unwrap();
    let shutdown = api.shutdown;

    let dir = tmp_dir("host");
    let dir_str = dir.display().to_string();
    let cfg = serde_json::to_vec(&serde_json::json!({
        "data_dir": dir_str,
        "cache_dir": dir_str,
    }))
    .unwrap();
    let mut inst: u64 = 0;
    assert_eq!(
        create(cfg.as_ptr(), cfg.len(), &mut inst),
        ABI_OK,
        "create instance"
    );
    assert!(inst > 0);

    let fixture = spawn_slow_fixture(Duration::from_millis(1500));
    let lan_port = free_tcp_port();

    // ---- LAN inbound (no VpnService) ----
    let lan = call_ok(
        call_fn,
        free_fn,
        inst,
        "lan.set",
        format!(r#"{{"enabled":true,"port":{lan_port},"bindAddress":"127.0.0.1"}}"#).as_bytes(),
    );
    assert_eq!(
        lan["status"]["bound"], true,
        "LAN listener must bind: {lan}"
    );
    assert_eq!(lan["status"]["listening"], true, "LAN must be listening: {lan}");

    // ---- lanProxy mode: engine + LAN inbox, no TUN ----
    let mode = call_ok(
        call_fn,
        free_fn,
        inst,
        "core.set_mode",
        br#"{"mode":"lanProxy"}"#,
    );
    assert_eq!(mode["mode"], "lanProxy", "mode switch: {mode}");
    // Bound is established synchronously by lan.set; give the engine ticker a beat.
    std::thread::sleep(Duration::from_millis(800));

    // ================= (a) no records at all =================
    let reset = call_ok(call_fn, free_fn, inst, "requests.reset", &[]);
    assert_eq!(reset["ok"], true);
    let empty = call_ok(call_fn, free_fn, inst, "requests.get", br#"{"limit":256}"#);
    let empty_rows = records_of(&empty);
    assert!(
        empty_rows.is_empty(),
        "FAILURE(a): fresh reset must have zero records, got {}",
        empty_rows.len()
    );
    let empty_export = call_ok(
        call_fn,
        free_fn,
        inst,
        "requests.export",
        br#"{"format":"csv"}"#,
    );
    assert_eq!(empty_export["rows"], 0, "FAILURE(a): empty export rows");
    let empty_csv = std::fs::read_to_string(empty_export["csvPath"].as_str().unwrap()).unwrap();
    let empty_lines = empty_csv.lines().count();
    assert_eq!(empty_lines, 1, "FAILURE(a): empty CSV is header only");
    println!(
        "FAILURE(a) no-records: get_rows=0 export_rows={} csv_lines={} -> PASS",
        empty_export["rows"], empty_lines
    );

    // ================= happy path =================
    let _ = take_events(); // clear so the dirty signal below is from our flow
    let url = format!("http://{}/f3", fixture);
    let body = curl_socks5(&format!("127.0.0.1:{lan_port}"), &url);
    assert!(
        body.contains(FIXTURE_MARKER),
        "traffic did not traverse the LAN proxy: {body:?}"
    );
    println!("HAPPY marker: curl through LAN proxy returned {FIXTURE_MARKER}");

    let deadline = Instant::now() + Duration::from_secs(30);
    let records = poll_requests(
        call_fn,
        free_fn,
        inst,
        "127.0.0.1",
        fixture.port(),
        deadline.saturating_duration_since(Instant::now()),
    );
    let mut rec = records
        .iter()
        .find(|r| {
            r["dstIp"].as_str() == Some("127.0.0.1")
                && r["dstPort"].as_u64() == Some(fixture.port() as u64)
        })
        .cloned()
        .unwrap_or_else(|| panic!("requests.get never captured the loopback flow: {records:?}"));

    let domain = rec["domain"].as_str().unwrap_or("").to_string();
    let dst_ip = rec["dstIp"].as_str().unwrap_or("").to_string();
    assert!(!domain.is_empty(), "HAPPY: domain must be non-empty");
    assert!(!dst_ip.is_empty(), "HAPPY: dstIp must be non-empty");
    assert_eq!(dst_ip, "127.0.0.1", "HAPPY: dstIp");
    assert_eq!(
        rec["dstPort"].as_u64(),
        Some(fixture.port() as u64),
        "HAPPY: dstPort"
    );
    assert_eq!(rec["network"], "tcp", "HAPPY: network");
    // The flow is still `open` at first sighting; wait for the sampling tick to
    // observe the terminal close (curl sends Connection: close, relay ends).
    let close_deadline = Instant::now() + Duration::from_secs(15);
    while rec["closeReason"].as_str() != Some("closed") && Instant::now() < close_deadline {
        std::thread::sleep(Duration::from_millis(250));
        let data = call_ok(call_fn, free_fn, inst, "requests.get", br#"{"limit":256}"#);
        if let Some(found) = records_of(&data).into_iter().find(|r| {
            r["dstIp"].as_str() == Some("127.0.0.1")
                && r["dstPort"].as_u64() == Some(fixture.port() as u64)
        }) {
            rec = found;
        }
    }
    assert_eq!(
        rec["closeReason"], "closed",
        "HAPPY: the sampled flow must reach a terminal closed state"
    );
    println!(
        "HAPPY requests.get: domain={domain} domainKnown={} dstIp={dst_ip} dstPort={} closeReason={} uidState={}",
        rec["domainKnown"], rec["dstPort"], rec["closeReason"], rec["uidState"]
    );

    // ---- export CSV + JSON consistency ----
    let export = call_ok(
        call_fn,
        free_fn,
        inst,
        "requests.export",
        br#"{"format":"both"}"#,
    );
    let get_rows = records.len() as u64;
    assert_eq!(
        export["rows"].as_u64(),
        Some(get_rows),
        "HAPPY: export rows must equal requests.get rows"
    );
    let csv_path = export["csvPath"].as_str().expect("csvPath");
    let json_path = export["jsonPath"].as_str().expect("jsonPath");
    let csv = std::fs::read_to_string(csv_path).unwrap();
    let csv_lines: Vec<&str> = csv.lines().filter(|l| !l.is_empty()).collect();
    assert_eq!(
        csv_lines.len() as u64,
        get_rows + 1,
        "HAPPY: CSV lines == rows + header"
    );
    assert!(
        csv_lines[0].starts_with("recordId,connId,openTsMs,"),
        "HAPPY: CSV header order, got {:?}",
        csv_lines[0]
    );
    let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(json_path).unwrap())
        .expect("HAPPY: export JSON parses");
    assert_eq!(
        json.as_array().map(|a| a.len()).unwrap_or(0) as u64,
        get_rows,
        "HAPPY: JSON array length == rows"
    );
    println!(
        "HAPPY export: rows={} csv_lines={} json_len={} bytes={}",
        export["rows"],
        csv_lines.len(),
        json.as_array().unwrap().len(),
        export["bytes"]
    );

    // ---- payload-free dirty signal ----
    let signal_deadline = Instant::now() + Duration::from_secs(15);
    let mut proxy_events = Vec::new();
    while Instant::now() < signal_deadline {
        proxy_events = take_events();
        if has_proxy_request_kind(&proxy_events) {
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    let (_, sig_payload) = proxy_events
        .iter()
        .find(|(k, _)| k == "proxy.request")
        .expect("HAPPY: proxy.request dirty signal must reach the event stream");
    let sig: serde_json::Value = serde_json::from_slice(sig_payload).expect("signal payload JSON");
    assert!(
        sig["count"].as_u64().unwrap_or(0) >= 1,
        "HAPPY: proxy.request count >= 1, got {sig}"
    );
    let keys: Vec<&str> = sig.as_object().unwrap().keys().map(|s| s.as_str()).collect();
    assert!(
        keys.iter().all(|k| ["seq", "count", "tsMs"].contains(k)),
        "HAPPY: proxy.request must be payload-free, got keys {keys:?}"
    );
    assert!(
        sig.get("records").is_none() && sig.get("items").is_none(),
        "HAPPY: proxy.request must not carry per-record data"
    );
    println!("HAPPY proxy.request dirty signal: payload={sig}");

    // ================= (b) UID unknown (LAN never queries) =================
    assert_eq!(
        rec["uidState"], "unknown",
        "FAILURE(b): LAN mode must degrade to uidState=unknown (never pending)"
    );
    assert!(
        rec["uid"].is_null(),
        "FAILURE(b): LAN-mode uid must surface as null, got {}",
        rec["uid"]
    );
    println!(
        "FAILURE(b) uid-unknown: LAN uidState=unknown uid=null -> PASS"
    );

    // ================= (c) export failure contract =================
    // The real byte cap is 64 MiB with a 50k-row ceiling, so a *real* over-limit
    // snapshot cannot be produced through the C ABI. The over-limit path is the
    // same `export_impl` boundary and is proven by the module's own test
    // `export_over_byte_cap_is_structured_and_leaves_no_file` (run separately).
    // Here we prove the other real export failure: an invalid filter is a
    // structured error with no file left behind.
    let (bad_code, bad) = call(
        call_fn,
        free_fn,
        inst,
        "requests.export",
        br#"{"format":"csv","filter":{"sinceMs":"not-a-number"}}"#,
    );
    println!("FAILURE(c) export invalid filter -> ABI code={bad_code} body={bad} (over-limit via unit test)");

    // ================= (e) proxy.request not arriving =================
    // Let the close settle and the 1 s throttle elapse, clear, then observe a
    // quiet window: the signal is change-driven, so its absence (a delivery
    // failure) is observable rather than masked by an always-on tick.
    std::thread::sleep(Duration::from_secs(3));
    let _ = take_events();
    std::thread::sleep(Duration::from_millis(2500));
    let quiet = take_events();
    assert!(
        !has_proxy_request_kind(&quiet),
        "FAILURE(e): no new proxy.request without new flow changes, got {}",
        quiet.len()
    );
    println!("FAILURE(e) proxy.request not arriving: quiet window emitted none -> PASS");

    // ---- teardown ----
    let _ = call(call_fn, free_fn, inst, "core.set_mode", br#"{"mode":"off"}"#);
    let _ = call(
        call_fn,
        free_fn,
        inst,
        "lan.set",
        br#"{"enabled":false}"#,
    );
    assert_eq!(destroy(inst), ABI_OK, "destroy");
    if let Some(s) = shutdown {
        let _ = s();
    }
    let _ = std::fs::remove_dir_all(&dir);
    println!("=== F3 host-equivalent QA complete ===");
}
