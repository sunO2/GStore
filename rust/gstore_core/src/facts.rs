//! Frontend-pushed facts and the core↔frontend install/update wire DTOs.
//!
//! The core never calls platform code. The frontend collects device facts and
//! installed-app inventory, pushes them in, and executes the install requests
//! the core returns. Every type here is a plain serde DTO (no traits, no `dyn`)
//! so it crosses the FFI surface unchanged.
//!
//! [`FactStore`] persists one [`PlatformFacts`] row (`platform_facts.id = 1`).

use rusqlite::OptionalExtension;

use crate::db::{DbError, DbHandle};
use crate::error::Error;
use crate::install::InstallRecord;

/// Device identity reported by the frontend.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct DeviceFacts {
    /// Device model.
    pub model: String,
    /// Device manufacturer.
    pub manufacturer: String,
}

/// Storage paths the frontend resolved for the core.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CorePaths {
    /// App data directory.
    pub data: String,
    /// App files directory.
    pub files: String,
    /// App cache directory.
    pub cache: String,
}

/// One platform-facts snapshot pushed by the frontend.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct PlatformFacts {
    /// Inventory/facts source identity (for example `android`).
    pub source_id: String,
    /// Operating system (`android`).
    pub os: String,
    /// CPU architecture (`aarch64`).
    pub arch: String,
    /// Supported ABIs in preference order.
    pub abis: Vec<String>,
    /// Android SDK level.
    pub sdk: i32,
    /// Device identity.
    pub device: DeviceFacts,
    /// Storage paths.
    pub paths: CorePaths,
    /// Optional key material for the host secret store; never logged.
    pub crypto_key: Option<Vec<u8>>,
    /// Milliseconds since the Unix epoch when the frontend captured the facts.
    pub captured_at: i64,
}

/// One installed application in an inventory snapshot.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct InstalledApp {
    /// Android package name.
    pub package_name: String,
    /// User-visible application name.
    pub app_name: Option<String>,
    /// Version name (`versionName`).
    pub version_name: String,
    /// Monotonic version code.
    pub version_code: i64,
    /// SHA-256 of the signing certificate, when known.
    pub signature_sha256: Option<String>,
    /// Directory the APK was installed from.
    pub source_dir: Option<String>,
    /// Installer package name.
    pub installer: Option<String>,
    /// Whether this is a system application.
    pub is_system: bool,
    /// Target SDK level.
    pub target_sdk: i32,
    /// Minimum SDK level.
    pub min_sdk: i32,
    /// Supported ABIs.
    pub abis: Vec<String>,
}

/// One inventory snapshot pushed by the frontend.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct InventorySnapshot {
    /// Inventory source identity.
    pub source_id: String,
    /// Monotonic sequence number for this source.
    pub seq: i64,
    /// Milliseconds since the Unix epoch when the frontend captured the snapshot.
    pub captured_at: i64,
    /// Full installed-app set for this source.
    pub apps: Vec<InstalledApp>,
}

/// Result of [`crate::inventory::InventoryStore::push`].
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct InventoryPushResult {
    /// Whether the snapshot was applied.
    pub accepted: bool,
    /// Why the snapshot was rejected as a no-op (`unchanged`), when applicable.
    pub reason: Option<String>,
}

/// One download variant the frontend should install.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct VariantChoice {
    /// ABI this APK targets.
    pub abi: String,
    /// Absolute download URL.
    pub url: String,
    /// Absolute fallback URLs in preference order.
    pub fallback_chain: Vec<String>,
}

/// Durable install request returned to the frontend.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct InstallRequest {
    /// Download task id this request belongs to.
    pub module_task_id: String,
    /// Installer session id the frontend must report back.
    pub session_id: String,
    /// Android package name.
    pub package_name: String,
    /// Version name being installed.
    pub version_name: String,
    /// Local APK path the frontend installs.
    pub apk_path: String,
    /// `shizuku` / `package_installer` / `intent` / `platform`.
    pub method: String,
    /// Selected download variant.
    pub variant: VariantChoice,
}

/// Result of an install call: a settled record, a request, or both shapes.
///
/// Exactly one of `record.status == installed` or `request.is_some()` is true.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallStart {
    /// Current durable record.
    pub record: InstallRecord,
    /// Request to execute, when an install is still needed.
    pub request: Option<InstallRequest>,
}

