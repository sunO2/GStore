//! Ordered, idempotent migration of legacy channel data into the core schema.
//!
//! This module implements Todo 12: the old Floor `channel_apps.db`, per-channel
//! JS env documents, F-Droid source configuration, and local channel packs all
//! enter the core database through the same idempotent upsert paths used by the
//! live drivers. It adds **no** schema changes and no new public `CoreApi`
//! methods.
//!
//! ## Safety model
//!
//! * The old SQLite file is copied to `<backup_dir>/<name>.<utc-ts>.bak` and
//!   fsynced **before** it is opened. The source file is never moved, renamed,
//!   or deleted.
//! * Rows are written inside one `BEGIN IMMEDIATE` transaction. A malformed
//!   schema, unreadable file, or bad row leaves the core database unchanged
//!   while the backup remains available for inspection.
//! * Sensitive env values (keys containing `PASS`, `TOKEN`, `SECRET`, `KEY`,
//!   `COOKIE`, or `CREDENTIAL`, case-insensitive) go to the [`FileSecretPort`]
//!   under `channel.<channel_key>.<ENV_KEY>`; the plaintext `channel_env` row
//!   contains only non-sensitive values.
//! * An exported `channel_env.*.json` file is deleted only after the DB upsert
//!   committed. Errors leave it in place so a retry can resume.
//! * Secrets are never logged or embedded in error messages.

use std::fmt::Write as _;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::channel::{rebase_icon, PackStore};
use crate::dto::ChannelKey;
use crate::migration::MIGRATION_DOC_VERSION;
use crate::ports::config::CoreConfig;
use crate::ports::secret::{validate_secret_key, FileSecretPort};

/// Stable machine codes for [`ChannelMigrationError`].
pub const CODE_BACKUP: &str = "CORE_E_MIGRATION_BACKUP";
pub const CODE_DB_OPEN: &str = "CORE_E_MIGRATION_DB";
pub const CODE_DB_VERSION: &str = "CORE_E_MIGRATION_DB_VERSION";
pub const CODE_SCHEMA: &str = "CORE_E_MIGRATION_SCHEMA";
pub const CODE_READ: &str = "CORE_E_MIGRATION_READ";
pub const CODE_JSON: &str = "CORE_E_MIGRATION_JSON";
pub const CODE_SHAPE: &str = "CORE_E_MIGRATION_SHAPE";
pub const CODE_WRITE: &str = "CORE_E_MIGRATION_WRITE";
pub const CODE_SECRET: &str = "CORE_E_MIGRATION_SECRET";
pub const CODE_CONFIG: &str = "CORE_E_MIGRATION_CONFIG";
pub const CODE_PACK: &str = "CORE_E_MIGRATION_PACK";
pub const CODE_DELETE: &str = "CORE_E_MIGRATION_DELETE";

/// Typed migration failure with a stable machine code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelMigrationError {
    /// The pre-read backup could not be written.
    Backup(String),
    /// The legacy database could not be opened or queried.
    DbOpen(String),
    /// `PRAGMA user_version` is outside the supported Floor range.
    DbVersion(String),
    /// `channel_added_app` is missing or has an unexpected shape.
    Schema(String),
    /// A source file could not be read.
    Read(String),
    /// A JSON document is not valid JSON.
    Json(String),
    /// A JSON document has the wrong shape/version.
    Shape(String),
    /// A core database write failed (transaction rolled back).
    Write(String),
    /// A secret could not be persisted or validated.
    Secret(String),
    /// Proxy/token/F-Droid configuration was rejected.
    Config(String),
    /// A local pack could not be imported.
    Pack(String),
    /// A successfully imported document could not be deleted.
    Delete(String),
}

impl ChannelMigrationError {
    /// Stable machine-readable code.
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Backup(_) => CODE_BACKUP,
            Self::DbOpen(_) => CODE_DB_OPEN,
            Self::DbVersion(_) => CODE_DB_VERSION,
            Self::Schema(_) => CODE_SCHEMA,
            Self::Read(_) => CODE_READ,
            Self::Json(_) => CODE_JSON,
            Self::Shape(_) => CODE_SHAPE,
            Self::Write(_) => CODE_WRITE,
            Self::Secret(_) => CODE_SECRET,
            Self::Config(_) => CODE_CONFIG,
            Self::Pack(_) => CODE_PACK,
            Self::Delete(_) => CODE_DELETE,
        }
    }

    /// Human-readable message (never contains secret values).
    pub fn message(&self) -> &str {
        match self {
            Self::Backup(message)
            | Self::DbOpen(message)
            | Self::DbVersion(message)
            | Self::Schema(message)
            | Self::Read(message)
            | Self::Json(message)
            | Self::Shape(message)
            | Self::Write(message)
            | Self::Secret(message)
            | Self::Config(message)
            | Self::Pack(message)
            | Self::Delete(message) => message,
        }
    }

    /// True when a pre-read backup exists for a failed legacy-DB import.
    pub const fn backup_retained(&self) -> bool {
        matches!(self, Self::DbOpen(_) | Self::DbVersion(_) | Self::Schema(_))
    }
}

