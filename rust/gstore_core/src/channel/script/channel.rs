//! The in-crate `ChannelDriver` implementation backed by one script runtime.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use gstore_script::ScriptRuntime;
use serde_json::{Map, Value as JsonValue};

use crate::channel::driver::{ChannelCategory, ChannelConfig, ChannelDriver};
use crate::channel::sealed;
use crate::dto::{AppDetail, AppSummary, AppUpdate, ChannelKey, ChannelMeta};
use crate::error::Error;

use super::config::ScriptChannelConfig;
use super::convert;
use super::dispatch;
use super::meta;

/// Script-backed [`ChannelDriver`]; one QuickJS runtime per channel.
pub struct ScriptChannel {
    key: ChannelKey,
    meta: ChannelMeta,
    icon: Option<String>,
    fallback: Option<Arc<dyn ChannelDriver>>,
    runtime: Mutex<Option<ScriptRuntime>>,
    initialized: AtomicBool,
}

impl sealed::Sealed for ScriptChannel {}

impl ScriptChannel {
    /// Spawns the channel runtime, loads the entry script, and reads
    /// `CHANNEL_META` once.
    pub fn new(config: ScriptChannelConfig) -> Result<Self, Error> {
        config.validate()?;
        let ScriptChannelConfig {
            key,
            script,
            host,
            fallback,
            pack_key: _,
        } = config;
        let runtime = dispatch::spawn(&key, &script, host)?;
        let script_meta = meta::read(&runtime);
        let meta = meta::build_meta(&key, &script_meta);
        Ok(Self {
            key,
            meta,
            icon: script_meta.icon,
            fallback,
            runtime: Mutex::new(Some(runtime)),
            initialized: AtomicBool::new(true),
        })
    }

    /// Script-advertised `CHANNEL_META.icon`, if any (not part of `ChannelMeta`).
    pub fn script_icon(&self) -> Option<&str> {
        self.icon.as_deref()
    }

    fn call(&self, method: &str, params: &Map<String, JsonValue>) -> dispatch::MainOutcome {
        let guard = dispatch::lock_runtime(&self.runtime)?;
        let runtime = guard
            .as_ref()
            .ok_or_else(|| Error::Internal("script channel runtime is disposed".to_string()))?;
        dispatch::call_main(runtime, method, params)
    }

    fn fallback(&self) -> Option<&dyn ChannelDriver> {
        self.fallback.as_deref()
    }
}

impl ChannelDriver for ScriptChannel {
    fn key(&self) -> &ChannelKey {
        &self.key
    }

    fn meta(&self) -> &ChannelMeta {
        &self.meta
    }

