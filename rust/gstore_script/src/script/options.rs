//! Script runtime tuning knobs.
//!
//! All limits live in [`SandboxLimits`] so callers have exactly one policy to
//! review; this wrapper keeps the historical `ScriptOptions` entry point and
//! delegates every setter to the policy.

use std::time::Duration;

use super::limits::SandboxLimits;

/// Limits applied to one channel's QuickJS runtime.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ScriptOptions {
    /// The single, explicit sandbox policy (defaults per plan Todo 4).
    pub limits: SandboxLimits,
}

impl ScriptOptions {
    /// Options carrying an explicit policy.
    pub fn new(limits: SandboxLimits) -> Self {
        Self { limits }
    }

    /// Replace the policy wholesale.
    #[must_use]
    pub fn with_limits(mut self, limits: SandboxLimits) -> Self {
        self.limits = limits;
        self
    }

    /// Defaults with a custom evaluation budget (used by the timeout tests).
    #[must_use]
    pub fn with_eval_timeout(mut self, eval_timeout: Duration) -> Self {
        self.limits = self.limits.with_eval_timeout(eval_timeout);
        self
    }

    /// Override the QuickJS heap ceiling.
    #[must_use]
    pub fn with_memory_limit(mut self, bytes: usize) -> Self {
        self.limits = self.limits.with_memory_limit(bytes);
        self
    }
}
