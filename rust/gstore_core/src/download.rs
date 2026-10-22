//! Download task persistence helpers for gstore_core.

pub mod legacy;
pub mod parity;
pub mod port;
pub mod strategy;

use rusqlite::OptionalExtension;

use crate::db::DbError;

/// Status marker meaning the module's own database was lost and must be recreated.
pub const NEEDS_RESTART: &str = "needs_restart";

/// Columns selected by [`load_task`] and the port's list query, in the same
/// order as [`row_from_sql`] reads them.
pub(crate) const ROW_COLUMNS: &str = "id, module_task_id, dedup_key, app_id, app_name, version,
     file_name, kind, resource_id, resource_version, url, dest_path, status, bytes_done, total,
     speed_bps, eta_sec, segments_json, retries, server_meta, priority, headers_json,
     expected_sha256, install_after_download, error, last_started_at, created_at, updated_at";

/// Lightweight projection of a `download_task` row used by the download port.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct DownloadTaskRow {
    pub id: i64,
    pub module_task_id: Option<String>,
    pub dedup_key: Option<String>,
    pub app_id: Option<String>,
    pub app_name: Option<String>,
    pub version: Option<String>,
    pub file_name: Option<String>,
    pub kind: Option<String>,
    pub resource_id: Option<String>,
    pub resource_version: Option<String>,
    pub url: Option<String>,
    pub dest_path: Option<String>,
    pub status: String,
    pub bytes_done: i64,
    pub total: i64,
    pub speed_bps: i64,
    pub eta_sec: Option<i64>,
    pub segments_json: Option<String>,
    pub retries: i64,
    pub server_meta: Option<String>,
    pub priority: i64,
    pub headers_json: Option<String>,
    pub expected_sha256: Option<String>,
    pub install_after_download: bool,
    pub error: Option<String>,
    pub last_started_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

/// Maps a row selected with [`ROW_COLUMNS`] into a [`DownloadTaskRow`].
pub(crate) fn row_from_sql(row: &rusqlite::Row<'_>) -> rusqlite::Result<DownloadTaskRow> {
    Ok(DownloadTaskRow {
        id: row.get(0)?,
        module_task_id: row.get(1)?,
        dedup_key: row.get(2)?,
        app_id: row.get(3)?,
        app_name: row.get(4)?,
        version: row.get(5)?,
        file_name: row.get(6)?,
        kind: row.get(7)?,
        resource_id: row.get(8)?,
        resource_version: row.get(9)?,
        url: row.get(10)?,
        dest_path: row.get(11)?,
        status: row.get(12)?,
        bytes_done: row.get(13)?,
        total: row.get(14)?,
        speed_bps: row.get(15)?,
        eta_sec: row.get(16)?,
        segments_json: row.get(17)?,
        retries: row.get(18)?,
        server_meta: row.get(19)?,
        priority: row.get(20)?,
        headers_json: row.get(21)?,
        expected_sha256: row.get(22)?,
        install_after_download: row.get::<_, i64>(23)? != 0,
        error: row.get(24)?,
        last_started_at: row.get(25)?,
        created_at: row.get(26)?,
        updated_at: row.get(27)?,
    })
}

/// Loads a single task row by `module_task_id`.
pub fn load_task(
    conn: &rusqlite::Connection,
    module_task_id: &str,
) -> Result<Option<DownloadTaskRow>, DbError> {
    conn.query_row(
        &format!("SELECT {ROW_COLUMNS} FROM download_task WHERE module_task_id = ?1"),
        [module_task_id],
        row_from_sql,
    )
    .optional()
    .map_err(|e| DbError(format!("load task {module_task_id}: {e}")))
}

/// Loads every task row in `id` order.
///
/// `download_task` in `gstore_core.db` is authoritative, so callers that only
/// need a snapshot (the host list/watch paths) must use this instead of asking
/// the download module.
pub fn list_tasks(conn: &rusqlite::Connection) -> Result<Vec<DownloadTaskRow>, DbError> {
    let mut stmt = conn
        .prepare(&format!("SELECT {ROW_COLUMNS} FROM download_task ORDER BY id"))
        .map_err(|e| DbError(format!("prepare list tasks: {e}")))?;
    let rows = stmt
        .query_map([], row_from_sql)
        .map_err(|e| DbError(format!("query list tasks: {e}")))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| DbError(format!("read list tasks: {e}")))
}
