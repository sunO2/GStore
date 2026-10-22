//! Added apps and user tags over the V2 `added_apps` / `added_app_tags` tables.
//!
//! This is the storage half of Dart's `AppAggregatorManager` +
//! `AddedAppDao` + `AppTagDao`. It reproduces the observable behavior of the
//! Floor DAO queries; it deliberately does **not** call channel drivers, and it
//! does **not** canonicalize app ids. Callers own `canonicalAppId` and must
//! pass the already-canonical id (documented at each entry point that needs
//! it).
//!
//! Dart-parity quirks reproduced on purpose (do not "fix" these):
//!
//! * `clear_channel` / `clear_all` delete only `added_apps` rows. Dart leaves
//!   `added_app_tags` untouched, so orphan tags survive a clear.
//! * `rename` deletes and re-inserts the moved tags, so every moved tag gets a
//!   fresh `add_time = now`; a tag that already existed on the target app is
//!   replaced (and refreshed) as well.
//! * `add` is an upsert: adding an existing `(channel, app_id)` refreshes
//!   `add_time`, keeps `is_enabled`, and only changes `sort_order` when the
//!   caller supplied one.
//!
//! Every mutation runs in one `BEGIN IMMEDIATE` transaction on the single
//! [`DbHandle`] writer; reads use fresh read-only WAL connections.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, Row, Transaction, TransactionBehavior};

use crate::db::{DbError, DbHandle};
use crate::error::Error;

type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

const SELECT_COLUMNS: &str = "id, channel_id, app_id, add_time, sort_order, is_enabled";

/// One row of the `added_apps` reference table.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct AddedApp {
    pub id: i64,
    pub channel_id: String,
    pub app_id: String,
    pub add_time: i64,
    pub sort_order: i64,
    pub is_enabled: bool,
}

/// One user tag attached to a `(channel_id, app_id)` pair.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct AddedAppTag {
    pub channel_id: String,
    pub app_id: String,
    pub tag: String,
    pub add_time: i64,
}

/// Storage service for added apps and their user tags.
pub struct AddedAppsService {
    db: DbHandle,
    clock: Clock,
}

impl AddedAppsService {
    /// Creates a service over an already-open core database using wall-clock time.
    pub fn new(db: DbHandle) -> Self {
        Self::with_clock(db, Arc::new(system_now_millis))
    }

    /// Creates a service with an injectable millisecond clock.
    ///
    /// The clock is called at most once per mutation and never during reads.
    pub fn with_clock(db: DbHandle, clock: Clock) -> Self {
        Self { db, clock }
    }

    /// Adds an app, or refreshes an existing `(channel, app_id)` row.
    ///
    /// The caller must pass the channel-canonical `app_id`; this service does
    /// not canonicalize. New rows get `sort_order = supplied ?? 0` and
    /// `is_enabled = 1`. An existing row keeps its `is_enabled`, always
    /// refreshes `add_time = now`, and keeps its `sort_order` unless one is
    /// supplied.
    pub fn add(
        &self,
        channel: &str,
        app_id: &str,
        sort_order: Option<i64>,
    ) -> Result<AddedApp, Error> {
        self.write(|tx, now| {
            tx.execute(
                "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
                 VALUES (?1, ?2, ?3, ?4, 1) \
                 ON CONFLICT(channel_id, app_id) DO UPDATE SET \
                     add_time = excluded.add_time, \
                     sort_order = CASE WHEN ?5 = 1 \
                         THEN excluded.sort_order ELSE added_apps.sort_order END, \
                     is_enabled = added_apps.is_enabled",
                rusqlite::params![
                    channel,
                    app_id,
                    now,
                    sort_order.unwrap_or(0),
                    i64::from(sort_order.is_some())
                ],
            )
            .map_err(sql_error)?;
            load_app(tx, channel, app_id)?
                .ok_or_else(|| Error::Internal("added app disappeared after upsert".to_string()))
        })
    }

