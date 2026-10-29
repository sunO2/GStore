//! Reproduction + regression for the "detail page shows the F-Droid icon but
//! the restored home/discovery row does not" bug.
//!
//! A RESTORE writes a `channel_apps('fdroid')` row with a **repo-relative**
//! icon (`icons/<pkg>.png`) and a `source_id` that is either `NULL` or a legacy
//! source *identity* (`official`, `fp:<HEX>`), not the configured repo URL.
//!
//! * `get_app_detail` never reads `channel_apps`: it ensures the index and reads
//!   the repository, so its icon was always absolute.
//! * `get_app_info` / `get_all_apps` read the stored row. When the row's
//!   identity matches no active source the row was dropped/left relative, so
//!   the Dart `AppIcon` fell back to the default icon on home/discovery.
//!
//! The invariant: both read paths return an ABSOLUTE icon, with or without a
//! local repository index, and a genuinely disabled source stays excluded.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::channel::{ChannelDriver, FdroidDriver};
use gstore_core::db::{DbError, DbHandle};
use gstore_core::dto::{ChannelKey, ChannelKind, ChannelMeta};
use gstore_core::error::Error;
use gstore_core::ports::{CoreConfig, RepoApp, RepoMeta, RepoPort};

const SOURCE: &str = "https://fdroid.test/repo";
const OTHER_SOURCE: &str = "https://mirror.test/fdroid";
const APP_ID: &str = "com.example.restored";
const ABSOLUTE_ICON: &str = "https://fdroid.test/repo/icons/com.example.restored.png";
const MIRROR_ICON: &str = "https://mirror.test/fdroid/icons/com.example.restored.png";
const RELATIVE_ICON: &str = "icons/com.example.restored.png";

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_fdroid_home_vs_detail_{tag}_{}_{}",
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

/// Repository fake with an explicit "local index present" switch, so the exact
/// (a) NO index / (b) index states can both be exercised.
struct IndexRepo {
    indexed: AtomicBool,
    downloads: AtomicU64,
    one_app_calls: AtomicU64,
    app: RepoApp,
}

impl IndexRepo {
    fn new(indexed: bool) -> Self {
        Self {
            indexed: AtomicBool::new(indexed),
            downloads: AtomicU64::new(0),
            one_app_calls: AtomicU64::new(0),
            app: RepoApp {
                package_name: APP_ID.to_string(),
                name: "Restored App".to_string(),
                summary: "restored summary".to_string(),
                version: Some("1.0".to_string()),
                version_code: Some(1),
                icon: Some(ABSOLUTE_ICON.to_string()),
                apk_url: None,
                size: None,
                categories: vec!["Tools".to_string()],
                metadata: None,
            },
        }
    }

    fn downloads(&self) -> u64 {
        self.downloads.load(Ordering::SeqCst)
    }

    fn one_app_calls(&self) -> u64 {
        self.one_app_calls.load(Ordering::SeqCst)
    }

    fn repo_meta(&self, source: &str) -> RepoMeta {
        RepoMeta {
            source: source.to_string(),
            name: "Test".to_string(),
            description: None,
            version: None,
            timestamp: None,
            app_count: 1,
        }
    }
}

impl RepoPort for IndexRepo {
    fn download_repo(&self, source: &str) -> Result<RepoMeta, Error> {
        if source != SOURCE {
            return Err(Error::NotFound(format!("repo not seeded: {source}")));
        }
        self.downloads.fetch_add(1, Ordering::SeqCst);
        self.indexed.store(true, Ordering::SeqCst);
        Ok(self.repo_meta(source))
    }

    fn get_app_count(&self, _source: &str) -> Result<u64, Error> {
        Ok(u64::from(self.indexed.load(Ordering::SeqCst)))
    }

    fn search_apps(
        &self,
        source: &str,
        _query: &str,
        _limit: usize,
    ) -> Result<Vec<RepoApp>, Error> {
        if source != SOURCE || !self.indexed.load(Ordering::SeqCst) {
            return Ok(Vec::new());
        }
        Ok(vec![self.app.clone()])
    }

    fn get_repo_meta(&self, source: &str) -> Result<Option<RepoMeta>, Error> {
        if source != SOURCE {
            return Ok(None);
        }
        Ok(self
            .indexed
            .load(Ordering::SeqCst)
            .then(|| self.repo_meta(source)))
    }

