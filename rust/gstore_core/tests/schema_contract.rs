//! Wave 0/1 schema contract.
//!
//! These tests are intentionally strict: they assert the exact migrated schema
//! shape, the `download_task` dedup semantics, and that `docs/core-schema.sql`
//! produces the same structure as the embedded refinery migration. Evidence is
//! printed (actual SQL, PK columns, index WHERE clause) so a green run cannot
//! hide a misleading success.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::db;
use rusqlite::{Connection, ErrorCode};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

type ForeignKeyRow = (i64, i64, String, String, Option<String>, String, String);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_schema_{tag}_{}_{}",
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

const REQUIRED_TABLES: &[&str] = &[
    "channels",
    "channel_env",
    "channel_apps",
    "channel_state",
    "channel_packs",
    "apps",
    "apps_fts",
    "categories",
    "app_config",
    "download_task",
    "core_writes",
    "schema_migrations",
];

fn table_exists(conn: &Connection, name: &str) -> bool {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
        [name],
        |row| row.get::<_, i64>(0),
    )
    .unwrap()
        == 1
}

fn object_sql(conn: &Connection, kind: &str, name: &str) -> String {
    conn.query_row(
        "SELECT COALESCE(sql,'') FROM sqlite_master WHERE type=?1 AND name=?2",
        [kind, name],
        |row| row.get(0),
    )
    .unwrap_or_else(|e| panic!("missing {kind} {name}: {e}"))
}

fn table_columns(conn: &Connection, table: &str) -> Vec<String> {
    let sql = format!("PRAGMA table_info(\"{}\")", table.replace('"', "\"\""));
    let mut stmt = conn.prepare(&sql).unwrap();
    stmt.query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
}

fn table_pk_columns(conn: &Connection, table: &str) -> Vec<String> {
    let sql = format!("PRAGMA table_info(\"{}\")", table.replace('"', "\"\""));
    let mut stmt = conn.prepare(&sql).unwrap();
    let mut cols: Vec<(i64, String)> = stmt
        .query_map([], |row| {
            Ok((row.get::<_, i64>(5)?, row.get::<_, String>(1)?))
        })
        .unwrap()
        .map(|r| r.unwrap())
        .filter(|(pk, _)| *pk > 0)
        .collect();
    cols.sort_by_key(|(pk, _)| *pk);
    cols.into_iter().map(|(_, name)| name).collect()
}

