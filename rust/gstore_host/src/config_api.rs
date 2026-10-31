//! Internals of the FRB `ConfigApi` facade (Todo 8 / C1 / C3 / C9 / C18).
//!
//! The process-global [`ConfigStore`] is installed by
//! [`crate::bridge::CoreApi::finish_init`] from the **same** `SharedConn` and
//! `files_dir` the rest of the core uses (C1). It lives behind a replaceable
//! `RwLock<Option<Arc<ConfigStore>>>` so re-init and tests never reuse a stale
//! store (`OnceLock` is deliberately not used).
//!
//! `ConfigApi` itself is defined directly in `bridge.rs` because FRB 2.11 only
//! follows opaque types declared in the input file. Every method there is a
//! thin delegate to this module.
//!
//! # Secret policy (C3)
//!
//! Every surface produced here is masked by the committed core policy:
//! `list`, `snapshots`, `snapshot`, change events, and `get(masked = true)`.
//! The only raw surfaces are `get(masked = false)` (trusted Dart) and `export`
//! (the backup artifact). No plaintext secret is stored in the sink registry.
//!
//! # Sink multiplicity (C18)
//!
//! The Dart sink registry is a `Vec` of sinks **per filter**. Two listeners on
//! the same `(module, key)` both receive. A sink whose `add` fails is pruned
//! without affecting its siblings. [`clear_sinks`] unsubscribes every bus
//! token and drops every sink; `HostInspector::reset_bridges` calls it.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard};

use gstore_core::config::{
    import as config_import, schema, secrets, ConfigBus, ConfigCaller, ConfigChangePayload,
    ConfigChange, ConfigFilter, ConfigKey, ConfigSource, ConfigStore, ConfigToken,
};
use gstore_core::db::DbHandle;
use rusqlite::OptionalExtension;
use serde_json::Value;

use crate::frb_generated::StreamSink;

// allow: SIZE_OK — one private module behind the single FRB `ConfigApi` opaque
// type; its DTOs, replaceable globals, sink registry, and delegating operations
// share the same private state and are re-exported as one bridge surface.

const NOT_INITIALIZED: &str = "CORE_E_NOT_INITIALIZED: CoreApi.init() has not been called";

// ---------------------------------------------------------------------------
// Process-global replaceable state
// ---------------------------------------------------------------------------

/// The authoritative config store. Replaced on every `CoreApi::finish_init`.
static CONFIG_STORE: RwLock<Option<Arc<ConfigStore>>> = RwLock::new(None);

/// The config change bus. Replaced together with the store.
static CONFIG_BUS: RwLock<Option<Arc<ConfigBus>>> = RwLock::new(None);

/// Same `DbHandle` (same `SharedConn`) as the store, used only for the
/// unrestricted `config_meta` get/set surface. Never opens a connection.
static CONFIG_META_DB: RwLock<Option<DbHandle>> = RwLock::new(None);

fn read_lock<T>(lock: &RwLock<T>) -> RwLockReadGuard<'_, T> {
    lock.read().unwrap_or_else(PoisonError::into_inner)
}

fn write_lock<T>(lock: &RwLock<T>) -> RwLockWriteGuard<'_, T> {
    lock.write().unwrap_or_else(PoisonError::into_inner)
}

fn mutex_lock<T>(lock: &Mutex<T>) -> MutexGuard<'_, T> {
    lock.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Installs the store/bus/db created by `CoreApi::finish_init`.
///
/// Any stale sink registrations from a previous core instance are cleared
/// first, so a re-init can never keep delivering from the old bus.
pub(crate) fn install_core_config(store: Arc<ConfigStore>, bus: Arc<ConfigBus>, db: DbHandle) {
    clear_sinks();
    *write_lock(&CONFIG_STORE) = Some(store);
    *write_lock(&CONFIG_BUS) = Some(bus);
    *write_lock(&CONFIG_META_DB) = Some(db);
}

/// Drops the process-global store, bus, and meta handle (tests / re-init).
pub fn reset_store_for_test() {
    clear_sinks();
    *write_lock(&CONFIG_STORE) = None;
    *write_lock(&CONFIG_BUS) = None;
    *write_lock(&CONFIG_META_DB) = None;
}

