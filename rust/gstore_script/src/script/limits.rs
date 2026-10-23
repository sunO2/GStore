//! The single sandbox policy for a script runtime.
//!
//! Every value here is a *ceiling*: a host may tighten it, but [`SandboxLimits::validate`]
//! rejects values that would silently disable a guard (for example `memory = 0`,
//! which QuickJS interprets as "unlimited"). Enforcement points are listed per
//! field; see `README.md` for the limit table and the tests that prove each one.

use std::time::Duration;

use super::error::ScriptError;

/// Plan/Wave 5 sandbox budget: 64 MB QuickJS heap.
///
/// Source: `.omo/plans/gstore-rust-core-android-wave05.md` Todo 4 ("64 MB memory").
/// Why: large enough for the bundled `example.js` and catalog JSON, small enough
/// that a runaway allocation cannot take the process down.
pub const DEFAULT_MEMORY_LIMIT_BYTES: usize = 64 * 1024 * 1024;

/// QuickJS stack ceiling (1 MB).
///
/// Source: plan Todo 4 ("stack limit"). Why: bounds native recursion depth so a
/// recursive script raises `CORE_E_SCRIPT_LIMIT` instead of overflowing the OS
/// thread stack.
pub const DEFAULT_STACK_LIMIT_BYTES: usize = 1024 * 1024;

/// Wall-clock budget for one normal `eval` / `sendMessage` round-trip (5 s).
///
/// Source: Dart `js_channel_runtime.dart` `_awaitJsFuture`
/// (`Duration(seconds: 5)`). Why: parity with the authoritative Dart runtime;
/// an infinite loop cannot wedge the per-channel thread.
pub const DEFAULT_EVAL_TIMEOUT_MS: u64 = 5_000;

/// Wall-clock budget for an explicitly long operation (30 s).
///
/// Source: plan Todo 4 ("wall-clock 5 s/30 s") and Todo 5's 30 s UI budget.
/// Why: UI round-trips and pack warm-up legitimately outlive a normal call while
/// still being bounded.
pub const DEFAULT_LONG_EVAL_TIMEOUT_MS: u64 = 30_000;

/// Maximum serialised size of an eval result / script output (10 MB).
///
/// Source: plan Todo 4 ("output 10 MB"). Why: catalog pages are far smaller;
/// a larger result is a bug or an exfiltration attempt, never a success.
pub const DEFAULT_MAX_OUTPUT_BYTES: usize = 10 * 1024 * 1024;

/// Maximum serialised size of `data` in a `host.network.*` envelope (20 MB).
///
/// Source: plan Todo 4 ("response 20 MB"). Why: twice the output cap because a
/// host may hand the script a response body it then filters down.
pub const DEFAULT_MAX_RESPONSE_BYTES: usize = 20 * 1024 * 1024;

/// Maximum number of HTTP redirects a script may request (5).
///
/// Source: plan Todo 4 ("redirect 5"). Why: the transport (host) follows the
/// redirects, so this is a request-shape contract; five hops covers real CDNs
/// without allowing redirect loops.
pub const DEFAULT_MAX_REDIRECTS: u32 = 5;

/// Process-wide ceiling on simultaneously live runtimes.
///
/// Source: plan Todo 4 ("global runtime budget"). Why: one thread + 64 MB heap
/// per channel; 32 channels is well beyond the shipped channel count and keeps
/// the worst case bounded.
pub const DEFAULT_MAX_CONCURRENT_RUNTIMES: usize = 32;

/// Cumulative eval wall-clock allowed per runtime (10 minutes).
///
/// Source: plan Todo 4 ("global runtime budget"). Why: a channel that burns more
/// than ten minutes of script time in its lifetime is misbehaving; refusing
/// further evals is fail-closed and does not need an async accounting system.
pub const DEFAULT_CUMULATIVE_EVAL_BUDGET_MS: u64 = 10 * 60 * 1_000;

/// Explicit, fail-closed sandbox policy for one runtime.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SandboxLimits {
    /// QuickJS heap ceiling (`set_memory_limit`).
    pub memory_limit_bytes: usize,
    /// QuickJS stack ceiling (`set_max_stack_size`).
    pub stack_limit_bytes: usize,
    /// Wall-clock budget for [`ScriptRuntime::eval`](super::ScriptRuntime::eval).
    pub eval_timeout: Duration,
    /// Wall-clock budget for
    /// [`ScriptRuntime::eval_long`](super::ScriptRuntime::eval_long).
    pub long_eval_timeout: Duration,
    /// Maximum serialised eval result, in bytes.
    pub max_output_bytes: usize,
    /// Maximum serialised `data` of a `host.network.*` envelope, in bytes.
    pub max_response_bytes: usize,
    /// Maximum redirects requested from the host transport.
    pub max_redirects: u32,
    /// Process-wide cap on concurrently live runtimes.
    pub max_concurrent_runtimes: usize,
    /// Cumulative eval time allowed per runtime.
    pub cumulative_eval_budget: Duration,
}

