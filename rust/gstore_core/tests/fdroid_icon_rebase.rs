//! Regression for the stale source/mirror prefix on stored F-Droid icons.
//!
//! F-Droid icons reach `channel_apps` in three shapes: a repo-relative key
//! (`icons/<pkg>.png`, what `FdroidDriver::add_app` writes for a known host), an
//! absolute URL on a third-party CDN host (kept verbatim), and — from the legacy
//! Dart lane and from backups exported while a mirror was current — an ABSOLUTE
//! URL prefixed with the source/mirror base of that moment.
//!
//! `normalize_repo_asset_path` + `join_repo_url` both pass absolute URLs through
//! verbatim, so the last shape used to keep a stale prefix on home/discovery
//! forever while the detail page (index-based) showed the right icon.
//!
//! The invariant: an absolute icon whose host is a known source/mirror base is
//! re-based onto the CURRENT source; an unknown-host icon and an already-current
//! icon are byte-identical; relative keys and the empty fallback still resolve
//! against the current source.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::channel::{ChannelDriver, FdroidDriver};
use gstore_core::channel_migration::{repair_fdroid_source_identities, ChannelMigrator};
use gstore_core::db::{DbError, DbHandle};
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta};
use gstore_core::error::Error;
use gstore_core::ports::{CoreConfig, InMemorySecretPort, RepoApp, RepoMeta, RepoPort};
use rusqlite::Connection;
use serde_json::json;

const CURRENT: &str = "https://f-droid.org/repo";
const OLD_MIRROR: &str = "https://old-mirror.example/repo";
const CDN_ICON: &str = "https://cdn.example.net/icons/com.x.png";
const APP_ID: &str = "com.x";
const STALE_ICON: &str = "https://old-mirror.example/repo/icons/com.x.png";
const CURRENT_ICON: &str = "https://f-droid.org/repo/icons/com.x.png";
const RELATIVE_ICON: &str = "icons/com.x.png";

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_fdroid_icon_rebase_{tag}_{}_{}",
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

/// Repository with no local app: every lookup misses, so the stored icon is the
/// only source of truth (the "empty icon" and "no index" states).
struct EmptyIndexRepo;

impl EmptyIndexRepo {
    fn repo_meta(&self, source: &str) -> RepoMeta {
        RepoMeta {
            source: source.to_string(),
            name: "Test".to_string(),
            description: None,
            version: None,
            timestamp: None,
            app_count: 0,
        }
    }
}

impl RepoPort for EmptyIndexRepo {
    fn download_repo(&self, source: &str) -> Result<RepoMeta, Error> {
        Ok(self.repo_meta(source))
    }

    fn get_app_count(&self, _source: &str) -> Result<u64, Error> {
        Ok(0)
    }

    fn search_apps(&self, _source: &str, _query: &str, _limit: usize) -> Result<Vec<RepoApp>, Error> {
        Ok(Vec::new())
    }

    fn get_repo_meta(&self, source: &str) -> Result<Option<RepoMeta>, Error> {
        Ok(Some(self.repo_meta(source)))
    }

    fn clear_apps(&self, _source: &str) -> Result<(), Error> {
        Ok(())
    }

    fn get_one_app(&self, _source: &str, _package_name: &str) -> Result<Option<RepoApp>, Error> {
        Ok(None)
    }

    fn db_path(&self) -> &Path {
        Path::new("/tmp/gstore-fdroid-icon-rebase-empty.db")
    }
}

fn driver(db: &DbHandle, sources: &[&str], bases: &[&str]) -> FdroidDriver {
    let config = CoreConfig::default()
        .with_fdroid_sources(sources.iter().map(ToString::to_string).collect())
        .unwrap()
        .with_fdroid_asset_bases(bases.iter().map(ToString::to_string).collect());
    FdroidDriver::new(
        ChannelKey::new("fdroid").unwrap(),
        meta(ChannelKind::Fdroid, "F-Droid"),
        db.clone(),
        config,
        Arc::new(EmptyIndexRepo),
    )
}

fn seed_row(db: &DbHandle, icon: &str, source_id: Option<&str>) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,icon,\
             description,category,add_time,source_id) \
             VALUES ('fdroid',?1,'Example','','com.x',?2,'summary','Tools',1700000000000,?3)",
            rusqlite::params![APP_ID, icon, source_id],
        )
        .map_err(|error| DbError(error.to_string()))?;
        Ok(())
    })
    .unwrap();
}

