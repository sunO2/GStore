//! `host.database.*` for the production script host.
//!
//! Reads/writes the core `channel_apps` table, always pinned to the runtime
//! channel. Script-supplied `channelCode` is ignored: the channel passed by the
//! engine is the only write authority. Row JSON mirrors Dart
//! `_channelAppToJson` / `_toChannelAddedApp`. Every successful write also
//! records the `js_channel` core-write marker in the same transaction **when
//! the `js_channel` flag is on** (`mark_core_write_if_flipped`), so this lane's
//! provenance is visible without inventing a new domain.
//!
//! The marker's only effect is the `core_writes` projection that
//! [`gstore_core::migration`] arms; no Dart writer consumes `js_channel`
//! before the flip (pre-flip Dart writes stay on the `channel` domain and the
//! two lanes ship together), and the unconditional `mark_core_write` path is
//! deliberately not used here.

use gstore_core::channel::ScriptChannelStore;
use gstore_core::db::DbHandle;
use gstore_core::dto::{AppSummary, ChannelKey};
use gstore_core::error::Error as CoreError;
use gstore_script::{
    ChannelApp, DatabaseAppRequest, DatabaseInsertRequest, ScriptChannel, ScriptError,
};
use rusqlite::OptionalExtension;
use serde_json::{json, Value as JsonValue};

const SELECT: &str = "SELECT app_id, name, user, repositories, apprepo, icon, description, \
                      category, add_time, extra FROM channel_apps";

pub(crate) fn get_apps(
    db: &DbHandle,
    channel: &ScriptChannel,
) -> Result<Vec<ChannelApp>, ScriptError> {
    let conn = db
        .reader()
        .map_err(|error| host("read channel apps", error.0))?;
    let mut statement = conn
        .prepare(&format!(
            "{SELECT} WHERE channel_key=?1 ORDER BY add_time DESC, app_id"
        ))
        .map_err(|error| host("prepare channel apps", error))?;
    let rows = statement
        .query_map([channel.as_str()], raw_app)
        .map_err(|error| host("query channel apps", error))?;
    let mut apps = Vec::new();
    for row in rows {
        let raw = row.map_err(|error| host("channel app row", error))?;
        apps.push(raw.into_app(channel)?);
    }
    Ok(apps)
}

pub(crate) fn get_app(
    db: &DbHandle,
    channel: &ScriptChannel,
    request: DatabaseAppRequest,
) -> Result<Option<ChannelApp>, ScriptError> {
    let conn = db
        .reader()
        .map_err(|error| host("read channel app", error.0))?;
    let raw = conn
        .query_row(
            &format!("{SELECT} WHERE channel_key=?1 AND app_id=?2"),
            rusqlite::params![channel.as_str(), request.app_id],
            raw_app,
        )
        .optional()
        .map_err(|error| host("query channel app", error))?;
    raw.map(|raw| raw.into_app(channel)).transpose()
}

