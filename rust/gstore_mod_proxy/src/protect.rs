//! Outbound-socket protection seam (Todo 7).
//!
//! The host injects a `protect_fd` function pointer through ABI v3
//! (`GStoreModuleEntry::protect_fd`); it ultimately calls Android
//! `VpnService.protect(fd)`. Installing it as meow's global `SocketProtector`
//! makes meow call it before every outbound `connect()`/`bind()`, so proxy
//! adapters, DNS and hostname resolution all bypass the VPN from one hook.
//!
//! meow's `set_socket_protector` is compiled only on Android
//! (`meow-common/src/lib.rs:49-52`), so on the host target this module still
//! stores and invokes the wrapper directly (tests exercise the wrapper), while
//! the meow-hook integration itself is **UNVERIFIED on device**.
//!
//! Construction rule: our own outbound dials must go through [`connect_tcp`] /
//! [`bind_udp`], which always apply the protector before traffic. Never call
//! `TcpStream::connect` / `UdpSocket::bind` directly in this module.

use std::io;
use std::net::SocketAddr;
use std::os::fd::{AsRawFd, RawFd};
use std::os::raw::c_int;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

use gstore_contract::error::{ModuleError, StatusCode};
use tokio::net::{TcpSocket, TcpStream, UdpSocket};

/// Structured domain error: the host refused/failed to protect an outbound fd.
pub(crate) const ERR_PROTECT_FAILED: &str = "PROXY_PROTECT_FAILED";

pub(crate) type ProtectFn = extern "C" fn(c_int) -> c_int;

/// Number of `protect()` invocations on installed protectors (test proof that
/// one outbound socket causes exactly one protect call).
static PROTECT_CALLS: AtomicUsize = AtomicUsize::new(0);
/// Number of those invocations that were rejected by the host.
static PROTECT_FAILURES: AtomicUsize = AtomicUsize::new(0);

struct ProtectState {
    installed: Option<ProtectFn>,
}

static STATE: OnceLock<Mutex<ProtectState>> = OnceLock::new();

fn state() -> &'static Mutex<ProtectState> {
    STATE.get_or_init(|| Mutex::new(ProtectState { installed: None }))
}

fn current_protector() -> Option<ProtectFn> {
    state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .installed
}

/// Install (or replace) the single outbound protector. Returns `true` when a
/// host function pointer was available. Re-installing is idempotent.
pub(crate) fn install(f: Option<ProtectFn>) -> bool {
    let installed = f.is_some();
    state().lock().unwrap_or_else(|e| e.into_inner()).installed = f;

    #[cfg(target_os = "android")]
    match f {
        Some(_) => meow_common::set_socket_protector(std::sync::Arc::new(MeowSocketProtector)),
        None => meow_common::clear_socket_protector(),
    }

    installed
}

/// Remove the protector so no stale hook survives teardown.
pub(crate) fn clear() {
    state().lock().unwrap_or_else(|e| e.into_inner()).installed = None;

    #[cfg(target_os = "android")]
    meow_common::clear_socket_protector();
}

pub(crate) fn is_installed() -> bool {
    current_protector().is_some()
}

/// Protect one outbound fd. Counts exactly one call per invocation when a
/// protector is installed; a host failure becomes a structured
/// [`ERR_PROTECT_FAILED`] so the dial never proceeds unprotected.
pub(crate) fn protect_fd(fd: RawFd) -> Result<(), ModuleError> {
    let Some(f) = current_protector() else {
        // No host guard (non-VPN mode, host tests, or an ABI < 3 host). There is
        // nothing to bypass yet, so treat the socket as already protected.
        return Ok(());
    };
    PROTECT_CALLS.fetch_add(1, Ordering::SeqCst);
    if f(fd as c_int) != 0 {
        PROTECT_FAILURES.fetch_add(1, Ordering::SeqCst);
        return Err(ModuleError::new(
            StatusCode::InternalError,
            ERR_PROTECT_FAILED,
            format!("host protect_fd({fd}) failed; refusing to use an unprotected socket"),
        ));
    }
    Ok(())
}

