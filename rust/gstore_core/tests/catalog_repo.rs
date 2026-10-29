//! Catalog repository contract: content-addressed seeds, validated downloads,
//! version ordering, read-only storage, and materialization into the core.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::catalog::repo::CatalogRepo;
use gstore_core::db::DbHandle;
use gstore_core::ports::{FakeHttpPort, HttpResponse};
use rusqlite::{params, Connection, OpenFlags};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_repo_{tag}_{}_{}",
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

fn create_source(path: &Path, version: &str, app_ids: &[&str]) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY);",
    )
    .unwrap();
    for id in app_ids {
        conn.execute(
            "INSERT INTO apps(appId,name,user,repositories,icon,des,category) \
             VALUES (?1, ?1, 'u', 'r', 'i', 'd', 'T')",
            params![id],
        )
        .unwrap();
    }
    conn.execute("INSERT INTO category VALUES ('T','Tools','t')", [])
        .unwrap();
    conn.execute("INSERT INTO config VALUES (?1)", params![version])
        .unwrap();
}

fn push_db(http: &FakeHttpPort, path: &Path) {
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: std::fs::read(path).unwrap(),
    });
}

fn seed_files(repo: &CatalogRepo) -> usize {
    std::fs::read_dir(repo.root().join("seed"))
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().and_then(|ext| ext.to_str()) == Some("db"))
        .count()
}

fn manifest(repo: &CatalogRepo) -> serde_json::Value {
    let bytes = std::fs::read(repo.root().join("manifest.json")).unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

fn manifest_entries(repo: &CatalogRepo) -> usize {
    manifest(repo)["entries"].as_array().unwrap().len()
}

fn core_apps(db: &DbHandle) -> i64 {
    db.with_reader(|conn| {
        conn.query_row("SELECT COUNT(*) FROM apps", [], |row| row.get(0))
            .map_err(|e| gstore_core::db::DbError(e.to_string()))
    })
    .unwrap()
}

#[test]
fn ensure_seed_is_content_addressed_and_idempotent() {
    let dir = TempDir::new("ensure");
    let repo = CatalogRepo::new(dir.path().join("repo")).unwrap();
    let seed_a = dir.path().join("a.db");
    create_source(&seed_a, "0.0.12", &["com.a"]);

    let first = repo.ensure_seed(&seed_a).unwrap();
    assert_eq!(first.entries.len(), 1);
    assert_eq!(first.apps, 1);
    assert_eq!(first.categories, 1);
    assert_eq!(first.current_version.as_deref(), Some("0.0.12"));
    assert!(first.current_file.as_deref().unwrap().starts_with("seed/"));
    assert_eq!(seed_files(&repo), 1);

    let second = repo.ensure_seed(&seed_a).unwrap();
    assert_eq!(second.entries.len(), 1, "same content must not duplicate the entry");
    assert_eq!(manifest_entries(&repo), 1);
    assert_eq!(seed_files(&repo), 1, "same content must not copy twice");

    let seed_b = dir.path().join("b.db");
    create_source(&seed_b, "0.0.13", &["com.b"]);
    let third = repo.ensure_seed(&seed_b).unwrap();
    assert_eq!(third.entries.len(), 2, "different content must register a new entry");
    assert_eq!(seed_files(&repo), 2, "different content must create a second file");
    assert_eq!(
        third.current_version.as_deref(),
        Some("0.0.12"),
        "an existing selection must be preserved"
    );
}

#[test]
fn download_rejects_invalid_body_and_accepts_valid() {
    let dir = TempDir::new("download");
    let repo = CatalogRepo::new(dir.path().join("repo")).unwrap();
    let seed = dir.path().join("seed.db");
    create_source(&seed, "0.0.12", &["com.seed"]);
    repo.ensure_seed(&seed).unwrap();
    let before = repo.status().unwrap();

    let http = FakeHttpPort::new();
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: b"definitely not a sqlite database".to_vec(),
    });
    let error = repo
        .download(&http, "https://example.invalid/bad.db")
        .expect_err("invalid body must be rejected");
    assert_eq!(error.code(), "invalid_argument");

    let after_bad = repo.status().unwrap();
    assert_eq!(
        after_bad.current_file, before.current_file,
        "an invalid download must not change current"
    );
    assert_eq!(after_bad.entries, before.entries);
    assert!(
        std::fs::read_dir(dir.path().join("repo").join("tmp"))
            .unwrap()
            .next()
            .is_none(),
        "a failed download must not leave temp files"
    );
}

