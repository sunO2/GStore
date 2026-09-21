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

use futures::{SinkExt, StreamExt};
use gstore_contract::error::{ModuleError, StatusCode};
use tokio::io::unix::AsyncFd;
use tokio::sync::{mpsc, watch};

/// Domain error code for an unusable / missing TUN fd (`rust/ERROR_CODES.md`).
pub(crate) const ERR_TUN_FD_INVALID: &str = "PROXY_TUN_FD_INVALID";

const LOOP_THREAD_NAME: &str = "gstore-proxy-tun";
const READ_BUFFER_SIZE: usize = 65_535; // covers IPv4/IPv6 MTU with headroom
const STACK_BUFFER_SIZE: usize = 1024;
const UDP_BUFFER_SIZE: usize = 256;
const INGRESS_CHANNEL: usize = 256;
const CORE_DONE_TIMEOUT: Duration = Duration::from_secs(3);

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

/// `core.start` (vpn mode): spawn the single reader loop if not already running.
/// Returns `false` when a loop was already live (idempotent no-op).
pub(crate) fn start(instance_id: u64) -> Result<bool, ModuleError> {
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

    RUNNING.fetch_add(1, Ordering::SeqCst);
    let join = match std::thread::Builder::new()
        .name(LOOP_THREAD_NAME.to_string())
        .spawn(move || {
            run_thread(owned, stop_rx);
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

/// `destroy`/`shutdown`: tear down everything and drop our pending dup.
pub(crate) fn shutdown() {
    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(active) = st.active.take() {
        stop_and_join(active);
    }
    st.pending = None;
    st.pending_host_fd = -1;
    st.last_host_fd = -1;
}

#[allow(dead_code)]
pub(crate) fn is_running() -> bool {
    state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .active
        .is_some()
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

fn run_thread(owned: OwnedFd, stop_rx: watch::Receiver<bool>) {
    let rt = match crate::bounded_runtime() {
        Ok(rt) => rt,
        Err(e) => {
            crate::log_message(3, &format!("proxy: TUN loop runtime build failed: {e}"));
            return;
        }
    };
    rt.block_on(tun_loop(owned, stop_rx));
    drop(rt); // joins the 4 bounded worker threads deterministically
    crate::log_message(1, "proxy: TUN loop thread exited");
}

/// The real datapath. Builds the netstack on this runtime (so meow's
/// `tokio::spawn` uses `Handle::current()` = our 4 workers), then runs three
/// tasks: the single fd reader, the ingress pump (fd → stack), and the egress
/// pump (stack → fd). Only the reader ever calls `read()`.
async fn tun_loop(owned: OwnedFd, mut stop_rx: watch::Receiver<bool>) {
    let built = meow_lwip::NetStack::with_buffer_size(STACK_BUFFER_SIZE, UDP_BUFFER_SIZE);
    let (stack, tcp_listener, udp) = match built {
        Ok(v) => v,
        Err(e) => {
            crate::log_message(3, &format!("proxy: NetStack build failed: {e}"));
            return;
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
            return;
        }
    };
    let (ingress_tx, mut ingress_rx) = mpsc::channel::<Vec<u8>>(INGRESS_CHANNEL);

    // --- the ONE reader -----------------------------------------------------
    let reader = {
        let afd = afd.clone();
        let mut stop = stop_rx.clone();
        tokio::spawn(async move {
            let mut buf = vec![0u8; READ_BUFFER_SIZE];
            loop {
                tokio::select! {
                    _ = stop.changed() => break,
                    ready = afd.readable() => {
                        let mut guard = match ready {
                            Ok(g) => g,
                            Err(_) => break,
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
                                    break;
                                }
                            }
                            Ok(Err(e)) if e.kind() == io::ErrorKind::WouldBlock => {}
                            Ok(Err(_)) | Err(_) => {}
                        }
                    }
                }
            }
        })
    };

    // --- egress pump: stack → fd -------------------------------------------
    let egress = {
        let afd = afd.clone();
        tokio::spawn(async move {
            let mut stream = stream;
            while let Some(item) = stream.next().await {
                match item {
                    Ok(frame) if !frame.is_empty() => {
                        let _ = write_frame(&afd, &frame).await;
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
        })
    };

    // --- ingress pump: fd → stack ------------------------------------------
    let ingress = tokio::spawn(async move {
        let mut sink = sink;
        while let Some(frame) = ingress_rx.recv().await {
            if sink.send(frame).await.is_err() {
                break;
            }
        }
    });

    // Flow-dispatch handles (TcpListener accept stream + UDP socket) are handed
    // to the meow tunnel dispatcher; the protector is installed first so any
    // outbound socket a dial opens is protected from the very first packet.
    let protect_installed = crate::protect::install(crate::host_protect_fd());
    let dns_engine = crate::dns::ensure_engine().await;
    let engine = crate::dispatch::build_engine(dns_engine.resolver());
    let dispatcher = crate::dispatch::spawn(engine, tcp_listener, udp, Some(Arc::clone(&dns_engine)));
    crate::log_message(
        1,
        &format!("proxy: flow dispatch active protectInstalled={protect_installed}"),
    );

    // Wait for the stop signal from `core.stop`.
    while !*stop_rx.borrow() {
        if stop_rx.changed().await.is_err() {
            break;
        }
    }

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
        let _g = SERIAL.lock().unwrap();
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
        let _g = SERIAL.lock().unwrap();
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
        let _g = SERIAL.lock().unwrap();
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
        let _g = SERIAL.lock().unwrap();
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
