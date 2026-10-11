//! Flow dispatch: accepted netstack flows -> meow tunnel routing (Todo 7).
//!
//! The TUN loop owns one [`meow_lwip::NetStack`]; this module consumes its
//! `TcpListener` accept stream and `UdpSocket` receive stream and hands each
//! flow to meow's routing engine ([`meow_tunnel::tcp::handle_tcp`] /
//! [`meow_tunnel::udp::handle_udp`]). Every outbound socket a dial then opens
//! (proxy adapter, DNS, hostname resolution) goes through meow's global
//! `SocketProtector` installed in [`crate::protect`], so none can loop back
//! into the VPN.
//!
//! Engine configuration (DNS nameservers, proxy list, rule set) arrives in
//! Todos 8/9: DNS supplies the resolver, and [`crate::rules`] publishes the
//! compiled Clash ruleset into the tunnel (an empty ruleset resolves to meow's
//! built-in DIRECT adapter).

use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::panic::AssertUnwindSafe;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use futures::{FutureExt, StreamExt};
use meow_common::{ConnType, Metadata, Network, ProxyConn};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use crate::capture::{self, AppAttribution};
use crate::dns::DnsEngine;
use crate::mitm::{
    self, BridgeContext, CertificateAuthority, MitmFailure, MitmGateObserver, MitmStage, MitmTls,
    TunnelUpstreamDialer, UpstreamDialer, UpstreamTarget,
};
use crate::sniff;

/// Event type for one DNS query record (Todo 15/16 consume it).
pub(crate) const EVT_DNS: &str = "proxy.dns";

/// Emit a DNS query record as a `proxy.dns` event. The payload is the record
/// JSON documented in `API.md` §3; the same record also goes to the module log
/// path (`proxy.dns.query` / `proxy.dns.failure`).
pub(crate) fn emit_dns_event(record_json: &str) {
    crate::emit_event(0, EVT_DNS, record_json.as_bytes());
}

/// Build the routing engine over the configured resolver.
///
/// The resolver (nameservers, fake-IP pools, hostname hook) is owned by the
/// DNS subsystem ([`crate::dns::ensure_engine`]); this just wires it into the
/// tunnel so hostname dials made by meow adapters consult it through
/// [`meow_common::set_host_resolver`] instead of libc `getaddrinfo` (whose own
/// DNS sockets would be unprotected and loop through the VPN).
pub(crate) fn build_engine(resolver: Arc<meow_dns::Resolver>) -> Arc<meow_tunnel::tunnel::TunnelInner> {
    meow_common::set_host_resolver(Arc::new(meow_dns::ResolverHostHook::new(Arc::clone(
        &resolver,
    ))));
    let tunnel = meow_tunnel::Tunnel::new(resolver);
    let tunnel = crate::rules::attach_tunnel(tunnel);
    tunnel.inner().clone()
}

/// Live flow-dispatch tasks; abort + await for deterministic teardown (the
/// netstack handles they own must drop before lwIP's `core_done`).
pub(crate) struct Dispatcher {
    tcp: tokio::task::JoinHandle<()>,
    udp: tokio::task::JoinHandle<()>,
}

impl Dispatcher {
    pub(crate) async fn shutdown(self) {
        self.tcp.abort();
        let _ = self.tcp.await;
        self.udp.abort();
        let _ = self.udp.await;
        crate::rules::detach_tunnel();
        meow_common::clear_host_resolver();
    }
}

/// Consume the netstack flow handles and dispatch every accepted flow.
///
/// UDP datagrams whose destination is the DNS port (`dns-hijack`) are answered
/// locally by `dns` (fake-IP / redir-host) and their reply is written back to
/// the TUN; every other datagram goes to meow's UDP dispatcher.
pub(crate) fn spawn(
    inner: Arc<meow_tunnel::tunnel::TunnelInner>,
    tcp_listener: meow_lwip::TcpListener,
    udp: Box<meow_lwip::UdpSocket>,
    dns: Option<Arc<DnsEngine>>,
) -> Dispatcher {
    let tcp_inner = Arc::clone(&inner);
    // Best-effort SNI / HTTP-Host sniffing (see `crate::sniff`): recovers a
    // domain for flows the UDP:53 fake-IP hijack never saw (DoH, Android
    // Private DNS/DoT, cached or plain-IP dials). Built once, shared per flow;
    // it only fills `metadata.sniff_host` and never changes routing.
    let sniffer = Arc::new(sniff::Sniffer::default_enabled());
    let tcp = tokio::spawn(async move {
        let mut listener = tcp_listener;
        while let Some((stream, src, dst)) = listener.next().await {
            let inner = Arc::clone(&tcp_inner);
            let sniffer = Arc::clone(&sniffer);
            tokio::spawn(handle_flow(inner, src, dst, stream, sniffer));
        }
    });

    let udp_inner = Arc::clone(&inner);
    let udp = tokio::spawn(async move {
        let (send, mut recv) = udp.split();
        let send = Arc::new(send);
        while let Ok((data, src, dst)) = recv.recv_from().await {
            if let Some(dns) = dns.as_ref() {
                if dns.is_hijacked(&dst) {
                    let dns = Arc::clone(dns);
                    let send = Arc::clone(&send);
                    tokio::spawn(async move {
                        let (response, _record) = dns.query(&data).await;
                        if let Err(e) = send.send_to(&response, &dst, &src) {
                            crate::log_message(
                                3,
                                &format!("proxy.dns: TUN reply to {src} failed: {e}"),
                            );
                        }
                    });
                    continue;
                }
            }
            let inner = Arc::clone(&udp_inner);
            tokio::spawn(async move {
                let metadata = udp_metadata(src, dst);
                meow_tunnel::udp::handle_udp(&inner, &data, src, metadata).await;
            });
        }
    });

    Dispatcher { tcp, udp }
}

/// TLS ports sniffed even when capture is disabled, so `sniff_host` still fills
/// the connection record on the common secure ports.
const BASELINE_TLS_SNIFF_PORTS: [u16; 2] = [443, 8443];
/// Prefetch budget for the baseline/best-effort ports.
const SNIFF_TIMEOUT_MS: u64 = 100;
/// Longer prefetch budget for capture-enabled ports: the gate needs the SNI /
/// `Host` before it can decide, so waiting a little longer is worthwhile.
const SNIFF_TIMEOUT_CAPTURE_MS: u64 = 400;

/// Decide whether to sniff `port` and with which parser/window.
///
/// Precedence:
/// 1. capture enabled and `tls_ports` contains the port -> TLS, 400 ms;
/// 2. baseline TLS port (`443`/`8443`) -> TLS, 100 ms;
/// 3. plaintext-HTTP capture port ([`capture::HTTP_CAPTURE_PORTS`]) -> HTTP,
///    400 ms while capture is enabled (so the may-decrypt `Host` is awaited),
///    else the baseline 100 ms;
/// 4. otherwise -> `None` (nothing is read).
///
/// A capture `tls_ports` entry always wins over the HTTP defaults, so a port
/// listed in both is sniffed as TLS, never as HTTP.
fn sniff_plan(config: &capture::CaptureConfig, port: u16) -> Option<sniff::SniffPlan> {
    if config.enabled && config.tls_ports.contains(&port) {
        return Some(sniff::SniffPlan {
            proto: sniff::SniffProto::Tls,
            timeout: Duration::from_millis(SNIFF_TIMEOUT_CAPTURE_MS),
        });
    }
    if BASELINE_TLS_SNIFF_PORTS.contains(&port) {
        return Some(sniff::SniffPlan {
            proto: sniff::SniffProto::Tls,
            timeout: Duration::from_millis(SNIFF_TIMEOUT_MS),
        });
    }
    if capture::HTTP_CAPTURE_PORTS.contains(&port) {
        return Some(sniff::SniffPlan {
            proto: sniff::SniffProto::Http,
            timeout: Duration::from_millis(if config.enabled {
                SNIFF_TIMEOUT_CAPTURE_MS
            } else {
                SNIFF_TIMEOUT_MS
            }),
        });
    }
    None
}

/// Handle one accepted TCP flow.
///
/// The sniffer runs first so the gate can consult the SNI host; its prefetched
/// bytes are replayed verbatim. A gate hit hands the stream to an isolated MITM
/// task; a miss (or any MITM init failure) falls back to the unchanged
/// [`meow_tunnel::tcp::handle_tcp`] pass-through.
pub(crate) async fn handle_flow<S>(
    inner: Arc<meow_tunnel::tunnel::TunnelInner>,
    src: SocketAddr,
    dst: SocketAddr,
    mut stream: S,
    sniffer: Arc<sniff::Sniffer>,
) where
    S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    let mut metadata = tcp_metadata(src, dst);
    let config = capture::config();
    // Prefetch the first flight, then replay it before the live stream so the
    // tunnel sees every byte in order.
    let plan = sniff_plan(&config, dst.port());
    let sniff_proto = plan.map(|p| p.proto);
    let (prefix, host) = sniffer.sniff_prefix(&mut stream, plan).await;
    if let Some(h) = host.as_deref() {
        metadata.sniff_host = h.into();
    }

    // App attribution is only resolved when it is the sole possible decider.
    let app = if capture::needs_app_resolution(&config, dst.port())
        || capture::needs_app_resolution_http(&config, dst.port())
    {
        capture::resolve_app(src, dst).await
    } else {
        AppAttribution::Unknown
    };

    // The sniff plan decides which gate applies: TLS ports consult the
    // certificate gate, plaintext-HTTP ports the CA-free one. The matched
    // host is carried with its proto so the dialer/context match below.
    let decision = match sniff_proto {
        Some(sniff::SniffProto::Tls) => {
            capture::decide_mitm(&config, dst.port(), host.as_deref(), &app)
                .map(|h| (h, sniff::SniffProto::Tls))
        }
        Some(sniff::SniffProto::Http) => {
            capture::decide_mitm_http(&config, dst.port(), host.as_deref(), &app)
                .map(|h| (h, sniff::SniffProto::Http))
        }
        None => None,
    };

    let passthrough = match decision {
        Some((mitm_host, proto)) => {
            let prefixed = sniff::PrefixedStream::new(prefix, stream);
            let (dialer, ctx) = match proto {
                // TLS: terminate, then re-originate through upstream TLS.
                sniff::SniffProto::Tls => (
                    production_dialer(&inner, &mitm_host, src, dst, config.skip_cert_verify),
                    bridge_context(&config, &mitm_host, src, dst),
                ),
                // Plaintext HTTP: no TLS on either leg, captures tagged `http`.
                sniff::SniffProto::Http => (
                    production_dialer_plain(&inner, &mitm_host, src, dst),
                    bridge_context(&config, &mitm_host, src, dst).with_scheme("http"),
                ),
            };
            match begin_mitm(prefixed, Some(mitm_host.as_str()), dialer, ctx) {
                // The isolated MITM task owns the stream now.
                Ok(()) => None,
                // Init failed before consuming a byte: pass the stream through.
                Err((prefixed, _err)) => Some(prefixed),
            }
        }
        None => Some(sniff::PrefixedStream::new(prefix, stream)),
    };

    if let Some(stream) = passthrough {
        let conn = LwipProxyConn::new(stream);
        meow_tunnel::tcp::handle_tcp(&inner, Box::new(conn), metadata).await;
    }
}

