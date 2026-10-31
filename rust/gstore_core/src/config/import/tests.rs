//! Tests for idempotent bulk import and read-back verification (Todo 7 / C9).

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use rusqlite::Connection;
use serde_json::json;

use super::*;
use crate::config::bus::{ConfigCaller, ConfigChangePayload, ConfigFilter};
use crate::config::error::{CODE_TYPE_MISMATCH, CODE_UNKNOWN_KEY, CODE_VALIDATION};
use crate::config::model::ConfigKey;
use crate::config::secrets::MASKED;
use crate::config::store::ConfigStore;
use crate::db::DbHandle;
use crate::ports::secret::{FileSecretPort, FileSecretStore};

fn temp_root(tag: &str) -> PathBuf {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!(
        "gstore_cfg_import_{tag}_{}_{}_{}",
        std::process::id(),
        millis,
        counter
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("create temp root");
    dir
}

fn key(module: &str, name: &str) -> ConfigKey {
    ConfigKey::new(module, name).expect("valid test key")
}

struct Fixture {
    root: PathBuf,
    db: DbHandle,
    secrets: Arc<FileSecretStore>,
}

impl Fixture {
    fn new(tag: &str) -> Self {
        let root = temp_root(tag);
        let db = DbHandle::open(&root.join("data")).expect("open core db");
        let secrets = Arc::new(FileSecretStore::new(root.join("secrets")));
        Self { root, db, secrets }
    }

    fn store(&self) -> ConfigStore {
        let store = ConfigStore::new(self.db.clone(), self.secrets.clone());
        store.load_all().expect("load all");
        store
    }

    fn conn(&self) -> Connection {
        Connection::open(self.db.path()).expect("open raw connection")
    }

    fn secret_keys(&self) -> Vec<String> {
        self.secrets.list().expect("list secrets")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn count(conn: &Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |row| row.get(0))
        .expect("count query")
}

fn ten_entry_batch() -> Vec<(ConfigKey, Value)> {
    vec![
        (key("download", "multi_segment.enabled"), json!(false)),
        (key("download", "wifi_only"), json!(true)),
        (key("download", "max_concurrent"), json!(5)),
        (key("download", "default_connections"), json!(6)),
        (key("download", "max_retries"), json!(2)),
        (key("download", "speed_limit_bps"), json!(1024)),
        (key("update", "channel"), json!("beta")),
        (key("update", "auto_update_policy"), json!("always")),
        (key("update", "check_interval_hours"), json!(12)),
        (key("theme", "mode"), json!(2)),
    ]
}

#[test]
fn import_applies_ten_entries_and_verify_passes() {
    let fx = Fixture::new("ten");
    let store = fx.store();
    let bus = ConfigBus::new();
    let batch = ten_entry_batch();

    let report = import_batch(&store, &bus, &batch, ConfigSource::Restore).expect("import");
    assert_eq!(report.total, 10);
    assert_eq!(report.applied, 10);
    assert_eq!(report.unchanged, 0);
    assert!(report.failed.is_empty(), "failed: {:?}", report.failed);
    assert_eq!(report.events_published, 10);

    let verified = verify(&store, &batch).expect("verify");
    assert_eq!(verified.total, 10);
    assert_eq!(verified.matched, 10);
    assert!(verified.all_matched());
    assert!(verified
        .results
        .iter()
        .all(|result| result.status == VerifyStatus::Match));

    let conn = fx.conn();
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM config_entry"), 10);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM config_change_log"), 10);
    assert_eq!(store.revision(), 10, "one revision per applied entry");
    let mut revisions: Vec<u64> = batch
        .iter()
        .map(|(key, _)| {
            store
                .snapshot(key)
                .expect("snapshot")
                .expect("applied entry is set")
                .revision
        })
        .collect();
    revisions.sort_unstable();
    assert_eq!(revisions, (1..=10).collect::<Vec<u64>>());
}

