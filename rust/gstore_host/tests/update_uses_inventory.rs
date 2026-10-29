//! Wave 4 Todo 3 contract: update judgement reads the core-maintained
//! inventory and platform facts (no platform host), plus the catalog/added-apps
//! facades over a real core database and the `catalog.changed` forwarding point.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

use gstore_core::added::apps::AddedAppsService;
use gstore_core::catalog::import::{import_catalog, CatalogImportOptions};
use gstore_core::channel::{ChannelDriver, InMemoryChannelDriver};
use gstore_core::db::DbHandle;
use gstore_core::dto::{
    AppDetail, AppDownload, AppUpdate, ChannelKey, ChannelKind, ChannelMeta, DetailSection,
};
use gstore_core::update::service::{ChannelResolver, UpdateService};
use gstore_host::bridge::{AddedAppsApi, CatalogApi, UpdateApi};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_host_catalog_update_{tag}_{}_{}",
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

    fn data(&self) -> String {
        self.0.join("data").to_string_lossy().into_owned()
    }

    fn files(&self) -> String {
        self.0.join("files").to_string_lossy().into_owned()
    }

    fn cache(&self) -> String {
        self.0.join("cache").to_string_lossy().into_owned()
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn create_source(path: &Path, sql: &str) {
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.execute_batch(sql).unwrap();
}

fn import_source(root: &TempDir, source: &Path) {
    let db = DbHandle::open(Path::new(&root.data())).expect("open core db");
    let report = import_catalog(
        &db,
        Some(source),
        &root.path().join("missing_seed.db"),
        &CatalogImportOptions::default(),
    )
    .expect("import catalog");
    assert_eq!(report.apps, 2);
    drop(db);
}

fn serve_once(body: Vec<u8>) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind test server");
    let addr = listener.local_addr().expect("local addr");
    let handle = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let mut buf = [0_u8; 4096];
        let _ = stream.read(&mut buf);
        let header = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\
             Content-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        stream.write_all(header.as_bytes()).expect("write header");
        stream.write_all(&body).expect("write body");
        stream.flush().expect("flush");
    });
    (format!("http://{addr}/catalog.db"), handle)
}

#[test]
fn catalog_and_added_apps_contract() {
    catalog_contract();
    added_apps_contract();
    println!("catalog_and_added_apps_contract: PASS");
}

#[test]
fn update_uses_inventory() {
    update_contract();
    println!("update_uses_inventory: PASS");
}