/// Why the MITM path could not be started. Every variant means the same thing:
/// leave the stream untouched and keep the existing tunnel pass-through.
#[derive(Debug)]
pub(crate) enum MitmInitError {
    /// No sniffed host.
    NoHost,
    /// No CA is installed (todo 10 owns the lifecycle).
    NoCa,
    /// At the [`crate::limits::MITM_MAX_INFLIGHT`] cap.
    InflightCap,
}

impl std::fmt::Display for MitmInitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MitmInitError::NoHost => write!(f, "no host"),
            MitmInitError::NoCa => write!(f, "no ca installed"),
            MitmInitError::InflightCap => write!(f, "inflight cap reached"),
        }
    }
}

/// Build the production upstream dialer for one gate-hit flow: a decrypted
/// request is re-originated through the live tunnel (rules/outbound/protect).
///
/// `skip_cert_verify` is the session snapshot's opt-in; true selects
/// [`mitm::upstream_tls_config_for`] with `SkipServerVerify` and records one
/// security event for the session.
pub(crate) fn production_dialer(
    inner: &Arc<meow_tunnel::tunnel::TunnelInner>,
    host: &str,
    src: SocketAddr,
    dst: SocketAddr,
    skip_cert_verify: bool,
) -> Arc<dyn UpstreamDialer> {
    let target = UpstreamTarget::new(host, dst.port())
        .with_dst_ip(dst.ip())
        .with_source(src.ip(), src.port());
    if skip_cert_verify {
        crate::log_message(
            2,
            &format!(
                "proxy.mitm: upstream cert verification DISABLED by config \
                 (skipCertVerify) host={host}"
            ),
        );
    }
    Arc::new(TunnelUpstreamDialer::new(
        Arc::clone(inner),
        target,
        mitm::upstream_tls_config_for(skip_cert_verify),
    ))
}

/// Build the production upstream dialer for one **plaintext-HTTP** gate-hit
/// flow: the captured request is re-originated as plaintext HTTP/1.1 through the
/// live tunnel (rules/outbound/protect) with no upstream TLS handshake, matching
/// the plaintext client leg.
pub(crate) fn production_dialer_plain(
    inner: &Arc<meow_tunnel::tunnel::TunnelInner>,
    host: &str,
    src: SocketAddr,
    dst: SocketAddr,
) -> Arc<dyn UpstreamDialer> {
    let target = UpstreamTarget::new(host, dst.port())
        .with_dst_ip(dst.ip())
        .with_source(src.ip(), src.port());
    Arc::new(mitm::PlainUpstreamDialer::new(Arc::clone(inner), target))
}

/// Build the bridge context for one gate-hit flow from the capture.config
/// snapshot taken at session start, so in-flight sessions are internally
/// consistent even if the live config changes mid-session.
pub(crate) fn bridge_context(
    config: &capture::CaptureConfig,
    host: &str,
    src: SocketAddr,
    dst: SocketAddr,
) -> BridgeContext {
    BridgeContext::new(host, format!("tun-{src}->{dst}"), 0)
        .with_endpoints(src, dst)
        .with_capture_body(config.capture_body)
        .with_capture_ws(config.capture_ws)
        .with_capture_h2(config.capture_h2)
        .with_max_body_bytes(config.max_body_bytes)
}

/// Finalizes the synthetic `requests` skeleton for a started MITM session when
/// the session task ends — normal completion, the session-deadline `Err`
/// branch, or panic unwind alike.
struct MitmFlowClose(String);

impl Drop for MitmFlowClose {
    fn drop(&mut self) {
        crate::requests::close_mitm_flow(&self.0, crate::now_ms());
    }
}

/// Hand a gate-hit flow to the MITM path.
///
/// `Ok(())` means an isolated task owns the stream and will terminate TLS then
/// bridge it to the tunnel-re-originated upstream. `Err((stream, _))` returns
/// the **untouched** stream (its prefetched prefix intact) so the caller can
/// pass it through byte-for-byte. Every failure is recorded as `mitmFailed`.
pub(crate) fn begin_mitm<S>(
    stream: S,
    host: Option<&str>,
    dialer: Arc<dyn UpstreamDialer>,
    ctx: BridgeContext,
) -> Result<(), (S, MitmInitError)>
where
    S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    let Some(host) = host.map(str::trim).filter(|h| !h.is_empty()) else {
        return Err((stream, init_failed(MitmInitError::NoHost)));
    };
    // Plaintext HTTP terminates no TLS, so it needs no CA; only the TLS branch
    // requires an installed certificate authority.
    let plaintext = ctx.scheme == "http";
    let ca = if plaintext {
        None
    } else {
        match mitm::ca() {
            Some(ca) => Some(ca),
            None => return Err((stream, init_failed(MitmInitError::NoCa))),
        }
    };
    let Some(guard) = mitm::InflightGuard::try_acquire() else {
        return Err((stream, init_failed(MitmInitError::InflightCap)));
    };

    let observer = mitm::gate_observer();
    let host = host.to_string();
    spawn_isolated(async move {
        // The guard releases the slot when the session ends, panic included.
        let _guard = guard;
        let mut ctx = ctx;
        let _flow_guard = match (ctx.src, ctx.dst) {
            (Some(s), Some(d)) => {
                let rid = crate::requests::open_mitm_flow(
                    &ctx.conn_id,
                    &ctx.host,
                    s,
                    d,
                    crate::now_ms(),
                );
                ctx.request_record_id = rid;
                Some(MitmFlowClose(ctx.conn_id.clone()))
            }
            _ => None,
        };
        let outcome = match ca {
            Some(ca) => {
                tokio::time::timeout(
                    mitm::session_deadline(),
                    mitigate(stream, ca, host.clone(), observer, dialer, ctx),
                )
                .await
            }
            None => {
                tokio::time::timeout(
                    mitm::session_deadline(),
                    mitigate_plaintext(stream, host.clone(), observer, dialer, ctx),
                )
                .await
            }
        };
        match outcome {
            Ok(MitmStreamOutcome::Terminated) | Ok(MitmStreamOutcome::ClientAbort) => {}
            Ok(MitmStreamOutcome::Failed(e)) => {
                crate::log_message(
                    2,
                    &format!(
                        "proxy.mitm: session failed stage={} host={host}: {}{}",
                        e.stage().as_str(),
                        e.message(),
                        diagnostic_suffix(&e),
                    ),
                );
            }
            Err(_) => {
                mitm::record_mitm_failed("session deadline exceeded");
                crate::log_message(
                    2,
                    &format!(
                        "proxy.mitm: session failed stage=session_deadline host={host}: \
                         session deadline exceeded"
                    ),
                );
            }
        }
    });
    Ok(())
}

fn init_failed(err: MitmInitError) -> MitmInitError {
    mitm::record_mitm_failed(&err.to_string());
    err
}

fn diagnostic_suffix(failure: &MitmFailure) -> String {
    let rendered = failure.diagnostics().render();
    if rendered.is_empty() {
        String::new()
    } else {
        format!(" {rendered}")
    }
}

/// Spawn a detached task that catches an unwinding panic and records it, so a
/// panicking MITM handler can never take down the TUN dataplane.
pub(crate) fn spawn_isolated<F>(future: F) -> tokio::task::JoinHandle<()>
where
    F: Future<Output = ()> + Send + 'static,
{
    let isolated = AssertUnwindSafe(future).catch_unwind();
    tokio::spawn(async move {
        if isolated.await.is_err() {
            mitm::record_mitm_failed("handler panic (isolated)");
            crate::log_message(3, "proxy.mitm: handler panicked; dataplane continues");
        }
    })
}

/// Outcome of running one MITM-terminated client stream.
#[derive(Debug)]
pub(crate) enum MitmStreamOutcome {
    /// TLS termination succeeded and the bridge finished normally.
    Terminated,
    /// The peer aborted its own connection; not a proxy failure.
    ClientAbort,
    /// A stage-tagged failure; the flow was closed.
    Failed(MitmFailure),
}

/// Run TLS termination over `stream` for `host`, then bridge the decrypted
/// session to the tunnel-re-originated upstream via [`mitm::bridge_deferred`].
///
/// Any bridge failure is fail-safe: the TLS stream is dropped (clean close),
/// the failure is recorded as `mitmFailed`, and the TUN dataplane is never
/// disrupted. Allowlisted traffic is never silently dropped while capture is
/// enabled — it is either captured or cleanly closed with a recorded failure.
pub(crate) async fn mitigate<S>(
    stream: S,
    ca: Arc<CertificateAuthority>,
    host: String,
    observer: Arc<dyn MitmGateObserver>,
    dialer: Arc<dyn UpstreamDialer>,
    ctx: BridgeContext,
) -> MitmStreamOutcome
where
    S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    observer.on_mitm_entered(&host);
    match mitm::terminate(stream, &ca, Some(host.as_str())).await {
        MitmTls::Terminated(tls) => {
            observer.on_terminated(&host);
            match mitm::bridge_deferred(tls, dialer, ctx).await {
                Ok(()) => MitmStreamOutcome::Terminated,
                Err(e) if e.is_client_abort() => {
                    crate::log_message(
                        1,
                        &format!(
                            "proxy.mitm: client_abort host={host}: {}{}",
                            e.message(),
                            diagnostic_suffix(&e),
                        ),
                    );
                    MitmStreamOutcome::ClientAbort
                }
                Err(e) => {
                    observer.on_failed(&host, &e.to_string());
                    mitm::record_mitm_failed(&format!("bridge: {e}"));
                    MitmStreamOutcome::Failed(e)
                }
            }
        }
        MitmTls::Passthrough(_stream) => {
            let e = MitmFailure::new(MitmStage::ClientTls, "unexpected passthrough");
            observer.on_failed(&host, &e.to_string());
            MitmStreamOutcome::Failed(e)
        }
        MitmTls::Failed(e) => {
            let failure = MitmFailure::new(MitmStage::ClientTls, e.to_string());
            observer.on_failed(&host, &e.to_string());
            mitm::record_mitm_failed(&failure.to_string());
            MitmStreamOutcome::Failed(failure)
        }
    }
}

/// Run the **plaintext** MITM data plane over `stream` for `host`: no TLS
/// termination on the client leg, the client is served as HTTP/1.1, and captures
/// are tagged `scheme="http"` by [`mitm::bridge_deferred_plain`].
///
/// Mirrors [`mitigate`]'s failure recording, but there is no TLS handshake to
/// terminate, so [`MitmGateObserver::on_terminated`] is not called (it is
/// TLS-termination-specific).
pub(crate) async fn mitigate_plaintext<S>(
    stream: S,
    host: String,
    observer: Arc<dyn MitmGateObserver>,
    dialer: Arc<dyn UpstreamDialer>,
    ctx: BridgeContext,
) -> MitmStreamOutcome
where
    S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    observer.on_mitm_entered(&host);
    match mitm::bridge_deferred_plain(stream, dialer, ctx).await {
        Ok(()) => MitmStreamOutcome::Terminated,
        Err(e) if e.is_client_abort() => MitmStreamOutcome::ClientAbort,
        Err(e) => {
            observer.on_failed(&host, &e.to_string());
            mitm::record_mitm_failed(&format!("plain: {e}"));
            MitmStreamOutcome::Failed(e)
        }
    }
}

