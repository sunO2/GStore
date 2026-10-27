//! Wave 3 Todo 7: legacy download migration + on-disk parity contract.
//!
//! Every test name contains `download_legacy_parity` so the plan's QA command
//! (`cargo test ... download_legacy_parity`) selects this whole file. The tests
//! cover the status table, path/dedup parity against the shared JSON fixture,
//! part/merge/resume rules, idempotency, core-row-wins, missing databases, and
//! an in-process drift detector that must fail on status/path mutation.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use gstore_core::db::SharedConn;
use gstore_core::download::legacy::{migrate_legacy_floor_db, migrate_module_db, MigrationReport};
use gstore_core::download::parity::{
    merge_temp_role, part_files, resume_expected_bytes, status_core_label, status_enum_label,
};
use gstore_core::download::port::{DownloadPort, ModuleBridge, ModuleDownloadPort};
use gstore_core::download::strategy::resolve_save_path;
use gstore_core::download::NEEDS_RESTART;
use rusqlite::Connection;
use serde_json::{json, Value};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_download_legacy_parity_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create temp dir");
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

fn core_conn() -> Connection {
    let mut conn = Connection::open_in_memory().expect("in-memory core");
    gstore_core::migration::apply_core_schema(&mut conn).expect("core schema");
    conn
}

fn create_floor_db(path: &Path, rows: &[(i64, &str, &str, i64)]) {
    let conn = Connection::open(path).expect("open floor fixture");
    conn.execute_batch(
        "CREATE TABLE download_task (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            appId TEXT NOT NULL,
            appName TEXT NOT NULL,
            version TEXT NOT NULL,
            fileName TEXT NOT NULL,
            url TEXT NOT NULL,
            filePath TEXT NOT NULL,
            total INTEGER NOT NULL,
            received INTEGER NOT NULL,
            status INTEGER NOT NULL,
            speedBps INTEGER NOT NULL DEFAULT 0,
            etaSec INTEGER,
            error TEXT,
            segments TEXT,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            dedupKey TEXT,
            installAfterDownload INTEGER NOT NULL DEFAULT 0
        );",
    )
    .expect("floor DDL");
    for (index, (status, app_id, dest, received)) in rows.iter().enumerate() {
        conn.execute(
            "INSERT INTO download_task
             (appId, appName, version, fileName, url, filePath, total, received,
              status, createdAt, updatedAt, dedupKey, installAfterDownload)
             VALUES (?1, 'Example', '1.0.0', 'app.bin', ?2, ?3, 1000, ?4, ?5,
                     1700000000000, 1700000001000, ?6, 0)",
            rusqlite::params![
                app_id,
                format!("https://example.test/{}.bin", app_id),
                dest,
                received,
                status,
                format!("app:{index}"),
            ],
        )
        .expect("insert floor row");
    }
}

fn create_module_db(path: &Path, rows: &[(i64, &str, &str, i64)]) {
    let conn = Connection::open(path).expect("open module fixture");
    conn.execute_batch(
        "CREATE TABLE download_task (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_id TEXT NOT NULL,
            app_name TEXT NOT NULL,
            version TEXT NOT NULL,
            file_name TEXT NOT NULL,
            url TEXT NOT NULL,
            file_path TEXT NOT NULL,
            total INTEGER NOT NULL DEFAULT 0,
            received INTEGER NOT NULL DEFAULT 0,
            status INTEGER NOT NULL,
            dedup_key TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );",
    )
    .expect("module DDL");
    for (id, app_id, dedup, status) in rows {
        conn.execute(
            "INSERT INTO download_task
             (id, app_id, app_name, version, file_name, url, file_path, total,
              received, status, dedup_key, created_at, updated_at)
             VALUES (?1, ?2, 'Module', '1.0.0', 'app.bin', 'https://example.test/m.bin',
                     '/tmp/module-app.bin', 1000, 500, ?3, ?4, 1, 2)",
            rusqlite::params![id, app_id, status, dedup],
        )
        .expect("insert module row");
    }
}

