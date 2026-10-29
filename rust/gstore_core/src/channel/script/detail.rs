//! Page-scoped detail script dispatcher (Dart `JsDetailChannel`).
//!
//! A detail instance owns its own QuickJS runtime, so detail-page state is
//! isolated from the entry channel and from other apps. Param maps mirror Dart
//! `js_detail_channel.dart` exactly; optional keys are omitted when absent.

use std::sync::Mutex;

use gstore_script::ScriptRuntime;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value as JsonValue};

use crate::dto::{AppDetail, ChannelKey};
use crate::error::Error;

use super::config::ScriptDetailConfig;
use super::convert;
use super::dispatch;

/// Query for `versionOptions`.
pub struct VersionOptionsQuery<'a> {
    /// Channel-scoped app id.
    pub app_id: &'a str,
    /// Optional environment filter.
    pub env: Option<&'a str>,
    /// Optional version filter (omitted from the script params when `None`).
    pub version: Option<&'a str>,
}

/// Query for `switchVersion`.
pub struct SwitchVersionQuery<'a> {
    /// Channel-scoped app id.
    pub app_id: &'a str,
    /// Target environment.
    pub env: &'a str,
    /// Target version.
    pub version: &'a str,
    /// Optional historical build selector `{num, ipaName}`.
    pub build: Option<&'a Map<String, JsonValue>>,
}

/// Query for `buildHistory`.
pub struct BuildHistoryQuery<'a> {
    /// Channel-scoped app id.
    pub app_id: &'a str,
    /// Target environment.
    pub env: &'a str,
    /// Target version.
    pub version: &'a str,
}

/// One entry of the script's `detailMenu` result.
///
/// Field names match what Dart `_refreshActions` reads:
/// `action`, `jscall`, `icon`, `clickIsDimiss`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DetailAction {
    /// Display label (Dart falls back to `jscall`, then `未知动作`).
    #[serde(default)]
    pub action: String,
    /// Script method invoked when the action is tapped.
    #[serde(default)]
    pub jscall: String,
    /// Icon name; Dart currently uses a default icon.
    #[serde(default)]
    pub icon: Option<String>,
    /// Whether tapping dismisses the "more" panel.
    #[serde(default, rename = "clickIsDimiss")]
    pub click_is_dimiss: Option<bool>,
}

impl DetailAction {
    /// Dart's label resolution: `action`, then `jscall`, then `未知动作`.
    pub fn label(&self) -> &str {
        if !self.action.is_empty() {
            &self.action
        } else if !self.jscall.is_empty() {
            &self.jscall
        } else {
            "未知动作"
        }
    }

    fn from_value(value: &JsonValue) -> Self {
        let Some(map) = value.as_object() else {
            return Self {
                action: String::new(),
                jscall: String::new(),
                icon: None,
                click_is_dimiss: None,
            };
        };
        Self {
            action: text(map, "action").unwrap_or_default(),
            jscall: text(map, "jscall").unwrap_or_default(),
            icon: text(map, "icon"),
            click_is_dimiss: map.get("clickIsDimiss").and_then(JsonValue::as_bool),
        }
    }
}

/// Page-level script runtime bound to one channel key.
pub struct ScriptDetail {
    key: ChannelKey,
    runtime: Mutex<Option<ScriptRuntime>>,
}

impl ScriptDetail {
    /// Spawns a dedicated runtime and loads the detail script once.
    pub fn new(config: ScriptDetailConfig) -> Result<Self, Error> {
        config.validate()?;
        let ScriptDetailConfig {
            key,
            script,
            host,
            pack_key: _,
        } = config;
        let runtime = dispatch::spawn(&key, &script, host)?;
        Ok(Self {
            key,
            runtime: Mutex::new(Some(runtime)),
        })
    }

    /// Channel key bound at construction.
    pub fn key(&self) -> &ChannelKey {
        &self.key
    }

