//! Durable, transactional store for the module-scoped configuration.
//!
//! [`ConfigStore`] is the single writer for user configuration. It owns the
//! caller's [`DbHandle`] (the same shared `SharedConn` as `CoreApi`, never a
//! second connection) and a `RwLock` cache of the committed state. Every
//! accepted write runs in exactly one `BEGIN IMMEDIATE` transaction:
//!
//! * upsert `config_entry`,
//! * append the masked `config_change_log` row,
//! * bump `config_meta('revision')`.
//!
//! The in-memory cache is only updated after the commit succeeds.
//!
//! # Sensitive values (C3 / C10)
//!
//! Entries whose registry flag is `sensitive` (or whose visibility is
//! [`super::model::ConfigVisibility::Secret`]) are never written to `value_json` or the
//! change log. Their plaintext lives only in the [`FileSecretPort`] under a
//! fresh, versioned key:
//!
//! ```text
//! config.<module>.<key>.<revision>              // normal form
//! config.h<sha256(module.key)>.<revision>       // when the base key > 128 bytes (C23)
//! ```
//!
//! Write order (C10): decide the content hash, write the new versioned key,
//! commit the row, then swap the cache first and delete the old key last. A
//! commit failure deletes the newly written key **only if** it differs from the
//! old ref; identical content is an idempotent rewrite (`new_ref == old_ref`)
//! that never touches or deletes the live file.
//!
//! `get` holds the cache read guard across the secret file read (and falls back
//! to a fresh DB re-read if the cached ref vanished), so a concurrent rotation
//! can never yield a missing value.
//!
//! # Garbage collection
//!
//! [`ConfigStore::reload_from_db`] runs a namespace-scoped GC under the writer
//! lock. Only keys that start with [`CONFIG_SECRET_PREFIX`] (`config.`) **and**
//! end in a numeric revision suffix are candidates. `channel.*`,
//! `core_config.*`, and every other namespace are never touched. A `config.*`
//! key is preserved when it is referenced by a committed row, is in the
//! in-flight marker set, or has a revision **strictly greater** than the
//! committed `config_meta('revision')` (a writer that has not committed yet).
//! This is the documented in-flight rule: a secret written just before a
//! crash-before-commit is retained rather than deleted out from under a writer.
//!
//! # Semantics
//!
//! * `get` returns the raw committed value (or the registry default when unset).
//! * `get_masked` returns `***` for a sensitive entry when it is set.
//! * `remove` deletes the stored row; reads then fall back to the registry
//!   default.
//! * `reset` persists the registry default as an ordinary write (revision + 1).
//! * `list` returns every registered entry of a module with effective values and
//!   masks sensitive ones; `snapshot`/`snapshots` return only stored entries and
//!   never expose plaintext; `export` is the only raw surface.
//!
//! allow: SIZE_OK — Todo 3 requires the whole persistence surface plus its
//! concurrency/fault-injection tests colocated in this single owned file.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock, RwLockReadGuard, RwLockWriteGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::db::DbHandle;
use crate::error::Error;
use crate::ports::secret::FileSecretPort;

use super::error::ConfigError;
use super::model::{
    ConfigChange, ConfigEntry, ConfigKey, ConfigSource, ConfigValueType,
};
use super::schema;
use super::secrets::{
    is_secret_entry, masked_snapshot_value, redact_change_log_value, secret_ref_for, MASKED,
};

/// Root namespace for versioned config secrets.
///
/// Only keys with this prefix are config-managed; `channel.*`, `core_config.*`,
/// and every other namespace are outside the GC blast radius.
pub const CONFIG_SECRET_PREFIX: &str = "config.";

/// `config_meta` key holding the global monotonic revision.
const REVISION_META_KEY: &str = "revision";

const UPSERT_ENTRY_SQL: &str = "INSERT INTO config_entry(\
         module, key, value_json, secret_ref, secret_hash, value_type, revision, updated_at, updated_by) \
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9) \
     ON CONFLICT(module, key) DO UPDATE SET \
         value_json = excluded.value_json, \
         secret_ref = excluded.secret_ref, \
         secret_hash = excluded.secret_hash, \
         value_type = excluded.value_type, \
         revision = excluded.revision, \
         updated_at = excluded.updated_at, \
         updated_by = excluded.updated_by";

const SELECT_ROW_SQL: &str = "SELECT value_json, secret_ref, secret_hash, revision, updated_at, \
     updated_by FROM config_entry WHERE module=?1 AND key=?2";

const SELECT_ALL_SQL: &str = "SELECT module, key, value_json, secret_ref, secret_hash, revision, \
     updated_at, updated_by FROM config_entry ORDER BY module, key";

/// Error type returned by [`ConfigStore`].
///
/// Validation failures keep their typed [`ConfigError`] (so callers can match
/// `UnknownKey`, `TypeMismatch`, `Validation`, ...); storage/IO failures wrap
/// the crate [`Error`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigStoreError {
    /// The key/value was rejected before any write.
    Config(ConfigError),
    /// A database or secret-port operation failed.
    Core(Error),
}

impl ConfigStoreError {
    /// Stable machine-readable code (`config_...` or the core error code).
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Config(error) => error.code(),
            Self::Core(error) => error.code(),
        }
    }
}

impl fmt::Display for ConfigStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Config(error) => error.fmt(f),
            Self::Core(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for ConfigStoreError {}

impl From<ConfigError> for ConfigStoreError {
    fn from(error: ConfigError) -> Self {
        Self::Config(error)
    }
}

impl From<Error> for ConfigStoreError {
    fn from(error: Error) -> Self {
        Self::Core(error)
    }
}

/// A read-only view of one stored configuration entry.
///
/// `value` is masked (`***`) for sensitive entries in every surface that
/// produces this type; only [`ConfigStore::export`] returns raw values.
#[derive(Debug, Clone, PartialEq)]
pub struct ConfigSnapshot {
    /// Key identity.
    pub key: ConfigKey,
    /// Committed value (masked for sensitive entries).
    pub value: Option<Value>,
    /// Whether `value` was redacted.
    pub masked: bool,
    /// Per-entry revision (0 when unset).
    pub revision: u64,
    /// Last commit time (milliseconds since the Unix epoch).
    pub updated_at: i64,
    /// Optional actor recorded for the last commit.
    pub updated_by: Option<String>,
}

/// One raw entry produced by [`ConfigStore::export`] (backup artifact only).
#[derive(Debug, Clone, PartialEq)]
pub struct ConfigExportEntry {
    /// Key identity.
    pub key: ConfigKey,
    /// Raw, unmasked value (including plaintext secrets).
    pub value: Value,
}

/// Result of a bulk [`ConfigStore::import`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigImportReport {
    /// Number of input entries.
    pub total: usize,
    /// Number applied in the single transaction.
    pub applied: usize,
    /// Rejected entries `(key, stable error code)`; never written.
    pub failed: Vec<(ConfigKey, String)>,
}

/// Committed storage shape for one key.
#[derive(Debug, Clone)]
enum Stored {
    /// Non-sensitive JSON value.
    Value(Value),
    /// Sensitive value held in the secret port (never plaintext here).
    Secret { reference: String },
}

/// Cached committed state for one key.
#[derive(Debug, Clone)]
struct EntryState {
    stored: Option<Stored>,
    revision: u64,
    updated_at: i64,
    updated_by: Option<String>,
}

/// Row loaded directly from `config_entry`.
#[derive(Debug, Clone)]
struct RowState {
    value_json: Option<String>,
    secret_ref: Option<String>,
    secret_hash: Option<String>,
    revision: u64,
    updated_at: i64,
    updated_by: Option<String>,
}

/// Transactional configuration store over the shared core writer.
pub struct ConfigStore {
    db: DbHandle,
    cache: RwLock<BTreeMap<ConfigKey, EntryState>>,
    revision: AtomicU64,
    secrets: Arc<dyn FileSecretPort + Send + Sync>,
    in_flight: Mutex<BTreeSet<String>>,
    loaded: AtomicBool,
}

impl fmt::Debug for ConfigStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Never format the secret port or any cached secret material.
        f.debug_struct("ConfigStore")
            .field("db", &self.db.path())
            .field("revision", &self.revision.load(Ordering::Relaxed))
            .field("cached_entries", &self.cache_size())
            .finish_non_exhaustive()
    }
}

impl ConfigStore {
    /// Creates a store over an already-open core database and secret port.
    ///
    /// The caller passes the *same* [`DbHandle`] (shared `SharedConn`) as the
    /// rest of the core; no second connection is opened. The cache is loaded on
    /// first use (or explicitly with [`ConfigStore::load_all`]).
    pub fn new(db: DbHandle, secrets: Arc<dyn FileSecretPort + Send + Sync>) -> Self {
        Self {
            db,
            cache: RwLock::new(BTreeMap::new()),
            revision: AtomicU64::new(0),
            secrets,
            in_flight: Mutex::new(BTreeSet::new()),
            loaded: AtomicBool::new(false),
        }
    }

