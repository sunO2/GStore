//! Script runtime tuning knobs.
//!
//! Defaults follow the Dart `JsChannelRuntime` contract (5 s Promise budget) and
//! the sandbox budget from the plan (64 MB heap). Todo 4 of the Wave 5 plan wires
//! the remaining sandbox limits; the fields already live here so callers never
//! have to guess.

use std::time::Duration;

/// Default wall-clock budget for a single `eval` / `sendMessage` round-trip.
pub const DEFAULT_EVAL_TIMEOUT_MS: u64 = 5_000;
/// Default QuickJS heap ceiling (matches the plan's 64 MB sandbox budget).
pub const DEFAULT_MEMORY_LIMIT_BYTES: usize = 64 * 1024 * 1024;
/// Default QuickJS stack ceiling.
pub const DEFAULT_STACK_LIMIT_BYTES: usize = 1024 * 1024;

/// Limits applied to one channel's QuickJS runtime.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScriptOptions {
    /// Hard wall-clock budget for one evaluation. Enforced by the runtime's
    /// QuickJS interrupt handler, so an infinite loop cannot hang the thread.
    pub eval_timeout: Duration,
    /// QuickJS heap ceiling in bytes (`0` keeps QuickJS' unlimited default).
    pub memory_limit_bytes: usize,
    /// QuickJS stack ceiling in bytes.
    pub stack_limit_bytes: usize,
}

impl Default for ScriptOptions {
    fn default() -> Self {
        Self {
            eval_timeout: Duration::from_millis(DEFAULT_EVAL_TIMEOUT_MS),
            memory_limit_bytes: DEFAULT_MEMORY_LIMIT_BYTES,
            stack_limit_bytes: DEFAULT_STACK_LIMIT_BYTES,
        }
    }
}

impl ScriptOptions {
    /// Defaults with a custom evaluation budget (used by the timeout tests).
    pub fn with_eval_timeout(mut self, eval_timeout: Duration) -> Self {
        self.eval_timeout = eval_timeout;
        self
    }

    /// Override the QuickJS heap ceiling.
    pub fn with_memory_limit(mut self, bytes: usize) -> Self {
        self.memory_limit_bytes = bytes;
        self
    }
}
