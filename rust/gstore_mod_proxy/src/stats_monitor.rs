//! Engine-level statistics ticker.
//!
//! [`crate::stats::tick`] is the only producer of the throttled `proxy.stats`
//! snapshot. It used to be driven by the TUN flow-dispatch loop
//! ([`crate::dispatch`]): with no TUN attached — LAN-proxy mode, or before
//! `tun.set_fd` — nothing ever ticked, so the home page's 实时流量 stayed at zero
//! even though LAN connections were already counted by meow's relay.
//!
//! The ticker is a property of the **engine**, not of the TUN: exactly one
//! driver runs per process whenever an engine is live, in every mode. It is
//! started/stopped by the mode machine ([`crate::mode`]) and `destroy`/
//! `shutdown`, and it resolves [`crate::rules::active_tunnel`] on every tick so
//! a supervisor TUN restart (which rebuilds the tunnel) keeps reporting the
//! live engine without re-registering.
//!
//! Runs on one dedicated OS thread with the crate's bounded runtime
//! ([`crate::bounded_runtime`], never `Runtime::new()`); [`stop`] signals and
//! joins it, so no ticker outlives `core.stop` / `destroy` (the Final Wave
//! checks bounded runtimes and clean shutdown).

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// A live ticker: its stop signal, the joined-at-stop thread, and the instance
/// id its `drive` resolves the mode from.
struct Running {
    stop: tokio::sync::oneshot::Sender<()>,
    thread: std::thread::JoinHandle<()>,
    #[cfg_attr(not(test), allow(dead_code))]
    instance_id: u64,
}

static RUNNING: OnceLock<Mutex<Option<Running>>> = OnceLock::new();
/// Live ticker threads (0 after `stop`), the no-leak/single-driver proof.
static COUNT: AtomicUsize = AtomicUsize::new(0);

fn cell() -> &'static Mutex<Option<Running>> {
    RUNNING.get_or_init(|| Mutex::new(None))
}

/// One engine tick: fold the live engine's connection table into the per-domain
/// aggregate, emit the throttled `proxy.stats` snapshot, flush SQLite, and emit
/// the throttled `proxy.request` dirty signal. Missing tunnel (LAN async-attach
/// window) is tolerated: the stats fold is skipped and the rest still runs.
///
/// Factored out of the thread body so it is directly testable. Resolving the
/// tunnel here (rather than holding an `Arc<TunnelInner>`) keeps the driver
/// correct across a supervisor restart, which builds a fresh tunnel.
pub(crate) fn drive(instance_id: u64, now: u64) {
    if let Some(tunnel) = crate::rules::active_tunnel() {
        crate::stats::tick(&tunnel.inner().stats, instance_id, now);
    }
    crate::stats::maybe_persist(now);
    // Resolve the mode from the ticker's held instance (same fact source as
    // `mode::apply`); a destroyed/unknown instance degrades to `Off`. Never
    // `active_tunnel().is_some()`, which is true after a LAN engine attach and
    // would mis-gate the T11 UID query.
    let mode = crate::instance_of(instance_id)
        .map(|inst| crate::current_mode(&inst))
        .unwrap_or(crate::ProxyMode::Off);
    crate::requests::tick(instance_id, mode, now);
    crate::captures::maybe_persist(now);
}

/// Start the engine ticker if one is not already live. Idempotent: a second
/// call never spawns a second driver. A finished thread (e.g. after a panic) is
/// replaced so the ticker self-heals.
pub(crate) fn start(instance_id: u64) {
    let mut guard = cell().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(existing) = guard.as_ref() {
        if !existing.thread.is_finished() {
            return;
        }
    }
    if let Some(dead) = guard.take() {
        let _ = dead.thread.join();
        COUNT.fetch_sub(1, Ordering::SeqCst);
    }
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    match std::thread::Builder::new()
        .name("gstore-proxy-stats".to_string())
        .spawn(move || run(instance_id, stop_rx))
    {
        Ok(thread) => {
            COUNT.fetch_add(1, Ordering::SeqCst);
            *guard = Some(Running {
                stop: stop_tx,
                thread,
                instance_id,
            });
        }
        Err(e) => crate::log_message(3, &format!("proxy.stats: ticker spawn failed: {e}")),
    }
}

/// Stop and join the engine ticker. Returns whether one was running. Idempotent
/// and safe to call from any teardown path.
pub(crate) fn stop() -> bool {
    let taken = cell().lock().unwrap_or_else(|e| e.into_inner()).take();
    match taken {
        Some(running) => {
            let _ = running.stop.send(());
            if running.thread.join().is_err() {
                crate::log_message(3, "proxy.stats: ticker thread panicked during teardown");
            }
            COUNT.fetch_sub(1, Ordering::SeqCst);
            true
        }
        None => false,
    }
}

