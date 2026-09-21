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
//! Todos 8/9; until then the tunnel runs with an empty route table, which meow
//! resolves to its built-in DIRECT adapter.

use std::io;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use futures::StreamExt;
use meow_common::{ConnType, Metadata, Network, ProxyConn};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use crate::dns::DnsEngine;

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
    let tcp = tokio::spawn(async move {
        let mut listener = tcp_listener;
        while let Some((stream, src, dst)) = listener.next().await {
            let inner = Arc::clone(&tcp_inner);
            tokio::spawn(async move {
                let metadata = tcp_metadata(src, dst);
                meow_tunnel::tcp::handle_tcp(&inner, Box::new(LwipProxyConn::new(stream)), metadata)
                    .await;
            });
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
        let _g = SERIAL.lock().unwrap();
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
