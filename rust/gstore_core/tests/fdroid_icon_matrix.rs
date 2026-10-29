//! Home-icon matrix for the three write paths that can produce an F-Droid
//! `channel_apps` row: a NEW search+add, the cutover import of the legacy
//! `channel_added_app` table, and a backup restore (the row the Dart restore
//! writes through `add_app`).
//!
//! The invariant under test: after every path, the resolved home icon
//! (`FdroidDriver::get_app_info`, and the `SqliteChannelAppFallback` used when
//! the driver is absent/disabled) is an ABSOLUTE url, never a repo-relative key
//! such as `icons/<pkg>.png` that the Dart `AppIcon` cannot render.
//!
//! The legacy Dart channel wrote `ChannelAddedApp.sourceId` as a *source
//! identity* (`official`, `fp:<HEX>`, `url:<url>`), not the repo URL the core
//! driver compares against — the cutover fix maps it to the configured URL and
//! stores the icon absolute.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::aggregate::channel_app_fallback::SqliteChannelAppFallback;
use gstore_core::aggregate::service::AggregationService;
use gstore_core::channel::{ChannelDriver, FdroidDriver, GitHubDriver, VivoDriver};
use gstore_core::channel_migration::ChannelMigrator;
use gstore_core::db::{DbError, DbHandle};
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta};
use gstore_core::ports::{
    CoreConfig, FakeHttpPort, FakeMetadataPort, FakeRepoPort, InMemorySecretPort, MetadataPort,
    RepoApp, RepoMeta, RepoPort,
};
use rusqlite::Connection;
use serde_json::{json, Value};

const SOURCE: &str = "https://fdroid.test/repo";
const APP_ID: &str = "com.example.app";
const ABSOLUTE_ICON: &str = "https://fdroid.test/repo/icons/com.example.app.png";
const RELATIVE_ICON: &str = "icons/com.example.app.png";

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_fdroid_icon_matrix_{tag}_{}_{}",
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

fn fdroid_driver(db: &DbHandle, repo: Arc<dyn RepoPort>, sources: &[&str]) -> FdroidDriver {
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

fn repo_app() -> RepoApp {
    RepoApp {
        package_name: APP_ID.to_string(),
        name: "Example App".to_string(),
        summary: "short summary".to_string(),
        version: Some("1.0".to_string()),
        version_code: Some(1),
        icon: Some(ABSOLUTE_ICON.to_string()),
        apk_url: None,
        size: None,
        categories: vec!["Tools".to_string()],
        metadata: None,
    }
}

fn seeded_repo() -> FakeRepoPort {
    let repo = FakeRepoPort::new(std::env::temp_dir().join("unused-fdroid-rows.db"));
    repo.add_repo(RepoMeta {
        source: SOURCE.to_string(),
        name: "Test".to_string(),
        description: None,
        version: None,
        timestamp: None,
        app_count: 1,
    });
    repo.add_app(SOURCE, repo_app());
    repo
}

fn summary(icon: &str, extra: Option<Value>) -> AppSummary {
    AppSummary {
        app_id: APP_ID.to_string(),
        package_name: Some(APP_ID.to_string()),
        name: "Example App".to_string(),
        user: String::new(),
        repositories: APP_ID.to_string(),
        icon: icon.to_string(),
        des: "short summary".to_string(),
        readme: None,
        category: Some(vec!["Tools".to_string()]),
        extra: extra.and_then(|value| value.as_object().cloned()),
        labels: Vec::new(),
    }
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

fn row_count(db: &DbHandle) -> i64 {
    db.with_reader(|conn| {
        conn.query_row("SELECT COUNT(*) FROM channel_apps", [], |row| row.get(0))
            .map_err(|error| DbError(error.to_string()))
    })
    .unwrap()
}

/// Legacy Floor v5 `channel_added_app` fixture. `source_id` is what the old
/// Dart channel stored: a source identity, not a repo URL.
fn write_legacy_db(
    path: &Path,
    rows: &[(&str, &str, &str, Option<&str>, Option<&str>)],
    with_source_column: bool,
) {
    let conn = Connection::open(path).unwrap();
    let source_column = if with_source_column {
        "sourceId TEXT,"
    } else {
        ""
    };
    conn.execute_batch(&format!(
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
             {source_column}
             PRIMARY KEY (channelCode, appId)
         );
         PRAGMA user_version = 5;"
    ))
    .unwrap();
    for (index, (channel, app_id, icon, source_id, extra)) in rows.iter().enumerate() {
        let sql = if with_source_column {
            "INSERT INTO channel_added_app(
                 appId,name,user,repositories,apprepo,icon,description,category,
                 addTime,channelCode,extra,sourceId)
             VALUES (?1,?2,'owner',?3,?4,?5,'description',?6,?7,?8,?9,?10)"
        } else {
            "INSERT INTO channel_added_app(
                 appId,name,user,repositories,apprepo,icon,description,category,
                 addTime,channelCode,extra)
             VALUES (?1,?2,'owner',?3,?4,?5,'description',?6,?7,?8,?9)"
        };
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = vec![
            Box::new(app_id.to_string()),
            Box::new(format!("App {index}")),
            Box::new(app_id.to_string()),
            Box::new(Some("owner/repo".to_string())),
            Box::new(icon.to_string()),
            Box::new(Some("Tools".to_string())),
            Box::new(1_700_000_000_000i64 + index as i64),
            Box::new(channel.to_string()),
            Box::new(extra.map(ToString::to_string)),
        ];
        if with_source_column {
            params.push(Box::new(source_id.map(ToString::to_string)));
        }
        let borrowed: Vec<&dyn rusqlite::ToSql> = params.iter().map(|value| value.as_ref()).collect();
        conn.execute(sql, borrowed.as_slice()).unwrap();
    }
}

