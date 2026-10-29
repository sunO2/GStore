//! Unified-read fallback tests: driver → `channel_apps` → placeholder, plus
//! `metadata_state` provenance and unchanged paging/sort semantics.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::added::apps::AddedAppsService;
use gstore_core::aggregate::service::{
    AggregatedApp, AggregationService, ChannelAppFallback, ChannelResolver, MetadataState,
};
use gstore_core::channel::{ChannelDriver, InMemoryChannelDriver};
use gstore_core::db::DbHandle;
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta};
use gstore_core::error::Error;
use rusqlite::params;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_fallback_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn meta(code: &str, kind: ChannelKind) -> ChannelMeta {
    ChannelMeta {
        kind,
        name: code.to_string(),
        description: format!("{code} channel"),
        enabled: true,
        priority: 0,
        support_offline: true,
        last_update_time: None,
        version: Some("1".to_string()),
    }
}

fn summary(app_id: &str, package: Option<&str>, name: &str) -> AppSummary {
    AppSummary {
        app_id: app_id.to_string(),
        package_name: package.map(str::to_string),
        name: name.to_string(),
        user: String::new(),
        repositories: String::new(),
        icon: String::new(),
        des: format!("{name} description"),
        readme: None,
        category: Some(vec!["TOOLS".to_string()]),
        extra: None,
        labels: Vec::new(),
    }
}

fn driver(code: &str, kind: ChannelKind, apps: Vec<AppSummary>) -> Arc<dyn ChannelDriver> {
    let key = ChannelKey::new(code).unwrap();
    Arc::new(InMemoryChannelDriver::new(key, meta(code, kind)).with_apps(apps))
}

fn resolver(drivers: Vec<Arc<dyn ChannelDriver>>) -> ChannelResolver {
    let map: BTreeMap<String, Arc<dyn ChannelDriver>> = drivers
        .into_iter()
        .map(|driver| (driver.key().as_str().to_string(), driver))
        .collect();
    Arc::new(move |code: &str| map.get(code).cloned())
}

fn add_added(db: &DbHandle, channel: &str, app_id: &str, add_time: i64, sort_order: i64) {
    let conn = db.writer().unwrap();
    conn.execute(
        "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
         VALUES (?1, ?2, ?3, ?4, 1)",
        params![channel, app_id, add_time, sort_order],
    )
    .unwrap();
}

#[derive(Default)]
struct FakeFallback {
    rows: BTreeMap<(String, String), AppSummary>,
}

impl FakeFallback {
    fn new() -> Self {
        Self::default()
    }

    fn with(mut self, channel: &str, app_id: &str, app: AppSummary) -> Self {
        self.rows
            .insert((channel.to_string(), app_id.to_string()), app);
        self
    }
}

impl ChannelAppFallback for FakeFallback {
    fn get(&self, channel_key: &str, app_id: &str) -> Result<Option<AppSummary>, Error> {
        Ok(self
            .rows
            .get(&(channel_key.to_string(), app_id.to_string()))
            .cloned())
    }
}

fn service(
    db: &DbHandle,
    drivers: Vec<Arc<dyn ChannelDriver>>,
    fallback: FakeFallback,
) -> AggregationService {
    AggregationService::new(db.clone(), resolver(drivers))
        .unwrap()
        .with_fallback(Arc::new(fallback))
}

fn ids(apps: &[AggregatedApp]) -> Vec<String> {
    apps.iter().map(|app| app.app.app_id.clone()).collect()
}

#[test]
fn fallback_resolves_js_channel_without_driver() {
    let dir = TempDir::new("js_hit");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "js_pingan", "app-1", 3000, 0);

    let fallback = FakeFallback::new().with(
        "js_pingan",
        "app-1",
        summary("app-1", Some("com.pingan.app"), "PingAn"),
    );
    let service = service(&db, Vec::new(), fallback);

    let all = service.aggregate_all().unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].app.name, "PingAn");
    assert_eq!(all[0].app.package_name.as_deref(), Some("com.pingan.app"));
    assert_eq!(all[0].metadata_state, MetadataState::FromChannelStore);
    assert!(!all[0].is_from_cache);
    assert_eq!(all[0].channel, ChannelKind::JsLocal);
    assert!(all[0].error.is_none());
}

