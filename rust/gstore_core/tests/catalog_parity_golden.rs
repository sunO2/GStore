//! Real cutover parity: the production Rust `added_apps` / `catalog` code reads
//! the SAME input databases the legacy Dart readers produced the golden from.
//!
//! Golden generation (legacy Dart readers over committed input DBs):
//!
//! ```text
//! GSTORE_WRITE_PARITY_GOLDEN=1 \
//!   flutter test test/catalog_parity_golden_generator_test.dart
//! ```
//!
//! This test:
//! 1. verifies the committed input DBs still hash to the values recorded in the
//!    golden (a stale-fixture guard);
//! 2. imports those DBs through the production migrations
//!    (`import_dart_added_db` / `import_catalog`);
//! 3. reads them back through the real `AddedAppsService` / `CatalogService`;
//! 4. compares every row against the golden. Any divergence fails.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::added::apps::AddedAppsService;
use gstore_core::added::migration::import_dart_added_db;
use gstore_core::catalog::import::{import_catalog, CatalogImportOptions};
use gstore_core::catalog::service::CatalogService;
use gstore_core::db::DbHandle;
use gstore_core::dto::AppSummary;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_catalog_parity_{tag}_{}_{}",
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

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn golden_path() -> PathBuf {
    // Test-only override so a scratch copy can be mutated in /tmp to prove the
    // comparison really goes red (the committed golden is never modified).
    std::env::var_os("GSTORE_PARITY_GOLDEN")
        .map(PathBuf::from)
        .unwrap_or_else(|| fixtures_dir().join("catalog_parity_golden.json"))
}

fn sha256_hex(path: &Path) -> String {
    let bytes = std::fs::read(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    Sha256::digest(&bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn app_row(app: &AppSummary) -> Value {
    json!({
        "appId": app.app_id,
        "packageName": app.package_name,
        "name": app.name,
        "user": app.user,
        "repositories": app.repositories,
        "icon": app.icon,
        "des": app.des,
        "category": app.category,
    })
}

#[test]
fn rust_cutover_matches_legacy_golden_row_for_row() {
    let golden: Value = serde_json::from_str(
        &std::fs::read_to_string(golden_path()).expect("read golden"),
    )
    .expect("parse golden");

    let fixtures = fixtures_dir();
    let catalog_db = fixtures.join("catalog_parity_catalog.db");
    let added_db = fixtures.join("catalog_parity_added.db");

    // ---- 1. Same input bytes the legacy readers consumed ------------------
    assert_eq!(
        sha256_hex(&catalog_db),
        golden["input"]["catalog_db"]["sha256"]
            .as_str()
            .expect("catalog input sha256"),
        "stale-state: committed catalog fixture changed without regenerating the golden"
    );
    assert_eq!(
        sha256_hex(&added_db),
        golden["input"]["added_db"]["sha256"]
            .as_str()
            .expect("added input sha256"),
        "stale-state: committed added-apps fixture changed without regenerating the golden"
    );

    // Work on copies so the committed fixtures stay byte-identical.
    let dir = TempDir::new("run");
    let catalog_copy = dir.join("catalog.db");
    let added_copy = dir.join("added.db");
    std::fs::copy(&catalog_db, &catalog_copy).unwrap();
    std::fs::copy(&added_db, &added_copy).unwrap();

    // ---- 2. Real production imports --------------------------------------
    let db = DbHandle::open(dir.path()).unwrap();
    import_dart_added_db(&db, &added_copy).expect("import Dart added_apps.db");
    import_catalog(
        &db,
        Some(&catalog_copy),
        &catalog_copy,
        &CatalogImportOptions { dry_run: false },
    )
    .expect("import Dart apps.db");

    // ---- 3. Real production read services --------------------------------
    let added_service = AddedAppsService::new(db.clone());
    let added_apps = added_service.list().unwrap();
    let tags = added_service.tags_index().unwrap();

    let catalog = CatalogService::new(db).unwrap();
    let list = catalog.list().unwrap();
    let categories = catalog.categories().unwrap();
    let by_category = catalog.by_category("Tools").unwrap();
    let one = catalog.get_app("com.example.alpha").unwrap();

    let tag_map: Map<String, Value> = tags
        .iter()
        .map(|(key, values)| (key.clone(), json!(values)))
        .collect();

    let actual = json!({
        "added": {
            "apps": added_apps
                .iter()
                .map(|app| json!({
                    "channel": app.channel_id,
                    "appId": app.app_id,
                    "addTime": app.add_time,
                    "sortOrder": app.sort_order,
                    "isEnabled": app.is_enabled,
                }))
                .collect::<Vec<_>>(),
            "tags": tag_map,
        },
        "catalog": {
            "list": list.iter().map(app_row).collect::<Vec<_>>(),
            "categories": categories
                .iter()
                .map(|category| json!([category.id, category.description, category.icon]))
                .collect::<Vec<_>>(),
            "byCategory": by_category.iter().map(app_row).collect::<Vec<_>>(),
            "one": one.as_ref().map(app_row),
        },
    });

    // Non-empty guards: an empty-vs-empty comparison must not pass.
    assert_eq!(added_apps.len(), 4);
    assert_eq!(tags.len(), 4);
    assert_eq!(list.len(), 5);
    assert_eq!(categories.len(), 3);
    assert_eq!(by_category.len(), 3);
    assert!(one.is_some());

    // ---- 4. Row-for-row comparison ---------------------------------------
    assert_eq!(
        actual["added"], golden["added"],
        "added-apps rows diverged from the legacy golden"
    );
    assert_eq!(
        actual["catalog"], golden["catalog"],
        "catalog rows diverged from the legacy golden"
    );
}