fn import_legacy_rows(core: &DbHandle, legacy: &Path, root: &Path) -> usize {
    let secrets = InMemorySecretPort::new();
    let conn = core.writer().unwrap();
    let migrator = ChannelMigrator::new(&conn, &secrets, root.join("backups"));
    migrator.import_channel_db(legacy).unwrap().rows_imported
}

fn import_sources(core: &DbHandle, root: &Path, doc: Value) -> usize {
    let secrets = InMemorySecretPort::new();
    let conn = core.writer().unwrap();
    let migrator = ChannelMigrator::new(&conn, &secrets, root.join("backups"));
    migrator.import_fdroid_sources(&doc).unwrap().sources
}

fn official_sources_doc() -> Value {
    json!({
        "version": 1,
        "sources": [
            {"id": "official", "name": "Official", "repoUrl": SOURCE},
            {
                "id": "custom_1",
                "name": "Custom",
                "repoUrl": "https://mirror.test/fdroid",
                "fingerprint": "AB:CD:EF:01"
            }
        ],
        "last_source_id": "official"
    })
}

// ---------------------------------------------------------------------------
// (a) NEW add: search carries an absolute icon + extra.sourceId
// ---------------------------------------------------------------------------

#[test]
fn fdroid_icon_matrix_new_add_resolves_absolute_icon() {
    let dir = TempDir::new("new_add");
    let db = DbHandle::open(dir.path()).unwrap();
    let repo = seeded_repo();
    let driver = fdroid_driver(&db, Arc::new(repo), &[SOURCE]);

    driver
        .add_app(&summary(ABSOLUTE_ICON, Some(json!({"sourceId": SOURCE}))))
        .unwrap();
    let (stored_icon, stored_source) = stored_icon_and_source(&db, APP_ID);
    assert_eq!(
        stored_icon, RELATIVE_ICON,
        "add_app keeps the repo-relative key (driver parity)"
    );
    assert_eq!(stored_source.as_deref(), Some(SOURCE));

    let info = driver.get_app_info(APP_ID, false).unwrap();
    assert_eq!(info.icon, ABSOLUTE_ICON);
}

