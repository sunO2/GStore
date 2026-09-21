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
use std::time::Duration;

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
    instance_id: u64,
) -> LoopExit {
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
    let reader = {
        let afd = afd.clone();
        let mut stop = stop_rx.clone();
        let tx = death_tx.clone();
        spawn_guarded(
            "reader",
            async move {
                let mut buf = vec![0u8; READ_BUFFER_SIZE];
                loop {
                    tokio::select! {
                        _ = stop.changed() => return Ok(()),
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
                                    if ingress_tx.send(buf[..n].to_vec()).await.is_err() {
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
                    }
                }
            },
            tx,
        )
    };

    // --- egress pump: stack → fd -------------------------------------------
    let egress = {
        let afd = afd.clone();
        let tx = death_tx.clone();
        spawn_guarded(
            "egress",
            async move {
                let mut stream = stream;
                while let Some(item) = stream.next().await {
                    match item {
                        Ok(frame) if !frame.is_empty() => {
                            if let Err(e) = write_frame(&afd, &frame).await {
                                crate::log_message(
                                    3,
                                    &format!("proxy: TUN egress write failed: {e}"),
                                );
                            }
                        }
                        Ok(_) => {}
                        Err(_) => return Err("netstack egress stream errored".to_string()),
                    }
                }
                Err("netstack egress stream ended unexpectedly".to_string())
            },
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
    let dispatcher = crate::dispatch::spawn(engine, tcp_listener, udp, Some(Arc::clone(&dns_engine)), instance_id);
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::io::Write as _;
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
        let mut w = peer.try_clone().unwrap();
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
        let mut peer_read = peer.try_clone().unwrap();
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
        let mut peer_write = peer.try_clone().unwrap();
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
