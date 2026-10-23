//! Host adapter for [`gstore_core::download::port::DownloadPort`].
//!
//! The download module is mounted by Dart through [`crate::manager::ModuleManager`];
//! this adapter only routes method calls through the already-registered instance
//! (no new C ABI, no link from the module cdylib into `gstore_core`). The
//! instance is created lazily on first use so `CoreApi::init` performs no module
//! I/O beyond the one best-effort reconcile sweep.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use gstore_core::db::SharedConn;
use gstore_core::download::legacy::{migrate_legacy_floor_db, migrate_module_db, MigrationReport};
use gstore_core::download::port::{
    DownloadPort, DownloadRequest, ModuleBridge, ModuleDownloadPort, PortError, ReconcileReport,
};
use gstore_core::download::resync::ResyncReport;
use gstore_core::download::DownloadTaskRow;

use crate::bridge::DownloadTaskDto;

/// `ModuleBridge` that dispatches to the global module manager.
#[derive(Debug, Clone, Copy)]
pub struct HostModuleBridge {
    module_id: u64,
    instance_id: u64,
}

impl HostModuleBridge {
    pub fn new(module_id: u64, instance_id: u64) -> Self {
        Self {
            module_id,
            instance_id,
        }
    }
}

impl ModuleBridge for HostModuleBridge {
    fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        crate::manager::ModuleManager::global()
            .call(self.module_id, Some(self.instance_id), method, payload)
            .map_err(|error| format!("download module {method}: {error}"))
    }
}

/// Bridge used only when the module database is provably gone.
///
/// `ModuleDownloadPort::reconcile` short-circuits to `needs_restart` before
/// touching the bridge in that case, so this type must never be called.
#[derive(Debug, Clone, Copy)]
struct UnavailableBridge;

impl ModuleBridge for UnavailableBridge {
    fn call(&self, method: &str, _payload: &[u8]) -> Result<Vec<u8>, String> {
        Err(format!(
            "download module is unavailable; refusing to call {method}"
        ))
    }
}

enum PortSlot {
    Host(ModuleDownloadPort<HostModuleBridge>),
    Injected(Box<dyn DownloadPort + Send + Sync>),
}

/// Combined outcome of the one-shot legacy import.
///
/// A missing database is not an error: it is skipped and its path is recorded
/// in [`Self::skipped_missing`], so a fresh install (or a device that never
/// used one of the two legacy engines) still imports whatever exists.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LegacyImportReport {
    pub floor: Option<MigrationReport>,
    pub module: Option<MigrationReport>,
    pub skipped_missing: Vec<String>,
}

/// Result of the last reconcile attempt (kept observable for tests and Todo 2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReconcileOutcome {
    Ok(ReconcileReport),
    Err(String),
}

/// Bridge-free reader over the authoritative core `download_task` table.
///
/// The watch thread owns one of these, so a snapshot never needs a mounted
/// module and never touches global module state.
#[derive(Clone)]
pub struct CoreTaskReader {
    conn: SharedConn,
}

impl CoreTaskReader {
    pub fn new(conn: SharedConn) -> Self {
        Self { conn }
    }

    pub fn list(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        let conn = self
            .conn
            .lock()
            .map_err(|_| PortError::Db("download core connection mutex poisoned".to_string()))?;
        gstore_core::download::list_tasks(&conn).map_err(|e| PortError::Db(e.to_string()))
    }

    pub fn get(&self, module_task_id: &str) -> Result<Option<DownloadTaskRow>, PortError> {
        let conn = self
            .conn
            .lock()
            .map_err(|_| PortError::Db("download core connection mutex poisoned".to_string()))?;
        gstore_core::download::load_task(&conn, module_task_id)
            .map_err(|e| PortError::Db(e.to_string()))
    }
}

const TERMINAL_STATUSES: [&str; 5] = [
    "completed",
    "failed",
    "cancelled",
    "removed",
    "needs_restart",
];

fn is_present(path: &Path) -> bool {
    !path.as_os_str().is_empty() && path.exists()
}

fn record_missing(report: &mut LegacyImportReport, path: &Path) {
    if !path.as_os_str().is_empty() {
        report.skipped_missing.push(path.display().to_string());
    }
}

fn is_terminal_status(status: &str) -> bool {
    TERMINAL_STATUSES.contains(&status)
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct WatchEntry {
    projection: String,
    terminal: bool,
}

/// Change detector behind `DownloadApi::watch_all`.
///
/// Contract: a row is emitted only when its full projection changes; a terminal
/// row is emitted exactly once and never again, while later tasks are still
/// emitted. In other words, "terminal" is a per-task terminal event and the
/// stream remains open for tasks that appear afterwards.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DownloadWatchState {
    last: HashMap<i64, WatchEntry>,
}

