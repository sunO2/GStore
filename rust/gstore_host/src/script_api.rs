//! `ScriptApi`: import/list/refresh local JS packs and execute their `main`.
//!
//! # Runtime model
//!
//! `ScriptApi` is the FRB-facing facade over a [`PackStore`] and a small cache of
//! per-channel runtimes. An installed pack contributes up to two QuickJS
//! runtimes: `entry.js` for the discovery methods and `detail.js` for the page
//! methods. Runtimes are created lazily, are serialised per channel, and are
//! re-created by `refresh`/`import`/`remove`; dropping them joins their thread.
//!
//! Every call evaluates `(typeof main === 'function' ? main(method, params) :
//! null)` with [`ScriptRuntime::eval_long`](gstore_script::ScriptRuntime::eval_long)
//! and unwraps the same envelope core's `ScriptChannel` uses (`null` -> `null`,
//! `{ok:false}` -> typed error). Using the long budget is deliberate: a script
//! may park on `host.ui.call` for up to the UI budget, and the normal 5 s
//! deadline must not fire while parked. The long budget is set to
//! `UI budget + 5 s` so the UI timeout wins first.
//!
//! # Parked wait / cumulative budget
//!
//! The UI wait is wrapped in [`ScriptRuntime::begin_park`](gstore_script::ScriptRuntime::begin_park):
//! the leaf crate suspends both the interrupt deadline and the cumulative eval
//! clock for the parked interval, bounded by the same UI budget. Unparking
//! extends the deadline by exactly the exempted interval, so the remaining
//! budget is charged normally (parking pauses the clock, it does not reset it).
//!
//! # Config injection
//!
//! `set_config(key, values)` populates the channel-scoped snapshot read by
//! `host.config.get`. Each value is a JSON document (for example `"\"sit\""`
//! for the string `sit`, `42` for a number), parsed at this boundary; a miss
//! returns `null`. The snapshot lives on the API instance's entry for that pack,
//! like the cached runtimes and env hot-updates.
//!
//! # Policy
//!
//! `import` is strict by default (Todo 9 behaviour). A previously installed key
//! retries with [`PackPolicy::LegacyPermissive`] only when the strict decode
//! fails, so a brand-new pack can never be imported permissively.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gstore_core::channel::{validate_channel_key, PackPolicy, PackStore, ScriptChannelStore};
use gstore_core::db::DbHandle;
use gstore_core::dto::ChannelKey;
use gstore_core::ports::{FileSecretStore, HttpPort};
use gstore_script::SandboxLimits;

use crate::script_db::SqliteScriptChannelStore;
use crate::script_env;
use crate::script_pack;
pub(crate) use crate::script_pack::ScriptPackInfo;
use crate::script_runtime_entry::{classify, parse_params, EntryDeps, ScriptEntry};

/// Default UI wall-clock budget (Todo 5: 30 s).
pub(crate) const DEFAULT_UI_BUDGET: Duration = Duration::from_secs(30);
/// Default normal eval budget (kept for parity / the test seam).
pub(crate) const DEFAULT_EVAL_TIMEOUT: Duration = Duration::from_secs(5);

/// Shared state behind the FRB facade.
pub(crate) struct ScriptApiInner {
    db: DbHandle,
    store: Arc<dyn ScriptChannelStore>,
    strict: PackStore,
    legacy: PackStore,
    secrets: FileSecretStore,
    http: Arc<dyn HttpPort>,
    entries: Mutex<HashMap<String, Arc<ScriptEntry>>>,
    ui_budget: Duration,
    eval_timeout: Duration,
    cumulative_budget: Duration,
}

impl ScriptApiInner {
    /// Production construction (reqwest transport, 30 s UI budget).
    pub(crate) fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<Self, String> {
        let http: Arc<dyn HttpPort> = Arc::new(crate::http_port::ReqwestHttpPort::new());
        Self::init_with_ports(
            data_dir,
            files_dir,
            cache_dir,
            http,
            DEFAULT_UI_BUDGET,
            DEFAULT_EVAL_TIMEOUT,
            SandboxLimits::default().cumulative_eval_budget,
        )
    }

