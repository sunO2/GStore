//! Run-mode state machine (Todo 29).
//!
//! The module exposes three first-class run modes — `off`, `vpn`, `lanProxy` —
//! through `core.set_mode` / `core.get_mode`. **All mode state and transitions
//! live here (Rust); Dart only renders and requests.**
//!
//! ## Exact state machine
//!
//! * `vpn` — start `VpnService` (Kotlin, before the module is asked), hand the
//!   `establish()` fd to `tun.set_fd`, then ring the single TUN reader
//!   ([`crate::tun`]) **and install the `SocketProtector`** (every outbound is
//!   protected). LAN listeners also start when the LAN config is enabled.
//! * `lanProxy` — **no `VpnService`, no TUN reader, no protect hook**: engine +
//!   LAN inbounds only, so other devices use the phone as a proxy while the
//!   phone's own traffic is *not* tunneled. The protector is explicitly cleared
//!   (calling `VpnService.protect` with no active VPN would fail and meow would
//!   error on every dial).
//! * `off` — engine stopped, listeners closed, (Kotlin) service stopped.
//!
//! ## Guarantees
//!
//! * **Single mutation lane** ([`lane`]): every engine/mode transition is
//!   serialized, so two modes can never run at once.
//! * **Fully stop before start** — Todo 24's teardown ordering (stop reader →
//!   join → clear protect → stop service) is applied before the next mode is
//!   started.
//! * **Idempotent** — switching to the already-current, *resource-consistent*
//!   mode is a no-op (and emits no events). If a mode's resources are missing
//!   (e.g. a stray listener while `off`), re-selecting it self-heals.
//! * **Profile/node/rule/DNS state is preserved** across a switch (the mode
//!   machine never touches the profile store, selection store, rule state or
//!   DNS config; the engine is simply rebuilt from them).
//! * **Last-used mode is persisted** to `<dataDir>/mode.json`; `core.get_mode`
//!   reports it as `lastMode`. A fresh instance starts `off` (never auto-starts
//!   a mode: `vpn` needs a live fd/consent).

use std::sync::{Arc, Mutex, MutexGuard};

use gstore_contract::error::{ModuleError, StatusCode};
use serde::{Deserialize, Serialize};

use crate::{ProxyInstance, ProxyMode, ProxyRunState};

/// `core.set_mode` target has no usable inbound (`lanProxy` with LAN disabled).
pub(crate) const ERR_NO_INBOUND: &str = "PROXY_NO_INBOUND";
/// `core.set_mode` / `core.start` received an unknown `mode` string.
pub(crate) const ERR_MODE_INVALID: &str = "PROXY_MODE_INVALID";

/// Persisted last-used mode file (inside `<dataDir>`).
const MODE_FILE: &str = "mode.json";

/// The single mutation lane. Held for the whole of a mode/engine transition.
static LANE: Mutex<()> = Mutex::new(());

/// Acquire the mode mutation lane. Poison-safe: a panic elsewhere must not turn
/// a mode switch into a permanent failure.
pub(crate) fn lane() -> MutexGuard<'static, ()> {
    LANE.lock().unwrap_or_else(|e| e.into_inner())
}

