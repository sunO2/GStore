//! Persistent profile store (Todo 12 of the proxy kernel plan).
//!
//! Backs `profile.list/get/create/update/delete/refresh` with files under
//! `<data_dir>/profiles/`. The canonical profile/node model is **Todo 11's**
//! [`crate::subscription::ImportedProfile`] — this module never re-parses
//! subscription content; it only persists and enumerates the already-parsed
//! model.
//!
//! ## On-disk layout (schema v2)
//!
//! ```text
//! <data_dir>/profiles/
//!   index.json        ProfileIndex — schemaVersion, revision, nextId, summaries[]
//!   <id>.json         StoredProfile — schemaVersion, id, timestamps,
//!                     optional refresh/appBackup, and the full ImportedProfile
//! ```
//!
//! Every write is atomic: a sibling temp file is written, `fsync`ed, then
//! `rename`d over the destination (same directory, so the rename is atomic on
//! every supported filesystem), then the directory is `fsync`ed best-effort.
//! A reader therefore always sees either the complete old file or the complete
//! new file — never a partial one. The payload is the source of truth; the
//! index is an enumeration/cache. A per-profile payload that fails to parse is
//! reported as a structured warning and skipped, so one corrupt file never
//! hides the valid profiles.
//!
//! ## Credentials / secrets
//!
//! `ProxyNode` carries `password`/`uuid` fields. They are stored **only** in
//! the per-profile payload under the module's app-private data directory
//! (`<app documents>/gstore_mods/proxy/profiles/`, i.e. inside the app
//! sandbox). The module never copies them to shared storage, the cache
//! directory, logs, or `profile.list` summaries. If the app later adds a
//! backup/restore transport it must treat this directory as sensitive; see
//! [`APP_BACKUP_HOOK`].
//!
//! ## Schema versioning & migration
//!
//! Current schema is [`SCHEMA_VERSION`] (2). v1 (the pre-Todo-12 shape: an
//! index with a top-level `version` and a payload that was the bare
//! `ImportedProfile`) is migrated on read by [`parse_index`] /
//! [`parse_payload`]. A version newer than [`SCHEMA_VERSION`] is rejected with
//! `PROXY_PROFILE_SCHEMA_UNSUPPORTED` so an older module never corrupts data
//! written by a newer one.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use gstore_contract::error::{ModuleError, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::subscription::{ImportSource, ImportedProfile, SubscriptionUserinfo};

/// Current on-disk schema version for both the index and each payload.
pub(crate) const SCHEMA_VERSION: u32 = 2;

/// Directory (relative to `data_dir`) that holds the store.
pub(crate) const PROFILES_DIR: &str = "profiles";
const INDEX_FILE: &str = "index.json";

/// Hard bounds so the store cannot grow without limit.
const MAX_PROFILES: usize = 4096;
const MAX_NODES: usize = 4096;
const MAX_INDEX_BYTES: u64 = 4 * 1024 * 1024;
const MAX_PAYLOAD_BYTES: u64 = 32 * 1024 * 1024;

/// Hook for the app-level backup/restore format (`lib/core/service/backup_service.dart`,
/// `lib/core/config/AppConfig.dart`). The module does **not** read or write the
/// app backup format and does not depend on it: every record is plain JSON and
/// the whole store lives under `data_dir/profiles/`, so the app can embed the
/// records (including the opaque `appBackup` field preserved verbatim per
/// profile) under a key of its choosing. Treat the directory as sensitive —
/// it contains credentials.
#[allow(dead_code)]
pub const APP_BACKUP_HOOK: &str = "data_dir/profiles/ is a JSON tree; per-record `appBackup` is preserved verbatim for the app's backup format";

pub(crate) const ERR_PROFILE_NOT_FOUND: &str = "PROXY_PROFILE_NOT_FOUND";
pub(crate) const ERR_PROFILE_INVALID: &str = "PROXY_PROFILE_INVALID";
pub(crate) const ERR_PROFILE_STORE_FAILED: &str = "PROXY_PROFILE_STORE_FAILED";
pub(crate) const ERR_PROFILE_CORRUPT: &str = "PROXY_PROFILE_CORRUPT";
pub(crate) const ERR_PROFILE_MISSING: &str = "PROXY_PROFILE_MISSING";
pub(crate) const ERR_PROFILE_TOO_LARGE: &str = "PROXY_PROFILE_TOO_LARGE";
pub(crate) const ERR_PROFILE_SCHEMA_UNSUPPORTED: &str = "PROXY_PROFILE_SCHEMA_UNSUPPORTED";
pub(crate) const ERR_PROFILE_NOT_REFRESHABLE: &str = "PROXY_PROFILE_NOT_REFRESHABLE";
pub(crate) const ERR_PROFILE_REFRESH_BACKOFF: &str = "PROXY_PROFILE_REFRESH_BACKOFF";

static STORE_LOCK: Mutex<()> = Mutex::new(());
static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

/// Serialize all store mutations (and reads) so two concurrent C ABI calls
/// cannot interleave a payload write with an index write.
fn lock_store() -> std::sync::MutexGuard<'static, ()> {
    STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// Test-only fault injection for the atomic-write path.
#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum WriteFault {
    #[default]
    None,
    /// Simulate a crash after the temp file was written+fsynced but before the
    /// rename: the destination must be untouched and no temp residue left.
    FailBeforeRename,
    /// Simulate a failure right after the temp file write.
    FailAfterTempWrite,
}

// ============================ models ============================

/// One stored profile record — the per-profile payload. Wraps Todo 11's
/// canonical [`ImportedProfile`] with store metadata.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StoredProfile {
    #[serde(default = "current_schema_version")]
    pub schema_version: u32,
    pub id: String,
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub created_at_ms: u64,
    #[serde(default)]
    pub updated_at_ms: u64,
    /// Refresh bookkeeping. Todo 14 owns performing the fetch; this module owns
    /// the persisted flag and the `FetchSpec` it reads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh: Option<RefreshState>,
    /// Opaque metadata reserved for the app's backup/restore format. Preserved
    /// verbatim; the module never interprets it (see [`APP_BACKUP_HOOK`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_backup: Option<Value>,
    pub profile: ImportedProfile,
}

/// Compact projection returned by `profile.list` (no nodes, so it cannot leak
/// credentials embedded in node protocol params).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProfileSummary {
    pub id: String,
    pub name: String,
    pub format: String,
    pub node_count: usize,
    pub group_count: usize,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_origin: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub userinfo: Option<SubscriptionUserinfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh: Option<RefreshState>,
}

impl ProfileSummary {
    fn from_record(record: &StoredProfile) -> Self {
        Self {
            id: record.id.clone(),
            name: record.profile.name.clone(),
            format: record.profile.format.clone(),
            node_count: record.profile.node_count,
            group_count: record.profile.groups.len(),
            created_at_ms: record.created_at_ms,
            updated_at_ms: record.updated_at_ms,
            revision: record.revision,
            source_origin: {
                let origin = record.profile.source.origin.clone();
                if origin.is_empty() {
                    None
                } else {
                    Some(origin)
                }
            },
            source_url: record.profile.source.url.clone(),
            userinfo: record.profile.userinfo.clone(),
            refresh: record.refresh.clone(),
        }
    }
}

/// Persisted refresh bookkeeping.
///
/// `state` is one of `idle|requested|done|failed`. The scheduling fields
/// (`last_updated_at_ms`, `interval_ms`, `next_refresh_at_ms`) are Todo 14's
/// per-profile auto-update metadata; `consecutive_failures` drives the bounded
/// backoff so a failing subscription is never retried in a tight loop.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RefreshState {
    pub state: String,
    #[serde(default)]
    pub requested_at_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_attempt_ms: Option<u64>,
    #[serde(default)]
    pub attempts: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Structured error code of the last failure (e.g. `PROXY_SUB_FETCH_FAILED`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    /// Last successful refresh (drives `nextRefreshAtMs` with `intervalMs`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_updated_at_ms: Option<u64>,
    /// User-configured auto-update interval in ms; `null` = manual only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interval_ms: Option<u64>,
    /// Failures since the last success (reset to 0 on success).
    #[serde(default)]
    pub consecutive_failures: u32,
    /// Earliest time a non-forced refresh may run (backoff or interval).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_refresh_at_ms: Option<u64>,
}

