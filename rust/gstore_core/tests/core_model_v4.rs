//! Todo 1 model contract: facts, inventory, rules, and the V4 schema.
//!
//! Every assertion checks a concrete value (accepted flag, row count, exact
//! error variant/message, exact defaults) so a green run cannot hide a
//! misleading success. The stale-seq policy is Decision 3; the rule defaults
//! are Decision 11.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::db::DbHandle;
use gstore_core::event::CoreEvent;
use gstore_core::facts::{
    CorePaths, DeviceFacts, FactStore, InstallReport, InstallReportStatus, InstallRequest,
    InstallResultAck, InstallRules, InventoryPushResult, InventorySnapshot, PlatformFacts,
    UpdateRules, VariantChoice,
};
use gstore_core::inventory::InventoryStore;
use gstore_core::rules::{RuleStore, RULES_VERSION};
use gstore_core::{Error, InstalledApp};
use rusqlite::Connection;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_v4_{tag}_{}_{}",
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

fn app(package: &str, version_name: &str, version_code: i64) -> InstalledApp {
    InstalledApp {
        package_name: package.to_string(),
        app_name: Some(format!("{package} name")),
        version_name: version_name.to_string(),
        version_code,
        signature_sha256: Some("sha256:deadbeef".to_string()),
        source_dir: Some(format!("/data/app/{package}")),
        installer: Some("com.android.vending".to_string()),
        is_system: false,
        target_sdk: 34,
        min_sdk: 26,
        abis: vec!["arm64-v8a".to_string()],
    }
}

fn snapshot(source: &str, seq: i64, captured_at: i64, apps: Vec<InstalledApp>) -> InventorySnapshot {
    InventorySnapshot {
        source_id: source.to_string(),
        seq,
        captured_at,
        apps,
    }
}

fn sample_request() -> InstallRequest {
    InstallRequest {
        module_task_id: "task-1".to_string(),
        session_id: "session-1".to_string(),
        package_name: "com.example.demo".to_string(),
        version_name: "1.2.3".to_string(),
        apk_path: "/data/cache/demo.apk".to_string(),
        method: "shizuku".to_string(),
        variant: VariantChoice {
            abi: "arm64-v8a".to_string(),
            url: "https://example.com/demo-arm64.apk".to_string(),
            fallback_chain: vec![
                "https://example.com/demo-arm64.apk".to_string(),
                "https://example.com/demo.apk".to_string(),
            ],
        },
    }
}

fn table_exists(conn: &Connection, name: &str) -> bool {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
        [name],
        |row| row.get::<_, i64>(0),
    )
    .unwrap()
        == 1
}

fn table_columns(conn: &Connection, table: &str) -> Vec<String> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info(\"{table}\")"))
        .unwrap();
    stmt.query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .map(|row| row.unwrap())
        .collect()
}

fn evidence_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../target/test-evidence")
}

fn snapshot_db(conn: &Connection, name: &str) {
    let dir = evidence_dir();
    std::fs::create_dir_all(&dir).expect("create evidence dir");
    let path = dir.join(name);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    conn.execute(
        "VACUUM INTO ?1",
        rusqlite::params![path.to_string_lossy().into_owned()],
    )
    .expect("snapshot evidence db");
}

