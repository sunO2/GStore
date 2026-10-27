//! SQLite-backed [`ChannelStore`] implementation.
//!
//! Registry rows live in the existing `channels` table from
//! `migrations/V1__core_schema.sql`; this module adds no schema changes. Every
//! mutation runs inside one `BEGIN IMMEDIATE` transaction on the single
//! [`DbHandle`] writer, and every read uses a fresh read-only WAL connection.
//!
//! Semantics mirror `ChannelManager`:
//! - `register` is idempotent for an identical record; the same key with a
//!   different kind is [`Error::Conflict`], while mutable metadata (name,
//!   enabled, priority, ...) is updated and `updated_at` is refreshed.
//! - `insert`/`create` reject any existing key with [`Error::Conflict`].
//! - `unregister`/`enable`/`disable`/`set_priority` return
//!   [`Error::NotFound`] for unknown keys.
//! - `list` is ordered by key; `priority_order` is enabled-only and ordered by
//!   `(priority, key)`.
//!
//! `created_at` is written once; `updated_at` is refreshed by each real
//! mutation. Timestamps come from an injectable clock so tests never sleep.

use std::path::Path;
#[cfg(test)]
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, Row, Transaction, TransactionBehavior};

use crate::db::{DbError, DbHandle};
use crate::dto::{ChannelKey, ChannelKind, ChannelMeta};
use crate::error::Error;

use super::pack::validate_channel_key;
use super::store::{ChannelRecord, ChannelStore};

type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

const SELECT_COLUMNS: &str = "key, kind, name, description, enabled, priority, \
     support_offline, last_update_time, version";

/// SQLite-backed persistent channel registry.
///
/// The store is `Send + Sync` (the writer is a mutex and the clock is an
/// `Arc<dyn Fn ... + Send + Sync>`) and can therefore live behind `Arc` or
/// inside [`super::ChannelRegistry`].
pub struct SqliteChannelStore {
    db: DbHandle,
    clock: Clock,
    #[cfg(test)]
    fail_after_write: AtomicBool,
}

impl SqliteChannelStore {
    /// Creates a store over an already-open core database using wall-clock time.
    pub fn new(db: DbHandle) -> Self {
        Self::with_clock(db, system_now_millis)
    }

    /// Creates a store with an injectable millisecond clock.
    ///
    /// The clock is called at most once per mutation and never during reads.
    pub fn with_clock<F>(db: DbHandle, clock: F) -> Self
    where
        F: Fn() -> i64 + Send + Sync + 'static,
    {
        Self {
            db,
            clock: Arc::new(clock),
            #[cfg(test)]
            fail_after_write: AtomicBool::new(false),
        }
    }

    /// Opens (or creates) the core database under `data_dir` and wraps it.
    pub fn open(data_dir: &Path) -> Result<Self, Error> {
        DbHandle::open(data_dir).map(Self::new).map_err(db_error)
    }

    /// Opens (or creates) the core database at an explicit path and wraps it.
    pub fn open_at(path: &Path) -> Result<Self, Error> {
        DbHandle::open_at(path).map(Self::new).map_err(db_error)
    }

    /// Borrows the shared database handle.
    pub fn db(&self) -> &DbHandle {
        &self.db
    }

