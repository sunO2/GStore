//! TUN datapath: a **single-reader** packet loop over `meow_lwip::NetStack`.
//!
//! Todo 6 of `.omo/plans/vpn-proxy-kernel.md`.
//!
//! ## Why we drive the netstack ourselves
//!
//! meow's `TunListener` builds its **own** `tun_rs` device by interface name
//! (`crates/meow-listener/src/tun/mod.rs:411`) and cannot consume an Android
//! `VpnService.establish()` fd. We therefore take the raw fd from the host and
//! shuttle IP frames between that fd and [`meow_lwip::NetStack`] directly — the
//! exact path proven by the Todo 1 hard gate (`datapath_selftest`).
//!
//! ## fd ownership (pinned)
//!
//! - Kotlin owns the `ParcelFileDescriptor`; it passes only the raw integer fd.
//! - We [`libc::dup`] it once and wrap the duplicate in an [`OwnedFd`]. All
//!   reads/writes go through that duplicate, so dropping it (loop teardown)
//!   **never closes Kotlin's fd**. We never close the host fd here.
//! - We set `O_NONBLOCK` on the duplicate. Note `O_NONBLOCK` is a *file status*
//!   flag shared by all descriptors of the same open file description, so it is
//!   visible through the host fd too — this is what `madeye/meow`'s
//!   `tun2socks.rs` does as well, and `VpnService` fds are expected to be used
//!   non-blocking.
//! - Teardown order: stop the loop (watch signal) → abort the reader/ingress/
//!   egress tasks → join the dedicated thread → wait for lwIP `core_done` →
//!   return, at which point the caller (`core.stop`) emits `proxy.tun.released`
//!   so the host may clear its cached fd; Kotlin then closes the PFD.
//!
//! ## Exactly one reader, ever
//!
//! All TUN state lives in a process-global [`TunState`] guarded by a mutex. At
//! most one [`ActiveLoop`] exists; `start` is idempotent while running and
//! `install_fd` tears an existing loop down *before* replacing the fd. A second
//! reader is impossible by construction, and [`READ_COUNT`] is exposed so the
//! test suite can prove a frame is consumed exactly once.
//!
//! The loop runs on one std thread *we own*, inside the module's bounded
//! [`crate::bounded_runtime`] (`new_multi_thread().worker_threads(4)`), never
//! `Runtime::new()` (Android SIGSEGV, `rust/gstore_mod_repo/src/lib.rs:117-120`).

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::raw::c_void;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::shaper;
use futures::{FutureExt, SinkExt, StreamExt};
use gstore_contract::error::{ModuleError, StatusCode};
use tokio::io::unix::AsyncFd;
use tokio::sync::{mpsc, watch};

/// Domain error code for an unusable / missing TUN fd (`rust/ERROR_CODES.md`).
pub(crate) const ERR_TUN_FD_INVALID: &str = "PROXY_TUN_FD_INVALID";

const LOOP_THREAD_NAME: &str = "gstore-proxy-tun";
/// Per-read buffer. Covers any TUN MTU (Kotlin default 1500) with headroom;
/// the TUN read truncates at this bound, so it is also the max frame size.
pub(crate) const READ_BUFFER_SIZE: usize = 65_535;
/// lwIP core ingress/egress channel depth (`NetStack::with_buffer_size` first
/// arg). meow's `NetStack::new()` uses 512; the module deliberately doubles it
/// to absorb bursty TUN reads (Todo 27 budget in [`crate::limits`]).
pub(crate) const STACK_BUFFER_SIZE: usize = 1024;
/// lwIP UDP channel depth (`with_buffer_size` second arg). meow's default is
/// 64; the module uses 4x for DNS/QUIC bursts.
pub(crate) const UDP_BUFFER_SIZE: usize = 256;
/// Bounded reader → ingress-pump queue depth. Each queued item is one IP frame
/// (MTU-sized in practice), so worst-case retained bytes are bounded by
/// `INGRESS_CHANNEL * MTU` (see [`crate::limits::worst_case_bytes`]).
pub(crate) const INGRESS_CHANNEL: usize = 256;
const CORE_DONE_TIMEOUT: Duration = Duration::from_secs(3);
const ENGINE_READY_TIMEOUT: Duration = Duration::from_secs(3);

/// A live loop: the dedicated thread plus its stop signal.
struct ActiveLoop {
    stop_tx: watch::Sender<bool>,
    join: std::thread::JoinHandle<()>,
    /// Kotlin's original fd — reported in `proxy.tun.released`, never closed here.
    host_fd: RawFd,
    /// Instance that started the loop (event attribution).
    instance_id: u64,
}

/// Everything the loop owns. `pending` holds our `dup` until `core.start`.
struct TunState {
    pending: Option<OwnedFd>,
    pending_host_fd: RawFd,
    /// Last host fd we saw. Retained across `stop` so `core.restart` can re-dup
    /// it while the host still holds it open.
    last_host_fd: RawFd,
    active: Option<ActiveLoop>,
}

static TUN: OnceLock<Mutex<TunState>> = OnceLock::new();

/// Number of live TUN loop threads (incremented on spawn, decremented on exit).
static RUNNING: AtomicUsize = AtomicUsize::new(0);

/// Number of successful fd reads performed by the single reader (test proof).
static READ_COUNT: AtomicUsize = AtomicUsize::new(0);

fn state() -> &'static Mutex<TunState> {
    TUN.get_or_init(|| {
        Mutex::new(TunState {
            pending: None,
            pending_host_fd: -1,
            last_host_fd: -1,
            active: None,
        })
    })
}

fn invalid_fd(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_TUN_FD_INVALID, message)
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// What a successful `tun.set_fd` returns to the caller.
#[derive(Debug)]
pub(crate) struct InstalledFd {
    pub host_fd: RawFd,
    /// True when an already-running loop was torn down to accept this fd.
    pub replaced_running: bool,
}

/// Validate + `dup` + `O_NONBLOCK` a host fd. Never touches the host fd itself.
fn dup_nonblocking(host_fd: RawFd) -> Result<OwnedFd, ModuleError> {
    if host_fd < 0 {
        return Err(invalid_fd(format!("fd {host_fd} < 0")));
    }
    // `F_GETFD` proves the descriptor is actually open in this process; a stale
    // integer or a closed PFD fails here with a structured error, never a panic.
    if unsafe { libc::fcntl(host_fd, libc::F_GETFD) } < 0 {
        return Err(invalid_fd(format!(
            "fd {host_fd} is not an open descriptor: {}",
            io::Error::last_os_error()
        )));
    }
    let dup = unsafe { libc::dup(host_fd) };
    if dup < 0 {
        return Err(invalid_fd(format!(
            "dup({host_fd}) failed: {}",
            io::Error::last_os_error()
        )));
    }
    let owned = unsafe { OwnedFd::from_raw_fd(dup) };
    if let Err(e) = set_nonblocking(owned.as_raw_fd()) {
        return Err(invalid_fd(format!(
            "set O_NONBLOCK on fd {host_fd} failed: {e}"
        )));
    }
    Ok(owned)
}

/// `tun.set_fd`: validate the host fd, `dup` it, set `O_NONBLOCK`, and store the
/// duplicate as the *pending* fd for `core.start`. Kotlin's fd is never closed.
pub(crate) fn install_fd(host_fd: RawFd) -> Result<InstalledFd, ModuleError> {
    let owned = dup_nonblocking(host_fd)?;

    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    // Replace semantics: a running loop must be fully joined before its fd is
    // retired, otherwise a second reader could exist.
    let replaced_running = match st.active.take() {
        Some(active) => {
            stop_and_join(active);
            true
        }
        None => false,
    };
    st.pending = Some(owned); // drops (closes) any previous pending dup
    st.pending_host_fd = host_fd;
    st.last_host_fd = host_fd;
    Ok(InstalledFd {
        host_fd,
        replaced_running,
    })
}

/// Re-arm the pending fd from the last host fd (used by `core.restart` after the
/// previous loop consumed and closed our dup). Fails structurally if Kotlin has
/// already closed the descriptor.
pub(crate) fn ensure_pending_from_last() -> Result<(), ModuleError> {
    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    if st.pending.is_some() {
        return Ok(());
    }
    let host_fd = st.last_host_fd;
    if host_fd < 0 {
        return Err(invalid_fd("no previous TUN fd is available to restart"));
    }
    let owned = dup_nonblocking(host_fd)?;
    st.pending = Some(owned);
    st.pending_host_fd = host_fd;
    Ok(())
}

/// `core.start` (vpn mode) without an explicit proxy registry. See
/// [`start_with_proxies`].
#[allow(dead_code)]
pub(crate) fn start(instance_id: u64) -> Result<bool, ModuleError> {
    start_with_proxies(instance_id, None)
}

/// `core.start` (vpn mode): spawn the single reader loop if not already running.
/// Returns `false` when a loop was already live (idempotent no-op).
///
/// `proxies` (Todo 13) is the generated `name -> Arc<dyn Proxy>` registry
/// (leaf nodes **and** groups). It is published into the tunnel right after the
/// engine is built and **before** any flow is admitted, so no packet can be
/// matched against an empty registry. When `None` only meow's built-in
/// DIRECT/REJECT adapters exist.
pub(crate) fn start_with_proxies(
    instance_id: u64,
    proxies: Option<crate::config::ProxyMap>,
) -> Result<bool, ModuleError> {
    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    if st.active.is_some() {
        return Ok(false);
    }
    let Some(owned) = st.pending.take() else {
        return Err(invalid_fd(
            "no TUN fd installed; call tun.set_fd before core.start",
        ));
    };
    let host_fd = st.pending_host_fd;
    let (stop_tx, stop_rx) = watch::channel(false);

    // An explicit start begins a fresh failure burst: the supervisor restart
    // budget (Todo 24) only counts consecutive automatic restarts.
    crate::supervisor::reset_burst();
    RUNNING.fetch_add(1, Ordering::SeqCst);
    let join = match std::thread::Builder::new()
        .name(LOOP_THREAD_NAME.to_string())
        .spawn(move || {
            run_thread(owned, stop_rx, proxies, instance_id);
            RUNNING.fetch_sub(1, Ordering::SeqCst);
        }) {
        Ok(join) => join,
        Err(e) => {
            RUNNING.fetch_sub(1, Ordering::SeqCst);
            st.pending = None;
            return Err(ModuleError::internal(format!(
                "spawn TUN loop thread failed: {e}"
            )));
        }
    };

    st.active = Some(ActiveLoop {
        stop_tx,
        join,
        host_fd,
        instance_id,
    });
    drop(st);

    // `core.start` reports a live engine: the routing engine (and the generated
    // proxy registry) is built inside the loop thread, so wait for the tunnel
    // handle to appear before returning. A bounded wait keeps a failed build
    // from hanging the caller.
    let deadline = std::time::Instant::now() + ENGINE_READY_TIMEOUT;
    while crate::rules::active_tunnel().is_none() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    if crate::rules::active_tunnel().is_none() {
        crate::log_message(3, "proxy: TUN loop did not publish the engine before start returned");
    }
    Ok(true)
}