#[test]
fn download_accepts_valid_and_reads_config_version() {
    let dir = TempDir::new("download_ok");
    let repo = CatalogRepo::new(dir.path().join("repo")).unwrap();
    let seed = dir.path().join("seed.db");
    create_source(&seed, "0.0.12", &["com.seed"]);
    repo.ensure_seed(&seed).unwrap();

    let good = dir.path().join("good.db");
    create_source(&good, "0.0.13", &["com.remote.one", "com.remote.two"]);
    let http = FakeHttpPort::new();
    push_db(&http, &good);

    let report = repo
        .download(&http, "https://example.invalid/good.db")
        .expect("valid download");
    assert_eq!(report.version.as_deref(), Some("0.0.13"));
    assert!(report.changed, "a newer version must become current");
    assert_eq!(report.entries.len(), 2);

    let status = repo.status().unwrap();
    assert_eq!(status.current_version.as_deref(), Some("0.0.13"));
    assert!(
        status
            .current_file
            .as_deref()
            .unwrap()
            .starts_with("remote/0.0.13-"),
        "current must be the downloaded remote file"
    );
    assert_eq!(status.apps, 2, "apps read from the current repo DB");
    assert_eq!(status.categories, 1);
}

#[test]
fn older_remote_does_not_replace_newer_current() {
    let dir = TempDir::new("version_order");
    let repo = CatalogRepo::new(dir.path().join("repo")).unwrap();
    let seed = dir.path().join("seed.db");
    create_source(&seed, "0.0.10", &["com.seed"]);
    repo.ensure_seed(&seed).unwrap();

    let newer = dir.path().join("newer.db");
    create_source(&newer, "0.0.20", &["com.new"]);
    let http = FakeHttpPort::new();
    push_db(&http, &newer);
    let newer_report = repo
        .download(&http, "https://example.invalid/newer.db")
        .expect("newer download");
    assert!(newer_report.changed);
    assert_eq!(
        repo.status().unwrap().current_version.as_deref(),
        Some("0.0.20")
    );

    let older = dir.path().join("older.db");
    create_source(&older, "0.0.15", &["com.old"]);
    push_db(&http, &older);
    let older_report = repo
        .download(&http, "https://example.invalid/older.db")
        .expect("older download");
    assert!(!older_report.changed, "an older version must not switch current");

    let status = repo.status().unwrap();
    assert_eq!(status.current_version.as_deref(), Some("0.0.20"));
    assert_eq!(status.apps, 1);
    assert_eq!(status.entries.len(), 3, "seed plus both remotes are registered");
}

#[test]
fn materialize_imports_when_core_empty_then_noops_until_current_changes() {
    let dir = TempDir::new("materialize");
    let repo = CatalogRepo::new(dir.path().join("repo")).unwrap();
    let seed_a = dir.path().join("a.db");
    create_source(&seed_a, "0.0.12", &["com.a", "com.b"]);
    repo.ensure_seed(&seed_a).unwrap();
    let core = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    assert_eq!(core_apps(&core), 0);

    let first = repo.materialize_if_needed(&core).unwrap();
    assert!(first.materialized);
    assert_eq!(first.apps, 2);
    assert_eq!(first.categories, 1);
    assert_eq!(core_apps(&core), 2);

    let second = repo.materialize_if_needed(&core).unwrap();
    assert!(!second.materialized, "same current must not re-import");
    assert_eq!(second.apps, 2);

    let seed_b = dir.path().join("b.db");
    create_source(&seed_b, "0.0.13", &["com.a", "com.b", "com.c"]);
    repo.ensure_seed(&seed_b).unwrap();
    repo.select("0.0.13").unwrap();
    let third = repo.materialize_if_needed(&core).unwrap();
    assert!(third.materialized, "a new current must re-import");
    assert_eq!(third.apps, 3);
    assert_eq!(core_apps(&core), 3);
}

#[test]
fn repo_databases_are_opened_read_only() {
    let dir = TempDir::new("read_only");
    let repo = CatalogRepo::new(dir.path().join("repo")).unwrap();
    let seed = dir.path().join("seed.db");
    create_source(&seed, "0.0.12", &["com.a"]);
    repo.ensure_seed(&seed).unwrap();
    let current = repo.current_db().unwrap().expect("current db");

    let read_only = Connection::open_with_flags(&current, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .expect("open repo db read-only");
    let write = read_only.execute(
        "INSERT INTO apps(appId, name) VALUES ('com.evil', 'Evil')",
        [],
    );
    match write {
        Err(rusqlite::Error::SqliteFailure(error, _)) => {
            assert_eq!(error.code, rusqlite::ErrorCode::ReadOnly);
        }
        other => panic!("a repo db write must fail, got {other:?}"),
    }

    let before = std::fs::read(&current).unwrap();
    repo.status().unwrap();
    let after = std::fs::read(&current).unwrap();
    assert_eq!(before, after, "status must not write the repo database");
}
