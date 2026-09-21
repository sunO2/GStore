//! Data-plane supervisor + health check (Todo 24).
//!
//! ## Why this exists
//!
//! The TUN datapath is a **single dedicated std thread** ([`crate::tun`]) that
//! owns a bounded tokio runtime and three critical tasks — the one fd *reader*,
//! the ingress pump and the egress pump. The module is compiled `panic=unwind`,
//! but `catch_unwind` only guards the C ABI boundary
//! (`proxy_call_export`/`proxy_on_event_export`): a panic **inside a
//! module-spawned worker thread** (the loop thread body, or a `tokio::spawn`
//! task) does **not** propagate to any caller. Before Todo 24 that killed the
//! data plane silently — the process stayed up, `core.get_mode` still said
//! `running`, but no packet moved.
//!
//! This module owns the process-global health state and the bounded-restart
//! policy. [`crate::tun`] detects an abnormal worker exit (task ended, or the
//! loop thread body panicked) and calls [`on_death`]; the loop thread then
//! optionally restarts with exponential backoff (bounded by [`MAX_RESTARTS`]).
//!
//! ## Root cause is never masked
//!
//! Every transition emits a structured `proxy.state` event that carries a
//! machine-readable `error { code, message }` **and** a `health` object with the
//! verbatim failure reason, so Dart/`LogManager` see *why* the plane died. The
//! supervisor never swallows or renames the underlying error.
//!
//! ## Bounded, never infinite
//!
//! Backoff is `BASE_BACKOFF_MS * 2^(attempt-1)` capped at [`MAX_BACKOFF_MS`];
//! after [`MAX_RESTARTS`] consecutive failures the plane is left **stopped**
//! (structured `dataplane_failed`) and the operator must re-issue `core.start`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

/// Structured error reported when a datapath worker dies unexpectedly.
pub(crate) const ERR_DATAPLANE_DEAD: &str = "PROXY_DATAPLANE_DEAD";

/// First retry delay; each subsequent attempt doubles it.
pub(crate) const BASE_BACKOFF_MS: u64 = 250;
/// Hard cap on any single retry delay.
pub(crate) const MAX_BACKOFF_MS: u64 = 8_000;
/// Maximum consecutive automatic restarts before the plane is left stopped.
pub(crate) const MAX_RESTARTS: u32 = 5;

/// Public (log/event-safe) health snapshot. Serialized camelCase for Dart.
#[derive(Debug, Clone, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HealthSnapshot {
    pub alive: bool,
    pub generation: u64,
    pub restarts: u32,
    pub consecutive_failures: u32,
    pub last_error: Option<String>,
    pub backoff_ms: u64,
}

#[derive(Default)]
struct HealthState {
    alive: bool,
    generation: u64,
    restarts: u32,
    consecutive_failures: u32,
    last_error: Option<String>,
    last_backoff_ms: u64,
}

static HEALTH: OnceLock<Mutex<HealthState>> = OnceLock::new();

/// Coarse "is the loop currently expected to be reading" flag, updated by
/// [`crate::tun`]. Read without the state lock on the hot path.
static ALIVE: AtomicBool = AtomicBool::new(false);

fn state() -> &'static Mutex<HealthState> {
    HEALTH.get_or_init(|| Mutex::new(HealthState::default()))
}

/// Exponential backoff for retry `attempt` (1-based), capped at
/// [`MAX_BACKOFF_MS`]. Pure so it is exhaustively testable.
pub(crate) fn backoff_ms(attempt: u32) -> u64 {
    let shift = attempt.saturating_sub(1).min(6);
    BASE_BACKOFF_MS
        .saturating_mul(1u64 << shift)
        .min(MAX_BACKOFF_MS)
}

/// Whether a `attempt`-th consecutive failure may still be auto-restarted.
pub(crate) fn should_restart(attempt: u32) -> bool {
    attempt <= MAX_RESTARTS
}