    /// Returns `(created_at, updated_at)` for a row, if present.
    ///
    /// Exposed for observability and evidence: callers can prove that an
    /// idempotent register did not touch `created_at`.
    pub fn timestamps(&self, key: &ChannelKey) -> Result<Option<(i64, i64)>, Error> {
        validate_key(key)?;
        let conn = self.db.reader().map_err(db_error)?;
        conn.query_row(
            "SELECT created_at, updated_at FROM channels WHERE key=?1",
            [key.as_str()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(sql_error)
    }

    fn now(&self) -> i64 {
        (self.clock)()
    }

    fn mutate<F>(&self, f: F) -> Result<(), Error>
    where
        F: FnOnce(&Transaction<'_>, i64) -> Result<(), Error>,
    {
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;
        f(&tx, self.now())?;
        crate::migration::mark_core_write_if_flipped(&tx, "channel", None).map_err(db_error)?;
        #[cfg(test)]
        self.injected_failure()?;
        tx.commit().map_err(sql_error)
    }

    #[cfg(test)]
    fn fail_next_mutation(&self) {
        self.fail_after_write.store(true, Ordering::SeqCst);
    }

    #[cfg(test)]
    fn injected_failure(&self) -> Result<(), Error> {
        if self.fail_after_write.swap(false, Ordering::SeqCst) {
            return Err(Error::Internal(
                "injected failure after the first write".to_string(),
            ));
        }
        Ok(())
    }
}

impl ChannelStore for SqliteChannelStore {
    fn register(&self, record: ChannelRecord) -> Result<(), Error> {
        validate_record(&record)?;
        self.mutate(|tx, now| match load_one(tx, &record.key)? {
            None => insert_row(tx, &record, now, now),
            Some(existing) if existing.record.kind() != record.kind() => Err(Error::Conflict(
                format!("channel already registered: {}", record.key),
            )),
            Some(existing) if existing.record == record => Ok(()),
            Some(_) => update_row(tx, &record, now),
        })
    }

    fn insert(&self, record: ChannelRecord) -> Result<(), Error> {
        validate_record(&record)?;
        self.mutate(|tx, now| {
            if load_one(tx, &record.key)?.is_some() {
                return Err(Error::Conflict(format!(
                    "channel already registered: {}",
                    record.key
                )));
            }
            insert_row(tx, &record, now, now)
        })
    }

    fn unregister(&self, key: &ChannelKey) -> Result<(), Error> {
        validate_key(key)?;
        self.mutate(|tx, _now| {
            let changed = tx
                .execute("DELETE FROM channels WHERE key=?1", [key.as_str()])
                .map_err(sql_error)?;
            if changed == 0 {
                return Err(not_found(key));
            }
            Ok(())
        })
    }

    fn get(&self, key: &ChannelKey) -> Result<Option<ChannelRecord>, Error> {
        validate_key(key)?;
        let conn = self.db.reader().map_err(db_error)?;
        Ok(load_one(&conn, key)?.map(|stored| stored.record))
    }

    fn list(&self) -> Result<Vec<ChannelRecord>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {SELECT_COLUMNS} FROM channels ORDER BY key ASC"
            ))
            .map_err(sql_error)?;
        let raw = stmt
            .query_map([], row_to_raw)
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)?;
        raw.into_iter()
            .map(|row| row.into_stored().map(|stored| stored.record))
            .collect()
    }

    fn enable(&self, key: &ChannelKey) -> Result<(), Error> {
        self.set_enabled(key, true)
    }

    fn disable(&self, key: &ChannelKey) -> Result<(), Error> {
        self.set_enabled(key, false)
    }

    fn set_priority(&self, key: &ChannelKey, priority: i32) -> Result<(), Error> {
        validate_key(key)?;
        validate_priority(priority)?;
        self.mutate(|tx, now| {
            let changed = tx
                .execute(
                    "UPDATE channels SET priority=?2, updated_at=?3 WHERE key=?1",
                    rusqlite::params![key.as_str(), priority, now],
                )
                .map_err(sql_error)?;
            if changed == 0 {
                return Err(not_found(key));
            }
            Ok(())
        })
    }

    fn priority_order(&self) -> Result<Vec<ChannelRecord>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {SELECT_COLUMNS} FROM channels \
                 WHERE enabled = 1 ORDER BY priority ASC, key ASC"
            ))
            .map_err(sql_error)?;
        let raw = stmt
            .query_map([], row_to_raw)
            .map_err(sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql_error)?;
        raw.into_iter()
            .map(|row| row.into_stored().map(|stored| stored.record))
            .collect()
    }
}