impl Default for RefreshState {
    fn default() -> Self {
        Self {
            state: "idle".to_string(),
            requested_at_ms: 0,
            last_attempt_ms: None,
            attempts: 0,
            error: None,
            error_code: None,
            last_updated_at_ms: None,
            interval_ms: None,
            consecutive_failures: 0,
            next_refresh_at_ms: None,
        }
    }
}

/// Bounded exponential backoff between failed refreshes: 30s, 60s, 2m, 4m, …
/// capped at 6h. Never returns 0, so a failed refresh is always rate-limited.
pub(crate) fn refresh_backoff_ms(consecutive_failures: u32) -> u64 {
    const BASE_MS: u64 = 30_000;
    const CAP_MS: u64 = 6 * 60 * 60 * 1000;
    let shift = consecutive_failures.saturating_sub(1).min(20);
    BASE_MS.saturating_mul(1u64 << shift).min(CAP_MS)
}

/// What `profile.refresh` hands to Todo 14: the canonical source plus the
/// exact arguments to pass to `profile.import_url`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct FetchSpec {
    pub url: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_agent: Option<String>,
}

/// Result of `profile.refresh` (store/refresh-flag side only; the fetch itself
/// is Todo 14's).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RefreshPlan {
    pub profile_id: String,
    pub refreshable: bool,
    pub state: String,
    pub requested_at_ms: u64,
    pub attempts: u32,
    pub source: ImportSource,
    pub fetch: Option<FetchSpec>,
    pub profile: StoredProfile,
}

/// Structured refresh failure carried by [`RefreshResult`] and the
/// `proxy.subscription.failed` event.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RefreshError {
    pub code: String,
    pub message: String,
}

/// Outcome of a performed refresh (Todo 14). On failure the previous profile is
/// preserved and `error` carries the structured cause; `retryAfterMs` is the
/// remaining bounded-backoff window.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RefreshResult {
    pub profile_id: String,
    pub state: String,
    pub attempts: u32,
    pub node_count: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub userinfo: Option<SubscriptionUserinfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_updated_at_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interval_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_refresh_at_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_after_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<RefreshError>,
    pub profile: StoredProfile,
}

/// A structured, non-fatal store warning (corrupt/missing sibling file).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct StoreWarning {
    pub code: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    pub message: String,
}

/// `profile.list` result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProfileList {
    pub schema_version: u32,
    pub revision: u64,
    pub count: usize,
    pub profiles: Vec<ProfileSummary>,
    pub warnings: Vec<StoreWarning>,
}

/// `profile.delete` result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DeleteOutcome {
    pub ok: bool,
    pub id: String,
    pub deleted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ProfileIndex {
    #[serde(default = "current_schema_version")]
    pub schema_version: u32,
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub next_id: u64,
    #[serde(default)]
    pub profiles: Vec<ProfileSummary>,
}

impl ProfileIndex {
    fn fresh() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            revision: 0,
            next_id: 1,
            profiles: Vec::new(),
        }
    }
}

fn current_schema_version() -> u32 {
    SCHEMA_VERSION
}

// ============================ request payloads ============================

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IdRequest {
    id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RefreshRequest {
    id: String,
    #[serde(default)]
    force: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScheduleRequest {
    id: String,
    #[serde(default)]
    interval_ms: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RefreshAllRequest {
    #[serde(default)]
    pub force: bool,
    #[serde(default)]
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateRequest {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    profile: Option<ImportedProfile>,
    #[serde(default)]
    app_backup: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateRequest {
    id: String,
    #[serde(default)]
    profile: Option<ImportedProfile>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    app_backup: Option<Value>,
    #[serde(default)]
    refresh: Option<RefreshPatch>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RefreshPatch {
    state: String,
    #[serde(default)]
    error: Option<String>,
}

// ============================ error helpers ============================

fn store_failed(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InternalError, ERR_PROFILE_STORE_FAILED, message)
}

fn profile_invalid(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_PROFILE_INVALID, message)
}

fn not_found(id: &str) -> ModuleError {
    ModuleError::new(
        StatusCode::ModuleNotFound,
        ERR_PROFILE_NOT_FOUND,
        format!("profile not found: {id}"),
    )
}

fn too_large(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::ResourceExhausted, ERR_PROFILE_TOO_LARGE, message)
}

fn schema_unsupported(version: u32) -> ModuleError {
    ModuleError::new(
        StatusCode::InvalidArgument,
        ERR_PROFILE_SCHEMA_UNSUPPORTED,
        format!("profile schema version {version} is newer than supported {SCHEMA_VERSION}"),
    )
}

fn parse_json<T: for<'de> Deserialize<'de>>(payload: &[u8], method: &str) -> Result<T, ModuleError> {
    if payload.is_empty() {
        return Err(ModuleError::invalid_arg(format!(
            "{method} requires a JSON object payload"
        )));
    }
    serde_json::from_slice(payload)
        .map_err(|e| ModuleError::invalid_arg(format!("{method} payload JSON: {e}")))
}

fn validate_id(id: &str) -> Result<(), ModuleError> {
    if id.is_empty()
        || id.len() > 64
        || !id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(profile_invalid(
            "profile id must match [A-Za-z0-9_-]{1,64}",
        ));
    }
    Ok(())
}

fn numeric_suffix(id: &str) -> Option<u64> {
    let digits: String = id.chars().skip_while(|c| !c.is_ascii_digit()).collect();
    if digits.is_empty() {
        None
    } else {
        digits.parse::<u64>().ok()
    }
}

fn validate_profile(profile: &mut ImportedProfile) -> Result<(), ModuleError> {
    let name = profile.name.trim().to_string();
    if name.is_empty() {
        return Err(profile_invalid("profile name must not be empty"));
    }
    if profile.nodes.is_empty() {
        return Err(profile_invalid("profile contains no nodes"));
    }
    if profile.nodes.len() > MAX_NODES {
        return Err(too_large(format!(
            "profile contains more than {MAX_NODES} nodes"
        )));
    }
    profile.name = name;
    // Normalize the derived count; this is not parsing, just consistency.
    profile.node_count = profile.nodes.len();
    Ok(())
}

/// Stable `profile.list` sort key: `(createdAtMs asc, id asc)`. Creation time
/// is monotonic per profile and the id tie-break makes the order total and
/// independent of filesystem/hash iteration order.
fn sort_key(record: &StoredProfile) -> (u64, &str) {
    (record.created_at_ms, record.id.as_str())
}

fn sort_index(index: &mut ProfileIndex) {
    index.profiles.sort_by(|a, b| {
        (a.created_at_ms, a.id.as_str()).cmp(&(b.created_at_ms, b.id.as_str()))
    });
}

// ============================ migration ============================

fn declared_version(value: &Value) -> u32 {
    value
        .get("schemaVersion")
        .and_then(Value::as_u64)
        .or_else(|| value.get("version").and_then(Value::as_u64))
        .unwrap_or(1) as u32
}

/// Parse an index file, running the v1→v2 migration when needed.
fn parse_index(bytes: &[u8]) -> Result<ProfileIndex, ModuleError> {
    let value: Value = serde_json::from_slice(bytes)
        .map_err(|e| ModuleError::new(StatusCode::InternalError, ERR_PROFILE_CORRUPT, format!("index JSON: {e}")))?;
    match declared_version(&value) {
        1 => migrate_index_v1(value),
        v if v == SCHEMA_VERSION => serde_json::from_value(value).map_err(|e| {
            ModuleError::new(
                StatusCode::InternalError,
                ERR_PROFILE_CORRUPT,
                format!("index schema v{v}: {e}"),
            )
        }),
        v if v > SCHEMA_VERSION => Err(schema_unsupported(v)),
        v => Err(schema_unsupported(v)),
    }
}

/// v1 index: `{ "version": 1, "profiles": [{ id, name, nodeCount, createdAtMs }] }`.
/// v2 adds `schemaVersion`, `revision`, `nextId` and the richer summary fields.
fn migrate_index_v1(value: Value) -> Result<ProfileIndex, ModuleError> {
    let mut index = ProfileIndex::fresh();
    let profiles = value
        .get("profiles")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut next_id = 1u64;
    for entry in profiles {
        let id = entry
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if validate_id(&id).is_err() {
            continue;
        }
        if let Some(n) = numeric_suffix(&id) {
            next_id = next_id.max(n + 1);
        }
        let created = entry.get("createdAtMs").and_then(Value::as_u64).unwrap_or(0);
        index.profiles.push(ProfileSummary {
            id,
            name: entry
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("profile")
                .to_string(),
            format: entry
                .get("format")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string(),
            node_count: entry.get("nodeCount").and_then(Value::as_u64).unwrap_or(0) as usize,
            group_count: 0,
            created_at_ms: created,
            updated_at_ms: created,
            revision: 1,
            source_origin: None,
            source_url: None,
            userinfo: None,
            refresh: None,
        });
    }
    index.next_id = next_id;
    index.revision = 1;
    sort_index(&mut index);
    Ok(index)
}

/// Parse a per-profile payload, running the v1→v2 migration when needed.
/// `id_hint`/`created_hint` come from the index because v1 payloads carried
/// neither an id nor timestamps.
fn parse_payload(
    bytes: &[u8],
    id_hint: &str,
    created_hint: u64,
) -> Result<StoredProfile, ModuleError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|e| {
        ModuleError::new(
            StatusCode::InternalError,
            ERR_PROFILE_CORRUPT,
            format!("payload JSON: {e}"),
        )
    })?;
    match declared_version(&value) {
        1 => {
            // v1 payload was the bare ImportedProfile JSON.
            let profile: ImportedProfile = serde_json::from_value(value).map_err(|e| {
                ModuleError::new(
                    StatusCode::InternalError,
                    ERR_PROFILE_CORRUPT,
                    format!("payload v1: {e}"),
                )
            })?;
            Ok(StoredProfile {
                schema_version: SCHEMA_VERSION,
                id: id_hint.to_string(),
                revision: 1,
                created_at_ms: created_hint,
                updated_at_ms: created_hint,
                refresh: None,
                app_backup: None,
                profile,
            })
        }
        v if v == SCHEMA_VERSION => serde_json::from_value(value).map_err(|e| {
            ModuleError::new(
                StatusCode::InternalError,
                ERR_PROFILE_CORRUPT,
                format!("payload schema v{v}: {e}"),
            )
        }),
        v if v > SCHEMA_VERSION => Err(schema_unsupported(v)),
        v => Err(schema_unsupported(v)),
    }
}