/// A loop that `core.stop` just tore down (for the `proxy.tun.released` event).
pub(crate) struct StoppedLoop {
    pub host_fd: RawFd,
    pub instance_id: u64,
}

/// `core.stop`: stop the loop, join the thread. `None` when it was not running.
pub(crate) fn stop() -> Option<StoppedLoop> {
    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    let active = st.active.take()?;
    let stopped = StoppedLoop {
        host_fd: active.host_fd,
        instance_id: active.instance_id,
    };
    stop_and_join(active);
    Some(stopped)
}

/// Stop the loop only if it belongs to `instance_id` (used by `destroy`).
pub(crate) fn stop_for_instance(instance_id: u64) -> Option<StoppedLoop> {
    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    if st.active.as_ref().map(|a| a.instance_id) != Some(instance_id) {
        return None;
    }
    let active = st.active.take()?;
    let stopped = StoppedLoop {
        host_fd: active.host_fd,
        instance_id: active.instance_id,
    };
    stop_and_join(active);
    Some(stopped)
}

/// Signal the loop and wait for its dedicated thread to exit (runtime joined).
fn stop_and_join(active: ActiveLoop) {
    let _ = active.stop_tx.send(true);
    if active.join.join().is_err() {
        crate::log_message(3, "proxy: TUN loop thread panicked during teardown");
    }
}

/// Ask the active loop to stop without joining (host/Kotlin-initiated teardown).
/// The loop thread performs its own teardown and emits `proxy.tun.released`, so
/// the host can wait for `current_tun_fd() == -1` before Kotlin closes the PFD.
/// Returns `false` when no loop is running. Never triggers a supervisor restart
/// (the stop flag makes the loop exit through the clean `Stopped` path).
pub(crate) fn request_stop() -> bool {
    let st = state().lock().unwrap_or_else(|e| e.into_inner());
    match st.active.as_ref() {
        Some(active) if !active.stop_tx.is_closed() => {
            let _ = active.stop_tx.send(true);
            true
        }
        _ => false,
    }
}

/// `destroy`/`shutdown`: tear down everything and drop our pending dup.
pub(crate) fn shutdown() {
    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(active) = st.active.take() {
        stop_and_join(active);
    }
    st.pending = None;
    st.pending_host_fd = -1;
    st.last_host_fd = -1;
    crate::supervisor::mark_stopped();
    crate::supervisor::reset_burst();
}

pub(crate) fn is_running() -> bool {
    state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .active
        .is_some()
}

/// Whether an unstarted TUN fd is staged for the next `core.start` (Todo 29's
/// mode machine validates `vpn` readiness before tearing down the current mode).
pub(crate) fn has_pending() -> bool {
    state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .pending
        .is_some()
}

/// Whether a previous host fd is retained (lets a forced restart re-`dup` it).
pub(crate) fn has_last() -> bool {
    state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .last_host_fd
        >= 0
}

/// Live loop threads. After `stop` returns this must be `0` — the no-leak proof.
#[allow(dead_code)]
pub(crate) fn running_count() -> usize {
    RUNNING.load(Ordering::SeqCst)
}

/// Successful fd reads by the single reader (exactly-once proof).
#[allow(dead_code)]
pub(crate) fn read_count() -> usize {
    READ_COUNT.load(Ordering::SeqCst)
}

/// Reset read instrumentation (tests only).
#[cfg(test)]
pub(crate) fn reset_read_count() {
    READ_COUNT.store(0, Ordering::SeqCst);
}

// ---------------------------------------------------------------------------
// Dedicated thread + async loop
// ---------------------------------------------------------------------------

/// How the datapath loop ended. `Failed` carries the **verbatim** reason (a
/// panicking worker's message, or the error that ended a critical task) so the
/// supervisor can report the root cause instead of masking it.
enum LoopExit {
    Stopped,
    Failed(String),
}

/// Extract a human-readable message from a caught panic payload.
fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".to_string()
    }
}

/// Guard one critical datapath task. Every exit — clean return, error, or panic
/// — is reported on `death_tx`. Panics are caught here so a panicking worker
/// kills neither the guard nor the loop thread, and its verbatim message is
/// preserved. The returned handle is only awaited once during teardown; the
/// select waits on the channel, never on the handle, so a completion can't be
/// observed twice.
fn spawn_guarded<F>(
    name: &'static str,
    fut: F,
    death_tx: mpsc::Sender<String>,
) -> tokio::task::JoinHandle<()>
where
    F: std::future::Future<Output = Result<(), String>> + Send + 'static,
{
    tokio::spawn(async move {
        let outcome = std::panic::AssertUnwindSafe(fut).catch_unwind().await;
        let reason = match outcome {
            Ok(Ok(())) => format!("{name} task ended unexpectedly"),
            Ok(Err(e)) => format!("{name} task failed: {e}"),
            Err(payload) => format!("{name} task panicked: {}", panic_message(payload.as_ref())),
        };
        let _ = death_tx.send(reason).await;
    })
}

/// Wait until `core.stop` signals, or until any guarded datapath task reports
/// its exit. Factoried out so a unit test can drive it with synthetic tasks.
async fn wait_for_stop_or_task_death(
    stop_rx: &mut watch::Receiver<bool>,
    death_rx: &mut mpsc::Receiver<String>,
) -> LoopExit {
    let mut stop = stop_rx.clone();
    tokio::select! {
        _ = async {
            while !*stop.borrow() {
                if stop.changed().await.is_err() {
                    break;
                }
            }
        } => LoopExit::Stopped,
        reason = death_rx.recv() => match reason {
            Some(reason) => LoopExit::Failed(reason),
            None => LoopExit::Failed("all datapath task reporters dropped".to_string()),
        },
    }
}

/// Bounded, stop-aware backoff wait (plain std thread, not inside the runtime).
/// Returns `false` when a stop was requested during the wait.
fn wait_backoff_or_stop(stop_rx: &mut watch::Receiver<bool>, ms: u64) -> bool {
    let deadline = std::time::Instant::now() + Duration::from_millis(ms);
    loop {
        if *stop_rx.borrow() {
            return false;
        }
        if std::time::Instant::now() >= deadline {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Re-duplicate the last host fd so a supervisor restart can ring a new loop
/// without a fresh `nativeSetTunFd` (Kotlin still owns the PFD).
fn rearm_pending_fd() -> Result<OwnedFd, String> {
    ensure_pending_from_last().map_err(|e| e.to_string())?;
    state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .pending
        .take()
        .ok_or_else(|| "no pending fd after re-arm".to_string())
}

/// The dedicated loop thread body. Runs `tun_loop`; on an abnormal exit it
/// reports the root cause and restarts with **bounded** exponential backoff,
/// unless a stop was requested (clean stop / host-initiated teardown) or the
/// restart budget is exhausted.
fn run_thread(
    mut owned: OwnedFd,
    mut stop_rx: watch::Receiver<bool>,
    proxies: Option<crate::config::ProxyMap>,
    instance_id: u64,
) {
    crate::supervisor::mark_alive();
    loop {
        let rt = match crate::bounded_runtime() {
            Ok(rt) => rt,
            Err(e) => {
                crate::log_message(3, &format!("proxy: TUN loop runtime build failed: {e}"));
                crate::supervisor::on_failed(instance_id, &format!("bounded_runtime: {e}"));
                return;
            }
        };
        // A panic in the loop body is caught here (the module is `panic=unwind`)
        // so the plane is reported + restarted; a panic in a spawned task is
        // caught by tokio and surfaced through `wait_for_stop_or_task_death`.
        let outcome = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            rt.block_on(tun_loop(owned, stop_rx.clone(), proxies.clone(), instance_id))
        })) {
            Ok(outcome) => outcome,
            Err(payload) => LoopExit::Failed(format!(
                "TUN loop thread panicked: {}",
                panic_message(payload.as_ref())
            )),
        };
        drop(rt); // joins the 4 bounded worker threads deterministically

        match outcome {
            LoopExit::Stopped => {
                crate::supervisor::mark_stopped();
                crate::log_message(1, "proxy: TUN loop thread exited");
                return;
            }
            LoopExit::Failed(reason) => {
                crate::supervisor::mark_stopped();
                if *stop_rx.borrow() {
                    // The stop raced the failure: clean stop, do not restart.
                    crate::log_message(2, "proxy: TUN loop stopped during failure handling");
                    return;
                }
                let attempt = crate::supervisor::on_death(instance_id, &reason);
                if !crate::supervisor::should_restart(attempt) {
                    crate::supervisor::on_failed(
                        instance_id,
                        &format!("restart budget exhausted after {attempt} attempts: {reason}"),
                    );
                    return;
                }
                let backoff = crate::supervisor::backoff_ms(attempt);
                crate::supervisor::on_restart(instance_id, &reason, backoff);
                if !wait_backoff_or_stop(&mut stop_rx, backoff) {
                    crate::supervisor::on_failed(instance_id, "stopped during restart backoff");
                    return;
                }
                match rearm_pending_fd() {
                    Ok(fd) => owned = fd,
                    Err(e) => {
                        crate::supervisor::on_failed(
                            instance_id,
                            &format!("cannot re-arm TUN fd for restart: {e}"),
                        );
                        return;
                    }
                }
                crate::supervisor::mark_alive();
                crate::log_message(
                    1,
                    &format!("proxy: TUN loop restarted attempt={attempt} backoffMs={backoff}"),
                );
            }
        }
    }
}

