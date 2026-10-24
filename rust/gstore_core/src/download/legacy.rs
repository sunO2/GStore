//! One-shot imports of the legacy Dart (Floor) and download-module databases.
//!
//! Precedence is always "the core row wins": migration only ever inserts rows
//! that are absent, and at most fills a missing `module_task_id` /
//! `segments_json` on an existing row. Non-null core metadata is never
//! overwritten, so re-running a migration is idempotent and safe after the
//! core has already started updating a task.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::types::Value;
use rusqlite::{Connection, OpenFlags};

use super::port::PortError;

/// Outcome counters of a one-shot migration.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MigrationReport {
    pub inserted: usize,
    pub updated: usize,
    pub skipped: usize,
}

type RowMap = HashMap<String, Value>;

/// Imports the legacy Floor download database into the core `download_task` table.
///
/// The Floor table name is not assumed: the first table exposing a `url` column
/// plus a `filePath`/`file_path` column is used. Both camelCase (Floor) and
/// snake_case spellings are accepted. Missing databases/tables are reported as
/// [`PortError::Db`].
pub fn migrate_legacy_floor_db(
    core: &Connection,
    legacy_path: &Path,
) -> Result<MigrationReport, PortError> {
    let legacy = open_read_only(legacy_path, "legacy floor db")?;
    let table = find_download_table(&legacy, legacy_path)?;
    let rows = read_rows(&legacy, &format!("SELECT * FROM {}", quote_ident(&table)))?;

    let mut report = MigrationReport::default();
    for row in rows {
        let task = map_floor_task(&row);
        let dedup_key = task.dedup_key.clone().ok_or_else(|| {
            PortError::Db(format!("legacy row in {table} has no usable dedup key"))
        })?;
        if find_core_task(core, None, Some(&dedup_key))?.is_some() {
            report.skipped += 1;
            continue;
        }
        insert_task(core, &task)?;
        report.inserted += 1;
    }
    Ok(report)
}

/// Imports the download module's v4 database into the core `download_task` table.
///
/// `download_task` is required; `download_segment` is optional. Module task ids
/// become `module_task_id`, and segment rows are folded into `segments_json`.
/// An existing core row is matched by `module_task_id` or `dedup_key`; it only
/// receives a missing `module_task_id` and/or `segments_json`, and the caller's
/// other metadata is left untouched.
pub fn migrate_module_db(
    core: &Connection,
    module_path: &Path,
) -> Result<MigrationReport, PortError> {
    let module = open_read_only(module_path, "module db")?;
    if !table_exists(&module, "download_task")? {
        return Err(PortError::Db(format!(
            "module db {} has no download_task table",
            module_path.display()
        )));
    }
    let rows = read_rows(&module, "SELECT * FROM \"download_task\"")?;

    let mut report = MigrationReport::default();
    for row in rows {
        let module_id = get_i64(&row, &["id"]);
        let segments_json = match module_id {
            Some(id) => read_segments_json(&module, id)?,
            None => None,
        };
        let task = map_module_task(&row, segments_json);

        let existing = find_core_task(
            core,
            task.module_task_id.as_deref(),
            task.dedup_key.as_deref(),
        )?;
        let Some(existing) = existing else {
            insert_task(core, &task)?;
            report.inserted += 1;
            continue;
        };

        if existing.module_task_id.is_none() {
            core.execute(
                "UPDATE download_task SET
                    module_task_id = ?1,
                    segments_json = COALESCE(segments_json, ?2),
                    updated_at = ?3
                 WHERE id = ?4",
                rusqlite::params![
                    task.module_task_id,
                    task.segments_json,
                    now_secs(),
                    existing.id
                ],
            )
            .map_err(|e| PortError::Db(format!("link module task to core row {}: {e}", existing.id)))?;
            report.updated += 1;
            continue;
        }

        if existing.module_task_id.as_deref() == task.module_task_id.as_deref()
            && existing.segments_json.is_none()
            && task.segments_json.is_some()
        {
            core.execute(
                "UPDATE download_task SET segments_json = ?1, updated_at = ?2 WHERE id = ?3",
                rusqlite::params![task.segments_json, now_secs(), existing.id],
            )
            .map_err(|e| PortError::Db(format!("fill segments for core row {}: {e}", existing.id)))?;
        }
        report.skipped += 1;
    }
    Ok(report)
}