fn normalize_sql(sql: &str) -> String {
    let joined = sql.split_whitespace().collect::<Vec<_>>().join(" ");
    joined
        .replace("( ", "(")
        .replace(" )", ")")
        .replace(" ,", ",")
        .replace(" ;", ";")
}

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// Deterministic schema dump: sqlite_master objects (whitespace normalized)
/// plus table_info/index_list/index_info/foreign_key_list for every table.
fn dump_schema(conn: &Connection) -> String {
    let mut out = String::new();

    let mut stmt = conn
        .prepare(
            "SELECT type, name, tbl_name, COALESCE(sql,'') FROM sqlite_master \
             WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
        )
        .unwrap();
    let objects: Vec<(String, String, String, String)> = stmt
        .query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    for (kind, name, tbl_name, sql) in objects {
        out.push_str(&format!(
            "object|{kind}|{name}|{tbl_name}|{}\n",
            normalize_sql(&sql)
        ));
    }

    let mut stmt = conn
        .prepare(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' \
             ORDER BY name",
        )
        .unwrap();
    let tables: Vec<String> = stmt
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();

    for table in tables {
        out.push_str(&format!("table|{table}\n"));

        let mut stmt = conn
            .prepare(&format!("PRAGMA table_info({})", quote_ident(&table)))
            .unwrap();
        let mut cols: Vec<(i64, String, String, i64, Option<String>, i64)> = stmt
            .query_map([], |row| {
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
            .map(|r| r.unwrap())
            .collect();
        cols.sort_by_key(|(cid, _, _, _, _, _)| *cid);
        for (cid, name, ty, notnull, dflt, pk) in cols {
            out.push_str(&format!(
                "column|{table}|{cid}|{name}|{ty}|notnull={notnull}|default={}|pk={pk}\n",
                dflt.unwrap_or_else(|| "<null>".to_string())
            ));
        }

        let mut stmt = conn
            .prepare(&format!("PRAGMA index_list({})", quote_ident(&table)))
            .unwrap();
        let mut indexes: Vec<(String, i64, String, i64)> = stmt
            .query_map([], |row| {
                Ok((row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?))
            })
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
        indexes.sort_by(|a, b| a.0.cmp(&b.0));
        for (name, unique, origin, partial) in indexes {
            out.push_str(&format!(
                "index|{table}|{name}|unique={unique}|origin={origin}|partial={partial}\n"
            ));
            let mut stmt = conn
                .prepare(&format!("PRAGMA index_info({})", quote_ident(&name)))
                .unwrap();
            let mut info: Vec<(i64, i64, Option<String>)> = stmt
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
                .unwrap()
                .map(|r| r.unwrap())
                .collect();
            info.sort_by_key(|(seqno, _, _)| *seqno);
            for (seqno, cid, col) in info {
                out.push_str(&format!(
                    "index_column|{name}|{seqno}|{cid}|{}\n",
                    col.unwrap_or_else(|| "<null>".to_string())
                ));
            }
        }

        let mut stmt = conn
            .prepare(&format!("PRAGMA foreign_key_list({})", quote_ident(&table)))
            .unwrap();
        let mut fks: Vec<ForeignKeyRow> = stmt
            .query_map([], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                ))
            })
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
        fks.sort_by(|a, b| (a.0, a.1).cmp(&(b.0, b.1)));
        for (id, seq, parent, from, to, on_update, on_delete) in fks {
            out.push_str(&format!(
                "fk|{table}|{id}|{seq}|{parent}|{from}|{}|{on_update}|{on_delete}\n",
                to.unwrap_or_else(|| "<null>".to_string())
            ));
        }
    }

    out
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
fn schema_contract_required_tables_and_shape() {
    let dir = TempDir::new("shape");
    let conn = db::open(dir.path()).expect("open core db");

    let journal_mode: String = conn
        .pragma_query_value(None, "journal_mode", |row| row.get(0))
        .unwrap();
    println!("journal_mode = {journal_mode}");
    assert_eq!(journal_mode.to_lowercase(), "wal");

    for table in REQUIRED_TABLES {
        assert!(table_exists(&conn, table), "missing required table {table}");
    }

    // Print the actual sqlite_master rows (misleading-success guard).
    let mut stmt = conn
        .prepare(
            "SELECT type, name, COALESCE(sql,'') FROM sqlite_master \
             WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
        )
        .unwrap();
    let rows: Vec<(String, String, String)> = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    for (kind, name, sql) in &rows {
        println!("sqlite_master {kind} {name}: {}", normalize_sql(sql));
    }

    let pk = table_pk_columns(&conn, "channel_apps");
    println!("channel_apps PK = {pk:?}");
    assert_eq!(pk, vec!["channel_key", "app_id"]);

    let pack_cols = table_columns(&conn, "channel_packs");
    println!("channel_packs columns = {pack_cols:?}");
    assert_eq!(
        pack_cols,
        vec!["key", "pack_hash", "meta_json", "installed_at"]
    );

    // Contentless FTS table + all three sync triggers exist.
    assert!(table_exists(&conn, "apps_fts"));
    let triggers: Vec<String> = {
        let mut stmt = conn
            .prepare(
                "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='apps' \
                 ORDER BY name",
            )
            .unwrap();
        stmt.query_map([], |row| row.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    };
    println!("apps triggers = {triggers:?}");
    assert_eq!(
        triggers,
        vec!["apps_fts_delete", "apps_fts_insert", "apps_fts_update"]
    );

    // FTS triggers actually index inserts/updates/deletes.
    conn.execute(
        "INSERT INTO apps(appId, name, user, repositories, icon, des, category) \
         VALUES ('a1', 'Needle App', 'u', 'r', 'i', 'short summary', 'tools')",
        [],
    )
    .unwrap();
    let hits: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH 'Needle'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(hits, 1, "insert trigger must populate apps_fts");
    conn.execute("UPDATE apps SET name='Haystack App' WHERE appId='a1'", [])
        .unwrap();
    let hits: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH 'Needle'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(hits, 0, "update trigger must remove the stale FTS row");
    conn.execute("DELETE FROM apps WHERE appId='a1'", [])
        .unwrap();
    let hits: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH 'Haystack'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(hits, 0, "delete trigger must remove the FTS row");

    // Partial unique index: exact WHERE clause over ACTIVE statuses only.
    let index_sql = normalize_sql(&object_sql(&conn, "index", "ux_download_task_active_dedup"));
    println!("dedup index SQL = {index_sql}");
    assert_eq!(
        index_sql,
        "CREATE UNIQUE INDEX ux_download_task_active_dedup ON \
         download_task(dedup_key) WHERE dedup_key IS NOT NULL AND status IN \
         ('queued', 'connecting', 'downloading', 'running')"
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    );

    for forbidden in [
        "'completed'",
        "'failed'",
        "'cancelled'",
        "'removed'",
        "'paused'",
        "'needs_restart'",
    ] {
        assert!(
            !index_sql.contains(forbidden),
            "partial index must not include non-active status {forbidden}: {index_sql}"
        );
    }

    let migration_rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
            row.get(0)
        })
        .unwrap();
    println!("schema_migrations rows = {migration_rows}");
    assert_eq!(migration_rows, 3);
}

