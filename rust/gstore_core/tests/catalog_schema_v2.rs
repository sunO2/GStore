//! Wave 2 catalog/update schema contract.
//!
//! Asserts the exact V2 table shapes, the contentless FTS rebuild, V1 row
//! preservation, and that applying the V2 SQL twice is a no-op. Evidence is
//! printed (actual PRAGMA output and integrity checks) so a green run cannot
//! hide a misleading success.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::{db, migration};
use rusqlite::{Connection, ErrorCode};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

const V1_SQL: &str = include_str!("../migrations/V1__core_schema.sql");
const V2_SQL: &str = include_str!("../migrations/V2__catalog_update.sql");

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_catalog_v2_{tag}_{}_{}",
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

struct Column {
    name: &'static str,
    ty: &'static str,
    notnull: i64,
    default: Option<&'static str>,
    pk: i64,
}

fn fresh_db(dir: &Path) -> Connection {
    let mut conn = Connection::open(dir.join("core.db")).unwrap();
    migration::apply_core_schema(&mut conn).unwrap();
    conn
}

fn v1_db() -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(V1_SQL).unwrap();
    conn
}

fn object_exists(conn: &Connection, kind: &str, name: &str) -> bool {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type=?1 AND name=?2",
        [kind, name],
        |row| row.get::<_, i64>(0),
    )
    .unwrap()
        == 1
}

fn user_version(conn: &Connection) -> i64 {
    conn.pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap()
}

fn count(conn: &Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |row| row.get(0)).unwrap()
}

fn assert_table(conn: &Connection, table: &str, expected: &[Column]) {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info(\"{table}\")"))
        .unwrap();
    let actual: Vec<(String, String, i64, Option<String>, i64)> = stmt
        .query_map([], |row| {
            Ok((
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
            ))
        })
        .unwrap()
        .map(|row| row.unwrap())
        .collect();
    assert_eq!(
        actual.len(),
        expected.len(),
        "{table}: column count mismatch, actual={actual:?}"
    );
    for (index, want) in expected.iter().enumerate() {
        let (name, ty, notnull, default, pk) = &actual[index];
        assert_eq!(name, want.name, "{table}: cid {index} name");
        assert_eq!(ty, want.ty, "{table}.{name}: type");
        assert_eq!(*notnull, want.notnull, "{table}.{name}: notnull");
        assert_eq!(default.as_deref(), want.default, "{table}.{name}: default");
        assert_eq!(*pk, want.pk, "{table}.{name}: pk");
    }
    println!("{table} columns = {actual:?}");
}

fn assert_constraint<T: std::fmt::Debug>(result: Result<T, rusqlite::Error>, label: &str) {
    match result {
        Ok(value) => panic!("{label}: expected a constraint error, got Ok({value:?})"),
        Err(rusqlite::Error::SqliteFailure(err, msg)) => {
            assert_eq!(
                err.code,
                ErrorCode::ConstraintViolation,
                "{label}: expected SQLITE_CONSTRAINT, got {err:?} ({msg:?})"
            );
            println!("{label}: rejected with {err:?} ({msg:?})");
        }
        Err(other) => panic!("{label}: expected SqliteFailure constraint, got {other:?}"),
    }
}