impl DownloadWatchState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn observe(&mut self, rows: Vec<DownloadTaskRow>) -> Vec<DownloadTaskDto> {
        let mut emitted = Vec::new();
        for row in rows {
            let dto = DownloadTaskDto::from(row);
            let projection = format!("{dto:?}");
            let terminal = is_terminal_status(&dto.status);
            match self.last.get(&dto.id) {
                Some(entry) if entry.projection == projection => continue,
                Some(entry) if entry.terminal => continue,
                _ => {}
            }
            self.last.insert(
                dto.id,
                WatchEntry {
                    projection,
                    terminal,
                },
            );
            emitted.push(dto);
        }
        emitted
    }
}

/// [`DownloadPort`] facade that lazily binds the core port to the mounted
/// `download` module.
pub struct HostDownloadPort {
    conn: SharedConn,
    core_db_path: PathBuf,
    data_dir: PathBuf,
    cache_dir: PathBuf,
    module_db_path: Option<PathBuf>,
    slot: Mutex<Option<PortSlot>>,
    last_reconcile: Mutex<Option<ReconcileOutcome>>,
}

impl HostDownloadPort {
    /// Production constructor. Module paths follow the Dart
    /// `ModuleContext.forModule` convention: `<data_dir>/gstore_mods/download`
    /// and `<cache_dir>/gstore_mods/download`, with an explicit
    /// `<data_dir>/gstore_mods/download/download.db` so reconcile reads exactly
    /// the database the module was told to create.
    pub fn new(
        conn: SharedConn,
        core_db_path: PathBuf,
        data_dir: PathBuf,
        cache_dir: PathBuf,
    ) -> Self {
        let module_data_dir = data_dir.join("gstore_mods").join("download");
        let module_cache_dir = cache_dir.join("gstore_mods").join("download");
        let module_db_path = module_data_dir.join("download.db");
        Self {
            conn,
            core_db_path,
            data_dir: module_data_dir,
            cache_dir: module_cache_dir,
            module_db_path: Some(module_db_path),
            slot: Mutex::new(None),
            last_reconcile: Mutex::new(None),
        }
    }

