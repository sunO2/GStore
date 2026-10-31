//! Todo 37 failure-mode tests for the config bridge (plan C19).
//!
//! These complement the store-level unit tests. They drive the **real host
//! surfaces** (FRB DTOs, host bus sinks, the live core database, and a core
//! snapshot artifact) to prove:
//!
//! 1. a raw secret never leaks off the trusted path, while the intentional
//!    raw reads (`ConfigApi::get(masked = false)`, host store, backup export)
//!    still return it;
//! 2. restoring a core snapshot with a live `ConfigStore` keeps a valid secret,
//!    and a missing or hash-mismatched secret file clears the row instead of
//!    binding an old row to a newer/other secret.
//!
//! The config store/bus are process-global, so every test serializes.

use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

use gstore_host::bridge::{
    events_recording_config_for_test, reset_config_store_for_test, watch_recording_config_for_test,
    ConfigApi, ConfigEntryDto, CoreApi, RecordingConfigSink,
};
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};

static SERIAL: Mutex<()> = Mutex::new(());

fn serial() -> MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|error| error.into_inner())
}

struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new(tag: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "gstore_config_failure_modes_{tag}_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        Self { root }
    }

    fn init(&self) -> CoreApi {
        CoreApi::init(
            self.root.join("data").to_string_lossy().into_owned(),
            self.root.join("files").to_string_lossy().into_owned(),
            self.root.join("cache").to_string_lossy().into_owned(),
        )
        .expect("CoreApi::init")
    }

    fn db_path(&self) -> PathBuf {
        self.root.join("data").join("gstore_core.db")
    }

    fn db(&self) -> Connection {
        Connection::open_with_flags(self.db_path(), OpenFlags::SQLITE_OPEN_READ_ONLY)
            .expect("open live core db read-only")
    }

    fn secrets_dir(&self) -> PathBuf {
        self.root.join("files").join("secrets")
    }

    fn snapshot_path(&self) -> PathBuf {
        self.root.join("core-snapshot.db")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn value(text: &str) -> Value {
    serde_json::from_str(text).expect("value is JSON")
}

fn watch(module: &str, key: Option<&str>, sink: &RecordingConfigSink) {
    watch_recording_config_for_test(module.to_string(), key.map(str::to_string), sink.clone())
        .expect("register recording config sink");
}

fn entry_of(entries: &[ConfigEntryDto], module: &str, key: &str) -> ConfigEntryDto {
    entries
        .iter()
        .find(|entry| entry.module == module && entry.key == key)
        .unwrap_or_else(|| panic!("missing {module}.{key} entry"))
        .clone()
}

fn assert_absent(haystack: &str, needle: &str, surface: &str) {
    assert!(
        !haystack.contains(needle),
        "raw secret leaked through {surface}: {haystack}"
    );
}

/// Reads the committed `(secret_ref, secret_hash, value_json)` row for a key.
fn secret_row(db: &Connection, module: &str, key: &str) -> (Option<String>, Option<String>, Option<String>) {
    db.query_row(
        "SELECT secret_ref, secret_hash, value_json FROM config_entry \
         WHERE module=?1 AND key=?2",
        rusqlite::params![module, key],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )
    .expect("config_entry row")
}

/// Concatenates every text column that could possibly hold a config value.
fn db_text_dump(db: &Connection) -> String {
    let mut dump = String::new();
    let mut stmt = db
        .prepare(
            "SELECT module, key, value_json, secret_ref, secret_hash, updated_by \
             FROM config_entry",
        )
        .expect("entry stmt");
    let rows = stmt
        .query_map([], |row| {
            Ok(format!(
                "{}|{}|{}|{}|{}|{}",
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                row.get::<_, Option<String>>(4)?.unwrap_or_default(),
                row.get::<_, Option<String>>(5)?.unwrap_or_default(),
            ))
        })
        .expect("entry rows");
    for row in rows {
        dump.push_str(&row.expect("entry row"));
        dump.push('\n');
    }

    let log: String = db
        .query_row(
            "SELECT COALESCE(group_concat(old_json), '') || '|' || \
                    COALESCE(group_concat(new_json), '') || '|' || \
                    COALESCE(group_concat(actor), '') \
             FROM config_change_log",
            [],
            |row| row.get(0),
        )
        .expect("change log dump");
    dump.push_str(&log);
    dump.push('\n');

    let meta: String = db
        .query_row(
            "SELECT COALESCE(group_concat(k), '') || '|' || \
                    COALESCE(group_concat(v), '') FROM config_meta",
            [],
            |row| row.get(0),
        )
        .expect("meta dump");
    dump.push_str(&meta);
    dump
}

#[test]
fn secret_is_absent_from_frb_bus_change_log_and_core_snapshot_but_trusted_paths_keep_it() {
    let _guard = serial();
    reset_config_store_for_test();
    let scratch = Scratch::new("secret_scan");
    let core = scratch.init();
    let config = ConfigApi::init().expect("ConfigApi::init");

    let secret = "task37-frb-host-secret-marker-7c1f";
    let producer = RecordingConfigSink::new();
    let global = RecordingConfigSink::new();
    watch("webdav", Some("password"), &producer);
    events_recording_config_for_test(global.clone());

    let result = config
        .set(
            "webdav".to_string(),
            "password".to_string(),
            json!(secret).to_string(),
            "user".to_string(),
        )
        .expect("set webdav.password");
    assert_eq!(
        value(result.value_json.as_deref().expect("op value")),
        json!("***"),
        "the mutation result is a non-trusted surface"
    );

    // ---- masked surfaces: FRB get/list/snapshot/snapshots + change DTOs ----
    let masked = config
        .get("webdav".to_string(), "password".to_string(), true)
        .expect("masked get");
    assert_eq!(value(&masked), json!("***"));

    let listed = config.list(Some("webdav".to_string())).expect("list webdav");
    let listed_password = entry_of(&listed, "webdav", "password");
    assert!(listed_password.sensitive);
    assert_eq!(value(&listed_password.value_json), json!("***"));
    assert_absent(&format!("{listed:?}"), secret, "ConfigApi::list");

    let snapshots = config
        .snapshots(Some("webdav".to_string()))
        .expect("snapshots");
    let password_snapshot = snapshots
        .iter()
        .find(|snapshot| snapshot.key == "password")
        .expect("password snapshot");
    assert!(password_snapshot.masked);
    assert_eq!(
        value(password_snapshot.value_json.as_deref().expect("snapshot value")),
        json!("***")
    );
    assert_absent(&format!("{snapshots:?}"), secret, "ConfigApi::snapshots");

    let single = config
        .snapshot("webdav".to_string(), "password".to_string())
        .expect("snapshot")
        .expect("stored password");
    assert_eq!(
        value(single.value_json.as_deref().expect("single value")),
        json!("***")
    );

    let producer_changes = producer.received();
    let global_changes = global.received();
    assert_eq!(producer_changes.len(), 1, "exact-key watcher receives once");
    assert_eq!(global_changes.len(), 1, "global stream receives once");
    for change in producer_changes.iter().chain(global_changes.iter()) {
        assert_eq!(change.wire_key, "webdav.password");
        assert_eq!(
            change.value_json.as_deref().map(value),
            Some(json!("***")),
            "bus payload must be masked"
        );
        assert_absent(&format!("{change:?}"), secret, "ConfigChangeDto/bus payload");
    }

    // ---- persistent surfaces: config_entry + config_change_log + core snapshot
    let db = scratch.db();
    let (reference, hash, value_json) = secret_row(&db, "webdav", "password");
    assert_eq!(value_json, None, "secret plaintext must never be in value_json");
    let reference = reference.expect("secret_ref");
    assert!(
        reference.starts_with("config.webdav.password."),
        "unexpected secret_ref {reference}"
    );
    assert!(hash.is_some(), "secret_hash must be recorded");
    assert_absent(&db_text_dump(&db), secret, "config_entry/config_change_log/config_meta");

    let snapshot = scratch.snapshot_path();
    core.export_snapshot(snapshot.to_string_lossy().into_owned())
        .expect("export_snapshot");
    let snapshot_bytes = std::fs::read(&snapshot).expect("read core snapshot");
    assert!(
        !snapshot_bytes
            .windows(secret.len())
            .any(|window| window == secret.as_bytes()),
        "raw secret leaked into the core snapshot artifact"
    );
    let snapshot_db = Connection::open_with_flags(&snapshot, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .expect("open snapshot read-only");
    assert_absent(
        &db_text_dump(&snapshot_db),
        secret,
        "core snapshot config tables",
    );

    // ---- intentional trusted surfaces still return the raw secret ----
    assert_eq!(
        value(&config
            .get("webdav".to_string(), "password".to_string(), false)
            .expect("raw get")),
        json!(secret),
        "trusted ConfigApi.get(masked:false) must keep the raw value"
    );
    assert_eq!(
        value(&core
            .config_value_for_test("webdav".to_string(), "password".to_string())
            .expect("host store raw read")),
        json!(secret),
        "the host-owned ConfigStore path must keep the raw value"
    );
    let export = config.export().expect("raw backup export");
    let exported = export
        .entries
        .iter()
        .find(|entry| entry.wire_key == "webdav.password")
        .expect("password in export");
    assert_eq!(value(&exported.value_json), json!(secret));
    // `export` is the one intentional raw artifact (checked above); all other
    // DTO surfaces were scanned before this point.
    assert!(
        format!("{export:?}").contains(secret),
        "the backup export is the one intentional raw artifact"
    );

    // Rotate once: the old plaintext must not survive anywhere in the DB.
    config
        .set(
            "webdav".to_string(),
            "password".to_string(),
            json!("task37-rotated-marker").to_string(),
            "user".to_string(),
        )
        .expect("rotate");
    assert_absent(&db_text_dump(&scratch.db()), secret, "config tables after rotation");
    assert_eq!(
        value(&config
            .get("webdav".to_string(), "password".to_string(), false)
            .expect("raw get after rotation")),
        json!("task37-rotated-marker")
    );

    drop(snapshot_db);
    drop(db);
    drop(core);
    reset_config_store_for_test();
}

#[test]
fn snapshot_restore_keeps_a_live_secret_and_clears_missing_or_mismatched_hash() {
    let _guard = serial();
    reset_config_store_for_test();
    let scratch = Scratch::new("snapshot_secret");
    let core = scratch.init();
    let config = ConfigApi::init().expect("ConfigApi::init");

    let secret = "task37-restore-secret-marker-2d9a";
    config
        .set(
            "webdav".to_string(),
            "password".to_string(),
            json!(secret).to_string(),
            "user".to_string(),
        )
        .expect("seed secret");
    assert_eq!(
        value(&config
            .get("webdav".to_string(), "password".to_string(), true)
            .expect("masked seed")),
        json!("***")
    );

    let (reference, hash, value_json) = secret_row(&scratch.db(), "webdav", "password");
    let reference = reference.expect("seed secret_ref");
    assert!(hash.is_some());
    assert_eq!(value_json, None);
    let secret_path = scratch.secrets_dir().join(&reference);
    assert!(secret_path.is_file(), "secret file must exist: {}", secret_path.display());

    let snapshot = scratch.snapshot_path();
    core.export_snapshot(snapshot.to_string_lossy().into_owned())
        .expect("export snapshot with config");

    // A live write after the snapshot must be reverted by the restore; it also
    // proves the restore reloads the live ConfigStore cache.
    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(7).to_string(),
            "user".to_string(),
        )
        .expect("post-snapshot write");

    let version = core
        .import_snapshot(snapshot.to_string_lossy().into_owned())
        .expect("restore snapshot");
    assert_eq!(version, gstore_core::migration::CORE_SCHEMA_VERSION);

    // The live store (same Arc as the ABI vtable) observes the restored value.
    assert_eq!(
        value(&config
            .get("webdav".to_string(), "password".to_string(), false)
            .expect("restored raw secret")),
        json!(secret),
        "a snapshot restore with a live store must keep the valid secret"
    );
    assert_eq!(
        value(&core
            .config_value_for_test("webdav".to_string(), "password".to_string())
            .expect("host store after restore")),
        json!(secret)
    );
    assert_eq!(
        value(&config
            .get("download".to_string(), "max_concurrent".to_string(), true)
            .expect("post-snapshot write reverted")),
        json!(3),
        "cache/revision must be reloaded after the swap"
    );
    let password_entry = entry_of(
        &config.list(Some("webdav".to_string())).expect("list after restore"),
        "webdav",
        "password",
    );
    assert_eq!(
        password_entry.revision, 1,
        "the restored revision must come from the snapshot meta"
    );

    // ---- missing secret file: the restored row reads as unset ----
    std::fs::remove_file(&secret_path).expect("remove secret file");
    core.import_snapshot(snapshot.to_string_lossy().into_owned())
        .expect("restore with missing secret");
    assert_eq!(
        value(&config
            .get("webdav".to_string(), "password".to_string(), false)
            .expect("missing secret read")),
        json!(""),
        "a missing secret file must read as the unset default"
    );
    assert!(
        config
            .snapshot("webdav".to_string(), "password".to_string())
            .expect("snapshot lookup")
            .is_none(),
        "a cleared secret row must have no snapshot"
    );
    let (cleared_ref, cleared_hash, cleared_value) =
        secret_row(&scratch.db(), "webdav", "password");
    assert_eq!(cleared_ref, None);
    assert_eq!(cleared_hash, None);
    assert_eq!(cleared_value, None);

    // Restore the correct file, then re-import the same snapshot: the row is
    // valid again (proves the previous clear did not corrupt the snapshot).
    std::fs::write(&secret_path, secret).expect("rewrite correct secret");
    core.import_snapshot(snapshot.to_string_lossy().into_owned())
        .expect("restore with valid secret");
    assert_eq!(
        value(&config
            .get("webdav".to_string(), "password".to_string(), false)
            .expect("restored valid secret")),
        json!(secret)
    );

    // ---- hash mismatch: an old row must never bind to another secret ----
    std::fs::write(&secret_path, "task37-tampered-secret").expect("tamper secret");
    core.import_snapshot(snapshot.to_string_lossy().into_owned())
        .expect("restore with mismatched hash");
    assert_eq!(
        value(&config
            .get("webdav".to_string(), "password".to_string(), false)
            .expect("mismatched hash read")),
        json!(""),
        "a secret_hash mismatch must read as unset, never as the tampered value"
    );
    assert_absent(
        &format!("{:?}", config.list(Some("webdav".to_string())).expect("list")),
        "task37-tampered-secret",
        "list after hash mismatch",
    );
    let (mismatch_ref, mismatch_hash, _) = secret_row(&scratch.db(), "webdav", "password");
    assert_eq!(mismatch_ref, None);
    assert_eq!(mismatch_hash, None);

    drop(core);
    reset_config_store_for_test();
}
