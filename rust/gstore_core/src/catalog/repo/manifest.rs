//! Manifest read/write/recovery for the catalog repository.

use std::cmp::Ordering;
use std::fs;
use std::io::Write;
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::store::{is_valid_catalog, now_millis};
use super::types::RepoEntry;
use crate::catalog::refresh::{read_catalog_counts, read_catalog_version};
use crate::error::Error;

pub(super) const MANIFEST_FILE: &str = "manifest.json";
pub(super) const KIND_SEED: &str = "seed";
pub(super) const KIND_REMOTE: &str = "remote";

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(super) struct Manifest {
    #[serde(default)]
    pub current: Option<String>,
    #[serde(default)]
    pub materialized: Option<String>,
    #[serde(default)]
    pub entries: Vec<ManifestEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct ManifestEntry {
    pub file: String,
    pub version: String,
    pub sha256: String,
    #[serde(default)]
    pub source: String,
    pub kind: String,
    #[serde(default)]
    pub added_at: i64,
    #[serde(default)]
    pub apps: usize,
}

impl From<ManifestEntry> for RepoEntry {
    fn from(entry: ManifestEntry) -> Self {
        Self {
            file: entry.file,
            version: entry.version,
            sha256: entry.sha256,
            source: entry.source,
            kind: entry.kind,
            added_at: entry.added_at,
            apps: entry.apps,
        }
    }
}

pub(super) fn upsert_entry(manifest: &mut Manifest, mut entry: ManifestEntry) {
    if let Some(existing) = manifest
        .entries
        .iter_mut()
        .find(|candidate| candidate.file == entry.file)
    {
        entry.added_at = existing.added_at;
        *existing = entry;
    } else {
        manifest.entries.push(entry);
    }
}

pub(super) fn entry_order(a: &ManifestEntry, b: &ManifestEntry) -> Ordering {
    match compare_semver(&a.version, &b.version) {
        Some(Ordering::Equal) | None => a.added_at.cmp(&b.added_at),
        Some(other) => other,
    }
}

pub(super) fn is_newer(
    candidate: &str,
    candidate_added: i64,
    current: &str,
    current_added: i64,
) -> bool {
    match compare_semver(candidate, current) {
        Some(Ordering::Greater) => true,
        Some(_) => false,
        None => candidate_added > current_added,
    }
}

fn compare_semver(a: &str, b: &str) -> Option<Ordering> {
    let left = parse_version(a)?;
    let right = parse_version(b)?;
    for index in 0..left.len().max(right.len()) {
        let x = left.get(index).copied().unwrap_or(0);
        let y = right.get(index).copied().unwrap_or(0);
        match x.cmp(&y) {
            Ordering::Equal => {}
            other => return Some(other),
        }
    }
    Some(Ordering::Equal)
}

fn parse_version(value: &str) -> Option<Vec<u64>> {
    let trimmed = value.trim().trim_start_matches(['v', 'V']);
    if trimmed.is_empty() {
        return None;
    }
    trimmed
        .split('.')
        .map(|part| {
            let digits: String = part.chars().take_while(char::is_ascii_digit).collect();
            if digits.is_empty() {
                None
            } else {
                digits.parse().ok()
            }
        })
        .collect()
}

pub(super) fn manifest_path(root: &Path) -> std::path::PathBuf {
    root.join(MANIFEST_FILE)
}

pub(super) fn load(root: &Path) -> Manifest {
    match fs::read(manifest_path(root)) {
        Ok(bytes) => match serde_json::from_slice(&bytes) {
            Ok(manifest) => manifest,
            Err(error) => {
                log::warn!("CORE_E_CATALOG_REPO_MANIFEST: corrupt, rescanning: {error}");
                rebuild(root)
            }
        },
        Err(error) => {
            if error.kind() != std::io::ErrorKind::NotFound {
                log::warn!("CORE_E_CATALOG_REPO_MANIFEST: unreadable, rescanning: {error}");
            }
            rebuild(root)
        }
    }
}

pub(super) fn save(root: &Path, manifest: &Manifest) -> Result<(), Error> {
    fs::create_dir_all(root).map_err(|e| {
        Error::Io(format!(
            "CORE_E_CATALOG_REPO_MANIFEST: create {}: {e}",
            root.display()
        ))
    })?;
    let tmp = root.join(format!("{MANIFEST_FILE}.tmp"));
    let bytes = serde_json::to_vec_pretty(manifest)
        .map_err(|e| Error::Serialization(format!("CORE_E_CATALOG_REPO_MANIFEST: {e}")))?;
    let mut file = fs::File::create(&tmp).map_err(|e| {
        Error::Io(format!(
            "CORE_E_CATALOG_REPO_MANIFEST: create {}: {e}",
            tmp.display()
        ))
    })?;
    file.write_all(&bytes).map_err(|e| {
        Error::Io(format!(
            "CORE_E_CATALOG_REPO_MANIFEST: write {}: {e}",
            tmp.display()
        ))
    })?;
    drop(file);
    fs::rename(&tmp, manifest_path(root)).map_err(|e| {
        Error::Io(format!(
            "CORE_E_CATALOG_REPO_MANIFEST: rename {}: {e}",
            tmp.display()
        ))
    })
}

fn rebuild(root: &Path) -> Manifest {
    let mut entries = Vec::new();
    for (dir, kind) in [
        (root.join(KIND_SEED), KIND_SEED),
        (root.join(KIND_REMOTE), KIND_REMOTE),
    ] {
        let Ok(read) = fs::read_dir(&dir) else {
            continue;
        };
        for path in read.filter_map(Result::ok).map(|entry| entry.path()) {
            if path.extension().and_then(|ext| ext.to_str()) != Some("db") || !is_valid_catalog(&path)
            {
                continue;
            }
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            let stem = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or_default();
            let (version, sha256) = if kind == KIND_REMOTE {
                stem.rsplit_once('-')
                    .map_or((String::new(), String::new()), |(version, sha)| {
                        (version.to_string(), sha.to_string())
                    })
            } else {
                (
                    read_catalog_version(&path).unwrap_or_default(),
                    stem.to_string(),
                )
            };
            let apps = read_catalog_counts(&path).map_or(0, |(apps, _)| apps);
            entries.push(ManifestEntry {
                file: format!("{kind}/{name}"),
                version,
                sha256,
                source: String::new(),
                kind: kind.to_string(),
                added_at: now_millis(),
                apps,
            });
        }
    }
    entries.sort_by(|a, b| a.file.cmp(&b.file));
    Manifest {
        entries,
        ..Manifest::default()
    }
}