/// One row of a Floor or module database mapped into core column semantics.
///
/// Shared by the one-shot importers ([`migrate_legacy_floor_db`],
/// [`migrate_module_db`]) and the three-way resync reader so both use exactly
/// the same column spellings, status table, and millisecond normalization.
#[derive(Debug)]
pub(crate) struct MappedTask {
    pub(crate) module_task_id: Option<String>,
    pub(crate) dedup_key: Option<String>,
    pub(crate) app_id: Option<String>,
    pub(crate) app_name: Option<String>,
    pub(crate) version: Option<String>,
    pub(crate) file_name: Option<String>,
    pub(crate) kind: Option<String>,
    pub(crate) resource_id: Option<String>,
    pub(crate) resource_version: Option<String>,
    pub(crate) url: Option<String>,
    pub(crate) dest_path: Option<String>,
    pub(crate) status: String,
    pub(crate) bytes_done: i64,
    pub(crate) total: i64,
    pub(crate) speed_bps: i64,
    pub(crate) eta_sec: Option<i64>,
    pub(crate) segments_json: Option<String>,
    pub(crate) retries: i64,
    pub(crate) server_meta: Option<String>,
    pub(crate) priority: i64,
    pub(crate) headers_json: Option<String>,
    pub(crate) expected_sha256: Option<String>,
    pub(crate) install_after_download: bool,
    pub(crate) error: Option<String>,
    pub(crate) last_started_at: Option<i64>,
    pub(crate) created_at: i64,
    pub(crate) updated_at: i64,
}

pub(crate) fn map_floor_task(row: &RowMap) -> MappedTask {
    let url = get_text(row, &["url"]).unwrap_or_default();
    let dest_path = get_text(row, &["filePath", "file_path"]).unwrap_or_default();
    let dedup_key = get_text(row, &["dedup_key", "dedupKey"])
        .unwrap_or_else(|| format!("legacy:{url}|{dest_path}"));

    MappedTask {
        module_task_id: None,
        dedup_key: Some(dedup_key),
        app_id: get_text(row, &["appId", "app_id"]),
        app_name: get_text(row, &["appName", "app_name"]),
        version: get_text(row, &["version"]),
        file_name: get_text(row, &["fileName", "file_name"]),
        kind: get_text(row, &["kind"]).or_else(|| Some("file".to_string())),
        resource_id: get_text(row, &["resourceId", "resource_id"]),
        resource_version: get_text(row, &["resourceVersion", "resource_version"]),
        url: get_text(row, &["url"]),
        dest_path: get_text(row, &["filePath", "file_path"]),
        status: status_text(get_i64(row, &["status"]).unwrap_or_default()),
        bytes_done: get_i64(row, &["received"]).unwrap_or_default(),
        total: get_i64(row, &["total"]).unwrap_or_default(),
        speed_bps: get_i64(row, &["speedBps", "speed_bps"]).unwrap_or_default(),
        eta_sec: get_i64(row, &["etaSec", "eta_sec"]),
        segments_json: get_text(row, &["segments"]),
        retries: get_i64(row, &["retries"]).unwrap_or_default(),
        server_meta: get_text(row, &["serverMeta", "server_meta"]),
        priority: get_i64(row, &["priority"]).unwrap_or_default(),
        headers_json: get_text(row, &["headersJson", "headers_json", "headers"]),
        expected_sha256: get_text(row, &["expectedSha256", "expected_sha256"]),
        install_after_download: get_i64(row, &["installAfterDownload", "install_after_download"])
            .map(|v| v != 0)
            .unwrap_or(false),
        error: get_text(row, &["error"]),
        last_started_at: get_i64(row, &["lastStartedAt", "last_started_at"]).map(to_secs),
        created_at: get_i64(row, &["createdAt", "created_at"]).map(to_secs).unwrap_or_default(),
        updated_at: get_i64(row, &["updatedAt", "updated_at"]).map(to_secs).unwrap_or_default(),
    }
}