    /// Removes one app row and all of its tags.
    ///
    /// Returns whether an `added_apps` row existed. Tags are deleted even when
    /// the row was already gone (Dart `removeApp` does the same).
    pub fn remove(&self, channel: &str, app_id: &str) -> Result<bool, Error> {
        self.write(|tx, _now| {
            let existed = tx
                .execute(
                    "DELETE FROM added_apps WHERE channel_id=?1 AND app_id=?2",
                    rusqlite::params![channel, app_id],
                )
                .map_err(sql_error)?
                > 0;
            tx.execute(
                "DELETE FROM added_app_tags WHERE channel_id=?1 AND app_id=?2",
                rusqlite::params![channel, app_id],
            )
            .map_err(sql_error)?;
            Ok(existed)
        })
    }

    /// Renames an app id inside one channel (Dart `renameApp`).
    ///
    /// * `old == new`, or the source row is missing: no-op, returns `false`.
    /// * Target absent: the source row keeps its id, `add_time`, `sort_order`,
    ///   and `is_enabled`; only `app_id` changes.
    /// * Target present: the source row is deleted and the target row's
    ///   metadata is kept.
    ///
    /// Moved tags are re-inserted with `add_time = now`; a collision with an
    /// existing target tag replaces the target tag. Caller owns canonical ids.
    pub fn rename(&self, channel: &str, old_app_id: &str, new_app_id: &str) -> Result<bool, Error> {
        if old_app_id == new_app_id {
            return Ok(false);
        }
        self.write(|tx, now| {
            if load_app(tx, channel, old_app_id)?.is_none() {
                return Ok(false);
            }

            let target_exists = load_app(tx, channel, new_app_id)?.is_some();
            if target_exists {
                tx.execute(
                    "DELETE FROM added_apps WHERE channel_id=?1 AND app_id=?2",
                    rusqlite::params![channel, old_app_id],
                )
                .map_err(sql_error)?;
            } else {
                tx.execute(
                    "UPDATE added_apps SET app_id=?2 \
                     WHERE channel_id=?1 AND app_id=?3",
                    rusqlite::params![channel, new_app_id, old_app_id],
                )
                .map_err(sql_error)?;
            }

            let source_tags = read_tag_names(tx, channel, old_app_id)?;
            if !source_tags.is_empty() {
                tx.execute(
                    "DELETE FROM added_app_tags WHERE channel_id=?1 AND app_id=?2",
                    rusqlite::params![channel, old_app_id],
                )
                .map_err(sql_error)?;
                for tag in &source_tags {
                    tx.execute(
                        "INSERT OR REPLACE INTO added_app_tags(channel_id, app_id, tag, add_time) \
                         VALUES (?1, ?2, ?3, ?4)",
                        rusqlite::params![channel, new_app_id, tag, now],
                    )
                    .map_err(sql_error)?;
                }
            }
            Ok(true)
        })
    }

    /// Sets the sort weight of one app; a missing row is [`Error::NotFound`].
    pub fn set_order(&self, channel: &str, app_id: &str, sort_order: i64) -> Result<(), Error> {
        self.write(|tx, _now| {
            let changed = tx
                .execute(
                    "UPDATE added_apps SET sort_order=?3 \
                     WHERE channel_id=?1 AND app_id=?2",
                    rusqlite::params![channel, app_id, sort_order],
                )
                .map_err(sql_error)?;
            if changed == 0 {
                return Err(not_found(channel, app_id));
            }
            Ok(())
        })
    }

    /// Toggles an app: present rows (and their tags) are removed, absent rows
    /// are added with `sort_order = 0`. Returns the new added state.
    ///
    /// The caller must pass the channel-canonical `app_id`.
    pub fn toggle(&self, channel: &str, app_id: &str) -> Result<bool, Error> {
        self.write(|tx, now| {
            if load_app(tx, channel, app_id)?.is_some() {
                tx.execute(
                    "DELETE FROM added_apps WHERE channel_id=?1 AND app_id=?2",
                    rusqlite::params![channel, app_id],
                )
                .map_err(sql_error)?;
                tx.execute(
                    "DELETE FROM added_app_tags WHERE channel_id=?1 AND app_id=?2",
                    rusqlite::params![channel, app_id],
                )
                .map_err(sql_error)?;
                return Ok(false);
            }
            tx.execute(
                "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
                 VALUES (?1, ?2, ?3, 0, 1)",
                rusqlite::params![channel, app_id, now],
            )
            .map_err(sql_error)?;
            Ok(true)
        })
    }

