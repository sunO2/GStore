//! Versioned frontend rules: defaults, overrides, and effective merging.
//!
//! Rules are data, not callbacks (Decision 5). `frontend_rules` stores one
//! JSON document per kind (`install` / `update`). Missing rows resolve to the
//! pinned Decision 11 defaults; `effective_*` additionally merges empty or
//! non-positive override fields back to those defaults so a legacy/tampered
//! row can never disable an update check by accident.
//!
//! Invalid rule input — wrong version, malformed JSON, an unknown
//! `signature_policy` — is [`Error::InvalidArgument`] with the stable
//! `CORE_E_RULES_INVALID` prefix.

use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::OptionalExtension;

use crate::db::{DbError, DbHandle};
use crate::error::Error;
use crate::facts::{InstallRules, UpdateRules};

/// Supported rules document version.
pub const RULES_VERSION: i64 = 1;

/// `frontend_rules.kind` for install rules.
pub const KIND_INSTALL: &str = "install";
/// `frontend_rules.kind` for update rules.
pub const KIND_UPDATE: &str = "update";

/// Strict signature verification.
pub const SIGNATURE_POLICY_STRICT: &str = "strict";
/// Warn on signature mismatch but continue.
pub const SIGNATURE_POLICY_WARN: &str = "warn";
/// Skip signature verification.
pub const SIGNATURE_POLICY_OFF: &str = "off";

/// Default install timeout in seconds.
pub const DEFAULT_TIMEOUT_SECS: i64 = 180;
/// Default maximum inventory age in seconds (24 hours).
pub const DEFAULT_MAX_INVENTORY_AGE_SECS: i64 = 86_400;
/// Default ABI preference order.
pub const DEFAULT_ABI_PRIORITY: [&str; 4] =
    ["arm64-v8a", "armeabi-v7a", "x86_64", "x86"];

impl Default for InstallRules {
    fn default() -> Self {
        Self {
            version: RULES_VERSION,
            install_enabled: true,
            abi_priority: DEFAULT_ABI_PRIORITY
                .iter()
                .map(|abi| (*abi).to_string())
                .collect(),
            allow_downgrade: false,
            allow_unknown_sources: false,
            signature_policy: SIGNATURE_POLICY_STRICT.to_string(),
            silent_install: true,
            timeout_secs: DEFAULT_TIMEOUT_SECS,
        }
    }
}

impl Default for UpdateRules {
    fn default() -> Self {
        Self {
            version: RULES_VERSION,
            channel_priority: Vec::new(),
            allow_prerelease: false,
            signature_policy: SIGNATURE_POLICY_STRICT.to_string(),
            max_inventory_age_secs: DEFAULT_MAX_INVENTORY_AGE_SECS,
        }
    }
}

/// Storage for the install and update rule documents.
pub struct RuleStore {
    db: DbHandle,
    clock: fn() -> i64,
}

impl RuleStore {
    /// Creates a store over an already-open core database using wall-clock time.
    pub fn new(db: DbHandle) -> Self {
        Self::with_clock(db, system_now_millis)
    }

    /// Creates a store with an injected millisecond clock for `updated_at`.
    pub fn with_clock(db: DbHandle, clock: fn() -> i64) -> Self {
        Self { db, clock }
    }

    /// Returns the stored install rules, or the pinned defaults.
    pub fn get_install(&self) -> Result<InstallRules, Error> {
        match self.load(KIND_INSTALL)? {
            Some(json) => {
                let rules: InstallRules = parse_rules(KIND_INSTALL, &json)?;
                validate_install(&rules)?;
                Ok(rules)
            }
            None => Ok(InstallRules::default()),
        }
    }

    /// Persists install rules after validation.
    pub fn set_install(&self, rules: &InstallRules) -> Result<(), Error> {
        validate_install(rules)?;
        self.store(KIND_INSTALL, rules.version, rules)
    }

    /// Returns the stored update rules, or the pinned defaults.
    pub fn get_update(&self) -> Result<UpdateRules, Error> {
        match self.load(KIND_UPDATE)? {
            Some(json) => {
                let rules: UpdateRules = parse_rules(KIND_UPDATE, &json)?;
                validate_update(&rules)?;
                Ok(rules)
            }
            None => Ok(UpdateRules::default()),
        }
    }

