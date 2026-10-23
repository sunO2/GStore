//! Typed request/response values for the [`ScriptHost`](super::ScriptHost)
//! capabilities.
//!
//! The default `send_message` dispatcher parses each JS payload into one of
//! these structs, so a host implementation never has to interpret raw JSON for
//! the envelope contract. Opaque, script-defined parts (`opts`, native payloads,
//! app rows) are carried as [`JsonValue`] on purpose.

use std::collections::BTreeMap;

use serde_json::{json, Map, Value as JsonValue};

use super::channel::ScriptChannel;

/// HTTP verb requested by `host.network.get` / `host.network.post`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
}

/// One `host.network.*` call. `opts` is kept exactly as the script produced it
/// (`{params, headers, body|json}`), mirroring the Dart prefix byte-for-byte.
///
/// `max_redirects` is added by the bridge, not by the script: the effective
/// value is `min(script request, runtime policy)` and the runtime policy can
/// never exceed [`DEFAULT_MAX_REDIRECTS`](super::DEFAULT_MAX_REDIRECTS). The
/// host transport owns actual redirect following; this field is the contract.
#[derive(Debug, Clone, PartialEq)]
pub struct HttpRequest {
    pub method: HttpMethod,
    pub url: String,
    pub opts: JsonValue,
    pub max_redirects: u32,
}

impl HttpRequest {
    pub(crate) fn parse(method: HttpMethod, payload: &JsonValue, policy_max: u32) -> Self {
        let opts = object_field(payload, "opts");
        // A script may tighten the hop count, never raise it.
        let requested = opts
            .get("maxRedirects")
            .or_else(|| opts.get("max_redirects"))
            .and_then(JsonValue::as_u64)
            .and_then(|value| u32::try_from(value).ok())
            .unwrap_or(policy_max);
        Self {
            method,
            url: string_field(payload, "url"),
            opts,
            max_redirects: requested
                .min(policy_max)
                .min(super::limits::DEFAULT_MAX_REDIRECTS),
        }
    }
}

/// Result of a network call. The bridge owns the envelope; the host reports the
/// status plus the already-decoded body (Dart `_wrapResponse` equivalent).
#[derive(Debug, Clone, PartialEq)]
pub struct HttpResponse {
    pub status: u16,
    pub data: JsonValue,
}

impl HttpResponse {
    pub fn new(status: u16, data: JsonValue) -> Self {
        Self { status, data }
    }
}

/// `host.database.getAppsByChannel()` (no arguments).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DatabaseAppsRequest;

/// `host.database.getApp(appId)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DatabaseAppRequest {
    pub app_id: String,
}

impl DatabaseAppRequest {
    pub(crate) fn parse(payload: &JsonValue) -> Self {
        Self {
            app_id: string_field(payload, "appId"),
        }
    }
}

/// `host.database.insertApps(apps)`.
///
/// Every row has already had any script-supplied `channelCode` removed; the
/// runtime channel is the only write authority.
#[derive(Debug, Clone, PartialEq)]
pub struct DatabaseInsertRequest {
    pub apps: Vec<JsonValue>,
}

impl DatabaseInsertRequest {
    pub(crate) fn parse(payload: &JsonValue) -> Self {
        let apps = payload
            .get("apps")
            .and_then(JsonValue::as_array)
            .map(|rows| rows.iter().cloned().map(strip_channel_code).collect())
            .unwrap_or_default();
        Self { apps }
    }
}

fn strip_channel_code(mut app: JsonValue) -> JsonValue {
    if let Some(object) = app.as_object_mut() {
        object.remove("channelCode");
    }
    app
}

/// One channel app exactly as Dart's `_channelAppToJson` renders it.
///
/// The field set (including the always-present nullable keys) is part of the
/// script contract, so `to_json` is the single place that decides it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChannelApp {
    pub app_id: String,
    pub name: String,
    pub user: String,
    pub repositories: String,
    pub apprepo: Option<String>,
    pub icon: String,
    pub description: String,
    pub category: Option<String>,
    pub add_time: i64,
    pub channel_code: String,
    pub extra: Option<JsonValue>,
}

impl ChannelApp {
    /// Render the Dart-compatible app JSON (same keys, nulls preserved).
    pub fn to_json(&self) -> JsonValue {
        json!({
            "appId": self.app_id,
            "name": self.name,
            "user": self.user,
            "repositories": self.repositories,
            "apprepo": self.apprepo,
            "icon": self.icon,
            "description": self.description,
            "category": self.category,
            "addTime": self.add_time,
            "channelCode": self.channel_code,
            "extra": self.extra,
        })
    }