    /// Injects a pre-built bridge so tests never touch global module state.
    pub fn with_bridge_for_test<B: ModuleBridge + 'static>(
        bridge: B,
        conn: SharedConn,
        core_db_path: PathBuf,
        module_db_path: Option<PathBuf>,
    ) -> Self {
        let mut inner = ModuleDownloadPort::new(bridge, conn.clone(), core_db_path.clone());
        if let Some(path) = &module_db_path {
            inner = inner.with_module_db_path(path.clone());
        }
        Self {
            conn,
            core_db_path,
            data_dir: PathBuf::new(),
            cache_dir: PathBuf::new(),
            module_db_path,
            slot: Mutex::new(Some(PortSlot::Injected(Box::new(inner)))),
            last_reconcile: Mutex::new(None),
        }
    }

    fn with_port<T>(
        &self,
        f: impl FnOnce(&dyn DownloadPort) -> Result<T, PortError>,
    ) -> Result<T, PortError> {
        let mut guard = self
            .slot
            .lock()
            .map_err(|_| PortError::Module("download port lock poisoned".to_string()))?;
        if guard.is_none() {
            let manager = crate::manager::ModuleManager::global();
            let module_id = manager.module_id_by_name("download").ok_or_else(|| {
                PortError::Module(
                    "download module is not mounted (download unavailable until it is)"
                        .to_string(),
                )
            })?;
            let config = serde_json::json!({
                "data_dir": self.data_dir.to_string_lossy(),
                "cache_dir": self.cache_dir.to_string_lossy(),
                "db_path": self
                    .module_db_path
                    .as_ref()
                    .map(|path| path.to_string_lossy().into_owned())
                    .unwrap_or_default(),
            });
            let bytes = serde_json::to_vec(&config)
                .map_err(|error| PortError::Module(format!("download create config: {error}")))?;
            let instance_id = manager
                .call_create(module_id, &bytes)
                .map_err(|error| PortError::Module(format!("download module create: {error}")))?;
            let mut inner = ModuleDownloadPort::new(
                HostModuleBridge::new(module_id, instance_id),
                self.conn.clone(),
                self.core_db_path.clone(),
            );
            if let Some(path) = &self.module_db_path {
                inner = inner.with_module_db_path(path.clone());
            }
            *guard = Some(PortSlot::Host(inner));
        }
        match guard.as_ref() {
            Some(PortSlot::Host(port)) => f(port),
            Some(PortSlot::Injected(port)) => f(port.as_ref()),
            None => Err(PortError::Module(
                "download port was not initialized".to_string(),
            )),
        }
    }

    fn reconcile_inner(&self) -> Result<ReconcileReport, PortError> {
        if let Some(path) = &self.module_db_path {
            if !path.exists() {
                let fallback = ModuleDownloadPort::new(
                    UnavailableBridge,
                    self.conn.clone(),
                    self.core_db_path.clone(),
                )
                .with_module_db_path(path.clone());
                return fallback.reconcile();
            }
        }
        self.with_port(|port| port.reconcile())
    }

    /// Runs one reconciliation sweep and records its outcome.
    pub fn reconcile(&self) -> Result<ReconcileReport, PortError> {
        let result = self.reconcile_inner();
        let outcome = match &result {
            Ok(report) => ReconcileOutcome::Ok(report.clone()),
            Err(error) => ReconcileOutcome::Err(error.to_string()),
        };
        let mut last = self
            .last_reconcile
            .lock()
            .map_err(|_| PortError::Module("download reconcile state lock poisoned".to_string()))?;
        *last = Some(outcome);
        result
    }

    /// Last recorded reconcile outcome, including a non-fatal init failure.
    pub fn last_reconcile(&self) -> Option<ReconcileOutcome> {
        self.last_reconcile
            .lock()
            .map(|guard| guard.clone())
            .unwrap_or(None)
    }

    /// Imports the legacy Floor (`download_task.db`) and download-module
    /// databases into the shared core `download_task` table.
    ///
    /// Both sources are optional. A non-empty path that does not exist is
    /// skipped and recorded in [`LegacyImportReport::skipped_missing`]; an
    /// empty path is treated as "not provided". Only real I/O/schema failures
    /// surface as [`PortError`]. The migration itself is idempotent and always
    /// keeps the core row authoritative.
    pub fn import_legacy(
        &self,
        floor_db_path: &Path,
        module_db_path: &Path,
    ) -> Result<LegacyImportReport, PortError> {
        let mut report = LegacyImportReport::default();
        let conn = self
            .conn
            .lock()
            .map_err(|_| PortError::Db("download core connection mutex poisoned".to_string()))?;

        if is_present(floor_db_path) {
            report.floor = Some(migrate_legacy_floor_db(&conn, floor_db_path)?);
        } else {
            record_missing(&mut report, floor_db_path);
        }

        if is_present(module_db_path) {
            report.module = Some(migrate_module_db(&conn, module_db_path)?);
        } else {
            record_missing(&mut report, module_db_path);
        }

        Ok(report)
    }

    pub fn db_path(&self) -> &Path {
        &self.core_db_path
    }

    /// Path of the download module's own SQLite database.
    ///
    /// Empty when the port was built without one; consumers treat an empty
    /// path as absent (`is_present`).
    pub fn module_db_path(&self) -> &Path {
        self.module_db_path.as_deref().unwrap_or(Path::new(""))
    }

    /// Three-way Floor ↔ module ↔ core resync (dry-run or apply).
    ///
    /// Runs bridge-free: the module database is read directly, so an unmounted
    /// module never blocks the report. See
    /// [`gstore_core::download::resync::run`] for the exact parity/conflict
    /// semantics and the read-only dry-run guarantee.
    pub fn resync_downloads(
        &self,
        apply: bool,
        floor_db_path: Option<&Path>,
        files_dir: &Path,
    ) -> Result<ResyncReport, PortError> {
        let mut inner = ModuleDownloadPort::new(
            UnavailableBridge,
            self.conn.clone(),
            self.core_db_path.clone(),
        );
        if let Some(path) = &self.module_db_path {
            inner = inner.with_module_db_path(path.clone());
        }
        inner.resync(apply, floor_db_path, files_dir)
    }

    /// Creates a bridge-free core reader (used by the FRB watch thread).
    pub fn core_reader(&self) -> CoreTaskReader {
        CoreTaskReader::new(self.conn.clone())
    }

    /// Lists the authoritative core rows without requiring a mounted module.
    pub fn list_core(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        self.core_reader().list()
    }

    /// Best-effort module refresh, then a bridge-free core read.
    ///
    /// Live module progress is only reflected in `download_task` after a
    /// reconcile sweep, so every list/watch tick must refresh first. A module
    /// failure (not mounted, transient bridge error, missing module DB) is
    /// logged and never hides the authoritative core rows.
    pub fn refresh_and_list(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        if let Err(error) = self.reconcile() {
            crate::log_bridge::push_host_log(
                2,
                format!("download reconcile (best-effort) failed: {error}"),
            );
        }
        self.list_core()
    }

    pub fn start(&self, req: &DownloadRequest) -> Result<i64, PortError> {
        self.with_port(|port| port.start(req))
    }

    pub fn list(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        self.refresh_and_list()
    }

    pub fn get(&self, module_task_id: &str) -> Result<DownloadTaskRow, PortError> {
        if let Some(row) = self.core_reader().get(module_task_id)? {
            return Ok(row);
        }
        self.with_port(|port| port.get(module_task_id))
    }

    pub fn pause(&self, id: &str) -> Result<(), PortError> {
        self.with_port(|port| port.pause(id))
    }

    pub fn resume(&self, id: &str) -> Result<(), PortError> {
        self.with_port(|port| port.resume(id))
    }

    pub fn cancel(&self, id: &str) -> Result<(), PortError> {
        self.with_port(|port| port.cancel(id))
    }

    pub fn retry(&self, id: &str) -> Result<(), PortError> {
        self.with_port(|port| port.retry(id))
    }

    pub fn restart(&self, id: &str) -> Result<(), PortError> {
        self.with_port(|port| port.restart(id))
    }

    pub fn remove(&self, id: &str) -> Result<(), PortError> {
        self.with_port(|port| port.remove(id))
    }

    pub fn snapshot(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        self.list_core()
    }

    pub fn watch_all(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        self.refresh_and_list()
    }
}