#[test]
fn schema_contract_dedup_active_unique_with_terminal_reinsert() {
    let dir = TempDir::new("dedup");
    let conn = db::open(dir.path()).expect("open core db");

    let insert = |status: &str| {
        conn.execute(
            "INSERT INTO download_task(dedup_key, status, app_id) VALUES ('app:demo:1:demo.apk', ?1, 'demo')",
            [status],
        )
    };

    insert("downloading").expect("first ACTIVE row must insert");
    assert_constraint(
        insert("queued"),
        "second ACTIVE row with the same dedup_key",
    );
    assert_constraint(
        insert("connecting"),
        "third ACTIVE row with the same dedup_key",
    );

    // NULL dedup keys never collide.
    conn.execute(
        "INSERT INTO download_task(dedup_key, status, app_id) VALUES (NULL, 'downloading', 'n1')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO download_task(dedup_key, status, app_id) VALUES (NULL, 'downloading', 'n2')",
        [],
    )
    .unwrap();

    // Move the only dedup row to a terminal status: re-insert must succeed.
    conn.execute(
        "UPDATE download_task SET status='completed' WHERE dedup_key='app:demo:1:demo.apk'",
        [],
    )
    .unwrap();
    insert("queued").expect("re-insert after COMPLETED must succeed");

    // The new ACTIVE row now blocks a second active one again.
    assert_constraint(
        insert("downloading"),
        "new ACTIVE row after terminal re-insert",
    );

    // PAUSED is resumable and not ACTIVE, so it does not block a new row.
    conn.execute(
        "UPDATE download_task SET status='paused' WHERE dedup_key='app:demo:1:demo.apk' AND status='queued'",
        [],
    )
    .unwrap();
    insert("downloading").expect("PAUSED is not an ACTIVE status");

    // CANCELLED is terminal (matches gstore_mod_download TaskStatus::is_terminal).
    conn.execute(
        "UPDATE download_task SET status='cancelled' WHERE dedup_key='app:demo:1:demo.apk' AND status='downloading'",
        [],
    )
    .unwrap();
    insert("queued").expect("re-insert after CANCELLED must succeed");

    let mut stmt = conn
        .prepare("SELECT id, COALESCE(dedup_key,'<null>'), status FROM download_task ORDER BY id")
        .unwrap();
    let rows: Vec<(i64, String, String)> = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    println!("download_task rows = {rows:?}");
}

