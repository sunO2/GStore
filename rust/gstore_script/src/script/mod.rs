//! Script runtime module tree.
//!
//! Layering (each file owns exactly one concern):
//! - `channel`    — validated channel identity
//! - `limits`     — the single `SandboxLimits` policy (defaults + validation)
//! - `options`    — the public `ScriptOptions` wrapper
//! - `error`      — typed `CORE_E_SCRIPT_*` errors
//! - `host_types` — typed capability requests/responses
//! - `host`       — the `ScriptHost` capability contract + dispatcher
//! - `prelude.js` — the JS `sendMessage` / `host.*` facade (included as an asset)
//! - `bridge`     — native bridge + prelude installation
//! - `js_error`   — rquickjs error -> typed error mapping
//! - `interrupt`  — wall-clock budget shared with QuickJS
//! - `budget`     — process-wide live-runtime admission
//! - `engine`     — one thread-confined QuickJS runtime/context
//! - `thread`     — command loop on the dedicated OS thread
//! - `runtime`    — the public, `Send + Sync` handle

mod bridge;
mod budget;
mod channel;
mod engine;
mod error;
mod host;
mod host_types;
mod interrupt;
mod js_error;
mod limits;
mod options;
mod runtime;
mod thread;

pub use channel::ScriptChannel;
pub use error::{
    ScriptError, ScriptErrorKind, CODE_DISPOSED, CODE_EVAL, CODE_HOST, CODE_INTERNAL,
    CODE_INVALID_ARGUMENT, CODE_LIMIT, CODE_TIMEOUT,
};
pub use host::{ScriptHost, UnsupportedHost};
pub use host_types::{
    ChannelApp, CheckVersionRequest, ConfigGetRequest, DatabaseAppRequest, DatabaseAppsRequest,
    DatabaseInsertRequest, EnvAllRequest, EnvGetRequest, EnvHasRequest, EnvSnapshot, HttpMethod,
    HttpRequest, HttpResponse, InstalledInfo, LogLevel, LogRequest, NativeCallRequest, UiRequest,
};
pub use limits::{
    SandboxLimits, DEFAULT_CUMULATIVE_EVAL_BUDGET_MS, DEFAULT_EVAL_TIMEOUT_MS,
    DEFAULT_LONG_EVAL_TIMEOUT_MS, DEFAULT_MAX_CONCURRENT_RUNTIMES, DEFAULT_MAX_OUTPUT_BYTES,
    DEFAULT_MAX_REDIRECTS, DEFAULT_MAX_RESPONSE_BYTES, DEFAULT_MEMORY_LIMIT_BYTES,
    DEFAULT_STACK_LIMIT_BYTES,
};
pub use options::ScriptOptions;
pub use runtime::ScriptRuntime;
