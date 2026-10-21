//! Todo 12: ordered, idempotent channel-data migration contract.
//!
//! Every test name starts with `channel_migration_roundtrip` so the plan QA
//! command selects the whole file. Tests print real row counts, secret
//! presence, backup paths, and source-file existence so a green run cannot
//! hide a misleading success. All fixtures live in private temp directories
//! and are removed on drop.

use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::channel::PackStore;
use gstore_core::channel_migration::ChannelMigrator;
use gstore_core::db::DbHandle;
use gstore_core::ports::{FileSecretPort, FileSecretStore, InMemorySecretPort};
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_channel_migration_{tag}_{}_{}",
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

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// Minimal Floor v5 `channel_added_app` fixture.
fn write_old_db(path: &Path, rows: &[(&str, &str, &str, &str, Option<&str>)]) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
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
             sourceId TEXT,
             PRIMARY KEY (channelCode, appId)
         );
         PRAGMA user_version = 5;",
    )
    .unwrap();
    for (index, (channel, app_id, name, repositories, source_id)) in rows.iter().enumerate() {
        conn.execute(
            "INSERT INTO channel_added_app(
                 appId,name,user,repositories,apprepo,icon,description,category,
                 addTime,channelCode,extra,sourceId)
             VALUES (?1,?2,'owner',?3,?4,'icon.png','description',?5,?6,?7,?8,?9)",
            rusqlite::params![
                app_id,
                name,
                repositories,
                Some("owner/repo"),
                Some("Games"),
                1_700_000_000_000i64 + index as i64,
                channel,
                Some(r#"{"k":"v"}"#),
                source_id,
            ],
        )
        .unwrap();
    }
}

