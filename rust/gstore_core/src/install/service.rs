//! SQLite-backed install request/response service.
//!
//! The service owns the durable install state machine on `download_task`:
//!
//! ```text
//! none -> pending -> installed | failed | denied | timeout
//!                            \-> unknown (timeout sweep)
//! ```
//!
//! `pending` and the request payload columns are written before the request is
//! returned, so a process death cannot lose the attempt and
//! [`InstallService::pending_requests`] can rebuild it from SQL. The frontend
//! owns execution; it reports back through [`InstallService::on_result`].
//! [`InstallService::sweep_timeouts`] is read-driven — it runs inside
//! `install()` and `pending_requests()`, never on a background thread.

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;
use rusqlite::{OptionalExtension, TransactionBehavior};

use crate::db::SharedConn;
use crate::error::Error;
use crate::event::CoreEvent;
use crate::facts::{
    InstallReport, InstallReportStatus, InstallRequest, InstallResultAck, InstallStart,
    VariantChoice,
};
use crate::rules::RuleStore;

/// No install has been attempted.
pub const INSTALL_STATUS_NONE: &str = "none";
/// An install request is pending (or the frontend is executing it).
pub const INSTALL_STATUS_PENDING: &str = "pending";
/// The package is installed.
pub const INSTALL_STATUS_INSTALLED: &str = "installed";
/// The install attempt failed.
pub const INSTALL_STATUS_FAILED: &str = "failed";
/// The user rejected the install (terminal: no silent fallback).
pub const INSTALL_STATUS_DENIED: &str = "denied";
/// The install attempt reported a timeout.
pub const INSTALL_STATUS_TIMEOUT: &str = "timeout";
/// The pending attempt exhausted its timeout window or lost its session id.
pub const INSTALL_STATUS_UNKNOWN: &str = "unknown";

const APK_MISSING: &str = "CORE_E_INSTALL_APK_MISSING";
const NOT_DOWNLOADED: &str = "CORE_E_INSTALL_NOT_DOWNLOADED";
const SESSION_ERROR: &str = "CORE_E_INSTALL_SESSION";
const SESSION_MISSING: &str = "CORE_E_INSTALL_SESSION_MISSING";
const TIMEOUT_ERROR: &str = "CORE_E_INSTALL_TIMEOUT";

/// Method string persisted when the frontend has not chosen one yet.
const DEFAULT_INSTALL_METHOD: &str = "platform";

const ROW_SELECT: &str =
    "SELECT module_task_id, app_id, resource_id, app_name, version, file_name, \
     url, dest_path, status, install_status, install_method, install_session_id, install_error, \
     installed_at, installed_version, install_after_download, package_name, abi, variant_url, \
     fallback_json FROM download_task WHERE module_task_id = ?1";

const SESSION_SELECT: &str = "SELECT module_task_id, app_id, resource_id, app_name, version, \
     file_name, url, dest_path, status, install_status, install_method, install_session_id, \
     install_error, installed_at, installed_version, install_after_download, package_name, abi, \
     variant_url, fallback_json FROM download_task \
     WHERE install_session_id = ?1 ORDER BY id DESC LIMIT 1";

const PENDING_SELECT: &str = "SELECT module_task_id, app_id, resource_id, app_name, version, \
     file_name, url, dest_path, status, install_status, install_method, install_session_id, \
     install_error, installed_at, installed_version, install_after_download, package_name, abi, \
     variant_url, fallback_json FROM download_task \
     WHERE install_status = 'pending' ORDER BY id";

/// Durable install row projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallRecord {
    /// Download task id (`download_task.module_task_id`).
    pub module_task_id: String,
    /// Channel-scoped app id, empty when the legacy row has none.
    pub app_id: String,
    /// One of the `INSTALL_STATUS_*` constants.
    pub status: String,
    /// `shizuku` / `package_installer` / `intent` / `platform`.
    pub method: Option<String>,
    /// Async installer session id, persisted before the install begins.
    pub session_id: Option<String>,
    /// Last install error.
    pub error: Option<String>,
    /// Milliseconds since the Unix epoch when the install succeeded.
    pub installed_at: Option<i64>,
    /// Version name reported by the installer.
    pub installed_version: Option<String>,
    /// Whether the row requests automatic install after download.
    pub install_after_download: bool,
}

