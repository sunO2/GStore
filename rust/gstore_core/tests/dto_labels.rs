//! Todo 13 contract: the typed `Label` DTO and per-driver label derivation.

mod support;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::channel::{ChannelDriver, LocalDbDriver, ScriptChannel};
use gstore_core::db::{DbError, DbHandle};
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta, Label};
use gstore_core::ScriptChannelConfig;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_dto_labels_{tag}_{}_{}",
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

fn meta() -> ChannelMeta {
    ChannelMeta {
        kind: ChannelKind::LocalDb,
        name: "LocalDB".to_string(),
        description: "LocalDB channel".to_string(),
        enabled: true,
        priority: 10,
        support_offline: true,
        last_update_time: None,
        version: Some("1".to_string()),
    }
}

fn key() -> ChannelKey {
    ChannelKey::new("local_db").unwrap()
}

fn insert_app(db: &DbHandle, app_id: &str, name: &str, user: &str, repositories: &str, extra: Option<&str>) {
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO apps(appId,name,user,repositories,icon,des,readme,category,extra) \
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            rusqlite::params![app_id, name, user, repositories, "", "", None::<&str>, None::<&str>, extra],
        )
        .map_err(|e| DbError(e.to_string()))?;
        Ok(())
    })
    .unwrap();
}

fn labels_of(labels: &[Label]) -> Vec<(String, String)> {
    labels
        .iter()
        .map(|label| (label.key.clone(), label.value.clone()))
        .collect()
}

#[test]
fn dto_label_roundtrip() {
    let label = Label {
        key: "version".to_string(),
        label: "版本".to_string(),
        value: "1.2.3".to_string(),
        icon: Some("label".to_string()),
    };
    let encoded = serde_json::to_string(&label).expect("serialize label");
    assert_eq!(
        encoded,
        r#"{"key":"version","label":"版本","value":"1.2.3","icon":"label"}"#,
        "serde field names are key/label/value/icon"
    );
    let decoded: Label = serde_json::from_str(&encoded).expect("deserialize label");
    assert_eq!(decoded, label, "Label must round-trip");

    let no_icon = Label {
        key: "package".to_string(),
        label: "包名".to_string(),
        value: "com.example.app".to_string(),
        icon: None,
    };
    let decoded: Label =
        serde_json::from_str(&serde_json::to_string(&no_icon).unwrap()).expect("round-trip");
    assert_eq!(decoded, no_icon, "optional icon round-trips");

    let omitted: Label =
        serde_json::from_str(r#"{"key":"k","label":"l","value":"v"}"#).expect("omitted icon");
    assert_eq!(omitted.icon, None, "an omitted icon deserializes to None");
}

#[test]
fn driver_labels_populated() {
    let dir = TempDir::new("populated");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    insert_app(
        &db,
        "com.example.labels",
        "Labels App",
        "Acme Studio",
        "labels-app",
        Some(r#"{"packageName":"com.example.labels"}"#),
    );
    let driver = LocalDbDriver::new(key(), meta(), db);

    let summary = driver.get_app_info("com.example.labels", false).unwrap();
    assert_eq!(
        labels_of(&summary.labels),
        vec![
            ("developer".to_string(), "Acme Studio".to_string()),
            ("package".to_string(), "com.example.labels".to_string()),
            ("channel".to_string(), "labels-app".to_string()),
        ],
        "summary labels derive developer/package/channel from the row"
    );

    let detail = driver
        .get_app_detail("com.example.labels", false)
        .unwrap();
    assert_eq!(
        labels_of(&detail.labels),
        vec![
            ("developer".to_string(), "Acme Studio".to_string()),
            ("package".to_string(), "com.example.labels".to_string()),
        ],
        "detail labels derive developer/package from the row"
    );

    let script = r#"
        async function main(method, params) {
          if (method === 'getAppDetail') {
            return { ok: true, data: {
              appId: 'com.example.js', name: 'JS App', version: '2.0.0',
              developer: 'JS Dev', packageName: 'com.example.js',
              downloadCount: 123, downloads: []
            } };
          }
          return null;
        }
    "#;
    let config = ScriptChannelConfig::new(
        ChannelKey::new("js.labels").unwrap(),
        script.to_string(),
        support::fake_host(),
    )
    .with_store(support::memory_store());
    let channel = ScriptChannel::new(config).unwrap();
    let js_detail = channel.get_app_detail("com.example.js", true).unwrap();
    assert_eq!(
        labels_of(&js_detail.labels),
        vec![
            ("version".to_string(), "2.0.0".to_string()),
            ("developer".to_string(), "JS Dev".to_string()),
            ("package".to_string(), "com.example.js".to_string()),
            ("downloads".to_string(), "123".to_string()),
        ],
        "js detail labels derive from the pack JSON"
    );
    channel.dispose().unwrap();
}

#[test]
fn labels_default_empty_and_never_invented() {
    let dir = TempDir::new("empty");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    insert_app(&db, "com.example.blank", "Blank", "", "", None);
    let driver = LocalDbDriver::new(key(), meta(), db);

    let summary = driver.get_app_info("com.example.blank", false).unwrap();
    assert!(
        summary.labels.is_empty(),
        "absent data must yield no labels, got {:?}",
        summary.labels
    );

    let detail = driver.get_app_detail("com.example.blank", false).unwrap();
    assert!(
        detail.labels.is_empty(),
        "absent data must yield no labels, got {:?}",
        detail.labels
    );

    let legacy = r#"{"app_id":"a","package_name":null,"name":"n","user":"","repositories":"","icon":"","des":"","readme":null,"category":null,"extra":null}"#;
    let decoded: AppSummary =
        serde_json::from_str(legacy).expect("legacy summary without labels still deserializes");
    assert!(
        decoded.labels.is_empty(),
        "serde default keeps old data valid"
    );
}
