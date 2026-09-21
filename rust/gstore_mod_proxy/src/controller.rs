//! Optional loopback Clash-compatible diagnostics controller (Todo 18).
//!
//! **We do not author a controller.** meow already ships a mihomo-compatible
//! REST/WebSocket controller (`meow-api`; coverage table in meow's
//! `docs/mihomo-api-compatibility.md`). This module only *embeds* it:
//!
//! * **OFF by default.** Nothing is started at `create` / `core.start`. A
//!   developer (or a diagnostic build) must call `diagnostics.clash_api.start`.
//! * **Loopback only.** The listener is always bound to `127.0.0.1`, never
//!   `0.0.0.0`; there is no code path that accepts a bind host from the caller.
//! * **Random per-run secret.** A fresh 128-bit UUIDv4 secret is generated on
//!   every start and enforced by meow's `require_auth` middleware
//!   (`Authorization: Bearer <secret>`). It is **never** returned by any method,
//!   never emitted as an event, and never written to a log line. The only way to
//!   read it is the app-private file `<data_dir>/.clash_api_secret` (mode `0600`
//!   on unix), which exists for on-device diagnostics only.
//!
//! **The Flutter UI never speaks this API.** FRB/envelope (`core.*`,
//! `stats.*`, …) is the only contract Dart uses for normal operation; a Dart
//! HTTP client against the Clash API would move logic into Dart. This is a
//! diagnostics-only, best-effort side channel (like meow's `external-controller`
//! but explicitly loopback + secret).
//!
//! The server runs on its own dedicated OS thread with a bounded
//! [`crate::bounded_runtime`] (`worker_threads(4)`), never `Runtime::new()` /
//! CPU-default workers. Graceful shutdown drops the listener and joins the
//! thread, so `stop` is deterministic and repeatable (required for the
//! 5-consecutive-parallel-run test gate).

use std::net::SocketAddr;
use std::sync::{Mutex, OnceLock};

use gstore_contract::error::{ModuleError, StatusCode};
use meow_tunnel::Tunnel;

/// Domain error code for a controller that could not be (re)started.
pub(crate) const ERR_CLASH_API_FAILED: &str = "PROXY_CLASH_API_FAILED";

/// The only bind host this module will ever use. Deliberately a constant so no
/// caller-supplied value can widen the exposure.
const LOOPBACK_HOST: &str = "127.0.0.1";

/// App-private file the per-run secret is written to (diagnostics only).
const SECRET_FILE: &str = ".clash_api_secret";

/// A running diagnostics controller.
struct Running {
    addr: SocketAddr,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

static RUNNING: OnceLock<Mutex<Option<Running>>> = OnceLock::new();

fn running() -> &'static Mutex<Option<Running>> {
    RUNNING.get_or_init(|| Mutex::new(None))
}

/// Public (non-secret) status of the loopback diagnostics controller.
///
/// Note the deliberate absence of any `secret` field: the contract can never
/// leak it, and a test asserts the serialized shape has no secret-shaped key.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ClashApiStatus {
    /// Whether a controller is currently running.
    pub enabled: bool,
    /// Whether the listener actually bound (always equals `enabled` here).
    pub bound: bool,
    /// `127.0.0.1:<port>` when running.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub address: Option<String>,
    /// Always `true`; the bind host is a hard-coded loopback literal.
    pub loopback_only: bool,
    /// Bound port when running (for diagnostics).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
}

fn status_of(addr: SocketAddr) -> ClashApiStatus {
    ClashApiStatus {
        enabled: true,
        bound: true,
        address: Some(addr.to_string()),
        loopback_only: true,
        port: Some(addr.port()),
    }
}

/// Current status (never includes the secret).
pub(crate) fn status() -> ClashApiStatus {
    let guard = running().lock().unwrap_or_else(|e| e.into_inner());
    match guard.as_ref() {
        Some(r) => status_of(r.addr),
        None => ClashApiStatus {
            enabled: false,
            bound: false,
            address: None,
            loopback_only: true,
            port: None,
        },
    }
}