impl std::fmt::Display for ChannelMigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.code(), self.message())
    }
}

impl std::error::Error for ChannelMigrationError {}

/// Report for a legacy `channel_apps.db` import.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelDbReport {
    /// Rows upserted into `channel_apps` (the count is stable across retries).
    pub rows_imported: usize,
    /// `PRAGMA user_version` read from the legacy database.
    pub schema_version: i64,
    /// Fsynced backup written before the legacy DB was opened.
    pub backup_path: PathBuf,
}

/// Report for one `channel_env` document import.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvImportReport {
    /// `channel_env` rows upserted (0 or 1).
    pub rows: usize,
    /// Sensitive env entries written to the secret port.
    pub secrets_written: usize,
}

/// Report for a `fdroid_sources` document import.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FdroidImportReport {
    /// Configured sources persisted.
    pub sources: usize,
    /// Selected source id, when one was supplied.
    pub last_source_id: Option<String>,
    /// Secret values written (GitHub token).
    pub secrets_written: usize,
}

/// Report for a local pack archive import.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackImportReport {
    /// Pack rows upserted (0 or 1).
    pub packs: usize,
    /// Channel key (`js_<stem>`).
    pub key: String,
    /// SHA-256 of the whole archive.
    pub pack_hash: String,
    /// Stored `channel_packs.installed_at` (unchanged for an identical hash).
    pub installed_at: i64,
}

/// Bundled result for a complete ordered handoff.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ChannelMigrationReport {
    /// Legacy channel DB rows.
    pub rows_imported: usize,
    /// Env documents imported.
    pub env_documents: usize,
    /// Secret values written.
    pub secrets_written: usize,
    /// F-Droid sources persisted.
    pub sources: usize,
    /// Packs imported.
    pub packs: usize,
}

/// Channel-data importer bound to a core write connection, secret port, and
/// backup directory.
pub struct ChannelMigrator<'a> {
    conn: &'a Connection,
    secrets: &'a dyn FileSecretPort,
    backup_dir: PathBuf,
}

impl<'a> ChannelMigrator<'a> {
    /// Creates an importer. `backup_dir` is created lazily.
    pub fn new(
        conn: &'a Connection,
        secrets: &'a dyn FileSecretPort,
        backup_dir: impl Into<PathBuf>,
    ) -> Self {
        Self {
            conn,
            secrets,
            backup_dir: backup_dir.into(),
        }
    }