pub(crate) fn map_module_task(row: &RowMap, segments_json: Option<String>) -> MappedTask {
    MappedTask {
        module_task_id: get_i64(row, &["id"]).map(|id| id.to_string()),
        dedup_key: get_text(row, &["dedup_key", "dedupKey"]),
        app_id: get_text(row, &["app_id", "appId"]),
        app_name: get_text(row, &["app_name", "appName"]),
        version: get_text(row, &["version"]),
        file_name: get_text(row, &["file_name", "fileName"]),
        kind: get_text(row, &["kind"]).or_else(|| Some("file".to_string())),
        resource_id: get_text(row, &["resource_id", "resourceId"]),
        resource_version: get_text(row, &["resource_version", "resourceVersion"]),
        url: get_text(row, &["url"]),
        dest_path: get_text(row, &["file_path", "filePath"]),
        status: status_text(get_i64(row, &["status"]).unwrap_or(5)),
        bytes_done: get_i64(row, &["received"]).unwrap_or_default(),
        total: get_i64(row, &["total"]).unwrap_or_default(),
        speed_bps: get_i64(row, &["speed_bps", "speedBps"]).unwrap_or_default(),
        eta_sec: get_i64(row, &["eta_sec", "etaSec"]),
        segments_json,
        retries: get_i64(row, &["retries"]).unwrap_or_default(),
        server_meta: get_text(row, &["server_meta", "serverMeta"]),
        priority: get_i64(row, &["priority"]).unwrap_or_default(),
        headers_json: get_text(row, &["headers_json", "headersJson", "headers"]),
        expected_sha256: get_text(row, &["expected_sha256", "expectedSha256"]),
        install_after_download: get_i64(row, &["install_after_download", "installAfterDownload"])
            .map(|v| v != 0)
            .unwrap_or(false),
        error: get_text(row, &["error"]),
        last_started_at: get_i64(row, &["last_started_at", "lastStartedAt"]).map(to_secs),
        created_at: get_i64(row, &["created_at", "createdAt"]).map(to_secs).unwrap_or_default(),
        updated_at: get_i64(row, &["updated_at", "updatedAt"]).map(to_secs).unwrap_or_default(),
    }
}

/// Module status ints come from `TaskStatus::from_i32`: queued/connecting/
/// downloading (0/1/2) are active and map to `running`; paused=3, completed=4,
/// failed=5, cancelled=6; anything else falls back to `failed`.
fn status_text(code: i64) -> String {
    match code {
        0..=2 => "running",
        3 => "paused",
        4 => "completed",
        5 => "failed",
        6 => "cancelled",
        _ => "failed",
    }
    .to_string()
}

/// Reads every Floor task row read-only, using the same table discovery and
/// mapping as [`migrate_legacy_floor_db`] but never writing anything.
///
/// A present-but-unreadable Floor database is an error; a missing one is the
/// caller's decision and must be handled before calling this.
pub(crate) fn read_floor_task_rows(floor_path: &Path) -> Result<Vec<MappedTask>, PortError> {
    let floor = open_read_only(floor_path, "legacy floor db")?;
    let table = find_download_table(&floor, floor_path)?;
    let rows = read_rows(&floor, &format!("SELECT * FROM {}", quote_ident(&table)))?;
    Ok(rows.iter().map(map_floor_task).collect())
}