fn protect_socket(fd: RawFd) -> io::Result<()> {
    protect_fd(fd).map_err(|e| io::Error::new(io::ErrorKind::PermissionDenied, e.to_string()))
}

/// Dial an outbound TCP socket, applying the protector to the fd before
/// `connect()` so the very first SYN bypasses the VPN. The only sanctioned
/// outbound TCP constructor for this module.
#[allow(dead_code)]
pub(crate) async fn connect_tcp(addr: SocketAddr) -> io::Result<TcpStream> {
    let socket = if addr.is_ipv4() {
        TcpSocket::new_v4()?
    } else {
        TcpSocket::new_v6()?
    };
    protect_socket(socket.as_raw_fd())?;
    socket.connect(addr).await
}

/// Bind an outbound UDP socket, applying the protector to the fd before the
/// socket can carry a datagram. The only sanctioned outbound UDP constructor
/// for this module.
#[allow(dead_code)]
pub(crate) async fn bind_udp(local: SocketAddr) -> io::Result<UdpSocket> {
    let socket = std::net::UdpSocket::bind(local)?;
    protect_socket(socket.as_raw_fd())?;
    socket.set_nonblocking(true)?;
    UdpSocket::from_std(socket)
}

/// Test/diagnostic accessors.
#[allow(dead_code)]
pub(crate) fn protect_calls() -> usize {
    PROTECT_CALLS.load(Ordering::SeqCst)
}

#[allow(dead_code)]
pub(crate) fn protect_failures() -> usize {
    PROTECT_FAILURES.load(Ordering::SeqCst)
}

#[cfg(test)]
pub(crate) fn reset_counts() {
    PROTECT_CALLS.store(0, Ordering::SeqCst);
    PROTECT_FAILURES.store(0, Ordering::SeqCst);
}

#[cfg(target_os = "android")]
struct MeowSocketProtector;

#[cfg(target_os = "android")]
impl meow_common::SocketProtector for MeowSocketProtector {
    fn protect(&self, fd: RawFd) -> io::Result<()> {
        protect_socket(fd)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;
    use std::sync::atomic::AtomicUsize as StdAtomicUsize;
    use std::sync::Arc;
    use std::time::Duration;

    use crate::TEST_SERIAL as SERIAL;

    static COUNTING_FDS: StdAtomicUsize = StdAtomicUsize::new(0);
    static ORDERING_PRE_CONNECT: StdAtomicUsize = StdAtomicUsize::new(0);
    static STUB_FAILS: StdAtomicUsize = StdAtomicUsize::new(0);

    fn reset_stub_state() {
        COUNTING_FDS.store(0, Ordering::SeqCst);
        ORDERING_PRE_CONNECT.store(0, Ordering::SeqCst);
        STUB_FAILS.store(0, Ordering::SeqCst);
        reset_counts();
    }

    /// Never fails; counts each fd handed to it.
    extern "C" fn counting_protect(_fd: c_int) -> c_int {
        COUNTING_FDS.fetch_add(1, Ordering::SeqCst);
        0
    }

    /// Fails every call, like a `VpnService.protect` that returns false.
    extern "C" fn failing_protect(_fd: c_int) -> c_int {
        -1
    }

    /// Records that the fd is open but not yet connected at the moment protect
    /// runs — the invariant `VpnService.protect` relies on.
    extern "C" fn ordering_protect(fd: c_int) -> c_int {
        let open = unsafe { libc::fcntl(fd, libc::F_GETFD) } != -1;
        let mut sa: libc::sockaddr_storage = unsafe { std::mem::zeroed() };
        let mut len = std::mem::size_of_val(&sa) as libc::socklen_t;
        let peer = unsafe {
            libc::getpeername(fd, &mut sa as *mut _ as *mut libc::sockaddr, &mut len)
        };
        let not_connected = peer == -1
            && io::Error::last_os_error().raw_os_error() == Some(libc::ENOTCONN);
        if open && not_connected {
            ORDERING_PRE_CONNECT.fetch_add(1, Ordering::SeqCst);
        }
        0
    }

    /// Happy QA: exactly one protect call per outbound socket, and it runs
    /// before `connect()`.
    #[tokio::test]
    async fn every_outbound_socket_is_protected_exactly_once() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_stub_state();
        assert!(install(Some(ordering_protect)));
        assert!(is_installed());

        let listener = Arc::new(tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap());
        let addr = listener.local_addr().unwrap();
        let accept = {
            let listener = Arc::clone(&listener);
            tokio::spawn(async move {
                for _ in 0..3 {
                    let _ = listener.accept().await;
                }
            })
        };

        for _ in 0..3 {
            let _stream = connect_tcp(addr).await.expect("protected connect");
        }
        accept.await.unwrap();

        assert_eq!(protect_calls(), 3, "one protect call per outbound socket");
        assert_eq!(protect_failures(), 0);
        assert_eq!(
            ORDERING_PRE_CONNECT.load(Ordering::SeqCst),
            3,
            "protect must run on an open, not-yet-connected fd"
        );
        clear();
        assert!(!is_installed());
    }

