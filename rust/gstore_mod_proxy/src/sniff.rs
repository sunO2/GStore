//! TCP SNI / HTTP Host sniffing for TUN flows — best-effort domain attribution.
//!
//! The only other domain source is the UDP:53 fake-IP hijack in [`crate::dns`].
//! A flow whose DNS was *not* hijacked (DoH, Android Private DNS/DoT, a cached
//! answer, or a plain-IP dial) enters the TUN with no domain and would be
//! recorded under its destination IP with `domainKnown:false` (§9.5). This
//! module recovers the domain from the client's first bytes instead.
//!
//! meow ships the parsers ([`meow_common::sniffer`]) but its own
//! `SnifferRuntime` peeks a `tokio::net::TcpStream`. Our stream is
//! [`meow_lwip::TcpStream`] — a channel-based `AsyncRead`/`AsyncWrite` with an
//! internal `leftover` buffer and **no `peek`** — so this module implements a
//! **prefetch-and-replay** wrapper: [`Sniffer::sniff_prefix`] reads the first
//! flight (bounded), and [`PrefixedStream`] replays those bytes ahead of the
//! live stream so the tunnel sees an unmodified byte sequence.
//!
//! Sniffing is **best-effort** and strictly additive: it only populates
//! `metadata.sniff_host` (which [`meow_common::Metadata::rule_host`] prefers
//! over `host`, and which `conn.rs` writes into the connection record). It must
//! **never** rewrite the routing destination — `override_destination` stays
//! `false`. ECH/ESNI, QUIC/HTTP3 (UDP, deliberately out of scope) and ports not
//! in the configured lists still fall back to the IP.

use std::collections::HashMap;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Instant;

use meow_common::sniffer::{sniff_http, sniff_tls, SnifferConfig};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, ReadBuf};

/// Largest prefix buffered and replayed. No byte of the client's first flight
/// is ever dropped: each read is sized to the remaining room, so the buffer can
/// never exceed this cap.
const MAX_PREFIX: usize = 8192;
/// Per-read chunk when draining the first flight.
const CHUNK: usize = 2048;

/// Which parser to run for a destination port.
#[derive(Clone, Copy)]
enum Proto {
    Tls,
    Http,
}

/// Prefetch-and-replay sniffer. Built once and shared (`Arc`) by every accepted
/// TCP flow ([`crate::dispatch`]).
pub(crate) struct Sniffer {
    cfg: SnifferConfig,
    port_map: HashMap<u16, Proto>,
}

impl Sniffer {
    /// Build from a [`SnifferConfig`]; `port_map` maps each `tls_ports` entry
    /// to [`Proto::Tls`] and each `http_ports` entry to [`Proto::Http`].
    pub(crate) fn new(cfg: SnifferConfig) -> Self {
        let mut port_map = HashMap::new();
        for &p in &cfg.tls_ports {
            port_map.insert(p, Proto::Tls);
        }
        for &p in &cfg.http_ports {
            port_map.insert(p, Proto::Http);
        }
        Self { cfg, port_map }
    }

    /// Shipping configuration: enabled with [`SnifferConfig::default`]'s
    /// 100 ms timeout and `443/8443` (TLS) + `80/8080/8880` (HTTP) port lists.
    pub(crate) fn default_enabled() -> Self {
        Self::new(SnifferConfig {
            enable: true,
            ..Default::default()
        })
    }