/// The real datapath. Builds the netstack on this runtime (so meow's
/// `tokio::spawn` uses `Handle::current()` = our 4 workers), then runs three
/// tasks: the single fd reader, the ingress pump (fd → stack), and the egress
/// pump (stack → fd). Only the reader ever calls `read()`.
async fn tun_loop(
    owned: OwnedFd,
    mut stop_rx: watch::Receiver<bool>,
    proxies: Option<crate::config::ProxyMap>,
    _instance_id: u64,
) -> LoopExit {
    // Todo 8: a fresh loop is a fresh shaper measurement window, and every pump
    // observes hot config changes through this watch receiver.
    shaper::reset_counters();
    let cfg_rx = shaper::subscribe();

    let built = meow_lwip::NetStack::with_buffer_size(STACK_BUFFER_SIZE, UDP_BUFFER_SIZE);
    let (stack, tcp_listener, udp) = match built {
        Ok(v) => v,
        Err(e) => {
            crate::log_message(3, &format!("proxy: NetStack build failed: {e}"));
            return LoopExit::Failed(format!("NetStack build failed: {e}"));
        }
    };
    let mut core_done = stack.core_done();
    // Split the NetStack into independent Sink/Stream halves so the two pumps
    // can run on separate tasks without aliasing mutable borrows.
    let (sink, stream) = stack.split::<Vec<u8>>();

    let afd = match AsyncFd::new(owned) {
        Ok(a) => Arc::new(a),
        Err(e) => {
            crate::log_message(3, &format!("proxy: AsyncFd wrap failed: {e}"));
            return LoopExit::Failed(format!("AsyncFd wrap failed: {e}"));
        }
    };
    let (ingress_tx, mut ingress_rx) = mpsc::channel::<Vec<u8>>(INGRESS_CHANNEL);

    let (death_tx, mut death_rx) = mpsc::channel::<String>(4);

    // --- the ONE reader -----------------------------------------------------
    // Uplink shaping lives here: the reader is still the ONLY fd reader, and it
    // never sleeps inline. `sleep_until(next_deadline)` is the only timer, and
    // `pending()` when the heap is empty prevents a busy loop.
    //
    // Accounting note (Todo 16): every drop on this path — `DamageCore` loss and
    // `ReleaseHeap` drop-newest — happens *before* the frame reaches the ingress
    // sink, so meow's connection accounting never sees it and `stats::traffic`
    // is **post-drop**. The drop is counted only by the shaper's `lossDropped` /
    // `bufferDropped` (see the `stats` module docs).
    let reader = {
        let afd = afd.clone();
        let mut stop = stop_rx.clone();
        let mut cfg_rx = cfg_rx.clone();
        let tx = death_tx.clone();
        spawn_guarded(
            "reader",
            async move {
                let mut buf = vec![0u8; READ_BUFFER_SIZE];
                let now = Instant::now();
                let initial = cfg_rx.borrow_and_update().clone();
                let mut current = initial;
                let mut enabled = current.enabled;
                let mut pump = ShapePump::new(
                    shaper::ShaperDirection::Uplink,
                    &current.uplink,
                    pump_seed(&current),
                    now,
                );
                // `false` after the watch sender drops: the branch is then
                // disabled entirely, so the select cannot busy-loop on `Err`.
                let mut cfg_live = true;
                loop {
                    let deadline = pump.next_deadline();
                    tokio::select! {
                        _ = stop.changed() => return Ok(()),
                        changed = cfg_rx.changed(), if cfg_live => {
                            match changed {
                                Ok(()) => {
                                    // Clone the Arc and drop the `Ref` before any
                                    // `.await`; never hold a watch `Ref` across await.
                                    let next = cfg_rx.borrow_and_update().clone();
                                    enabled = next.enabled;
                                    let now = Instant::now();
                                    let ready = pump.reconfigure(&next.uplink, enabled, now);
                                    current = next;
                                    for frame in ready {
                                        if ingress_tx.send(frame).await.is_err() {
                                            return Err("reader -> ingress channel closed".to_string());
                                        }
                                    }
                                }
                                Err(_) => {
                                    // Sender gone: degrade to the identity path
                                    // and stop polling this branch (no busy loop).
                                    cfg_live = false;
                                    enabled = false;
                                    let now = Instant::now();
                                    let ready = pump.reconfigure(&current.uplink, false, now);
                                    for frame in ready {
                                        if ingress_tx.send(frame).await.is_err() {
                                            return Err("reader -> ingress channel closed".to_string());
                                        }
                                    }
                                }
                            }
                        }
                        ready = afd.readable() => {
                            let mut guard = match ready {
                                Ok(g) => g,
                                Err(e) => return Err(format!("TUN fd readiness error: {e}")),
                            };
                            let read = guard.try_io(|inner| {
                                let n = unsafe {
                                    libc::read(
                                        inner.as_raw_fd(),
                                        buf.as_mut_ptr() as *mut c_void,
                                        buf.len(),
                                    )
                                };
                                if n < 0 {
                                    Err(io::Error::last_os_error())
                                } else {
                                    Ok(n as usize)
                                }
                            });
                            match read {
                                Ok(Ok(0)) => {}
                                Ok(Ok(n)) => {
                                    READ_COUNT.fetch_add(1, Ordering::SeqCst);
                                    let frame = buf[..n].to_vec();
                                    if enabled {
                                        let now = Instant::now();
                                        let ready = pump.on_frame(&current, true, now, frame);
                                        for f in ready {
                                            if ingress_tx.send(f).await.is_err() {
                                                return Err("reader -> ingress channel closed".to_string());
                                            }
                                        }
                                    } else if ingress_tx.send(frame).await.is_err() {
                                        return Err("reader -> ingress channel closed".to_string());
                                    }
                                }
                                Ok(Err(e)) if e.kind() == io::ErrorKind::WouldBlock => {}
                                Ok(Err(e)) => {
                                    return Err(format!("TUN read failed: {e}"));
                                }
                                // `guard.try_io` returns the outer `Err` when the
                                // closure hit `WouldBlock` (readiness consumed but
                                // no data). Under sustained load this spurious
                                // wakeup is routine; retry rather than kill the one
                                // reader (which would restart the whole data plane).
                                Err(_) => continue,
                            }
                        }
                        _ = sleep_until_deadline(deadline) => {
                            let now = Instant::now();
                            for frame in pump.take_ready(now) {
                                if ingress_tx.send(frame).await.is_err() {
                                    return Err("reader -> ingress channel closed".to_string());
                                }
                            }
                        }
                    }
                }
            },
            tx,
        )
    };

    // --- egress pump: stack → fd -------------------------------------------
    // Downlink shaping lives here. The body is an `async fn` generic over the
    // egress stream so a test can drive it with a mock `futures::Stream`.
    let egress = {
        let afd = afd.clone();
        let tx = death_tx.clone();
        let stop = stop_rx.clone();
        let cfg = cfg_rx.clone();
        spawn_guarded(
            "egress",
            async move { run_egress(stream, afd, stop, cfg).await },
            tx,
        )
    };

    // --- ingress pump: fd → stack ------------------------------------------
    let ingress = {
        let tx = death_tx.clone();
        spawn_guarded(
            "ingress",
            async move {
                let mut sink = sink;
                while let Some(frame) = ingress_rx.recv().await {
                    if sink.send(frame).await.is_err() {
                        return Err("netstack ingress sink erred".to_string());
                    }
                }
                Err("ingress channel closed unexpectedly".to_string())
            },
            tx,
        )
    };

    // Flow-dispatch handles (TcpListener accept stream + UDP socket) are handed
    // to the meow tunnel dispatcher; the protector is installed first so any
    // outbound socket a dial opens is protected from the very first packet.
    let protect_installed = crate::protect::install(crate::host_protect_fd());
    let dns_engine = crate::dns::ensure_engine().await;
    let engine = crate::dispatch::build_engine(dns_engine.resolver());
    if let Some(map) = proxies {
        let count = map.len();
        if let Some(tunnel) = crate::rules::active_tunnel() {
            crate::nodes::install_proxies(&tunnel, map);
            crate::log_message(1, &format!("proxy: installed {count} proxies/groups"));
        }
    }
    let dispatcher = crate::dispatch::spawn(engine, tcp_listener, udp, Some(Arc::clone(&dns_engine)));
    crate::log_message(
        1,
        &format!("proxy: flow dispatch active protectInstalled={protect_installed}"),
    );

    let outcome = wait_for_stop_or_task_death(&mut stop_rx, &mut death_rx).await;
    // A stop that raced a task exit is a clean stop, not a data-plane death.
    let outcome = if *stop_rx.borrow() {
        LoopExit::Stopped
    } else {
        outcome
    };

    // Teardown: stop the reader first (no more fd reads), then drop the pumps so
    // the NetStack is released, then wait for lwIP's deterministic core teardown
    // before a successor generation may build a new stack.
    reader.abort();
    let _ = reader.await;
    egress.abort();
    let _ = egress.await;
    ingress.abort();
    let _ = ingress.await;
    dispatcher.shutdown().await;
    crate::protect::clear();

    let _ = tokio::time::timeout(CORE_DONE_TIMEOUT, async {
        let _ = core_done.wait_for(|done| *done).await;
    })
    .await;

    outcome
}

async fn write_frame(afd: &AsyncFd<OwnedFd>, frame: &[u8]) -> io::Result<()> {
    let mut written = 0usize;
    while written < frame.len() {
        let mut guard = afd.writable().await?;
        let res = guard.try_io(|inner| {
            let n = unsafe {
                libc::write(
                    inner.as_raw_fd(),
                    frame[written..].as_ptr() as *const c_void,
                    frame.len() - written,
                )
            };
            if n < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(n as usize)
            }
        });
        match res {
            Ok(Ok(0)) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "tun write returned 0",
                ))
            }
            Ok(Ok(n)) => written += n,
            Ok(Err(e)) if e.kind() == io::ErrorKind::WouldBlock => continue,
            Ok(Err(e)) => return Err(e),
            Err(_) => continue,
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Per-direction shaping pump (Todo 8 / D13)
// ---------------------------------------------------------------------------

