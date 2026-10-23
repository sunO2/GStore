// allow: SIZE_OK — one cohesive three-way resync fixture matrix; splitting the
// module/floor/core fixture builders would duplicate the same DDL and mapping.
//! Plan-Todo 5 (6A-A5): three-way download resync contract.
//!
//! Every test name contains `download_resync` so the plan's QA command
//! (`cargo test ... download_resync`) selects this whole file.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use gstore_core::download::legacy::migrate_module_db;
use gstore_core::download::port::{ModuleBridge, ModuleDownloadPort, PortError};
use gstore_core::download::resync::{ResyncReport, TERMINAL_STATUSES};
use gstore_core::download::{DownloadTaskRow, NEEDS_RESTART};
use gstore_core::flags::{flags, reset_flags, set_flags, FlagsPatch};
use rusqlite::{Connection, OpenFlags};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);
static FLAGS_LOCK: Mutex<()> = Mutex::new(());

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_download_resync_{tag}_{}_{}",
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

struct PanicBridge;

impl ModuleBridge for PanicBridge {
    fn call(&self, method: &str, _payload: &[u8]) -> Result<Vec<u8>, String> {
        panic!("resync must never call the module bridge ({method})");
    }
}

fn core_conn() -> Connection {
    let mut conn = Connection::open_in_memory().expect("in-memory core");
    gstore_core::migration::apply_core_schema(&mut conn).expect("core schema");
    conn
}

fn resync(
    conn: &Arc<Mutex<Connection>>,
    module_db: Option<&Path>,
    floor_db: Option<&Path>,
    apply: bool,
    files_dir: &Path,
) -> Result<ResyncReport, PortError> {
    let mut port =
        ModuleDownloadPort::new(PanicBridge, conn.clone(), PathBuf::from("/tmp/core.db"));
    if let Some(path) = module_db {
        port = port.with_module_db_path(path.to_path_buf());
    }
    port.resync(apply, floor_db, files_dir)
}

fn rows(conn: &Connection) -> Vec<DownloadTaskRow> {
    gstore_core::download::list_tasks(conn).expect("list core rows")
}

fn fingerprint(conn: &Connection) -> String {
    format!("{:?}", rows(conn))
}

fn snapshot_files(files_dir: &Path) -> Vec<PathBuf> {
    let backups = files_dir.join("migration").join("backups");
    let Ok(entries) = std::fs::read_dir(backups) else {
        return Vec::new();
    };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("pre-resync-") && name.ends_with(".db"))
        })
        .collect();
    paths.sort();
    paths
}

fn assert_snapshot_ok(path: &Path) {
    assert!(path.exists(), "snapshot missing: {}", path.display());
    assert!(
        std::fs::metadata(path).expect("snapshot metadata").len() > 0,
        "snapshot must not be empty: {}",
        path.display()
    );
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .expect("open snapshot read-only");
    let check: String = conn
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .expect("integrity_check");
    assert_eq!(check, "ok", "snapshot failed integrity_check");
}

struct ModuleRow<'a> {
    id: i64,
    app_id: &'a str,
    version: &'a str,
    file_name: &'a str,
    status: i64,
    dedup_key: &'a str,
}

fn module_ddl() -> &'static str {
    "CREATE TABLE download_task (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        app_id TEXT NOT NULL, app_name TEXT NOT NULL, version TEXT NOT NULL,
        file_name TEXT NOT NULL, url TEXT NOT NULL, file_path TEXT NOT NULL,
        total INTEGER NOT NULL DEFAULT 0, received INTEGER NOT NULL DEFAULT 0,
        status INTEGER NOT NULL, speed_bps INTEGER NOT NULL DEFAULT 0,
        eta_sec INTEGER, error TEXT, fail_kind TEXT, retries INTEGER NOT NULL DEFAULT 0,
        server_meta TEXT, expected_sha256 TEXT, actual_sha256 TEXT,
        priority INTEGER NOT NULL DEFAULT 0, queue_reason TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        dedup_key TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT 'file',
        resource_id TEXT NOT NULL DEFAULT '', resource_version TEXT NOT NULL DEFAULT '',
        install_after_download INTEGER NOT NULL DEFAULT 0,
        last_started_at INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE download_segment (
        task_id INTEGER NOT NULL, idx INTEGER NOT NULL, start_byte INTEGER NOT NULL,
        end_byte INTEGER NOT NULL, received INTEGER NOT NULL DEFAULT 0,
        done INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (task_id, idx)
    );"
}