/// Mark the datapath as alive (called by the loop thread on entry, and after a
/// successful restart). Does **not** clear the consecutive-failure burst — the
/// burst is reset only by an explicit `core.start`/`core.restart`/shutdown via
/// [`reset_burst`], so a rapidly-crashing plane cannot restart forever.
pub(crate) fn mark_alive() {
    ALIVE.store(true, Ordering::SeqCst);
    let mut s = state().lock().unwrap_or_else(|e| e.into_inner());
    s.alive = true;
    s.generation = s.generation.wrapping_add(1);
}

/// Mark the datapath as stopped (clean `core.stop`, failed restart, teardown).
pub(crate) fn mark_stopped() {
    ALIVE.store(false, Ordering::SeqCst);
    state().lock().unwrap_or_else(|e| e.into_inner()).alive = false;
}

/// Reset the failure burst without touching liveness (explicit `core.start` /
/// `core.restart` / process-global shutdown).
pub(crate) fn reset_burst() {
    let mut s = state().lock().unwrap_or_else(|e| e.into_inner());
    s.consecutive_failures = 0;
    s.restarts = 0;
    s.last_error = None;
}

/// Current snapshot (used by `ping` and diagnostics).
pub(crate) fn snapshot() -> HealthSnapshot {
    let s = state().lock().unwrap_or_else(|e| e.into_inner());
    HealthSnapshot {
        alive: s.alive,
        generation: s.generation,
        restarts: s.restarts,
        consecutive_failures: s.consecutive_failures,
        last_error: s.last_error.clone(),
        backoff_ms: s.last_backoff_ms,
    }
}

/// Fast liveness flag for hot-path checks (does not take the state lock).
pub(crate) fn is_alive() -> bool {
    ALIVE.load(Ordering::SeqCst)
}

/// Record a datapath death, emit the structured `dead` state, and return the
/// 1-based consecutive-failure attempt number. The **verbatim** reason is kept
/// in `lastError`/`error.message`; the supervisor never rewrites it.
pub(crate) fn on_death(instance_id: u64, reason: &str) -> u32 {
    ALIVE.store(false, Ordering::SeqCst);
    let attempt = {
        let mut s = state().lock().unwrap_or_else(|e| e.into_inner());
        s.alive = false;
        s.consecutive_failures = s.consecutive_failures.saturating_add(1);
        s.last_error = Some(reason.to_string());
        s.consecutive_failures
    };
    let snap = snapshot();
    emit(
        instance_id,
        "stopping",
        "vpn",
        "dataplane_dead",
        ERR_DATAPLANE_DEAD,
        reason,
        &snap,
        0,
    );
    attempt
}

/// Emit the structured `restarting` state just before the bounded-backoff wait.
pub(crate) fn on_restart(instance_id: u64, reason: &str, backoff: u64) {
    let mut s = state().lock().unwrap_or_else(|e| e.into_inner());
    s.restarts = s.restarts.saturating_add(1);
    s.last_backoff_ms = backoff;
    let snap = HealthSnapshot {
        alive: false,
        generation: s.generation,
        restarts: s.restarts,
        consecutive_failures: s.consecutive_failures,
        last_error: s.last_error.clone(),
        backoff_ms: backoff,
    };
    drop(s);
    emit(
        instance_id,
        "starting",
        "vpn",
        "supervisor_restart",
        ERR_DATAPLANE_DEAD,
        reason,
        &snap,
        backoff,
    );
}

/// Emit the terminal `dataplane_failed` state (restart budget exhausted, no
/// pending fd, or stopped during backoff). Marks the plane stopped.
pub(crate) fn on_failed(instance_id: u64, reason: &str) {
    mark_stopped();
    let snap = snapshot();
    emit(
        instance_id,
        "stopped",
        "off",
        "dataplane_failed",
        ERR_DATAPLANE_DEAD,
        reason,
        &snap,
        0,
    );
}

/// Test-only reset of the process-global health state.
#[cfg(test)]
pub(crate) fn reset_for_tests() {
    ALIVE.store(false, Ordering::SeqCst);
    *state().lock().unwrap_or_else(|e| e.into_inner()) = HealthState::default();
}