/// Seed-stream domain tags. XORed into the single config seed so the uplink and
/// downlink pumps, and each pump's damage vs. scheduling stream, never share a
/// SplitMix64 sequence.
const SEED_TAG_UPLINK: u64 = 0x9E37_79B9_0000_0001;
const SEED_TAG_DOWNLINK: u64 = 0x9E37_79B9_0000_0002;
const SEED_TAG_DAMAGE: u64 = 0xD1CE_5EED_0000_0001;
const SEED_TAG_SCHEDULE: u64 = 0xD1CE_5EED_0000_0002;

/// Derive a pump's base seed from the config. A pinned `seed` (tests) wins
/// verbatim; production mixes in time-derived entropy, exactly as
/// [`shaper::derive_seed`] specifies.
fn pump_seed(cfg: &shaper::ShaperConfig) -> u64 {
    let entropy = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    shaper::derive_seed(cfg.seed, entropy)
}

/// The ONLY timer in a pump. `Some(d)` awaits the absolute deadline; `None`
/// awaits forever (`pending()`), so an empty heap never spins.
async fn sleep_until_deadline(deadline: Option<Instant>) {
    match deadline {
        Some(at) => tokio::time::sleep_until(tokio::time::Instant::from_std(at)).await,
        None => std::future::pending::<()>().await,
    }
}

/// One direction's shaping pipeline: damage (loss/duplicate) + the unified
/// release scheduler + the bounded release heap. Task-local, never shared.
///
/// Callers drive it per frame with [`ShapePump::on_frame`], drain due frames
/// with [`ShapePump::take_ready`], arm the single timer with
/// [`ShapePump::next_deadline`], and hot-apply config with
/// [`ShapePump::reconfigure`]. No method sleeps or reads the clock: every
/// `now` is injected, so the pump is a deterministic, unit-testable core.
struct ShapePump {
    dir: shaper::ShaperDirection,
    heap: shaper::ReleaseHeap,
    scheduler: shaper::ReleaseScheduler,
    damage: shaper::DamageCore,
    seq: u64,
}

impl ShapePump {
    fn new(
        dir: shaper::ShaperDirection,
        cfg: &shaper::DirectionConfig,
        seed: u64,
        now: Instant,
    ) -> Self {
        let dir_tag = match dir {
            shaper::ShaperDirection::Uplink => SEED_TAG_UPLINK,
            shaper::ShaperDirection::Downlink => SEED_TAG_DOWNLINK,
        };
        Self {
            dir,
            heap: shaper::ReleaseHeap::new(),
            scheduler: shaper::ReleaseScheduler::new(
                cfg,
                shaper::SplitMix64::new(seed ^ dir_tag ^ SEED_TAG_SCHEDULE),
                now,
            ),
            damage: shaper::DamageCore::new(seed ^ dir_tag ^ SEED_TAG_DAMAGE, cfg),
            seq: 0,
        }
    }

    fn sync_occupancy(&self) {
        let stats = self.heap.stats();
        shaper::counters().set_occupancy(self.dir, stats.frames as u64, stats.bytes as u64);
    }

    /// Schedule one release copy. `count_reorder` is `false` for a D14 recompute
    /// so an already-counted hold is not billed twice.
    fn push_release(&mut self, now: Instant, frame: Vec<u8>, count_reorder: bool) {
        let exempt = shaper::is_damage_exempt(&frame);
        let release = self.scheduler.schedule(now, frame.len(), exempt);
        if count_reorder && self.scheduler.was_reordered() {
            shaper::counters().record_reorder();
        }
        self.heap.push(shaper::PendingFrame {
            release,
            seq: self.seq,
            payload: frame,
        });
        self.seq = self.seq.wrapping_add(1);
        self.sync_occupancy();
    }

    /// Shape one arriving frame.
    ///
    /// `enabled=false` is the identity path: no damage, no heap, the frame is
    /// returned for immediate forwarding. When enabled the frame is exempted or
    /// damaged (`Drop` => lost, `Duplicate` => two copies), each released copy
    /// is pushed, and any frame already due is returned.
    fn on_frame(
        &mut self,
        cfg: &shaper::ShaperConfig,
        enabled: bool,
        now: Instant,
        frame: Vec<u8>,
    ) -> Vec<Vec<u8>> {
        if !enabled || !cfg.enabled {
            return vec![frame];
        }
        let len = frame.len();
        match self.damage.shape(&frame) {
            shaper::DamageAction::Forward => {
                shaper::counters().record_shaped(self.dir, len);
                self.push_release(now, frame, true);
            }
            shaper::DamageAction::Duplicate => {
                shaper::counters().record_duplicate();
                shaper::counters().record_shaped(self.dir, len);
                let extra = frame.clone();
                self.push_release(now, frame, true);
                self.push_release(now, extra, true);
            }
            shaper::DamageAction::Drop => {
                shaper::counters().record_loss();
            }
        }
        self.take_ready(now)
    }

    /// Pop and return every frame whose release is due by `now`.
    fn take_ready(&mut self, now: Instant) -> Vec<Vec<u8>> {
        let ready = self.heap.pop_ready(now);
        self.sync_occupancy();
        ready.into_iter().map(|f| f.payload).collect()
    }

    /// Release instant of the earliest buffered frame, or `None` when empty.
    fn next_deadline(&self) -> Option<Instant> {
        self.heap.next_deadline()
    }

    /// D14 hot switch. `enabled=false` releases everything immediately. When
    /// enabled, the scheduler/damage are re-snapshotted and every in-flight
    /// frame is re-released under the new config treating `now` as its arrival
    /// -- a bounded approximation (the original arrival spacing is not kept).
    fn reconfigure(
        &mut self,
        cfg: &shaper::DirectionConfig,
        enabled: bool,
        now: Instant,
    ) -> Vec<Vec<u8>> {
        self.scheduler.reconfigure(cfg, now);
        self.damage.reconfigure(cfg);
        if !enabled {
            return self.drain_all();
        }
        let mut in_flight = self.heap.drain_all();
        self.sync_occupancy();
        in_flight.sort_by_key(|f| f.seq);
        self.seq = 0;
        for f in in_flight {
            self.push_release(now, f.payload, false);
        }
        self.take_ready(now)
    }

    /// Release every buffered frame (teardown / hot-disable).
    fn drain_all(&mut self) -> Vec<Vec<u8>> {
        let drained = self.heap.drain_all();
        self.sync_occupancy();
        drained.into_iter().map(|f| f.payload).collect()
    }
}

/// The downlink egress loop (stack -> fd), factored out as an `async fn` over a
/// generic stream so a test can drive it. Source is `stream.next()` (cancel
/// safe), sink is [`write_frame`], and the only timer is the
/// `sleep_until(next_deadline)` branch.
async fn run_egress<S>(
    mut stream: S,
    afd: Arc<AsyncFd<OwnedFd>>,
    mut stop: watch::Receiver<bool>,
    mut cfg_rx: watch::Receiver<Arc<shaper::ShaperConfig>>,
) -> Result<(), String>
where
    S: futures::Stream<Item = io::Result<Vec<u8>>> + Unpin,
{
    let now = Instant::now();
    let initial = cfg_rx.borrow_and_update().clone();
    let mut current = initial;
    let mut enabled = current.enabled;
    let mut pump = ShapePump::new(
        shaper::ShaperDirection::Downlink,
        &current.downlink,
        pump_seed(&current),
        now,
    );
    let mut cfg_live = true;
    loop {
        let deadline = pump.next_deadline();
        tokio::select! {
            _ = stop.changed() => return Ok(()),
            changed = cfg_rx.changed(), if cfg_live => {
                match changed {
                    Ok(()) => {
                        let next = cfg_rx.borrow_and_update().clone();
                        enabled = next.enabled;
                        let now = Instant::now();
                        let ready = pump.reconfigure(&next.downlink, enabled, now);
                        current = next;
                        for frame in ready {
                            write_egress(&afd, &frame).await;
                        }
                    }
                    Err(_) => {
                        cfg_live = false;
                        enabled = false;
                        let now = Instant::now();
                        let ready = pump.reconfigure(&current.downlink, false, now);
                        for frame in ready {
                            write_egress(&afd, &frame).await;
                        }
                    }
                }
            }
            item = stream.next() => {
                match item {
                    Some(Ok(frame)) if !frame.is_empty() => {
                        if enabled {
                            let now = Instant::now();
                            let ready = pump.on_frame(&current, true, now, frame);
                            for f in ready {
                                write_egress(&afd, &f).await;
                            }
                        } else {
                            write_egress(&afd, &frame).await;
                        }
                    }
                    Some(Ok(_)) => {}
                    Some(Err(_)) => return Err("netstack egress stream errored".to_string()),
                    None => return Err("netstack egress stream ended unexpectedly".to_string()),
                }
            }
            _ = sleep_until_deadline(deadline) => {
                let now = Instant::now();
                for frame in pump.take_ready(now) {
                    write_egress(&afd, &frame).await;
                }
            }
        }
    }
}

