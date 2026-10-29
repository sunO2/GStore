//! Regression: the F-Droid **list** path (home / discovery / GStore channel)
//! must resolve icons the same way the **detail** page does.
//!
//! Detail reads `get_one_app` from the repository index and builds the icon
//! from that entry. List used to trust the stored `channel_apps.icon` whenever
//! it already looked absolute, so a dead/insecure absolute URL, an empty icon,
//! or the default `icons/<pkg>.png` key shadowed the index's real (versioned)
//! asset forever.
//!
//! Invariant: `get_all_apps` / `get_app_info` return exactly the icon
//! `get_app_detail` returns whenever the index carries an absolute icon; the
//! rebased stored icon is only a fallback when the index has nothing.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::channel::{ChannelDriver, FdroidDriver};
use gstore_core::db::{DbError, DbHandle};
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta};
use gstore_core::error::Error;
use gstore_core::ports::{CoreConfig, FakeRepoPort, RepoApp, RepoMeta, RepoPort};

const SOURCE: &str = "https://f-droid.org/repo";
const OLD_MIRROR: &str = "https://old-mirror.example/repo";
const APP_ID: &str = "com.x";
const DEAD_ICON: &str = "https://dead.example/repo/icons/com.x.png";
const INDEX_ICON_KEY: &str = "icons/com.x.123.png";
const EXPECTED_ICON: &str = "https://f-droid.org/repo/icons/com.x.123.png";
const RELATIVE_ICON: &str = "icons/com.x.png";

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_fdroid_icon_index_first_{tag}_{}_{}",
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

fn repo_meta(source: &str) -> RepoMeta {
    RepoMeta {
        source: source.to_string(),
        name: "Test".to_string(),
        description: None,
        version: None,
        timestamp: None,
        app_count: 0,
    }
}

fn repo_app(package_name: &str, icon_key: &str) -> RepoApp {
    RepoApp {
        package_name: package_name.to_string(),
        name: format!("App {package_name}"),
        summary: "summary".to_string(),
        version: Some("1.0".to_string()),
        version_code: Some(1),
        icon: Some(icon_key.to_string()),
        apk_url: None,
        size: None,
        categories: vec!["Tools".to_string()],
        metadata: None,
    }
}

/// Counts the index probes that matter for the performance contract:
/// `get_one_app` lookups and `get_repo_meta` calls made by
/// `ensure_active_index`.
struct CountingRepo {
    inner: FakeRepoPort,
    one_app_calls: AtomicU64,
    meta_calls: AtomicU64,
}

impl CountingRepo {
    fn new(inner: FakeRepoPort) -> Self {
        Self {
            inner,
            one_app_calls: AtomicU64::new(0),
            meta_calls: AtomicU64::new(0),
        }
    }

    fn one_app_calls(&self) -> u64 {
        self.one_app_calls.load(Ordering::SeqCst)
    }

    fn meta_calls(&self) -> u64 {
        self.meta_calls.load(Ordering::SeqCst)
    }
}

impl RepoPort for CountingRepo {
    fn download_repo(&self, source: &str) -> Result<RepoMeta, Error> {
        self.inner.download_repo(source)
    }

    fn get_app_count(&self, source: &str) -> Result<u64, Error> {
        self.inner.get_app_count(source)
    }

    fn search_apps(
        &self,
        source: &str,
        query: &str,
        limit: usize,
    ) -> Result<Vec<RepoApp>, Error> {
        self.inner.search_apps(source, query, limit)
    }

    fn get_repo_meta(&self, source: &str) -> Result<Option<RepoMeta>, Error> {
        self.meta_calls.fetch_add(1, Ordering::SeqCst);
        self.inner.get_repo_meta(source)
    }

    fn clear_apps(&self, source: &str) -> Result<(), Error> {
        self.inner.clear_apps(source)
    }

    fn get_one_app(&self, source: &str, package_name: &str) -> Result<Option<RepoApp>, Error> {
        self.one_app_calls.fetch_add(1, Ordering::SeqCst);
        self.inner.get_one_app(source, package_name)
    }

    fn db_path(&self) -> &Path {
        self.inner.db_path()
    }
}

