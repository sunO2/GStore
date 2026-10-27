//! Todo 3 contract: channel driver/store/registry/local-pack traits.
//!
//! The test names all carry the `channel_traits_contract` prefix so the plan's
//! QA command (`cargo test ... channel_traits_contract`) selects this binary.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;

use gstore_core::channel::{
    ChannelCategory, ChannelConfig, ChannelDriver, ChannelPack, ChannelRecord, ChannelRegistry,
    ChannelStore, InMemoryChannelDriver, InMemoryChannelRegistry, InMemoryChannelStore,
    PackIconSource,
};
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta};
use gstore_core::error::Error;
use serde_json::json;

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

fn sample_app(app_id: &str) -> AppSummary {
    let mut extra = serde_json::Map::new();
    extra.insert("stars".to_string(), json!(1));
    AppSummary {
        app_id: app_id.to_string(),
        package_name: Some(format!("com.example.{app_id}")),
        name: format!("Demo {app_id}"),
        user: "acme".to_string(),
        repositories: "demo".to_string(),
        icon: "https://example.test/icon.png".to_string(),
        des: "demo app for the contract test".to_string(),
        readme: Some(format!("# {app_id}")),
        category: Some(vec!["tools".to_string()]),
        extra: Some(extra),
    }
}

fn sample_app_named(app_id: &str, name: &str) -> AppSummary {
    let mut app = sample_app(app_id);
    app.name = name.to_string();
    app.des = format!("{name} description");
    app
}

fn keys(records: &[ChannelRecord]) -> Vec<String> {
    records
        .iter()
        .map(|record| record.key.as_str().to_string())
        .collect()
}

#[test]
fn channel_traits_contract_registry_register_list_priority_enabled() {
    let registry = ChannelRegistry::new(InMemoryChannelStore::new());
    let empty: InMemoryChannelRegistry = ChannelRegistry::new(InMemoryChannelStore::new());
    assert!(empty.list().expect("empty list").is_empty());

    let local = record("local_db", ChannelKind::LocalDb, true, 30);
    let github = record("github", ChannelKind::Github, false, 20);
    let vivo = record("vivo", ChannelKind::Vivo, true, 10);
    let js = record("js_alpha", ChannelKind::JsLocal, true, 10);
    for item in [local.clone(), github.clone(), vivo.clone(), js.clone()] {
        registry.register(item).expect("register channel");
    }

    // list() is deterministic (key order); priority_order() is enabled-only and
    // sorted by (priority, key), mirroring ChannelManager's compareTo ordering.
    assert_eq!(
        keys(&registry.list().expect("list")),
        vec!["github", "js_alpha", "local_db", "vivo"]
    );
    assert_eq!(
        keys(&registry.priority_order().expect("priority order")),
        vec!["js_alpha", "vivo", "local_db"]
    );
    assert_eq!(
        keys(&registry.enabled().expect("enabled")),
        vec!["js_alpha", "vivo", "local_db"]
    );

    let github_key = ChannelKey::new("github").expect("key");
    registry.enable(&github_key).expect("enable github");
    assert_eq!(
        keys(&registry.priority_order().expect("priority order")),
        vec!["js_alpha", "vivo", "github", "local_db"]
    );

    let js_key = ChannelKey::new("js_alpha").expect("key");
    registry.disable(&js_key).expect("disable js_alpha");
    assert_eq!(
        keys(&registry.priority_order().expect("priority order")),
        vec!["vivo", "github", "local_db"]
    );

    let local_key = ChannelKey::new("local_db").expect("key");
    registry
        .set_priority(&local_key, 5)
        .expect("set local_db priority");
    assert_eq!(
        keys(&registry.priority_order().expect("priority order")),
        vec!["local_db", "vivo", "github"]
    );

    // Re-registering the exact same record is idempotent; changing it is a
    // typed conflict instead of a silent overwrite.
    let current_local = registry
        .get(&local_key)
        .expect("get local_db")
        .expect("local_db registered");
    registry
        .register(current_local.clone())
        .expect("idempotent register");
    let mut changed = current_local;
    changed.meta.name = "Changed".to_string();
    let conflict = registry
        .register(changed)
        .expect_err("conflicting duplicate");
    assert_eq!(conflict.code(), "conflict");

    // Missing keys surface typed NotFound errors (never panic).
    let missing = ChannelKey::new("missing").expect("key");
    assert_eq!(registry.get(&missing).expect("get missing"), None);
    assert_eq!(registry.enable(&missing).unwrap_err().code(), "not_found");
    assert_eq!(registry.disable(&missing).unwrap_err().code(), "not_found");
    assert_eq!(
        registry.set_priority(&missing, 1).unwrap_err().code(),
        "not_found"
    );
    assert_eq!(
        registry.unregister(&missing).unwrap_err().code(),
        "not_found"
    );

    registry.unregister(&github_key).expect("unregister github");
    assert_eq!(registry.get(&github_key).expect("get removed"), None);
    assert_eq!(registry.list().expect("list").len(), 3);
    assert_eq!(registry.store().list().expect("store list").len(), 3);

    println!(
        "registry list={:?} priority_order={:?} enabled_after_mutations={:?}",
        keys(&registry.list().expect("list")),
        keys(&registry.priority_order().expect("priority order")),
        keys(&registry.enabled().expect("enabled"))
    );
}