// ============================ the store ============================

pub(crate) struct ProfileStore {
    root: PathBuf,
    index_path: PathBuf,
    #[cfg(test)]
    fault: WriteFault,
}

impl ProfileStore {
    /// Open (creating if needed) the store under `<data_dir>/profiles/`.
    pub(crate) fn open(data_dir: &str) -> Result<Self, ModuleError> {
        let dir = data_dir.trim();
        if dir.is_empty() {
            return Err(store_failed(
                "module data_dir is empty; profiles cannot be persisted",
            ));
        }
        let root = Path::new(dir).join(PROFILES_DIR);
        fs::create_dir_all(&root)
            .map_err(|e| store_failed(format!("create {}: {e}", root.display())))?;
        Ok(Self {
            index_path: root.join(INDEX_FILE),
            root,
            #[cfg(test)]
            fault: WriteFault::None,
        })
    }

    #[cfg(test)]
    pub(crate) fn open_with_fault(data_dir: &str, fault: WriteFault) -> Result<Self, ModuleError> {
        let mut store = Self::open(data_dir)?;
        store.fault = fault;
        Ok(store)
    }

    fn payload_path(&self, id: &str) -> PathBuf {
        self.root.join(format!("{id}.json"))
    }

    /// Atomic write: temp + fsync + rename (+ best-effort directory fsync).
    fn atomic_write(&self, path: &Path, bytes: &[u8]) -> Result<(), ModuleError> {
        let dir = path
            .parent()
            .ok_or_else(|| store_failed("write path has no parent directory"))?;
        fs::create_dir_all(dir).map_err(|e| store_failed(format!("create {}: {e}", dir.display())))?;
        let file_name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("file");
        let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
        let tmp = dir.join(format!(".{file_name}.tmp-{}-{seq}", std::process::id()));

        let write_result = (|| -> std::io::Result<()> {
            use std::io::Write as _;
            let mut file = fs::File::create(&tmp)?;
            file.write_all(bytes)?;
            file.sync_all()?;
            Ok(())
        })();
        if let Err(e) = write_result {
            let _ = fs::remove_file(&tmp);
            return Err(store_failed(format!("write {}: {e}", tmp.display())));
        }

        #[cfg(test)]
        {
            match self.fault {
                WriteFault::FailAfterTempWrite => {
                    let _ = fs::remove_file(&tmp);
                    return Err(store_failed("injected failure after temp write"));
                }
                WriteFault::FailBeforeRename => {
                    let _ = fs::remove_file(&tmp);
                    return Err(store_failed("injected failure before rename"));
                }
                WriteFault::None => {}
            }
        }

        if let Err(e) = fs::rename(&tmp, path) {
            let _ = fs::remove_file(&tmp);
            return Err(store_failed(format!(
                "rename {} -> {}: {e}",
                tmp.display(),
                path.display()
            )));
        }
        // Best-effort durability of the rename itself.
        if let Ok(d) = fs::File::open(dir) {
            let _ = d.sync_all();
        }
        Ok(())
    }

    fn write_index(&self, index: &ProfileIndex) -> Result<(), ModuleError> {
        let mut index = index.clone();
        index.schema_version = SCHEMA_VERSION;
        let bytes = serde_json::to_vec_pretty(&index)
            .map_err(|e| store_failed(format!("index serialize: {e}")))?;
        if bytes.len() as u64 > MAX_INDEX_BYTES {
            return Err(too_large("profile index exceeds the size cap"));
        }
        self.atomic_write(&self.index_path, &bytes)
    }

    fn write_payload(&self, record: &StoredProfile) -> Result<(), ModuleError> {
        validate_id(&record.id)?;
        let bytes = serde_json::to_vec_pretty(record)
            .map_err(|e| store_failed(format!("profile serialize: {e}")))?;
        if bytes.len() as u64 > MAX_PAYLOAD_BYTES {
            return Err(too_large("profile payload exceeds the size cap"));
        }
        self.atomic_write(&self.payload_path(&record.id), &bytes)
    }