    /// Persists update rules after validation.
    pub fn set_update(&self, rules: &UpdateRules) -> Result<(), Error> {
        validate_update(rules)?;
        self.store(KIND_UPDATE, rules.version, rules)
    }

    /// Returns install rules with empty/non-positive fields merged to defaults.
    pub fn effective_install(&self) -> Result<InstallRules, Error> {
        let mut rules = self.get_install()?;
        let defaults = InstallRules::default();
        if rules.abi_priority.is_empty() {
            rules.abi_priority = defaults.abi_priority;
        }
        if rules.timeout_secs <= 0 {
            rules.timeout_secs = defaults.timeout_secs;
        }
        Ok(rules)
    }

    /// Returns update rules with non-positive fields merged to defaults.
    pub fn effective_update(&self) -> Result<UpdateRules, Error> {
        let mut rules = self.get_update()?;
        if rules.max_inventory_age_secs <= 0 {
            rules.max_inventory_age_secs = DEFAULT_MAX_INVENTORY_AGE_SECS;
        }
        Ok(rules)
    }

    fn load(&self, kind: &str) -> Result<Option<String>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        let row: Option<(i64, String)> = conn
            .query_row(
                "SELECT version, json FROM frontend_rules WHERE kind=?1",
                [kind],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(sql_error)?;
        match row {
            Some((version, json)) if version == RULES_VERSION => Ok(Some(json)),
            Some((version, _)) => Err(invalid(format!(
                "{kind} version {version} is not supported (expected {RULES_VERSION})"
            ))),
            None => Ok(None),
        }
    }

    fn store<T: serde::Serialize>(&self, kind: &str, version: i64, rules: &T) -> Result<(), Error> {
        let json = serde_json::to_string(rules)
            .map_err(|e| invalid(format!("encode {kind} rules: {e}")))?;
        let updated_at = (self.clock)();
        self.db
            .with_writer(|conn| {
                conn.execute(
                    "INSERT INTO frontend_rules(kind, version, json, updated_at) \
                     VALUES (?1, ?2, ?3, ?4) \
                     ON CONFLICT(kind) DO UPDATE SET \
                         version = excluded.version, \
                         json = excluded.json, \
                         updated_at = excluded.updated_at",
                    rusqlite::params![kind, version, json, updated_at],
                )
                .map_err(|e| DbError(format!("write {kind} rules: {e}")))?;
                Ok(())
            })
            .map_err(db_error)
    }
}

fn parse_rules<T: serde::de::DeserializeOwned>(kind: &str, json: &str) -> Result<T, Error> {
    serde_json::from_str(json).map_err(|e| invalid(format!("parse {kind} rules: {e}")))
}

fn validate_install(rules: &InstallRules) -> Result<(), Error> {
    validate_version(KIND_INSTALL, rules.version)?;
    validate_policy(&rules.signature_policy)?;
    if rules.timeout_secs <= 0 {
        return Err(invalid("install timeout_secs must be positive".to_string()));
    }
    Ok(())
}

fn validate_update(rules: &UpdateRules) -> Result<(), Error> {
    validate_version(KIND_UPDATE, rules.version)?;
    validate_policy(&rules.signature_policy)?;
    if rules.max_inventory_age_secs <= 0 {
        return Err(invalid(
            "update max_inventory_age_secs must be positive".to_string(),
        ));
    }
    Ok(())
}

fn validate_version(kind: &str, version: i64) -> Result<(), Error> {
    if version == RULES_VERSION {
        Ok(())
    } else {
        Err(invalid(format!(
            "{kind} version {version} is not supported (expected {RULES_VERSION})"
        )))
    }
}

fn validate_policy(policy: &str) -> Result<(), Error> {
    if [
        SIGNATURE_POLICY_STRICT,
        SIGNATURE_POLICY_WARN,
        SIGNATURE_POLICY_OFF,
    ]
    .contains(&policy)
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "unknown signature_policy {policy:?} (expected strict | warn | off)"
        )))
    }
}

fn invalid(message: String) -> Error {
    Error::InvalidArgument(format!("CORE_E_RULES_INVALID: {message}"))
}

fn system_now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_millis() as i64)
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
