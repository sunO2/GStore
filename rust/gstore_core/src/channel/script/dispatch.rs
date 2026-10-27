//! Runtime spawning and the single `main(method, params)` dispatch path.
//!
//! Every public driver/detail method funnels through [`call_main`], so the
//! envelope rules from Dart `_callMain` live here exactly once. A script that
//! returns nothing (`null`, `{ok:true,data:null}`), reports failure
//! (`{ok:false}`), or throws a JS exception all mean "no script result": the
//! caller applies Dart's fallback. Only malformed output / transport faults
//! (timeout, disposal, sandbox limit, host failure, invalid JSON) are errors.

use std::sync::{Arc, Mutex, MutexGuard};

use gstore_script::{
    ScriptChannel as EngineChannel, ScriptError, ScriptErrorKind, ScriptHost, ScriptOptions,
    ScriptRuntime,
};
use serde_json::{Map, Value as JsonValue};

use crate::dto::ChannelKey;
use crate::error::Error;

/// One `main(method, params)` call outcome.
pub(crate) type MainOutcome = Result<Option<JsonValue>, Error>;

/// Spawns the channel runtime and evaluates the entry/detail script once.
pub(crate) fn spawn(
    key: &ChannelKey,
    script: &str,
    host: Arc<dyn ScriptHost>,
) -> Result<ScriptRuntime, Error> {
    let engine_channel =
        EngineChannel::new(key.as_str()).map_err(|error| map_script_error(&error))?;
    let runtime = ScriptRuntime::spawn(engine_channel, ScriptOptions::default(), host)
        .map_err(|error| map_script_error(&error))?;
    runtime
        .eval(script)
        .map_err(|error| map_script_error(&error))?;
    Ok(runtime)
}

/// Invokes `main(method, params)` and unwraps the Dart-compatible envelope.
///
/// A script without a `main` function degrades to `null` (fallback) instead of
/// surfacing a `ReferenceError`, matching "missing method -> caller falls back".
pub(crate) fn call_main(
    runtime: &ScriptRuntime,
    method: &str,
    params: &Map<String, JsonValue>,
) -> MainOutcome {
    let method_json = serde_json::to_string(method)?;
    let params_json = serde_json::to_string(params)?;
    let source =
        format!("(typeof main === 'function' ? main({method_json}, {params_json}) : null)");
    let raw = match runtime.eval(&source) {
        Ok(value) => value,
        Err(error) if error.kind() == ScriptErrorKind::Eval => return Ok(None),
        Err(error) => return Err(map_script_error(&error)),
    };
    Ok(unwrap_envelope(raw))
}

fn unwrap_envelope(raw: JsonValue) -> Option<JsonValue> {
    let JsonValue::Object(map) = raw else {
        return (!raw.is_null()).then_some(raw);
    };
    match map.get("ok") {
        Some(JsonValue::Bool(true)) => map.get("data").filter(|value| !value.is_null()).cloned(),
        Some(JsonValue::Bool(false)) => None,
        _ => Some(JsonValue::Object(map)),
    }
}

/// Builds a script param map from literal key/value pairs.
pub(crate) fn params(pairs: &[(&str, JsonValue)]) -> Map<String, JsonValue> {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_owned(), value.clone()))
        .collect()
}

/// Borrows the live runtime or reports that the slot was disposed.
pub(crate) fn lock_runtime(
    slot: &Mutex<Option<ScriptRuntime>>,
) -> Result<MutexGuard<'_, Option<ScriptRuntime>>, Error> {
    slot.lock()
        .map_err(|_| Error::Internal("script runtime lock poisoned".to_string()))
}

/// Disposes the runtime if present; safe to call repeatedly.
pub(crate) fn dispose_runtime(slot: &Mutex<Option<ScriptRuntime>>) -> Result<(), Error> {
    let mut guard = lock_runtime(slot)?;
    match guard.take() {
        Some(runtime) => runtime.dispose().map_err(|error| map_script_error(&error)),
        None => Ok(()),
    }
}

/// Maps the leaf crate's typed error into the core error surface.
pub(crate) fn map_script_error(error: &ScriptError) -> Error {
    match error.kind() {
        ScriptErrorKind::InvalidArgument => Error::InvalidArgument(error.to_string()),
        ScriptErrorKind::Eval
        | ScriptErrorKind::Timeout
        | ScriptErrorKind::Disposed
        | ScriptErrorKind::Limit
        | ScriptErrorKind::Host
        | ScriptErrorKind::Internal => Error::Internal(error.to_string()),
    }
}