fn driver(
    db: &DbHandle,
    repo: Arc<CountingRepo>,
    sources: &[&str],
    bases: &[&str],
) -> FdroidDriver {
    let config = CoreConfig::default()
        .with_fdroid_sources(sources.iter().map(ToString::to_string).collect())
        .unwrap()
        .with_fdroid_asset_bases(bases.iter().map(ToString::to_string).collect());
    FdroidDriver::new(
        ChannelKey::new("fdroid").unwrap(),
        meta(ChannelKind::Fdroid, "F-Droid"),
        db.clone(),
        config,
        repo,
    )
}

fn seeded_repo(apps: &[(&str, &str)]) -> CountingRepo {
    let inner = FakeRepoPort::new("/tmp/gstore-fdroid-icon-index-first.db");
    inner.add_repo(repo_meta(SOURCE));
    for (app_id, icon_key) in apps {
        inner.add_app(SOURCE, repo_app(app_id, icon_key));
    }
    CountingRepo::new(inner)
}

fn seed_row(db: &DbHandle, app_id: &str, icon: &str, source_id: Option<&str>) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,icon,\
             description,category,add_time,source_id) \
             VALUES ('fdroid',?1,?2,'','',?3,'summary','Tools',1700000000000,?4)",
            rusqlite::params![app_id, format!("App {app_id}"), icon, source_id],
        )
        .map_err(|error| DbError(error.to_string()))?;
        Ok(())
    })
    .unwrap();
}

fn summary(icon: &str) -> AppSummary {
    AppSummary {
        app_id: APP_ID.to_string(),
        package_name: Some(APP_ID.to_string()),
        name: "App".to_string(),
        user: String::new(),
        repositories: APP_ID.to_string(),
        icon: icon.to_string(),
        des: "summary".to_string(),
        readme: None,
        category: Some(vec!["Tools".to_string()]),
        extra: Some(
            [("sourceId".to_string(), serde_json::json!(SOURCE))]
                .into_iter()
                .collect(),
        ),
        labels: Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// RED before the fix: a dead absolute stored icon won the list path.
// ---------------------------------------------------------------------------

#[test]
fn dead_absolute_stored_icon_is_replaced_by_the_index_on_list_and_detail() {
    let dir = TempDir::new("dead_absolute");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_row(&db, APP_ID, DEAD_ICON, Some(SOURCE));
    let repo = Arc::new(seeded_repo(&[(APP_ID, INDEX_ICON_KEY)]));
    let driver = driver(&db, repo.clone(), &[SOURCE], &[]);

    let detail = driver.get_app_detail(APP_ID, false).unwrap();
    println!("dead-absolute get_app_detail.icon={}", detail.icon);
    assert_eq!(detail.icon, EXPECTED_ICON);

    let info = driver.get_app_info(APP_ID, false).unwrap();
    println!("dead-absolute get_app_info.icon={}", info.icon);
    assert_eq!(
        info.icon, detail.icon,
        "the list read must match the detail page, not the dead stored URL"
    );

    let listed = driver.get_all_apps(false).unwrap();
    assert_eq!(listed.len(), 1);
    println!("dead-absolute get_all_apps.icon={}", listed[0].icon);
    assert_eq!(listed[0].icon, detail.icon);
}

#[test]
fn empty_stored_icon_resolves_to_the_index_icon() {
    let dir = TempDir::new("empty");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_row(&db, APP_ID, "", Some(SOURCE));
    let repo = Arc::new(seeded_repo(&[(APP_ID, INDEX_ICON_KEY)]));
    let driver = driver(&db, repo.clone(), &[SOURCE], &[]);

    assert_eq!(
        driver.get_app_info(APP_ID, false).unwrap().icon,
        EXPECTED_ICON
    );
    assert_eq!(driver.get_all_apps(false).unwrap()[0].icon, EXPECTED_ICON);
}

#[test]
fn new_added_row_resolves_to_the_index_icon() {
    let dir = TempDir::new("new_add");
    let db = DbHandle::open(dir.path()).unwrap();
    let repo = Arc::new(seeded_repo(&[(APP_ID, INDEX_ICON_KEY)]));
    let driver = driver(&db, repo.clone(), &[SOURCE], &[]);

    driver.add_app(&summary(RELATIVE_ICON)).unwrap();
    assert_eq!(
        driver.get_app_info(APP_ID, false).unwrap().icon,
        EXPECTED_ICON,
        "a just-searched row must render the same icon the detail page shows"
    );
}

// ---------------------------------------------------------------------------
// Index miss: the rebased stored icon remains the fallback.
// ---------------------------------------------------------------------------

#[test]
fn missing_index_entry_falls_back_to_the_rebased_stored_icon() {
    let dir = TempDir::new("index_miss");
    let db = DbHandle::open(dir.path()).unwrap();
    let stale = format!("{OLD_MIRROR}/{RELATIVE_ICON}");
    seed_row(&db, APP_ID, &stale, Some(SOURCE));
    let repo = Arc::new(seeded_repo(&[]));
    let driver = driver(&db, repo.clone(), &[SOURCE], &[OLD_MIRROR]);

    assert_eq!(
        driver.get_app_info(APP_ID, false).unwrap().icon,
        "https://f-droid.org/repo/icons/com.x.png",
        "no index entry -> the stored icon is rebased onto the current source"
    );
    assert_eq!(
        driver.get_all_apps(false).unwrap()[0].icon,
        "https://f-droid.org/repo/icons/com.x.png"
    );
}

#[test]
fn list_survives_an_unavailable_index_without_crashing() {
    let dir = TempDir::new("no_index_meta");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_row(&db, APP_ID, RELATIVE_ICON, Some(SOURCE));
    // No repo metadata and no apps: every index probe misses, `ensure` fails.
    let repo = Arc::new(CountingRepo::new(FakeRepoPort::new(
        "/tmp/gstore-fdroid-icon-index-first-empty.db",
    )));
    let driver = driver(&db, repo.clone(), &[SOURCE], &[]);

    let listed = driver.get_all_apps(false).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].icon, "https://f-droid.org/repo/icons/com.x.png");
}