    fn initialize(&self) -> Result<(), Error> {
        let guard = dispatch::lock_runtime(&self.runtime)?;
        if guard.is_none() {
            return Err(Error::Internal(
                "script channel runtime is disposed".to_string(),
            ));
        }
        self.initialized.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn is_initialized(&self) -> Result<bool, Error> {
        Ok(self.initialized.load(Ordering::SeqCst))
    }

    fn check_available(&self) -> Result<bool, Error> {
        self.is_initialized()
    }

    fn get_all_apps(&self, force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        let call = self.call(
            "getAllApps",
            &dispatch::params(&[("forceRefresh", JsonValue::Bool(force_refresh))]),
        )?;
        match call {
            Some(data) => convert::apps(&data, &self.key),
            None => match self.fallback() {
                Some(fallback) => fallback.get_all_apps(force_refresh),
                None => Err(Error::NotFound(format!(
                    "script channel `{}` returned no app list and has no fallback",
                    self.key
                ))),
            },
        }
    }

    fn get_app_info(&self, app_id: &str, force_refresh: bool) -> Result<AppSummary, Error> {
        let call = self.call(
            "getAppInfo",
            &dispatch::params(&[("appId", JsonValue::String(app_id.to_owned()))]),
        )?;
        match call {
            Some(data) => match convert::summary(&data, &self.key)? {
                Some(app) => Ok(app),
                None => self.missing_app_info(app_id, force_refresh),
            },
            None => self.missing_app_info(app_id, force_refresh),
        }
    }

    fn get_app_detail(&self, app_id: &str, force_refresh: bool) -> Result<AppDetail, Error> {
        let call = self.call(
            "getAppDetail",
            &dispatch::params(&[("appId", JsonValue::String(app_id.to_owned()))]),
        )?;
        match call {
            Some(data) => convert::detail(&data),
            None => match self.fallback() {
                Some(fallback) => fallback.get_app_detail(app_id, force_refresh),
                None => Err(Error::NotFound(format!(
                    "script channel `{}` returned no detail for `{app_id}` and has no fallback",
                    self.key
                ))),
            },
        }
    }

    fn check_app_update(&self, app_id: &str) -> Result<AppUpdate, Error> {
        let call = self.call(
            "checkAppUpdate",
            &dispatch::params(&[("appId", JsonValue::String(app_id.to_owned()))]),
        )?;
        match call {
            Some(data) => convert::update(&data, app_id),
            None => match self.fallback() {
                Some(fallback) => fallback.check_app_update(app_id),
                None => Err(Error::NotFound(format!(
                    "script channel `{}` returned no update for `{app_id}` and has no fallback",
                    self.key
                ))),
            },
        }
    }

    fn search_apps(&self, keyword: &str, force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        let call = self.call(
            "searchApps",
            &dispatch::params(&[("keyword", JsonValue::String(keyword.to_owned()))]),
        )?;
        match call {
            Some(data) => convert::apps(&data, &self.key),
            None => match self.fallback() {
                Some(fallback) => fallback.search_apps(keyword, force_refresh),
                None => Err(Error::NotFound(format!(
                    "script channel `{}` returned no search result and has no fallback",
                    self.key
                ))),
            },
        }
    }

    fn check_update(&self) -> Result<bool, Error> {
        match self.call("checkUpdate", &Map::new())? {
            Some(JsonValue::Bool(available)) => Ok(available),
            Some(other) => Err(Error::Serialization(format!(
                "script `checkUpdate` must return a boolean, got {other}"
            ))),
            None => match self.fallback() {
                Some(fallback) => fallback.check_update(),
                None => Ok(false),
            },
        }
    }

    fn do_update(&self, progress: Option<&mut dyn FnMut(u64, u64)>) -> Result<bool, Error> {
        match self.call("doUpdate", &Map::new())? {
            Some(JsonValue::Bool(updated)) => Ok(updated),
            Some(other) => Err(Error::Serialization(format!(
                "script `doUpdate` must return a boolean, got {other}"
            ))),
            // Dart's fallback pulls the full list and persists it. Core has no
            // repository here, so it delegates to the injected same-key driver
            // and NEVER deletes or purges existing data.
            None => match self.fallback() {
                Some(fallback) => fallback.do_update(progress),
                None => Ok(false),
            },
        }
    }

    fn get_config(&self, force_refresh: bool) -> Result<Option<ChannelConfig>, Error> {
        match self.call("getConfig", &Map::new())? {
            Some(data) => Ok(Some(convert::config(&data)?)),
            None => match self.fallback() {
                Some(fallback) => fallback.get_config(force_refresh),
                None => Err(Error::Unsupported(format!(
                    "script channel `{}` returned no configuration",
                    self.key
                ))),
            },
        }
    }

    fn add_app(&self, app: &AppSummary) -> Result<(), Error> {
        let _ = app;
        Err(Error::Unsupported(
            "script channel addApp is persisted by the host, not by core".to_string(),
        ))
    }

    fn remove_app(&self, app_id: &str) -> Result<(), Error> {
        let _ = app_id;
        Err(Error::Unsupported(
            "script channel removeApp is persisted by the host, not by core".to_string(),
        ))
    }

    fn search_by_category(
        &self,
        category_id: &str,
        force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error> {
        let _ = (category_id, force_refresh);
        Err(Error::Unsupported(
            "script channel does not support category search".to_string(),
        ))
    }

    fn get_all_categories(&self, force_refresh: bool) -> Result<Vec<ChannelCategory>, Error> {
        let _ = force_refresh;
        Err(Error::Unsupported(
            "script channel does not expose categories".to_string(),
        ))
    }

    fn clear_cache(&self) -> Result<(), Error> {
        Err(Error::Unsupported(
            "script channel has no cache to clear".to_string(),
        ))
    }

    fn get_cache_size(&self) -> Result<u64, Error> {
        Err(Error::Unsupported(
            "script channel has no cache size".to_string(),
        ))
    }

    fn dispose(&self) -> Result<(), Error> {
        dispatch::dispose_runtime(&self.runtime)?;
        self.initialized.store(false, Ordering::SeqCst);
        Ok(())
    }
}

impl ScriptChannel {
    fn missing_app_info(&self, app_id: &str, force_refresh: bool) -> Result<AppSummary, Error> {
        match self.fallback() {
            Some(fallback) => fallback.get_app_info(app_id, force_refresh),
            None => Err(Error::NotFound(format!(
                "script channel `{}` returned no app `{app_id}` and has no fallback",
                self.key
            ))),
        }
    }
}
