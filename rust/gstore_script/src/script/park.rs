//! Host-side park accounting.
//!
//! A host capability sometimes has to block the script thread while it waits for
//! an external answer (Todo 5: `UiApi.respond`). That wait is not script work, so
//! it must not consume either the normal eval deadline or the per-runtime
//! cumulative eval clock — while still being bounded and impossible to use from
//! JavaScript to extend a budget.
//!
//! The engine installs its [`InterruptState`] in a thread-local when the channel
//! thread starts. Host code running on that thread calls
//! [`ScriptRuntime::begin_park`](super::ScriptRuntime::begin_park), which returns
//! a [`ParkGuard`]. The guard:
//!
//! - makes the interrupt handler report "not expired" for the whole park;
//! - on drop, extends the armed deadline by the parked interval **clamped to the
//!   bound the host passed** (so an over-long park only exempts its bound and the
//!   excess is charged to the eval); and
//! - records the exempted interval so the engine can subtract it from the
//!   cumulative eval clock (paused, not reset).
//!
//! Dropping the guard is the only way to end a park, so unwinding/panic and early
//! returns restore accounting automatically. Hosts outside an engine thread get
//! an inert guard, which keeps `ui_api` usable in tests and in the Rust-side
//! `send_message` path without special-casing.

use std::cell::RefCell;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::interrupt::InterruptState;

thread_local! {
    /// Set exactly once, by [`install`], on the channel thread.
    static ACTIVE: RefCell<Option<Arc<InterruptState>>> = const { RefCell::new(None) };
}

/// Bind the current thread's park accounting to `interrupt`.
pub(crate) fn install(interrupt: Arc<InterruptState>) {
    ACTIVE.with(|slot| *slot.borrow_mut() = Some(interrupt));
}

/// Limits a park interval and restores budget accounting when dropped.
///
/// Created by [`ScriptRuntime::begin_park`](super::ScriptRuntime::begin_park);
/// never exposed to JavaScript.
#[derive(Debug)]
pub struct ParkGuard {
    state: Option<Arc<InterruptState>>,
    started: Instant,
    bound: Duration,
}

impl ParkGuard {
    /// Start a park bounded by `bound`.
    ///
    /// `bound` is the maximum interval that may be exempted from the deadlines;
    /// a longer park charges the excess back to the evaluation. Callers should
    /// pass the same budget that bounds the wait itself (the UI budget in
    /// `gstore_host`).
    pub(crate) fn begin(bound: Duration) -> Self {
        let state = ACTIVE.with(|slot| slot.borrow().clone());
        if let Some(interrupt) = &state {
            interrupt.begin_park(bound);
        }
        Self {
            state,
            started: Instant::now(),
            bound,
        }
    }

    /// The bound this park was created with.
    pub fn bound(&self) -> Duration {
        self.bound
    }
}

impl Drop for ParkGuard {
    fn drop(&mut self) {
        if let Some(interrupt) = self.state.take() {
            interrupt.end_park(self.started.elapsed().min(self.bound));
        }
    }
}