// ---------------------------------------------------------------------------
// (b) CUTOVER: legacy channel_added_app -> import_channel_db
// ---------------------------------------------------------------------------

#[test]
fn fdroid_icon_matrix_cutover_maps_identity_key_after_sources_import() {
    let dir = TempDir::new("cutover_handoff_order");
    let core = DbHandle::open(dir.path()).unwrap();
    let legacy = dir.path().join("channel_apps.db");
    write_legacy_db(
        &legacy,
        &[("fdroid", APP_ID, RELATIVE_ICON, Some("official"), None)],
        true,
    );

    // Handoff order: channel_db first, sources afterwards.
    assert_eq!(import_legacy_rows(&core, &legacy, dir.path()), 1);
    assert_eq!(import_sources(&core, dir.path(), official_sources_doc()), 2);

    let (stored_icon, stored_source) = stored_icon_and_source(&core, APP_ID);
    assert_eq!(
        stored_source.as_deref(),
        Some(SOURCE),
        "the source id key must become the configured repo URL"
    );
    assert_eq!(
        stored_icon, ABSOLUTE_ICON,
        "the icon must no longer depend on source_id"
    );

    let driver = fdroid_driver(&core, Arc::new(seeded_repo()), &[SOURCE]);
    let info = driver.get_app_info(APP_ID, false).unwrap();
    assert_eq!(info.icon, ABSOLUTE_ICON);
}

#[test]
fn fdroid_icon_matrix_cutover_maps_identity_key_when_sources_already_known() {
    let dir = TempDir::new("cutover_sources_first");
    let core = DbHandle::open(dir.path()).unwrap();
    assert_eq!(import_sources(&core, dir.path(), official_sources_doc()), 2);

    let legacy = dir.path().join("channel_apps.db");
    write_legacy_db(
        &legacy,
        &[("fdroid", APP_ID, RELATIVE_ICON, Some("official"), None)],
        true,
    );
    assert_eq!(import_legacy_rows(&core, &legacy, dir.path()), 1);

    let (stored_icon, stored_source) = stored_icon_and_source(&core, APP_ID);
    assert_eq!(stored_source.as_deref(), Some(SOURCE));
    assert_eq!(stored_icon, ABSOLUTE_ICON);

    let driver = fdroid_driver(&core, Arc::new(seeded_repo()), &[SOURCE]);
    assert_eq!(driver.get_app_info(APP_ID, false).unwrap().icon, ABSOLUTE_ICON);
}

#[test]
fn fdroid_icon_matrix_cutover_maps_fingerprint_and_url_identities() {
    let dir = TempDir::new("cutover_identities");
    let core = DbHandle::open(dir.path()).unwrap();
    assert_eq!(import_sources(&core, dir.path(), official_sources_doc()), 2);

    let legacy = dir.path().join("channel_apps.db");
    let mirror = "https://mirror.test/fdroid";
    write_legacy_db(
        &legacy,
        &[
            ("fdroid", "com.fp", RELATIVE_ICON, Some("fp:abcdef01"), None),
            (
                "fdroid",
                "com.url",
                RELATIVE_ICON,
                Some("url:https://fdroid.test/repo/"),
                None,
            ),
            (
                "fdroid",
                "com.bare",
                RELATIVE_ICON,
                Some("https://fdroid.test/repo"),
                None,
            ),
        ],
        true,
    );
    assert_eq!(import_legacy_rows(&core, &legacy, dir.path()), 3);

    assert_eq!(
        stored_icon_and_source(&core, "com.fp").1.as_deref(),
        Some(mirror)
    );
    assert_eq!(
        stored_icon_and_source(&core, "com.url").1.as_deref(),
        Some(SOURCE)
    );
    assert_eq!(
        stored_icon_and_source(&core, "com.bare").1.as_deref(),
        Some(SOURCE)
    );
    for (app, base) in [
        ("com.fp", mirror),
        ("com.url", SOURCE),
        ("com.bare", SOURCE),
    ] {
        assert_eq!(
            stored_icon_and_source(&core, app).0,
            format!("{base}/icons/com.example.app.png"),
            "{app} icon must be absolute"
        );
    }
}

