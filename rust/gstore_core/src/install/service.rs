//! SQLite-backed install service.
//!
//! The service owns the durable install state machine on `download_task`:
//!
//! ```text
//! none -> pending -> installed | failed | denied | timeout
//! ```
//!
//! `pending` is written before the installer is asked to start, so a process
//! death cannot lose the attempt. Reconciliation polls the installer for the
//! persisted session id; an install is claimed with a single atomic `UPDATE`
//! so `install_after_download` can never start two installs.

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension};

use crate::db::SharedConn;
use crate::error::Error;
use crate::event::CoreEvent;
use crate::ports::installer::{InstallOutcome, InstallerPort};

/// No install has been attempted.
pub const INSTALL_STATUS_NONE: &str = "none";
/// An install attempt is in flight (or awaiting reconciliation).
pub const INSTALL_STATUS_PENDING: &str = "pending";
/// The package is installed.
pub const INSTALL_STATUS_INSTALLED: &str = "installed";
/// The install attempt failed.
pub const INSTALL_STATUS_FAILED: &str = "failed";
/// The user rejected the install (terminal: no silent fallback).
pub const INSTALL_STATUS_DENIED: &str = "denied";
/// The install attempt timed out.
pub const INSTALL_STATUS_TIMEOUT: &str = "timeout";
/// The pending attempt lost its session id and cannot be reconciled.
pub const INSTALL_STATUS_UNKNOWN: &str = "unknown";

const APK_MISSING: &str = "CORE_E_INSTALL_APK_MISSING";
const NOT_DOWNLOADED: &str = "CORE_E_INSTALL_NOT_DOWNLOADED";
const UNSUPPORTED: &str = "CORE_E_INSTALL_UNSUPPORTED";
const SESSION_MISSING: &str = "CORE_E_INSTALL_SESSION_MISSING";

const ROW_SELECT: &str = "SELECT module_task_id, app_id, dest_path, status, install_status, \
     install_method, install_session_id, install_error, installed_at, installed_version, \
     install_after_download FROM download_task WHERE module_task_id = ?1";

const SESSION_SELECT: &str = "SELECT module_task_id, app_id, dest_path, status, install_status, \
     install_method, install_session_id, install_error, installed_at, installed_version, \
     install_after_download FROM download_task WHERE install_session_id = ?1 \
     ORDER BY id DESC LIMIT 1";

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

/// Result of one install attempt.
#[derive(Debug, Clone, PartialEq)]
pub struct InstallAttempt {
    /// Current durable record.
    pub record: InstallRecord,
    /// Exactly one event when this call produced a terminal result.
    pub event: Option<CoreEvent>,
}

/// Summary of one reconciliation sweep.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct InstallReconcileReport {
    /// Pending rows examined.
    pub checked: usize,
    /// Rows that reached a terminal (or `unknown`) state.
    pub resolved: usize,
    /// Rows that remain pending.
    pub still_pending: usize,
}

#[derive(Debug, Clone)]
struct TaskRow {
    module_task_id: String,
    app_id: String,
    dest_path: Option<String>,
    download_status: String,
    install_status: String,
    install_method: Option<String>,
    install_session_id: Option<String>,
    install_error: Option<String>,
    installed_at: Option<i64>,
    installed_version: Option<String>,
    install_after_download: bool,
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
        dest_path: row.get(2)?,
        download_status: row.get(3)?,
        install_status: row.get(4)?,
        install_method: row.get(5)?,
        install_session_id: row.get(6)?,
        install_error: row.get(7)?,
        installed_at: row.get(8)?,
        installed_version: row.get(9)?,
        install_after_download: row.get::<_, i64>(10)? != 0,
    })
}

fn now_ms() -> Result<i64, Error> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| Error::Internal(format!("install clock: {e}")))?;
    i64::try_from(elapsed.as_millis())
        .map_err(|_| Error::Internal("install clock overflow".to_string()))
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

fn install_event(
    row: &TaskRow,
    success: bool,
    package_name: Option<&str>,
    message: Option<&str>,
) -> CoreEvent {
    CoreEvent::InstallResult {
        app_id: row.app_id.clone(),
        package_name: package_name.map(str::to_string),
        success,
        message: message.map(str::to_string),
    }
}

/// Durable install service over the core database.
pub struct InstallService {
    conn: SharedConn,
    installer: Arc<dyn InstallerPort>,
}

