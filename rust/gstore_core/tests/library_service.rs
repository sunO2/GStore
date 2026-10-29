//! `LibraryService` write-path tests: metadata-first add, local-db/unsupported
//! tolerance, failure without membership, toggle/remove separation, and
//! canonical membership ids.
//!
//! Tests drive real drivers (GitHubDB / local-db) over a real migrated core
//! database, so they assert on observable rows (`channel_apps`, `added_apps`)
//! instead of internals.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::added::apps::AddedAppsService;
use gstore_core::channel::{ChannelDriver, GitHubDriver, LocalDbDriver};
use gstore_core::db::DbHandle;
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta};
use gstore_core::error::Error;
use gstore_core::library::{LibraryDriverResolver, LibraryService};
use gstore_core::ports::{
    CoreConfig, FakeHttpPort, FakeMetadataPort, MetadataPort, PackageMetadata,
};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_library_{tag}_{}_{}",
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

fn summary(app_id: &str) -> AppSummary {
    let (user, repositories) = match app_id.split_once('/') {
        Some((user, repo)) => (user.to_string(), repo.to_string()),
        None => (String::new(), String::new()),
    };
    AppSummary {
        app_id: app_id.to_string(),
        package_name: None,
        name: app_id.to_string(),
        user,
        repositories,
        icon: String::new(),
        des: format!("{app_id} description"),
        readme: None,
        category: None,
        extra: None,
        labels: Vec::new(),
    }
}

struct Resolver {
    drivers: BTreeMap<String, Arc<dyn ChannelDriver>>,
}

impl Resolver {
    fn new(drivers: Vec<Arc<dyn ChannelDriver>>) -> Self {
        Self {
            drivers: drivers
                .into_iter()
                .map(|driver| (driver.key().as_str().to_string(), driver))
                .collect(),
        }
    }
}

impl LibraryDriverResolver for Resolver {
    fn writable_driver(&self, channel: &str) -> Option<Arc<dyn ChannelDriver>> {
        self.drivers.get(channel).cloned()
    }
}

fn github_driver(db: DbHandle, metadata: Arc<dyn MetadataPort>) -> Arc<dyn ChannelDriver> {
    Arc::new(GitHubDriver::new(
        ChannelKey::new("github").unwrap(),
        meta("github", ChannelKind::Github),
        db,
        CoreConfig::new(None, None).unwrap(),
        Arc::new(FakeHttpPort::new()),
        metadata,
    ))
}

fn local_driver(db: DbHandle) -> Arc<dyn ChannelDriver> {
    Arc::new(LocalDbDriver::new(
        ChannelKey::new("local_db").unwrap(),
        meta("local_db", ChannelKind::LocalDb),
        db,
    ))
}

fn service(db: &DbHandle, drivers: Vec<Arc<dyn ChannelDriver>>) -> LibraryService {
    LibraryService::new(
        AddedAppsService::new(db.clone()),
        Arc::new(Resolver::new(drivers)),
    )
}

fn channel_apps_count(db: &DbHandle, channel: &str) -> i64 {
    let conn = db.reader().unwrap();
    conn.query_row(
        "SELECT COUNT(*) FROM channel_apps WHERE channel_key=?1",
        [channel],
        |row| row.get(0),
    )
    .unwrap()
}

fn channel_apps_ids(db: &DbHandle, channel: &str) -> Vec<String> {
    let conn = db.reader().unwrap();
    let mut stmt = conn
        .prepare("SELECT app_id FROM channel_apps WHERE channel_key=?1 ORDER BY app_id")
        .unwrap();
    let rows = stmt
        .query_map([channel], |row| row.get(0))
        .unwrap()
        .collect::<Result<Vec<String>, _>>()
        .unwrap();
    rows
}

fn channel_apps_metadata(db: &DbHandle, channel: &str, app_id: &str) -> (String, String) {
    let conn = db.reader().unwrap();
    conn.query_row(
        "SELECT name, icon FROM channel_apps WHERE channel_key=?1 AND app_id=?2",
        rusqlite::params![channel, app_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .unwrap()
}

fn package_metadata(package_name: &str) -> PackageMetadata {
    PackageMetadata {
        package_name: Some(package_name.to_string()),
        app_name: None,
        icon_url: None,
        version_name: None,
    }
}

#[test]
fn library_add_writes_channel_metadata_and_membership() {
    let dir = TempDir::new("add_both");
    let db = DbHandle::open(dir.path()).unwrap();
    let driver = github_driver(db.clone(), Arc::new(FakeMetadataPort::new()));
    let service = service(&db, vec![driver.clone()]);

    let app = summary("acme/repo");
    let added = service.add("github", &app, Some(7)).unwrap();

    assert_eq!(added.app_id, "acme/repo");
    assert_eq!(added.sort_order, 7);
    assert_eq!(channel_apps_ids(&db, "github"), vec!["acme/repo"]);
    let saved = driver.get_all_apps(false).unwrap();
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0].app_id, "acme/repo");
    assert!(service.is_added("github", "acme/repo").unwrap());
    assert_eq!(service.total_count().unwrap(), 1);
}

