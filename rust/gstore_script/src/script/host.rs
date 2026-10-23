//! The host-callback contract invoked by scripts via `sendMessage`.

use serde_json::Value as JsonValue;

use super::error::ScriptError;

/// Host callbacks reachable from scripts through `sendMessage(method, payload)`.
///
/// Implementations run **on the channel's QuickJS thread** (synchronously, while
/// the script waits), so they must be thread-safe and bounded in time. Returning
/// `Err` surfaces to the script as a thrown `Error` tagged with
/// [`ScriptError::code`]; a panic is caught at the bridge and reported as
/// `CORE_E_SCRIPT_HOST` instead of unwinding through QuickJS.
pub trait ScriptHost: Send + Sync {
    fn send_message(&self, method: &str, payload: &JsonValue) -> Result<JsonValue, ScriptError>;
}

/// Host implementation used before Todo 2 registers the real `host.*` surface.
#[derive(Debug, Default, Clone, Copy)]
pub struct UnsupportedHost;

impl ScriptHost for UnsupportedHost {
    fn send_message(&self, method: &str, _payload: &JsonValue) -> Result<JsonValue, ScriptError> {
        Err(ScriptError::host(format!(
            "no host callback registered for `{method}`"
        )))
    }
}