    /// Force the owning channel (reads are pinned to the runtime channel).
    pub fn with_channel(mut self, channel: &ScriptChannel) -> Self {
        self.channel_code = channel.as_str().to_owned();
        self
    }
}

/// `host.config.get(key)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigGetRequest {
    pub key: String,
}

impl ConfigGetRequest {
    pub(crate) fn parse(payload: &JsonValue) -> Self {
        Self {
            key: string_field(payload, "key"),
        }
    }
}

/// `host.env.get(name)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvGetRequest {
    pub name: String,
}

impl EnvGetRequest {
    pub(crate) fn parse(payload: &JsonValue) -> Self {
        Self {
            name: string_field(payload, "name"),
        }
    }
}

/// `host.env.all()` (no arguments).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EnvAllRequest;

/// `host.env.has(name)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvHasRequest {
    pub name: String,
}

impl EnvHasRequest {
    pub(crate) fn parse(payload: &JsonValue) -> Self {
        Self {
            name: string_field(payload, "name"),
        }
    }
}

/// `host.utils.checkVersion(packageName)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckVersionRequest {
    pub package_name: String,
}

impl CheckVersionRequest {
    pub(crate) fn parse(payload: &JsonValue) -> Self {
        Self {
            package_name: string_field(payload, "packageName"),
        }
    }
}

/// `{installed, version, versionCode, name}` as returned by Dart's reader.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledInfo {
    pub installed: bool,
    pub version: Option<String>,
    pub version_code: Option<i64>,
    pub name: Option<String>,
}

impl InstalledInfo {
    pub fn not_installed() -> Self {
        Self {
            installed: false,
            version: None,
            version_code: None,
            name: None,
        }
    }

    pub fn installed(
        version: Option<String>,
        version_code: Option<i64>,
        name: Option<String>,
    ) -> Self {
        Self {
            installed: true,
            version,
            version_code,
            name,
        }
    }

    /// Dart emits only `{installed:false}` when the app is absent.
    pub fn to_json(&self) -> JsonValue {
        if !self.installed {
            return json!({ "installed": false });
        }
        json!({
            "installed": true,
            "version": self.version,
            "versionCode": self.version_code,
            "name": self.name,
        })
    }
}

/// `host.log.info` / `host.log.error`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogLevel {
    Info,
    Error,
}

/// One log line. The message goes to the host, never back into the envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogRequest {
    pub level: LogLevel,
    pub message: String,
}

impl LogRequest {
    pub(crate) fn parse(level: LogLevel, payload: &JsonValue) -> Self {
        Self {
            level,
            message: string_field(payload, "msg"),
        }
    }
}

/// `host.native.call` routed from `host.ui/core/alert.call`.
#[derive(Debug, Clone, PartialEq)]
pub struct NativeCallRequest {
    pub namespace: String,
    pub method: String,
    pub payload: JsonValue,
}

impl NativeCallRequest {
    pub(crate) fn parse(payload: &JsonValue) -> Self {
        Self {
            namespace: string_field(payload, "ns"),
            method: string_field(payload, "method"),
            payload: match payload.get("payload") {
                Some(value) if !value.is_null() => value.clone(),
                _ => payload.clone(),
            },
        }
    }
}

/// `script.ui_request` / `host.ui.request` (Todo 5 round-trip).
#[derive(Debug, Clone, PartialEq)]
pub struct UiRequest {
    pub method: String,
    pub payload: JsonValue,
}

impl UiRequest {
    pub(crate) fn parse(payload: &JsonValue) -> Self {
        Self {
            method: string_field(payload, "method"),
            payload: match payload.get("payload") {
                Some(value) if !value.is_null() => value.clone(),
                _ => payload.clone(),
            },
        }
    }
}

/// Dart `_asMap(x)[key]?.toString() ?? ''` for scalar values.
pub(crate) fn string_field(payload: &JsonValue, key: &str) -> String {
    match payload.get(key) {
        Some(JsonValue::String(value)) => value.clone(),
        Some(JsonValue::Number(value)) => value.to_string(),
        Some(JsonValue::Bool(value)) => value.to_string(),
        _ => String::new(),
    }
}

/// Dart `_asMap(x)[key]` defaulting to `{}` (non-objects are ignored).
pub(crate) fn object_field(payload: &JsonValue, key: &str) -> JsonValue {
    payload
        .get(key)
        .filter(|value| value.is_object())
        .cloned()
        .unwrap_or_else(|| JsonValue::Object(Map::new()))
}

/// Channel-scoped env snapshot (`BTreeMap` keeps output stable).
pub type EnvSnapshot = BTreeMap<String, String>;