    /// Imports the old Floor `channel_added_app` table into `channel_apps`.
    ///
    /// Idempotent: `(channel_key, app_id)` is upserted, so a second run writes
    /// the same rows and counts without duplicating.
    pub fn import_channel_db(&self, path: &Path) -> Result<ChannelDbReport, ChannelMigrationError> {
        if !path.is_file() {
            return Err(ChannelMigrationError::Read(format!(
                "legacy channel db not found: {}",
                path.display()
            )));
        }
        let backup_path = self.backup_before_read(path)?;

        let source = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(
            |error| ChannelMigrationError::DbOpen(format!("open {}: {error}", path.display())),
        )?;
        let schema_version: i64 = source
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .map_err(|error| {
                ChannelMigrationError::DbOpen(format!(
                    "read user_version from {}: {error}",
                    path.display()
                ))
            })?;
        if !(1..=5).contains(&schema_version) {
            return Err(ChannelMigrationError::DbVersion(format!(
                "unsupported channel_added_app schema version {schema_version} (expected 1..=5)"
            )));
        }

        let columns = table_columns(&source, "channel_added_app")?;
        let required = [
            "appId",
            "name",
            "user",
            "repositories",
            "icon",
            "description",
            "addTime",
            "channelCode",
        ];
        let missing: Vec<&str> = required
            .iter()
            .copied()
            .filter(|name| !columns.iter().any(|column| column == name))
            .collect();
        if !missing.is_empty() {
            return Err(ChannelMigrationError::Schema(format!(
                "channel_added_app missing required columns: {missing:?}"
            )));
        }

        let optional = |name: &str| -> String {
            if columns.iter().any(|column| column == name) {
                name.to_string()
            } else {
                format!("NULL AS {name}")
            }
        };
        let sql = format!(
            "SELECT appId, name, user, repositories, {}, icon, description, \
                    {}, addTime, channelCode, {}, {} \
             FROM channel_added_app",
            optional("apprepo"),
            optional("category"),
            optional("extra"),
            optional("sourceId")
        );

        let mut statement = source.prepare(&sql).map_err(|error| {
            ChannelMigrationError::DbOpen(format!("prepare legacy channel rows: {error}"))
        })?;
        let mut rows = statement.query([]).map_err(|error| {
            ChannelMigrationError::DbOpen(format!("query legacy channel rows: {error}"))
        })?;

        let tx = self.conn.unchecked_transaction().map_err(|error| {
            ChannelMigrationError::Write(format!("begin channel_apps import: {error}"))
        })?;
        let sources = configured_sources(self.conn);
        let mut imported = 0usize;
        loop {
            let row = match rows.next() {
                Ok(Some(row)) => row,
                Ok(None) => break,
                Err(error) => {
                    return Err(ChannelMigrationError::DbOpen(format!(
                        "read legacy channel row: {error}"
                    )))
                }
            };
            let app_id: String = required_text(row, 0, "appId")?;
            let name: String = required_text(row, 1, "name")?;
            let user: String = required_text(row, 2, "user")?;
            let repositories: String = required_text(row, 3, "repositories")?;
            let apprepo: Option<String> = optional_text(row, 4, "apprepo")?;
            let icon: String = required_text(row, 5, "icon")?;
            let description: String = required_text(row, 6, "description")?;
            let category: Option<String> = optional_text(row, 7, "category")?;
            let add_time: i64 = row.get(8).map_err(|error| {
                ChannelMigrationError::Schema(format!("column addTime: {error}"))
            })?;
            let channel_key: String = required_text(row, 9, "channelCode")?;
            let extra: Option<String> = optional_text(row, 10, "extra")?;
            let source_id: Option<String> = optional_text(row, 11, "sourceId")?;
            if app_id.trim().is_empty() || channel_key.trim().is_empty() {
                return Err(ChannelMigrationError::Schema(
                    "channel_added_app row has an empty appId/channelCode".to_string(),
                ));
            }
            let (source_id, icon) = normalize_fdroid_row(
                &channel_key,
                &app_id,
                icon,
                source_id,
                extra.as_deref(),
                &sources,
            );

            tx.execute(
                "INSERT INTO channel_apps(
                     channel_key, app_id, name, user, repositories, apprepo, icon,
                     description, category, add_time, source_id, extra)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
                 ON CONFLICT(channel_key, app_id) DO UPDATE SET
                     name = excluded.name,
                     user = excluded.user,
                     repositories = excluded.repositories,
                     apprepo = excluded.apprepo,
                     icon = excluded.icon,
                     description = excluded.description,
                     category = excluded.category,
                     add_time = excluded.add_time,
                     source_id = excluded.source_id,
                     extra = excluded.extra",
                rusqlite::params![
                    channel_key,
                    app_id,
                    name,
                    user,
                    repositories,
                    apprepo,
                    icon,
                    description,
                    category,
                    add_time,
                    source_id,
                    extra,
                ],
            )
            .map_err(|error| {
                ChannelMigrationError::Write(format!(
                    "upsert channel_apps {channel_key}/{app_id}: {error}"
                ))
            })?;
            imported += 1;
        }
        tx.commit().map_err(|error| {
            ChannelMigrationError::Write(format!("commit channel_apps import: {error}"))
        })?;

