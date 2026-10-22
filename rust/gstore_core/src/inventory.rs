//! Core-maintained installed-app inventory and the stale-seq policy.
//!
//! The frontend pushes a full [`InventorySnapshot`] per source. The store
//! applies Decision 3 exactly:
//!
//! * same `(source_id, seq)` → idempotent no-op (`accepted: false`,
//!   `reason: "unchanged"`);
//! * `seq < stored_seq` for the same source → [`Error::Conflict`] with the
//!   stable `CORE_E_INVENTORY_STALE` message;
//! * `seq > stored_seq` (or a first push) → the source's app set is replaced
//!   and the push is accepted.
//!
//! Applying a push runs in one `BEGIN IMMEDIATE` transaction and queues a
//! [`CoreEvent::InventoryChanged`] event, drained with
//! [`InventoryStore::take_events`]. No-op and stale pushes emit nothing.
//! Duplicate `package_name` entries inside one snapshot collapse to one row
//! (last wins); an empty snapshot still advances the sequence and clears the
//! source's app set.

use std::collections::HashSet;
use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension, Row, Transaction, TransactionBehavior};

use crate::db::{DbError, DbHandle};
use crate::error::Error;
use crate::event::CoreEvent;
use crate::facts::{InstalledApp, InventoryPushResult, InventorySnapshot};

const SELECT_COLUMNS: &str = "package_name, app_name, version_name, version_code, \
     signature_sha256, source_dir, installer, is_system, target_sdk, min_sdk, abis_json";

/// Stale-seq conflict message (stable wire contract).
pub const INVENTORY_STALE: &str = "CORE_E_INVENTORY_STALE";

/// Storage for the latest installed-app inventory per source.
pub struct InventoryStore {
    db: DbHandle,
    events: Mutex<Vec<CoreEvent>>,
}

impl InventoryStore {
    /// Creates a store over an already-open core database.
    pub fn new(db: DbHandle) -> Self {
        Self {
            db,
            events: Mutex::new(Vec::new()),
        }
    }

    /// Applies one inventory snapshot under the Decision 3 stale-seq policy.
    pub fn push(&self, snapshot: &InventorySnapshot) -> Result<InventoryPushResult, Error> {
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;

        let stored_seq = read_source_seq(&tx, &snapshot.source_id)?;
        match stored_seq {
            Some(seq) if seq == snapshot.seq => {
                return Ok(InventoryPushResult {
                    accepted: false,
                    reason: Some("unchanged".to_string()),
                });
            }
            Some(seq) if snapshot.seq < seq => {
                return Err(Error::Conflict(INVENTORY_STALE.to_string()));
            }
            _ => {}
        }

        tx.execute(
            "DELETE FROM installed_app WHERE source_id=?1",
            [&snapshot.source_id],
        )
        .map_err(sql_error)?;

        let mut seen = HashSet::new();
        for app in &snapshot.apps {
            insert_app(&tx, &snapshot.source_id, snapshot.captured_at, app)?;
            seen.insert(app.package_name.as_str());
        }
        let count = seen.len();

        tx.execute(
            "INSERT INTO inventory_source(source_id, seq, captured_at) \
             VALUES (?1, ?2, ?3) \
             ON CONFLICT(source_id) DO UPDATE SET \
                 seq = excluded.seq, captured_at = excluded.captured_at",
            rusqlite::params![snapshot.source_id, snapshot.seq, snapshot.captured_at],
        )
        .map_err(sql_error)?;
        tx.commit().map_err(sql_error)?;

        self.events
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push(CoreEvent::InventoryChanged {
                source_id: snapshot.source_id.clone(),
                seq: snapshot.seq,
                count,
            });
        Ok(InventoryPushResult {
            accepted: true,
            reason: None,
        })
    }