#[test]
fn inventory_push_and_diff() {
    let dir = TempDir::new("inventory");
    let db = DbHandle::open(dir.path()).expect("open core db");
    let store = InventoryStore::new(db.clone());

    let first = store
        .push(&snapshot(
            "android",
            1,
            1_700_000_000_000,
            vec![app("com.a", "1.0", 10), app("com.b", "2.0", 20)],
        ))
        .expect("first push");
    assert_eq!(
        first,
        InventoryPushResult {
            accepted: true,
            reason: None
        }
    );
    assert_eq!(store.list().expect("list after first push").len(), 2);
    assert_eq!(store.source_seq("android").expect("seq"), Some(1));

    // Same (source, seq) is an idempotent no-op: the payload is ignored.
    let same = store
        .push(&snapshot(
            "android",
            1,
            1_700_000_000_000,
            vec![app("com.c", "9.9", 99)],
        ))
        .expect("same seq push");
    assert_eq!(
        same,
        InventoryPushResult {
            accepted: false,
            reason: Some("unchanged".to_string())
        }
    );
    let after_same = store.list().expect("list after same push");
    assert_eq!(after_same.len(), 2, "same seq must not replace the app set");
    assert!(after_same.iter().any(|row| row.package_name == "com.a"));

    // Older seq is a typed conflict, and the stored set is untouched.
    let stale = store
        .push(&snapshot("android", 0, 1_700_000_000_001, vec![]))
        .expect_err("older seq must be rejected");
    match stale {
        Error::Conflict(message) => assert_eq!(message, "CORE_E_INVENTORY_STALE"),
        other => panic!("expected Error::Conflict, got {other:?}"),
    }
    assert_eq!(store.list().expect("list after stale").len(), 2);

    // Newer seq replaces this source's set and bumps the stored seq.
    let newer = store
        .push(&snapshot(
            "android",
            2,
            1_700_000_100_000,
            vec![app("com.a", "1.1", 11)],
        ))
        .expect("newer seq push");
    assert!(newer.accepted);
    assert_eq!(newer.reason, None);
    assert_eq!(store.source_seq("android").expect("seq"), Some(2));
    let rows = store.list().expect("list after newer");
    assert_eq!(rows.len(), 1, "newer push replaces the source app set");
    assert_eq!(rows[0].package_name, "com.a");
    assert_eq!(rows[0].version_name, "1.1");
    assert_eq!(store.get("com.b").expect("get removed app"), None);
    assert!(!store
        .is_stale("android", 86_400, 1_700_000_100_000)
        .expect("fresh inventory"));

    // Exactly the two accepted pushes emit an event; the no-op and stale attempts do not.
    let events = store.take_events();
    assert_eq!(events.len(), 2, "only accepted pushes emit events: {events:?}");
    assert_eq!(
        events[0],
        CoreEvent::InventoryChanged {
            source_id: "android".to_string(),
            seq: 1,
            count: 2,
        }
    );
    assert_eq!(
        events[1],
        CoreEvent::InventoryChanged {
            source_id: "android".to_string(),
            seq: 2,
            count: 1,
        }
    );
}

#[test]
fn inventory_rejects_stale_seq() {
    let dir = TempDir::new("stale");
    let db = DbHandle::open(dir.path()).expect("open core db");
    let store = InventoryStore::new(db);

    store
        .push(&snapshot("android", 5, 5_000, vec![]))
        .expect("seed seq 5");

    let error = store
        .push(&snapshot("android", 4, 4_000, vec![app("com.a", "1.0", 1)]))
        .expect_err("seq 4 after 5 must conflict");
    assert!(
        matches!(&error, Error::Conflict(message) if message == "CORE_E_INVENTORY_STALE"),
        "unexpected error: {error:?}"
    );

    // A different source starts its own sequence and is accepted.
    let other = store
        .push(&snapshot("tui", 1, 5_000, vec![app("com.x", "1.0", 1)]))
        .expect("other source first push");
    assert!(other.accepted);
    assert_eq!(store.source_seq("android").expect("android seq"), Some(5));
    assert_eq!(store.source_seq("tui").expect("tui seq"), Some(1));
}