        Ok(ChannelDbReport {
            rows_imported: imported,
            schema_version,
            backup_path,
        })
    }

    /// Imports one parsed `channel_env` document.
    ///
    /// Sensitive values never reach the plaintext `channel_env.env_json` row.
    pub fn import_channel_env(
        &self,
        doc: &Value,
    ) -> Result<EnvImportReport, ChannelMigrationError> {
        check_document_version(doc)?;
        let channel_key = doc
            .get("channel_key")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                ChannelMigrationError::Shape("channel_key must be a non-empty string".to_string())
            })?;
        let env = doc
            .get("env")
            .and_then(Value::as_object)
            .ok_or_else(|| ChannelMigrationError::Shape("env must be an object".to_string()))?;

        let mut plain = Map::new();
        let mut secrets_written = 0usize;
        for (key, value) in env {
            let text = match value {
                Value::String(text) => text.clone(),
                other => other.to_string(),
            };
            if is_sensitive_key(key) {
                let secret_key = format!("channel.{channel_key}.{key}");
                validate_secret_key(&secret_key).map_err(|error| {
                    ChannelMigrationError::Secret(format!(
                        "secret key for env entry {key}: {}",
                        error.message()
                    ))
                })?;
                self.secrets.set(&secret_key, &text).map_err(|error| {
                    ChannelMigrationError::Secret(format!(
                        "write secret for env entry {key}: {}",
                        error.message()
                    ))
                })?;
                secrets_written += 1;
            } else {
                plain.insert(key.clone(), Value::String(text));
            }
        }
        let env_json = Value::Object(plain).to_string();

        self.conn
            .execute(
                "INSERT INTO channel_env(channel_key, env_json, imported_at) \
                 VALUES (?1, ?2, strftime('%s','now')) \
                 ON CONFLICT(channel_key) DO UPDATE SET \
                     env_json = excluded.env_json, imported_at = excluded.imported_at",
                rusqlite::params![channel_key, env_json],
            )
            .map_err(|error| {
                ChannelMigrationError::Write(format!("upsert channel_env {channel_key}: {error}"))
            })?;

        Ok(EnvImportReport {
            rows: 1,
            secrets_written,
        })
    }

    /// Reads and imports an env document without deleting it.
    ///
    /// The bridge calls this and deletes only documents that live in the
    /// managed `migration/` directory.
    pub fn import_channel_env_path(
        &self,
        path: &Path,
    ) -> Result<EnvImportReport, ChannelMigrationError> {
        let doc = read_json(path)?;
        self.import_channel_env(&doc)
    }

    /// Reads and imports an exported env document, deleting it only after the
    /// database row committed.
    pub fn import_channel_env_file(
        &self,
        path: &Path,
    ) -> Result<EnvImportReport, ChannelMigrationError> {
        let report = self.import_channel_env_path(path)?;
        delete_after_commit(path)?;
        Ok(report)
    }

    /// Imports F-Droid sources, the selected source id, proxy URL, and GitHub
    /// token from one versioned document.
    ///
    /// Sources and non-secret config live in the existing `update_prefs` table;
    /// the GitHub token lives in the secret port under
    /// `core_config.github_token`.
    pub fn import_fdroid_sources(
        &self,
        doc: &Value,
    ) -> Result<FdroidImportReport, ChannelMigrationError> {
        check_document_version(doc)?;
        let sources = doc
            .get("sources")
            .and_then(Value::as_array)
            .ok_or_else(|| ChannelMigrationError::Shape("sources must be an array".to_string()))?;
        let mut urls = Vec::with_capacity(sources.len());
        for (index, source) in sources.iter().enumerate() {
            let object = source.as_object().ok_or_else(|| {
                ChannelMigrationError::Shape(format!("sources[{index}] must be an object"))
            })?;
            for field in ["id", "name", "repoUrl"] {
                let value = object.get(field).and_then(Value::as_str).unwrap_or("");
                if value.trim().is_empty() {
                    return Err(ChannelMigrationError::Shape(format!(
                        "sources[{index}].{field} must be a non-empty string"
                    )));
                }
            }
            urls.push(object["repoUrl"].as_str().unwrap_or_default().to_string());
        }

        let last_source_id = match doc.get("last_source_id") {
            None | Some(Value::Null) => None,
            Some(Value::String(value)) if value.is_empty() => None,
            Some(Value::String(value)) => Some(value.clone()),
            Some(_) => {
                return Err(ChannelMigrationError::Shape(
                    "last_source_id must be a string or null".to_string(),
                ))
            }
        };
        let proxy_url = optional_document_string(doc, "proxy_url")?;
        let github_token = optional_document_string(doc, "github_token")?;

        let config = CoreConfig::new(proxy_url.clone(), github_token.clone())
            .and_then(|config| config.with_fdroid_sources(urls))
            .map_err(|error| {
                ChannelMigrationError::Config(format!(
                    "invalid F-Droid/proxy configuration: {}",
                    error.message()
                ))
            })?;

        let sources_json = serde_json::to_string(sources).map_err(|error| {
            ChannelMigrationError::Json(format!("encode fdroid sources: {error}"))
        })?;
        self.conn
            .execute(
                "INSERT INTO update_prefs(key, value, imported_at) \
                 VALUES ('fdroid_sources', ?1, strftime('%s','now')) \
                 ON CONFLICT(key) DO UPDATE SET \
                     value = excluded.value, imported_at = excluded.imported_at",
                [sources_json],
            )
            .map_err(|error| {
                ChannelMigrationError::Write(format!("persist fdroid_sources: {error}"))
            })?;
        repair_fdroid_source_identities(self.conn)?;
        match &last_source_id {
            Some(value) => {
                self.conn
                    .execute(
                        "INSERT INTO update_prefs(key, value, imported_at) \
                         VALUES ('last_source_id', ?1, strftime('%s','now')) \
                         ON CONFLICT(key) DO UPDATE SET \
                             value = excluded.value, imported_at = excluded.imported_at",
                        [value],
                    )
                    .map_err(|error| {
                        ChannelMigrationError::Write(format!("persist last_source_id: {error}"))
                    })?;
            }
            None => {
                self.conn
                    .execute("DELETE FROM update_prefs WHERE key='last_source_id'", [])
                    .map_err(|error| {
                        ChannelMigrationError::Write(format!("clear last_source_id: {error}"))
                    })?;
            }
        }
        match config.proxy_url() {
            Some(proxy) => {
                self.conn
                    .execute(
                        "INSERT INTO update_prefs(key, value, imported_at) \
                         VALUES ('proxy_url', ?1, strftime('%s','now')) \
                         ON CONFLICT(key) DO UPDATE SET \
                             value = excluded.value, imported_at = excluded.imported_at",
                        [proxy],
                    )
                    .map_err(|error| {
                        ChannelMigrationError::Write(format!("persist proxy_url: {error}"))
                    })?;
            }
            None => {
                self.conn
                    .execute("DELETE FROM update_prefs WHERE key='proxy_url'", [])
                    .map_err(|error| {
                        ChannelMigrationError::Write(format!("clear proxy_url: {error}"))
                    })?;
            }
        }

        let mut secrets_written = 0usize;
        match config.github_token() {
            Some(token) => {
                self.secrets
                    .set("core_config.github_token", token)
                    .map_err(|error| {
                        ChannelMigrationError::Secret(format!(
                            "write core_config.github_token: {}",
                            error.message()
                        ))
                    })?;
                secrets_written += 1;
            }
            None => {
                self.secrets
                    .remove("core_config.github_token")
                    .map_err(|error| {
                        ChannelMigrationError::Secret(format!(
                            "remove core_config.github_token: {}",
                            error.message()
                        ))
                    })?;
            }
        }

        Ok(FdroidImportReport {
            sources: sources.len(),
            last_source_id,
            secrets_written,
        })
    }

    /// Reads and imports a `fdroid_sources.json` document, deleting it only
    /// after the configuration rows committed.
    pub fn import_fdroid_sources_file(
        &self,
        path: &Path,
    ) -> Result<FdroidImportReport, ChannelMigrationError> {
        let doc = read_json(path)?;
        let report = self.import_fdroid_sources(&doc)?;
        delete_after_commit(path)?;
        Ok(report)
    }

    /// Imports a local pack through [`PackStore`].
    ///
    /// An identical archive hash is a true no-op: `installed_at` and the
    /// `channel_packs` row are untouched.
    pub fn import_pack_archive(
        &self,
        store: &PackStore,
        zip_path: &Path,
    ) -> Result<PackImportReport, ChannelMigrationError> {
        let (key, artifact) = read_pack_artifact(zip_path)?;
        let pack_hash = sha256_hex(&artifact);
        let existing = store
            .db()
            .with_reader(|conn| {
                conn.query_row(
                    "SELECT pack_hash, installed_at FROM channel_packs WHERE key=?1",
                    [key.as_str()],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
                )
                .optional()
                .map_err(|error| crate::db::DbError(error.to_string()))
            })
            .map_err(|error| {
                ChannelMigrationError::Write(format!("read channel_packs {}: {error}", key))
            })?;
        if let Some((stored_hash, installed_at)) = existing {
            if stored_hash == pack_hash {
                return Ok(PackImportReport {
                    packs: 1,
                    key: key.as_str().to_string(),
                    pack_hash,
                    installed_at,
                });
            }
        }

        let installed = store.import_pack(zip_path).map_err(|error| {
            ChannelMigrationError::Pack(format!(
                "import pack {}: [{}] {}",
                zip_path.display(),
                error.code(),
                error.message()
            ))
        })?;
        Ok(PackImportReport {
            packs: 1,
            key: installed.key.as_str().to_string(),
            pack_hash: installed.pack_hash,
            installed_at: installed.installed_at,
        })
    }

    /// Copies the legacy DB into the backup directory and fsyncs the copy.
    ///
    /// The source is only read. Backups use a millisecond-resolution UTC epoch
    /// stamp so repeated runs never overwrite an earlier backup.
    fn backup_before_read(&self, source: &Path) -> Result<PathBuf, ChannelMigrationError> {
        fs::create_dir_all(&self.backup_dir).map_err(|error| {
            ChannelMigrationError::Backup(format!(
                "create backup dir {}: {error}",
                self.backup_dir.display()
            ))
        })?;
        let file_name = source
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| {
                ChannelMigrationError::Backup(format!(
                    "legacy db has no usable file name: {}",
                    source.display()
                ))
            })?;
        let (seconds, nanos) = utc_stamp();
        let backup_path = self
            .backup_dir
            .join(format!("{file_name}.{seconds}.{nanos:09}.bak"));
        fs::copy(source, &backup_path).map_err(|error| {
            ChannelMigrationError::Backup(format!(
                "copy {} -> {}: {error}",
                source.display(),
                backup_path.display()
            ))
        })?;
        File::open(&backup_path)
            .and_then(|file| file.sync_all())
            .map_err(|error| {
                ChannelMigrationError::Backup(format!(
                    "fsync backup {}: {error}",
                    backup_path.display()
                ))
            })?;
        if let Ok(dir) = File::open(&self.backup_dir) {
            let _ = dir.sync_all();
        }
        Ok(backup_path)
    }
}

