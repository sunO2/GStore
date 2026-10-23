//! One installed pack's QuickJS runtimes: `entry.js` plus one `detail.js`
//! runtime per `appId` (Dart `JsChannel.getDetailChannel` / `releaseDetailChannel`).
//!
//! Both runtimes are created lazily on the same dedicated-thread machinery as
//! `gstore_script::ScriptRuntime`, are serialised by `op`, and share the env,
//! config, and app-id state that the host reads. Calls use `eval_long` because a
//! script may park on a UI request (see `ui_api.rs`).

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::http_port::ScriptHttp;
use gstore_core::channel::ScriptChannelStore;
use gstore_core::db::DbHandle;
use gstore_core::dto::ChannelKey;
use gstore_script::{
    SandboxLimits, ScriptChannel as EngineChannel, ScriptError, ScriptErrorKind, ScriptOptions,
    ScriptRuntime,
};
use serde_json::{Map, Value as JsonValue};

use crate::script_host_impl::{ConfigMap, EnvMap, ScriptHostImpl};
use crate::script_pack::LoadedPack;

/// Extra long-eval head-room granted so the UI timeout fires before QuickJS
/// interrupts the evaluation.
const UI_GRACE: Duration = Duration::from_secs(5);

/// Maximum live `detail.js` runtimes per pack (Dart releases per page exit;
/// the cap protects long-lived callers that never release).
const DETAIL_RUNTIME_CAP: usize = 4;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum RuntimeKind {
    Entry,
    Detail,
}

/// Infrastructure a pack runtime needs from the facade.
pub(crate) struct EntryDeps {
    pub db: DbHandle,
    pub store: Arc<dyn ScriptChannelStore>,
    pub http: Arc<dyn ScriptHttp>,
    pub ui_budget: Duration,
    pub eval_timeout: Duration,
    pub cumulative_budget: Duration,
}

pub(crate) struct ScriptEntry {
    key: ChannelKey,
    entry_js: String,
    detail_js: Option<String>,
    env: Arc<Mutex<EnvMap>>,
    config: Arc<Mutex<ConfigMap>>,
    app_id: Arc<Mutex<Option<String>>>,
    op: Mutex<()>,
    runtimes: Mutex<RuntimeSlots>,
    store: Arc<dyn ScriptChannelStore>,
    db: DbHandle,
    http: Arc<dyn ScriptHttp>,
    ui_budget: Duration,
    eval_timeout: Duration,
    cumulative_budget: Duration,
}

#[derive(Default)]
struct RuntimeSlots {
    entry: Option<ScriptRuntime>,
    detail: DetailRuntimes,
}

#[derive(Default)]
struct DetailRuntimes {
    order: VecDeque<String>,
    runtimes: HashMap<String, ScriptRuntime>,
}

impl DetailRuntimes {
    fn take(&mut self, app_id: &str) -> Option<ScriptRuntime> {
        self.order.retain(|key| key != app_id);
        self.runtimes.remove(app_id)
    }

    fn insert(&mut self, app_id: String, runtime: ScriptRuntime) -> Option<ScriptRuntime> {
        self.order.retain(|key| key != &app_id);
        self.order.push_back(app_id.clone());
        let evicted = if self.runtimes.len() >= DETAIL_RUNTIME_CAP {
            self.order
                .pop_front()
                .and_then(|oldest| self.runtimes.remove(&oldest))
        } else {
            None
        };
        self.runtimes.insert(app_id, runtime);
        evicted
    }
}

impl ScriptEntry {
    pub(crate) fn new(key: ChannelKey, loaded: LoadedPack, env: EnvMap, deps: EntryDeps) -> Self {
        Self {
            key,
            entry_js: loaded.entry_js,
            detail_js: loaded.detail_js,
            env: Arc::new(Mutex::new(env)),
            config: Arc::new(Mutex::new(ConfigMap::new())),
            app_id: Arc::new(Mutex::new(None)),
            op: Mutex::new(()),
            runtimes: Mutex::new(RuntimeSlots::default()),
            store: deps.store,
            db: deps.db,
            http: deps.http,
            ui_budget: deps.ui_budget,
            eval_timeout: deps.eval_timeout,
            cumulative_budget: deps.cumulative_budget,
        }
    }

    pub(crate) fn replace_env(&self, env: EnvMap) {
        if let Ok(mut guard) = self.env.lock() {
            *guard = env;
        }
    }

    pub(crate) fn replace_config(&self, config: ConfigMap) {
        if let Ok(mut guard) = self.config.lock() {
            *guard = config;
        }
    }

    pub(crate) fn run(
        &self,
        kind: RuntimeKind,
        method: &str,
        params: &Map<String, JsonValue>,
    ) -> Result<String, String> {
        let _op = self
            .op
            .lock()
            .map_err(|_| "internal: script runtime lock poisoned".to_string())?;
        if let Ok(mut app_id) = self.app_id.lock() {
            *app_id = params
                .get("appId")
                .and_then(JsonValue::as_str)
                .map(str::to_owned);
        }
        let method_json = serde_json::to_string(method)
            .map_err(|error| format!("internal: encode method: {error}"))?;
        let params_json = serde_json::to_string(params)
            .map_err(|error| format!("internal: encode params: {error}"))?;
        let source =
            format!("(typeof main === 'function' ? main({method_json}, {params_json}) : null)");
        let app_id = params.get("appId").and_then(JsonValue::as_str);
        let raw = self.eval(kind, &source, app_id)?;
        if let Ok(mut app_id) = self.app_id.lock() {
            *app_id = None;
        }
        let data = unwrap_envelope(method, raw)?;
        serde_json::to_string(&data)
            .map_err(|error| format!("internal: serialise script result: {error}"))
    }

