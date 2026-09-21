//! gstore_mod_proxy — Android cross-compile spike for the meow-rs proxy kernel.
//!
//! **This is Todo 1 of `.omo/plans/vpn-proxy-kernel.md`: a risk-first spike.**
//! Its only job is to prove that meow-rs can be consumed as *libraries* from an
//! external crate, cross-compiled for Android with the project NDK, and that the
//! netstack (lwIP) datapath is reachable **without forking meow**.
//!
//! What lives here:
//!  * [`gstore_mod_proxy_probe`] — the required `#[no_mangle]` export. It also
//!    address-takes the whole meow API surface so the Android link step really
//!    resolves meow/BoringSSL/lwIP symbols (LTO cannot drop address-taken fns).
//!  * [`bounded_runtime`] — the only runtime construction allowed in this
//!    project (`new_multi_thread().worker_threads(N <= 4)`), never
//!    `Runtime::new()` / CPU-default workers (Android SIGSEGV, see
//!    `rust/gstore_mod_repo/src/lib.rs:117-120`).
//!  * [`datapath_selftest`] — the HARD GATE: builds `meow_lwip::NetStack` on our
//!    bounded runtime and shuttles real IP frames between the stack and a real
//!    fd (a `socketpair`), both directions.
//!
//! No Dart/Flutter/FRB symbols are referenced here (module crates are pure
//! Rust cdylibs — `rust/ARCHITECTURE.md` §3.6).

/// Required spike export: proves the crate loads as `libgstore_mod_proxy.so`.
/// Address-taking the meow API surface inside makes the Android link step a
/// genuine proof that every entry point the real module will use resolves.
#[no_mangle]
pub extern "C" fn gstore_mod_proxy_probe() -> i32 {
    meow_api_surface();
    1
}

/// The **only** permitted async runtime shape for GStore modules on Android.
///
/// `worker_threads` is bounded (<= 4). `Runtime::new()` uses the CPU-default
/// worker count and has been observed to SIGSEGV inside a dlopen'ed `.so` on
/// Android (see `rust/gstore_mod_repo/src/lib.rs:117-120`). A bounded
/// multi-thread runtime is the pattern already shipping in
/// `rust/gstore_mod_download/src/lib.rs:173-181`.
pub fn bounded_runtime() -> std::io::Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .thread_name("gstore-proxy")
        .build()
}

/// References every meow entry point the real module will call. The key
/// constructors are coerced to concrete `fn` pointers and passed through
/// `black_box`, which forces LTO to emit them — and therefore link the C deps
/// they pull in (lwIP for the netstack, BoringSSL for the proxy layer). The
/// remaining references guarantee the API stays public and type-checks under
/// the Android configuration. Either way, a loss of public visibility, a
/// feature-flag regression, or a C-link failure breaks the cross-compile
/// instead of surfacing at integration time.
#[inline(never)]
fn meow_api_surface() {
    let tunnel_new: fn(std::sync::Arc<meow_dns::Resolver>) -> meow_tunnel::Tunnel =
        meow_tunnel::Tunnel::new;
    std::hint::black_box(tunnel_new);
    std::hint::black_box(meow_tunnel::Tunnel::inner);
    std::hint::black_box(meow_tunnel::Tunnel::update_proxies);
    std::hint::black_box(meow_tunnel::Tunnel::update_rules);
    std::hint::black_box(meow_tunnel::tcp::handle_tcp);
    std::hint::black_box(meow_tunnel::udp::handle_udp);

    std::hint::black_box(meow_config::subscription::fetch_subscription);
    std::hint::black_box(meow_config::subscription::parse_subscription_yaml);
    std::hint::black_box(meow_config::rebuild_from_raw);

    let mixed_new: fn(meow_tunnel::Tunnel, std::net::SocketAddr, String) -> meow_listener::MixedListener =
        meow_listener::MixedListener::new;
    std::hint::black_box(mixed_new);
    std::hint::black_box(meow_listener::MixedListener::run);

    std::hint::black_box(meow_api::routes::create_router);
    std::hint::black_box(meow_api::ApiServer::run);

    let netstack_parts = || Result::<
        (meow_lwip::NetStack, meow_lwip::TcpListener, Box<meow_lwip::UdpSocket>),
        meow_lwip::Error,
    >::Ok;
    let _ = netstack_parts;
    let netstack_new: fn() -> Result<
        (meow_lwip::NetStack, meow_lwip::TcpListener, Box<meow_lwip::UdpSocket>),
        meow_lwip::Error,
    > = meow_lwip::NetStack::new;
    std::hint::black_box(netstack_new);
    let netstack_buf: fn(usize, usize) -> Result<
        (meow_lwip::NetStack, meow_lwip::TcpListener, Box<meow_lwip::UdpSocket>),
        meow_lwip::Error,
    > = meow_lwip::NetStack::with_buffer_size;
    std::hint::black_box(netstack_buf);
    std::hint::black_box(meow_lwip::NetStack::core_done);

    let resolver_slot: fn(std::sync::Arc<meow_dns::Resolver>) -> meow_dns::ResolverSlot =
        meow_dns::new_resolver_slot;
    std::hint::black_box(resolver_slot);
    std::hint::black_box(std::any::type_name::<meow_proxy::DirectAdapter>());

    // Android-only: `meow_common::set_socket_protector` / `SocketProtector` are
    // re-exported under `#[cfg(target_os = "android")]` only. This is the single
    // hook the host JNI bridge installs so *every* outbound socket (TCP/UDP/DNS/
    // libc getaddrinfo) bypasses the VPN.
    #[cfg(target_os = "android")]
    {
        use std::os::fd::RawFd;

        struct HostFdProtector;
        impl meow_common::SocketProtector for HostFdProtector {
            fn protect(&self, _fd: RawFd) -> std::io::Result<()> {
                Ok(())
            }
        }
        std::hint::black_box(&HostFdProtector as &dyn meow_common::SocketProtector);
        std::hint::black_box(meow_common::set_socket_protector);
    }
}