/// One configured F-Droid source as persisted in the `update_prefs` row
/// `fdroid_sources` (by [`ChannelMigrator::import_fdroid_sources`] and by the
/// bridge's `set_fdroid_sources`).
#[derive(Debug, Clone, PartialEq, Eq)]
struct ConfiguredSource {
    id: String,
    url: String,
    fingerprint: String,
    mirrors: Vec<String>,
}

impl ConfiguredSource {
    fn from_value(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        let url = object
            .get("repoUrl")
            .or_else(|| object.get("url"))
            .and_then(Value::as_str)?
            .trim();
        (!url.is_empty()).then(|| Self {
            id: object
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim()
                .to_string(),
            url: url.to_string(),
            fingerprint: object
                .get("fingerprint")
                .and_then(Value::as_str)
                .map(hex_key)
                .unwrap_or_default(),
            mirrors: object
                .get("mirrors")
                .and_then(Value::as_array)
                .map(|items| items.iter().filter_map(mirror_url).collect())
                .unwrap_or_default(),
        })
    }

    /// Every URL prefix an icon written by this source may carry.
    fn asset_bases(&self) -> impl Iterator<Item = &str> {
        std::iter::once(self.url.as_str())
            .chain(self.mirrors.iter().map(String::as_str))
    }

    /// The legacy identity forms the Dart read side accepts
    /// (`FdroidRustRepoManager.identityMatches`): the storage id, a raw
    /// fingerprint, `fp:<HEX>`, `url:<url>`, and a bare URL.
    fn matches(&self, stored: &str) -> bool {
        if !self.id.is_empty() && stored == self.id {
            return true;
        }
        let stored_url = strip_prefix_ci(stored, "url:").unwrap_or(stored);
        if is_http_url(stored_url) && same_url(stored_url, &self.url) {
            return true;
        }
        let stored_hex = strip_prefix_ci(stored, "fp:").unwrap_or(stored);
        !self.fingerprint.is_empty() && hex_key(stored_hex) == self.fingerprint
    }
}