fn tcp_metadata(src: SocketAddr, dst: SocketAddr) -> Metadata {
    Metadata {
        network: Network::Tcp,
        conn_type: ConnType::Tun,
        src_ip: Some(src.ip()),
        src_port: src.port(),
        dst_ip: Some(dst.ip()),
        dst_port: dst.port(),
        in_name: "tun".into(),
        ..Default::default()
    }
}

fn udp_metadata(src: SocketAddr, dst: SocketAddr) -> Metadata {
    Metadata {
        network: Network::Udp,
        ..tcp_metadata(src, dst)
    }
}

/// `ProxyConn` wrapper over the netstack stream. Only one task ever polls a
/// given connection; the `Mutex` makes the wrapper `Sync` as `ProxyConn`
/// requires without relying on the inner stream being `Sync`.
struct LwipProxyConn<S> {
    inner: Mutex<S>,
}

impl<S> LwipProxyConn<S> {
    fn new(stream: S) -> Self {
        Self {
            inner: Mutex::new(stream),
        }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for LwipProxyConn<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let mut inner = self
            .get_mut()
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Pin::new(&mut *inner).poll_read(cx, buf)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for LwipProxyConn<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let mut inner = self
            .get_mut()
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Pin::new(&mut *inner).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let mut inner = self
            .get_mut()
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Pin::new(&mut *inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let mut inner = self
            .get_mut()
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Pin::new(&mut *inner).poll_shutdown(cx)
    }
}

impl<S: AsyncRead + AsyncWrite + Send + Unpin> ProxyConn for LwipProxyConn<S> {}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::time::Duration;

    use crate::TEST_SERIAL as SERIAL;

    /// The engine builds with an empty route table and resolves every flow to
    /// meow's DIRECT fallback without panicking.
    #[test]
    fn engine_builds_with_direct_fallback() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let resolver = Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ));
        let inner = build_engine(resolver);
        let metadata = tcp_metadata(
            "10.10.0.2:40000".parse().unwrap(),
            "1.1.1.1:443".parse().unwrap(),
        );
        let (proxy, rule, _payload) = inner
            .resolve_proxy(&metadata)
            .expect("empty route table must fall back to DIRECT");
        assert_eq!(proxy.name(), "DIRECT");
        assert_eq!(&*rule, "Final");
    }

    /// The `ProxyConn` wrapper relays bytes both directions, which is what
    /// meow's relay loop drives once a flow is accepted.
    #[tokio::test]
    async fn lwip_proxy_conn_relays_both_directions() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let (client, mut peer) = tokio::io::duplex(64);
        let mut conn = LwipProxyConn::new(client);

        conn.write_all(b"ping").await.unwrap();
        conn.flush().await.unwrap();
        let mut got = [0u8; 4];
        peer.read_exact(&mut got).await.unwrap();
        assert_eq!(&got, b"ping");

        peer.write_all(b"pong").await.unwrap();
        let n = tokio::time::timeout(Duration::from_secs(1), conn.read(&mut got))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&got[..n], b"pong");

        conn.shutdown().await.unwrap();
    }
}

