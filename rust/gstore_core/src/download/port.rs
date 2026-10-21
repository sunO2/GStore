//! Download port: reconciles core `download_task` rows against the download module.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension};
use serde_json::{json, Value};

use crate::db::SharedConn;
use crate::download::{DownloadTaskRow, NEEDS_RESTART};

/// Transport used to invoke the download module without linking its cdylib.
pub trait ModuleBridge: Send + Sync {
    fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, String>;
}

/// Fully-resolved download request accepted by [`DownloadPort::start`].
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DownloadRequest {
    pub app_id: String,
    pub app_name: String,
    pub version: String,
    pub file_name: String,
    pub url: String,
    pub dest_path: String,
    pub kind: String,
    pub resource_id: String,
    pub resource_version: String,
    pub dedup_key: String,
    pub expected_sha256: Option<String>,
    pub install_after_download: bool,
}

/// Typed failures of the download port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PortError {
    Module(String),
    Db(String),
    UnknownTask(String),
    NeedsRestart(String),
}

impl std::fmt::Display for PortError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Module(msg) => write!(f, "module: {msg}"),
            Self::Db(msg) => write!(f, "db: {msg}"),
            Self::UnknownTask(id) => write!(f, "unknown task: {id}"),
            Self::NeedsRestart(id) => write!(f, "needs restart: {id}"),
        }
    }
}

impl std::error::Error for PortError {}

/// Result of a reconciliation sweep over locally persisted module task ids.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReconcileReport {
    pub checked: usize,
    pub needs_restart: Vec<String>,
}

/// Stable core-side facade over the download module's task API.
pub trait DownloadPort {
    fn db_path(&self) -> &Path;
    fn start(&self, req: &DownloadRequest) -> Result<i64, PortError>;
    fn list(&self) -> Result<Vec<DownloadTaskRow>, PortError>;
    fn get(&self, module_task_id: &str) -> Result<DownloadTaskRow, PortError>;
    fn pause(&self, id: &str) -> Result<(), PortError>;
    fn resume(&self, id: &str) -> Result<(), PortError>;
    fn cancel(&self, id: &str) -> Result<(), PortError>;
    fn retry(&self, id: &str) -> Result<(), PortError>;
    fn restart(&self, id: &str) -> Result<(), PortError>;
    fn remove(&self, id: &str) -> Result<(), PortError>;
    /// Spike implementation delegates to [`DownloadPort::snapshot`]; live module event
    /// streaming is scheduled for the main migration plan.
    fn watch_all(&self) -> Result<Vec<DownloadTaskRow>, PortError>;
    fn snapshot(&self) -> Result<Vec<DownloadTaskRow>, PortError>;
    fn reconcile(&self) -> Result<ReconcileReport, PortError>;
}

/// [`DownloadPort`] backed by a [`ModuleBridge`] plus the core SQLite database.
pub struct ModuleDownloadPort<B: ModuleBridge> {
    bridge: B,
    conn: SharedConn,
    db_path: PathBuf,
    module_db_path: Option<PathBuf>,
}

impl<B: ModuleBridge> ModuleDownloadPort<B> {
    pub fn new(bridge: B, conn: SharedConn, db_path: PathBuf) -> Self {
        Self {
            bridge,
            conn,
            db_path,
            module_db_path: None,
        }
    }