fn store() -> Result<Arc<ConfigStore>, String> {
    read_lock(&CONFIG_STORE)
        .clone()
        .ok_or_else(|| NOT_INITIALIZED.to_string())
}

fn bus() -> Result<Arc<ConfigBus>, String> {
    read_lock(&CONFIG_BUS)
        .clone()
        .ok_or_else(|| NOT_INITIALIZED.to_string())
}

fn meta_db() -> Result<DbHandle, String> {
    read_lock(&CONFIG_META_DB)
        .clone()
        .ok_or_else(|| NOT_INITIALIZED.to_string())
}

/// Test seam: the store currently installed in the process global.
#[doc(hidden)]
pub fn installed_store_for_test() -> Option<Arc<ConfigStore>> {
    read_lock(&CONFIG_STORE).clone()
}

// ---------------------------------------------------------------------------
// FRB data classes
// ---------------------------------------------------------------------------

/// Registry metadata plus the current (masked) value of one entry.
#[derive(Debug, Clone)]
pub struct ConfigEntryDto {
    pub module: String,
    pub key: String,
    pub wire_key: String,
    pub value_type: String,
    /// Serialized JSON; masked (`"***"`) for set secrets.
    pub value_json: String,
    pub masked: bool,
    pub revision: u64,
    pub sensitive: bool,
    pub agent_accessible: bool,
    pub visibility: String,
    pub default_json: String,
    pub description_zh: String,
    pub description_en: String,
    pub category: String,
    pub unit: Option<String>,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub enum_values: Vec<String>,
    pub example: Option<String>,
}

/// One stored snapshot (already masked for secrets).
#[derive(Debug, Clone)]
pub struct ConfigSnapshotDto {
    pub module: String,
    pub key: String,
    pub wire_key: String,
    pub value_json: Option<String>,
    pub masked: bool,
    pub revision: u64,
    pub updated_at: i64,
    pub updated_by: Option<String>,
}

/// Result of a single-key write operation.
#[derive(Debug, Clone)]
pub struct ConfigOpResultDto {
    pub success: bool,
    pub message: String,
    pub module: String,
    pub key: String,
    pub wire_key: String,
    pub value_json: Option<String>,
    pub default_json: String,
}

/// One committed change forwarded to a watcher (secrets already masked).
#[derive(Debug, Clone)]
pub struct ConfigChangeDto {
    pub module: String,
    pub key: String,
    pub wire_key: String,
    pub value_json: Option<String>,
    pub old_value_json: Option<String>,
    pub revision: u64,
    pub source: String,
}

/// Input entry for `import`.
#[derive(Debug, Clone)]
pub struct ConfigImportEntryDto {
    pub module: String,
    pub key: String,
    pub value_json: String,
}

/// One rejected import entry (stable code only, never a value).
#[derive(Debug, Clone)]
pub struct ConfigImportFailureDto {
    pub module: String,
    pub key: String,
    pub code: String,
}

/// Result of a bulk import.
#[derive(Debug, Clone)]
pub struct ConfigImportReportDto {
    pub total: u32,
    pub applied: u32,
    pub unchanged: u32,
    pub failed: Vec<ConfigImportFailureDto>,
    pub events_published: u32,
}

/// Input entry for `verify`.
#[derive(Debug, Clone)]
pub struct ConfigVerifyEntryDto {
    pub module: String,
    pub key: String,
    pub value_json: String,
}

/// Per-key verification outcome.
#[derive(Debug, Clone)]
pub struct ConfigVerifyResultDto {
    pub module: String,
    pub key: String,
    /// `match` / `mismatch` / `rejected` / `error`.
    pub status: String,
    /// Stable code when `status` is `rejected` or `error`.
    pub code: Option<String>,
}

/// Read-back verification report.
#[derive(Debug, Clone)]
pub struct ConfigVerifyReportDto {
    pub total: u32,
    pub matched: u32,
    pub all_matched: bool,
    pub results: Vec<ConfigVerifyResultDto>,
}

/// One raw export entry (backup artifact only; may contain plaintext secrets).
#[derive(Debug, Clone)]
pub struct ConfigExportEntryDto {
    pub module: String,
    pub key: String,
    pub wire_key: String,
    pub value_json: String,
}