    /// Read the client's first flight and try to extract a hostname.
    ///
    /// Reads are bounded by a **single overall deadline**
    /// (`Instant::now() + cfg.timeout`) and by [`MAX_PREFIX`] bytes. The loop
    /// stops early once a full TLS record is buffered
    /// (`buf.len() >= 5 + record_len`) or an HTTP header terminator (`\r\n\r\n`)
    /// is seen — whichever the port's [`Proto`] selects.
    ///
    /// Returns **all** bytes read together with the sniffed host (`None` when
    /// nothing was parsed), so the caller can replay them via
    /// [`PrefixedStream`]. **Never returns an error**: a disabled sniffer, an
    /// unmapped port, EOF, timeout, IO error or parse failure all collapse to
    /// `(prefix, None)`. A disabled sniffer or an unmapped port reads **nothing**
    /// (so no latency/data is added on non-sniff ports).
    pub(crate) async fn sniff_prefix<S: AsyncRead + Unpin>(
        &self,
        stream: &mut S,
        dst_port: u16,
    ) -> (Vec<u8>, Option<String>) {
        if !self.cfg.enable {
            return (Vec::new(), None);
        }
        let Some(proto) = self.port_map.get(&dst_port).copied() else {
            return (Vec::new(), None);
        };

        let deadline = Instant::now() + self.cfg.timeout;
        let mut buf: Vec<u8> = Vec::new();
        let mut chunk = [0u8; CHUNK];

        loop {
            let now = Instant::now();
            if now >= deadline || buf.len() >= MAX_PREFIX {
                break;
            }
            // Never read past the cap: cap the slice to the remaining room so a
            // read can neither overflow nor drop bytes.
            let want = (MAX_PREFIX - buf.len()).min(CHUNK);
            match tokio::time::timeout(deadline - now, stream.read(&mut chunk[..want])).await {
                // Overall deadline elapsed, or an IO error: keep what we have.
                Err(_) | Ok(Err(_)) => break,
                // EOF.
                Ok(Ok(0)) => break,
                Ok(Ok(n)) => {
                    buf.extend_from_slice(&chunk[..n]);
                    let complete = match proto {
                        Proto::Tls => tls_record_complete(&buf),
                        Proto::Http => has_http_header_end(&buf),
                    };
                    if complete {
                        break;
                    }
                }
            }
        }

        let host = match proto {
            Proto::Tls => sniff_tls(&buf),
            Proto::Http => sniff_http(&buf),
        };
        (buf, host.map(|h| h.to_string()))
    }
}

/// A complete TLS record is buffered once the 5-byte header and the declared
/// body are both present.
fn tls_record_complete(buf: &[u8]) -> bool {
    if buf.len() < 5 {
        return false;
    }
    let record_len = u16::from_be_bytes([buf[3], buf[4]]) as usize;
    buf.len() >= 5 + record_len
}

/// HTTP request headers end at the first blank line.
fn has_http_header_end(buf: &[u8]) -> bool {
    buf.windows(4).any(|w| w == b"\r\n\r\n")
}

/// An [`AsyncRead`] that yields the prefetched `prefix` first, then delegates to
/// `inner`.
///
/// The replay wrapper for [`Sniffer::sniff_prefix`]: the sniffed bytes are handed
/// back verbatim before the live stream, so the tunnel observes an unmodified
/// byte sequence. [`AsyncWrite`] is a pure pass-through. `Send`/`Unpin` follow
/// `S`.
pub(crate) struct PrefixedStream<S> {
    prefix: Vec<u8>,
    pos: usize,
    inner: S,
}