fn write_zip(path: &Path, entry_js: &str) -> Vec<u8> {
    let mut cursor = Cursor::new(Vec::new());
    {
        let mut writer = ZipWriter::new(&mut cursor);
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .unix_permissions(0o644);
        writer.start_file("entry.js", options).unwrap();
        writer.write_all(entry_js.as_bytes()).unwrap();
        writer.start_file("meta.json", options).unwrap();
        writer.write_all(br#"{"name":"Alpha"}"#).unwrap();
        writer.finish().unwrap();
    }
    let bytes = cursor.into_inner();
    std::fs::write(path, &bytes).unwrap();
    bytes
}

fn core(path: &Path) -> DbHandle {
    DbHandle::open_at(&path.join("gstore_core.db")).unwrap()
}

#[test]
fn channel_migration_roundtrip_old_db_rows_backup_and_double_import() {
    let root = TempDir::new("old_db");
    let core_db = core(root.path());
    let old_db = root.path().join("channel_apps.db");
    write_old_db(
        &old_db,
        &[
            ("github", "owner/app", "App One", "owner/app", None),
            (
                "fdroid",
                "org.example",
                "Example",
                "org.example",
                Some("official"),
            ),
        ],
    );
    let source_before = std::fs::read(&old_db).unwrap();
    let backup_dir = root.path().join("backups");
    let secrets = InMemorySecretPort::new();

    let first = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &backup_dir);
        migrator.import_channel_db(&old_db).unwrap()
    };
    println!(
        "first import: rows={} schema_version={} backup={}",
        first.rows_imported,
        first.schema_version,
        first.backup_path.display()
    );
    assert_eq!(first.rows_imported, 2);
    assert_eq!(first.schema_version, 5);
    assert!(first.backup_path.is_file(), "backup must exist");
    let backup_name = first.backup_path.file_name().unwrap().to_string_lossy();
    let expected_prefix = old_db.file_name().unwrap().to_string_lossy();
    println!("backup name = {backup_name}");
    assert!(backup_name.starts_with(&format!("{expected_prefix}.")));
    assert!(backup_name.ends_with(".bak"));
    let stamp = backup_name
        .strip_prefix(&format!("{expected_prefix}."))
        .unwrap()
        .strip_suffix(".bak")
        .unwrap();
    assert!(
        !stamp.is_empty() && stamp.chars().all(|c: char| c.is_ascii_digit() || c == '.'),
        "backup name must be <name>.<utc-ts>.bak, got {backup_name}"
    );
    assert_eq!(
        std::fs::read(&first.backup_path).unwrap(),
        source_before,
        "backup bytes must match the source"
    );
    assert!(old_db.is_file(), "source DB must never be moved/deleted");
    assert_eq!(
        std::fs::read(&old_db).unwrap(),
        source_before,
        "source DB must never be modified"
    );

    let row: (String, String, String, Option<String>, Option<String>) = core_db
        .with_reader(|conn| {
            conn.query_row(
                "SELECT channel_key, name, repositories, source_id, extra
                 FROM channel_apps WHERE channel_key='fdroid' AND app_id='org.example'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    println!("mapped row: {row:?}");
    assert_eq!(row.0, "fdroid");
    assert_eq!(row.1, "Example");
    assert_eq!(row.2, "org.example");
    assert_eq!(row.3.as_deref(), Some("official"));
    assert_eq!(row.4.as_deref(), Some(r#"{"k":"v"}"#));

    let second = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &backup_dir);
        migrator.import_channel_db(&old_db).unwrap()
    };
    let rows: i64 = core_db
        .with_reader(|conn| {
            conn.query_row("SELECT COUNT(*) FROM channel_apps", [], |row| row.get(0))
                .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    println!(
        "second import: rows={} table_rows={rows} backup={}",
        second.rows_imported,
        second.backup_path.display()
    );
    assert_eq!(second.rows_imported, 2);
    assert_eq!(rows, 2, "re-import must upsert, not duplicate");
}

#[test]
fn channel_migration_roundtrip_malformed_db_is_typed_and_retains_backup() {
    let root = TempDir::new("malformed_db");
    let core_db = core(root.path());
    let secrets = InMemorySecretPort::new();
    let backup_dir = root.path().join("backups");

    // Missing required columns.
    let missing = root.path().join("missing_columns.db");
    let conn = Connection::open(&missing).unwrap();
    conn.execute_batch(
        "CREATE TABLE channel_added_app(appId TEXT, name TEXT);
         PRAGMA user_version = 5;",
    )
    .unwrap();
    drop(conn);

    let err = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &backup_dir);
        migrator.import_channel_db(&missing).unwrap_err()
    };
    println!("missing columns -> {err}");
    assert_eq!(err.code(), "CORE_E_MIGRATION_SCHEMA");
    assert!(err.backup_retained(), "backup must be retained on failure");
    let backups = std::fs::read_dir(&backup_dir).unwrap().count();
    println!("backups retained after missing-column failure = {backups}");
    assert!(backups >= 1);

    // Wrong (future) schema version.
    let wrong = root.path().join("wrong_version.db");
    let conn = Connection::open(&wrong).unwrap();
    conn.execute_batch(
        "CREATE TABLE channel_added_app(
             appId TEXT NOT NULL, name TEXT NOT NULL, user TEXT NOT NULL,
             repositories TEXT NOT NULL, icon TEXT NOT NULL,
             description TEXT NOT NULL, addTime INTEGER NOT NULL,
             channelCode TEXT NOT NULL);
         PRAGMA user_version = 99;",
    )
    .unwrap();
    drop(conn);
    let err = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &backup_dir);
        migrator.import_channel_db(&wrong).unwrap_err()
    };
    println!("wrong version -> {err}");
    assert_eq!(err.code(), "CORE_E_MIGRATION_DB_VERSION");

    // Corrupt file: open/query fails, backup still exists.
    let corrupt = root.path().join("corrupt.db");
    std::fs::write(&corrupt, b"this is definitely not a sqlite database").unwrap();
    let err = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &backup_dir);
        migrator.import_channel_db(&corrupt).unwrap_err()
    };
    println!("corrupt -> {err}");
    assert_eq!(err.code(), "CORE_E_MIGRATION_DB");
    let corrupt_backups: Vec<PathBuf> = std::fs::read_dir(&backup_dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("corrupt.db.")
        })
        .collect();
    println!("corrupt backups = {corrupt_backups:?}");
    assert_eq!(corrupt_backups.len(), 1);
    assert!(corrupt_backups[0].is_file());
    assert!(corrupt.is_file(), "corrupt source must be retained");

    let rows: i64 = core_db
        .with_reader(|conn| {
            conn.query_row("SELECT COUNT(*) FROM channel_apps", [], |row| row.get(0))
                .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    assert_eq!(rows, 0, "a failed import must not partially commit rows");
}

#[test]
fn channel_migration_roundtrip_env_sensitive_values_go_to_secret_port() {
    let root = TempDir::new("env");
    let core_db = core(root.path());
    let secret_root = root.path().join("secrets");
    let secrets = FileSecretStore::new(&secret_root);
    let doc = serde_json::json!({
        "version": 1,
        "channel_key": "js.pingan",
        "env": {
            "USER": "alice",
            "PASSWORD": "p@ssw0rd",
            "API_TOKEN": "tok-123",
            "CLIENT_SECRET": "shh",
            "COOKIE": "sid=1",
            "CREDENTIAL": "cred",
            "COLOR": "banana",
            "REGION": "cn"
        }
    });
    let file = root.path().join("channel_env.js.pingan.json");
    std::fs::write(&file, serde_json::to_vec(&doc).unwrap()).unwrap();

    let report = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &root.path().join("backups"));
        migrator.import_channel_env_file(&file).unwrap()
    };
    println!(
        "env report: rows={} secrets={} file_exists={}",
        report.rows,
        report.secrets_written,
        file.exists()
    );
    assert_eq!(report.rows, 1);
    assert_eq!(
        report.secrets_written, 5,
        "PASS/TOKEN/SECRET/COOKIE/CREDENTIAL"
    );
    assert!(!file.exists(), "exported JSON must be deleted after commit");

    let env_json: String = core_db
        .with_reader(|conn| {
            conn.query_row(
                "SELECT env_json FROM channel_env WHERE channel_key='js.pingan'",
                [],
                |row| row.get(0),
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    println!("stored plaintext env row = {env_json}");
    for secret in ["p@ssw0rd", "tok-123", "shh", "sid=1", "cred"] {
        assert!(
            !env_json.contains(secret),
            "plain row leaked secret {secret}: {env_json}"
        );
    }
    assert!(!env_json.contains("PASSWORD"));
    assert!(!env_json.contains("API_TOKEN"));
    assert!(env_json.contains("\"USER\":\"alice\""));
    assert!(env_json.contains("\"COLOR\":\"banana\""));
    assert!(env_json.contains("\"REGION\":\"cn\""));
    assert_eq!(
        secrets
            .get("channel.js.pingan.PASSWORD")
            .unwrap()
            .as_deref(),
        Some("p@ssw0rd")
    );
    assert_eq!(
        secrets
            .get("channel.js.pingan.API_TOKEN")
            .unwrap()
            .as_deref(),
        Some("tok-123")
    );
    let listed = secrets.list().unwrap();
    println!("secrets listed = {listed:?}");
    assert_eq!(listed.len(), 5);

    // Double import: same counts, no duplicate rows or secrets.
    let second = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &root.path().join("backups"));
        migrator.import_channel_env(&doc).unwrap()
    };
    let rows: i64 = core_db
        .with_reader(|conn| {
            conn.query_row("SELECT COUNT(*) FROM channel_env", [], |row| row.get(0))
                .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    assert_eq!(second.rows, 1);
    assert_eq!(second.secrets_written, 5);
    assert_eq!(rows, 1, "env re-import must upsert");
    assert_eq!(secrets.list().unwrap().len(), 5);

    let bad_json = root.path().join("channel_env.bad.json");
    std::fs::write(&bad_json, b"{not json").unwrap();
    let err = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &root.path().join("backups"));
        migrator.import_channel_env_file(&bad_json).unwrap_err()
    };
    println!("malformed env -> {err}");
    assert_eq!(err.code(), "CORE_E_MIGRATION_JSON");
    assert!(bad_json.is_file(), "malformed env doc must be retained");

    let bad_shape = serde_json::json!({"version": 1, "channel_key": "js.bad", "env": []});
    let err = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &root.path().join("backups"));
        migrator.import_channel_env(&bad_shape).unwrap_err()
    };
    println!("malformed env shape -> {err}");
    assert_eq!(err.code(), "CORE_E_MIGRATION_SHAPE");
}