    /// Invokes `main(method, params)` with the same envelope rules as the entry
    /// channel: `null`, `{ok:false}` and a JS throw all degrade to `None`.
    pub fn call_main(
        &self,
        method: &str,
        params: &Map<String, JsonValue>,
    ) -> dispatch::MainOutcome {
        let guard = dispatch::lock_runtime(&self.runtime)?;
        let runtime = guard
            .as_ref()
            .ok_or_else(|| Error::Internal("script detail runtime is disposed".to_string()))?;
        dispatch::call_main(runtime, method, params)
    }

    /// `versionOptions({appId, env?, version?})`.
    pub fn version_options(
        &self,
        query: VersionOptionsQuery<'_>,
    ) -> Result<Option<JsonValue>, Error> {
        let mut params = Map::new();
        params.insert(
            "appId".to_string(),
            JsonValue::String(query.app_id.to_owned()),
        );
        if let Some(env) = query.env {
            params.insert("env".to_string(), JsonValue::String(env.to_owned()));
        }
        if let Some(version) = query.version {
            params.insert("version".to_string(), JsonValue::String(version.to_owned()));
        }
        self.call_main("versionOptions", &params)
    }

    /// `switchVersion({appId, env, version, build?})`.
    pub fn switch_version(
        &self,
        query: SwitchVersionQuery<'_>,
    ) -> Result<Option<JsonValue>, Error> {
        let mut params = Map::new();
        params.insert(
            "appId".to_string(),
            JsonValue::String(query.app_id.to_owned()),
        );
        params.insert("env".to_string(), JsonValue::String(query.env.to_owned()));
        params.insert(
            "version".to_string(),
            JsonValue::String(query.version.to_owned()),
        );
        if let Some(build) = query.build {
            params.insert("build".to_string(), JsonValue::Object(build.clone()));
        }
        self.call_main("switchVersion", &params)
    }

    /// `switchVersion` mapped to the typed [`AppDetail`] the driver returns.
    ///
    /// A pack's `switchVersion` reply has the same shape as `getAppDetail`, so
    /// the conversion lives once in [`convert::detail`]. A JSON `null` result
    /// (unimplemented method / `{ok:false}` / a JS throw) and a non-object
    /// payload both degrade to `Ok(None)`, matching Dart's `decoded is! Map`
    /// check, so the caller preserves the existing null-degradation.
    pub fn switch_version_detail(
        &self,
        query: SwitchVersionQuery<'_>,
    ) -> Result<Option<AppDetail>, Error> {
        match self.switch_version(query)? {
            Some(value) if value.is_object() => convert::detail(&value).map(Some),
            _ => Ok(None),
        }
    }

    /// `buildHistory({appId, version, env})`.
    pub fn build_history(&self, query: BuildHistoryQuery<'_>) -> Result<Option<JsonValue>, Error> {
        let params = dispatch::params(&[
            ("appId", JsonValue::String(query.app_id.to_owned())),
            ("version", JsonValue::String(query.version.to_owned())),
            ("env", JsonValue::String(query.env.to_owned())),
        ]);
        self.call_main("buildHistory", &params)
    }

    /// `detailMenu(appId)`; a missing/non-list result degrades to an empty menu.
    pub fn detail_menu(&self, app_id: &str) -> Result<Vec<DetailAction>, Error> {
        let params = dispatch::params(&[("appId", JsonValue::String(app_id.to_owned()))]);
        Ok(match self.call_main("detailMenu", &params)? {
            Some(JsonValue::Array(items)) => items.iter().map(DetailAction::from_value).collect(),
            _ => Vec::new(),
        })
    }

    /// Releases the runtime; safe to call repeatedly.
    pub fn dispose(&self) -> Result<(), Error> {
        dispatch::dispose_runtime(&self.runtime)
    }
}

fn text(map: &Map<String, JsonValue>, key: &str) -> Option<String> {
    map.get(key).and_then(JsonValue::as_str).map(str::to_owned)
}