    /// Records where the download module keeps its own database.
    ///
    /// When the path is set and the file is missing, reconciliation treats every
    /// non-terminal row as `needs_restart` instead of asking a module that has
    /// provably lost its state.
    pub fn with_module_db_path(mut self, path: PathBuf) -> Self {
        self.module_db_path = Some(path);
        self
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>, PortError> {
        self.conn
            .lock()
            .map_err(|_| PortError::Db("connection mutex poisoned".to_string()))
    }

    fn module_id(id: &str) -> Result<u64, PortError> {
        id.trim()
            .parse::<u64>()
            .map_err(|_| PortError::Module(format!("invalid module task id: {id}")))
    }

    fn module_call(&self, method: &str, payload: Value) -> Result<Value, PortError> {
        let bytes = serde_json::to_vec(&payload)
            .map_err(|e| PortError::Module(format!("serialize {method}: {e}")))?;
        let out = self.bridge.call(method, &bytes).map_err(PortError::Module)?;
        serde_json::from_slice(&out)
            .map_err(|e| PortError::Module(format!("parse {method} response: {e}")))
    }

    fn module_get(&self, id: &str) -> Result<Option<Value>, PortError> {
        let numeric = Self::module_id(id)?;
        let value = self.module_call("download.get", json!({ "id": numeric }))?;
        Ok((!value.is_null()).then_some(value))
    }

    fn module_mutate(&self, method: &str, id: &str, status: &str) -> Result<(), PortError> {
        let numeric = Self::module_id(id)?;
        self.module_call(method, json!({ "id": numeric }))?;
        let conn = self.lock()?;
        conn.execute(
            "UPDATE download_task SET status = ?1, updated_at = ?2 WHERE module_task_id = ?3",
            rusqlite::params![status, now_secs(), id],
        )
        .map_err(|e| PortError::Db(format!("mark task {id} {status}: {e}")))?;
        Ok(())
    }

    fn upsert(&self, record: &TaskRecord) -> Result<(), PortError> {
        let conn = self.lock()?;
        upsert_record(&conn, record, now_secs())
    }

    fn mark_needs_restart(&self, id: &str) -> Result<(), PortError> {
        let conn = self.lock()?;
        conn.execute(
            "UPDATE download_task SET status = ?1, updated_at = ?2 WHERE module_task_id = ?3",
            rusqlite::params![NEEDS_RESTART, now_secs(), id],
        )
        .map_err(|e| PortError::Db(format!("mark task {id} needs_restart: {e}")))?;
        Ok(())
    }

    fn reconcile_without_module_db(&self) -> Result<ReconcileReport, PortError> {
        let rows = self.list()?;
        let mut report = ReconcileReport {
            checked: rows.len(),
            needs_restart: Vec::new(),
        };
        let conn = self.lock()?;
        for row in rows {
            if matches!(row.status.as_str(), "completed" | "cancelled" | "removed") {
                continue;
            }
            conn.execute(
                "UPDATE download_task SET status = ?1, updated_at = ?2 WHERE id = ?3",
                rusqlite::params![NEEDS_RESTART, now_secs(), row.id],
            )
            .map_err(|e| PortError::Db(format!("mark row {} needs_restart: {e}", row.id)))?;
            report
                .needs_restart
                .push(row.module_task_id.unwrap_or_else(|| row.id.to_string()));
        }
        Ok(report)
    }
}

impl<B: ModuleBridge> DownloadPort for ModuleDownloadPort<B> {
    fn db_path(&self) -> &Path {
        &self.db_path
    }

    fn start(&self, req: &DownloadRequest) -> Result<i64, PortError> {
        let payload = start_payload(req);
        let value = self.module_call("download.start", payload)?;
        let id = field_i64(&value, &["id"])
            .ok_or_else(|| PortError::Module("download.start response missing id".to_string()))?;
        let status = field_i64(&value, &["status"])
            .map_or_else(|| "running".to_string(), |s| status_label(s).to_string());
        self.upsert(&TaskRecord::from_request(req, id.to_string(), &status))?;
        Ok(id)
    }

    fn list(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        let conn = self.lock()?;
        query_rows(&conn)
    }

    fn get(&self, module_task_id: &str) -> Result<DownloadTaskRow, PortError> {
        {
            let conn = self.lock()?;
            if let Some(row) = crate::download::load_task(&conn, module_task_id)
                .map_err(|e| PortError::Db(e.to_string()))?
            {
                return Ok(row);
            }
        }
        let Some(value) = self.module_get(module_task_id)? else {
            return Err(PortError::NeedsRestart(module_task_id.to_string()));
        };
        let record = TaskRecord::from_module_value(&value)
            .ok_or_else(|| PortError::Module("download.get returned a task without id".to_string()))?;
        self.upsert(&record)?;
        let conn = self.lock()?;
        crate::download::load_task(&conn, module_task_id)
            .map_err(|e| PortError::Db(e.to_string()))?
            .ok_or_else(|| PortError::UnknownTask(module_task_id.to_string()))
    }

