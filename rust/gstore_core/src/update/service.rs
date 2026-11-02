//! Update checks over the V2 `update_state` / `update_log` tables.
//!
//! This is the Rust half of Dart's `UpdateManagerService` + `UpdateCache`:
//! exact version comparison, per-app update checks, the one-hour result cache,
//! ABI-aware download selection, preferred-APK matching, and the
//! `update.found` event.
//!
//! Installed applications come from the core-maintained [`InventoryStore`] and
//! device ABIs from the stored [`PlatformFacts`]; this module never calls
//! platform code. A missing facts row aborts the batch with
//! [`Error::Unsupported`] (`CORE_E_FACTS_MISSING`); a missing or stale
//! inventory row skips only that app. Staleness is judged with
//! [`UpdateRules::max_inventory_age_secs`] and [`InventoryStore::is_stale`].
//!
//! [`InventoryStore`]: crate::inventory::InventoryStore
//! [`PlatformFacts`]: crate::facts::PlatformFacts
//! [`UpdateRules`]: crate::facts::UpdateRules
//! [`InventoryStore::is_stale`]: crate::inventory::InventoryStore::is_stale

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use rusqlite::{Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};

use crate::added::apps::AddedAppsService;
use crate::channel::ChannelDriver;
use crate::db::{DbError, DbHandle};
use crate::dto::{AppDetail, AppDownload, AppUpdate, ChannelKey};
use crate::error::Error;
use crate::event::CoreEvent;
use crate::facts::{FactStore, PlatformFacts};
use crate::inventory::InventoryStore;
use crate::rules::RuleStore;

/// Stable message prefix for a missing `platform_facts` row.
pub const FACTS_MISSING: &str = "CORE_E_FACTS_MISSING";
/// Stable message prefix for inventory older than `max_inventory_age_secs`.
pub const INVENTORY_STALE: &str = "CORE_E_INVENTORY_STALE";

/// Resolves a channel code stored in `added_apps.channel_id` to its driver.
pub type ChannelResolver =
    Arc<dyn Fn(&str) -> Option<Arc<dyn crate::channel::ChannelDriver>> + Send + Sync>;

/// Cache validity window (one hour), in milliseconds.
pub const UPDATE_CACHE_TTL_MS: i64 = 3_600_000;

const KEY_LAST_CHECKED: &str = "update_last_checked_at";
const KEY_RESULTS: &str = "update_results_v1";
const KEY_LOGS: &str = "update_check_logs_v1";
const KEY_PREFERRED_APK: &str = "update_preferred_apk";

/// Download payload persisted in the update cache (Dart `toCacheJson` shape).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CachedDownload {
    pub url: String,
    pub name: String,
    pub size: Option<i64>,
    pub download_count: Option<i64>,
    pub version: Option<String>,
    pub version_code: Option<i64>,
    pub published_at: Option<i64>,
    pub platform: Option<String>,
    pub hash: Option<String>,
    pub hash_type: Option<String>,
}

impl From<&AppDownload> for CachedDownload {
    fn from(download: &AppDownload) -> Self {
        Self {
            url: download.url.clone(),
            name: download.name.clone(),
            size: download.size,
            download_count: download.download_count,
            version: download.version.clone(),
            version_code: download.version_code,
            published_at: download.published_at,
            platform: download.platform.clone(),
            hash: download.hash.clone(),
            hash_type: download.hash_type.clone(),
        }
    }
}

/// One updatable app (mirrors Dart `AppUpdateInfo`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdateInfo {
    pub channel_id: String,
    pub app_id: String,
    pub app_name: String,
    pub icon_url: Option<String>,
    pub package_name: String,
    pub installed_version: String,
    pub latest_version: String,
    pub checked_at: i64,
    pub download: CachedDownload,
    #[serde(skip)]
    pub detail: Option<AppDetail>,
}

/// Log severity (Dart `CheckLogLevel`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckLogLevel {
    Info,
    Installed,
    Update,
    None,
    Skip,
    Error,
}

/// One update-check log line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CheckLogEntry {
    pub level: CheckLogLevel,
    pub text: String,
    pub time: i64,
}

/// One skipped app and the reason it was skipped.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateSkip {
    pub channel_id: String,
    pub app_id: String,
    pub reason: String,
}

/// Result of one `check_all` / `run` call.
#[derive(Debug, Clone, PartialEq)]
pub struct UpdateCheckReport {
    pub checked_at: i64,
    pub total: usize,
    pub updates: Vec<AppUpdateInfo>,
    pub skipped: Vec<UpdateSkip>,
    pub used_cache: bool,
    pub events: Vec<CoreEvent>,
}