    /// Current global revision (last committed write, 0 when never written).
    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::Acquire)
    }

    /// Loads the committed rows and revision into the cache.
    ///
    /// This does not validate or repair secret files; use
    /// [`ConfigStore::reload_from_db`] for the crash/restore path.
    pub fn load_all(&self) -> Result<(), ConfigStoreError> {
        let conn = self.db.reader().map_err(|error| {
            ConfigStoreError::Core(db_error(format!("open reader: {error}")))
        })?;
        let revision = read_meta_revision(&conn)?;
        let states = states_from_rows(read_all_rows(&conn)?);
        {
            let mut cache = self.write_cache()?;
            *cache = states;
        }
        self.revision.store(revision, Ordering::Release);
        self.loaded.store(true, Ordering::Release);
        Ok(())
    }

    /// Re-reads every row, repairs stale secrets, and garbage-collects dead
    /// versioned secret keys under the writer lock.
    ///
    /// Rows whose `secret_ref` file is missing or whose `secret_hash` no longer
    /// matches are persist-cleared (the entry then reads as unset, so an old row
    /// can never be bound to a newer secret). The revision is reset from
    /// `config_meta('revision')`.
    pub fn reload_from_db(&self) -> Result<(), ConfigStoreError> {
        let mut writer = self.db.writer().map_err(|error| {
            ConfigStoreError::Core(db_error(format!("lock writer: {error}")))
        })?;

        let mut states = BTreeMap::new();
        let revision;
        {
            let tx = writer
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(sql_error)?;
            revision = read_meta_revision(&tx)?;
            for (key, row) in read_all_rows(&tx)? {
                if let Some(state) = reload_state(&tx, self.secrets.as_ref(), &key, &row)? {
                    states.insert(key, state);
                }
            }
            tx.commit().map_err(sql_error)?;
        }

        {
            let mut cache = self.write_cache()?;
            *cache = states;
        }
        self.revision.store(revision, Ordering::Release);
        self.loaded.store(true, Ordering::Release);

        self.gc_secrets(revision)?;
        Ok(())
    }

    /// Reads the raw effective value for `key` (trusted owner/Dart/host path).
    ///
    /// Returns the registry default when the entry is unset. Sensitive values
    /// are read from the secret port while the cache read guard is held, so a
    /// concurrent rotation cannot observe a missing value.
    pub fn get(&self, key: &ConfigKey) -> Result<Value, ConfigStoreError> {
        self.ensure_loaded()?;
        let entry = require_entry(key)?;

        let cache = self.read_cache()?;
        match cache.get(key) {
            Some(state) => match &state.stored {
                Some(Stored::Value(value)) => Ok(value.clone()),
                Some(Stored::Secret { reference, .. }) => {
                    match self.secrets.get(reference) {
                        Ok(Some(text)) => decode_secret(entry, &text),
                        Ok(None) => {
                            // The cached ref vanished: re-read the committed row.
                            drop(cache);
                            self.read_value_from_db(key, entry)
                        }
                        Err(error) => Err(ConfigStoreError::Core(error)),
                    }
                }
                None => Ok(entry.default_json.clone()),
            },
            None => {
                drop(cache);
                self.read_value_from_db(key, entry)
            }
        }
    }

    /// Reads the masked effective value (`***` for a set sensitive entry).
    pub fn get_masked(&self, key: &ConfigKey) -> Result<Value, ConfigStoreError> {
        self.ensure_loaded()?;
        let entry = require_entry(key)?;
        if is_secret_entry(entry) {
            let cache = self.read_cache()?;
            if cache
                .get(key)
                .and_then(|state| state.stored.as_ref())
                .is_some()
            {
                return Ok(Value::String(MASKED.to_string()));
            }
        }
        self.get(key)
    }

    /// Sets and commits a value.
    ///
    /// The returned [`ConfigChange`] is already masked for sensitive entries
    /// (safe to publish on the change bus).
    pub fn set(
        &self,
        key: &ConfigKey,
        value: Value,
        source: ConfigSource,
        actor: Option<String>,
    ) -> Result<ConfigChange, ConfigStoreError> {
        let entry = require_entry(key)?;
        entry.validate_value(&value)?;
        self.ensure_loaded()?;

        let now = now_millis();
        let actor_ref = actor.as_deref();
        let mut writer = self.db.writer().map_err(|error| {
            ConfigStoreError::Core(db_error(format!("lock writer: {error}")))
        })?;
        let new_revision = read_meta_revision(&writer)? + 1;
        let old_row = read_row(&writer, key)?;

        let mut new_secret: Option<(String, String)> = None;
        let mut written_secret: Option<String> = None;
        if is_secret_entry(entry) {
            let text = encode_secret(&value)?;
            let new_hash = sha256_hex(text.as_bytes());
            let old_ref = old_row.as_ref().and_then(|row| row.secret_ref.clone());
            let old_hash = old_row.as_ref().and_then(|row| row.secret_hash.clone());
            if old_ref.is_some() && old_hash.as_deref() == Some(new_hash.as_str()) {
                // Identical content: idempotent rewrite, no file write and the
                // live key is kept (`new_ref == old_ref`).
                if let Some(reference) = old_ref {
                    new_secret = Some((reference, new_hash));
                }
            } else {
                let reference = secret_ref_for(key, new_revision);
                self.secrets
                    .set(&reference, &text)
                    .map_err(ConfigStoreError::Core)?;
                self.mark_in_flight(&reference)?;
                written_secret = Some(reference.clone());
                new_secret = Some((reference, new_hash));
            }
        }

        #[cfg(test)]
        let failpoint = take_failpoint();
        #[cfg(test)]
        if let Some(Failpoint::ForceDbFailure) = failpoint {
            self.compensate(written_secret.as_deref());
            return Err(ConfigStoreError::Core(Error::Internal(
                "CORE_E_CONFIG_DB: injected failure after secret write".to_string(),
            )));
        }
        #[cfg(test)]
        if let Some(Failpoint::CrashBeforeCommit) = failpoint {
            // Simulated process death: leave the freshly written key in place so
            // the reload GC's in-flight rule can be observed.
            return Err(ConfigStoreError::Core(Error::Internal(
                "CORE_E_CONFIG_DB: simulated crash before commit".to_string(),
            )));
        }

        let commit_result: Result<(), ConfigStoreError> = (|| {
            let tx = writer
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(sql_error)?;
            write_entry(
                &tx,
                entry,
                key,
                &value,
                new_secret.as_ref(),
                new_revision,
                now,
                actor_ref,
            )?;
            write_change_log(
                &tx,
                entry,
                key,
                old_row.as_ref(),
                Some(&value),
                source,
                actor_ref,
                now,
            )?;
            write_meta_revision(&tx, new_revision)?;
            tx.commit().map_err(sql_error)?;
            Ok(())
        })();
        if let Err(error) = commit_result {
            self.compensate(written_secret.as_deref());
            return Err(error);
        }

        #[cfg(test)]
        if let Some(Failpoint::CrashAfterCommit) = failpoint {
            // Simulated death between commit and old-key deletion: the row is
            // committed, the cache is not swapped, and the old key survives.
            self.clear_in_flight(written_secret.as_deref());
            return Ok(change_for(
                entry,
                key,
                old_row.as_ref(),
                Some(&value),
                new_revision,
                source,
                actor,
            ));
        }

        self.install_cache(
            key,
            entry,
            &value,
            new_secret,
            new_revision,
            now,
            actor.clone(),
            old_row.as_ref(),
        )?;
        self.clear_in_flight(written_secret.as_deref());
        self.revision.fetch_max(new_revision, Ordering::AcqRel);
        Ok(change_for(
            entry,
            key,
            old_row.as_ref(),
            Some(&value),
            new_revision,
            source,
            actor,
        ))
    }

    /// Clears a stored value (reads fall back to the registry default).
    ///
    /// Removing an already-unset key is a no-op that does not bump the revision.
    pub fn remove(
        &self,
        key: &ConfigKey,
        source: ConfigSource,
        actor: Option<String>,
    ) -> Result<ConfigChange, ConfigStoreError> {
        let entry = require_entry(key)?;
        self.ensure_loaded()?;
        let now = now_millis();
        let actor_ref = actor.as_deref();
        let mut writer = self.db.writer().map_err(|error| {
            ConfigStoreError::Core(db_error(format!("lock writer: {error}")))
        })?;

        let Some(old_row) = read_row(&writer, key)? else {
            return Ok(change_for(
                entry,
                key,
                None,
                None,
                self.revision.load(Ordering::Acquire),
                source,
                actor,
            ));
        };
        let new_revision = read_meta_revision(&writer)? + 1;

        let commit_result: Result<(), ConfigStoreError> = (|| {
            let tx = writer
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(sql_error)?;
            tx.execute(
                "DELETE FROM config_entry WHERE module=?1 AND key=?2",
                rusqlite::params![key.module(), key.key()],
            )
            .map_err(sql_error)?;
            write_change_log(
                &tx,
                entry,
                key,
                Some(&old_row),
                None,
                source,
                actor_ref,
                now,
            )?;
            write_meta_revision(&tx, new_revision)?;
            tx.commit().map_err(sql_error)?;
            Ok(())
        })();
        commit_result?;

        {
            let mut cache = self.write_cache()?;
            cache.remove(key);
            if let Some(old_ref) = old_row.secret_ref.as_deref() {
                if let Err(error) = self.secrets.remove(old_ref) {
                    log::warn!("config: failed to remove cleared secret {old_ref}: {error}");
                }
            }
        }
        self.revision.fetch_max(new_revision, Ordering::AcqRel);
        Ok(change_for(
            entry,
            key,
            Some(&old_row),
            None,
            new_revision,
            source,
            actor,
        ))
    }

    /// Restores the registry default, persisted as an ordinary write.
    pub fn reset(
        &self,
        key: &ConfigKey,
        source: ConfigSource,
        actor: Option<String>,
    ) -> Result<ConfigChange, ConfigStoreError> {
        let entry = require_entry(key)?;
        self.set(key, entry.default_json.clone(), source, actor)
    }

    /// Lists every registered entry of `module` with its effective value.
    ///
    /// Unset entries carry the registry default; sensitive entries are masked
    /// (`***`) once set.
    pub fn list(&self, module: &str) -> Result<Vec<ConfigSnapshot>, ConfigStoreError> {
        self.ensure_loaded()?;
        let cache = self.read_cache()?;
        let mut out = Vec::new();
        for entry in schema::module_entries(module) {
            out.push(snapshot_for_list(entry, cache.get(&entry.key)));
        }
        Ok(out)
    }

    /// Returns the stored snapshot for `key`, or `None` when unset.
    pub fn snapshot(&self, key: &ConfigKey) -> Result<Option<ConfigSnapshot>, ConfigStoreError> {
        self.ensure_loaded()?;
        let entry = require_entry(key)?;
        let cache = self.read_cache()?;
        let Some(state) = cache.get(key) else {
            return Ok(None);
        };
        Ok(Some(snapshot_for_state(entry, key, state)))
    }

    /// Returns stored snapshots, filtered by module when `module` is `Some`.
    pub fn snapshots(
        &self,
        module: Option<&str>,
    ) -> Result<Vec<ConfigSnapshot>, ConfigStoreError> {
        self.ensure_loaded()?;
        let cache = self.read_cache()?;
        let mut out = Vec::new();
        for (key, state) in cache.iter() {
            if module.is_some_and(|name| key.module() != name) {
                continue;
            }
            let entry = require_entry(key)?;
            out.push(snapshot_for_state(entry, key, state));
        }
        Ok(out)
    }

    /// Exports every stored entry with **raw** values (backup artifact only).
    pub fn export(&self) -> Result<Vec<ConfigExportEntry>, ConfigStoreError> {
        self.ensure_loaded()?;
        let cache = self.read_cache()?;
        let mut out = Vec::new();
        for (key, state) in cache.iter() {
            let entry = require_entry(key)?;
            let value = match &state.stored {
                Some(Stored::Value(value)) => value.clone(),
                Some(Stored::Secret { reference, .. }) => {
                    let text = self
                        .secrets
                        .get(reference)
                        .map_err(ConfigStoreError::Core)?
                        .ok_or_else(|| {
                            ConfigStoreError::Core(Error::NotFound(format!(
                                "CORE_E_CONFIG_SECRET: missing {reference}"
                            )))
                        })?;
                    decode_secret(entry, &text)?
                }
                None => continue,
            };
            out.push(ConfigExportEntry {
                key: key.clone(),
                value,
            });
        }
        Ok(out)
    }

    /// Applies a batch of entries atomically (C9).
    ///
    /// Every entry is validated first. The valid subset runs in one
    /// `BEGIN IMMEDIATE` transaction; invalid entries are reported and never
    /// written, and a DB failure rolls the whole valid subset back (and deletes
    /// any freshly written secret keys).
    pub fn import(
        &self,
        entries: &[(ConfigKey, Value)],
        source: ConfigSource,
    ) -> Result<ConfigImportReport, ConfigStoreError> {
        self.ensure_loaded()?;
        let mut valid: Vec<(&'static ConfigEntry, &ConfigKey, &Value)> = Vec::new();
        let mut failed: Vec<(ConfigKey, String)> = Vec::new();
        for (key, value) in entries {
            match require_entry(key) {
                Ok(entry) => match entry.validate_value(value) {
                    Ok(()) => valid.push((entry, key, value)),
                    Err(error) => failed.push((key.clone(), error.code().to_string())),
                },
                Err(ConfigStoreError::Config(error)) => {
                    failed.push((key.clone(), error.code().to_string()));
                }
                Err(error) => return Err(error),
            }
        }
        let total = entries.len();

        if valid.is_empty() {
            return Ok(ConfigImportReport {
                total,
                applied: 0,
                failed,
            });
        }

        let now = now_millis();
        let mut writer = self.db.writer().map_err(|error| {
            ConfigStoreError::Core(db_error(format!("lock writer: {error}")))
        })?;
        let base_revision = read_meta_revision(&writer)?;

        struct Prepared<'a> {
            entry: &'static ConfigEntry,
            key: &'a ConfigKey,
            value: &'a Value,
            old_row: Option<RowState>,
            revision: u64,
            secret: Option<(String, String)>,
        }

        let mut prepared: Vec<Prepared<'_>> = Vec::with_capacity(valid.len());
        let mut written_refs: Vec<String> = Vec::new();
        for (index, (entry, key, value)) in valid.iter().enumerate() {
            let revision = base_revision + index as u64 + 1;
            let old_row = read_row(&writer, key)?;
            let mut secret = None;
            if is_secret_entry(entry) {
                let text = encode_secret(value)?;
                let hash = sha256_hex(text.as_bytes());
                let old_ref = old_row.as_ref().and_then(|row| row.secret_ref.clone());
                let old_hash = old_row.as_ref().and_then(|row| row.secret_hash.clone());
                if old_ref.is_some() && old_hash.as_deref() == Some(hash.as_str()) {
                    if let Some(reference) = old_ref {
                        secret = Some((reference, hash));
                    }
                } else {
                    let reference = secret_ref_for(key, revision);
                    if let Err(error) = self.secrets.set(&reference, &text) {
                        self.compensate_many(&written_refs);
                        return Err(ConfigStoreError::Core(error));
                    }
                    self.mark_in_flight(&reference)?;
                    written_refs.push(reference.clone());
                    secret = Some((reference, hash));
                }
            }
            prepared.push(Prepared {
                entry,
                key,
                value,
                old_row,
                revision,
                secret,
            });
        }

        let final_revision = base_revision + prepared.len() as u64;
        let commit_result: Result<(), ConfigStoreError> = (|| {
            let tx = writer
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(sql_error)?;
            for item in &prepared {
                write_entry(
                    &tx,
                    item.entry,
                    item.key,
                    item.value,
                    item.secret.as_ref(),
                    item.revision,
                    now,
                    None,
                )?;
                write_change_log(
                    &tx,
                    item.entry,
                    item.key,
                    item.old_row.as_ref(),
                    Some(item.value),
                    source,
                    None,
                    now,
                )?;
            }
            write_meta_revision(&tx, final_revision)?;
            tx.commit().map_err(sql_error)?;
            Ok(())
        })();
        if let Err(error) = commit_result {
            self.compensate_many(&written_refs);
            return Err(error);
        }

        {
            let mut cache = self.write_cache()?;
            for item in &prepared {
                let stored = if is_secret_entry(item.entry) {
                    match item.secret.clone() {
                        Some((reference, _hash)) => Some(Stored::Secret { reference }),
                        None => continue,
                    }
                } else {
                    Some(Stored::Value(item.value.clone()))
                };
                let new_ref = item
                    .secret
                    .as_ref()
                    .map(|(reference, _)| reference.as_str());
                cache.insert(
                    item.key.clone(),
                    EntryState {
                        stored,
                        revision: item.revision,
                        updated_at: now,
                        updated_by: None,
                    },
                );
                if let Some(old_ref) = item
                    .old_row
                    .as_ref()
                    .and_then(|row| row.secret_ref.as_deref())
                {
                    if Some(old_ref) != new_ref {
                        if let Err(error) = self.secrets.remove(old_ref) {
                            log::warn!(
                                "config: failed to remove replaced secret {old_ref}: {error}"
                            );
                        }
                    }
                }
            }
        }
        self.clear_in_flight_many(&written_refs);
        self.revision.fetch_max(final_revision, Ordering::AcqRel);

        Ok(ConfigImportReport {
            total,
            applied: prepared.len(),
            failed,
        })
    }

    fn ensure_loaded(&self) -> Result<(), ConfigStoreError> {
        if self.loaded.load(Ordering::Acquire) {
            return Ok(());
        }
        self.load_all()
    }

    fn cache_size(&self) -> usize {
        self.cache.read().map_or(0, |cache| cache.len())
    }

    fn read_cache(
        &self,
    ) -> Result<RwLockReadGuard<'_, BTreeMap<ConfigKey, EntryState>>, ConfigStoreError> {
        self.cache.read().map_err(|_| {
            ConfigStoreError::Core(Error::Internal(
                "CORE_E_CONFIG_LOCK: cache read lock poisoned".to_string(),
            ))
        })
    }

    fn write_cache(
        &self,
    ) -> Result<RwLockWriteGuard<'_, BTreeMap<ConfigKey, EntryState>>, ConfigStoreError> {
        self.cache.write().map_err(|_| {
            ConfigStoreError::Core(Error::Internal(
                "CORE_E_CONFIG_LOCK: cache write lock poisoned".to_string(),
            ))
        })
    }

    fn read_value_from_db(
        &self,
        key: &ConfigKey,
        entry: &'static ConfigEntry,
    ) -> Result<Value, ConfigStoreError> {
        let conn = self.db.reader().map_err(|error| {
            ConfigStoreError::Core(db_error(format!("open reader: {error}")))
        })?;
        let Some(row) = read_row(&conn, key)? else {
            return Ok(entry.default_json.clone());
        };
        if let Some(reference) = row.secret_ref.as_deref() {
            if let Some(text) = self.secrets.get(reference).map_err(ConfigStoreError::Core)? {
                return decode_secret(entry, &text);
            }
            // A committed ref whose file is gone reads as unset.
            return Ok(entry.default_json.clone());
        }
        match row.value_json.as_deref() {
            Some(text) => serde_json::from_str(text)
                .map_err(|error| ConfigStoreError::Core(Error::Serialization(error.to_string()))),
            None => Ok(entry.default_json.clone()),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn install_cache(
        &self,
        key: &ConfigKey,
        entry: &'static ConfigEntry,
        value: &Value,
        secret: Option<(String, String)>,
        revision: u64,
        updated_at: i64,
        updated_by: Option<String>,
        old_row: Option<&RowState>,
    ) -> Result<(), ConfigStoreError> {
        let new_ref = secret.as_ref().map(|(reference, _)| reference.clone());
        let mut cache = self.write_cache()?;
        let stored = if is_secret_entry(entry) {
            let Some((reference, _hash)) = secret else {
                return Err(ConfigStoreError::Core(Error::Internal(
                    "CORE_E_CONFIG_SECRET: missing computed secret ref".to_string(),
                )));
            };
            Some(Stored::Secret { reference })
        } else {
            Some(Stored::Value(value.clone()))
        };
        cache.insert(
            key.clone(),
            EntryState {
                stored,
                revision,
                updated_at,
                updated_by,
            },
        );
        if let Some(old_ref) = old_row.and_then(|row| row.secret_ref.as_deref()) {
            if Some(old_ref) != new_ref.as_deref() {
                if let Err(error) = self.secrets.remove(old_ref) {
                    log::warn!("config: failed to remove replaced secret {old_ref}: {error}");
                }
            }
        }
        Ok(())
    }

    fn mark_in_flight(&self, reference: &str) -> Result<(), ConfigStoreError> {
        let mut guard = self.in_flight.lock().map_err(|_| {
            ConfigStoreError::Core(Error::Internal(
                "CORE_E_CONFIG_LOCK: in-flight lock poisoned".to_string(),
            ))
        })?;
        guard.insert(reference.to_string());
        Ok(())
    }

    fn clear_in_flight(&self, reference: Option<&str>) {
        let Some(reference) = reference else {
            return;
        };
        match self.in_flight.lock() {
            Ok(mut guard) => {
                guard.remove(reference);
            }
            Err(_) => log::warn!("config: in-flight lock poisoned while clearing marker"),
        }
    }

    fn clear_in_flight_many(&self, references: &[String]) {
        match self.in_flight.lock() {
            Ok(mut guard) => {
                for reference in references {
                    guard.remove(reference);
                }
            }
            Err(_) => log::warn!("config: in-flight lock poisoned while clearing markers"),
        }
    }

    fn compensate(&self, written: Option<&str>) {
        if let Some(reference) = written {
            if let Err(error) = self.secrets.remove(reference) {
                log::warn!("config: failed to compensate secret {reference}: {error}");
            }
            self.clear_in_flight(Some(reference));
        }
    }

    fn compensate_many(&self, written: &[String]) {
        for reference in written {
            if let Err(error) = self.secrets.remove(reference) {
                log::warn!("config: failed to compensate secret {reference}: {error}");
            }
        }
        self.clear_in_flight_many(written);
    }

    /// Namespace-scoped GC. Caller holds the writer lock.
    fn gc_secrets(&self, committed_revision: u64) -> Result<(), ConfigStoreError> {
        let referenced: BTreeSet<String> = {
            let cache = self.read_cache()?;
            cache
                .values()
                .filter_map(|state| match &state.stored {
                    Some(Stored::Secret { reference, .. }) => Some(reference.clone()),
                    _ => None,
                })
                .collect()
        };
        let in_flight: BTreeSet<String> = match self.in_flight.lock() {
            Ok(guard) => guard.clone(),
            Err(_) => {
                log::warn!("config: in-flight lock poisoned during GC; skipping GC");
                return Ok(());
            }
        };
        let keys = self.secrets.list().map_err(ConfigStoreError::Core)?;
        for key in keys {
            if !is_config_versioned_key(&key) {
                continue;
            }
            if referenced.contains(&key) || in_flight.contains(&key) {
                continue;
            }
            let Some(revision) = version_suffix(&key) else {
                continue;
            };
            if revision > committed_revision {
                // Written by a writer that has not committed yet (or crashed
                // before commit). Preserve it: see the module docs.
                continue;
            }
            if let Err(error) = self.secrets.remove(&key) {
                log::warn!("config: GC failed to remove unreferenced secret {key}: {error}");
            }
        }
        Ok(())
    }
}

fn require_entry(key: &ConfigKey) -> Result<&'static ConfigEntry, ConfigStoreError> {
    schema::entry(key).ok_or_else(|| {
        ConfigStoreError::Config(ConfigError::UnknownKey {
            module: key.module().to_string(),
            key: key.key().to_string(),
        })
    })
}


