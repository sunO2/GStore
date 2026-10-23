//! Public handle for one channel's script runtime.

use std::sync::mpsc;
use std::sync::Arc;

use serde_json::Value as JsonValue;

use super::channel::ScriptChannel;
use super::error::ScriptError;
use super::host::ScriptHost;
use super::options::ScriptOptions;
use super::thread::{self, Command, ThreadHandle};

/// Handle to one channel's dedicated QuickJS runtime.
///
/// Thread model: construction spawns one OS thread and builds the
/// `rquickjs::Runtime` there; every call is a command on that thread. Two
/// `ScriptRuntime`s therefore share no JS state, which is how channel isolation
/// is guaranteed by construction rather than by convention.
///
/// The handle is `Send + Sync`; calls from the same handle are serialised on the
/// engine thread.
pub struct ScriptRuntime {
    channel: ScriptChannel,
    handle: Option<ThreadHandle>,
}

impl ScriptRuntime {
    /// Spawn the channel thread and its QuickJS runtime.
    pub fn spawn(
        channel: ScriptChannel,
        options: ScriptOptions,
        host: Arc<dyn ScriptHost>,
    ) -> Result<Self, ScriptError> {
        let handle = thread::spawn(&channel, options, host)?;
        Ok(Self {
            channel,
            handle: Some(handle),
        })
    }

    /// Channel key this runtime is bound to.
    pub fn channel(&self) -> &ScriptChannel {
        &self.channel
    }

    /// Evaluate a script and return its JSON completion value.
    ///
    /// A Promise result is drained until settled (bounded by
    /// [`ScriptOptions::eval_timeout`]); an infinite loop is interrupted and
    /// reported as [`ScriptErrorKind::Timeout`](super::ScriptErrorKind::Timeout).
    pub fn eval(&self, source: &str) -> Result<JsonValue, ScriptError> {
        let (reply, rx) = mpsc::sync_channel(1);
        self.send(Command::Eval {
            source: source.to_owned(),
            reply,
        })?;
        rx.recv().map_err(|_| ScriptError::Disposed)?
    }

    /// Dispatch one host message through [`ScriptHost::send_message`].
    ///
    /// This is the same path the JS-side `sendMessage` helper uses; exposing it
    /// on the handle lets the host invoke callbacks with channel affinity and
    /// lets tests assert isolation without evaluating JS.
    pub fn send_message(&self, method: &str, payload: JsonValue) -> Result<JsonValue, ScriptError> {
        let (reply, rx) = mpsc::sync_channel(1);
        self.send(Command::SendMessage {
            method: method.to_owned(),
            payload,
            reply,
        })?;
        rx.recv().map_err(|_| ScriptError::Disposed)?
    }

    /// Stop the engine thread and release the QuickJS runtime.
    ///
    /// Idempotent-by-ownership: consumes the handle, so a disposed runtime
    /// cannot be used again at the type level.
    pub fn dispose(mut self) -> Result<(), ScriptError> {
        self.shutdown()
    }

    fn send(&self, command: Command) -> Result<(), ScriptError> {
        let handle = self.handle.as_ref().ok_or(ScriptError::Disposed)?;
        handle.tx.send(command).map_err(|_| ScriptError::Disposed)
    }

    fn shutdown(&mut self) -> Result<(), ScriptError> {
        let Some(handle) = self.handle.take() else {
            return Ok(());
        };
        let (reply, rx) = mpsc::sync_channel(1);
        let _ = handle.tx.send(Command::Dispose { reply });
        let _ = rx.recv();
        handle
            .join
            .join()
            .map_err(|_| ScriptError::internal("script thread panicked"))
    }
}

impl Drop for ScriptRuntime {
    fn drop(&mut self) {
        // Join so no thread outlives its handle; errors are already surfaced by
        // an explicit `dispose()`.
        let _ = self.shutdown();
    }
}