    /// Deletes every `added_apps` row in one channel.
    ///
    /// Dart parity: `added_app_tags` rows are intentionally left in place, so
    /// clearing a channel can leave orphan tags.
    pub fn clear_channel(&self, channel: &str) -> Result<usize, Error> {
        self.write(|tx, _now| {
            tx.execute("DELETE FROM added_apps WHERE channel_id=?1", [channel])
                .map_err(sql_error)
        })
    }

    /// Deletes every `added_apps` row across all channels.
    ///
    /// Dart parity: `added_app_tags` rows are intentionally left in place.
    pub fn clear_all(&self) -> Result<usize, Error> {
        self.write(|tx, _now| tx.execute("DELETE FROM added_apps", []).map_err(sql_error))
    }

    /// Lists every added app, newest first (`add_time DESC`).
    pub fn list(&self) -> Result<Vec<AddedApp>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        query_apps(
            &conn,
            &format!("SELECT {SELECT_COLUMNS} FROM added_apps ORDER BY add_time DESC"),
            [],
        )
    }

    /// Lists one channel's added apps, newest first (`add_time DESC`).
    pub fn list_channel(&self, channel: &str) -> Result<Vec<AddedApp>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        query_apps(
            &conn,
            &format!(
                "SELECT {SELECT_COLUMNS} FROM added_apps \
                 WHERE channel_id=?1 ORDER BY add_time DESC"
            ),
            [channel],
        )
    }

    /// Returns one app row, if present.
    pub fn get(&self, channel: &str, app_id: &str) -> Result<Option<AddedApp>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        load_app(&conn, channel, app_id)
    }

    /// Returns whether `(channel, app_id)` is in `added_apps`.
    pub fn is_added(&self, channel: &str, app_id: &str) -> Result<bool, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM added_apps WHERE channel_id=?1 AND app_id=?2)",
            rusqlite::params![channel, app_id],
            |row| row.get::<_, i64>(0),
        )
        .map(|count| count != 0)
        .map_err(sql_error)
    }

    /// Total number of added apps.
    pub fn total_count(&self) -> Result<i64, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        conn.query_row("SELECT COUNT(*) FROM added_apps", [], |row| row.get(0))
            .map_err(sql_error)
    }

    /// Number of added apps in one channel.
    pub fn count_channel(&self, channel: &str) -> Result<i64, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        conn.query_row(
            "SELECT COUNT(*) FROM added_apps WHERE channel_id=?1",
            [channel],
            |row| row.get(0),
        )
        .map_err(sql_error)
    }

    /// Replaces all tags for one app.
    ///
    /// Tags are trimmed, empty strings dropped, and duplicates removed by first
    /// occurrence while preserving insertion order.
    pub fn set_tags(&self, channel: &str, app_id: &str, tags: &[String]) -> Result<(), Error> {
        let mut seen = std::collections::HashSet::new();
        let cleaned: Vec<&str> = tags
            .iter()
            .map(|tag| tag.trim())
            .filter(|tag| !tag.is_empty())
            .filter(|tag| seen.insert((*tag).to_string()))
            .collect();

        self.write(|tx, now| {
            tx.execute(
                "DELETE FROM added_app_tags WHERE channel_id=?1 AND app_id=?2",
                rusqlite::params![channel, app_id],
            )
            .map_err(sql_error)?;
            for tag in &cleaned {
                tx.execute(
                    "INSERT INTO added_app_tags(channel_id, app_id, tag, add_time) \
                     VALUES (?1, ?2, ?3, ?4)",
                    rusqlite::params![channel, app_id, tag, now],
                )
                .map_err(sql_error)?;
            }
            Ok(())
        })
    }

    /// Adds one tag, replacing (and refreshing `add_time`) on duplicate.
    ///
    /// The tag is trimmed; an empty tag is a no-op. Caller owns canonical ids.
    pub fn add_tag(&self, channel: &str, app_id: &str, tag: &str) -> Result<(), Error> {
        let tag = tag.trim();
        if tag.is_empty() {
            return Ok(());
        }
        self.write(|tx, now| {
            tx.execute(
                "INSERT OR REPLACE INTO added_app_tags(channel_id, app_id, tag, add_time) \
                 VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![channel, app_id, tag, now],
            )
            .map_err(sql_error)?;
            Ok(())
        })
    }

    /// Removes one tag; absent tags are a no-op.
    pub fn remove_tag(&self, channel: &str, app_id: &str, tag: &str) -> Result<(), Error> {
        self.write(|tx, _now| {
            tx.execute(
                "DELETE FROM added_app_tags \
                 WHERE channel_id=?1 AND app_id=?2 AND tag=?3",
                rusqlite::params![channel, app_id, tag],
            )
            .map_err(sql_error)?;
            Ok(())
        })
    }

    /// Returns one app's tags, earliest `add_time` first.
    pub fn tags(&self, channel: &str, app_id: &str) -> Result<Vec<String>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        read_tag_names(&conn, channel, app_id)
    }

    /// Returns all tags keyed by `"{channel_id}:{app_id}"`.
    ///
    /// Values follow `add_time` (then insertion) order; the `BTreeMap` makes
    /// the key order deterministic.
    pub fn tags_index(&self) -> Result<BTreeMap<String, Vec<String>>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        let mut stmt = conn
            .prepare(
                "SELECT channel_id, app_id, tag FROM added_app_tags \
                 ORDER BY add_time, rowid",
            )
            .map_err(sql_error)?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)?;

        let mut index: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for (channel, app_id, tag) in rows {
            index
                .entry(format!("{channel}:{app_id}"))
                .or_default()
                .push(tag);
        }
        Ok(index)
    }

    fn write<T>(
        &self,
        f: impl FnOnce(&Transaction<'_>, i64) -> Result<T, Error>,
    ) -> Result<T, Error> {
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;
        let value = f(&tx, (self.clock)())?;
        tx.commit().map_err(sql_error)?;
        Ok(value)
    }
}