fn snapshot_for_list(
    entry: &'static ConfigEntry,
    state: Option<&EntryState>,
) -> ConfigSnapshot {
    match state {
        Some(state) => snapshot_for_state(entry, &entry.key, state),
        None => ConfigSnapshot {
            key: entry.key.clone(),
            value: Some(entry.default_json.clone()),
            masked: false,
            revision: 0,
            updated_at: 0,
            updated_by: None,
        },
    }
}

fn snapshot_for_state(
    entry: &'static ConfigEntry,
    key: &ConfigKey,
    state: &EntryState,
) -> ConfigSnapshot {
    let masked = is_secret_entry(entry) && state.stored.is_some();
    let value = match &state.stored {
        Some(Stored::Value(value)) => Some(masked_snapshot_value(entry, value)),
        Some(Stored::Secret { .. }) => Some(Value::String(MASKED.to_string())),
        None => Some(entry.default_json.clone()),
    };
    ConfigSnapshot {
        key: key.clone(),
        value,
        masked,
        revision: state.revision,
        updated_at: state.updated_at,
        updated_by: state.updated_by.clone(),
    }
}

fn change_for(
    entry: &ConfigEntry,
    key: &ConfigKey,
    old_row: Option<&RowState>,
    new_value: Option<&Value>,
    revision: u64,
    source: ConfigSource,
    actor: Option<String>,
) -> ConfigChange {
    let (old_json, new_json) = if is_secret_entry(entry) {
        (None, redact_change_log_value(entry, new_value))
    } else {
        let old = old_row
            .and_then(|row| row.value_json.as_deref())
            .and_then(|text| serde_json::from_str::<Value>(text).ok());
        (old, new_value.cloned())
    };
    ConfigChange {
        module: key.module().to_string(),
        key: key.key().to_string(),
        old_json,
        new_json,
        revision,
        source,
        actor,
    }
}