/// Raw config export for backups. This is the only raw DTO.
#[derive(Debug, Clone)]
pub struct ConfigExportDto {
    pub revision: u64,
    pub entries: Vec<ConfigExportEntryDto>,
}

/// Result of [`ensure_migrated`].
#[derive(Debug, Clone)]
pub struct ConfigMigrationStateDto {
    /// The store cache is loaded from the committed v6 schema.
    pub schema_ready: bool,
    /// Legacy-value migration actually ran. Always `false` in Todo 8; Todo 21
    /// owns the migration tool.
    pub migrated: bool,
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

fn json_text(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "null".to_string())
}

fn option_json_text(value: &Option<Value>) -> Option<String> {
    value.as_ref().map(json_text)
}

fn parse_json(text: &str) -> Result<Value, String> {
    serde_json::from_str(text).map_err(|error| format!("[config_invalid_json] {error}"))
}

fn parse_source(source: &str) -> Result<ConfigSource, String> {
    source.parse::<ConfigSource>().map_err(|error: gstore_core::config::ConfigError| error.to_string())
}

fn parse_key(module: &str, key: &str) -> Result<ConfigKey, String> {
    ConfigKey::new(module.to_string(), key.to_string()).map_err(|error| error.to_string())
}

impl ConfigChangeDto {
    fn from_payload(payload: &ConfigChangePayload) -> Self {
        let wire_key = format!("{}.{}", payload.module, payload.key);
        Self {
            module: payload.module.clone(),
            key: payload.key.clone(),
            wire_key,
            value_json: option_json_text(&payload.value),
            old_value_json: option_json_text(&payload.old_value),
            revision: payload.revision,
            source: payload.source.as_str().to_string(),
        }
    }
}

// MUST be deleted when `frb_generated.rs` is regenerated in Todo 9: codegen
// emits its own SseEncode impl for ConfigChangeDto and keeping this one would
// cause a duplicate-impl E0119 compile error.
impl crate::frb_generated::SseEncode for ConfigChangeDto {
    fn sse_encode(self, serializer: &mut flutter_rust_bridge::for_generated::SseSerializer) {
        <String>::sse_encode(self.module, serializer);
        <String>::sse_encode(self.key, serializer);
        <String>::sse_encode(self.wire_key, serializer);
        <Option<String>>::sse_encode(self.value_json, serializer);
        <Option<String>>::sse_encode(self.old_value_json, serializer);
        <u64>::sse_encode(self.revision, serializer);
        <String>::sse_encode(self.source, serializer);
    }
}

fn snapshot_dto(snapshot: gstore_core::config::ConfigSnapshot) -> ConfigSnapshotDto {
    let module = snapshot.key.module().to_string();
    let key = snapshot.key.key().to_string();
    let wire_key = snapshot.key.wire();
    ConfigSnapshotDto {
        module,
        key,
        wire_key,
        value_json: option_json_text(&snapshot.value),
        masked: snapshot.masked,
        revision: snapshot.revision,
        updated_at: snapshot.updated_at,
        updated_by: snapshot.updated_by,
    }
}

fn entry_dto(
    entry: &'static gstore_core::config::ConfigEntry,
    snapshot: Option<gstore_core::config::ConfigSnapshot>,
) -> ConfigEntryDto {
    let (value, masked, revision) = match snapshot {
        Some(snapshot) => (
            snapshot.value.unwrap_or(Value::Null),
            snapshot.masked,
            snapshot.revision,
        ),
        None => (entry.default_json.clone(), false, 0),
    };
    // Defence in depth: a secret default must never appear raw either.
    let value = secrets::mask_if_secret(entry, &value);
    ConfigEntryDto {
        module: entry.key.module().to_string(),
        key: entry.key.key().to_string(),
        wire_key: entry.key.wire(),
        value_type: entry.value_type.as_str().to_string(),
        value_json: json_text(&value),
        masked,
        revision,
        sensitive: entry.sensitive,
        agent_accessible: entry.agent_accessible,
        visibility: entry.visibility.as_str().to_string(),
        default_json: json_text(&secrets::mask_if_secret(entry, &entry.default_json)),
        description_zh: entry.description_zh.clone(),
        description_en: entry.description_en.clone(),
        category: entry.category.clone(),
        unit: entry.unit.clone(),
        min: entry.min,
        max: entry.max,
        enum_values: entry.enum_values.clone(),
        example: entry.example.clone(),
    }
}