/// Terminal (or timeout) status reported by the frontend installer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InstallReportStatus {
    /// Install succeeded.
    Installed,
    /// Install failed.
    Failed,
    /// User rejected the install.
    Denied,
    /// Install timed out.
    Timeout,
}

/// Result report sent back by the frontend installer.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct InstallReport {
    /// Session id from [`InstallRequest`].
    pub session_id: String,
    /// Terminal status.
    pub status: InstallReportStatus,
    /// Install method actually used.
    pub method: String,
    /// Installed version name on success.
    pub installed_version: Option<String>,
    /// Error message on failure.
    pub error: Option<String>,
    /// Milliseconds since the Unix epoch when the frontend reported.
    pub reported_at: i64,
}

/// Acknowledgement of an [`InstallReport`].
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct InstallResultAck {
    /// Session id that was acknowledged.
    pub session_id: String,
    /// Resulting durable install status.
    pub status: String,
    /// Whether the report changed the row (a duplicate report is `false`).
    pub changed: bool,
}

/// Frontend install policy stored in `frontend_rules`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct InstallRules {
    /// Rules document version ([`crate::rules::RULES_VERSION`]).
    pub version: i64,
    /// Whether installs are allowed at all.
    pub install_enabled: bool,
    /// ABI preference order.
    pub abi_priority: Vec<String>,
    /// Whether installing an older version is allowed.
    pub allow_downgrade: bool,
    /// Whether unknown install sources are allowed.
    pub allow_unknown_sources: bool,
    /// `strict` / `warn` / `off`.
    pub signature_policy: String,
    /// Whether the installer may run without UI.
    pub silent_install: bool,
    /// Install timeout in seconds.
    pub timeout_secs: i64,
}

/// Frontend update policy stored in `frontend_rules`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct UpdateRules {
    /// Rules document version ([`crate::rules::RULES_VERSION`]).
    pub version: i64,
    /// Release-channel preference order; empty means no preference.
    pub channel_priority: Vec<String>,
    /// Whether prerelease versions are eligible.
    pub allow_prerelease: bool,
    /// `strict` / `warn` / `off`.
    pub signature_policy: String,
    /// Maximum accepted inventory age in seconds.
    pub max_inventory_age_secs: i64,
}

/// Single-row storage for the latest [`PlatformFacts`].
pub struct FactStore {
    db: DbHandle,
}

impl FactStore {
    /// Creates a store over an already-open core database.
    pub fn new(db: DbHandle) -> Self {
        Self { db }
    }

    /// Replaces the stored facts (single row `platform_facts.id = 1`).
    pub fn put(&self, facts: &PlatformFacts) -> Result<(), Error> {
        let json = serde_json::to_string(facts)?;
        self.db
            .with_writer(|conn| {
                conn.execute(
                    "INSERT INTO platform_facts(id, json, source_id, captured_at) \
                     VALUES (1, ?1, ?2, ?3) \
                     ON CONFLICT(id) DO UPDATE SET \
                         json = excluded.json, \
                         source_id = excluded.source_id, \
                         captured_at = excluded.captured_at",
                    rusqlite::params![json, facts.source_id, facts.captured_at],
                )
                .map_err(|e| DbError(format!("write platform_facts: {e}")))?;
                Ok(())
            })
            .map_err(db_error)
    }

    /// Returns the stored facts, if the frontend has pushed any.
    pub fn get(&self) -> Result<Option<PlatformFacts>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        let json: Option<String> = conn
            .query_row("SELECT json FROM platform_facts WHERE id=1", [], |row| {
                row.get(0)
            })
            .optional()
            .map_err(sql_error)?;
        match json {
            Some(json) => serde_json::from_str(&json)
                .map(Some)
                .map_err(|e| Error::Serialization(format!("CORE_E_FACTS_INVALID: {e}"))),
            None => Ok(None),
        }
    }
}

fn db_error(error: DbError) -> Error {
    Error::Io(error.to_string())
}

fn sql_error(error: rusqlite::Error) -> Error {
    if matches!(
        &error,
        rusqlite::Error::SqliteFailure(code, _)
            if code.code == rusqlite::ErrorCode::ConstraintViolation
    ) {
        Error::Conflict(error.to_string())
    } else {
        Error::Io(error.to_string())
    }
}