fn states_from_rows(
    rows: Vec<(ConfigKey, RowState)>,
) -> BTreeMap<ConfigKey, EntryState> {
    let mut states = BTreeMap::new();
    for (key, row) in rows {
        if let Some(state) = state_from_row(&key, &row) {
            states.insert(key, state);
        }
    }
    states
}

fn state_from_row(key: &ConfigKey, row: &RowState) -> Option<EntryState> {
    let stored = if let Some(reference) = row.secret_ref.clone() {
        Some(Stored::Secret { reference })
    } else if let Some(text) = row.value_json.as_deref() {
        match serde_json::from_str::<Value>(text) {
            Ok(value) => Some(Stored::Value(value)),
            Err(error) => {
                log::warn!(
                    "config: skipping malformed value_json for {}.{}: {error}",
                    key.module(),
                    key.key()
                );
                None
            }
        }
    } else {
        None
    };
    stored.map(|stored| EntryState {
        stored: Some(stored),
        revision: row.revision,
        updated_at: row.updated_at,
        updated_by: row.updated_by.clone(),
    })
}

/// Reload helper: validate a sensitive row and persist-clear it when stale.
fn reload_state(
    tx: &Transaction<'_>,
    secrets: &(dyn FileSecretPort + Send + Sync),
    key: &ConfigKey,
    row: &RowState,
) -> Result<Option<EntryState>, ConfigStoreError> {
    if let Some(reference) = row.secret_ref.as_deref() {
        let expected = row.secret_hash.clone().unwrap_or_default();
        let actual = match secrets.get(reference) {
            Ok(text) => text,
            Err(error) => {
                log::warn!(
                    "config: reload could not read secret {reference}: {error}"
                );
                None
            }
        };
        let matches = actual
            .as_deref()
            .filter(|text| !expected.is_empty() && sha256_hex(text.as_bytes()) == expected)
            .is_some();
        if matches {
            return Ok(Some(EntryState {
                stored: Some(Stored::Secret {
                    reference: reference.to_string(),
                }),
                revision: row.revision,
                updated_at: row.updated_at,
                updated_by: row.updated_by.clone(),
            }));
        }
        persist_clear_row(tx, key)?;
        log::warn!(
            "config: cleared stale secret row {}.{} (missing or hash mismatch)",
            key.module(),
            key.key()
        );
        return Ok(None);
    }

    match row.value_json.as_deref() {
        Some(text) => match serde_json::from_str::<Value>(text) {
            Ok(value) => Ok(Some(EntryState {
                stored: Some(Stored::Value(value)),
                revision: row.revision,
                updated_at: row.updated_at,
                updated_by: row.updated_by.clone(),
            })),
            Err(error) => {
                tx.execute(
                    "UPDATE config_entry SET value_json=NULL WHERE module=?1 AND key=?2",
                    rusqlite::params![key.module(), key.key()],
                )
                .map_err(sql_error)?;
                log::warn!(
                    "config: cleared malformed value row {}.{}: {error}",
                    key.module(),
                    key.key()
                );
                Ok(None)
            }
        },
        None => Ok(None),
    }
}