// ---------------------------------------------------------------------------
// Sink registry (per-filter list, C18)
// ---------------------------------------------------------------------------

/// Anything that can receive a change DTO (FRB sink or a test recorder).
pub trait ConfigSinkTarget: Send + Sync {
    /// Returns `false` when the sink must be pruned.
    fn deliver(&self, change: ConfigChangeDto) -> bool;
}

struct FrbSink(StreamSink<ConfigChangeDto>);

impl ConfigSinkTarget for FrbSink {
    fn deliver(&self, change: ConfigChangeDto) -> bool {
        self.0.add(change).is_ok()
    }
}

struct SinkGroup {
    module: String,
    key: Option<String>,
    token: ConfigToken,
    sinks: Vec<Arc<dyn ConfigSinkTarget>>,
}

static CONFIG_SINKS: Mutex<Vec<SinkGroup>> = Mutex::new(Vec::new());
static CONFIG_EVENT_SINKS: Mutex<Vec<Arc<dyn ConfigSinkTarget>>> = Mutex::new(Vec::new());
static CONFIG_EVENT_TOKENS: Mutex<Vec<ConfigToken>> = Mutex::new(Vec::new());

fn dispatch(module: &str, key: Option<&str>, change: &ConfigChangeDto) {
    let mut groups = mutex_lock(&CONFIG_SINKS);
    for group in groups.iter_mut() {
        if group.module == module && group.key.as_deref() == key {
            group.sinks.retain(|sink| sink.deliver(change.clone()));
        }
    }
}

fn dispatch_global(change: &ConfigChangeDto) {
    mutex_lock(&CONFIG_EVENT_SINKS).retain(|sink| sink.deliver(change.clone()));
}

fn register_group(
    module: String,
    key: Option<String>,
    target: Arc<dyn ConfigSinkTarget>,
) -> Result<(), String> {
    let bus = bus()?;
    let mut groups = mutex_lock(&CONFIG_SINKS);
    if let Some(group) = groups
        .iter_mut()
        .find(|group| group.module == module && group.key == key)
    {
        group.sinks.push(target);
        return Ok(());
    }
    let callback_module = module.clone();
    let callback_key = key.clone();
    let token = bus.subscribe(
        ConfigCaller::Dart,
        ConfigFilter::new(module.clone(), key.clone()),
        move |payload| {
            let change = ConfigChangeDto::from_payload(payload);
            dispatch(&callback_module, callback_key.as_deref(), &change);
        },
    );
    groups.push(SinkGroup {
        module,
        key,
        token,
        sinks: vec![target],
    });
    Ok(())
}

fn ensure_global_subscriptions() {
    let Ok(bus) = bus() else {
        return;
    };
    let mut tokens = mutex_lock(&CONFIG_EVENT_TOKENS);
    if !tokens.is_empty() {
        return;
    }
    for module in registered_modules() {
        let token = bus.subscribe(
            ConfigCaller::Dart,
            ConfigFilter::whole_module(module),
            move |payload| dispatch_global(&ConfigChangeDto::from_payload(payload)),
        );
        tokens.push(token);
    }
}

/// Every module namespace present in the registry, sorted and deduplicated.
///
/// `schema::MODULE_NAMES` is only the eleven `module.<name>.enabled` toggles;
/// the global stream must cover every registered owner namespace instead.
fn registered_modules() -> Vec<&'static str> {
    let mut modules: Vec<&'static str> = schema::entries()
        .iter()
        .map(|entry| entry.key.module())
        .collect();
    modules.sort_unstable();
    modules.dedup();
    modules
}

/// Registers one Dart sink for `(module, key)`; `key = None` is whole-module.
pub(crate) fn watch_stream(module: String, key: Option<String>, sink: StreamSink<ConfigChangeDto>) {
    let _ = register_group(module, key, Arc::new(FrbSink(sink)));
}

