//! [`ChannelAppFallback`] backed by the core `channel_apps` projection.
//!
//! This is the second step of the unified read order (driver → `channel_apps`
//! → placeholder). It covers every lane whose metadata is already projected
//! into `channel_apps`, most importantly the `js_*` script lanes (whose driver
//! is hosted outside core) and historical membership rows whose channel driver
//! is gone.
//!
//! The row → [`AppSummary`] mapping mirrors the channel drivers' own
//! `StoredApp::to_summary`: `description` becomes `des`, `category` is split on
//! `,`, and `extra` is parsed as a JSON object; a malformed `extra` column is
//! ignored rather than failing the whole read.

use rusqlite::{params, OptionalExtension, Row};

use crate::channel::{join_repo_url, normalize_repo_asset_path};
use crate::db::DbHandle;
use crate::dto::AppSummary;
use crate::error::Error;

use super::service::ChannelAppFallback;

/// Reads resolved summaries from `channel_apps` keyed by
/// `(channel_key, app_id)`.
pub struct SqliteChannelAppFallback {
    db: DbHandle,
}

impl SqliteChannelAppFallback {
    /// Creates the fallback over the core database.
    pub fn new(db: DbHandle) -> Self {
        Self { db }
    }
}

impl ChannelAppFallback for SqliteChannelAppFallback {
    fn get(&self, channel_key: &str, app_id: &str) -> Result<Option<AppSummary>, Error> {
        let conn = self
            .db
            .reader()
            .map_err(|error| Error::Io(format!("channel_apps open reader: {error}")))?;
        conn.query_row(
            "SELECT app_id,name,user,repositories,icon,description,category,extra,source_id \
             FROM channel_apps WHERE channel_key=?1 AND app_id=?2 LIMIT 1",
            params![channel_key, app_id],
            summary_from_row,
        )
        .optional()
        .map_err(|error| Error::Io(format!("channel_apps lookup: {error}")))
    }
}

fn summary_from_row(row: &Row<'_>) -> rusqlite::Result<AppSummary> {
    let app_id: String = row.get(0)?;
    let name: String = row.get(1)?;
    let user: String = row.get(2)?;
    let repositories: String = row.get(3)?;
    let stored_icon: String = row.get(4)?;
    let description: String = row.get(5)?;
    let category: Option<String> = row.get(6)?;
    let extra_raw: Option<String> = row.get(7)?;
    let source_id: Option<String> = row.get(8)?;
    let extra = parse_extra(extra_raw.as_deref());
    let package_name = extra
        .as_ref()
        .and_then(|map| map.get("packageName"))
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    let icon = resolve_icon(&stored_icon, source_id.as_deref(), extra.as_ref());

    Ok(AppSummary {
        app_id,
        package_name,
        name,
        user,
        repositories,
        icon,
        des: description,
        readme: None,
        // Dart `ChannelAddedApp.category?.split(',')`, same as the drivers.
        category: category.map(|value| value.split(',').map(ToString::to_string).collect()),
        extra,
        labels: Vec::new(),
    })
}

/// Parses the `extra` column, ignoring a malformed or non-object value.
fn parse_extra(raw: Option<&str>) -> Option<serde_json::Map<String, serde_json::Value>> {
    let raw = raw?;
    serde_json::from_str::<serde_json::Value>(raw)
        .ok()
        .and_then(|value| value.as_object().cloned())
}

/// Rebuilds a stored icon key against the row's own source.
///
/// Drivers such as F-Droid persist repo-relative keys (`icons/<pkg>.png`),
/// while the Dart icon loader only renders absolute `http(s)` URLs. Absolute
/// icons pass through; a relative key is joined to `source_id` (or the
/// `extra.sourceId` fallback). Without a usable source the icon is left as-is
/// so a row is never dropped over metadata.
fn resolve_icon(
    icon: &str,
    source_id: Option<&str>,
    extra: Option<&serde_json::Map<String, serde_json::Value>>,
) -> String {
    if icon.is_empty() || is_http_url(icon) {
        return icon.to_string();
    }
    let source = source_id
        .filter(|value| is_http_url(value))
        .or_else(|| {
            extra
                .and_then(|map| map.get("sourceId"))
                .and_then(serde_json::Value::as_str)
                .filter(|value| is_http_url(value))
        });
    match source {
        Some(source) => join_repo_url(source, &normalize_repo_asset_path(icon)),
        None => icon.to_string(),
    }
}

fn is_http_url(value: &str) -> bool {
    value.starts_with("http://") || value.starts_with("https://")
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    use rusqlite::params;

    use super::*;

    static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "gstore_core_app_fallback_{tag}_{}_{}",
                std::process::id(),
                n
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn insert_row(db: &DbHandle, channel_key: &str, app_id: &str, extra: Option<&str>) {
        db.with_writer(|conn| {
            conn.execute(
                "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,icon,\
                 description,category,add_time,extra) \
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
                params![
                    channel_key,
                    app_id,
                    "Example App",
                    "owner",
                    "repo",
                    "https://example.test/icon.png",
                    "short description",
                    "TOOLS,GAMES",
                    1234_i64,
                    extra
                ],
            )
            .map_err(|error| crate::db::DbError(error.to_string()))?;
            Ok(())
        })
        .unwrap();
    }

    #[test]
    fn get_returns_summary_for_existing_row() {
        let dir = TempDir::new("hit");
        let db = DbHandle::open(&dir.0).unwrap();
        insert_row(
            &db,
            "js_lane",
            "app-1",
            Some(r#"{"packageName":"com.example.app"}"#),
        );
        let fallback = SqliteChannelAppFallback::new(db);

        let summary = fallback.get("js_lane", "app-1").unwrap().unwrap();

        assert_eq!(summary.app_id, "app-1");
        assert_eq!(summary.name, "Example App");
        assert_eq!(summary.user, "owner");
        assert_eq!(summary.repositories, "repo");
        assert_eq!(summary.icon, "https://example.test/icon.png");
        assert_eq!(summary.des, "short description");
        assert_eq!(
            summary.category,
            Some(vec!["TOOLS".to_string(), "GAMES".to_string()])
        );
        assert_eq!(summary.package_name.as_deref(), Some("com.example.app"));
        assert!(summary.extra.is_some());
    }

    #[test]
    fn get_returns_none_for_missing_row() {
        let dir = TempDir::new("miss");
        let db = DbHandle::open(&dir.0).unwrap();
        let fallback = SqliteChannelAppFallback::new(db);

        assert!(fallback.get("js_lane", "ghost").unwrap().is_none());
    }

    #[test]
    fn malformed_extra_is_ignored() {
        let dir = TempDir::new("bad_extra");
        let db = DbHandle::open(&dir.0).unwrap();
        insert_row(&db, "js_lane", "app-2", Some("{not json"));
        let fallback = SqliteChannelAppFallback::new(db);

        let summary = fallback.get("js_lane", "app-2").unwrap().unwrap();

        assert!(summary.extra.is_none());
        assert!(summary.package_name.is_none());
        assert_eq!(summary.name, "Example App");
    }
}