/// One progressive event emitted while a batch update check runs.
///
/// `names` is only populated by the first event so the UI can pre-fill the
/// wheel with the full candidate list before any network call finishes.
#[derive(Debug, Clone, PartialEq)]
pub struct UpdateProgress {
    pub index: usize,
    pub total: usize,
    pub app_id: String,
    pub app_name: String,
    pub icon_url: Option<String>,
    pub log_level: Option<CheckLogLevel>,
    pub log_text: Option<String>,
    /// Whether this event is a completed per-app result (not a start line).
    pub is_result: bool,
    pub names: Option<Vec<String>>,
}

/// Update checking, caching, and persistence service.
pub struct UpdateService {
    db: DbHandle,
    added: AddedAppsService,
    channels: ChannelResolver,
    inventory: InventoryStore,
    facts: FactStore,
    rules: RuleStore,
    clock: Arc<dyn Fn() -> i64 + Send + Sync>,
}

struct CheckOutcome {
    app_id: String,
    channel_key: String,
    installed_version: Option<String>,
    latest_version: Option<String>,
    status: &'static str,
    payload_json: String,
}

struct OneCheck {
    update: Option<AppUpdateInfo>,
    event: Option<CoreEvent>,
    skip_reason: Option<&'static str>,
    log_lines: Vec<(CheckLogLevel, String)>,
    outcome: Option<CheckOutcome>,
    app_name: Option<String>,
    icon_url: Option<String>,
}

impl OneCheck {
    fn with_identity(mut self, name: &str, icon: Option<&str>) -> Self {
        self.app_name = Some(name.trim().to_string()).filter(|value| !value.is_empty());
        self.icon_url = icon
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        self
    }

    fn with_extra_log(mut self, level: CheckLogLevel, text: String) -> Self {
        self.log_lines.push((level, text));
        self
    }
}

