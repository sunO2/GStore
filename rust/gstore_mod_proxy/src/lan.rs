//! Optional LAN listening (Todo 28).
//!
//! Exposes one optional, **default-OFF** LAN inbound on `bindAddress:port`
//! (`1087`). It serves three protocols on the same port:
//!
//! * **HTTP** and **SOCKS5** — delegated to meow's native protocol handlers
//!   ([`meow_listener::http_proxy::handle_http`] /
//!   [`meow_listener::socks5::handle_socks5`]), exactly the implementations
//!   `meow_listener::MixedListener` dispatches to. We drive them directly
//!   (rather than through `MixedListener`) because `MixedListener` has a fixed
//!   `0x05 => SOCKS5 else HTTP` first-byte dispatch and binds its own socket:
//!   it offers no seam for SOCKS4 or for a per-connection IP deny-list. The
//!   protocol semantics, global auth and tunnel hand-off are still entirely
//!   meow's.
//! * **SOCKS4 / SOCKS4a** — a minimal front-end implemented here (meow has no
//!   SOCKS4 listener). It parses version `0x04`, `CD`, DSTPORT/DSTIP (+ the
//!   optional USERID, and for SOCKS4a the trailing hostname), replies
//!   `0x5A`/`0x5B`, and hands the flow to [`meow_tunnel::route_inbound_tcp`] —
//!   the same path Todo 7's TUN dispatch and meow's SOCKS5 handler use.
//!
//! ## Security invariants
//!
//! * **Default OFF.** Nothing binds until `lan.set {enabled:true}`.
//! * **Never the TUN.** The listener binds a normal TCP socket on the requested
//!   LAN address; it is not, and cannot be, the TUN interface.
//! * **IP allow-list is ours.** meow has no `lan-allowed-ips`; the accept loop
//!   rejects a peer that is not inside `allowedIps` *before* any dispatch.
//! * **Global auth is meow's.** `auth` becomes a meow
//!   [`meow_common::AuthConfig`] (`skip_prefixes` always contains loopback, so
//!   127.0.0.1/::1 is exempt). SOCKS4 cannot carry a password, so when auth is
//!   configured and the peer is not exempt the SOCKS4 request is rejected.
//! * **Warning surfaced.** Enabling without `auth` emits a `proxy.state`
//!   warning and every response carries a `warning` field.
//! * **Works with or without the VPN tunnel.** When a TUN/VPN engine is live the
//!   listener binds to that tunnel; otherwise it builds an engine-only tunnel
//!   (no `VpnService`, no protect hook) on its own bounded runtime, so the phone
//!   can share the proxy without tunneling its own traffic.
//!
//! ## Runtime
//!
//! One dedicated OS thread with a bounded [`crate::bounded_runtime`]
//! (`worker_threads(4)`), never `Runtime::new()` / CPU-default workers. Stop
//! drops the listener, signals the accept loop and joins the thread, so the
//! 5-consecutive-parallel-run test gate stays deterministic.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::str::FromStr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use gstore_contract::error::{ModuleError, StatusCode};
use ipnet::IpNet;
use meow_common::{AuthConfig, ConnType, Credentials, Metadata, Network};
use meow_tunnel::Tunnel;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// `lan.set` payload / CIDR invalid.
pub(crate) const ERR_LAN_CONFIG_INVALID: &str = "PROXY_LAN_CONFIG_INVALID";
/// LAN was requested while it is disabled (`PROXY_LAN_DISABLED`, 409).
#[allow(dead_code)]
pub(crate) const ERR_LAN_DISABLED: &str = "PROXY_LAN_DISABLED";
/// Warning code emitted/returned when the listener is enabled without auth.
pub(crate) const WARN_LAN_NO_AUTH: &str = "PROXY_LAN_NO_AUTH";

const DEFAULT_PORT: u16 = 1087;
const MAX_CONNECTIONS: usize = 256;
/// First-byte protocol detection timeout (mirrors meow's mixed listener).
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);
/// SOCKS4 USERID / domain name hard cap (RFC 1928 allows 255).
const MAX_CSTR: usize = 255;
const LAN_CONFIG_FILE: &str = "lan.json";
const BIND_TIMEOUT: Duration = Duration::from_secs(5);

/// Optional `user:pass`. `null` disables authentication.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LanAuth {
    pub user: String,
    pub pass: String,
}

/// The persisted LAN listener config (`API.md` §2.12).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct LanConfig {
    pub enabled: bool,
    pub port: u16,
    pub bind_address: String,
    pub auth: Option<LanAuth>,
    pub allowed_ips: Vec<String>,
}

impl Default for LanConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            port: DEFAULT_PORT,
            bind_address: "0.0.0.0".to_string(),
            auth: None,
            allowed_ips: Vec::new(),
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LanPatch {
    enabled: Option<bool>,
    port: Option<u16>,
    bind_address: Option<String>,
    /// `Some(None)` clears auth (explicit JSON `null`).
    auth: Option<Option<LanAuth>>,
    allowed_ips: Option<Vec<String>>,
}

fn invalid(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_LAN_CONFIG_INVALID, message)
}

impl LanConfig {
    /// Merge a partial JSON object over this config and validate the result.
    pub(crate) fn apply_patch(&mut self, payload: &[u8]) -> Result<(), ModuleError> {
        if payload.is_empty() {
            return self.validate();
        }
        let value: serde_json::Value = serde_json::from_slice(payload)
            .map_err(|e| invalid(format!("payload must be a JSON object: {e}")))?;
        if !value.is_object() {
            return Err(invalid("payload must be a JSON object"));
        }
        let patch: LanPatch =
            serde_json::from_value(value).map_err(|e| invalid(format!("invalid lan config: {e}")))?;
        if let Some(enabled) = patch.enabled {
            self.enabled = enabled;
        }
        if let Some(port) = patch.port {
            self.port = port;
        }
        if let Some(bind) = patch.bind_address {
            self.bind_address = bind;
        }
        if let Some(auth) = patch.auth {
            self.auth = auth;
        }
        if let Some(ips) = patch.allowed_ips {
            self.allowed_ips = ips;
        }
        self.validate()
    }

    pub(crate) fn validate(&self) -> Result<(), ModuleError> {
        normalize_bind(&self.bind_address)?;
        if let Some(auth) = &self.auth {
            if auth.user.trim().is_empty() {
                return Err(invalid("auth.user must not be empty"));
            }
            if auth.pass.is_empty() {
                return Err(invalid("auth.pass must not be empty"));
            }
        }
        for cidr in &self.allowed_ips {
            IpNet::from_str(cidr.trim())
                .map_err(|e| invalid(format!("invalid allowedIps entry {cidr:?}: {e}")))?;
        }
        Ok(())
    }

