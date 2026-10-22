//! Added-apps storage + Dart v5 migration parity tests.
//!
//! These tests compare every imported id/timestamp/order/flag/tag against the
//! source database, not just counts, and exercise the migration failure paths
//! with a pre-populated core database so a misleading "success" cannot pass.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::added::apps::{AddedApp, AddedAppsService};
use gstore_core::added::migration::{
    import_dart_added_db, CODE_DUPLICATE, CODE_SCHEMA, CODE_SCHEMA_VERSION,
};
use gstore_core::db::{DbError, DbHandle};
use gstore_core::error::{Error, CODE_NOT_FOUND};
use rusqlite::{params, Connection, ErrorCode, OpenFlags};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

type AppRow = (i64, String, String, i64, i64, i64);
type TagRow = (String, String, String, i64);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_added_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const V5_DDL: &str = "
CREATE TABLE added_apps (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  channelId TEXT NOT NULL,
  appId TEXT NOT NULL,
  addTime INTEGER NOT NULL,
  sortOrder INTEGER NOT NULL,
  isEnabled INTEGER NOT NULL
);
CREATE UNIQUE INDEX index_added_apps_channelId_appId ON added_apps(channelId, appId);
CREATE TABLE added_app_tags (
  channelId TEXT NOT NULL,
  appId TEXT NOT NULL,
  tag TEXT NOT NULL,
  addTime INTEGER NOT NULL,
  PRIMARY KEY (channelId, appId, tag)
);
PRAGMA user_version = 5;
";

fn create_source(dir: &TempDir, name: &str, ddl: &str) -> PathBuf {
    let path = dir.join(name);
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(ddl).unwrap();
    path
}

fn insert_source_app(
    conn: &Connection,
    id: i64,
    channel: &str,
    app_id: &str,
    add_time: i64,
    sort_order: i64,
    is_enabled: i64,
) {
    conn.execute(
        "INSERT INTO added_apps(id, channelId, appId, addTime, sortOrder, isEnabled) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![id, channel, app_id, add_time, sort_order, is_enabled],
    )
    .unwrap();
}

fn insert_source_tag(conn: &Connection, channel: &str, app_id: &str, tag: &str, add_time: i64) {
    conn.execute(
        "INSERT INTO added_app_tags(channelId, appId, tag, addTime) VALUES (?1, ?2, ?3, ?4)",
        params![channel, app_id, tag, add_time],
    )
    .unwrap();
}

fn seed_v5_source(dir: &TempDir) -> PathBuf {
    let source = create_source(dir, "added_apps.db", V5_DDL);
    let conn = Connection::open(&source).unwrap();
    insert_source_app(&conn, 7, "github", "owner-repo", 1_700_000_100_000, 3, 1);
    insert_source_app(&conn, 9, "fdroid", "org.example", 1_700_000_200_000, 1, 0);
    insert_source_app(&conn, 12, "local_db", "com.x", 1_700_000_300_000, 9, 1);
    insert_source_tag(&conn, "github", "owner-repo", "tools", 1_700_000_100_001);
    insert_source_tag(&conn, "github", "owner-repo", "rust", 1_700_000_100_002);
    insert_source_tag(&conn, "fdroid", "org.example", "fd", 1_700_000_200_001);
    // Tag for an app that is not in added_apps: orphan must survive the import.
    insert_source_tag(&conn, "github", "ghost", "orphan", 1_700_000_400_000);
    source
}

fn source_rows(source: &Path) -> (Vec<AppRow>, Vec<TagRow>) {
    let conn = Connection::open_with_flags(source, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let apps = {
        let mut stmt = conn
            .prepare(
                "SELECT id, channelId, appId, addTime, sortOrder, isEnabled \
                 FROM added_apps ORDER BY id",
            )
            .unwrap();
        stmt.query_map([], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
            ))
        })
        .unwrap()
        .map(|row| row.unwrap())
        .collect()
    };
    let tags = {
        let mut stmt = conn
            .prepare(
                "SELECT channelId, appId, tag, addTime FROM added_app_tags \
                 ORDER BY channelId, appId, tag",
            )
            .unwrap();
        stmt.query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })
        .unwrap()
        .map(|row| row.unwrap())
        .collect()
    };
    (apps, tags)
}

