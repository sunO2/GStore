//! Channel-aware aggregation and paged catalog queries.
//!
//! This is the Rust half of Dart's `AppAggregatorManager` plus the app-list
//! filter/sort helpers from `AppListLogic`:
//!
//! * [`AggregationService`] walks `added_apps` in `add_time DESC` order, asks
//!   the owning channel driver for each app, and keeps the input order.
//! * Channel misses degrade to the stored reference (placeholder summary)
//!   instead of failing the whole list; unknown channel codes are skipped.
//! * User tags and catalog category descriptions are merged into each
//!   summary's category list, preserving first occurrence.
//! * [`sort_filter`], [`categories_from_apps`], [`recent`], and
//!   [`dedup_channels_and_packages`] are pure helpers over the aggregated
//!   list, matching the Dart list page behavior and the plan's F-Droid
//!   package-priority rule.
//!
//! Dart parity notes (intentional):
//!
//! * A cached placeholder uses `name = app_id` and empty user/repository/
//!   icon/description fields; the aggregator database stores references only.
//! * A driver error other than [`crate::error::Error::NotFound`] marks the row
//!   as [`crate::dto::ChannelKind::LocalDb`] and records the error string,
//!   exactly like the Dart catch branch.
//! * Dart has no cross-channel package merge. [`AggregationService::aggregate_all`]
//!   and [`AggregationService::aggregate_page`] are pure Dart parity and never
//!   dedup; the `*_deduped` variants are explicit opt-in and apply the plan's
//!   F-Droid package-priority rule over the full ordered list.

use std::collections::{BTreeMap, HashSet};

use crate::added::apps::{AddedApp, AddedAppsService};
use crate::catalog::service::CatalogService;
use crate::db::DbHandle;
use crate::dto::{AppSummary, ChannelKind};
use crate::error::Error;

/// Resolves a channel code to its key-bound driver.
///
/// Returning `None` means the channel is unknown and the app is skipped, which
/// mirrors Dart's `getChannelByCode(...) == null` continue path.
pub type ChannelResolver = std::sync::Arc<
    dyn Fn(&str) -> Option<std::sync::Arc<dyn crate::channel::ChannelDriver>> + Send + Sync,
>;

/// One added app plus its resolved channel summary.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct AggregatedApp {
    /// Reference row from `added_apps`.
    pub added_app: AddedApp,
    /// Channel summary, or the cached placeholder when the driver failed.
    pub app: AppSummary,
    /// Channel implementation kind.
    pub channel: ChannelKind,
    /// Channel code stored in `added_apps.channel_id`.
    pub channel_code: String,
    /// Whether [`AggregatedApp::app`] is the stored-reference placeholder.
    pub is_from_cache: bool,
    /// Driver failure message when aggregation fell back after an error.
    pub error: Option<String>,
}

/// Sort mode for the aggregated app list.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AppSortMode {
    /// Newest added first (`add_time DESC`).
    #[default]
    Recent,
    /// Display name, case-insensitive ascending.
    Name,
    /// Apps with an update first, then newest added.
    UpdateFirst,
}

/// Keyword/category filter plus sort mode for the app list.
#[derive(Debug, Clone, Default)]
pub struct AppFilter {
    /// Case-insensitive match against name, description, or app id.
    pub keyword: Option<String>,
    /// Exact (trimmed) category membership.
    pub category: Option<String>,
    /// Requested sort mode.
    pub sort: AppSortMode,
    /// App id → "has update" flags used by [`AppSortMode::UpdateFirst`].
    pub update_states: BTreeMap<String, bool>,
}

/// Aggregation service over the core database and channel drivers.
pub struct AggregationService {
    db: DbHandle,
    added: AddedAppsService,
    channels: ChannelResolver,
}

impl AggregationService {
    /// Creates the service around `db` and the channel resolver.
    pub fn new(db: DbHandle, channels: ChannelResolver) -> Result<Self, Error> {
        Ok(Self {
            added: AddedAppsService::new(db.clone()),
            db,
            channels,
        })
    }

    /// Aggregates every added app without dedup, preserving `add_time DESC`
    /// order.
    ///
    /// Unknown channels are skipped; a driver `NotFound` degrades to the cached
    /// placeholder without an error; any other driver error degrades the same
    /// way but records the error and uses [`ChannelKind::LocalDb`].
    pub fn aggregate_all(&self) -> Result<Vec<AggregatedApp>, Error> {
        let added = self.added.list()?;
        self.aggregate_slice(&added)
    }

    /// Aggregates every added app and then applies
    /// [`dedup_channels_and_packages`].
    ///
    /// This is the opt-in variant for callers that want one representative per
    /// non-empty package (F-Droid preferred) across the whole list. Dart's
    /// `getAggregatedApps` does not dedup; use
    /// [`AggregationService::aggregate_all`] for pure parity.
    pub fn aggregate_all_deduped(&self) -> Result<Vec<AggregatedApp>, Error> {
        Ok(dedup_channels_and_packages(self.aggregate_all()?))
    }