    fn read_payload(&self, id: &str, created_hint: u64) -> Result<StoredProfile, ModuleError> {
        validate_id(id)?;
        let path = self.payload_path(id);
        let bytes = fs::read(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                not_found(id)
            } else {
                store_failed(format!("read {}: {e}", path.display()))
            }
        })?;
        if bytes.len() as u64 > MAX_PAYLOAD_BYTES {
            return Err(too_large(format!("profile '{id}' exceeds the size cap")));
        }
        parse_payload(&bytes, id, created_hint)
    }

    /// Read the index, rebuilding it from the directory when it is corrupt.
    fn read_index_best_effort(&self) -> (ProfileIndex, Vec<StoreWarning>) {
        let mut warnings = Vec::new();
        match fs::read(&self.index_path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                (ProfileIndex::fresh(), warnings)
            }
            Err(e) => {
                warnings.push(StoreWarning {
                    code: ERR_PROFILE_CORRUPT.to_string(),
                    id: None,
                    file: Some(INDEX_FILE.to_string()),
                    message: format!("index unreadable ({e}); rebuilt from directory"),
                });
                (self.rebuild_index(&mut warnings), warnings)
            }
            Ok(bytes) => match parse_index(&bytes) {
                Ok(index) => (index, warnings),
                Err(e) => {
                    warnings.push(StoreWarning {
                        code: ERR_PROFILE_CORRUPT.to_string(),
                        id: None,
                        file: Some(INDEX_FILE.to_string()),
                        message: format!("{}; rebuilt from directory", e.message),
                    });
                    (self.rebuild_index(&mut warnings), warnings)
                }
            },
        }
    }

    /// Rebuild the index by scanning every `<id>.json` payload. Corrupt files
    /// become warnings; valid ones are enumerated. The repaired index is
    /// persisted best-effort.
    fn rebuild_index(&self, warnings: &mut Vec<StoreWarning>) -> ProfileIndex {
        let mut index = ProfileIndex::fresh();
        let entries = match fs::read_dir(&self.root) {
            Ok(entries) => entries,
            Err(e) => {
                warnings.push(StoreWarning {
                    code: ERR_PROFILE_CORRUPT.to_string(),
                    id: None,
                    file: Some(PROFILES_DIR.to_string()),
                    message: format!("cannot scan profile directory: {e}"),
                });
                return index;
            }
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if path.extension().and_then(|e| e.to_str()) != Some("json") || name == INDEX_FILE {
                continue;
            }
            let Some(id) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if validate_id(id).is_err() {
                continue;
            }
            match fs::read(&path) {
                Ok(bytes) => match parse_payload(&bytes, id, 0) {
                    Ok(record) => {
                        if let Some(n) = numeric_suffix(id) {
                            index.next_id = index.next_id.max(n + 1);
                        }
                        index.profiles.push(ProfileSummary::from_record(&record));
                    }
                    Err(e) => warnings.push(StoreWarning {
                        code: ERR_PROFILE_CORRUPT.to_string(),
                        id: Some(id.to_string()),
                        file: Some(name.to_string()),
                        message: e.message,
                    }),
                },
                Err(e) => warnings.push(StoreWarning {
                    code: ERR_PROFILE_MISSING.to_string(),
                    id: Some(id.to_string()),
                    file: Some(name.to_string()),
                    message: format!("cannot read payload: {e}"),
                }),
            }
        }
        sort_index(&mut index);
        index.revision = 1;
        let _ = self.write_index(&index);
        index
    }

    fn created_hint(&self, index: &ProfileIndex, id: &str) -> u64 {
        index
            .profiles
            .iter()
            .find(|s| s.id == id)
            .map(|s| s.created_at_ms)
            .unwrap_or(0)
    }

    fn upsert_summary(index: &mut ProfileIndex, record: &StoredProfile) {
        let summary = ProfileSummary::from_record(record);
        if let Some(slot) = index.profiles.iter_mut().find(|s| s.id == record.id) {
            *slot = summary;
        } else {
            index.profiles.push(summary);
        }
        sort_index(index);
    }

    // ---------------------------- operations ----------------------------

    /// `profile.list`: enumerates payloads in stable order and reports corrupt
    /// siblings as warnings without failing.
    pub(crate) fn list(&self) -> Result<ProfileList, ModuleError> {
        let (index, mut warnings) = self.read_index_best_effort();
        let mut records: Vec<StoredProfile> = Vec::new();
        for summary in &index.profiles {
            match self.read_payload(&summary.id, summary.created_at_ms) {
                Ok(record) => records.push(record),
                Err(e) => {
                    let code = if e.code == ERR_PROFILE_NOT_FOUND {
                        ERR_PROFILE_MISSING
                    } else {
                        ERR_PROFILE_CORRUPT
                    };
                    warnings.push(StoreWarning {
                        code: code.to_string(),
                        id: Some(summary.id.clone()),
                        file: Some(format!("{}.json", summary.id)),
                        message: e.message,
                    });
                }
            }
        }
        records.sort_by(|a, b| sort_key(a).cmp(&sort_key(b)));
        let profiles: Vec<ProfileSummary> =
            records.iter().map(ProfileSummary::from_record).collect();
        Ok(ProfileList {
            schema_version: SCHEMA_VERSION,
            revision: index.revision,
            count: profiles.len(),
            profiles,
            warnings,
        })
    }

    /// `profile.get`.
    pub(crate) fn get(&self, payload: &[u8]) -> Result<StoredProfile, ModuleError> {
        let req: IdRequest = parse_json(payload, "profile.get")?;
        let (index, _w) = self.read_index_best_effort();
        let created = self.created_hint(&index, &req.id);
        self.read_payload(&req.id, created)
    }

    /// `profile.create`: persist an already-parsed [`ImportedProfile`].
    pub(crate) fn create(&self, payload: &[u8]) -> Result<StoredProfile, ModuleError> {
        let req: CreateRequest = parse_json(payload, "profile.create")?;
        let mut profile = req
            .profile
            .ok_or_else(|| profile_invalid("profile.create requires a `profile` object"))?;
        validate_profile(&mut profile)?;

        let _g = lock_store();
        let (mut index, _w) = self.read_index_best_effort();
        if index.profiles.len() >= MAX_PROFILES {
            return Err(too_large(format!(
                "profile store is full ({MAX_PROFILES} profiles)"
            )));
        }

        let id = match req.id.as_deref() {
            Some(requested) => {
                validate_id(requested)?;
                if index.profiles.iter().any(|s| s.id == requested) {
                    return Err(profile_invalid(format!(
                        "profile id already exists: {requested}"
                    )));
                }
                requested.to_string()
            }
            None => format!("p{}", index.next_id.max(1)),
        };
        if let Some(name) = req.name.as_deref() {
            let name = name.trim();
            if name.is_empty() {
                return Err(profile_invalid("profile name must not be empty"));
            }
            profile.name = name.to_string();
        }

        let now = crate::now_ms();
        let record = StoredProfile {
            schema_version: SCHEMA_VERSION,
            id: id.clone(),
            revision: 1,
            created_at_ms: now,
            updated_at_ms: now,
            refresh: None,
            app_backup: req.app_backup,
            profile,
        };

        self.write_payload(&record)?;
        if let Some(n) = numeric_suffix(&id) {
            index.next_id = index.next_id.max(n + 1);
        }
        Self::upsert_summary(&mut index, &record);
        index.revision += 1;
        if let Err(e) = self.write_index(&index) {
            // Keep the store consistent: an un-enumerable payload is worse than
            // no payload at all.
            let _ = fs::remove_file(self.payload_path(&id));
            return Err(e);
        }
        log_message(format!("profile.create id={id} nodes={}", record.profile.node_count));
        Ok(record)
    }

    /// `profile.update`: replace the profile and/or metadata (name, the opaque
    /// `appBackup` field, or refresh bookkeeping).
    pub(crate) fn update(&self, payload: &[u8]) -> Result<StoredProfile, ModuleError> {
        let req: UpdateRequest = parse_json(payload, "profile.update")?;
        validate_id(&req.id)?;
        if req.profile.is_none()
            && req.name.is_none()
            && req.app_backup.is_none()
            && req.refresh.is_none()
        {
            return Err(profile_invalid(
                "profile.update requires `profile`, `name`, `appBackup`, or `refresh`",
            ));
        }

        let _g = lock_store();
        let (mut index, _w) = self.read_index_best_effort();
        if !index.profiles.iter().any(|s| s.id == req.id) {
            return Err(not_found(&req.id));
        }
        let created = self.created_hint(&index, &req.id);
        let mut record = self.read_payload(&req.id, created)?;
        let mut content_changed = false;

        if let Some(mut profile) = req.profile {
            validate_profile(&mut profile)?;
            record.profile = profile;
            content_changed = true;
        }
        if let Some(name) = req.name.as_deref() {
            let name = name.trim();
            if name.is_empty() {
                return Err(profile_invalid("profile name must not be empty"));
            }
            record.profile.name = name.to_string();
            content_changed = true;
        }
        if let Some(backup) = req.app_backup {
            record.app_backup = if backup.is_null() { None } else { Some(backup) };
        }
        if let Some(patch) = req.refresh {
            apply_refresh_patch(&mut record, patch)?;
        }

        let now = crate::now_ms();
        record.updated_at_ms = now;
        if content_changed {
            record.revision += 1;
        }
        record.schema_version = SCHEMA_VERSION;

        self.write_payload(&record)?;
        Self::upsert_summary(&mut index, &record);
        index.revision += 1;
        self.write_index(&index)?;
        log_message(format!(
            "profile.update id={} revision={} contentChanged={content_changed}",
            record.id, record.revision
        ));
        Ok(record)
    }

    /// `profile.delete`: remove the payload and its index entry.
    pub(crate) fn delete(&self, payload: &[u8]) -> Result<DeleteOutcome, ModuleError> {
        let req: IdRequest = parse_json(payload, "profile.delete")?;
        validate_id(&req.id)?;

        let _g = lock_store();
        let (mut index, _w) = self.read_index_best_effort();
        if !index.profiles.iter().any(|s| s.id == req.id) {
            return Err(not_found(&req.id));
        }
        match fs::remove_file(self.payload_path(&req.id)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(store_failed(format!("delete {}: {e}", req.id))),
        }
        index.profiles.retain(|s| s.id != req.id);
        index.revision += 1;
        self.write_index(&index)?;
        log_message(format!("profile.delete id={}", req.id));
        Ok(DeleteOutcome {
            ok: true,
            id: req.id,
            deleted: true,
        })
    }

    /// `profile.refresh` begin step: record a refresh intent and return the
    /// fetch spec the caller feeds to `profile.import_url`. Performs **no
    /// network I/O**. A non-forced call is refused while the bounded failure
    /// backoff window is still open (`PROXY_PROFILE_REFRESH_BACKOFF`, 507).
    pub(crate) fn refresh(&self, payload: &[u8]) -> Result<RefreshPlan, ModuleError> {
        let req: RefreshRequest = parse_json(payload, "profile.refresh")?;
        validate_id(&req.id)?;

        let _g = lock_store();
        let (mut index, _w) = self.read_index_best_effort();
        if !index.profiles.iter().any(|s| s.id == req.id) {
            return Err(not_found(&req.id));
        }
        let created = self.created_hint(&index, &req.id);
        let mut record = self.read_payload(&req.id, created)?;

        let url = record
            .profile
            .source
            .url
            .clone()
            .filter(|u| !u.trim().is_empty());
        if record.profile.source.origin != "url" || url.is_none() {
            return Err(ModuleError::new(
                StatusCode::InvalidArgument,
                ERR_PROFILE_NOT_REFRESHABLE,
                format!(
                    "profile '{}' has no subscription URL (origin='{}'); import it from a URL to refresh",
                    req.id, record.profile.source.origin
                ),
            ));
        }

        let now = crate::now_ms();
        if !req.force {
            if let Some(state) = &record.refresh {
                if state.consecutive_failures > 0 {
                    let last = state.last_attempt_ms.unwrap_or(now);
                    let next = state
                        .next_refresh_at_ms
                        .unwrap_or_else(|| last.saturating_add(refresh_backoff_ms(state.consecutive_failures)));
                    if now < next {
                        return Err(ModuleError::new(
                            StatusCode::ResourceExhausted,
                            ERR_PROFILE_REFRESH_BACKOFF,
                            format!(
                                "profile '{}' refresh is backing off after {} failure(s); retry in {} ms",
                                req.id,
                                state.consecutive_failures,
                                next.saturating_sub(now)
                            ),
                        ));
                    }
                }
            }
        }

        let attempts = record.refresh.as_ref().map(|r| r.attempts).unwrap_or(0) + 1;
        let mut state = record.refresh.clone().unwrap_or_default();
        state.state = "requested".to_string();
        state.requested_at_ms = now;
        state.last_attempt_ms = None;
        state.attempts = attempts;
        state.error = None;
        state.error_code = None;
        record.refresh = Some(state);
        record.updated_at_ms = now;

        self.write_payload(&record)?;
        Self::upsert_summary(&mut index, &record);
        index.revision += 1;
        self.write_index(&index)?;

        let fetch = FetchSpec {
            url: url.unwrap_or_default(),
            name: record.profile.name.clone(),
            user_agent: record.profile.source.user_agent.clone(),
        };
        log_message(format!(
            "profile.refresh id={} attempts={attempts} force={} url={}",
            record.id, req.force, fetch.url
        ));
        Ok(RefreshPlan {
            profile_id: record.id.clone(),
            refreshable: true,
            state: "requested".to_string(),
            requested_at_ms: now,
            attempts,
            source: record.profile.source.clone(),
            fetch: Some(fetch),
            profile: record,
        })
    }

    /// Record a successful refresh: replace the profile content with the newly
    /// fetched/parsed canonical profile, clear the failure state, and schedule
    /// the next interval-based refresh. Bumps `revision`.
    pub(crate) fn apply_refresh_success(
        &self,
        id: &str,
        mut profile: ImportedProfile,
    ) -> Result<StoredProfile, ModuleError> {
        validate_id(id)?;
        validate_profile(&mut profile)?;

        let _g = lock_store();
        let (mut index, _w) = self.read_index_best_effort();
        if !index.profiles.iter().any(|s| s.id == id) {
            return Err(not_found(id));
        }
        let created = self.created_hint(&index, id);
        let mut record = self.read_payload(id, created)?;

        record.profile = profile;
        record.revision += 1;
        let now = crate::now_ms();
        record.updated_at_ms = now;

        let mut state = record.refresh.clone().unwrap_or_default();
        state.state = "done".to_string();
        state.last_attempt_ms = Some(now);
        state.last_updated_at_ms = Some(now);
        state.error = None;
        state.error_code = None;
        state.consecutive_failures = 0;
        state.next_refresh_at_ms = state.interval_ms.map(|i| now.saturating_add(i));
        record.refresh = Some(state);
        record.schema_version = SCHEMA_VERSION;

        self.write_payload(&record)?;
        Self::upsert_summary(&mut index, &record);
        index.revision += 1;
        self.write_index(&index)?;
        log_message(format!(
            "profile.refresh success id={} nodes={} revision={}",
            record.id, record.profile.node_count, record.revision
        ));
        Ok(record)
    }

    /// Record a failed refresh: the **previous profile is preserved** (only the
    /// refresh bookkeeping changes), `consecutiveFailures` increments, and the
    /// next allowed attempt is pushed out by the bounded backoff. No revision
    /// bump (content did not change).
    pub(crate) fn apply_refresh_failure(
        &self,
        id: &str,
        code: &str,
        message: &str,
    ) -> Result<StoredProfile, ModuleError> {
        validate_id(id)?;

        let _g = lock_store();
        let (mut index, _w) = self.read_index_best_effort();
        if !index.profiles.iter().any(|s| s.id == id) {
            return Err(not_found(id));
        }
        let created = self.created_hint(&index, id);
        let mut record = self.read_payload(id, created)?;

        let now = crate::now_ms();
        let mut state = record.refresh.clone().unwrap_or_default();
        state.state = "failed".to_string();
        state.last_attempt_ms = Some(now);
        state.error = Some(message.to_string());
        state.error_code = Some(code.to_string());
        state.consecutive_failures = state.consecutive_failures.saturating_add(1);
        state.next_refresh_at_ms =
            Some(now.saturating_add(refresh_backoff_ms(state.consecutive_failures)));
        record.refresh = Some(state);
        record.updated_at_ms = now;
        record.schema_version = SCHEMA_VERSION;

        self.write_payload(&record)?;
        Self::upsert_summary(&mut index, &record);
        index.revision += 1;
        self.write_index(&index)?;
        log_message(format!(
            "profile.refresh failed id={} code={code} failures={}",
            record.id,
            record.refresh.as_ref().map(|r| r.consecutive_failures).unwrap_or(0)
        ));
        Ok(record)
    }

    /// `profile.set_schedule`: set (or clear with `intervalMs: 0`) the
    /// per-profile auto-update interval and recompute the next due time. No
    /// content change, so `revision` is untouched.
    pub(crate) fn set_schedule(&self, payload: &[u8]) -> Result<StoredProfile, ModuleError> {
        let req: ScheduleRequest = parse_json(payload, "profile.set_schedule")?;
        validate_id(&req.id)?;

        let _g = lock_store();
        let (mut index, _w) = self.read_index_best_effort();
        if !index.profiles.iter().any(|s| s.id == req.id) {
            return Err(not_found(&req.id));
        }
        let created = self.created_hint(&index, &req.id);
        let mut record = self.read_payload(&req.id, created)?;

        let now = crate::now_ms();
        let mut state = record.refresh.clone().unwrap_or_default();
        state.interval_ms = req.interval_ms.filter(|value| *value > 0);
        state.next_refresh_at_ms = match (state.interval_ms, state.last_updated_at_ms) {
            (Some(interval), Some(last)) if state.consecutive_failures == 0 => {
                Some(last.saturating_add(interval))
            }
            _ => state.next_refresh_at_ms,
        };
        record.refresh = Some(state);
        record.updated_at_ms = now;
        record.schema_version = SCHEMA_VERSION;

        self.write_payload(&record)?;
        Self::upsert_summary(&mut index, &record);
        index.revision += 1;
        self.write_index(&index)?;
        log_message(format!(
            "profile.set_schedule id={} intervalMs={}",
            record.id,
            record
                .refresh
                .as_ref()
                .and_then(|r| r.interval_ms)
                .unwrap_or(0)
        ));
        Ok(record)
    }
}