#[test]
fn download_legacy_parity_status_mapping_covers_all_codes() {
    let dir = TempDir::new("status");
    let floor = dir.join("download_task.db");
    let cases = [
        (0, "running"),
        (1, "running"),
        (2, "running"),
        (3, "paused"),
        (4, "completed"),
        (5, "failed"),
        (6, "cancelled"),
        (9, "failed"),
    ];
    let rows: Vec<(i64, &str, &str, i64)> = cases
        .iter()
        .map(|(code, _)| (*code, "com.example.status", "/tmp/status.bin", 10))
        .collect();
    create_floor_db(&floor, &rows);

    let core = core_conn();
    let report = migrate_legacy_floor_db(&core, &floor).expect("first migration");
    assert_eq!(
        report,
        MigrationReport {
            inserted: cases.len(),
            updated: 0,
            skipped: 0
        }
    );

    let mut stmt = core
        .prepare("SELECT status FROM download_task ORDER BY id")
        .expect("prepare statuses");
    let stored: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .expect("query statuses")
        .collect::<Result<_, _>>()
        .expect("read statuses");
    let expected: Vec<String> = cases.iter().map(|(_, label)| label.to_string()).collect();
    assert_eq!(stored, expected);
    for (code, label) in cases {
        assert_eq!(status_core_label(code), label);
    }
    assert_eq!(status_enum_label(0), "queued");
    assert_eq!(status_enum_label(2), "downloading");
    assert_eq!(status_enum_label(7), "failed");
}

#[derive(serde::Deserialize)]
struct PathCase {
    name: String,
    save_file_name: Option<String>,
    file_name: String,
    downloads_dir: Option<String>,
    docs_dir: String,
    expected: String,
}

#[test]
fn download_legacy_parity_paths_match_shared_fixture() {
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../test/fixtures/download_path_cases.json");
    let raw = std::fs::read_to_string(&fixture).expect("read download_path_cases.json");
    let cases: Vec<PathCase> = serde_json::from_str(&raw).expect("parse download_path_cases.json");
    assert!(!cases.is_empty());

    for case in &cases {
        let resolved = resolve_save_path(
            case.downloads_dir.as_deref().map(Path::new),
            Path::new(&case.docs_dir),
            case.save_file_name.as_deref(),
            &case.file_name,
        )
        .to_string_lossy()
        .into_owned();
        assert_eq!(
            resolved, case.expected,
            "resolve_save_path mismatch for {:?}",
            case.name
        );

        let dir = TempDir::new("path");
        let floor = dir.join("download_task.db");
        let conn = Connection::open(&floor).expect("open floor");
        conn.execute_batch(
            "CREATE TABLE download_task (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                appId TEXT NOT NULL, appName TEXT NOT NULL, version TEXT NOT NULL,
                fileName TEXT NOT NULL, url TEXT NOT NULL, filePath TEXT NOT NULL,
                total INTEGER NOT NULL, received INTEGER NOT NULL, status INTEGER NOT NULL,
                createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL, dedupKey TEXT
            );",
        )
        .expect("DDL");
        conn.execute(
            "INSERT INTO download_task
             (appId, appName, version, fileName, url, filePath, total, received,
              status, createdAt, updatedAt, dedupKey)
             VALUES ('com.example.path', 'Example', '1.0.0', ?1,
                     'https://example.test/path.bin', ?2, 10, 0, 2, 1, 2, ?3)",
            rusqlite::params![case.file_name, case.expected, format!("path:{}", case.name)],
        )
        .expect("insert path row");
        drop(conn);

        let core = core_conn();
        migrate_legacy_floor_db(&core, &floor).expect("migrate path row");
        let dest: String = core
            .query_row("SELECT dest_path FROM download_task", [], |row| row.get(0))
            .expect("read dest");
        assert_eq!(
            dest, case.expected,
            "migrated dest_path mismatch for {:?}",
            case.name
        );
    }
}