// ---------------------------------------------------------------------------
// Performance: one `ensure_active_index` per list, one probe per app.
// ---------------------------------------------------------------------------

#[test]
fn large_list_runs_the_index_guard_once_and_probes_each_app_once() {
    const ROWS: usize = 500;
    let dir = TempDir::new("large_list");
    let db = DbHandle::open(dir.path()).unwrap();
    db.with_writer(|conn| {
        for index in 0..ROWS {
            conn.execute(
                "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,icon,\
                 description,category,add_time,source_id) \
                 VALUES ('fdroid',?1,?2,'','',?3,'summary','Tools',?4,?5)",
                rusqlite::params![
                    format!("com.bulk{index:04}"),
                    format!("Bulk {index}"),
                    RELATIVE_ICON,
                    1_700_000_000_000i64 + index as i64,
                    SOURCE
                ],
            )
            .map_err(|error| DbError(error.to_string()))?;
        }
        Ok(())
    })
    .unwrap();

    // Index present but empty: every probe misses, so `ensure` is what must
    // stay once-per-list instead of once-per-row.
    let repo = Arc::new(seeded_repo(&[]));
    let driver = driver(&db, repo.clone(), &[SOURCE], &[]);

    let started = std::time::Instant::now();
    let listed = driver.get_all_apps(false).unwrap();
    let elapsed = started.elapsed();
    println!(
        "large-list rows={} elapsed={elapsed:?} one_app_calls={} meta_calls={}",
        listed.len(),
        repo.one_app_calls(),
        repo.meta_calls()
    );

    assert_eq!(listed.len(), ROWS);
    assert!(
        listed
            .iter()
            .all(|app| app.icon == "https://f-droid.org/repo/icons/com.x.png"),
        "every unmatched row still gets its rebased stored icon"
    );
    assert_eq!(
        repo.meta_calls(),
        1,
        "ensure_active_index must run once for the whole list, not per row"
    );
    assert!(
        repo.one_app_calls() <= (ROWS as u64) * 2,
        "each app is probed at most twice (pre/post ensure), got {}",
        repo.one_app_calls()
    );
}
