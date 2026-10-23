//! Wall-clock budget shared with QuickJS' interrupt handler.
//!
//! QuickJS calls the interrupt handler periodically while executing JS. Returning
//! `true` raises an *uncatchable* exception and hands control back to `eval`, so
//! `while (true) {}` cannot wedge the dedicated thread. The handler must be a
//! plain `FnMut`, hence atomics instead of a mutex-guarded deadline.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Deadline state for one runtime. Armed before each evaluation, disarmed after.
#[derive(Debug)]
pub(crate) struct InterruptState {
    epoch: Instant,
    /// Absolute deadline in milliseconds since `epoch`; `0` means disarmed.
    deadline_ms: AtomicU64,
    /// Set when the interrupt handler actually fired (decisive timeout signal).
    fired: AtomicBool,
}

impl InterruptState {
    pub(crate) fn new() -> Self {
        Self {
            epoch: Instant::now(),
            deadline_ms: AtomicU64::new(0),
            fired: AtomicBool::new(false),
        }
    }

    /// Start a budget of `timeout` from now. A zero budget still allows 1 ms so
    /// that a caller mistake degrades to "times out immediately", not "unlimited".
    pub(crate) fn arm(&self, timeout: Duration) {
        self.fired.store(false, Ordering::SeqCst);
        let budget_ms = u64::try_from(timeout.as_millis())
            .unwrap_or(u64::MAX)
            .max(1);
        let deadline = self.elapsed_ms().saturating_add(budget_ms);
        self.deadline_ms.store(deadline.max(1), Ordering::SeqCst);
    }

    /// Stop enforcing a budget (between evaluations).
    pub(crate) fn disarm(&self) {
        self.deadline_ms.store(0, Ordering::SeqCst);
    }

    /// Whether the budget has passed, without marking the timeout as fired.
    pub(crate) fn expired(&self) -> bool {
        let deadline = self.deadline_ms.load(Ordering::SeqCst);
        deadline != 0 && self.elapsed_ms() >= deadline
    }

    /// Whether the QuickJS interrupt handler fired during the last evaluation.
    pub(crate) fn fired(&self) -> bool {
        self.fired.load(Ordering::SeqCst)
    }

    /// Interrupt-handler view: report and record exhaustion exactly once.
    pub(crate) fn on_interrupt(&self) -> bool {
        if self.expired() {
            self.fired.store(true, Ordering::SeqCst);
            true
        } else {
            false
        }
    }

    fn elapsed_ms(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_millis()).unwrap_or(u64::MAX)
    }
}