#[test]
fn channel_migration_roundtrip_fdroid_sources_proxy_token_and_idempotency() {
    let root = TempDir::new("fdroid");
    let core_db = core(root.path());
    let secrets = InMemorySecretPort::new();
    let doc = serde_json::json!({
        "version": 1,
        "sources": [
            {"id": "official", "name": "Official", "repoUrl": "https://f-droid.org/repo"},
            {"id": "custom_1", "name": "Custom", "repoUrl": "https://example.com/fdroid/repo"}
        ],
        "last_source_id": "custom_1",
        "proxy_url": "http://127.0.0.1:7890",
        "github_token": "ghp_secret"
    });

    let first = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &root.path().join("backups"));
        migrator.import_fdroid_sources(&doc).unwrap()
    };
    println!(
        "fdroid report: sources={} last={:?} secrets={}",
        first.sources, first.last_source_id, first.secrets_written
    );
    assert_eq!(first.sources, 2);
    assert_eq!(first.last_source_id.as_deref(), Some("custom_1"));
    assert_eq!(first.secrets_written, 1);

    let stored = |key: &str| -> Option<String> {
        core_db
            .with_reader(|conn| gstore_core::migration::update_pref(conn, key))
            .unwrap()
    };
    let sources_json = stored("fdroid_sources").expect("sources persisted");
    println!("stored fdroid_sources = {sources_json}");
    assert!(sources_json.contains("official"));
    assert!(sources_json.contains("custom_1"));
    assert_eq!(stored("last_source_id").as_deref(), Some("custom_1"));
    assert_eq!(
        stored("proxy_url").as_deref(),
        Some("http://127.0.0.1:7890")
    );
    assert_eq!(
        secrets.get("core_config.github_token").unwrap().as_deref(),
        Some("ghp_secret")
    );

    let second = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &root.path().join("backups"));
        migrator.import_fdroid_sources(&doc).unwrap()
    };
    let pref_rows: i64 = core_db
        .with_reader(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM update_prefs WHERE key IN ('fdroid_sources','last_source_id','proxy_url')",
                [],
                |row| row.get(0),
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    assert_eq!(second.sources, 2);
    assert_eq!(pref_rows, 3, "re-import must upsert config rows");
    assert_eq!(secrets.list().unwrap().len(), 1);

    let malformed = serde_json::json!({"version": 1, "sources": "not-a-list"});
    let err = {
        let conn = core_db.writer().unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &root.path().join("backups"));
        migrator.import_fdroid_sources(&malformed).unwrap_err()
    };
    println!("malformed fdroid -> {err}");
    assert_eq!(err.code(), "CORE_E_MIGRATION_SHAPE");
}