fn apply_refresh_patch(record: &mut StoredProfile, patch: RefreshPatch) -> Result<(), ModuleError> {
    let state = patch.state.trim();
    if !matches!(state, "requested" | "done" | "failed") {
        return Err(profile_invalid(
            "refresh.state must be one of requested|done|failed",
        ));
    }
    let now = crate::now_ms();
    let attempts = record.refresh.as_ref().map(|r| r.attempts).unwrap_or(0);
    let requested_at_ms = record
        .refresh
        .as_ref()
        .map(|r| r.requested_at_ms)
        .unwrap_or(now);
    let attempts = if state == "requested" {
        attempts + 1
    } else {
        attempts
    };
    let mut current = record.refresh.clone().unwrap_or_default();
    current.state = state.to_string();
    current.requested_at_ms = requested_at_ms;
    current.last_attempt_ms = if state == "requested" { None } else { Some(now) };
    current.attempts = attempts;
    current.error = patch.error;
    record.refresh = Some(current);
    Ok(())
}

fn log_message(message: String) {
    crate::log_message(1, &message);
}

// ============================ tests ============================

#[cfg(all(test, unix))]
pub(crate) mod tests {
    use super::*;
    use crate::subscription::{
        NodeSource, ProxyGroup, ProxyNode, SubscriptionUserinfo,
    };
    use std::sync::atomic::AtomicU32;