/// Reads every download-module task row read-only with the importer's mapping,
/// folding each task's `download_segment` rows into `segments_json`.
///
/// This is the live fold: a module task's block list must reach the core row so
/// the detail sheet can draw it. A missing `download_task` table is an error.
///
/// Performance: the fold runs on every reconcile sweep. Rather than one segment
/// query per module row per tick, a single `DISTINCT task_id` scan yields the
/// tasks that actually own segment rows, and only those pay the per-task read.
/// Tasks with no block list cost zero extra queries and stay `None`.
pub(crate) fn read_module_task_rows(module_path: &Path) -> Result<Vec<MappedTask>, PortError> {
    let module = open_read_only(module_path, "module db")?;
    if !table_exists(&module, "download_task")? {
        return Err(PortError::Db(format!(
            "module db {} has no download_task table",
            module_path.display()
        )));
    }
    let rows = read_rows(&module, "SELECT * FROM \"download_task\"")?;
    let segmented = segmented_task_ids(&module)?;
    let mut tasks = Vec::with_capacity(rows.len());
    for row in &rows {
        let segments_json = match get_i64(row, &["id"]) {
            Some(id) if segmented.contains(&id) => read_segments_json(&module, id)?,
            _ => None,
        };
        tasks.push(map_module_task(row, segments_json));
    }
    Ok(tasks)
}

/// Task ids that currently own at least one `download_segment` row.
///
/// One `DISTINCT` scan bounds the live fold's per-task segment reads to the
/// tasks that actually have a block list, instead of every module row.
fn segmented_task_ids(conn: &Connection) -> Result<HashSet<i64>, PortError> {
    if !table_exists(conn, "download_segment")? {
        return Ok(HashSet::new());
    }
    let mut stmt = conn
        .prepare("SELECT DISTINCT task_id FROM download_segment")
        .map_err(|e| PortError::Db(format!("prepare segmented task ids: {e}")))?;
    let ids = stmt
        .query_map([], |row| row.get::<_, i64>(0))
        .map_err(|e| PortError::Db(format!("query segmented task ids: {e}")))?
        .collect::<Result<HashSet<_>, _>>()
        .map_err(|e| PortError::Db(format!("read segmented task ids: {e}")))?;
    Ok(ids)
}

struct CoreLink {
    id: i64,
    module_task_id: Option<String>,
    segments_json: Option<String>,
}

fn find_core_task(
    conn: &Connection,
    module_task_id: Option<&str>,
    dedup_key: Option<&str>,
) -> Result<Option<CoreLink>, PortError> {
    if let Some(module_task_id) = module_task_id {
        if let Some(link) = query_core_link(conn, "module_task_id", module_task_id)? {
            return Ok(Some(link));
        }
    }
    if let Some(dedup_key) = dedup_key {
        return query_core_link(conn, "dedup_key", dedup_key);
    }
    Ok(None)
}

fn query_core_link(
    conn: &Connection,
    column: &str,
    value: &str,
) -> Result<Option<CoreLink>, PortError> {
    use rusqlite::OptionalExtension;
    let sql = format!(
        "SELECT id, module_task_id, segments_json FROM download_task WHERE {column} = ?1"
    );
    conn.query_row(&sql, [value], |row| {
        Ok(CoreLink {
            id: row.get(0)?,
            module_task_id: row.get(1)?,
            segments_json: row.get(2)?,
        })
    })
    .optional()
    .map_err(|e| PortError::Db(format!("lookup core task {column}={value}: {e}")))
}

const INSERT_TASK_SQL: &str = "INSERT INTO download_task (
        module_task_id, dedup_key, app_id, app_name, version, file_name, kind,
        resource_id, resource_version, url, dest_path, status, bytes_done, total,
        speed_bps, eta_sec, segments_json, retries, server_meta, priority, headers_json,
        expected_sha256, install_after_download, error, last_started_at, created_at, updated_at
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16,
              ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27)";