impl UpdateService {
    /// Creates a service using wall-clock time.
    pub fn new(db: DbHandle, channels: ChannelResolver) -> Self {
        Self::with_clock(
            db,
            channels,
            Arc::new(|| {
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|duration| duration.as_millis() as i64)
                    .unwrap_or(0)
            }),
        )
    }

    /// Creates a service with an injectable millisecond clock.
    pub fn with_clock(
        db: DbHandle,
        channels: ChannelResolver,
        clock: Arc<dyn Fn() -> i64 + Send + Sync>,
    ) -> Self {
        Self {
            added: AddedAppsService::new(db.clone()),
            inventory: InventoryStore::new(db.clone()),
            facts: FactStore::new(db.clone()),
            rules: RuleStore::new(db.clone()),
            db,
            channels,
            clock,
        }
    }

    /// Checks every added app, or returns the cached result when it is fresh.
    ///
    /// `force` skips the one-hour cache and always re-checks.
    pub fn check_all(&self, force: bool) -> Result<UpdateCheckReport, Error> {
        self.check_all_with_progress(force, |_| {})
    }

    pub fn check_all_with_progress<F>(
        &self,
        force: bool,
        mut on_progress: F,
    ) -> Result<UpdateCheckReport, Error>
    where
        F: FnMut(UpdateProgress),
    {
        let now = (self.clock)();
        if !force {
            let cached = self.list()?;
            if !cached.is_empty() {
                if let Some(last) = self.last_checked_at()? {
                    if now.saturating_sub(last) < UPDATE_CACHE_TTL_MS {
                        return Ok(UpdateCheckReport {
                            checked_at: last,
                            total: cached.len(),
                            updates: cached,
                            skipped: Vec::new(),
                            used_cache: true,
                            events: Vec::new(),
                        });
                    }
                }
            }
        }
        self.run_batch(now, force, &mut on_progress)
    }

    /// Forces a full update check.
    pub fn run(&self) -> Result<UpdateCheckReport, Error> {
        self.check_all(true)
    }

    /// Checks one app, preferring the cached result.
    pub fn check_app(
        &self,
        app_id: &str,
        channel_code: Option<&str>,
    ) -> Result<Option<AppUpdateInfo>, Error> {
        if let Some(cached) = self.list()?.into_iter().find(|info| info.app_id == app_id) {
            return Ok(Some(cached));
        }
        let Some(code) = channel_code.filter(|code| !code.is_empty()) else {
            return Ok(None);
        };
        let Some(channel) = (self.channels)(code) else {
            return Ok(None);
        };
        let facts = self.required_facts()?;
        let max_age = self.rules.effective_update()?.max_inventory_age_secs;
        let one = self.check_one(
            channel.as_ref(),
            code,
            app_id,
            (self.clock)(),
            &facts,
            max_age,
        )?;
        Ok(one.update)
    }

    /// Returns the cached updatable apps.
    pub fn list(&self) -> Result<Vec<AppUpdateInfo>, Error> {
        let Some(raw) = self.read_pref(KEY_RESULTS)? else {
            return Ok(Vec::new());
        };
        if raw.is_empty() {
            return Ok(Vec::new());
        }
        let parsed: Vec<AppUpdateInfo> = serde_json::from_str(&raw).unwrap_or_default();
        Ok(parsed
            .into_iter()
            .filter(|info| !info.app_id.is_empty() && !info.latest_version.is_empty())
            .map(|mut info| {
                info.detail = None;
                info
            })
            .collect())
    }

    /// Persisted log lines from the last check.
    pub fn cached_logs(&self) -> Result<Vec<CheckLogEntry>, Error> {
        let Some(raw) = self.read_pref(KEY_LOGS)? else {
            return Ok(Vec::new());
        };
        if raw.is_empty() {
            return Ok(Vec::new());
        }
        Ok(serde_json::from_str(&raw).unwrap_or_default())
    }

    /// Removes `app_id` from the cache once the installed version caught up.
    pub fn mark_updated(&self, app_id: &str) -> Result<bool, Error> {
        let mut results = self.list()?;
        let Some(position) = results.iter().position(|info| info.app_id == app_id) else {
            return Ok(false);
        };
        let info = results[position].clone();

        // Mapping chosen here (parity with the old host-backed branch): a cache
        // entry is dropped only when the stored install version has caught up.
        // An absent inventory row keeps the entry, and an inventory read error
        // propagates instead of silently deleting CORE_E_* state.
        let caught_up = match self.inventory.get(&info.package_name)? {
            Some(installed) => {
                !installed.version_name.trim().is_empty()
                    && compare_versions(&installed.version_name, &info.latest_version)
                        != Ordering::Less
            }
            None => false,
        };
        if !caught_up {
            return Ok(false);
        }

        results.retain(|cached| cached.app_id != app_id);
        let now = (self.clock)();
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;
        tx.execute(
            "INSERT INTO update_state(app_id, channel_key, latest_version, status, checked_at, payload_json) \
             VALUES (?1, ?2, ?3, 'updated', ?4, NULL) \
             ON CONFLICT(app_id, channel_key) DO UPDATE SET \
                 latest_version = excluded.latest_version, \
                 status = 'updated', \
                 checked_at = excluded.checked_at, \
                 payload_json = NULL",
            rusqlite::params![info.app_id, info.channel_id, info.latest_version, now],
        )
        .map_err(sql_error)?;
        let encoded = serde_json::to_string(&results)?;
        upsert_pref(&tx, KEY_RESULTS, &encoded, now)?;
        crate::migration::mark_core_write_if_flipped(&tx, "update", None).map_err(db_error)?;
        tx.commit().map_err(sql_error)?;
        Ok(true)
    }

    /// Whether the cache contains `app_id`.
    pub fn has_update(&self, app_id: &str) -> Result<bool, Error> {
        Ok(self.list()?.iter().any(|info| info.app_id == app_id))
    }

    /// Number of cached updatable apps.
    pub fn count(&self) -> Result<usize, Error> {
        Ok(self.list()?.len())
    }

    /// Whether the cached results are still inside the one-hour window.
    pub fn is_cache_valid(&self) -> Result<bool, Error> {
        if self.list()?.is_empty() {
            return Ok(false);
        }
        let Some(last) = self.last_checked_at()? else {
            return Ok(false);
        };
        Ok((self.clock)().saturating_sub(last) < UPDATE_CACHE_TTL_MS)
    }

    fn run_batch<F>(
        &self,
        now: i64,
        force: bool,
        on_progress: &mut F,
    ) -> Result<UpdateCheckReport, Error>
    where
        F: FnMut(UpdateProgress),
    {
        let facts = self.required_facts()?;
        let max_age = self.rules.effective_update()?.max_inventory_age_secs;
        if !force && self.inventory.is_stale(&facts.source_id, max_age, now)? {
            return Err(Error::Unsupported(format!(
                "{INVENTORY_STALE}: source {} is older than {max_age}s",
                facts.source_id
            )));
        }

        let added = self.added.list()?;
        let total = added.len();
        let cached: HashMap<String, (String, Option<String>)> = self
            .list()?
            .into_iter()
            .map(|info| (info.app_id, (info.app_name, info.icon_url)))
            .collect();
        let identities: HashMap<String, (String, Option<String>)> = added
            .iter()
            .filter_map(|app| {
                self.catalog_identity(&app.channel_id, &app.app_id)
                    .map(|identity| (app.app_id.clone(), identity))
            })
            .collect();
        let names: Vec<String> = added
            .iter()
            .map(|app| {
                cached
                    .get(&app.app_id)
                    .map(|(name, _)| name.clone())
                    .filter(|name| !name.trim().is_empty())
                    .or_else(|| {
                        identities
                            .get(&app.app_id)
                            .map(|(name, _)| name.clone())
                    })
                    .unwrap_or_else(|| app.app_id.clone())
            })
            .collect();
        let mut logs = vec![log_entry(CheckLogLevel::Info, "开始检测应用更新...", now)];
        logs.push(log_entry(
            CheckLogLevel::Info,
            &format!("已添加应用共 {total} 个"),
            now,
        ));
        on_progress(UpdateProgress {
            index: 0,
            total,
            app_id: String::new(),
            app_name: String::new(),
            icon_url: None,
            log_level: Some(CheckLogLevel::Info),
            log_text: Some("开始检测应用更新...".to_string()),
            is_result: false,
            names: Some(names),
        });
        on_progress(UpdateProgress {
            index: 0,
            total,
            app_id: String::new(),
            app_name: String::new(),
            icon_url: None,
            log_level: Some(CheckLogLevel::Info),
            log_text: Some(format!("已添加应用共 {total} 个")),
            is_result: false,
            names: None,
        });

        let mut updates = Vec::new();
        let mut skipped = Vec::new();
        let mut events = Vec::new();
        let mut outcomes = Vec::new();

        for (index, app) in added.iter().enumerate() {
            let cached_name = cached
                .get(&app.app_id)
                .map(|(name, _)| name.clone())
                .filter(|name| !name.trim().is_empty());
            let cached_icon = cached
                .get(&app.app_id)
                .and_then(|(_, icon)| icon.clone());
            let identity = identities.get(&app.app_id);
            let start_name = cached_name
                .clone()
                .or_else(|| identity.map(|(name, _)| name.clone()))
                .unwrap_or_else(|| app.app_id.clone());
            let start_icon = cached_icon
                .clone()
                .or_else(|| identity.and_then(|(_, icon)| icon.clone()));
            let start_text = format!("开始检测应用：{start_name}");
            logs.push(log_entry(CheckLogLevel::Info, &start_text, now));
            on_progress(UpdateProgress {
                index,
                total,
                app_id: app.app_id.clone(),
                app_name: start_name.clone(),
                icon_url: start_icon.clone(),
                log_level: Some(CheckLogLevel::Info),
                log_text: Some(start_text),
                is_result: false,
                names: None,
            });
            if app.app_id.trim().is_empty() {
                skipped.push(UpdateSkip {
                    channel_id: app.channel_id.clone(),
                    app_id: app.app_id.clone(),
                    reason: "invalid_app_id".to_string(),
                });
                continue;
            }
            let Some(channel) = (self.channels)(&app.channel_id) else {
                skipped.push(UpdateSkip {
                    channel_id: app.channel_id.clone(),
                    app_id: app.app_id.clone(),
                    reason: "unknown_channel".to_string(),
                });
                let unknown_text = format!("应用 {start_name}：渠道不可用，跳过检测");
                logs.push(log_entry(CheckLogLevel::Skip, &unknown_text, now));
                on_progress(UpdateProgress {
                    index,
                    total,
                    app_id: app.app_id.clone(),
                    app_name: start_name.clone(),
                    icon_url: start_icon.clone(),
                    log_level: Some(CheckLogLevel::Skip),
                    log_text: Some(unknown_text),
                    is_result: true,
                    names: None,
                });
                continue;
            };
            let one = self.check_one(
                channel.as_ref(),
                &app.channel_id,
                &app.app_id,
                now,
                &facts,
                max_age,
            )?;
            let result_name = one
                .app_name
                .clone()
                .filter(|name| !name.trim().is_empty())
                .or_else(|| {
                    one.update
                        .as_ref()
                        .map(|update| update.app_name.clone())
                        .filter(|name| !name.trim().is_empty())
                })
                .unwrap_or_else(|| start_name.clone());
            let result_icon = one
                .icon_url
                .clone()
                .or_else(|| {
                    one.update
                        .as_ref()
                        .and_then(|update| update.icon_url.clone())
                })
                .or_else(|| start_icon.clone());
            for (level, text) in one.log_lines.clone() {
                logs.push(log_entry(level, &text, now));
                on_progress(UpdateProgress {
                    index,
                    total,
                    app_id: app.app_id.clone(),
                    app_name: result_name.clone(),
                    icon_url: result_icon.clone(),
                    log_level: Some(level),
                    log_text: Some(text),
                    is_result: true,
                    names: None,
                });
            }
            if let Some(reason) = one.skip_reason {
                skipped.push(UpdateSkip {
                    channel_id: app.channel_id.clone(),
                    app_id: app.app_id.clone(),
                    reason: reason.to_string(),
                });
            }
            if let Some(outcome) = one.outcome {
                outcomes.push(outcome);
            }
            if let Some(event) = one.event {
                events.push(event);
            }
            if let Some(update) = one.update {
                updates.push(update);
            }
        }

        let summary = format!(
            "检测完成：共 {total} 个应用，更新 {} 个，跳过 {} 个",
            updates.len(),
            skipped.len()
        );
        logs.push(log_entry(CheckLogLevel::Update, &summary, now));
        on_progress(UpdateProgress {
            index: total.saturating_sub(1),
            total,
            app_id: String::new(),
            app_name: String::new(),
            icon_url: None,
            log_level: Some(CheckLogLevel::Update),
            log_text: Some(summary),
            is_result: true,
            names: None,
        });
        if updates.is_empty() && skipped.is_empty() {
            let latest = "所有已添加应用均已是最新版本";
            logs.push(log_entry(CheckLogLevel::None, latest, now));
            on_progress(UpdateProgress {
                index: total.saturating_sub(1),
                total,
                app_id: String::new(),
                app_name: String::new(),
                icon_url: None,
                log_level: Some(CheckLogLevel::None),
                log_text: Some(latest.to_string()),
                is_result: true,
                names: None,
            });
        }

        self.persist(now, &updates, &logs, &outcomes)?;
        Ok(UpdateCheckReport {
            checked_at: now,
            total,
            updates,
            skipped,
            used_cache: false,
            events,
        })
    }

    fn check_one(
        &self,
        channel: &dyn ChannelDriver,
        channel_code: &str,
        app_id: &str,
        now: i64,
        facts: &PlatformFacts,
        max_inventory_age_secs: i64,
    ) -> Result<OneCheck, Error> {
        let check = match channel.check_app_update(app_id) {
            Ok(check) => check,
            Err(error) => {
                return Ok(rejection(
                    app_id,
                    channel_code,
                    None,
                    None,
                    "channel_error",
                    &format!("应用 {app_id}：渠道检测失败 - {error}"),
                    serde_json::json!({
                        "reason": "channel_error",
                        "appId": app_id,
                        "channelKey": channel_code,
                        "error": error.to_string(),
                    })
                    .to_string(),
                ));
            }
        };

        let display_name = if check.name.trim().is_empty() {
            app_id.to_string()
        } else {
            check.name.clone()
        };
        let package_name = if check.package_name.trim().is_empty() {
            app_id.to_string()
        } else {
            check.package_name.trim().to_string()
        };
        if package_name.is_empty() {
            return Ok(rejection(
                app_id,
                channel_code,
                None,
                check.latest_version.clone(),
                "no_package",
                &format!("应用 {display_name}：无有效包名，跳过检测"),
                serde_json::json!({
                    "reason": "no_package",
                    "appId": app_id,
                    "channelKey": channel_code,
                })
                .to_string(),
            ).with_identity(&display_name, check.icon.as_deref()));
        }

        if self
            .inventory
            .is_stale(&facts.source_id, max_inventory_age_secs, now)?
        {
            return Ok(rejection(
                app_id,
                channel_code,
                None,
                check.latest_version.clone(),
                "inventory_stale",
                &format!("应用 {display_name}：设备清单已过期，跳过检测"),
                serde_json::json!({
                    "reason": "inventory_stale",
                    "appId": app_id,
                    "channelKey": channel_code,
                })
                .to_string(),
            ).with_identity(&display_name, check.icon.as_deref()));
        }

        let Some(installed) = self.inventory.get(&package_name)? else {
            return Ok(rejection(
                app_id,
                channel_code,
                None,
                check.latest_version.clone(),
                "inventory_missing",
                &format!("应用 {display_name}：应用未安装，跳过检测"),
                serde_json::json!({
                    "reason": "inventory_missing",
                    "appId": app_id,
                    "channelKey": channel_code,
                })
                .to_string(),
            ).with_identity(&display_name, check.icon.as_deref()));
        };

        let installed_version = installed.version_name;
        if installed_version.trim().is_empty() {
            return Ok(rejection(
                app_id,
                channel_code,
                Some(installed_version),
                check.latest_version.clone(),
                "no_installed_version",
                &format!("应用 {display_name}：已安装但无法获取版本号，跳过检测"),
                serde_json::json!({
                    "reason": "no_installed_version",
                    "appId": app_id,
                    "channelKey": channel_code,
                })
                .to_string(),
            ).with_identity(&display_name, check.icon.as_deref()));
        }

        let latest_version = check.latest_version.clone().unwrap_or_default();
        if latest_version.trim().is_empty() {
            return Ok(rejection(
                app_id,
                channel_code,
                Some(installed_version.clone()),
                Some(latest_version),
                "no_channel_version",
                &format!("应用 {display_name}：渠道无版本信息（安装版本 {installed_version}），跳过检测"),
                serde_json::json!({
                    "reason": "no_channel_version",
                    "appId": app_id,
                    "channelKey": channel_code,
                })
                .to_string(),
            ).with_identity(&display_name, check.icon.as_deref()));
        }

        if compare_versions(&latest_version, &installed_version) != Ordering::Greater {
            return Ok(rejection(
                app_id,
                channel_code,
                Some(installed_version.clone()),
                Some(latest_version),
                "up_to_date",
                &format!("应用 {display_name}：安装版本 {installed_version}"),
                serde_json::json!({
                    "reason": "up_to_date",
                    "appId": app_id,
                    "channelKey": channel_code,
                })
                .to_string(),
            )
            .with_extra_log(
                CheckLogLevel::None,
                format!("应用 {display_name} 已是最新版本：{installed_version}"),
            )
            .with_identity(&display_name, check.icon.as_deref()));
        }

        let fallback = match check.latest_download.clone() {
            Some(download) => download,
            None => match select_best_download(&check.detail.downloads, &facts.abis) {
                Some(download) => download,
                None => {
                    return Ok(rejection(
                        app_id,
                        channel_code,
                        Some(installed_version.clone()),
                        Some(latest_version.clone()),
                        "no_download",
                        &format!("应用 {display_name}：安装版本 {installed_version}，发现新版本 {latest_version}，但无可下载文件，跳过检测"),
                        serde_json::json!({
                            "reason": "no_download",
                            "appId": app_id,
                            "channelKey": channel_code,
                        })
                        .to_string(),
                    ).with_identity(&display_name, check.icon.as_deref()));
                }
            },
        };

        let preferred = self.preferred_apk(channel_code, app_id)?;
        let download = select_download_with_preference(
            &fallback,
            &check.detail.downloads,
            preferred.as_deref(),
        );

        let identity_icon = check
            .icon
            .clone()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        let platform = download
            .platform
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("自动匹配");
        let log_lines = vec![
            (
                CheckLogLevel::Installed,
                format!("应用 {display_name}：安装版本 {installed_version}"),
            ),
            (
                CheckLogLevel::Update,
                format!("应用 {display_name} 发现新版本：{latest_version}"),
            ),
            (
                CheckLogLevel::Info,
                format!("应用 {display_name}：选择平台 {platform}"),
            ),
        ];
        let info = AppUpdateInfo {
            channel_id: channel_code.to_string(),
            app_id: app_id.to_string(),
            app_name: display_name.clone(),
            icon_url: check.icon.clone(),
            package_name: package_name.clone(),
            installed_version: installed_version.clone(),
            latest_version: latest_version.clone(),
            checked_at: now,
            download: CachedDownload::from(&download),
            detail: Some(check.detail.clone()),
        };
        let key = ChannelKey::new(channel_code)?;
        let event = CoreEvent::UpdateFound {
            key,
            app_id: app_id.to_string(),
            update: Box::<AppUpdate>::new(check),
        };
        let payload_json = serde_json::to_string(&info)?;

        Ok(OneCheck {
            update: Some(info),
            event: Some(event),
            skip_reason: None,
            log_lines,
            outcome: Some(CheckOutcome {
                app_id: app_id.to_string(),
                channel_key: channel_code.to_string(),
                installed_version: Some(installed_version),
                latest_version: Some(latest_version),
                status: "update_available",
                payload_json,
            }),
            app_name: Some(display_name),
            icon_url: identity_icon,
        })
    }

    fn required_facts(&self) -> Result<PlatformFacts, Error> {
        self.facts.get()?.ok_or_else(|| {
            Error::Unsupported(format!(
                "{FACTS_MISSING}: the frontend has not pushed platform facts"
            ))
        })
    }

    fn persist(
        &self,
        now: i64,
        updates: &[AppUpdateInfo],
        logs: &[CheckLogEntry],
        outcomes: &[CheckOutcome],
    ) -> Result<(), Error> {
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;

        for outcome in outcomes {
            tx.execute(
                "INSERT INTO update_state(app_id, channel_key, latest_version, status, checked_at, payload_json) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6) \
                 ON CONFLICT(app_id, channel_key) DO UPDATE SET \
                     latest_version = excluded.latest_version, \
                     status = excluded.status, \
                     checked_at = excluded.checked_at, \
                     payload_json = excluded.payload_json",
                rusqlite::params![
                    outcome.app_id,
                    outcome.channel_key,
                    outcome.latest_version,
                    outcome.status,
                    now,
                    outcome.payload_json
                ],
            )
            .map_err(sql_error)?;
            tx.execute(
                "INSERT INTO update_log(app_id, channel_key, from_version, to_version, status, checked_at, payload_json) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                rusqlite::params![
                    outcome.app_id,
                    outcome.channel_key,
                    outcome.installed_version,
                    outcome.latest_version,
                    outcome.status,
                    now,
                    outcome.payload_json
                ],
            )
            .map_err(sql_error)?;
        }

        upsert_pref(&tx, KEY_LAST_CHECKED, &now.to_string(), now)?;
        upsert_pref(&tx, KEY_RESULTS, &serde_json::to_string(updates)?, now)?;
        upsert_pref(&tx, KEY_LOGS, &serde_json::to_string(logs)?, now)?;
        crate::migration::mark_core_write_if_flipped(&tx, "update", None).map_err(db_error)?;
        tx.commit().map_err(sql_error)?;
        Ok(())
    }

    fn read_pref(&self, key: &str) -> Result<Option<String>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        crate::migration::update_pref(&conn, key).map_err(db_error)
    }

    /// Persisted time of the last completed check (used by startup cache
    /// restore, including an all-up-to-date result with zero updates).
    pub fn last_checked_at(&self) -> Result<Option<i64>, Error> {
        Ok(self
            .read_pref(KEY_LAST_CHECKED)?
            .and_then(|raw| raw.parse::<i64>().ok()))
    }

    fn catalog_identity(
        &self,
        channel_code: &str,
        app_id: &str,
    ) -> Option<(String, Option<String>)> {
        let conn = self.db.reader().ok()?;
        let mut stmt = conn
            .prepare(
                "SELECT name, icon FROM channel_apps WHERE app_id = ?1 \
                 ORDER BY CASE WHEN channel_key = ?2 THEN 0 ELSE 1 END, add_time DESC \
                 LIMIT 1",
            )
            .ok()?;
        let (name, icon) = stmt
            .query_row(rusqlite::params![app_id, channel_code], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .ok()?;
        let name = name.trim().to_string();
        let icon = icon.trim().to_string();
        Some((
            if name.is_empty() {
                app_id.to_string()
            } else {
                name
            },
            (!icon.is_empty()).then_some(icon),
        ))
    }

    fn preferred_apk(&self, channel_code: &str, app_id: &str) -> Result<Option<String>, Error> {
        let Some(raw) = self.read_pref(KEY_PREFERRED_APK)? else {
            return Ok(None);
        };
        if raw.is_empty() {
            return Ok(None);
        }
        let map: BTreeMap<String, String> = serde_json::from_str(&raw).unwrap_or_default();
        Ok(map
            .get(&format!("{channel_code}:{app_id}"))
            .map(|name| name.trim().to_string())
            .filter(|name| !name.is_empty()))
    }
}

