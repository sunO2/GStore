//! Dedicated OS thread owning the engine + the command loop.
//!
//! The channel boundary is a `std::sync::mpsc` channel: no `unsafe`, no runtime
//! handle crossing threads, and `Runtime::new()` happens inside the thread
//! closure. Commands are serialised, which also serialises script execution.

use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

use serde_json::Value as JsonValue;

use super::budget::RuntimeSlot;
use super::channel::ScriptChannel;
use super::engine::Engine;
use super::error::ScriptError;
use super::host::ScriptHost;
use super::options::ScriptOptions;

/// One unit of work for the engine thread.
pub(crate) enum Command {
    Eval {
        source: String,
        reply: SyncSender<Result<JsonValue, ScriptError>>,
    },
    EvalLong {
        source: String,
        reply: SyncSender<Result<JsonValue, ScriptError>>,
    },
    SendMessage {
        method: String,
        payload: JsonValue,
        reply: SyncSender<Result<JsonValue, ScriptError>>,
    },
    Dispose {
        reply: SyncSender<()>,
    },
}

/// Sender + join handle for a live engine thread.
pub(crate) struct ThreadHandle {
    pub(crate) tx: Sender<Command>,
    pub(crate) join: JoinHandle<()>,
}

/// Spawn the channel thread and wait for engine construction to finish.
///
/// Initialisation failures (bad QuickJS build, OOM at startup, an invalid or
/// exhausted runtime budget) are reported here rather than surfacing later as a
/// mysterious `Disposed`. The process-wide live-runtime slot is acquired before
/// the thread exists and released when it exits.
pub(crate) fn spawn(
    channel: &ScriptChannel,
    options: ScriptOptions,
    host: Arc<dyn ScriptHost>,
) -> Result<ThreadHandle, ScriptError> {
    options.limits.validate()?;
    let slot = RuntimeSlot::acquire(options.limits.max_concurrent_runtimes)?;
    let (init_tx, init_rx) = mpsc::sync_channel(0);
    let (tx, rx) = mpsc::channel();

    let thread_channel = channel.clone();
    let join = thread::Builder::new()
        .name(format!("gstore-script:{thread_channel}"))
        .spawn(move || run(init_tx, rx, options, host, thread_channel, slot))
        .map_err(|err| ScriptError::internal(format!("spawn script thread: {err}")))?;

    match init_rx.recv() {
        Ok(Ok(())) => Ok(ThreadHandle { tx, join }),
        Ok(Err(err)) => {
            let _ = join.join();
            Err(err)
        }
        Err(_) => {
            let _ = join.join();
            Err(ScriptError::internal(
                "script thread exited before reporting readiness",
            ))
        }
    }
}

fn run(
    init_tx: SyncSender<Result<(), ScriptError>>,
    rx: Receiver<Command>,
    options: ScriptOptions,
    host: Arc<dyn ScriptHost>,
    channel: ScriptChannel,
    slot: RuntimeSlot,
) {
    let _slot = slot;
    let mut engine = match Engine::new(&options, host, channel) {
        Ok(engine) => {
            if init_tx.send(Ok(())).is_err() {
                return;
            }
            engine
        }
        Err(err) => {
            let _ = init_tx.send(Err(err));
            return;
        }
    };

    while let Ok(command) = rx.recv() {
        match command {
            Command::Eval { source, reply } => {
                let _ = reply.send(engine.eval(&source));
            }
            Command::EvalLong { source, reply } => {
                let _ = reply.send(engine.eval_long(&source));
            }
            Command::SendMessage {
                method,
                payload,
                reply,
            } => {
                let _ = reply.send(engine.send_message(&method, &payload));
            }
            Command::Dispose { reply } => {
                let _ = reply.send(());
                break;
            }
        }
    }
    // Engine (Runtime + Context) is dropped here, on its own thread.
}