/// Outcome of [`datapath_selftest`], for logging/evidence.
#[derive(Debug, Clone)]
pub struct DatapathReport {
    /// `meow_lwip::NetStack::new()` succeeded on the bounded runtime.
    pub stack_built: bool,
    /// Bytes of the IP frame lwIP emitted (egress path).
    pub egress_frame_bytes: usize,
    /// IP version nibble of the emitted frame (4 for IPv4).
    pub egress_ip_version: u8,
    /// Bytes of that frame actually delivered through the real fd.
    pub fd_delivered_bytes: usize,
    /// The frame read back from the fd was accepted by the stack ingress `Sink`.
    pub ingress_accepted: bool,
    /// The `TcpListener` accept stream stayed open/pollable (flow-dispatch handle).
    pub tcp_listener_pollable: bool,
    /// TCP/UDP flow-dispatch entry points are public (compile-time proof).
    pub tcp_flow_api_public: bool,
    pub udp_flow_api_public: bool,
}

/// **HARD GATE.** Prove the Android datapath is viable without forking meow:
///
/// 1. Build `meow_lwip::NetStack` on the bounded runtime.
/// 2. Push a UDP datagram into the netstack; lwIP emits a real IP frame on the
///    egress stream.
/// 3. Write that frame to a real fd (`socketpair`); the peer receives it.
/// 4. Send the frame back through the fd, read it, and feed it to the netstack
///    ingress `Sink` (fd -> stack path).
/// 5. Poll the `TcpListener` accept stream to confirm the flow-dispatch handle
///    is alive and public.
///
/// A host `socketpair` stands in for the Android TUN fd; the same code path runs
/// on-device. All work happens inside one bounded runtime, never `Runtime::new()`.
#[cfg(unix)]
pub fn datapath_selftest() -> Result<DatapathReport, String> {
    use std::net::SocketAddr;
    use std::time::Duration;

    use futures::{SinkExt, StreamExt};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let rt = bounded_runtime().map_err(|e| format!("bounded_runtime: {e}"))?;

    rt.block_on(async {
        // A real fd pair: `fd_side` is the "TUN" endpoint our loop owns,
        // `device_side` is the kernel/peer. On device the fd comes from
        // `VpnService.establish()`; here a socketpair is equivalent.
        let (mut fd_side, mut device_side) =
            tokio::net::UnixStream::pair().map_err(|e| format!("socketpair: {e}"))?;

        // NetStack must be built *inside* a runtime (it spawns its core task).
        let (mut stack, mut tcp_listener, udp) =
            meow_lwip::NetStack::new().map_err(|e| format!("NetStack::new: {e}"))?;

        let udp_local = udp.local_addr();
        let (udp_send, _udp_recv) = udp.split();
        // Keep `_udp_recv` alive: dropping the UdpSocket removes the lwIP pcb.

        // ---- egress: std UDP call -> lwIP -> IP frame on the egress stream ----
        let src: SocketAddr = if udp_local.ip().is_unspecified() {
            "127.0.0.1:40000".parse().unwrap()
        } else {
            udp_local
        };
        let dst: SocketAddr = "8.8.8.8:53".parse().unwrap();
        udp_send
            .send_to(b"gstore-spike", &src, &dst)
            .map_err(|e| format!("UdpSocket::send_to: {e}"))?;

        let frame = tokio::time::timeout(Duration::from_secs(5), stack.next())
            .await
            .map_err(|_| "timeout waiting for egress IP frame".to_string())?
            .ok_or_else(|| "netstack egress stream closed".to_string())?
            .map_err(|e| format!("netstack egress error: {e}"))?;

        if frame.is_empty() {
            return Err("netstack emitted an empty frame".to_string());
        }
        let egress_ip_version = frame[0] >> 4;

        // ---- fd path: write the frame to the real fd, peer must receive it ----
        fd_side
            .write_all(&frame)
            .await
            .map_err(|e| format!("fd write: {e}"))?;
        fd_side.flush().await.map_err(|e| format!("fd flush: {e}"))?;

        let mut rbuf = vec![0u8; 65_536];
        let n = tokio::time::timeout(Duration::from_secs(5), device_side.read(&mut rbuf))
            .await
            .map_err(|_| "timeout reading IP frame from fd".to_string())?
            .map_err(|e| format!("fd peer read: {e}"))?;
        if rbuf[..n] != frame[..] {
            return Err(format!(
                "fd delivered {n} bytes but expected {} bytes (content mismatch)",
                frame.len()
            ));
        }

        // ---- ingress: fd -> stack (feed a real frame into the ingress Sink) ----
        device_side
            .write_all(&frame)
            .await
            .map_err(|e| format!("device write: {e}"))?;
        device_side
            .flush()
            .await
            .map_err(|e| format!("device flush: {e}"))?;

        let mut ibuf = vec![0u8; 65_536];
        let m = tokio::time::timeout(Duration::from_secs(5), fd_side.read(&mut ibuf))
            .await
            .map_err(|_| "timeout reading IP frame back from fd".to_string())?
            .map_err(|e| format!("fd read: {e}"))?;
        let ingress_accepted = stack.send(ibuf[..m].to_vec()).await.is_ok();

        // ---- flow-dispatch handles: TcpListener accept stream is alive ----
        // No inbound SYN exists, so expect the poll to time out (not close) —
        // a timely timeout proves the stream is open and pollable.
        let tcp_listener_pollable =
            tokio::time::timeout(Duration::from_millis(100), tcp_listener.next())
                .await
                .is_err();

        Ok(DatapathReport {
            stack_built: true,
            egress_frame_bytes: frame.len(),
            egress_ip_version,
            fd_delivered_bytes: n,
            ingress_accepted,
            tcp_listener_pollable,
            // Public reachability is proven by `meow_api_surface` compiling.
            tcp_flow_api_public: true,
            udp_flow_api_public: true,
        })
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn probe_is_one() {
        assert_eq!(gstore_mod_proxy_probe(), 1);
    }

    #[test]
    fn hard_gate_datapath_shuttles_packets_over_real_fd() {
        let report = datapath_selftest().expect("datapath selftest failed");
        eprintln!("datapath report: {report:?}");
        assert!(report.stack_built);
        assert!(report.egress_frame_bytes > 0, "no egress frame emitted");
        assert_eq!(report.egress_ip_version, 4, "expected an IPv4 frame");
        assert_eq!(
            report.fd_delivered_bytes, report.egress_frame_bytes,
            "fd did not deliver the full frame"
        );
        assert!(report.ingress_accepted, "netstack ingress rejected the frame");
        assert!(report.tcp_listener_pollable, "tcp accept stream closed");
        assert!(report.tcp_flow_api_public);
        assert!(report.udp_flow_api_public);
    }
}