/// Parse a wire mode string (`off` | `vpn` | `lanProxy`).
pub(crate) fn parse_wire(s: &str) -> Option<ProxyMode> {
    match s {
        "off" => Some(ProxyMode::Off),
        "vpn" => Some(ProxyMode::Vpn),
        "lanProxy" => Some(ProxyMode::LanProxy),
        _ => None,
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedMode {
    mode: String,
    updated_at_ms: u64,
}

/// Read the last-used mode from disk (default `off`).
pub(crate) fn load_last_mode(data_dir: &str) -> ProxyMode {
    if data_dir.trim().is_empty() {
        return ProxyMode::Off;
    }
    let path = std::path::Path::new(data_dir).join(MODE_FILE);
    let Ok(bytes) = std::fs::read(&path) else {
        return ProxyMode::Off;
    };
    match serde_json::from_slice::<PersistedMode>(&bytes) {
        Ok(p) => parse_wire(&p.mode).unwrap_or(ProxyMode::Off),
        Err(_) => ProxyMode::Off,
    }
}

fn persist(data_dir: &str, mode: ProxyMode) {
    let dir = data_dir.trim();
    if dir.is_empty() {
        return;
    }
    let payload = PersistedMode {
        mode: mode.as_str().to_string(),
        updated_at_ms: crate::now_ms(),
    };
    if let Ok(bytes) = serde_json::to_vec(&payload) {
        let _ = std::fs::write(std::path::Path::new(dir).join(MODE_FILE), bytes);
    }
}

/// Record a successful transition: update the in-memory `lastMode` and persist.
fn record(inst: &ProxyInstance, mode: ProxyMode) {
    *inst.last_mode.lock().unwrap_or_else(|e| e.into_inner()) = mode;
    persist(&inst.data_dir, mode);
}

/// Outcome of a `core.set_mode` / `core.start` / `core.stop` transition.
pub(crate) struct Transition {
    pub previous: ProxyMode,
    pub mode: ProxyMode,
    pub spawned: bool,
    pub summary: Option<serde_json::Value>,
    pub idempotent: bool,
}

/// Whether the current resources match what `mode` promises. This is what makes
/// an idempotent re-selection a true no-op *and* lets a re-selection self-heal a
/// missing/stray resource.
fn is_consistent(inst: &ProxyInstance, mode: ProxyMode) -> bool {
    let state = crate::current_state(inst);
    match mode {
        ProxyMode::Off => {
            state == ProxyRunState::Stopped
                && !crate::tun::is_running()
                && !crate::lan::is_bound()
        }
        ProxyMode::Vpn => state == ProxyRunState::Running && crate::tun::is_running(),
        ProxyMode::LanProxy => {
            state == ProxyRunState::Running
                && !crate::tun::is_running()
                && crate::lan::is_bound()
        }
    }
}

/// Apply a mode transition under the caller-held [`lane`].
///
/// `force` skips the idempotent fast-path (used by `core.restart`, which must
/// rebuild the tunnel even when the mode is unchanged).
///
/// Validation happens **before** any teardown, so an impossible switch leaves
/// the current mode completely untouched.
pub(crate) fn apply(
    inst: &Arc<ProxyInstance>,
    target: ProxyMode,
    payload: &[u8],
    force: bool,
) -> Result<Transition, ModuleError> {
    let previous = crate::current_mode(inst);
    let prev_state = crate::current_state(inst);

    if !force && target == previous && is_consistent(inst, target) {
        // Never lose the single driver to the early return: `stats_monitor::start`
        // is idempotent, so re-arming a stopped ticker is a no-op when it is live.
        match target {
            ProxyMode::Off => {
                crate::stats_monitor::stop();
            }
            ProxyMode::Vpn | ProxyMode::LanProxy => crate::stats_monitor::start(inst.id),
        }
        return Ok(Transition {
            previous,
            mode: target,
            spawned: false,
            summary: None,
            idempotent: true,
        });
    }

    // ---- validate target before tearing anything down ----
    if target == ProxyMode::LanProxy && !crate::lan::get().enabled {
        return Err(ModuleError::new(
            StatusCode::InvalidArgument,
            ERR_NO_INBOUND,
            "lanProxy requires an enabled LAN listener; enable 局域网监听 (lan.set enabled=true) \
             or choose VPN mode",
        ));
    }
    if target == ProxyMode::Vpn
        && !crate::tun::has_pending()
        && !(force && crate::tun::has_last())
    {
        return Err(ModuleError::new(
            StatusCode::InvalidArgument,
            crate::tun::ERR_TUN_FD_INVALID,
            "no TUN fd installed; call tun.set_fd (VpnService establish) before switching to vpn",
        ));
    }

    // ---- STOP the current mode fully (Todo 24 ordering) ----
    let was_active = prev_state != ProxyRunState::Stopped || previous != ProxyMode::Off;
    if was_active {
        crate::emit_state_progress(
            inst.id,
            ProxyRunState::Stopping,
            previous,
            "mode.switch",
            target,
        );
        crate::controller::stop();
        if let Some(s) = crate::tun::stop() {
            crate::emit_tun_released(s.instance_id, s.host_fd);
        }
        // `lanProxy`/`off` must never carry a protect hook. `clear()` is
        // idempotent and also calls `meow_common::clear_socket_protector()` on
        // Android, so meow never dials with a dead `VpnService.protect`.
        crate::protect::clear();
    }
    // A mode owns its inbounds: close any listener before the new mode binds.
    crate::lan::stop();

    if target == ProxyMode::Off {
        crate::stats_monitor::stop();
        crate::set_state(inst, ProxyRunState::Stopped);
        crate::set_mode(inst, ProxyMode::Off);
        record(inst, ProxyMode::Off);
        crate::emit_mode(inst.id, ProxyMode::Off, previous);
        crate::emit_state(inst.id, ProxyRunState::Stopped, ProxyMode::Off, None);
        return Ok(Transition {
            previous,
            mode: ProxyMode::Off,
            spawned: false,
            summary: None,
            idempotent: false,
        });
    }

    // ---- START the target ----
    crate::emit_state_progress(
        inst.id,
        ProxyRunState::Starting,
        target,
        "mode.switch",
        target,
    );
    let (spawned, summary) = match start_target(inst, target, payload, force) {
        Ok(v) => v,
        Err(e) => {
            // A failed start must never leave a half-applied mode: fall back to
            // a fully stopped, protector-free `off`.
            crate::stats_monitor::stop();
            crate::protect::clear();
            crate::lan::stop();
            crate::set_state(inst, ProxyRunState::Stopped);
            crate::set_mode(inst, ProxyMode::Off);
            record(inst, ProxyMode::Off);
            crate::emit_state(
                inst.id,
                ProxyRunState::Stopped,
                ProxyMode::Off,
                Some("mode.switch.failed"),
            );
            return Err(e);
        }
    };

    // The engine is now attached (VPN `start_engine` / LAN `reconcile_result`),
    // so the single engine ticker can start for this instance.
    crate::stats_monitor::start(inst.id);
    record(inst, target);
    crate::emit_mode(inst.id, target, previous);
    crate::emit_state(inst.id, ProxyRunState::Running, target, None);
    Ok(Transition {
        previous,
        mode: target,
        spawned,
        summary,
        idempotent: false,
    })
}

fn start_target(
    inst: &Arc<ProxyInstance>,
    target: ProxyMode,
    payload: &[u8],
    force: bool,
) -> Result<(bool, Option<serde_json::Value>), ModuleError> {
    match target {
        ProxyMode::Vpn => {
            // A forced restart re-dups the still-open host fd (the previous loop
            // consumed our duplicate). A normal switch requires a fresh fd from
            // Kotlin (`tun.set_fd`) — validated before teardown.
            if force && !crate::tun::has_pending() {
                crate::tun::ensure_pending_from_last()?;
            }
            let out = crate::start_engine(inst, payload)?;
            crate::set_state(inst, ProxyRunState::Running);
            crate::set_mode(inst, ProxyMode::Vpn);
            Ok(out)
        }
        ProxyMode::LanProxy => {
            // Engine + LAN inbounds only: no VpnService, no TUN reader, no hook.
            crate::protect::clear();
            crate::lan::reconcile_result()?;
            crate::set_state(inst, ProxyRunState::Running);
            crate::set_mode(inst, ProxyMode::LanProxy);
            Ok((false, None))
        }
        ProxyMode::Off => Ok((false, None)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_wire_accepts_exactly_the_three_modes() {
        assert_eq!(parse_wire("off"), Some(ProxyMode::Off));
        assert_eq!(parse_wire("vpn"), Some(ProxyMode::Vpn));
        assert_eq!(parse_wire("lanProxy"), Some(ProxyMode::LanProxy));
        assert_eq!(parse_wire("VPN"), None);
        assert_eq!(parse_wire(""), None);
        assert_eq!(parse_wire("lan"), None);
    }

    #[test]
    fn last_mode_round_trips_through_disk_and_defaults_to_off() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("gstore-mode-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.to_str().unwrap();

        assert_eq!(load_last_mode(path), ProxyMode::Off, "missing file -> off");
        for mode in [ProxyMode::Vpn, ProxyMode::LanProxy, ProxyMode::Off] {
            persist(path, mode);
            assert_eq!(load_last_mode(path), mode, "persisted {mode:?} must round-trip");
        }
        // A corrupt file degrades to off instead of panicking.
        std::fs::write(dir.join(MODE_FILE), b"{not json").unwrap();
        assert_eq!(load_last_mode(path), ProxyMode::Off);
        // An unknown mode string also degrades to off.
        std::fs::write(
            dir.join(MODE_FILE),
            br#"{"mode":"bogus","updatedAtMs":1}"#,
        )
        .unwrap();
        assert_eq!(load_last_mode(path), ProxyMode::Off);
        // An empty data dir never touches the filesystem.
        assert_eq!(load_last_mode(""), ProxyMode::Off);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