fn insert_module_row(conn: &Connection, row: &ModuleRow<'_>, received: i64) {
    conn.execute(
        "INSERT INTO download_task
         (id, app_id, app_name, version, file_name, url, file_path, total, received, status,
          dedup_key, created_at, updated_at)
         VALUES (?1, ?2, 'Module', ?3, ?4, ?5, ?6, 1000, ?7, ?8, ?9, 1, 2)",
        rusqlite::params![
            row.id,
            row.app_id,
            row.version,
            row.file_name,
            format!("https://example.test/{}.bin", row.file_name),
            format!("/tmp/{}", row.file_name),
            received,
            row.status,
            row.dedup_key,
        ],
    )
    .expect("insert module row");
}

fn create_module_db(path: &Path, rows: &[ModuleRow<'_>]) {
    let conn = Connection::open(path).expect("open module fixture");
    conn.execute_batch(module_ddl()).expect("module DDL");
    for row in rows {
        insert_module_row(&conn, row, 500);
    }
}

struct FloorRow<'a> {
    app_id: &'a str,
    version: &'a str,
    file_name: &'a str,
    dedup_key: &'a str,
}

fn create_floor_db(path: &Path, rows: &[FloorRow<'_>]) {
    let conn = Connection::open(path).expect("open floor fixture");
    conn.execute_batch(
        "CREATE TABLE download_task (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            appId TEXT NOT NULL, appName TEXT NOT NULL, version TEXT NOT NULL,
            fileName TEXT NOT NULL, url TEXT NOT NULL, filePath TEXT NOT NULL,
            total INTEGER NOT NULL, received INTEGER NOT NULL, status INTEGER NOT NULL,
            speedBps INTEGER NOT NULL DEFAULT 0, etaSec INTEGER, error TEXT,
            segments TEXT, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL,
            dedupKey TEXT, installAfterDownload INTEGER NOT NULL DEFAULT 0
        );",
    )
    .expect("floor DDL");
    for row in rows {
        conn.execute(
            "INSERT INTO download_task
             (appId, appName, version, fileName, url, filePath, total, received, status,
              createdAt, updatedAt, dedupKey, installAfterDownload)
             VALUES (?1, 'Floor', ?2, ?3, ?4, ?5, 10, 5, 2, 1, 2, ?6, 0)",
            rusqlite::params![
                row.app_id,
                row.version,
                row.file_name,
                format!("https://example.test/{}.bin", row.file_name),
                format!("/tmp/{}", row.file_name),
                row.dedup_key,
            ],
        )
        .expect("insert floor row");
    }
}

fn insert_core_row(
    conn: &Connection,
    id: i64,
    module_task_id: Option<&str>,
    dedup_key: &str,
    app_id: &str,
    version: &str,
    file_name: &str,
    status: &str,
) {
    conn.execute(
        "INSERT INTO download_task
         (id, module_task_id, dedup_key, app_id, app_name, version, file_name, kind,
          url, dest_path, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, 'Core', ?5, ?6, 'file', ?7, ?8, ?9, 1, 1)",
        rusqlite::params![
            id,
            module_task_id,
            dedup_key,
            app_id,
            version,
            file_name,
            format!("https://example.test/{file_name}.bin"),
            format!("/tmp/{file_name}"),
            status,
        ],
    )
    .expect("insert core row");
}

fn row_status(conn: &Connection, id: i64) -> String {
    conn.query_row(
        "SELECT status FROM download_task WHERE id = ?1",
        [id],
        |row| row.get(0),
    )
    .expect("read row status")
}