    /// Aggregates one page of the raw added-app list, without dedup.
    ///
    /// `total` is the number of raw `added_apps` rows (including unknown
    /// channels), so callers can build a correct scroll extent even when a page
    /// yields fewer rows. Slicing happens before aggregation, so concatenating
    /// pages of any size reproduces [`AggregationService::aggregate_all`]
    /// exactly. Package dedup is opt-in via
    /// [`AggregationService::aggregate_page_deduped`].
    pub fn aggregate_page(
        &self,
        offset: u32,
        limit: u32,
    ) -> Result<(Vec<AggregatedApp>, usize), Error> {
        let added = self.added.list()?;
        let total = added.len();
        let start = usize::try_from(offset).unwrap_or(usize::MAX);
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);
        if start >= total || limit == 0 {
            return Ok((Vec::new(), total));
        }
        let end = start.saturating_add(limit).min(total);
        let page = self.aggregate_slice(&added[start..end])?;
        Ok((page, total))
    }

    /// Dedups the full ordered list first, then returns one page of it.
    ///
    /// `total` is the deduped length, so pages are invariant to `limit` and
    /// concatenating pages reproduces
    /// [`AggregationService::aggregate_all_deduped`] exactly.
    pub fn aggregate_page_deduped(
        &self,
        offset: u32,
        limit: u32,
    ) -> Result<(Vec<AggregatedApp>, usize), Error> {
        let deduped = self.aggregate_all_deduped()?;
        let total = deduped.len();
        let start = usize::try_from(offset).unwrap_or(usize::MAX);
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);
        if start >= total || limit == 0 {
            return Ok((Vec::new(), total));
        }
        let end = start.saturating_add(limit).min(total);
        Ok((deduped[start..end].to_vec(), total))
    }

    fn aggregate_slice(&self, added: &[AddedApp]) -> Result<Vec<AggregatedApp>, Error> {
        let tags = self.added.tags_index()?;
        let categories = self.category_descriptions();
        let mut results = Vec::with_capacity(added.len());

        for row in added {
            let Some(driver) = (self.channels)(&row.channel_id) else {
                continue;
            };
            let driver_kind = driver.meta().kind;
            let key = format!("{}:{}", row.channel_id, row.app_id);

            let (mut app, channel, is_from_cache, error) =
                match driver.get_app_info(&row.app_id, false) {
                    Ok(summary) => (summary, driver_kind, false, None),
                    Err(Error::NotFound(_)) => {
                        (placeholder(row), driver_kind, true, None)
                    }
                    Err(other) => (
                        placeholder(row),
                        ChannelKind::LocalDb,
                        true,
                        Some(other.to_string()),
                    ),
                };

            let merged = merge_categories(&app, tags.get(&key), &categories);
            if !merged.is_empty() {
                app.category = Some(merged);
            }

            results.push(AggregatedApp {
                added_app: row.clone(),
                app,
                channel,
                channel_code: row.channel_id.clone(),
                is_from_cache,
                error,
            });
        }

        Ok(results)
    }

    fn category_descriptions(&self) -> BTreeMap<String, String> {
        let Ok(service) = CatalogService::new(self.db.clone()) else {
            return BTreeMap::new();
        };
        let Ok(categories) = service.categories() else {
            return BTreeMap::new();
        };
        categories
            .into_iter()
            .filter_map(|category| {
                let id = category.id.trim();
                let description = category.description.trim();
                if id.is_empty() || description.is_empty() {
                    None
                } else {
                    Some((id.to_string(), description.to_string()))
                }
            })
            .collect()
    }
}

/// Lowercases like Dart `String.toLowerCase()`: maps U+0130 to `i` and applies
/// per-character lowercase (no Rust final-sigma context), so `ΟΔΟΣ` -> `οδοσ`.
pub fn dart_lowercase(value: &str) -> String {
    value
        .chars()
        .map(|c| if c == '\u{0130}' { 'i' } else { c })
        .flat_map(char::to_lowercase)
        .collect()
}

/// Sorts and filters an aggregated list, returning a new vector.
///
/// `keyword` is Dart-lowercased and matched with `contains` against name,
/// description, and app id. `category` is an exact, trimmed membership test.
/// Ties fall back to `add_time DESC` then `app_id ASC`, keeping every order
/// deterministic.
pub fn sort_filter(apps: &[AggregatedApp], filter: &AppFilter) -> Vec<AggregatedApp> {
    let keyword = dart_lowercase(filter.keyword.as_deref().unwrap_or(""));
    let category = filter
        .category
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());

    let mut result: Vec<AggregatedApp> = apps
        .iter()
        .filter(|app| {
            if !keyword.is_empty() {
                let name = dart_lowercase(&app.app.name);
                let description = dart_lowercase(&app.app.des);
                let app_id = dart_lowercase(&app.app.app_id);
                if !name.contains(&keyword)
                    && !description.contains(&keyword)
                    && !app_id.contains(&keyword)
                {
                    return false;
                }
            }
            if let Some(category) = category {
                let matched = app.app.category.as_ref().is_some_and(|categories| {
                    categories
                        .iter()
                        .any(|candidate| candidate.trim() == category)
                });
                if !matched {
                    return false;
                }
            }
            true
        })
        .cloned()
        .collect();

    match filter.sort {
        AppSortMode::Recent => result.sort_by(compare_recent),
        AppSortMode::Name => result.sort_by(|left, right| {
            dart_lowercase(&left.app.name)
                .cmp(&dart_lowercase(&right.app.name))
                .then_with(|| {
                    right
                        .added_app
                        .add_time
                        .cmp(&left.added_app.add_time)
                })
                .then_with(|| left.added_app.app_id.cmp(&right.added_app.app_id))
        }),
        AppSortMode::UpdateFirst => result.sort_by(|left, right| {
            let left_updated = filter
                .update_states
                .get(&left.app.app_id)
                .copied()
                .unwrap_or(false);
            let right_updated = filter
                .update_states
                .get(&right.app.app_id)
                .copied()
                .unwrap_or(false);
            right_updated
                .cmp(&left_updated)
                .then_with(|| {
                    right
                        .added_app
                        .add_time
                        .cmp(&left.added_app.add_time)
                })
                .then_with(|| left.added_app.app_id.cmp(&right.added_app.app_id))
        }),
    }

    result
}