/// Write one egress frame, logging (never failing the data plane) on error.
async fn write_egress(afd: &AsyncFd<OwnedFd>, frame: &[u8]) {
    if let Err(e) = write_frame(afd, frame).await {
        crate::log_message(3, &format!("proxy: TUN egress write failed: {e}"));
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::io::Write as _;
    use std::io::Read as _;
    use std::os::unix::net::UnixStream;

    /// A minimal but valid 40-byte IPv4/UDP frame (mirrors the Todo 1 spike).
    fn ipv4_udp_frame() -> Vec<u8> {
        let mut p = vec![0u8; 28];
        p[0] = 0x45; // IPv4, IHL 5
        p[2..4].copy_from_slice(&(28u16 + 8).to_be_bytes()); // total length
        p[8] = 64; // TTL
        p[9] = 17; // UDP
        p[12..16].copy_from_slice(&[10, 10, 0, 2]); // src
        p[16..20].copy_from_slice(&[8, 8, 8, 8]); // dst
        // UDP header
        p.extend_from_slice(&53u16.to_be_bytes()); // src port
        p.extend_from_slice(&53u16.to_be_bytes()); // dst port
        p.extend_from_slice(&8u16.to_be_bytes()); // length
        p.extend_from_slice(&[0, 0]); // checksum (lwIP tolerates 0)
        p
    }

    /// Tests mutate process-global loop state → serialize with the crate-wide lock.
    use crate::TEST_SERIAL as SERIAL;

    fn wait_until(mut cond: impl FnMut() -> bool, timeout: Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        while std::time::Instant::now() < deadline {
            if cond() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        cond()
    }

    /// A unique, created temp dir per test; caller removes it at the end
    /// (mirrors `shaper::config_io_tests::tmp_dir`).
    fn tmp_dir(tag: &str) -> std::path::PathBuf {
        use std::sync::atomic::AtomicU32;
        static SEQ: AtomicU32 = AtomicU32::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("gstore-tun-{tag}-{nanos}-{seq}"));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn invalid_fd_is_structured_error_not_panic() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        let err = install_fd(-1).unwrap_err();
        assert_eq!(err.status, StatusCode::InvalidArgument);
        assert_eq!(err.code, ERR_TUN_FD_INVALID);
        // A closed/garbage descriptor also fails structurally.
        let err = install_fd(99_999).unwrap_err();
        assert_eq!(err.code, ERR_TUN_FD_INVALID);
        // start without an fd is a structured error too.
        let err = start(1).unwrap_err();
        assert_eq!(err.code, ERR_TUN_FD_INVALID);
    }

    #[test]
    fn packet_written_to_mock_fd_is_read_exactly_once() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        let (loop_end, mut peer) = UnixStream::pair().unwrap();
        install_fd(loop_end.as_raw_fd()).expect("install mock fd");
        assert!(start(7).expect("start loop"));
        assert_eq!(running_count(), 1, "exactly one loop thread");

        // Give the reader a beat to register the AsyncFd, then push one frame.
        wait_until(|| true, Duration::from_millis(100));
        peer.write_all(&ipv4_udp_frame()).unwrap();
        peer.flush().unwrap();

        assert!(
            wait_until(|| read_count() >= 1, Duration::from_secs(2)),
            "loop never read the frame"
        );
        // No second reader: the count must stay exactly 1.
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(read_count(), 1, "frame must be read EXACTLY once");

        stop();
        assert_eq!(running_count(), 0, "loop thread joined");
    }

    #[test]
    fn start_stop_restart_is_idempotent_and_leaks_no_threads() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        let (loop_end, _peer) = UnixStream::pair().unwrap();
        install_fd(loop_end.as_raw_fd()).expect("install mock fd");

        // start twice → still one loop thread
        assert!(start(11).unwrap(), "first start spawns");
        assert!(!start(11).unwrap(), "second start is a no-op");
        assert_eq!(running_count(), 1);

        // stop twice → idempotent, thread joined
        assert!(stop().is_some(), "first stop joins");
        assert!(stop().is_none(), "second stop is a no-op");
        assert_eq!(running_count(), 0);

        // several stop→start cycles must not accumulate threads
        for _ in 0..3 {
            // re-install: the pending fd was consumed by the previous start
            let (again, _p) = UnixStream::pair().unwrap();
            install_fd(again.as_raw_fd()).expect("re-install mock fd");
            assert!(start(11).unwrap());
            assert_eq!(running_count(), 1);
            assert!(stop().is_some());
            assert_eq!(running_count(), 0, "no thread leaked after a cycle");
        }
    }

    #[test]
    fn install_fd_replaces_a_running_loop_without_a_second_reader() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        let (first, _p1) = UnixStream::pair().unwrap();
        install_fd(first.as_raw_fd()).expect("install first");
        assert!(start(3).unwrap());

        let (second, mut p2) = UnixStream::pair().unwrap();
        let info = install_fd(second.as_raw_fd()).expect("install second");
        assert!(info.replaced_running, "running loop must be torn down first");
        assert_eq!(running_count(), 0, "old loop joined before replace");

        assert!(start(3).unwrap());
        reset_read_count();
        p2.write_all(&ipv4_udp_frame()).unwrap();
        p2.flush().unwrap();
        assert!(wait_until(|| read_count() == 1, Duration::from_secs(2)));
        stop();
        assert_eq!(running_count(), 0);
    }

    /// `request_stop` (host/Kotlin-initiated teardown) must stop the reader and
    /// release the thread without going through `core.stop`.
    #[test]
    fn request_stop_stops_the_loop_without_core_stop() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        let (loop_end, _peer) = UnixStream::pair().unwrap();
        install_fd(loop_end.as_raw_fd()).expect("install mock fd");
        assert!(start(21).expect("start loop"));
        assert_eq!(running_count(), 1);

        assert!(request_stop(), "request_stop signals the live loop");
        assert!(
            wait_until(|| running_count() == 0, Duration::from_secs(2)),
            "loop must exit after request_stop"
        );
        assert!(!request_stop(), "no live loop remains after it exited");
        // Reap the finished ActiveLoop handle.
        assert!(stop().is_some(), "the finished loop handle is reaped by stop()");
        assert_eq!(running_count(), 0, "no reader left running");
    }

    async fn panic_reader() -> Result<(), String> {
        panic!("reader boom")
    }

    async fn pending_ok() -> Result<(), String> {
        std::future::pending::<()>().await;
        Ok(())
    }

    /// A panicking worker task must be surfaced as a failure (with the verbatim
    /// panic message), never silently swallowed.
    #[tokio::test]
    async fn dead_worker_task_is_detected_with_structured_reason() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let (stop_tx, mut stop_rx) = watch::channel(false);
        let (death_tx, mut death_rx) = mpsc::channel::<String>(4);
        let reader = spawn_guarded("reader", panic_reader(), death_tx.clone());
        let egress = spawn_guarded("egress", pending_ok(), death_tx.clone());
        let ingress = spawn_guarded("ingress", pending_ok(), death_tx.clone());

        let outcome = wait_for_stop_or_task_death(&mut stop_rx, &mut death_rx).await;
        drop(stop_tx);
        egress.abort();
        ingress.abort();
        reader.abort();

        match outcome {
            LoopExit::Failed(reason) => {
                assert!(reason.contains("reader"), "reason must name the task: {reason}");
                assert!(
                    reason.contains("boom"),
                    "reason must carry the verbatim panic: {reason}"
                );
            }
            LoopExit::Stopped => panic!("a panicking worker must be detected as failure"),
        }
    }

    /// A critical task that returns cleanly while the tunnel is up is also a dead
    /// data plane (e.g. a reader that exits on a transient error).
    #[tokio::test]
    async fn completed_worker_task_is_detected_as_dead() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let (stop_tx, mut stop_rx) = watch::channel(false);
        let (death_tx, mut death_rx) = mpsc::channel::<String>(4);
        let reader = spawn_guarded("reader", async { Ok::<(), String>(()) }, death_tx.clone());
        let egress = spawn_guarded("egress", pending_ok(), death_tx.clone());
        let ingress = spawn_guarded("ingress", pending_ok(), death_tx.clone());

        let outcome = wait_for_stop_or_task_death(&mut stop_rx, &mut death_rx).await;
        drop(stop_tx);
        egress.abort();
        ingress.abort();
        reader.abort();

        match outcome {
            LoopExit::Failed(reason) => {
                assert!(
                    reason.contains("reader task ended unexpectedly"),
                    "unexpected reason: {reason}"
                );
            }
            LoopExit::Stopped => panic!("a completed worker must be detected as failure"),
        }
    }

    /// The bounded backoff wait aborts immediately when a stop is requested and
    /// otherwise returns after the (small, bounded) delay.
    #[test]
    fn backoff_wait_is_stop_aware_and_bounded() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let (tx, mut rx) = watch::channel(false);
        tx.send(true).unwrap();
        let start = std::time::Instant::now();
        assert!(!wait_backoff_or_stop(&mut rx, 5_000));
        assert!(
            start.elapsed() < Duration::from_millis(100),
            "must not wait out the backoff once stopped"
        );

        let (_tx2, mut rx2) = watch::channel(false);
        assert!(wait_backoff_or_stop(&mut rx2, 30));
    }

    /// A valid-length IPv4 frame with protocol 253 (experimental): it reaches the
    /// netstack but is neither DNS/UDP-53 nor TCP, so the benchmark never dials
    /// the network (unlike [`ipv4_udp_frame`], which would trigger DNS hijack).
    fn non_dns_frame() -> Vec<u8> {
        let mut p = vec![0u8; 20];
        // IHL 15 claims a 60-byte header in a 40-byte frame: lwIP drops it
        // silently (no ICMP egress), so the benchmark measures pure ingest.
        p[0] = 0x4F;
        p[2..4].copy_from_slice(&40u16.to_be_bytes());
        p[8] = 64;
        p[9] = 253;
        p[12..16].copy_from_slice(&[10, 10, 0, 2]);
        p[16..20].copy_from_slice(&[10, 10, 0, 9]);
        p.extend_from_slice(&[0u8; 20]);
        p
    }

    /// A `len`-byte IPv4 frame the shaper treats as non-exempt data but lwIP
    /// drops silently: `total_length` is 40 while the IHL claims a 60-byte
    /// header, so the netstack never dials the network (same trick as
    /// [`non_dns_frame`], but large enough to observe per-frame pacing at a low
    /// `rateBps`). Protocol 253 (experimental) is an `IpProto::Other`, so
    /// [`shaper::is_damage_exempt`] is `false`.
    fn paced_frame(len: usize) -> Vec<u8> {
        let mut f = vec![0u8; len];
        f[0] = 0x4F; // IPv4, IHL 15 (claims a 60-byte header)
        f[2..4].copy_from_slice(&40u16.to_be_bytes()); // total length 40 < IHL -> lwIP drops
        f[8] = 64; // TTL
        f[9] = 253; // experimental protocol: non-exempt data
        f[12..16].copy_from_slice(&[10, 10, 0, 2]); // src
        f[16..20].copy_from_slice(&[10, 10, 0, 9]); // dst
        f
    }

    /// Regression (Todo 27): the single reader must survive the spurious
    /// `WouldBlock` it sees whenever it drains a burst and the fd goes idle.
    /// Before the fix that was treated as fatal ("readiness cancelled"), so the
    /// loop died (and the supervisor restarted the whole data plane) on a gap.
    #[test]
    fn reader_survives_idle_gaps_between_bursts() {
        use std::os::unix::net::UnixDatagram;

        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        const BURSTS: usize = 5;
        const PER_BURST: usize = 50;

        let (loop_end, peer) = UnixDatagram::pair().unwrap();
        install_fd(loop_end.as_raw_fd()).expect("install mock fd");
        drop(loop_end);
        assert!(start(55).expect("start loop"), "loop must start");
        reset_read_count();

        let frame = non_dns_frame();
        let w = peer.try_clone().unwrap();
        for b in 0..BURSTS {
            for _ in 0..PER_BURST {
                w.send(&frame).expect("send frame");
            }
            assert!(
                wait_until(|| read_count() >= (b + 1) * PER_BURST, Duration::from_secs(2)),
                "burst {b}: only read {}",
                read_count()
            );
            std::thread::sleep(Duration::from_millis(80));
            assert_eq!(
                running_count(),
                1,
                "loop must survive the idle gap after burst {b}"
            );
        }
        assert_eq!(read_count(), BURSTS * PER_BURST);
        stop();
        assert_eq!(running_count(), 0);
    }

    /// Manual local benchmark (Todo 27). Not run by default; `bench/run.sh`
    /// drives it. A `SOCK_DGRAM` pair gives one frame per `read` (a stream pair
    /// would coalesce frames, unlike a real TUN fd). Measures sustained reader
    /// throughput plus process RSS/CPU deltas against a recorded baseline.
    /// `GSTORE_BENCH_FRAMES` overrides the frame count.
    #[test]
    #[ignore = "manual local benchmark: cargo test -p gstore_mod_proxy bench_dataplane -- --ignored --nocapture --test-threads=1"]
    fn bench_dataplane_reader_throughput() {
        use std::os::unix::net::UnixDatagram;
        use std::sync::atomic::{AtomicBool, Ordering as AtomicOrdering};

        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        let frames: usize = std::env::var("GSTORE_BENCH_FRAMES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(20_000);

        let (loop_end, peer) = UnixDatagram::pair().unwrap();
        install_fd(loop_end.as_raw_fd()).expect("install mock fd");
        drop(loop_end);
        assert!(start(42).expect("start loop"), "loop must start");
        reset_read_count();

        let drain_stop = Arc::new(AtomicBool::new(false));
        let peer_read = peer.try_clone().unwrap();
        peer_read
            .set_read_timeout(Some(Duration::from_millis(50)))
            .unwrap();
        let ds = Arc::clone(&drain_stop);
        let drain = std::thread::spawn(move || {
            let mut buf = [0u8; 65_535];
            while !ds.load(AtomicOrdering::Relaxed) {
                match peer_read.recv(&mut buf) {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(e)
                        if e.kind() == io::ErrorKind::WouldBlock
                            || e.kind() == io::ErrorKind::TimedOut => {}
                    Err(_) => break,
                }
            }
        });

        let frame = non_dns_frame();
        let peer_write = peer.try_clone().unwrap();
        let rss0 = crate::limits::rss_kb();
        let cpu0 = crate::limits::cpu_ms();
        let t0 = std::time::Instant::now();
        let writer = std::thread::spawn(move || {
            for _ in 0..frames {
                if peer_write.send(&frame).is_err() {
                    return;
                }
            }
        });

        assert!(
            wait_until(|| read_count() >= frames, Duration::from_secs(120)),
            "reader did not consume {frames} frames in time (read={})",
            read_count()
        );
        let elapsed = t0.elapsed();
        let cpu = crate::limits::cpu_ms().saturating_sub(cpu0);
        let rss = crate::limits::rss_kb();
        let fps = frames as u128 * 1000 / elapsed.as_millis().max(1);
        crate::limits::bench_line(
            "dataplane_read",
            &[
                ("frames", frames as u128),
                ("elapsed_ms", elapsed.as_millis()),
                ("frames_per_sec", fps),
                ("rss_kb", rss as u128),
                ("rss_delta_kb", rss.saturating_sub(rss0) as u128),
                ("cpu_ms", cpu as u128),
                ("ingress_channel", INGRESS_CHANNEL as u128),
            ],
        );

        drain_stop.store(true, AtomicOrdering::Relaxed);
        let _ = writer.join();
        stop();
        drop(peer);
        let _ = drain.join();
        shallow_reset();
    }

    /// `enabled=false` must be the identity: the frame is returned unchanged and
    /// nothing is buffered or counted.
    #[test]
    fn shaper_disabled_is_identity() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shaper::reset_counters();
        let cfg = shaper::ShaperConfig::default();
        let now = Instant::now();
        let mut pump = ShapePump::new(
            shaper::ShaperDirection::Uplink,
            &cfg.uplink,
            0x1234_5678,
            now,
        );

        let frame = ipv4_udp_frame();
        let out = pump.on_frame(&cfg, false, now, frame.clone());
        assert_eq!(out, vec![frame], "disabled must forward the frame verbatim");
        assert_eq!(pump.next_deadline(), None, "disabled must buffer nothing");

        let snap = shaper::counters().snapshot();
        assert_eq!(snap.up_frames_shaped, 0);
        assert_eq!(snap.buffered_frames, 0);
        let stats = shaper::buffer_stats();
        assert_eq!(stats.uplink.frames, 0);
        assert_eq!(stats.uplink.bytes, 0);
    }

    /// D14: a hot-disable must release a frame stuck behind a multi-second
    /// delay immediately (well inside the 250 ms bound).
    #[test]
    fn hot_reload_disables_during_pending_delay() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shaper::reset_counters();
        let mut cfg = shaper::ShaperConfig {
            enabled: true,
            ..Default::default()
        };
        cfg.uplink.delay_ms = 5_000;

        let now = Instant::now();
        let mut pump = ShapePump::new(
            shaper::ShaperDirection::Uplink,
            &cfg.uplink,
            0xABCD,
            now,
        );
        let frame = ipv4_udp_frame();
        let out = pump.on_frame(&cfg, true, now, frame.clone());
        assert!(out.is_empty(), "a 5s delay must not release immediately");

        let deadline = pump.next_deadline().expect("a pending frame sets a deadline");
        let ahead = deadline.saturating_duration_since(now);
        assert!(
            ahead >= Duration::from_millis(4_500),
            "deadline must be ~5s ahead, got {ahead:?}"
        );

        let started = Instant::now();
        let released = pump.reconfigure(&cfg.uplink, false, Instant::now());
        assert_eq!(released, vec![frame], "hot-disable must release the pending frame");
        assert!(
            started.elapsed() < Duration::from_millis(250),
            "release must be immediate, took {:?}",
            started.elapsed()
        );
        assert_eq!(pump.next_deadline(), None);
    }

    /// The downlink pump must not lose a frame when the `sleep_until` branch
    /// wins: every frame sharing a release instant is drained together.
    #[test]
    fn egress_frame_not_lost_when_timer_wins() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shaper::reset_counters();
        let mut cfg = shaper::ShaperConfig {
            enabled: true,
            ..Default::default()
        };
        cfg.downlink.delay_ms = 30;

        let now = Instant::now();
        let mut pump = ShapePump::new(
            shaper::ShaperDirection::Downlink,
            &cfg.downlink,
            0x55AA,
            now,
        );
        let frame = ipv4_udp_frame();
        let total = 32usize;
        let mut released = Vec::new();
        for _ in 0..total {
            released.extend(pump.on_frame(&cfg, true, now, frame.clone()));
        }
        assert!(released.is_empty(), "nothing is due before the delay elapses");
        assert_eq!(pump.next_deadline(), Some(now + Duration::from_millis(30)));

        let due = pump.take_ready(now + Duration::from_millis(31));
        assert_eq!(due.len(), total, "no downlink frame may be lost when the timer wins");
        assert!(due.iter().all(|f| f == &frame));
        assert_eq!(pump.next_deadline(), None);
    }

    /// Integration variant: drive the extracted egress loop over a mock
    /// `futures::Stream` while the timer branch wins, and prove every frame
    /// reaches the mock fd (none lost).
    #[tokio::test]
    async fn egress_loop_releases_frames_when_timer_wins() {
        use std::os::fd::IntoRawFd;

        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shaper::reset_counters();

        let (fd_end, mut peer) = UnixStream::pair().unwrap();
        set_nonblocking(fd_end.as_raw_fd()).unwrap();
        peer.set_nonblocking(true).unwrap();
        let owned = unsafe { OwnedFd::from_raw_fd(fd_end.into_raw_fd()) };
        let afd = Arc::new(AsyncFd::new(owned).unwrap());

        let mut cfg = shaper::ShaperConfig {
            enabled: true,
            seed: Some(0x5151),
            ..Default::default()
        };
        cfg.downlink.delay_ms = 20;
        let (_cfg_tx, cfg_rx) = watch::channel(Arc::new(cfg.clone()));
        let (stop_tx, stop_rx) = watch::channel(false);

        let frame = ipv4_udp_frame();
        let total = 16usize;
        let frames: Vec<io::Result<Vec<u8>>> = (0..total).map(|_| Ok(frame.clone())).collect();
        let stream =
            futures::stream::iter(frames).chain(futures::stream::pending::<io::Result<Vec<u8>>>());

        let task = tokio::spawn(run_egress(stream, afd, stop_rx, cfg_rx));

        let expected = total * frame.len();
        let mut got = 0usize;
        let mut buf = vec![0u8; 65_535];
        let deadline = Instant::now() + Duration::from_secs(5);
        while got < expected && Instant::now() < deadline {
            match peer.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => got += n,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                Err(e) => panic!("peer read failed: {e}"),
            }
        }
        assert_eq!(got, expected, "the timer branch must not lose downlink frames");

        let _ = stop_tx.send(true);
        let _ = tokio::time::timeout(Duration::from_secs(1), task).await;
    }

    /// Prompt stop under a multi-second pending shape delay: `stop()` must join
    /// the loop in well under the delay (the reader is aborted, it never sleeps
    /// inline), and the frame must genuinely have been sitting in the heap.
    #[test]
    fn stop_is_prompt_with_pending_shape_delay() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        shaper::reset_counters();
        let dir = tmp_dir("stop-prompt");
        let dir_str = dir.to_str().unwrap().to_string();
        shaper::configure(&dir_str);
        let next = shaper::set(&dir_str, br#"{"enabled":true,"uplink":{"delayMs":5000}}"#)
            .expect("a 5s uplink delay is valid");
        assert!(next.enabled);

        let (loop_end, mut peer) = UnixStream::pair().unwrap();
        install_fd(loop_end.as_raw_fd()).expect("install mock fd");
        assert!(start(91).expect("start loop"), "loop must start");
        assert_eq!(running_count(), 1);

        peer.write_all(&ipv4_udp_frame()).unwrap();
        peer.flush().unwrap();
        assert!(
            wait_until(|| read_count() >= 1, Duration::from_secs(2)),
            "reader never consumed the frame"
        );
        assert!(
            wait_until(|| shaper::buffer_stats().uplink.frames >= 1, Duration::from_secs(2)),
            "frame must be pending in the uplink shape heap, got {:?}",
            shaper::buffer_stats().uplink
        );

        let started = std::time::Instant::now();
        stop();
        let elapsed = started.elapsed();
        assert_eq!(running_count(), 0, "loop thread joined");
        assert!(
            elapsed < Duration::from_millis(250),
            "stop must not wait out the pending 5s shape delay, took {elapsed:?}"
        );

        shaper::reset_for_test();
        shaper::reset_counters();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A rejected shaper config is a 422 and must never touch the supervisor:
    /// no restart is bumped and the live single-reader loop keeps running.
    #[test]
    fn shaper_misconfig_does_not_restart_dataplane() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        crate::supervisor::reset_for_tests();
        shaper::reset_for_test();
        shaper::reset_counters();

        let dir = tmp_dir("misconfig");
        let dir_str = dir.to_str().unwrap().to_string();
        shaper::configure(&dir_str);
        shaper::set(&dir_str, br#"{"enabled":true}"#).expect("valid config");
        let before = crate::supervisor::snapshot().restarts;

        let (loop_end, _peer) = UnixStream::pair().unwrap();
        install_fd(loop_end.as_raw_fd()).expect("install mock fd");
        assert!(start(92).expect("start loop"), "loop must start");
        assert_eq!(running_count(), 1);

        let err = shaper::set(&dir_str, br#"{"uplink":{"rateBps":999}}"#).unwrap_err();
        assert_eq!(err.status, StatusCode::InvalidArgument);
        assert_eq!(err.code, shaper::ERR_SHAPER_CONFIG_INVALID);

        // Give any (buggy) async restart a chance to fire before asserting.
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(
            crate::supervisor::snapshot().restarts,
            before,
            "a rejected shaper config must never bump the restart counter"
        );
        assert_eq!(
            running_count(),
            1,
            "the same single loop must still be running after a rejected config"
        );

        stop();
        assert_eq!(running_count(), 0);
        crate::supervisor::reset_for_tests();
        shaper::reset_for_test();
        shaper::reset_counters();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// With shaping enabled every frame is buffered in the heap, yet there must
    /// still be exactly one fd reader: each datagram is read exactly once and
    /// the loop count stays 1 until an explicit stop.
    #[test]
    fn single_reader_invariant_holds_with_shaping() {
        use std::os::unix::net::UnixDatagram;

        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        shaper::reset_counters();
        let dir = tmp_dir("single-reader");
        let dir_str = dir.to_str().unwrap().to_string();
        shaper::configure(&dir_str);
        shaper::set(
            &dir_str,
            br#"{"enabled":true,"seed":7,"uplink":{"delayMs":50}}"#,
        )
        .expect("valid config");

        const N: usize = 64;
        let (loop_end, peer) = UnixDatagram::pair().unwrap();
        install_fd(loop_end.as_raw_fd()).expect("install mock fd");
        drop(loop_end);
        assert!(start(93).expect("start loop"), "loop must start");
        reset_read_count();

        let frame = ipv4_udp_frame();
        let w = peer.try_clone().unwrap();
        for _ in 0..N {
            w.send(&frame).expect("send frame");
        }
        assert!(
            wait_until(|| read_count() == N, Duration::from_secs(2)),
            "reader consumed {} of {N} frames",
            read_count()
        );

        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(
            read_count(),
            N,
            "each frame read exactly once; a second reader would inflate this"
        );
        assert_eq!(running_count(), 1, "exactly one loop thread / reader");

        stop();
        assert_eq!(running_count(), 0);

        shaper::reset_for_test();
        shaper::reset_counters();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Todo 16: lock the `stats.traffic` accounting口径. With `lossPct=100` the
    /// damage core drops every non-exempt frame **before** the ingress sink, so
    /// nothing is shaped/forwarded into the netstack: `upFramesShaped` and the
    /// heap occupancy stay 0 while `lossDropped` counts every frame. Because
    /// meow's connection accounting only sees frames that reached the engine,
    /// `stats.traffic` is therefore **post-drop** and these bytes never appear
    /// there. Deterministic: no timing, no clock injection beyond `now`.
    #[test]
    fn stats_traffic_is_post_drop() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shaper::reset_counters();
        crate::stats::reset_for_tests();

        let mut cfg = shaper::ShaperConfig {
            enabled: true,
            seed: Some(0x1055),
            ..Default::default()
        };
        cfg.uplink.loss_model = shaper::LossModel::Random;
        cfg.uplink.loss_pct = 100.0;

        let now = Instant::now();
        let mut pump = ShapePump::new(
            shaper::ShaperDirection::Uplink,
            &cfg.uplink,
            pump_seed(&cfg),
            now,
        );

        const N: usize = 16;
        let frame = non_dns_frame();
        assert!(
            !shaper::is_damage_exempt(&frame),
            "the fixture must be a droppable (non-exempt) frame"
        );

        let mut forwarded = 0usize;
        for _ in 0..N {
            let out = pump.on_frame(&cfg, true, now, frame.clone());
            forwarded += out.len();
            assert!(out.is_empty(), "100% loss must never forward inline");
            assert_eq!(
                pump.next_deadline(),
                None,
                "a dropped frame must not be buffered"
            );
        }

        let json = shaper::counters_json();
        assert_eq!(
            json["lossDropped"],
            serde_json::json!(N as u64),
            "every non-exempt frame is billed to lossDropped"
        );
        assert_eq!(
            json["upFramesShaped"],
            serde_json::json!(0),
            "a dropped frame is never shaped/delivered"
        );
        assert_eq!(json["upBytesShaped"], serde_json::json!(0));
        assert_eq!(forwarded, 0, "not one frame may reach the ingress sink");
        let occ = shaper::buffer_stats().uplink;
        assert_eq!(occ.frames, 0, "post-drop: the shape heap stays empty");
        assert_eq!(occ.bytes, 0);

        // The `stats.traffic` read surface is fed only by meow's connection
        // accounting, so bytes dropped-before-engine can never be counted here.
        let data = crate::stats::traffic_get_arm(b"").unwrap();
        let traffic: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(traffic["data"]["uploadBytes"], serde_json::json!(0));
        assert_eq!(traffic["data"]["downloadBytes"], serde_json::json!(0));

        println!(
            "stats_traffic_is_post_drop: frames={N} lossDropped={} upFramesShaped={} \
             occupancy={:?} traffic_upload={}",
            json["lossDropped"], json["upFramesShaped"], occ, traffic["data"]["uploadBytes"]
        );

        shaper::reset_counters();
        crate::stats::reset_for_tests();
    }

    /// Todo 16: real-time datapath observation. A low uplink `rateBps` with
    /// `delayMs=0` makes the reader park the burst in the shape heap and release
    /// it spaced by `len/rate`. Occupancy must be non-zero right after the burst,
    /// must strictly decrease across a real interval, and the whole drain must
    /// take clearly longer than the disabled baseline (loose tolerance — the
    /// observed numbers are printed as evidence).
    #[test]
    fn mock_fd_bandwidth_limit_slows_delivery() {
        use std::os::unix::net::UnixDatagram;

        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        shaper::reset_counters();
        let dir = tmp_dir("bw-limit");
        let dir_str = dir.to_str().unwrap().to_string();
        shaper::configure(&dir_str);
        // The pacer spaces a frame by `len / rateBps` (its own convention), so
        // 25_000 gives a 1500-byte frame a 60 ms interval: 32 frames need ~1.9 s
        // of wall-clock vs. ~instant when disabled.
        shaper::set(
            &dir_str,
            br#"{"enabled":true,"seed":9,"uplink":{"rateBps":25000,"delayMs":0}}"#,
        )
        .expect("a 25 kbps / no-delay uplink is valid");

        const N: usize = 32;
        const FRAME_LEN: usize = 1_500;
        let (loop_end, peer) = UnixDatagram::pair().unwrap();
        install_fd(loop_end.as_raw_fd()).expect("install mock fd");
        drop(loop_end);
        assert!(start(94).expect("start loop"), "loop must start");
        reset_read_count();

        let frame = paced_frame(FRAME_LEN);
        assert!(
            !shaper::is_damage_exempt(&frame),
            "the fixture must be shapable data"
        );
        let w = peer.try_clone().unwrap();
        let sent_at = std::time::Instant::now();
        for _ in 0..N {
            w.send(&frame).expect("send frame");
        }
        assert!(
            wait_until(|| read_count() == N, Duration::from_secs(3)),
            "reader consumed {} of {N} frames",
            read_count()
        );
        assert!(
            wait_until(|| shaper::buffer_stats().uplink.frames > 0, Duration::from_secs(1)),
            "frames must accumulate in the shape heap"
        );
        let frames_before = shaper::buffer_stats().uplink.frames;
        std::thread::sleep(Duration::from_millis(400));
        let frames_after = shaper::buffer_stats().uplink.frames;
        assert!(
            frames_after < frames_before,
            "occupancy must strictly decrease over a real interval ({frames_before} -> {frames_after})"
        );
        assert!(
            wait_until(
                || shaper::buffer_stats().uplink.frames == 0,
                Duration::from_secs(10)
            ),
            "shaped frames must eventually drain (left {})",
            shaper::buffer_stats().uplink.frames
        );
        let drain_ms = sent_at.elapsed().as_millis();
        assert!(
            drain_ms > 700,
            "a 200 kbps uplink must slow delivery; drained in {drain_ms} ms"
        );
        assert_eq!(read_count(), N, "the single reader still reads each frame once");
        assert_eq!(running_count(), 1);

        let json = shaper::counters_json();
        println!(
            "mock_fd_bandwidth_limit_slows_delivery: N={N} frame_len={FRAME_LEN} \
             frames_before={frames_before} frames_after={frames_after} drain_ms={drain_ms} \
             upFramesShaped={} bufferDropped={} lossDropped={}",
            json["upFramesShaped"], json["bufferDropped"], json["lossDropped"]
        );

        stop();
        assert_eq!(running_count(), 0);
        shaper::reset_for_test();
        shaper::reset_counters();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Todo 16: with shaping disabled the datapath must add **no** loss and
    /// **no** delay — every frame is read promptly, nothing is buffered, and
    /// neither drop counter moves. The config is deliberately a slow+lossy one
    /// (200 kbps, 100% random loss) to prove `enabled=false` ignores it.
    #[test]
    fn shaper_disabled_throughput_baseline() {
        use std::os::unix::net::UnixDatagram;

        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shallow_reset();
        shaper::reset_counters();
        let dir = tmp_dir("bw-baseline");
        let dir_str = dir.to_str().unwrap().to_string();
        shaper::configure(&dir_str);
        shaper::set(
            &dir_str,
            br#"{"enabled":false,"seed":9,"uplink":{"rateBps":25000,"delayMs":0,"lossPct":100,"lossModel":"random"}}"#,
        )
        .expect("a disabled config is still schema-valid");

        const N: usize = 32;
        let (loop_end, peer) = UnixDatagram::pair().unwrap();
        install_fd(loop_end.as_raw_fd()).expect("install mock fd");
        drop(loop_end);
        assert!(start(95).expect("start loop"), "loop must start");
        reset_read_count();

        let frame = paced_frame(1_500);
        let w = peer.try_clone().unwrap();
        let sent_at = std::time::Instant::now();
        for _ in 0..N {
            w.send(&frame).expect("send frame");
        }
        assert!(
            wait_until(|| read_count() == N, Duration::from_secs(3)),
            "the disabled datapath must read all frames; got {} of {N}",
            read_count()
        );
        let elapsed_ms = sent_at.elapsed().as_millis();

        let occ = shaper::buffer_stats().uplink;
        assert_eq!(occ.frames, 0, "disabled shaping must buffer nothing");
        assert_eq!(occ.bytes, 0);
        let json = shaper::counters_json();
        assert_eq!(json["lossDropped"], serde_json::json!(0), "no added loss");
        assert_eq!(json["bufferDropped"], serde_json::json!(0));
        assert_eq!(json["upFramesShaped"], serde_json::json!(0));
        assert!(
            elapsed_ms < 2_000,
            "the disabled baseline must not add a real-time delay; took {elapsed_ms} ms"
        );
        println!(
            "shaper_disabled_throughput_baseline: N={N} elapsed_ms={elapsed_ms} \
             uplink_frames={} lossDropped={} bufferDropped={}",
            occ.frames, json["lossDropped"], json["bufferDropped"]
        );

        stop();
        assert_eq!(running_count(), 0);
        shaper::reset_for_test();
        shaper::reset_counters();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A distinct, valid `len`-byte IPv4/UDP frame keyed by `seq`. The dest port
    /// is 443 (never 53) and it is unfragmented, so it is a non-exempt data frame
    /// exactly like a real downlink TCP/UDP payload — the case the shaper must
    /// keep bounded under many concurrent flows.
    fn flow_frame(len: usize, seq: u64) -> Vec<u8> {
        let mut f = vec![0u8; len];
        f[0] = 0x45; // IPv4, IHL 5
        f[2..4].copy_from_slice(&(len as u16).to_be_bytes());
        f[8] = 64; // TTL
        f[9] = 17; // UDP
        f[12..16].copy_from_slice(&[10, 10, 0, 2]); // src
        f[16..20].copy_from_slice(&[10, 10, 0, 9]); // dst
        f[20..22].copy_from_slice(&(40_000u16 + (seq % 1000) as u16).to_be_bytes()); // src port
        f[22..24].copy_from_slice(&443u16.to_be_bytes()); // dst port
        f[24..26].copy_from_slice(&((len - 20) as u16).to_be_bytes());
        f[28..36].copy_from_slice(&seq.to_be_bytes()); // per-flow marker
        f
    }

    /// Deterministic memory-bound pressure test (Todo 10, D7): many concurrent
    /// downlink flows behind a sustained rate limit. Every frame parks in the
    /// release heap (low rate + multi-second delay), so the deterministic
    /// `buffer_stats` probe must never report occupancy past the byte cap or
    /// `MAX_FRAMES`; overflow is the documented drop-newest count, and
    /// released + dropped always accounts for every pushed frame.
    #[test]
    fn many_flows_downlink_shaping_occupancy_bounded() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shaper::reset_counters();

        let mut cfg = shaper::ShaperConfig {
            enabled: true,
            seed: Some(0xD0FF),
            ..Default::default()
        };
        cfg.downlink.rate_bps = 1_000_000;
        cfg.downlink.delay_ms = 5_000;

        let now = Instant::now();
        let mut pump = ShapePump::new(
            shaper::ShaperDirection::Downlink,
            &cfg.downlink,
            pump_seed(&cfg),
            now,
        );

        const FRAMES: usize = 20_000;
        const FRAME_LEN: usize = 1_500;
        const CAP: usize = shaper::BUFFER_BYTES_PER_DIRECTION;
        const MAX_FRAMES: usize = shaper::MAX_FRAMES;

        let mut worst_bytes = 0usize;
        let mut worst_frames = 0usize;
        let mut trace: Vec<(usize, usize, usize)> = Vec::new();
        for seq in 0..FRAMES as u64 {
            let ready = pump.on_frame(&cfg, true, now, flow_frame(FRAME_LEN, seq));
            assert!(ready.is_empty(), "a 5s delay must never release inline at now");
            let stats = shaper::buffer_stats().downlink;
            worst_bytes = worst_bytes.max(stats.bytes);
            worst_frames = worst_frames.max(stats.frames);
            assert!(
                stats.bytes <= CAP,
                "seq {seq}: buffered bytes {} exceed cap {CAP}",
                stats.bytes
            );
            assert!(
                stats.frames <= MAX_FRAMES,
                "seq {seq}: buffered frames {} exceed {MAX_FRAMES}",
                stats.frames
            );
            if seq % 2_000 == 0 {
                trace.push((seq as usize, stats.frames, stats.bytes));
            }
        }

        let after_push = shaper::buffer_stats().downlink;
        let json = shaper::counters_json();
        let dropped = json["bufferDropped"].as_u64().unwrap();
        assert!(dropped > 0, "drop-newest must kick in once a cap is reached");
        assert_eq!(
            json["lossDropped"],
            serde_json::json!(0),
            "no random loss is configured, so every drop is a buffer drop"
        );
        assert_eq!(after_push.frames, MAX_FRAMES, "the frame cap must be saturated");
        assert!(after_push.bytes <= CAP);
        trace.push((FRAMES, after_push.frames, after_push.bytes));

        let released = pump.take_ready(now + Duration::from_secs(60));
        assert_eq!(
            released.len() as u64 + dropped,
            FRAMES as u64,
            "every pushed frame is either released or a documented drop-newest"
        );
        assert_eq!(released.len(), MAX_FRAMES, "exactly the buffered frames come back");
        assert_eq!(pump.next_deadline(), None, "the heap must be fully drained");
        let end = shaper::buffer_stats().downlink;
        assert_eq!(end.frames, 0);
        assert_eq!(end.bytes, 0);

        println!(
            "many_flows_downlink_shaping_occupancy_bounded: pushed={FRAMES} \
             released={} dropped={dropped} worst_bytes={worst_bytes} worst_frames={worst_frames} \
             cap={CAP} max_frames={MAX_FRAMES} trace(seq,frames,bytes)={trace:?} json={json}",
            released.len(),
        );
    }

    /// Manual RSS observation (Todo 10 / Oracle6): RSS is App-dependent, so it is
    /// a coarse `#[ignore]` signal and NEVER a gate. Run with
    /// `cargo test -p gstore_mod_proxy shaper_rss_under_stress_manual -- --ignored --nocapture`.
    #[test]
    #[ignore = "manual RSS observation: run with --ignored --nocapture"]
    fn shaper_rss_under_stress_manual() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        shaper::reset_counters();

        let mut cfg = shaper::ShaperConfig {
            enabled: true,
            seed: Some(0x5255),
            ..Default::default()
        };
        cfg.downlink.rate_bps = 1_000_000;
        cfg.downlink.delay_ms = 5_000;

        let now = Instant::now();
        let mut pump = ShapePump::new(
            shaper::ShaperDirection::Downlink,
            &cfg.downlink,
            pump_seed(&cfg),
            now,
        );

        const FRAMES: usize = 50_000;
        let rss0 = crate::limits::rss_kb();
        for seq in 0..FRAMES as u64 {
            let _ = pump.on_frame(&cfg, true, now, flow_frame(1_500, seq));
        }
        let rss = crate::limits::rss_kb();
        let stats = shaper::buffer_stats().downlink;
        let json = shaper::counters_json();
        crate::limits::bench_line(
            "shaper_rss_stress",
            &[
                ("frames", FRAMES as u128),
                ("buffered_frames", stats.frames as u128),
                ("buffered_bytes", stats.bytes as u128),
                (
                    "buffer_dropped",
                    json["bufferDropped"].as_u64().unwrap_or(0) as u128,
                ),
                ("rss_kb", rss as u128),
                ("rss_delta_kb", rss.saturating_sub(rss0) as u128),
            ],
        );

        // The deterministic caps remain the only gate; RSS is evidence only.
        assert!(stats.bytes <= shaper::BUFFER_BYTES_PER_DIRECTION);
        assert!(stats.frames <= shaper::MAX_FRAMES);
        let _ = pump.take_ready(now + Duration::from_secs(60));
        shaper::reset_counters();
    }

    /// Drop any loop/pending fd left by an earlier test.
    fn shallow_reset() {
        if let Some(_) = stop() {
            // joined above
        }
        let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
        st.pending = None;
        st.pending_host_fd = -1;
        st.last_host_fd = -1;
        reset_read_count();
    }
}