/// Todo 6 acceptance: the MITM gate, its fail-safe pass-through, the hard
/// in-flight cap and panic isolation.
#[cfg(all(test, unix))]
mod mitm_gate_tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    use rustls::pki_types::ServerName;
    use smallvec::SmallVec;
    use smol_str::SmolStr;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_rustls::TlsConnector;

    use super::*;
    use crate::capture::{self, CaptureConfig};
    use crate::limits::MITM_MAX_INFLIGHT;
    use crate::mitm::{self, CertificateAuthority, MitmGateObserver};
    use crate::TEST_SERIAL as SERIAL;

    static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_dir(tag: &str) -> PathBuf {
        let n = TMP_SEQ.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "gstore-mitm-gate-{}-{}-{}",
            std::process::id(),
            tag,
            n
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn test_ca(tag: &str) -> Arc<CertificateAuthority> {
        let dir = temp_dir(tag);
        Arc::new(CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate CA"))
    }

    struct UnreachableDialer;

    impl UpstreamDialer for UnreachableDialer {
        fn dial(
            &self,
        ) -> Pin<
            Box<dyn Future<Output = Result<mitm::EstablishedUpstream, MitmFailure>> + Send>,
        > {
            Box::pin(async {
                Err(MitmFailure::new(
                    MitmStage::UpstreamDial,
                    "test dialer: no upstream",
                ))
            })
        }
    }

    fn begin_test_mitm<S>(stream: S, host: &str) -> Result<(), (S, MitmInitError)>
    where
        S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
    {
        let ctx = BridgeContext::new(host, "test-conn", 0);
        begin_mitm(stream, Some(host), Arc::new(UnreachableDialer), ctx)
    }

    #[derive(Default)]
    struct RecordingObserver {
        entered: AtomicUsize,
        terminated: AtomicUsize,
        failed: AtomicUsize,
    }

    impl MitmGateObserver for RecordingObserver {
        fn on_mitm_entered(&self, _host: &str) {
            self.entered.fetch_add(1, Ordering::SeqCst);
        }
        fn on_terminated(&self, _host: &str) {
            self.terminated.fetch_add(1, Ordering::SeqCst);
        }
        fn on_failed(&self, _host: &str, _reason: &str) {
            self.failed.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn enabled(domains: &[&str], apps: &[&str]) -> CaptureConfig {
        CaptureConfig {
            enabled: true,
            domain_allowlist: domains.iter().map(|s| s.to_string()).collect(),
            app_allowlist: apps.iter().map(|s| s.to_string()).collect(),
            ..CaptureConfig::default()
        }
    }

    async fn wait_for(what: &str, pred: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !pred() {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    /// Minimal TLS ClientHello carrying SNI `hostname` (same wire shape as the
    /// `sniff` tests) so the sniffer recovers a host before the gate.
    fn build_client_hello(hostname: &str) -> Vec<u8> {
        let name_bytes = hostname.as_bytes();
        let sni_entry_len = 3 + name_bytes.len();
        let sni_list_len = sni_entry_len;
        let sni_ext_data_len = 2 + sni_list_len;

        let mut sni_ext = Vec::new();
        sni_ext.extend_from_slice(&[0x00, 0x00]);
        sni_ext.extend_from_slice(&(sni_ext_data_len as u16).to_be_bytes());
        sni_ext.extend_from_slice(&(sni_list_len as u16).to_be_bytes());
        sni_ext.push(0x00);
        sni_ext.extend_from_slice(&(name_bytes.len() as u16).to_be_bytes());
        sni_ext.extend_from_slice(name_bytes);

        let extensions_len = sni_ext.len();
        let mut hello = Vec::new();
        hello.extend_from_slice(&[0x03, 0x03]);
        hello.extend_from_slice(&[0u8; 32]);
        hello.push(0x00);
        hello.extend_from_slice(&[0x00, 0x02, 0x00, 0x2f]);
        hello.extend_from_slice(&[0x01, 0x00]);
        hello.extend_from_slice(&(extensions_len as u16).to_be_bytes());
        hello.extend_from_slice(&sni_ext);

        let handshake_len = hello.len();
        let mut handshake = vec![
            0x01,
            ((handshake_len >> 16) & 0xff) as u8,
            ((handshake_len >> 8) & 0xff) as u8,
            (handshake_len & 0xff) as u8,
        ];
        handshake.extend_from_slice(&hello);

        let record_len = handshake.len();
        let mut record = Vec::new();
        record.push(0x16);
        record.extend_from_slice(&[0x03, 0x01]);
        record.extend_from_slice(&(record_len as u16).to_be_bytes());
        record.extend_from_slice(&handshake);
        record
    }

    /// Allowlist hit => the MITM path is entered and todo 5's TLS termination
    /// actually runs (a real rustls client completes the handshake).
    #[test]
    fn mitm_gate_allowlist_hit_enters_mitm_and_terminates() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            mitm::reset_gate_counters_for_tests();
            mitm::reset_gate_observer();
            let ca = test_ca("gate-hit");
            mitm::install_ca(Arc::clone(&ca));
            let obs = Arc::new(RecordingObserver::default());
            mitm::set_gate_observer(obs.clone());

            let cfg = enabled(&["a.example"], &[]);
            assert_eq!(
                capture::decide_mitm(&cfg, 443, Some("a.example"), &AppAttribution::Unknown)
                    .as_deref(),
                Some("a.example"),
                "allowlist hit must gate MITM"
            );

            let (client, server) = tokio::io::duplex(128 * 1024);
            assert!(
                begin_test_mitm(server, "a.example").is_ok(),
                "a gate hit must start the MITM path"
            );

            let mut roots = rustls::RootCertStore::empty();
            roots.add(ca.der().clone()).expect("trust the MITM CA");
            let mut ccfg = rustls::ClientConfig::builder_with_provider(Arc::new(
                rustls::crypto::aws_lc_rs::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .expect("versions")
            .with_root_certificates(roots)
            .with_no_client_auth();
            ccfg.alpn_protocols = vec![b"http/1.1".to_vec()];
            let connector = TlsConnector::from(Arc::new(ccfg));
            let sni = ServerName::try_from("a.example").expect("sni");
            let tls = tokio::time::timeout(Duration::from_secs(10), connector.connect(sni, client))
                .await
                .expect("handshake must not hang")
                .expect("client handshake");
            wait_for("MITM termination", || obs.terminated.load(Ordering::SeqCst) == 1).await;
            assert_eq!(obs.entered.load(Ordering::SeqCst), 1, "MITM path entered");
            assert_eq!(
                obs.terminated.load(Ordering::SeqCst),
                1,
                "todo 5 TLS termination invoked"
            );
            assert_eq!(ca.signings(), 1, "a leaf was signed during termination");
            // The session now stays live until the client closes: drop the
            // client first, then the in-flight slot is released.
            drop(tls);
            wait_for("in-flight release", || mitm::inflight_count() == 0).await;

            mitm::clear_ca();
            mitm::reset_gate_observer();
        });
    }

    /// A gate miss must reach the pass-through path with the exact client bytes.
    #[test]
    fn mitm_gate_miss_passes_through_bytes_identical() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            mitm::reset_gate_counters_for_tests();
            mitm::clear_ca();

            let hello = build_client_hello("blocked.example");
            let (mut client, server) = tokio::io::duplex(64 * 1024);
            client.write_all(&hello).await.expect("pre-write");
            client.flush().await.expect("flush");

            // Exact dispatch order: sniff first, then gate.
            let sniffer = sniff::Sniffer::default_enabled();
            let mut server = server;
            let plan = sniff::SniffPlan {
                proto: sniff::SniffProto::Tls,
                timeout: Duration::from_millis(100),
            };
            let (prefix, host) = sniffer.sniff_prefix(&mut server, Some(plan)).await;
            assert_eq!(host.as_deref(), Some("blocked.example"));

            let cfg = enabled(&["allowed.example"], &[]);
            assert_eq!(
                capture::decide_mitm(&cfg, 443, host.as_deref(), &AppAttribution::Unknown),
                None,
                "an allowlist miss must not gate MITM"
            );

            // The stream handed to `handle_tcp` replays the sniffed bytes verbatim.
            let mut prefixed = sniff::PrefixedStream::new(prefix, server);
            let mut got = vec![0u8; hello.len()];
            prefixed.read_exact(&mut got).await.expect("read passthrough");
            assert_eq!(got, hello, "pass-through must be byte-identical");
            assert_eq!(mitm::inflight_count(), 0, "a miss must not start a session");
        });
    }

    /// MITM init failure (no CA) => pass-through with the bytes untouched and a
    /// recorded `mitmFailed` marker.
    #[test]
    fn mitm_gate_init_failure_passes_through_and_marks_failed() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            mitm::reset_gate_counters_for_tests();
            mitm::clear_ca();

            let (mut client, server) = tokio::io::duplex(64);
            client.write_all(b"hello").await.expect("pre-write");
            client.flush().await.expect("flush");

            let before = mitm::mitm_failed_count();
            let result = begin_test_mitm(server, "a.example");
            let Err((mut stream, err)) = result else {
                panic!("MITM init without a CA must fail");
            };
            assert!(matches!(err, MitmInitError::NoCa), "got {err}");
            assert_eq!(
                mitm::mitm_failed_count(),
                before + 1,
                "init failure must record mitmFailed"
            );

            let mut got = [0u8; 5];
            stream.read_exact(&mut got).await.expect("read passthrough");
            assert_eq!(&got, b"hello", "init failure must pass bytes through unchanged");
            assert_eq!(mitm::inflight_count(), 0);
        });
    }

    /// At the in-flight cap the next gate hit must pass through, never queue.
    #[test]
    fn mitm_gate_inflight_cap_overflow_passes_through() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            mitm::reset_gate_counters_for_tests();
            let ca = test_ca("cap");
            mitm::install_ca(ca);

            let mut held = Vec::new();
            while let Some(slot) = mitm::InflightGuard::try_acquire() {
                held.push(slot);
            }
            assert_eq!(held.len(), MITM_MAX_INFLIGHT, "cap must be MITM_MAX_INFLIGHT");
            assert_eq!(mitm::inflight_count(), MITM_MAX_INFLIGHT);

            let (mut client, server) = tokio::io::duplex(64);
            client.write_all(b"hello").await.expect("pre-write");
            client.flush().await.expect("flush");

            let before = mitm::mitm_failed_count();
            let result = begin_test_mitm(server, "a.example");
            let Err((mut stream, err)) = result else {
                panic!("overflow must not start a MITM session");
            };
            assert!(matches!(err, MitmInitError::InflightCap), "got {err}");
            assert_eq!(mitm::mitm_failed_count(), before + 1);
            let mut got = [0u8; 5];
            stream.read_exact(&mut got).await.expect("read passthrough");
            assert_eq!(&got, b"hello", "overflow must pass through, never queue");
            drop(held);

            mitm::clear_ca();
        });
    }

    /// A panic in a MITM task is caught (no JoinError), releases its in-flight
    /// slot, is recorded as `mitmFailed`, and the runtime keeps working.
    #[test]
    fn mitm_gate_panic_is_isolated_and_releases_slot() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            mitm::reset_gate_counters_for_tests();

            let handle = spawn_isolated(async {
                let _slot = mitm::InflightGuard::try_acquire().expect("slot");
                panic!("forced MITM handler panic");
            });
            assert!(
                handle.await.is_ok(),
                "spawn_isolated must catch the panic instead of surfacing a JoinError"
            );
            assert_eq!(mitm::inflight_count(), 0, "panic must release the in-flight slot");
            assert!(
                mitm::mitm_failed_count() >= 1,
                "a panicking handler must be recorded as mitmFailed"
            );

            let sibling = tokio::spawn(async { 7u32 });
            assert_eq!(sibling.await.unwrap(), 7, "dataplane runtime survives the panic");
        });
    }

    fn capture_tls_plan() -> Option<sniff::SniffPlan> {
        Some(sniff::SniffPlan {
            proto: sniff::SniffProto::Tls,
            timeout: Duration::from_millis(400),
        })
    }

    fn baseline_tls_plan() -> Option<sniff::SniffPlan> {
        Some(sniff::SniffPlan {
            proto: sniff::SniffProto::Tls,
            timeout: Duration::from_millis(100),
        })
    }

    fn http_plan(timeout_ms: u64) -> Option<sniff::SniffPlan> {
        Some(sniff::SniffPlan {
            proto: sniff::SniffProto::Http,
            timeout: Duration::from_millis(timeout_ms),
        })
    }

    /// `sniff_plan` precedence matrix: a capture-enabled `tls_ports` entry
    /// (400 ms) always wins, over both the baseline TLS ports and the HTTP
    /// defaults (100 ms); an unmapped port yields no plan at all.
    #[test]
    fn sniff_plan_matrix_and_precedence() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());

        // (a) capture-enabled tls_port on a non-default port -> TLS, 400 ms.
        let cfg = CaptureConfig {
            enabled: true,
            tls_ports: vec![9443],
            ..CaptureConfig::default()
        };
        assert_eq!(sniff_plan(&cfg, 9443), capture_tls_plan());
        capture::reset_for_tests();

        // (b) capture disabled still sniffs baseline 443 -> TLS, 100 ms.
        let cfg = CaptureConfig {
            enabled: false,
            ..CaptureConfig::default()
        };
        assert_eq!(sniff_plan(&cfg, 443), baseline_tls_plan());
        capture::reset_for_tests();

        // (c) capture-enabled baseline 443 -> TLS, 400 ms (capture window wins).
        let cfg = CaptureConfig {
            enabled: true,
            tls_ports: vec![443, 8443],
            ..CaptureConfig::default()
        };
        assert_eq!(sniff_plan(&cfg, 443), capture_tls_plan());
        capture::reset_for_tests();

        // (d) an unmapped port yields no plan at all (nothing is read).
        let cfg = CaptureConfig::default();
        assert_eq!(sniff_plan(&cfg, 22), None);
        capture::reset_for_tests();

        // (e) a capture tls_ports entry beats the HTTP default 80 -> TLS, 400 ms.
        let cfg = CaptureConfig {
            enabled: true,
            tls_ports: vec![80],
            ..CaptureConfig::default()
        };
        assert_eq!(sniff_plan(&cfg, 80), capture_tls_plan());
        capture::reset_for_tests();

        // (f) capture-enabled HTTP port (not in tls_ports) -> HTTP, 400 ms.
        let cfg = CaptureConfig {
            enabled: true,
            ..CaptureConfig::default()
        };
        assert_eq!(sniff_plan(&cfg, 80), http_plan(400));
        capture::reset_for_tests();

        // (g) capture-disabled HTTP port -> HTTP, baseline 100 ms.
        let cfg = CaptureConfig {
            enabled: false,
            ..CaptureConfig::default()
        };
        assert_eq!(sniff_plan(&cfg, 80), http_plan(100));
        capture::reset_for_tests();
    }

    /// (a) A second `open_mitm_flow` for the SAME live session `conn_id` must
    /// reuse `active_by_conn` — exactly one record is minted, never a second
    /// skeleton for one session.
    #[test]
    fn mitm_open_flow_same_session_reuses_active_record() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::requests::reset_for_tests();

        let src: SocketAddr = "10.0.0.2:41000".parse().unwrap();
        let dst: SocketAddr = "203.0.113.9:443".parse().unwrap();
        let before = crate::requests::next_record_id_for_tests();
        let first =
            crate::requests::open_mitm_flow("tun-same-session", "shop.example", src, dst, 5_000);
        let second =
            crate::requests::open_mitm_flow("tun-same-session", "shop.example", src, dst, 5_100);

        assert_eq!(
            first, second,
            "a second open for the same live conn_id must reuse active_by_conn"
        );
        assert_eq!(
            crate::requests::next_record_id_for_tests(),
            before + 1,
            "a reused session must mint exactly one request skeleton"
        );
        let page =
            crate::requests::snapshot(0, 64, &crate::requests::RequestFilter::default());
        assert_eq!(
            page.records
                .iter()
                .filter(|r| r.conn_id == "tun-same-session")
                .count(),
            1,
            "only one record may exist for the reused conn_id"
        );
        crate::requests::reset_for_tests();
    }

    fn fixture_conn_metadata(host: &str) -> Metadata {
        Metadata {
            network: Network::Tcp,
            conn_type: ConnType::Tun,
            host: host.into(),
            dst_ip: Some("1.2.3.4".parse().unwrap()),
            dst_port: 443,
            src_ip: Some("10.10.0.2".parse().unwrap()),
            src_port: 40000,
            ..Default::default()
        }
    }

    /// (e) The synthetic `tun-…` conn_id cannot appear in meow's UUID-only
    /// projection, so a `sync_full` pass mints a skeleton for each live meow
    /// connection but neither duplicates nor stales/closes the synthetic one.
    #[test]
    fn mitm_sync_full_never_duplicates_synthetic_conn() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::requests::reset_for_tests();
        crate::conn::reset_for_tests();

        let src: SocketAddr = "10.0.0.2:41000".parse().unwrap();
        let dst: SocketAddr = "203.0.113.9:443".parse().unwrap();
        let conn_id = format!("tun-{src}->{dst}");
        let rid = crate::requests::open_mitm_flow(&conn_id, "flow.test", src, dst, 5_000);
        let after_open = crate::requests::next_record_id_for_tests();

        let stats = meow_tunnel::Statistics::new();
        stats.track_connection(
            fixture_conn_metadata("meow.example"),
            SmolStr::new("DOMAIN-SUFFIX"),
            SmolStr::new("meow.example"),
            SmallVec::from_vec(vec![Arc::<str>::from("proxy-a")]),
        );
        let outcome = crate::conn::sync_full(&stats);
        assert_eq!(outcome.live.len(), 1, "the real meow connection is projected");

        assert_eq!(
            crate::requests::next_record_id_for_tests(),
            after_open + 1,
            "sync_full must mint only the real connection's skeleton, never a second synthetic one"
        );
        let page =
            crate::requests::snapshot(0, 64, &crate::requests::RequestFilter::default());
        assert_eq!(
            page.records
                .iter()
                .filter(|r| r.conn_id == conn_id)
                .count(),
            1,
            "the synthetic tun-… conn_id must stay a single record"
        );
        let synthetic = page
            .records
            .iter()
            .find(|r| r.record_id == rid)
            .expect("the synthetic skeleton survives the projection pass");
        assert_eq!(
            synthetic.close_reason, "open",
            "sync_full must not stale/close a connection outside meow's projection"
        );
        crate::requests::reset_for_tests();
        crate::conn::reset_for_tests();
    }
}

