//! Host adapter for [`gstore_core::download::port::DownloadPort`].
//!
//! The download module is mounted by Dart through [`crate::manager::ModuleManager`];
//! this adapter only routes method calls through the already-registered instance
//! (no new C ABI, no link from the module cdylib into `gstore_core`). The
//! instance is created lazily on first use so `CoreApi::init` performs no module
//! I/O beyond the one best-effort reconcile sweep.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use gstore_core::db::SharedConn;
use gstore_core::download::port::{
    DownloadPort, DownloadRequest, ModuleBridge, ModuleDownloadPort, PortError, ReconcileReport,
};
use gstore_core::download::DownloadTaskRow;

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

/// Result of the last reconcile attempt (kept observable for tests and Todo 2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReconcileOutcome {
    Ok(ReconcileReport),
    Err(String),
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

    pub fn db_path(&self) -> &Path {
        &self.core_db_path
    }

    pub fn start(&self, req: &DownloadRequest) -> Result<i64, PortError> {
        self.with_port(|port| port.start(req))
    }

    pub fn list(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        self.with_port(|port| port.list())
    }

    pub fn get(&self, module_task_id: &str) -> Result<DownloadTaskRow, PortError> {
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
        self.with_port(|port| port.snapshot())
    }

    pub fn watch_all(&self) -> Result<Vec<DownloadTaskRow>, PortError> {
        self.with_port(|port| port.watch_all())
    }
}