impl<S> PrefixedStream<S> {
    pub(crate) fn new(prefix: Vec<u8>, inner: S) -> Self {
        Self {
            prefix,
            pos: 0,
            inner,
        }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for PrefixedStream<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let me = self.get_mut();
        if me.pos < me.prefix.len() {
            let remaining = &me.prefix[me.pos..];
            // Respect the caller's buffer capacity; a short read is fine and the
            // next poll continues from `pos`.
            let n = remaining.len().min(buf.remaining());
            buf.put_slice(&remaining[..n]);
            me.pos += n;
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut me.inner).poll_read(cx, buf)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for PrefixedStream<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    use tokio::io::AsyncReadExt;

    /// In-memory `AsyncRead` that counts `poll_read` calls, so "must not read"
    /// can be asserted deterministically without a timing race.
    struct CountingReader {
        data: Vec<u8>,
        pos: usize,
        reads: Arc<AtomicUsize>,
    }

    impl CountingReader {
        fn new(data: Vec<u8>, reads: Arc<AtomicUsize>) -> Self {
            Self {
                data,
                pos: 0,
                reads,
            }
        }
    }

    impl AsyncRead for CountingReader {
        fn poll_read(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            let me = self.get_mut();
            me.reads.fetch_add(1, Ordering::SeqCst);
            if me.pos >= me.data.len() {
                return Poll::Ready(Ok(())); // EOF
            }
            let n = (me.data.len() - me.pos).min(buf.remaining());
            let start = me.pos;
            buf.put_slice(&me.data[start..start + n]);
            me.pos += n;
            Poll::Ready(Ok(()))
        }
    }

    /// Minimal TLS ClientHello carrying an SNI `hostname` (same wire shape as
    /// meow's own sniffer tests).
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

    /// `PrefixedStream` replays the whole prefix before the inner bytes.
    #[tokio::test]
    async fn prefixed_stream_replays_prefix_before_inner() {
        let inner = CountingReader::new(b"inner".to_vec(), Arc::new(AtomicUsize::new(0)));
        let mut stream = PrefixedStream::new(b"prefix-".to_vec(), inner);
        let mut out = Vec::new();
        stream.read_to_end(&mut out).await.unwrap();
        assert_eq!(out, b"prefix-inner");
    }

    /// SNI is extracted and the returned prefix is byte-identical to the input.
    #[tokio::test]
    async fn sniff_prefix_extracts_tls_sni_and_returns_bytes_verbatim() {
        let hello = build_client_hello("example.com");
        let mut stream =
            CountingReader::new(hello.clone(), Arc::new(AtomicUsize::new(0)));
        let sniffer = Sniffer::default_enabled();

        let (prefix, host) = sniffer.sniff_prefix(&mut stream, 443).await;

        assert_eq!(host.as_deref(), Some("example.com"));
        assert_eq!(prefix, hello, "replayed prefix must equal the input bytes");
    }

    /// HTTP `Host` is extracted and the prefix is byte-identical.
    #[tokio::test]
    async fn sniff_prefix_extracts_http_host() {
        let request = b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".to_vec();
        let mut stream =
            CountingReader::new(request.clone(), Arc::new(AtomicUsize::new(0)));
        let sniffer = Sniffer::default_enabled();

        let (prefix, host) = sniffer.sniff_prefix(&mut stream, 80).await;

        assert_eq!(host.as_deref(), Some("example.com"));
        assert_eq!(prefix, request);
    }

    /// A port not in the map returns `(vec![], None)` **without reading**.
    #[tokio::test]
    async fn sniff_prefix_unmapped_port_reads_nothing() {
        let reads = Arc::new(AtomicUsize::new(0));
        let hello = build_client_hello("example.com");
        let mut stream = CountingReader::new(hello, Arc::clone(&reads));
        let sniffer = Sniffer::default_enabled();

        let (prefix, host) = sniffer.sniff_prefix(&mut stream, 22).await;

        assert!(prefix.is_empty());
        assert!(host.is_none());
        assert_eq!(
            reads.load(Ordering::SeqCst),
            0,
            "an unmapped port must consume no data"
        );
    }

    /// A disabled sniffer is a no-op and reads nothing.
    #[tokio::test]
    async fn sniff_prefix_disabled_sniffer_reads_nothing() {
        let reads = Arc::new(AtomicUsize::new(0));
        let mut stream = CountingReader::new(b"whatever".to_vec(), Arc::clone(&reads));
        let sniffer = Sniffer::new(SnifferConfig {
            enable: false,
            ..Default::default()
        });

        let (prefix, host) = sniffer.sniff_prefix(&mut stream, 443).await;

        assert!(prefix.is_empty());
        assert!(host.is_none());
        assert_eq!(reads.load(Ordering::SeqCst), 0);
    }

    /// A silent client returns within `timeout + slack`, with no host and no panic.
    #[tokio::test]
    async fn sniff_prefix_silent_client_returns_within_deadline() {
        let timeout = Duration::from_millis(100);
        let sniffer = Sniffer::new(SnifferConfig {
            enable: true,
            timeout,
            ..Default::default()
        });
        // Connected but never sends: the read stays Pending until the deadline.
        let (_client, mut server) = tokio::io::duplex(64);

        let start = Instant::now();
        let (prefix, host) = sniffer.sniff_prefix(&mut server, 443).await;
        let elapsed = start.elapsed();

        assert!(prefix.is_empty());
        assert!(host.is_none());
        assert!(
            elapsed <= timeout + Duration::from_millis(100),
            "silent client took {elapsed:?}, expected <= {:?}",
            timeout + Duration::from_millis(100)
        );
    }
}
