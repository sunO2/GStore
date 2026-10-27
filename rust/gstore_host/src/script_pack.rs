//! Local pack reading + diagnostics for `ScriptApi`.
//!
//! Everything here is pure filesystem/`PackStore` work: resolve the channel key
//! from the caller's `expected_key`, read the installed script files, and render
//! the FRB-facing [`ScriptPackInfo`]. No JS runtime is involved.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::channel::{InstalledPack, PackError, PackStore};
use gstore_core::dto::ChannelKey;
use serde_json::{Map, Value as JsonValue};

static TEMP_SEQ: AtomicU64 = AtomicU64::new(0);

/// Diagnostics/inspection view of one installed script pack.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScriptPackInfo {
    /// Channel key (`js_<stem>`).
    pub key: String,
    /// `meta.json` name, or the key when absent.
    pub name: String,
    /// `meta.json` description, or an empty string.
    pub description: String,
    /// `meta.json` icon path, or an empty string.
    pub icon: String,
    /// Whether the pack carries a non-empty `detail.js`.
    pub has_detail: bool,
}

/// Script sources + metadata read from an installed pack.
pub(crate) struct LoadedPack {
    pub entry_js: String,
    pub detail_js: Option<String>,
}

pub(crate) fn load(store: &PackStore, key: &ChannelKey) -> Result<LoadedPack, String> {
    let (_hash, _installed_at, dir) = store
        .installed_pack(key)
        .map_err(|error| pack_err(&error))?;
    let _meta = read_meta(&dir)?;
    let entry_js = read_script(&dir.join("entry.js"))?
        .ok_or_else(|| format!("pack_missing_entry: installed pack `{key}` has no entry.js"))?;
    let detail_js = read_script(&dir.join("detail.js"))?;
    Ok(LoadedPack {
        entry_js,
        detail_js,
    })
}

pub(crate) fn info(store: &PackStore, key: &ChannelKey) -> Result<ScriptPackInfo, String> {
    let (_hash, _installed_at, dir) = store
        .installed_pack(key)
        .map_err(|error| pack_err(&error))?;
    let meta = read_meta(&dir)?;
    Ok(info_from_parts(key.as_str(), &meta, &dir))
}

pub(crate) fn info_from_installed(installed: &InstalledPack) -> ScriptPackInfo {
    let has_detail = installed
        .pack
        .detail_js
        .as_ref()
        .is_some_and(|script| !script.trim().is_empty());
    let field = |name: &str| {
        installed
            .pack
            .meta_json
            .get(name)
            .and_then(JsonValue::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    let key = installed.key.as_str().to_owned();
    let name = field("name");
    ScriptPackInfo {
        key: key.clone(),
        name: if name.is_empty() { key } else { name },
        description: field("description"),
        icon: field("icon"),
        has_detail,
    }
}

/// Resolves the file stem for `PackStore::import_pack` (the store derives the
/// channel key as `js_<stem>`). A missing `expected_key` uses a stable content
/// hash so re-importing the same bytes is idempotent.
pub(crate) fn resolve_stem(expected_key: Option<&str>, bytes: &[u8]) -> Result<String, String> {
    match expected_key
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(raw) => {
            let stem = raw.strip_prefix("js_").unwrap_or(raw);
            if !valid_stem(stem) {
                return Err(format!(
                    "invalid_argument: expected_key must be `js_<stem>` with stem matching \
                     ^[a-zA-Z_][a-zA-Z0-9_]*$ (got {raw:?})"
                ));
            }
            Ok(stem.to_owned())
        }
        None => {
            let mut hasher = DefaultHasher::new();
            bytes.hash(&mut hasher);
            Ok(format!("pack_{:016x}", hasher.finish()))
        }
    }
}

/// Unique temp directory for the bytes-to-path bridge (`PackStore` reads a zip
/// path; `ScriptApi.import` receives bytes).
pub(crate) fn temp_dir(tag: &str) -> PathBuf {
    let seq = TEMP_SEQ.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("gstore-script-{tag}-{}-{seq}", std::process::id()))
}

pub(crate) fn pack_err(error: &PackError) -> String {
    format!("{}: {}", error.code(), error.message())
}

fn valid_stem(stem: &str) -> bool {
    let mut chars = stem.chars();
    matches!(chars.next(), Some(first) if first.is_ascii_alphabetic() || first == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn read_meta(dir: &Path) -> Result<Map<String, JsonValue>, String> {
    let path = dir.join("meta.json");
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return Ok(Map::new());
    };
    if raw.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<JsonValue>(&raw) {
        Ok(JsonValue::Object(map)) => Ok(map),
        Ok(_) => Ok(Map::new()),
        // Parity with Dart `ChannelPackage._parseMeta`: `meta.json` is optional
        // and opaque, so a malformed one is ignored, never fatal. A hard error
        // here made `ScriptApi.list` fail wholesale, hiding every installed
        // channel from the UI even though the pack imported fine.
        Err(error) => {
            log::warn!(
                "pack: ignoring malformed meta.json at {}: {error}",
                path.display()
            );
            Ok(Map::new())
        }
    }
}

fn read_script(path: &Path) -> Result<Option<String>, String> {
    match std::fs::read_to_string(path) {
        Ok(source) => Ok((!source.trim().is_empty()).then_some(source)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("io: read {}: {error}", path.display())),
    }
}

fn info_from_parts(key: &str, meta: &Map<String, JsonValue>, dir: &Path) -> ScriptPackInfo {
    let field = |name: &str| {
        meta.get(name)
            .and_then(JsonValue::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    let name = field("name");
    ScriptPackInfo {
        key: key.to_owned(),
        name: if name.is_empty() {
            key.to_owned()
        } else {
            name
        },
        description: field("description"),
        icon: field("icon"),
        has_detail: dir.join("detail.js").is_file(),
    }
}