#[test]
fn migration_v2_contract() {
    let dir = TempDir::new("contract");
    let conn = fresh_db(dir.path());

    assert_eq!(
        user_version(&conn),
        i64::from(gstore_core::migration::CORE_SCHEMA_VERSION),
        "fresh schema must carry the current core schema version"
    );
    println!("user_version = {}", user_version(&conn));

    assert_table(
        &conn,
        "added_apps",
        &[
            Column {
                name: "id",
                ty: "INTEGER",
                notnull: 0,
                default: None,
                pk: 1,
            },
            Column {
                name: "channel_id",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "app_id",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "add_time",
                ty: "INTEGER",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "sort_order",
                ty: "INTEGER",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "is_enabled",
                ty: "INTEGER",
                notnull: 1,
                default: Some("1"),
                pk: 0,
            },
        ],
    );

    assert_table(
        &conn,
        "added_app_tags",
        &[
            Column {
                name: "channel_id",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 1,
            },
            Column {
                name: "app_id",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 2,
            },
            Column {
                name: "tag",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 3,
            },
            Column {
                name: "add_time",
                ty: "INTEGER",
                notnull: 1,
                default: None,
                pk: 0,
            },
        ],
    );

    assert_table(
        &conn,
        "update_state",
        &[
            Column {
                name: "app_id",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 1,
            },
            Column {
                name: "channel_key",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 2,
            },
            Column {
                name: "latest_version",
                ty: "TEXT",
                notnull: 0,
                default: None,
                pk: 0,
            },
            Column {
                name: "status",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "checked_at",
                ty: "INTEGER",
                notnull: 0,
                default: None,
                pk: 0,
            },
            Column {
                name: "payload_json",
                ty: "TEXT",
                notnull: 0,
                default: None,
                pk: 0,
            },
        ],
    );

    assert_table(
        &conn,
        "update_log",
        &[
            Column {
                name: "id",
                ty: "INTEGER",
                notnull: 0,
                default: None,
                pk: 1,
            },
            Column {
                name: "app_id",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "channel_key",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "from_version",
                ty: "TEXT",
                notnull: 0,
                default: None,
                pk: 0,
            },
            Column {
                name: "to_version",
                ty: "TEXT",
                notnull: 0,
                default: None,
                pk: 0,
            },
            Column {
                name: "status",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "checked_at",
                ty: "INTEGER",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "payload_json",
                ty: "TEXT",
                notnull: 0,
                default: None,
                pk: 0,
            },
        ],
    );

    assert_table(
        &conn,
        "outbox",
        &[
            Column {
                name: "id",
                ty: "INTEGER",
                notnull: 0,
                default: None,
                pk: 1,
            },
            Column {
                name: "kind",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "payload_json",
                ty: "TEXT",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "status",
                ty: "TEXT",
                notnull: 1,
                default: Some("'pending'"),
                pk: 0,
            },
            Column {
                name: "attempts",
                ty: "INTEGER",
                notnull: 1,
                default: Some("0"),
                pk: 0,
            },
            Column {
                name: "next_attempt_at",
                ty: "INTEGER",
                notnull: 0,
                default: None,
                pk: 0,
            },
            Column {
                name: "created_at",
                ty: "INTEGER",
                notnull: 1,
                default: None,
                pk: 0,
            },
            Column {
                name: "updated_at",
                ty: "INTEGER",
                notnull: 1,
                default: None,
                pk: 0,
            },
        ],
    );

    // added_apps: UNIQUE(channel_id, app_id) rejects a duplicate but allows the
    // same app id on a different channel.
    conn.execute(
        "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order) VALUES ('x', 'a', 1, 0)",
        [],
    )
    .unwrap();
    assert_constraint(
        conn.execute(
            "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order) VALUES ('x', 'a', 2, 0)",
            [],
        ),
        "duplicate added_apps (channel_id, app_id)",
    );
    conn.execute(
        "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order) VALUES ('y', 'a', 3, 1)",
        [],
    )
    .expect("same app on another channel must be accepted");
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM added_apps"), 2);

    // added_app_tags: composite primary key rejects duplicates.
    conn.execute(
        "INSERT INTO added_app_tags(channel_id, app_id, tag, add_time) VALUES ('x', 'a', 't', 1)",
        [],
    )
    .unwrap();
    assert_constraint(
        conn.execute(
            "INSERT INTO added_app_tags(channel_id, app_id, tag, add_time) VALUES ('x', 'a', 't', 2)",
            [],
        ),
        "duplicate added_app_tags PK",
    );

    // update_state: composite PK rejects duplicates and supports upsert.
    conn.execute(
        "INSERT INTO update_state(app_id, channel_key, latest_version, status, checked_at) \
         VALUES ('a', 'github', '1.0', 'ok', 100)",
        [],
    )
    .unwrap();
    assert_constraint(
        conn.execute(
            "INSERT INTO update_state(app_id, channel_key, latest_version, status, checked_at) \
             VALUES ('a', 'github', '2.0', 'ok', 200)",
            [],
        ),
        "duplicate update_state PK",
    );
    conn.execute(
        "INSERT INTO update_state(app_id, channel_key, latest_version, status, checked_at) \
         VALUES ('a', 'github', '2.0', 'checked', 200) \
         ON CONFLICT(app_id, channel_key) DO UPDATE SET \
             latest_version = excluded.latest_version, \
             status = excluded.status, \
             checked_at = excluded.checked_at",
        [],
    )
    .unwrap();
    let (version, status) = conn
        .query_row(
            "SELECT latest_version, status FROM update_state WHERE app_id='a' AND channel_key='github'",
            [],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .unwrap();
    assert_eq!((version.as_str(), status.as_str()), ("2.0", "checked"));
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM update_state"), 1);

    // outbox defaults.
    conn.execute(
        "INSERT INTO outbox(kind, payload_json, created_at, updated_at) \
         VALUES ('catalog', '{}', 10, 10)",
        [],
    )
    .unwrap();
    let (status, attempts) = conn
        .query_row("SELECT status, attempts FROM outbox", [], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })
        .unwrap();
    assert_eq!(status, "pending");
    assert_eq!(attempts, 0);

    // update_log autoincrement.
    conn.execute(
        "INSERT INTO update_log(app_id, channel_key, to_version, status, checked_at) \
         VALUES ('a', 'github', '1.1', 'seen', 1)",
        [],
    )
    .unwrap();
    let first_id: i64 = conn
        .query_row("SELECT id FROM update_log", [], |row| row.get(0))
        .unwrap();
    conn.execute(
        "INSERT INTO update_log(app_id, channel_key, to_version, status, checked_at) \
         VALUES ('a', 'github', '1.2', 'seen', 2)",
        [],
    )
    .unwrap();
    let ids: Vec<i64> = conn
        .prepare("SELECT id FROM update_log ORDER BY id")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(|row| row.unwrap())
        .collect();
    assert_eq!(ids.len(), 2);
    assert!(ids[1] > ids[0], "autoincrement ids must increase: {ids:?}");
    assert_eq!(ids[0], first_id);

    // FTS shape: contentless, appId UNINDEXED, new triggers only.
    let fts_sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE name='apps_fts'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    println!("apps_fts SQL = {fts_sql}");
    assert!(
        fts_sql.contains("content=''"),
        "apps_fts must be contentless: {fts_sql}"
    );
    assert!(
        fts_sql.contains("appId UNINDEXED"),
        "apps_fts must declare appId UNINDEXED: {fts_sql}"
    );
    assert!(
        !fts_sql.contains("contentless_delete"),
        "apps_fts DDL must match Dart: {fts_sql}"
    );
    for old in ["apps_ai", "apps_ad", "apps_au"] {
        assert!(
            !object_exists(&conn, "trigger", old),
            "V1 trigger {old} must be gone"
        );
    }
    for new in ["apps_fts_insert", "apps_fts_delete", "apps_fts_update"] {
        assert!(
            object_exists(&conn, "trigger", new),
            "V2 trigger {new} must exist"
        );
    }

    // Contentless FTS does not store column values, so resolve appId through
    // the `apps` rowid join.
    conn.execute(
        "INSERT INTO apps(appId, name, user, repositories, icon, des, category) \
         VALUES ('com.topjohnwu.magisk', 'Magisk Manager', 'topjohnwu', 'Magisk', 'i', \
         'systemless root', 'TOOLS')",
        [],
    )
    .unwrap();
    let found: Vec<String> = conn
        .prepare(
            "SELECT a.appId FROM apps_fts JOIN apps a ON a.rowid = apps_fts.rowid \
             WHERE apps_fts MATCH '\"magisk\"*'",
        )
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(|row| row.unwrap())
        .collect();
    assert_eq!(found, vec!["com.topjohnwu.magisk".to_string()]);
    println!("FTS insert match = {found:?}");

    conn.execute(
        "UPDATE apps SET name='V2Ray NG' WHERE appId='com.topjohnwu.magisk'",
        [],
    )
    .unwrap();
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH '\"magisk\"*'"
        ),
        0,
        "update trigger must drop the old term"
    );
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH '\"v2ray\"*'"
        ),
        1,
        "update trigger must index the new term"
    );

    conn.execute("DELETE FROM apps WHERE appId='com.topjohnwu.magisk'", [])
        .unwrap();
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH '\"v2ray\"*'"
        ),
        0,
        "delete trigger must remove the FTS row"
    );

    let integrity: String = conn
        .pragma_query_value(None, "integrity_check", |row| row.get(0))
        .unwrap();
    println!("integrity_check = {integrity}");
    assert_eq!(integrity, "ok");
}