fn catalog_contract() {
    let root = TempDir::new("catalog");
    let source_a = root.path().join("source_a.db");
    create_source(
        &source_a,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY); \
         INSERT INTO apps VALUES ('com.example.alpha', 'Alpha', 'example', 'alpha', 'a.png', 'fast alpha', 'Tools'); \
         INSERT INTO apps VALUES ('com.example.beta', 'Beta', 'example', 'beta', 'b.png', 'beta app', 'Tools'); \
         INSERT INTO category VALUES ('Tools', '工具', 'tool.png'); \
         INSERT INTO config VALUES ('1.0.0');",
    );
    import_source(&root, &source_a);

    let api = CatalogApi::init(root.data(), root.files(), root.cache()).expect("catalog init");
    let apps = api.list().expect("list");
    println!("catalog list len={}", apps.len());
    assert_eq!(apps.len(), 2);
    assert_eq!(apps[0].app_id, "com.example.alpha");

    let page = api.list_page(0, 1).expect("page 0");
    assert_eq!(page.apps.len(), 1);
    assert_eq!(page.total, 2);
    let page = api.list_page(1, 5).expect("page 1");
    assert_eq!(page.apps.len(), 1);
    assert_eq!(page.apps[0].app_id, "com.example.beta");
    let empty = api.list_page(9, 5).expect("page past end");
    assert!(empty.apps.is_empty());
    assert_eq!(empty.total, 2);

    assert_eq!(api.search("alpha".to_string()).expect("search").len(), 1);
    assert!(api.search(String::new()).expect("empty search").is_empty());
    assert!(api.search("\"".to_string()).expect("malformed search").is_empty());

    let categories = api.categories().expect("categories");
    assert_eq!(categories.len(), 1);
    assert_eq!(categories[0].id, "Tools");
    assert_eq!(api.by_category("Tools".to_string()).expect("by category").len(), 2);

    assert_eq!(
        api.get_app("com.example.alpha".to_string())
            .expect("get app")
            .expect("present")
            .name,
        "Alpha"
    );
    assert!(api
        .get_app("missing.app".to_string())
        .expect("missing app")
        .is_none());
    let detail = api
        .get_app_detail("com.example.alpha".to_string())
        .expect("detail")
        .expect("present detail");
    assert_eq!(detail.name, "Alpha");
    assert_eq!(detail.channel, "local_db");

    // First refresh installs a different catalog -> changed + event.
    let source_b = root.path().join("source_b.db");
    create_source(
        &source_b,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY); \
         INSERT INTO apps VALUES ('com.example.alpha', 'Alpha', 'example', 'alpha', 'a.png', 'fast alpha', 'Tools'); \
         INSERT INTO apps VALUES ('com.example.gamma', 'Gamma', 'example', 'gamma', 'g.png', 'gamma app', 'Tools'); \
         INSERT INTO category VALUES ('Tools', '工具', 'tool.png'); \
         INSERT INTO config VALUES ('2.0.0');",
    );
    let bytes = std::fs::read(&source_b).unwrap();
    let (url, server) = serve_once(bytes.clone());
    let report = api.refresh(url).expect("refresh changed");
    server.join().expect("server");
    println!("catalog refresh changed={report:?}");
    assert!(report.changed);
    assert_eq!(report.apps, 2);
    let event: serde_json::Value = serde_json::from_str(&report.events_json).expect("event json");
    assert_eq!(event["event"], "catalog.changed");
    assert_eq!(event["payload"]["key"], "local_db");

    // Second identical refresh -> unchanged and the JSON literal null.
    let (url, server) = serve_once(bytes);
    let report = api.refresh(url).expect("refresh unchanged");
    server.join().expect("server");
    assert!(!report.changed);
    assert_eq!(report.events_json, "null");

    // Repeated init against the same directories is safe.
    let again = CatalogApi::init(root.data(), root.files(), root.cache()).expect("re-init");
    assert_eq!(again.list().expect("re-init list").len(), 2);
}

fn added_apps_contract() {
    let root = TempDir::new("added");
    let api = AddedAppsApi::init(root.data(), root.files(), root.cache()).expect("added init");

    let entry = api
        .add("github".to_string(), "owner/one".to_string(), Some(5))
        .expect("add");
    assert_eq!(entry.channel_id, "github");
    assert_eq!(entry.app_id, "owner/one");
    assert_eq!(entry.sort_order, 5);
    assert!(entry.is_enabled);

    api.add("github".to_string(), "owner/two".to_string(), None)
        .expect("add second");
    assert_eq!(api.list().expect("list").len(), 2);
    assert_eq!(
        api.list_channel("github".to_string())
            .expect("list channel")
            .len(),
        2
    );
    assert_eq!(api.total_count().expect("total"), 2);
    assert_eq!(api.count_channel("github".to_string()).expect("count"), 2);
    assert!(api
        .is_added("github".to_string(), "owner/one".to_string())
        .expect("is added"));

    api.set_tags(
        "github".to_string(),
        "owner/one".to_string(),
        vec![
            "favorite".to_string(),
            " favorite ".to_string(),
            String::new(),
            "tools".to_string(),
        ],
    )
    .expect("set tags");
    assert_eq!(
        api.tags("github".to_string(), "owner/one".to_string())
            .expect("tags"),
        vec!["favorite".to_string(), "tools".to_string()]
    );
    api.add_tag(
        "github".to_string(),
        "owner/one".to_string(),
        "later".to_string(),
    )
    .expect("add tag");
    let index = api.tags_index().expect("tags index");
    assert_eq!(index.len(), 1);
    assert_eq!(index[0].key, "github:owner/one");
    assert_eq!(index[0].tags, vec!["favorite", "tools", "later"]);
    api.remove_tag(
        "github".to_string(),
        "owner/one".to_string(),
        "later".to_string(),
    )
    .expect("remove tag");
    assert_eq!(
        api.tags("github".to_string(), "owner/one".to_string())
            .expect("tags after remove"),
        vec!["favorite".to_string(), "tools".to_string()]
    );

    assert!(api
        .rename(
            "github".to_string(),
            "owner/one".to_string(),
            "owner/renamed".to_string(),
        )
        .expect("rename"));
    assert!(api
        .is_added("github".to_string(), "owner/renamed".to_string())
        .expect("is renamed"));
    assert!(!api
        .is_added("github".to_string(), "owner/one".to_string())
        .expect("old gone"));
    assert_eq!(
        api.get("github".to_string(), "owner/renamed".to_string())
            .expect("get renamed")
            .expect("present")
            .sort_order,
        5
    );

    assert!(!api
        .toggle("github".to_string(), "owner/renamed".to_string())
        .expect("toggle off"));
    assert!(api
        .toggle("github".to_string(), "owner/renamed".to_string())
        .expect("toggle on"));

    assert_eq!(
        api.clear_channel("github".to_string()).expect("clear channel"),
        2
    );
    assert_eq!(api.total_count().expect("total after clear"), 0);
    api.add("github".to_string(), "owner/three".to_string(), None)
        .expect("add after clear");
    assert!(api.remove("github".to_string(), "owner/three".to_string()).expect("remove"));
    assert_eq!(api.clear_all().expect("clear all"), 0);

    let missing = api
        .set_order("github".to_string(), "no/such".to_string(), 1)
        .unwrap_err();
    println!("added missing set_order error = {missing}");
    assert!(missing.starts_with("not_found:"), "{missing}");
}