#[test]
fn channel_migration_roundtrip_pack_import_is_idempotent() {
    let root = TempDir::new("pack");
    let core_db = core(root.path());
    let pack_root = root.path().join("packs");
    let zip_path = root.path().join("alpha.zip");
    let bytes = write_zip(&zip_path, "// alpha entry\n");
    let expected_hash = sha256_hex(&bytes);
    let secrets = InMemorySecretPort::new();
    let store = PackStore::new(&pack_root, core_db.clone());

    let first = {
        let conn = Connection::open(core_db.path()).unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &root.path().join("backups"));
        migrator.import_pack_archive(&store, &zip_path).unwrap()
    };
    println!(
        "first pack: key={} hash={} installed_at={}",
        first.key, first.pack_hash, first.installed_at
    );
    assert_eq!(first.packs, 1);
    assert_eq!(first.key, "js_alpha");
    assert_eq!(first.pack_hash, expected_hash);
    assert!(
        zip_path.is_file(),
        "pack source must be copied, never moved"
    );

    let second = {
        let conn = Connection::open(core_db.path()).unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &root.path().join("backups"));
        migrator.import_pack_archive(&store, &zip_path).unwrap()
    };
    let (rows, stored_hash, installed_at): (i64, String, i64) = core_db
        .with_reader(|conn| {
            conn.query_row(
                "SELECT COUNT(*), MAX(pack_hash), MAX(installed_at) FROM channel_packs",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    println!(
        "second pack: hash={} rows={rows} stored_hash={stored_hash} installed_at={installed_at}",
        second.pack_hash
    );
    assert_eq!(second.packs, 1);
    assert_eq!(rows, 1, "identical pack must not duplicate the row");
    assert_eq!(stored_hash, expected_hash);
    assert_eq!(
        second.installed_at, first.installed_at,
        "identical pack re-import must be a no-op"
    );

    let corrupt = root.path().join("beta.zip");
    std::fs::write(&corrupt, b"not a zip").unwrap();
    let err = {
        let conn = Connection::open(core_db.path()).unwrap();
        let migrator = ChannelMigrator::new(&conn, &secrets, &root.path().join("backups"));
        migrator.import_pack_archive(&store, &corrupt).unwrap_err()
    };
    println!("corrupt pack -> {err}");
    assert_eq!(err.code(), "CORE_E_MIGRATION_PACK");
    let rows_after: i64 = core_db
        .with_reader(|conn| {
            conn.query_row("SELECT COUNT(*) FROM channel_packs", [], |row| row.get(0))
                .map_err(|error| gstore_core::db::DbError(error.to_string()))
        })
        .unwrap();
    assert_eq!(rows_after, 1, "failed pack must not add a row");
    assert!(corrupt.is_file(), "failed pack source must be retained");
}