    fn eval(
        &self,
        kind: RuntimeKind,
        source: &str,
        app_id: Option<&str>,
    ) -> Result<JsonValue, String> {
        match kind {
            RuntimeKind::Entry => {
                let script = self.entry_js.clone();
                let mut slots = self
                    .runtimes
                    .lock()
                    .map_err(|_| "internal: script runtime slots poisoned".to_string())?;
                if slots.entry.is_none() {
                    slots.entry = Some(self.spawn(&script)?);
                }
                match slots.entry.as_ref() {
                    Some(runtime) => runtime
                        .eval_long(source)
                        .map_err(|error| map_script(&error)),
                    None => Err("internal: script runtime missing after spawn".to_string()),
                }
            }
            RuntimeKind::Detail => {
                let script = self
                    .detail_js
                    .as_ref()
                    .ok_or_else(|| format!("not_found: pack `{}` has no detail.js", self.key))?
                    .clone();
                let app_id = app_id.unwrap_or("");
                let existing = {
                    let mut slots = self
                        .runtimes
                        .lock()
                        .map_err(|_| "internal: script runtime slots poisoned".to_string())?;
                    slots.detail.take(app_id)
                };
                let runtime = match existing {
                    Some(runtime) => runtime,
                    None => self.spawn(&script)?,
                };
                let result = runtime
                    .eval_long(source)
                    .map_err(|error| map_script(&error));
                let mut slots = self
                    .runtimes
                    .lock()
                    .map_err(|_| "internal: script runtime slots poisoned".to_string())?;
                if let Some(evicted) = slots.detail.insert(app_id.to_owned(), runtime) {
                    let _ = evicted.dispose();
                }
                result
            }
        }
    }

    /// Drops one app's detail runtime (Dart `releaseDetailChannel`).
    pub(crate) fn release_detail(&self, app_id: &str) -> Result<(), String> {
        let _op = self
            .op
            .lock()
            .map_err(|_| "internal: script runtime lock poisoned".to_string())?;
        let mut slots = self
            .runtimes
            .lock()
            .map_err(|_| "internal: script runtime slots poisoned".to_string())?;
        if let Some(runtime) = slots.detail.take(app_id) {
            runtime.dispose().map_err(|error| map_script(&error))?;
        }
        Ok(())
    }

    pub(crate) fn store(&self) -> &Arc<dyn ScriptChannelStore> {
        &self.store
    }

    fn spawn(&self, script: &str) -> Result<ScriptRuntime, String> {
        let limits = SandboxLimits::default()
            .with_eval_timeout(self.eval_timeout)
            .with_long_eval_timeout(self.ui_budget.saturating_add(UI_GRACE))
            .with_cumulative_eval_budget(self.cumulative_budget);
        let channel = EngineChannel::new(self.key.as_str()).map_err(|error| map_script(&error))?;
        let host = Arc::new(ScriptHostImpl::new(
            self.db.clone(),
            Arc::clone(&self.http),
            Arc::clone(&self.env),
            Arc::clone(&self.app_id),
            Arc::clone(&self.config),
            self.ui_budget,
        ));
        let runtime = ScriptRuntime::spawn(channel, ScriptOptions::new(limits), host)
            .map_err(|error| map_script(&error))?;
        runtime.eval(script).map_err(|error| map_script(&error))?;
        Ok(runtime)
    }
}

/// Entry methods use `entry.js`; page methods use `detail.js`.
pub(crate) fn classify(method: &str) -> Option<RuntimeKind> {
    match method {
        "getAllApps" | "searchApps" | "getAppInfo" | "getAppDetail" | "checkAppUpdate"
        | "checkUpdate" | "doUpdate" => Some(RuntimeKind::Entry),
        "versionOptions" | "switchVersion" | "buildHistory" | "detailMenu" => {
            Some(RuntimeKind::Detail)
        }
        _ => None,
    }
}

pub(crate) fn parse_params(raw: &str) -> Result<Map<String, JsonValue>, String> {
    if raw.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<JsonValue>(raw)
        .map_err(|error| format!("invalid_argument: params_json is not valid JSON: {error}"))?
    {
        JsonValue::Object(map) => Ok(map),
        JsonValue::Null => Ok(Map::new()),
        _ => Err("invalid_argument: params_json must be a JSON object or null".to_string()),
    }
}

fn unwrap_envelope(method: &str, raw: JsonValue) -> Result<JsonValue, String> {
    let JsonValue::Object(map) = raw else {
        return Ok(raw);
    };
    match map.get("ok") {
        None => Ok(JsonValue::Object(map)),
        Some(JsonValue::Bool(true)) => Ok(map
            .get("data")
            .filter(|value| !value.is_null())
            .cloned()
            .unwrap_or(JsonValue::Null)),
        Some(JsonValue::Bool(false)) => {
            let detail = map
                .get("error")
                .and_then(JsonValue::as_str)
                .unwrap_or("unknown error");
            Err(format!(
                "internal: script `{method}` returned ok:false: {detail}"
            ))
        }
        Some(_) => Err(format!(
            "internal: script `{method}` returned a non-boolean `ok`"
        )),
    }
}

fn map_script(error: &ScriptError) -> String {
    match error.kind() {
        ScriptErrorKind::InvalidArgument => format!("invalid_argument: {error}"),
        ScriptErrorKind::Timeout => error.to_string(),
        _ => format!("internal: {error}"),
    }
}