fn channel_meta(code: &str) -> ChannelMeta {
    ChannelMeta {
        kind: ChannelKind::Custom,
        name: code.to_string(),
        description: format!("{code} channel"),
        enabled: true,
        priority: 0,
        support_offline: true,
        last_update_time: None,
        version: Some("1".to_string()),
    }
}

fn download(name: &str) -> AppDownload {
    AppDownload {
        url: format!("https://example.test/{name}"),
        name: name.to_string(),
        size: Some(100),
        download_count: Some(1),
        version: Some("2.0.0".to_string()),
        version_code: Some(2),
        published_at: Some(1_600_000_000_000),
        platform: Some("arm64-v8a".to_string()),
        hash: Some("abc".to_string()),
        hash_type: Some("sha256".to_string()),
        downloadable: true,
        note: None,
        extra: None,
    }
}

fn app_update(app_id: &str, package: &str) -> AppUpdate {
    let download = download("app.apk");
    AppUpdate {
        app_id: app_id.to_string(),
        package_name: package.to_string(),
        name: "Example".to_string(),
        icon: None,
        latest_version: Some("2.0.0".to_string()),
        latest_download: Some(download.clone()),
        detail: AppDetail {
            app_id: app_id.to_string(),
            name: "Example".to_string(),
            icon: String::new(),
            description: String::new(),
            version: Some("2.0.0".to_string()),
            developer: None,
            package_name: Some(package.to_string()),
            project_url: None,
            channel: ChannelKind::Custom,
            sections: vec![DetailSection::Version, DetailSection::Downloads],
            downloads: vec![download],
            extra: serde_json::Map::new(),
            labels: Vec::new(),
        },
    }
}

fn resolver(drivers: Vec<Arc<dyn ChannelDriver>>) -> ChannelResolver {
    let map: std::collections::BTreeMap<String, Arc<dyn ChannelDriver>> = drivers
        .into_iter()
        .map(|driver| (driver.key().as_str().to_string(), driver))
        .collect();
    Arc::new(move |code: &str| map.get(code).cloned())
}

/// Seeds the core-maintained facts + inventory rows the update service reads.
///
/// This is the parity fixture that replaces the deleted `FakePlatformHost`:
/// the frontend would push exactly these rows through `pushPlatformFacts` /
/// `pushInventory`; the update judgement must not care who wrote them.
fn seed_facts_and_inventory(db: &DbHandle, one_version: &str) {
    let facts = serde_json::json!({
        "source_id": "android",
        "os": "android",
        "arch": "aarch64",
        "abis": ["arm64-v8a"],
        "sdk": 35,
        "device": { "model": "Fake Phone", "manufacturer": "Example" },
        "paths": { "data": "/data", "files": "/files", "cache": "/cache" },
        "crypto_key": null,
        "captured_at": 10_000,
    });
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO platform_facts(id, json, source_id, captured_at) \
             VALUES (1, ?1, 'android', 10000)",
            [facts.to_string()],
        )
        .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
        conn.execute(
            "INSERT INTO inventory_source(source_id, seq, captured_at) \
             VALUES ('android', 1, 10000)",
            [],
        )
        .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
        for (package, version) in [
            ("com.example.one", one_version),
            ("com.example.two", "1.0.0"),
        ] {
            conn.execute(
                "INSERT INTO installed_app(\
                     source_id, package_name, app_name, version_name, version_code, \
                     is_system, target_sdk, min_sdk, abis_json, captured_at\
                 ) VALUES ('android', ?1, ?1, ?2, 1, 0, 35, 24, '[\"arm64-v8a\"]', 10000)",
                rusqlite::params![package, version],
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
        }
        Ok(())
    })
    .expect("seed facts and inventory");
}