/// Sources currently persisted in the core database, in config order.
fn configured_sources(conn: &Connection) -> Vec<ConfiguredSource> {
    let Ok(Some(raw)) = crate::migration::update_pref(conn, "fdroid_sources") else {
        return Vec::new();
    };
    match serde_json::from_str::<Value>(&raw) {
        Ok(Value::Array(items)) => items
            .iter()
            .filter_map(ConfiguredSource::from_value)
            .collect(),
        _ => Vec::new(),
    }
}

/// Maps a legacy source identity to the configured source URL the driver's
/// `active_sources()` compares against.
fn source_url_for_identity(stored: &str, sources: &[ConfiguredSource]) -> Option<String> {
    let key = stored.trim();
    if key.is_empty() {
        return None;
    }
    if let Some(source) = sources.iter().find(|source| source.matches(key)) {
        return Some(normalize_source_url(&source.url));
    }
    let bare = strip_prefix_ci(key, "url:").unwrap_or(key);
    is_http_url(bare).then(|| normalize_source_url(bare))
}

/// Same shape as the driver's `normalize_source`, so a rewritten `source_id`
/// compares equal to an `active_sources()` entry.
fn normalize_source_url(url: &str) -> String {
    url.trim().trim_end_matches('/').to_string()
}

fn is_http_url(value: &str) -> bool {
    value.starts_with("http://") || value.starts_with("https://")
}

fn strip_prefix_ci<'a>(value: &'a str, prefix: &str) -> Option<&'a str> {
    value
        .get(..prefix.len())
        .filter(|head| head.eq_ignore_ascii_case(prefix))
        .map(|_| &value[prefix.len()..])
}

fn hex_key(value: &str) -> String {
    value
        .chars()
        .filter(|character| *character != ':')
        .flat_map(char::to_uppercase)
        .collect::<String>()
        .trim()
        .to_string()
}

fn mirror_url(value: &Value) -> Option<String> {
    match value {
        Value::String(url) => {
            let url = url.trim();
            (!url.is_empty()).then(|| url.to_string())
        }
        Value::Object(map) => {
            let enabled = map
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            let url = map.get("url").and_then(Value::as_str)?.trim();
            (enabled && !url.is_empty()).then(|| url.to_string())
        }
        _ => None,
    }
}

