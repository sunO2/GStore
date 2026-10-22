//! Wave 3 Todo 2 contract: the FRB `DownloadApi` over the Todo-1 host port.
//!
//! Everything except the single real-`.so` test runs against an in-memory core
//! database and a fake module bridge. The real-module and "module is not
//! mounted" tests share [`MODULE_SERIAL`] because the host `ModuleManager` is
//! process-global.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use gstore_core::db::SharedConn;
use gstore_core::download::port::ModuleBridge;
use gstore_core::download::{DownloadTaskRow, NEEDS_RESTART};
use gstore_host::bridge::{DownloadApi, DownloadStartRequest, DownloadTaskDto};
use gstore_host::download_host::{DownloadWatchState, HostDownloadPort};
use rusqlite::Connection;
use serde_json::{json, Value};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);
static MODULE_SERIAL: Mutex<()> = Mutex::new(());

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_host_download_api_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create temp dir");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn core_conn() -> (SharedConn, PathBuf) {
    let mut conn = Connection::open_in_memory().expect("open in-memory core db");
    gstore_core::migration::apply_core_schema(&mut conn).expect("apply core schema");
    (
        Arc::new(Mutex::new(conn)),
        PathBuf::from("/tmp/gstore-core-test.db"),
    )
}

fn task_json(id: u64, status: i64, received: i64, dedup: &str) -> Value {
    json!({
        "id": id,
        "appId": "com.example.app",
        "appName": "Example",
        "version": "1.2.3",
        "fileName": "example.apk",
        "url": "https://example.test/example.apk",
        "filePath": "/tmp/example.apk",
        "status": status,
        "received": received,
        "total": 100,
        "speedBps": 5,
        "etaSec": 18,
        "dedupKey": dedup,
        "kind": "app",
        "resourceId": "com.example.app",
        "resourceVersion": "1.2.3",
        "installAfterDownload": false
    })
}

fn start_request() -> DownloadStartRequest {
    DownloadStartRequest {
        app_id: "com.example.app".to_string(),
        app_name: "Example".to_string(),
        version: "1.2.3".to_string(),
        file_name: "example.apk".to_string(),
        url: "https://example.test/example.apk".to_string(),
        dest_path: "/tmp/example.apk".to_string(),
        kind: "app".to_string(),
        resource_id: "com.example.app".to_string(),
        resource_version: "1.2.3".to_string(),
        dedup_key: "dedup:example".to_string(),
        expected_sha256: None,
        install_after_download: false,
    }
}

/// Module double that answers the calls `DownloadApi::start/get` need.
#[derive(Clone, Default)]
struct FakeBridge {
    tasks: Arc<Mutex<HashMap<u64, Value>>>,
}

impl FakeBridge {
    fn seeded() -> Self {
        let bridge = Self::default();
        bridge
            .tasks
            .lock()
            .expect("fake bridge lock")
            .insert(42, task_json(42, 2, 10, "dedup:example"));
        bridge
    }
}

impl ModuleBridge for FakeBridge {
    fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        let body: Value =
            serde_json::from_slice(payload).map_err(|e| format!("bad payload: {e}"))?;
        match method {
            "download.start" => {
                let value = task_json(42, 2, 10, "dedup:example");
                self.tasks
                    .lock()
                    .expect("fake bridge lock")
                    .insert(42, value.clone());
                serde_json::to_vec(&value).map_err(|e| e.to_string())
            }
            "download.get" => {
                let id = body["id"].as_u64().ok_or("missing id")?;
                match self
                    .tasks
                    .lock()
                    .expect("fake bridge lock")
                    .get(&id)
                    .cloned()
                {
                    Some(value) => serde_json::to_vec(&value).map_err(|e| e.to_string()),
                    None => Ok(b"null".to_vec()),
                }
            }
            "download.pause" | "download.resume" | "download.cancel" | "download.retry"
            | "download.restart" | "download.remove" => Ok(br#"{"ok":true}"#.to_vec()),
            other => Err(format!("unexpected method {other}")),
        }
    }
}

