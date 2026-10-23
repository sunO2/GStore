//! Three-way download resync: legacy Floor DB ↔ download module DB ↔ core mirror.
//!
//! # Report semantics
//!
//! * `floor_rows` / `module_rows` / `core_rows` — row counts of each source.
//! * `matched` — distinct logical keys present in module **and** core, and also
//!   in Floor when a Floor DB is available (three-way intersection).
//! * `missing` — distinct logical keys in exactly one of module/core (the
//!   symmetric-difference count; a key only in Floor is not `missing` because
//!   Floor is a parity oracle).
//! * `updated` — module rows actually upserted; always `0` in dry-run.
//! * `needs_restart` — non-terminal core rows in a needs-restart state. Only a
//!   wholly absent module DB produces this; already-marked rows are counted but
//!   not rewritten, so re-runs stay write-idempotent.
//! * `conflicts` — identity disagreements (see the `parity` submodule).
//! * `snapshot_path` — pre-apply backup; `None` in dry-run.
//!
//! # Conflict rule
//!
//! A run with any conflict returns [`PortError::ResyncConflict`] and writes
//! nothing, even when `apply` is true:
//!
//! 1. a logical key present in core and in module (or Floor) whose **present**
//!    `dedup_key` values differ — a missing key cannot be "different", and the
//!    core value is preserved when only the mirror lacks one;
//! 2. a core row with a non-empty `module_task_id` that the module DB does not
//!    contain while its status is not terminal. Rows without a module id were
//!    never module-backed and are not "absent from the module DB".
//!
//! Terminal for this rule is exactly `completed`, `cancelled`, `removed`,
//! `failed`. A wholly missing module DB is the `needs_restart` path, not a
//! conflict.
//!
//! # Write policy
//!
//! Dry-run opens the module DB `SQLITE_OPEN_READ_ONLY` and performs zero writes.
//! Apply takes a `VACUUM INTO` snapshot under `backups_dir` first, then mirrors
//! module rows and (for a missing module DB) marks core rows in one transaction.
//! Neither path writes a `core_writes` marker: resync is maintenance, not a
//! domain mutation.

mod parity;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, TransactionBehavior};

pub use parity::TERMINAL_STATUSES;

use crate::download::legacy::{self, MappedTask};
use crate::download::port::{upsert_record_targeting, PortError, TaskRecord};
use crate::download::{DownloadTaskRow, NEEDS_RESTART};
use parity::{collect_conflicts, is_terminal, matched_keys, ConflictInputs, LogicalKey, Side};

/// Counters returned by [`run`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ResyncReport {
    pub floor_rows: usize,
    pub module_rows: usize,
    pub core_rows: usize,
    pub matched: usize,
    pub updated: usize,
    pub missing: usize,
    pub conflicts: usize,
    pub needs_restart: usize,
    pub snapshot_path: Option<String>,
}

/// Runs the three-way resync.
///
/// `module_db_path` and `floor_db_path` may be `None` or point at a missing
/// file; both then contribute zero rows. A path that exists but is not a
/// readable database is a [`PortError::Db`] and nothing is written.
pub fn run(
    conn: &mut Connection,
    module_db_path: Option<&Path>,
    floor_db_path: Option<&Path>,
    apply: bool,
    backups_dir: &Path,
) -> Result<ResyncReport, PortError> {
    let module_available = module_db_path.is_some_and(Path::exists);
    let module_tasks = match module_db_path {
        Some(path) if module_available => legacy::read_module_task_rows(path)?,
        _ => Vec::new(),
    };
    let floor_available = floor_db_path.is_some_and(Path::exists);
    let floor_tasks = match floor_db_path {
        Some(path) if floor_available => legacy::read_floor_task_rows(path)?,
        _ => Vec::new(),
    };
    let core_rows =
        crate::download::list_tasks(conn).map_err(|error| PortError::Db(error.to_string()))?;

    let module_side = Side::from_tasks(&module_tasks);
    let core_side = Side::from_rows(&core_rows);
    let floor_side = Side::from_tasks(&floor_tasks);

    let mut report = ResyncReport {
        floor_rows: floor_tasks.len(),
        module_rows: module_tasks.len(),
        core_rows: core_rows.len(),
        matched: matched_keys(
            &module_side,
            &core_side,
            floor_available.then_some(&floor_side),
        ),
        missing: parity::symmetric_key_difference(&module_side, &core_side),
        ..ResyncReport::default()
    };

    let conflicts = collect_conflicts(&ConflictInputs {
        module: &module_side,
        core: &core_side,
        floor: &floor_side,
        floor_available,
        module_available,
        module_tasks: &module_tasks,
        core_rows: &core_rows,
    });
    report.conflicts = conflicts.len();
    if let Some(error) = conflicts.first() {
        return Err(PortError::ResyncConflict(format!(
            "{} conflict(s); nothing written. {error}",
            conflicts.len()
        )));
    }

    if !module_available {
        report.needs_restart = core_rows
            .iter()
            .filter(|row| !is_terminal(&row.status))
            .count();
    }

    if !apply {
        return Ok(report);
    }

    let snapshot = write_snapshot(conn, backups_dir)?;
    report.updated = apply_mirror(conn, &module_tasks, &core_rows, !module_available)?;
    report.snapshot_path = Some(snapshot.to_string_lossy().into_owned());
    Ok(report)
}