/// Generate a fresh 128-bit per-run secret (hex, no dashes).
fn new_secret() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

/// Persist the secret to the app-private data dir with mode `0600` (unix).
///
/// Best-effort: a missing/unwritable data dir only loses the diagnostic file,
/// never the server. The secret is never logged and never returned.
fn persist_secret(data_dir: &str, secret: &str) {
    let dir = data_dir.trim();
    if dir.is_empty() {
        return;
    }
    let path = format!("{}/{}", dir.trim_end_matches('/'), SECRET_FILE);
    #[cfg(unix)]
    {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&path)
        {
            let _ = f.write_all(secret.as_bytes());
            let _ = f.flush();
        }
    }
    #[cfg(not(unix))]
    {
        let _ = std::fs::write(&path, secret);
    }
}

/// Start (or restart) the loopback controller against `tunnel`.
///
/// `port == 0` asks the OS for an ephemeral port (the returned status carries
/// the actual one). Always binds `127.0.0.1`. Replaces any previous instance.
pub(crate) fn start(
    port: u16,
    data_dir: &str,
    tunnel: Tunnel,
) -> Result<ClashApiStatus, ModuleError> {
    // Replace any previous controller: a diagnostics restart must not leak a
    // listener or a thread.
    stop();

    let secret = new_secret();
    let (addr_tx, addr_rx) = std::sync::mpsc::channel::<Result<SocketAddr, String>>();
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let secret_for_thread = secret.clone();

    let thread = std::thread::Builder::new()
        .name("gstore-clash-api".to_string())
        .spawn(move || {
            let rt = match crate::bounded_runtime() {
                Ok(rt) => rt,
                Err(e) => {
                    let _ = addr_tx.send(Err(format!("bounded_runtime: {e}")));
                    return;
                }
            };
            rt.block_on(async move {
                // Bind synchronously so the real (ephemeral) address is known
                // before the server future is polled.
                let std_listener = match std::net::TcpListener::bind((LOOPBACK_HOST, port)) {
                    Ok(l) => l,
                    Err(e) => {
                        let _ = addr_tx.send(Err(format!("bind {LOOPBACK_HOST}:{port}: {e}")));
                        return;
                    }
                };
                if let Err(e) = std_listener.set_nonblocking(true) {
                    let _ = addr_tx.send(Err(format!("set_nonblocking: {e}")));
                    return;
                }
                let addr = match std_listener.local_addr() {
                    Ok(a) => a,
                    Err(e) => {
                        let _ = addr_tx.send(Err(format!("local_addr: {e}")));
                        return;
                    }
                };
                let listener = match tokio::net::TcpListener::from_std(std_listener) {
                    Ok(l) => l,
                    Err(e) => {
                        let _ = addr_tx.send(Err(format!("tokio listener: {e}")));
                        return;
                    }
                };

                // Keep the receiver alive for the server's lifetime.
                let (log_tx, _log_rx) = tokio::sync::broadcast::channel(128);
                let state = meow_api::routes::AppState {
                    tunnel,
                    secret: Some(secret_for_thread),
                    config_path: String::new(),
                    raw_config: Default::default(),
                    log_tx,
                    proxy_providers: Default::default(),
                    rule_providers: Default::default(),
                    listeners: Vec::new(),
                    external_ui: None,
                    config_mutation_lock: tokio::sync::Mutex::new(()),
                    traffic_feed: Default::default(),
                    dns_server: Default::default(),
                };
                let app = meow_api::routes::create_router(std::sync::Arc::new(state));

                let _ = addr_tx.send(Ok(addr));
                let shutdown = async move {
                    let _ = shutdown_rx.await;
                };
                if let Err(e) =
                    axum::serve(listener, app).with_graceful_shutdown(shutdown).await
                {
                    crate::log_message(2, &format!("proxy.clash_api: server stopped: {e}"));
                }
            });
        })
        .map_err(|e| {
            ModuleError::new(
                StatusCode::InternalError,
                ERR_CLASH_API_FAILED,
                format!("clash api thread spawn failed: {e}"),
            )
        })?;

    let addr = match addr_rx.recv_timeout(std::time::Duration::from_secs(5)) {
        Ok(Ok(a)) => a,
        Ok(Err(e)) => {
            let _ = thread.join();
            return Err(ModuleError::new(
                StatusCode::InternalError,
                ERR_CLASH_API_FAILED,
                format!("clash api bind failed: {e}"),
            ));
        }
        Err(_) => {
            let _ = thread.join();
            return Err(ModuleError::new(
                StatusCode::InternalError,
                ERR_CLASH_API_FAILED,
                "clash api did not bind within 5s",
            ));
        }
    };

    // Diagnostics-only: the secret is written 0600 in the app sandbox and never
    // logged/returned/emitted.
    persist_secret(data_dir, &secret);
    crate::log_message(
        1,
        &format!(
            "proxy.clash_api: bound 127.0.0.1:{} (loopbackOnly=true, secret=redacted)",
            addr.port()
        ),
    );

    *running().lock().unwrap_or_else(|e| e.into_inner()) = Some(Running {
        addr,
        shutdown: Some(shutdown_tx),
        thread: Some(thread),
    });
    Ok(status_of(addr))
}