/// Whether the engine ticker is currently live. Test proof for the single-driver
/// invariant.
#[allow(dead_code)]
pub(crate) fn is_running() -> bool {
    cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .map(|r| !r.thread.is_finished())
        .unwrap_or(false)
}

/// Live ticker threads (0 after `stop`). Test proof for the no-leak/single-driver
/// invariant.
#[allow(dead_code)]
pub(crate) fn running_count() -> usize {
    COUNT.load(Ordering::SeqCst)
}

/// The instance id the live ticker currently holds; `None` when stopped. Test
/// proof that a `core.stop` → `core.start` cycle re-arms the driver on the
/// current (possibly new) instance instead of a stale id.
#[cfg(test)]
pub(crate) fn held_instance_for_tests() -> Option<u64> {
    cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .map(|r| r.instance_id)
}

/// The dedicated thread body: a bounded-runtime interval loop, stopped by
/// `stop`'s oneshot. Same cadence as the old TUN dispatch ticker.
fn run(instance_id: u64, stop: tokio::sync::oneshot::Receiver<()>) {
    let rt = match crate::bounded_runtime() {
        Ok(rt) => rt,
        Err(e) => {
            crate::log_message(3, &format!("proxy.stats: ticker runtime build failed: {e}"));
            return;
        }
    };
    rt.block_on(async move {
        let mut ticker = tokio::time::interval(Duration::from_millis(crate::stats::STATS_TICK_MS));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut stop = stop;
        loop {
            tokio::select! {
                _ = &mut stop => break,
                _ = ticker.tick() => drive(instance_id, crate::now_ms()),
            }
        }
    });
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::TEST_SERIAL as SERIAL;

    fn fixture_engine() -> Arc<meow_tunnel::Tunnel> {
        crate::tun::shutdown();
        crate::rules::reset_for_tests();
        crate::conn::reset_for_tests();
        crate::stats::reset_for_tests();
        let resolver = Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ));
        let _ = crate::dispatch::build_engine(resolver);
        crate::rules::active_tunnel().expect("fixture engine attached")
    }

    fn cleanup() {
        stop();
        crate::rules::reset_for_tests();
        crate::conn::reset_for_tests();
        crate::stats::reset_for_tests();
    }

    /// The engine ticker aggregates a live connection **without any TUN**, which
    /// is exactly the LAN-proxy mode the old TUN-owned ticker never covered.
    /// `drive` runs on this thread, so it reads the same test store the
    /// projection readers use.
    #[test]
    fn drive_aggregates_engine_stats_without_a_tun() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let tunnel = fixture_engine();
        assert!(!crate::tun::is_running(), "precondition: no TUN attached");

        let stats = tunnel.statistics();
        let id = stats.track_connection(
            meow_common::Metadata {
                network: meow_common::Network::Tcp,
                conn_type: meow_common::ConnType::Tun,
                host: "lan.example".into(),
                dst_ip: Some("1.2.3.4".parse().unwrap()),
                dst_port: 443,
                src_ip: Some("192.168.1.9".parse().unwrap()),
                src_port: 51000,
                ..Default::default()
            },
            smol_str::SmolStr::new("MATCH"),
            smol_str::SmolStr::new(""),
            smallvec::SmallVec::from_vec(vec![Arc::<str>::from("DIRECT")]),
        );
        let counters = stats.connection_counters(id).expect("counters");
        stats.record_upload(&counters, 4096);
        stats.record_download(&counters, 8192);

        let before = crate::stats::last_emit_for_tests();
        drive(7, crate::now_ms());

        let data = crate::stats::traffic_get_arm(b"").unwrap();
        let json: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(json["data"]["uploadBytes"], 4096);
        assert_eq!(json["data"]["downloadBytes"], 8192);
        assert_eq!(json["data"]["activeConns"], 1);
        assert_eq!(json["data"]["topDomains"][0]["domain"], "lan.example");
        assert!(
            crate::stats::last_emit_for_tests() > before,
            "the engine tick must emit the throttled snapshot"
        );

        cleanup();
    }

    /// Exactly one driver: a second `start` is a no-op, `stop` joins it, and a
    /// later `start` yields a fresh one (the core.stop/core.start invariant).
    #[test]
    fn ticker_is_a_single_driver_and_stop_joins() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        crate::conn::reset_for_tests();
        crate::stats::reset_for_tests();
        stop();

        assert!(!is_running());
        assert!(!stop(), "stop with no ticker is a no-op");

        start(7);
        assert!(is_running());
        assert_eq!(running_count(), 1);

        start(7);
        assert_eq!(running_count(), 1, "a second start must not spawn a driver");

        assert!(stop());
        assert!(!is_running());
        assert_eq!(running_count(), 0, "stop joins the ticker thread");
        assert!(!stop(), "second stop is a no-op");

        start(7);
        assert_eq!(running_count(), 1, "a later start yields a fresh driver");
        assert!(stop());
        assert_eq!(running_count(), 0);

        cleanup();
    }
}