#[test]
fn schema_contract_malformed_rows_are_constraint_errors() {
    let dir = TempDir::new("malformed");
    let conn = db::open(dir.path()).expect("open core db");

    assert_constraint(
        conn.execute(
            "INSERT INTO channels(key, kind, name) VALUES (NULL, 'custom', 'null key')",
            [],
        ),
        "NULL channels.key",
    );
    conn.execute(
        "INSERT INTO channels(key, kind, name) VALUES ('c1', 'custom', 'ok')",
        [],
    )
    .unwrap();
    assert_constraint(
        conn.execute(
            "INSERT INTO channels(key, kind, name) VALUES ('c1', 'custom', 'duplicate')",
            [],
        ),
        "duplicate channels.key",
    );

    assert_constraint(
        conn.execute(
            "INSERT INTO channel_apps(channel_key, app_id) VALUES ('c1', NULL)",
            [],
        ),
        "NULL channel_apps.app_id",
    );
    conn.execute(
        "INSERT INTO channel_apps(channel_key, app_id) VALUES ('c1', 'a1')",
        [],
    )
    .unwrap();
    assert_constraint(
        conn.execute(
            "INSERT INTO channel_apps(channel_key, app_id) VALUES ('c1', 'a1')",
            [],
        ),
        "duplicate channel_apps PK",
    );

    assert_constraint(
        conn.execute(
            "INSERT INTO channel_packs(key, pack_hash, meta_json, installed_at) \
             VALUES (NULL, 'h', '{}', 0)",
            [],
        ),
        "NULL channel_packs.key",
    );

    assert_constraint(
        conn.execute(
            "INSERT INTO download_task(status, install_after_download) VALUES ('queued', 2)",
            [],
        ),
        "invalid download_task.install_after_download",
    );
}

#[test]
fn schema_contract_docs_sql_matches_migrated_schema() {
    let dir = TempDir::new("docs");
    let migrated = db::open(dir.path()).expect("open core db");
    let migrated_dump = dump_schema(&migrated);

    let docs = Connection::open_in_memory().expect("open docs db");
    docs.execute_batch(include_str!("../../../docs/core-schema.sql"))
        .expect("docs/core-schema.sql must execute on a fresh SQLite database");
    let docs_dump = dump_schema(&docs);

    assert_eq!(
        migrated_dump, docs_dump,
        "\n--- migrated schema ---\n{migrated_dump}\n--- docs/core-schema.sql schema ---\n{docs_dump}"
    );

    let migrated_version: i64 = migrated
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    let docs_version: i64 = docs
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(migrated_version, 3);
    assert_eq!(docs_version, 3);
    println!("schema dumps match ({} bytes)", migrated_dump.len());
}

#[test]
fn schema_contract_reopen_does_not_reapply_or_alter_schema() {
    let dir = TempDir::new("reopen");
    let handle = db::DbHandle::open(dir.path()).expect("first open");

    let (dump1, count1) = {
        let conn = handle.writer().unwrap();
        let dump = dump_schema(&conn);
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
                row.get(0)
            })
            .unwrap();
        (dump, count)
    };
    drop(handle);

    let reopened = db::DbHandle::open(dir.path()).expect("second open");
    let (dump2, count2) = {
        let conn = reopened.writer().unwrap();
        let dump = dump_schema(&conn);
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
                row.get(0)
            })
            .unwrap();
        (dump, count)
    };

    assert_eq!(count1, count2, "reopening must not re-apply migrations");
    assert_eq!(count1, 3);
    assert_eq!(dump1, dump2, "reopening must not alter the schema");

    // Readers are separate read-only connections; the single writer stays guarded.
    let reader = reopened.reader().expect("reader connection");
    let err = reader
        .execute(
            "INSERT INTO channels(key, kind, name) VALUES ('r1', 'custom', 'read only')",
            [],
        )
        .expect_err("readers must be read-only");
    println!("reader rejected write: {err}");
    let name: String = reopened
        .with_writer(|conn| {
            conn.execute(
                "INSERT INTO channels(key, kind, name) VALUES ('w1', 'custom', 'writer')",
                [],
            )
            .map_err(|e| db::DbError(e.to_string()))?;
            Ok(())
        })
        .and_then(|()| {
            reopened.with_reader(|conn| {
                conn.query_row("SELECT name FROM channels WHERE key='w1'", [], |row| {
                    row.get(0)
                })
                .map_err(|e| db::DbError(e.to_string()))
            })
        })
        .expect("writer + reader roundtrip");
    assert_eq!(name, "writer");
}

#[test]
fn schema_contract_writes_migrated_db_fixture_for_sqlite_cli() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let evidence = root.join("target/test-evidence");
    std::fs::create_dir_all(&evidence).unwrap();
    let db_path = evidence.join("04-migrated.db");
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", db_path.display()));
    }
    let conn = db::open_at(&db_path).expect("create evidence db");
    let tables: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
            row.get(0)
        })
        .unwrap();
    println!(
        "evidence db = {} (objects={tables}, schema_migrations={count})",
        db_path.display()
    );
    drop(conn);
    assert!(db_path.exists());
}