#[derive(Debug, Clone)]
struct TaskRow {
    module_task_id: String,
    app_id: String,
    resource_id: Option<String>,
    version_name: Option<String>,
    file_name: Option<String>,
    url: Option<String>,
    dest_path: Option<String>,
    download_status: String,
    install_status: String,
    install_method: Option<String>,
    install_session_id: Option<String>,
    install_error: Option<String>,
    installed_at: Option<i64>,
    installed_version: Option<String>,
    install_after_download: bool,
    package_name: Option<String>,
    abi: Option<String>,
    variant_url: Option<String>,
    fallback_json: Option<String>,
}

impl TaskRow {
    fn into_record(self) -> InstallRecord {
        InstallRecord {
            module_task_id: self.module_task_id,
            app_id: self.app_id,
            status: self.install_status,
            method: self.install_method,
            session_id: self.install_session_id,
            error: self.install_error,
            installed_at: self.installed_at,
            installed_version: self.installed_version,
            install_after_download: self.install_after_download,
        }
    }
}

fn row_from_sql(row: &rusqlite::Row<'_>) -> rusqlite::Result<TaskRow> {
    Ok(TaskRow {
        module_task_id: row.get(0)?,
        app_id: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
        resource_id: row.get(2)?,
        version_name: row.get(4)?,
        file_name: row.get(5)?,
        url: row.get(6)?,
        dest_path: row.get(7)?,
        download_status: row.get(8)?,
        install_status: row.get(9)?,
        install_method: row.get(10)?,
        install_session_id: row.get(11)?,
        install_error: row.get(12)?,
        installed_at: row.get(13)?,
        installed_version: row.get(14)?,
        install_after_download: row.get::<_, i64>(15)? != 0,
        package_name: row.get(16)?,
        abi: row.get(17)?,
        variant_url: row.get(18)?,
        fallback_json: row.get(19)?,
    })
}

fn system_now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as i64)
}

fn make_session_id(module_task_id: &str, now: i64) -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let counter = COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("{module_task_id}:{now}:{}:{counter}", std::process::id())
}

fn terminal_fields(
    status: &str,
    version_name: Option<&str>,
    error: Option<&str>,
    now: i64,
) -> (Option<i64>, Option<String>, Option<String>) {
    if status == INSTALL_STATUS_INSTALLED {
        (Some(now), version_name.map(str::to_string), None)
    } else {
        (None, None, error.map(str::to_string))
    }
}

fn non_empty(value: &Option<String>) -> Option<String> {
    value
        .as_ref()
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
}

fn infer_abi(file_name: &str, priority: &[String]) -> String {
    let lower = file_name.to_lowercase();
    priority
        .iter()
        .find(|abi| lower.contains(&abi.to_lowercase()))
        .cloned()
        .unwrap_or_default()
}

fn parse_fallback(raw: Option<&str>) -> Vec<String> {
    raw.filter(|json| !json.trim().is_empty())
        .and_then(|json| serde_json::from_str::<Vec<String>>(json).ok())
        .unwrap_or_default()
}

fn rebuild_request(row: &TaskRow) -> Option<InstallRequest> {
    let session_id = non_empty(&row.install_session_id)?;
    let url = non_empty(&row.variant_url)
        .or_else(|| non_empty(&row.url))
        .unwrap_or_default();
    Some(InstallRequest {
        module_task_id: row.module_task_id.clone(),
        session_id,
        package_name: non_empty(&row.package_name)
            .or_else(|| non_empty(&row.resource_id))
            .unwrap_or_else(|| row.app_id.clone()),
        version_name: row.version_name.clone().unwrap_or_default(),
        apk_path: row.dest_path.clone().unwrap_or_default(),
        method: non_empty(&row.install_method)
            .unwrap_or_else(|| DEFAULT_INSTALL_METHOD.to_string()),
        variant: VariantChoice {
            abi: row.abi.clone().unwrap_or_default(),
            url,
            fallback_chain: parse_fallback(row.fallback_json.as_deref()),
        },
    })
}

/// Durable install service over the core database.
pub struct InstallService {
    conn: SharedConn,
    rules: RuleStore,
    events: Mutex<Vec<CoreEvent>>,
    clock: Arc<dyn Fn() -> i64 + Send + Sync>,
}