#[test]
fn inventory_duplicate_and_empty_snapshots_are_observable() {
    let dir = TempDir::new("dup");
    let db = DbHandle::open(dir.path()).expect("open core db");
    let store = InventoryStore::new(db);

    let dup = store
        .push(&snapshot(
            "android",
            1,
            1_000,
            vec![app("com.a", "1.0", 1), app("com.a", "2.0", 2)],
        ))
        .expect("duplicate package push");
    assert!(dup.accepted);
    let rows = store.list().expect("list");
    assert_eq!(rows.len(), 1, "duplicate package_names collapse to one row");
    assert_eq!(rows[0].version_name, "2.0", "last duplicate wins");
    assert_eq!(
        store.take_events()[0],
        CoreEvent::InventoryChanged {
            source_id: "android".to_string(),
            seq: 1,
            count: 1,
        }
    );

    // An empty snapshot still advances the sequence and clears the set.
    let empty = store
        .push(&snapshot("android", 2, 2_000, vec![]))
        .expect("empty push");
    assert!(empty.accepted);
    assert_eq!(store.list().expect("list after empty").len(), 0);
    assert_eq!(store.source_seq("android").expect("seq"), Some(2));

    store.invalidate("android").expect("invalidate");
    assert_eq!(store.source_seq("android").expect("seq after invalidate"), None);
    assert!(store
        .is_stale("android", 86_400, 2_001)
        .expect("invalidated inventory is stale"));
    let reseed = store
        .push(&snapshot("android", 1, 3_000, vec![]))
        .expect("push after invalidate");
    assert!(reseed.accepted, "invalidate resets the sequence");
}

#[test]
fn facts_put_and_get_roundtrip() {
    let dir = TempDir::new("facts");
    let db = DbHandle::open(dir.path()).expect("open core db");
    let store = FactStore::new(db.clone());

    assert_eq!(store.get().expect("empty facts"), None);

    let facts = PlatformFacts {
        source_id: "android".to_string(),
        os: "android".to_string(),
        arch: "aarch64".to_string(),
        abis: vec!["arm64-v8a".to_string(), "armeabi-v7a".to_string()],
        sdk: 34,
        device: DeviceFacts {
            model: "Pixel 8".to_string(),
            manufacturer: "Google".to_string(),
        },
        paths: CorePaths {
            data: "/data/data/com.suno2.gstore".to_string(),
            files: "/data/user/0/com.suno2.gstore/files".to_string(),
            cache: "/data/user/0/com.suno2.gstore/cache".to_string(),
        },
        crypto_key: Some(vec![1, 2, 3, 4]),
        captured_at: 1_700_000_000_000,
    };

    store.put(&facts).expect("put facts");
    assert_eq!(store.get().expect("get facts"), Some(facts.clone()));

    let updated = PlatformFacts {
        sdk: 35,
        captured_at: 1_700_000_100_000,
        ..facts
    };
    store.put(&updated).expect("overwrite facts");
    assert_eq!(
        store.get().expect("get updated facts"),
        Some(updated),
        "platform_facts is a single row"
    );
    let rows: i64 = db
        .writer()
        .expect("writer")
        .query_row("SELECT COUNT(*) FROM platform_facts", [], |row| row.get(0))
        .expect("count platform_facts");
    assert_eq!(rows, 1, "platform_facts must stay a single row");
}