impl SqliteChannelStore {
    fn set_enabled(&self, key: &ChannelKey, enabled: bool) -> Result<(), Error> {
        validate_key(key)?;
        self.mutate(|tx, now| {
            let changed = tx
                .execute(
                    "UPDATE channels SET enabled=?2, updated_at=?3 WHERE key=?1",
                    rusqlite::params![key.as_str(), i64::from(enabled), now],
                )
                .map_err(sql_error)?;
            if changed == 0 {
                return Err(not_found(key));
            }
            Ok(())
        })
    }
}

struct StoredChannel {
    record: ChannelRecord,
}

struct RawChannel {
    key: String,
    kind: String,
    name: String,
    description: String,
    enabled: i64,
    priority: i64,
    support_offline: i64,
    last_update_time: Option<i64>,
    version: Option<String>,
}

impl RawChannel {
    fn into_stored(self) -> Result<StoredChannel, Error> {
        let key = ChannelKey::new(self.key.clone())?;
        validate_channel_key(&key)?;
        let kind = ChannelKind::from_code(&self.kind)?;
        let priority = i32::try_from(self.priority)
            .ok()
            .filter(|value| *value >= 0)
            .ok_or_else(|| {
                Error::InvalidArgument(format!(
                    "channel priority out of range for {}: {}",
                    self.key, self.priority
                ))
            })?;
        Ok(StoredChannel {
            record: ChannelRecord::new(
                key,
                ChannelMeta {
                    kind,
                    name: self.name,
                    description: self.description,
                    enabled: parse_flag(self.enabled, "enabled")?,
                    priority,
                    support_offline: parse_flag(self.support_offline, "support_offline")?,
                    last_update_time: self.last_update_time,
                    version: self.version,
                },
            ),
        })
    }
}

fn row_to_raw(row: &Row<'_>) -> rusqlite::Result<RawChannel> {
    Ok(RawChannel {
        key: row.get(0)?,
        kind: row.get(1)?,
        name: row.get(2)?,
        description: row.get(3)?,
        enabled: row.get(4)?,
        priority: row.get(5)?,
        support_offline: row.get(6)?,
        last_update_time: row.get(7)?,
        version: row.get(8)?,
    })
}

fn load_one(conn: &Connection, key: &ChannelKey) -> Result<Option<StoredChannel>, Error> {
    let raw = conn
        .query_row(
            &format!("SELECT {SELECT_COLUMNS} FROM channels WHERE key=?1"),
            [key.as_str()],
            row_to_raw,
        )
        .optional()
        .map_err(sql_error)?;
    raw.map(RawChannel::into_stored).transpose()
}

fn insert_row(
    tx: &Transaction<'_>,
    record: &ChannelRecord,
    created_at: i64,
    updated_at: i64,
) -> Result<(), Error> {
    tx.execute(
        "INSERT INTO channels(\
             key, kind, name, description, enabled, priority, support_offline, \
             last_update_time, version, created_at, updated_at\
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        rusqlite::params![
            record.key.as_str(),
            record.meta.kind.as_code(),
            record.meta.name.as_str(),
            record.meta.description.as_str(),
            i64::from(record.meta.enabled),
            record.meta.priority,
            i64::from(record.meta.support_offline),
            record.meta.last_update_time,
            record.meta.version.as_deref(),
            created_at,
            updated_at,
        ],
    )
    .map(|_| ())
    .map_err(sql_error)
}

fn update_row(tx: &Transaction<'_>, record: &ChannelRecord, updated_at: i64) -> Result<(), Error> {
    let changed = tx
        .execute(
            "UPDATE channels SET \
                 name=?2, description=?3, enabled=?4, priority=?5, \
                 support_offline=?6, last_update_time=?7, version=?8, updated_at=?9 \
             WHERE key=?1",
            rusqlite::params![
                record.key.as_str(),
                record.meta.name.as_str(),
                record.meta.description.as_str(),
                i64::from(record.meta.enabled),
                record.meta.priority,
                i64::from(record.meta.support_offline),
                record.meta.last_update_time,
                record.meta.version.as_deref(),
                updated_at,
            ],
        )
        .map_err(sql_error)?;
    if changed == 0 {
        return Err(not_found(&record.key));
    }
    Ok(())
}