fn core_rows(db: &DbHandle) -> (Vec<AppRow>, Vec<TagRow>) {
    let conn = db.reader().unwrap();
    let apps = {
        let mut stmt = conn
            .prepare(
                "SELECT id, channel_id, app_id, add_time, sort_order, is_enabled \
                 FROM added_apps ORDER BY id",
            )
            .unwrap();
        stmt.query_map([], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
            ))
        })
        .unwrap()
        .map(|row| row.unwrap())
        .collect()
    };
    let tags = {
        let mut stmt = conn
            .prepare(
                "SELECT channel_id, app_id, tag, add_time FROM added_app_tags \
                 ORDER BY channel_id, app_id, tag",
            )
            .unwrap();
        stmt.query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })
        .unwrap()
        .map(|row| row.unwrap())
        .collect()
    };
    (apps, tags)
}

fn seed_core_old_row(db: &DbHandle) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
             VALUES ('old', 'legacy', 123, 0, 1)",
            [],
        )
        .map_err(|error| DbError(error.to_string()))?;
        Ok(())
    })
    .unwrap();
}

fn service(tmp: &TempDir) -> (DbHandle, AddedAppsService, Arc<AtomicI64>) {
    let db = DbHandle::open(&tmp.join("core")).unwrap();
    let clock = Arc::new(AtomicI64::new(1_000));
    let shared = Arc::clone(&clock);
    let service =
        AddedAppsService::with_clock(db.clone(), Arc::new(move || shared.load(Ordering::SeqCst)));
    (db, service, clock)
}

fn app_row(service: &AddedAppsService, channel: &str, app_id: &str) -> AddedApp {
    service
        .get(channel, app_id)
        .unwrap()
        .unwrap_or_else(|| panic!("missing added app {channel}:{app_id}"))
}

fn tag_times(db: &DbHandle, channel: &str, app_id: &str) -> Vec<(String, i64)> {
    let conn = db.reader().unwrap();
    let mut stmt = conn
        .prepare(
            "SELECT tag, add_time FROM added_app_tags \
             WHERE channel_id=?1 AND app_id=?2 ORDER BY tag",
        )
        .unwrap();
    stmt.query_map(params![channel, app_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    })
    .unwrap()
    .map(|row| row.unwrap())
    .collect()
}

fn count_tags(db: &DbHandle) -> i64 {
    db.reader()
        .unwrap()
        .query_row("SELECT COUNT(*) FROM added_app_tags", [], |row| row.get(0))
        .unwrap()
}

#[test]
fn added_apps_parity() {
    let tmp = TempDir::new("parity");
    let source = seed_v5_source(&tmp);
    let expected = source_rows(&source);

    let db = DbHandle::open(&tmp.join("core")).unwrap();
    let first = import_dart_added_db(&db, &source).unwrap();

    assert_eq!(first.apps, 3);
    assert_eq!(first.tags, 4);
    assert_eq!(first.source, source.display().to_string());
    assert!(
        first
            .backup
            .as_deref()
            .is_some_and(|path| path.contains(".bak-added-")),
        "missing pre-import core backup: {:?}",
        first.backup
    );
    assert!(first.snapshot_deleted, "source snapshot was not removed");

    let imported = core_rows(&db);
    assert_eq!(
        imported, expected,
        "imported rows must be byte-identical to the source"
    );

    let integrity: String = db
        .reader()
        .unwrap()
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .unwrap();
    assert_eq!(integrity, "ok");

    let next_id: i64 = db
        .reader()
        .unwrap()
        .query_row(
            "SELECT seq FROM sqlite_sequence WHERE name='added_apps'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(next_id > 3, "sqlite_sequence next id {next_id} <= max id 3");
    assert_eq!(next_id, 12);

    // Re-run: same rows, same ids, no duplicates.
    let second = import_dart_added_db(&db, &source).unwrap();
    assert_eq!(second.apps, 3);
    assert_eq!(second.tags, 4);
    assert_eq!(core_rows(&db), imported);
    assert_eq!(count_tags(&db), 4);

    // Leave a real-data artifact for the sqlite3 manual-QA capture.
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let evidence = root.join("target/test-evidence");
    std::fs::create_dir_all(&evidence).unwrap();
    let evidence_db = evidence.join("64-added.db");
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", evidence_db.display()));
    }
    db.with_writer(|conn| {
        conn.execute(
            "VACUUM INTO ?1",
            [evidence_db.to_string_lossy().into_owned()],
        )
        .map_err(|error| DbError(error.to_string()))?;
        Ok(())
    })
    .unwrap();
    assert!(evidence_db.exists());
}