#[test]
fn download_resync_three_way_parity() {
    let dir = TempDir::new("parity");
    let files_dir = dir.join("files");
    let module_path = dir.join("module.db");
    let floor_path = dir.join("floor.db");

    create_module_db(
        &module_path,
        &[
            ModuleRow {
                id: 1,
                app_id: "com.a",
                version: "1.0",
                file_name: "a.apk",
                status: 2,
                dedup_key: "app:com.a:1.0:a.apk",
            },
            ModuleRow {
                id: 2,
                app_id: "com.b",
                version: "2.0",
                file_name: "b.apk",
                status: 2,
                dedup_key: "app:com.b:2.0:b.apk",
            },
        ],
    );

    let conn = Arc::new(Mutex::new(core_conn()));
    {
        let guard = conn.lock().unwrap();
        migrate_module_db(&guard, &module_path).expect("seed core from module");
        insert_core_row(
            &guard,
            3,
            Some("3"),
            "app:com.c:3.0:c.apk",
            "com.c",
            "3.0",
            "c.apk",
            "completed",
        );
    }
    {
        let module = Connection::open(&module_path).expect("reopen module fixture");
        module
            .execute("UPDATE download_task SET status = 4 WHERE id = 2", [])
            .expect("make core mirror stale");
        insert_module_row(
            &module,
            &ModuleRow {
                id: 4,
                app_id: "com.d",
                version: "4.0",
                file_name: "d.apk",
                status: 3,
                dedup_key: "app:com.d:4.0:d.apk",
            },
            0,
        );
    }
    create_floor_db(
        &floor_path,
        &[
            FloorRow {
                app_id: "com.a",
                version: "1.0",
                file_name: "a.apk",
                dedup_key: "app:com.a:1.0:a.apk",
            },
            FloorRow {
                app_id: "com.b",
                version: "2.0",
                file_name: "b.apk",
                dedup_key: "app:com.b:2.0:b.apk",
            },
            FloorRow {
                app_id: "com.e",
                version: "5.0",
                file_name: "e.apk",
                dedup_key: "app:com.e:5.0:e.apk",
            },
        ],
    );

    let before = {
        let guard = conn.lock().unwrap();
        fingerprint(&guard)
    };
    let module_before = std::fs::read(&module_path).expect("module bytes");

    let dry = resync(
        &conn,
        Some(&module_path),
        Some(&floor_path),
        false,
        &files_dir,
    )
    .expect("dry-run");
    println!("download_resync dry-run -> {dry:?}");
    assert_eq!(dry.floor_rows, 3);
    assert_eq!(dry.module_rows, 3);
    assert_eq!(dry.core_rows, 3);
    assert_eq!(dry.matched, 2, "three-way intersection is K1 and K2");
    assert_eq!(dry.missing, 2, "module-only K4 plus core-only K3");
    assert_eq!(dry.conflicts, 0);
    assert_eq!(dry.needs_restart, 0);
    assert_eq!(dry.updated, 0, "dry-run must not report writes");
    assert_eq!(dry.snapshot_path, None, "dry-run must not snapshot");
    {
        let guard = conn.lock().unwrap();
        assert_eq!(fingerprint(&guard), before, "dry-run wrote core rows");
    }
    assert_eq!(
        std::fs::read(&module_path).expect("module bytes"),
        module_before,
        "dry-run wrote the module db"
    );
    assert!(
        snapshot_files(&files_dir).is_empty(),
        "dry-run created a snapshot"
    );

    let applied = resync(
        &conn,
        Some(&module_path),
        Some(&floor_path),
        true,
        &files_dir,
    )
    .expect("apply");
    println!("download_resync apply -> {applied:?}");
    assert_eq!(applied.matched, 2);
    assert_eq!(applied.missing, 2);
    assert_eq!(applied.conflicts, 0);
    assert_eq!(applied.updated, 2, "stale K2 + module-only K4");
    let snapshot = applied.snapshot_path.expect("apply snapshot");
    assert_snapshot_ok(Path::new(&snapshot));
    {
        let guard = conn.lock().unwrap();
        let core = rows(&guard);
        assert_eq!(core.len(), 4, "K4 inserted, nothing deleted");
        assert_eq!(row_status(&guard, 2), "completed", "stale mirror refreshed");
        assert!(
            core.iter()
                .any(|row| row.module_task_id.as_deref() == Some("3")),
            "core-only terminal row must survive"
        );
        assert!(
            core.iter()
                .any(|row| row.module_task_id.as_deref() == Some("4")),
            "module-only row must be mirrored"
        );
        assert!(
            !core
                .iter()
                .any(|row| row.app_id.as_deref() == Some("com.e")),
            "floor-only rows are a parity oracle, never imported"
        );
    }

    let after_first = {
        let guard = conn.lock().unwrap();
        fingerprint(&guard)
    };
    let second = resync(
        &conn,
        Some(&module_path),
        Some(&floor_path),
        true,
        &files_dir,
    )
    .expect("second");
    println!("download_resync second apply -> {second:?}");
    assert_eq!(second.updated, 0, "second apply must be idempotent");
    assert_eq!(second.core_rows, 4);
    assert_eq!(second.matched, 2);
    assert_eq!(second.missing, 1, "only core-only K3 remains");
    assert_eq!(second.conflicts, 0);
    let second_snapshot = second.snapshot_path.expect("second snapshot");
    assert_ne!(snapshot, second_snapshot, "snapshot names must be distinct");
    assert_snapshot_ok(Path::new(&second_snapshot));
    let guard = conn.lock().unwrap();
    assert_eq!(
        fingerprint(&guard),
        after_first,
        "second apply changed rows"
    );
    drop(guard);
    assert_eq!(snapshot_files(&files_dir).len(), 2);
}