    fn pause(&self, id: &str) -> Result<(), PortError> {
        self.module_mutate("download.pause", id, "paused")
    }

    fn resume(&self, id: &str) -> Result<(), PortError> {
        self.module_mutate("download.resume", id, "running")
    }

    fn cancel(&self, id: &str) -> Result<(), PortError> {
        self.module_mutate("download.cancel", id, "cancelled")
    }

    fn retry(&self, id: &str) -> Result<(), PortError> {
        self.module_mutate("download.retry", id, "running")
    }

    fn restart(&self, id: &str) -> Result<(), PortError> {
        self.module_mutate("download.restart", id, "running")
    }

    fn remove(&self, id: &str) -> Result<(), PortError> {
        self.module_mutate("download.remove", id, "removed")
    }

    fn watch_all(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        self.snapshot()
    }

    fn snapshot(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        self.list()
    }

    fn reconcile(&self) -> Result<ReconcileReport, PortError> {
        if let Some(path) = &self.module_db_path {
            if !path.exists() {
                return self.reconcile_without_module_db();
            }
        }
        let mut report = ReconcileReport::default();
        for row in self.list()? {
            let Some(id) = row.module_task_id else {
                continue;
            };
            report.checked += 1;
            match self.module_get(&id) {
                Ok(Some(value)) => {
                    if let Some(record) = TaskRecord::from_module_value(&value) {
                        self.upsert(&record)?;
                    }
                }
                Ok(None) => {
                    self.mark_needs_restart(&id)?;
                    report.needs_restart.push(id);
                }
                Err(PortError::NeedsRestart(_)) => {
                    self.mark_needs_restart(&id)?;
                    report.needs_restart.push(id);
                }
                Err(err) => return Err(err),
            }
        }
        Ok(report)
    }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn empty_to_none(value: &str) -> Option<String> {
    (!value.is_empty()).then(|| value.to_string())
}

fn field<'a>(value: &'a Value, names: &[&str]) -> Option<&'a Value> {
    names
        .iter()
        .find_map(|name| value.get(*name).filter(|v| !v.is_null()))
}

fn field_str(value: &Value, names: &[&str]) -> Option<String> {
    field(value, names).and_then(|v| v.as_str().map(ToString::to_string))
}

fn field_i64(value: &Value, names: &[&str]) -> Option<i64> {
    field(value, names).and_then(|v| {
        v.as_i64()
            .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
    })
}

/// Maps a download module status code to the core task status label.
///
/// Public so harnesses (for example the LocalDb parity bin) can assert the
/// exact rule without duplicating it.
pub fn status_label(code: i64) -> &'static str {
    match code {
        0..=2 => "running",
        3 => "paused",
        4 => "completed",
        5 => "failed",
        6 => "cancelled",
        _ => "unknown",
    }
}

#[derive(Debug)]
struct TaskRecord {
    module_task_id: String,
    dedup_key: Option<String>,
    app_id: String,
    app_name: String,
    version: String,
    file_name: String,
    kind: String,
    resource_id: String,
    resource_version: String,
    url: String,
    dest_path: String,
    status: String,
    bytes_done: i64,
    total: i64,
    speed_bps: i64,
    eta_sec: Option<i64>,
    last_started_at: Option<i64>,
    expected_sha256: Option<String>,
    install_after_download: bool,
}

impl TaskRecord {
    fn from_request(req: &DownloadRequest, module_task_id: String, status: &str) -> Self {
        Self {
            module_task_id,
            dedup_key: empty_to_none(&req.dedup_key),
            app_id: req.app_id.clone(),
            app_name: req.app_name.clone(),
            version: req.version.clone(),
            file_name: req.file_name.clone(),
            kind: req.kind.clone(),
            resource_id: req.resource_id.clone(),
            resource_version: req.resource_version.clone(),
            url: req.url.clone(),
            dest_path: req.dest_path.clone(),
            status: status.to_string(),
            bytes_done: 0,
            total: 0,
            speed_bps: 0,
            eta_sec: None,
            last_started_at: None,
            expected_sha256: req.expected_sha256.clone(),
            install_after_download: req.install_after_download,
        }
    }