pub(crate) fn remove_app(
    db: &DbHandle,
    channel: &ScriptChannel,
    app_id: &str,
) -> Result<(), ScriptError> {
    db.with_writer(|conn| {
        let changed = conn
            .execute(
                "DELETE FROM channel_apps WHERE channel_key=?1 AND app_id=?2",
                rusqlite::params![channel.as_str(), app_id],
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
        if changed > 0 {
            // Flag-gated: pre-flip store code must never arm the guard.
            gstore_core::migration::mark_core_write_if_flipped(conn, "js_channel", None)?;
        }
        Ok(())
    })
    .map_err(|error| host("remove channel app", error.0))
}

pub(crate) fn insert_apps(
    db: &DbHandle,
    channel: &ScriptChannel,
    request: DatabaseInsertRequest,
) -> Result<usize, ScriptError> {
    let mut rows = Vec::with_capacity(request.apps.len());
    for value in request.apps {
        rows.push(InsertRow::parse(&value)?);
    }
    let count = rows.len();
    db.with_writer(|conn| {
        let mut statement = conn
            .prepare(
                "INSERT INTO channel_apps(channel_key, app_id, name, user, repositories, \
                    apprepo, icon, description, category, add_time, source_id, extra) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, NULL, ?11) \
                 ON CONFLICT(channel_key, app_id) DO UPDATE SET \
                     name=excluded.name, user=excluded.user, \
                     repositories=excluded.repositories, apprepo=excluded.apprepo, \
                     icon=excluded.icon, description=excluded.description, \
                     category=excluded.category, add_time=excluded.add_time, \
                     extra=excluded.extra",
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
        for row in &rows {
            statement
                .execute(rusqlite::params![
                    channel.as_str(),
                    row.app_id,
                    row.name,
                    row.user,
                    row.repositories,
                    row.apprepo,
                    row.icon,
                    row.description,
                    row.category,
                    row.add_time,
                    row.extra,
                ])
                .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
        }
        // Flag-gated: pre-flip store code must never arm the guard.
        gstore_core::migration::mark_core_write_if_flipped(conn, "js_channel", None)?;
        Ok(())
    })
    .map_err(|error| host("insert channel apps", error.0))?;
    Ok(count)
}

fn host(context: &str, error: impl std::fmt::Display) -> ScriptError {
    ScriptError::host(format!("CORE_E_SCRIPT_HOST: {context}: {error}"))
}

struct RawApp {
    app_id: String,
    name: String,
    user: String,
    repositories: String,
    apprepo: Option<String>,
    icon: String,
    description: String,
    category: Option<String>,
    add_time: i64,
    extra: Option<String>,
}

fn raw_app(row: &rusqlite::Row<'_>) -> rusqlite::Result<RawApp> {
    Ok(RawApp {
        app_id: row.get(0)?,
        name: row.get(1)?,
        user: row.get(2)?,
        repositories: row.get(3)?,
        apprepo: row.get(4)?,
        icon: row.get(5)?,
        description: row.get(6)?,
        category: row.get(7)?,
        add_time: row.get(8)?,
        extra: row.get(9)?,
    })
}

impl RawApp {
    fn into_app(self, channel: &ScriptChannel) -> Result<ChannelApp, ScriptError> {
        let extra = self
            .extra
            .as_deref()
            .filter(|value| !value.trim().is_empty())
            .map(|value| {
                serde_json::from_str::<JsonValue>(value)
                    .map_err(|error| host("channel app extra is invalid", error))
            })
            .transpose()?;
        Ok(ChannelApp {
            app_id: self.app_id,
            name: self.name,
            user: self.user,
            repositories: self.repositories,
            apprepo: self.apprepo,
            icon: self.icon,
            description: self.description,
            category: self.category,
            add_time: self.add_time,
            channel_code: channel.as_str().to_owned(),
            extra,
        })
    }
}

struct InsertRow {
    app_id: String,
    name: String,
    user: String,
    repositories: String,
    apprepo: Option<String>,
    icon: String,
    description: String,
    category: Option<String>,
    add_time: i64,
    extra: Option<String>,
}

impl InsertRow {
    fn parse(value: &JsonValue) -> Result<Self, ScriptError> {
        let object = value
            .as_object()
            .ok_or_else(|| ScriptError::host("channel app row must be an object"))?;
        let app_id = text(object.get("appId"));
        if app_id.is_empty() {
            return Err(ScriptError::host("channel app row has an empty appId"));
        }
        Ok(Self {
            app_id,
            name: text(object.get("name")),
            user: text(object.get("user")),
            repositories: text(object.get("repositories")),
            apprepo: optional_text(object.get("apprepo")),
            icon: text(object.get("icon")),
            description: text(object.get("description")),
            category: optional_text(object.get("category")),
            add_time: object
                .get("addTime")
                .and_then(JsonValue::as_i64)
                .unwrap_or_else(now_millis),
            extra: object
                .get("extra")
                .filter(|value| !value.is_null())
                .map(ToString::to_string),
        })
    }
}

fn text(value: Option<&JsonValue>) -> String {
    match value {
        Some(JsonValue::String(text)) => text.clone(),
        Some(JsonValue::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn optional_text(value: Option<&JsonValue>) -> Option<String> {
    match value {
        Some(JsonValue::String(text)) if !text.is_empty() => Some(text.clone()),
        _ => None,
    }
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| i64::try_from(duration.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// SQLite-backed `ScriptChannelStore` over the core `channel_apps` table.
///
/// Every call takes the channel key from the caller (the core driver's bound
/// key), never from a script payload, so cross-channel writes stay impossible.
pub struct SqliteScriptChannelStore {
    db: DbHandle,
}

impl SqliteScriptChannelStore {
    pub fn new(db: DbHandle) -> Self {
        Self { db }
    }

    fn channel(&self, channel: &ChannelKey) -> Result<ScriptChannel, CoreError> {
        ScriptChannel::new(channel.as_str()).map_err(|error| CoreError::Internal(error.to_string()))
    }
}

impl ScriptChannelStore for SqliteScriptChannelStore {
    fn list_apps(&self, channel: &ChannelKey) -> Result<Vec<AppSummary>, CoreError> {
        let engine = self.channel(channel)?;
        get_apps(&self.db, &engine)
            .map(|rows| rows.into_iter().map(summary_from_row).collect())
            .map_err(core_err)
    }

    fn get_app(&self, channel: &ChannelKey, app_id: &str) -> Result<Option<AppSummary>, CoreError> {
        let engine = self.channel(channel)?;
        let request = DatabaseAppRequest {
            app_id: app_id.to_owned(),
        };
        get_app(&self.db, &engine, request)
            .map(|row| row.map(summary_from_row))
            .map_err(core_err)
    }

    fn insert_apps(&self, channel: &ChannelKey, apps: &[AppSummary]) -> Result<(), CoreError> {
        if apps.is_empty() {
            return Ok(());
        }
        let engine = self.channel(channel)?;
        let request = DatabaseInsertRequest {
            apps: apps.iter().map(summary_to_json).collect(),
        };
        insert_apps(&self.db, &engine, request)
            .map(|_| ())
            .map_err(core_err)
    }

    fn remove_app(&self, channel: &ChannelKey, app_id: &str) -> Result<(), CoreError> {
        let engine = self.channel(channel)?;
        remove_app(&self.db, &engine, app_id).map_err(core_err)
    }
}

fn core_err(error: ScriptError) -> CoreError {
    CoreError::Internal(error.to_string())
}

fn summary_from_row(row: ChannelApp) -> AppSummary {
    let extra = row.extra.as_ref().and_then(JsonValue::as_object).cloned();
    let package_name = extra
        .as_ref()
        .and_then(|extra| extra.get("packageName"))
        .and_then(JsonValue::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let category = row.category.and_then(|value| {
        let items: Vec<String> = value
            .split(',')
            .map(str::trim)
            .filter(|item| !item.is_empty())
            .map(str::to_owned)
            .collect();
        (!items.is_empty()).then_some(items)
    });
    AppSummary {
        app_id: row.app_id,
        package_name,
        name: row.name,
        user: row.user,
        repositories: row.repositories,
        icon: row.icon,
        des: row.description,
        readme: None,
        category,
        extra,
    }
}

fn summary_to_json(app: &AppSummary) -> JsonValue {
    json!({
        "appId": app.app_id,
        "name": app.name,
        "user": app.user,
        "repositories": app.repositories,
        "icon": app.icon,
        "description": app.des,
        "category": app.category.as_ref().map(|items| items.join(",")),
        "addTime": now_millis(),
        "extra": app.extra.clone(),
    })
}

#[cfg(test)]
mod tests {
    //! Behavioural proof that the `js_channel` marker is flag-gated: the same
    //! `host.database.insertApps` write leaves no `core_writes` row while the
    //! flag is off, and creates it once the flag is on (one run, both
    //! directions).

    use std::path::Path;
    use std::time::Duration;

    use gstore_core::db::core_db_path;
    use gstore_core::flags::{flags, reset_flags, set_flags, FlagsPatch};

    use crate::script_api_test_support::{harness, zip_with};
    use crate::TEST_SERIAL;

    const INSERT_JS: &str = r#"
function main(method, params) {
  if (method === 'doUpdate') {
    host.database.insertApps([{
      appId: params.appId, name: 'Marker', user: 'team',
      repositories: 'repo', icon: 'i', description: 'd'
    }]);
    return { ok: true, data: true };
  }
  return null;
}
"#;

    fn domain_markers(root: &Path, domain: &str) -> i64 {
        let db_path = core_db_path(&root.join("data"));
        let conn = rusqlite::Connection::open_with_flags(
            db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .expect("open core db read-only");
        conn.query_row(
            "SELECT COUNT(*) FROM core_writes WHERE domain=?1",
            [domain],
            |row| row.get(0),
        )
        .expect("count domain markers")
    }

    #[test]
    fn script_db_js_channel_marker_only_after_flip() {
        let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_flags();
        let harness = harness(
            "js-channel-marker",
            Duration::from_millis(500),
            Duration::from_millis(500),
        );
        harness
            .api
            .import(
                zip_with(INSERT_JS, None, None),
                Some("js_marker".to_string()),
            )
            .expect("import marker pack");

        // Flag off: the write happens, the marker does not.
        assert!(!flags().js_channel, "precondition: js_channel flag off");
        harness
            .api
            .run("js_marker", "doUpdate", r#"{"appId":"app.pre"}"#)
            .expect("pre-flip write");
        let stored = harness.api.stored_apps("js_marker").expect("stored apps");
        println!(
            "pre-flip: flag={} marker_rows={} stored={}",
            flags().js_channel,
            domain_markers(&harness.root, "js_channel"),
            stored
        );
        assert!(
            stored.contains("app.pre"),
            "the write must have happened pre-flip: {stored}"
        );
        assert_eq!(
            domain_markers(&harness.root, "js_channel"),
            0,
            "flag off must leave NO js_channel marker"
        );
        assert!(
            !flags().core_writes,
            "flag off must not arm the core_writes projection"
        );

        // Flag on: the same write now records exactly one marker.
        set_flags(FlagsPatch {
            js_channel: Some(true),
            ..FlagsPatch::default()
        })
        .expect("flip js_channel");
        harness
            .api
            .run("js_marker", "doUpdate", r#"{"appId":"app.post"}"#)
            .expect("post-flip write");
        let stored = harness.api.stored_apps("js_marker").expect("stored apps");
        println!(
            "post-flip: flag={} marker_rows={} projection={} stored={}",
            flags().js_channel,
            domain_markers(&harness.root, "js_channel"),
            flags().core_writes,
            stored
        );
        assert!(
            stored.contains("app.post"),
            "the write must have happened post-flip: {stored}"
        );
        assert_eq!(
            domain_markers(&harness.root, "js_channel"),
            1,
            "flag on must create the js_channel marker"
        );
        assert!(
            flags().core_writes,
            "the marker must arm the core_writes projection"
        );

        reset_flags();
    }
}