#[test]
fn fdroid_icon_matrix_cutover_uses_extra_source_id_when_column_is_missing() {
    let dir = TempDir::new("cutover_extra_only");
    let core = DbHandle::open(dir.path()).unwrap();
    let legacy = dir.path().join("channel_apps.db");
    // Pre-v5 rows carried the identity inside `extra` only.
    write_legacy_db(
        &legacy,
        &[(
            "fdroid",
            APP_ID,
            RELATIVE_ICON,
            None,
            Some(r#"{"sourceId":"official"}"#),
        )],
        false,
    );
    assert_eq!(import_legacy_rows(&core, &legacy, dir.path()), 1);
    assert_eq!(import_sources(&core, dir.path(), official_sources_doc()), 2);

    let (stored_icon, stored_source) = stored_icon_and_source(&core, APP_ID);
    assert_eq!(stored_source.as_deref(), Some(SOURCE));
    assert_eq!(stored_icon, ABSOLUTE_ICON);
}

#[test]
fn fdroid_icon_matrix_cutover_keeps_row_when_identity_is_unknown() {
    let dir = TempDir::new("cutover_unknown");
    let core = DbHandle::open(dir.path()).unwrap();
    let legacy = dir.path().join("channel_apps.db");
    write_legacy_db(
        &legacy,
        &[(
            "fdroid",
            APP_ID,
            RELATIVE_ICON,
            Some("fp:00000000"),
            None,
        )],
        true,
    );
    assert_eq!(import_legacy_rows(&core, &legacy, dir.path()), 1);
    assert_eq!(import_sources(&core, dir.path(), official_sources_doc()), 2);

    assert_eq!(row_count(&core), 1, "an unknown identity must not drop the app");
    let (icon, source) = stored_icon_and_source(&core, APP_ID);
    assert_eq!(source.as_deref(), Some("fp:00000000"));
    assert_eq!(icon, RELATIVE_ICON);

    // The app is still readable: the driver falls back to the repository
    // lookup, which yields an absolute icon.
    let driver = fdroid_driver(&core, Arc::new(seeded_repo()), &[SOURCE]);
    assert_eq!(driver.get_app_info(APP_ID, false).unwrap().icon, ABSOLUTE_ICON);
}

// ---------------------------------------------------------------------------
// (c) BACKUP RESTORE: the row the Dart restore writes through add_app
// ---------------------------------------------------------------------------

#[test]
fn fdroid_icon_matrix_restore_absolute_icon_with_source_id() {
    let dir = TempDir::new("restore_absolute");
    let db = DbHandle::open(dir.path()).unwrap();
    let driver = fdroid_driver(&db, Arc::new(seeded_repo()), &[SOURCE]);

    // What `_importChannelAppsToCore` now sends: absolute icon + merged
    // `extra.sourceId`.
    driver
        .add_app(&summary(ABSOLUTE_ICON, Some(json!({"sourceId": SOURCE}))))
        .unwrap();

    assert_eq!(
        stored_icon_and_source(&db, APP_ID).1.as_deref(),
        Some(SOURCE)
    );
    assert_eq!(driver.get_app_info(APP_ID, false).unwrap().icon, ABSOLUTE_ICON);
}

#[test]
fn fdroid_icon_matrix_restore_relative_icon_with_source_id() {
    let dir = TempDir::new("restore_relative");
    let db = DbHandle::open(dir.path()).unwrap();
    let driver = fdroid_driver(&db, Arc::new(seeded_repo()), &[SOURCE]);

    // A backup exported from the legacy Dart lane stores the repo-relative key
    // and the source identity next to it.
    driver
        .add_app(&summary(RELATIVE_ICON, Some(json!({"sourceId": SOURCE}))))
        .unwrap();

    assert_eq!(driver.get_app_info(APP_ID, false).unwrap().icon, ABSOLUTE_ICON);

    // ...and the projection fallback resolves it too when the driver is gone.
    let service = AggregationService::new(db.clone(), Arc::new(|_code: &str| None))
        .unwrap()
        .with_fallback(Arc::new(SqliteChannelAppFallback::new(db.clone())));
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
             VALUES ('fdroid', ?1, 1000, 0, 1)",
            [APP_ID],
        )
        .map_err(|error| DbError(error.to_string()))?;
        Ok(())
    })
    .unwrap();
    let all = service.aggregate_all().unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].app.icon, ABSOLUTE_ICON);
}

