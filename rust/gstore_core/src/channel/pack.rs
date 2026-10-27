//! Local channel-pack types.
//!
//! A pack is the in-memory form of a legacy flat zip:
//! `entry.js` (required), optional `detail.js`, optional `meta.json`, and
//! optional `icons/` bytes or on-disk paths. v2-style metadata is tolerated as
//! plain JSON, but this type deliberately has **no** signature, trust-root,
//! verification, or consent field. Zip decoding and path-traversal checks are
//! Todo 9; this module only validates the assembled pack.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::dto::ChannelKey;
use crate::error::Error;

/// Where a pack icon comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PackIconSource {
    /// Icon bytes embedded in the pack.
    Bytes(Vec<u8>),
    /// Icon path on the local filesystem.
    Path(PathBuf),
}

/// A validated local channel pack.
#[derive(Debug, Clone, PartialEq)]
pub struct ChannelPack {
    /// Stable pack/channel identity.
    pub key: ChannelKey,
    /// Discovery-page script (`entry.js`); required by the flat-pack format.
    pub entry_js: String,
    /// Detail-page script (`detail.js`), when present.
    pub detail_js: Option<String>,
    /// Validated `meta.json` object (empty when the file is absent).
    ///
    /// Kept as JSON rather than a frozen struct so legacy and v2-style metadata
    /// both round-trip without adding a trust surface.
    pub meta_json: serde_json::Map<String, serde_json::Value>,
    /// Embedded icons keyed by pack-relative name (`icons/<name>`).
    pub icons: BTreeMap<String, PackIconSource>,
    /// Environment variables the pack needs; parsed from `meta.json`.
    pub required_env_vars: Vec<String>,
}

impl ChannelPack {
    /// Assembles and validates a local pack.
    ///
    /// `meta_json` is optional. Malformed JSON is a typed
    /// [`Error::Serialization`]; a non-object document or malformed
    /// `requiredEnvVars` is [`Error::InvalidArgument`]. Nothing panics.
    pub fn new(
        key: ChannelKey,
        entry_js: impl Into<String>,
        detail_js: Option<String>,
        meta_json: Option<&str>,
        icons: BTreeMap<String, PackIconSource>,
    ) -> Result<Self, Error> {
        validate_channel_key(&key)?;
        let meta_json = parse_meta(meta_json)?;
        let required_env_vars = parse_required_env_vars(&meta_json)?;
        Ok(Self {
            key,
            entry_js: entry_js.into(),
            detail_js,
            meta_json,
            icons,
            required_env_vars,
        })
    }

    /// Builds a legacy flat pack (`entry.js`/`detail.js`/`meta.json` at root).
    pub fn from_legacy(
        key: ChannelKey,
        entry_js: impl Into<String>,
        detail_js: Option<String>,
        meta_json: Option<&str>,
        icons: BTreeMap<String, PackIconSource>,
    ) -> Result<Self, Error> {
        Self::new(key, entry_js, detail_js, meta_json, icons)
    }

    /// Looks up an embedded icon by pack-relative name.
    pub fn icon(&self, name: &str) -> Option<&PackIconSource> {
        self.icons.get(name)
    }
}

/// Validates a pack/registry channel key.
///
/// The key must be non-empty, contain no surrounding whitespace or `..`, start
/// with an ASCII alphanumeric or `_`, and use only ASCII alphanumerics plus
/// `_`, `-`, and `.`. This keeps `js_<file>` identities stable and prevents a
/// key from being reused as an escaping path segment.
pub fn validate_channel_key(key: &ChannelKey) -> Result<(), Error> {
    let raw = key.as_str();
    if raw.is_empty() {
        return Err(Error::InvalidArgument(
            "channel key must not be empty".to_string(),
        ));
    }
    if raw.trim() != raw {
        return Err(Error::InvalidArgument(format!(
            "channel key must not have surrounding whitespace: {raw:?}"
        )));
    }
    if raw.contains("..") {
        return Err(Error::InvalidArgument(format!(
            "channel key must not contain '..': {raw}"
        )));
    }
    if !raw
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
        || !raw
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
    {
        return Err(Error::InvalidArgument(format!(
            "channel key contains invalid characters: {raw}"
        )));
    }
    Ok(())
}

fn parse_meta(raw: Option<&str>) -> Result<serde_json::Map<String, serde_json::Value>, Error> {
    let Some(raw) = raw else {
        return Ok(serde_json::Map::new());
    };
    if raw.trim().is_empty() {
        return Ok(serde_json::Map::new());
    }
    let value: serde_json::Value = serde_json::from_str(raw).map_err(Error::from)?;
    match value {
        serde_json::Value::Object(map) => Ok(map),
        _ => Err(Error::InvalidArgument(
            "meta.json must be a JSON object".to_string(),
        )),
    }
}

fn parse_required_env_vars(
    meta: &serde_json::Map<String, serde_json::Value>,
) -> Result<Vec<String>, Error> {
    match meta.get("requiredEnvVars") {
        None => Ok(Vec::new()),
        Some(serde_json::Value::Array(items)) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let value = item.as_str().ok_or_else(|| {
                    Error::InvalidArgument("requiredEnvVars entries must be strings".to_string())
                })?;
                out.push(value.to_string());
            }
            Ok(out)
        }
        Some(_) => Err(Error::InvalidArgument(
            "requiredEnvVars must be a JSON array of strings".to_string(),
        )),
    }
}