    static SEQ: AtomicU32 = AtomicU32::new(0);

    pub(crate) fn tmp_dir(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("gstore-profiles-{tag}-{nanos}-{seq}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn node(name: &str, port: u16) -> ProxyNode {
        ProxyNode {
            name: name.to_string(),
            node_type: "ss".to_string(),
            server: "1.2.3.4".to_string(),
            port,
            cipher: Some("aes-256-gcm".to_string()),
            password: Some("secret".to_string()),
            uuid: None,
            alter_id: None,
            security: None,
            flow: None,
            network: None,
            tls: false,
            sni: None,
            skip_cert_verify: None,
            alpn: Vec::new(),
            fingerprint: None,
            reality: None,
            ws: None,
            grpc: None,
            obfs: None,
            obfs_password: None,
            udp: None,
            groups: vec!["PROXY".to_string()],
            source: NodeSource {
                format: "clash".to_string(),
                origin: "text".to_string(),
                index: 0,
            },
        }
    }

    /// Canonical ImportedProfile fixture (Todo 11's model, not re-parsed here).
    pub(crate) fn sample_profile(name: &str, origin: &str, url: Option<&str>) -> ImportedProfile {
        let nodes = vec![node("node-a", 8388), node("node-b", 8389)];
        ImportedProfile {
            name: name.to_string(),
            format: "clash".to_string(),
            node_count: nodes.len(),
            nodes,
            groups: vec![ProxyGroup {
                name: "PROXY".to_string(),
                group_type: "select".to_string(),
                members: vec!["node-a".to_string(), "node-b".to_string()],
            }],
            rules: Vec::new(),
            userinfo: Some(SubscriptionUserinfo {
                upload: Some(10),
                download: Some(20),
                total: Some(1000),
                expire: Some(1_700_000_000),
            }),
            source: ImportSource {
                origin: origin.to_string(),
                url: url.map(str::to_string),
                ..ImportSource::default()
            },
            warnings: Vec::new(),
        }
    }

    fn open(dir: &Path) -> ProfileStore {
        ProfileStore::open(&dir.display().to_string()).unwrap()
    }

    fn create(store: &ProfileStore, name: &str, origin: &str, url: Option<&str>) -> StoredProfile {
        let payload = serde_json::json!({
            "profile": sample_profile(name, origin, url),
        });
        store
            .create(serde_json::to_vec(&payload).unwrap().as_slice())
            .unwrap()
    }

    #[test]
    fn profile_rules_survive_serde_and_store_round_trip() {
        let dir = tmp_dir("rules");
        let store = open(&dir);
        let mut profile = sample_profile("Rules", "url", Some("https://example.com/sub"));
        profile.rules = vec![
            "DOMAIN-SUFFIX,example.com,PROXY".to_string(),
            "MATCH,PROXY".to_string(),
        ];
        let expected = profile.rules.clone();

        let json = serde_json::to_string(&profile).unwrap();
        let back: ImportedProfile = serde_json::from_str(&json).unwrap();
        assert_eq!(back.rules, expected, "ImportedProfile serde round-trip");

        let payload = serde_json::to_vec(&serde_json::json!({ "profile": profile })).unwrap();
        store.create(&payload).unwrap();
        let got = store.get(br#"{"id":"p1"}"#).unwrap();
        assert_eq!(got.profile.rules, expected, "ProfileStore create/get");

        let reopened = open(&dir);
        assert_eq!(
            reopened.get(br#"{"id":"p1"}"#).unwrap().profile.rules,
            expected,
            "rules survive a store reopen"
        );

        let legacy_json = serde_json::json!({
            "name": "Legacy",
            "format": "clash",
            "nodeCount": 1,
            "nodes": [serde_json::to_value(node("node-a", 8388)).unwrap()],
            "groups": [],
            "source": {"origin": "text"},
        });
        let legacy: ImportedProfile = serde_json::from_value(legacy_json).unwrap();
        assert!(legacy.rules.is_empty(), "a payload without `rules` defaults to empty");
    }

    /// Happy QA: create → list → get → update → delete round-trip; the files on
    /// disk reflect every step and survive a store reload.
    #[test]
    fn crud_round_trips_and_survives_reload() {
        let dir = tmp_dir("crud");
        let store = open(&dir);
        assert_eq!(store.list().unwrap().count, 0);

        let created = create(&store, "Sub A", "url", Some("https://example.com/sub"));
        assert_eq!(created.id, "p1");
        assert_eq!(created.revision, 1);
        assert!(dir.join(PROFILES_DIR).join("p1.json").exists());
        assert!(dir.join(PROFILES_DIR).join(INDEX_FILE).exists());

        // Reload from disk: a completely fresh ProfileStore sees the same data.
        let reloaded = open(&dir);
        let listed = reloaded.list().unwrap();
        assert_eq!(listed.count, 1);
        assert_eq!(listed.profiles[0].name, "Sub A");
        assert_eq!(listed.profiles[0].node_count, 2);
        assert_eq!(listed.profiles[0].source_url.as_deref(), Some("https://example.com/sub"));

        // get round-trip through the JSON request payload.
        let got = reloaded
            .get(br#"{"id":"p1"}"#)
            .expect("profile.get must find p1");
        assert_eq!(got.profile.nodes.len(), 2);
        assert_eq!(got.profile.nodes[0].password.as_deref(), Some("secret"));

        // update: rename only -> revision bumps; list reflects it.
        let updated = reloaded
            .update(serde_json::to_vec(&serde_json::json!({"id":"p1","name":"Renamed"})).unwrap().as_slice())
            .unwrap();
        assert_eq!(updated.profile.name, "Renamed");
        assert_eq!(updated.revision, 2);
        assert_eq!(open(&dir).list().unwrap().profiles[0].name, "Renamed");

        // update: replace the whole profile.
        let replacement = sample_profile("Replaced", "url", Some("https://example.com/sub"));
        let updated = reloaded
            .update(
                serde_json::to_vec(&serde_json::json!({"id":"p1","profile": replacement})).unwrap().as_slice(),
            )
            .unwrap();
        assert_eq!(updated.profile.name, "Replaced");
        assert_eq!(updated.revision, 3);

        // appBackup is preserved verbatim (app backup/restore hook).
        let with_backup = reloaded
            .update(
                serde_json::to_vec(&serde_json::json!({"id":"p1","appBackup":{"fav":true,"note":"keep"}}))
                    .unwrap()
                    .as_slice(),
            )
            .unwrap();
        assert_eq!(with_backup.app_backup.as_ref().unwrap()["fav"], true);
        assert_eq!(
            open(&dir).get(br#"{"id":"p1"}"#).unwrap().app_backup.unwrap()["note"],
            "keep"
        );

        // delete removes the payload file and the index entry.
        let outcome = reloaded.delete(br#"{"id":"p1"}"#).unwrap();
        assert!(outcome.deleted);
        assert!(!dir.join(PROFILES_DIR).join("p1.json").exists());
        assert_eq!(open(&dir).list().unwrap().count, 0);
        assert_eq!(reloaded.get(br#"{"id":"p1"}"#).unwrap_err().code, ERR_PROFILE_NOT_FOUND);

        let _ = fs::remove_dir_all(&dir);
    }

    /// `profile.list` order is stable: sorted by `(createdAtMs asc, id asc)` and
    /// identical across reloads.
    #[test]
    fn list_order_is_stable() {
        let dir = tmp_dir("order");
        let profiles = dir.join(PROFILES_DIR);
        fs::create_dir_all(&profiles).unwrap();
        let mut summaries = Vec::new();
        for (id, created) in [("p10", 300u64), ("p2", 100), ("p7", 200)] {
            let record = StoredProfile {
                schema_version: SCHEMA_VERSION,
                id: id.to_string(),
                revision: 1,
                created_at_ms: created,
                updated_at_ms: created,
                refresh: None,
                app_backup: None,
                profile: sample_profile(id, "text", None),
            };
            fs::write(
                profiles.join(format!("{id}.json")),
                serde_json::to_vec_pretty(&record).unwrap(),
            )
            .unwrap();
            summaries.push(ProfileSummary::from_record(&record));
        }
        let index = ProfileIndex {
            schema_version: SCHEMA_VERSION,
            revision: 1,
            next_id: 11,
            profiles: summaries,
        };
        fs::write(
            profiles.join(INDEX_FILE),
            serde_json::to_vec_pretty(&index).unwrap(),
        )
        .unwrap();

        let first = open(&dir).list().unwrap();
        let ids: Vec<&str> = first.profiles.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, vec!["p2", "p7", "p10"], "stable (createdAtMs, id) ordering");
        let second = open(&dir).list().unwrap();
        assert_eq!(second, first, "repeated list is identical");

        let _ = fs::remove_dir_all(&dir);
    }

    /// Failure QA: an injected failure at the temp/rename boundary leaves the
    /// previous file intact and no temp residue.
    #[test]
    fn atomic_write_failure_leaves_old_file_intact() {
        let dir = tmp_dir("atomic");
        let target = dir.join("target.json");
        fs::write(&target, b"old").unwrap();

        let store = ProfileStore::open_with_fault(&dir.display().to_string(), WriteFault::FailBeforeRename)
            .unwrap();
        let err = store.atomic_write(&target, b"new-content").unwrap_err();
        assert_eq!(err.code, ERR_PROFILE_STORE_FAILED);
        assert_eq!(fs::read(&target).unwrap(), b"old", "destination untouched");
        let residue: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
            .collect();
        assert!(residue.is_empty(), "no temp residue: {residue:?}");

        let store = ProfileStore::open_with_fault(&dir.display().to_string(), WriteFault::FailAfterTempWrite)
            .unwrap();
        assert!(store.atomic_write(&target, b"newer").is_err());
        assert_eq!(fs::read(&target).unwrap(), b"old");

        let _ = fs::remove_dir_all(&dir);
    }

    /// Failure QA at the store level: a failing create never partial-writes the
    /// index and leaves the previous profiles intact.
    #[test]
    fn failed_create_does_not_corrupt_the_index() {
        let dir = tmp_dir("atomic-store");
        let store = open(&dir);
        let first = create(&store, "Keep", "text", None);
        assert_eq!(first.id, "p1");

        let failing = ProfileStore::open_with_fault(&dir.display().to_string(), WriteFault::FailBeforeRename)
            .unwrap();
        let payload = serde_json::to_vec(&serde_json::json!({
            "profile": sample_profile("Doomed", "text", None),
        }))
        .unwrap();
        let err = failing.create(&payload).unwrap_err();
        assert_eq!(err.code, ERR_PROFILE_STORE_FAILED);

        // The store still lists the original profile and nothing else.
        let reloaded = open(&dir);
        let list = reloaded.list().unwrap();
        assert_eq!(list.count, 1);
        assert_eq!(list.profiles[0].name, "Keep");
        assert!(!dir.join(PROFILES_DIR).join("p2.json").exists());

        let _ = fs::remove_dir_all(&dir);
    }

    /// Schema migration: a v1 index + bare-payload fixture is read as the
    /// current schema, and the next mutation upgrades the files on disk.
    #[test]
    fn migrates_v1_fixture_to_current_schema() {
        let dir = tmp_dir("migrate");
        let profiles = dir.join(PROFILES_DIR);
        fs::create_dir_all(&profiles).unwrap();

        let v1_index = serde_json::json!({
            "version": 1,
            "profiles": [
                {"id": "p1", "name": "Legacy Sub", "nodeCount": 1, "createdAtMs": 1000}
            ]
        });
        fs::write(
            profiles.join(INDEX_FILE),
            serde_json::to_vec_pretty(&v1_index).unwrap(),
        )
        .unwrap();

        // v1 payload = bare ImportedProfile (no schemaVersion / wrapper / timestamps).
        let mut legacy = sample_profile("Legacy Sub", "url", Some("https://example.com/legacy"));
        legacy.nodes.truncate(1);
        legacy.node_count = 1;
        legacy.groups[0].members = vec!["node-a".to_string()];
        fs::write(
            profiles.join("p1.json"),
            serde_json::to_vec_pretty(&legacy).unwrap(),
        )
        .unwrap();

        let store = open(&dir);
        let list = store.list().unwrap();
        assert_eq!(list.schema_version, SCHEMA_VERSION);
        assert_eq!(list.count, 1, "v1 profile is visible after migration");
        assert_eq!(list.profiles[0].id, "p1");
        assert_eq!(list.profiles[0].name, "Legacy Sub");
        assert_eq!(list.profiles[0].created_at_ms, 1000);
        assert_eq!(list.profiles[0].updated_at_ms, 1000);
        assert_eq!(list.profiles[0].revision, 1);

        let got = store.get(br#"{"id":"p1"}"#).unwrap();
        assert_eq!(got.schema_version, SCHEMA_VERSION);
        assert_eq!(got.profile.node_count, 1);
        assert_eq!(got.created_at_ms, 1000);

        // A mutation persists the upgraded v2 shape and allocates id p2.
        let new_record = create(&store, "Fresh", "text", None);
        assert_eq!(new_record.id, "p2", "nextId derived from the v1 id");
        let index: Value = serde_json::from_slice(&fs::read(profiles.join(INDEX_FILE)).unwrap()).unwrap();
        assert_eq!(index["schemaVersion"], SCHEMA_VERSION);
        assert_eq!(index["nextId"], 3);

        // Touching the legacy record rewrites its payload in the v2 wrapper.
        store
            .update(br#"{"id":"p1","appBackup":{"migrated":true}}"#)
            .unwrap();
        let payload: Value = serde_json::from_slice(&fs::read(profiles.join("p1.json")).unwrap()).unwrap();
        assert_eq!(payload["schemaVersion"], SCHEMA_VERSION);
        assert!(payload["profile"]["name"].is_string(), "v1 payload was wrapped");
        assert_eq!(payload["createdAtMs"], 1000, "v1 createdAt preserved from the index");

        let _ = fs::remove_dir_all(&dir);
    }

    /// Failure QA: a corrupt per-profile file is skipped with a structured
    /// warning; the valid profiles are still listed and nothing panics.
    #[test]
    fn corrupt_profile_file_is_skipped_with_warning() {
        let dir = tmp_dir("corrupt");
        let store = open(&dir);
        let good = create(&store, "Good", "text", None);
        create(&store, "Victim", "text", None);
        fs::write(
            dir.join(PROFILES_DIR).join("p2.json"),
            b"{ this is not valid json",
        )
        .unwrap();

        let list = store.list().expect("list must not fail on a corrupt sibling");
        assert_eq!(list.count, 1);
        assert_eq!(list.profiles[0].id, good.id);
        assert_eq!(list.profiles[0].name, "Good");
        assert!(
            list.warnings
                .iter()
                .any(|w| w.code == ERR_PROFILE_CORRUPT && w.id.as_deref() == Some("p2")),
            "structured warning naming the corrupt file: {:?}",
            list.warnings
        );

        // get on the corrupt id is a structured error, never a panic.
        let err = store.get(br#"{"id":"p2"}"#).unwrap_err();
        assert_eq!(err.code, ERR_PROFILE_CORRUPT);

        // A missing payload referenced by the index warns too.
        fs::remove_file(dir.join(PROFILES_DIR).join("p2.json")).unwrap();
        let list = store.list().unwrap();
        assert_eq!(list.count, 1);
        assert!(list.warnings.iter().any(|w| w.code == ERR_PROFILE_MISSING));

        let _ = fs::remove_dir_all(&dir);
    }

    /// A corrupt index is rebuilt from the payload directory instead of losing
    /// every profile.
    #[test]
    fn corrupt_index_is_rebuilt_from_payloads() {
        let dir = tmp_dir("index-corrupt");
        let store = open(&dir);
        create(&store, "One", "text", None);
        create(&store, "Two", "text", None);
        fs::write(
            dir.join(PROFILES_DIR).join(INDEX_FILE),
            b"not json at all",
        )
        .unwrap();

        let list = open(&dir).list().unwrap();
        assert_eq!(list.count, 2, "index rebuilt from the payload files");
        assert!(list.warnings.iter().any(|w| w.file.as_deref() == Some(INDEX_FILE)));
        let reloaded = open(&dir).list().unwrap();
        assert_eq!(reloaded.count, 2);
        assert!(reloaded.warnings.is_empty(), "repaired index is clean");

        let _ = fs::remove_dir_all(&dir);
    }

    /// `profile.refresh` persists a refresh flag and exposes the fetch spec
    /// Todo 14 needs; a text/link profile is not refreshable.
    #[test]
    fn refresh_records_flag_and_exposes_fetch_spec() {
        let dir = tmp_dir("refresh");
        let store = open(&dir);
        let created = create(&store, "Refreshable", "url", Some("https://example.com/sub"));
        let plan = store
            .refresh(serde_json::to_vec(&serde_json::json!({"id": created.id})).unwrap().as_slice())
            .unwrap();
        assert!(plan.refreshable);
        assert_eq!(plan.state, "requested");
        assert_eq!(plan.attempts, 1);
        let fetch = plan.fetch.expect("url-origin profile yields a fetch spec");
        assert_eq!(fetch.url, "https://example.com/sub");
        assert_eq!(fetch.name, "Refreshable");

        // Persisted: a reload sees the requested flag.
        let reloaded = open(&dir);
        let got = reloaded.get(serde_json::to_vec(&serde_json::json!({"id": created.id})).unwrap().as_slice()).unwrap();
        let refresh = got.refresh.as_ref().expect("refresh flag persisted");
        assert_eq!(refresh.state, "requested");
        assert_eq!(refresh.attempts, 1);

        // Todo 14 clears it through profile.update.
        let done = reloaded
            .update(
                serde_json::to_vec(&serde_json::json!({"id": created.id, "refresh": {"state": "done"}}))
                    .unwrap()
                    .as_slice(),
            )
            .unwrap();
        let refresh = done.refresh.unwrap();
        assert_eq!(refresh.state, "done");
        assert!(refresh.last_attempt_ms.is_some());

        // A text-origin profile cannot be refreshed.
        let text = create(&store, "Text", "text", None);
        let err = store
            .refresh(serde_json::to_vec(&serde_json::json!({"id": text.id})).unwrap().as_slice())
            .unwrap_err();
        assert_eq!(err.code, ERR_PROFILE_NOT_REFRESHABLE);

        let _ = fs::remove_dir_all(&dir);
    }

    /// Bad input is a structured error: unknown ids, traversal ids, and
    /// out-of-range schema versions.
    #[test]
    fn bad_input_is_structured() {
        let dir = tmp_dir("bad-input");
        let store = open(&dir);
        create(&store, "One", "text", None);

        assert_eq!(store.get(br#"{"id":"nope"}"#).unwrap_err().code, ERR_PROFILE_NOT_FOUND);
        assert_eq!(store.delete(br#"{"id":"../etc/passwd"}"#).unwrap_err().code, ERR_PROFILE_INVALID);
        assert_eq!(store.get(br#"{"id":"../evil"}"#).unwrap_err().code, ERR_PROFILE_INVALID);
        assert_eq!(
            store.update(br#"{"id":"p1"}"#).unwrap_err().code,
            ERR_PROFILE_INVALID
        );
        let dup = serde_json::to_vec(&serde_json::json!({"id":"p1","profile": sample_profile("Dup","text",None)})).unwrap();
        assert_eq!(store.create(&dup).unwrap_err().code, ERR_PROFILE_INVALID);
        assert_eq!(store.create(br#"{}"#).unwrap_err().code, ERR_PROFILE_INVALID);

        // A newer schema version is refused rather than silently truncated.
        let payload = dir.join(PROFILES_DIR).join("future.json");
        fs::write(&payload, br#"{"schemaVersion":99,"id":"future"}"#).unwrap();
        let err = store.get(br#"{"id":"future"}"#).unwrap_err();
        assert_eq!(err.code, ERR_PROFILE_SCHEMA_UNSUPPORTED);

        let _ = fs::remove_dir_all(&dir);
    }
}