    /// Counts without failing, to prove the count tracks the dial count even
    /// when a prior test left a protector set.
    #[tokio::test]
    async fn protect_count_equals_outbound_connection_count() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_stub_state();
        assert!(install(Some(counting_protect)));

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let accept = tokio::spawn(async move {
            for _ in 0..2 {
                let _ = listener.accept().await;
            }
        });
        for _ in 0..2 {
            drop(connect_tcp(addr).await.expect("connect"));
        }
        accept.await.unwrap();
        assert_eq!(COUNTING_FDS.load(Ordering::SeqCst), 2);
        assert_eq!(protect_calls(), 2);
        clear();
    }

    /// Failure QA: a rejected protect aborts the dial with a structured
    /// `PROXY_PROTECT_FAILED` and never hangs; nothing reaches the listener.
    #[tokio::test]
    async fn failed_protect_aborts_dial_with_structured_error() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_stub_state();
        assert!(install(Some(failing_protect)));

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        let result = tokio::time::timeout(Duration::from_secs(2), connect_tcp(addr))
            .await
            .expect("connect must not hang when protect fails");
        let err = result.expect_err("protect failure must abort the dial");
        assert!(
            err.to_string().contains(ERR_PROTECT_FAILED),
            "error must carry {ERR_PROTECT_FAILED}, got: {err}"
        );
        assert_eq!(protect_calls(), 1);
        assert_eq!(protect_failures(), 1);

        // The connection was never attempted: the listener has nothing queued.
        let accept = tokio::time::timeout(Duration::from_millis(150), listener.accept()).await;
        assert!(accept.is_err(), "no connection may reach the listener");
        clear();
    }

    /// A socket cannot skip protection by construction: the only outbound
    /// constructors in this module route through `protect_socket`, and with a
    /// failing protector they return before any connect/bind traffic.
    #[tokio::test]
    async fn outbound_helpers_cannot_skip_protection() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_stub_state();
        assert!(install(Some(failing_protect)));

        let err = bind_udp("127.0.0.1:0".parse().unwrap())
            .await
            .expect_err("udp bind must fail when protect fails");
        assert!(err.to_string().contains(ERR_PROTECT_FAILED));
        assert_eq!(protect_failures(), 1);

        // Uninstalled protector = non-VPN mode: dials proceed unprotected only
        // because there is nothing to bypass; still counted zero.
        clear();
        let addr: SocketAddr = "127.0.0.1:0".parse().unwrap();
        let _sock = bind_udp(addr).await.expect("plain bind without protector");
        assert_eq!(protect_calls(), 1, "unprotected path adds no protect call");
    }

    /// A closed descriptor is still just an `i32` to the wrapper; the host
    /// decides. Here a real socketpair fd proves the count path.
    #[test]
    fn protect_fd_counts_and_propagates_failures() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_stub_state();
        let (a, _b) = UnixStream::pair().unwrap();
        let fd = a.as_raw_fd();

        assert!(install(Some(counting_protect)));
        protect_fd(fd).expect("counting protector ok");
        assert_eq!(protect_calls(), 1);

        assert!(install(Some(failing_protect)));
        let err = protect_fd(fd).expect_err("failing protector");
        assert_eq!(err.code, ERR_PROTECT_FAILED);
        assert_eq!(protect_failures(), 1);

        clear();
    }
}
