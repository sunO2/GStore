//! Wall-clock budget shared with QuickJS' interrupt handler.
//!
//! QuickJS calls the interrupt handler periodically while executing JS. Returning
//! `true` raises an *uncatchable* exception and hands control back to `eval`, so
//! `while (true) {}` cannot wedge the dedicated thread. The handler must be a
//! plain `FnMut`, hence atomics instead of a mutex-guarded deadline.
//!
//! The same state owns host-park accounting: while a [`ParkGuard`](super::ParkGuard)
//! is live the deadline is suspended, and on unpark the armed deadline is pushed
//! forward by the exempted interval (clamped to the park's bound). The cumulative
//! eval clock reads [`InterruptState::exempted`] to subtract the same interval.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// Nanoseconds in one millisecond.
const NANOS_PER_MS: u64 = 1_000_000;

/// Deadline state for one runtime. Armed before each evaluation, disarmed after.
#[derive(Debug)]
pub(crate) struct InterruptState {
    epoch: Instant,
    /// Absolute deadline in milliseconds since `epoch`; `0` means disarmed.
    deadline_ms: AtomicU64,
    /// Set when the interrupt handler actually fired (decisive timeout signal).
    fired: AtomicBool,
    /// Nesting depth of live park guards. Non-zero means the deadline is paused.
    park_depth: AtomicUsize,
    /// Bound for the outermost live park, in nanoseconds.
    park_bound_nanos: AtomicU64,
    /// Total interval exempted from eval clocks since the runtime started.
    exempted_nanos: AtomicU64,
}

impl InterruptState {
    pub(crate) fn new() -> Self {
        Self {
            epoch: Instant::now(),
            deadline_ms: AtomicU64::new(0),
            fired: AtomicBool::new(false),
            park_depth: AtomicUsize::new(0),
            park_bound_nanos: AtomicU64::new(0),
            exempted_nanos: AtomicU64::new(0),
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
    ///
    /// Returns `false` while a host park is active: a parked wait is not script
    /// execution time.
    pub(crate) fn expired(&self) -> bool {
        if self.park_depth.load(Ordering::SeqCst) != 0 {
            return false;
        }
        let deadline = self.deadline_ms.load(Ordering::SeqCst);
        deadline != 0 && self.elapsed_ms() >= deadline
    }

    /// Whether the QuickJS interrupt handler fired during the last evaluation.
    pub(crate) fn fired(&self) -> bool {
        self.fired.load(Ordering::SeqCst)
    }

    /// Total interval exempted from eval clocks so far.
    pub(crate) fn exempted(&self) -> Duration {
        Duration::from_nanos(self.exempted_nanos.load(Ordering::SeqCst))
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

    /// Begin a host park bounded by `bound`; nested guards share the outer bound.
    pub(crate) fn begin_park(&self, bound: Duration) {
        if self.park_depth.fetch_add(1, Ordering::SeqCst) == 0 {
            self.park_bound_nanos.store(nanos(bound), Ordering::SeqCst);
        }
    }

    /// End a host park, exempting at most the outermost bound.
    ///
    /// The armed deadline is extended by the exempted interval so the remaining
    /// budget is exactly what it was before the park. An over-long park extends
    /// only by its bound, charging the excess to the evaluation.
    pub(crate) fn end_park(&self, elapsed: Duration) {
        if self.park_depth.fetch_sub(1, Ordering::SeqCst) != 1 {
            return;
        }
        let bound = self.park_bound_nanos.load(Ordering::SeqCst);
        let exempted = nanos(elapsed).min(bound);
        self.exempted_nanos.fetch_add(exempted, Ordering::SeqCst);

        let extension_ms = exempted / NANOS_PER_MS;
        if extension_ms == 0 {
            return;
        }
        let _ = self
            .deadline_ms
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |deadline| {
                (deadline != 0).then(|| deadline.saturating_add(extension_ms))
            });
    }

    fn elapsed_ms(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_millis()).unwrap_or(u64::MAX)
    }
}

fn nanos(duration: Duration) -> u64 {
    u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)
}