fn system_now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn db_error(error: DbError) -> Error {
    Error::Io(error.to_string())
}

fn sql_error(error: rusqlite::Error) -> Error {
    if matches!(
        &error,
        rusqlite::Error::SqliteFailure(code, _)
            if code.code == rusqlite::ErrorCode::ConstraintViolation
    ) {
        Error::Conflict(error.to_string())
    } else {
        Error::Io(error.to_string())
    }
}

fn not_found(channel: &str, app_id: &str) -> Error {
    Error::NotFound(format!("added app not found: {channel}:{app_id}"))
}

fn row_to_app(row: &Row<'_>) -> rusqlite::Result<AddedApp> {
    Ok(AddedApp {
        id: row.get(0)?,
        channel_id: row.get(1)?,
        app_id: row.get(2)?,
        add_time: row.get(3)?,
        sort_order: row.get(4)?,
        is_enabled: row.get::<_, i64>(5)? != 0,
    })
}

fn query_apps<P: rusqlite::Params>(
    conn: &Connection,
    sql: &str,
    params: P,
) -> Result<Vec<AddedApp>, Error> {
    let mut stmt = conn.prepare(sql).map_err(sql_error)?;
    let rows = stmt
        .query_map(params, row_to_app)
        .map_err(sql_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(sql_error)?;
    Ok(rows)
}

fn load_app(conn: &Connection, channel: &str, app_id: &str) -> Result<Option<AddedApp>, Error> {
    conn.query_row(
        &format!(
            "SELECT {SELECT_COLUMNS} FROM added_apps \
             WHERE channel_id=?1 AND app_id=?2 LIMIT 1"
        ),
        rusqlite::params![channel, app_id],
        row_to_app,
    )
    .optional()
    .map_err(sql_error)
}

fn read_tag_names(conn: &Connection, channel: &str, app_id: &str) -> Result<Vec<String>, Error> {
    let mut stmt = conn
        .prepare(
            "SELECT tag FROM added_app_tags \
             WHERE channel_id=?1 AND app_id=?2 ORDER BY add_time",
        )
        .map_err(sql_error)?;
    let rows = stmt
        .query_map(rusqlite::params![channel, app_id], |row| row.get(0))
        .map_err(sql_error)?
        .collect::<Result<Vec<String>, _>>()
        .map_err(sql_error)?;
    Ok(rows)
}