#[test]
fn second_import_pass_is_idempotent_and_adds_no_change_log() {
    let fx = Fixture::new("idempotent");
    let store = fx.store();
    let bus = ConfigBus::new();
    let batch = ten_entry_batch();

    let first = import_batch(&store, &bus, &batch, ConfigSource::Restore).expect("first");
    assert_eq!(first.applied, 10);
    let revision_after_first = store.revision();
    let log_after_first = count(&fx.conn(), "SELECT COUNT(*) FROM config_change_log");

    let second = import_batch(&store, &bus, &batch, ConfigSource::Restore).expect("second");
    assert_eq!(second.total, 10);
    assert_eq!(second.applied, 0);
    assert_eq!(second.unchanged, 10);
    assert!(second.failed.is_empty());
    assert_eq!(second.events_published, 0);
    assert_eq!(store.revision(), revision_after_first);
    assert_eq!(
        count(&fx.conn(), "SELECT COUNT(*) FROM config_change_log"),
        log_after_first,
        "unchanged entries must not append change-log rows"
    );
    assert!(verify(&store, &batch).expect("verify").all_matched());
}

#[test]
fn invalid_entry_is_reported_and_valid_subset_applies_atomically() {
    let fx = Fixture::new("invalid");
    let store = fx.store();
    let bus = ConfigBus::new();
    let mut batch = ten_entry_batch();
    // Replace the valid update channel with an out-of-enum value.
    batch[6] = (key("update", "channel"), json!("nightly"));

    let report = import_batch(&store, &bus, &batch, ConfigSource::Restore).expect("import");
    assert_eq!(report.total, 10);
    assert_eq!(report.applied, 9);
    assert_eq!(report.unchanged, 0);
    assert_eq!(
        report.failed,
        vec![(key("update", "channel"), CODE_VALIDATION.to_string())]
    );

    assert_eq!(
        store.get(&key("update", "channel")).expect("get"),
        json!("stable"),
        "the invalid entry must never be written"
    );
    let conn = fx.conn();
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM config_entry"), 9);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM config_change_log"), 9);
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM config_entry WHERE module='update' AND key='channel'"
        ),
        0
    );
}

#[test]
fn malformed_entries_report_unknown_type_and_range_codes() {
    let fx = Fixture::new("malformed");
    let store = fx.store();
    let bus = ConfigBus::new();
    let batch = vec![
        (key("download", "max_concurrent"), json!(5)),
        (key("download", "nope"), json!(1)),
        (key("download", "wifi_only"), json!("yes")),
        (key("download", "max_retries"), json!(99)),
    ];

    let report = import_batch(&store, &bus, &batch, ConfigSource::Restore).expect("import");
    assert_eq!(report.total, 4);
    assert_eq!(report.applied, 1);
    assert_eq!(report.unchanged, 0);
    assert_eq!(report.failed.len(), 3);
    assert!(report
        .failed
        .iter()
        .any(|(_, code)| code == CODE_UNKNOWN_KEY));
    assert!(report
        .failed
        .iter()
        .any(|(_, code)| code == CODE_TYPE_MISMATCH));
    assert!(report
        .failed
        .iter()
        .any(|(_, code)| code == CODE_VALIDATION));
    assert_eq!(count(&fx.conn(), "SELECT COUNT(*) FROM config_entry"), 1);
    assert_eq!(
        store.get(&key("download", "max_retries")).expect("get"),
        json!(3),
        "out-of-range value keeps its default"
    );
}

#[test]
fn forced_db_failure_rolls_back_rows_change_log_and_secret_files() {
    let fx = Fixture::new("failure");
    let store = fx.store();
    let bus = ConfigBus::new();
    let batch = vec![
        (key("download", "max_concurrent"), json!(5)),
        (key("webdav", "password"), json!("db-failure-secret")),
        (key("theme", "mode"), json!(2)),
    ];

    let trigger = fx.conn();
    trigger
        .execute(
            "CREATE TRIGGER fail_import BEFORE INSERT ON config_change_log \
             BEGIN SELECT RAISE(ABORT, 'forced import failure'); END;",
            [],
        )
        .expect("create failure trigger");

    let revision_before = store.revision();
    let secrets_before = fx.secret_keys();
    let result = import_batch(&store, &bus, &batch, ConfigSource::Restore);
    assert!(result.is_err(), "forced DB failure must surface as Err");

    let conn = fx.conn();
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM config_entry"), 0);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM config_change_log"), 0);
    assert_eq!(store.revision(), revision_before);
    assert_eq!(
        store.get(&key("webdav", "password")).expect("get"),
        json!(""),
        "cache still reads the unset default"
    );
    assert_eq!(
        fx.secret_keys(),
        secrets_before,
        "compensated secret writes must not leave orphan files"
    );
}