    fn allowed_nets(&self) -> Result<Vec<IpNet>, ModuleError> {
        self.allowed_ips
            .iter()
            .map(|cidr| {
                IpNet::from_str(cidr.trim())
                    .map_err(|e| invalid(format!("invalid allowedIps entry {cidr:?}: {e}")))
            })
            .collect()
    }

    fn bind_addr(&self) -> Result<SocketAddr, ModuleError> {
        Ok(SocketAddr::new(normalize_bind(&self.bind_address)?, self.port))
    }

    /// The meow global auth config, or `None` when auth is disabled.
    ///
    /// `skip_prefixes` always seeds loopback (`127.0.0.1/32`, `::1/128`), which
    /// is meow's documented invariant: loopback can never be forced to
    /// authenticate.
    fn auth_config(&self) -> Option<Arc<AuthConfig>> {
        let auth = self.auth.as_ref()?;
        let mut creds = HashMap::new();
        creds.insert(auth.user.clone(), auth.pass.clone());
        let skip = vec![
            IpNet::from_str("127.0.0.1/32").unwrap(),
            IpNet::from_str("::1/128").unwrap(),
        ];
        Some(Arc::new(AuthConfig::new(
            Arc::new(Credentials::new(creds)),
            skip,
        )))
    }
}

fn normalize_bind(raw: &str) -> Result<IpAddr, ModuleError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed == "*" {
        return Ok(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    }
    IpAddr::from_str(trimmed).map_err(|e| invalid(format!("invalid bindAddress {raw:?}: {e}")))
}