#[test]
fn added_apps_migration_rejects_bad_schema() {
    let tmp = TempDir::new("bad_schema");
    let db = DbHandle::open(&tmp.join("core")).unwrap();
    seed_core_old_row(&db);
    let baseline = core_rows(&db);

    // user_version = 4
    let old_version = create_source(
        &tmp,
        "v4.db",
        &V5_DDL.replace("PRAGMA user_version = 5;", "PRAGMA user_version = 4;"),
    );
    let error = import_dart_added_db(&db, &old_version).unwrap_err();
    println!("user_version=4 -> {error}");
    assert!(
        error.message().contains(CODE_SCHEMA_VERSION),
        "expected {CODE_SCHEMA_VERSION}, got {error}"
    );
    assert_eq!(core_rows(&db), baseline);

    // missing added_app_tags table
    let missing_tags = create_source(
        &tmp,
        "missing-tags.db",
        "
        CREATE TABLE added_apps (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          channelId TEXT NOT NULL,
          appId TEXT NOT NULL,
          addTime INTEGER NOT NULL,
          sortOrder INTEGER NOT NULL,
          isEnabled INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX index_added_apps_channelId_appId ON added_apps(channelId, appId);
        PRAGMA user_version = 5;
        ",
    );
    let error = import_dart_added_db(&db, &missing_tags).unwrap_err();
    println!("missing added_app_tags -> {error}");
    assert!(
        error.message().contains(CODE_SCHEMA),
        "expected {CODE_SCHEMA}, got {error}"
    );
    assert_eq!(core_rows(&db), baseline);

    // duplicate (channelId, appId), no unique index in the fixture
    let duplicate_apps = create_source(
        &tmp,
        "duplicate-apps.db",
        "
        CREATE TABLE added_apps (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          channelId TEXT NOT NULL,
          appId TEXT NOT NULL,
          addTime INTEGER NOT NULL,
          sortOrder INTEGER NOT NULL,
          isEnabled INTEGER NOT NULL
        );
        CREATE TABLE added_app_tags (
          channelId TEXT NOT NULL,
          appId TEXT NOT NULL,
          tag TEXT NOT NULL,
          addTime INTEGER NOT NULL,
          PRIMARY KEY (channelId, appId, tag)
        );
        PRAGMA user_version = 5;
        ",
    );
    {
        let conn = Connection::open(&duplicate_apps).unwrap();
        insert_source_app(&conn, 1, "github", "dup", 10, 0, 1);
        insert_source_app(&conn, 2, "github", "dup", 20, 0, 1);
    }
    let error = import_dart_added_db(&db, &duplicate_apps).unwrap_err();
    println!("duplicate (channelId, appId) -> {error}");
    assert!(
        error.message().contains(CODE_DUPLICATE),
        "expected {CODE_DUPLICATE}, got {error}"
    );
    assert_eq!(core_rows(&db), baseline);

    // isEnabled = 2
    let bad_enabled = create_source(&tmp, "bad-enabled.db", V5_DDL);
    {
        let conn = Connection::open(&bad_enabled).unwrap();
        insert_source_app(&conn, 1, "github", "bad", 10, 0, 2);
    }
    let error = import_dart_added_db(&db, &bad_enabled).unwrap_err();
    println!("isEnabled=2 -> {error}");
    assert!(
        error.message().contains(CODE_SCHEMA),
        "expected {CODE_SCHEMA}, got {error}"
    );
    assert_eq!(core_rows(&db), baseline);
}

#[test]
fn added_apps_migration_backup() {
    let tmp = TempDir::new("backup");
    let source = create_source(&tmp, "added_apps.db", V5_DDL);
    {
        let conn = Connection::open(&source).unwrap();
        insert_source_app(&conn, 5, "github", "new", 555, 2, 1);
    }

    let core_dir = tmp.join("core");
    let db = DbHandle::open(&core_dir).unwrap();
    seed_core_old_row(&db);
    let old_rows = core_rows(&db);

    let report = import_dart_added_db(&db, &source).unwrap();
    let backup = PathBuf::from(report.backup.as_deref().expect("backup path"));
    assert!(backup.exists(), "backup {} missing", backup.display());

    let backups: Vec<PathBuf> = std::fs::read_dir(&core_dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.contains(".bak-added-"))
        })
        .collect();
    assert_eq!(backups, vec![backup.clone()]);

    let backup_conn =
        Connection::open_with_flags(&backup, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let backup_rows: AppRow = backup_conn
        .query_row(
            "SELECT id, channel_id, app_id, add_time, sort_order, is_enabled \
             FROM added_apps",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(backup_rows, old_rows.0[0]);
    let backup_count: i64 = backup_conn
        .query_row("SELECT COUNT(*) FROM added_apps", [], |row| row.get(0))
        .unwrap();
    assert_eq!(backup_count, 1, "backup must hold only pre-import rows");

    let live = core_rows(&db);
    assert_eq!(live.0.len(), 1);
    assert_eq!(live.0[0].0, 5);
    assert_eq!(live.0[0].2, "new");
    assert!(
        old_rows.0.iter().all(|old| !live.0.contains(old)),
        "old rows survived the import"
    );
}

#[test]
fn added_apps_add_and_duplicate_update() {
    let tmp = TempDir::new("add");
    let (db, service, clock) = service(&tmp);

    let created = service.add("github", "owner/repo", None).unwrap();
    assert_eq!(created.id, 1);
    assert_eq!(created.add_time, 1_000);
    assert_eq!(created.sort_order, 0);
    assert!(created.is_enabled);

    db.with_writer(|conn| {
        conn.execute("UPDATE added_apps SET is_enabled=0", [])
            .map_err(|error| DbError(error.to_string()))?;
        Ok(())
    })
    .unwrap();

    clock.store(2_000, Ordering::SeqCst);
    let updated = service.add("github", "owner/repo", Some(5)).unwrap();
    assert_eq!(updated.id, created.id, "duplicate add must reuse the row");
    assert_eq!(updated.add_time, 2_000);
    assert_eq!(updated.sort_order, 5);
    assert!(
        !updated.is_enabled,
        "duplicate add must preserve is_enabled"
    );
    assert_eq!(service.total_count().unwrap(), 1);
}

#[test]
fn added_apps_remove_cleans_tags() {
    let tmp = TempDir::new("remove");
    let (db, service, _clock) = service(&tmp);

    service.add("github", "a", None).unwrap();
    service.add("github", "b", None).unwrap();
    service
        .set_tags("github", "a", &["one".to_string(), "two".to_string()])
        .unwrap();
    service.add_tag("github", "b", "keep").unwrap();

    assert!(service.remove("github", "a").unwrap());
    assert!(service.get("github", "a").unwrap().is_none());
    assert!(service.tags("github", "a").unwrap().is_empty());
    assert_eq!(service.tags("github", "b").unwrap(), vec!["keep"]);
    assert_eq!(service.total_count().unwrap(), 1);
    assert!(!service.remove("github", "a").unwrap());

    let _ = db;
}

#[test]
fn added_apps_rename_preserves_metadata() {
    let tmp = TempDir::new("rename");
    let (_db, service, clock) = service(&tmp);

    let created = service.add("github", "old", Some(3)).unwrap();
    service
        .set_tags("github", "old", &["t1".to_string(), "t2".to_string()])
        .unwrap();

    clock.store(2_000, Ordering::SeqCst);
    assert!(service.rename("github", "old", "new").unwrap());

    assert!(service.get("github", "old").unwrap().is_none());
    let renamed = app_row(&service, "github", "new");
    assert_eq!(renamed.id, created.id);
    assert_eq!(renamed.add_time, created.add_time);
    assert_eq!(renamed.sort_order, 3);
    assert!(renamed.is_enabled);
    assert_eq!(service.tags("github", "new").unwrap(), vec!["t1", "t2"]);
    let times = tag_times(&_db, "github", "new");
    assert_eq!(
        times,
        vec![("t1".to_string(), 2_000), ("t2".to_string(), 2_000)]
    );
}

#[test]
fn added_apps_rename_merges_into_existing() {
    let tmp = TempDir::new("rename-merge");
    let (db, service, clock) = service(&tmp);

    let old = service.add("github", "old", Some(3)).unwrap();
    service
        .set_tags("github", "old", &["a".to_string(), "shared".to_string()])
        .unwrap();
    let target = service.add("github", "new", Some(7)).unwrap();
    service
        .set_tags("github", "new", &["shared".to_string(), "b".to_string()])
        .unwrap();
    assert_ne!(old.id, target.id);

    clock.store(2_000, Ordering::SeqCst);
    assert!(service.rename("github", "old", "new").unwrap());

    assert!(service.get("github", "old").unwrap().is_none());
    let merged = app_row(&service, "github", "new");
    assert_eq!(merged.id, target.id, "target row metadata must be kept");
    assert_eq!(merged.add_time, target.add_time);
    assert_eq!(merged.sort_order, 7);
    assert!(merged.is_enabled);

    let tags = service.tags("github", "new").unwrap();
    assert!(tags.contains(&"a".to_string()));
    assert!(tags.contains(&"b".to_string()));
    assert!(tags.contains(&"shared".to_string()));
    let times = tag_times(&db, "github", "new");
    let by_tag = |name: &str| {
        times
            .iter()
            .find(|(tag, _)| tag == name)
            .map(|(_, time)| *time)
            .unwrap()
    };
    assert_eq!(by_tag("b"), target.add_time);
    assert_eq!(by_tag("a"), 2_000);
    assert_eq!(by_tag("shared"), 2_000);
}

#[test]
fn added_apps_rename_is_noop_when_source_missing() {
    let tmp = TempDir::new("rename-noop");
    let (_db, service, clock) = service(&tmp);

    assert!(!service.rename("github", "missing", "new").unwrap());

    let created = service.add("github", "old", Some(4)).unwrap();
    clock.store(2_000, Ordering::SeqCst);
    assert!(!service.rename("github", "old", "old").unwrap());
    let unchanged = app_row(&service, "github", "old");
    assert_eq!(unchanged, created);
}

#[test]
fn added_apps_tags_parity() {
    let tmp = TempDir::new("tags");
    let (db, service, clock) = service(&tmp);

    service.add("github", "x", None).unwrap();
    service.add("github", "y", None).unwrap();

    service
        .set_tags(
            "github",
            "x",
            &[
                "  a ".to_string(),
                "b".to_string(),
                "a".to_string(),
                String::new(),
                "   ".to_string(),
                "c".to_string(),
                "b".to_string(),
            ],
        )
        .unwrap();
    assert_eq!(service.tags("github", "x").unwrap(), vec!["a", "b", "c"]);

    clock.store(2_000, Ordering::SeqCst);
    service.add_tag("github", "x", " b ").unwrap();
    assert_eq!(
        service.tags("github", "x").unwrap(),
        vec!["a", "c", "b"],
        "duplicate add_tag replaces and refreshes add_time"
    );
    let times = tag_times(&db, "github", "x");
    assert_eq!(
        times,
        vec![
            ("a".to_string(), 1_000),
            ("b".to_string(), 2_000),
            ("c".to_string(), 1_000),
        ]
    );

    service.add_tag("github", "x", "   ").unwrap();
    assert_eq!(count_tags(&db), 3);

    service.remove_tag("github", "x", "does-not-exist").unwrap();
    service.remove_tag("github", "x", "a").unwrap();
    assert_eq!(service.tags("github", "x").unwrap(), vec!["c", "b"]);

    service.set_tags("github", "y", &["z".to_string()]).unwrap();
    let index = service.tags_index().unwrap();
    assert_eq!(
        index.keys().cloned().collect::<Vec<_>>(),
        vec!["github:x".to_string(), "github:y".to_string()],
        "BTreeMap keys must be deterministic"
    );
    assert_eq!(
        index.get("github:x"),
        Some(&vec!["c".to_string(), "b".to_string()])
    );
    assert_eq!(index.get("github:y"), Some(&vec!["z".to_string()]));
}

#[test]
fn added_apps_toggle_and_order() {
    let tmp = TempDir::new("toggle");
    let (_db, service, clock) = service(&tmp);

    assert!(service.toggle("fdroid", "org.example").unwrap());
    let added = app_row(&service, "fdroid", "org.example");
    assert_eq!(added.add_time, 1_000);
    assert_eq!(added.sort_order, 0);
    assert!(added.is_enabled);

    service.set_order("fdroid", "org.example", 5).unwrap();
    assert_eq!(app_row(&service, "fdroid", "org.example").sort_order, 5);

    service
        .set_tags("fdroid", "org.example", &["tag".to_string()])
        .unwrap();
    clock.store(2_000, Ordering::SeqCst);
    assert!(!service.toggle("fdroid", "org.example").unwrap());
    assert!(service.get("fdroid", "org.example").unwrap().is_none());
    assert!(service.tags("fdroid", "org.example").unwrap().is_empty());

    let error = service.set_order("fdroid", "org.example", 9).unwrap_err();
    assert!(matches!(error, Error::NotFound(_)), "got {error:?}");
    assert_eq!(error.code(), CODE_NOT_FOUND);
}

#[test]
fn added_apps_clear_leaves_orphan_tags_like_dart() {
    let tmp = TempDir::new("clear");
    let (db, service, _clock) = service(&tmp);

    service.add("c1", "a", None).unwrap();
    service.add("c1", "b", None).unwrap();
    service.add("c2", "c", None).unwrap();
    service.set_tags("c1", "a", &["ta".to_string()]).unwrap();
    service.set_tags("c1", "b", &["tb".to_string()]).unwrap();
    service.set_tags("c2", "c", &["tc".to_string()]).unwrap();

    // Dart `clearChannel` deletes only added_apps rows; tags stay behind.
    assert_eq!(service.clear_channel("c1").unwrap(), 2);
    assert!(service.list_channel("c1").unwrap().is_empty());
    assert_eq!(service.list_channel("c2").unwrap().len(), 1);
    assert_eq!(count_tags(&db), 3, "clear_channel must not delete tags");
    assert_eq!(service.tags("c1", "a").unwrap(), vec!["ta"]);
    assert_eq!(service.tags("c1", "b").unwrap(), vec!["tb"]);
    assert_eq!(service.tags("c2", "c").unwrap(), vec!["tc"]);

    // Dart `clearAll` deletes only added_apps rows; all tags stay behind.
    assert_eq!(service.clear_all().unwrap(), 1);
    assert_eq!(service.total_count().unwrap(), 0);
    assert_eq!(count_tags(&db), 3, "clear_all must not delete tags");
    assert_eq!(service.tags_index().unwrap().len(), 3);
}

#[test]
fn added_apps_duplicate_add_unique_constraint() {
    let tmp = TempDir::new("unique");
    let (db, service, _clock) = service(&tmp);

    service.add("github", "a", None).unwrap();
    let conn = db.writer().unwrap();
    let error = conn
        .execute(
            "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
             VALUES ('github', 'a', 1, 0, 1)",
            [],
        )
        .unwrap_err();
    assert!(
        matches!(
            error,
            rusqlite::Error::SqliteFailure(code, _)
                if code.code == ErrorCode::ConstraintViolation
        ),
        "expected UNIQUE constraint failure, got {error:?}"
    );
}
