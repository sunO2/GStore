//! Todo 8: persistent channel registry contract.
//!
//! Every test name carries the `registry_persists` prefix so the plan's QA
//! command (`cargo test ... registry_persists`) selects the whole file. The
//! tests print observable row counts, ordering, timestamps, and typed error
//! codes so a green run cannot hide a misleading success.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::channel::{ChannelRecord, ChannelRegistry, ChannelStore, SqliteChannelStore};
use gstore_core::db::DbHandle;
use gstore_core::dto::{ChannelKey, ChannelKind, ChannelMeta};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_registry_{tag}_{}_{}",
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

fn meta(kind: ChannelKind, name: &str, enabled: bool, priority: i32) -> ChannelMeta {
    ChannelMeta {
        kind,
        name: name.to_string(),
        description: format!("{name} channel"),
        enabled,
        priority,
        support_offline: false,
        last_update_time: None,
        version: Some("test".to_string()),
    }
}

fn record(key: &str, kind: ChannelKind, enabled: bool, priority: i32) -> ChannelRecord {
    ChannelRecord::new(
        ChannelKey::new(key).expect("valid channel key"),
        meta(kind, key, enabled, priority),
    )
}

fn keys(records: &[ChannelRecord]) -> Vec<String> {
    records
        .iter()
        .map(|record| record.key.as_str().to_string())
        .collect()
}

fn clock(start: i64) -> (Arc<AtomicI64>, impl Fn() -> i64 + Send + Sync + 'static) {
    let value = Arc::new(AtomicI64::new(start));
    let handle = Arc::clone(&value);
    (value, move || handle.fetch_add(1, Ordering::SeqCst))
}

#[test]
fn registry_persists_order_filter_js_key_and_reopen() {
    let dir = TempDir::new("reopen");
    let db_path = dir.path().join("gstore_core.db");
    let handle = DbHandle::open_at(&db_path).expect("open core db");
    let (_ticks, tick) = clock(1_000);
    let store = SqliteChannelStore::with_clock(handle.clone(), tick);

    store
        .register(record("local_db", ChannelKind::LocalDb, true, 30))
        .expect("register local_db");
    store
        .register(record("github", ChannelKind::Github, false, 20))
        .expect("register github");
    // Dynamic script channel: `js_*` key plus JsLocal kind.
    store
        .register(record("js_custom", ChannelKind::JsLocal, true, 10))
        .expect("register js_custom");
    store
        .register(record("http", ChannelKind::Http, true, 10))
        .expect("register http");

    let listed = store.list().expect("list");
    println!(
        "after 4 registers: list count={} keys={:?}",
        listed.len(),
        keys(&listed)
    );
    assert_eq!(listed.len(), 4);
    assert_eq!(
        keys(&listed),
        vec!["github", "http", "js_custom", "local_db"]
    );

    let ordered = store.priority_order().expect("priority order");
    println!(
        "enabled priority_order count={} keys={:?} (priority,key)",
        ordered.len(),
        keys(&ordered)
    );
    assert_eq!(keys(&ordered), vec!["http", "js_custom", "local_db"]);

    let js = store
        .get(&ChannelKey::new("js_custom").unwrap())
        .expect("get js")
        .expect("js_custom registered");
    println!(
        "js_custom round-trip kind={:?} enabled={}",
        js.kind(),
        js.enabled()
    );
    assert_eq!(js.kind(), ChannelKind::JsLocal);

    // enable/disable and priority mutations must persist.
    let github = ChannelKey::new("github").unwrap();
    let local_db = ChannelKey::new("local_db").unwrap();
    let js_custom = ChannelKey::new("js_custom").unwrap();
    store.enable(&github).expect("enable github");
    store.disable(&local_db).expect("disable local_db");
    store
        .set_priority(&js_custom, 5)
        .expect("priority js_custom");
    let mutated = store
        .priority_order()
        .expect("priority order after mutations");
    println!(
        "after enable(github)/disable(local_db)/set_priority(js_custom,5): enabled={:?}",
        keys(&mutated)
    );
    assert_eq!(keys(&mutated), vec!["js_custom", "http", "github"]);

    let before_close = store.list().expect("list before close");
    drop(store);
    drop(handle);

    // Reopen the same database file through a brand-new handle/store.
    let reopened_handle = DbHandle::open_at(&db_path).expect("reopen core db");
    let (_ticks2, tick2) = clock(9_000);
    let reopened = SqliteChannelStore::with_clock(reopened_handle, tick2);
    let after_reopen = reopened.list().expect("list after reopen");
    println!(
        "after reopen: list count={} keys={:?}",
        after_reopen.len(),
        keys(&after_reopen)
    );
    assert_eq!(after_reopen, before_close, "rows must survive reopen");

    let reopened_order = reopened.priority_order().expect("priority after reopen");
    println!(
        "after reopen: priority_order count={} keys={:?}",
        reopened_order.len(),
        keys(&reopened_order)
    );
    assert_eq!(
        keys(&reopened_order),
        vec!["js_custom", "http", "github"],
        "enabled filter and (priority,key) order must survive reopen"
    );

    let persisted_github = reopened.get(&github).expect("get github").unwrap();
    let persisted_local = reopened.get(&local_db).expect("get local_db").unwrap();
    let persisted_js = reopened.get(&js_custom).expect("get js").unwrap();
    println!(
        "persisted flags: github.enabled={} local_db.enabled={} js_custom.kind={:?} js_custom.priority={}",
        persisted_github.enabled(),
        persisted_local.enabled(),
        persisted_js.kind(),
        persisted_js.priority()
    );
    assert!(persisted_github.enabled());
    assert!(!persisted_local.enabled());
    assert_eq!(persisted_js.kind(), ChannelKind::JsLocal);
    assert_eq!(persisted_js.priority(), 5);

    // A second live store sees the first store's commits (rollback and stale
    // state are both observable).
    let second = SqliteChannelStore::new(DbHandle::open_at(&db_path).expect("second handle"));
    second
        .register(record("fdroid", ChannelKind::Fdroid, true, 1))
        .expect("second store register");
    println!(
        "second store sees first store rows: count={} keys={:?}",
        second.list().expect("second list").len(),
        keys(&second.list().expect("second list"))
    );
    assert!(reopened
        .get(&ChannelKey::new("fdroid").unwrap())
        .expect("first store sees second commit")
        .is_some());
}