#[test]
fn rules_defaults_and_override() {
    const CLOCK_MS: i64 = 1_700_000_000_123;

    let dir = TempDir::new("rules");
    let db = DbHandle::open(dir.path()).expect("open core db");
    let store = RuleStore::with_clock(db.clone(), || CLOCK_MS);

    let defaults = InstallRules {
        version: RULES_VERSION,
        install_enabled: true,
        abi_priority: vec![
            "arm64-v8a".to_string(),
            "armeabi-v7a".to_string(),
            "x86_64".to_string(),
            "x86".to_string(),
        ],
        allow_downgrade: false,
        allow_unknown_sources: false,
        signature_policy: "strict".to_string(),
        silent_install: true,
        timeout_secs: 180,
    };
    assert_eq!(store.get_install().expect("install defaults"), defaults);
    assert_eq!(store.effective_install().expect("effective defaults"), defaults);

    let update_defaults = UpdateRules {
        version: RULES_VERSION,
        channel_priority: Vec::new(),
        allow_prerelease: false,
        signature_policy: "strict".to_string(),
        max_inventory_age_secs: 86_400,
    };
    assert_eq!(store.get_update().expect("update defaults"), update_defaults);
    assert_eq!(
        store.effective_update().expect("effective update defaults"),
        update_defaults
    );

    let install_override = InstallRules {
        install_enabled: false,
        abi_priority: vec!["x86_64".to_string()],
        allow_downgrade: true,
        allow_unknown_sources: true,
        signature_policy: "warn".to_string(),
        silent_install: false,
        timeout_secs: 60,
        ..defaults.clone()
    };
    store.set_install(&install_override).expect("set install");
    assert_eq!(
        store.get_install().expect("stored install"),
        install_override
    );
    let updated_at: i64 = db
        .writer()
        .expect("writer")
        .query_row(
            "SELECT updated_at FROM frontend_rules WHERE kind='install'",
            [],
            |row| row.get(0),
        )
        .expect("read updated_at");
    assert_eq!(
        updated_at, CLOCK_MS,
        "RuleStore must use the injected clock, not the wall clock"
    );
    assert_eq!(
        store.effective_install().expect("effective install"),
        install_override,
        "effective_* returns the stored override"
    );

    let update_override = UpdateRules {
        channel_priority: vec!["stable".to_string(), "beta".to_string()],
        allow_prerelease: true,
        signature_policy: "off".to_string(),
        max_inventory_age_secs: 3_600,
        ..update_defaults.clone()
    };
    store.set_update(&update_override).expect("set update");
    assert_eq!(
        store.get_update().expect("stored update"),
        update_override
    );
    assert_eq!(
        store.effective_update().expect("effective update"),
        update_override
    );

    // An empty stored abi_priority (tampered/legacy row) merges back to defaults.
    let db_handle = db_read_handle(dir.path());
    db_handle
        .with_writer(|conn| {
            let json = serde_json::json!({
                "version": RULES_VERSION,
                "install_enabled": true,
                "abi_priority": [],
                "allow_downgrade": false,
                "allow_unknown_sources": false,
                "signature_policy": "strict",
                "silent_install": true,
                "timeout_secs": 180,
            });
            conn.execute(
                "INSERT INTO frontend_rules(kind, version, json, updated_at) \
                 VALUES ('install', ?1, ?2, 1) \
                 ON CONFLICT(kind) DO UPDATE SET version=excluded.version, \
                     json=excluded.json, updated_at=excluded.updated_at",
                rusqlite::params![RULES_VERSION, json.to_string()],
            )
            .map_err(|e| gstore_core::db::DbError(e.to_string()))?;
            Ok(())
        })
        .expect("seed empty abi_priority");
    assert_eq!(
        store.effective_install().expect("merged install").abi_priority,
        defaults.abi_priority,
        "empty abi_priority is merged from defaults"
    );
}

fn db_read_handle(path: &Path) -> DbHandle {
    DbHandle::open(path).expect("reopen core db")
}

#[test]
fn rules_reject_bad_version() {
    let dir = TempDir::new("rules_bad");
    let db = DbHandle::open(dir.path()).expect("open core db");
    let store = RuleStore::new(db.clone());

    let mut bad = store.get_install().expect("defaults");
    bad.version = RULES_VERSION + 1;
    let error = store.set_install(&bad).expect_err("bad install version");
    match &error {
        Error::InvalidArgument(message) => {
            assert!(
                message.starts_with("CORE_E_RULES_INVALID:"),
                "unexpected message: {message}"
            );
        }
        other => panic!("expected InvalidArgument, got {other:?}"),
    }

    let mut bad_update = store.get_update().expect("update defaults");
    bad_update.version = 0;
    let error = store
        .set_update(&bad_update)
        .expect_err("bad update version");
    assert!(
        matches!(&error, Error::InvalidArgument(message)
            if message.starts_with("CORE_E_RULES_INVALID:")),
        "unexpected error: {error:?}"
    );

    // Unknown signature policy is rejected as invalid rules, not silently stored.
    let mut bad_policy = store.get_install().expect("defaults");
    bad_policy.signature_policy = "maybe".to_string();
    let error = store
        .set_install(&bad_policy)
        .expect_err("unknown signature policy");
    assert!(
        matches!(&error, Error::InvalidArgument(message)
            if message.contains("CORE_E_RULES_INVALID") && message.contains("signature_policy")),
        "unexpected error: {error:?}"
    );

    // Malformed JSON and a diverged version column are rejected on read.
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO frontend_rules(kind, version, json, updated_at) \
             VALUES ('install', ?1, '{not json', 1) \
             ON CONFLICT(kind) DO UPDATE SET version=excluded.version, \
                 json=excluded.json, updated_at=excluded.updated_at",
            rusqlite::params![RULES_VERSION],
        )
        .map_err(|e| gstore_core::db::DbError(e.to_string()))?;
        Ok(())
    })
    .expect("seed malformed rules");
    let error = store.get_install().expect_err("malformed stored JSON");
    assert!(
        matches!(&error, Error::InvalidArgument(message)
            if message.starts_with("CORE_E_RULES_INVALID:")),
        "unexpected error: {error:?}"
    );

    db.with_writer(|conn| {
        conn.execute(
            "UPDATE frontend_rules SET version=?1, json='{}' WHERE kind='install'",
            rusqlite::params![RULES_VERSION + 9],
        )
        .map_err(|e| gstore_core::db::DbError(e.to_string()))?;
        Ok(())
    })
    .expect("seed diverged version");
    let error = store.get_install().expect_err("diverged version column");
    assert!(
        matches!(&error, Error::InvalidArgument(message)
            if message.starts_with("CORE_E_RULES_INVALID:")),
        "unexpected error: {error:?}"
    );
}

