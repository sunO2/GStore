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
//! - [`ScriptRuntime::begin_park`] / [`ParkGuard`] — host-only pause of the eval
//!   clocks while a capability blocks (UI round-trips)
//! - [`ScriptHost`] — implemented by the host layer (Todo 2)
//! - [`ScriptOptions`] / [`SandboxLimits`] — the single sandbox policy
//!   (heap, stack, wall-clock, output/response size, redirects, global budget)
//! - [`ScriptError`] / [`ScriptErrorKind`] — `CORE_E_SCRIPT_*` typed errors
//!
//! See `README.md` for the contract and out-of-scope notes.

mod script;

pub use script::{
    ChannelApp, CheckVersionRequest, ConfigGetRequest, DatabaseAppRequest, DatabaseAppsRequest,
    DatabaseInsertRequest, EnvAllRequest, EnvGetRequest, EnvHasRequest, EnvSnapshot, HttpMethod,
    HttpRequest, HttpResponse, InstalledInfo, LogLevel, LogRequest, NativeCallRequest, ParkGuard,
    SandboxLimits, ScriptChannel, ScriptError, ScriptErrorKind, ScriptHost, ScriptOptions,
    ScriptRuntime, UiRequest, UnsupportedHost, CODE_DISPOSED, CODE_EVAL, CODE_HOST, CODE_INTERNAL,
    CODE_INVALID_ARGUMENT, CODE_LIMIT, CODE_TIMEOUT, DEFAULT_CUMULATIVE_EVAL_BUDGET_MS,
    DEFAULT_EVAL_TIMEOUT_MS, DEFAULT_LONG_EVAL_TIMEOUT_MS, DEFAULT_MAX_CONCURRENT_RUNTIMES,
    DEFAULT_MAX_OUTPUT_BYTES, DEFAULT_MAX_REDIRECTS, DEFAULT_MAX_RESPONSE_BYTES,
    DEFAULT_MEMORY_LIMIT_BYTES, DEFAULT_STACK_LIMIT_BYTES,
};
