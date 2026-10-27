//! The host-callback contract invoked by scripts via `sendMessage`.
//!
//! Every method is a capability with a default `not implemented` body, so a host
//! (the device layer in Todo 3, fakes in tests) implements only what it needs.
//! Every capability receives the [`ScriptChannel`] explicitly: database/env
//! isolation is structural rather than caller discipline.
//!
//! Envelope ownership lives here too: [`ScriptHost::send_message`] is the single
//! dispatcher that maps JS method strings to capabilities and builds the exact
//! Dart-compatible envelope. Errors from a capability become
//! `{ok:false, error:"<CODE>: <detail>"}` at the engine boundary; only runtime
//! faults (timeout/limit/invalid argument) throw in JS.

use serde_json::{json, Value as JsonValue};

use super::channel::ScriptChannel;
use super::error::ScriptError;
use super::host_types::{
    ChannelApp, CheckVersionRequest, ConfigGetRequest, DatabaseAppRequest, DatabaseAppsRequest,
    DatabaseInsertRequest, EnvAllRequest, EnvGetRequest, EnvHasRequest, EnvSnapshot, HttpMethod,
    HttpRequest, HttpResponse, InstalledInfo, LogLevel, LogRequest, NativeCallRequest, UiRequest,
};
use super::limits::SandboxLimits;

/// Host callbacks reachable from scripts through `sendMessage(method, payload)`.
///
/// Implementations run **on the channel's QuickJS thread** (synchronously, while
/// the script waits), so they must be thread-safe and bounded in time.
pub trait ScriptHost: Send + Sync {
    /// Single bridge dispatcher: parse the JS method string, route to the
    /// capability method, and return the JSON envelope verbatim.
    ///
    /// Hosts normally leave this at the default and implement capabilities. An
    /// `Err(ScriptError)` becomes `{ok:false, error:"<CODE>: <detail>"}`. A panic
    /// is caught as `CORE_E_SCRIPT_HOST` **only in unwind builds**; release
    /// artifacts set `panic = "abort"`, so capabilities must be panic-free and
    /// report failures through `Result` (see the README host contract).
    fn send_message(
        &self,
        channel: &ScriptChannel,
        method: &str,
        payload: &JsonValue,
        limits: &SandboxLimits,
    ) -> Result<JsonValue, ScriptError> {
        dispatch(self, channel, method, payload, limits)
    }

    /// `host.network.get` / `host.network.post` (status + decoded body).
    fn http(
        &self,
        _channel: &ScriptChannel,
        _request: HttpRequest,
    ) -> Result<HttpResponse, ScriptError> {
        Err(not_implemented())
    }

    /// `host.database.getAppsByChannel()`, forced to `channel`.
    fn db_get_apps(
        &self,
        _channel: &ScriptChannel,
        _request: DatabaseAppsRequest,
    ) -> Result<Vec<ChannelApp>, ScriptError> {
        Err(not_implemented())
    }

    /// `host.database.getApp(appId)`, forced to `channel`.
    fn db_get_app(
        &self,
        _channel: &ScriptChannel,
        _request: DatabaseAppRequest,
    ) -> Result<Option<ChannelApp>, ScriptError> {
        Err(not_implemented())
    }

    /// `host.database.insertApps(apps)`, forced to `channel`; returns the count.
    fn db_insert_apps(
        &self,
        _channel: &ScriptChannel,
        _request: DatabaseInsertRequest,
    ) -> Result<usize, ScriptError> {
        Err(not_implemented())
    }

    /// `host.config.get(key)`; `JsonValue::Null` means "no such key".
    fn config_get(
        &self,
        _channel: &ScriptChannel,
        _request: ConfigGetRequest,
    ) -> Result<JsonValue, ScriptError> {
        Err(not_implemented())
    }

    /// `host.env.get(name)`, channel-scoped read-only snapshot.
    fn env_get(
        &self,
        _channel: &ScriptChannel,
        _request: EnvGetRequest,
    ) -> Result<Option<String>, ScriptError> {
        Err(not_implemented())
    }

    /// `host.env.all()`, channel-scoped snapshot.
    fn env_all(
        &self,
        _channel: &ScriptChannel,
        _request: EnvAllRequest,
    ) -> Result<EnvSnapshot, ScriptError> {
        Err(not_implemented())
    }

    /// `host.env.has(name)`, channel-scoped snapshot.
    fn env_has(
        &self,
        _channel: &ScriptChannel,
        _request: EnvHasRequest,
    ) -> Result<bool, ScriptError> {
        Err(not_implemented())
    }

    /// `host.utils.checkVersion(packageName)`; the empty name is handled by the
    /// dispatcher and never reaches the host.
    fn check_version(
        &self,
        _channel: &ScriptChannel,
        _request: CheckVersionRequest,
    ) -> Result<InstalledInfo, ScriptError> {
        Err(not_implemented())
    }

    /// `host.log.info` / `host.log.error`. The message goes to the host.
    fn log(&self, _channel: &ScriptChannel, _request: LogRequest) -> Result<(), ScriptError> {
        Err(not_implemented())
    }

