//! Constructor inputs for the script-backed channel and detail runtimes.
//!
//! Both configs keep the channel key and the optional pack key together so
//! [`ScriptChannel`](super::ScriptChannel) can reject a config where the script
//! belongs to a different pack. Foreign crates cannot bypass the check: the
//! driver is only constructible through these validated configs.

use std::sync::Arc;

use gstore_script::ScriptHost;

use crate::dto::ChannelKey;
use crate::error::Error;

use super::store::ScriptChannelStore;

/// Inputs for one [`ScriptChannel`](super::ScriptChannel).
pub struct ScriptChannelConfig {
    /// Channel identity bound to the runtime and every DTO it produces.
    pub key: ChannelKey,
    /// Entry script source (for example `assets/channels/example.js`).
    pub script: String,
    /// Host capabilities injected by the device layer.
    pub host: Arc<dyn ScriptHost>,
    /// Optional local store used when the script returns no result.
    ///
    /// This mirrors Dart `JsChannel`'s "script returned nothing -> query this
    /// channel's own database" fallback. Every store call is pinned to the
    /// channel key, so the store can never address another channel.
    pub store: Option<Arc<dyn ScriptChannelStore>>,
    /// Pack key when the script came from a zip pack.
    ///
    /// When present it must equal [`Self::key`]; otherwise construction fails
    /// with [`Error::InvalidArgument`] before any runtime is spawned.
    pub pack_key: Option<ChannelKey>,
}

impl ScriptChannelConfig {
    /// Creates a config with no fallback and no pack key.
    pub fn new(key: ChannelKey, script: impl Into<String>, host: Arc<dyn ScriptHost>) -> Self {
        Self {
            key,
            script: script.into(),
            host,
            store: None,
            pack_key: None,
        }
    }

    /// Attaches the same-key local app store used by Dart's fallbacks.
    #[must_use]
    pub fn with_store(mut self, store: Arc<dyn ScriptChannelStore>) -> Self {
        self.store = Some(store);
        self
    }

    /// Declares the pack key this script was imported from.
    #[must_use]
    pub fn with_pack_key(mut self, pack_key: ChannelKey) -> Self {
        self.pack_key = Some(pack_key);
        self
    }

    /// Rejects an empty script or a mismatched pack key.
    pub(crate) fn validate(&self) -> Result<(), Error> {
        if self.script.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "channel script source must not be empty".to_string(),
            ));
        }
        validate_pack_key(&self.key, self.pack_key.as_ref())
    }
}

/// Inputs for one [`ScriptDetail`](super::ScriptDetail).
pub struct ScriptDetailConfig {
    /// Channel identity; must match the owning entry channel.
    pub key: ChannelKey,
    /// Detail script source (`detail.js`).
    pub script: String,
    /// Host capabilities injected by the device layer.
    pub host: Arc<dyn ScriptHost>,
    /// Pack key when the detail script came from a zip pack.
    pub pack_key: Option<ChannelKey>,
}

impl ScriptDetailConfig {
    /// Creates a detail config with no pack key.
    pub fn new(key: ChannelKey, script: impl Into<String>, host: Arc<dyn ScriptHost>) -> Self {
        Self {
            key,
            script: script.into(),
            host,
            pack_key: None,
        }
    }

    /// Declares the pack key this detail script was imported from.
    #[must_use]
    pub fn with_pack_key(mut self, pack_key: ChannelKey) -> Self {
        self.pack_key = Some(pack_key);
        self
    }

    /// Rejects an empty script or a mismatched pack key.
    pub(crate) fn validate(&self) -> Result<(), Error> {
        if self.script.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "detail script source must not be empty".to_string(),
            ));
        }
        validate_pack_key(&self.key, self.pack_key.as_ref())
    }
}

fn validate_pack_key(key: &ChannelKey, pack_key: Option<&ChannelKey>) -> Result<(), Error> {
    match pack_key {
        Some(pack_key) if pack_key != key => Err(Error::InvalidArgument(format!(
            "script channel key `{key}` does not match pack key `{pack_key}`"
        ))),
        _ => Ok(()),
    }
}