impl InstallService {
    /// Creates a service over `conn` using `installer` for every install call.
    pub fn new(conn: SharedConn, installer: Arc<dyn InstallerPort>) -> Self {
        Self { conn, installer }
    }

    fn lock(&self) -> Result<MutexGuard<'_, Connection>, Error> {
        self.conn
            .lock()
            .map_err(|_| Error::Internal("install db mutex poisoned".to_string()))
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
    /// Idempotent: an `installed` row or an in-flight `pending` row returns the
    /// existing record with no event and never calls the installer again.
    ///
    /// # Errors
    /// - [`Error::NotFound`] when the download task does not exist.
    /// - [`Error::InvalidArgument`] when `dest_path` is empty or not a file.
    /// - [`Error::Conflict`] when the download is not `completed`.
    /// - [`Error::Unsupported`] when the installer cannot install.
    /// - The installer's typed error (after recording `failed`).
    pub fn install(&self, module_task_id: &str) -> Result<InstallAttempt, Error> {
        let row = {
            let guard = self.lock()?;
            Self::required(&guard, module_task_id)?
        };

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
        if !self.installer.can_install() {
            return Err(Error::Unsupported(format!(
                "{UNSUPPORTED}: no install capability"
            )));
        }

        let now = now_ms()?;
        let session = make_session_id(module_task_id, now);
        let claimed = {
            let guard = self.lock()?;
            guard
                .execute(
                    "UPDATE download_task SET install_status = 'pending', \
                         install_session_id = ?1, install_method = NULL, install_error = NULL, \
                         installed_at = NULL, installed_version = NULL, updated_at = ?2 \
                     WHERE module_task_id = ?3 \
                       AND install_status IN ('none', 'failed', 'denied', 'timeout', 'unknown')",
                    rusqlite::params![session, now, module_task_id],
                )
                .map_err(|e| {
                    Error::Internal(format!("CORE_E_INSTALL_WRITE: claim {module_task_id}: {e}"))
                })?
        };
        if claimed == 0 {
            let guard = self.lock()?;
            let current = Self::required(&guard, module_task_id)?;
            return Ok(InstallAttempt {
                record: current.into_record(),
                event: None,
            });
        }

        let ticket = match self
            .installer
            .begin_install(Path::new(&dest_path), &session)
        {
            Ok(ticket) => ticket,
            Err(error) => {
                if let Err(persist) = self.record_port_failure(module_task_id, &session, &error) {
                    return Err(Error::Internal(format!(
                        "{} (persist failure: {})",
                        error.message(),
                        persist.message()
                    )));
                }
                return Err(error);
            }
        };

        let guard = self.lock()?;
        let method_changed = guard
            .execute(
                "UPDATE download_task SET install_method = ?1, updated_at = ?2 \
                 WHERE module_task_id = ?3 AND install_session_id = ?4 \
                   AND install_status = 'pending'",
                rusqlite::params![ticket.method.as_str(), now_ms()?, module_task_id, session],
            )
            .map_err(|e| {
                Error::Internal(format!(
                    "CORE_E_INSTALL_WRITE: method {module_task_id}: {e}"
                ))
            })?;
        if method_changed == 0 {
            let current = Self::required(&guard, module_task_id)?;
            return Ok(InstallAttempt {
                record: current.into_record(),
                event: None,
            });
        }

        match ticket.outcome {
            Some(outcome) => {
                let changed = Self::transition_outcome(
                    &guard,
                    module_task_id,
                    &session,
                    &outcome,
                    now_ms()?,
                )?;
                let current = Self::required(&guard, module_task_id)?;
                let event = if changed {
                    Some(install_event(
                        &current,
                        outcome.is_success(),
                        outcome.package_name(),
                        outcome.message(),
                    ))
                } else {
                    None
                };
                Ok(InstallAttempt {
                    record: current.into_record(),
                    event,
                })
            }
            None => {
                let current = Self::required(&guard, module_task_id)?;
                Ok(InstallAttempt {
                    record: current.into_record(),
                    event: None,
                })
            }
        }
    }

    fn record_port_failure(
        &self,
        module_task_id: &str,
        session: &str,
        error: &Error,
    ) -> Result<(), Error> {
        let guard = self.lock()?;
        guard
            .execute(
                "UPDATE download_task SET install_status = 'failed', install_error = ?1, \
                     updated_at = ?2 \
                 WHERE module_task_id = ?3 AND install_session_id = ?4 \
                   AND install_status = 'pending'",
                rusqlite::params![error.message(), now_ms()?, module_task_id, session],
            )
            .map_err(|e| {
                Error::Internal(format!(
                    "CORE_E_INSTALL_WRITE: failure {module_task_id}: {e}"
                ))
            })?;
        Ok(())
    }