fn rejection(
    app_id: &str,
    channel_code: &str,
    installed_version: Option<String>,
    latest_version: Option<String>,
    reason: &'static str,
    log_text: &str,
    payload_json: String,
) -> OneCheck {
    OneCheck {
        update: None,
        event: None,
        skip_reason: Some(reason),
        log_lines: vec![(level_for_reason(reason), log_text.to_string())],
        outcome: Some(CheckOutcome {
            app_id: app_id.to_string(),
            channel_key: channel_code.to_string(),
            installed_version,
            latest_version,
            status: status_for_reason(reason),
            payload_json,
        }),
        app_name: None,
        icon_url: None,
    }
}

fn status_for_reason(reason: &str) -> &'static str {
    match reason {
        "channel_error" | "no_package" => "error",
        "not_installed" => "not_installed",
        "inventory_missing" => "inventory_missing",
        "inventory_stale" => "inventory_stale",
        "no_installed_version" | "no_channel_version" => "no_version",
        "up_to_date" => "up_to_date",
        "no_download" => "no_download",
        _ => "error",
    }
}

fn level_for_reason(reason: &str) -> CheckLogLevel {
    match reason {
        "channel_error" => CheckLogLevel::Error,
        "up_to_date" => CheckLogLevel::None,
        _ => CheckLogLevel::Skip,
    }
}