    fn from_module_value(value: &Value) -> Option<Self> {
        let module_task_id = field_i64(value, &["id"])?.to_string();
        let received = field_i64(value, &["received"]).unwrap_or(0);
        let total = field_i64(value, &["total"]).unwrap_or(0);
        Some(Self {
            module_task_id,
            dedup_key: field_str(value, &["dedup_key", "dedupKey"]).and_then(|s| empty_to_none(&s)),
            app_id: field_str(value, &["app_id", "appId"]).unwrap_or_default(),
            app_name: field_str(value, &["app_name", "appName"]).unwrap_or_default(),
            version: field_str(value, &["version"]).unwrap_or_default(),
            file_name: field_str(value, &["file_name", "fileName"]).unwrap_or_default(),
            kind: field_str(value, &["kind"]).unwrap_or_default(),
            resource_id: field_str(value, &["resource_id", "resourceId"]).unwrap_or_default(),
            resource_version: field_str(value, &["resource_version", "resourceVersion"])
                .unwrap_or_default(),
            url: field_str(value, &["url"]).unwrap_or_default(),
            dest_path: field_str(value, &["file_path", "filePath"]).unwrap_or_default(),
            status: field_i64(value, &["status"])
                .map_or_else(|| "running".to_string(), |s| status_label(s).to_string()),
            bytes_done: received,
            total,
            speed_bps: field_i64(value, &["speed_bps", "speedBps"]).unwrap_or(0),
            eta_sec: field_i64(value, &["eta_sec", "etaSec"]),
            last_started_at: field_i64(value, &["last_started_at", "lastStartedAt"]),
            expected_sha256: field_str(value, &["expected_sha256", "expectedSha256"]),
            install_after_download: field(value, &["install_after_download", "installAfterDownload"])
                .and_then(Value::as_bool)
                .unwrap_or(false),
        })
    }
}

fn start_payload(req: &DownloadRequest) -> Value {
    // gstore_mod_download deserializes with camelCase; the core contract also
    // names snake_case keys, so emit both spellings for compatibility.
    json!({
        "app_id": req.app_id,
        "appId": req.app_id,
        "app_name": req.app_name,
        "appName": req.app_name,
        "version": req.version,
        "file_name": req.file_name,
        "fileName": req.file_name,
        "url": req.url,
        "file_path": req.dest_path,
        "filePath": req.dest_path,
        "kind": req.kind,
        "resource_id": req.resource_id,
        "resourceId": req.resource_id,
        "resource_version": req.resource_version,
        "resourceVersion": req.resource_version,
        "dedup_key": req.dedup_key,
        "dedupKey": req.dedup_key,
        "headers": {},
        "expected_sha256": req.expected_sha256,
        "expectedSha256": req.expected_sha256,
        "install_after_download": req.install_after_download,
        "installAfterDownload": req.install_after_download,
    })
}

fn upsert_record(conn: &Connection, record: &TaskRecord, now: i64) -> Result<(), PortError> {
    let existing = existing_row_id(conn, "module_task_id", &record.module_task_id)?;
    let existing = match existing {
        Some(id) => Some(id),
        None => match &record.dedup_key {
            Some(key) => existing_row_id(conn, "dedup_key", key)?,
            None => None,
        },
    };
    let params = rusqlite::params![
        record.module_task_id,
        record.dedup_key,
        record.app_id,
        record.app_name,
        record.version,
        record.file_name,
        record.kind,
        record.resource_id,
        record.resource_version,
        record.url,
        record.dest_path,
        record.status,
        record.bytes_done,
        record.total,
        record.speed_bps,
        record.eta_sec,
        record.last_started_at,
        record.expected_sha256,
        i64::from(record.install_after_download),
        now,
    ];
    match existing {
        Some(row_id) => conn.execute(
            "UPDATE download_task SET
                module_task_id = ?1, dedup_key = ?2, app_id = ?3, app_name = ?4, version = ?5,
                file_name = ?6, kind = ?7, resource_id = ?8, resource_version = ?9, url = ?10,
                dest_path = ?11, status = ?12, bytes_done = ?13, total = ?14, speed_bps = ?15,
                eta_sec = ?16, last_started_at = ?17, expected_sha256 = ?18,
                install_after_download = ?19, updated_at = ?20
             WHERE id = ?21",
            rusqlite::params![
                record.module_task_id,
                record.dedup_key,
                record.app_id,
                record.app_name,
                record.version,
                record.file_name,
                record.kind,
                record.resource_id,
                record.resource_version,
                record.url,
                record.dest_path,
                record.status,
                record.bytes_done,
                record.total,
                record.speed_bps,
                record.eta_sec,
                record.last_started_at,
                record.expected_sha256,
                i64::from(record.install_after_download),
                now,
                row_id,
            ],
        ),
        None => conn.execute(
            "INSERT INTO download_task (
                module_task_id, dedup_key, app_id, app_name, version, file_name, kind,
                resource_id, resource_version, url, dest_path, status, bytes_done, total,
                speed_bps, eta_sec, last_started_at, expected_sha256, install_after_download,
                created_at, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
                       ?16, ?17, ?18, ?19, ?20, ?20)",
            params,
        ),
    }
    .map(|_| ())
    .map_err(|e| PortError::Db(format!("upsert task {}: {e}", record.module_task_id)))
}