#[test]
fn fdroid_icon_matrix_restore_source_id_only_in_extra() {
    let dir = TempDir::new("restore_extra");
    let db = DbHandle::open(dir.path()).unwrap();
    let driver = fdroid_driver(&db, Arc::new(seeded_repo()), &[SOURCE]);

    driver
        .add_app(&summary(RELATIVE_ICON, Some(json!({"sourceId": SOURCE}))))
        .unwrap();
    // Same row as an old backup restored without the dedicated `sourceId`
    // field: the identity rides `extra` only.
    assert_eq!(driver.get_app_info(APP_ID, false).unwrap().icon, ABSOLUTE_ICON);
}

// ---------------------------------------------------------------------------
// github / vivo: same generic paths, icons already absolute — no regression
// ---------------------------------------------------------------------------

#[test]
fn fdroid_icon_matrix_github_and_vivo_rows_are_untouched_by_the_repair() {
    let dir = TempDir::new("other_channels");
    let core = DbHandle::open(dir.path()).unwrap();
    let legacy = dir.path().join("channel_apps.db");
    write_legacy_db(
        &legacy,
        &[
            (
                "github",
                "owner/repo",
                "https://avatars.test/owner.png",
                None,
                None,
            ),
            (
                "vivo",
                "com.vivo.app",
                "https://icons.vivo.test/app.png",
                None,
                None,
            ),
        ],
        true,
    );
    assert_eq!(import_legacy_rows(&core, &legacy, dir.path()), 2);
    assert_eq!(import_sources(&core, dir.path(), official_sources_doc()), 2);

    let rows: Vec<(String, String, Option<String>)> = core
        .with_reader(|conn| {
            let mut statement = conn
                .prepare("SELECT channel_key, icon, source_id FROM channel_apps ORDER BY channel_key")
                .map_err(|error| DbError(error.to_string()))?;
            let rows = statement
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
                .map_err(|error| DbError(error.to_string()))?;
            rows.collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| DbError(error.to_string()))
        })
        .unwrap();
    assert_eq!(
        rows,
        vec![
            (
                "github".to_string(),
                "https://avatars.test/owner.png".to_string(),
                None
            ),
            (
                "vivo".to_string(),
                "https://icons.vivo.test/app.png".to_string(),
                None
            ),
        ]
    );

    let github = GitHubDriver::new(
        ChannelKey::new("github").unwrap(),
        meta(ChannelKind::Github, "GitHub"),
        core.clone(),
        CoreConfig::default(),
        Arc::new(FakeHttpPort::new()),
        Arc::new(FakeMetadataPort::new()) as Arc<dyn MetadataPort>,
    );
    assert_eq!(
        github.get_app_info("owner/repo", false).unwrap().icon,
        "https://avatars.test/owner.png"
    );

    let vivo = VivoDriver::new(
        ChannelKey::new("vivo").unwrap(),
        meta(ChannelKind::Vivo, "vivo"),
        core.clone(),
        CoreConfig::default(),
        Arc::new(FakeHttpPort::new()),
    );
    assert_eq!(
        vivo.get_app_info("com.vivo.app", false).unwrap().icon,
        "https://icons.vivo.test/app.png"
    );
}