    fn transition_outcome(
        conn: &Connection,
        module_task_id: &str,
        session: &str,
        outcome: &InstallOutcome,
        now: i64,
    ) -> Result<bool, Error> {
        let (installed_at, installed_version, install_error) = terminal_fields(
            outcome.status_str(),
            outcome.version_name(),
            outcome.message(),
            now,
        );
        let changed = conn
            .execute(
                "UPDATE download_task SET install_status = ?1, installed_at = ?2, \
                     installed_version = ?3, install_error = ?4, updated_at = ?5 \
                 WHERE module_task_id = ?6 AND install_session_id = ?7 \
                   AND install_status = 'pending'",
                rusqlite::params![
                    outcome.status_str(),
                    installed_at,
                    installed_version,
                    install_error,
                    now,
                    module_task_id,
                    session
                ],
            )
            .map_err(|e| {
                Error::Internal(format!(
                    "CORE_E_INSTALL_WRITE: outcome {module_task_id}: {e}"
                ))
            })?;
        Ok(changed > 0)
    }

    /// Applies an asynchronous installer result.
    ///
    /// Only a `pending` row transitions; duplicates (including a terminal row)
    /// return `Ok(None)` and never emit a second event.
    ///
    /// # Errors
    /// - [`Error::InvalidArgument`] for an empty session id or unknown status.
    /// - [`Error::NotFound`] when no row carries `session_id`.
    pub fn on_result(
        &self,
        session_id: &str,
        status: &str,
        package_name: Option<&str>,
        version_name: Option<&str>,
        error: Option<&str>,
    ) -> Result<Option<CoreEvent>, Error> {
        if session_id.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "CORE_E_INSTALL_SESSION: session id must not be empty".to_string(),
            ));
        }
        if !matches!(
            status,
            INSTALL_STATUS_INSTALLED
                | INSTALL_STATUS_FAILED
                | INSTALL_STATUS_DENIED
                | INSTALL_STATUS_TIMEOUT
        ) {
            return Err(Error::InvalidArgument(format!(
                "CORE_E_INSTALL_STATUS: unexpected terminal status {status}"
            )));
        }

        let guard = self.lock()?;
        let row = Self::load_by_session(&guard, session_id)?
            .ok_or_else(|| Error::NotFound(format!("install session not found: {session_id}")))?;
        if row.install_status != INSTALL_STATUS_PENDING {
            return Ok(None);
        }

        let now = now_ms()?;
        let (installed_at, installed_version, install_error) =
            terminal_fields(status, version_name, error, now);
        let changed = guard
            .execute(
                "UPDATE download_task SET install_status = ?1, installed_at = ?2, \
                     installed_version = ?3, install_error = ?4, updated_at = ?5 \
                 WHERE install_session_id = ?6 AND install_status = 'pending'",
                rusqlite::params![
                    status,
                    installed_at,
                    installed_version,
                    install_error,
                    now,
                    session_id
                ],
            )
            .map_err(|e| {
                Error::Internal(format!("CORE_E_INSTALL_WRITE: result {session_id}: {e}"))
            })?;
        if changed == 0 {
            return Ok(None);
        }

        let row = Self::load_by_session(&guard, session_id)?
            .ok_or_else(|| Error::NotFound(format!("install session not found: {session_id}")))?;
        Ok(Some(install_event(
            &row,
            status == INSTALL_STATUS_INSTALLED,
            package_name,
            error,
        )))
    }

    /// Reconciles every pending install session against the installer.
    ///
    /// Returns the sweep report together with every event produced by the
    /// sweep, so callers cannot accidentally drop install results. A pending
    /// row with an empty session id becomes `unknown`.
    ///
    /// # Errors
    /// Propagates installer and database failures.
    pub fn reconcile(&self) -> Result<(InstallReconcileReport, Vec<CoreEvent>), Error> {
        let pending: Vec<(String, Option<String>)> = {
            let guard = self.lock()?;
            let mut stmt = guard
                .prepare(
                    "SELECT module_task_id, install_session_id FROM download_task \
                     WHERE install_status = 'pending' ORDER BY id",
                )
                .map_err(|e| {
                    Error::Internal(format!("CORE_E_INSTALL_READ: prepare reconcile: {e}"))
                })?;
            let rows = stmt
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
                })
                .map_err(|e| {
                    Error::Internal(format!("CORE_E_INSTALL_READ: query reconcile: {e}"))
                })?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| Error::Internal(format!("CORE_E_INSTALL_READ: read reconcile: {e}")))?
        };

        let mut report = InstallReconcileReport::default();
        let mut events = Vec::new();
        for (module_task_id, session_id) in pending {
            report.checked += 1;
            let session_id = session_id.unwrap_or_default();
            if session_id.trim().is_empty() {
                let guard = self.lock()?;
                let changed = guard
                    .execute(
                        "UPDATE download_task SET install_status = 'unknown', \
                             install_error = ?1, updated_at = ?2 \
                         WHERE module_task_id = ?3 AND install_status = 'pending'",
                        rusqlite::params![SESSION_MISSING, now_ms()?, module_task_id],
                    )
                    .map_err(|e| {
                        Error::Internal(format!(
                            "CORE_E_INSTALL_WRITE: unknown {module_task_id}: {e}"
                        ))
                    })?;
                if changed > 0 {
                    report.resolved += 1;
                } else {
                    report.still_pending += 1;
                }
                continue;
            }

            match self.installer.install_result(&session_id)? {
                Some(outcome) => {
                    let guard = self.lock()?;
                    let changed = Self::transition_outcome(
                        &guard,
                        &module_task_id,
                        &session_id,
                        &outcome,
                        now_ms()?,
                    )?;
                    if !changed {
                        let current = Self::required(&guard, &module_task_id)?;
                        if current.install_status == INSTALL_STATUS_PENDING {
                            report.still_pending += 1;
                        } else {
                            report.resolved += 1;
                        }
                        continue;
                    }
                    let current = Self::required(&guard, &module_task_id)?;
                    events.push(install_event(
                        &current,
                        outcome.is_success(),
                        outcome.package_name(),
                        outcome.message(),
                    ));
                    report.resolved += 1;
                }
                None => report.still_pending += 1,
            }
        }

        Ok((report, events))
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
    ) -> Result<Option<InstallAttempt>, Error> {
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

    /// Uninstalls `package_name` through the installer port.
    ///
    /// # Errors
    /// [`Error::InvalidArgument`] for an empty name, plus port errors.
    pub fn uninstall(&self, package_name: &str) -> Result<(), Error> {
        if package_name.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "CORE_E_INSTALL_PACKAGE: package name must not be empty".to_string(),
            ));
        }
        self.installer.uninstall(package_name)
    }

    /// Launches `package_name` through the installer port.
    ///
    /// # Errors
    /// [`Error::InvalidArgument`] for an empty name, plus port errors.
    pub fn launch(&self, package_name: &str) -> Result<(), Error> {
        if package_name.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "CORE_E_INSTALL_PACKAGE: package name must not be empty".to_string(),
            ));
        }
        self.installer.launch(package_name)
    }

    /// Whether the installer can install packages.
    pub fn can_install(&self) -> bool {
        self.installer.can_install()
    }

    /// Reads the durable install record for `module_task_id`.
    ///
    /// # Errors
    /// [`Error::NotFound`] when the task does not exist.
    pub fn get(&self, module_task_id: &str) -> Result<InstallRecord, Error> {
        let guard = self.lock()?;
        Ok(Self::required(&guard, module_task_id)?.into_record())
    }

    /// Lists every row currently pending reconciliation.
    ///
    /// # Errors
    /// Propagates database read failures.
    pub fn list_pending(&self) -> Result<Vec<InstallRecord>, Error> {
        let guard = self.lock()?;
        let mut stmt = guard
            .prepare(
                "SELECT module_task_id, app_id, dest_path, status, install_status, \
                     install_method, install_session_id, install_error, installed_at, \
                     installed_version, install_after_download \
                 FROM download_task WHERE install_status = 'pending' ORDER BY id",
            )
            .map_err(|e| Error::Internal(format!("CORE_E_INSTALL_READ: prepare pending: {e}")))?;
        let rows = stmt
            .query_map([], row_from_sql)
            .map_err(|e| Error::Internal(format!("CORE_E_INSTALL_READ: query pending: {e}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map(|rows| rows.into_iter().map(TaskRow::into_record).collect())
            .map_err(|e| Error::Internal(format!("CORE_E_INSTALL_READ: read pending: {e}")))
    }
}