    pub(crate) fn init_with_ports(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
        http: Arc<dyn HttpPort>,
        ui_budget: Duration,
        eval_timeout: Duration,
        cumulative_budget: Duration,
    ) -> Result<Self, String> {
        for dir in [&data_dir, &files_dir, &cache_dir] {
            std::fs::create_dir_all(dir)
                .map_err(|error| format!("io: create dir {dir}: {error}"))?;
        }
        let db = DbHandle::open(Path::new(&data_dir))
            .map_err(|error| format!("io: open core db: {}", error.0))?;
        let store: Arc<dyn ScriptChannelStore> =
            Arc::new(SqliteScriptChannelStore::new(db.clone()));
        let root = Path::new(&files_dir).join("channel_packs");
        Ok(Self {
            db: db.clone(),
            store,
            strict: PackStore::new(root.clone(), db.clone()).with_policy(PackPolicy::Strict),
            legacy: PackStore::new(root, db.clone()).with_policy(PackPolicy::LegacyPermissive),
            secrets: FileSecretStore::new(Path::new(&files_dir).join("secrets")),
            http,
            entries: Mutex::new(HashMap::new()),
            ui_budget,
            eval_timeout,
            cumulative_budget,
        })
    }

    /// Imports `bytes` (a legacy flat zip) under `expected_key` when given.
    pub(crate) fn import(
        &self,
        bytes: Vec<u8>,
        expected_key: Option<String>,
    ) -> Result<ScriptPackInfo, String> {
        if bytes.is_empty() {
            return Err("invalid_argument: pack bytes are empty".to_string());
        }
        let stem = script_pack::resolve_stem(expected_key.as_deref(), &bytes)?;
        let key = ChannelKey::new(format!("js_{stem}"))
            .map_err(|error| format!("invalid_argument: {error}"))?;
        validate_channel_key(&key).map_err(|error| format!("invalid_argument: {error}"))?;
        let already_installed = self.strict.installed_pack(&key).is_ok();
        let dir = script_pack::temp_dir("import");
        std::fs::create_dir_all(&dir)
            .map_err(|error| format!("io: create pack temp dir {}: {error}", dir.display()))?;
        let zip_path = dir.join(format!("{stem}.zip"));
        std::fs::write(&zip_path, &bytes)
            .map_err(|error| format!("io: write pack temp file {}: {error}", zip_path.display()))?;
        let result = match self.strict.import_pack(&zip_path) {
            Ok(installed) => Ok(installed),
            Err(strict_error) if already_installed => {
                self.legacy.import_pack(&zip_path).map_err(|legacy_error| {
                    format!(
                        "{}; legacy retry: {}",
                        script_pack::pack_err(&strict_error),
                        script_pack::pack_err(&legacy_error)
                    )
                })
            }
            Err(error) => Err(script_pack::pack_err(&error)),
        };
        let _ = std::fs::remove_dir_all(&dir);
        let installed = result?;
        self.invalidate(key.as_str());
        Ok(script_pack::info_from_installed(&installed))
    }

    /// Removes a pack: cached runtimes, env row/secrets, then the files and row.
    pub(crate) fn remove(&self, key: &str) -> Result<(), String> {
        let key = self.channel_key(key)?;
        self.ensure_entry(&key)?;
        script_env::clear(&self.db, &self.secrets, &key)?;
        self.strict
            .remove_pack(&key)
            .map_err(|error| script_pack::pack_err(&error))?;
        self.invalidate(key.as_str());
        Ok(())
    }

    /// Reloads a pack from its installed directory and rebuilds its runtimes.
    pub(crate) fn refresh(&self, key: &str) -> Result<ScriptPackInfo, String> {
        let key = self.channel_key(key)?;
        let info = script_pack::info(&self.strict, &key)?;
        self.invalidate(key.as_str());
        Ok(info)
    }

    /// Replaces the persisted env and hot-updates every live runtime snapshot.
    pub(crate) fn set_env(&self, key: &str, values: HashMap<String, String>) -> Result<(), String> {
        let key = self.channel_key(key)?;
        let entry = self.ensure_entry(&key)?;
        let values = values.into_iter().collect();
        let saved = script_env::save(&self.db, &self.secrets, &key, &values)?;
        entry.replace_env(saved);
        Ok(())
    }