impl Default for SandboxLimits {
    fn default() -> Self {
        Self {
            memory_limit_bytes: DEFAULT_MEMORY_LIMIT_BYTES,
            stack_limit_bytes: DEFAULT_STACK_LIMIT_BYTES,
            eval_timeout: Duration::from_millis(DEFAULT_EVAL_TIMEOUT_MS),
            long_eval_timeout: Duration::from_millis(DEFAULT_LONG_EVAL_TIMEOUT_MS),
            max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES,
            max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
            max_redirects: DEFAULT_MAX_REDIRECTS,
            max_concurrent_runtimes: DEFAULT_MAX_CONCURRENT_RUNTIMES,
            cumulative_eval_budget: Duration::from_millis(DEFAULT_CUMULATIVE_EVAL_BUDGET_MS),
        }
    }
}

impl SandboxLimits {
    /// Tighten the QuickJS heap ceiling.
    #[must_use]
    pub fn with_memory_limit(mut self, bytes: usize) -> Self {
        self.memory_limit_bytes = bytes;
        self
    }

    /// Tighten the QuickJS stack ceiling.
    #[must_use]
    pub fn with_stack_limit(mut self, bytes: usize) -> Self {
        self.stack_limit_bytes = bytes;
        self
    }

    /// Change the normal eval wall-clock budget.
    #[must_use]
    pub fn with_eval_timeout(mut self, timeout: Duration) -> Self {
        self.eval_timeout = timeout;
        self
    }

    /// Change the long-operation wall-clock budget.
    #[must_use]
    pub fn with_long_eval_timeout(mut self, timeout: Duration) -> Self {
        self.long_eval_timeout = timeout;
        self
    }

    /// Tighten the serialised output ceiling.
    #[must_use]
    pub fn with_max_output(mut self, bytes: usize) -> Self {
        self.max_output_bytes = bytes;
        self
    }

    /// Tighten the `host.network.*` response ceiling.
    #[must_use]
    pub fn with_max_response(mut self, bytes: usize) -> Self {
        self.max_response_bytes = bytes;
        self
    }

    /// Tighten the redirect ceiling (values above 5 are rejected on spawn).
    #[must_use]
    pub fn with_max_redirects(mut self, redirects: u32) -> Self {
        self.max_redirects = redirects;
        self
    }

    /// Lower the process-wide live-runtime cap.
    #[must_use]
    pub fn with_max_concurrent_runtimes(mut self, runtimes: usize) -> Self {
        self.max_concurrent_runtimes = runtimes;
        self
    }

    /// Lower the per-runtime cumulative eval budget.
    #[must_use]
    pub fn with_cumulative_eval_budget(mut self, budget: Duration) -> Self {
        self.cumulative_eval_budget = budget;
        self
    }

    /// Rejects configurations that would silently disable a guard.
    ///
    /// Zero is not a valid ceiling for any guard: QuickJS treats a zero heap
    /// limit as "unlimited", and a zero timeout would mean either "no budget"
    /// or "always fail" depending on the layer. Redirects may be zero (deny all
    /// redirects) but never above the contract maximum of 5.
    pub(crate) fn validate(&self) -> Result<(), ScriptError> {
        let positive = [
            ("memory_limit_bytes", self.memory_limit_bytes),
            ("stack_limit_bytes", self.stack_limit_bytes),
            ("max_output_bytes", self.max_output_bytes),
            ("max_response_bytes", self.max_response_bytes),
            ("max_concurrent_runtimes", self.max_concurrent_runtimes),
        ];
        for (name, value) in positive {
            if value == 0 {
                return Err(ScriptError::invalid_argument(format!(
                    "sandbox limit `{name}` must be greater than zero (0 would disable it)"
                )));
            }
        }
        for (name, value) in [
            ("eval_timeout", self.eval_timeout),
            ("long_eval_timeout", self.long_eval_timeout),
            ("cumulative_eval_budget", self.cumulative_eval_budget),
        ] {
            if value.is_zero() {
                return Err(ScriptError::invalid_argument(format!(
                    "sandbox limit `{name}` must be greater than zero"
                )));
            }
        }
        if self.max_redirects > DEFAULT_MAX_REDIRECTS {
            return Err(ScriptError::invalid_argument(format!(
                "sandbox limit `max_redirects` is {}, contract maximum is {DEFAULT_MAX_REDIRECTS}",
                self.max_redirects
            )));
        }
        Ok(())
    }
}