fn log_entry(level: CheckLogLevel, text: &str, time: i64) -> CheckLogEntry {
    CheckLogEntry {
        level,
        text: text.to_string(),
        time,
    }
}

fn upsert_pref(tx: &Transaction<'_>, key: &str, value: &str, now: i64) -> Result<(), Error> {
    tx.execute(
        "INSERT INTO update_prefs(key, value, imported_at) VALUES (?1, ?2, ?3) \
         ON CONFLICT(key) DO UPDATE SET \
             value = excluded.value, imported_at = excluded.imported_at",
        rusqlite::params![key, value, now],
    )
    .map_err(sql_error)?;
    Ok(())
}

fn db_error(error: DbError) -> Error {
    Error::Io(error.to_string())
}

fn sql_error(error: rusqlite::Error) -> Error {
    Error::Io(error.to_string())
}

/// Compares two version strings with arbitrary-precision numeric segments.
///
/// Every run of ASCII digits is a segment. Leading zeros are stripped and
/// missing trailing segments are treated as `0`, so `"1.0" == "1.0.0"` and
/// `"v2" > "1.9"`. `Ordering::Greater` means `a` is newer than `b`.
pub fn compare_versions(a: &str, b: &str) -> Ordering {
    let left = version_segments(a);
    let right = version_segments(b);
    let len = left.len().max(right.len());
    for index in 0..len {
        let left_part = left.get(index).map(String::as_str).unwrap_or("0");
        let right_part = right.get(index).map(String::as_str).unwrap_or("0");
        let ordering = left_part
            .len()
            .cmp(&right_part.len())
            .then_with(|| left_part.cmp(right_part));
        if ordering != Ordering::Equal {
            return ordering;
        }
    }
    Ordering::Equal
}

