//! Logical-key parity and conflict detection for the three-way resync.
//!
//! The dedup-key spaces do **not** join: the legacy Floor importer derives
//! `legacy:<url>|<dest_path>`, while the module (and Dart) use
//! `app:<app_id>:<version>:<file_name>`. Every comparison here joins on the
//! logical key `(app_id, version, file_name)` (trimmed, exact).
//!
//! Rows missing any logical field cannot be joined; they are counted in the
//! row totals but never in `matched`/`missing`/`conflicts`.

use std::collections::{BTreeMap, BTreeSet};

use crate::download::legacy::MappedTask;
use crate::download::DownloadTaskRow;

/// Terminal statuses for the resync conflict rule.
pub const TERMINAL_STATUSES: [&str; 4] = ["completed", "cancelled", "removed", "failed"];

pub(super) fn is_terminal(status: &str) -> bool {
    TERMINAL_STATUSES.contains(&status)
}

pub(super) type LogicalKey = (String, String, String);

pub(super) fn logical_key(
    app_id: Option<&str>,
    version: Option<&str>,
    file_name: Option<&str>,
) -> Option<LogicalKey> {
    let app_id = app_id?.trim();
    let version = version?.trim();
    let file_name = file_name?.trim();
    if app_id.is_empty() || version.is_empty() || file_name.is_empty() {
        return None;
    }
    Some((
        app_id.to_string(),
        version.to_string(),
        file_name.to_string(),
    ))
}

fn key_label(key: &LogicalKey) -> String {
    format!("({}, {}, {})", key.0, key.1, key.2)
}

#[derive(Debug, Default)]
pub(super) struct Side {
    keys: BTreeSet<LogicalKey>,
    dedup: BTreeMap<LogicalKey, BTreeSet<String>>,
}

impl Side {
    fn add(
        &mut self,
        app_id: Option<&str>,
        version: Option<&str>,
        file_name: Option<&str>,
        dedup_key: Option<&str>,
    ) {
        let Some(key) = logical_key(app_id, version, file_name) else {
            return;
        };
        self.keys.insert(key.clone());
        if let Some(dedup_key) = dedup_key.filter(|key| !key.trim().is_empty()) {
            self.dedup
                .entry(key)
                .or_default()
                .insert(dedup_key.to_string());
        }
    }

    pub(super) fn from_tasks(tasks: &[MappedTask]) -> Self {
        let mut side = Self::default();
        for task in tasks {
            side.add(
                task.app_id.as_deref(),
                task.version.as_deref(),
                task.file_name.as_deref(),
                task.dedup_key.as_deref(),
            );
        }
        side
    }

    pub(super) fn from_rows(rows: &[DownloadTaskRow]) -> Self {
        let mut side = Self::default();
        for row in rows {
            side.add(
                row.app_id.as_deref(),
                row.version.as_deref(),
                row.file_name.as_deref(),
                row.dedup_key.as_deref(),
            );
        }
        side
    }

}

pub(super) fn matched_keys(module: &Side, core: &Side, floor: Option<&Side>) -> usize {
    module
        .keys
        .iter()
        .filter(|key| core.keys.contains(*key) && floor.is_none_or(|side| side.keys.contains(*key)))
        .count()
}

pub(super) fn symmetric_key_difference(module: &Side, core: &Side) -> usize {
    module.keys.symmetric_difference(&core.keys).count()
}

fn dedup_mismatch(
    core: &Side,
    other: &Side,
    other_label: &str,
    key: &LogicalKey,
) -> Option<String> {
    let core_keys = core.dedup.get(key)?;
    let other_keys = other.dedup.get(key)?;
    if core_keys.is_empty() || other_keys.is_empty() || core_keys == other_keys {
        return None;
    }
    let join = |values: &BTreeSet<String>| values.iter().cloned().collect::<Vec<_>>().join(" | ");
    Some(format!(
        "logical key {}: core dedup_key [{}] vs {other_label} dedup_key [{}]",
        key_label(key),
        join(core_keys),
        join(other_keys)
    ))
}

pub(super) struct ConflictInputs<'a> {
    pub(super) module: &'a Side,
    pub(super) core: &'a Side,
    pub(super) floor: &'a Side,
    pub(super) floor_available: bool,
    pub(super) module_available: bool,
    pub(super) module_tasks: &'a [MappedTask],
    pub(super) core_rows: &'a [DownloadTaskRow],
}

pub(super) fn collect_conflicts(inputs: &ConflictInputs<'_>) -> Vec<String> {
    let mut conflicts = Vec::new();
    for key in inputs.module.keys.intersection(&inputs.core.keys) {
        if let Some(detail) = dedup_mismatch(inputs.core, inputs.module, "module", key) {
            conflicts.push(detail);
        }
    }
    if inputs.floor_available {
        for key in inputs.floor.keys.intersection(&inputs.core.keys) {
            if let Some(detail) = dedup_mismatch(inputs.core, inputs.floor, "floor", key) {
                conflicts.push(detail);
            }
        }
    }
    if inputs.module_available {
        let module_ids: BTreeSet<&str> = inputs
            .module_tasks
            .iter()
            .filter_map(|task| task.module_task_id.as_deref())
            .collect();
        for row in inputs.core_rows {
            let Some(id) = row
                .module_task_id
                .as_deref()
                .map(str::trim)
                .filter(|id| !id.is_empty())
            else {
                continue;
            };
            if !module_ids.contains(id) && !is_terminal(&row.status) {
                conflicts.push(format!(
                    "core row {} (module_task_id {id}, status {}) is absent from the module db",
                    row.id, row.status
                ));
            }
        }
    }
    conflicts
}