fn write_snapshot(conn: &Connection, backups_dir: &Path) -> Result<PathBuf, PortError> {
    std::fs::create_dir_all(backups_dir).map_err(|error| {
        PortError::Db(format!(
            "create resync backup dir {}: {error}",
            backups_dir.display()
        ))
    })?;
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| PortError::Db(format!("resync snapshot clock: {error}")))?
        .as_millis();
    let dest = unique_snapshot_path(backups_dir, millis);
    conn.execute(
        "VACUUM INTO ?1",
        rusqlite::params![dest.to_string_lossy().into_owned()],
    )
    .map_err(|error| PortError::Db(format!("resync snapshot into {}: {error}", dest.display())))?;
    Ok(dest)
}

fn unique_snapshot_path(backups_dir: &Path, millis: u128) -> PathBuf {
    let mut candidate = backups_dir.join(format!("pre-resync-{millis}.db"));
    let mut attempt = 0_u32;
    while candidate.exists() {
        attempt += 1;
        candidate = backups_dir.join(format!("pre-resync-{millis}-{attempt}.db"));
    }
    candidate
}

fn apply_mirror(
    conn: &mut Connection,
    module_tasks: &[MappedTask],
    core_rows: &[DownloadTaskRow],
    mark_needs_restart: bool,
) -> Result<usize, PortError> {
    let mut by_module_id: BTreeMap<String, &DownloadTaskRow> = BTreeMap::new();
    let mut by_key: BTreeMap<LogicalKey, &DownloadTaskRow> = BTreeMap::new();
    for row in core_rows {
        if let Some(id) = row
            .module_task_id
            .as_deref()
            .map(str::trim)
            .filter(|id| !id.is_empty())
        {
            by_module_id.entry(id.to_string()).or_insert(row);
        }
        if let Some(key) = parity::logical_key(
            row.app_id.as_deref(),
            row.version.as_deref(),
            row.file_name.as_deref(),
        ) {
            by_key.entry(key).or_insert(row);
        }
    }

    let now = now_secs();
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| PortError::Db(format!("begin resync transaction: {error}")))?;
    let mut updated = 0_usize;
    for task in module_tasks {
        let Some(mut record) = TaskRecord::from_mapped(task) else {
            continue;
        };
        let key = parity::logical_key(
            task.app_id.as_deref(),
            task.version.as_deref(),
            task.file_name.as_deref(),
        );
        let target = by_module_id
            .get(&record.module_task_id)
            .copied()
            .or_else(|| key.as_ref().and_then(|key| by_key.get(key)).copied());
        if record.dedup_key.is_none() {
            if let Some(core) = target {
                record.dedup_key = core.dedup_key.clone();
            }
        }
        if target.is_some_and(|core| !mirror_differs(core, &record)) {
            continue;
        }
        upsert_record_targeting(&tx, &record, now, target.map(|core| core.id))?;
        updated += 1;
    }
    if mark_needs_restart {
        for row in core_rows {
            if is_terminal(&row.status) || row.status == NEEDS_RESTART {
                continue;
            }
            tx.execute(
                "UPDATE download_task SET status = ?1, updated_at = ?2 WHERE id = ?3",
                rusqlite::params![NEEDS_RESTART, now, row.id],
            )
            .map_err(|error| {
                PortError::Db(format!("mark core row {} needs_restart: {error}", row.id))
            })?;
        }
    }
    tx.commit()
        .map_err(|error| PortError::Db(format!("commit resync transaction: {error}")))?;
    Ok(updated)
}

fn mirror_differs(core: &DownloadTaskRow, record: &TaskRecord) -> bool {
    let text = |current: Option<&str>, next: &str| current.unwrap_or("") != next;
    text(core.module_task_id.as_deref(), &record.module_task_id)
        || core.dedup_key != record.dedup_key
        || text(core.app_id.as_deref(), &record.app_id)
        || text(core.app_name.as_deref(), &record.app_name)
        || text(core.version.as_deref(), &record.version)
        || text(core.file_name.as_deref(), &record.file_name)
        || text(core.kind.as_deref(), &record.kind)
        || text(core.resource_id.as_deref(), &record.resource_id)
        || text(core.resource_version.as_deref(), &record.resource_version)
        || text(core.url.as_deref(), &record.url)
        || text(core.dest_path.as_deref(), &record.dest_path)
        || text(Some(core.status.as_str()), &record.status)
        || core.bytes_done != record.bytes_done
        || core.total != record.total
        || core.speed_bps != record.speed_bps
        || core.eta_sec != record.eta_sec
        || core.last_started_at != record.last_started_at
        || core.expected_sha256 != record.expected_sha256
        || core.install_after_download != record.install_after_download
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs() as i64)
}