    /// Replaces the channel config snapshot read by `host.config.get`.
    ///
    /// Values are channel-scoped and hot-updated on the live entry (the same
    /// lifetime as the cached runtimes). Each value must be a JSON document;
    /// `host.config.get` returns it verbatim, or `null` for a key that was never
    /// injected.
    pub(crate) fn set_config(
        &self,
        key: &str,
        values: HashMap<String, String>,
    ) -> Result<(), String> {
        let key = self.channel_key(key)?;
        let mut config = BTreeMap::new();
        for (name, text) in values {
            let value = serde_json::from_str(&text).map_err(|error| {
                format!("invalid_argument: config `{name}` is not valid JSON: {error}")
            })?;
            config.insert(name, value);
        }
        let entry = self.ensure_entry(&key)?;
        entry.replace_config(config);
        Ok(())
    }

    /// Runs `main(method, params)` and returns the raw JSON result as a string.
    pub(crate) fn run(&self, key: &str, method: &str, params_json: &str) -> Result<String, String> {
        let key = self.channel_key(key)?;
        let params = parse_params(params_json)?;
        let kind = classify(method).ok_or_else(|| {
            format!("unsupported: script method `{method}` is not supported by ScriptApi")
        })?;
        self.ensure_entry(&key)?.run(kind, method, &params)
    }

    /// Lists every installed pack in deterministic key order.
    pub(crate) fn list(&self) -> Result<Vec<ScriptPackInfo>, String> {
        let keys = {
            let conn = self
                .db
                .reader()
                .map_err(|error| format!("io: read pack list: {}", error.0))?;
            let mut statement = conn
                .prepare("SELECT key FROM channel_packs ORDER BY key")
                .map_err(|error| format!("io: prepare pack list: {error}"))?;
            let rows = statement
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|error| format!("io: query pack list: {error}"))?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|error| format!("io: pack list row: {error}"))?
        };
        keys.iter()
            .map(|key| {
                let key = self.channel_key(key)?;
                script_pack::info(&self.strict, &key)
            })
            .collect()
    }

    /// Returns the saved app rows for `key` as a JSON array string.
    pub(crate) fn stored_apps(&self, key: &str) -> Result<String, String> {
        let key = self.channel_key(key)?;
        let entry = self.ensure_entry(&key)?;
        let apps = entry
            .store()
            .list_apps(&key)
            .map_err(|error| format!("{}: {}", error.code(), error.message()))?;
        serde_json::to_string(&apps)
            .map_err(|error| format!("internal: encode stored apps: {error}"))
    }

    /// Releases the `app_id` detail runtime; unknown ids are a no-op.
    pub(crate) fn release_detail(&self, key: &str, app_id: &str) -> Result<(), String> {
        let key = self.channel_key(key)?;
        let entry = {
            let entries = self
                .entries
                .lock()
                .map_err(|_| "internal: script entry cache poisoned".to_string())?;
            entries.get(key.as_str()).cloned()
        };
        match entry {
            Some(entry) => entry.release_detail(app_id),
            None => Ok(()),
        }
    }

    fn channel_key(&self, key: &str) -> Result<ChannelKey, String> {
        let key =
            ChannelKey::new(key.trim()).map_err(|error| format!("invalid_argument: {error}"))?;
        validate_channel_key(&key).map_err(|error| format!("invalid_argument: {error}"))?;
        Ok(key)
    }

    fn invalidate(&self, key: &str) {
        if let Ok(mut entries) = self.entries.lock() {
            entries.remove(key);
        }
    }

    fn ensure_entry(&self, key: &ChannelKey) -> Result<Arc<ScriptEntry>, String> {
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| "internal: script entry cache poisoned".to_string())?;
        if let Some(entry) = entries.get(key.as_str()) {
            return Ok(Arc::clone(entry));
        }
        let loaded = script_pack::load(&self.strict, key)?;
        let env = script_env::load(&self.db, &self.secrets, key)?;
        let entry = Arc::new(ScriptEntry::new(
            key.clone(),
            loaded,
            env,
            EntryDeps {
                db: self.db.clone(),
                store: Arc::clone(&self.store),
                http: Arc::clone(&self.http),
                ui_budget: self.ui_budget,
                eval_timeout: self.eval_timeout,
                cumulative_budget: self.cumulative_budget,
            },
        ));
        entries.insert(key.as_str().to_owned(), Arc::clone(&entry));
        Ok(entry)
    }
}