fn persist_clear_row(tx: &Transaction<'_>, key: &ConfigKey) -> Result<(), ConfigStoreError> {
    tx.execute(
        "UPDATE config_entry SET value_json=NULL, secret_ref=NULL, secret_hash=NULL \
         WHERE module=?1 AND key=?2",
        rusqlite::params![key.module(), key.key()],
    )
    .map_err(sql_error)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn write_entry(
    tx: &Transaction<'_>,
    entry: &ConfigEntry,
    key: &ConfigKey,
    value: &Value,
    secret: Option<&(String, String)>,
    revision: u64,
    updated_at: i64,
    updated_by: Option<&str>,
) -> Result<(), ConfigStoreError> {
    let (value_json, secret_ref, secret_hash) = if is_secret_entry(entry) {
        let Some((reference, hash)) = secret else {
            return Err(ConfigStoreError::Core(Error::Internal(
                "CORE_E_CONFIG_SECRET: missing computed secret ref".to_string(),
            )));
        };
        (None, Some(reference.clone()), Some(hash.clone()))
    } else {
        let text = serde_json::to_string(value).map_err(|error| {
            ConfigStoreError::Core(Error::Serialization(error.to_string()))
        })?;
        (Some(text), None, None)
    };
    tx.execute(
        UPSERT_ENTRY_SQL,
        rusqlite::params![
            key.module(),
            key.key(),
            value_json,
            secret_ref,
            secret_hash,
            entry.value_type.as_str(),
            revision as i64,
            updated_at,
            updated_by
        ],
    )
    .map_err(sql_error)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn write_change_log(
    tx: &Transaction<'_>,
    entry: &ConfigEntry,
    key: &ConfigKey,
    old_row: Option<&RowState>,
    new_value: Option<&Value>,
    source: ConfigSource,
    actor: Option<&str>,
    at: i64,
) -> Result<(), ConfigStoreError> {
    let (old_json, new_json) = if is_secret_entry(entry) {
        (
            None,
            new_value.map(|_| MASKED.to_string()),
        )
    } else {
        let old = old_row.and_then(|row| row.value_json.clone());
        let new = new_value
            .map(serde_json::to_string)
            .transpose()
            .map_err(|error| ConfigStoreError::Core(Error::Serialization(error.to_string())))?;
        (old, new)
    };
    tx.execute(
        "INSERT INTO config_change_log(module, key, old_json, new_json, source, actor, at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![
            key.module(),
            key.key(),
            old_json,
            new_json,
            source.as_str(),
            actor,
            at
        ],
    )
    .map_err(sql_error)?;
    Ok(())
}

fn write_meta_revision(tx: &Transaction<'_>, revision: u64) -> Result<(), ConfigStoreError> {
    tx.execute(
        "INSERT INTO config_meta(k, v) VALUES (?1, ?2) \
         ON CONFLICT(k) DO UPDATE SET v=excluded.v",
        rusqlite::params![REVISION_META_KEY, revision.to_string()],
    )
    .map_err(sql_error)?;
    Ok(())
}

fn read_meta_revision(conn: &Connection) -> Result<u64, ConfigStoreError> {
    let raw: Option<String> = conn
        .query_row(
            "SELECT v FROM config_meta WHERE k=?1",
            [REVISION_META_KEY],
            |row| row.get(0),
        )
        .optional()
        .map_err(sql_error)?;
    match raw {
        Some(text) => match text.parse::<u64>() {
            Ok(revision) => Ok(revision),
            Err(error) => {
                log::warn!("config: malformed revision {text:?}: {error}");
                Ok(0)
            }
        },
        None => Ok(0),
    }
}

fn read_row(
    conn: &Connection,
    key: &ConfigKey,
) -> Result<Option<RowState>, ConfigStoreError> {
    conn.query_row(
        SELECT_ROW_SQL,
        rusqlite::params![key.module(), key.key()],
        |row| {
            Ok(RowState {
                value_json: row.get(0)?,
                secret_ref: row.get(1)?,
                secret_hash: row.get(2)?,
                revision: row.get::<_, i64>(3)?.max(0) as u64,
                updated_at: row.get(4)?,
                updated_by: row.get(5)?,
            })
        },
    )
    .optional()
    .map_err(sql_error)
}

fn read_all_rows(
    conn: &Connection,
) -> Result<Vec<(ConfigKey, RowState)>, ConfigStoreError> {
    let mut statement = conn.prepare(SELECT_ALL_SQL).map_err(sql_error)?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                RowState {
                    value_json: row.get(2)?,
                    secret_ref: row.get(3)?,
                    secret_hash: row.get(4)?,
                    revision: row.get::<_, i64>(5)?.max(0) as u64,
                    updated_at: row.get(6)?,
                    updated_by: row.get(7)?,
                },
            ))
        })
        .map_err(sql_error)?;
    let mut out = Vec::new();
    for row in rows {
        let (module, key, state) = row.map_err(sql_error)?;
        match ConfigKey::new(module.clone(), key.clone()) {
            Ok(config_key) => out.push((config_key, state)),
            Err(error) => log::warn!(
                "config: skipping malformed row {module}.{key}: {error}"
            ),
        }
    }
    Ok(out)
}

fn is_config_versioned_key(secret_key: &str) -> bool {
    secret_key.starts_with(CONFIG_SECRET_PREFIX) && version_suffix(secret_key).is_some()
}

fn version_suffix(secret_key: &str) -> Option<u64> {
    secret_key.rsplit('.').next()?.parse::<u64>().ok()
}

fn encode_secret(value: &Value) -> Result<String, ConfigStoreError> {
    match value {
        Value::String(text) => Ok(text.clone()),
        other => serde_json::to_string(other)
            .map_err(|error| ConfigStoreError::Core(Error::Serialization(error.to_string()))),
    }
}