fn insert_task(conn: &Connection, task: &MappedTask) -> Result<(), PortError> {
    conn.execute(
        INSERT_TASK_SQL,
        rusqlite::params![
            task.module_task_id,
            task.dedup_key,
            task.app_id,
            task.app_name,
            task.version,
            task.file_name,
            task.kind,
            task.resource_id,
            task.resource_version,
            task.url,
            task.dest_path,
            task.status,
            task.bytes_done,
            task.total,
            task.speed_bps,
            task.eta_sec,
            task.segments_json,
            task.retries,
            task.server_meta,
            task.priority,
            task.headers_json,
            task.expected_sha256,
            i64::from(task.install_after_download),
            task.error,
            task.last_started_at,
            task.created_at,
            task.updated_at,
        ],
    )
    .map(|_| ())
    .map_err(|e| {
        PortError::Db(format!(
            "insert migrated task {}: {e}",
            task.module_task_id.as_deref().unwrap_or("<legacy>")
        ))
    })
}

/// Reads a task's `download_segment` rows as the JSON snapshot stored in the
/// core `download_task.segments_json` column.
///
/// Keys match the Dart consumer (`SegmentInfo.fromMap`: `index` / `startByte` /
/// `endByte` / `received`), so a written snapshot renders without a second
/// translation. A task with no segment rows is `None`, never `[]`: an empty
/// array would masquerade as a real (empty) block list and defeat the sheet's
/// `segs.isNotEmpty` guard.
fn read_segments_json(conn: &Connection, task_id: i64) -> Result<Option<String>, PortError> {
    if !table_exists(conn, "download_segment")? {
        return Ok(None);
    }
    let mut stmt = conn
        .prepare(
            "SELECT idx, start_byte, end_byte, received
             FROM download_segment WHERE task_id = ?1 ORDER BY idx ASC",
        )
        .map_err(|e| PortError::Db(format!("prepare segments for task {task_id}: {e}")))?;
    let rows = stmt
        .query_map([task_id], |row| {
            Ok(serde_json::json!({
                "index": row.get::<_, i64>(0)?,
                "startByte": row.get::<_, i64>(1)?,
                "endByte": row.get::<_, i64>(2)?,
                "received": row.get::<_, i64>(3)?,
            }))
        })
        .map_err(|e| PortError::Db(format!("query segments for task {task_id}: {e}")))?;
    let segments = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| PortError::Db(format!("read segments for task {task_id}: {e}")))?;
    if segments.is_empty() {
        return Ok(None);
    }
    serde_json::to_string(&segments)
        .map(Some)
        .map_err(|e| PortError::Db(format!("encode segments for task {task_id}: {e}")))
}

pub(crate) fn open_read_only(path: &Path, label: &str) -> Result<Connection, PortError> {
    if !path.exists() {
        return Err(PortError::Db(format!(
            "{label} not found: {}",
            path.display()
        )));
    }
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| PortError::Db(format!("open {label} {}: {e}", path.display())))
}

pub(crate) fn find_download_table(conn: &Connection, path: &Path) -> Result<String, PortError> {
    let mut stmt = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .map_err(|e| PortError::Db(format!("list tables in {}: {e}", path.display())))?;
    let names = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|e| PortError::Db(format!("query tables in {}: {e}", path.display())))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| PortError::Db(format!("read tables in {}: {e}", path.display())))?;

    for name in names {
        let columns = table_columns(conn, &name)?;
        let has_url = columns.iter().any(|c| c == "url");
        let has_dest = columns.iter().any(|c| c == "filepath" || c == "file_path");
        if has_url && has_dest {
            return Ok(name);
        }
    }
    Err(PortError::Db(format!(
        "no download table (url + filePath/file_path) in {}",
        path.display()
    )))
}

pub(crate) fn table_exists(conn: &Connection, name: &str) -> Result<bool, PortError> {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
        [name],
        |row| row.get::<_, i64>(0),
    )
    .map(|found| found != 0)
    .map_err(|e| PortError::Db(format!("table_exists {name}: {e}")))
}

