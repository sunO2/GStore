//! `gstore_script` — leaf crate hosting the per-channel QuickJS runtime.
//!
//! Deliberately dependency-free of `gstore_core` (plan constraint): core will
//! depend on this crate in Todo 3, never the other way around.
//!
//! # Thread model
//!
//! `ScriptRuntime::spawn` creates **one** OS thread per channel and builds the
//! `rquickjs::Runtime` + `Context` inside it. All script execution happens on
//! that thread; the handle talks to it over an `mpsc` command channel. Two
//! channels therefore cannot share JS state, and no `unsafe` is needed for the
//! hand-off.
//!
//! # Public surface
//!
//! - [`ScriptRuntime::spawn`] / [`ScriptRuntime::dispose`]
//! - [`ScriptRuntime::eval`] — JSON completion value, Promise-aware
//! - [`ScriptRuntime::send_message`] — the `sendMessage` host bridge
//! - [`ScriptHost`] — implemented by the host layer (Todo 2)
//! - [`ScriptOptions`] — eval budget, heap/stack ceilings
//! - [`ScriptError`] / [`ScriptErrorKind`] — `CORE_E_SCRIPT_*` typed errors
//!
//! See `README.md` for the contract and out-of-scope notes.

mod script;

pub use script::{
    ScriptChannel, ScriptError, ScriptErrorKind, ScriptHost, ScriptOptions, ScriptRuntime,
    UnsupportedHost, CODE_DISPOSED, CODE_EVAL, CODE_HOST, CODE_INTERNAL, CODE_INVALID_ARGUMENT,
    CODE_LIMIT, CODE_TIMEOUT, DEFAULT_EVAL_TIMEOUT_MS, DEFAULT_MEMORY_LIMIT_BYTES,
    DEFAULT_STACK_LIMIT_BYTES,
};
