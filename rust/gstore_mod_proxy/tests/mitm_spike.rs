//! Todo 1 HARD GATE (`.omo/plans/proxy-http-capture.md`): prove the in-TUN TLS
//! MITM datapath is viable.
//!
//! The chain this test builds end to end, all inside one `bounded_runtime`:
//!
//! ```text
//!  raw IPv4/TCP SYNs + TLS ClientHello
//!        │  (SyntheticTcpClient, injected via NetStack ingress)
//!        ▼
//!  meow_lwip::NetStack ──► meow_lwip::TcpListener ── accepted in-TUN TcpStream
//!                                                        │
//!                                          rustls acceptor │ (rcgen leaf, SNI example.com)
//!                                                        ▼
//!                                               hyper HTTP/1.1 request
//!                                                        │
//!   meow_tunnel::TunnelInner::resolve_proxy_lazy(&mut metadata)  ← rules engine
//!   meow_common::ProxyAdapter::dial_tcp(&metadata)               ← outbound
//!                                                        │
//!                                          rustls client │ (upstream.test)
//!                                                        ▼
//!                                          local TLS fixture server
//! ```
//!
//! It is a spike: test-only, never wired into production dispatch. It exists to
//! answer one empirical question the plan marks as the HARD GATE — can we get
//! an `AsyncRead + AsyncWrite` from meow by handing it a `Metadata`, going
//! through the real rules/outbound selection? A second scenario proves a
//! failing upstream dial closes the in-TUN connection cleanly and leaves the
//! tunnel loop unpanicked.
//!
//! Because lwIP's pcb lists are process globals only one `NetStack` may be live
//! at a time, so the two scenarios are serialized on `SERIAL`.

use std::convert::Infallible;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::TokioIo;
use meow_common::{ConnType, Metadata, Network};
use rustls::client::ClientConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName};
use rustls::server::ServerConfig;
use rustls::RootCertStore;
use smol_str::SmolStr;
use tokio::sync::mpsc;

static SERIAL: Mutex<()> = Mutex::new(());

const CLIENT_IP: [u8; 4] = [10, 0, 0, 2];
const SERVER_IP: [u8; 4] = [127, 0, 0, 1];

const PROBE_PORT: u16 = 0xC001;
const CLIENT_ISN: u32 = 0x1000;

const FLAG_FIN: u8 = 0x01;
const FLAG_SYN: u8 = 0x02;
const FLAG_RST: u8 = 0x04;
const FLAG_PSH: u8 = 0x08;
const FLAG_ACK: u8 = 0x10;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Scenario {
    Happy,
    UpstreamFails,
}

#[test]
fn mitm_spike() {
    let guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let rt = gstore_mod_proxy::bounded_runtime().expect("bounded_runtime");
    rt.block_on(spike_all()).expect("spike scenario");
    drop(guard);
}

/// Runs both scenarios over ONE `meow_lwip::NetStack`. lwIP's pcb lists and
/// netif are process globals (meow's single-owner-core contract), so a second
/// stack generation in the same process is not supported; each scenario is a
/// separate in-TUN TCP flow instead.
async fn spike_all() -> Result<(), String> {
    rustls::crypto::aws_lc_rs::default_provider()
        .install_default()
        .ok();

    let pki = Pki::generate()?;
    let mitm_cfg = Arc::new(
        ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![pki.example_leaf.clone()], pki.example_key.clone_key())
            .map_err(|e| format!("mitm server config: {e}"))?,
    );
    let fixture_cfg = Arc::new(
        ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![pki.upstream_leaf.clone()],
                pki.upstream_key.clone_key(),
            )
            .map_err(|e| format!("fixture server config: {e}"))?,
    );
    let client_cfg = Arc::new(pki.client_config()?);
    let tunnel = build_tunnel()?;
    let inner = tunnel.inner().clone();

    let (stack, mut tcp_listener, _udp) =
        meow_lwip::NetStack::new().map_err(|e| format!("NetStack::new: {e}"))?;
    let core_done = stack.core_done();

    let (conn_tx, conn_rx) = mpsc::unbounded_channel::<ConnRequest>();
    let driver = tokio::spawn(drive_lwip(stack, conn_rx));

    for (scenario, client_port) in [(Scenario::Happy, 40_123u16), (Scenario::UpstreamFails, 40_124)]
    {
        run_connection(
            scenario,
            client_port,
            &mut tcp_listener,
            &conn_tx,
            &inner,
            &mitm_cfg,
            &client_cfg,
            &fixture_cfg,
        )
        .await?;
    }

    run_malformed_client_hello(&mut tcp_listener, &conn_tx, &mitm_cfg).await?;

    drop(conn_tx);
    driver.await.map_err(|e| format!("driver join: {e}"))??;
    let mut done = core_done.clone();
    let _ = tokio::time::timeout(Duration::from_secs(3), done.wait_for(|d| *d)).await;
    Ok(())
}

