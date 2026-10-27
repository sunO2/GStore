//! Process-wide runtime admission.
//!
//! The plan asks for a "global runtime budget" without async machinery. Two
//! plain guards cover it:
//!
//! - a process-wide count of live runtimes (`max_concurrent_runtimes`), taken
//!   before the OS thread is spawned and released when it exits;
//! - a per-runtime cumulative eval clock, tracked by the engine (not here).
//!
//! Both fail closed with [`ScriptErrorKind::Limit`](super::ScriptErrorKind::Limit):
//! exceeding the count refuses the new runtime instead of degrading.

use std::sync::atomic::{AtomicUsize, Ordering};

use super::error::ScriptError;

/// Runtimes currently alive in this process (all channels, all callers).
static LIVE_RUNTIMES: AtomicUsize = AtomicUsize::new(0);

/// Admission ticket: one live runtime. Dropping it releases the slot.
#[derive(Debug)]
pub(crate) struct RuntimeSlot {
    held: bool,
}

impl RuntimeSlot {
    /// Reserve a live-runtime slot, or fail closed with a typed limit error.
    pub(crate) fn acquire(max_concurrent: usize) -> Result<Self, ScriptError> {
        if max_concurrent == 0 {
            return Err(ScriptError::limit(
                "runtime budget: max_concurrent_runtimes must be greater than zero",
            ));
        }
        LIVE_RUNTIMES
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |live| {
                (live < max_concurrent).then_some(live + 1)
            })
            .map(|_| Self { held: true })
            .map_err(|live| {
                ScriptError::limit(format!(
                    "runtime budget: {live} live runtimes, cap is {max_concurrent}"
                ))
            })
    }
}

impl Drop for RuntimeSlot {
    fn drop(&mut self) {
        if self.held {
            LIVE_RUNTIMES.fetch_sub(1, Ordering::SeqCst);
            self.held = false;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_slot_returns_a_slot_when_under_the_cap() {
        let slot = RuntimeSlot::acquire(1).expect("under cap");
        drop(slot);
        RuntimeSlot::acquire(1).expect("slot released on drop");
    }

    #[test]
    fn runtime_slot_rejects_zero_cap() {
        let error = RuntimeSlot::acquire(0).expect_err("zero cap fails closed");
        assert_eq!(error.code(), super::super::CODE_LIMIT);
    }
}
