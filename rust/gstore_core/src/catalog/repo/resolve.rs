//! Current-database resolution and entry version lookup.

use std::cmp::Ordering;
use std::fs;
use std::path::{Path, PathBuf};

use super::manifest::{entry_order, Manifest, ManifestEntry, KIND_SEED};
use super::store::is_valid_catalog;
use crate::catalog::refresh::read_catalog_version;

pub(super) fn entry_version(manifest: &Manifest, rel: &str, path: &Path) -> String {
    manifest
        .entries
        .iter()
        .find(|entry| entry.file == rel)
        .map(|entry| entry.version.clone())
        .or_else(|| read_catalog_version(path).ok())
        .unwrap_or_default()
}

pub(super) fn resolve_current(root: &Path, manifest: &Manifest) -> Option<(String, PathBuf)> {
    if let Some(rel) = &manifest.current {
        let path = root.join(rel);
        if is_valid_catalog(&path) {
            return Some((rel.clone(), path));
        }
    }
    let mut best: Option<(&ManifestEntry, PathBuf)> = None;
    for entry in &manifest.entries {
        let path = root.join(&entry.file);
        if !is_valid_catalog(&path) {
            continue;
        }
        if best
            .as_ref()
            .is_none_or(|(current, _)| entry_order(entry, current) == Ordering::Greater)
        {
            best = Some((entry, path));
        }
    }
    if let Some((entry, path)) = best {
        return Some((entry.file.clone(), path));
    }
    scan_seeds(root)
}

fn scan_seeds(root: &Path) -> Option<(String, PathBuf)> {
    let mut seeds: Vec<PathBuf> = fs::read_dir(root.join(KIND_SEED))
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("db"))
        .collect();
    seeds.sort();
    for path in seeds {
        if is_valid_catalog(&path) {
            let name = path.file_name()?.to_str()?;
            return Some((format!("{KIND_SEED}/{name}"), path));
        }
    }
    None
}