#[test]
fn download_resync_aborts_on_conflict() {
    let dir = TempDir::new("conflict");
    let files_dir = dir.join("files");
    let module_path = dir.join("module.db");

    create_module_db(
        &module_path,
        &[ModuleRow {
            id: 1,
            app_id: "com.a",
            version: "1.0",
            file_name: "a.apk",
            status: 2,
            dedup_key: "app:com.a:1.0:a.apk",
        }],
    );

    let conn = Arc::new(Mutex::new(core_conn()));
    let first = resync(&conn, Some(&module_path), None, true, &files_dir).expect("baseline apply");
    assert_eq!(first.updated, 1);
    let baseline = {
        let guard = conn.lock().unwrap();
        fingerprint(&guard)
    };
    let snapshots_before = snapshot_files(&files_dir).len();

    {
        let module = Connection::open(&module_path).expect("reopen module");
        module
            .execute(
                "UPDATE download_task SET dedup_key = 'app:com.a:1.0:a.apk:rev2' WHERE id = 1",
                [],
            )
            .expect("introduce dedup conflict");
    }
    let module_before = std::fs::read(&module_path).expect("module bytes");

    let dry = resync(&conn, Some(&module_path), None, false, &files_dir)
        .expect_err("dry-run must surface the conflict");
    println!("download_resync conflict (dry) -> {dry:?}");
    assert!(
        matches!(dry, PortError::ResyncConflict(ref msg) if msg.contains("dedup_key")),
        "unexpected dry-run error: {dry:?}"
    );

    let applied = resync(&conn, Some(&module_path), None, true, &files_dir)
        .expect_err("apply must abort on a conflict");
    println!("download_resync conflict (apply) -> {applied:?}");
    assert!(
        matches!(applied, PortError::ResyncConflict(ref msg) if msg.contains("dedup_key")),
        "unexpected apply error: {applied:?}"
    );
    {
        let guard = conn.lock().unwrap();
        assert_eq!(
            fingerprint(&guard),
            baseline,
            "conflict abort wrote core rows"
        );
    }
    assert_eq!(
        std::fs::read(&module_path).expect("module bytes"),
        module_before,
        "conflict abort wrote the module db"
    );
    assert_eq!(
        snapshot_files(&files_dir).len(),
        snapshots_before,
        "conflict abort created a snapshot"
    );
}

#[test]
fn download_resync_aborts_on_absent_module_task() {
    let dir = TempDir::new("absent_task");
    let files_dir = dir.join("files");
    let module_path = dir.join("module.db");

    create_module_db(
        &module_path,
        &[ModuleRow {
            id: 1,
            app_id: "com.b",
            version: "2.0",
            file_name: "b.apk",
            status: 2,
            dedup_key: "app:com.b:2.0:b.apk",
        }],
    );

    let conn = Arc::new(Mutex::new(core_conn()));
    {
        let guard = conn.lock().unwrap();
        insert_core_row(
            &guard,
            7,
            Some("9"),
            "app:com.a:1.0:a.apk",
            "com.a",
            "1.0",
            "a.apk",
            "running",
        );
        insert_core_row(
            &guard,
            8,
            Some("8"),
            "app:com.c:3.0:c.apk",
            "com.c",
            "3.0",
            "c.apk",
            "completed",
        );
    }
    let before = {
        let guard = conn.lock().unwrap();
        fingerprint(&guard)
    };

    let applied = resync(&conn, Some(&module_path), None, true, &files_dir)
        .expect_err("a live core row absent from the module db is a conflict");
    println!("download_resync absent module task -> {applied:?}");
    assert!(
        matches!(applied, PortError::ResyncConflict(ref msg) if msg.contains("module_task_id 9")),
        "unexpected error: {applied:?}"
    );
    {
        let guard = conn.lock().unwrap();
        assert_eq!(
            fingerprint(&guard),
            before,
            "conflict abort wrote core rows"
        );
        assert_eq!(row_status(&guard, 7), "running");
        assert_eq!(row_status(&guard, 8), "completed");
    }
    assert!(snapshot_files(&files_dir).is_empty());
}