/// The security warning for a config, if any (`None` when safe).
pub(crate) fn warning_for(config: &LanConfig) -> Option<serde_json::Value> {
    if config.enabled && config.auth.is_none() {
        Some(serde_json::json!({
            "code": WARN_LAN_NO_AUTH,
            "message": "LAN listening is enabled without authentication; anyone who can reach \
                        this port on the local network can use the proxy. Set a username and \
                        password, or keep allowedIps restricted.",
        }))
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Process-global state
// ---------------------------------------------------------------------------

struct Running {
    addr: SocketAddr,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
    active: Arc<AtomicUsize>,
    engine_only: bool,
}

struct LanState {
    config: LanConfig,
    data_dir: String,
    cache_dir: String,
    running: Option<Running>,
}

impl Default for LanState {
    fn default() -> Self {
        Self {
            config: LanConfig::default(),
            data_dir: String::new(),
            cache_dir: String::new(),
            running: None,
        }
    }
}

static STATE: OnceLock<Mutex<LanState>> = OnceLock::new();

fn state() -> &'static Mutex<LanState> {
    STATE.get_or_init(|| Mutex::new(LanState::default()))
}

/// Install the module context and load any persisted LAN config.
pub(crate) fn configure(data_dir: &str, cache_dir: &str) {
    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    st.data_dir = data_dir.to_string();
    st.cache_dir = cache_dir.to_string();
    if data_dir.trim().is_empty() {
        return;
    }
    let path = std::path::Path::new(data_dir).join(LAN_CONFIG_FILE);
    if let Ok(bytes) = std::fs::read(&path) {
        if let Ok(config) = serde_json::from_slice::<LanConfig>(&bytes) {
            if config.validate().is_ok() {
                st.config = config;
            }
        }
    }
}

fn persist(data_dir: &str, config: &LanConfig) {
    let dir = data_dir.trim();
    if dir.is_empty() {
        return;
    }
    let path = std::path::Path::new(dir).join(LAN_CONFIG_FILE);
    if let Ok(bytes) = serde_json::to_vec(config) {
        let _ = std::fs::write(path, bytes);
    }
}

pub(crate) fn get() -> LanConfig {
    state().lock().unwrap_or_else(|e| e.into_inner()).config.clone()
}

/// `lan.get` data: the config plus the current security warning.
pub(crate) fn get_json() -> serde_json::Value {
    let config = get();
    serde_json::json!({ "config": config, "warning": warning_for(&config) })
}

/// `lan.status` data.
pub(crate) fn status_json() -> serde_json::Value {
    let st = state().lock().unwrap_or_else(|e| e.into_inner());
    let config = st.config.clone();
    let (bound, addresses, active, engine_only, actual_port) = match st.running.as_ref() {
        Some(running) => (
            true,
            vec![running.addr.to_string()],
            running.active.load(Ordering::SeqCst),
            running.engine_only,
            running.addr.port(),
        ),
        None => (false, Vec::new(), 0, false, config.port),
    };
    serde_json::json!({
        "enabled": config.enabled,
        "bound": bound,
        "listening": bound,
        "addresses": addresses,
        "activeConns": active,
        "port": actual_port,
        "bindAddress": config.bind_address,
        "engineOnly": engine_only,
        "warning": warning_for(&config),
        "config": config,
    })
}

/// `lan.set`: merge, validate, persist and reconcile the listener.
///
/// Returns the effective config (the listener is started/restarted when enabled
/// and stopped when disabled).
pub(crate) fn set(
    data_dir: &str,
    cache_dir: &str,
    payload: &[u8],
) -> Result<LanConfig, ModuleError> {
    let (config, data_dir_owned, cache_dir_owned) = {
        let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
        if !data_dir.trim().is_empty() {
            st.data_dir = data_dir.to_string();
        }
        if !cache_dir.trim().is_empty() {
            st.cache_dir = cache_dir.to_string();
        }
        let mut config = st.config.clone();
        config.apply_patch(payload)?;
        st.config = config.clone();
        persist(&st.data_dir, &config);
        (config, st.data_dir.clone(), st.cache_dir.clone())
    };

    if config.enabled {
        // Always restart: port/bind/auth/allowedIps may have changed, and a fresh
        // bind is the only way to guarantee no stale listener survives.
        start_listener(&config, &data_dir_owned, &cache_dir_owned)?;
    } else {
        stop();
    }
    Ok(config)
}

/// Start (or restart) the listener from `config`. Replaces any running one.
fn start_listener(config: &LanConfig, data_dir: &str, cache_dir: &str) -> Result<SocketAddr, ModuleError> {
    stop();
    let bind = config.bind_addr()?;
    let auth = config.auth_config();
    let auth_present = auth.is_some();
    let nets = config.allowed_nets()?;
    let port = config.port;
    // Share the live tunnel when one exists; otherwise the thread builds an
    // engine-only tunnel (no TUN, no VpnService) so LAN works standalone.
    let shared = crate::rules::active_tunnel();
    let engine_only = shared.is_none();
    let data_dir = data_dir.to_string();
    let cache_dir = cache_dir.to_string();
    let active = Arc::new(AtomicUsize::new(0));

    let (addr_tx, addr_rx) = std::sync::mpsc::channel::<Result<SocketAddr, String>>();
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let active_for_thread = Arc::clone(&active);

    let thread = std::thread::Builder::new()
        .name("gstore-proxy-lan".to_string())
        .spawn(move || {
            let rt = match crate::bounded_runtime() {
                Ok(rt) => rt,
                Err(e) => {
                    let _ = addr_tx.send(Err(format!("bounded_runtime: {e}")));
                    return;
                }
            };
            rt.block_on(async move {
                let tunnel = match shared {
                    Some(tunnel) => tunnel,
                    None => match build_engine_only(&data_dir, &cache_dir).await {
                        Ok(tunnel) => tunnel,
                        Err(e) => {
                            let _ = addr_tx.send(Err(e));
                            return;
                        }
                    },
                };

                let std_listener = match std::net::TcpListener::bind(bind) {
                    Ok(listener) => listener,
                    Err(e) => {
                        let _ = addr_tx.send(Err(format!("bind {bind}: {e}")));
                        return;
                    }
                };
                if let Err(e) = std_listener.set_nonblocking(true) {
                    let _ = addr_tx.send(Err(format!("set_nonblocking: {e}")));
                    return;
                }
                let addr = match std_listener.local_addr() {
                    Ok(addr) => addr,
                    Err(e) => {
                        let _ = addr_tx.send(Err(format!("local_addr: {e}")));
                        return;
                    }
                };
                let listener = match tokio::net::TcpListener::from_std(std_listener) {
                    Ok(listener) => listener,
                    Err(e) => {
                        let _ = addr_tx.send(Err(format!("tokio listener: {e}")));
                        return;
                    }
                };

                let _ = addr_tx.send(Ok(addr));
                run_accept_loop(
                    listener,
                    Arc::clone(&tunnel),
                    auth,
                    nets,
                    port,
                    active_for_thread,
                    shutdown_rx,
                )
                .await;

                // Engine-only teardown: drop the tunnel we built, but only if it
                // is still the process-global one (a TUN engine may have replaced
                // it in the meantime).
                if engine_only && crate::rules::detach_tunnel_if(&tunnel) {
                    meow_common::clear_host_resolver();
                }
            });
        })
        .map_err(|e| {
            ModuleError::new(
                StatusCode::InternalError,
                ERR_LAN_CONFIG_INVALID,
                format!("lan listener thread spawn failed: {e}"),
            )
        })?;

    let addr = match addr_rx.recv_timeout(BIND_TIMEOUT) {
        Ok(Ok(addr)) => addr,
        Ok(Err(e)) => {
            let _ = thread.join();
            return Err(ModuleError::new(
                StatusCode::InternalError,
                ERR_LAN_CONFIG_INVALID,
                format!("lan listener bind failed: {e}"),
            ));
        }
        Err(_) => {
            let _ = thread.join();
            return Err(ModuleError::new(
                StatusCode::InternalError,
                ERR_LAN_CONFIG_INVALID,
                "lan listener did not bind within 5s",
            ));
        }
    };

    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    st.running = Some(Running {
        addr,
        shutdown: Some(shutdown_tx),
        thread: Some(thread),
        active,
        engine_only,
    });
    crate::log_message(
        1,
        &format!(
            "proxy.lan: bound {addr} engineOnly={engine_only} auth={} allowedIps={}",
            auth_present,
            config.allowed_ips.len()
        ),
    );
    Ok(addr)
}

/// Stop the listener if running. Idempotent.
pub(crate) fn stop() -> bool {
    let taken = state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .running
        .take();
    let Some(mut running) = taken else { return false };
    if let Some(tx) = running.shutdown.take() {
        let _ = tx.send(());
    }
    if let Some(thread) = running.thread.take() {
        let _ = thread.join();
    }
    crate::log_message(1, "proxy.lan: stopped");
    true
}

/// `destroy`/`shutdown`: stop the listener and drop all LAN state.
pub(crate) fn shutdown() {
    stop();
    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    *st = LanState::default();
}

/// Reconcile the listener after the engine (re)starts: when enabled, rebind so
/// the listener shares the freshly built tunnel. Errors are swallowed because
/// the VPN engine must not fail just because an optional LAN bind failed.
pub(crate) fn reconcile() {
    let _ = reconcile_result();
}

/// Error-returning reconcile used by the `lanProxy` mode transition (Todo 29):
/// an enabled config that cannot bind must fail the switch structurally instead
/// of silently leaving the mode without an inbound.
pub(crate) fn reconcile_result() -> Result<bool, ModuleError> {
    let (config, data_dir, cache_dir) = {
        let st = state().lock().unwrap_or_else(|e| e.into_inner());
        if !st.config.enabled {
            return Ok(false);
        }
        (st.config.clone(), st.data_dir.clone(), st.cache_dir.clone())
    };
    start_listener(&config, &data_dir, &cache_dir)?;
    Ok(true)
}

/// Whether a LAN listener is currently bound (Todo 29 consistency check).
pub(crate) fn is_bound() -> bool {
    state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .running
        .is_some()
}

#[cfg(test)]
pub(crate) fn reset_for_tests() {
    stop();
    let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
    *st = LanState::default();
}

/// Build an engine-only tunnel (no TUN reader, no protect hook) with the
/// configured proxies/rules, so the LAN listener works without `VpnService`.
async fn build_engine_only(data_dir: &str, cache_dir: &str) -> Result<Arc<Tunnel>, String> {
    let dns = crate::dns::ensure_engine().await;
    let _inner = crate::dispatch::build_engine(dns.resolver());
    let tunnel = crate::rules::active_tunnel().ok_or_else(|| "engine build produced no tunnel".to_string())?;
    if !data_dir.trim().is_empty() {
        if let Ok(Some(generated)) = crate::config::try_generate(
            data_dir,
            cache_dir,
            &crate::config::GenerateRequest::default(),
        ) {
            let store = crate::nodes::ensure_selector_store(data_dir);
            let (map, warnings) = crate::config::build_registry(&generated.raw, Some(&store));
            crate::nodes::install_proxies(&tunnel, map);
            crate::log_message(
                1,
                &format!(
                    "proxy.lan: engine-only profile={:?} nodes={} warnings={}",
                    generated.profile_id,
                    generated.node_count,
                    warnings.len()
                ),
            );
        }
    }
    Ok(tunnel)
}

// ---------------------------------------------------------------------------
// Accept loop + protocol dispatch
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
async fn run_accept_loop(
    listener: tokio::net::TcpListener,
    tunnel: Arc<Tunnel>,
    auth: Option<Arc<AuthConfig>>,
    nets: Vec<IpNet>,
    port: u16,
    active: Arc<AtomicUsize>,
    mut shutdown: tokio::sync::oneshot::Receiver<()>,
) {
    let semaphore = Arc::new(tokio::sync::Semaphore::new(MAX_CONNECTIONS));
    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            accepted = listener.accept() => {
                let (stream, src) = match accepted {
                    Ok(pair) => pair,
                    Err(e) => {
                        crate::log_message(2, &format!("proxy.lan: accept failed: {e}"));
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        continue;
                    }
                };
                if !is_allowed(&nets, src.ip()) {
                    // Reject before any dispatch: the peer is outside allowedIps.
                    crate::log_message(2, &format!("proxy.lan: rejected {src} (not in allowedIps)"));
                    drop(stream);
                    continue;
                }
                let permit = match Arc::clone(&semaphore).acquire_owned().await {
                    Ok(permit) => permit,
                    Err(_) => break,
                };
                let tunnel = Arc::clone(&tunnel);
                let auth = auth.clone();
                let active = Arc::clone(&active);
                tokio::spawn(async move {
                    let _permit = permit;
                    active.fetch_add(1, Ordering::SeqCst);
                    handle_stream(tunnel, stream, src, auth, port).await;
                    active.fetch_sub(1, Ordering::SeqCst);
                });
            }
        }
    }
}