fn version_segments(version: &str) -> Vec<String> {
    let mut segments = Vec::new();
    let mut current = String::new();
    for ch in version.chars() {
        if ch.is_ascii_digit() {
            current.push(ch);
        } else if !current.is_empty() {
            segments.push(normalize_segment(&current));
            current.clear();
        }
    }
    if !current.is_empty() {
        segments.push(normalize_segment(&current));
    }
    if segments.is_empty() {
        segments.push("0".to_string());
    }
    segments
}

fn normalize_segment(segment: &str) -> String {
    let trimmed = segment.trim_start_matches('0');
    if trimmed.is_empty() {
        "0".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Normalizes an Android ABI string to the canonical Dart form.
pub fn normalize_abi(abi: &str) -> String {
    let lower = abi.to_lowercase();
    if lower.contains("arm64") && lower.contains("v8a") {
        "arm64-v8a".to_string()
    } else if lower.contains("armeabi-v7a") {
        "armeabi-v7a".to_string()
    } else if lower.contains("x86_64") {
        "x86_64".to_string()
    } else if lower.contains("x86") {
        "x86".to_string()
    } else {
        abi.to_string()
    }
}

/// Whether an asset file name matches `abi` (Dart `assetMatchesDevice`).
pub fn asset_matches_abi(file_name: &str, abi: &str) -> bool {
    let lower = file_name.to_lowercase();
    if lower.contains("universal") {
        return true;
    }
    match normalize_abi(abi).as_str() {
        "arm64-v8a" => lower.contains("arm64"),
        "armeabi-v7a" => lower.contains("armeabi-v7a") || lower.contains("arm32"),
        "x86_64" => lower.contains("x86_64"),
        "x86" => lower.contains("x86") && !lower.contains("x86_64"),
        _ => true,
    }
}

/// Selects the best download using the device ABI preference order.
///
/// Order: an `.apk` matching an ABI, any file matching an ABI, any `.apk`, then
/// the first candidate. An empty list yields `None`.
pub fn select_best_download(downloads: &[AppDownload], abis: &[String]) -> Option<AppDownload> {
    if downloads.is_empty() {
        return None;
    }
    let is_apk = |download: &AppDownload| download.name.to_lowercase().ends_with(".apk");

    for abi in abis {
        for download in downloads {
            if is_apk(download) && asset_matches_abi(&download.name, abi) {
                return Some(download.clone());
            }
        }
    }
    for abi in abis {
        for download in downloads {
            if asset_matches_abi(&download.name, abi) {
                return Some(download.clone());
            }
        }
    }
    for download in downloads {
        if is_apk(download) {
            return Some(download.clone());
        }
    }
    downloads.first().cloned()
}

/// Picks the candidate whose file name is closest to `preferred`.
///
/// Comparison is lowercase and uses Levenshtein distance over UTF-16 code
/// units. Equal distances keep the earlier candidate; distance zero returns
/// immediately. Empty candidates or a blank preference yield `None`.
pub fn pick_closest_apk(candidates: &[AppDownload], preferred: &str) -> Option<AppDownload> {
    if candidates.is_empty() || preferred.trim().is_empty() {
        return None;
    }
    let target: Vec<u16> = preferred.to_lowercase().encode_utf16().collect();
    let mut best: Option<&AppDownload> = None;
    let mut best_distance = usize::MAX;
    for candidate in candidates {
        let name: Vec<u16> = candidate.name.to_lowercase().encode_utf16().collect();
        let distance = levenshtein(&name, &target);
        if distance < best_distance {
            best_distance = distance;
            best = Some(candidate);
            if distance == 0 {
                break;
            }
        }
    }
    best.cloned()
}

/// Applies the preferred file name over the architecture-selected fallback.
pub fn select_download_with_preference(
    fallback: &AppDownload,
    candidates: &[AppDownload],
    preferred: Option<&str>,
) -> AppDownload {
    let Some(preferred) = preferred.filter(|name| !name.trim().is_empty()) else {
        return fallback.clone();
    };
    pick_closest_apk(candidates, preferred).unwrap_or_else(|| fallback.clone())
}

fn levenshtein(left: &[u16], right: &[u16]) -> usize {
    if left == right {
        return 0;
    }
    if left.is_empty() {
        return right.len();
    }
    if right.is_empty() {
        return left.len();
    }
    let mut previous: Vec<usize> = (0..=right.len()).collect();
    let mut current = vec![0_usize; right.len() + 1];
    for (left_index, left_unit) in left.iter().enumerate() {
        current[0] = left_index + 1;
        for (right_index, right_unit) in right.iter().enumerate() {
            let cost = usize::from(left_unit != right_unit);
            current[right_index + 1] = (previous[right_index + 1] + 1)
                .min(current[right_index] + 1)
                .min(previous[right_index] + cost);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[right.len()]
}