#[test]
fn registry_persists_idempotent_register_preserves_created_at() {
    let dir = TempDir::new("idempotent");
    let handle = DbHandle::open_at(&dir.path().join("gstore_core.db")).expect("open");
    let (_ticks, tick) = clock(100);
    let store = SqliteChannelStore::with_clock(handle, tick);
    let original = record("js_idem", ChannelKind::JsLocal, true, 7);

    store.register(original.clone()).expect("first register");
    let first_ts = store
        .timestamps(&ChannelKey::new("js_idem").unwrap())
        .expect("timestamps")
        .expect("row exists");
    let first_count = store.list().expect("list").len();
    println!("first register: count={first_count} timestamps={first_ts:?}");

    store
        .register(original.clone())
        .expect("identical re-register is idempotent");
    let second_ts = store
        .timestamps(&ChannelKey::new("js_idem").unwrap())
        .expect("timestamps")
        .expect("row exists");
    let second_count = store.list().expect("list").len();
    let stored = store
        .get(&ChannelKey::new("js_idem").unwrap())
        .expect("get")
        .expect("row exists");
    println!(
        "identical re-register: count={second_count} timestamps={second_ts:?} record={stored:?}"
    );
    assert_eq!(
        second_count, first_count,
        "idempotent register must not duplicate"
    );
    assert_eq!(
        stored, original,
        "idempotent register must keep the payload"
    );
    assert_eq!(
        second_ts.0, first_ts.0,
        "created_at must be set exactly once"
    );
    assert_eq!(
        second_ts.1, first_ts.1,
        "an identical register is not a mutation, so updated_at stays put"
    );
    assert!(second_count > 0, "row count must be visible in the log");
}