/// R1 acceptance: the MITM bridge is wired into the **production** flow entry
/// (`handle_flow` -> `begin_mitm` -> `bridge_deferred`), not exercised through
/// `bridge` directly. Every case drives `handle_flow` over a duplex that stands
/// in for the accepted in-TUN stream, and asserts the shipped capture store /
/// rule store / WS sink actually received the result.
#[cfg(all(test, unix))]
mod mitm_e2e_tests {
    use std::net::SocketAddr;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, Instant};

    use futures::{SinkExt, StreamExt};
    use http_body_util::{BodyExt, Full};
    use hyper::body::Bytes;
    use hyper::Uri;
    use rustls::pki_types::ServerName;
    use rustls::RootCertStore;
    use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
    use tokio::net::TcpListener;
    use tokio_rustls::{TlsAcceptor, TlsConnector};
    use tokio_tungstenite::tungstenite::ClientRequestBuilder;
    use tokio_tungstenite::tungstenite::Message as WsMessage;
    use tokio_tungstenite::{accept_async_with_config, client_async_with_config};

    use super::*;
    use crate::capture::{self, AppScope, CaptureConfig};
    use crate::captures::{self, CaptureFilter};
    use crate::limits::CAPTURE_BODY_MAX_BYTES;
    use crate::mitm::{self, CertificateAuthority, UpstreamTlsConfig};
    use crate::TEST_SERIAL as SERIAL;

    static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

    fn current_thread() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("current-thread runtime")
    }

    fn temp_ca(tag: &str) -> Arc<CertificateAuthority> {
        let n = TMP_SEQ.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "gstore-mitm-e2e-{}-{}-{}",
            std::process::id(),
            tag,
            n
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Arc::new(CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate CA"))
    }

    fn roots(ca: &CertificateAuthority) -> RootCertStore {
        let mut store = RootCertStore::empty();
        store.add(ca.der().clone()).expect("trust CA");
        store
    }

    fn client_tls(ca: &CertificateAuthority, alpn: &[u8]) -> Arc<rustls::ClientConfig> {
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let mut config = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("versions")
            .with_root_certificates(roots(ca))
            .with_no_client_auth();
        config.alpn_protocols = vec![alpn.to_vec()];
        Arc::new(config)
    }

    fn tunnel(rules: &[&str]) -> Arc<meow_tunnel::tunnel::TunnelInner> {
        let resolver = Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ));
        let tunnel = meow_tunnel::Tunnel::new(resolver);
        let parsed: Vec<Box<dyn meow_common::Rule>> = rules
            .iter()
            .map(|line| {
                meow_rules::parser::parse_rule(line, &meow_rules::ParserContext::empty())
                    .expect("test rule parses")
            })
            .collect();
        tunnel.update_rules(parsed);
        tunnel.inner().clone()
    }

    fn sniffer(tls_ports: &[u16]) -> Arc<sniff::Sniffer> {
        let mut cfg = meow_common::sniffer::SnifferConfig::default();
        cfg.enable = true;
        cfg.tls_ports = tls_ports.to_vec();
        cfg.http_ports = Vec::new();
        cfg.timeout = Duration::from_millis(300);
        Arc::new(sniff::Sniffer::new(cfg))
    }

    fn capture_config_ex(
        tls_ports: &[u16],
        capture_ws: bool,
        skip_cert_verify: bool,
    ) -> CaptureConfig {
        capture::set_config(CaptureConfig {
            enabled: true,
            tls_ports: tls_ports.to_vec(),
            domain_allowlist: vec!["flow.test".to_string()],
            app_allowlist: Vec::new(),
            app_scope: AppScope::Uid,
            capture_body: true,
            capture_ws,
            capture_h2: true,
            skip_cert_verify,
            max_body_bytes: CAPTURE_BODY_MAX_BYTES,
        });
        capture::config().as_ref().clone()
    }

    fn capture_config(tls_ports: &[u16], capture_ws: bool) -> CaptureConfig {
        capture_config_ex(tls_ports, capture_ws, false)
    }

    async fn start_tls_fixture(ca: Arc<CertificateAuthority>, host: &str, body: Vec<u8>) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let config = ca.server_config(host).unwrap();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let tls = TlsAcceptor::from(config).accept(tcp).await.unwrap();
            let service = hyper::service::service_fn(move |_req| {
                let body = body.clone();
                async move {
                    let mut response = hyper::Response::new(Full::new(Bytes::from(body)));
                    response.headers_mut().insert(
                        hyper::header::CONTENT_TYPE,
                        hyper::header::HeaderValue::from_static("text/plain"),
                    );
                    Ok::<_, std::convert::Infallible>(response)
                }
            });
            let _ = hyper::server::conn::http1::Builder::new()
                .keep_alive(false)
                .serve_connection(hyper_util::rt::TokioIo::new(tls), service)
                .await;
        });
        port
    }

    /// Same as [`start_tls_fixture`] but keeps the HTTP/1.1 connection alive, so
    /// one MITM session can serve several exchanges (and thus several captures).
    async fn start_tls_keepalive_fixture(
        ca: Arc<CertificateAuthority>,
        host: &str,
        body: Vec<u8>,
    ) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let config = ca.server_config(host).unwrap();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let tls = TlsAcceptor::from(config).accept(tcp).await.unwrap();
            let service = hyper::service::service_fn(move |_req| {
                let body = body.clone();
                async move {
                    let mut response = hyper::Response::new(Full::new(Bytes::from(body)));
                    response.headers_mut().insert(
                        hyper::header::CONTENT_TYPE,
                        hyper::header::HeaderValue::from_static("text/plain"),
                    );
                    Ok::<_, std::convert::Infallible>(response)
                }
            });
            let _ = hyper::server::conn::http1::Builder::new()
                .keep_alive(true)
                .serve_connection(hyper_util::rt::TokioIo::new(tls), service)
                .await;
        });
        port
    }

    async fn start_hanging_tls_fixture(ca: Arc<CertificateAuthority>, host: &str) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let config = ca.server_config(host).unwrap();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut tls = TlsAcceptor::from(config).accept(tcp).await.unwrap();
            let mut buf = [0u8; 4096];
            let _ = tls.read(&mut buf).await;
            std::future::pending::<()>().await;
        });
        port
    }

    async fn start_ws_fixture(ca: Arc<CertificateAuthority>, host: &str) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let config = ca.server_config(host).unwrap();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let tls = TlsAcceptor::from(config).accept(tcp).await.unwrap();
            let mut ws = accept_async_with_config(tls, Some(mitm::ws_config()))
                .await
                .expect("ws fixture accept");
            while let Some(Ok(message)) = ws.next().await {
                if message.is_close() {
                    break;
                }
                if ws.send(message).await.is_err() {
                    break;
                }
            }
        });
        port
    }

    async fn run_flow<F, Fut>(
        inner: Arc<meow_tunnel::tunnel::TunnelInner>,
        dst_port: u16,
        sniffer: Arc<sniff::Sniffer>,
        client: F,
    ) where
        F: FnOnce(DuplexStream) -> Fut,
        Fut: std::future::Future<Output = ()>,
    {
        let src: SocketAddr = "10.0.0.2:40000".parse().unwrap();
        let dst: SocketAddr = format!("127.0.0.1:{dst_port}").parse().unwrap();
        let (client_io, server_io) = tokio::io::duplex(1 << 16);
        let flow = tokio::spawn(handle_flow(inner, src, dst, server_io, sniffer));
        client(client_io).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), flow).await;
    }

    async fn client_h1_tls(
        ca: &Arc<CertificateAuthority>,
        host: &str,
        io: DuplexStream,
        path: &str,
    ) -> (u16, Vec<u8>) {
        let tls = TlsConnector::from(client_tls(ca, b"http/1.1"))
            .connect(ServerName::try_from(host.to_string()).unwrap(), io)
            .await
            .expect("client TLS handshake");
        let (mut sender, conn) = hyper::client::conn::http1::handshake::<_, Full<Bytes>>(
            hyper_util::rt::TokioIo::new(tls),
        )
        .await
        .expect("client h1 handshake");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        let request = hyper::Request::builder()
            .method("GET")
            .uri(path)
            .header(hyper::header::HOST, host)
            .body(Full::new(Bytes::new()))
            .unwrap();
        let response = sender.send_request(request).await.expect("send request");
        let status = response.status().as_u16();
        let body = response
            .into_body()
            .collect()
            .await
            .expect("client body")
            .to_bytes()
            .to_vec();
        (status, body)
    }

    async fn wait_for_capture(pred: impl Fn(&[crate::captures::CaptureSummary]) -> bool) -> Vec<crate::captures::CaptureSummary> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let page = captures::snapshot(0, 64, &CaptureFilter::default());
            if pred(&page.records) {
                return page.records;
            }
            assert!(Instant::now() < deadline, "timed out waiting for capture: {:?}", page.records);
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    /// Wait for every MITM session (including detached bridge/WS tasks) to
    /// release its in-flight slot before the test resets global state, so a
    /// lingering `InflightGuard` can never decrement a counter a peer test has
    /// already reset.
    async fn drain_inflight() {
        let deadline = Instant::now() + Duration::from_secs(10);
        while mitm::inflight_count() != 0 && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(
            mitm::inflight_count(),
            0,
            "every MITM session must drain before teardown"
        );
    }

    fn setup(capture_ws: bool, tls_ports: &[u16]) -> (Arc<CertificateAuthority>, Arc<meow_tunnel::tunnel::TunnelInner>) {
        mitm::reset_gate_counters_for_tests();
        mitm::clear_ca();
        mitm::reset_capture_sink();
        mitm::reset_ws_frame_sink();
        captures::reset_for_tests();
        captures::rules_reset_for_tests();
        crate::requests::reset_for_tests();
        let ca = temp_ca("wire");
        mitm::install_ca(Arc::clone(&ca));
        mitm::set_upstream_tls_for_tests(UpstreamTlsConfig::with_roots(roots(&ca)));
        captures::install_store_sinks_for_tests();
        capture_config(tls_ports, capture_ws);
        let inner = tunnel(&["DOMAIN,flow.test,DIRECT", "DOMAIN,blocked.test,DIRECT"]);
        (ca, inner)
    }

    fn teardown() {
        mitm::clear_ca();
        mitm::reset_capture_sink();
        mitm::reset_ws_frame_sink();
        captures::reset_for_tests();
        captures::rules_reset_for_tests();
        capture::reset_for_tests();
        crate::requests::reset_for_tests();
    }

    #[test]
    fn mitm_e2e_allowlisted_is_decrypted_and_captured() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, inner) = setup(true, &[0]);
            let port = start_tls_fixture(
                mitm::ca().unwrap(),
                "flow.test",
                b"upstream".to_vec(),
            )
            .await;
            capture_config(&[port], true);
            let ca = mitm::ca().unwrap();

            run_flow(Arc::clone(&inner), port, sniffer(&[port]), {
                let ca = Arc::clone(&ca);
                move |io| async move {
                    let (status, body) = client_h1_tls(&ca, "flow.test", io, "/hello").await;
                    assert_eq!(status, 200);
                    assert_eq!(body, b"upstream");
                }
            })
            .await;

            let records = wait_for_capture(|rs| {
                rs.iter().any(|r| {
                    r.host == "flow.test" && r.method == "GET" && r.url.ends_with("/hello")
                })
            })
            .await;
            let rec = records
                .iter()
                .find(|r| r.host == "flow.test" && r.url.ends_with("/hello"))
                .expect("captured exchange present");
            assert_eq!(rec.status_code, 200);
            assert_eq!(rec.protocol, "h1");
            assert_eq!(rec.scheme, "https");
            assert_eq!(rec.resp_body_preview, b"upstream");
            drain_inflight().await;
            teardown();
        });
    }

    #[test]
    fn mitm_e2e_capture_links_to_request_skeleton() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, inner) = setup(true, &[0]);
            let port =
                start_tls_fixture(mitm::ca().unwrap(), "flow.test", b"upstream".to_vec()).await;
            capture_config(&[port], true);
            let ca = mitm::ca().unwrap();

            run_flow(Arc::clone(&inner), port, sniffer(&[port]), {
                let ca = Arc::clone(&ca);
                move |io| async move {
                    let (status, body) = client_h1_tls(&ca, "flow.test", io, "/linked").await;
                    assert_eq!(status, 200);
                    assert_eq!(body, b"upstream");
                }
            })
            .await;

            let records = wait_for_capture(|rs| rs.len() == 1).await;
            let capture = records.first().expect("exactly one capture record");
            let rid = capture.request_record_id;
            assert_ne!(
                rid, 0,
                "a MITM capture must carry the non-zero requestRecordId of its skeleton"
            );
            let page =
                crate::requests::snapshot(0, 64, &crate::requests::RequestFilter::default());
            assert!(
                page.records.iter().any(|x| x.record_id == rid),
                "the requests skeleton {rid} must exist at session start"
            );

            drain_inflight().await;
            let page =
                crate::requests::snapshot(0, 64, &crate::requests::RequestFilter::default());
            let skeleton = page
                .records
                .iter()
                .find(|x| x.record_id == rid)
                .expect("skeleton retained after the session ends");
            assert!(
                skeleton.duration_ms.is_some(),
                "session end must finalize the skeleton with a duration"
            );
            teardown();
        });
    }

    /// One TLS/HTTP1.1 keep-alive session carries several exchanges; every
    /// resulting capture must point at the SAME single non-zero skeleton id.
    /// This is a Rust-observable linkage fact only — the Dart row folding is
    /// covered separately.
    #[test]
    fn mitm_e2e_multi_capture_session_shares_one_skeleton_id() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, inner) = setup(true, &[0]);
            let port = start_tls_keepalive_fixture(
                mitm::ca().unwrap(),
                "flow.test",
                b"upstream".to_vec(),
            )
            .await;
            capture_config(&[port], true);
            let ca = mitm::ca().unwrap();

            run_flow(Arc::clone(&inner), port, sniffer(&[port]), {
                let ca = Arc::clone(&ca);
                move |io| async move {
                    let tls = TlsConnector::from(client_tls(&ca, b"http/1.1"))
                        .connect(ServerName::try_from("flow.test").unwrap(), io)
                        .await
                        .expect("client TLS handshake");
                    let (mut sender, conn) =
                        hyper::client::conn::http1::handshake::<_, Full<Bytes>>(
                            hyper_util::rt::TokioIo::new(tls),
                        )
                        .await
                        .expect("client h1 handshake");
                    tokio::spawn(async move {
                        let _ = conn.await;
                    });
                    for path in ["/keep-alive-one", "/keep-alive-two"] {
                        let request = hyper::Request::builder()
                            .method("GET")
                            .uri(path)
                            .header(hyper::header::HOST, "flow.test")
                            .body(Full::new(Bytes::new()))
                            .unwrap();
                        let response = sender
                            .send_request(request)
                            .await
                            .expect("keep-alive response");
                        assert_eq!(response.status().as_u16(), 200);
                        let _ = response.into_body().collect().await;
                    }
                }
            })
            .await;

            let records = wait_for_capture(|rs| {
                rs.iter().filter(|r| r.host == "flow.test").count() >= 2
            })
            .await;
            let linked: Vec<crate::captures::CaptureSummary> = records
                .into_iter()
                .filter(|r| r.host == "flow.test")
                .collect();
            assert!(
                linked.len() >= 2,
                "one keep-alive session must yield two or more captures, got {}",
                linked.len()
            );
            let rid = linked[0].request_record_id;
            assert_ne!(
                rid, 0,
                "a MITM capture must carry the non-zero requestRecordId of its skeleton"
            );
            assert!(
                linked.iter().all(|r| r.request_record_id == rid),
                "all captures of one session must share the skeleton id: {:?}",
                linked.iter().map(|r| r.request_record_id).collect::<Vec<_>>()
            );

            let page =
                crate::requests::snapshot(0, 64, &crate::requests::RequestFilter::default());
            assert_eq!(
                page.records.iter().filter(|r| r.record_id == rid).count(),
                1,
                "exactly one request skeleton must back the whole session"
            );

            drain_inflight().await;
            teardown();
        });
    }

    #[test]
    fn mitm_e2e_noca_starts_no_session_and_records_nothing() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, inner) = setup(false, &[0]);
            mitm::clear_ca();

            let src: SocketAddr = "10.0.0.2:40000".parse().unwrap();
            let dst: SocketAddr = "127.0.0.1:443".parse().unwrap();
            let (mut client, server) = tokio::io::duplex(64);
            client.write_all(b"hello").await.expect("pre-write");
            client.flush().await.expect("flush");

            let before = crate::requests::next_record_id_for_tests();
            let ctx =
                BridgeContext::new("flow.test", "tun-flow", 0).with_endpoints(src, dst);
            let dialer = production_dialer(&inner, "flow.test", src, dst, false);
            let result = begin_mitm(server, Some("flow.test"), dialer, ctx);
            let Err((mut stream, err)) = result else {
                panic!("MITM init without a CA must fail");
            };
            assert!(matches!(err, MitmInitError::NoCa), "got {err}");
            let mut got = [0u8; 5];
            stream.read_exact(&mut got).await.expect("read passthrough");
            assert_eq!(&got, b"hello", "init failure must pass bytes through unchanged");
            assert_eq!(
                crate::requests::next_record_id_for_tests(),
                before,
                "a session that never started must register zero request records"
            );
            teardown();
        });
    }

    #[test]
    fn mitm_e2e_inflight_cap_starts_no_session_and_records_nothing() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, inner) = setup(false, &[0]);

            let mut held = Vec::new();
            while let Some(slot) = mitm::InflightGuard::try_acquire() {
                held.push(slot);
            }
            assert_eq!(
                held.len(),
                crate::limits::MITM_MAX_INFLIGHT,
                "must reach the in-flight cap"
            );

            let src: SocketAddr = "10.0.0.2:40000".parse().unwrap();
            let dst: SocketAddr = "127.0.0.1:443".parse().unwrap();
            let (mut client, server) = tokio::io::duplex(64);
            client.write_all(b"hello").await.expect("pre-write");
            client.flush().await.expect("flush");

            let before = crate::requests::next_record_id_for_tests();
            let ctx =
                BridgeContext::new("flow.test", "tun-flow", 0).with_endpoints(src, dst);
            let dialer = production_dialer(&inner, "flow.test", src, dst, false);
            let result = begin_mitm(server, Some("flow.test"), dialer, ctx);
            let Err((mut stream, err)) = result else {
                panic!("MITM init at the in-flight cap must fail");
            };
            assert!(matches!(err, MitmInitError::InflightCap), "got {err}");
            let mut got = [0u8; 5];
            stream.read_exact(&mut got).await.expect("read passthrough");
            assert_eq!(&got, b"hello", "overflow must pass bytes through unchanged");
            assert_eq!(
                crate::requests::next_record_id_for_tests(),
                before,
                "an overflowed session must register zero request records"
            );

            drop(held);
            mitm::clear_ca();
            teardown();
        });
    }

    #[test]
    fn mitm_e2e_skip_cert_verify_accepts_untrusted_upstream() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_mitm_ca, inner) = setup(true, &[0]);
            let upstream_ca = temp_ca("untrusted-upstream");
            let port = start_tls_fixture(
                Arc::clone(&upstream_ca),
                "flow.test",
                b"UNTRUSTED-OK".to_vec(),
            )
            .await;
            capture_config_ex(&[port], true, true);
            let ca = mitm::ca().unwrap();
            crate::logging::reset_for_tests();

            run_flow(Arc::clone(&inner), port, sniffer(&[port]), {
                let ca = Arc::clone(&ca);
                move |io| async move {
                    let (status, body) = client_h1_tls(&ca, "flow.test", io, "/skip").await;
                    assert_eq!(
                        status, 200,
                        "skipCertVerify=true must accept the untrusted upstream"
                    );
                    assert_eq!(body, b"UNTRUSTED-OK");
                }
            })
            .await;

            let messages: Vec<String> = crate::logging::snapshot(0, 200, None)
                .records
                .into_iter()
                .map(|r| r.message)
                .collect();
            assert_eq!(
                messages
                    .iter()
                    .filter(|m| m.contains("upstream cert verification DISABLED"))
                    .count(),
                1,
                "exactly one skipCertVerify security event per session: {messages:?}"
            );
            drain_inflight().await;
            teardown();
        });
    }

    /// D6b contrast: with the flag off (the default), the SAME untrusted
    /// fixture is rejected by strict upstream TLS — proving the opt-in actually
    /// changes behavior and the default is unchanged.
    #[test]
    fn mitm_e2e_strict_upstream_rejects_untrusted_fixture() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_mitm_ca, inner) = setup(true, &[0]);
            let upstream_ca = temp_ca("untrusted-upstream-strict");
            let port = start_tls_fixture(
                Arc::clone(&upstream_ca),
                "flow.test",
                b"UNTRUSTED-NOPE".to_vec(),
            )
            .await;
            capture_config_ex(&[port], true, false);
            let ca = mitm::ca().unwrap();
            crate::logging::reset_for_tests();

            run_flow(Arc::clone(&inner), port, sniffer(&[port]), {
                let ca = Arc::clone(&ca);
                move |io| async move {
                    let (status, _body) = client_h1_tls(&ca, "flow.test", io, "/strict").await;
                    assert_eq!(
                        status, 502,
                        "the default strict upstream TLS must reject an untrusted leaf"
                    );
                }
            })
            .await;

            let messages: Vec<String> = crate::logging::snapshot(0, 200, None)
                .records
                .into_iter()
                .map(|r| r.message)
                .collect();
            assert_eq!(
                messages
                    .iter()
                    .filter(|m| m.contains("upstream cert verification DISABLED"))
                    .count(),
                0,
                "no security event when the flag is off: {messages:?}"
            );
            drain_inflight().await;
            teardown();
        });
    }

    /// D6b: the dialer TLS selection honors the snapshot flag exactly — strict
    /// by default, `SkipServerVerify` only when explicitly enabled.
    #[test]
    fn upstream_tls_config_for_honors_skip_flag() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        assert!(
            !mitm::upstream_tls_config_for(false).skip_cert_verify(),
            "false must stay strict"
        );
        assert!(
            mitm::upstream_tls_config_for(true).skip_cert_verify(),
            "true must opt into skip verification"
        );
    }

    #[test]
    fn mitm_e2e_unmatched_passes_through_unchanged() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, inner) = setup(true, &[0]);
            let port = start_tls_fixture(
                mitm::ca().unwrap(),
                "blocked.test",
                b"PASS".to_vec(),
            )
            .await;
            capture_config(&[port], true);
            let ca = mitm::ca().unwrap();

            run_flow(Arc::clone(&inner), port, sniffer(&[port]), {
                let ca = Arc::clone(&ca);
                move |io| async move {
                    let (status, body) = client_h1_tls(&ca, "blocked.test", io, "/x").await;
                    assert_eq!(status, 200, "unmatched flow is forwarded, not decrypted");
                    assert_eq!(body, b"PASS", "unmatched bytes are unchanged end to end");
                }
            })
            .await;

            tokio::time::sleep(Duration::from_millis(100)).await;
            let page = captures::snapshot(0, 64, &CaptureFilter::default());
            assert!(
                page.records.iter().all(|r| r.host != "blocked.test"),
                "an unmatched (non-allowlisted) flow must never be captured"
            );
            drain_inflight().await;
            teardown();
        });
    }

    #[test]
    fn mitm_e2e_replace_and_local_rules_apply_live() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let _rg = captures::rules_test_guard();
            let (_ca, inner) = setup(true, &[0]);
            let port = start_tls_fixture(
                mitm::ca().unwrap(),
                "flow.test",
                b"upstream".to_vec(),
            )
            .await;
            capture_config(&[port], true);
            let ca = mitm::ca().unwrap();
            captures::rules_set(
                br#"{"enabled":true,"url":"https://flow.test/replace","kind":"replace","statusCode":201,"headers":"content-type: text/plain","body":"replaced-live"}"#,
            )
            .expect("replace rule");
            captures::rules_set(
                br#"{"enabled":true,"url":"https://flow.test/local","kind":"local","statusCode":418,"headers":"content-type: text/plain","body":"local-live"}"#,
            )
            .expect("local rule");

            run_flow(Arc::clone(&inner), port, sniffer(&[port]), {
                let ca = Arc::clone(&ca);
                move |io| async move {
                    let (status, body) = client_h1_tls(&ca, "flow.test", io, "/replace").await;
                    assert_eq!(status, 201, "replace rule status applies live");
                    assert_eq!(body, b"replaced-live", "replace rule body applies live");
                }
            })
            .await;

            run_flow(Arc::clone(&inner), port, sniffer(&[port]), {
                let ca = Arc::clone(&ca);
                move |io| async move {
                    let (status, body) = client_h1_tls(&ca, "flow.test", io, "/local").await;
                    assert_eq!(status, 418, "local rule status applies live");
                    assert_eq!(body, b"local-live", "local rule body applies live");
                }
            })
            .await;

            let records = wait_for_capture(|rs| {
                rs.iter().any(|r| r.url.ends_with("/replace") && r.status_code == 201)
                    && rs.iter().any(|r| r.url.ends_with("/local") && r.status_code == 418)
            })
            .await;
            assert!(records.iter().any(|r| r.url.ends_with("/replace")));
            assert!(records.iter().any(|r| r.url.ends_with("/local")));
            drain_inflight().await;
            teardown();
        });
    }

    #[test]
    fn mitm_e2e_ws_frames_persisted_and_capture_ws_toggle() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, inner) = setup(true, &[0]);
            let port = start_ws_fixture(mitm::ca().unwrap(), "flow.test").await;
            capture_config(&[port], true);

            run_flow(Arc::clone(&inner), port, sniffer(&[port]), move |io| async move {
                let ca = mitm::ca().unwrap();
                let tls = TlsConnector::from(client_tls(&ca, b"http/1.1"))
                    .connect(ServerName::try_from("flow.test").unwrap(), io)
                    .await
                    .expect("ws client TLS");
                let uri: Uri = "ws://flow.test/socket".parse().unwrap();
                let (mut ws, response) =
                    client_async_with_config(ClientRequestBuilder::new(uri), tls, Some(mitm::ws_config()))
                        .await
                        .expect("ws upgrade");
                assert_eq!(response.status(), 101);
                ws.send(WsMessage::text("hello-ws")).await.unwrap();
                let mut echoed = false;
                for _ in 0..5 {
                    match tokio::time::timeout(Duration::from_secs(5), ws.next()).await {
                        Ok(Some(Ok(m))) if m == WsMessage::text("hello-ws") => {
                            echoed = true;
                            break;
                        }
                        Ok(Some(Ok(_))) => continue,
                        _ => break,
                    }
                }
                assert!(echoed, "ws echo round-trips through the MITM");
                let _ = ws.close(None).await;
            })
            .await;

            let records = wait_for_capture(|rs| {
                rs.iter().any(|r| r.protocol == "ws" && !r.ws_frames.is_empty())
            })
            .await;
            let ws_rec = records
                .iter()
                .find(|r| r.protocol == "ws" && !r.ws_frames.is_empty())
                .expect("ws capture record with frames");
            let detail = captures::detail(ws_rec.record_id).unwrap().unwrap();
            assert!(
                detail.ws_frames.iter().any(|f| f.preview == b"hello-ws"),
                "the persisted WS frame preview must round-trip: {:?}",
                detail.ws_frames
            );

            let before = captures::snapshot(0, 64, &CaptureFilter::default())
                .records
                .iter()
                .filter(|r| r.protocol == "ws")
                .count();
            capture_config(&[port], false);
            let port2 = start_ws_fixture(mitm::ca().unwrap(), "flow.test").await;
            capture_config(&[port2], false);
            run_flow(Arc::clone(&inner), port2, sniffer(&[port2]), move |io| async move {
                let ca = mitm::ca().unwrap();
                let tls = TlsConnector::from(client_tls(&ca, b"http/1.1"))
                    .connect(ServerName::try_from("flow.test").unwrap(), io)
                    .await
                    .expect("ws client TLS");
                let uri: Uri = "ws://flow.test/socket2".parse().unwrap();
                let (mut ws, _) =
                    client_async_with_config(ClientRequestBuilder::new(uri), tls, Some(mitm::ws_config()))
                        .await
                        .expect("ws upgrade");
                ws.send(WsMessage::text("not-recorded")).await.unwrap();
                let _ = tokio::time::timeout(Duration::from_secs(5), ws.next()).await;
                let _ = ws.close(None).await;
            })
            .await;
            tokio::time::sleep(Duration::from_millis(150)).await;
            let after = captures::snapshot(0, 64, &CaptureFilter::default())
                .records
                .iter()
                .filter(|r| r.protocol == "ws")
                .count();
            assert_eq!(
                after, before,
                "captureWs=false must persist no WS frames/records"
            );
            drain_inflight().await;
            teardown();
        });
    }

    #[test]
    fn mitm_e2e_upstream_failure_is_failsafe_no_panic() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, inner) = setup(true, &[0]);
            let fail_port = {
                let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
                listener.local_addr().unwrap().port()
            };
            capture_config(&[fail_port], true);
            let before = mitm::mitm_failed_count();

            run_flow(Arc::clone(&inner), fail_port, sniffer(&[fail_port]), move |io| async move {
                let ca = mitm::ca().unwrap();
                let tls = tokio::time::timeout(
                    Duration::from_secs(5),
                    TlsConnector::from(client_tls(&ca, b"http/1.1"))
                        .connect(ServerName::try_from("flow.test").unwrap(), io),
                )
                .await
                .expect("handshake must not hang")
                .expect("MITM terminates the client");
                let (mut sender, conn) = hyper::client::conn::http1::handshake::<_, Full<Bytes>>(
                    hyper_util::rt::TokioIo::new(tls),
                )
                .await
                .expect("client h1 handshake");
                tokio::spawn(async move {
                    let _ = conn.await;
                });
                let request = hyper::Request::builder()
                    .method("GET")
                    .uri("/dead")
                    .header(hyper::header::HOST, "flow.test")
                    .body(Full::new(Bytes::new()))
                    .unwrap();
                let response = sender
                    .send_request(request)
                    .await
                    .expect("an unreachable upstream must still yield a fail-safe response");
                assert_eq!(
                    response.status().as_u16(),
                    502,
                    "an unreachable upstream degrades to a structured 502, not a dropped connection"
                );
            })
            .await;

            assert!(
                mitm::mitm_failed_count() > before,
                "the upstream failure must be recorded as mitmFailed"
            );
            let records = wait_for_capture(|rs| rs.iter().any(|r| r.mitm_failed)).await;
            assert!(
                records.iter().any(|r| r.mitm_failed),
                "a failed exchange must still be recorded, not silently dropped"
            );
            let sibling = tokio::spawn(async { 7u32 });
            assert_eq!(sibling.await.unwrap(), 7, "dataplane runtime survives the failure");
            drain_inflight().await;
            teardown();
        });
    }

    #[test]
    fn mitm_e2e_upstream_response_timeout_is_failsafe_and_releases_slot() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, inner) = setup(true, &[0]);
            let port = start_hanging_tls_fixture(mitm::ca().unwrap(), "flow.test").await;
            capture_config(&[port], true);
            mitm::set_upstream_response_timeout_for_tests(200);
            let _reset = UpstreamTimeoutReset;
            let ca = mitm::ca().unwrap();
            let before = mitm::mitm_failed_count();

            run_flow(Arc::clone(&inner), port, sniffer(&[port]), move |io| async move {
                let outcome = tokio::time::timeout(Duration::from_secs(2), async {
                    let tls = TlsConnector::from(client_tls(&ca, b"http/1.1"))
                        .connect(ServerName::try_from("flow.test").unwrap(), io)
                        .await
                        .expect("client TLS");
                    let (mut sender, conn) =
                        hyper::client::conn::http1::handshake::<_, Full<Bytes>>(
                            hyper_util::rt::TokioIo::new(tls),
                        )
                        .await
                        .expect("client h1 handshake");
                    tokio::spawn(async move {
                        let _ = conn.await;
                    });
                    let request = hyper::Request::builder()
                        .method("GET")
                        .uri("/hang")
                        .header(hyper::header::HOST, "flow.test")
                        .body(Full::new(Bytes::new()))
                        .unwrap();
                    let response = sender.send_request(request).await.expect("fail-safe response");
                    response.status().as_u16()
                })
                .await;
                assert_eq!(
                    outcome.expect(
                        "a hung origin must not stall the client past the upstream response timeout"
                    ),
                    mitm::UPSTREAM_FAILURE_STATUS,
                    "a hung origin must degrade to the structured upstream-failure status"
                );
            })
            .await;

            assert!(
                mitm::mitm_failed_count() > before,
                "an upstream response timeout must be recorded as mitmFailed"
            );
            drain_inflight().await;
            teardown();
        });
    }

    struct UpstreamTimeoutReset;

    impl Drop for UpstreamTimeoutReset {
        fn drop(&mut self) {
            mitm::reset_upstream_response_timeout_for_tests();
        }
    }

    #[derive(Debug)]
    struct ShutdownFailingIo<S>(S);

    impl<S: AsyncRead + Unpin> AsyncRead for ShutdownFailingIo<S> {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            Pin::new(&mut self.0).poll_read(cx, buf)
        }
    }

    impl<S: AsyncWrite + Unpin> AsyncWrite for ShutdownFailingIo<S> {
        fn poll_write(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            Pin::new(&mut self.0).poll_write(cx, buf)
        }

        fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.0).poll_flush(cx)
        }

        fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "forced shutdown failure",
            )))
        }
    }

    async fn client_h1_close(
        ca: &CertificateAuthority,
        io: DuplexStream,
        host: &str,
        path: &str,
    ) -> u16 {
        let tls = TlsConnector::from(client_tls(ca, b"http/1.1"))
            .connect(ServerName::try_from(host.to_string()).unwrap(), io)
            .await
            .expect("client TLS handshake");
        let (mut sender, conn) = hyper::client::conn::http1::handshake::<_, Full<Bytes>>(
            hyper_util::rt::TokioIo::new(tls),
        )
        .await
        .expect("client h1 handshake");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        let request = hyper::Request::builder()
            .method("GET")
            .uri(path)
            .header(hyper::header::HOST, host)
            .header(hyper::header::CONNECTION, "close")
            .body(Full::new(Bytes::new()))
            .unwrap();
        let response = sender.send_request(request).await.expect("response");
        let status = response.status().as_u16();
        let _ = response.into_body().collect().await;
        status
    }

    #[test]
    fn mitm_client_abort_is_not_counted_as_a_failure() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let _rg = captures::rules_test_guard();
            let (ca, _inner) = setup(true, &[0]);
            captures::rules_set(
                br#"{"enabled":true,"url":"https://flow.test/abort","kind":"local","statusCode":200,"headers":"content-type: text/plain","body":"bye"}"#,
            )
            .expect("local rule");

            let before = mitm::mitm_failed_count();
            let (client, server) = tokio::io::duplex(1 << 16);
            let ctx = BridgeContext::new("flow.test", "conn-abort", 0);
            begin_mitm(
                ShutdownFailingIo(server),
                Some("flow.test"),
                Arc::new(NeverDialer),
                ctx,
            )
            .expect("session must start");
            assert_eq!(
                client_h1_close(&ca, client, "flow.test", "/abort").await,
                200,
                "the local rule response must reach the client"
            );
            drain_inflight().await;
            assert_eq!(
                mitm::mitm_failed_count(),
                before,
                "a client abort (hyper Kind::Shutdown) must NOT increment mitmFailed"
            );

            let before_real = mitm::mitm_failed_count();
            let (client, server) = tokio::io::duplex(1 << 16);
            let ctx = BridgeContext::new("flow.test", "conn-real", 0);
            begin_mitm(
                ShutdownFailingIo(server),
                Some("flow.test"),
                Arc::new(NeverDialer),
                ctx,
            )
            .expect("session must start");
            assert_eq!(
                client_h1_close(&ca, client, "flow.test", "/real").await,
                mitm::UPSTREAM_FAILURE_STATUS,
                "an unreachable upstream must still surface the failure status"
            );
            drain_inflight().await;
            assert_eq!(
                mitm::mitm_failed_count(),
                before_real + 1,
                "a genuine upstream failure must still be counted exactly once"
            );

            teardown();
        });
    }

    struct NeverDialer;

    impl UpstreamDialer for NeverDialer {
        fn dial(
            &self,
        ) -> Pin<Box<dyn Future<Output = Result<mitm::EstablishedUpstream, MitmFailure>> + Send>>
        {
            Box::pin(async {
                Err(MitmFailure::new(
                    MitmStage::UpstreamDial,
                    "test: never dials",
                ))
            })
        }
    }

    /// A forced client TLS failure must appear in the session log with its
    /// stage label, so a device log attributes the failure instead of showing a
    /// bare hyper string.
    #[test]
    fn mitm_session_failure_log_is_stage_tagged() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, _inner) = setup(true, &[0]);
            crate::logging::reset_for_tests();

            let (mut client, server) = tokio::io::duplex(4096);
            let ctx = BridgeContext::new("flow.test", "conn-stage", 0);
            begin_mitm(server, Some("flow.test"), Arc::new(NeverDialer), ctx)
                .expect("gate must start the session");
            client.write_all(&[0xffu8; 32]).await.unwrap();
            client.flush().await.unwrap();

            drain_inflight().await;
            let messages: Vec<String> = crate::logging::snapshot(0, 200, None)
                .records
                .into_iter()
                .map(|r| r.message)
                .collect();
            assert!(
                messages.iter().any(|m| {
                    m.contains("session failed stage=client_tls") && m.contains("host=flow.test")
                }),
                "a client TLS failure must be stage-tagged: {messages:?}"
            );
            teardown();
        });
    }

    /// Latency upper bound: a silent client must return within `timeout + slack`
    /// and never panic. Deliberately uses the 100 ms baseline window (not the
    /// 400 ms capture window) so the bound stays tight.
    #[test]
    fn sniff_prefix_silent_client_returns_within_latency_bound() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let timeout = Duration::from_millis(100);
            let sniffer = sniff::Sniffer::default_enabled();
            // Connected but never sends: the read stays pending until the deadline.
            let (_client, mut server) = tokio::io::duplex(64);

            let start = Instant::now();
            let plan = sniff::SniffPlan {
                proto: sniff::SniffProto::Tls,
                timeout,
            };
            let (prefix, host) = sniffer.sniff_prefix(&mut server, Some(plan)).await;
            let elapsed = start.elapsed();

            assert!(prefix.is_empty());
            assert!(host.is_none());
            assert!(
                elapsed <= Duration::from_millis(200),
                "silent client took {elapsed:?}, expected <= 200ms"
            );
        });
    }

    /// Todo 10: the capture config — not the sniffer's own port table — is the
    /// source of truth for which ports get sniffed. The sniffer is built with
    /// [`sniff::Sniffer::default_enabled`] (no port arguments at all), so the
    /// only way an ephemeral fixture port can yield a host is
    /// [`sniff_plan`] reading it back out of `capture.tlsPorts`.
    ///
    /// Positive: a `tlsPorts` entry is sniffed, gated, MITM-decrypted and
    /// captured. Negative: a second fixture port **not** in `tlsPorts`, with
    /// capture still enabled, is relayed untouched and produces neither a
    /// capture nor a request skeleton.
    #[test]
    fn mitm_e2e_custom_tls_port_sniffs_decrypts_and_spares_others() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, _default_inner) = setup(true, &[0]);
            // `MATCH,DIRECT` lets the relay reach the negative fixture even
            // though no host is sniffed for it (no host => no DOMAIN match).
            let inner = tunnel(&[
                "DOMAIN,flow.test,DIRECT",
                "DOMAIN,blocked.test,DIRECT",
                "MATCH,DIRECT",
            ]);

            let positive_port =
                start_tls_fixture(mitm::ca().unwrap(), "flow.test", b"upstream".to_vec()).await;
            let negative_port =
                start_tls_fixture(mitm::ca().unwrap(), "flow.test", b"PASS".to_vec()).await;

            assert!(
                !BASELINE_TLS_SNIFF_PORTS.contains(&positive_port)
                    && !capture::HTTP_CAPTURE_PORTS.contains(&positive_port)
                    && !BASELINE_TLS_SNIFF_PORTS.contains(&negative_port)
                    && !capture::HTTP_CAPTURE_PORTS.contains(&negative_port),
                "fixture ports must stay outside every hard-coded sniff set"
            );

            capture_config(&[positive_port], true);
            let sniffer = Arc::new(sniff::Sniffer::default_enabled());
            let ca = mitm::ca().unwrap();

            run_flow(Arc::clone(&inner), positive_port, Arc::clone(&sniffer), {
                let ca = Arc::clone(&ca);
                move |io| async move {
                    let (status, body) = client_h1_tls(&ca, "flow.test", io, "/custom-port").await;
                    assert_eq!(status, 200);
                    assert_eq!(body, b"upstream");
                }
            })
            .await;

            let records =
                wait_for_capture(|rs| rs.iter().any(|r| r.url.ends_with("/custom-port"))).await;
            let rec = records
                .iter()
                .find(|r| r.url.ends_with("/custom-port"))
                .expect("the custom tlsPorts flow must be captured");
            assert_eq!(
                rec.host, "flow.test",
                "the capture host proves the flow was sniffed via sniff_plan(config, port)"
            );
            assert_ne!(
                rec.request_record_id, 0,
                "a MITM capture must carry the non-zero requestRecordId of its skeleton"
            );
            assert_eq!(rec.status_code, 200, "the gate decrypted the custom port");
            assert_eq!(rec.scheme, "https");

            let before_negative = crate::requests::next_record_id_for_tests();

            run_flow(Arc::clone(&inner), negative_port, Arc::clone(&sniffer), {
                let ca = Arc::clone(&ca);
                move |io| async move {
                    let (status, body) =
                        client_h1_tls(&ca, "flow.test", io, "/passthrough").await;
                    assert_eq!(
                        status, 200,
                        "an unlisted port must still relay the upstream response"
                    );
                    assert_eq!(
                        body, b"PASS",
                        "bytes on an unlisted port pass through unchanged (no MITM)"
                    );
                }
            })
            .await;

            assert_eq!(
                crate::requests::next_record_id_for_tests(),
                before_negative,
                "an unlisted port must never open a MITM request skeleton"
            );
            drain_inflight().await;
            tokio::time::sleep(Duration::from_millis(100)).await;
            assert!(
                captures::snapshot(0, 64, &CaptureFilter::default())
                    .records
                    .iter()
                    .all(|r| !r.url.ends_with("/passthrough")),
                "an unlisted port must produce no capture"
            );

            teardown();
        });
    }

    /// (d) A panic inside an isolated MITM task must still run the RAII
    /// `MitmFlowClose`, finalizing the skeleton, and must not escape to the
    /// dataplane runtime.
    #[test]
    fn mitm_flow_guard_finalizes_skeleton_on_task_panic() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, _inner) = setup(true, &[0]);

            let src: SocketAddr = "10.0.0.2:41000".parse().unwrap();
            let dst: SocketAddr = "203.0.113.9:443".parse().unwrap();
            let conn_id = format!("tun-{src}->{dst}");
            let rid =
                crate::requests::open_mitm_flow(&conn_id, "flow.test", src, dst, crate::now_ms());

            let handle = spawn_isolated(async move {
                // Mirrors `begin_mitm`: the flow guard is held for the session
                // body, so a panic must still finalize on unwind.
                let _flow_guard = MitmFlowClose(conn_id);
                panic!("forced MITM task panic after the skeleton was registered");
            });
            assert!(
                handle.await.is_ok(),
                "spawn_isolated must catch the panic (no JoinError)"
            );

            let page =
                crate::requests::snapshot(0, 64, &crate::requests::RequestFilter::default());
            let skeleton = page
                .records
                .iter()
                .find(|r| r.record_id == rid)
                .expect("the skeleton must survive the panic");
            assert_eq!(
                skeleton.close_reason, "closed",
                "the RAII guard must finalize the skeleton during panic unwind"
            );
            assert!(
                skeleton.close_ts_ms.is_some() && skeleton.duration_ms.is_some(),
                "panic unwind must stamp closeTsMs/durationMs"
            );

            let sibling = tokio::spawn(async { 7u32 });
            assert_eq!(sibling.await.unwrap(), 7, "the dataplane runtime survives the panic");
            teardown();
        });
    }

    /// (f) `dial_upstream` re-originates through `adapter.dial_tcp` only — it
    /// must NOT `track_connection`, so an upstream re-dial never adds a second
    /// `requests` skeleton (even after a meow projection pass).
    #[test]
    fn mitm_upstream_redial_adds_no_request_skeleton() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let (_ca, inner) = setup(true, &[0]);
            crate::conn::reset_for_tests();

            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let accept = tokio::spawn(async move {
                if let Ok((_tcp, _)) = listener.accept().await {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            });

            let target = UpstreamTarget::new("flow.test", port)
                .with_dst_ip(std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST))
                .with_source("10.0.0.2".parse().unwrap(), 40000);
            let before_conns = inner.stats.active_connection_count();
            let before_records = crate::requests::next_record_id_for_tests();

            let upstream = crate::mitm::dial_upstream(&inner, &target)
                .await
                .expect("the re-dial must reach the DIRECT fixture");
            drop(upstream);

            assert_eq!(
                inner.stats.active_connection_count(),
                before_conns,
                "dial_upstream must not track_connection"
            );
            let _ = crate::conn::sync_full(&inner.stats);
            assert_eq!(
                crate::requests::next_record_id_for_tests(),
                before_records,
                "an upstream re-dial must never add a requests skeleton"
            );

            let _ = accept.await;
            teardown();
        });
    }
}