fn table_columns(conn: &Connection, table: &str) -> Result<Vec<String>, PortError> {
    let sql = format!("PRAGMA table_info({})", quote_ident(table));
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| PortError::Db(format!("describe table {table}: {e}")))?;
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| PortError::Db(format!("query columns of {table}: {e}")))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| PortError::Db(format!("read columns of {table}: {e}")))?;
    Ok(columns.iter().map(|c| c.to_ascii_lowercase()).collect())
}

pub(crate) fn read_rows(conn: &Connection, sql: &str) -> Result<Vec<RowMap>, PortError> {
    let mut stmt = conn
        .prepare(sql)
        .map_err(|e| PortError::Db(format!("prepare {sql}: {e}")))?;
    let names = stmt
        .column_names()
        .iter()
        .map(|name| name.to_ascii_lowercase())
        .collect::<Vec<_>>();
    let mut rows = stmt
        .query([])
        .map_err(|e| PortError::Db(format!("query {sql}: {e}")))?;
    let mut out = Vec::new();
    while let Some(row) = rows
        .next()
        .map_err(|e| PortError::Db(format!("read row from {sql}: {e}")))?
    {
        let mut map = RowMap::new();
        for (index, name) in names.iter().enumerate() {
            let value: Value = row
                .get(index)
                .map_err(|e| PortError::Db(format!("read column {name}: {e}")))?;
            map.insert(name.clone(), value);
        }
        out.push(map);
    }
    Ok(out)
}

pub(crate) fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn get<'a>(row: &'a RowMap, names: &[&str]) -> Option<&'a Value> {
    names
        .iter()
        .filter_map(|name| row.get(&name.to_ascii_lowercase()))
        .find(|value| !matches!(value, Value::Null))
}

fn get_text(row: &RowMap, names: &[&str]) -> Option<String> {
    match get(row, names)? {
        Value::Text(text) if !text.is_empty() => Some(text.clone()),
        Value::Integer(value) => Some(value.to_string()),
        Value::Real(value) => Some(value.to_string()),
        _ => None,
    }
}

fn get_i64(row: &RowMap, names: &[&str]) -> Option<i64> {
    match get(row, names)? {
        Value::Integer(value) => Some(*value),
        Value::Real(value) => Some(*value as i64),
        Value::Text(text) => text.parse().ok(),
        _ => None,
    }
}