#[test]
fn event_wire_names() {
    let events = vec![
        (
            CoreEvent::InventoryChanged {
                source_id: "android".to_string(),
                seq: 7,
                count: 3,
            },
            "inventory.changed",
        ),
        (
            CoreEvent::InstallUnknown {
                session_id: "session-1".to_string(),
                module_task_id: Some("task-1".to_string()),
            },
            "install.unknown",
        ),
        (
            CoreEvent::InstallRequested {
                request: sample_request(),
            },
            "install.requested",
        ),
    ];

    for (event, expected) in events {
        assert_eq!(event.wire_name(), expected, "wire_name mismatch");
        let value = serde_json::to_value(&event).expect("serialize event");
        assert_eq!(
            value.get("event").and_then(|value| value.as_str()),
            Some(expected),
            "serde event name mismatch for {expected}"
        );
        let round_trip: CoreEvent =
            serde_json::from_value(value).expect("deserialize event round-trip");
        assert_eq!(round_trip, event, "event must round-trip: {expected}");
    }
}

#[test]
fn install_report_wire_shape() {
    let base = InstallReport {
        session_id: "session-1".to_string(),
        status: InstallReportStatus::Denied,
        method: "shizuku".to_string(),
        installed_version: None,
        error: Some("user denied".to_string()),
        reported_at: 1_700_000_000_000,
    };

    for (status, expected) in [
        (InstallReportStatus::Installed, "installed"),
        (InstallReportStatus::Failed, "failed"),
        (InstallReportStatus::Denied, "denied"),
        (InstallReportStatus::Timeout, "timeout"),
    ] {
        let report = InstallReport {
            status,
            ..base.clone()
        };
        let value = serde_json::to_value(&report).expect("serialize report");
        assert_eq!(
            value.get("status").and_then(|value| value.as_str()),
            Some(expected),
            "InstallReportStatus must be snake_case on the wire"
        );
        assert_eq!(
            serde_json::from_value::<InstallReport>(value).expect("report round-trip"),
            report
        );
    }

    let ack = InstallResultAck {
        session_id: "session-1".to_string(),
        status: "installed".to_string(),
        changed: false,
    };
    assert_eq!(
        serde_json::from_str::<InstallResultAck>(
            &serde_json::to_string(&ack).expect("serialize ack")
        )
        .expect("ack round-trip"),
        ack
    );
}