fn update_contract() {
    let root = TempDir::new("update");
    let db = DbHandle::open(Path::new(&root.data())).expect("open core db");
    let added = AddedAppsService::new(db.clone());
    added.add("gh", "app.one", None).expect("add app.one");
    added.add("gh", "app.two", None).expect("add app.two");
    seed_facts_and_inventory(&db, "1.0.0");

    let key = ChannelKey::new("gh").unwrap();
    let driver: Arc<dyn ChannelDriver> = Arc::new(
        InMemoryChannelDriver::new(key, channel_meta("gh"))
            .with_updates(vec![app_update("app.one", "com.example.one")]),
    );
    let resolver = resolver(vec![driver]);
    let service = UpdateService::with_clock(db.clone(), resolver.clone(), Arc::new(|| 10_000_i64));
    let api = UpdateApi::from_service_for_test(service);

    let report = api.check(true).expect("check");
    println!("update report checked_at={} total={}", report.checked_at, report.total);
    assert_eq!(report.checked_at, 10_000);
    assert_eq!(report.total, 2);
    assert!(!report.used_cache);
    let updates: serde_json::Value =
        serde_json::from_str(&report.updates_json).expect("updates json");
    let updates = updates.as_array().expect("updates array");
    assert_eq!(updates.len(), 1);
    assert_eq!(updates[0]["appId"], "app.one");
    assert_eq!(updates[0]["latestVersion"], "2.0.0");
    let skipped: serde_json::Value =
        serde_json::from_str(&report.skipped_json).expect("skipped json");
    assert!(skipped.is_array());
    let events: serde_json::Value =
        serde_json::from_str(&report.events_json).expect("events json");
    let events = events.as_array().expect("events array");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["event"], "update.found");

    let cached: serde_json::Value = serde_json::from_str(&api.list().expect("list")).unwrap();
    assert_eq!(cached.as_array().unwrap().len(), 1);
    assert!(api.has_update("app.one".to_string()).expect("has update"));
    assert_eq!(api.count().expect("count"), 1);
    assert!(api.cache_valid().expect("cache valid"));

    let cached_report = api.check(false).expect("cached check");
    assert!(cached_report.used_cache);

    let one = api
        .check_app("app.one".to_string(), Some("gh".to_string()))
        .expect("check app")
        .expect("cached app");
    let one: serde_json::Value = serde_json::from_str(&one).unwrap();
    assert_eq!(one["appId"], "app.one");
    assert!(api
        .check_app("missing.app".to_string(), Some("gh".to_string()))
        .expect("missing app")
        .is_none());

    // Original installed version is older -> mark_updated keeps the entry.
    assert!(!api.mark_updated("app.one".to_string()).expect("mark keeps"));

    // Now the device pushes the new version into the inventory -> the cache
    // entry is dropped.
    db.with_writer(|conn| {
        conn.execute(
            "UPDATE installed_app SET version_name = '2.0.0' \
             WHERE source_id = 'android' AND package_name = 'com.example.one'",
            [],
        )
        .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
        Ok(())
    })
    .expect("upgrade inventory");
    let upgraded = UpdateService::with_clock(db.clone(), resolver, Arc::new(|| 20_000_i64));
    let api = UpdateApi::from_service_for_test(upgraded);
    // The cache survives across services; the upgraded inventory lets mark drop it.
    assert!(api.has_update("app.one".to_string()).unwrap());
    assert!(api.mark_updated("app.one".to_string()).expect("mark drops"));
    assert_eq!(api.count().expect("count after mark"), 0);
    assert!(!api.cache_valid().expect("cache invalid after mark"));
}
