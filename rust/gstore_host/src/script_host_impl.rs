//! Production [`ScriptHost`] for the Rust script lane.
//!
//! One instance is bound to one channel runtime, so channel isolation is a
//! construction property: the host never reads a channel from the script
//! payload, every capability uses the [`ScriptChannel`] the engine passes in.
//!
//! | capability | backing seam |
//! |---|---|
//! | `http` | any injected [`ScriptHttp`] (production: `ReqwestHttpPort` with per-request caps) |
//! | `db_*` | core `channel_apps` rows via [`DbHandle`] |
//! | `config_get` | channel config snapshot injected by `ScriptApi::set_config` (`null` when absent) |
//! | `env_*` | shared channel env snapshot (hot-updated by `ScriptApi::set_env`) |
//! | `check_version` | core installed-app inventory |
//! | `log` | the host LogBridge ring |
//! | `native_call` | `ns=ui` -> the `script.ui_request` round-trip; other namespaces -> unregistered envelope |

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::http_port::ScriptHttp;
use gstore_core::db::DbHandle;
use gstore_core::inventory::InventoryStore;
use gstore_script::{
    CheckVersionRequest, ConfigGetRequest, DatabaseAppRequest, DatabaseAppsRequest,
    DatabaseInsertRequest, EnvAllRequest, EnvGetRequest, EnvHasRequest, HttpRequest,
    HttpResponse as HostHttpResponse, InstalledInfo, LogLevel, LogRequest, NativeCallRequest,
    ScriptChannel, ScriptError, ScriptHost, UiRequest,
};
use serde_json::Value as JsonValue;

/// Shared, hot-updatable env snapshot type.
pub type EnvMap = BTreeMap<String, String>;

/// Shared, hot-updatable config snapshot type (JSON values, `null` on a miss).
pub type ConfigMap = BTreeMap<String, JsonValue>;

/// Host capabilities bound to one channel runtime.
pub(crate) struct ScriptHostImpl {
    db: DbHandle,
    http: Arc<dyn ScriptHttp>,
    env: Arc<Mutex<EnvMap>>,
    app_id: Arc<Mutex<Option<String>>>,
    config: Arc<Mutex<ConfigMap>>,
    ui_budget: Duration,
    /// Set while this host is parked inside a `host.ui.call` round-trip. Shared
    /// with the owning [`ScriptEntry`](crate::script_runtime_entry::ScriptEntry)
    /// so a re-entrant dispatch is rejected instead of deadlocking on `op`.
    parked: Arc<AtomicBool>,
}

impl ScriptHostImpl {
    pub(crate) fn new(
        db: DbHandle,
        http: Arc<dyn ScriptHttp>,
        env: Arc<Mutex<EnvMap>>,
        app_id: Arc<Mutex<Option<String>>>,
        config: Arc<Mutex<ConfigMap>>,
        ui_budget: Duration,
        parked: Arc<AtomicBool>,
    ) -> Self {
        Self {
            db,
            http,
            env,
            app_id,
            config,
            ui_budget,
            parked,
        }
    }

    fn current_app_id(&self) -> Option<String> {
        self.app_id.lock().ok().and_then(|guard| guard.clone())
    }

    fn env_map(&self) -> Result<EnvMap, ScriptError> {
        self.env
            .lock()
            .map(|guard| guard.clone())
            .map_err(|_| ScriptError::host("channel env snapshot is poisoned"))
    }
}

impl ScriptHost for ScriptHostImpl {
    fn http(
        &self,
        _channel: &ScriptChannel,
        request: HttpRequest,
    ) -> Result<HostHttpResponse, ScriptError> {
        crate::script_http::perform(&self.http, request)
    }

    fn db_get_apps(
        &self,
        channel: &ScriptChannel,
        _request: DatabaseAppsRequest,
    ) -> Result<Vec<gstore_script::ChannelApp>, ScriptError> {
        crate::script_db::get_apps(&self.db, channel)
    }

    fn db_get_app(
        &self,
        channel: &ScriptChannel,
        request: DatabaseAppRequest,
    ) -> Result<Option<gstore_script::ChannelApp>, ScriptError> {
        crate::script_db::get_app(&self.db, channel, request)
    }

    fn db_insert_apps(
        &self,
        channel: &ScriptChannel,
        request: DatabaseInsertRequest,
    ) -> Result<usize, ScriptError> {
        crate::script_db::insert_apps(&self.db, channel, request)
    }

    fn config_get(
        &self,
        _channel: &ScriptChannel,
        request: ConfigGetRequest,
    ) -> Result<JsonValue, ScriptError> {
        self.config
            .lock()
            .map(|config| config.get(&request.key).cloned().unwrap_or(JsonValue::Null))
            .map_err(|_| ScriptError::host("channel config snapshot is poisoned"))
    }

    fn env_get(
        &self,
        _channel: &ScriptChannel,
        request: EnvGetRequest,
    ) -> Result<Option<String>, ScriptError> {
        Ok(self.env_map()?.get(&request.name).cloned())
    }

    fn env_all(
        &self,
        _channel: &ScriptChannel,
        _request: EnvAllRequest,
    ) -> Result<gstore_script::EnvSnapshot, ScriptError> {
        self.env_map()
    }

    fn env_has(
        &self,
        _channel: &ScriptChannel,
        request: EnvHasRequest,
    ) -> Result<bool, ScriptError> {
        Ok(self.env_map()?.contains_key(&request.name))
    }

    fn check_version(
        &self,
        _channel: &ScriptChannel,
        request: CheckVersionRequest,
    ) -> Result<InstalledInfo, ScriptError> {
        let found = InventoryStore::new(self.db.clone())
            .get(&request.package_name)
            .map_err(|error| {
                ScriptError::host(format!(
                    "CORE_E_SCRIPT_HOST: check version: {}",
                    error.message()
                ))
            })?;
        Ok(match found {
            Some(app) => InstalledInfo::installed(
                Some(app.version_name),
                Some(app.version_code),
                app.app_name,
            ),
            None => InstalledInfo::not_installed(),
        })
    }

    fn log(&self, channel: &ScriptChannel, request: LogRequest) -> Result<(), ScriptError> {
        let level = match request.level {
            LogLevel::Info => 1,
            LogLevel::Error => 3,
        };
        crate::log_bridge::push_host_log(
            level,
            format!("[script:{}] {}", channel.as_str(), request.message),
        );
        Ok(())
    }

    fn native_call(
        &self,
        channel: &ScriptChannel,
        request: NativeCallRequest,
    ) -> Result<Option<JsonValue>, ScriptError> {
        if request.namespace != "ui" || !crate::ui_api::is_ui_method(&request.method) {
            return Ok(None);
        }
        self.parked.store(true, Ordering::SeqCst);
        let result = crate::ui_api::request(
            channel,
            self.current_app_id(),
            &request.method,
            &request.payload,
            self.ui_budget,
        );
        self.parked.store(false, Ordering::SeqCst);
        result.map(Some)
    }

    fn ui_request(
        &self,
        channel: &ScriptChannel,
        request: UiRequest,
    ) -> Result<JsonValue, ScriptError> {
        if !crate::ui_api::is_ui_method(&request.method) {
            return Err(ScriptError::host(format!(
                "host.native.ui.{} 未注册",
                request.method
            )));
        }
        self.parked.store(true, Ordering::SeqCst);
        let result = crate::ui_api::request(
            channel,
            self.current_app_id(),
            &request.method,
            &request.payload,
            self.ui_budget,
        );
        self.parked.store(false, Ordering::SeqCst);
        result
    }
}