#[test]
fn migration_v3_upgrades_to_v4() {
    let dir = TempDir::new("migrate_v3");
    let path = dir.path().join("gstore_core.db");

    {
        let mut conn = Connection::open(&path).expect("open text db");
        let mut runner = gstore_core::migration::migrations::runner();
        runner.set_migration_table_name(gstore_core::migration::MIGRATION_LEDGER_TABLE);
        runner
            .set_target(refinery::Target::Version(3))
            .run(&mut conn)
            .expect("build a genuine V3 database");
        let version: i64 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(version, 3, "fixture must be V3");
        let ledger: i64 = conn
            .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(ledger, 3, "fixture ledger must hold V1-V3");

        conn.execute(
            "INSERT INTO channels(key, kind, name) VALUES ('kept', 'custom', 'Kept')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO download_task(module_task_id, app_id, app_name, status) \
             VALUES ('task-old', 'app.old', 'Old', 'completed')",
            [],
        )
        .unwrap();
        snapshot_db(&conn, "04-upgrade-v3.db");
    }

    let handle = DbHandle::open_at(&path).expect("open with new code upgrades in place");
    let conn = handle.writer().expect("writer");

    let version: i64 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(
        version,
        i64::from(gstore_core::migration::CORE_SCHEMA_VERSION),
        "V3 must upgrade to the current core schema version"
    );
    let ledger: i64 = conn
        .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(ledger, 6, "V4+V5+V6 add three ledger rows");

    for table in [
        "installed_app",
        "inventory_source",
        "platform_facts",
        "frontend_rules",
    ] {
        assert!(table_exists(&conn, table), "missing V4 table {table}");
    }

    let columns = table_columns(&conn, "download_task");
    println!("download_task columns after V3->V4 upgrade = {columns:?}");
    for column in [
        "package_name",
        "abi",
        "variant_url",
        "fallback_json",
        "install_requested_at",
    ] {
        assert!(columns.iter().any(|name| name == column), "missing column {column}");
    }

    // Existing rows survive the upgrade untouched.
    let channel_name: String = conn
        .query_row("SELECT name FROM channels WHERE key='kept'", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(channel_name, "Kept");
    let (task, status): (String, String) = conn
        .query_row(
            "SELECT module_task_id, status FROM download_task WHERE module_task_id='task-old'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(task, "task-old");
    assert_eq!(status, "completed");
    snapshot_db(&conn, "04-upgrade-v4.db");
}

#[test]
fn migration_v4_is_additive_only() {
    let v4 = include_str!("../migrations/V4__inventory_facts.sql");
    assert!(
        !v4.to_ascii_uppercase().contains("DROP "),
        "V4 must never drop anything"
    );
    assert!(
        v4.contains("PRAGMA user_version = 4"),
        "V4 must stamp user_version=4"
    );
    let docs = include_str!("../../../docs/core-schema.sql");
    for object in [
        "CREATE TABLE IF NOT EXISTS installed_app(",
        "CREATE TABLE IF NOT EXISTS inventory_source(",
        "CREATE TABLE IF NOT EXISTS platform_facts(",
        "CREATE TABLE IF NOT EXISTS frontend_rules(",
    ] {
        assert!(v4.contains(object), "V4 missing {object}");
        assert!(docs.contains(object), "docs/core-schema.sql missing {object}");
    }
    for column in [
        "ALTER TABLE download_task ADD COLUMN package_name TEXT;",
        "ALTER TABLE download_task ADD COLUMN abi TEXT;",
        "ALTER TABLE download_task ADD COLUMN variant_url TEXT;",
        "ALTER TABLE download_task ADD COLUMN fallback_json TEXT;",
        "ALTER TABLE download_task ADD COLUMN install_requested_at INTEGER;",
    ] {
        assert!(v4.contains(column), "V4 missing {column}");
    }
}

#[test]
fn schema_stamps_v4_and_adds_columns() {
    let dir = TempDir::new("stamp");
    let conn = gstore_core::db::open(dir.path()).expect("open core db");

    let version: i64 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(
        version,
        i64::from(gstore_core::migration::CORE_SCHEMA_VERSION)
    );

    for table in [
        "installed_app",
        "inventory_source",
        "platform_facts",
        "frontend_rules",
    ] {
        assert!(table_exists(&conn, table), "missing V4 table {table}");
    }
    let columns = table_columns(&conn, "download_task");
    for column in [
        "package_name",
        "abi",
        "variant_url",
        "fallback_json",
        "install_requested_at",
    ] {
        assert!(columns.iter().any(|name| name == column), "missing column {column}");
    }
    snapshot_db(&conn, "04-migrated.db");
}
