//! Idempotent bulk import and read-back verification for module-scoped config.
//!
//! This module is the public orchestration layer required by Todo 7 / C9:
//!
//! 1. **Pre-validate every input entry** against the built-in registry
//!    (`unknown key`, JSON type, numeric range, enum set, secret policy).
//! 2. **Reject duplicates** (first occurrence wins; later occurrences are
//!    reported as [`CODE_IMPORT_DUPLICATE`]). This is deliberate: a batch with
//!    the same secret key twice would otherwise write two versioned secret
//!    files and leave one orphaned.
//! 3. **Skip unchanged values.** An entry whose effective value already equals
//!    the input is counted as `unchanged`, never written, never logged, and
//!    never published. This is what makes a repeated import a no-op.
//! 4. **Apply the changed valid subset in exactly one transaction** by reusing
//!    [`ConfigStore::import`] — there is a single transaction implementation,
//!    not two. Invalid entries are excluded from that subset (C9 decision); a
//!    database failure rolls the whole subset back and applies nothing.
//! 5. **Publish exactly one event per applied key** through the committed
//!    [`ConfigBus`], unless the caller explicitly asks for a quiet import.
//! 6. **Never delete entries absent from the input.**
//!
//! # Report semantics
//!
//! [`ImportReport`]:
//!
//! * `total` — number of input entries (duplicates included).
//! * `applied` — entries written in the single transaction.
//! * `unchanged` — valid, unique entries whose effective JSON already matched;
//!   they do **not** count as `applied`, do not bump the revision, and do not
//!   emit an event.
//! * `failed` — `(key, stable code)` for rejected entries; never written.
//! * `events_published` — changes accepted by the bus (0 for quiet imports).
//!
//! Rejected entries are reported by code only; no plaintext value ever reaches
//! a report.
//!
//! # Event policy
//!
//! [`import_batch`] is the default entry point and publishes events
//! (`publish = true`). Restore paths that must not fan out notifications use
//! [`import_quiet`] or [`import_batch_with_events`] with `publish = false`.
//! Unchanged and invalid entries never produce an event in either mode.
//!
//! # Verification
//!
//! [`verify`] reloads the committed database state (so an out-of-band change is
//! visible), then re-reads each key and compares the raw JSON. Sensitive values
//! are compared internally against the secret port; the report carries only a
//! per-key status, never a value. A commit failure during import is returned as
//! [`ConfigStoreError`], in which case nothing was applied.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::bus::ConfigBus;
use super::error::ConfigError;
use super::model::{ConfigChange, ConfigKey, ConfigSource};
use super::schema;
use super::secrets::{is_secret_entry, redact_change_log_value};
use super::store::{ConfigStore, ConfigStoreError};

/// Stable code reported when the same key appears more than once in a batch.
///
/// The first occurrence reserves the key; every later occurrence is rejected
/// and never written (so a duplicated secret can never leave an orphan file).
pub const CODE_IMPORT_DUPLICATE: &str = "config_import_duplicate";

/// Result of an idempotent bulk import.
///
/// See the module docs for the exact meaning of each field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportReport {
    /// Number of input entries, duplicates included.
    pub total: usize,
    /// Entries written in the single transaction.
    pub applied: usize,
    /// Valid, unique entries whose effective value already matched.
    pub unchanged: usize,
    /// Rejected entries as `(key, stable code)`; never written.
    pub failed: Vec<(ConfigKey, String)>,
    /// Changes accepted by the bus (0 when events are suppressed).
    pub events_published: usize,
}

/// Per-key outcome of [`verify`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum VerifyStatus {
    /// Stored raw JSON equals the expected JSON.
    Match,
    /// Stored raw JSON differs from the expected JSON.
    Mismatch,
    /// The key or expected value could not be validated (stable code only).
    Rejected(String),
    /// Reading the committed value failed (stable code only).
    Error(String),
}

/// One key's verification result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerifyResult {
    /// Key that was verified.
    pub key: ConfigKey,
    /// Outcome; never carries a value.
    pub status: VerifyStatus,
}

/// Read-back verification report.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerifyReport {
    /// Number of input entries.
    pub total: usize,
    /// Number of entries whose stored value matched.
    pub matched: usize,
    /// One result per input entry, in input order.
    pub results: Vec<VerifyResult>,
}

impl VerifyReport {
    /// Whether every entry matched.
    pub fn all_matched(&self) -> bool {
        self.matched == self.total
    }
}

/// Imports `entries` and publishes one event per applied key (default).
///
/// This is [`import_batch_with_events`] with `publish = true`.
///
/// # Errors
/// [`ConfigStoreError`] when the store cannot read its cache or the single
/// transaction fails. A failed transaction applies nothing (no rows, no change
/// log, no new secret files) and publishes no events.
pub fn import_batch(
    store: &ConfigStore,
    bus: &ConfigBus,
    entries: &[(ConfigKey, Value)],
    source: ConfigSource,
) -> Result<ImportReport, ConfigStoreError> {
    import_batch_with_events(store, bus, entries, source, true)
}