#[test]
fn channel_traits_contract_pack_preserves_icons_and_required_env() {
    let key = ChannelKey::new("js_alpha").expect("valid key");
    let meta_json = r#"{"name":"Alpha","description":"alpha pack","icon":"icons/a.png","requiredEnvVars":["TOKEN","ENDPOINT"]}"#;
    let mut icons = BTreeMap::new();
    icons.insert(
        "icons/a.png".to_string(),
        PackIconSource::Bytes(vec![1, 2, 3]),
    );
    icons.insert(
        "icons/nested/b.png".to_string(),
        PackIconSource::Path(PathBuf::from("/packs/js_alpha/icons/nested/b.png")),
    );

    let pack = ChannelPack::new(
        key.clone(),
        "async function main() {}",
        Some("async function detail() {}".to_string()),
        Some(meta_json),
        icons,
    )
    .expect("build pack");

    assert_eq!(pack.key, key);
    assert_eq!(pack.entry_js, "async function main() {}");
    assert_eq!(
        pack.detail_js.as_deref(),
        Some("async function detail() {}")
    );
    assert_eq!(pack.icons.len(), 2);
    assert_eq!(
        pack.icon("icons/a.png"),
        Some(&PackIconSource::Bytes(vec![1, 2, 3]))
    );
    assert!(matches!(
        pack.icon("icons/nested/b.png"),
        Some(PackIconSource::Path(path))
            if path == &PathBuf::from("/packs/js_alpha/icons/nested/b.png")
    ));
    assert_eq!(
        pack.required_env_vars,
        vec!["TOKEN".to_string(), "ENDPOINT".to_string()]
    );
    assert_eq!(pack.meta_json.get("name"), Some(&json!("Alpha")));

    println!(
        "pack icons={:?} requiredEnvVars={:?}",
        pack.icons.keys().collect::<Vec<_>>(),
        pack.required_env_vars
    );
}

