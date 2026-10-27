//! Wave 3 Todo 1 contract: the core download port wired through the host's
//! module manager. Fake-bridge tests never touch global module state; the one
//! real-`.so` roundtrip test is the only test that registers module name
//! "download" and is serialized through [`REAL_MODULE_SERIAL`].

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use gstore_core::db::SharedConn;
use gstore_core::download::port::{DownloadRequest, ModuleBridge};
use gstore_host::download_host::{HostDownloadPort, ReconcileOutcome};
use rusqlite::Connection;
use serde_json::{json, Value};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);
static REAL_MODULE_SERIAL: Mutex<()> = Mutex::new(());

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_host_download_bridge_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
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
    let mut conn = Connection::open_in_memory().unwrap();
    gstore_core::migration::apply_core_schema(&mut conn).unwrap();
    (Arc::new(Mutex::new(conn)), PathBuf::from("/tmp/gstore-core-test.db"))
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

fn request() -> DownloadRequest {
    DownloadRequest {
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
        headers: std::collections::HashMap::new(),
    }
}

/// In-memory module double shared by the fake-bridge tests.
#[derive(Clone)]
struct FakeBridge {
    tasks: Arc<Mutex<HashMap<u64, Value>>>,
    calls: Arc<AtomicUsize>,
}

impl FakeBridge {
    fn new() -> Self {
        Self {
            tasks: Arc::new(Mutex::new(HashMap::new())),
            calls: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn seeded() -> Self {
        let bridge = Self::new();
        bridge.put(task_json(42, 2, 10, "dedup:example"));
        bridge
    }

    fn put(&self, value: Value) {
        let id = value["id"].as_u64().unwrap();
        self.tasks.lock().unwrap().insert(id, value);
    }

}

impl ModuleBridge for FakeBridge {
    fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let body: Value =
            serde_json::from_slice(payload).map_err(|e| format!("bad payload: {e}"))?;
        match method {
            "download.start" => {
                let id = 42u64;
                let value = task_json(id, 2, 10, "dedup:example");
                self.tasks.lock().unwrap().insert(id, value.clone());
                serde_json::to_vec(&value).map_err(|e| e.to_string())
            }
            "download.get" => {
                let id = body["id"].as_u64().ok_or("missing id")?;
                match self.tasks.lock().unwrap().get(&id).cloned() {
                    Some(value) => serde_json::to_vec(&value).map_err(|e| e.to_string()),
                    None => Ok(b"null".to_vec()),
                }
            }
            "download.pause"
            | "download.resume"
            | "download.cancel"
            | "download.retry"
            | "download.restart"
            | "download.remove" => {
                let id = body["id"].as_u64().ok_or("missing id")?;
                let status = match method {
                    "download.pause" => 3,
                    "download.cancel" | "download.remove" => 6,
                    _ => 2,
                };
                if let Some(task) = self.tasks.lock().unwrap().get_mut(&id) {
                    task["status"] = json!(status);
                }
                Ok(br#"{"ok":true}"#.to_vec())
            }
            other => Err(format!("unexpected method {other}")),
        }
    }
}

fn load_core_row(conn: &SharedConn, module_task_id: &str) -> gstore_core::download::DownloadTaskRow {
    let guard = conn.lock().unwrap();
    gstore_core::download::load_task(&guard, module_task_id)
        .expect("load core row")
        .unwrap_or_else(|| panic!("core download_task row {module_task_id} is missing"))
}

fn core_row_count(conn: &SharedConn) -> i64 {
    conn.lock()
        .unwrap()
        .query_row("SELECT COUNT(*) FROM download_task", [], |row| row.get(0))
        .unwrap()
}

#[test]
fn download_host_bridge_start_populates_core_row() {
    let bridge = FakeBridge::seeded();
    let calls = bridge.calls.clone();
    let (conn, core_db) = core_conn();
    let port = HostDownloadPort::with_bridge_for_test(bridge.clone(), conn.clone(), core_db, None);

    let id = port.start(&request()).expect("start");
    assert_eq!(id, 42);

    let row = load_core_row(&conn, "42");
    println!("core row after start: {row:?}");
    assert_eq!(row.module_task_id.as_deref(), Some("42"));
    assert_eq!(row.dedup_key.as_deref(), Some("dedup:example"));
    assert_eq!(row.app_id.as_deref(), Some("com.example.app"));
    assert_eq!(row.dest_path.as_deref(), Some("/tmp/example.apk"));
    assert_eq!(row.status, "running");

    // Module-only task: `get` must mirror the module row into the core table.
    bridge.put(task_json(43, 2, 33, "dedup:mirrored"));
    let mirrored = port.get("43").expect("get mirrors module row");
    println!("mirrored row: {mirrored:?}");
    assert_eq!(mirrored.module_task_id.as_deref(), Some("43"));
    assert_eq!(mirrored.bytes_done, 33);
    assert_eq!(mirrored.app_name.as_deref(), Some("Example"));

    port.pause("42").expect("pause");
    let row = load_core_row(&conn, "42");
    assert_eq!(row.status, "paused");

    let list = port.list().expect("list");
    println!("list rows: {list:?}");
    assert_eq!(list.len(), 2);
    assert_eq!(port.snapshot().expect("snapshot"), list);
    assert_eq!(port.watch_all().expect("watch_all"), list);
    assert_eq!(port.db_path(), Path::new("/tmp/gstore-core-test.db"));
    assert!(calls.load(Ordering::SeqCst) >= 3);
}

#[test]
fn download_host_bridge_reconcile_idempotent() {
    let bridge = FakeBridge::seeded();
    bridge.put(task_json(43, 4, 100, "dedup:mirrored"));
    let (conn, core_db) = core_conn();
    let port = HostDownloadPort::with_bridge_for_test(bridge.clone(), conn.clone(), core_db, None);

    port.start(&request()).expect("start");
    port.get("43").expect("get");

    let first = port.reconcile().expect("first reconcile");
    let second = port.reconcile().expect("second reconcile");
    println!("reconcile first={first:?} second={second:?}");
    println!("core row count after reconcile: {}", core_row_count(&conn));

    assert_eq!(first.checked, 2);
    assert_eq!(second.checked, first.checked);
    assert!(first.needs_restart.is_empty());
    assert!(second.needs_restart.is_empty());
    assert_eq!(core_row_count(&conn), 2);

    let duplicate_dedup_keys: i64 = conn
        .lock()
        .unwrap()
        .query_row(
            "SELECT COUNT(*) FROM (
                 SELECT dedup_key FROM download_task
                 WHERE dedup_key IS NOT NULL
                 GROUP BY dedup_key HAVING COUNT(*) > 1
             )",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(duplicate_dedup_keys, 0, "dedup_key must stay unique");

    assert_eq!(
        port.last_reconcile(),
        Some(ReconcileOutcome::Ok(second)),
        "last reconcile report must be observable"
    );
}

#[test]
fn download_host_bridge_recover_missing_module_db() {
    let dir = TempDir::new("recover");
    let bridge = FakeBridge::new();
    let calls = bridge.calls.clone();
    let (conn, core_db) = core_conn();
    conn.lock()
        .unwrap()
        .execute(
            "INSERT INTO download_task
             (module_task_id, dedup_key, app_id, version, file_name, status, created_at, updated_at)
             VALUES ('7', 'dedup:7', 'com.example.app', '1.0.0', 'app.apk', 'running', 1, 1)",
            [],
        )
        .unwrap();

    let missing = dir.path().join("download.db");
    let port =
        HostDownloadPort::with_bridge_for_test(bridge, conn.clone(), core_db, Some(missing));

    let report = port.reconcile().expect("missing module db is not fatal");
    println!("missing module db reconcile report: {report:?}");
    println!("bridge calls: {}", calls.load(Ordering::SeqCst));
    println!("core row after recover: {:?}", load_core_row(&conn, "7"));
    println!("snapshot after recover: {:?}", port.snapshot().expect("snapshot"));
    assert_eq!(report.checked, 1);
    assert_eq!(report.needs_restart, vec!["7".to_string()]);
    assert_eq!(
        calls.load(Ordering::SeqCst),
        0,
        "a missing module db must be handled without the bridge"
    );
    assert_eq!(load_core_row(&conn, "7").status, "needs_restart");
    assert!(
        port.snapshot()
            .expect("snapshot")
            .iter()
            .all(|row| row.status != "running"),
        "no stale running row may survive a lost module db"
    );
    assert_eq!(
        port.last_reconcile(),
        Some(ReconcileOutcome::Ok(report)),
        "the recover report must be observable"
    );
}

/// Locates the built module `.so`; missing is fatal unless the explicit
/// `GSTORE_ALLOW_MISSING_MODULE` escape hatch is set (same convention as
/// `src/dl_adapter.rs`).
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
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
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
fn download_host_bridge_real_module_roundtrip() {
    let _serial = REAL_MODULE_SERIAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(so_path) =
        module_so("../gstore_mod_download/target/debug/libgstore_mod_download.so")
    else {
        return;
    };

    let dir = TempDir::new("real_module");
    let data_dir = dir.path().join("data");
    let cache_dir = dir.path().join("cache");
    let dest = dir.path().join("payload.bin");
    std::fs::create_dir_all(&data_dir).unwrap();
    std::fs::create_dir_all(&cache_dir).unwrap();

    let (conn, core_db) = core_conn();
    let handle =
        gstore_host::bridge::ModuleHandle::mount_from_so(so_path.to_string_lossy().into_owned())
            .expect("mount download module");
    assert!(handle.is_loaded(), "download module must be registered");

    let port = HostDownloadPort::new(conn.clone(), core_db, data_dir, cache_dir);
    let url = spawn_range_server(b"hello".to_vec(), "\"fixture-etag\"");
    let mut req = request();
    req.url = url;
    req.dest_path = dest.to_string_lossy().into_owned();
    req.dedup_key = "http:local".to_string();

    let id = port.start(&req).expect("start real download");
    println!("real module task id: {id}");

    let deadline = Instant::now() + Duration::from_secs(15);
    let mut completed = None;
    while Instant::now() < deadline {
        port.reconcile().expect("reconcile real module");
        if let Some(row) = port
            .snapshot()
            .expect("snapshot")
            .into_iter()
            .find(|row| row.module_task_id.as_deref() == Some(id.to_string().as_str()))
        {
            println!("core row while polling: {row:?}");
            if row.status == "completed" {
                completed = Some(row);
                break;
            }
            assert_ne!(row.status, "failed", "real download failed: {row:?}");
        }
        std::thread::sleep(Duration::from_millis(100));
    }

    let row = completed.expect("real module download did not reach completed in time");
    println!("final core row: {row:?}");
    println!("final file bytes: {:?}", std::fs::read(&dest));
    assert_eq!(row.status, "completed");
    assert_eq!(std::fs::read(&dest).expect("download file exists"), b"hello");
}