/// Stop the controller if running. Returns whether one was running. Idempotent.
pub(crate) fn stop() -> bool {
    let taken = running().lock().unwrap_or_else(|e| e.into_inner()).take();
    let Some(mut r) = taken else { return false };
    if let Some(tx) = r.shutdown.take() {
        let _ = tx.send(());
    }
    if let Some(thread) = r.thread.take() {
        let _ = thread.join();
    }
    crate::log_message(1, "proxy.clash_api: stopped");
    true
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::TEST_SERIAL as SERIAL;

    fn fixture_tunnel() -> Tunnel {
        crate::rules::reset_for_tests();
        crate::conn::reset_for_tests();
        let resolver = std::sync::Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ));
        let _engine = crate::dispatch::build_engine(resolver);
        let tunnel = crate::rules::active_tunnel().expect("fixture engine");
        (*tunnel).clone()
    }

    /// Default state is OFF: no listener, no secret file.
    #[test]
    fn default_status_is_disabled() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        stop();
        let s = status();
        assert!(!s.enabled);
        assert!(!s.bound);
        assert!(s.address.is_none());
        assert!(s.loopback_only);
    }

    /// Happy path: start on an ephemeral loopback port, prove the address is a
    /// `127.0.0.1` literal, the secret file exists and is not part of any
    /// returned status, then stop deterministically.
    #[test]
    fn start_binds_loopback_and_never_exports_secret() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("gstore-clash-api-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();

        let tunnel = fixture_tunnel();
        let s = start(0, dir.to_str().unwrap(), tunnel).expect("start");
        assert!(s.enabled && s.bound);
        assert!(s.loopback_only);
        let addr = s.address.as_deref().expect("address");
        assert!(addr.starts_with("127.0.0.1:"), "must bind loopback only: {addr}");
        assert!(!addr.contains("0.0.0.0"));

        // The serialized status must never contain a secret.
        let json = serde_json::to_string(&s).unwrap();
        for forbidden in ["secret", "token", "password", "authorization"] {
            assert!(
                !json.to_lowercase().contains(forbidden),
                "status leaked a secret-shaped key: {json}"
            );
        }

        // The per-run secret is only in the 0600 app-private file.
        let secret_path = dir.join(SECRET_FILE);
        let secret = std::fs::read_to_string(&secret_path).expect("secret file");
        assert_eq!(secret.len(), 32, "uuidv4 simple hex is 32 chars");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(&secret_path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600, "secret file must be 0600");
        }

        // Starting again replaces the previous listener + thread.
        let s2 = start(0, dir.to_str().unwrap(), fixture_tunnel()).expect("restart");
        assert_ne!(s.address, s2.address, "restart must rebind");

        assert!(stop(), "stop reports it was running");
        assert!(!status().enabled);
        assert!(!stop(), "second stop is a no-op");
        stop();
        crate::conn::reset_for_tests();
        crate::rules::reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