#[test]
fn registry_persists_duplicate_and_conflict_typed_errors() {
    let dir = TempDir::new("errors");
    let handle = DbHandle::open_at(&dir.path().join("gstore_core.db")).expect("open");
    let store = SqliteChannelStore::new(handle.clone());

    store
        .insert(record("js_dup", ChannelKind::JsLocal, true, 0))
        .expect("strict insert first time");
    let duplicate = store
        .insert(record("js_dup", ChannelKind::JsLocal, true, 0))
        .expect_err("insert must reject any existing key");
    println!(
        "insert duplicate js_dup: code={} message={}",
        duplicate.code(),
        duplicate.message()
    );
    assert_eq!(duplicate.code(), "conflict");

    // Same key, same kind but different mutable metadata: register upserts.
    store
        .register(record("js_dup", ChannelKind::JsLocal, false, 9))
        .expect("register same identity updates metadata");
    let updated = store
        .get(&ChannelKey::new("js_dup").unwrap())
        .expect("get")
        .expect("row exists");
    println!(
        "register mutable upsert: enabled={} priority={}",
        updated.enabled(),
        updated.priority()
    );
    assert!(!updated.enabled());
    assert_eq!(updated.priority(), 9);

    // Same key, different immutable identity (kind): typed Conflict.
    let conflict = store
        .register(record("js_dup", ChannelKind::Custom, true, 0))
        .expect_err("kind mismatch must conflict");
    println!(
        "register kind mismatch js_dup: code={} message={}",
        conflict.code(),
        conflict.message()
    );
    assert_eq!(conflict.code(), "conflict");

    let bad_key = ChannelKey::new("bad/key").expect("non-empty key");
    let bad_key_err = store
        .insert(ChannelRecord::new(
            bad_key,
            meta(ChannelKind::Custom, "bad/key", true, 0),
        ))
        .expect_err("path characters must be rejected");
    println!(
        "invalid key: code={} message={}",
        bad_key_err.code(),
        bad_key_err.message()
    );
    assert_eq!(bad_key_err.code(), "invalid_argument");

    let empty: ChannelKey = serde_json::from_str("\"\"").expect("transparent key");
    let empty_err = store
        .insert(ChannelRecord::new(
            empty,
            meta(ChannelKind::Custom, "empty", true, 0),
        ))
        .expect_err("empty key must be rejected");
    println!(
        "empty key: code={} message={}",
        empty_err.code(),
        empty_err.message()
    );
    assert_eq!(empty_err.code(), "invalid_argument");

    let negative = store
        .insert(record("negative", ChannelKind::Custom, true, -1))
        .expect_err("negative priority must be rejected");
    println!(
        "negative priority: code={} message={}",
        negative.code(),
        negative.message()
    );
    assert_eq!(negative.code(), "invalid_argument");

    let valid_count = store.list().expect("valid rows list").len();
    println!("valid row count before malformed reads failed = {valid_count}");
    assert_eq!(valid_count, 1);

    // Simulate legacy/external corruption: unknown kind strings and overflow
    // priorities must produce typed errors on read, never a panic.
    handle
        .with_writer(|conn| {
            conn.execute(
                "INSERT INTO channels(key, kind, name) VALUES ('weird', 'bogus', 'weird')",
                [],
            )
            .map_err(|e| gstore_core::db::DbError(e.to_string()))?;
            conn.execute(
                "INSERT INTO channels(key, kind, name, priority) VALUES ('overflow', 'custom', 'overflow', ?1)",
                [i64::MAX],
            )
            .map_err(|e| gstore_core::db::DbError(e.to_string()))?;
            Ok(())
        })
        .expect("seed malformed rows");

    let unknown_kind = store
        .get(&ChannelKey::new("weird").unwrap())
        .expect_err("unknown kind must be typed");
    println!(
        "unknown kind row: code={} message={}",
        unknown_kind.code(),
        unknown_kind.message()
    );
    assert_eq!(unknown_kind.code(), "invalid_argument");

    let overflow = store
        .get(&ChannelKey::new("overflow").unwrap())
        .expect_err("overflow priority must be typed");
    println!(
        "overflow priority row: code={} message={}",
        overflow.code(),
        overflow.message()
    );
    assert_eq!(overflow.code(), "invalid_argument");

    let list_error = store
        .list()
        .expect_err("a malformed row must fail list with a typed error, not panic");
    println!(
        "list with malformed row: code={} message={}",
        list_error.code(),
        list_error.message()
    );
    assert_eq!(list_error.code(), "invalid_argument");
}

#[test]
fn registry_persists_db_backed_registry_facade() {
    let dir = TempDir::new("facade");
    let registry = ChannelRegistry::open_db(dir.path()).expect("db-backed registry");
    registry
        .register(record("local_db", ChannelKind::LocalDb, true, 0))
        .expect("register");
    println!(
        "ChannelRegistry<SqliteChannelStore> list={:?} priority={:?}",
        keys(&registry.list().expect("list")),
        keys(&registry.priority_order().expect("priority"))
    );
    assert_eq!(registry.store().list().expect("store list").len(), 1);
}

#[test]
fn registry_persists_unregister_create_and_missing_keys() {
    let dir = TempDir::new("unregister");
    let db_path = dir.path().join("gstore_core.db");
    let handle = DbHandle::open_at(&db_path).expect("open");
    let store = SqliteChannelStore::new(handle);

    let local = record("local_db", ChannelKind::LocalDb, true, 0);
    store.insert(local.clone()).expect("strict insert");
    let duplicate_create = store
        .create(local.clone())
        .expect_err("create alias must reject an existing key");
    println!(
        "create duplicate local_db: code={} message={}",
        duplicate_create.code(),
        duplicate_create.message()
    );
    assert_eq!(duplicate_create.code(), "conflict");

    let key = local.key.clone();
    store.unregister(&key).expect("unregister");
    println!(
        "after unregister: get={:?} list={:?}",
        store.get(&key).expect("get"),
        keys(&store.list().expect("list"))
    );
    assert!(store.get(&key).expect("get").is_none());
    assert!(store.list().expect("list").is_empty());

    drop(store);
    let reopened = SqliteChannelStore::new(DbHandle::open_at(&db_path).expect("reopen"));
    assert!(
        reopened.get(&key).expect("get after reopen").is_none(),
        "unregister must be durable"
    );

    let missing = ChannelKey::new("missing").unwrap();
    for (label, error) in [
        ("unregister", reopened.unregister(&missing).unwrap_err()),
        ("enable", reopened.enable(&missing).unwrap_err()),
        ("disable", reopened.disable(&missing).unwrap_err()),
        (
            "set_priority",
            reopened.set_priority(&missing, 1).unwrap_err(),
        ),
    ] {
        println!(
            "{label} missing key: code={} message={}",
            error.code(),
            error.message()
        );
        assert_eq!(error.code(), "not_found");
    }
    println!(
        "durable unregister proof: reopened list count={}",
        reopened.list().expect("list").len()
    );
}