#[test]
fn secret_import_masks_change_log_and_verify_never_leaks_plaintext() {
    let fx = Fixture::new("secret");
    let store = fx.store();
    let bus = ConfigBus::new();
    let seen = Arc::new(Mutex::new(Vec::<ConfigChangePayload>::new()));
    let captured = seen.clone();
    let _token = bus.subscribe(
        ConfigCaller::Host,
        ConfigFilter::whole_module("webdav"),
        move |payload| captured.lock().expect("lock").push(payload.clone()),
    );
    let batch = vec![
        (key("webdav", "password"), json!("s3cr3t-plaintext")),
        (key("download", "max_concurrent"), json!(4)),
    ];

    let report = import_batch(&store, &bus, &batch, ConfigSource::Restore).expect("import");
    assert_eq!(report.applied, 2);
    assert!(report.failed.is_empty());

    let conn = fx.conn();
    let (old_json, new_json): (Option<String>, Option<String>) = conn
        .query_row(
            "SELECT old_json, new_json FROM config_change_log \
             WHERE module='webdav' AND key='password'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("secret change-log row");
    assert_eq!(old_json, None);
    assert_eq!(new_json.as_deref(), Some(MASKED));

    let verified = verify(&store, &batch).expect("verify");
    assert!(verified.all_matched());
    let report_json = serde_json::to_string(&report).expect("report json");
    let verify_json = serde_json::to_string(&verified).expect("verify json");
    assert!(!report_json.contains("s3cr3t-plaintext"));
    assert!(!verify_json.contains("s3cr3t-plaintext"));
    assert_eq!(
        store.get(&key("webdav", "password")).expect("raw get"),
        json!("s3cr3t-plaintext"),
        "trusted raw read still returns the secret"
    );
    assert_eq!(
        store
            .get_masked(&key("webdav", "password"))
            .expect("masked get"),
        json!(MASKED)
    );

    let payloads = seen.lock().expect("lock").clone();
    assert_eq!(
        payloads.len(),
        1,
        "only the secret change belongs to webdav"
    );
    let payload_json = serde_json::to_string(&payloads[0]).expect("payload json");
    assert_eq!(payloads[0].value, Some(json!(MASKED)));
    assert_eq!(payloads[0].old_value, None);
    assert!(!payload_json.contains("s3cr3t-plaintext"));
}

#[test]
fn duplicate_keys_are_rejected_without_orphan_secret_files() {
    let fx = Fixture::new("duplicate");
    let store = fx.store();
    let bus = ConfigBus::new();
    let batch = vec![
        (key("download", "max_concurrent"), json!(5)),
        (key("download", "max_concurrent"), json!(7)),
        (key("webdav", "password"), json!("first-secret")),
        (key("webdav", "password"), json!("second-secret")),
    ];

    let report = import_batch(&store, &bus, &batch, ConfigSource::Restore).expect("import");
    assert_eq!(report.total, 4);
    assert_eq!(report.applied, 2, "first occurrence of each key wins");
    assert_eq!(report.unchanged, 0);
    assert_eq!(report.failed.len(), 2);
    assert!(report
        .failed
        .iter()
        .all(|(_, code)| code == CODE_IMPORT_DUPLICATE));
    assert_eq!(
        store.get(&key("download", "max_concurrent")).expect("get"),
        json!(5)
    );
    assert_eq!(
        store.get(&key("webdav", "password")).expect("get"),
        json!("first-secret")
    );
    assert_eq!(
        fx.secret_keys().len(),
        1,
        "the rejected duplicate secret must not leave an orphan file"
    );
    assert_eq!(
        count(&fx.conn(), "SELECT COUNT(*) FROM config_change_log"),
        2
    );
}

#[test]
fn events_are_published_once_per_applied_key_and_suppressed_when_quiet() {
    let fx = Fixture::new("events");
    let store = fx.store();
    let bus = ConfigBus::new();
    // Seed one value so it is unchanged during the import.
    store
        .set(
            &key("download", "wifi_only"),
            json!(true),
            ConfigSource::User,
            None,
        )
        .expect("seed");

    let seen = Arc::new(Mutex::new(Vec::<ConfigChangePayload>::new()));
    let captured = seen.clone();
    let _token = bus.subscribe(
        ConfigCaller::Host,
        ConfigFilter::whole_module("download"),
        move |payload| captured.lock().expect("lock").push(payload.clone()),
    );

    let batch = vec![
        (key("download", "wifi_only"), json!(true)),
        (key("download", "max_concurrent"), json!(5)),
        (key("download", "max_retries"), json!(1)),
        (key("download", "nope"), json!(1)),
    ];
    let report = import_batch(&store, &bus, &batch, ConfigSource::Restore).expect("import");
    assert_eq!(report.applied, 2);
    assert_eq!(report.unchanged, 1);
    assert_eq!(report.failed.len(), 1);
    assert_eq!(report.events_published, 2);

    let keys: Vec<String> = seen
        .lock()
        .expect("lock")
        .iter()
        .map(|payload| payload.key.clone())
        .collect();
    assert_eq!(keys, vec!["max_concurrent", "max_retries"]);
    assert!(
        !keys.iter().any(|name| name == "wifi_only"),
        "unchanged entries must not emit"
    );

    let quiet = import_quiet(
        &store,
        &bus,
        &[(key("download", "max_concurrent"), json!(6))],
        ConfigSource::Restore,
    )
    .expect("quiet import");
    assert_eq!(quiet.applied, 1);
    assert_eq!(quiet.events_published, 0);
    assert_eq!(
        seen.lock().expect("lock").len(),
        2,
        "quiet import must not emit any event"
    );
}

#[test]
fn verify_reports_mismatch_after_external_change_without_leaking_values() {
    let fx = Fixture::new("verify");
    let store = fx.store();
    let bus = ConfigBus::new();
    let numeric = vec![(key("download", "max_concurrent"), json!(5))];
    import_batch(&store, &bus, &numeric, ConfigSource::Restore).expect("import");
    assert!(verify(&store, &numeric).expect("verify").all_matched());

    fx.conn()
        .execute(
            "UPDATE config_entry SET value_json='7' \
             WHERE module='download' AND key='max_concurrent'",
            [],
        )
        .expect("external update");
    let report = verify(&store, &numeric).expect("verify");
    assert_eq!(report.matched, 0);
    assert_eq!(report.results[0].status, VerifyStatus::Mismatch);

    let password = key("webdav", "password");
    let secret = vec![(password.clone(), json!("external-old-secret"))];
    import_batch(&store, &bus, &secret, ConfigSource::Restore).expect("import secret");
    store
        .set(
            &password,
            json!("external-new-secret"),
            ConfigSource::User,
            None,
        )
        .expect("external secret change");
    let secret_report = verify(&store, &secret).expect("verify secret");
    assert_eq!(secret_report.matched, 0);
    assert_eq!(secret_report.results[0].status, VerifyStatus::Mismatch);
    let serialized = serde_json::to_string(&secret_report).expect("json");
    assert!(!serialized.contains("external-old-secret"));
    assert!(!serialized.contains("external-new-secret"));
}

#[test]
fn verify_reports_per_key_rejection_for_unknown_and_invalid_entries() {
    let fx = Fixture::new("verify_invalid");
    let store = fx.store();
    let bus = ConfigBus::new();
    import_batch(
        &store,
        &bus,
        &[(key("download", "max_concurrent"), json!(5))],
        ConfigSource::Restore,
    )
    .expect("import");

    let report = verify(
        &store,
        &[
            (key("download", "nope"), json!(1)),
            (key("update", "channel"), json!("nightly")),
            (key("download", "max_concurrent"), json!(5)),
        ],
    )
    .expect("verify");
    assert_eq!(report.total, 3);
    assert_eq!(report.matched, 1);
    assert!(matches!(
        report.results[0].status,
        VerifyStatus::Rejected(ref code) if code == CODE_UNKNOWN_KEY
    ));
    assert!(matches!(
        report.results[1].status,
        VerifyStatus::Rejected(ref code) if code == CODE_VALIDATION
    ));
    assert_eq!(report.results[2].status, VerifyStatus::Match);
}

#[test]
fn import_never_deletes_entries_absent_from_the_input() {
    let fx = Fixture::new("no_delete");
    let store = fx.store();
    let bus = ConfigBus::new();
    store
        .set(&key("theme", "mode"), json!(2), ConfigSource::User, None)
        .expect("seed unrelated key");

    import_batch(
        &store,
        &bus,
        &[(key("download", "max_concurrent"), json!(5))],
        ConfigSource::Restore,
    )
    .expect("import");
    assert_eq!(
        store.get(&key("theme", "mode")).expect("get"),
        json!(2),
        "entries absent from the batch are preserved"
    );
    assert_eq!(count(&fx.conn(), "SELECT COUNT(*) FROM config_entry"), 2);
}