async fn run_malformed_client_hello(
    tcp_listener: &mut meow_lwip::TcpListener,
    conn_tx: &mpsc::UnboundedSender<ConnRequest>,
    mitm_cfg: &Arc<ServerConfig>,
) -> Result<(), String> {
    let (c2s_tx, c2s_rx) = mpsc::unbounded_channel::<ClientMsg>();
    let (s2c_tx, s2c_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    conn_tx
        .send(ConnRequest {
            client_port: 40_125,
            read_tx: s2c_tx,
            write_rx: c2s_rx,
        })
        .map_err(|_| "lwIP driver gone".to_string())?;

    let client = tokio::spawn(async move {
        let _ = c2s_tx.send(ClientMsg::Data(vec![0xff; 32]));
        let _ = c2s_tx.send(ClientMsg::Fin);
        tokio::time::sleep(Duration::from_millis(50)).await;
        drop(c2s_tx);
        drop(s2c_rx);
    });

    let (stream, _, _) = tokio::time::timeout(Duration::from_secs(10), tcp_listener.next())
        .await
        .map_err(|_| "timeout waiting for malformed-flow accept".to_string())?
        .ok_or_else(|| "TcpListener closed on malformed flow".to_string())?;
    let res = tokio_rustls::TlsAcceptor::from(Arc::clone(mitm_cfg))
        .accept(stream)
        .await;
    match res {
        Ok(_) => return Err("garbage ClientHello unexpectedly completed TLS".into()),
        Err(e) => println!(
            "[spike] (5) malformed ClientHello rejected ({e}); in-TUN flow closed cleanly, tunnel loop unpanicked"
        ),
    }
    let _ = client.await;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run_connection(
    scenario: Scenario,
    client_port: u16,
    tcp_listener: &mut meow_lwip::TcpListener,
    conn_tx: &mpsc::UnboundedSender<ConnRequest>,
    inner: &Arc<meow_tunnel::tunnel::TunnelInner>,
    mitm_cfg: &Arc<ServerConfig>,
    client_cfg: &Arc<ClientConfig>,
    fixture_cfg: &Arc<ServerConfig>,
) -> Result<(), String> {
    let (upstream_port, fixture) = match scenario {
        Scenario::Happy => {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
                .await
                .map_err(|e| format!("fixture bind: {e}"))?;
            let port = listener
                .local_addr()
                .map_err(|e| format!("fixture addr: {e}"))?
                .port();
            let cfg = Arc::clone(fixture_cfg);
            let handle = tokio::spawn(async move { run_fixture(listener, cfg).await });
            (port, Some(handle))
        }
        Scenario::UpstreamFails => (closed_port().await?, None),
    };

    let (c2s_tx, c2s_rx) = mpsc::unbounded_channel::<ClientMsg>();
    let (s2c_tx, s2c_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    conn_tx
        .send(ConnRequest {
            client_port,
            read_tx: s2c_tx,
            write_rx: c2s_rx,
        })
        .map_err(|_| "lwIP driver gone".to_string())?;

    let client_cfg_task = Arc::clone(client_cfg);
    let client_task = tokio::spawn(async move {
        let connector = tokio_rustls::TlsConnector::from(client_cfg_task);
        let tls = connector
            .connect(
                ServerName::try_from("example.com").expect("server name"),
                SyntheticTcpClient::new(s2c_rx, c2s_tx),
            )
            .await
            .map_err(|e| format!("client TLS handshake: {e}"))?;
        println!("[spike] (1) client TLS handshake OK, peer leaf CN/SAN = example.com");

        let (mut sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(tls))
            .await
            .map_err(|e| format!("client hyper handshake: {e}"))?;
        let conn_task = tokio::spawn(conn);
        let req = Request::builder()
            .method("GET")
            .uri("/hello")
            .header("host", "example.com")
            .body(Full::new(Bytes::new()))
            .map_err(|e| format!("client request: {e}"))?;
        let resp = sender
            .send_request(req)
            .await
            .map_err(|e| format!("client send_request: {e}"))?;
        let status = resp.status().as_u16();
        let body = resp
            .into_body()
            .collect()
            .await
            .map_err(|e| format!("client body: {e}"))?
            .to_bytes();
        conn_task.abort();
        Ok::<(u16, String), String>((status, String::from_utf8_lossy(&body).into_owned()))
    });

    let (lwip_stream, src, dst) =
        tokio::time::timeout(Duration::from_secs(10), tcp_listener.next())
            .await
            .map_err(|_| format!("[{}] timeout waiting for in-TUN accepted flow", scenario_name(scenario)))?
            .ok_or_else(|| format!("[{}] TcpListener closed", scenario_name(scenario)))?;
    println!("[spike] (2) in-TUN accepted TCP flow {src} -> {dst}");

    let captured = Arc::new(Mutex::new(Capture::default()));
    let serve = serve_mitm(
        lwip_stream,
        Arc::clone(mitm_cfg),
        Arc::clone(client_cfg),
        Arc::clone(inner),
        upstream_port,
        scenario,
        Arc::clone(&captured),
    )
    .await;

    let (client_status, client_body) = client_task
        .await
        .map_err(|e| format!("client join: {e}"))??;
    serve?;
    if let Some(handle) = fixture {
        let _ = handle.await;
    }

    let cap = captured.lock().unwrap_or_else(|e| e.into_inner()).clone();
    assert_scenario(scenario, &cap, client_status, &client_body);

    println!(
        "[spike] scenario={} RESULT=PASS client_status={} client_body={client_body:?} rule={} adapter={}",
        scenario_name(scenario),
        client_status,
        cap.rule,
        cap.adapter,
    );
    Ok(())
}

fn assert_scenario(scenario: Scenario, cap: &Capture, client_status: u16, client_body: &str) {
    assert_eq!(cap.method, "GET", "parsed method");
    assert_eq!(cap.path, "/hello", "parsed path");
    assert_eq!(cap.host, "example.com", "parsed Host header");
    assert_eq!(
        cap.rule, "DOMAIN-SUFFIX",
        "rules engine must have selected the DOMAIN-SUFFIX rule, not a DIRECT bypass"
    );
    assert_eq!(cap.payload, "upstream.test", "matched rule payload");
    assert!(
        cap.adapter.starts_with("DIRECT"),
        "outbound selection: {}",
        cap.adapter
    );
    println!(
        "[spike] (3) rules engine selected rule={} payload={} outbound={}",
        cap.rule, cap.payload, cap.adapter
    );

    match scenario {
        Scenario::Happy => {
            assert!(
                cap.dial_error.is_none(),
                "happy dial must succeed: {:?}",
                cap.dial_error
            );
            assert_eq!(client_status, 200, "client status");
            assert_eq!(client_body, "UPSTREAM_OK:/hello", "upstream bytes replayed");
            assert_eq!(cap.upstream_body.as_deref(), Some("UPSTREAM_OK:/hello"));
            println!("[spike] (4) upstream dial OK; response bytes replayed to in-TUN TLS client");
        }
        Scenario::UpstreamFails => {
            assert!(
                cap.dial_error.is_some(),
                "failure scenario must record a dial error"
            );
            assert_eq!(
                client_status, 502,
                "client got a clean 502, not a broken connection"
            );
            assert_eq!(client_body, "UPSTREAM_DIAL_FAILED");
            println!(
                "[spike] (4) upstream dial FAILED as designed ({}); in-TUN TLS connection closed cleanly, tunnel loop unpanicked",
                cap.dial_error.as_deref().unwrap_or("")
            );
        }
    }
}

fn scenario_name(scenario: Scenario) -> &'static str {
    match scenario {
        Scenario::Happy => "happy",
        Scenario::UpstreamFails => "upstream-dial-failure",
    }
}

// ============================ meow tunnel ============================

fn build_tunnel() -> Result<meow_tunnel::Tunnel, String> {
    let resolver = Arc::new(meow_dns::Resolver::new(
        Vec::new(),
        Vec::new(),
        meow_common::DnsMode::Normal,
        meow_trie::DomainTrie::new(),
        false,
        false,
    ));
    let tunnel = meow_tunnel::Tunnel::new(resolver);
    let rule = meow_rules::parser::parse_rule(
        "DOMAIN-SUFFIX,upstream.test,DIRECT",
        &meow_rules::ParserContext::empty(),
    )
    .map_err(|e| format!("parse_rule: {e}"))?;
    tunnel.update_rules(vec![rule]);
    Ok(tunnel)
}

// ============================ MITM server side ============================

#[allow(clippy::too_many_arguments)]
async fn serve_mitm(
    lwip_stream: meow_lwip::TcpStream,
    mitm_cfg: Arc<ServerConfig>,
    client_cfg: Arc<ClientConfig>,
    inner: Arc<meow_tunnel::tunnel::TunnelInner>,
    upstream_port: u16,
    scenario: Scenario,
    captured: Arc<Mutex<Capture>>,
) -> Result<(), String> {
    let tls = tokio_rustls::TlsAcceptor::from(mitm_cfg)
        .accept(lwip_stream)
        .await
        .map_err(|e| format!("mitm TLS accept: {e}"))?;
    println!("[spike] in-TUN TLS terminated (rustls server, rcgen leaf for example.com)");

    let connector = tokio_rustls::TlsConnector::from(client_cfg);
    let service = service_fn(move |req: Request<hyper::body::Incoming>| {
        let inner = Arc::clone(&inner);
        let connector = connector.clone();
        let captured = Arc::clone(&captured);
        async move {
            let req = req;
            let cap = forward_request(inner, connector, upstream_port, scenario, captured, req).await;
            Ok::<_, Infallible>(cap)
        }
    });

    hyper::server::conn::http1::Builder::new()
        .keep_alive(false)
        .serve_connection(TokioIo::new(tls), service)
        .await
        .map_err(|e| format!("hyper serve_connection: {e}"))?;
    Ok(())
}

async fn forward_request(
    inner: Arc<meow_tunnel::tunnel::TunnelInner>,
    connector: tokio_rustls::TlsConnector,
    upstream_port: u16,
    _scenario: Scenario,
    captured: Arc<Mutex<Capture>>,
    req: Request<hyper::body::Incoming>,
) -> Response<Full<Bytes>> {
    let method = req.method().to_string();
    let path = req.uri().path().to_string();
    let host = req
        .headers()
        .get(hyper::header::HOST)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string();
    {
        let mut c = captured.lock().unwrap_or_else(|e| e.into_inner());
        c.method = method.clone();
        c.path = path.clone();
        c.host = host;
    }

    let mut metadata = Metadata {
        network: Network::Tcp,
        conn_type: ConnType::Tun,
        src_ip: Some(IpAddr::from(CLIENT_IP)),
        src_port: 0,
        dst_ip: Some(IpAddr::from([127, 0, 0, 1])),
        dst_port: upstream_port,
        host: SmolStr::new("upstream.test"),
        in_name: SmolStr::new("tun"),
        ..Default::default()
    };

    let Some((adapter, rule, payload)) = inner.resolve_proxy_lazy(&mut metadata).await else {
        return bad_gateway("NO_ROUTE");
    };
    {
        let mut c = captured.lock().unwrap_or_else(|e| e.into_inner());
        c.rule = rule.to_string();
        c.payload = payload.to_string();
        c.adapter = adapter.name().to_string();
    }

    let conn = match adapter.dial_tcp(&metadata).await {
        Ok(conn) => conn,
        Err(e) => {
            let msg = e.to_string();
            captured
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .dial_error = Some(msg.clone());
            println!("[spike] upstream dial_tcp error = {msg}");
            return bad_gateway("UPSTREAM_DIAL_FAILED");
        }
    };

    let tls = match connector
        .connect(ServerName::try_from("upstream.test").expect("server name"), conn)
        .await
    {
        Ok(tls) => tls,
        Err(e) => return bad_gateway(&format!("upstream_tls:{e}")),
    };

    let (mut sender, conn) = match hyper::client::conn::http1::handshake(TokioIo::new(tls)).await {
        Ok(pair) => pair,
        Err(e) => return bad_gateway(&format!("upstream_h1:{e}")),
    };
    let conn_task = tokio::spawn(conn);

    let up_req = Request::builder()
        .method(method.as_str())
        .uri(path.as_str())
        .header("host", "upstream.test")
        .body(Full::new(Bytes::new()));
    let resp = match up_req {
        Ok(req) => sender.send_request(req).await,
        Err(e) => {
            conn_task.abort();
            return bad_gateway(&format!("upstream_request:{e}"));
        }
    };
    let resp = match resp {
        Ok(resp) => resp,
        Err(e) => {
            conn_task.abort();
            return bad_gateway(&format!("upstream_send:{e}"));
        }
    };
    let status = resp.status().as_u16();
    let body = match resp.into_body().collect().await {
        Ok(b) => b.to_bytes(),
        Err(e) => {
            conn_task.abort();
            return bad_gateway(&format!("upstream_body:{e}"));
        }
    };
    conn_task.abort();
    {
        let mut c = captured.lock().unwrap_or_else(|e| e.into_inner());
        c.upstream_status = Some(status);
        c.upstream_body = Some(String::from_utf8_lossy(&body).into_owned());
    }
    Response::builder()
        .status(status)
        .body(Full::new(body))
        .unwrap_or_else(|_| bad_gateway("response_build"))
}

fn bad_gateway(reason: &str) -> Response<Full<Bytes>> {
    Response::builder()
        .status(502)
        .body(Full::new(Bytes::from_static(b"UPSTREAM_DIAL_FAILED")))
        .unwrap_or_else(|_| {
            let _ = reason;
            Response::new(Full::new(Bytes::from_static(b"UPSTREAM_DIAL_FAILED")))
        })
}

async fn run_fixture(
    listener: tokio::net::TcpListener,
    cfg: Arc<ServerConfig>,
) -> Result<(), String> {
    let (tcp, _) = listener
        .accept()
        .await
        .map_err(|e| format!("fixture accept: {e}"))?;
    let tls = tokio_rustls::TlsAcceptor::from(cfg)
        .accept(tcp)
        .await
        .map_err(|e| format!("fixture TLS accept: {e}"))?;
    let service = service_fn(|req: Request<hyper::body::Incoming>| async move {
        let path = req.uri().path().to_string();
        Ok::<_, Infallible>(Response::new(Full::new(Bytes::from(format!(
            "UPSTREAM_OK:{path}"
        )))))
    });
    hyper::server::conn::http1::Builder::new()
        .keep_alive(false)
        .serve_connection(TokioIo::new(tls), service)
        .await
        .map_err(|e| format!("fixture serve: {e}"))?;
    Ok(())
}

async fn closed_port() -> Result<u16, String> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| format!("closed_port bind: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("closed_port addr: {e}"))?
        .port();
    drop(listener);
    Ok(port)
}

// ============================ synthetic in-TUN TCP client ============================

enum ClientMsg {
    Data(Vec<u8>),
    Fin,
}

struct SyntheticTcpClient {
    read_rx: mpsc::UnboundedReceiver<Vec<u8>>,
    write_tx: mpsc::UnboundedSender<ClientMsg>,
    pending: Vec<u8>,
    pending_pos: usize,
    eof: bool,
}

impl SyntheticTcpClient {
    fn new(
        read_rx: mpsc::UnboundedReceiver<Vec<u8>>,
        write_tx: mpsc::UnboundedSender<ClientMsg>,
    ) -> Self {
        Self {
            read_rx,
            write_tx,
            pending: Vec::new(),
            pending_pos: 0,
            eof: false,
        }
    }
}

impl tokio::io::AsyncRead for SyntheticTcpClient {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        use std::task::Poll;
        if self.pending_pos < self.pending.len() {
            let n = (self.pending.len() - self.pending_pos).min(buf.remaining());
            buf.put_slice(&self.pending[self.pending_pos..self.pending_pos + n]);
            self.pending_pos += n;
            return Poll::Ready(Ok(()));
        }
        if self.eof {
            return Poll::Ready(Ok(()));
        }
        match self.read_rx.poll_recv(cx) {
            Poll::Ready(Some(chunk)) => {
                if chunk.is_empty() {
                    self.eof = true;
                    return Poll::Ready(Ok(()));
                }
                let n = chunk.len().min(buf.remaining());
                buf.put_slice(&chunk[..n]);
                self.pending = chunk;
                self.pending_pos = n;
                Poll::Ready(Ok(()))
            }
            Poll::Ready(None) => {
                self.eof = true;
                Poll::Ready(Ok(()))
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

impl tokio::io::AsyncWrite for SyntheticTcpClient {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        use std::task::Poll;
        match self.write_tx.send(ClientMsg::Data(buf.to_vec())) {
            Ok(()) => Poll::Ready(Ok(buf.len())),
            Err(_) => Poll::Ready(Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "tcp driver gone",
            ))),
        }
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        let _ = self.write_tx.send(ClientMsg::Fin);
        std::task::Poll::Ready(Ok(()))
    }
}

// ============================ lwIP TCP driver ============================

struct ConnRequest {
    client_port: u16,
    read_tx: mpsc::UnboundedSender<Vec<u8>>,
    write_rx: mpsc::UnboundedReceiver<ClientMsg>,
}

async fn drive_lwip(
    stack: meow_lwip::NetStack,
    mut conn_rx: mpsc::UnboundedReceiver<ConnRequest>,
) -> Result<(), String> {
    let (mut sink, mut stream) = stack.split();

    while let Some(ConnRequest {
        client_port,
        read_tx,
        mut write_rx,
    }) = conn_rx.recv().await
    {
        // meow's lwIP is built with TUN2SOCKS, so `tcp_listen_input` accepts a
        // SYN on ANY destination port and pins the new pcb to that same port;
        // the SYN-ACK therefore always arrives from the port we probed. One SYN
        // both opens the flow and reveals the server port.
        sink.send(build_frame(client_port, PROBE_PORT, CLIENT_ISN, 0, FLAG_SYN, &[]))
            .await
            .map_err(|e| format!("send SYN: {e}"))?;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        let mut handshake = None;
        loop {
            match tokio::time::timeout_at(deadline, stream.next()).await {
                Ok(Some(Ok(frame))) => {
                    if let Some(seg) = parse_segment(&frame) {
                        if seg.dst_port == client_port
                            && seg.flags & FLAG_SYN != 0
                            && seg.flags & FLAG_ACK != 0
                        {
                            handshake = Some((seg.src_port, seg.seq));
                            break;
                        }
                    }
                }
                Ok(Some(Err(e))) => return Err(format!("ingress stream: {e}")),
                Ok(None) => return Err("netstack egress closed during handshake".into()),
                Err(_) => break,
            }
        }
        let (server_port, srv_isn) =
            handshake.ok_or_else(|| "no SYN-ACK from the in-TUN lwIP listener".to_string())?;

        let mut my_next = CLIENT_ISN.wrapping_add(1);
        let mut srv_next = srv_isn.wrapping_add(1);
        sink.send(build_frame(client_port, server_port, my_next, srv_next, FLAG_ACK, &[]))
            .await
            .map_err(|e| format!("send final ACK: {e}"))?;

        let mut write_closed = false;
        loop {
            tokio::select! {
                maybe = stream.next() => {
                    match maybe {
                        Some(Ok(frame)) => {
                            let Some(seg) = parse_segment(&frame) else { continue };
                            if seg.src_port != server_port || seg.dst_port != client_port {
                                continue;
                            }
                            if seg.flags & FLAG_RST != 0 {
                                let _ = read_tx.send(Vec::new());
                                break;
                            }
                            if !seg.payload.is_empty() {
                                if seg.seq == srv_next {
                                    srv_next = srv_next.wrapping_add(seg.payload.len() as u32);
                                    let _ = read_tx.send(seg.payload.to_vec());
                                }
                                sink.send(build_frame(client_port, server_port, my_next, srv_next, FLAG_ACK, &[]))
                                    .await
                                    .map_err(|e| format!("send ACK: {e}"))?;
                            }
                            if seg.flags & FLAG_FIN != 0 {
                                srv_next = srv_next.wrapping_add(1);
                                sink.send(build_frame(client_port, server_port, my_next, srv_next, FLAG_ACK, &[]))
                                    .await
                                    .map_err(|e| format!("send FIN ACK: {e}"))?;
                                let _ = read_tx.send(Vec::new());
                                break;
                            }
                        }
                        Some(Err(e)) => return Err(format!("ingress stream: {e}")),
                        None => break,
                    }
                }
                msg = write_rx.recv(), if !write_closed => {
                    match msg {
                        Some(ClientMsg::Data(data)) => {
                            for part in data.chunks(1200) {
                                sink.send(build_frame(client_port, server_port, my_next, srv_next, FLAG_PSH | FLAG_ACK, part))
                                    .await
                                    .map_err(|e| format!("send data: {e}"))?;
                                my_next = my_next.wrapping_add(part.len() as u32);
                            }
                        }
                        Some(ClientMsg::Fin) => {
                            sink.send(build_frame(client_port, server_port, my_next, srv_next, FLAG_FIN | FLAG_ACK, &[]))
                                .await
                                .map_err(|e| format!("send FIN: {e}"))?;
                            my_next = my_next.wrapping_add(1);
                            write_closed = true;
                        }
                        None => write_closed = true,
                    }
                }
            }
        }
    }
    Ok(())
}

struct Segment<'a> {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    flags: u8,
    payload: &'a [u8],
}

fn parse_segment(frame: &[u8]) -> Option<Segment<'_>> {
    if frame.len() < 40 || frame[0] >> 4 != 4 || frame[9] != 6 {
        return None;
    }
    let ihl = ((frame[0] & 0x0f) as usize) * 4;
    let total = u16::from_be_bytes([frame[2], frame[3]]) as usize;
    let end = total.min(frame.len());
    if ihl + 20 > end {
        return None;
    }
    let tcp = &frame[ihl..end];
    let doff = ((tcp[12] >> 4) as usize) * 4;
    if doff < 20 || doff > tcp.len() {
        return None;
    }
    Some(Segment {
        src_port: u16::from_be_bytes([tcp[0], tcp[1]]),
        dst_port: u16::from_be_bytes([tcp[2], tcp[3]]),
        seq: u32::from_be_bytes([tcp[4], tcp[5], tcp[6], tcp[7]]),
        flags: tcp[13],
        payload: &tcp[doff..],
    })
}