#[test]
fn download_resync_needs_restart_missing_module_db() {
    let dir = TempDir::new("restart");
    let files_dir = dir.join("files");
    let module_path = dir.join("missing-module.db");
    let floor_path = dir.join("missing-floor.db");

    let conn = Arc::new(Mutex::new(core_conn()));
    {
        let guard = conn.lock().unwrap();
        for (id, status) in [
            (1, "running"),
            (2, "paused"),
            (3, "completed"),
            (4, "failed"),
            (5, NEEDS_RESTART),
        ] {
            insert_core_row(
                &guard,
                id,
                Some(&id.to_string()),
                &format!("app:com.r{id}:1.0:r{id}.apk"),
                &format!("com.r{id}"),
                "1.0",
                &format!("r{id}.apk"),
                status,
            );
        }
    }

    let dry = resync(
        &conn,
        Some(&module_path),
        Some(&floor_path),
        false,
        &files_dir,
    )
    .expect("dry-run without a module db");
    println!("download_resync needs_restart dry -> {dry:?}");
    assert_eq!(dry.floor_rows, 0, "a missing floor db is a two-way run");
    assert_eq!(dry.module_rows, 0);
    assert_eq!(dry.core_rows, 5);
    assert_eq!(dry.matched, 0);
    assert_eq!(dry.missing, 5, "every core key is absent from the module");
    assert_eq!(dry.conflicts, 0, "a missing module db is never a conflict");
    assert_eq!(dry.needs_restart, 3);
    assert_eq!(dry.updated, 0);
    assert_eq!(dry.snapshot_path, None);

    let applied = resync(
        &conn,
        Some(&module_path),
        Some(&floor_path),
        true,
        &files_dir,
    )
    .expect("apply without a module db");
    println!("download_resync needs_restart apply -> {applied:?}");
    assert_eq!(applied.needs_restart, 3);
    let first_snapshot = applied.snapshot_path.clone();
    assert_snapshot_ok(Path::new(
        first_snapshot.as_deref().expect("apply snapshot"),
    ));
    {
        let guard = conn.lock().unwrap();
        assert_eq!(row_status(&guard, 1), NEEDS_RESTART);
        assert_eq!(row_status(&guard, 2), NEEDS_RESTART);
        assert_eq!(row_status(&guard, 3), "completed");
        assert_eq!(row_status(&guard, 4), "failed");
        assert_eq!(row_status(&guard, 5), NEEDS_RESTART);
    }
    let after_first = {
        let guard = conn.lock().unwrap();
        fingerprint(&guard)
    };
    let second = resync(
        &conn,
        Some(&module_path),
        Some(&floor_path),
        true,
        &files_dir,
    )
    .expect("second apply without a module db");
    assert_eq!(second.needs_restart, 3, "already-marked rows still count");
    assert_eq!(second.updated, 0);
    assert_ne!(
        first_snapshot, second.snapshot_path,
        "each apply must snapshot under a distinct name"
    );
    let guard = conn.lock().unwrap();
    assert_eq!(
        fingerprint(&guard),
        after_first,
        "a repeated needs_restart apply must not rewrite rows"
    );
}

#[test]
fn download_resync_apply_snapshots_are_verified_and_unique() {
    let dir = TempDir::new("snapshots");
    let files_dir = dir.join("files");

    let conn = Arc::new(Mutex::new(core_conn()));
    {
        let guard = conn.lock().unwrap();
        insert_core_row(
            &guard,
            1,
            Some("1"),
            "app:com.a:1.0:a.apk",
            "com.a",
            "1.0",
            "a.apk",
            "running",
        );
    }

    let first = resync(&conn, None, None, true, &files_dir).expect("first apply");
    let second = resync(&conn, None, None, true, &files_dir).expect("second apply");
    let first_path = first.snapshot_path.expect("first snapshot");
    let second_path = second.snapshot_path.expect("second snapshot");
    println!("snapshots: {first_path} | {second_path}");
    assert_ne!(first_path, second_path);
    assert!(first_path.contains("pre-resync-"));
    assert_snapshot_ok(Path::new(&first_path));
    assert_snapshot_ok(Path::new(&second_path));
    assert_eq!(
        snapshot_files(&files_dir).len(),
        2,
        "each apply keeps its own rollback copy"
    );
}