    fn clear_apps(&self, _source: &str) -> Result<(), Error> {
        Ok(())
    }

    fn get_one_app(&self, source: &str, package_name: &str) -> Result<Option<RepoApp>, Error> {
        self.one_app_calls.fetch_add(1, Ordering::SeqCst);
        if source != SOURCE || package_name != APP_ID || !self.indexed.load(Ordering::SeqCst) {
            return Ok(None);
        }
        Ok(Some(self.app.clone()))
    }

    fn db_path(&self) -> &Path {
        Path::new("/tmp/gstore-fdroid-home-vs-detail-index.db")
    }
}

fn driver(db: &DbHandle, repo: Arc<dyn RepoPort>, sources: &[&str]) -> FdroidDriver {
    let config = CoreConfig::default()
        .with_fdroid_sources(sources.iter().map(ToString::to_string).collect())
        .unwrap();
    FdroidDriver::new(
        ChannelKey::new("fdroid").unwrap(),
        meta(ChannelKind::Fdroid, "F-Droid"),
        db.clone(),
        config,
        repo,
    )
}

/// Writes a row exactly as a RESTORE does: repo-relative icon plus a
/// `source_id`/`extra.sourceId` the driver cannot match to a configured URL.
fn seed_restored_row(db: &DbHandle, icon: &str, source_id: Option<&str>, extra: Option<&str>) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,icon,\
             description,category,add_time,source_id,extra) \
             VALUES ('fdroid',?1,'Restored App','','com.example.restored',?2,\
             'restored summary','Tools',1700000000000,?3,?4)",
            rusqlite::params![APP_ID, icon, source_id, extra],
        )
        .map_err(|error| DbError(error.to_string()))?;
        Ok(())
    })
    .unwrap();
}

fn assert_absolute(icon: &str) {
    assert!(
        icon.starts_with("https://") || icon.starts_with("http://"),
        "home/discovery icon must be absolute, got {icon:?}"
    );
}

// ---------------------------------------------------------------------------
// (a) NO local index: the restored row alone must still yield an absolute icon
// ---------------------------------------------------------------------------

#[test]
fn restored_row_null_source_without_index_is_absolute_on_home_and_detail() {
    let dir = TempDir::new("null_no_index");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_restored_row(&db, RELATIVE_ICON, None, None);
    let repo = Arc::new(IndexRepo::new(false));
    let driver = driver(&db, repo.clone(), &[SOURCE]);

    let info = driver.get_app_info(APP_ID, false).unwrap();
    println!("null-source/no-index get_app_info.icon={}", info.icon);
    assert_absolute(&info.icon);

    let listed = driver.get_all_apps(false).unwrap();
    println!("null-source/no-index get_all_apps={listed:?}");
    assert_eq!(listed.len(), 1, "the restored row must never be dropped");
    assert_absolute(&listed[0].icon);

    let detail = driver.get_app_detail(APP_ID, false).unwrap();
    println!("null-source/no-index get_app_detail.icon={}", detail.icon);
    assert_absolute(&detail.icon);
    assert_eq!(detail.icon, ABSOLUTE_ICON);
}

#[test]
fn restored_row_legacy_identity_without_index_is_absolute_on_home_and_detail() {
    let dir = TempDir::new("legacy_no_index");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_restored_row(&db, RELATIVE_ICON, Some("official"), None);
    let repo = Arc::new(IndexRepo::new(false));
    let driver = driver(&db, repo.clone(), &[SOURCE]);

    let info = driver.get_app_info(APP_ID, false).unwrap();
    println!("legacy-id/no-index get_app_info.icon={}", info.icon);
    assert_absolute(&info.icon);

    let listed = driver.get_all_apps(false).unwrap();
    println!("legacy-id/no-index get_all_apps={listed:?}");
    assert_eq!(
        listed.len(),
        1,
        "a legacy identity must not drop the restored row from discovery"
    );
    assert_absolute(&listed[0].icon);

    let detail = driver.get_app_detail(APP_ID, false).unwrap();
    println!("legacy-id/no-index get_app_detail.icon={}", detail.icon);
    assert_absolute(&detail.icon);
    assert_eq!(detail.icon, ABSOLUTE_ICON);
}