#[test]
fn migration_v2_preserves_v1_rows() {
    let conn = v1_db();
    assert_eq!(user_version(&conn), 1, "V1 SQL must stamp version 1");

    for (app_id, name) in [
        ("com.topjohnwu.magisk", "Magisk"),
        ("com.v2ray.ang", "v2rayNG"),
        ("com.x8bit.bitwarden", "Bitwarden"),
    ] {
        conn.execute(
            "INSERT INTO apps(appId, name, user, repositories, icon, des, category) \
             VALUES (?1, ?2, 'u', 'r', 'i', 'summary', 'TOOLS')",
            rusqlite::params![app_id, name],
        )
        .unwrap();
    }
    conn.execute(
        "INSERT INTO categories(id, description, icon) VALUES ('TOOLS', '工具', 'i')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO categories(id, description, icon) VALUES ('MEDIA', '影音', 'i')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO app_config(version, proxy) VALUES ('0.0.12', NULL)",
        [],
    )
    .unwrap();

    conn.execute_batch(V2_SQL).unwrap();

    assert_eq!(user_version(&conn), 2);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM apps"), 3);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM categories"), 2);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM app_config"), 1);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM apps_fts"), 3);

    for term in ["magisk", "v2ray", "bitwarden"] {
        assert_eq!(
            count(
                &conn,
                &format!("SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH '\"{term}\"*'")
            ),
            1,
            "V2 backfill must index {term}"
        );
    }
    println!("preserved: apps=3 categories=2 app_config=1 fts=3");
}