#[test]
fn missing_driver_and_fallback_row_yields_unresolved_placeholder() {
    let dir = TempDir::new("js_miss");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "js_missing", "ghost-1", 1000, 0);

    let service = service(&db, Vec::new(), FakeFallback::new());

    let all = service.aggregate_all().unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].app.name, "ghost-1");
    assert!(all[0].app.package_name.is_none());
    assert!(all[0].is_from_cache);
    assert_eq!(all[0].metadata_state, MetadataState::Unresolved);
    assert_eq!(all[0].channel, ChannelKind::JsLocal);
}

#[test]
fn driver_hit_wins_over_fallback() {
    let dir = TempDir::new("driver_wins");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "app-1", 2000, 0);

    let fallback = FakeFallback::new().with(
        "github",
        "app-1",
        summary("app-1", Some("com.fallback"), "Fallback App"),
    );
    let service = service(
        &db,
        vec![driver(
            "github",
            ChannelKind::Github,
            vec![summary("app-1", Some("com.driver"), "Driver App")],
        )],
        fallback,
    );

    let all = service.aggregate_all().unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].app.name, "Driver App");
    assert_eq!(all[0].app.package_name.as_deref(), Some("com.driver"));
    assert_eq!(all[0].metadata_state, MetadataState::Resolved);
    assert!(!all[0].is_from_cache);
}

#[test]
fn fallback_keeps_add_time_order_and_raw_row_totals() {
    let dir = TempDir::new("paging");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "old", 1000, 99);
    add_added(&db, "js_lane", "js1", 3000, 0);
    add_added(&db, "ghost", "gone", 2000, 50);

    let fallback =
        FakeFallback::new().with("js_lane", "js1", summary("js1", Some("com.js"), "JS App"));
    let service = service(
        &db,
        vec![driver(
            "github",
            ChannelKind::Github,
            vec![summary("old", Some("com.old"), "Old App")],
        )],
        fallback,
    );

    let all = service.aggregate_all().unwrap();
    assert_eq!(
        ids(&all),
        vec!["js1", "gone", "old"],
        "add_time DESC; sort_order never participates"
    );
    assert_eq!(all[0].metadata_state, MetadataState::FromChannelStore);
    assert_eq!(all[1].metadata_state, MetadataState::Unresolved);
    assert_eq!(all[2].metadata_state, MetadataState::Resolved);

    let (page, total) = service.aggregate_page(0, 2).unwrap();
    assert_eq!(total, 3, "total is the raw added_apps row count");
    let (rest, rest_total) = service.aggregate_page(2, 2).unwrap();
    assert_eq!(rest_total, 3);
    let mut concatenated = ids(&page);
    concatenated.extend(ids(&rest));
    assert_eq!(
        concatenated,
        ids(&all),
        "pages concatenate to aggregate_all"
    );

    let (everything, everything_total) = service.aggregate_page(0, 100).unwrap();
    assert_eq!(everything_total, 3);
    assert_eq!(ids(&everything), ids(&all));
}

#[test]
fn legacy_constructor_still_skips_unknown_channels() {
    let dir = TempDir::new("legacy");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "ghost", "gone", 2000, 0);
    add_added(&db, "github", "app-1", 1000, 0);

    let service = AggregationService::new(
        db.clone(),
        resolver(vec![driver(
            "github",
            ChannelKind::Github,
            vec![summary("app-1", None, "App")],
        )]),
    )
    .unwrap();

    let all = service.aggregate_all().unwrap();
    assert_eq!(ids(&all), vec!["app-1"]);
    assert_eq!(service.aggregate_page(0, 10).unwrap().1, 2);
}

#[test]
fn fallback_preserves_legacy_tag_merge() {
    let dir = TempDir::new("tags");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "js_lane", "js1", 1000, 0);
    AddedAppsService::new(db.clone())
        .set_tags("js_lane", "js1", &["自定义".to_string()])
        .unwrap();

    let fallback =
        FakeFallback::new().with("js_lane", "js1", summary("js1", Some("com.js"), "JS App"));
    let service = service(&db, Vec::new(), fallback);

    let all = service.aggregate_all().unwrap();
    assert_eq!(
        all[0].app.category,
        Some(vec!["TOOLS".to_string(), "自定义".to_string()])
    );
}