#[test]
fn download_resync_writes_no_core_writes_markers() {
    let _guard = FLAGS_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    set_flags(FlagsPatch {
        download: Some(true),
        ..FlagsPatch::default()
    })
    .expect("flip download for the marker probe");
    assert!(flags().download);

    let dir = TempDir::new("markers");
    let files_dir = dir.join("files");
    let module_path = dir.join("module.db");
    create_module_db(
        &module_path,
        &[ModuleRow {
            id: 1,
            app_id: "com.a",
            version: "1.0",
            file_name: "a.apk",
            status: 2,
            dedup_key: "app:com.a:1.0:a.apk",
        }],
    );

    let conn = Arc::new(Mutex::new(core_conn()));
    let applied = resync(&conn, Some(&module_path), None, true, &files_dir).expect("apply");
    assert_eq!(applied.updated, 1);
    let markers: i64 = {
        let guard = conn.lock().unwrap();
        guard
            .query_row("SELECT COUNT(*) FROM core_writes", [], |row| row.get(0))
            .expect("count markers")
    };
    println!("core_writes rows after resync: {markers}");
    assert_eq!(markers, 0, "resync must not arm core_writes");
    assert!(!flags().core_writes, "the projection must stay false");

    reset_flags();
}

#[test]
fn download_resync_rejects_malformed_module_db() {
    let dir = TempDir::new("malformed");
    let files_dir = dir.join("files");

    let cases: [(&str, Vec<u8>); 3] = [
        ("garbage.db", b"this is not a sqlite database".to_vec()),
        ("header-only.db", b"SQLite format 3\0".to_vec()),
        ("no-task-table.db", Vec::new()),
    ];

    for (name, bytes) in cases {
        let module_path = dir.join(name);
        if bytes.is_empty() {
            let module = Connection::open(&module_path).expect("open empty db");
            module
                .execute_batch("CREATE TABLE unrelated (id INTEGER PRIMARY KEY);")
                .expect("unrelated table");
        } else {
            std::fs::write(&module_path, bytes).expect("write malformed db");
        }

        let conn = Arc::new(Mutex::new(core_conn()));
        {
            let guard = conn.lock().unwrap();
            insert_core_row(
                &guard,
                1,
                Some("1"),
                "app:com.a:1.0:a.apk",
                "com.a",
                "1.0",
                "a.apk",
                "running",
            );
        }
        let before = {
            let guard = conn.lock().unwrap();
            fingerprint(&guard)
        };
        let error = resync(&conn, Some(&module_path), None, true, &files_dir)
            .expect_err("a malformed module db must be a typed error");
        println!("download_resync malformed {name} -> {error:?}");
        assert!(
            matches!(error, PortError::Db(_)),
            "malformed {name} must be PortError::Db: {error:?}"
        );
        {
            let guard = conn.lock().unwrap();
            assert_eq!(fingerprint(&guard), before, "malformed {name} wrote rows");
            assert_eq!(row_status(&guard, 1), "running");
        }
        assert!(
            snapshot_files(&files_dir).is_empty(),
            "malformed {name} created a snapshot"
        );
    }
}

#[test]
fn download_resync_large_snapshot_is_bounded() {
    let dir = TempDir::new("large");
    let files_dir = dir.join("files");

    let conn = Arc::new(Mutex::new(core_conn()));
    {
        let mut guard = conn.lock().unwrap();
        let tx = guard.transaction().expect("bulk insert tx");
        for id in 1..=1500_i64 {
            tx.execute(
                "INSERT INTO download_task
                 (id, module_task_id, dedup_key, app_id, version, file_name, status, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, '1.0', ?5, 'running', 1, 1)",
                rusqlite::params![
                    id,
                    id.to_string(),
                    format!("app:com.l{id}:1.0:l{id}.apk"),
                    format!("com.l{id}"),
                    format!("l{id}.apk"),
                ],
            )
            .expect("bulk row");
        }
        tx.commit().expect("commit bulk rows");
    }

    let started = Instant::now();
    let applied = resync(&conn, None, None, true, &files_dir).expect("large apply");
    let elapsed = started.elapsed();
    println!("download_resync large apply -> {applied:?} in {elapsed:?}");
    assert_eq!(applied.core_rows, 1500);
    assert_eq!(applied.needs_restart, 1500);
    assert!(elapsed < Duration::from_secs(30), "snapshot is unbounded");
    assert_snapshot_ok(Path::new(&applied.snapshot_path.expect("large snapshot")));
}

#[test]
fn download_resync_terminal_statuses_are_exact() {
    assert_eq!(
        TERMINAL_STATUSES,
        ["completed", "cancelled", "removed", "failed"]
    );
    assert!(!TERMINAL_STATUSES.contains(&NEEDS_RESTART));
    assert!(!TERMINAL_STATUSES.contains(&"running"));
}