#[test]
fn migration_v2_is_idempotent() {
    let conn = v1_db();
    conn.execute(
        "INSERT INTO apps(appId, name, user, repositories, icon, des, category) \
         VALUES ('a1', 'Magisk', 'u', 'r', 'i', 'summary', 'TOOLS')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO apps(appId, name, user, repositories, icon, des, category) \
         VALUES ('a2', 'v2rayNG', 'u', 'r', 'i', 'summary', 'NET')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO categories(id, description, icon) VALUES ('TOOLS', '工具', 'i')",
        [],
    )
    .unwrap();

    conn.execute_batch(V2_SQL).unwrap();
    let before = (
        count(&conn, "SELECT COUNT(*) FROM apps"),
        count(&conn, "SELECT COUNT(*) FROM categories"),
        count(&conn, "SELECT COUNT(*) FROM added_apps"),
        count(&conn, "SELECT COUNT(*) FROM added_app_tags"),
        count(&conn, "SELECT COUNT(*) FROM update_state"),
        count(&conn, "SELECT COUNT(*) FROM update_log"),
        count(&conn, "SELECT COUNT(*) FROM outbox"),
        count(&conn, "SELECT COUNT(*) FROM apps_fts"),
        user_version(&conn),
    );
    println!("after first apply: {before:?}");

    conn.execute_batch(V2_SQL).unwrap();
    let after = (
        count(&conn, "SELECT COUNT(*) FROM apps"),
        count(&conn, "SELECT COUNT(*) FROM categories"),
        count(&conn, "SELECT COUNT(*) FROM added_apps"),
        count(&conn, "SELECT COUNT(*) FROM added_app_tags"),
        count(&conn, "SELECT COUNT(*) FROM update_state"),
        count(&conn, "SELECT COUNT(*) FROM update_log"),
        count(&conn, "SELECT COUNT(*) FROM outbox"),
        count(&conn, "SELECT COUNT(*) FROM apps_fts"),
        user_version(&conn),
    );
    println!("after second apply: {after:?}");
    assert_eq!(before, after, "second V2 apply must be a no-op");
    assert_eq!(after.8, 2);
    assert_eq!(after.7, 2, "FTS must keep one row per app, not duplicate");

    let integrity: String = conn
        .pragma_query_value(None, "integrity_check", |row| row.get(0))
        .unwrap();
    println!("integrity_check = {integrity}");
    assert_eq!(integrity, "ok");
}