/// Collects distinct, trimmed, non-empty categories sorted by Dart
/// `String.compareTo` (UTF-16 code unit order).
///
/// There is no "All" entry; the UI adds it.
pub fn categories_from_apps(apps: &[AggregatedApp]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut categories = Vec::new();
    for app in apps {
        if let Some(values) = &app.app.category {
            for raw in values {
                let value = raw.trim();
                if value.is_empty() {
                    continue;
                }
                if seen.insert(value.to_string()) {
                    categories.push(value.to_string());
                }
            }
        }
    }
    categories.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
    categories
}

/// Returns the `count` most recently added apps, newest first.
pub fn recent(apps: &[AggregatedApp], count: usize) -> Vec<AggregatedApp> {
    let mut list = apps.to_vec();
    list.sort_by(compare_recent);
    list.truncate(count);
    list
}

/// Removes duplicate channel/app identities and collapses package duplicates.
///
/// First every `(channel_code, app_id)` pair keeps its first occurrence. Then
/// apps sharing a non-empty `package_name` collapse to one representative:
/// the first F-Droid entry when present, otherwise the first entry. Empty or
/// missing package names never collapse, and the survivors keep their original
/// relative order.
///
/// Dart has no cross-channel package merge; the F-Droid priority is the plan's
/// explicit rule for the Rust list.
pub fn dedup_channels_and_packages(apps: Vec<AggregatedApp>) -> Vec<AggregatedApp> {
    let mut seen = HashSet::new();
    let mut identity_unique = Vec::with_capacity(apps.len());
    for app in apps {
        let identity = (app.channel_code.clone(), app.added_app.app_id.clone());
        if seen.insert(identity) {
            identity_unique.push(app);
        }
    }

    let mut chosen: BTreeMap<String, usize> = BTreeMap::new();
    for (index, app) in identity_unique.iter().enumerate() {
        let Some(package) = app
            .app
            .package_name
            .as_deref()
            .filter(|package| !package.is_empty())
        else {
            continue;
        };
        match chosen.get(package) {
            None => {
                chosen.insert(package.to_string(), index);
            }
            Some(&existing)
                if identity_unique[existing].channel != ChannelKind::Fdroid
                    && app.channel == ChannelKind::Fdroid =>
            {
                chosen.insert(package.to_string(), index);
            }
            Some(_) => {}
        }
    }

    identity_unique
        .into_iter()
        .enumerate()
        .filter(|(index, app)| {
            app.app
                .package_name
                .as_deref()
                .filter(|package| !package.is_empty())
                .is_none_or(|package| chosen.get(package) == Some(index))
        })
        .map(|(_, app)| app)
        .collect()
}

fn placeholder(row: &AddedApp) -> AppSummary {
    AppSummary {
        app_id: row.app_id.clone(),
        package_name: None,
        name: row.app_id.clone(),
        user: String::new(),
        repositories: String::new(),
        icon: String::new(),
        des: String::new(),
        readme: None,
        category: None,
        extra: None,
    }
}

fn merge_categories(
    app: &AppSummary,
    tags: Option<&Vec<String>>,
    descriptions: &BTreeMap<String, String>,
) -> Vec<String> {
    let mut merged = Vec::new();
    let mut seen = HashSet::new();
    let from_summary = app.category.iter().flatten();
    let from_tags = tags.into_iter().flatten();

    for raw in from_summary.chain(from_tags) {
        let value = raw.trim();
        if value.is_empty() {
            continue;
        }
        let mapped = descriptions
            .get(value)
            .cloned()
            .unwrap_or_else(|| value.to_string());
        if seen.insert(mapped.clone()) {
            merged.push(mapped);
        }
    }

    merged
}

fn compare_recent(left: &AggregatedApp, right: &AggregatedApp) -> std::cmp::Ordering {
    right
        .added_app
        .add_time
        .cmp(&left.added_app.add_time)
        .then_with(|| left.added_app.app_id.cmp(&right.added_app.app_id))
}