fn existing_row_id(conn: &Connection, column: &str, value: &str) -> Result<Option<i64>, PortError> {
    let sql = format!("SELECT id FROM download_task WHERE {column} = ?1");
    conn.query_row(&sql, [value], |row| row.get(0))
        .optional()
        .map_err(|e| PortError::Db(format!("lookup {column}={value}: {e}")))
}

fn query_rows(conn: &Connection) -> Result<Vec<DownloadTaskRow>, PortError> {
    let mut stmt = conn
        .prepare(&format!(
            "SELECT {} FROM download_task ORDER BY id",
            crate::download::ROW_COLUMNS
        ))
        .map_err(|e| PortError::Db(format!("prepare list: {e}")))?;
    let rows = stmt
        .query_map([], crate::download::row_from_sql)
        .map_err(|e| PortError::Db(format!("query list: {e}")))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| PortError::Db(format!("read list: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct FakeBridge {
        present: Arc<Mutex<HashSet<u64>>>,
    }

    impl FakeBridge {
        fn seeded() -> Self {
            Self::default().with_task(42)
        }

        fn with_task(self, id: u64) -> Self {
            self.present.lock().unwrap().insert(id);
            self
        }

        fn drop_task(&self, id: u64) {
            self.present.lock().unwrap().remove(&id);
        }
    }

    fn task_json(id: u64) -> Value {
        json!({
            "id": id,
            "appId": "com.example.app",
            "appName": "Example",
            "version": "1.2.3",
            "fileName": "example.apk",
            "url": "https://example.test/example.apk",
            "filePath": "/tmp/example.apk",
            "status": 2,
            "received": 10,
            "total": 100,
            "speedBps": 5,
            "etaSec": 18,
            "dedupKey": "dedup:example",
            "kind": "app",
            "resourceId": "com.example.app",
            "resourceVersion": "1.2.3",
            "installAfterDownload": true
        })
    }

    impl ModuleBridge for FakeBridge {
        fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
            let body: Value =
                serde_json::from_slice(payload).map_err(|e| format!("bad payload: {e}"))?;
            match method {
                "download.start" => {
                    assert_eq!(body["dedup_key"], "dedup:example");
                    assert_eq!(body["file_path"], "/tmp/example.apk");
                    self.present.lock().unwrap().insert(42);
                    serde_json::to_vec(&task_json(42)).map_err(|e| e.to_string())
                }
                "download.get" => {
                    let id = body["id"].as_u64().ok_or("missing id")?;
                    if self.present.lock().unwrap().contains(&id) {
                        serde_json::to_vec(&task_json(id)).map_err(|e| e.to_string())
                    } else {
                        Ok(b"null".to_vec())
                    }
                }
                "download.pause"
                | "download.resume"
                | "download.cancel"
                | "download.retry"
                | "download.restart"
                | "download.remove" => Ok(br#"{"ok":true}"#.to_vec()),
                other => Err(format!("unexpected method {other}")),
            }
        }
    }

    fn port(bridge: FakeBridge) -> (ModuleDownloadPort<FakeBridge>, SharedConn) {
        port_with(bridge)
    }

    fn port_with<B: ModuleBridge>(bridge: B) -> (ModuleDownloadPort<B>, SharedConn) {
        let conn = Arc::new(Mutex::new(Connection::open_in_memory().unwrap()));
        crate::migration::apply_core_schema(&mut conn.lock().unwrap()).unwrap();
        let port = ModuleDownloadPort::new(bridge, conn.clone(), PathBuf::from("/tmp/core.db"));
        (port, conn)
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
            expected_sha256: Some("abc123".to_string()),
            install_after_download: true,
        }
    }

    #[test]
    fn download_port_contract() {
        let bridge = FakeBridge::seeded();
        let (port, conn) = port(bridge.clone());

        let id = port.start(&request()).unwrap();
        assert_eq!(id, 42);

        {
            let guard = conn.lock().unwrap();
            let row = crate::download::load_task(&guard, "42").unwrap().unwrap();
            assert_eq!(row.module_task_id.as_deref(), Some("42"));
            assert_eq!(row.dedup_key.as_deref(), Some("dedup:example"));
            assert_eq!(row.status, "running");
            assert_eq!(row.app_id.as_deref(), Some("com.example.app"));
            let stored: (String, i64, Option<String>) = guard
                .query_row(
                    "SELECT dest_path, install_after_download, expected_sha256
                     FROM download_task WHERE module_task_id = '42'",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .unwrap();
            assert_eq!(stored.0, "/tmp/example.apk");
            assert_eq!(stored.1, 1);
            assert_eq!(stored.2.as_deref(), Some("abc123"));
        }

        port.cancel("42").unwrap();
        {
            let guard = conn.lock().unwrap();
            let row = crate::download::load_task(&guard, "42").unwrap().unwrap();
            assert_eq!(row.status, "cancelled");
        }

        let unknown = port.get("999").unwrap_err();
        println!("unknown module task id 999 -> {unknown:?}");
        assert_eq!(unknown, PortError::NeedsRestart("999".to_string()));

        let bad_id = port.cancel("not-a-number").unwrap_err();
        assert!(
            matches!(bad_id, PortError::Module(ref msg) if msg.contains("invalid module task id")),
            "unexpected error: {bad_id:?}"
        );

        bridge.drop_task(42);
        let report = port.reconcile().unwrap();
        println!("reconcile after module task loss -> {report:?}");
        println!("row status -> {}", port.get("42").unwrap().status);
        assert_eq!(report.checked, 1);
        assert_eq!(report.needs_restart, vec!["42".to_string()]);
        let rows = port.snapshot().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].module_task_id.as_deref(), Some("42"));
        assert_eq!(rows[0].status, NEEDS_RESTART);
        assert_eq!(port.watch_all().unwrap(), rows);
        assert_eq!(port.db_path(), Path::new("/tmp/core.db"));
    }

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let dir = std::env::temp_dir().join(format!(
                "gstore_core_port_{}_{}_{}",
                std::process::id(),
                tag,
                n
            ));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
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

    #[derive(Clone, Default)]
    struct CountingBridge {
        calls: Arc<std::sync::atomic::AtomicUsize>,
    }

    impl ModuleBridge for CountingBridge {
        fn call(&self, method: &str, _payload: &[u8]) -> Result<Vec<u8>, String> {
            self.calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Err(format!("bridge must not be called for {method}"))
        }
    }

    #[test]
    fn download_legacy_and_reconcile_missing_module_db() {
        let dir = TempDir::new("missing_module");
        let bridge = CountingBridge::default();
        let calls = bridge.calls.clone();
        let (port, conn) = port_with(bridge);
        {
            let guard = conn.lock().unwrap();
            guard
                .execute(
                    "INSERT INTO download_task
                     (module_task_id, dedup_key, app_id, version, file_name, status, created_at, updated_at)
                     VALUES ('7', 'dedup:7', 'com.example.app', '1.0.0', 'app.apk', 'running', 1, 1)",
                    [],
                )
                .unwrap();
        }

        let missing = dir.path().join("module-db-does-not-exist.db");
        let port = port.with_module_db_path(missing);
        let report = port.reconcile().unwrap();
        println!("missing module db reconcile -> {report:?}");
        println!("bridge calls -> {}", calls.load(std::sync::atomic::Ordering::SeqCst));
        assert_eq!(report.needs_restart, vec!["7".to_string()]);
        assert_eq!(
            calls.load(std::sync::atomic::Ordering::SeqCst),
            0,
            "a missing module db must be handled without the bridge"
        );
        let rows = port.snapshot().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].status, NEEDS_RESTART);
        assert!(
            rows.iter().all(|row| row.status != "running"),
            "no stale running row may survive a lost module db"
        );
    }

    /// This test double performs the real HTTP GET only to prove the port
    /// completes a local transfer end-to-end. Production byte transfer stays in
    /// `gstore_mod_download`; the bridge here is a test fixture, not a port
    /// responsibility.
    #[test]
    fn download_legacy_and_reconcile_local_http_completes() {
        use std::io::{Read, Write};
        use std::net::{TcpListener, TcpStream};
        use std::time::Duration;

        let dir = TempDir::new("local_http");
        let dest = dir.path().join("payload.bin");

        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let addr = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            stream.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut request = Vec::new();
            let mut buffer = [0u8; 1024];
            loop {
                let read = stream.read(&mut buffer).unwrap();
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
                if request.windows(4).any(|window| window == b"\r\n\r\n") {
                    break;
                }
            }
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
                )
                .unwrap();
            stream.flush().unwrap();
        });

        struct HttpBridge {
            dest: PathBuf,
        }

        impl ModuleBridge for HttpBridge {
            fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
                if method != "download.start" {
                    return Err(format!("unexpected method {method}"));
                }
                let body: Value =
                    serde_json::from_slice(payload).map_err(|e| format!("bad payload: {e}"))?;
                let url = body["url"].as_str().ok_or("missing url")?;
                let (host_port, path) = split_http_url(url)?;

                let mut stream = TcpStream::connect(&host_port).map_err(|e| e.to_string())?;
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .map_err(|e| e.to_string())?;
                stream
                    .set_write_timeout(Some(Duration::from_secs(5)))
                    .map_err(|e| e.to_string())?;
                write!(
                    stream,
                    "GET {path} HTTP/1.1\r\nHost: {host_port}\r\nConnection: close\r\n\r\n"
                )
                .map_err(|e| e.to_string())?;
                stream.flush().map_err(|e| e.to_string())?;

                let mut response = Vec::new();
                stream
                    .read_to_end(&mut response)
                    .map_err(|e| e.to_string())?;
                let split = response
                    .windows(4)
                    .position(|window| window == b"\r\n\r\n")
                    .ok_or("response has no header terminator")?
                    + 4;
                std::fs::write(&self.dest, &response[split..]).map_err(|e| e.to_string())?;

                Ok(serde_json::json!({
                    "id": 7,
                    "status": 4,
                    "received": 5,
                    "total": 5,
                    "filePath": self.dest.to_string_lossy(),
                })
                .to_string()
                .into_bytes())
            }
        }

        fn split_http_url(url: &str) -> Result<(String, String), String> {
            let rest = url
                .strip_prefix("http://")
                .ok_or_else(|| format!("only http:// fixtures are supported: {url}"))?;
            Ok(match rest.split_once('/') {
                Some((host, path)) => (host.to_string(), format!("/{path}")),
                None => (rest.to_string(), "/".to_string()),
            })
        }

        let url = format!("http://{addr}/payload.bin");
        let dest_text = dest.to_string_lossy().to_string();
        let (port, _conn) = port_with(HttpBridge {
            dest: dest.clone(),
        });
        let mut request = request();
        request.url = url;
        request.dest_path = dest_text;
        request.dedup_key = "http:local".to_string();

        let id = port.start(&request).unwrap();
        server.join().unwrap();

        assert_eq!(id, 7);
        let rows = port.snapshot().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].status, "completed");
        assert_eq!(rows[0].dest_path.as_deref(), Some(request.dest_path.as_str()));
        assert_eq!(std::fs::read(&dest).unwrap(), b"hello");
    }
}