#[test]
fn library_add_without_driver_still_writes_membership() {
    let dir = TempDir::new("no_driver");
    let db = DbHandle::open(dir.path()).unwrap();
    let service = service(&db, Vec::new());

    let added = service.add("ghost", &summary("orphan"), None).unwrap();

    assert_eq!(added.app_id, "orphan");
    assert!(service.is_added("ghost", "orphan").unwrap());
    assert_eq!(service.total_count().unwrap(), 1);
    assert_eq!(channel_apps_count(&db, "ghost"), 0);
}

#[test]
fn library_add_tolerates_unsupported_local_db_metadata() {
    let dir = TempDir::new("unsupported");
    let db = DbHandle::open(dir.path()).unwrap();
    let service = service(&db, vec![local_driver(db.clone())]);

    let added = service
        .add("local_db", &summary("com.local.app"), None)
        .unwrap();

    assert_eq!(added.app_id, "com.local.app");
    assert!(service.is_added("local_db", "com.local.app").unwrap());
    assert_eq!(service.total_count().unwrap(), 1);
    assert_eq!(channel_apps_count(&db, "local_db"), 0);
}

#[test]
fn library_add_propagates_driver_error_without_membership() {
    let dir = TempDir::new("error");
    let db = DbHandle::open(dir.path()).unwrap();

    let broken_dir = TempDir::new("error_driver");
    let broken_db = DbHandle::open(broken_dir.path()).unwrap();
    {
        let conn = broken_db.writer().unwrap();
        conn.execute_batch("DROP TABLE channel_apps;").unwrap();
    }
    let driver = github_driver(broken_db, Arc::new(FakeMetadataPort::new()));
    let service = service(&db, vec![driver]);

    let error = service
        .add("github", &summary("acme/repo"), None)
        .unwrap_err();

    assert!(matches!(error, Error::Io(_)), "unexpected error: {error}");
    assert!(!service.is_added("github", "acme/repo").unwrap());
    assert_eq!(service.total_count().unwrap(), 0);
    assert_eq!(channel_apps_count(&db, "github"), 0);
}

#[test]
fn library_toggle_round_trips_without_deleting_channel_apps() {
    let dir = TempDir::new("toggle");
    let db = DbHandle::open(dir.path()).unwrap();
    let driver = github_driver(db.clone(), Arc::new(FakeMetadataPort::new()));
    let service = service(&db, vec![driver]);

    let app = summary("acme/repo");
    assert!(service.toggle("github", &app).unwrap());
    assert!(service.is_added("github", "acme/repo").unwrap());
    assert_eq!(channel_apps_ids(&db, "github"), vec!["acme/repo"]);

    assert!(!service.toggle("github", &app).unwrap());
    assert!(!service.is_added("github", "acme/repo").unwrap());
    assert_eq!(service.total_count().unwrap(), 0);
    assert_eq!(
        channel_apps_ids(&db, "github"),
        vec!["acme/repo"],
        "remove keeps the channel's saved row"
    );
}

#[test]
fn library_add_uses_driver_canonical_app_id_for_membership() {
    let dir = TempDir::new("canonical");
    let db = DbHandle::open(dir.path()).unwrap();
    let metadata = FakeMetadataPort::new();
    metadata.set("acme", "repo", Some(package_metadata("com.example.pkg")));
    let driver = github_driver(db.clone(), Arc::new(metadata));
    let service = service(&db, vec![driver]);

    let added = service.add("github", &summary("acme/repo"), None).unwrap();

    assert_eq!(added.app_id, "com.example.pkg");
    assert!(service.is_added("github", "com.example.pkg").unwrap());
    assert!(!service.is_added("github", "acme/repo").unwrap());
    assert_eq!(
        channel_apps_ids(&db, "github"),
        vec!["acme/repo"],
        "channel metadata keeps the channel-native id"
    );
}

#[test]
fn library_add_membership_leaves_existing_channel_apps_row_untouched() {
    let dir = TempDir::new("membership_only");
    let db = DbHandle::open(dir.path()).unwrap();
    let driver = github_driver(db.clone(), Arc::new(FakeMetadataPort::new()));
    let service = service(&db, vec![driver.clone()]);

    // Seed a GOOD channel_apps row through the normal metadata path.
    let mut real = summary("acme/repo");
    real.name = "Real App Name".to_string();
    real.icon = "https://icons.example/real.png".to_string();
    driver.add_app(&real).unwrap();
    assert_eq!(
        channel_apps_metadata(&db, "github", "acme/repo"),
        (
            "Real App Name".to_string(),
            "https://icons.example/real.png".to_string()
        )
    );

    // A reference-only backup item must only restore membership.
    let added = service
        .add_membership("github", "acme/repo", Some(3))
        .unwrap();

    assert_eq!(added.app_id, "acme/repo");
    assert_eq!(added.sort_order, 3);
    assert!(service.is_added("github", "acme/repo").unwrap());
    assert_eq!(channel_apps_count(&db, "github"), 1);
    assert_eq!(
        channel_apps_metadata(&db, "github", "acme/repo"),
        (
            "Real App Name".to_string(),
            "https://icons.example/real.png".to_string()
        ),
        "add_membership must never downgrade a channel_apps metadata row"
    );
}