#[test]
fn download_legacy_parity_part_inventory_resume_and_merge_roles() {
    let dir = TempDir::new("parts");
    let paused = dir.join("paused.bin");
    std::fs::write(format!("{}.part0", paused.display()), vec![1u8; 400]).expect("part0");
    std::fs::write(format!("{}.part1", paused.display()), vec![2u8; 600]).expect("part1");
    std::fs::write(format!("{}.part", paused.display()), vec![3u8; 50]).expect("stray part");
    std::fs::write(format!("{}.temp", paused.display()), vec![4u8; 700]).expect("temp");

    assert_eq!(
        part_files(&paused),
        vec![
            gstore_core::download::parity::PartFile {
                index: 0,
                bytes: 400
            },
            gstore_core::download::parity::PartFile {
                index: 1,
                bytes: 600
            }
        ]
    );
    assert_eq!(merge_temp_role(&paused), Some("temp"));
    assert_eq!(
        resume_expected_bytes(&paused),
        700,
        ".temp must win over the part sum"
    );

    let merged = dir.join("rust-merge.bin");
    std::fs::write(format!("{}.part0", merged.display()), vec![5u8; 300]).expect("merge part");
    std::fs::write(format!("{}.merge", merged.display()), vec![6u8; 300]).expect("merge temp");
    assert_eq!(part_files(&merged).len(), 1);
    assert_eq!(merge_temp_role(&merged), Some("merge"));
    assert_eq!(resume_expected_bytes(&merged), 300);

    let completed = dir.join("completed.bin");
    std::fs::write(&completed, vec![7u8; 2048]).expect("final file");
    std::fs::write(format!("{}.part0", completed.display()), vec![8u8; 10]).expect("stale part");
    assert_eq!(
        resume_expected_bytes(&completed),
        2048,
        "the final file must win over stale parts"
    );
}

#[test]
fn download_legacy_parity_second_migration_is_idempotent() {
    let dir = TempDir::new("idempotent");
    let floor = dir.join("download_task.db");
    create_floor_db(
        &floor,
        &[
            (3, "com.example.one", "/tmp/one.bin", 10),
            (4, "com.example.two", "/tmp/two.bin", 10),
        ],
    );
    let module = dir.join("download.db");
    create_module_db(
        &module,
        &[
            (101, "com.example.one", "app:0", 2),
            (102, "com.example.module-only", "module:only", 4),
        ],
    );

    let core = core_conn();
    let floor_first = migrate_legacy_floor_db(&core, &floor).expect("floor first");
    let module_first = migrate_module_db(&core, &module).expect("module first");
    assert_eq!(floor_first.inserted, 2);
    assert_eq!(module_first.inserted, 1);
    assert_eq!(module_first.updated, 1);
    let rows_first: i64 = core
        .query_row("SELECT COUNT(*) FROM download_task", [], |row| row.get(0))
        .expect("count rows");
    assert_eq!(rows_first, 3);

    let floor_second = migrate_legacy_floor_db(&core, &floor).expect("floor second");
    let module_second = migrate_module_db(&core, &module).expect("module second");
    assert_eq!(
        floor_second,
        MigrationReport {
            inserted: 0,
            updated: 0,
            skipped: 2
        }
    );
    assert_eq!(module_second.inserted, 0);
    let rows_second: i64 = core
        .query_row("SELECT COUNT(*) FROM download_task", [], |row| row.get(0))
        .expect("count rows");
    assert_eq!(rows_second, rows_first, "second run must not insert rows");
    let duplicates: i64 = core
        .query_row(
            "SELECT COUNT(*) FROM (
                 SELECT dedup_key FROM download_task WHERE dedup_key IS NOT NULL
                 GROUP BY dedup_key HAVING COUNT(*) > 1
             )",
            [],
            |row| row.get(0),
        )
        .expect("duplicate dedup keys");
    assert_eq!(duplicates, 0);
}