    /// `host.native.call` (`host.ui/core/alert.call`). `None` means the
    /// `ns.method` handler is not registered.
    fn native_call(
        &self,
        _channel: &ScriptChannel,
        _request: NativeCallRequest,
    ) -> Result<Option<JsonValue>, ScriptError> {
        Err(not_implemented())
    }

    /// `script.ui_request` (Todo 5 UI round-trip).
    fn ui_request(
        &self,
        _channel: &ScriptChannel,
        _request: UiRequest,
    ) -> Result<JsonValue, ScriptError> {
        Err(not_implemented())
    }
}

fn not_implemented() -> ScriptError {
    ScriptError::host("not implemented")
}

/// Default dispatcher: JS method string -> capability -> Dart-shaped envelope.
fn dispatch<H: ScriptHost + ?Sized>(
    host: &H,
    channel: &ScriptChannel,
    method: &str,
    payload: &JsonValue,
    limits: &SandboxLimits,
) -> Result<JsonValue, ScriptError> {
    match method {
        "host.network.get" => {
            let request = HttpRequest::parse(HttpMethod::Get, payload, limits.max_redirects);
            Ok(http_envelope(host.http(channel, request)?))
        }
        "host.network.post" => {
            let request = HttpRequest::parse(HttpMethod::Post, payload, limits.max_redirects);
            Ok(http_envelope(host.http(channel, request)?))
        }
        "host.database.getAppsByChannel" => {
            let apps = host.db_get_apps(channel, DatabaseAppsRequest)?;
            let data: Vec<JsonValue> = apps
                .into_iter()
                .map(|app| app.with_channel(channel).to_json())
                .collect();
            Ok(ok_data(JsonValue::Array(data)))
        }
        "host.database.getApp" => {
            let request = DatabaseAppRequest::parse(payload);
            let data = host
                .db_get_app(channel, request)?
                .map(|app| app.with_channel(channel).to_json())
                .unwrap_or(JsonValue::Null);
            Ok(ok_data(data))
        }
        "host.database.insertApps" => {
            let request = DatabaseInsertRequest::parse(payload);
            Ok(ok_data(json!(host.db_insert_apps(channel, request)?)))
        }
        "host.config.get" => {
            let request = ConfigGetRequest::parse(payload);
            Ok(ok_data(host.config_get(channel, request)?))
        }
        "host.env.get" => {
            let request = EnvGetRequest::parse(payload);
            Ok(ok_data(json!(host.env_get(channel, request)?)))
        }
        "host.env.all" => Ok(ok_data(json!(host.env_all(channel, EnvAllRequest)?))),
        "host.env.has" => {
            let request = EnvHasRequest::parse(payload);
            Ok(ok_data(json!(host.env_has(channel, request)?)))
        }
        "host.utils.checkVersion" => {
            let request = CheckVersionRequest::parse(payload);
            let data = if request.package_name.is_empty() {
                InstalledInfo::not_installed()
            } else {
                host.check_version(channel, request)?
            };
            Ok(ok_data(data.to_json()))
        }
        "host.log.info" => {
            let request = LogRequest::parse(LogLevel::Info, payload);
            host.log(channel, request)?;
            Ok(json!({ "ok": true }))
        }
        "host.log.error" => {
            let request = LogRequest::parse(LogLevel::Error, payload);
            host.log(channel, request)?;
            Ok(json!({ "ok": true }))
        }
        "host.native.call" => {
            let request = NativeCallRequest::parse(payload);
            let namespace = request.namespace.clone();
            let name = request.method.clone();
            match host.native_call(channel, request)? {
                Some(data) => Ok(ok_data(data)),
                None => Ok(json!({
                    "ok": false,
                    "error": format!("host.native.{namespace}.{name} 未注册"),
                })),
            }
        }
        "script.ui_request" | "host.ui.request" => {
            let request = UiRequest::parse(payload);
            Ok(ok_data(host.ui_request(channel, request)?))
        }
        // Legacy default: an unknown `host.utils.<method>` is an envelope, not
        // a thrown error, and names the missing method exactly like natives do.
        other if other.starts_with("host.utils.") => Ok(json!({
            "ok": false,
            "error": format!("{other} 未注册"),
        })),
        other => Err(ScriptError::host(format!(
            "unsupported host method `{other}`"
        ))),
    }
}

fn ok_data(data: JsonValue) -> JsonValue {
    json!({ "ok": true, "data": data })
}

/// Dart `_wrapResponse`: non-2xx keeps its body and gains `error:"HTTP <status>"`.
fn http_envelope(response: HttpResponse) -> JsonValue {
    let ok = (200..300).contains(&response.status);
    let mut envelope = json!({
        "ok": ok,
        "status": response.status,
        "data": response.data,
    });
    if !ok {
        envelope["error"] = json!(format!("HTTP {}", response.status));
    }
    envelope
}

/// Host implementation used when no capabilities are registered.
#[derive(Debug, Default, Clone, Copy)]
pub struct UnsupportedHost;

impl ScriptHost for UnsupportedHost {}