impl InstallService {
    /// Creates a service over `conn` using wall-clock time.
    pub fn new(conn: SharedConn) -> Self {
        Self::with_clock(conn, Arc::new(system_now_millis))
    }

    /// Creates a service with an injectable millisecond clock.
    pub fn with_clock(conn: SharedConn, clock: Arc<dyn Fn() -> i64 + Send + Sync>) -> Self {
        Self {
            rules: RuleStore::from_shared(conn.clone()),
            conn,
            events: Mutex::new(Vec::new()),
            clock,
        }
    }

    fn lock(&self) -> Result<MutexGuard<'_, Connection>, Error> {
        self.conn
            .lock()
            .map_err(|_| Error::Internal("install db mutex poisoned".to_string()))
    }

    fn push_events(&self, events: &[CoreEvent]) {
        if events.is_empty() {
            return;
        }
        self.events
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .extend(events.iter().cloned());
    }

    /// Drains queued `install.requested` / `install.unknown` events.
    pub fn take_events(&self) -> Vec<CoreEvent> {
        std::mem::take(
            &mut *self
                .events
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()),
        )
    }

    fn load(conn: &Connection, module_task_id: &str) -> Result<Option<TaskRow>, Error> {
        conn.query_row(ROW_SELECT, [module_task_id], row_from_sql)
            .optional()
            .map_err(|e| {
                Error::Internal(format!("CORE_E_INSTALL_READ: load {module_task_id}: {e}"))
            })
    }

    fn load_by_session(conn: &Connection, session_id: &str) -> Result<Option<TaskRow>, Error> {
        conn.query_row(SESSION_SELECT, [session_id], row_from_sql)
            .optional()
            .map_err(|e| {
                Error::Internal(format!(
                    "CORE_E_INSTALL_READ: load session {session_id}: {e}"
                ))
            })
    }

    fn required(conn: &Connection, module_task_id: &str) -> Result<TaskRow, Error> {
        Self::load(conn, module_task_id)?
            .ok_or_else(|| Error::NotFound(format!("install task not found: {module_task_id}")))
    }

    /// Starts (or observes) an install for `module_task_id`.
    ///
    /// Idempotent: an `installed` row returns no request; a `pending` row
    /// returns its rebuilt request without a second event; a retryable row
    /// (`none|failed|denied|timeout|unknown`) starts a new session.
    ///
    /// # Errors
    /// - [`Error::NotFound`] when the download task does not exist.
    /// - [`Error::InvalidArgument`] when `dest_path` is empty or not a file.
    /// - [`Error::Conflict`] when the download is not `completed`.
    /// - [`Error::Internal`] when a durable write fails.
    pub fn install(&self, module_task_id: &str) -> Result<InstallStart, Error> {
        let now = (self.clock)();
        self.sweep_timeouts(now)?;

        let row = {
            let guard = self.lock()?;
            Self::required(&guard, module_task_id)?
        };

        if row.install_status == INSTALL_STATUS_INSTALLED {
            return Ok(InstallStart {
                record: row.into_record(),
                request: None,
            });
        }
        if row.install_status == INSTALL_STATUS_PENDING {
            let request = rebuild_request(&row);
            return Ok(InstallStart {
                record: row.into_record(),
                request,
            });
        }

        let dest_path = row.dest_path.clone().unwrap_or_default();
        if dest_path.trim().is_empty() || !Path::new(&dest_path).is_file() {
            return Err(Error::InvalidArgument(format!(
                "{APK_MISSING}: {}",
                if dest_path.trim().is_empty() {
                    "<empty dest_path>"
                } else {
                    dest_path.as_str()
                }
            )));
        }
        if row.download_status != "completed" {
            return Err(Error::Conflict(format!(
                "{NOT_DOWNLOADED}: {} is {}",
                module_task_id, row.download_status
            )));
        }

        let rules = self.rules.effective_install()?;
        let file_name = non_empty(&row.file_name).unwrap_or_else(|| {
            Path::new(&dest_path)
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default()
        });
        let package_name = non_empty(&row.package_name)
            .or_else(|| non_empty(&row.resource_id))
            .unwrap_or_else(|| row.app_id.clone());
        let abi = non_empty(&row.abi).unwrap_or_else(|| infer_abi(&file_name, &rules.abi_priority));
        let variant_url = non_empty(&row.variant_url)
            .or_else(|| non_empty(&row.url))
            .unwrap_or_default();
        let fallback_json = non_empty(&row.fallback_json).unwrap_or_else(|| {
            serde_json::to_string(&vec![variant_url.clone()]).unwrap_or_else(|_| "[]".to_string())
        });

        let session = make_session_id(module_task_id, now);
        let claimed = {
            let guard = self.lock()?;
            guard
                .execute(
                    "UPDATE download_task SET install_status = 'pending', \
                         install_session_id = ?1, install_requested_at = ?2, install_method = ?3, \
                         package_name = ?4, abi = ?5, variant_url = ?6, fallback_json = ?7, \
                         install_error = NULL, installed_at = NULL, installed_version = NULL, \
                         updated_at = ?2 \
                     WHERE module_task_id = ?8 \
                       AND install_status IN ('none', 'failed', 'denied', 'timeout', 'unknown')",
                    rusqlite::params![
                        session,
                        now,
                        DEFAULT_INSTALL_METHOD,
                        package_name,
                        abi,
                        variant_url,
                        fallback_json,
                        module_task_id
                    ],
                )
                .map_err(|e| {
                    Error::Internal(format!("CORE_E_INSTALL_WRITE: claim {module_task_id}: {e}"))
                })?
        };

        let row = {
            let guard = self.lock()?;
            Self::required(&guard, module_task_id)?
        };
        let request = if row.install_status == INSTALL_STATUS_INSTALLED {
            None
        } else {
            rebuild_request(&row)
        };
        if claimed > 0 {
            if let Some(request) = request.clone() {
                self.push_events(&[CoreEvent::InstallRequested { request }]);
            }
        }
        Ok(InstallStart {
            record: row.into_record(),
            request,
        })
    }

    /// Applies an install result reported by the frontend.
    ///
    /// Only a `pending` or `unknown` row transitions; a duplicate or late report
    /// on a terminal row returns `changed: false` and mutates nothing.
    ///
    /// # Errors
    /// - [`Error::InvalidArgument`] for an empty session id.
    /// - [`Error::NotFound`] when no row carries `report.session_id`.
    pub fn on_result(&self, report: InstallReport) -> Result<InstallResultAck, Error> {
        let session_id = report.session_id;
        if session_id.trim().is_empty() {
            return Err(Error::InvalidArgument(format!(
                "{SESSION_ERROR}: session id must not be empty"
            )));
        }
        let status = match report.status {
            InstallReportStatus::Installed => INSTALL_STATUS_INSTALLED,
            InstallReportStatus::Failed => INSTALL_STATUS_FAILED,
            InstallReportStatus::Denied => INSTALL_STATUS_DENIED,
            InstallReportStatus::Timeout => INSTALL_STATUS_TIMEOUT,
        };
        let now = (self.clock)();
        let guard = self.lock()?;
        let Some(row) = Self::load_by_session(&guard, &session_id)? else {
            return Err(Error::NotFound(format!(
                "{SESSION_ERROR}: install session not found: {session_id}"
            )));
        };
        if row.install_status != INSTALL_STATUS_PENDING
            && row.install_status != INSTALL_STATUS_UNKNOWN
        {
            return Ok(InstallResultAck {
                session_id,
                status: row.install_status,
                changed: false,
            });
        }

        let (installed_at, installed_version, install_error) = terminal_fields(
            status,
            report.installed_version.as_deref(),
            report.error.as_deref(),
            now,
        );
        let method = non_empty(&Some(report.method));
        let changed = guard
            .execute(
                "UPDATE download_task SET install_status = ?1, installed_at = ?2, \
                     installed_version = ?3, install_error = ?4, updated_at = ?5, \
                     install_method = COALESCE(?6, install_method) \
                 WHERE install_session_id = ?7 \
                   AND install_status IN ('pending', 'unknown')",
                rusqlite::params![
                    status,
                    installed_at,
                    installed_version,
                    install_error,
                    now,
                    method,
                    &session_id
                ],
            )
            .map_err(|e| {
                Error::Internal(format!("CORE_E_INSTALL_WRITE: result {session_id}: {e}"))
            })?;
        if changed == 0 {
            let current = Self::load_by_session(&guard, &session_id)?.ok_or_else(|| {
                Error::NotFound(format!(
                    "{SESSION_ERROR}: install session not found: {session_id}"
                ))
            })?;
            return Ok(InstallResultAck {
                session_id,
                status: current.install_status,
                changed: false,
            });
        }
        Ok(InstallResultAck {
            session_id,
            status: status.to_string(),
            changed: true,
        })
    }

    /// Moves expired or session-less `pending` rows to `unknown`.
    ///
    /// A row expires when `install_requested_at` is missing or older than
    /// `InstallRules::timeout_secs` at `now`. Every transitioned row queues a
    /// [`CoreEvent::InstallUnknown`]; the same events are returned so a direct
    /// caller does not have to drain the queue.
    ///
    /// # Errors
    /// Propagates database failures.
    pub fn sweep_timeouts(&self, now: i64) -> Result<Vec<CoreEvent>, Error> {
        let timeout_ms = self
            .rules
            .effective_install()?
            .timeout_secs
            .saturating_mul(1_000);
        let mut guard = self.lock()?;
        let tx = guard
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;

        let pending: Vec<(String, Option<String>, Option<i64>)> = {
            let mut stmt = tx
                .prepare(
                    "SELECT module_task_id, install_session_id, install_requested_at \
                     FROM download_task WHERE install_status = 'pending' ORDER BY id",
                )
                .map_err(sql_error)?;
            let rows = stmt
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
                .map_err(sql_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sql_error)?;
            rows
        };

        let mut events = Vec::new();
        for (module_task_id, session, requested_at) in pending {
            let session_missing = session
                .as_deref()
                .map(|text| text.trim().is_empty())
                .unwrap_or(true);
            let requested_at = requested_at.unwrap_or(0);
            let expired = requested_at <= 0 || now.saturating_sub(requested_at) > timeout_ms;
            if !session_missing && !expired {
                continue;
            }
            let reason = if session_missing {
                SESSION_MISSING
            } else {
                TIMEOUT_ERROR
            };
            let changed = tx
                .execute(
                    "UPDATE download_task SET install_status = 'unknown', install_error = ?1, \
                         updated_at = ?2 \
                     WHERE module_task_id = ?3 AND install_status = 'pending'",
                    rusqlite::params![reason, now, module_task_id],
                )
                .map_err(sql_error)?;
            if changed > 0 {
                events.push(CoreEvent::InstallUnknown {
                    session_id: session.unwrap_or_default(),
                    module_task_id: Some(module_task_id),
                });
            }
        }
        tx.commit().map_err(sql_error)?;
        self.push_events(&events);
        Ok(events)
    }

    /// Lists every still-pending request after sweeping expired rows.
    ///
    /// # Errors
    /// Propagates database failures.
    pub fn pending_requests(&self) -> Result<Vec<InstallStart>, Error> {
        self.sweep_timeouts((self.clock)())?;
        let guard = self.lock()?;
        let mut stmt = guard.prepare(PENDING_SELECT).map_err(sql_error)?;
        let rows = stmt
            .query_map([], row_from_sql)
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)?;
        let mut starts = Vec::with_capacity(rows.len());
        for row in rows {
            let request = rebuild_request(&row);
            if request.is_some() {
                starts.push(InstallStart {
                    record: row.into_record(),
                    request,
                });
            }
        }
        Ok(starts)
    }

    /// Installs exactly once after a completed download when requested.
    ///
    /// Returns `Ok(None)` when the row is not completed, did not request
    /// auto-install, or already left the `none` install state.
    ///
    /// # Errors
    /// Propagates [`InstallService::install`] errors.
    pub fn maybe_install_after_download(
        &self,
        module_task_id: &str,
    ) -> Result<Option<InstallStart>, Error> {
        {
            let guard = self.lock()?;
            let row = Self::required(&guard, module_task_id)?;
            if row.download_status != "completed"
                || !row.install_after_download
                || row.install_status != INSTALL_STATUS_NONE
            {
                return Ok(None);
            }
        }
        self.install(module_task_id).map(Some)
    }

    /// Reads the durable install record for `module_task_id`.
    ///
    /// # Errors
    /// [`Error::NotFound`] when the task does not exist.
    pub fn get(&self, module_task_id: &str) -> Result<InstallRecord, Error> {
        let guard = self.lock()?;
        Ok(Self::required(&guard, module_task_id)?.into_record())
    }
}

fn sql_error(error: rusqlite::Error) -> Error {
    Error::Io(error.to_string())
}