// ---------------------------------------------------------------------------
// (b) index present: same absolute icon on both paths
// ---------------------------------------------------------------------------

#[test]
fn restored_row_legacy_identity_with_index_is_absolute_on_home_and_detail() {
    let dir = TempDir::new("legacy_index");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_restored_row(&db, RELATIVE_ICON, Some("official"), None);
    let repo = Arc::new(IndexRepo::new(true));
    let driver = driver(&db, repo.clone(), &[SOURCE]);

    let info = driver.get_app_info(APP_ID, false).unwrap();
    println!("legacy-id/index get_app_info.icon={}", info.icon);
    assert_eq!(info.icon, ABSOLUTE_ICON);

    let listed = driver.get_all_apps(false).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].icon, ABSOLUTE_ICON);

    let detail = driver.get_app_detail(APP_ID, false).unwrap();
    assert_eq!(detail.icon, ABSOLUTE_ICON);
}

#[test]
fn restored_row_empty_icon_resolves_from_the_index_when_present() {
    let dir = TempDir::new("empty_icon_index");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_restored_row(&db, "", None, None);
    let repo = Arc::new(IndexRepo::new(true));
    let driver = driver(&db, repo.clone(), &[SOURCE]);

    let info = driver.get_app_info(APP_ID, false).unwrap();
    println!("empty-icon/index get_app_info.icon={}", info.icon);
    assert_eq!(
        info.icon, ABSOLUTE_ICON,
        "the index carries the real icon path, prefer it over icons/<pkg>.png"
    );
}

// ---------------------------------------------------------------------------
// disabled source: never resurrected
// ---------------------------------------------------------------------------

#[test]
fn disabled_source_row_stays_excluded_from_home() {
    let dir = TempDir::new("disabled");
    let db = DbHandle::open(dir.path()).unwrap();
    // Belongs to OTHER_SOURCE (a real repo URL), which the user disabled.
    seed_restored_row(&db, MIRROR_ICON, Some(OTHER_SOURCE), None);
    let repo = Arc::new(IndexRepo::new(true));
    let driver = driver(&db, repo.clone(), &[SOURCE]);

    let listed = driver.get_all_apps(false).unwrap();
    println!("disabled-source get_all_apps={listed:?}");
    assert!(
        listed.is_empty(),
        "a genuinely disabled source must stay excluded: {listed:?}"
    );
}

// ---------------------------------------------------------------------------
// unknown identity with a relative icon joins the first active source
// ---------------------------------------------------------------------------

#[test]
fn unknown_identity_relative_icon_joins_first_active_source() {
    let dir = TempDir::new("unknown_first_active");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_restored_row(
        &db,
        RELATIVE_ICON,
        Some("fp:deadbeef"),
        Some(r#"{"sourceId":"fp:deadbeef"}"#),
    );
    let repo = Arc::new(IndexRepo::new(false));
    let driver = driver(&db, repo.clone(), &[OTHER_SOURCE, SOURCE]);

    let listed = driver.get_all_apps(false).unwrap();
    println!("unknown-identity get_all_apps={listed:?}");
    assert_eq!(listed.len(), 1);
    assert_eq!(
        listed[0].icon, MIRROR_ICON,
        "an unresolvable identity joins the first active source, not verbatim"
    );

    let info = driver.get_app_info(APP_ID, false).unwrap();
    assert_eq!(info.icon, MIRROR_ICON);
}

// ---------------------------------------------------------------------------
// index-first: an absolute icon no longer short-circuits the index lookup
// ---------------------------------------------------------------------------

#[test]
fn list_with_absolute_icons_consults_the_local_index_once_without_downloading() {
    let dir = TempDir::new("index_probe");
    let db = DbHandle::open(dir.path()).unwrap();
    seed_restored_row(&db, ABSOLUTE_ICON, Some(SOURCE), None);
    let repo = Arc::new(IndexRepo::new(true));
    let driver = driver(&db, repo.clone(), &[SOURCE]);

    let listed = driver.get_all_apps(false).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].icon, ABSOLUTE_ICON);
    assert_eq!(
        repo.downloads(),
        0,
        "a local index must be reused, never re-downloaded for a list read"
    );
    assert_eq!(
        repo.one_app_calls(),
        1,
        "the list path probes the index once per row, exactly like detail"
    );
}