#[test]
fn download_legacy_parity_core_row_wins_over_legacy_duplicate() {
    let dir = TempDir::new("core-wins");
    let floor = dir.join("download_task.db");
    create_floor_db(&floor, &[(0, "com.example.legacy", "/tmp/legacy.bin", 1)]);

    let core = core_conn();
    core.execute(
        "INSERT INTO download_task
         (dedup_key, app_id, version, file_name, status, bytes_done, total, created_at, updated_at)
         VALUES ('app:0', 'com.example.core', '9.9.9', 'core.bin', 'completed', 999, 1000, 1, 1)",
        [],
    )
    .expect("seed core row");

    let report = migrate_legacy_floor_db(&core, &floor).expect("migrate duplicate");
    assert_eq!(
        report,
        MigrationReport {
            inserted: 0,
            updated: 0,
            skipped: 1
        }
    );
    let (app_id, status, bytes_done): (String, String, i64) = core
        .query_row(
            "SELECT app_id, status, bytes_done FROM download_task WHERE dedup_key = 'app:0'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("read core row");
    assert_eq!(app_id, "com.example.core");
    assert_eq!(status, "completed");
    assert_eq!(bytes_done, 999);
    let total: i64 = core
        .query_row("SELECT COUNT(*) FROM download_task", [], |row| row.get(0))
        .expect("row count");
    assert_eq!(total, 1, "duplicate legacy row must be skipped");
}

#[test]
fn download_legacy_parity_missing_databases_are_typed() {
    let dir = TempDir::new("missing");
    let core = core_conn();
    let missing = dir.join("does-not-exist.db");

    let floor_error = migrate_legacy_floor_db(&core, &missing).expect_err("missing floor db");
    println!("missing floor db -> {floor_error:?}");
    assert!(floor_error.to_string().contains("not found"));

    let module_error = migrate_module_db(&core, &missing).expect_err("missing module db");
    println!("missing module db -> {module_error:?}");
    assert!(module_error.to_string().contains("not found"));
}

#[test]
fn download_legacy_parity_reconcile_after_process_death() {
    struct NeverBridge;
    impl ModuleBridge for NeverBridge {
        fn call(&self, method: &str, _payload: &[u8]) -> Result<Vec<u8>, String> {
            Err(format!("bridge must not be called: {method}"))
        }
    }

    let dir = TempDir::new("reconcile");
    let floor = dir.join("download_task.db");
    create_floor_db(
        &floor,
        &[
            (2, "com.example.running", "/tmp/running.bin", 10),
            (4, "com.example.completed", "/tmp/completed.bin", 10),
        ],
    );
    let core = core_conn();
    migrate_legacy_floor_db(&core, &floor).expect("migrate");

    let conn: SharedConn = Arc::new(Mutex::new(core));
    let port = ModuleDownloadPort::new(NeverBridge, conn.clone(), dir.join("core.db"))
        .with_module_db_path(dir.join("module-db-gone.db"));
    let report = port.reconcile().expect("reconcile without module db");
    println!("reconcile after process death -> {report:?}");
    assert_eq!(report.checked, 2);
    assert_eq!(report.needs_restart.len(), 1);

    let statuses: HashMap<String, String> = {
        let guard = conn.lock().expect("core lock");
        let mut stmt = guard
            .prepare("SELECT app_id, status FROM download_task")
            .expect("prepare statuses");
        stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .expect("query statuses")
            .collect::<Result<_, _>>()
            .expect("read statuses")
    };
    assert_eq!(
        statuses.get("com.example.running").map(String::as_str),
        Some(NEEDS_RESTART)
    );
    assert_eq!(
        statuses.get("com.example.completed").map(String::as_str),
        Some("completed")
    );
}

fn first_difference(left: &Value, right: &Value, path: &str) -> Option<String> {
    if left == right {
        return None;
    }
    match (left, right) {
        (Value::Object(left), Value::Object(right)) => {
            for key in left.keys().chain(right.keys()) {
                match (left.get(key), right.get(key)) {
                    (Some(left), Some(right)) => {
                        if let Some(found) = first_difference(left, right, &format!("{path}.{key}"))
                        {
                            return Some(found);
                        }
                    }
                    _ => return Some(format!("{path}.{key}")),
                }
            }
            Some(path.to_string())
        }
        (Value::Array(left), Value::Array(right)) => {
            if left.len() != right.len() {
                return Some(format!("{path}.length"));
            }
            for (index, (left, right)) in left.iter().zip(right).enumerate() {
                if let Some(found) = first_difference(left, right, &format!("{path}[{index}]")) {
                    return Some(found);
                }
            }
            Some(path.to_string())
        }
        _ => Some(path.to_string()),
    }
}

#[test]
fn download_legacy_parity_drift_check_fails_on_status_and_path() {
    let dart = json!({
        "rows": [{
            "dedup_key": "app:paused",
            "dest_path": "/tmp/paused.bin",
            "status_code": 3,
            "resume_expected_bytes": 700
        }]
    });
    let baseline = dart.clone();
    assert_eq!(first_difference(&dart, &baseline, "$"), None);

    let mut status_drift = baseline.clone();
    status_drift["rows"][0]["status_code"] = json!(4);
    let found = first_difference(&dart, &status_drift, "$").expect("status drift must fail");
    println!("status drift detected at {found}");
    assert!(found.contains("status_code"), "unexpected path: {found}");

    let mut path_drift = baseline;
    path_drift["rows"][0]["dest_path"] = json!("/tmp/paused.bin-drift");
    let found = first_difference(&dart, &path_drift, "$").expect("path drift must fail");
    println!("path drift detected at {found}");
    assert!(found.contains("dest_path"), "unexpected path: {found}");
}