fn build_frame(src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, payload: &[u8]) -> Vec<u8> {
    let total = 40 + payload.len();
    let mut f = vec![0u8; total];
    f[0] = 0x45;
    f[2..4].copy_from_slice(&(total as u16).to_be_bytes());
    f[6..8].copy_from_slice(&0x4000u16.to_be_bytes());
    f[8] = 64;
    f[9] = 6;
    f[12..16].copy_from_slice(&CLIENT_IP);
    f[16..20].copy_from_slice(&SERVER_IP);
    f[20..22].copy_from_slice(&src_port.to_be_bytes());
    f[22..24].copy_from_slice(&dst_port.to_be_bytes());
    f[24..28].copy_from_slice(&seq.to_be_bytes());
    f[28..32].copy_from_slice(&ack.to_be_bytes());
    f[32] = 0x50;
    f[33] = flags;
    f[34..36].copy_from_slice(&0xFFFFu16.to_be_bytes());
    f[40..].copy_from_slice(payload);
    f
}

// ============================ PKI (rcgen) ============================

struct Pki {
    ca_der: CertificateDer<'static>,
    example_leaf: CertificateDer<'static>,
    example_key: PrivateKeyDer<'static>,
    upstream_leaf: CertificateDer<'static>,
    upstream_key: PrivateKeyDer<'static>,
}