    /// Returns the newest stored row for `package_name`, regardless of source.
    pub fn get(&self, package_name: &str) -> Result<Option<InstalledApp>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        let sql = format!(
            "SELECT {SELECT_COLUMNS} FROM installed_app WHERE package_name=?1 \
             ORDER BY captured_at DESC, rowid DESC LIMIT 1"
        );
        conn.query_row(&sql, [package_name], row_to_app)
            .optional()
            .map_err(sql_error)
    }

    /// Lists every stored installed app, ordered by package name then source.
    ///
    /// Multiple sources can contribute the same package name; callers that
    /// need one row per package use [`InventoryStore::get`].
    pub fn list(&self) -> Result<Vec<InstalledApp>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        query_apps(
            &conn,
            &format!(
                "SELECT {SELECT_COLUMNS} FROM installed_app \
                 ORDER BY package_name, source_id"
            ),
        )
    }

    /// Forgets one source's app set and stored sequence.
    ///
    /// The next push for the source is treated as a first push. Reads fail
    /// closed (`is_stale == true`, `get == None`) until the frontend pushes
    /// again.
    pub fn invalidate(&self, source_id: &str) -> Result<(), Error> {
        let mut conn = self.db.writer().map_err(db_error)?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql_error)?;
        tx.execute("DELETE FROM installed_app WHERE source_id=?1", [source_id])
            .map_err(sql_error)?;
        tx.execute("DELETE FROM inventory_source WHERE source_id=?1", [source_id])
            .map_err(sql_error)?;
        tx.commit().map_err(sql_error)
    }

    /// Whether `source_id` is missing or older than `max_age_secs` at `now`.
    ///
    /// Both times are milliseconds since the Unix epoch; callers inject `now`
    /// so judgement never reads the wall clock implicitly.
    pub fn is_stale(&self, source_id: &str, max_age_secs: i64, now: i64) -> Result<bool, Error> {
        let Some(captured_at) = self.captured_at(source_id)? else {
            return Ok(true);
        };
        let max_age_ms = max_age_secs.saturating_mul(1_000);
        Ok(now.saturating_sub(captured_at) > max_age_ms)
    }

    /// Returns the accepted sequence for `source_id`, if any.
    pub fn source_seq(&self, source_id: &str) -> Result<Option<i64>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        read_source_seq(&conn, source_id)
    }

    /// Drains queued [`CoreEvent::InventoryChanged`] events.
    pub fn take_events(&self) -> Vec<CoreEvent> {
        std::mem::take(
            &mut *self
                .events
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()),
        )
    }

    fn captured_at(&self, source_id: &str) -> Result<Option<i64>, Error> {
        let conn = self.db.reader().map_err(db_error)?;
        conn.query_row(
            "SELECT captured_at FROM inventory_source WHERE source_id=?1",
            [source_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(sql_error)
    }
}

fn read_source_seq(conn: &Connection, source_id: &str) -> Result<Option<i64>, Error> {
    conn.query_row(
        "SELECT seq FROM inventory_source WHERE source_id=?1",
        [source_id],
        |row| row.get(0),
    )
    .optional()
    .map_err(sql_error)
}

fn insert_app(
    tx: &Transaction<'_>,
    source_id: &str,
    captured_at: i64,
    app: &InstalledApp,
) -> Result<(), Error> {
    let abis_json = serde_json::to_string(&app.abis)?;
    tx.execute(
        "INSERT INTO installed_app(\
             source_id, package_name, app_name, version_name, version_code, \
             signature_sha256, source_dir, installer, is_system, target_sdk, \
             min_sdk, abis_json, captured_at\
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13) \
         ON CONFLICT(source_id, package_name) DO UPDATE SET \
             app_name = excluded.app_name, \
             version_name = excluded.version_name, \
             version_code = excluded.version_code, \
             signature_sha256 = excluded.signature_sha256, \
             source_dir = excluded.source_dir, \
             installer = excluded.installer, \
             is_system = excluded.is_system, \
             target_sdk = excluded.target_sdk, \
             min_sdk = excluded.min_sdk, \
             abis_json = excluded.abis_json, \
             captured_at = excluded.captured_at",
        rusqlite::params![
            source_id,
            app.package_name,
            app.app_name,
            app.version_name,
            app.version_code,
            app.signature_sha256,
            app.source_dir,
            app.installer,
            i64::from(app.is_system),
            app.target_sdk,
            app.min_sdk,
            abis_json,
            captured_at,
        ],
    )
    .map_err(sql_error)?;
    Ok(())
}

fn row_to_app(row: &Row<'_>) -> rusqlite::Result<InstalledApp> {
    let abis_json: String = row.get(10)?;
    let abis = serde_json::from_str(&abis_json).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(10, rusqlite::types::Type::Text, Box::new(e))
    })?;
    Ok(InstalledApp {
        package_name: row.get(0)?,
        app_name: row.get(1)?,
        version_name: row.get(2)?,
        version_code: row.get(3)?,
        signature_sha256: row.get(4)?,
        source_dir: row.get(5)?,
        installer: row.get(6)?,
        is_system: row.get::<_, i64>(7)? != 0,
        target_sdk: row.get(8)?,
        min_sdk: row.get(9)?,
        abis,
    })
}

fn query_apps(conn: &Connection, sql: &str) -> Result<Vec<InstalledApp>, Error> {
    let mut stmt = conn.prepare(sql).map_err(sql_error)?;
    let rows = stmt
        .query_map([], row_to_app)
        .map_err(sql_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(sql_error)?;
    Ok(rows)
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