fn is_allowed(nets: &[IpNet], ip: IpAddr) -> bool {
    nets.is_empty() || nets.iter().any(|net| net.contains(&ip))
}

/// Dispatch one accepted connection by its first byte.
///
/// `src` is a parameter (not read from the socket) so tests can exercise the
/// auth / allow-list policy with a synthetic source address.
pub(crate) async fn handle_stream(
    tunnel: Arc<Tunnel>,
    stream: TcpStream,
    src: SocketAddr,
    auth: Option<Arc<AuthConfig>>,
    port: u16,
) {
    let mut peek = [0u8; 1];
    match tokio::time::timeout(HANDSHAKE_TIMEOUT, stream.peek(&mut peek)).await {
        Err(_) => {
            crate::log_message(2, &format!("proxy.lan: protocol detection timed out for {src}"));
            return;
        }
        Ok(Ok(0)) => return,
        Ok(Ok(_)) => {}
        Ok(Err(e)) => {
            crate::log_message(2, &format!("proxy.lan: peek failed for {src}: {e}"));
            return;
        }
    }
    if peek[0] == 0x04 {
        socks4::handle(&tunnel, stream, src, auth.as_deref(), port).await;
    } else if peek[0] == 0x05 {
        meow_listener::socks5::handle_socks5(
            &tunnel,
            stream,
            src,
            None,
            auth.as_deref(),
            "lan",
            port,
        )
        .await;
    } else {
        meow_listener::http_proxy::handle_http(
            &tunnel,
            stream,
            src,
            None,
            auth.as_deref(),
            "lan",
            port,
        )
        .await;
    }
}

/// Minimal SOCKS4 / SOCKS4a front-end (meow has no SOCKS4 listener).
///
/// RFC 1928 + the SOCKS4a convention: request is `VN(0x04) CD DSTPORT(2) DSTIP(4)
/// USERID\0 [HOSTNAME\0 when DSTIP is 0.0.0.x]`. Only `CD=0x01` (CONNECT) is
/// served; BIND (`0x02`) replies `0x5B`. The reply is `00 CD 0000 00000000`.
mod socks4 {
    use super::*;

    pub(super) async fn handle(
        tunnel: &Tunnel,
        mut stream: TcpStream,
        src: SocketAddr,
        auth: Option<&AuthConfig>,
        in_port: u16,
    ) {
        let mut header = [0u8; 8];
        if stream.read_exact(&mut header).await.is_err() {
            return;
        }
        if header[0] != 0x04 {
            return;
        }
        let command = header[1];
        let dst_port = u16::from_be_bytes([header[2], header[3]]);
        let dst_ip = Ipv4Addr::new(header[4], header[5], header[6], header[7]);

        // USERID is consumed (and ignored); SOCKS4 has no password field.
        if read_cstr(&mut stream).await.is_none() {
            return;
        }

        let mut host = String::new();
        let mut dst_ip_opt = Some(IpAddr::V4(dst_ip));
        // SOCKS4a: 0.0.0.x means "hostname follows".
        if dst_ip.octets()[..3] == [0, 0, 0] {
            match read_cstr(&mut stream).await {
                Some(name) => host = name,
                None => return,
            }
            dst_ip_opt = None;
        }

        if command != 0x01 {
            let _ = reply(&mut stream, 0x5B).await;
            return;
        }
        if host.is_empty() && dst_ip_opt.is_none() {
            let _ = reply(&mut stream, 0x5B).await;
            return;
        }
        // SOCKS4 carries no password: when auth is required and the peer is not
        // exempt (loopback is always exempt), reject rather than run unauthed.
        if let Some(cfg) = auth.filter(|cfg| {
            !cfg.credentials.is_empty() && !cfg.should_skip(&src.ip())
        }) {
            let _ = cfg;
            crate::log_message(
                2,
                &format!("proxy.lan: SOCKS4 from {src} rejected (auth required, no password field)"),
            );
            let _ = reply(&mut stream, 0x5B).await;
            return;
        }

        let metadata = Metadata {
            network: Network::Tcp,
            conn_type: ConnType::Socks4,
            src_ip: Some(src.ip()),
            src_port: src.port(),
            dst_ip: dst_ip_opt,
            dst_port,
            host: Metadata::lower_host(&host),
            in_name: "lan".into(),
            in_port,
            ..Default::default()
        };

        // Grant first: `route_inbound_tcp` owns the dial + relay, so there is no
        // post-dial, pre-relay hook to write the reply from. A failed upstream
        // dial then surfaces as a closed connection.
        if reply(&mut stream, 0x5A).await.is_err() {
            return;
        }
        crate::log_message(
            1,
            &format!(
                "proxy.lan: SOCKS4 CONNECT {} -> {}:{}",
                src,
                if host.is_empty() { dst_ip.to_string() } else { host.clone() },
                dst_port
            ),
        );
        let inner = tunnel.inner();
        meow_tunnel::route_inbound_tcp(inner, &mut stream, metadata, &[]).await;
    }