fn stored_icon_and_source(db: &DbHandle, app_id: &str) -> (String, Option<String>) {
    db.with_reader(|conn| {
        conn.query_row(
            "SELECT icon, source_id FROM channel_apps WHERE channel_key='fdroid' AND app_id=?1",
            [app_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|error| DbError(error.to_string()))
    })
    .unwrap()
}

fn summary(icon: &str, extra: serde_json::Value) -> AppSummary {
    AppSummary {
        app_id: APP_ID.to_string(),
        package_name: Some(APP_ID.to_string()),
        name: "Example".to_string(),
        user: String::new(),
        repositories: APP_ID.to_string(),
        icon: icon.to_string(),
        des: "summary".to_string(),
        readme: None,
        category: Some(vec!["Tools".to_string()]),
        extra: extra.as_object().cloned(),
        labels: Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// read path: home/discovery resolves against the CURRENT source
// ---------------------------------------------------------------------------

#[test]
fn stale_mirror_absolute_icon_is_rebased_on_home_and_discovery() {
    let dir = TempDir::new("stale");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_row(&db, STALE_ICON, None);
    let driver = driver(&db, &[CURRENT], &[OLD_MIRROR]);

    let info = driver.get_app_info(APP_ID, false).unwrap();
    println!("stale get_app_info.icon={}", info.icon);
    assert_eq!(info.icon, CURRENT_ICON);

    let listed = driver.get_all_apps(false).unwrap();
    println!("stale get_all_apps={listed:?}");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].icon, CURRENT_ICON);
}

#[test]
fn stale_prefix_is_rebased_even_when_the_row_names_an_active_source() {
    let dir = TempDir::new("stale_named_source");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_row(&db, STALE_ICON, Some(CURRENT));
    let driver = driver(&db, &[CURRENT], &[OLD_MIRROR]);

    assert_eq!(
        driver.get_app_info(APP_ID, false).unwrap().icon,
        CURRENT_ICON
    );
}

#[test]
fn absolute_icon_under_the_current_source_is_unchanged() {
    let dir = TempDir::new("current");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_row(&db, CURRENT_ICON, None);
    let driver = driver(&db, &[CURRENT], &[OLD_MIRROR]);

    assert_eq!(
        driver.get_app_info(APP_ID, false).unwrap().icon,
        CURRENT_ICON
    );
    assert_eq!(driver.get_all_apps(false).unwrap()[0].icon, CURRENT_ICON);
}

#[test]
fn third_party_cdn_icon_is_preserved_verbatim() {
    let dir = TempDir::new("cdn");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_row(&db, CDN_ICON, None);
    let driver = driver(&db, &[CURRENT], &[OLD_MIRROR]);

    assert_eq!(
        driver.get_app_info(APP_ID, false).unwrap().icon,
        CDN_ICON,
        "a CDN host is not a source/mirror and must never be re-based"
    );
    assert_eq!(driver.get_all_apps(false).unwrap()[0].icon, CDN_ICON);
}

#[test]
fn relative_key_still_joins_the_current_source() {
    let dir = TempDir::new("relative");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_row(&db, RELATIVE_ICON, None);
    let driver = driver(&db, &[CURRENT], &[OLD_MIRROR]);

    assert_eq!(
        driver.get_app_info(APP_ID, false).unwrap().icon,
        CURRENT_ICON
    );
}

#[test]
fn empty_icon_still_falls_back_to_the_default_icon_on_the_current_source() {
    let dir = TempDir::new("empty");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_row(&db, "", None);
    let driver = driver(&db, &[CURRENT], &[OLD_MIRROR]);

    assert_eq!(
        driver.get_app_info(APP_ID, false).unwrap().icon,
        "https://f-droid.org/repo/icons/com.x.png"
    );
}

// ---------------------------------------------------------------------------
// write path: a stale prefix is not baked in again
// ---------------------------------------------------------------------------

#[test]
fn restore_stores_a_relative_key_when_the_icon_carries_a_known_mirror_prefix() {
    let dir = TempDir::new("restore_stale");
    let db = DbHandle::open(dir.path()).unwrap();
    let driver = driver(&db, &[CURRENT], &[OLD_MIRROR]);

    driver
        .add_app(&summary(STALE_ICON, json!({"sourceId": CURRENT})))
        .unwrap();

    let (icon, source) = stored_icon_and_source(&db, APP_ID);
    assert_eq!(icon, RELATIVE_ICON, "the stale prefix must not be stored");
    assert_eq!(source.as_deref(), Some(CURRENT));
    assert_eq!(
        driver.get_app_info(APP_ID, false).unwrap().icon,
        CURRENT_ICON
    );
}

#[test]
fn restore_keeps_a_third_party_cdn_icon_verbatim() {
    let dir = TempDir::new("restore_cdn");
    let db = DbHandle::open(dir.path()).unwrap();
    let driver = driver(&db, &[CURRENT], &[OLD_MIRROR]);

    driver
        .add_app(&summary(CDN_ICON, json!({"sourceId": CURRENT})))
        .unwrap();

    assert_eq!(stored_icon_and_source(&db, APP_ID).0, CDN_ICON);
    assert_eq!(
        driver.get_app_info(APP_ID, false).unwrap().icon,
        CDN_ICON
    );
}

// ---------------------------------------------------------------------------
// cutover migration: existing absolute rows are healed, idempotently
// ---------------------------------------------------------------------------

fn write_legacy_db(path: &Path, icon: &str, source_id: &str) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE channel_added_app (
             appId TEXT NOT NULL,
             name TEXT NOT NULL,
             user TEXT NOT NULL,
             repositories TEXT NOT NULL,
             apprepo TEXT,
             icon TEXT NOT NULL,
             description TEXT NOT NULL,
             category TEXT,
             addTime INTEGER NOT NULL,
             channelCode TEXT NOT NULL,
             extra TEXT,
             sourceId TEXT,
             PRIMARY KEY (channelCode, appId)
         );
         PRAGMA user_version = 5;",
    )
    .unwrap();
    conn.execute(
        "INSERT INTO channel_added_app(appId,name,user,repositories,apprepo,icon,\
         description,category,addTime,channelCode,extra,sourceId) \
         VALUES (?1,'Example','owner','com.x',NULL,?2,'description','Tools',1700000000000,'fdroid',NULL,?3)",
        rusqlite::params![APP_ID, icon, source_id],
    )
    .unwrap();
}

