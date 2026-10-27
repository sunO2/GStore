//! Channel identity: the isolation primitive for the whole Wave 5 script layer.

use std::fmt;

use super::error::ScriptError;

/// Validated channel key (e.g. `js.vivo`).
///
/// A newtype, not a bare `String`: [`ScriptRuntime::spawn`](super::ScriptRuntime::spawn)
/// cannot be called with an unvalidated key, so an empty or NUL-containing key
/// cannot reach the thread builder (which would otherwise panic on an invalid
/// thread name).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ScriptChannel(String);

impl ScriptChannel {
    /// Validate and wrap a channel key.
    pub fn new(key: impl Into<String>) -> Result<Self, ScriptError> {
        let key = key.into();
        if key.trim().is_empty() {
            return Err(ScriptError::invalid_argument(
                "channel key must not be empty",
            ));
        }
        if key.contains('\0') {
            return Err(ScriptError::invalid_argument(
                "channel key must not contain NUL bytes",
            ));
        }
        Ok(Self(key))
    }

    /// Borrow the key.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ScriptChannel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