/// Registers the global compatibility sink (all modules).
pub(crate) fn events_stream(sink: StreamSink<ConfigChangeDto>) {
    mutex_lock(&CONFIG_EVENT_SINKS).push(Arc::new(FrbSink(sink)));
    ensure_global_subscriptions();
}

/// Test seam: registers an in-memory sink without an FRB runtime.
#[doc(hidden)]
pub fn watch_recording(
    module: String,
    key: Option<String>,
    sink: RecordingConfigSink,
) -> Result<(), String> {
    register_group(module, key, Arc::new(sink))
}

/// Test seam: registers the global compatibility recorder.
#[doc(hidden)]
pub fn events_recording(sink: RecordingConfigSink) {
    mutex_lock(&CONFIG_EVENT_SINKS).push(Arc::new(sink));
    ensure_global_subscriptions();
}

/// In-memory sink used by tests to count deliveries (no FRB runtime needed).
#[doc(hidden)]
#[derive(Clone, Default)]
pub struct RecordingConfigSink {
    changes: Arc<Mutex<Vec<ConfigChangeDto>>>,
    failing: Arc<AtomicBool>,
}

impl RecordingConfigSink {
    pub fn new() -> Self {
        Self::default()
    }

    /// Marks the sink as failing; the next delivery returns `false` and the
    /// registry prunes it (C18 cancel/abort path).
    pub fn set_failing(&self, failing: bool) {
        self.failing.store(failing, Ordering::SeqCst);
    }

    /// Snapshot of everything delivered so far.
    pub fn received(&self) -> Vec<ConfigChangeDto> {
        mutex_lock(&self.changes).clone()
    }

    pub fn count(&self) -> usize {
        mutex_lock(&self.changes).len()
    }
}

impl ConfigSinkTarget for RecordingConfigSink {
    fn deliver(&self, change: ConfigChangeDto) -> bool {
        if self.failing.load(Ordering::SeqCst) {
            return false;
        }
        mutex_lock(&self.changes).push(change);
        true
    }
}