fn import_sources_with_mirror(core: &DbHandle, root: &Path) {
    let doc = json!({
        "version": 1,
        "sources": [
            {
                "id": "official",
                "name": "Official",
                "repoUrl": CURRENT,
                "mirrors": [OLD_MIRROR]
            }
        ],
        "last_source_id": "official"
    });
    let secrets = InMemorySecretPort::new();
    let conn = core.writer().unwrap();
    let migrator = ChannelMigrator::new(&conn, &secrets, root.join("backups"));
    migrator.import_fdroid_sources(&doc).unwrap();
}

fn import_legacy_row(core: &DbHandle, legacy: &Path, root: &Path) -> usize {
    let secrets = InMemorySecretPort::new();
    let conn = core.writer().unwrap();
    let migrator = ChannelMigrator::new(&conn, &secrets, root.join("backups"));
    migrator.import_channel_db(legacy).unwrap().rows_imported
}

#[test]
fn cutover_rebases_a_stale_absolute_icon_and_stays_idempotent() {
    let dir = TempDir::new("cutover");
    let core = DbHandle::open(dir.path()).unwrap();
    import_sources_with_mirror(&core, dir.path());
    let legacy = dir.path().join("channel_apps.db");
    write_legacy_db(&legacy, STALE_ICON, "official");
    assert_eq!(import_legacy_row(&core, &legacy, dir.path()), 1);

    let (icon, source) = stored_icon_and_source(&core, APP_ID);
    println!("cutover icon={icon} source={source:?}");
    assert_eq!(source.as_deref(), Some(CURRENT));
    assert_eq!(icon, CURRENT_ICON, "the stale mirror prefix must be dropped");

    let conn = core.writer().unwrap();
    assert_eq!(
        repair_fdroid_source_identities(&conn).unwrap(),
        0,
        "a repaired row must not be rewritten again on the next source push"
    );
}

#[test]
fn cutover_preserves_a_third_party_cdn_icon() {
    let dir = TempDir::new("cutover_cdn");
    let core = DbHandle::open(dir.path()).unwrap();
    import_sources_with_mirror(&core, dir.path());
    let legacy = dir.path().join("channel_apps.db");
    write_legacy_db(&legacy, CDN_ICON, "official");
    assert_eq!(import_legacy_row(&core, &legacy, dir.path()), 1);

    assert_eq!(stored_icon_and_source(&core, APP_ID).0, CDN_ICON);
}