    /// Read a NUL-terminated string, bounded to [`MAX_CSTR`] bytes.
    async fn read_cstr(stream: &mut TcpStream) -> Option<String> {
        let mut buf = Vec::new();
        let mut byte = [0u8; 1];
        for _ in 0..MAX_CSTR {
            stream.read_exact(&mut byte).await.ok()?;
            if byte[0] == 0 {
                return Some(String::from_utf8_lossy(&buf).into_owned());
            }
            buf.push(byte[0]);
        }
        Some(String::from_utf8_lossy(&buf).into_owned())
    }

    async fn reply(stream: &mut TcpStream, code: u8) -> std::io::Result<()> {
        stream.write_all(&[0x00, code, 0, 0, 0, 0, 0, 0]).await?;
        stream.flush().await
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::AtomicU32;

    use async_trait::async_trait;
    use meow_common::{
        AdapterType, DelayHistory, MeowError, Proxy, ProxyAdapter, ProxyConn, ProxyHealth,
        ProxyPacketConn, Result as MeowResult,
    };
    use smol_str::SmolStr;

    use crate::TEST_SERIAL as SERIAL;

    static SEQ: AtomicU32 = AtomicU32::new(0);

    fn tmp_dir(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("gstore-lan-{tag}-{nanos}-{seq}"));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn free_port() -> u16 {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    }

    /// Fixture tunnel with empty rules (meow Final -> DIRECT).
    fn fixture_tunnel() -> Arc<Tunnel> {
        crate::rules::reset_for_tests();
        crate::conn::reset_for_tests();
        let resolver = Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ));
        let _inner = crate::dispatch::build_engine(resolver);
        crate::rules::active_tunnel().expect("fixture engine")
    }

    fn sync() -> std::sync::MutexGuard<'static, ()> {
        SERIAL.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn cleanup() {
        reset_for_tests();
        crate::rules::reset_for_tests();
        crate::conn::reset_for_tests();
    }

    /// Recording outbound: captures each dial's target and returns `NotSupported`
    /// (so the relay closes immediately after the SOCKS4 grant).
    struct RecordingProxy {
        name: String,
        health: ProxyHealth,
        dials: Mutex<Vec<String>>,
    }

    impl RecordingProxy {
        fn new(name: &str) -> Arc<Self> {
            Arc::new(Self {
                name: name.to_string(),
                health: ProxyHealth::new(),
                dials: Mutex::new(Vec::new()),
            })
        }

        fn targets(&self) -> Vec<String> {
            self.dials.lock().unwrap_or_else(|e| e.into_inner()).clone()
        }
    }

    #[async_trait]
    impl ProxyAdapter for RecordingProxy {
        fn name(&self) -> &str {
            &self.name
        }
        fn adapter_type(&self) -> AdapterType {
            AdapterType::Direct
        }
        fn addr(&self) -> &str {
            ""
        }
        fn support_udp(&self) -> bool {
            false
        }
        async fn dial_tcp(&self, metadata: &Metadata) -> MeowResult<Box<dyn ProxyConn>> {
            let target = if !metadata.host.is_empty() {
                metadata.host.to_string()
            } else {
                metadata
                    .dst_ip
                    .map(|ip| ip.to_string())
                    .unwrap_or_default()
            };
            self.dials
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(format!("{target}:{}", metadata.dst_port));
            Err(MeowError::NotSupported("recording".into()))
        }
        async fn dial_udp(&self, _metadata: &Metadata) -> MeowResult<Box<dyn ProxyPacketConn>> {
            Err(MeowError::NotSupported("recording".into()))
        }
        fn health(&self) -> &ProxyHealth {
            &self.health
        }
    }

    impl Proxy for RecordingProxy {
        fn alive(&self) -> bool {
            true
        }
        fn alive_for_url(&self, _url: &str) -> bool {
            true
        }
        fn last_delay(&self) -> u16 {
            0
        }
        fn last_delay_for_url(&self, _url: &str) -> u16 {
            0
        }
        fn delay_history(&self) -> Vec<DelayHistory> {
            Vec::new()
        }
    }

    /// Install a `MATCH,<name>` rule and a named recording outbound.
    fn install_recording(name: &str, dir: &std::path::Path) -> Arc<RecordingProxy> {
        let yaml = format!("rules:\n  - MATCH,{name}\n");
        let payload = serde_json::to_vec(&serde_json::json!({ "config": yaml })).unwrap();
        crate::rules::reload(dir.to_str().unwrap(), dir.to_str().unwrap(), &payload).unwrap();
        let proxy = RecordingProxy::new(name);
        let mut map: HashMap<SmolStr, Arc<dyn Proxy>> = HashMap::new();
        map.insert(SmolStr::from(name), Arc::clone(&proxy) as Arc<dyn Proxy>);
        let tunnel = crate::rules::active_tunnel().unwrap();
        crate::nodes::install_proxies(&tunnel, map);
        proxy
    }

    async fn connect(port: u16) -> TcpStream {
        TcpStream::connect(("127.0.0.1", port))
            .await
            .expect("connect to LAN listener")
    }

    fn socks4_request(dst_ip: Ipv4Addr, port: u16) -> Vec<u8> {
        let mut req = vec![0x04, 0x01];
        req.extend_from_slice(&port.to_be_bytes());
        req.extend_from_slice(&dst_ip.octets());
        req.push(0); // empty USERID
        req
    }

    fn socks4a_request(host: &str, port: u16) -> Vec<u8> {
        let mut req = vec![0x04, 0x01];
        req.extend_from_slice(&port.to_be_bytes());
        req.extend_from_slice(&[0, 0, 0, 1]); // SOCKS4a marker
        req.push(0); // empty USERID
        req.extend_from_slice(host.as_bytes());
        req.push(0);
        req
    }

    /// Default: OFF, port 1087, 0.0.0.0 bind, no auth, empty allow-list.
    #[test]
    fn default_config_is_off() {
        let _g = sync();
        cleanup();
        let config = get();
        assert!(!config.enabled);
        assert_eq!(config.port, 1087);
        assert_eq!(config.bind_address, "0.0.0.0");
        assert!(config.auth.is_none());
        assert!(config.allowed_ips.is_empty());
        let status = status_json();
        assert_eq!(status["enabled"], false);
        assert_eq!(status["bound"], false);
        assert_eq!(status["addresses"].as_array().unwrap().len(), 0);
        assert_eq!(status["activeConns"], 0);
        // Loopback is always exempt from auth.
        let with_auth = LanConfig {
            enabled: true,
            auth: Some(LanAuth {
                user: "u".into(),
                pass: "p".into(),
            }),
            ..LanConfig::default()
        };
        let auth = with_auth.auth_config().unwrap();
        assert!(auth.should_skip(&IpAddr::from_str("127.0.0.1").unwrap()));
        assert!(auth.should_skip(&IpAddr::from_str("::1").unwrap()));
        assert!(!auth.should_skip(&IpAddr::from_str("192.0.2.9").unwrap()));
    }

    /// Enabling binds the configured port and status reports it; disabling
    /// refuses new connections.
    #[test]
    fn enabling_binds_configured_port_and_disabling_refuses() {
        let _g = sync();
        cleanup();
        let dir = tmp_dir("bind");
        let port = free_port();
        let payload = serde_json::to_vec(&serde_json::json!({
            "enabled": true,
            "port": port,
            "bindAddress": "127.0.0.1",
        }))
        .unwrap();
        let config = set(dir.to_str().unwrap(), dir.to_str().unwrap(), &payload).unwrap();
        assert!(config.enabled);
        let status = status_json();
        assert_eq!(status["enabled"], true);
        assert_eq!(status["bound"], true);
        assert_eq!(status["port"], port);
        let address = status["addresses"][0].as_str().unwrap();
        assert!(address.starts_with(&format!("127.0.0.1:{port}")));
        // The socket is really listening.
        std::net::TcpStream::connect(("127.0.0.1", port)).expect("bound port accepts");

        let off = serde_json::to_vec(&serde_json::json!({ "enabled": false })).unwrap();
        set(dir.to_str().unwrap(), dir.to_str().unwrap(), &off).unwrap();
        assert_eq!(status_json()["bound"], false);
        let refused = std::net::TcpStream::connect(("127.0.0.1", port));
        assert!(refused.is_err(), "disabled listener must refuse connections");

        cleanup();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A source outside `allowedIps` is dropped before dispatch; an allowed
    /// source is served.
    #[tokio::test]
    async fn allow_list_rejects_non_listed_source() {
        let _g = sync();
        cleanup();
        let dir = tmp_dir("allow");
        let tunnel = fixture_tunnel();
        let proxy = install_recording("REC", &dir);
        let port = free_port();

        let payload = serde_json::to_vec(&serde_json::json!({
            "enabled": true, "port": port, "bindAddress": "127.0.0.1",
            "allowedIps": ["192.0.2.0/24"],
        }))
        .unwrap();
        set(dir.to_str().unwrap(), dir.to_str().unwrap(), &payload).unwrap();

        // Not allowed: connection is closed with no SOCKS reply.
        let mut blocked = connect(port).await;
        blocked.write_all(&socks4_request(Ipv4Addr::new(93, 184, 216, 34), 80)).await.unwrap();
        let mut buf = [0u8; 8];
        let n = tokio::time::timeout(Duration::from_secs(2), blocked.read(&mut buf))
            .await
            .expect("read must not hang")
            .unwrap_or(0);
        assert_eq!(n, 0, "rejected source must see EOF, got {n} bytes");
        assert!(proxy.targets().is_empty());

        // Allowed: loopback in the list, SOCKS4 is served.
        let allow = serde_json::to_vec(&serde_json::json!({ "allowedIps": ["127.0.0.0/8"] })).unwrap();
        set(dir.to_str().unwrap(), dir.to_str().unwrap(), &allow).unwrap();
        let _ = Arc::clone(&tunnel);
        let mut ok = connect(port).await;
        ok.write_all(&socks4_request(Ipv4Addr::new(1, 2, 3, 4), 443)).await.unwrap();
        let mut reply = [0u8; 8];
        tokio::time::timeout(Duration::from_secs(2), ok.read_exact(&mut reply))
            .await
            .expect("reply must arrive")
            .unwrap();
        assert_eq!(reply[1], 0x5A, "allowed source must be granted");

        cleanup();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// SOCKS4 CONNECT (IP) and SOCKS4a (hostname) both reach the selected
    /// outbound with the right target.
    #[tokio::test]
    async fn socks4_and_4a_route_through_selected_outbound() {
        let _g = sync();
        cleanup();
        let dir = tmp_dir("socks4");
        let tunnel = fixture_tunnel();
        let proxy = install_recording("FIXTURE", &dir);
        let port = free_port();
        let payload = serde_json::to_vec(&serde_json::json!({
            "enabled": true, "port": port, "bindAddress": "127.0.0.1"
        }))
        .unwrap();
        set(dir.to_str().unwrap(), dir.to_str().unwrap(), &payload).unwrap();
        let _ = Arc::clone(&tunnel);

        // SOCKS4 CONNECT with an IPv4 target.
        let mut ip_client = connect(port).await;
        ip_client
            .write_all(&socks4_request(Ipv4Addr::new(203, 0, 113, 7), 8443))
            .await
            .unwrap();
        let mut reply = [0u8; 8];
        tokio::time::timeout(Duration::from_secs(2), ip_client.read_exact(&mut reply))
            .await
            .expect("socks4 reply")
            .unwrap();
        assert_eq!(reply[1], 0x5A);

        // SOCKS4a CONNECT with a hostname.
        let mut name_client = connect(port).await;
        name_client
            .write_all(&socks4a_request("fixture.example", 9443))
            .await
            .unwrap();
        let mut reply2 = [0u8; 8];
        tokio::time::timeout(Duration::from_secs(2), name_client.read_exact(&mut reply2))
            .await
            .expect("socks4a reply")
            .unwrap();
        assert_eq!(reply2[1], 0x5A);

        // Give the relay tasks a beat to record the dials.
        tokio::time::sleep(Duration::from_millis(150)).await;
        let targets = proxy.targets();
        assert!(
            targets.iter().any(|t| t == "203.0.113.7:8443"),
            "SOCKS4 IP target must reach the selected outbound: {targets:?}"
        );
        assert!(
            targets.iter().any(|t| t == "fixture.example:9443"),
            "SOCKS4a hostname must reach the selected outbound: {targets:?}"
        );

        cleanup();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Fixture HTTP server returning a fixed marker.
    async fn fixture_http() -> (SocketAddr, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                tokio::spawn(async move {
                    let mut buf = [0u8; 2048];
                    let _ = stream.read(&mut buf).await;
                    let body = "GSTORE_LAN_FIXTURE_MARKER";
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = stream.write_all(response.as_bytes()).await;
                    let _ = stream.flush().await;
                });
            }
        });
        (addr, handle)
    }

    /// SOCKS5 and HTTP CONNECT both proxy a real request through the tunnel.
    #[tokio::test]
    async fn socks5_and_http_connect_succeed_through_direct() {
        let _g = sync();
        cleanup();
        let dir = tmp_dir("direct");
        fixture_tunnel();
        let (fixture, fixture_task) = fixture_http().await;
        let port = free_port();
        let payload = serde_json::to_vec(&serde_json::json!({
            "enabled": true, "port": port, "bindAddress": "127.0.0.1"
        }))
        .unwrap();
        set(dir.to_str().unwrap(), dir.to_str().unwrap(), &payload).unwrap();

        // --- SOCKS5 (no auth): [VER, NMETHODS, METHODS] then CONNECT IPv4 ---
        let mut socks = connect(port).await;
        socks.write_all(&[0x05, 0x01, 0x00]).await.unwrap();
        let mut greeting = [0u8; 2];
        socks.read_exact(&mut greeting).await.unwrap();
        assert_eq!(greeting, [0x05, 0x00], "SOCKS5 no-auth negotiated");
        let mut connect_req = vec![0x05, 0x01, 0x00, 0x01];
        connect_req
            .extend_from_slice(&fixture.ip().to_string().parse::<Ipv4Addr>().unwrap().octets());
        connect_req.extend_from_slice(&fixture.port().to_be_bytes());
        socks.write_all(&connect_req).await.unwrap();
        let mut reply = [0u8; 10];
        socks.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply[1], 0x00, "SOCKS5 CONNECT granted");
        let request = format!("GET / HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n", fixture);
        socks.write_all(request.as_bytes()).await.unwrap();
        let mut body = Vec::new();
        tokio::time::timeout(Duration::from_secs(3), socks.read_to_end(&mut body))
            .await
            .expect("socks5 response")
            .unwrap();
        assert!(
            String::from_utf8_lossy(&body).contains("GSTORE_LAN_FIXTURE_MARKER"),
            "SOCKS5 body: {}",
            String::from_utf8_lossy(&body)
        );

        // --- HTTP forward proxy (absolute-form GET) ---
        let mut http = connect(port).await;
        let request = format!(
            "GET http://{fixture}/ HTTP/1.1\r\nHost: {fixture}\r\nConnection: close\r\n\r\n"
        );
        http.write_all(request.as_bytes()).await.unwrap();
        let mut body = Vec::new();
        tokio::time::timeout(Duration::from_secs(3), http.read_to_end(&mut body))
            .await
            .expect("http response")
            .unwrap();
        assert!(
            String::from_utf8_lossy(&body).contains("GSTORE_LAN_FIXTURE_MARKER"),
            "HTTP body: {}",
            String::from_utf8_lossy(&body)
        );

        fixture_task.abort();
        cleanup();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Engine-only mode: with **no** live tunnel the listener builds its own
    /// engine and still proxies a request (works without the VPN/TUN).
    #[tokio::test]
    async fn engine_only_serves_without_a_tunnel() {
        let _g = sync();
        cleanup();
        assert!(
            crate::rules::active_tunnel().is_none(),
            "precondition: no live tunnel"
        );
        let dir = tmp_dir("engine-only");
        let (fixture, fixture_task) = fixture_http().await;
        let port = free_port();
        let payload = serde_json::to_vec(&serde_json::json!({
            "enabled": true, "port": port, "bindAddress": "127.0.0.1"
        }))
        .unwrap();
        set(dir.to_str().unwrap(), dir.to_str().unwrap(), &payload).unwrap();
        let status = status_json();
        assert_eq!(status["bound"], true);
        assert_eq!(status["engineOnly"], true, "listener must have built its own engine");

        let mut socks = connect(port).await;
        socks.write_all(&[0x05, 0x01, 0x00]).await.unwrap();
        let mut greeting = [0u8; 2];
        socks.read_exact(&mut greeting).await.unwrap();
        assert_eq!(greeting, [0x05, 0x00]);
        let mut connect_req = vec![0x05, 0x01, 0x00, 0x01];
        connect_req
            .extend_from_slice(&fixture.ip().to_string().parse::<Ipv4Addr>().unwrap().octets());
        connect_req.extend_from_slice(&fixture.port().to_be_bytes());
        socks.write_all(&connect_req).await.unwrap();
        let mut reply = [0u8; 10];
        socks.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply[1], 0x00);
        let request = format!("GET / HTTP/1.1\r\nHost: {fixture}\r\nConnection: close\r\n\r\n");
        socks.write_all(request.as_bytes()).await.unwrap();
        let mut body = Vec::new();
        tokio::time::timeout(Duration::from_secs(3), socks.read_to_end(&mut body))
            .await
            .expect("engine-only socks5 response")
            .unwrap();
        assert!(
            String::from_utf8_lossy(&body).contains("GSTORE_LAN_FIXTURE_MARKER"),
            "engine-only body: {}",
            String::from_utf8_lossy(&body)
        );

        fixture_task.abort();
        cleanup();
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn auth_config_for(user: &str, pass: &str) -> Arc<AuthConfig> {
        let config = LanConfig {
            enabled: true,
            auth: Some(LanAuth {
                user: user.into(),
                pass: pass.into(),
            }),
            ..LanConfig::default()
        };
        config.auth_config().unwrap()
    }

    fn rfc1929(user: &str, pass: &str) -> Vec<u8> {
        let mut out = vec![0x01, user.len() as u8];
        out.extend_from_slice(user.as_bytes());
        out.push(pass.len() as u8);
        out.extend_from_slice(pass.as_bytes());
        out
    }

    /// A non-exempt (non-loopback) peer is challenged; wrong credentials are
    /// rejected, correct credentials are accepted.
    #[tokio::test]
    async fn wrong_auth_is_rejected() {
        let _g = sync();
        cleanup();
        fixture_tunnel();
        let auth = auth_config_for("alice", "secret");

        // Synthetic non-loopback source so meow's auth is actually enforced.
        let src: SocketAddr = "192.0.2.9:4444".parse().unwrap();

        // --- SOCKS5 wrong password -> [0x01, 0x01] ---
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server_addr = listener.local_addr().unwrap();
        let tunnel = crate::rules::active_tunnel().unwrap();
        let auth_for_first = Arc::clone(&auth);
        let accept = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            handle_stream(Arc::clone(&tunnel), stream, src, Some(Arc::clone(&auth_for_first)), 1087).await;
        });
        let mut client = TcpStream::connect(server_addr).await.unwrap();
        client.write_all(&[0x05, 0x01, 0x02]).await.unwrap();
        let mut method = [0u8; 2];
        client.read_exact(&mut method).await.unwrap();
        assert_eq!(method, [0x05, 0x02], "server must request user/pass auth");
        client.write_all(&rfc1929("alice", "WRONG")).await.unwrap();
        let mut status = [0u8; 2];
        client.read_exact(&mut status).await.unwrap();
        assert_eq!(status, [0x01, 0x01], "wrong password must be rejected");
        let _ = accept.await;

        // --- SOCKS5 correct password -> [0x01, 0x00], then CONNECT succeeds ---
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server_addr = listener.local_addr().unwrap();
        let tunnel = crate::rules::active_tunnel().unwrap();
        let auth2 = Arc::clone(&auth);
        let accept = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            handle_stream(Arc::clone(&tunnel), stream, src, Some(Arc::clone(&auth2)), 1087).await;
        });
        let mut client = TcpStream::connect(server_addr).await.unwrap();
        client.write_all(&[0x05, 0x01, 0x02]).await.unwrap();
        let mut method = [0u8; 2];
        client.read_exact(&mut method).await.unwrap();
        assert_eq!(method, [0x05, 0x02]);
        client.write_all(&rfc1929("alice", "secret")).await.unwrap();
        let mut status = [0u8; 2];
        client.read_exact(&mut status).await.unwrap();
        assert_eq!(status, [0x01, 0x00], "correct password must be accepted");
        let _ = accept.await;

        cleanup();
    }

    /// HTTP CONNECT from a non-exempt peer without credentials gets 407.
    #[tokio::test]
    async fn http_connect_without_auth_is_407() {
        let _g = sync();
        cleanup();
        fixture_tunnel();
        let auth = auth_config_for("alice", "secret");
        let src: SocketAddr = "192.0.2.9:4444".parse().unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server_addr = listener.local_addr().unwrap();
        let tunnel = crate::rules::active_tunnel().unwrap();
        let accept = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            handle_stream(tunnel, stream, src, Some(auth), 1087).await;
        });
        let mut client = TcpStream::connect(server_addr).await.unwrap();
        client
            .write_all(b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
            .await
            .unwrap();
        let mut head = [0u8; 64];
        let n = tokio::time::timeout(Duration::from_secs(2), client.read(&mut head))
            .await
            .expect("407 must arrive")
            .unwrap();
        let text = String::from_utf8_lossy(&head[..n]);
        assert!(text.starts_with("HTTP/1.1 407"), "expected 407, got: {text}");
        let _ = accept.await;
        cleanup();
    }

    /// Enabling without auth surfaces the warning; bad config is a structured
    /// 422.
    #[test]
    fn warning_and_invalid_config() {
        let _g = sync();
        cleanup();
        let dir = tmp_dir("warn");
        let payload = serde_json::to_vec(&serde_json::json!({
            "enabled": true, "port": free_port(), "bindAddress": "127.0.0.1"
        }))
        .unwrap();
        let config = set(dir.to_str().unwrap(), dir.to_str().unwrap(), &payload).unwrap();
        let warning = warning_for(&config).expect("no-auth warning");
        assert_eq!(warning["code"], WARN_LAN_NO_AUTH);
        assert_eq!(get_json()["warning"]["code"], WARN_LAN_NO_AUTH);

        // Invalid CIDR -> structured error, config unchanged.
        let bad = serde_json::to_vec(&serde_json::json!({ "allowedIps": ["not-a-cidr"] })).unwrap();
        let err = set(dir.to_str().unwrap(), dir.to_str().unwrap(), &bad).unwrap_err();
        assert_eq!(err.code, ERR_LAN_CONFIG_INVALID);
        assert_eq!(err.status, StatusCode::InvalidArgument);

        // Invalid bind address -> structured error.
        let bad_bind = serde_json::to_vec(&serde_json::json!({ "bindAddress": "nope" })).unwrap();
        let err = set(dir.to_str().unwrap(), dir.to_str().unwrap(), &bad_bind).unwrap_err();
        assert_eq!(err.code, ERR_LAN_CONFIG_INVALID);

        // Auth clears the warning.
        let with_auth = serde_json::to_vec(&serde_json::json!({
            "auth": { "user": "u", "pass": "p" }
        }))
        .unwrap();
        let config = set(dir.to_str().unwrap(), dir.to_str().unwrap(), &with_auth).unwrap();
        assert!(warning_for(&config).is_none());

        cleanup();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A blocking fixture HTTP server (std threads) so the harness can drive
    /// `curl` without a Tokio runtime being starved by the blocking process call.
    fn spawn_blocking_fixture() -> SocketAddr {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            use std::io::{Read as _, Write as _};
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { break };
                std::thread::spawn(move || {
                    let mut buf = [0u8; 2048];
                    let _ = stream.read(&mut buf);
                    let body = "GSTORE_LAN_FIXTURE_MARKER";
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = stream.write_all(response.as_bytes());
                    let _ = stream.flush();
                });
            }
        });
        addr
    }

    /// Host harness: real `curl --socks4/--socks5` and `curl -x http://` through
    /// the listener. Run explicitly:
    /// `cargo test -p gstore_mod_proxy lan_curl_host_harness -- --ignored --nocapture`
    #[test]
    #[ignore = "host QA harness: drives the real curl binary against port 1087"]
    fn lan_curl_host_harness() {
        let _g = sync();
        cleanup();
        let dir = tmp_dir("curl");
        fixture_tunnel();
        let fixture = spawn_blocking_fixture();
        let port = 1087u16;
        let payload = serde_json::to_vec(&serde_json::json!({
            "enabled": true, "port": port, "bindAddress": "127.0.0.1"
        }))
        .unwrap();
        set(dir.to_str().unwrap(), dir.to_str().unwrap(), &payload).unwrap();

        let url = format!("http://{fixture}/");
        for args in [
            vec!["--socks4", "127.0.0.1:1087", url.as_str()],
            vec!["--socks5", "127.0.0.1:1087", url.as_str()],
            vec!["-x", "http://127.0.0.1:1087", url.as_str()],
        ] {
            let output = std::process::Command::new("curl")
                .args(&args)
                .arg("-sS")
                .arg("--max-time")
                .arg("10")
                .output()
                .expect("run curl");
            let stdout = String::from_utf8_lossy(&output.stdout);
            eprintln!("curl {:?} -> status={} body={}", args, output.status, stdout);
            assert!(
                stdout.contains("GSTORE_LAN_FIXTURE_MARKER"),
                "curl {:?} must return the fixture marker, got: {stdout}",
                args
            );
        }

        cleanup();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