fn decode_secret(
    entry: &ConfigEntry,
    text: &str,
) -> Result<Value, ConfigStoreError> {
    if matches!(entry.value_type, ConfigValueType::String) {
        Ok(Value::String(text.to_string()))
    } else {
        serde_json::from_str(text)
            .map_err(|error| ConfigStoreError::Core(Error::Serialization(error.to_string())))
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

fn db_error(message: String) -> Error {
    Error::Internal(format!("CORE_E_CONFIG_DB: {message}"))
}

fn sql_error(error: rusqlite::Error) -> ConfigStoreError {
    ConfigStoreError::Core(db_error(error.to_string()))
}

fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Failpoint {
    /// Inject a DB failure after the secret decision/write; compensation runs.
    ForceDbFailure,
    /// Simulate process death after the secret write and before commit; the
    /// freshly written key is intentionally left behind.
    CrashBeforeCommit,
    /// Simulate process death after commit and before old-key deletion; the
    /// cache is not swapped and the old key survives until the next reload GC.
    CrashAfterCommit,
}

#[cfg(test)]
thread_local! {
    static FAILPOINT: std::cell::Cell<Option<Failpoint>> = const { std::cell::Cell::new(None) };
}

#[cfg(test)]
fn set_failpoint(failpoint: Failpoint) {
    FAILPOINT.with(|cell| cell.set(Some(failpoint)));
}

#[cfg(test)]
fn take_failpoint() -> Option<Failpoint> {
    FAILPOINT.with(std::cell::Cell::take)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};

    use rusqlite::Connection;
    use serde_json::json;

    use super::*;
    use crate::ports::secret::{FileSecretStore, MAX_SECRET_KEY_LEN};

    fn temp_root(tag: &str) -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "gstore_cfg_store_{tag}_{}_{}_{}",
            std::process::id(),
            now_millis(),
            counter
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create temp root");
        dir
    }

    fn key(module: &str, name: &str) -> ConfigKey {
        ConfigKey::new(module, name).expect("valid test key")
    }

    struct Fixture {
        root: PathBuf,
        db: DbHandle,
        secrets: Arc<FileSecretStore>,
    }

    impl Fixture {
        fn new(tag: &str) -> Self {
            let root = temp_root(tag);
            let db = DbHandle::open(&root.join("data")).expect("open core db");
            let secrets = Arc::new(FileSecretStore::new(root.join("secrets")));
            Self { root, db, secrets }
        }

        fn store(&self) -> ConfigStore {
            let store = ConfigStore::new(self.db.clone(), self.secrets.clone());
            store.load_all().expect("load all");
            store
        }

        fn conn(&self) -> Connection {
            Connection::open(self.db.path()).expect("open raw connection")
        }

        fn secret_keys(&self) -> Vec<String> {
            self.secrets.list().expect("list secrets")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn count(conn: &Connection, sql: &str) -> i64 {
        conn.query_row(sql, [], |row| row.get(0)).expect("count query")
    }

    fn stored_ref(fx: &Fixture, module: &str, name: &str) -> Option<String> {
        let conn = fx.conn();
        conn.query_row(
            "SELECT secret_ref FROM config_entry WHERE module=?1 AND key=?2",
            rusqlite::params![module, name],
            |row| row.get(0),
        )
        .optional()
        .expect("read secret_ref")
        .flatten()
    }

    #[test]
    fn config_store_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ConfigStore>();
    }

    #[test]
    fn set_get_round_trip_typed_values_and_revision_increments() {
        let fx = Fixture::new("roundtrip");
        let store = fx.store();
        let cases = [
            (
                key("download", "multi_segment.enabled"),
                json!(false),
            ),
            (key("download", "max_concurrent"), json!(7)),
            (key("update", "channel"), json!("beta")),
            (key("theme", "config"), json!({"fontStyle": 3})),
            (
                key("discovery", "selected_channels"),
                json!(["alpha", "beta"]),
            ),
        ];
        let mut last = 0u64;
        for (config_key, value) in &cases {
            let change = store
                .set(config_key, value.clone(), ConfigSource::User, Some("tester".into()))
                .expect("set");
            assert!(
                change.revision > last,
                "revision must increase: {} after {last}",
                change.revision
            );
            last = change.revision;
            assert_eq!(store.get(config_key).expect("get"), *value);
        }
        assert_eq!(store.revision(), last);

        let fresh = fx.store();
        fresh.reload_from_db().expect("reload");
        assert_eq!(fresh.revision(), last);
        for (config_key, value) in &cases {
            assert_eq!(fresh.get(config_key).expect("get"), *value);
        }
    }

    #[test]
    fn rejects_unknown_type_range_and_enum_before_any_write() {
        let fx = Fixture::new("validation");
        let store = fx.store();

        let unknown = key("download", "nope");
        assert!(matches!(
            store.set(&unknown, json!(true), ConfigSource::User, None),
            Err(ConfigStoreError::Config(ConfigError::UnknownKey { .. }))
        ));

        let concurrent = key("download", "max_concurrent");
        assert!(matches!(
            store.set(&concurrent, json!("7"), ConfigSource::User, None),
            Err(ConfigStoreError::Config(ConfigError::TypeMismatch { .. }))
        ));
        assert!(matches!(
            store.set(&concurrent, json!(0), ConfigSource::User, None),
            Err(ConfigStoreError::Config(ConfigError::Validation { .. }))
        ));
        assert!(matches!(
            store.set(&concurrent, json!(11), ConfigSource::User, None),
            Err(ConfigStoreError::Config(ConfigError::Validation { .. }))
        ));

        let channel = key("update", "channel");
        assert!(matches!(
            store.set(&channel, json!("nightly"), ConfigSource::User, None),
            Err(ConfigStoreError::Config(ConfigError::Validation { .. }))
        ));

        let theme = key("theme", "config");
        assert!(matches!(
            store.set(&theme, json!("not-an-object"), ConfigSource::User, None),
            Err(ConfigStoreError::Config(ConfigError::TypeMismatch { .. }))
        ));

        assert_eq!(store.revision(), 0, "rejected writes must not bump revision");
        let conn = fx.conn();
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM config_entry"), 0);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM config_change_log"), 0);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM config_meta"), 0);
    }

    #[test]
    fn sensitive_value_uses_secret_port_and_masks_every_surface() {
        let fx = Fixture::new("secret");
        let store = fx.store();
        let password = key("webdav", "password");
        assert_eq!(
            store.get(&password).expect("default"),
            json!(""),
            "unset sensitive entry reads its default"
        );
        store
            .set(&password, json!("hunter2"), ConfigSource::User, Some("app".into()))
            .expect("set secret");

        let conn = fx.conn();
        let (value_json, secret_ref, secret_hash): (Option<String>, Option<String>, Option<String>) =
            conn.query_row(
                "SELECT value_json, secret_ref, secret_hash FROM config_entry \
                 WHERE module='webdav' AND key='password'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("row");
        assert_eq!(value_json, None, "secret plaintext must never be in value_json");
        let reference = secret_ref.expect("secret ref");
        assert!(
            reference.starts_with("config.webdav.password."),
            "unexpected ref {reference}"
        );
        let expected_hash = sha256_hex(b"hunter2");
        assert_eq!(secret_hash.as_deref(), Some(expected_hash.as_str()));
        assert_eq!(
            fx.secrets.get(&reference).expect("read file").as_deref(),
            Some("hunter2")
        );

        assert_eq!(store.get(&password).expect("raw get"), json!("hunter2"));
        assert_eq!(
            store.get_masked(&password).expect("masked get"),
            json!("***")
        );

        let listed = store.list("webdav").expect("list");
        let entry = listed
            .iter()
            .find(|snapshot| snapshot.key == password)
            .expect("password listed");
        assert!(entry.masked);
        assert_eq!(entry.value, Some(json!("***")));

        for snapshot in store.snapshots(None).expect("snapshots") {
            if let Some(value) = snapshot.value {
                assert_ne!(value, json!("hunter2"), "snapshots must exclude plaintext");
            }
        }

        let exported = store.export().expect("export");
        let raw = exported
            .iter()
            .find(|entry| entry.key == password)
            .expect("password exported");
        assert_eq!(raw.value, json!("hunter2"), "export is the raw surface");

        let (old_json, new_json): (Option<String>, Option<String>) = conn
            .query_row(
                "SELECT old_json, new_json FROM config_change_log \
                 WHERE module='webdav' AND key='password'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("change log row");
        assert_eq!(old_json, None);
        assert_eq!(new_json.as_deref(), Some("***"));

        let dump: String = conn
            .query_row(
                "SELECT COALESCE(group_concat(old_json), '') || '|' || \
                        COALESCE(group_concat(new_json), '') \
                 FROM config_change_log",
                [],
                |row| row.get(0),
            )
            .expect("dump log");
        assert!(!dump.contains("hunter2"), "change log leaked plaintext: {dump}");

        let debug = format!("{store:?}");
        assert!(!debug.contains("hunter2"), "Debug leaked a secret: {debug}");
    }

    #[test]
    fn idempotent_content_hash_rewrite_keeps_the_live_secret() {
        let fx = Fixture::new("idempotent");
        let store = fx.store();
        let password = key("webdav", "password");

        let first = store
            .set(&password, json!("same"), ConfigSource::User, None)
            .expect("first set");
        let refs = fx.secret_keys();
        assert_eq!(refs.len(), 1);
        let reference = refs[0].clone();

        let second = store
            .set(&password, json!("same"), ConfigSource::User, None)
            .expect("idempotent set");
        assert!(
            second.revision > first.revision,
            "an accepted write still bumps the revision"
        );
        assert_eq!(
            fx.secret_keys(),
            refs,
            "idempotent rewrite must not delete or duplicate the live secret"
        );
        assert_eq!(store.get(&password).expect("get"), json!("same"));
        assert_eq!(stored_ref(&fx, "webdav", "password"), Some(reference));

        // Forced DB failure during the idempotent rewrite: no file write, so the
        // live file and the visible value must both survive.
        set_failpoint(Failpoint::ForceDbFailure);
        let error = store
            .set(&password, json!("same"), ConfigSource::User, None)
            .expect_err("forced failure");
        assert!(matches!(error, ConfigStoreError::Core(Error::Internal(_))));
        assert_eq!(fx.secret_keys(), refs, "idempotent failure must keep the file");
        assert_eq!(store.get(&password).expect("get"), json!("same"));
    }

    #[test]
    fn forced_db_failure_after_secret_write_compensates() {
        let fx = Fixture::new("dbfail");
        let store = fx.store();
        let password = key("webdav", "password");
        store
            .set(&password, json!("v1"), ConfigSource::User, None)
            .expect("seed secret");
        let before = fx.secret_keys();
        let old_ref = before[0].clone();

        set_failpoint(Failpoint::ForceDbFailure);
        let error = store
            .set(&password, json!("v2"), ConfigSource::User, None)
            .expect_err("forced failure");
        assert!(matches!(error, ConfigStoreError::Core(Error::Internal(_))));

        assert_eq!(
            fx.secret_keys(),
            before,
            "newly written secret key must be compensated"
        );
        assert_eq!(
            store.get(&password).expect("visible value"),
            json!("v1"),
            "visible value must be unchanged after a failed write"
        );
        assert_eq!(
            stored_ref(&fx, "webdav", "password"),
            Some(old_ref),
            "row must still point at the old secret"
        );
        let conn = fx.conn();
        let value_json: Option<String> = conn
            .query_row(
                "SELECT value_json FROM config_entry WHERE module='webdav' AND key='password'",
                [],
                |row| row.get(0),
            )
            .expect("row");
        assert_eq!(value_json, None);
    }

    #[test]
    fn crash_before_commit_retains_old_value_and_in_flight_key() {
        let fx = Fixture::new("crash_before");
        let store = fx.store();
        let password = key("webdav", "password");
        store
            .set(&password, json!("v1"), ConfigSource::User, None)
            .expect("seed");
        let before = fx.secret_keys();
        let old_ref = before[0].clone();
        let committed = store.revision();

        set_failpoint(Failpoint::CrashBeforeCommit);
        let error = store
            .set(&password, json!("v2"), ConfigSource::User, None)
            .expect_err("simulated crash");
        assert!(matches!(error, ConfigStoreError::Core(Error::Internal(_))));
        drop(store);

        let after_crash = fx.secret_keys();
        assert_eq!(after_crash.len(), 2, "crash leaves the in-flight key behind");
        let new_ref = after_crash
            .iter()
            .find(|reference| **reference != old_ref)
            .cloned()
            .expect("new in-flight ref");
        assert!(
            version_suffix(&new_ref).expect("rev") > committed,
            "in-flight key must be newer than the committed revision"
        );

        let restarted = fx.store();
        restarted.reload_from_db().expect("reload");
        assert_eq!(
            restarted.get(&password).expect("get"),
            json!("v1"),
            "crash-before-commit retains the old value"
        );
        assert_eq!(restarted.revision(), committed);
        let after_reload = fx.secret_keys();
        assert!(after_reload.contains(&old_ref));
        assert!(
            after_reload.contains(&new_ref),
            "in-flight key is preserved by the documented GC rule"
        );
        assert_eq!(stored_ref(&fx, "webdav", "password"), Some(old_ref));
    }

    #[test]
    fn crash_after_commit_keeps_new_value_and_gc_removes_old_key() {
        let fx = Fixture::new("crash_after");
        let store = fx.store();
        let password = key("webdav", "password");
        store
            .set(&password, json!("v1"), ConfigSource::User, None)
            .expect("seed");
        let old_ref = fx.secret_keys()[0].clone();
        let before = store.revision();

        set_failpoint(Failpoint::CrashAfterCommit);
        let change = store
            .set(&password, json!("v2"), ConfigSource::User, None)
            .expect("commit succeeds");
        assert!(change.revision > before);
        drop(store);

        let after_crash = fx.secret_keys();
        assert_eq!(after_crash.len(), 2, "old key survives the simulated crash");
        let new_ref = after_crash
            .iter()
            .find(|reference| **reference != old_ref)
            .cloned()
            .expect("new ref");
        assert_eq!(
            stored_ref(&fx, "webdav", "password"),
            Some(new_ref.clone()),
            "the row is already committed before the simulated crash"
        );

        let restarted = fx.store();
        restarted.reload_from_db().expect("reload");
        assert_eq!(restarted.get(&password).expect("get"), json!("v2"));
        assert_eq!(restarted.revision(), change.revision);
        let after_reload = fx.secret_keys();
        assert!(after_reload.contains(&new_ref));
        assert!(
            !after_reload.contains(&old_ref),
            "old key must be garbage-collected on reload"
        );
    }

    #[test]
    fn reload_gc_is_namespace_scoped_and_preserves_in_flight_keys() {
        let fx = Fixture::new("gc");
        let store = fx.store();
        store
            .set(
                &key("download", "max_concurrent"),
                json!(5),
                ConfigSource::User,
                None,
            )
            .expect("seed write");
        let committed = store.revision();
        let password = key("webdav", "password");
        store
            .set(&password, json!("live"), ConfigSource::User, None)
            .expect("secret write");
        let referenced = fx.secret_keys()[0].clone();

        let dead = format!("config.download.max_concurrent.{committed}");
        let in_flight = format!("config.download.max_concurrent.{}", committed + 7);
        fx.secrets.set("channel.secret.1", "x").expect("channel");
        fx.secrets
            .set("core_config.legacy", "y")
            .expect("core_config");
        fx.secrets.set(&dead, "z").expect("dead config key");
        fx.secrets.set(&in_flight, "w").expect("in-flight key");
        fx.secrets
            .set("config.unversioned", "u")
            .expect("unversioned key");

        store.reload_from_db().expect("reload");
        let keys = fx.secret_keys();
        assert!(keys.contains(&referenced), "referenced key must survive");
        assert!(!keys.contains(&dead), "dead config key must be GC'd");
        assert!(
            keys.contains(&in_flight),
            "newer-than-committed key is in-flight and preserved"
        );
        assert!(
            keys.contains(&"channel.secret.1".to_string()),
            "channel.* namespace must never be touched"
        );
        assert!(
            keys.contains(&"core_config.legacy".to_string()),
            "core_config.* namespace must never be touched"
        );
        assert!(
            keys.contains(&"config.unversioned".to_string()),
            "a non-versioned config key is not a GC candidate"
        );
    }

    #[test]
    fn remove_and_reset_semantics() {
        let fx = Fixture::new("remove_reset");
        let store = fx.store();
        let concurrent = key("download", "max_concurrent");
        let set = store
            .set(&concurrent, json!(7), ConfigSource::User, None)
            .expect("set");
        assert_eq!(store.get(&concurrent).expect("get"), json!(7));

        let removed = store
            .remove(&concurrent, ConfigSource::User, None)
            .expect("remove");
        assert!(removed.revision > set.revision);
        assert_eq!(removed.new_json, None);
        assert_eq!(
            store.get(&concurrent).expect("get"),
            json!(3),
            "remove falls back to the registry default"
        );
        assert!(store.snapshot(&concurrent).expect("snapshot").is_none());

        let again = store
            .remove(&concurrent, ConfigSource::User, None)
            .expect("remove again");
        assert_eq!(
            again.revision, removed.revision,
            "removing an unset key is a no-op"
        );

        let reset = store
            .reset(&concurrent, ConfigSource::User, None)
            .expect("reset");
        assert!(reset.revision > removed.revision);
        assert_eq!(store.get(&concurrent).expect("get"), json!(3));
        assert!(
            store.snapshot(&concurrent).expect("snapshot").is_some(),
            "reset persists the default"
        );

        let password = key("webdav", "password");
        store
            .set(&password, json!("secret"), ConfigSource::User, None)
            .expect("set secret");
        assert_eq!(fx.secret_keys().len(), 1);
        store
            .remove(&password, ConfigSource::User, None)
            .expect("remove secret");
        assert!(
            fx.secret_keys().is_empty(),
            "clearing a secret removes its file"
        );
        assert_eq!(store.get(&password).expect("get"), json!(""));
    }

    #[test]
    fn reload_restores_cache_and_revision_from_meta() {
        let fx = Fixture::new("reload");
        let writer = fx.store();
        writer
            .set(
                &key("download", "max_concurrent"),
                json!(9),
                ConfigSource::User,
                None,
            )
            .expect("set");
        writer
            .set(
                &key("webdav", "password"),
                json!("pw"),
                ConfigSource::User,
                None,
            )
            .expect("set secret");
        let revision = writer.revision();
        drop(writer);

        let reader = ConfigStore::new(fx.db.clone(), fx.secrets.clone());
        reader.reload_from_db().expect("reload");
        assert_eq!(reader.revision(), revision);
        assert_eq!(
            reader.get(&key("download", "max_concurrent")).expect("get"),
            json!(9)
        );
        assert_eq!(
            reader.get(&key("webdav", "password")).expect("get"),
            json!("pw")
        );

        let conn = fx.conn();
        let meta: String = conn
            .query_row("SELECT v FROM config_meta WHERE k='revision'", [], |row| {
                row.get(0)
            })
            .expect("meta");
        assert_eq!(meta, revision.to_string());
    }

    #[test]
    fn reload_persist_clears_missing_or_mismatched_secrets() {
        let fx = Fixture::new("stale");
        let store = fx.store();
        let password = key("webdav", "password");
        store
            .set(&password, json!("v1"), ConfigSource::User, None)
            .expect("set");
        let reference = fx.secret_keys()[0].clone();

        // Missing file: the row is cleared and reads as unset.
        fx.secrets.remove(&reference).expect("remove file");
        store.reload_from_db().expect("reload");
        assert_eq!(store.get(&password).expect("get"), json!(""));
        assert_eq!(stored_ref(&fx, "webdav", "password"), None);

        // Hash mismatch: an old row must never bind to a newer/other secret.
        store
            .set(&password, json!("v2"), ConfigSource::User, None)
            .expect("set again");
        let reference = fx.secret_keys()[0].clone();
        fx.secrets.set(&reference, "tampered").expect("tamper");
        store.reload_from_db().expect("reload");
        assert_eq!(store.get(&password).expect("get"), json!(""));
        assert_eq!(stored_ref(&fx, "webdav", "password"), None);
    }

    #[test]
    fn import_applies_valid_subset_atomically() {
        let fx = Fixture::new("import");
        let store = fx.store();
        let batch = vec![
            (key("download", "max_concurrent"), json!(6)),
            (key("download", "wifi_only"), json!(true)),
            (key("download", "nope"), json!(1)),
            (key("update", "channel"), json!("nightly")),
            (key("webdav", "password"), json!("pw")),
        ];
        let report = store.import(&batch, ConfigSource::Restore).expect("import");
        assert_eq!(report.total, 5);
        assert_eq!(report.applied, 3);
        assert_eq!(report.failed.len(), 2);
        assert_eq!(
            store.get(&key("download", "max_concurrent")).expect("get"),
            json!(6)
        );
        assert_eq!(
            store.get(&key("webdav", "password")).expect("get"),
            json!("pw")
        );
        assert_eq!(
            store.get(&key("update", "channel")).expect("get"),
            json!("stable"),
            "invalid entries are never written"
        );
        assert_eq!(store.revision(), 3, "one revision per applied entry");
        assert_eq!(fx.secret_keys().len(), 1, "imported secret uses the secret port");
        let conn = fx.conn();
        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM config_change_log"),
            3
        );
    }

    #[test]
    fn secret_ref_hashes_keys_that_exceed_the_secret_limit() {
        let long = ConfigKey::new("a".repeat(64), "b".repeat(64)).expect("long key");
        let reference = secret_ref_for(&long, 42);
        assert!(
            reference.len() <= MAX_SECRET_KEY_LEN,
            "hashed ref exceeds the limit: {}",
            reference.len()
        );
        assert!(reference.starts_with(CONFIG_SECRET_PREFIX));
        assert!(reference.contains("config.h"), "expected a hashed ref: {reference}");
        assert_eq!(version_suffix(&reference), Some(42));
        assert_eq!(reference, secret_ref_for(&long, 42), "deterministic");

        let other = ConfigKey::new("a".repeat(64), "c".repeat(64)).expect("other key");
        assert_ne!(reference, secret_ref_for(&other, 42));

        assert_eq!(
            secret_ref_for(&key("webdav", "password"), 7),
            "config.webdav.password.7"
        );
    }

    #[test]
    fn concurrent_sets_and_secret_rotation_never_miss() {
        let fx = Fixture::new("concurrency");
        let store = Arc::new(fx.store());
        let password = key("webdav", "password");
        store
            .set(&password, json!("seed"), ConfigSource::User, None)
            .expect("seed secret");

        let modules = [
            "channel",
            "download",
            "backup",
            "webdav",
            "fdroid",
            "theme",
            "install",
            "aggregate",
        ];
        let stop = Arc::new(AtomicBool::new(false));
        let revisions = Arc::new(Mutex::new(Vec::<u64>::new()));

        let reader = {
            let store = Arc::clone(&store);
            let stop = Arc::clone(&stop);
            let password = password.clone();
            std::thread::spawn(move || {
                let mut observed = 0usize;
                while !stop.load(Ordering::Relaxed) {
                    let value = store.get(&password).expect("reader must never fail");
                    assert!(
                        value.is_string(),
                        "reader must never observe a missing secret"
                    );
                    observed += 1;
                }
                observed
            })
        };

        let rotator = {
            let store = Arc::clone(&store);
            let stop = Arc::clone(&stop);
            let password = password.clone();
            let revisions = Arc::clone(&revisions);
            std::thread::spawn(move || {
                let mut written = 0u64;
                for index in 0..200u64 {
                    let change = store
                        .set(
                            &password,
                            json!(format!("rotated-{index}")),
                            ConfigSource::Module,
                            Some("rotator".into()),
                        )
                        .expect("rotation must succeed");
                    revisions.lock().expect("revisions lock").push(change.revision);
                    written += 1;
                }
                stop.store(true, Ordering::Relaxed);
                written
            })
        };

        let mut writers = Vec::new();
        for (index, module) in modules.iter().enumerate() {
            let store = Arc::clone(&store);
            let revisions = Arc::clone(&revisions);
            let module = (*module).to_string();
            writers.push(std::thread::spawn(move || {
                let config_key =
                    ConfigKey::new("module", format!("{module}.enabled")).expect("toggle key");
                let value = index % 2 == 0;
                for _ in 0..20 {
                    let change = store
                        .set(
                            &config_key,
                            json!(value),
                            ConfigSource::User,
                            Some(module.clone()),
                        )
                        .expect("writer set");
                    revisions.lock().expect("revisions lock").push(change.revision);
                }
                (config_key, value)
            }));
        }

        let rotated = rotator.join().expect("rotator join");
        assert_eq!(rotated, 200);
        let observed = reader.join().expect("reader join");
        assert!(observed > 0, "reader must have observed at least one value");

        let mut expected = Vec::new();
        for handle in writers {
            let (config_key, value) = handle.join().expect("writer join");
            expected.push((config_key, value));
        }

        let mut all_revisions = revisions.lock().expect("revisions lock").clone();
        all_revisions.sort_unstable();
        let total = all_revisions.len();
        assert_eq!(total, 8 * 20 + 200);
        // The seed write claimed revision 1; every later write is contiguous
        // from 2 onward with no gaps and no duplicates (no lost writes).
        let expected_revisions: Vec<u64> = (2..=total as u64 + 1).collect();
        assert_eq!(
            all_revisions, expected_revisions,
            "revisions must be contiguous and monotonic with no lost writes"
        );

        for (config_key, value) in expected {
            assert_eq!(
                store.get(&config_key).expect("final value"),
                json!(value),
                "lost write for {config_key}"
            );
        }
        assert_eq!(store.revision(), total as u64 + 1);
        assert_eq!(
            store.get(&password).expect("final secret"),
            json!("rotated-199")
        );
    }
}
