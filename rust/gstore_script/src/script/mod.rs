//! Script runtime module tree.
//!
//! Layering (each file owns exactly one concern):
//! - `channel`   — validated channel identity
//! - `options`   — limits / budgets
//! - `error`     — typed `CORE_E_SCRIPT_*` errors
//! - `host`      — the `ScriptHost` callback contract
//! - `interrupt` — wall-clock budget shared with QuickJS
//! - `engine`    — one thread-confined QuickJS runtime/context
//! - `thread`    — command loop on the dedicated OS thread
//! - `runtime`   — the public, `Send + Sync` handle

mod channel;
mod engine;
mod error;
mod host;
mod interrupt;
mod options;
mod runtime;
mod thread;

pub use channel::ScriptChannel;
pub use error::{
    ScriptError, ScriptErrorKind, CODE_DISPOSED, CODE_EVAL, CODE_HOST, CODE_INTERNAL,
    CODE_INVALID_ARGUMENT, CODE_LIMIT, CODE_TIMEOUT,
};
pub use host::{ScriptHost, UnsupportedHost};
pub use options::{
    ScriptOptions, DEFAULT_EVAL_TIMEOUT_MS, DEFAULT_MEMORY_LIMIT_BYTES, DEFAULT_STACK_LIMIT_BYTES,
};
pub use runtime::ScriptRuntime;