/// Bridge that always fails, used to prove `list` never touches the module.
#[derive(Debug, Clone, Copy)]
struct FailingBridge;

impl ModuleBridge for FailingBridge {
    fn call(&self, method: &str, _payload: &[u8]) -> Result<Vec<u8>, String> {
        Err(format!("bridge must not be called: {method}"))
    }
}

fn row(id: i64, status: &str) -> DownloadTaskRow {
    DownloadTaskRow {
        id,
        module_task_id: Some(id.to_string()),
        dedup_key: Some(format!("dedup:{id}")),
        app_id: Some("com.example.app".to_string()),
        app_name: Some("Example".to_string()),
        version: Some("1.2.3".to_string()),
        file_name: Some("example.apk".to_string()),
        kind: Some("app".to_string()),
        resource_id: Some("com.example.app".to_string()),
        resource_version: Some("1.2.3".to_string()),
        url: Some("https://example.test/example.apk".to_string()),
        dest_path: Some("/tmp/example.apk".to_string()),
        status: status.to_string(),
        bytes_done: 0,
        total: 100,
        speed_bps: 0,
        eta_sec: None,
        segments_json: None,
        retries: 0,
        server_meta: None,
        priority: 0,
        headers_json: None,
        expected_sha256: None,
        install_after_download: false,
        error: None,
        last_started_at: None,
        created_at: 1,
        updated_at: 1,
    }
}

#[test]
fn download_api_start_and_list_without_module_mount() {
    let (conn, core_db) = core_conn();
    let port = HostDownloadPort::with_bridge_for_test(
        FakeBridge::seeded(),
        conn.clone(),
        core_db.clone(),
        None,
    );
    let api = DownloadApi::from_port_for_test(port);

    let id = api.start(start_request()).expect("start via fake module");
    assert_eq!(id, 42);

    let rows = api.list().expect("list from core");
    println!("download_api list rows after start: {rows:?}");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].module_task_id.as_deref(), Some("42"));
    assert_eq!(rows[0].status, "running");

    // A port whose bridge always errors still lists core rows: `download_task`
    // in `gstore_core.db` is authoritative and must not require the module.
    let failing =
        HostDownloadPort::with_bridge_for_test(FailingBridge, conn.clone(), core_db, None);
    let api_without_module = DownloadApi::from_port_for_test(failing);
    let core_rows = api_without_module.list().expect("list must be bridge-free");
    println!("download_api list without module: {core_rows:?}");
    assert_eq!(core_rows, rows);
    assert_eq!(
        core_rows[0].app_id.as_deref(),
        Some("com.example.app"),
        "core authority survives an unusable module"
    );
}