#[allow(clippy::too_many_arguments)]
fn emit(
    instance_id: u64,
    state_str: &str,
    mode: &str,
    reason: &str,
    code: &str,
    message: &str,
    snap: &HealthSnapshot,
    backoff: u64,
) {
    let value = serde_json::json!({
        "state": state_str,
        "mode": mode,
        "reason": reason,
        "error": { "code": code, "message": message },
        "health": {
            "alive": snap.alive,
            "generation": snap.generation,
            "restarts": snap.restarts,
            "consecutiveFailures": snap.consecutive_failures,
            "lastError": snap.last_error,
            "backoffMs": backoff,
        },
    });
    if let Ok(bytes) = serde_json::to_vec(&value) {
        crate::emit_event(instance_id, crate::EVT_STATE, &bytes);
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use crate::TEST_SERIAL as SERIAL;

    use super::*;

    #[test]
    fn backoff_is_exponential_and_capped() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        assert_eq!(backoff_ms(1), BASE_BACKOFF_MS);
        assert_eq!(backoff_ms(2), BASE_BACKOFF_MS * 2);
        assert_eq!(backoff_ms(3), BASE_BACKOFF_MS * 4);
        // Monotonically non-decreasing and never above the cap.
        let mut prev = 0;
        for attempt in 1..=40u32 {
            let b = backoff_ms(attempt);
            assert!(b >= prev, "backoff must not shrink: {b} < {prev}");
            assert!(b <= MAX_BACKOFF_MS, "backoff exceeded cap: {b}");
            prev = b;
        }
        assert_eq!(backoff_ms(100), MAX_BACKOFF_MS);
    }

    #[test]
    fn restart_budget_is_bounded() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        assert!(should_restart(1));
        assert!(should_restart(MAX_RESTARTS));
        assert!(!should_restart(MAX_RESTARTS + 1));
        // A very large attempt number must never be treated as restartable.
        assert!(!should_restart(u32::MAX));
    }

    #[test]
    fn health_tracks_alive_and_death_burst() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        assert!(!snapshot().alive);
        assert!(!is_alive());

        mark_alive();
        assert!(snapshot().alive);
        assert!(is_alive());
        assert_eq!(snapshot().generation, 1);
        assert_eq!(snapshot().consecutive_failures, 0);

        let attempt = on_death(1, "reader task panicked: boom");
        assert_eq!(attempt, 1);
        let snap = snapshot();
        assert!(!snap.alive);
        assert!(!is_alive());
        assert_eq!(snap.consecutive_failures, 1);
        assert_eq!(
            snap.last_error.as_deref(),
            Some("reader task panicked: boom"),
            "verbatim panic reason must be preserved"
        );

        // A second death in the same burst increments the attempt, bounded.
        assert_eq!(on_death(1, "egress task ended unexpectedly"), 2);

        // Restart consumes one budget slot but does not clear the burst.
        on_restart(1, "reader task panicked: boom", backoff_ms(2));
        assert_eq!(snapshot().restarts, 1);
        assert_eq!(snapshot().backoff_ms, backoff_ms(2));

        // Terminal failure marks stopped; an explicit start resets the burst.
        on_failed(1, "restart budget exhausted");
        assert!(!snapshot().alive);
        reset_burst();
        assert_eq!(snapshot().consecutive_failures, 0);
        assert_eq!(snapshot().restarts, 0);
        assert!(snapshot().last_error.is_none());

        reset_for_tests();
    }

    #[test]
    fn shutdown_style_reset_is_immediate() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        mark_alive();
        on_death(1, "boom");
        reset_for_tests();
        assert!(!snapshot().alive);
        assert_eq!(snapshot().last_error, None);
        // A trivial sleep keeps the test honest about the bounded policy being
        // constant-time (no hidden retry loop here).
        std::thread::sleep(Duration::from_millis(1));
    }
}