fn validate_record(record: &ChannelRecord) -> Result<(), Error> {
    validate_key(&record.key)?;
    validate_priority(record.meta.priority)
}

fn validate_key(key: &ChannelKey) -> Result<(), Error> {
    validate_channel_key(key)
}

fn validate_priority(priority: i32) -> Result<(), Error> {
    if priority < 0 {
        return Err(Error::InvalidArgument(format!(
            "channel priority must not be negative: {priority}"
        )));
    }
    Ok(())
}

fn parse_flag(value: i64, column: &str) -> Result<bool, Error> {
    match value {
        0 => Ok(false),
        1 => Ok(true),
        other => Err(Error::InvalidArgument(format!(
            "invalid channels.{column} value: {other}"
        ))),
    }
}

fn not_found(key: &ChannelKey) -> Error {
    Error::NotFound(format!("channel not registered: {key}"))
}

fn db_error(error: DbError) -> Error {
    Error::Io(error.0)
}

fn sql_error(error: rusqlite::Error) -> Error {
    if let rusqlite::Error::SqliteFailure(inner, _) = &error {
        if inner.code == rusqlite::ErrorCode::ConstraintViolation {
            return Error::Conflict(error.to_string());
        }
    }
    Error::Io(error.to_string())
}

fn system_now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| i64::try_from(duration.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use crate::dto::ChannelMeta;
    use std::path::PathBuf;

    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "gstore_core_sqlite_store_{tag}_{}_{}",
            std::process::id(),
            system_now_millis()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    fn record(
        key: &str,
        kind: ChannelKind,
        name: &str,
        enabled: bool,
        priority: i32,
    ) -> ChannelRecord {
        ChannelRecord::new(
            ChannelKey::new(key).unwrap(),
            ChannelMeta {
                kind,
                name: name.to_string(),
                description: format!("{name} channel"),
                enabled,
                priority,
                support_offline: false,
                last_update_time: None,
                version: Some("test".to_string()),
            },
        )
    }

    #[test]
    fn registry_persists_store_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<SqliteChannelStore>();
        println!("SqliteChannelStore: Send + Sync");
    }

    #[test]
    fn registry_persists_rollback_on_mid_mutation() {
        let dir = temp_dir("rollback");
        let store = SqliteChannelStore::open_at(&dir.join("gstore_core.db")).expect("open");
        let original = record("js_rollback", ChannelKind::JsLocal, "Original", true, 3);
        store.register(original.clone()).expect("seed row");
        let key = original.key.clone();
        let before_ts = store.timestamps(&key).expect("timestamps").expect("row");
        let before_count = store.list().expect("list").len();

        let mut changed = original.clone();
        changed.meta.name = "Changed".to_string();
        changed.meta.priority = 99;
        changed.meta.enabled = false;

        store.fail_next_mutation();
        let error = store
            .register(changed)
            .expect_err("injected failure must abort the transaction");
        println!(
            "injected mid-mutation failure: code={} message={}",
            error.code(),
            error.message()
        );
        assert_eq!(error.code(), "internal");

        let after = store.get(&key).expect("get").expect("row survived");
        let after_ts = store.timestamps(&key).expect("timestamps").expect("row");
        let after_count = store.list().expect("list").len();
        println!(
            "rollback proof: count {before_count}->{after_count} timestamps {before_ts:?}->{after_ts:?} record={after:?}"
        );
        assert_eq!(
            after, original,
            "failed transaction must leave the row untouched"
        );
        assert_eq!(
            after_count, before_count,
            "rollback must not add/remove rows"
        );
        assert_eq!(after_ts, before_ts, "rollback must not refresh timestamps");

        drop(store);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
