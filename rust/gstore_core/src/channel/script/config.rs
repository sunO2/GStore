//! Constructor inputs for the script-backed channel and detail runtimes.
//!
//! Both configs keep the channel key and the optional pack key together so
//! [`ScriptChannel`](super::ScriptChannel) can reject a config where the script
//! belongs to a different pack. Foreign crates cannot bypass the check: the
//! driver is only constructible through these validated configs.

use std::sync::Arc;

use gstore_script::ScriptHost;

use crate::channel::ChannelDriver;
use crate::dto::ChannelKey;
use crate::error::Error;

/// Inputs for one [`ScriptChannel`](super::ScriptChannel).
pub struct ScriptChannelConfig {
    /// Channel identity bound to the runtime and every DTO it produces.
    pub key: ChannelKey,
    /// Entry script source (for example `assets/channels/example.js`).
    pub script: String,
    /// Host capabilities injected by the device layer.
    pub host: Arc<dyn ScriptHost>,
    /// Optional same-key driver used when the script returns `null`.
    ///
    /// This mirrors Dart `JsChannel`'s "script returned null -> query this
    /// channel's local database" fallback. The fallback must never be allowed
    /// to change the script channel's identity.
    pub fallback: Option<Arc<dyn ChannelDriver>>,
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
            fallback: None,
            pack_key: None,
        }
    }

    /// Attaches the same-key fallback driver.
    #[must_use]
    pub fn with_fallback(mut self, fallback: Arc<dyn ChannelDriver>) -> Self {
        self.fallback = Some(fallback);
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