#[test]
fn download_api_error_codes() {
    let (conn, core_db) = core_conn();
    let api = DownloadApi::from_port_for_test(HostDownloadPort::with_bridge_for_test(
        FakeBridge::default(),
        conn.clone(),
        core_db.clone(),
        None,
    ));

    let unknown = api
        .get("999".to_string())
        .expect_err("unknown task must fail");
    println!("download_api unknown task error: {unknown}");
    assert!(
        unknown.starts_with("CORE_E_DOWNLOAD_NEEDS_RESTART")
            || unknown.starts_with("CORE_E_DOWNLOAD_UNKNOWN_TASK"),
        "unknown task must use a typed download error: {unknown}"
    );

    let invalid = api.get("   ".to_string()).expect_err("blank id must fail");
    println!("download_api invalid id error: {invalid}");
    assert!(
        invalid.starts_with("CORE_E_DOWNLOAD_INVALID_ARG"),
        "blank id must be invalid: {invalid}"
    );

    let invalid_start = api
        .start(DownloadStartRequest {
            app_id: "   ".to_string(),
            ..start_request()
        })
        .expect_err("blank app_id must fail");
    println!("download_api invalid start error: {invalid_start}");
    assert!(invalid_start.starts_with("CORE_E_DOWNLOAD_INVALID_ARG"));

    // The injected fake bridge itself failing is still a module error.
    let fake_failure = DownloadApi::from_port_for_test(HostDownloadPort::with_bridge_for_test(
        FailingBridge,
        conn.clone(),
        core_db.clone(),
        None,
    ))
    .start(start_request())
    .expect_err("failing bridge must fail");
    println!("download_api bridge failure error: {fake_failure}");
    assert!(fake_failure.starts_with("CORE_E_DOWNLOAD_MODULE"));

    // No module has been mounted in this test binary at this point (the
    // real-module test serializes on the same lock).
    let _serial = MODULE_SERIAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let dir = TempDir::new("unmounted");
    let data_dir = dir.path().join("data");
    let cache_dir = dir.path().join("cache");
    std::fs::create_dir_all(&data_dir).expect("data dir");
    std::fs::create_dir_all(&cache_dir).expect("cache dir");
    let unmounted =
        DownloadApi::from_port_for_test(HostDownloadPort::new(conn, core_db, data_dir, cache_dir));
    let error = unmounted
        .start(start_request())
        .expect_err("unmounted module must fail");
    println!("download_api unmounted start error: {error}");
    assert!(
        error.starts_with("CORE_E_DOWNLOAD_MODULE"),
        "unmounted module error prefix: {error}"
    );
}

#[test]
fn download_api_watch_terminal_dedup() {
    let mut state = DownloadWatchState::new();

    let mut running = row(1, "running");
    assert_eq!(
        state.observe(vec![running.clone()]),
        vec![DownloadTaskDto::from(running.clone())],
        "the first tick emits the new running task"
    );
    assert!(
        state.observe(vec![running.clone()]).is_empty(),
        "running -> running must emit nothing"
    );
    println!("download_api watch: running -> running emitted 0");

    running.status = "completed".to_string();
    running.bytes_done = 100;
    let terminal = state.observe(vec![running.clone()]);
    println!("download_api watch: running -> completed emitted {terminal:?}");
    assert_eq!(terminal.len(), 1, "running -> completed emits exactly once");
    assert_eq!(terminal[0].status, "completed");

    assert!(
        state.observe(vec![running.clone()]).is_empty(),
        "completed -> completed must emit nothing"
    );
    running.bytes_done = 55;
    assert!(
        state.observe(vec![running]).is_empty(),
        "a terminal row must never be emitted again even if it changes"
    );
    println!("download_api watch: completed -> completed emitted 0");

    let later = row(2, "running");
    let later_emits = state.observe(vec![row(1, "completed"), later.clone()]);
    println!("download_api watch: new task after terminal emitted {later_emits:?}");
    assert_eq!(
        later_emits.len(),
        1,
        "new tasks appear after a terminal one"
    );
    assert_eq!(later_emits[0].id, 2);
    assert_eq!(later_emits[0].status, "running");

    let mut failed = row(3, "failed");
    assert_eq!(state.observe(vec![failed.clone()]).len(), 1);
    failed.status = "running".to_string();
    assert!(
        state.observe(vec![failed]).is_empty(),
        "failed is terminal-once"
    );

    let mut restart = row(4, NEEDS_RESTART);
    assert_eq!(state.observe(vec![restart.clone()]).len(), 1);
    restart.status = "running".to_string();
    assert!(
        state.observe(vec![restart]).is_empty(),
        "needs_restart is terminal-once"
    );
    println!("download_api watch: failed/needs_restart terminal-once verified");
}

/// Locates the built module `.so`; missing is fatal unless the explicit
/// `GSTORE_ALLOW_MISSING_MODULE` escape hatch is set (Todo-1 convention).
fn module_so(rel: &str) -> Option<PathBuf> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(rel);
    if path.exists() {
        return Some(path);
    }
    if std::env::var("GSTORE_ALLOW_MISSING_MODULE").is_ok() {
        eprintln!(
            "SKIP (GSTORE_ALLOW_MISSING_MODULE=1): module .so not built: {}",
            path.display()
        );
        return None;
    }
    panic!(
        "module .so not built: {} — 先运行 rust/build_all.sh 构建模块，\
         或设 GSTORE_ALLOW_MISSING_MODULE=1 显式跳过",
        path.display()
    );
}