/// Unsubscribes every config bus subscription and drops every sink.
pub(crate) fn clear_sinks() {
    let bus = read_lock(&CONFIG_BUS).clone();
    let groups = std::mem::take(&mut *mutex_lock(&CONFIG_SINKS));
    let tokens = std::mem::take(&mut *mutex_lock(&CONFIG_EVENT_TOKENS));
    if let Some(bus) = bus {
        for group in groups {
            let _ = bus.unsubscribe(&group.token);
        }
        for token in tokens {
            let _ = bus.unsubscribe(&token);
        }
    }
    mutex_lock(&CONFIG_EVENT_SINKS).clear();
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

pub(crate) fn api_init() -> Result<(), String> {
    store().map(|_| ())
}

pub(crate) fn get(module: String, key: String, masked: bool) -> Result<String, String> {
    let key = parse_key(&module, &key)?;
    let store = store()?;
    let value = if masked {
        store.get_masked(&key)
    } else {
        store.get(&key)
    }
    .map_err(|error| error.to_string())?;
    Ok(json_text(&value))
}

fn publish_change(change: &ConfigChange) {
    let Ok(bus) = bus() else {
        return;
    };
    if let Err(error) = bus.publish(change) {
        log::warn!("config: event publish failed for {}: {error}", change.wire_key());
    }
}

pub(crate) fn set(
    module: String,
    key: String,
    value_json: String,
    source: String,
) -> Result<ConfigOpResultDto, String> {
    let key = parse_key(&module, &key)?;
    let value = parse_json(&value_json)?;
    let source = parse_source(&source)?;
    let store = store()?;
    let change = store
        .set(&key, value, source, None)
        .map_err(|error| error.to_string())?;
    publish_change(&change);
    Ok(op_result("set", &change, &key))
}

pub(crate) fn clear(
    module: String,
    key: String,
    source: String,
) -> Result<ConfigOpResultDto, String> {
    let key = parse_key(&module, &key)?;
    let source = parse_source(&source)?;
    let store = store()?;
    let change = store
        .remove(&key, source, None)
        .map_err(|error| error.to_string())?;
    publish_change(&change);
    Ok(op_result("clear", &change, &key))
}

pub(crate) fn reset(
    module: String,
    key: String,
    source: String,
) -> Result<ConfigOpResultDto, String> {
    let key = parse_key(&module, &key)?;
    let source = parse_source(&source)?;
    let store = store()?;
    let change = store
        .reset(&key, source, None)
        .map_err(|error| error.to_string())?;
    publish_change(&change);
    Ok(op_result("reset", &change, &key))
}

fn op_result(action: &str, change: &ConfigChange, key: &ConfigKey) -> ConfigOpResultDto {
    let default_json = schema::entry(key)
        .map(|entry| json_text(&secrets::mask_if_secret(entry, &entry.default_json)))
        .unwrap_or_else(|| "null".to_string());
    ConfigOpResultDto {
        success: true,
        message: format!("{action} {}", key.wire()),
        module: key.module().to_string(),
        key: key.key().to_string(),
        wire_key: key.wire(),
        value_json: option_json_text(&change.new_json),
        default_json,
    }
}

pub(crate) fn list(module: Option<String>) -> Result<Vec<ConfigEntryDto>, String> {
    let store = store()?;
    let mut out = Vec::new();
    for entry in schema::entries() {
        if module
            .as_deref()
            .is_some_and(|name| entry.key.module() != name)
        {
            continue;
        }
        let snapshot = store
            .snapshot(&entry.key)
            .map_err(|error| error.to_string())?;
        out.push(entry_dto(entry, snapshot));
    }
    Ok(out)
}

pub(crate) fn snapshot(
    module: String,
    key: String,
) -> Result<Option<ConfigSnapshotDto>, String> {
    let key = parse_key(&module, &key)?;
    let store = store()?;
    Ok(store
        .snapshot(&key)
        .map_err(|error| error.to_string())?
        .map(snapshot_dto))
}

pub(crate) fn snapshots(module: Option<String>) -> Result<Vec<ConfigSnapshotDto>, String> {
    let store = store()?;
    Ok(store
        .snapshots(module.as_deref())
        .map_err(|error| error.to_string())?
        .into_iter()
        .map(snapshot_dto)
        .collect())
}

pub(crate) fn export() -> Result<ConfigExportDto, String> {
    let store = store()?;
    let entries = store
        .export()
        .map_err(|error| error.to_string())?
        .into_iter()
        .map(|entry| ConfigExportEntryDto {
            module: entry.key.module().to_string(),
            key: entry.key.key().to_string(),
            wire_key: entry.key.wire(),
            value_json: json_text(&entry.value),
        })
        .collect();
    Ok(ConfigExportDto {
        revision: store.revision(),
        entries,
    })
}

fn collect_import_entries(
    entries: Vec<ConfigImportEntryDto>,
) -> (
    Vec<(ConfigKey, Value)>,
    Vec<ConfigImportFailureDto>,
) {
    let mut parsed = Vec::new();
    let mut failed = Vec::new();
    for entry in entries {
        let key = match ConfigKey::new(entry.module.clone(), entry.key.clone()) {
            Ok(key) => key,
            Err(error) => {
                failed.push(ConfigImportFailureDto {
                    module: entry.module,
                    key: entry.key,
                    code: error.code().to_string(),
                });
                continue;
            }
        };
        match serde_json::from_str::<Value>(&entry.value_json) {
            Ok(value) => parsed.push((key, value)),
            Err(_) => failed.push(ConfigImportFailureDto {
                module: entry.module,
                key: entry.key,
                code: "config_invalid_json".to_string(),
            }),
        }
    }
    (parsed, failed)
}

pub(crate) fn import(
    entries: Vec<ConfigImportEntryDto>,
    source: String,
) -> Result<ConfigImportReportDto, String> {
    let source = parse_source(&source)?;
    let total = u32::try_from(entries.len()).unwrap_or(u32::MAX);
    let (parsed, mut failed) = collect_import_entries(entries);
    let store = store()?;
    let bus = bus()?;
    let report = config_import::import_batch_with_events(&store, &bus, &parsed, source, true)
        .map_err(|error| error.to_string())?;
    failed.extend(report.failed.into_iter().map(|(key, code)| {
        ConfigImportFailureDto {
            module: key.module().to_string(),
            key: key.key().to_string(),
            code,
        }
    }));
    Ok(ConfigImportReportDto {
        total,
        applied: u32::try_from(report.applied).unwrap_or(u32::MAX),
        unchanged: u32::try_from(report.unchanged).unwrap_or(u32::MAX),
        failed,
        events_published: u32::try_from(report.events_published).unwrap_or(u32::MAX),
    })
}

pub(crate) fn verify(entries: Vec<ConfigVerifyEntryDto>) -> Result<ConfigVerifyReportDto, String> {
    let store = store()?;
    let total = u32::try_from(entries.len()).unwrap_or(u32::MAX);
    let mut parsed = Vec::new();
    let mut results = Vec::new();
    for entry in entries {
        let key = match ConfigKey::new(entry.module.clone(), entry.key.clone()) {
            Ok(key) => key,
            Err(error) => {
                results.push(ConfigVerifyResultDto {
                    module: entry.module,
                    key: entry.key,
                    status: "rejected".to_string(),
                    code: Some(error.code().to_string()),
                });
                continue;
            }
        };
        match serde_json::from_str::<Value>(&entry.value_json) {
            Ok(value) => parsed.push((key, value)),
            Err(_) => results.push(ConfigVerifyResultDto {
                module: entry.module,
                key: entry.key,
                status: "rejected".to_string(),
                code: Some("config_invalid_json".to_string()),
            }),
        }
    }

    let report = config_import::verify(&store, &parsed).map_err(|error| error.to_string())?;
    let mut matched = u32::try_from(report.matched).unwrap_or(u32::MAX);
    for result in report.results {
        let (status, code) = match result.status {
            gstore_core::config::VerifyStatus::Match => ("match".to_string(), None),
            gstore_core::config::VerifyStatus::Mismatch => ("mismatch".to_string(), None),
            gstore_core::config::VerifyStatus::Rejected(code) => ("rejected".to_string(), Some(code)),
            gstore_core::config::VerifyStatus::Error(code) => ("error".to_string(), Some(code)),
        };
        results.push(ConfigVerifyResultDto {
            module: result.key.module().to_string(),
            key: result.key.key().to_string(),
            status,
            code,
        });
    }
    // Parse failures were not part of the core report; keep the totals honest.
    let parsed_total = u32::try_from(parsed.len()).unwrap_or(u32::MAX);
    if parsed_total < total {
        matched = matched.min(parsed_total);
    }
    Ok(ConfigVerifyReportDto {
        total,
        matched,
        all_matched: matched == total,
        results,
    })
}

pub(crate) fn meta_get(key: String) -> Result<Option<String>, String> {
    let db = meta_db()?;
    let conn = db.reader().map_err(|error| error.to_string())?;
    conn.query_row(
        "SELECT v FROM config_meta WHERE k=?1",
        rusqlite::params![key],
        |row| row.get::<_, String>(0),
    )
    .optional()
    .map_err(|error| error.to_string())
}

pub(crate) fn meta_set(key: String, value: String) -> Result<(), String> {
    if key == "revision" {
        return Err("[config_meta_reserved] revision is owned by the store".to_string());
    }
    let db = meta_db()?;
    let writer = db.writer().map_err(|error| error.to_string())?;
    writer
        .execute(
            "INSERT INTO config_meta(k, v) VALUES (?1, ?2) \
             ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            rusqlite::params![key, value],
        )
        .map_err(|error| error.to_string())?;
    Ok(())
}

/// Hydrates the store cache from the committed database.
///
/// This performs **no legacy migration** (that is Todo 21). `schema_ready` is
/// `true` once the store has been loaded from the committed schema;
/// `migrated` is always `false` here so callers cannot mistake hydration for
/// migration success.
pub(crate) fn ensure_migrated() -> Result<ConfigMigrationStateDto, String> {
    let store = store()?;
    store.load_all().map_err(|error| error.to_string())?;
    Ok(ConfigMigrationStateDto {
        schema_ready: true,
        migrated: false,
    })
}
