//! Download task persistence helpers for gstore_core.

use rusqlite::OptionalExtension;

use crate::db::DbError;

/// Status marker meaning the module's own database was lost and must be recreated.
pub const NEEDS_RESTART: &str = "needs_restart";

/// Lightweight projection of a `download_task` row used by the download port.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DownloadTaskRow {
    pub id: i64,
    pub module_task_id: Option<String>,
    pub dedup_key: Option<String>,
    pub app_id: Option<String>,
    pub app_name: Option<String>,
    pub version: Option<String>,
    pub file_name: Option<String>,
    pub kind: Option<String>,
    pub status: String,
    pub bytes_done: i64,
    pub total: i64,
    pub speed_bps: i64,
    pub eta_sec: Option<i64>,
    pub last_started_at: Option<i64>,
}

/// Loads a single task row by `module_task_id`.
pub fn load_task(
    conn: &rusqlite::Connection,
    module_task_id: &str,
) -> Result<Option<DownloadTaskRow>, DbError> {
    conn.query_row(
        "SELECT id, module_task_id, dedup_key, app_id, app_name, version, file_name,
                kind, status, bytes_done, total, speed_bps, eta_sec, last_started_at
         FROM download_task
         WHERE module_task_id = ?1",
        [module_task_id],
        |row| {
            Ok(DownloadTaskRow {
                id: row.get(0)?,
                module_task_id: row.get(1)?,
                dedup_key: row.get(2)?,
                app_id: row.get(3)?,
                app_name: row.get(4)?,
                version: row.get(5)?,
                file_name: row.get(6)?,
                kind: row.get(7)?,
                status: row.get(8)?,
                bytes_done: row.get(9)?,
                total: row.get(10)?,
                speed_bps: row.get(11)?,
                eta_sec: row.get(12)?,
                last_started_at: row.get(13)?,
            })
        },
    )
    .optional()
    .map_err(|e| DbError(format!("load task {module_task_id}: {e}")))
}