/// Local HTTP fixture with HEAD + Range support (the download engine probes
/// both before transferring).
fn spawn_range_server(body: Vec<u8>, etag: &'static str) -> String {
    use std::net::TcpListener;
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind fixture server");
    let addr = listener.local_addr().expect("fixture addr");
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut sock) = stream else { continue };
            let body = body.clone();
            std::thread::spawn(move || {
                let mut buf = [0u8; 8192];
                let n = sock.read(&mut buf).unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let range = req.lines().find_map(|line| {
                    let line = line.to_ascii_lowercase();
                    line.strip_prefix("range: bytes=")
                        .map(|value| value.trim().to_string())
                });
                match range {
                    Some(range) => {
                        let (a, b) = range.split_once('-').unwrap_or(("0", ""));
                        let start: usize = a.parse().unwrap_or(0);
                        let end: usize = if b.is_empty() {
                            body.len().saturating_sub(1)
                        } else {
                            b.parse().unwrap_or(body.len() - 1)
                        };
                        let end = end.min(body.len().saturating_sub(1));
                        if start > end {
                            let _ = sock.write_all(
                                b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                            );
                            return;
                        }
                        let slice = &body[start..=end];
                        let head = format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nAccept-Ranges: bytes\r\nETag: {}\r\nConnection: close\r\n\r\n",
                            slice.len(), start, end, body.len(), etag
                        );
                        let _ = sock.write_all(head.as_bytes());
                        let _ = sock.write_all(slice);
                    }
                    None => {
                        let head = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nETag: {}\r\nConnection: close\r\n\r\n",
                            body.len(), etag
                        );
                        let _ = sock.write_all(head.as_bytes());
                        let _ = sock.write_all(&body);
                    }
                }
            });
        }
    });
    format!("http://{addr}/file.bin")
}

#[test]
fn download_api_real_module_start_list_get() {
    let _serial = MODULE_SERIAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(so_path) = module_so("../gstore_mod_download/target/debug/libgstore_mod_download.so")
    else {
        return;
    };

    let dir = TempDir::new("real_module");
    let data_dir = dir.path().join("data");
    let cache_dir = dir.path().join("cache");
    let dest = dir.path().join("payload.bin");
    std::fs::create_dir_all(&data_dir).expect("data dir");
    std::fs::create_dir_all(&cache_dir).expect("cache dir");

    let (conn, core_db) = core_conn();
    let handle =
        gstore_host::bridge::ModuleHandle::mount_from_so(so_path.to_string_lossy().into_owned())
            .expect("mount download module");
    assert!(handle.is_loaded(), "download module must be registered");

    let port = HostDownloadPort::new(conn, core_db, data_dir, cache_dir);
    let api = DownloadApi::from_port_for_test(port);
    let url = spawn_range_server(b"hello".to_vec(), "\"fixture-etag\"");
    let mut request = start_request();
    request.url = url;
    request.dest_path = dest.to_string_lossy().into_owned();
    request.dedup_key = "http:download-api".to_string();

    let started = Instant::now();
    let id = api.start(request).expect("start real download");
    println!("download_api real module task id: {id}");

    let rows = api.list().expect("list real module start row");
    println!("download_api real module list: {rows:?}");
    assert!(
        rows.iter()
            .any(|row| row.module_task_id.as_deref() == Some(id.to_string().as_str())),
        "started task must be present in the core list"
    );

    let one = api
        .get(id.to_string())
        .expect("get real module task")
        .expect("real task row present");
    println!("download_api real module get: {one:?}");
    assert_eq!(one.module_task_id.as_deref(), Some(id.to_string().as_str()));
    assert!(
        started.elapsed() < Duration::from_secs(15),
        "bounded real-module test"
    );
}
