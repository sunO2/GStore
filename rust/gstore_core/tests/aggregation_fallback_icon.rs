//! Home-read icon resolution for the `channel_apps` fallback.
//!
//! F-Droid stores its icon as a repo-relative asset key (`icons/<pkg>.png`,
//! see `FdroidDriver::add_app` -> `repo_asset_key`). When the driver is absent
//! (or disabled, so it yields `NotFound`) the aggregation fallback serves the
//! row; the icon must be rebuilt against the row's own source exactly like the
//! driver's `summary_from_stored` -> `absolute_icon_url`. Before the fix the
//! fallback copied the relative key verbatim, which the Dart `AppIcon` widget
//! treats as a network URL and thus fails to render.
//!
//! These tests drive the real [`SqliteChannelAppFallback`] through
//! [`AggregationService::with_fallback`] with no resolver driver, so the only
//! path that can serve the row is the projection.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::aggregate::channel_app_fallback::SqliteChannelAppFallback;
use gstore_core::aggregate::service::{AggregationService, ChannelResolver, MetadataState};
use gstore_core::channel::{ChannelDriver, FdroidDriver};
use gstore_core::db::{DbError, DbHandle};
use gstore_core::dto::{ChannelKey, ChannelKind, ChannelMeta};
use gstore_core::ports::{CoreConfig, FakeRepoPort};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_fallback_icon_{tag}_{}_{}",
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

fn meta(kind: ChannelKind, name: &str) -> ChannelMeta {
    ChannelMeta {
        kind,
        name: name.to_string(),
        description: format!("{name} channel"),
        enabled: true,
        priority: 0,
        support_offline: true,
        last_update_time: None,
        version: Some("1".to_string()),
    }
}

/// Inserts an `added_apps` membership row so the aggregator has something to
/// resolve. `sort_order` is irrelevant to the read order.
fn add_added(db: &DbHandle, channel: &str, app_id: &str, add_time: i64) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
             VALUES (?1, ?2, ?3, 0, 1)",
            rusqlite::params![channel, app_id, add_time],
        )
        .map_err(|error| DbError(error.to_string()))?;
        Ok(())
    })
    .unwrap();
}

#[allow(clippy::too_many_arguments)]
fn insert_channel_app(
    db: &DbHandle,
    channel: &str,
    app_id: &str,
    icon: &str,
    source_id: Option<&str>,
    extra: Option<&str>,
) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,icon,description,\
             category,add_time,source_id,extra) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            rusqlite::params![
                channel,
                app_id,
                "Example App",
                "author",
                app_id,
                icon,
                "short description",
                "TOOLS",
                1000_i64,
                source_id,
                extra,
            ],
        )
        .map_err(|error| DbError(error.to_string()))?;
        Ok(())
    })
    .unwrap();
}

fn no_driver_resolver() -> ChannelResolver {
    Arc::new(|_code: &str| None)
}

fn service_with_real_fallback(db: &DbHandle) -> AggregationService {
    AggregationService::new(db.clone(), no_driver_resolver())
        .unwrap()
        .with_fallback(Arc::new(SqliteChannelAppFallback::new(db.clone())))
}

/// The reported bug: an F-Droid row whose driver is gone/disabled is served by
/// the projection, and the relative `icons/<pkg>.png` key must become an
/// absolute URL the Dart icon loader can render.
#[test]
fn fdroid_fallback_rebuilds_relative_icon_against_source() {
    let dir = TempDir::new("fdroid_relative");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "fdroid", "com.x", 3000);
    insert_channel_app(
        &db,
        "fdroid",
        "com.x",
        "icons/com.x.png",
        Some("https://fdroid.test/repo"),
        None,
    );

    let all = service_with_real_fallback(&db).aggregate_all().unwrap();

    assert_eq!(all.len(), 1);
    assert_eq!(all[0].metadata_state, MetadataState::FromChannelStore);
    assert_eq!(all[0].app.name, "Example App");
    assert_eq!(
        all[0].app.icon, "https://fdroid.test/repo/icons/com.x.png",
        "relative repo asset keys must be joined to the row's source"
    );
}

/// `source_id` missing but `extra.sourceId` carries the source URL.
#[test]
fn fallback_uses_extra_source_id_when_column_is_missing() {
    let dir = TempDir::new("extra_source");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "fdroid", "com.extra", 3000);
    insert_channel_app(
        &db,
        "fdroid",
        "com.extra",
        "icons/com.extra.png",
        None,
        Some(r#"{"sourceId":"https://fdroid.test/repo"}"#),
    );

    let all = service_with_real_fallback(&db).aggregate_all().unwrap();

    assert_eq!(
        all[0].app.icon,
        "https://fdroid.test/repo/icons/com.extra.png"
    );
}

/// Without any source hint the row is still served, with the icon untouched.
#[test]
fn fallback_leaves_icon_when_no_source_is_available() {
    let dir = TempDir::new("no_source");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "fdroid", "com.nosource", 3000);
    insert_channel_app(
        &db,
        "fdroid",
        "com.nosource",
        "icons/com.nosource.png",
        None,
        None,
    );

    let all = service_with_real_fallback(&db).aggregate_all().unwrap();

    assert_eq!(all.len(), 1);
    assert_eq!(all[0].app.icon, "icons/com.nosource.png");
}

/// An already-absolute icon is never re-based.
#[test]
fn fallback_keeps_absolute_icon_verbatim() {
    let dir = TempDir::new("absolute");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "fdroid", "com.abs", 3000);
    insert_channel_app(
        &db,
        "fdroid",
        "com.abs",
        "https://cdn.example.test/com.abs.png",
        Some("https://fdroid.test/repo"),
        None,
    );

    let all = service_with_real_fallback(&db).aggregate_all().unwrap();

    assert_eq!(all[0].app.icon, "https://cdn.example.test/com.abs.png");
}

/// The resolution is generic: any channel row carrying a source URL gets the
/// same treatment, not just the `fdroid` key.
#[test]
fn fallback_resolves_icon_for_any_channel_with_source_url() {
    let dir = TempDir::new("generic");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "js_lane", "js-1", 3000);
    insert_channel_app(
        &db,
        "js_lane",
        "js-1",
        "/repo/icons/js-1.png",
        Some("https://repo.example.test/base"),
        None,
    );

    let all = service_with_real_fallback(&db).aggregate_all().unwrap();

    assert_eq!(
        all[0].app.icon,
        "https://repo.example.test/base/icons/js-1.png"
    );
}

/// TASK 3 witness: the F-Droid driver's own read path already rebuilds stored
/// relative keys into absolute URLs (`summary_from_stored` -> `absolute_icon_url`),
/// so the driver is not the culprit and must stay that way.
#[test]
fn fdroid_driver_get_app_info_returns_absolute_icon_for_stored_row() {
    let dir = TempDir::new("driver_absolute");
    let db = DbHandle::open(dir.path()).unwrap();
    insert_channel_app(
        &db,
        "fdroid",
        "com.driver",
        "icons/com.driver.png",
        Some("https://fdroid.test/repo"),
        None,
    );

    let config = CoreConfig::default()
        .with_fdroid_sources(vec!["https://fdroid.test/repo".to_string()])
        .unwrap();
    let repo = Arc::new(FakeRepoPort::new(dir.path().join("repo.db")));
    let driver = FdroidDriver::new(
        ChannelKey::new("fdroid").unwrap(),
        meta(ChannelKind::Fdroid, "F-Droid"),
        db,
        config,
        repo,
    );

    let info = driver.get_app_info("com.driver", false).unwrap();

    assert_eq!(info.icon, "https://fdroid.test/repo/icons/com.driver.png");
}