#[test]
fn channel_traits_contract_legacy_flat_pack_accepted() {
    let key = ChannelKey::new("js_legacy").expect("valid key");
    let pack = ChannelPack::from_legacy(
        key.clone(),
        "function main() { return null; }",
        None,
        None,
        BTreeMap::new(),
    )
    .expect("legacy flat pack");

    assert_eq!(pack.key, key);
    assert!(pack.detail_js.is_none());
    assert!(pack.meta_json.is_empty());
    assert!(pack.required_env_vars.is_empty());
    assert!(pack.icons.is_empty());

    let with_optional = ChannelPack::from_legacy(
        ChannelKey::new("js_legacy_optional").expect("valid key"),
        "entry",
        Some("detail".to_string()),
        Some(r#"{"name":"Legacy"}"#),
        BTreeMap::new(),
    )
    .expect("legacy pack with optional files");
    assert_eq!(with_optional.detail_js.as_deref(), Some("detail"));
    assert_eq!(with_optional.meta_json.get("name"), Some(&json!("Legacy")));

    println!(
        "legacy flat pack accepted: detail={:?} meta_keys={:?}",
        with_optional.detail_js,
        with_optional.meta_json.keys().collect::<Vec<_>>()
    );
}

#[test]
fn channel_traits_contract_v2_metadata_tolerated_without_signature() {
    let key = ChannelKey::new("js_v2").expect("valid key");
    let meta_json = r#"{"schemaVersion":2,"name":"V2 pack","description":"v2 metadata","requiredEnvVars":[],"vendor":{"id":"acme"},"extensionHints":{"k":1}}"#;

    let pack = ChannelPack::new(key.clone(), "entry", None, Some(meta_json), BTreeMap::new())
        .expect("v2 metadata is tolerated as plain JSON");
    assert_eq!(pack.meta_json.get("schemaVersion"), Some(&json!(2)));
    assert_eq!(pack.meta_json.get("name"), Some(&json!("V2 pack")));
    assert!(pack.required_env_vars.is_empty());

    // Pin the exact local-pack field set. A signature/trust/verification field
    // would make this struct literal fail to compile.
    let pinned = ChannelPack {
        key: pack.key.clone(),
        entry_js: pack.entry_js.clone(),
        detail_js: pack.detail_js.clone(),
        meta_json: pack.meta_json.clone(),
        icons: pack.icons.clone(),
        required_env_vars: pack.required_env_vars.clone(),
    };
    assert_eq!(pinned, pack);

    println!(
        "v2 metadata tolerated without a signature field: keys={:?}",
        pack.meta_json.keys().collect::<Vec<_>>()
    );
}

#[test]
fn channel_traits_contract_malformed_input_typed_errors() {
    assert!(matches!(
        ChannelKey::new(""),
        Err(Error::InvalidArgument(_))
    ));

    // ChannelKey only rejects the empty string; pack identity rules are stricter.
    let slash = ChannelKey::new("bad/key").expect("non-empty key");
    let err = ChannelPack::new(slash, "entry", None, None, BTreeMap::new())
        .expect_err("slash key must be rejected");
    assert_eq!(err.code(), "invalid_argument");

    // Transparent serde can construct an empty key without ChannelKey::new, so
    // the pack validator must reject it too.
    let empty: ChannelKey = serde_json::from_str("\"\"").expect("transparent key");
    let err = ChannelPack::new(empty, "entry", None, None, BTreeMap::new())
        .expect_err("empty key must be rejected by the pack");
    assert_eq!(err.code(), "invalid_argument");

    let key = ChannelKey::new("js_ok").expect("valid key");
    let err = ChannelPack::new(
        key.clone(),
        "entry",
        None,
        Some("{not-json"),
        BTreeMap::new(),
    )
    .expect_err("malformed meta.json");
    assert_eq!(err.code(), "serialization");

    let err = ChannelPack::new(key.clone(), "entry", None, Some("[]"), BTreeMap::new())
        .expect_err("non-object meta.json");
    assert_eq!(err.code(), "invalid_argument");

    let err = ChannelPack::new(
        key.clone(),
        "entry",
        None,
        Some(r#"{"requiredEnvVars":[1]}"#),
        BTreeMap::new(),
    )
    .expect_err("non-string requiredEnvVars entry");
    assert_eq!(err.code(), "invalid_argument");

    let err = ChannelPack::new(
        key,
        "entry",
        None,
        Some(r#"{"requiredEnvVars":"TOKEN"}"#),
        BTreeMap::new(),
    )
    .expect_err("non-array requiredEnvVars");
    assert_eq!(err.code(), "invalid_argument");

    println!("malformed inputs returned typed errors without panicking");
}

#[test]
fn channel_traits_contract_isolation_cross_key_rejected() {
    let key_a = ChannelKey::new("js_alpha").expect("valid key");
    let key_b = ChannelKey::new("js_beta").expect("valid key");

    // Both channels deliberately hold the SAME app id with different payloads.
    let driver_a =
        InMemoryChannelDriver::new(key_a.clone(), meta(ChannelKind::JsLocal, "Alpha", true, 10))
            .with_apps(vec![
                sample_app_named("shared-id", "Alpha payload"),
                sample_app_named("a-only", "Alpha only"),
            ]);
    let driver_b =
        InMemoryChannelDriver::new(key_b.clone(), meta(ChannelKind::JsLocal, "Beta", true, 20))
            .with_apps(vec![
                sample_app_named("shared-id", "Beta payload"),
                sample_app_named("b-only", "Beta only"),
            ]);

    let registry = ChannelRegistry::new(InMemoryChannelStore::new());
    registry
        .register_driver(Arc::new(driver_a))
        .expect("register alpha driver");
    registry
        .register_driver(Arc::new(driver_b))
        .expect("register beta driver");

    let handle_a = registry.driver(&key_a).expect("driver a by key");
    let handle_b = registry.driver(&key_b).expect("driver b by key");
    assert_eq!(handle_a.key(), &key_a);
    assert_eq!(handle_b.key(), &key_b);

    // (a) Same app id, no bleed: each handle returns its own payload.
    assert_eq!(
        handle_a
            .get_app_info("shared-id", false)
            .expect("alpha shared")
            .name,
        "Alpha payload"
    );
    assert_eq!(
        handle_b
            .get_app_info("shared-id", false)
            .expect("beta shared")
            .name,
        "Beta payload"
    );
    assert_eq!(handle_a.get_all_apps(false).unwrap().len(), 2);
    assert_eq!(handle_b.get_all_apps(false).unwrap().len(), 2);

    // (b) A cannot obtain B's unique app: typed NotFound, no key parameter.
    let foreign_read = handle_a
        .get_app_info("b-only", false)
        .expect_err("owner A must not see B's unique app");
    assert_eq!(foreign_read.code(), "not_found");
    let foreign_detail = handle_a
        .get_app_detail("b-only", false)
        .expect_err("owner A must not read B's detail");
    assert_eq!(foreign_detail.code(), "not_found");
    let foreign_remove = handle_a
        .remove_app("b-only")
        .expect_err("owner A must not remove B's app");
    assert_eq!(foreign_remove.code(), "not_found");

    // Writes on A land only in A; B's same-id payload is unchanged.
    handle_a
        .add_app(&sample_app_named("shared-id", "Alpha overwritten"))
        .expect("write alpha");
    assert_eq!(
        handle_a
            .get_app_info("shared-id", false)
            .expect("alpha after write")
            .name,
        "Alpha overwritten"
    );
    assert_eq!(
        handle_b
            .get_app_info("shared-id", false)
            .expect("beta untouched")
            .name,
        "Beta payload"
    );

    // (c) Routing an unregistered key fails with typed NotFound.
    let unregistered = ChannelKey::new("js_missing").expect("valid key");
    let route_err = registry
        .driver(&unregistered)
        .err()
        .expect("unregistered driver must be NotFound");
    assert_eq!(route_err.code(), "not_found");

    // Store-only registration exposes no driver handle.
    let record_only = ChannelKey::new("js_record_only").expect("valid key");
    registry
        .register(ChannelRecord::new(
            record_only.clone(),
            meta(ChannelKind::JsLocal, "Record only", true, 30),
        ))
        .expect("register record only");
    assert_eq!(
        registry
            .driver(&record_only)
            .err()
            .expect("record without driver")
            .code(),
        "not_found"
    );

    println!("a shared-id -> Alpha payload");
    println!("b shared-id -> Beta payload");
    println!("a cannot read b-only -> {foreign_read:?}");
    println!("a cannot read b-only detail -> {foreign_detail:?}");
    println!("a cannot remove b-only -> {foreign_remove:?}");
    println!("registry driver(unregistered) -> {route_err:?}");
    println!(
        "handle_a.key={} handle_b.key={}",
        handle_a.key(),
        handle_b.key()
    );
}

#[test]
fn channel_traits_contract_driver_surface_semantics() {
    let key = ChannelKey::new("js_alpha").expect("valid key");
    let category = ChannelCategory {
        id: "tools".to_string(),
        description: "Tools".to_string(),
        icon: "icons/tools.png".to_string(),
    };
    let config = ChannelConfig {
        version: "2026.10".to_string(),
        proxy: Some("http://127.0.0.1:7890".to_string()),
    };
    let driver =
        InMemoryChannelDriver::new(key.clone(), meta(ChannelKind::JsLocal, "Alpha", true, 10))
            .with_apps(vec![sample_app("app-1"), sample_app("app-2")])
            .with_categories(vec![category.clone()])
            .with_config(Some(config));

    driver.initialize().expect("initialize");
    assert!(driver.is_initialized().expect("initialized"));
    assert!(driver.check_available().expect("available"));
    assert_eq!(driver.key(), &key);
    assert_eq!(driver.kind(), ChannelKind::JsLocal);
    assert_eq!(driver.meta().name, "Alpha");

    assert_eq!(driver.get_all_apps(false).unwrap().len(), 2);
    let info = driver.get_app_info("app-1", false).expect("app info");
    assert_eq!(info.name, "Demo app-1");
    let detail = driver.get_app_detail("app-1", false).expect("detail");
    assert_eq!(detail.app_id, "app-1");
    assert_eq!(detail.channel, ChannelKind::JsLocal);

    assert!(driver.supports_progressive_loading().unwrap());
    assert!(driver.fetch_downloads("app-1").unwrap().is_empty());
    assert_eq!(
        driver.fetch_readme("app-1").unwrap().as_deref(),
        Some("# app-1")
    );
    let stats = driver.fetch_statistics("app-1").unwrap();
    assert_eq!(
        stats.as_ref().and_then(|map| map.get("stars")),
        Some(&json!(1))
    );

    assert_eq!(driver.search_apps("DEMO", false).unwrap().len(), 2);
    assert_eq!(driver.search_by_category("tools", false).unwrap().len(), 2);
    assert_eq!(driver.get_all_categories(false).unwrap(), vec![category]);

    assert!(!driver.check_update().unwrap());
    let mut progress = Vec::new();
    assert!(driver
        .do_update(Some(&mut |current, total| {
            progress.push((current, total));
        }))
        .unwrap());
    assert_eq!(progress, vec![(0, 2), (2, 2)]);

    assert_eq!(
        driver.get_config(false).unwrap().expect("config").version,
        "2026.10"
    );
    assert_eq!(driver.get_cache_size().unwrap(), 0);
    driver.clear_cache().expect("clear cache");
    assert_eq!(driver.canonical_app_id(&info).unwrap(), "app-1".to_string());

    driver.remove_app("app-1").expect("remove");
    assert_eq!(
        driver.get_app_info("app-1", false).unwrap_err().code(),
        "not_found"
    );
    assert_eq!(
        driver.get_app_info("missing", false).unwrap_err().code(),
        "not_found"
    );
    assert_eq!(
        driver.remove_app("missing").unwrap_err().code(),
        "not_found"
    );

    driver.dispose().expect("dispose");
    assert!(!driver.is_initialized().unwrap());

    println!(
        "driver surface ok: apps=2 categories=1 update_progress={:?}",
        progress
    );
}