/// Imports `entries` without publishing any change event.
///
/// Intended for backup restore flows that refresh their own mirrors after the
/// import. Invalid and unchanged entries are still reported.
///
/// # Errors
/// Same as [`import_batch`].
pub fn import_quiet(
    store: &ConfigStore,
    bus: &ConfigBus,
    entries: &[(ConfigKey, Value)],
    source: ConfigSource,
) -> Result<ImportReport, ConfigStoreError> {
    import_batch_with_events(store, bus, entries, source, false)
}

/// Imports `entries`, optionally publishing one event per applied key.
///
/// Validation, duplicate rejection, unchanged detection, and the single
/// transaction are identical in both modes; `publish` only controls the bus
/// fan-out after the commit succeeds.
///
/// # Errors
/// Same as [`import_batch`].
pub fn import_batch_with_events(
    store: &ConfigStore,
    bus: &ConfigBus,
    entries: &[(ConfigKey, Value)],
    source: ConfigSource,
    publish: bool,
) -> Result<ImportReport, ConfigStoreError> {
    let total = entries.len();
    let mut failed: Vec<(ConfigKey, String)> = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    let mut valid: Vec<(&'static super::model::ConfigEntry, &ConfigKey, &Value)> =
        Vec::with_capacity(total);

    for (key, value) in entries {
        if !seen.insert(key.clone()) {
            failed.push((key.clone(), CODE_IMPORT_DUPLICATE.to_string()));
            continue;
        }
        match schema::entry(key) {
            None => failed.push((
                key.clone(),
                ConfigError::UnknownKey {
                    module: key.module().to_string(),
                    key: key.key().to_string(),
                }
                .code()
                .to_string(),
            )),
            Some(entry) => match entry.validate_value(value) {
                Ok(()) => valid.push((entry, key, value)),
                Err(error) => failed.push((key.clone(), error.code().to_string())),
            },
        }
    }

    let mut unchanged = 0usize;
    let mut changed: Vec<(ConfigKey, Value)> = Vec::new();
    let mut old_values: std::collections::BTreeMap<ConfigKey, Option<Value>> =
        std::collections::BTreeMap::new();
    for (_, key, value) in valid {
        let was_set = store.snapshot(key)?.is_some();
        let current = store.get(key)?;
        if current == *value {
            unchanged += 1;
            continue;
        }
        old_values.insert(key.clone(), if was_set { Some(current) } else { None });
        changed.push((key.clone(), value.clone()));
    }

    let applied = if changed.is_empty() {
        0
    } else {
        let report = store.import(&changed, source)?;
        // The store re-validates the same subset. Any rejection here would mean
        // the two validators disagreed, so surface it instead of silently
        // dropping a key from the report.
        failed.extend(report.failed);
        report.applied
    };

    let mut events_published = 0usize;
    if publish && applied > 0 {
        for (key, value) in &changed {
            let Some(entry) = schema::entry(key) else {
                continue;
            };
            let revision = store.snapshot(key)?.map_or(0, |snapshot| snapshot.revision);
            // Mask before constructing the change so plaintext secrets never
            // exist in an event value, even transiently.
            let old_json = if is_secret_entry(entry) {
                None
            } else {
                old_values.get(key).cloned().flatten()
            };
            let change = ConfigChange {
                module: key.module().to_string(),
                key: key.key().to_string(),
                old_json,
                new_json: redact_change_log_value(entry, Some(value)),
                revision,
                source,
                actor: None,
            };
            match bus.publish(&change) {
                Ok(_) => events_published += 1,
                Err(error) => {
                    log::warn!("config: import event publish failed for {key}: {error}");
                }
            }
        }
    }

    Ok(ImportReport {
        total,
        applied,
        unchanged,
        failed,
        events_published,
    })
}

/// Re-reads every committed value and compares it with `entries`.
///
/// The committed state is reloaded from the database first, so a value changed
/// externally after an import is reported as [`VerifyStatus::Mismatch`].
/// Sensitive entries are compared against their raw secret-port value; the
/// report only ever contains per-key statuses.
///
/// # Errors
/// [`ConfigStoreError`] when the committed state cannot be reloaded. Per-key
/// read failures are reported as [`VerifyStatus::Error`] instead of aborting
/// the whole report.
pub fn verify(
    store: &ConfigStore,
    entries: &[(ConfigKey, Value)],
) -> Result<VerifyReport, ConfigStoreError> {
    store.reload_from_db()?;
    let total = entries.len();
    let mut matched = 0usize;
    let mut results = Vec::with_capacity(total);

    for (key, expected) in entries {
        let status = match schema::entry(key) {
            None => VerifyStatus::Rejected(
                ConfigError::UnknownKey {
                    module: key.module().to_string(),
                    key: key.key().to_string(),
                }
                .code()
                .to_string(),
            ),
            Some(entry) => match entry.validate_value(expected) {
                Err(error) => VerifyStatus::Rejected(error.code().to_string()),
                Ok(()) => match store.get(key) {
                    Ok(actual) if actual == *expected => {
                        matched += 1;
                        VerifyStatus::Match
                    }
                    Ok(_) => VerifyStatus::Mismatch,
                    Err(error) => VerifyStatus::Error(error.code().to_string()),
                },
            },
        };
        results.push(VerifyResult {
            key: key.clone(),
            status,
        });
    }

    Ok(VerifyReport {
        total,
        matched,
        results,
    })
}

#[cfg(test)]
mod tests;