/// Same normalization as the Dart `FdroidRustRepoManager.normalizeRepoUrl`.
fn normalized_url_key(url: &str) -> String {
    let trimmed = url.trim().trim_end_matches('/');
    match trimmed.split_once("://") {
        Some((scheme, rest)) => {
            let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
            format!(
                "{}://{}/{}",
                scheme.to_ascii_lowercase(),
                authority.to_ascii_lowercase(),
                path
            )
        }
        None => trimmed.to_string(),
    }
}

fn same_url(left: &str, right: &str) -> bool {
    normalized_url_key(left) == normalized_url_key(right)
}

fn extra_source_id(extra: Option<&str>) -> Option<String> {
    serde_json::from_str::<Value>(extra?).ok()?.as_object()?.get("sourceId")?
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

/// Rewrites one legacy F-Droid row so the record no longer depends on a source
/// *identity* the driver cannot match.
///
/// When the stored identity resolves to a URL, the column becomes that URL and
/// the icon is re-based onto it through [`rebase_icon`]: a repo-relative key is
/// written absolute, an absolute icon still carrying a known source/mirror
/// prefix loses that prefix, and an unknown-host (third-party CDN) icon is kept
/// verbatim. An unresolvable identity is left verbatim: the row is never
/// dropped and no source is guessed.
fn normalize_fdroid_row(
    channel_key: &str,
    app_id: &str,
    icon: String,
    source_id: Option<String>,
    extra: Option<&str>,
    sources: &[ConfiguredSource],
) -> (Option<String>, String) {
    if channel_key != "fdroid" {
        return (source_id, icon);
    }
    let legacy = source_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
        .or_else(|| extra_source_id(extra));
    let Some(source_url) = legacy
        .as_deref()
        .and_then(|stored| source_url_for_identity(stored, sources))
    else {
        return (source_id, icon);
    };
    let bases: Vec<String> = std::iter::once(source_url.clone())
        .chain(
            sources
                .iter()
                .flat_map(|source| source.asset_bases())
                .map(ToString::to_string),
        )
        .collect();
    let icon = rebase_icon(&icon, app_id, &source_url, &bases);
    (Some(source_url), icon)
}

/// Repairs `channel_apps` F-Droid rows already imported before the sources
/// were known (the handoff imports `channel_db` first).
fn repair_fdroid_rows(
    conn: &Connection,
    sources: &[ConfiguredSource],
) -> Result<usize, ChannelMigrationError> {
    let rows = {
        let mut statement = conn
            .prepare(
                "SELECT app_id, icon, source_id, extra FROM channel_apps \
                 WHERE channel_key='fdroid'",
            )
            .map_err(|error| {
                ChannelMigrationError::Write(format!("prepare fdroid rows: {error}"))
            })?;
        let mapped = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            })
            .map_err(|error| ChannelMigrationError::Write(format!("query fdroid rows: {error}")))?;
        mapped.collect::<Result<Vec<_>, _>>().map_err(|error| {
            ChannelMigrationError::Write(format!("read fdroid row: {error}"))
        })?
    };
    let mut repaired = 0usize;
    for (app_id, icon, source_id, extra) in rows {
        let (next_source, next_icon) = normalize_fdroid_row(
            "fdroid",
            &app_id,
            icon.clone(),
            source_id.clone(),
            extra.as_deref(),
            sources,
        );
        if next_source == source_id && next_icon == icon {
            continue;
        }
        conn.execute(
            "UPDATE channel_apps SET icon=?1, source_id=?2 \
             WHERE channel_key='fdroid' AND app_id=?3",
            rusqlite::params![next_icon, next_source, app_id],
        )
        .map_err(|error| {
            ChannelMigrationError::Write(format!("repair fdroid row {app_id}: {error}"))
        })?;
        repaired += 1;
    }
    Ok(repaired)
}

/// Heals legacy F-Droid rows in `channel_apps` against the sources persisted in
/// this database.
///
/// The handoff imports `channel_db` before `fdroid_sources`, and an install that
/// already migrated can never re-run it — so the repair must also be callable
/// after the source list is (re)published. Idempotent: only changed rows are
/// written.
pub fn repair_fdroid_source_identities(
    conn: &Connection,
) -> Result<usize, ChannelMigrationError> {
    repair_fdroid_rows(conn, &configured_sources(conn))
}

fn utc_stamp() -> (u64, u32) {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => (duration.as_secs(), duration.subsec_nanos()),
        Err(_) => (0, 0),
    }
}