impl Pki {
    fn generate() -> Result<Self, String> {
        use rcgen::{
            BasicConstraints, CertificateParams, DnType, IsCa, Issuer, KeyPair, KeyUsagePurpose,
        };

        let ca_key = KeyPair::generate().map_err(|e| format!("ca key: {e}"))?;
        let mut ca_params =
            CertificateParams::new(Vec::<String>::new()).map_err(|e| format!("ca params: {e}"))?;
        ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        ca_params
            .distinguished_name
            .push(DnType::CommonName, "GStore MITM Spike CA");
        ca_params.key_usages = vec![
            KeyUsagePurpose::KeyCertSign,
            KeyUsagePurpose::CrlSign,
            KeyUsagePurpose::DigitalSignature,
        ];
        let ca_cert = ca_params
            .self_signed(&ca_key)
            .map_err(|e| format!("ca self-sign: {e}"))?;
        let ca_der = CertificateDer::from(ca_cert.der().to_vec());
        let issuer = Issuer::new(ca_params, ca_key);

        let (example_leaf, example_key) = issue_leaf(&issuer, "example.com")?;
        let (upstream_leaf, upstream_key) = issue_leaf(&issuer, "upstream.test")?;

        Ok(Self {
            ca_der,
            example_leaf,
            example_key,
            upstream_leaf,
            upstream_key,
        })
    }