#[test]
fn catalog_fts_helper_reports_presence() {
    let mut conn = Connection::open_in_memory().unwrap();
    assert!(
        !migration::catalog_fts_available(&conn),
        "empty database has no apps_fts"
    );

    migration::apply_core_schema(&mut conn).unwrap();
    assert!(
        migration::catalog_fts_available(&conn),
        "migrated database must report apps_fts"
    );
    println!("catalog_fts_available = true after apply_core_schema");
}

#[test]
fn catalog_schema_v2_backup_before_upgrade() {
    let dir = TempDir::new("backup");
    let db_path = dir.path().join("gstore_core.db");
    {
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(V1_SQL).unwrap();
        for (app_id, name) in [
            ("com.topjohnwu.magisk", "Magisk"),
            ("com.v2ray.ang", "v2rayNG"),
            ("com.x8bit.bitwarden", "Bitwarden"),
        ] {
            conn.execute(
                "INSERT INTO apps(appId, name, user, repositories, icon, des, category) \
                 VALUES (?1, ?2, 'u', 'r', 'i', 'summary', 'TOOLS')",
                rusqlite::params![app_id, name],
            )
            .unwrap();
        }
        conn.execute(
            "INSERT INTO categories(id, description, icon) VALUES ('TOOLS', '工具', 'i')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO categories(id, description, icon) VALUES ('MEDIA', '影音', 'i')",
            [],
        )
        .unwrap();
        assert_eq!(user_version(&conn), 1);
    }

    let conn = db::open_at(&db_path).expect("upgrade V1 database");

    assert_eq!(
        user_version(&conn),
        i64::from(gstore_core::migration::CORE_SCHEMA_VERSION)
    );
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM apps"), 3);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM categories"), 2);

    let mut backups: Vec<PathBuf> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.contains(".bak-v1-"))
        })
        .collect();
    backups.sort();
    println!("backups = {backups:?}");
    assert_eq!(backups.len(), 1, "exactly one V1 backup: {backups:?}");

    let backup = Connection::open(&backups[0]).expect("open backup");
    assert_eq!(user_version(&backup), 1, "backup keeps the V1 version");
    assert_eq!(count(&backup, "SELECT COUNT(*) FROM apps"), 3);
    assert_eq!(count(&backup, "SELECT COUNT(*) FROM categories"), 2);
    println!(
        "backup = {} user_version={} apps={} categories={}",
        backups[0].display(),
        user_version(&backup),
        count(&backup, "SELECT COUNT(*) FROM apps"),
        count(&backup, "SELECT COUNT(*) FROM categories")
    );
    drop(backup);
    drop(conn);

    let reopened = db::open_at(&db_path).expect("reopen at current version");
    assert_eq!(
        user_version(&reopened),
        i64::from(gstore_core::migration::CORE_SCHEMA_VERSION)
    );
    let backups_after: Vec<PathBuf> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.contains(".bak-v1-"))
        })
        .collect();
    assert_eq!(
        backups_after.len(),
        1,
        "current-version reopen must not create another backup: {backups_after:?}"
    );
}