fn check_document_version(doc: &Value) -> Result<(), ChannelMigrationError> {
    let version = doc.get("version").and_then(Value::as_i64);
    if version != Some(MIGRATION_DOC_VERSION) {
        return Err(ChannelMigrationError::Shape(format!(
            "expected document version {MIGRATION_DOC_VERSION}, got {}",
            doc.get("version")
                .map_or_else(|| "missing".to_string(), ToString::to_string)
        )));
    }
    Ok(())
}

fn read_json(path: &Path) -> Result<Value, ChannelMigrationError> {
    let raw = fs::read_to_string(path).map_err(|error| {
        ChannelMigrationError::Read(format!("read {}: {error}", path.display()))
    })?;
    serde_json::from_str(&raw)
        .map_err(|error| ChannelMigrationError::Json(format!("parse {}: {error}", path.display())))
}

fn delete_after_commit(path: &Path) -> Result<(), ChannelMigrationError> {
    fs::remove_file(path).map_err(|error| {
        ChannelMigrationError::Delete(format!(
            "delete imported document {}: {error}",
            path.display()
        ))
    })
}

fn optional_document_string(
    doc: &Value,
    field: &str,
) -> Result<Option<String>, ChannelMigrationError> {
    match doc.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if value.trim().is_empty() => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(ChannelMigrationError::Shape(format!(
            "{field} must be a string or null"
        ))),
    }
}

/// Sensitive env key rule: case-insensitive substring match.
pub fn is_sensitive_key(key: &str) -> bool {
    let upper = key.to_ascii_uppercase();
    ["PASS", "TOKEN", "SECRET", "KEY", "COOKIE", "CREDENTIAL"]
        .iter()
        .any(|needle| upper.contains(needle))
}

fn table_columns(conn: &Connection, table: &str) -> Result<Vec<String>, ChannelMigrationError> {
    let mut statement = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|error| {
            ChannelMigrationError::DbOpen(format!("inspect table {table}: {error}"))
        })?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| ChannelMigrationError::DbOpen(format!("inspect table {table}: {error}")))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| {
            ChannelMigrationError::DbOpen(format!("inspect table {table}: {error}"))
        })?;
    if columns.is_empty() {
        return Err(ChannelMigrationError::Schema(format!(
            "required table {table} is missing"
        )));
    }
    Ok(columns)
}

fn required_text(
    row: &rusqlite::Row<'_>,
    index: usize,
    column: &str,
) -> Result<String, ChannelMigrationError> {
    row.get::<_, String>(index)
        .map_err(|error| ChannelMigrationError::Schema(format!("column {column}: {error}")))
}

fn optional_text(
    row: &rusqlite::Row<'_>,
    index: usize,
    column: &str,
) -> Result<Option<String>, ChannelMigrationError> {
    row.get::<_, Option<String>>(index)
        .map_err(|error| ChannelMigrationError::Schema(format!("column {column}: {error}")))
}

fn read_pack_artifact(path: &Path) -> Result<(ChannelKey, Vec<u8>), ChannelMigrationError> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            ChannelMigrationError::Pack(format!("pack path has no file name: {}", path.display()))
        })?;
    let stem = file_name.strip_suffix(".zip").ok_or_else(|| {
        ChannelMigrationError::Pack(format!("pack must end with .zip: {file_name:?}"))
    })?;
    let mut chars = stem.chars();
    let first = chars.next().ok_or_else(|| {
        ChannelMigrationError::Pack("pack file name must not be empty".to_string())
    })?;
    if !(first.is_ascii_alphabetic() || first == '_')
        || !chars.all(|character: char| character.is_ascii_alphanumeric() || character == '_')
    {
        return Err(ChannelMigrationError::Pack(format!(
            "pack file stem must match ^[a-zA-Z_][a-zA-Z0-9_]*$: {stem:?}"
        )));
    }
    let key = ChannelKey::new(format!("js_{stem}")).map_err(|error| {
        ChannelMigrationError::Pack(format!("pack channel key: {}", error.message()))
    })?;
    let artifact = fs::read(path).map_err(|error| {
        ChannelMigrationError::Read(format!("read pack {}: {error}", path.display()))
    })?;
    Ok((key, artifact))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for byte in digest {
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sensitive_key_rule_is_case_insensitive() {
        for key in [
            "password",
            "API_TOKEN",
            "client_secret",
            "apiKey",
            "session_cookie",
            "CREDENTIAL",
        ] {
            assert!(is_sensitive_key(key), "{key} must be sensitive");
        }
        for key in ["USER", "REGION", "COLOR"] {
            assert!(!is_sensitive_key(key), "{key} must stay plain");
        }
    }

    #[test]
    fn update_pref_helper_is_visible() {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::migration::apply_core_schema(&mut conn).unwrap();
        assert_eq!(
            crate::migration::update_pref(&conn, "missing").unwrap(),
            None
        );
    }
}
