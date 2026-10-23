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
use super::store::{self, ScriptChannelStore, StoreSlot};
use super::{convert, dispatch, meta};

const MISSING_DETAIL: &str = "脚本未返回详情数据（脚本未实现或数据获取失败）";
const MISSING_UPDATE: &str = "脚本未返回更新信息且渠道库无该应用";
const MISSING_UPDATE_DATA: &str = "脚本未返回更新数据（脚本未实现或数据获取失败）";
const MISSING_CONFIG: &str = "脚本未返回配置数据（脚本未实现或数据获取失败）";
const MISSING_SEARCH: &str = "脚本未实现 searchApps 和 getAllApps";

/// Script-backed [`ChannelDriver`]; one QuickJS runtime per channel.
pub struct ScriptChannel {
    key: ChannelKey,
    meta: ChannelMeta,
    icon: Option<String>,
    store: Option<Arc<dyn ScriptChannelStore>>,
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
            store,
            pack_key: _,
        } = config;
        let runtime = dispatch::spawn(&key, &script, host)?;
        let script_meta = meta::read(&runtime);
        let meta = meta::build_meta(&key, &script_meta);
        Ok(Self {
            key,
            meta,
            icon: script_meta.icon,
            store,
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

    fn store_slot(&self) -> StoreSlot<'_> {
        self.store.as_ref()
    }

    fn saved_app(&self, app_id: &str) -> Result<Option<AppSummary>, Error> {
        store::get(self.store_slot(), &self.key, app_id)
    }

    fn missing_app(&self, app_id: &str) -> Error {
        Error::NotFound(format!(
            "script channel `{}` returned no app `{app_id}` and has no saved row",
            self.key
        ))
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

    fn get_all_apps(&self, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        store::list(self.store_slot(), &self.key)
    }

    fn get_app_info(&self, app_id: &str, force_refresh: bool) -> Result<AppSummary, Error> {
        if !force_refresh {
            if let Some(app) = self.saved_app(app_id)? {
                return Ok(app);
            }
        }
        let params = dispatch::params(&[("appId", JsonValue::String(app_id.to_owned()))]);
        if let Some(data) = self.call("getAppInfo", &params)? {
            if data.is_object() {
                if let Some(app) = convert::summary(&data, &self.key)? {
                    return Ok(app);
                }
            }
        }
        self.saved_app(app_id)?
            .ok_or_else(|| self.missing_app(app_id))
    }

    fn get_app_detail(&self, app_id: &str, _force_refresh: bool) -> Result<AppDetail, Error> {
        let params = dispatch::params(&[("appId", JsonValue::String(app_id.to_owned()))]);
        match self.call("getAppDetail", &params)? {
            Some(data) if data.is_object() => convert::detail(&data),
            _ => Err(Error::NotFound(MISSING_DETAIL.to_string())),
        }
    }

    fn check_app_update(&self, app_id: &str) -> Result<AppUpdate, Error> {
        let params = dispatch::params(&[("appId", JsonValue::String(app_id.to_owned()))]);
        if let Some(data) = self.call("checkAppUpdate", &params)? {
            if data.is_object() {
                return convert::update(&data, app_id);
            }
        }
        match self.saved_app(app_id)? {
            Some(app) => Ok(convert::update_from_summary(&app)),
            None => Err(Error::NotFound(MISSING_UPDATE.to_string())),
        }
    }

    fn search_apps(&self, keyword: &str, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        let params = dispatch::params(&[("keyword", JsonValue::String(keyword.to_owned()))]);
        if let Some(data) = self.call("searchApps", &params)? {
            if let Some(apps) = convert::apps_opt(&data, &self.key) {
                return Ok(apps);
            }
        }
        let all = self.call("getAllApps", &Map::new())?;
        let apps = all
            .as_ref()
            .and_then(|data| convert::apps_opt(data, &self.key))
            .ok_or_else(|| Error::NotFound(MISSING_SEARCH.to_string()))?;
        let needle = keyword.to_lowercase();
        Ok(apps
            .into_iter()
            .filter(|app| matches_keyword(app, &needle))
            .collect())
    }

    fn check_update(&self) -> Result<bool, Error> {
        match self.call("checkUpdate", &Map::new())? {
            Some(JsonValue::Bool(available)) => Ok(available),
            _ => Ok(false),
        }
    }

    fn do_update(&self, progress: Option<&mut dyn FnMut(u64, u64)>) -> Result<bool, Error> {
        if let Some(JsonValue::Bool(updated)) = self.call("doUpdate", &Map::new())? {
            return Ok(updated);
        }
        let all = self.call("getAllApps", &Map::new())?;
        let apps = all
            .as_ref()
            .and_then(|data| convert::apps_opt(data, &self.key))
            .ok_or_else(|| Error::NotFound(MISSING_UPDATE_DATA.to_string()))?;
        let total = apps.len() as u64;
        store::insert(self.store_slot(), &self.key, &apps)?;
        if let Some(progress) = progress {
            progress(total, total);
        }
        Ok(true)
    }

    fn get_config(&self, _force_refresh: bool) -> Result<Option<ChannelConfig>, Error> {
        match self.call("getConfig", &Map::new())? {
            Some(data) if data.is_object() => Ok(Some(convert::config(&data)?)),
            _ => Err(Error::NotFound(MISSING_CONFIG.to_string())),
        }
    }

    fn add_app(&self, app: &AppSummary) -> Result<(), Error> {
        store::insert(self.store_slot(), &self.key, std::slice::from_ref(app))
    }

    fn remove_app(&self, app_id: &str) -> Result<(), Error> {
        store::remove(self.store_slot(), &self.key, app_id)
    }

    fn search_by_category(
        &self,
        _category_id: &str,
        _force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error> {
        Ok(Vec::new())
    }

    fn get_all_categories(&self, _force_refresh: bool) -> Result<Vec<ChannelCategory>, Error> {
        Ok(Vec::new())
    }

    fn clear_cache(&self) -> Result<(), Error> {
        Ok(())
    }

    fn get_cache_size(&self) -> Result<u64, Error> {
        Ok(0)
    }

    fn dispose(&self) -> Result<(), Error> {
        dispatch::dispose_runtime(&self.runtime)?;
        self.initialized.store(false, Ordering::SeqCst);
        Ok(())
    }
}

fn matches_keyword(app: &AppSummary, needle: &str) -> bool {
    app.name.to_lowercase().contains(needle)
        || app.des.to_lowercase().contains(needle)
        || app.app_id.to_lowercase().contains(needle)
}