    fn client_config(&self) -> Result<ClientConfig, String> {
        let mut roots = RootCertStore::empty();
        roots
            .add(self.ca_der.clone())
            .map_err(|e| format!("trust CA: {e}"))?;
        Ok(ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth())
    }
}

fn issue_leaf(
    issuer: &rcgen::Issuer<'_, rcgen::KeyPair>,
    dns: &str,
) -> Result<(CertificateDer<'static>, PrivateKeyDer<'static>), String> {
    use rcgen::{
        CertificateParams, DnType, ExtendedKeyUsagePurpose, KeyPair, KeyUsagePurpose,
    };

    let key = KeyPair::generate().map_err(|e| format!("{dns} key: {e}"))?;
    let mut params =
        CertificateParams::new(vec![dns.to_string()]).map_err(|e| format!("{dns} params: {e}"))?;
    params.distinguished_name.push(DnType::CommonName, dns);
    params.use_authority_key_identifier_extension = true;
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    let cert = params
        .signed_by(&key, issuer)
        .map_err(|e| format!("{dns} sign: {e}"))?;
    Ok((CertificateDer::from(cert.der().to_vec()), PrivateKeyDer::from(key)))
}

// ============================ captured state ============================

#[derive(Clone, Default)]
struct Capture {
    method: String,
    path: String,
    host: String,
    rule: String,
    payload: String,
    adapter: String,
    dial_error: Option<String>,
    upstream_status: Option<u16>,
    upstream_body: Option<String>,
}