/// Millisecond timestamps (Floor and the download module) are normalized to the
/// core's seconds so mixed imports sort consistently.
fn to_secs(value: i64) -> i64 {
    if value.unsigned_abs() >= 1_000_000_000_000 {
        value / 1000
    } else {
        value
    }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let n = COUNTER.fetch_add(1, Ordering::SeqCst);
            let dir = std::env::temp_dir().join(format!(
                "gstore_core_legacy_{}_{}_{}",
                std::process::id(),
                tag,
                n
            ));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
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

    #[test]
    fn download_legacy_and_reconcile_floor_and_module_db() {
        let dir = TempDir::new("floor_module");
        let mut core = Connection::open_in_memory().unwrap();
        crate::migration::apply_core_schema(&mut core).unwrap();

        let url = "https://example.test/app.apk";
        let dest = "/storage/emulated/0/Download/app.apk";
        let expected_dedup = format!("legacy:{url}|{dest}");

        let floor_path = dir.path().join("download_task.db");
        {
            let floor = Connection::open(&floor_path).unwrap();
            floor
                .execute_batch(
                    "CREATE TABLE download_task_entity (
                        id          INTEGER PRIMARY KEY AUTOINCREMENT,
                        appId       TEXT NOT NULL,
                        appName     TEXT NOT NULL,
                        version     TEXT NOT NULL,
                        fileName    TEXT NOT NULL,
                        url         TEXT NOT NULL,
                        filePath    TEXT NOT NULL,
                        total       INTEGER NOT NULL,
                        received    INTEGER NOT NULL,
                        status      INTEGER NOT NULL,
                        speedBps    INTEGER NOT NULL,
                        etaSec      INTEGER,
                        error       TEXT,
                        segments    TEXT,
                        createdAt   INTEGER NOT NULL,
                        updatedAt   INTEGER NOT NULL
                    );",
                )
                .unwrap();
            floor
                .execute(
                    "INSERT INTO download_task_entity
                     (appId, appName, version, fileName, url, filePath, total, received,
                      status, speedBps, etaSec, error, segments, createdAt, updatedAt)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL, NULL, ?12, ?13)",
                    rusqlite::params![
                        "com.example.app",
                        "Example",
                        "1.2.3",
                        "app.apk",
                        url,
                        dest,
                        10_000i64,
                        4_096i64,
                        2i64,
                        2048i64,
                        3i64,
                        1_700_000_000_000i64,
                        1_700_000_001_000i64,
                    ],
                )
                .unwrap();
        }

        let report = migrate_legacy_floor_db(&core, &floor_path).unwrap();
        assert_eq!(
            report,
            MigrationReport {
                inserted: 1,
                updated: 0,
                skipped: 0
            }
        );

        let (dedup_key, module_id, app_name, status, created_at): (
            Option<String>,
            Option<String>,
            Option<String>,
            String,
            i64,
        ) = core
            .query_row(
                "SELECT dedup_key, module_task_id, app_name, status, created_at
                 FROM download_task",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
            )
            .unwrap();
        assert_eq!(dedup_key.as_deref(), Some(expected_dedup.as_str()));
        assert_eq!(module_id, None);
        assert_eq!(app_name.as_deref(), Some("Example"));
        assert_eq!(status, "running");
        assert_eq!(created_at, 1_700_000_000, "Floor milliseconds become seconds");

        let rerun = migrate_legacy_floor_db(&core, &floor_path).unwrap();
        assert_eq!(
            rerun,
            MigrationReport {
                inserted: 0,
                updated: 0,
                skipped: 1
            },
            "re-running the Floor migration must be idempotent"
        );

        let module_path = dir.path().join("download_module.db");
        {
            let module = Connection::open(&module_path).unwrap();
            module
                .execute_batch(
                    "CREATE TABLE download_task (
                        id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                        app_id                TEXT NOT NULL,
                        app_name              TEXT NOT NULL,
                        version               TEXT NOT NULL,
                        file_name             TEXT NOT NULL,
                        url                   TEXT NOT NULL,
                        file_path             TEXT NOT NULL,
                        total                 INTEGER NOT NULL DEFAULT 0,
                        received              INTEGER NOT NULL DEFAULT 0,
                        status                INTEGER NOT NULL,
                        speed_bps             INTEGER NOT NULL DEFAULT 0,
                        eta_sec               INTEGER,
                        error                 TEXT,
                        fail_kind             TEXT,
                        retries               INTEGER NOT NULL DEFAULT 0,
                        server_meta           TEXT,
                        expected_sha256       TEXT,
                        actual_sha256         TEXT,
                        priority              INTEGER NOT NULL DEFAULT 0,
                        queue_reason          TEXT,
                        created_at            INTEGER NOT NULL,
                        updated_at            INTEGER NOT NULL,
                        dedup_key             TEXT NOT NULL DEFAULT '',
                        kind                  TEXT NOT NULL DEFAULT 'file',
                        resource_id           TEXT NOT NULL DEFAULT '',
                        resource_version      TEXT NOT NULL DEFAULT '',
                        install_after_download INTEGER NOT NULL DEFAULT 0,
                        last_started_at       INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE TABLE download_segment (
                        task_id    INTEGER NOT NULL,
                        idx        INTEGER NOT NULL,
                        start_byte INTEGER NOT NULL,
                        end_byte   INTEGER NOT NULL,
                        received   INTEGER NOT NULL DEFAULT 0,
                        done       INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY (task_id, idx)
                    );",
                )
                .unwrap();
            module
                .execute(
                    "INSERT INTO download_task
                     (id, app_id, app_name, version, file_name, url, file_path, total, received,
                      status, speed_bps, eta_sec, retries, server_meta, expected_sha256, priority,
                      created_at, updated_at, dedup_key, kind, resource_id, resource_version,
                      install_after_download, last_started_at)
                     VALUES (7, ?1, 'Example', '1.2.3', 'app.apk', ?2, ?3, 10000, 10000,
                             2, 0, NULL, 2, '{\"etag\":\"abc\"}', 'sha-abc', 4,
                             ?4, ?5, ?6, 'app', 'com.example.app', '1.2.3', 1, ?4)",
                    rusqlite::params![
                        "com.example.app",
                        url,
                        dest,
                        1_700_000_002_000i64,
                        1_700_000_003_000i64,
                        expected_dedup,
                    ],
                )
                .unwrap();
            module
                .execute(
                    "INSERT INTO download_segment (task_id, idx, start_byte, end_byte, received, done)
                     VALUES (7, 0, 0, 10000, 10000, 1)",
                    [],
                )
                .unwrap();
        }

        let module_report = migrate_module_db(&core, &module_path).unwrap();
        assert_eq!(
            module_report,
            MigrationReport {
                inserted: 0,
                updated: 1,
                skipped: 0
            },
            "the module task must link onto the existing legacy dedup row"
        );

        let linked = crate::download::load_task(&core, "7").unwrap().unwrap();
        assert_eq!(linked.dedup_key.as_deref(), Some(expected_dedup.as_str()));
        assert_eq!(linked.module_task_id.as_deref(), Some("7"));
        assert_eq!(linked.app_name.as_deref(), Some("Example"));
        assert_eq!(linked.retries, 0, "core metadata must not be overwritten");
        assert_eq!(
            linked.status, "running",
            "module status must not overwrite the core row status"
        );
        let segments: Vec<serde_json::Value> =
            serde_json::from_str(linked.segments_json.as_deref().unwrap()).unwrap();
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0]["index"], 0);
        assert_eq!(segments[0]["startByte"], 0);
        assert_eq!(segments[0]["endByte"], 10000);
        assert_eq!(segments[0]["received"], 10000);

        let module_rerun = migrate_module_db(&core, &module_path).unwrap();
        assert_eq!(
            module_rerun,
            MigrationReport {
                inserted: 0,
                updated: 0,
                skipped: 1
            },
            "re-running the module migration must be idempotent"
        );

        let rows: i64 = core
            .query_row("SELECT COUNT(*) FROM download_task", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rows, 1, "migration must never duplicate the task");
    }

    #[test]
    fn download_legacy_and_reconcile_absent_table_is_db_error() {
        let dir = TempDir::new("absent_table");
        let mut core = Connection::open_in_memory().unwrap();
        crate::migration::apply_core_schema(&mut core).unwrap();

        let empty_path = dir.path().join("empty.db");
        Connection::open(&empty_path).unwrap();

        let err = migrate_legacy_floor_db(&core, &empty_path)
            .expect_err("a database without a download table must be rejected");
        assert!(
            matches!(err, PortError::Db(ref msg) if msg.contains("no download table")),
            "unexpected error: {err:?}"
        );

        let missing_path = dir.path().join("missing.db");
        let err = migrate_legacy_floor_db(&core, &missing_path)
            .expect_err("a missing database must be rejected");
        assert!(
            matches!(err, PortError::Db(ref msg) if msg.contains("not found")),
            "unexpected error: {err:?}"
        );

        let module_path = dir.path().join("module_without_task.db");
        Connection::open(&module_path).unwrap();
        let err = migrate_module_db(&core, &module_path)
            .expect_err("a module db without download_task must be rejected");
        assert!(
            matches!(err, PortError::Db(ref msg) if msg.contains("no download_task")),
            "unexpected error: {err:?}"
        );
    }
}
