//! MITM certificate authority: CA lifecycle + bounded per-host leaf issuance.
//!
//! Todo 3 of `.omo/plans/proxy-http-capture.md`. This module owns **only** the
//! certificate primitives the later MITM data path (SNI cert resolver, TLS
//! termination, HTTP/WS capture) builds on:
//!
//!  * a self-signed ECDSA P-256 CA persisted as `<dataDir>/mitm/ca.pem` +
//!    `<dataDir>/mitm/ca.key` (key file mode `0600` on unix),
//!  * per-host leaf certificates (`CN=host`, `SAN dNSName=host`, EKU
//!    `serverAuth`, AKI extension, random serial) signed by that CA,
//!  * a **bounded** per-host [`rustls::ServerConfig`] cache so a keep-alive /
//!    reconnect storm for the same host signs exactly once per CA epoch.
//!
//! ## Bounds & failure semantics
//!
//! * The leaf cache is a `Mutex<HashMap>` capped at
//!   [`crate::limits::MITM_CERT_CACHE_CAP`]; when the cap is exceeded the entry
//!   with the smallest monotonic sequence (the oldest) is evicted. Every
//!   eviction is counted. A leaf whose estimated footprint exceeds
//!   [`crate::limits::MITM_CERT_ENTRY_MAX_BYTES`] is served but **not cached**,
//!   so the memory budget can never be under-counted (expiry can never happen).
//! * A **corrupted or missing** `ca.pem`/`ca.key` is treated exactly like "no CA
//!   generated": [`CertificateAuthority::load`] returns `Ok(None)` and never
//!   panics.
//! * The CA private key is written but **never logged** and never placed in an
//!   event payload.
//!
//! ## rcgen feature note
//!
//! The crate pins `rcgen` with `default-features = false, features = ["crypto",
//! "aws_lc_rs"]` (SPIKE.md §11), so rcgen's optional `pem` and `x509-parser`
//! features are **off** and `Certificate::pem()` / `Issuer::from_ca_cert_pem`
//! are unavailable. PEM encode/decode is therefore done locally with the
//! already-direct `base64` crate, and on reload the issuer is rebuilt from the
//! same deterministic [`ca_params`] used at generation time (identical subject
//! DN, key usages and `KeyIdMethod::Sha256`), which keeps the leaf issuer name
//! and Authority Key Identifier consistent with the persisted CA.

use std::collections::HashMap;
use std::net::IpAddr;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use meow_common::{ConnType, Metadata, Network, ProxyConn};
use rcgen::{
    BasicConstraints, CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    KeyUsagePurpose, SerialNumber,
};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::server::{ClientHello, ResolvesServerCert, ServerConfig};
use rustls::sign::CertifiedKey;
use rustls::{ClientConfig, DigitallySignedStruct, RootCertStore, SignatureScheme};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_rustls::client::TlsStream as ClientTlsStream;
use tokio_rustls::server::TlsStream;
use tokio_rustls::{TlsAcceptor, TlsConnector};

use crate::limits::{MITM_CERT_CACHE_CAP, MITM_CERT_ENTRY_MAX_BYTES, MITM_PEM_BUFFER_MAX_BYTES};

/// Directory under `<dataDir>` holding the CA material.
const MITM_DIR: &str = "mitm";
/// PEM-encoded self-signed CA certificate.
const CA_CERT_FILE: &str = "ca.pem";
/// PKCS#8 PEM-encoded CA private key (mode `0600`).
const CA_KEY_FILE: &str = "ca.key";
/// CA subject common name. Kept stable so a reloaded CA reproduces the same
/// issuer fields without re-parsing the certificate (see module docs).
const CA_COMMON_NAME: &str = "GStore MITM CA";
/// Fixed per-entry accounting overhead: the `ServerConfig`/key/chain plumbing a
/// cached entry retains in addition to the host string and the leaf DER. Real
/// ECDSA entries are far under the cap; the guard exists so an oversized entry
/// is never cached and the memory budget is never under-counted.
const LEAF_ENTRY_FIXED_OVERHEAD: usize = 1024;

/// Errors produced by the CA lifecycle and leaf issuance. Kept local (not a
/// `ModuleError`) because this is a low-level primitive; the dispatch layer
/// (todo 11) maps it to `PROXY_CAPTURE_CA_FAILED`.
#[derive(Debug)]
pub(crate) enum MitmError {
    /// Filesystem failure reading/writing CA material.
    Io(std::io::Error),
    /// rcgen failed to generate/parse a key or sign a certificate.
    Rcgen(rcgen::Error),
    /// rustls rejected the built `ServerConfig`.
    Rustls(rustls::Error),
    /// The data directory is empty or the on-disk state is unusable.
    InvalidState(&'static str),
}

impl std::fmt::Display for MitmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MitmError::Io(e) => write!(f, "mitm io: {e}"),
            MitmError::Rcgen(e) => write!(f, "mitm rcgen: {e}"),
            MitmError::Rustls(e) => write!(f, "mitm rustls: {e}"),
            MitmError::InvalidState(m) => write!(f, "mitm state: {m}"),
        }
    }
}

impl std::error::Error for MitmError {}

impl From<std::io::Error> for MitmError {
    fn from(e: std::io::Error) -> Self {
        MitmError::Io(e)
    }
}

impl From<rcgen::Error> for MitmError {
    fn from(e: rcgen::Error) -> Self {
        MitmError::Rcgen(e)
    }
}

impl From<rustls::Error> for MitmError {
    fn from(e: rustls::Error) -> Self {
        MitmError::Rustls(e)
    }
}

/// One cached per-host leaf: its `ServerConfig`, the `CertifiedKey` the SNI
/// resolver returns, the monotonic sequence used for oldest-first eviction, and
/// the accounted byte size.
struct CachedLeaf {
    config: Arc<ServerConfig>,
    key: Arc<CertifiedKey>,
    seq: u64,
    size_bytes: usize,
}

/// A per-host leaf returned from the cache (or freshly issued): both the
/// single-cert `ServerConfig` (todo 3's `server_config`) and the `CertifiedKey`
/// the SNI resolver needs.
struct LeafEntry {
    config: Arc<ServerConfig>,
    key: Arc<CertifiedKey>,
}

/// Bounded per-host leaf cache. Mirrors the cap+oldest-eviction discipline of
/// [`crate::stats::StatsStore`] (`src/stats.rs:74-117`).
struct LeafCache {
    entries: HashMap<String, CachedLeaf>,
    next_seq: u64,
    evicted: u64,
}

impl LeafCache {
    fn fresh() -> Self {
        Self {
            entries: HashMap::new(),
            next_seq: 0,
            evicted: 0,
        }
    }

    /// Insert an entry, assigning it the next sequence, then evict the oldest
    /// entries until the cap is met. Returns the number evicted by this call.
    fn insert(&mut self, host: String, entry: CachedLeaf) -> u64 {
        let seq = self.next_seq;
        self.next_seq += 1;
        self.entries.insert(host, CachedLeaf { seq, ..entry });
        let mut evicted_now = 0;
        while self.entries.len() > MITM_CERT_CACHE_CAP {
            let victim = self
                .entries
                .iter()
                .min_by_key(|(_, e)| e.seq)
                .map(|(k, _)| k.clone());
            match victim {
                Some(k) => {
                    self.entries.remove(&k);
                    self.evicted += 1;
                    evicted_now += 1;
                }
                None => break,
            }
        }
        evicted_now
    }

    fn clear(&mut self) {
        self.entries.clear();
        // Do not reset `next_seq`/`evicted`: sequences must stay monotonic
        // across a reset so an old, still-held `Arc<ServerConfig>` can never be
        // confused with a freshly issued one in diagnostics.
    }
}

/// A generated + persisted CA with a bounded leaf cache.
///
/// Constructed by [`CertificateAuthority::generate`] (fresh CA) or
/// [`CertificateAuthority::load`] (existing material). Leaf acquisition is
/// [`CertificateAuthority::server_config`].
pub(crate) struct CertificateAuthority {
    dir: PathBuf,
    ca_cert_der: CertificateDer<'static>,
    ca_cert_pem: String,
    issuer: Issuer<'static, KeyPair>,
    cache: Mutex<LeafCache>,
    signings: AtomicU64,
}

impl CertificateAuthority {
    /// Generate a fresh ECDSA P-256 CA, persist it, and return the live handle.
    ///
    /// Overwrites any existing material. The private key file is created with
    /// mode `0600` on unix.
    pub(crate) fn generate(data_dir: &str) -> Result<Self, MitmError> {
        let dir = mitm_dir(data_dir)?;
        let key = KeyPair::generate()?;
        let params = ca_params()?;
        let cert = params.self_signed(&key)?;
        let ca_cert_der = CertificateDer::from(cert.der().to_vec());
        let ca_cert_pem = pem_encode("CERTIFICATE", ca_cert_der.as_ref());
        if ca_cert_pem.len() > MITM_PEM_BUFFER_MAX_BYTES {
            return Err(MitmError::InvalidState("ca pem exceeds buffer budget"));
        }
        // Key is written FIRST so a crash between the two writes leaves a
        // half-written CA that `load` rejects as not-generated (never a cert
        // without its key).
        write_private(&dir.join(CA_KEY_FILE), pem_encode("PRIVATE KEY", &key.serialize_der()).as_bytes())?;
        write_public(&dir.join(CA_CERT_FILE), ca_cert_pem.as_bytes())?;
        crate::log_message(
            1,
            &format!("proxy.mitm: generated CA at {}", dir.display()),
        );
        Ok(Self {
            dir,
            ca_cert_der,
            ca_cert_pem,
            issuer: Issuer::new(params, key),
            cache: Mutex::new(LeafCache::fresh()),
            signings: AtomicU64::new(0),
        })
    }

    /// Load existing CA material.
    ///
    /// Returns `Ok(None)` — never an error and never a panic — when either file
    /// is missing or the certificate/key is corrupt. (An unusable on-disk CA is
    /// indistinguishable from "not generated"; the caller regenerates.)
    pub(crate) fn load(data_dir: &str) -> Result<Option<Self>, MitmError> {
        let base = data_dir.trim();
        if base.is_empty() {
            return Ok(None);
        }
        let dir = Path::new(base).join(MITM_DIR);
        let cert_path = dir.join(CA_CERT_FILE);
        let key_path = dir.join(CA_KEY_FILE);

        let Ok(ca_cert_pem) = std::fs::read_to_string(&cert_path) else {
            return Ok(None);
        };
        if ca_cert_pem.len() > MITM_PEM_BUFFER_MAX_BYTES {
            return Ok(None);
        }
        let Ok(key_pem) = std::fs::read_to_string(&key_path) else {
            return Ok(None);
        };
        // Corrupt PEM decodes to `None`/empty → treated as not-generated.
        let Some(ca_der) = pem_decode(&ca_cert_pem).filter(|d| !d.is_empty()) else {
            return Ok(None);
        };
        let Some(key_der) = pem_decode(&key_pem).filter(|d| !d.is_empty()) else {
            return Ok(None);
        };
        let Ok(key) = KeyPair::try_from(key_der.as_slice()) else {
            return Ok(None);
        };
        // Rebuild the issuer from the same deterministic params used to
        // generate the CA (rcgen's x509-parser feature is off; see module docs),
        // so the leaf issuer name + Authority Key Identifier match the CA.
        let params = ca_params()?;
        Ok(Some(Self {
            dir,
            ca_cert_der: CertificateDer::from(ca_der),
            ca_cert_pem,
            issuer: Issuer::new(params, key),
            cache: Mutex::new(LeafCache::fresh()),
            signings: AtomicU64::new(0),
        }))
    }

    /// Remove the persisted CA material **and** drop every cached leaf, so any
    /// previously issued leaf is no longer served. Returns `true` when there was
    /// something to remove.
    pub(crate) fn reset(&self) -> Result<bool, MitmError> {
        let mut cleared = false;
        for name in [CA_CERT_FILE, CA_KEY_FILE] {
            let path = self.dir.join(name);
            match std::fs::remove_file(&path) {
                Ok(()) => cleared = true,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(MitmError::Io(e)),
            }
        }
        let had = {
            let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            let had = !cache.entries.is_empty();
            cache.clear();
            had
        };
        if had {
            cleared = true;
        }
        crate::log_message(1, &format!("proxy.mitm: reset CA at {} cleared={cleared}", self.dir.display()));
        Ok(cleared)
    }

    /// Delete the on-disk CA without a live handle (used by `capture.ca.reset`
    /// when no instance has been loaded).
    pub(crate) fn reset_at(data_dir: &str) -> Result<bool, MitmError> {
        let base = data_dir.trim();
        if base.is_empty() {
            return Ok(false);
        }
        let dir = Path::new(base).join(MITM_DIR);
        let mut cleared = false;
        for name in [CA_CERT_FILE, CA_KEY_FILE] {
            match std::fs::remove_file(dir.join(name)) {
                Ok(()) => cleared = true,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(MitmError::Io(e)),
            }
        }
        Ok(cleared)
    }

    /// PEM-encoded CA certificate (export / client install).
    pub(crate) fn pem(&self) -> &str {
        &self.ca_cert_pem
    }

    /// DER-encoded CA certificate.
    pub(crate) fn der(&self) -> &CertificateDer<'static> {
        &self.ca_cert_der
    }

    /// Lowercase hex SHA-256 of the DER CA certificate.
    pub(crate) fn fingerprint_sha256(&self) -> String {
        use sha2::{Digest, Sha256};
        let digest = Sha256::digest(self.ca_cert_der.as_ref());
        let mut out = String::with_capacity(digest.len() * 2);
        for byte in digest {
            out.push_str(&format!("{byte:02x}"));
        }
        out
    }

    /// Return the cached [`ServerConfig`] for `host`, signing a fresh leaf on a
    /// cache miss. A cached entry is returned without re-signing.
    pub(crate) fn server_config(&self, host: &str) -> Result<Arc<ServerConfig>, MitmError> {
        Ok(self.entry_for(host)?.config)
    }

    /// Return the cached [`CertifiedKey`] for `host`, signing a fresh leaf on a
    /// cache miss. Backs the SNI [`ResolvesServerCert`] implementation. Shares
    /// the same bounded cache (and signing counter) as [`Self::server_config`],
    /// so a host is signed at most once per CA epoch regardless of which API
    /// asks first.
    pub(crate) fn certified_key(&self, host: &str) -> Result<Arc<CertifiedKey>, MitmError> {
        Ok(self.entry_for(host)?.key)
    }

    fn entry_for(&self, host: &str) -> Result<LeafEntry, MitmError> {
        let host = normalize_host(host)?;
        if let Some(hit) = self.cache_lookup(&host) {
            return Ok(hit);
        }
        let (leaf_der, leaf_key) = self.issue_leaf(&host)?;
        let key = Arc::new(self.certified_from(leaf_der.clone(), leaf_key.clone_key())?);
        let config = Arc::new(self.build_config(leaf_der.clone(), leaf_key)?);
        let size_bytes = estimate_entry_bytes(&host, &leaf_der);
        if size_bytes > MITM_CERT_ENTRY_MAX_BYTES {
            // Serve it, but never cache an entry that would under-count the
            // bounded memory budget.
            crate::log_message(
                2,
                &format!(
                    "proxy.mitm: leaf for {host} accounts {size_bytes} B > {} B entry cap; served uncached",
                    MITM_CERT_ENTRY_MAX_BYTES
                ),
            );
            return Ok(LeafEntry { config, key });
        }
        let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        // Another thread may have signed the same host while we were unlocked.
        if let Some(existing) = cache.entries.get(&host) {
            return Ok(LeafEntry {
                config: Arc::clone(&existing.config),
                key: Arc::clone(&existing.key),
            });
        }
        let evicted = cache.insert(
            host,
            CachedLeaf {
                config: Arc::clone(&config),
                key: Arc::clone(&key),
                seq: 0,
                size_bytes,
            },
        );
        if evicted > 0 {
            crate::log_message(
                2,
                &format!("proxy.mitm: evicted {evicted} leaf cert(s) at capacity {MITM_CERT_CACHE_CAP}"),
            );
        }
        Ok(LeafEntry { config, key })
    }

    /// Number of cached leaves (diagnostics / tests).
    pub(crate) fn cache_len(&self) -> usize {
        self.cache.lock().unwrap_or_else(|e| e.into_inner()).entries.len()
    }

    /// Total evictions since construction (diagnostics / tests).
    pub(crate) fn evicted(&self) -> u64 {
        self.cache.lock().unwrap_or_else(|e| e.into_inner()).evicted
    }

    /// Number of leaf certificates actually signed (cache misses). A cache hit
    /// must not move this counter.
    pub(crate) fn signings(&self) -> u64 {
        self.signings.load(Ordering::Relaxed)
    }

    fn cache_lookup(&self, host: &str) -> Option<LeafEntry> {
        let cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        cache.entries.get(host).map(|e| LeafEntry {
            config: Arc::clone(&e.config),
            key: Arc::clone(&e.key),
        })
    }

    fn issue_leaf(&self, host: &str) -> Result<(CertificateDer<'static>, PrivateKeyDer<'static>), MitmError> {
        let key = KeyPair::generate()?;
        let mut params = CertificateParams::new(vec![host.to_string()])?;
        params.distinguished_name.push(DnType::CommonName, host);
        params.use_authority_key_identifier_extension = true;
        params.serial_number = Some(SerialNumber::from_slice(&random_serial()));
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        let cert = params.signed_by(&key, &self.issuer)?;
        self.signings.fetch_add(1, Ordering::Relaxed);
        Ok((CertificateDer::from(cert.der().to_vec()), PrivateKeyDer::from(key)))
    }

    fn build_config(
        &self,
        leaf: CertificateDer<'static>,
        key: PrivateKeyDer<'static>,
    ) -> Result<ServerConfig, MitmError> {
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let config = ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_single_cert(vec![leaf], key)?;
        Ok(config)
    }

    fn certified_from(
        &self,
        leaf: CertificateDer<'static>,
        key: PrivateKeyDer<'static>,
    ) -> Result<CertifiedKey, MitmError> {
        let provider = rustls::crypto::aws_lc_rs::default_provider();
        Ok(CertifiedKey::from_der(vec![leaf], key, &provider)?)
    }

    /// Build the MITM server [`ServerConfig`] served to in-TUN clients: a
    /// [`SniCertResolver`] over this CA's bounded leaf cache, advertising ALPN
    /// `h2` then `http/1.1`. `fallback_host` is signed when the client omits SNI
    /// (e.g. an IP literal) but the flow host is known from DNS/sniff.
    pub(crate) fn mitm_server_config(
        self: &Arc<Self>,
        fallback_host: Option<&str>,
    ) -> Result<Arc<ServerConfig>, MitmError> {
        ensure_crypto_provider();
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let mut config = ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_cert_resolver(Arc::new(SniCertResolver {
                ca: Arc::clone(self),
                fallback_host: fallback_host
                    .map(str::trim)
                    .filter(|h| !h.is_empty())
                    .map(str::to_ascii_lowercase),
            }));
        config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
        Ok(Arc::new(config))
    }
}

/// Per-SNI certificate selection for the MITM acceptor.
///
/// `resolve` consults the [`ClientHello`]'s SNI first and falls back to the
/// flow's known host when the client omitted SNI. The leaf is fetched from (or
/// issued into) the CA's bounded leaf cache via
/// [`CertificateAuthority::certified_key`]. Returning `None` aborts the
/// handshake — the caller records `mitmFailed`.
pub(crate) struct SniCertResolver {
    ca: Arc<CertificateAuthority>,
    fallback_host: Option<String>,
}

impl std::fmt::Debug for SniCertResolver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SniCertResolver")
            .field("fallback_host", &self.fallback_host)
            .finish_non_exhaustive()
    }
}

impl ResolvesServerCert for SniCertResolver {
    fn resolve(&self, client_hello: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        let host = client_hello
            .server_name()
            .map(str::to_string)
            .or_else(|| self.fallback_host.clone())?;
        match self.ca.certified_key(&host) {
            Ok(key) => Some(key),
            Err(e) => {
                crate::log_message(2, &format!("proxy.mitm: refusing SNI {host}: {e}"));
                None
            }
        }
    }
}

/// Signal the dispatch layer records when [`MitmTls::Failed`] is returned.
pub(crate) const MITM_FAILED_SIGNAL: &str = "mitmFailed";

/// Ceiling on the in-TUN **client** TLS handshake. A silent or stalled client
/// must not pin an in-flight slot indefinitely.
pub(crate) const CLIENT_TLS_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// Ceiling on the **upstream TCP dial** (`adapter.dial_tcp`). meow's
/// [`meow_common::with_dial_timeout`] is a compile-time 5 s that is too short
/// for slow mobile DIRECT connects, so the MITM upstream owns a longer,
/// test-settable deadline (default 12 s) and retries a *timeout* once.
pub(crate) const UPSTREAM_DIAL_TIMEOUT: Duration = Duration::from_secs(12);
/// Ceiling on the **upstream** TLS handshake after the TCP dial succeeded.
pub(crate) const UPSTREAM_TLS_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// Ceiling on the upstream hyper HTTP/1.1 or HTTP/2 handshake.
pub(crate) const UPSTREAM_HTTP_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
/// Ceiling on waiting for an upstream response head after the request was sent.
/// A hung origin (TLS accepted, request written, no response) must not stall the
/// client connection until the app aborts.
pub(crate) const UPSTREAM_RESPONSE_TIMEOUT: Duration = Duration::from_secs(30);
/// Whole-session deadline in milliseconds (default 10 minutes). Reclaims the
/// in-flight slot even when a later stage (an idle HTTP connection, a stalled
/// body) never completes. The detached WS pump is excluded: it holds no slot
/// after the 101 upgrade.
pub(crate) const MITM_SESSION_DEADLINE_MS: u64 = 10 * 60 * 1000;

static SESSION_DEADLINE_MS: AtomicU64 = AtomicU64::new(MITM_SESSION_DEADLINE_MS);

/// The whole-session deadline in effect. Production uses
/// [`MITM_SESSION_DEADLINE_MS`]; tests shorten it to exercise the deadline path.
pub(crate) fn session_deadline() -> Duration {
    Duration::from_millis(SESSION_DEADLINE_MS.load(Ordering::Relaxed))
}

#[cfg(test)]
pub(crate) fn set_session_deadline_for_tests(ms: u64) {
    SESSION_DEADLINE_MS.store(ms, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn reset_session_deadline_for_tests() {
    SESSION_DEADLINE_MS.store(MITM_SESSION_DEADLINE_MS, Ordering::Relaxed);
}

static UPSTREAM_RESPONSE_TIMEOUT_MS: AtomicU64 = AtomicU64::new(30_000);

/// The upstream response ceiling in effect. Production uses
/// [`UPSTREAM_RESPONSE_TIMEOUT`]; tests shorten it to exercise the timeout path.
pub(crate) fn upstream_response_timeout() -> Duration {
    Duration::from_millis(UPSTREAM_RESPONSE_TIMEOUT_MS.load(Ordering::Relaxed))
}

#[cfg(test)]
pub(crate) fn set_upstream_response_timeout_for_tests(ms: u64) {
    UPSTREAM_RESPONSE_TIMEOUT_MS.store(ms, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn reset_upstream_response_timeout_for_tests() {
    UPSTREAM_RESPONSE_TIMEOUT_MS.store(
        UPSTREAM_RESPONSE_TIMEOUT.as_millis() as u64,
        Ordering::Relaxed,
    );
}

static UPSTREAM_DIAL_TIMEOUT_MS: AtomicU64 = AtomicU64::new(12_000);

/// The upstream dial ceiling in effect. Production uses
/// [`UPSTREAM_DIAL_TIMEOUT`]; tests shorten it to exercise the timeout path.
pub(crate) fn upstream_dial_timeout() -> Duration {
    Duration::from_millis(UPSTREAM_DIAL_TIMEOUT_MS.load(Ordering::Relaxed))
}

#[cfg(test)]
pub(crate) fn set_upstream_dial_timeout_for_tests(ms: u64) {
    UPSTREAM_DIAL_TIMEOUT_MS.store(ms, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn reset_upstream_dial_timeout_for_tests() {
    UPSTREAM_DIAL_TIMEOUT_MS.store(
        UPSTREAM_DIAL_TIMEOUT.as_millis() as u64,
        Ordering::Relaxed,
    );
}

/// Why the MITM acceptor could not terminate TLS.
#[derive(Debug)]
pub(crate) enum MitmTlsError {
    /// The CA could not build the server config.
    Config(String),
    /// The TLS handshake failed (malformed ClientHello, no cert, IO error).
    Handshake(String),
}

impl std::fmt::Display for MitmTlsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MitmTlsError::Config(e) => write!(f, "mitm tls config: {e}"),
            MitmTlsError::Handshake(e) => write!(f, "mitm tls handshake: {e}"),
        }
    }
}

impl std::error::Error for MitmTlsError {}

/// Outcome of [`terminate`]. The caller owns the decision to pass through.
pub(crate) enum MitmTls<S> {
    /// No flow host was known (no DNS/sniff): the *unmodified* inbound stream,
    /// to be passed through. No byte was read and no certificate was issued.
    Passthrough(S),
    /// TLS terminated: the decrypted client stream.
    Terminated(TlsStream<S>),
    /// Handshake/config failure: the stream has been closed. The caller records
    /// [`MITM_FAILED_SIGNAL`] and falls back to pass-through upstream if it can.
    Failed(MitmTlsError),
}

/// Install the `aws-lc-rs` crypto provider as the process default exactly once.
/// Idempotent (and race-safe): a second install is a no-op.
pub(crate) fn ensure_crypto_provider() {
    static INSTALL: std::sync::Once = std::sync::Once::new();
    INSTALL.call_once(|| {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    });
}

/// MITM entry point: run the server-side TLS handshake over an inbound client
/// stream and hand back the decrypted stream.
///
/// The fixed no-SNI decision lives here: an unknown `flow_host` (no DNS/sniff)
/// returns [`MitmTls::Passthrough`] with the stream untouched — this flow is
/// **not** MITM'd. A known host builds the per-flow resolver (SNI preferred,
/// host as fallback) and performs the handshake. A failed handshake returns
/// [`MitmTls::Failed`] after the stream is dropped (clean close); it never
/// panics.
pub(crate) async fn terminate<S>(
    stream: S,
    ca: &Arc<CertificateAuthority>,
    flow_host: Option<&str>,
) -> MitmTls<S>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let Some(host) = flow_host.map(str::trim).filter(|h| !h.is_empty()) else {
        return MitmTls::Passthrough(stream);
    };
    let config = match ca.mitm_server_config(Some(host)) {
        Ok(config) => config,
        Err(e) => return MitmTls::Failed(MitmTlsError::Config(e.to_string())),
    };
    match tokio::time::timeout(
        CLIENT_TLS_HANDSHAKE_TIMEOUT,
        TlsAcceptor::from(config).accept(stream),
    )
    .await
    {
        Ok(Ok(mut tls)) => {
            tls.get_mut()
                .1
                .set_buffer_limit(Some(RUSTLS_BUFFER_LIMIT_BYTES));
            MitmTls::Terminated(tls)
        }
        Ok(Err(e)) => MitmTls::Failed(MitmTlsError::Handshake(e.to_string())),
        Err(_) => MitmTls::Failed(MitmTlsError::Handshake(
            "client tls handshake timed out".to_string(),
        )),
    }
}

// ==================== Todo 6: TUN MITM gate state ====================
//
// The gate in `crate::dispatch` reads these process-level primitives. They are
// deliberately tiny and lock-light so the TUN dataplane never blocks on them.

/// Process-level MITM CA handle. Until Todo 10 wires the CA lifecycle to
/// `capture.ca.*`, the owner installs the generated/loaded handle here; the TUN
/// gate reads it via [`ca`]. A missing CA is a **fail-safe pass-through**, never
/// a decryption attempt.
static MITM_CA: OnceLock<Mutex<Option<Arc<CertificateAuthority>>>> = OnceLock::new();

fn ca_cell() -> &'static Mutex<Option<Arc<CertificateAuthority>>> {
    MITM_CA.get_or_init(|| Mutex::new(None))
}

/// Install (or replace) the process-level CA used by the TUN MITM gate.
pub(crate) fn install_ca(ca: Arc<CertificateAuthority>) {
    *ca_cell().lock().unwrap_or_else(|e| e.into_inner()) = Some(ca);
}

/// The installed CA, if any. Cloned `Arc`; the lock is not held by the caller.
pub(crate) fn ca() -> Option<Arc<CertificateAuthority>> {
    ca_cell().lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Drop the process-level CA (tests / teardown).
pub(crate) fn clear_ca() {
    *ca_cell().lock().unwrap_or_else(|e| e.into_inner()) = None;
}

/// Observer seam over the MITM gate. Used by tests to assert the MITM path was
/// entered and TLS termination (todo 5) was actually invoked; production uses
/// the no-op default.
pub(crate) trait MitmGateObserver: Send + Sync {
    /// The MITM handler task started for `host`.
    fn on_mitm_entered(&self, _host: &str) {}
    /// TLS termination (todo 5) completed; todo 7/8 take over.
    fn on_terminated(&self, _host: &str) {}
    /// Handshake/parse/dial failed; the flow was closed or passed through.
    fn on_failed(&self, _host: &str, _reason: &str) {}
}

/// No-op observer (shipping default).
struct NoopMitmObserver;

impl MitmGateObserver for NoopMitmObserver {}

static GATE_OBSERVER: OnceLock<Mutex<Arc<dyn MitmGateObserver>>> = OnceLock::new();

fn observer_cell() -> &'static Mutex<Arc<dyn MitmGateObserver>> {
    GATE_OBSERVER.get_or_init(|| Mutex::new(Arc::new(NoopMitmObserver)))
}

/// Current observer (cloned `Arc`).
pub(crate) fn gate_observer() -> Arc<dyn MitmGateObserver> {
    observer_cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Install a gate observer (tests / diagnostics).
pub(crate) fn set_gate_observer(observer: Arc<dyn MitmGateObserver>) {
    *observer_cell().lock().unwrap_or_else(|e| e.into_inner()) = observer;
}

/// Restore the no-op observer (tests).
#[cfg(test)]
pub(crate) fn reset_gate_observer() {
    set_gate_observer(Arc::new(NoopMitmObserver));
}

/// MITM sessions currently in flight. Bounded by
/// [`crate::limits::MITM_MAX_INFLIGHT`]; an overflow is a direct pass-through,
/// never a queue.
static MITM_INFLIGHT: AtomicUsize = AtomicUsize::new(0);

/// Total MITM init/handshake/panic failures recorded (the `mitmFailed` signal).
static MITM_FAILED: AtomicU64 = AtomicU64::new(0);

/// RAII in-flight slot. Acquired with [`InflightGuard::try_acquire`]; released
/// on drop, which includes a panic unwinding the MITM task.
pub(crate) struct InflightGuard;

impl InflightGuard {
    /// Claim an MITM slot, or `None` when the cap is reached (the caller must
    /// then take the pass-through path — never queue).
    pub(crate) fn try_acquire() -> Option<Self> {
        let mut current = MITM_INFLIGHT.load(Ordering::Acquire);
        loop {
            if current >= crate::limits::MITM_MAX_INFLIGHT {
                return None;
            }
            match MITM_INFLIGHT.compare_exchange_weak(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return Some(InflightGuard),
                Err(observed) => current = observed,
            }
        }
    }
}

impl Drop for InflightGuard {
    fn drop(&mut self) {
        // Saturating: a global counter must never wrap to `usize::MAX`, which
        // would make the gate permanently believe the cap is reached and stop
        // decrypting allowlisted traffic (tests reset the counter while a
        // detached session may still be unwinding).
        let _ = MITM_INFLIGHT.fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            Some(n.saturating_sub(1))
        });
    }
}

/// MITM sessions currently in flight (diagnostics / tests).
pub(crate) fn inflight_count() -> usize {
    MITM_INFLIGHT.load(Ordering::Acquire)
}

/// Record a failed MITM attempt under the [`MITM_FAILED_SIGNAL`] marker. The
/// line intentionally contains `mitmFailed` so the evidence/log grep can find
/// it; the count backs the test assertions.
pub(crate) fn record_mitm_failed(reason: &str) {
    let total = MITM_FAILED.fetch_add(1, Ordering::Relaxed) + 1;
    crate::log_message(
        2,
        &format!("proxy.mitm: {MITM_FAILED_SIGNAL} {reason} (total {total})"),
    );
}

/// Number of recorded MITM failures (`mitmFailed`).
pub(crate) fn mitm_failed_count() -> u64 {
    MITM_FAILED.load(Ordering::Relaxed)
}

/// Reset the gate counters (tests).
#[cfg(test)]
pub(crate) fn reset_gate_counters_for_tests() {
    MITM_INFLIGHT.store(0, Ordering::Release);
    MITM_FAILED.store(0, Ordering::Release);
}

/// Deterministic, bounded CA generation parameters. Both `generate` and `load`
/// call this, so a reloaded issuer is field-for-field identical to the one that
/// self-signed the persisted CA certificate.
fn ca_params() -> Result<CertificateParams, rcgen::Error> {
    let mut params = CertificateParams::new(Vec::<String>::new())?;
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params
        .distinguished_name
        .push(DnType::CommonName, CA_COMMON_NAME);
    params.key_usages = vec![
        KeyUsagePurpose::KeyCertSign,
        KeyUsagePurpose::CrlSign,
        KeyUsagePurpose::DigitalSignature,
    ];
    Ok(params)
}

/// Resolve + create `<dataDir>/mitm`. Rejects an empty data dir.
fn mitm_dir(data_dir: &str) -> Result<PathBuf, MitmError> {
    let base = data_dir.trim();
    if base.is_empty() {
        return Err(MitmError::InvalidState("empty data dir"));
    }
    let dir = Path::new(base).join(MITM_DIR);
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// Normalize a leaf host: trim, lowercase, strip a `host:port` / `[v6]:port`
/// suffix and a trailing dot. Rejects empty / whitespace-only hosts.
fn normalize_host(host: &str) -> Result<String, MitmError> {
    let mut h = host.trim().to_ascii_lowercase();
    if h.starts_with('[') {
        // [v6]:port -> v6 (without brackets, suitable as a SAN dNSName fallback).
        if let Some(end) = h.find(']') {
            h.truncate(end);
            h.remove(0);
        }
    } else if let Some((name, port)) = h.rsplit_once(':') {
        if port.chars().all(|c| c.is_ascii_digit()) {
            h = name.to_string();
        }
    }
    while h.ends_with('.') {
        h.pop();
    }
    if h.is_empty() {
        return Err(MitmError::InvalidState("empty host"));
    }
    Ok(h)
}

/// Estimated retained bytes for one cached leaf entry.
fn estimate_entry_bytes(host: &str, leaf_der: &CertificateDer<'_>) -> usize {
    host.len() + leaf_der.as_ref().len() + LEAF_ENTRY_FIXED_OVERHEAD
}

/// 16-byte serial with the high bit clear. Combined timestamp + process-unique
/// counter: uniqueness (all a public serial needs), never security-sensitive.
fn random_serial() -> [u8; 16] {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let mix = t ^ n.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ (std::process::id() as u64);
    let mut out = [0u8; 16];
    let mut x = mix;
    for chunk in out.chunks_mut(8) {
        x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = x;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        chunk.copy_from_slice(&z.to_be_bytes()[..chunk.len()]);
    }
    out[0] &= 0x7f; // keep the INTEGER positive
    if out.iter().all(|b| *b == 0) {
        out[15] = 1;
    }
    out
}

/// Minimal PEM encoder (rcgen's `pem` feature is off). 64-char base64 lines.
fn pem_encode(label: &str, der: &[u8]) -> String {
    use base64::Engine as _;
    let b64 = base64::engine::general_purpose::STANDARD.encode(der);
    let mut out = String::with_capacity(b64.len() + 64);
    out.push_str("-----BEGIN ");
    out.push_str(label);
    out.push_str("-----\n");
    for chunk in b64.as_bytes().chunks(64) {
        out.push_str(std::str::from_utf8(chunk).unwrap_or_default());
        out.push('\n');
    }
    out.push_str("-----END ");
    out.push_str(label);
    out.push_str("-----\n");
    out
}

/// Minimal PEM decoder: strips armor lines and base64-decodes the body.
fn pem_decode(input: &str) -> Option<Vec<u8>> {
    use base64::Engine as _;
    let body: String = input
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with("-----"))
        .collect();
    base64::engine::general_purpose::STANDARD.decode(body).ok()
}

/// Write a secret file with mode `0600` on unix.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(path)?;
        f.write_all(bytes)?;
        f.flush()
    }
    #[cfg(not(unix))]
    {
        std::fs::write(path, bytes)
    }
}

/// Write a public (non-secret) file, tightening an existing file's mode.
fn write_public(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    std::fs::write(path, bytes)
}

// ==================== Todo 7: upstream re-origination through the tunnel ====================
//
// A decrypted MITM request is re-originated to its real upstream **through the
// live tunnel**: the same rule engine + outbound registry + protect seam the
// normal TUN path uses. DIRECT is a rule *result*; a raw dial that ignores the
// rules is never performed, so MITM upstream traffic can never escape the VPN.

/// `PROXY_CAPTURE_UPSTREAM_FAILED`: the upstream re-origination dial or TLS
/// handshake failed. The HTTP layer (todo 8) renders it as a 502-style response;
/// registered in `rust/ERROR_CODES.md`.
pub(crate) const ERR_CAPTURE_UPSTREAM_FAILED: &str = "PROXY_CAPTURE_UPSTREAM_FAILED";

/// Fixed HTTP status for every upstream failure. Carried on the error itself so
/// an unreachable upstream can never be mistaken for a captured success.
pub(crate) const UPSTREAM_FAILURE_STATUS: u16 = 502;

/// The decrypted request target to re-originate to: the host the client asked
/// for plus the original destination port. `dst_ip` is optional — when absent,
/// `resolve_proxy_lazy` enriches it through the DNS/resolver hook exactly as the
/// normal TUN path does.
#[derive(Debug, Clone)]
pub(crate) struct UpstreamTarget {
    pub host: String,
    pub port: u16,
    pub dst_ip: Option<IpAddr>,
    pub src_ip: Option<IpAddr>,
    pub src_port: u16,
}

impl UpstreamTarget {
    /// A target with no pre-resolved IP (the resolver hook fills it in).
    pub(crate) fn new(host: impl Into<String>, port: u16) -> Self {
        Self {
            host: host.into(),
            port,
            dst_ip: None,
            src_ip: None,
            src_port: 0,
        }
    }

    /// The destination IP the flow was originally addressed to, when known.
    pub(crate) fn with_dst_ip(mut self, ip: IpAddr) -> Self {
        self.dst_ip = Some(ip);
        self
    }

    /// The original client source address, when known (rule `SRC-*` matching).
    pub(crate) fn with_source(mut self, ip: IpAddr, port: u16) -> Self {
        self.src_ip = Some(ip);
        self.src_port = port;
        self
    }

    /// The routing `Metadata` for this target. `conn_type: Tun` keeps outbound
    /// selection identical to the in-TUN flow the request arrived on.
    pub(crate) fn metadata(&self) -> Metadata {
        Metadata {
            network: Network::Tcp,
            conn_type: ConnType::Tun,
            src_ip: self.src_ip,
            src_port: self.src_port,
            dst_ip: self.dst_ip,
            dst_port: self.port,
            host: self.host.as_str().into(),
            in_name: "tun".into(),
            ..Default::default()
        }
    }

    fn validate(&self) -> Result<(), UpstreamError> {
        if self.host.trim().is_empty() {
            return Err(UpstreamError::invalid("empty upstream host"));
        }
        if self.port == 0 {
            return Err(UpstreamError::invalid("zero upstream port"));
        }
        Ok(())
    }
}

/// Which boundary of a MITM session failed. Stable diagnostic labels so a
/// device log attributes a `mitmFailed` to exactly one stage.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MitmStage {
    ClientTls,
    UpstreamDial,
    UpstreamTls,
    UpstreamHttp,
    ClientHttp,
    ClientAbort,
}

impl MitmStage {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            MitmStage::ClientTls => "client_tls",
            MitmStage::UpstreamDial => "upstream_dial",
            MitmStage::UpstreamTls => "upstream_tls",
            MitmStage::UpstreamHttp => "upstream_http",
            MitmStage::ClientHttp => "client_http",
            MitmStage::ClientAbort => "client_abort",
        }
    }

    fn from_upstream_kind(kind: &str) -> Self {
        match kind {
            "tls" => MitmStage::UpstreamTls,
            _ => MitmStage::UpstreamDial,
        }
    }
}

/// Optional connection facts attached to a [`MitmFailure`] so a device log can
/// attribute a failure without a second log line. All fields are best-effort.
#[derive(Debug, Default, Clone)]
pub(crate) struct FailureDiagnostics {
    client_proto: Option<&'static str>,
    method: Option<String>,
    upstream_proto: Option<&'static str>,
}

impl FailureDiagnostics {
    pub(crate) fn render(&self) -> String {
        let mut parts: Vec<String> = Vec::new();
        if let Some(proto) = self.client_proto {
            parts.push(format!("client_proto={proto}"));
        }
        if let Some(method) = &self.method {
            parts.push(format!("method={method}"));
        }
        if let Some(proto) = self.upstream_proto {
            parts.push(format!("upstream_proto={proto}"));
        }
        parts.join(" ")
    }
}

/// A stage-tagged MITM failure. [`Self::stage`] drives the session-failure log
/// (`session failed stage=<label>`); `Display` renders the same tag inline so
/// request-level records (`record_mitm_failed`) are attributable too.
#[derive(Debug)]
pub(crate) struct MitmFailure {
    stage: MitmStage,
    message: String,
    diagnostics: FailureDiagnostics,
}

impl MitmFailure {
    pub(crate) fn new(stage: MitmStage, message: impl Into<String>) -> Self {
        Self {
            stage,
            message: message.into(),
            diagnostics: FailureDiagnostics::default(),
        }
    }

    pub(crate) fn stage(&self) -> MitmStage {
        self.stage
    }

    pub(crate) fn message(&self) -> &str {
        &self.message
    }

    pub(crate) fn diagnostics(&self) -> &FailureDiagnostics {
        &self.diagnostics
    }

    /// A client abort is the peer tearing down its own connection, not a proxy
    /// failure; the failure counter and error-level logs must exclude it.
    pub(crate) fn is_client_abort(&self) -> bool {
        self.stage == MitmStage::ClientAbort
    }

    pub(crate) fn with_client_proto(mut self, proto: HttpProtocol) -> Self {
        self.diagnostics.client_proto = Some(proto.as_str());
        self
    }

    pub(crate) fn with_method(mut self, method: impl Into<String>) -> Self {
        self.diagnostics.method = Some(method.into());
        self
    }

    pub(crate) fn with_upstream_proto(mut self, proto: HttpProtocol) -> Self {
        self.diagnostics.upstream_proto = Some(proto.as_str());
        self
    }
}

impl std::fmt::Display for MitmFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "stage={}: {}", self.stage.as_str(), self.message)
    }
}

impl std::error::Error for MitmFailure {}

/// Why an upstream re-origination attempt failed. `kind` is a stable label for
/// logs/tests; `status`/`code` are the frozen failure contract.
#[derive(Debug)]
pub(crate) struct UpstreamError {
    kind: &'static str,
    message: String,
}

impl UpstreamError {
    fn invalid(message: impl Into<String>) -> Self {
        Self {
            kind: "invalid_target",
            message: message.into(),
        }
    }

    fn no_route() -> Self {
        Self {
            kind: "no_route",
            message: "no rule resolved an outbound for the upstream target".to_string(),
        }
    }

    fn dial(error: impl std::fmt::Display) -> Self {
        Self {
            kind: "dial",
            message: error.to_string(),
        }
    }

    fn tls(error: impl std::fmt::Display) -> Self {
        Self {
            kind: "tls",
            message: error.to_string(),
        }
    }

    /// The HTTP status the capture layer returns (always 502).
    pub(crate) fn status(&self) -> u16 {
        UPSTREAM_FAILURE_STATUS
    }

    /// The registered error code.
    pub(crate) fn code(&self) -> &'static str {
        ERR_CAPTURE_UPSTREAM_FAILED
    }

    pub(crate) fn kind(&self) -> &'static str {
        self.kind
    }

    fn stage(&self) -> MitmStage {
        MitmStage::from_upstream_kind(self.kind)
    }

    pub(crate) fn message(&self) -> &str {
        &self.message
    }
}

impl std::fmt::Display for UpstreamError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} [{}] {}", self.code(), self.kind, self.message)
    }
}

impl std::error::Error for UpstreamError {}

/// Re-originate a decrypted request to `target` **through the tunnel**:
/// `resolve_proxy_lazy` selects the outbound by the live rules (DIRECT is a rule
/// result, not a bypass), then that adapter's `dial_tcp` opens the connection
/// through the protect seam. A raw direct dial that ignores the rules never
/// happens.
pub(crate) async fn dial_upstream(
    inner: &meow_tunnel::tunnel::TunnelInner,
    target: &UpstreamTarget,
) -> Result<Box<dyn ProxyConn>, UpstreamError> {
    target.validate()?;
    let mut metadata = target.metadata();
    // The TUN path hands us the address the client dialed as `dst_ip`. Under the
    // default FakeIp DNS mode that is a synthetic `198.18.x.x` address, and
    // meow's `DirectAdapter::resolve_targets` prefers `dst_ip` over `host` — so
    // dialing it unchanged opens the dead fake-IP address. Mirror
    // `route_inbound_tcp` (meow-tunnel/src/tcp.rs): rewrite fake-IP → host and
    // clear `dst_ip` BEFORE rule matching, so the selected outbound re-resolves
    // the real address (or reaches the client's proxy by name). Outside fake-IP
    // mode this is a no-op apart from a hostname fill-in.
    inner.pre_handle_metadata(&mut metadata);
    let Some((adapter, rule, _payload)) = inner.resolve_proxy_lazy(&mut metadata).await else {
        return Err(UpstreamError::no_route());
    };
    crate::log_message(
        2,
        &format!(
            "proxy.mitm: upstream {}:{} via {} rule={} dst_ip={:?}",
            target.host,
            target.port,
            adapter.name(),
            rule,
            metadata.dst_ip,
        ),
    );
    let timeout = upstream_dial_timeout();
    let dial_result: Result<Box<dyn ProxyConn>, UpstreamError> =
        match tokio::time::timeout(timeout, adapter.dial_tcp(&metadata)).await {
            Ok(Ok(conn)) => Ok(conn),
            Ok(Err(e)) => Err(UpstreamError::dial(e)),
            Err(_) => {
                crate::log_message(
                    2,
                    &format!(
                        "proxy.mitm: upstream dial timed out after {:?} via {} host={} dst_ip={:?} rule={}; retrying once",
                        timeout, adapter.name(), target.host, metadata.dst_ip, rule,
                    ),
                );
                match tokio::time::timeout(timeout, adapter.dial_tcp(&metadata)).await {
                    Ok(Ok(conn)) => Ok(conn),
                    Ok(Err(e)) => Err(UpstreamError::dial(e)),
                    Err(_) => Err(UpstreamError::dial(format!(
                        "dial via {} exceeded the {:?} deadline",
                        adapter.name(),
                        timeout
                    ))),
                }
            }
        };
    match dial_result {
        Ok(conn) => Ok(conn),
        Err(error) => {
            crate::log_message(
                2,
                &format!(
                    "proxy.mitm: upstream dial failed via {} host={} dst_ip={:?} rule={}: {}",
                    adapter.name(),
                    target.host,
                    metadata.dst_ip,
                    rule,
                    error.message(),
                ),
            );
            Err(error)
        }
    }
}

/// Upstream-side TLS client settings.
///
/// `skip_cert_verify` defaults to `false` (**strict**): the upstream leaf chain
/// is verified against `roots`. Turning it on is an explicit opt-in for a
/// broken/self-signed upstream and is never the default.
#[derive(Clone)]
pub(crate) struct UpstreamTlsConfig {
    roots: RootCertStore,
    skip_cert_verify: bool,
    alpn: Vec<Vec<u8>>,
}

impl Default for UpstreamTlsConfig {
    fn default() -> Self {
        Self {
            roots: RootCertStore::empty(),
            skip_cert_verify: false,
            alpn: vec![b"h2".to_vec(), b"http/1.1".to_vec()],
        }
    }
}

impl UpstreamTlsConfig {
    /// Strict config that trusts `roots`.
    pub(crate) fn with_roots(roots: RootCertStore) -> Self {
        Self {
            roots,
            ..Self::default()
        }
    }

    /// Explicitly toggle certificate verification (opt-in, never default).
    pub(crate) fn with_skip_cert_verify(mut self, skip: bool) -> Self {
        self.skip_cert_verify = skip;
        self
    }

    pub(crate) fn skip_cert_verify(&self) -> bool {
        self.skip_cert_verify
    }

    /// Build the rustls client config with the SAME `aws_lc_rs` provider used by
    /// the in-TUN terminator.
    pub(crate) fn client_config(&self) -> Result<Arc<ClientConfig>, UpstreamError> {
        ensure_crypto_provider();
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let builder = ClientConfig::builder_with_provider(provider.clone())
            .with_safe_default_protocol_versions()
            .map_err(UpstreamError::tls)?;
        let mut config = if self.skip_cert_verify {
            builder
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(SkipServerVerify(provider)))
                .with_no_client_auth()
        } else {
            builder
                .with_root_certificates(self.roots.clone())
                .with_no_client_auth()
        };
        config.alpn_protocols = self.alpn.clone();
        Ok(Arc::new(config))
    }
}

/// Speak TLS to the upstream over an already-dialed tunnel connection.
pub(crate) async fn connect_upstream_tls(
    conn: Box<dyn ProxyConn>,
    server_name: &str,
    client_config: Arc<ClientConfig>,
) -> Result<ClientTlsStream<Box<dyn ProxyConn>>, UpstreamError> {
    let name = server_name.trim();
    if name.is_empty() {
        return Err(UpstreamError::invalid("empty upstream SNI"));
    }
    let sni = ServerName::try_from(name.to_string())
        .map_err(|e| UpstreamError::invalid(format!("invalid upstream SNI '{name}': {e}")))?;
    let mut tls = tokio::time::timeout(
        UPSTREAM_TLS_HANDSHAKE_TIMEOUT,
        TlsConnector::from(client_config).connect(sni, conn),
    )
    .await
    .map_err(|_| UpstreamError::tls("upstream tls handshake timed out"))?
    .map_err(UpstreamError::tls)?;
    tls.get_mut()
        .1
        .set_buffer_limit(Some(RUSTLS_BUFFER_LIMIT_BYTES));
    Ok(tls)
}

/// Dial `target` through the tunnel and speak TLS to it. On any failure the
/// returned [`UpstreamError`] carries the fixed 502 status and
/// [`ERR_CAPTURE_UPSTREAM_FAILED`] code.
pub(crate) async fn open_upstream(
    inner: &meow_tunnel::tunnel::TunnelInner,
    target: &UpstreamTarget,
    tls: &UpstreamTlsConfig,
) -> Result<ClientTlsStream<Box<dyn ProxyConn>>, UpstreamError> {
    let conn = dial_upstream(inner, target).await?;
    connect_upstream_tls(conn, &target.host, tls.client_config()?).await
}

/// Production upstream re-origination: dials the decrypted request's target
/// through the live meow tunnel (rules/outbound + protect), then speaks TLS.
/// DIRECT is a rule *result* — this type never opens a bare socket that skips
/// the rules engine.
pub(crate) struct TunnelUpstreamDialer {
    inner: Arc<meow_tunnel::tunnel::TunnelInner>,
    target: UpstreamTarget,
    tls: UpstreamTlsConfig,
}

impl TunnelUpstreamDialer {
    pub(crate) fn new(
        inner: Arc<meow_tunnel::tunnel::TunnelInner>,
        target: UpstreamTarget,
        tls: UpstreamTlsConfig,
    ) -> Self {
        Self { inner, target, tls }
    }
}

impl UpstreamDialer for TunnelUpstreamDialer {
    fn dial(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<EstablishedUpstream, MitmFailure>> + Send>> {
        let inner = Arc::clone(&self.inner);
        let target = self.target.clone();
        let tls = self.tls.clone();
        Box::pin(async move {
            let stream = open_upstream(&inner, &target, &tls)
                .await
                .map_err(|e| MitmFailure::new(e.stage(), e.to_string()))?;
            let proto = HttpProtocol::from_alpn(stream.get_ref().1.alpn_protocol());
            let client = UpstreamClient::establish(stream, proto)
                .await
                .map_err(|e| MitmFailure::new(MitmStage::UpstreamHttp, e))?;
            Ok(EstablishedUpstream { client, proto })
        })
    }
}

/// Plaintext counterpart of [`TunnelUpstreamDialer`]: dials the request's target
/// through the live meow tunnel (same rules/protect seam) and speaks **plain
/// HTTP/1.1** to it — no TLS handshake, no ALPN.
pub(crate) struct PlainUpstreamDialer {
    inner: Arc<meow_tunnel::tunnel::TunnelInner>,
    target: UpstreamTarget,
}

impl PlainUpstreamDialer {
    pub(crate) fn new(
        inner: Arc<meow_tunnel::tunnel::TunnelInner>,
        target: UpstreamTarget,
    ) -> Self {
        Self { inner, target }
    }
}

impl UpstreamDialer for PlainUpstreamDialer {
    fn dial(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<EstablishedUpstream, MitmFailure>> + Send>> {
        let inner = Arc::clone(&self.inner);
        let target = self.target.clone();
        Box::pin(async move {
            let conn = dial_upstream(&inner, &target)
                .await
                .map_err(|e| MitmFailure::new(e.stage(), e.to_string()))?;
            let client = UpstreamClient::establish(conn, HttpProtocol::H1)
                .await
                .map_err(|e| MitmFailure::new(MitmStage::UpstreamHttp, e))?;
            Ok(EstablishedUpstream {
                client,
                proto: HttpProtocol::H1,
            })
        })
    }
}

/// The production upstream trust anchors: Mozilla's root store.
fn production_roots() -> RootCertStore {
    let mut roots = RootCertStore::empty();
    for cert in webpki_root_certs::TLS_SERVER_ROOT_CERTS {
        let _ = roots.add(cert.clone());
    }
    roots
}

static UPSTREAM_TLS: OnceLock<Mutex<UpstreamTlsConfig>> = OnceLock::new();

fn upstream_tls_cell() -> &'static Mutex<UpstreamTlsConfig> {
    UPSTREAM_TLS.get_or_init(|| Mutex::new(UpstreamTlsConfig::with_roots(production_roots())))
}

/// The upstream TLS settings the production dialer uses (strict verification
/// against [`production_roots`]).
pub(crate) fn upstream_tls_config() -> UpstreamTlsConfig {
    upstream_tls_cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Per-session upstream TLS selection: strict [`upstream_tls_config`] unless the
/// session's config snapshot explicitly opted into `skipCertVerify`, in which
/// case the verifier accepts ANY upstream leaf. Never process-wide — the caller
/// passes the flag from its session snapshot each time.
pub(crate) fn upstream_tls_config_for(skip_cert_verify: bool) -> UpstreamTlsConfig {
    let config = upstream_tls_config();
    if skip_cert_verify {
        config.with_skip_cert_verify(true)
    } else {
        config
    }
}

/// Override the upstream TLS settings. Tests point the dialer at a local
/// fixture whose leaf is signed by the test CA; production never calls this.
#[cfg(test)]
pub(crate) fn set_upstream_tls_for_tests(config: UpstreamTlsConfig) {
    *upstream_tls_cell().lock().unwrap_or_else(|e| e.into_inner()) = config;
}

/// Test/opt-in verifier accepting any upstream leaf. Reachable only when
/// [`UpstreamTlsConfig::skip_cert_verify`] is explicitly set.
#[derive(Debug)]
struct SkipServerVerify(Arc<rustls::crypto::CryptoProvider>);

impl ServerCertVerifier for SkipServerVerify {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

// ==================== Todo 8: HTTP/1.1 + HTTP/2 request/response capture ====================
//
// hyper sits between the decrypted client TLS stream (server role) and the
// re-originated upstream TLS stream (client role). ALPN decides the protocol on
// each side independently. The proxy is a streaming **tee**:
//
//  * every response byte is forwarded to the client **unchanged** — same
//    `Content-Encoding`, same payload; hyper only performs HTTP framing;
//  * a *second, separate* copy is retained for capture and, for `gzip`/`br`
//    only, decoded in a **streamed, capped** fashion into the disk-bound copy;
//  * the in-memory ring fields (≤256 B/side preview + `truncated`) are produced
//    here, but the full (≤1 MiB/side) bodies are handed to a **sink seam** that
//    Todo 13 persists to SQLite — no ring/DB is built in this todo.
//
// A malformed upstream response can no longer be raw-forwarded once hyper has
// consumed it, so it degrades to a structured `502` and is recorded with
// `mitm_failed = true`; forwarding never aborts and nothing panics.

use std::convert::Infallible;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::AtomicBool;
use std::task::{Context, Poll};

use futures::executor::block_on;
use futures::{SinkExt, StreamExt};
use http_body_util::combinators::UnsyncBoxBody;
use http_body_util::{BodyExt, Empty, Full};
use hyper::body::{Body, Bytes, Frame, Incoming, SizeHint};
use hyper::client::conn::{http1 as client_http1, http2 as client_http2};
use hyper::header::{
    HeaderName, HeaderValue, CONNECTION, CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_TYPE, HOST,
    SEC_WEBSOCKET_EXTENSIONS, SEC_WEBSOCKET_KEY, TRANSFER_ENCODING, UPGRADE,
};
use tokio_tungstenite::tungstenite::protocol::{Role, WebSocketConfig};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::WebSocketStream;
use hyper::server::conn::{http1 as server_http1, http2 as server_http2};
use hyper::service::Service;
use hyper::{HeaderMap, Request, Response, StatusCode, Uri};
use hyper_util::rt::{TokioExecutor, TokioIo};
use tokio::sync::{Mutex as AsyncMutex, OwnedSemaphorePermit, Semaphore};

use crate::captures::{
    CaptureRule, CaptureRuleSource, StoreRuleSource, RULE_KIND_LOCAL, RULE_KIND_REPLACE,
};
use crate::limits::CAPTURE_BODY_MAX_BYTES;

/// In-memory capture preview per side (also the ring's per-side bound).
pub(crate) const CAPTURE_PREVIEW_MAX_BYTES: usize = 256;
/// In-memory request/response header text per side (ring field bound).
pub(crate) const CAPTURE_HEADERS_MAX_BYTES: usize = 512;
/// hyper h1 head buffer cap (per connection): the client-facing h1 server and
/// the upstream h1 client both parse through this bound. hyper rejects a larger
/// request head with `message head is too large` (`Parse::TooLarge`). hyper's
/// default is ~400 KiB; we had lowered it to 8 KiB for the memory budget, which
/// rejected real app requests carrying large `Cookie`/token heads (device defect
/// 5). 64 KiB accepts those real heads while staying a hard, bounded cap that
/// fits `MITM_SESSION_BUFFER_MAX_BYTES` (device defect 5).
pub(crate) const H1_MAX_BUF_SIZE: usize = 64 * 1024;
/// hyper h1 `max_headers` (header **count**, not bytes) on the client-facing
/// server. hyper's default is 100, too low for real app requests (device defect
/// 5), so we raise it to 256. A request exceeding it is answered with 431.
pub(crate) const H1_MAX_HEADERS: usize = 256;
/// hyper h2 flow-control windows / buffers, explicitly lowered from the 1–5 MiB
/// defaults so one session cannot blow `MITM_SESSION_BUFFER_MAX_BYTES` (T9).
pub(crate) const H2_INITIAL_STREAM_WINDOW_SIZE: u32 = 16 * 1024;
pub(crate) const H2_INITIAL_CONNECTION_WINDOW_SIZE: u32 = 16 * 1024;
pub(crate) const H2_MAX_SEND_BUF_SIZE: usize = 4 * 1024;
/// hyper h2 `SETTINGS_MAX_HEADER_LIST_SIZE`: the bound on the decoded request
/// header list. 4 KiB was far too small for real app requests (large Cookie/
/// token heads, device defect 5), so raise it to 64 KiB while keeping a hard cap
/// that fits `MITM_SESSION_BUFFER_MAX_BYTES`.
pub(crate) const H2_MAX_HEADER_LIST_SIZE: u32 = 64 * 1024;
/// Per-connection h2 accounting asserted in tests to match the T9 budget term.
pub(crate) const H2_PER_CONNECTION_BUDGET_BYTES: u32 = H2_INITIAL_STREAM_WINDOW_SIZE
    + H2_INITIAL_CONNECTION_WINDOW_SIZE
    + H2_MAX_SEND_BUF_SIZE as u32
    + H2_MAX_HEADER_LIST_SIZE;

// ==================== Todo 9: WebSocket frame capture ====================
//
// After an HTTP `Upgrade: websocket` (status `101`, `Sec-WebSocket-*`) the two
// terminated TLS streams are bridged frame-for-frame by `tokio-tungstenite`, and
// every text/binary/ping/pong/close frame is recorded with its direction and a
// **bounded** (≤512 B) payload preview.
//
// ## Extension handling (decided: strip in BOTH directions)
//
// `tungstenite` 0.29 is compiled without the `deflate` feature (see
// `Cargo.toml`), so it cannot speak permessage-deflate. The MITM therefore
// **removes `Sec-WebSocket-Extensions` in both directions**: the client's offer
// never reaches the origin and the origin's answer never reaches the client.
// Both peers thus negotiate compression-less framing and the recorded frames are
// directly parseable. Consequence: **WS does not preserve permessage-deflate**.
//
// ## Buffer bounds (hard, never defaults)
//
// Both tungstenite endpoints are built from an explicit [`WebSocketConfig`].
// `tungstenite`'s defaults (read 128 KiB, write unbounded, message 64 MiB,
// frame 16 MiB) would each blow the per-session budget, so all five knobs are
// configured and summed into [`MITM_SESSION_BUDGET_BYTES`].

/// tungstenite read buffer capacity, per endpoint. Hard cap.
pub(crate) const WS_READ_BUFFER_SIZE: usize = 4096;
/// tungstenite write-buffer flush target, per endpoint. Must stay **below**
/// [`WS_MAX_WRITE_BUFFER_SIZE`] or tungstenite asserts/panics at construction.
pub(crate) const WS_WRITE_BUFFER_SIZE: usize = 8192;
/// tungstenite write-buffer hard cap (backpressure), per endpoint. The real
/// retained ceiling charged to the session budget.
pub(crate) const WS_MAX_WRITE_BUFFER_SIZE: usize = 16384;
/// Largest incoming message accepted, per endpoint.
pub(crate) const WS_MAX_MESSAGE_SIZE: usize = 16384;
/// Largest incoming frame accepted, per endpoint.
pub(crate) const WS_MAX_FRAME_SIZE: usize = 16384;
/// In-memory frame payload preview cap. Over-limit payloads are truncated to
/// this many bytes and flagged; the frame itself is still forwarded intact.
pub(crate) const WS_PREVIEW_MAX_BYTES: usize = 512;

/// One tungstenite endpoint's charged bytes: read + write hard cap + message
/// accumulation + frame accumulation.
pub(crate) const WS_PER_SIDE_BUDGET_BYTES: usize = WS_READ_BUFFER_SIZE
    + WS_MAX_WRITE_BUFFER_SIZE
    + WS_MAX_MESSAGE_SIZE
    + WS_MAX_FRAME_SIZE;
/// rustls `set_buffer_limit` caps **both** the plaintext and TLS buffers, per
/// connection; two connections (client-side + upstream-side) are live per MITM
/// session.
pub(crate) const RUSTLS_BUFFER_LIMIT_BYTES: usize = 8192;

/// T9 per-session budget terms (see `.omo/plans/proxy-http-capture.md` todo 9).
pub(crate) const MITM_WS_TWO_SIDES_BYTES: usize = 2 * WS_PER_SIDE_BUDGET_BYTES; // 106_496
pub(crate) const MITM_RUSTLS_TWO_CONNS_BYTES: usize = 2 * 2 * RUSTLS_BUFFER_LIMIT_BYTES; // 32_768
pub(crate) const MITM_H1_TWO_CONNS_BYTES: usize = 2 * 2 * H1_MAX_BUF_SIZE; // 262_144
pub(crate) const MITM_H2_TWO_CONNS_BYTES: usize = 2 * (H2_PER_CONNECTION_BUDGET_BYTES as usize); // 204_800
/// Sum of every per-session buffer knob. A hard `const` assertion below proves it
/// fits [`crate::limits::MITM_SESSION_BUFFER_MAX_BYTES`]; if any term regresses
/// (or a knob silently goes back to a default) this stops compiling.
pub(crate) const MITM_SESSION_BUDGET_BYTES: usize = MITM_WS_TWO_SIDES_BYTES
    + MITM_RUSTLS_TWO_CONNS_BYTES
    + MITM_H1_TWO_CONNS_BYTES
    + MITM_H2_TWO_CONNS_BYTES;

const _: () = assert!(
    MITM_SESSION_BUDGET_BYTES <= crate::limits::MITM_SESSION_BUFFER_MAX_BYTES,
    "MITM per-session buffer budget exceeds MITM_SESSION_BUFFER_MAX_BYTES"
);
const _: () = assert!(
    WS_WRITE_BUFFER_SIZE < WS_MAX_WRITE_BUFFER_SIZE,
    "tungstenite requires write_buffer_size < max_write_buffer_size"
);

/// Frame direction relative to the MITM: `ClientToServer` are frames read from
/// the browser, `ServerToClient` are frames read from the origin.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum WsDirection {
    ClientToServer,
    ServerToClient,
}

/// One recorded WebSocket frame (or complete message, since tungstenite
/// reassembles fragments). Payload retention is bounded to
/// [`WS_PREVIEW_MAX_BYTES`]; `payload_len` always carries the true length so an
/// over-limit frame is both accounted for exactly and never buffered in full.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct WsFrameRecord {
    pub direction: WsDirection,
    /// `"text" | "binary" | "ping" | "pong" | "close" | "frame"`.
    pub opcode: &'static str,
    pub payload_len: u64,
    pub preview: Vec<u8>,
    pub truncated: bool,
    pub at_ms: u64,
}

/// Bounded sink seam for recorded WS frames. The capture store (todo 12/13)
/// installs the durable implementor; the shipping default is a no-op and the
/// dataplane never blocks on it.
pub(crate) trait WsFrameSink: Send + Sync {
    fn on_ws_open(&self, _host: &str, _conn_id: &str, _method: &str, _url: &str) {}

    fn on_ws_frame(&self, _host: &str, _conn_id: &str, _frame: &WsFrameRecord) {}

    fn on_ws_close(&self, _host: &str, _conn_id: &str) {}
}

struct NoopWsFrameSink;

impl WsFrameSink for NoopWsFrameSink {}

pub(crate) fn noop_ws_frame_sink() -> Arc<dyn WsFrameSink> {
    Arc::new(NoopWsFrameSink)
}

static WS_FRAME_SINK: OnceLock<Mutex<Arc<dyn WsFrameSink>>> = OnceLock::new();

fn ws_frame_sink_cell() -> &'static Mutex<Arc<dyn WsFrameSink>> {
    WS_FRAME_SINK.get_or_init(|| Mutex::new(Arc::new(NoopWsFrameSink)))
}

/// Current WS frame sink (cloned `Arc`).
pub(crate) fn ws_frame_sink() -> Arc<dyn WsFrameSink> {
    ws_frame_sink_cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Install the process-level WS frame sink (todo 12/13 / tests).
pub(crate) fn set_ws_frame_sink(sink: Arc<dyn WsFrameSink>) {
    *ws_frame_sink_cell().lock().unwrap_or_else(|e| e.into_inner()) = sink;
}

/// Restore the no-op sink (tests).
#[cfg(test)]
pub(crate) fn reset_ws_frame_sink() {
    set_ws_frame_sink(Arc::new(NoopWsFrameSink));
}

/// The explicit, never-default tungstenite configuration used on **both**
/// endpoints. Kept as a function (not a `const`) because the builder methods are
/// not `const`, and both endpoints must observe the identical bounds.
pub(crate) fn ws_config() -> WebSocketConfig {
    let config = WebSocketConfig::default()
        .read_buffer_size(WS_READ_BUFFER_SIZE)
        .write_buffer_size(WS_WRITE_BUFFER_SIZE)
        .max_write_buffer_size(WS_MAX_WRITE_BUFFER_SIZE)
        .max_message_size(Some(WS_MAX_MESSAGE_SIZE))
        .max_frame_size(Some(WS_MAX_FRAME_SIZE));
    debug_assert!(
        config.write_buffer_size < config.max_write_buffer_size,
        "tungstenite would panic on this config"
    );
    config
}

/// Boxed error used across the MITM HTTP path (hyper error, IO error, …).
pub(crate) type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Boxed request body shared by the h1/h2 upstream clients. Boxing lets the
/// normal tee'd body and the WebSocket upgrade's empty body flow through the
/// **same** established connection type (the sender's body type is fixed).
pub(crate) type UpstreamBody = UnsyncBoxBody<Bytes, BoxError>;

/// The wire protocol negotiated by ALPN on one side of the bridge.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HttpProtocol {
    H1,
    H2,
}

impl HttpProtocol {
    /// `h2` when the peer offered ALPN `h2`, otherwise HTTP/1.1. An absent or
    /// unknown ALPN is **not** h2 (h2 requires explicit negotiation).
    pub(crate) fn from_alpn(alpn: Option<&[u8]>) -> Self {
        if alpn == Some(b"h2".as_slice()) {
            HttpProtocol::H2
        } else {
            HttpProtocol::H1
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            HttpProtocol::H1 => "h1",
            HttpProtocol::H2 => "h2",
        }
    }
}

/// One captured HTTP exchange, shaped for the capture store (Todo 12/13).
///
/// The ring will retain only the `*_preview`/`truncated` fields; the full
/// `req_body`/`resp_body` (≤ [`CAPTURE_BODY_MAX_BYTES`] each) are disk-bound and
/// handed to the [`CaptureSink`] so Todo 13 can persist them without the ring
/// ever holding a bulk payload resident.
#[derive(Clone, Debug)]
pub(crate) struct CaptureRecord {
    pub record_id: u64,
    /// Foreign key into `requests.*`; `0` = no matching flow record.
    pub request_record_id: u64,
    pub conn_id: String,
    pub host: String,
    pub method: String,
    pub scheme: String,
    pub url: String,
    pub status_code: u16,
    pub protocol: String,
    pub req_headers: String,
    pub resp_headers: String,
    pub req_body_preview: Vec<u8>,
    pub resp_body_preview: Vec<u8>,
    pub req_body: Vec<u8>,
    pub resp_body: Vec<u8>,
    pub req_bytes: u64,
    pub resp_bytes: u64,
    pub content_type: String,
    pub started_at_ms: u64,
    pub finished_at_ms: u64,
    pub duration_ms: u64,
    pub truncated: bool,
    pub mitm_failed: bool,
    /// Stage/reason the capture degraded to pass-through; empty when it did not
    /// fail. First non-empty reason wins (see `ExchangeCapture::mark_failed`).
    pub failure_reason: String,
    pub ws_frames: Vec<WsFrameRecord>,
}

/// Bounded sink seam: captures are pushed here, nothing is ever emitted
/// per-packet and the sink never blocks the dataplane. Todo 13 installs the
/// SQLite-backed implementor; the shipping default is a no-op.
pub(crate) trait CaptureSink: Send + Sync {
    fn on_capture(&self, _record: CaptureRecord) {}
}

struct NoopCaptureSink;

impl CaptureSink for NoopCaptureSink {}

pub(crate) fn noop_capture_sink() -> Arc<dyn CaptureSink> {
    Arc::new(NoopCaptureSink)
}

static CAPTURE_SINK: OnceLock<Mutex<Arc<dyn CaptureSink>>> = OnceLock::new();

fn capture_sink_cell() -> &'static Mutex<Arc<dyn CaptureSink>> {
    CAPTURE_SINK.get_or_init(|| Mutex::new(Arc::new(NoopCaptureSink)))
}

/// Current capture sink (cloned `Arc`).
pub(crate) fn capture_sink() -> Arc<dyn CaptureSink> {
    capture_sink_cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Install a capture sink (Todo 13 / tests).
pub(crate) fn set_capture_sink(sink: Arc<dyn CaptureSink>) {
    *capture_sink_cell().lock().unwrap_or_else(|e| e.into_inner()) = sink;
}

/// Restore the no-op sink (tests).
#[cfg(test)]
pub(crate) fn reset_capture_sink() {
    set_capture_sink(Arc::new(NoopCaptureSink));
}

static CAPTURE_RECORD_SEQ: AtomicU64 = AtomicU64::new(0);

fn next_capture_record_id() -> u64 {
    CAPTURE_RECORD_SEQ.fetch_add(1, Ordering::Relaxed) + 1
}

/// Content codings the capture copy can decode. Forwarding never uses this.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum BodyEncoding {
    Identity,
    Gzip,
    Brotli,
}

fn body_encoding(headers: &HeaderMap) -> BodyEncoding {
    let Some(value) = headers.get(CONTENT_ENCODING) else {
        return BodyEncoding::Identity;
    };
    let Ok(text) = value.to_str() else {
        return BodyEncoding::Identity;
    };
    match text.trim().to_ascii_lowercase().as_str() {
        "gzip" | "x-gzip" => BodyEncoding::Gzip,
        "br" => BodyEncoding::Brotli,
        _ => BodyEncoding::Identity,
    }
}

/// Decoded capture copy of one body side.
#[derive(Default)]
struct CapturedBody {
    full: Vec<u8>,
    preview: Vec<u8>,
    bytes: u64,
    truncated: bool,
}

#[derive(Default)]
struct BodyBuffer {
    raw: Vec<u8>,
    total: u64,
}

/// Tee-owned capture state for one body side: raw wire bytes are appended as
/// they pass through, capped at [`CAPTURE_BODY_MAX_BYTES`]; `total` always
/// counts the true on-the-wire length so `*_bytes` is exact even past the cap.
struct BodyCapture {
    enabled: bool,
    encoding: BodyEncoding,
    cap: usize,
    buffer: Mutex<BodyBuffer>,
}

impl BodyCapture {
    fn new(enabled: bool, encoding: BodyEncoding, cap: usize) -> Arc<Self> {
        Arc::new(Self {
            enabled,
            encoding,
            cap,
            buffer: Mutex::new(BodyBuffer::default()),
        })
    }

    fn push(&self, data: &[u8]) {
        if !self.enabled {
            return;
        }
        let mut buffer = self.buffer.lock().unwrap_or_else(|e| e.into_inner());
        buffer.total += data.len() as u64;
        if buffer.raw.len() < self.cap {
            let room = self.cap - buffer.raw.len();
            let take = room.min(data.len());
            buffer.raw.extend_from_slice(&data[..take]);
        }
    }

    /// Finalize this side: decode a *copy*, streaming and capped, never the
    /// whole payload and never the forwarded bytes.
    fn finish(&self) -> CapturedBody {
        let (raw, total) = {
            let buffer = self.buffer.lock().unwrap_or_else(|e| e.into_inner());
            (buffer.raw.clone(), buffer.total)
        };
        if !self.enabled {
            return CapturedBody {
                full: Vec::new(),
                preview: Vec::new(),
                bytes: total,
                truncated: false,
            };
        }
        let raw_truncated = total > raw.len() as u64;
        let (full, decode_truncated) = decode_capture(self.encoding, &raw, self.cap);
        let preview = full[..full.len().min(CAPTURE_PREVIEW_MAX_BYTES)].to_vec();
        CapturedBody {
            full,
            preview,
            bytes: total,
            truncated: raw_truncated || decode_truncated,
        }
    }
}

/// Decode a captured body copy with a hard output cap. This is the decompression
/// bomb guard: the decoder is read in bounded chunks and stops at
/// [`CAPTURE_BODY_MAX_BYTES`], setting the truncated flag. The input is an
/// in-memory slice, and the inner reader is always ready, so the future never
/// yields and can be driven to completion without a reactor.
fn decode_capture(encoding: BodyEncoding, raw: &[u8], cap: usize) -> (Vec<u8>, bool) {
    use async_compression::tokio::bufread::{BrotliDecoder, GzipDecoder};
    use tokio::io::{AsyncRead, AsyncReadExt, BufReader};

    async fn read_capped<R: AsyncRead + Unpin>(reader: &mut R, cap: usize) -> (Vec<u8>, bool) {
        let mut out = Vec::new();
        let mut buf = [0u8; 8192];
        let mut truncated = false;
        loop {
            match reader.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    if out.len() + n > cap {
                        let take = cap - out.len();
                        out.extend_from_slice(&buf[..take]);
                        truncated = true;
                        break;
                    }
                    out.extend_from_slice(&buf[..n]);
                }
                // A malformed compressed stream is not fatal: keep what decoded.
                Err(_) => {
                    truncated = true;
                    break;
                }
            }
        }
        (out, truncated)
    }

    match encoding {
        BodyEncoding::Identity => (raw.to_vec(), false),
        BodyEncoding::Gzip => {
            let mut decoder = GzipDecoder::new(BufReader::new(raw));
            block_on(read_capped(&mut decoder, cap))
        }
        BodyEncoding::Brotli => {
            let mut decoder = BrotliDecoder::new(BufReader::new(raw));
            block_on(read_capped(&mut decoder, cap))
        }
    }
}

fn headers_to_string(headers: &HeaderMap, cap: usize) -> String {
    let mut out = String::new();
    for (name, value) in headers.iter() {
        let line = format!("{name}: {}\n", value.to_str().unwrap_or("<binary>"));
        if out.len() + line.len() > cap {
            out.push_str("...truncated");
            break;
        }
        out.push_str(&line);
    }
    out
}

/// Headers that must not be forwarded across a version/connection boundary.
fn is_hop_by_hop(name: &HeaderName) -> bool {
    matches!(
        name.as_str(),
        "connection"
            | "proxy-connection"
            | "keep-alive"
            | "transfer-encoding"
            | "te"
            | "trailer"
            | "upgrade"
    )
}

/// Forward request headers to the re-originated upstream request. Hop-by-hop
/// headers never cross; `Content-Length` is preserved because the body is a
/// byte-for-byte tee under unchanged framing, and is dropped only when a
/// client `Transfer-Encoding` makes the tee re-frame the body as chunked.
fn copy_forward_request_headers(src: &HeaderMap, dst: &mut HeaderMap) {
    let reframed_chunked = src.contains_key(TRANSFER_ENCODING);
    for (name, value) in src.iter() {
        if is_hop_by_hop(name) {
            continue;
        }
        if name == CONTENT_LENGTH && reframed_chunked {
            continue;
        }
        dst.append(name, value.clone());
    }
}

fn host_header(headers: &HeaderMap) -> Option<String> {
    headers
        .get(HOST)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

#[derive(Clone, Copy)]
enum Side {
    Request,
    Response,
}

#[derive(Clone, Default)]
struct RequestMeta {
    method: String,
    url: String,
    headers: String,
}

#[derive(Clone, Default)]
struct ResponseMeta {
    status: u16,
    headers: String,
    content_type: String,
}

/// Per-exchange capture state shared by the request and response tees. When both
/// body sides complete (or the exchange is marked failed) exactly one record is
/// emitted through the sink.
struct ExchangeCapture {
    sink: Arc<dyn CaptureSink>,
    protocol: &'static str,
    host: String,
    scheme: String,
    conn_id: String,
    request_record_id: u64,
    started_at_ms: u64,
    request_meta: Mutex<RequestMeta>,
    response_meta: Mutex<Option<ResponseMeta>>,
    req_body: Arc<BodyCapture>,
    resp_body: Mutex<Option<Arc<BodyCapture>>>,
    sides_done: AtomicUsize,
    emitted: AtomicBool,
    failed: AtomicBool,
    failure_reason: Mutex<String>,
}

impl ExchangeCapture {
    #[allow(clippy::too_many_arguments)]
    fn new(
        sink: Arc<dyn CaptureSink>,
        protocol: HttpProtocol,
        scheme: &'static str,
        host: &str,
        conn_id: &str,
        request_record_id: u64,
        method: &str,
        url: &str,
        req_headers: &HeaderMap,
        req_body: Arc<BodyCapture>,
        started_at_ms: u64,
    ) -> Self {
        Self {
            sink,
            protocol: protocol.as_str(),
            host: host.to_string(),
            scheme: scheme.to_string(),
            conn_id: conn_id.to_string(),
            request_record_id,
            started_at_ms,
            request_meta: Mutex::new(RequestMeta {
                method: method.to_string(),
                url: url.to_string(),
                headers: headers_to_string(req_headers, CAPTURE_HEADERS_MAX_BYTES),
            }),
            response_meta: Mutex::new(None),
            req_body,
            resp_body: Mutex::new(None),
            sides_done: AtomicUsize::new(0),
            emitted: AtomicBool::new(false),
            failed: AtomicBool::new(false),
            failure_reason: Mutex::new(String::new()),
        }
    }

    fn set_response(
        &self,
        status: u16,
        headers: &HeaderMap,
        content_type: &str,
        body: Arc<BodyCapture>,
    ) {
        *self
            .response_meta
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(ResponseMeta {
            status,
            headers: headers_to_string(headers, CAPTURE_HEADERS_MAX_BYTES),
            content_type: content_type.to_string(),
        });
        *self.resp_body.lock().unwrap_or_else(|e| e.into_inner()) = Some(body);
    }

    fn mark_failed(&self, reason: &str) {
        self.failed.store(true, Ordering::Release);
        if !reason.trim().is_empty() {
            let mut slot = self.failure_reason.lock().unwrap_or_else(|e| e.into_inner());
            if slot.is_empty() {
                *slot = reason.to_string();
            }
        }
        // A cancellation is the client/connection aborting, not a capture defect;
        // keep it at debug so real failures are not drowned out.
        let level = if is_cancellation_reason(reason) { 0 } else { 2 };
        crate::log_message(level, &format!("proxy.mitm: http capture failed: {reason}"));
    }

    fn side_done(&self, side: Side) {
        let _ = side;
        if self.sides_done.fetch_add(1, Ordering::AcqRel) + 1 >= 2 {
            self.emit(false);
        }
    }

    fn emit(&self, failed: bool) {
        if self.emitted.swap(true, Ordering::AcqRel) {
            return;
        }
        let request_meta = self
            .request_meta
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let response_meta = self
            .response_meta
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let request = self.req_body.finish();
        let response = self
            .resp_body
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
            .map(|b| b.finish())
            .unwrap_or_default();
        let failed = failed || self.failed.load(Ordering::Acquire);
        let now = crate::now_ms();
        let record = CaptureRecord {
            record_id: next_capture_record_id(),
            request_record_id: self.request_record_id,
            conn_id: self.conn_id.clone(),
            host: self.host.clone(),
            method: request_meta.method,
            scheme: self.scheme.clone(),
            url: request_meta.url,
            status_code: response_meta.as_ref().map(|m| m.status).unwrap_or(0),
            protocol: self.protocol.to_string(),
            req_headers: request_meta.headers,
            resp_headers: response_meta
                .as_ref()
                .map(|m| m.headers.clone())
                .unwrap_or_default(),
            req_body_preview: request.preview,
            resp_body_preview: response.preview,
            req_body: request.full,
            resp_body: response.full,
            req_bytes: request.bytes,
            resp_bytes: response.bytes,
            content_type: response_meta
                .as_ref()
                .map(|m| m.content_type.clone())
                .unwrap_or_default(),
            started_at_ms: self.started_at_ms,
            finished_at_ms: now,
            duration_ms: now.saturating_sub(self.started_at_ms),
            truncated: request.truncated || response.truncated,
            mitm_failed: failed,
            failure_reason: self
                .failure_reason
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone(),
            ws_frames: Vec::new(),
        };
        self.sink.on_capture(record);
    }
}

/// True when a capture failure reason is hyper's cancellation (the client or the
/// upstream connection aborted), which is expected during normal closes and is
/// not a capture defect worth a warning.
fn is_cancellation_reason(reason: &str) -> bool {
    let lower = reason.to_ascii_lowercase();
    lower.contains("canceled") || lower.contains("cancelled")
}

/// Streaming body wrapper that forwards every frame **unchanged** while also
/// feeding the capture copy. The forwarded frame is returned as-is, so the wire
/// bytes and `Content-Encoding` are identical to upstream.
struct TeeBody<B> {
    inner: B,
    capture: Arc<BodyCapture>,
    exchange: Arc<ExchangeCapture>,
    side: Side,
    permit: Option<OwnedSemaphorePermit>,
    finished: bool,
}

impl<B> TeeBody<B> {
    fn new(
        inner: B,
        capture: Arc<BodyCapture>,
        exchange: Arc<ExchangeCapture>,
        side: Side,
        permit: Option<OwnedSemaphorePermit>,
    ) -> Self {
        Self {
            inner,
            capture,
            exchange,
            side,
            permit,
            finished: false,
        }
    }

    fn finish_side(&mut self) {
        if self.finished {
            return;
        }
        self.finished = true;
        self.permit.take();
        self.exchange.side_done(self.side);
    }
}

impl<B> Body for TeeBody<B>
where
    B: Body<Data = Bytes> + Unpin,
    B::Error: Into<BoxError>,
{
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, BoxError>>> {
        let this = self.get_mut();
        match Pin::new(&mut this.inner).poll_frame(cx) {
            Poll::Ready(Some(Ok(frame))) => {
                if let Some(data) = frame.data_ref() {
                    this.capture.push(data);
                }
                Poll::Ready(Some(Ok(frame)))
            }
            Poll::Ready(Some(Err(error))) => {
                this.finish_side();
                Poll::Ready(Some(Err(error.into())))
            }
            Poll::Ready(None) => {
                this.finish_side();
                Poll::Ready(None)
            }
            Poll::Pending => Poll::Pending,
        }
    }

    fn is_end_stream(&self) -> bool {
        self.finished || self.inner.is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.inner.size_hint()
    }
}

impl<B> Drop for TeeBody<B> {
    fn drop(&mut self) {
        self.finish_side();
    }
}

/// Response body returned to the downstream client: either a tee'd upstream
/// stream (or a rule-generated plaintext body, boxed the same way) or a locally
/// generated empty body (the structured 502 degradation).
enum BridgeBody {
    Tee(TeeBody<UpstreamBody>),
    Empty(Empty<Bytes>),
}

impl Body for BridgeBody {
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, BoxError>>> {
        match self.get_mut() {
            BridgeBody::Tee(body) => Pin::new(body).poll_frame(cx),
            BridgeBody::Empty(body) => match Pin::new(body).poll_frame(cx) {
                Poll::Ready(Some(Ok(frame))) => Poll::Ready(Some(Ok(frame))),
                Poll::Ready(Some(Err(never))) => match never {},
                Poll::Ready(None) => Poll::Ready(None),
                Poll::Pending => Poll::Pending,
            },
        }
    }

    fn is_end_stream(&self) -> bool {
        match self {
            BridgeBody::Tee(body) => body.is_end_stream(),
            BridgeBody::Empty(body) => body.is_end_stream(),
        }
    }

    fn size_hint(&self) -> SizeHint {
        match self {
            BridgeBody::Tee(body) => body.size_hint(),
            BridgeBody::Empty(body) => body.size_hint(),
        }
    }
}

fn simple_response(status: StatusCode) -> Response<BridgeBody> {
    let mut response = Response::new(BridgeBody::Empty(Empty::new()));
    *response.status_mut() = status;
    response
}

/// The 502-style response sent to the client when upstream re-origination fails.
/// Reads [`UPSTREAM_FAILURE_STATUS`] so the documented failure contract has one
/// source of truth instead of a duplicated status literal.
fn upstream_failure_response() -> Response<BridgeBody> {
    simple_response(StatusCode::from_u16(UPSTREAM_FAILURE_STATUS).unwrap_or(StatusCode::BAD_GATEWAY))
}

/// The established upstream HTTP client connection, one per bridge.
pub(crate) enum UpstreamClient {
    H1 {
        sender: AsyncMutex<client_http1::SendRequest<UpstreamBody>>,
        gate: Arc<Semaphore>,
    },
    H2(client_http2::SendRequest<UpstreamBody>),
}

impl UpstreamClient {
    async fn establish<IO>(io: IO, protocol: HttpProtocol) -> Result<Self, String>
    where
        IO: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let io = TokioIo::new(io);
        match protocol {
            HttpProtocol::H1 => {
                let mut builder = client_http1::Builder::new();
                builder.max_buf_size(H1_MAX_BUF_SIZE);
                let (sender, conn) = tokio::time::timeout(
                    UPSTREAM_HTTP_HANDSHAKE_TIMEOUT,
                    builder.handshake::<_, UpstreamBody>(io),
                )
                .await
                .map_err(|_| "upstream h1 handshake timed out".to_string())?
                .map_err(|e| format!("upstream h1 handshake: {e}"))?;
                tokio::spawn(async move {
                    let _ = conn.with_upgrades().await;
                });
                Ok(UpstreamClient::H1 {
                    sender: AsyncMutex::new(sender),
                    gate: Arc::new(Semaphore::new(1)),
                })
            }
            HttpProtocol::H2 => {
                let mut builder = client_http2::Builder::new(TokioExecutor::new());
                configure_h2_client(&mut builder);
                let (sender, conn) = tokio::time::timeout(
                    UPSTREAM_HTTP_HANDSHAKE_TIMEOUT,
                    builder.handshake::<_, UpstreamBody>(io),
                )
                .await
                .map_err(|_| "upstream h2 handshake timed out".to_string())?
                .map_err(|e| format!("upstream h2 handshake: {e}"))?;
                tokio::spawn(async move {
                    let _ = conn.await;
                });
                Ok(UpstreamClient::H2(sender))
            }
        }
    }

    /// Send one request and return the response. The h1 gate is released only
    /// when the response body completes (dropped with the tee), so a h1 upstream
    /// connection is never asked to start a second request mid-body.
    async fn send(
        &self,
        req: Request<UpstreamBody>,
    ) -> Result<(Response<Incoming>, Option<OwnedSemaphorePermit>), BoxError> {
        match self {
            UpstreamClient::H1 { sender, gate } => {
                let permit = Arc::clone(gate)
                    .acquire_owned()
                    .await
                    .map_err(|e| Box::new(e) as BoxError)?;
                let mut sender = sender.lock().await;
                let response = sender.send_request(req).await?;
                drop(sender);
                Ok((response, Some(permit)))
            }
            UpstreamClient::H2(sender) => {
                let mut sender = sender.clone();
                let response = sender.send_request(req).await?;
                Ok((response, None))
            }
        }
    }

    /// Whether the origin has closed this connection (`Connection: close`, idle
    /// close, or the connection task ending). A closed sender rejects the next
    /// request with hyper's `Kind::Canceled`, so the bridge re-dials instead of
    /// reusing it.
    async fn is_closed(&self) -> bool {
        match self {
            UpstreamClient::H1 { sender, .. } => sender.lock().await.is_closed(),
            UpstreamClient::H2(sender) => sender.is_closed(),
        }
    }
}

/// An established upstream HTTP client plus the wire protocol its TLS ALPN
/// negotiated.
pub(crate) struct EstablishedUpstream {
    pub(crate) client: UpstreamClient,
    pub(crate) proto: HttpProtocol,
}

/// Dials + TLS-handshakes the upstream connection on demand. Deferring the dial
/// until a request actually needs upstream is what lets a `kind:"local"` rewrite
/// short-circuit **before any upstream socket is opened** (todo 15).
pub(crate) trait UpstreamDialer: Send + Sync {
    fn dial(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<EstablishedUpstream, MitmFailure>> + Send>>;
}

/// Everything the bridge needs beyond the two TLS streams.
#[derive(Clone)]
pub(crate) struct BridgeContext {
    pub host: String,
    /// The URL scheme this bridge presents to the capture/rule layer: `"https"`
    /// for TLS-terminated flows, `"http"` for the plaintext branch. It is also
    /// the plaintext/TLS discriminator the dispatch layer reads (`scheme ==
    /// "http"` means no CA was needed).
    pub scheme: &'static str,
    pub conn_id: String,
    pub request_record_id: u64,
    pub src: Option<SocketAddr>,
    pub dst: Option<SocketAddr>,
    pub capture_body: bool,
    pub capture_ws: bool,
    pub capture_h2: bool,
    pub max_body_bytes: usize,
    pub started_at_ms: u64,
    pub sink: Option<Arc<dyn CaptureSink>>,
    pub ws_sink: Option<Arc<dyn WsFrameSink>>,
    rule_source: Arc<dyn CaptureRuleSource>,
}

impl BridgeContext {
    pub(crate) fn new(
        host: impl Into<String>,
        conn_id: impl Into<String>,
        request_record_id: u64,
    ) -> Self {
        Self {
            host: host.into(),
            scheme: "https",
            conn_id: conn_id.into(),
            request_record_id,
            src: None,
            dst: None,
            capture_body: true,
            capture_ws: true,
            capture_h2: true,
            max_body_bytes: CAPTURE_BODY_MAX_BYTES,
            started_at_ms: crate::now_ms(),
            sink: None,
            ws_sink: None,
            rule_source: Arc::new(StoreRuleSource),
        }
    }

    /// Present this bridge under `scheme` (`"http"` for the plaintext branch,
    /// `"https"` otherwise). This also selects the plaintext semantics the
    /// dispatch layer keys on.
    pub(crate) fn with_scheme(mut self, s: &'static str) -> Self {
        self.scheme = s;
        self
    }

    /// Serve requests with a fixed rule snapshot instead of the live store. Used
    /// by tests (the store is process-global, the bridge runs on worker threads).
    pub(crate) fn with_rule_source(mut self, source: Arc<dyn CaptureRuleSource>) -> Self {
        self.rule_source = source;
        self
    }

    /// Attach the bridged socket endpoints so the session can register a
    /// synthetic `requests` skeleton keyed to this flow's `conn_id`.
    pub(crate) fn with_endpoints(mut self, src: SocketAddr, dst: SocketAddr) -> Self {
        self.src = Some(src);
        self.dst = Some(dst);
        self
    }

    pub(crate) fn with_capture_body(mut self, on: bool) -> Self {
        self.capture_body = on;
        self
    }

    pub(crate) fn with_capture_ws(mut self, on: bool) -> Self {
        self.capture_ws = on;
        self
    }

    pub(crate) fn with_capture_h2(mut self, on: bool) -> Self {
        self.capture_h2 = on;
        self
    }

    pub(crate) fn with_max_body_bytes(mut self, cap: usize) -> Self {
        self.max_body_bytes = cap;
        self
    }

    /// Route captures for this bridge to `sink`; when unset the process sink is
    /// used. A per-bridge sink keeps tests/parallel flows isolated.
    pub(crate) fn with_sink(mut self, sink: Arc<dyn CaptureSink>) -> Self {
        self.sink = Some(sink);
        self
    }

    /// Route WebSocket frame records for this bridge to `sink`; when unset the
    /// process sink is used.
    pub(crate) fn with_ws_sink(mut self, sink: Arc<dyn WsFrameSink>) -> Self {
        self.ws_sink = Some(sink);
        self
    }
}

struct BridgeState {
    sink: Arc<dyn CaptureSink>,
    ws_sink: Arc<dyn WsFrameSink>,
    host: String,
    scheme: &'static str,
    conn_id: String,
    request_record_id: u64,
    capture_body: bool,
    capture_ws: bool,
    capture_h2: bool,
    body_cap: usize,
    started_at_ms: u64,
    client_proto: HttpProtocol,
    rule_source: Arc<dyn CaptureRuleSource>,
    upstream: AsyncMutex<Option<Arc<EstablishedUpstream>>>,
    dialer: Option<Arc<dyn UpstreamDialer>>,
    last_method: std::sync::Mutex<Option<String>>,
}

impl BridgeState {
    /// The sink an exchange on this connection records through: HTTP/2
    /// exchanges are suppressed when `captureH2` is off (forwarding is
    /// unaffected).
    fn exchange_sink(&self) -> Arc<dyn CaptureSink> {
        if self.client_proto == HttpProtocol::H2 && !self.capture_h2 {
            noop_capture_sink()
        } else {
            Arc::clone(&self.sink)
        }
    }
    /// Resolve the upstream client, dialing through the tunnel on first use and
    /// re-dialing whenever the cached connection has been closed by the origin
    /// (`Connection: close`, idle close). A `kind:"local"` rewrite never reaches
    /// here, so it opens no socket. The liveness check runs before the caller
    /// consumes the request body, so a stale connection never costs it.
    async fn upstream_client(&self) -> Result<Arc<EstablishedUpstream>, MitmFailure> {
        let mut cached = self.upstream.lock().await;
        if let Some(current) = cached.as_ref() {
            if !current.client.is_closed().await {
                return Ok(Arc::clone(current));
            }
        }
        let Some(dialer) = self.dialer.as_ref() else {
            return Err(MitmFailure::new(
                MitmStage::UpstreamDial,
                "bridge has no upstream",
            ));
        };
        let fresh = Arc::new(dialer.dial().await?);
        *cached = Some(Arc::clone(&fresh));
        Ok(fresh)
    }

    async fn handle(&self, req: Request<Incoming>) -> Response<BridgeBody> {
        if let Ok(mut slot) = self.last_method.lock() {
            *slot = Some(req.method().as_str().to_string());
        }
        if is_websocket_upgrade(&req) {
            return self.handle_websocket(req).await;
        }
        let method = req.method().clone();
        let req_headers = req.headers().clone();
        let path = req
            .uri()
            .path_and_query()
            .map(|pq| pq.as_str().to_string())
            .unwrap_or_else(|| "/".to_string());
        let host = host_header(&req_headers).unwrap_or_else(|| self.host.clone());
        let url = format!("{}://{host}{path}", self.scheme);
        // Exact-URL (+ optional method) match against the stored *enabled* rules.
        // The source hands back a snapshot and counts the hit; no lock is held
        // across the dial below.
        let rule = self.rule_source.match_rule(method.as_str(), &url);
        let req_capture = BodyCapture::new(self.capture_body, body_encoding(&req_headers), self.body_cap);
        let exchange = Arc::new(ExchangeCapture::new(
            self.exchange_sink(),
            self.client_proto,
            self.scheme,
            &self.host,
            &self.conn_id,
            self.request_record_id,
            method.as_str(),
            &url,
            &req_headers,
            Arc::clone(&req_capture),
            self.started_at_ms,
        ));

        if let Some(rule) = rule.as_ref().filter(|r| r.kind == RULE_KIND_LOCAL) {
            return serve_local_rule(rule, self.capture_body, self.body_cap, exchange, req.into_body());
        }

        // Only now resolve the upstream connection, dialing on first use.
        let upstream = match self.upstream_client().await {
            Ok(upstream) => upstream,
            Err(e) => {
                exchange.mark_failed(&e.to_string());
                record_mitm_failed(&format!("http upstream: {e}"));
                exchange.emit(true);
                return upstream_failure_response();
            }
        };
        let upstream_proto = upstream.proto;

        let upstream_body = TeeBody::new(
            req.into_body(),
            Arc::clone(&req_capture),
            Arc::clone(&exchange),
            Side::Request,
            None,
        );
        let origin: Uri = match path.parse() {
            Ok(uri) => uri,
            Err(_) => Uri::from_static("/"),
        };
        let upstream_uri = match upstream_proto {
            HttpProtocol::H2 => format!("{}://{host}{path}", self.scheme)
                .parse()
                .unwrap_or(origin),
            HttpProtocol::H1 => origin,
        };
        let mut builder = Request::builder().method(method).uri(upstream_uri);
        match builder.headers_mut() {
            Some(dst) => {
                copy_forward_request_headers(&req_headers, dst);
                if self.scheme == "http" && is_h2c_upgrade(&req_headers) {
                    dst.remove("http2-settings");
                }
                if !dst.contains_key(HOST) {
                    if let Ok(value) = HeaderValue::from_str(&host) {
                        dst.insert(HOST, value);
                    }
                }
            }
            None => {
                exchange.mark_failed("request header build failed");
                exchange.emit(true);
                return simple_response(StatusCode::INTERNAL_SERVER_ERROR);
            }
        }
        let upstream_request = match builder.body(upstream_body.boxed_unsync()) {
            Ok(request) => request,
            Err(e) => {
                exchange.mark_failed(&format!("request build: {e}"));
                exchange.emit(true);
                return simple_response(StatusCode::INTERNAL_SERVER_ERROR);
            }
        };
        let (response, permit) = match tokio::time::timeout(
            upstream_response_timeout(),
            upstream.client.send(upstream_request),
        )
        .await
        {
            Ok(Ok(pair)) => pair,
            Ok(Err(e)) => {
                exchange.mark_failed(&e.to_string());
                record_mitm_failed(&format!("http upstream: {e}"));
                exchange.emit(true);
                return upstream_failure_response();
            }
            Err(_) => {
                exchange.mark_failed("upstream response timed out");
                record_mitm_failed(&format!(
                    "http upstream: response timed out after {}ms",
                    upstream_response_timeout().as_millis()
                ));
                exchange.emit(true);
                return upstream_failure_response();
            }
        };
        let status = response.status();
        let resp_headers = response.headers().clone();

        if let Some(rule) = rule.as_ref().filter(|r| r.kind == RULE_KIND_REPLACE) {
            return serve_replace_rule(
                rule,
                self.capture_body,
                self.body_cap,
                exchange,
                response,
                permit,
                status,
                resp_headers,
            )
            .await;
        }

        // Unmatched (or an unknown kind): forward byte-for-byte, exactly as
        // before — the body and `Content-Encoding` are untouched.
        let content_type = content_type_of(&resp_headers);
        let resp_capture = BodyCapture::new(self.capture_body, body_encoding(&resp_headers), self.body_cap);
        exchange.set_response(
            status.as_u16(),
            &resp_headers,
            &content_type,
            Arc::clone(&resp_capture),
        );
        let resp_body = TeeBody::new(
            response
                .into_body()
                .map_err(|e| Box::new(e) as BoxError)
                .boxed_unsync(),
            resp_capture,
            Arc::clone(&exchange),
            Side::Response,
            permit,
        );
        let mut out = Response::new(BridgeBody::Tee(resp_body));
        *out.status_mut() = status;
        {
            let dst = out.headers_mut();
            for (name, value) in resp_headers.iter() {
                if is_hop_by_hop(name) {
                    continue;
                }
                dst.append(name, value.clone());
            }
        }
        out
    }

    /// After a WebSocket `Upgrade`, hyper hands back both raw IO objects. This
    /// forwards the handshake through the established upstream connection,
    /// returns the origin's `101` to the client (with `Sec-WebSocket-Extensions`
    /// stripped), then spawns the frame bridge.
    async fn handle_websocket(&self, mut req: Request<Incoming>) -> Response<BridgeBody> {
        // WS-over-h2 (RFC 8441) is out of scope: hyper's h2 path cannot express
        // the h1-style `101` upgrade, so degrade explicitly without dialing.
        if self.client_proto == HttpProtocol::H2 {
            return ws_over_h2_response();
        }
        let upstream = match self.upstream_client().await {
            Ok(upstream) => upstream,
            Err(e) => {
                record_mitm_failed(&format!("ws upstream: {e}"));
                return simple_response(StatusCode::BAD_GATEWAY);
            }
        };
        if upstream.proto == HttpProtocol::H2 {
            return ws_over_h2_response();
        }

        let client_upgrade = hyper::upgrade::on(&mut req);
        let method = req.method().clone();
        let method_text = method.as_str().to_string();
        let req_headers = req.headers().clone();
        let path = req
            .uri()
            .path_and_query()
            .map(|pq| pq.as_str().to_string())
            .unwrap_or_else(|| "/".to_string());
        let host = host_header(&req_headers).unwrap_or_else(|| self.host.clone());
        let ws_url = format!("{}://{host}{path}", self.scheme);
        let origin: Uri = match path.parse() {
            Ok(uri) => uri,
            Err(_) => Uri::from_static("/"),
        };
        let mut builder = Request::builder().method(method).uri(origin);
        {
            let Some(dst) = builder.headers_mut() else {
                return simple_response(StatusCode::INTERNAL_SERVER_ERROR);
            };
            for (name, value) in req_headers.iter() {
                if !ws_forward_request_header(name) {
                    continue;
                }
                dst.append(name, value.clone());
            }
            if !dst.contains_key(HOST) {
                if let Ok(value) = HeaderValue::from_str(&host) {
                    dst.insert(HOST, value);
                }
            }
            dst.insert(CONNECTION, HeaderValue::from_static("Upgrade"));
            dst.insert(UPGRADE, HeaderValue::from_static("websocket"));
        }
        let empty = Empty::<Bytes>::new()
            .map_err(|never| -> BoxError { match never {} })
            .boxed_unsync();
        let upstream_request = match builder.body(empty) {
            Ok(request) => request,
            Err(e) => {
                crate::log_message(2, &format!("proxy.mitm: ws request build: {e}"));
                return simple_response(StatusCode::INTERNAL_SERVER_ERROR);
            }
        };
        let (mut response, permit) = match tokio::time::timeout(
            upstream_response_timeout(),
            upstream.client.send(upstream_request),
        )
        .await
        {
            Ok(Ok(pair)) => pair,
            Ok(Err(e)) => {
                record_mitm_failed(&format!("ws upstream: {e}"));
                return simple_response(StatusCode::BAD_GATEWAY);
            }
            Err(_) => {
                record_mitm_failed(&format!(
                    "ws upstream: response timed out after {}ms",
                    upstream_response_timeout().as_millis()
                ));
                return simple_response(StatusCode::BAD_GATEWAY);
            }
        };
        drop(permit);
        if response.status() != StatusCode::SWITCHING_PROTOCOLS {
            let mut out = simple_response(response.status());
            for (name, value) in response.headers().iter() {
                if is_hop_by_hop(name) {
                    continue;
                }
                out.headers_mut().append(name, value.clone());
            }
            return out;
        }
        let upstream_upgrade = hyper::upgrade::on(&mut response);

        let mut out = simple_response(StatusCode::SWITCHING_PROTOCOLS);
        {
            let dst = out.headers_mut();
            for (name, value) in response.headers().iter() {
                if name == SEC_WEBSOCKET_EXTENSIONS || is_hop_by_hop(name) {
                    continue;
                }
                dst.append(name, value.clone());
            }
            dst.insert(CONNECTION, HeaderValue::from_static("Upgrade"));
            dst.insert(UPGRADE, HeaderValue::from_static("websocket"));
        }
        let host = self.host.clone();
        let conn_id = self.conn_id.clone();
        let capture_ws = self.capture_ws;
        let sink = if capture_ws {
            Arc::clone(&self.ws_sink)
        } else {
            noop_ws_frame_sink()
        };
        if capture_ws {
            sink.on_ws_open(&host, &conn_id, &method_text, &ws_url);
        }
        tokio::spawn(async move {
            let outcome =
                bridge_websocket(client_upgrade, upstream_upgrade, host.clone(), conn_id.clone(), sink.clone())
                    .await;
            if capture_ws {
                sink.on_ws_close(&host, &conn_id);
            }
            if let Err(e) = outcome {
                crate::log_message(2, &format!("proxy.mitm: ws bridge ended: {e}"));
            }
        });
        out
    }
}

/// Serve a `kind:"local"` rule. No upstream dial happens; the rule's
/// status/headers/body are returned directly. The rule body is decoded
/// plaintext, so the content coding is forced to `identity` and
/// `Content-Length` is recomputed.
fn serve_local_rule(
    rule: &CaptureRule,
    capture_body: bool,
    body_cap: usize,
    exchange: Arc<ExchangeCapture>,
    request_body: Incoming,
) -> Response<BridgeBody> {
    drop(request_body);
    exchange.side_done(Side::Request);

    let status = rule_status(rule, StatusCode::OK);
    let mut headers = HeaderMap::new();
    if let Some(text) = rule.resp_headers.as_deref() {
        overlay_rule_headers(&mut headers, text);
    }
    let bytes = Bytes::from(rule.resp_body.clone().unwrap_or_default().into_bytes());
    force_plaintext_body_headers(&mut headers, bytes.len());
    let content_type = content_type_of(&headers);
    let resp_capture = BodyCapture::new(capture_body, BodyEncoding::Identity, body_cap);
    exchange.set_response(
        status.as_u16(),
        &headers,
        &content_type,
        Arc::clone(&resp_capture),
    );
    let body = TeeBody::new(full_body(bytes), resp_capture, exchange, Side::Response, None);
    response_with(status, headers, BridgeBody::Tee(body))
}

/// Apply a `kind:"replace"` rule to the upstream response: overlay
/// status/headers and, when the rule carries a body, replace the body outright.
/// Non-overridden headers keep their upstream values.
async fn serve_replace_rule(
    rule: &CaptureRule,
    capture_body: bool,
    body_cap: usize,
    exchange: Arc<ExchangeCapture>,
    upstream: Response<Incoming>,
    permit: Option<OwnedSemaphorePermit>,
    upstream_status: StatusCode,
    upstream_headers: HeaderMap,
) -> Response<BridgeBody> {
    let status = rule_status(rule, upstream_status);
    let mut headers = end_to_end_headers(&upstream_headers);
    if let Some(text) = rule.resp_headers.as_deref() {
        overlay_rule_headers(&mut headers, text);
    }

    let Some(body) = rule.resp_body.as_deref() else {
        // Status/headers only: the upstream body streams through unchanged, so
        // its content coding is preserved.
        let content_type = content_type_of(&headers);
        let resp_capture = BodyCapture::new(capture_body, body_encoding(&upstream_headers), body_cap);
        exchange.set_response(
            status.as_u16(),
            &headers,
            &content_type,
            Arc::clone(&resp_capture),
        );
        let body = TeeBody::new(
            upstream
                .into_body()
                .map_err(|e| Box::new(e) as BoxError)
                .boxed_unsync(),
            resp_capture,
            exchange,
            Side::Response,
            permit,
        );
        return response_with(status, headers, BridgeBody::Tee(body));
    };

    // Body override: the rule body is decoded plaintext, so the response MUST
    // NOT keep an upstream `Content-Encoding` (e.g. gzip) — force `identity`
    // and recompute `Content-Length`.
    let bytes = Bytes::from(body.as_bytes().to_vec());
    force_plaintext_body_headers(&mut headers, bytes.len());
    let content_type = content_type_of(&headers);
    let resp_capture = BodyCapture::new(capture_body, BodyEncoding::Identity, body_cap);
    exchange.set_response(
        status.as_u16(),
        &headers,
        &content_type,
        Arc::clone(&resp_capture),
    );
    // Drain the discarded upstream body before releasing the h1 gate permit, so
    // the persistent upstream connection is reusable for the next keep-alive
    // request instead of being poisoned.
    drain_discarded_upstream_body(upstream.into_body(), permit);
    let body = TeeBody::new(full_body(bytes), resp_capture, exchange, Side::Response, None);
    response_with(status, headers, BridgeBody::Tee(body))
}

/// Read and discard an overwritten upstream body to EOF in the background. The
/// h1 gate permit is released only when the drain finishes, so hyper never starts
/// the next request on a half-read connection; a failed drain still releases it.
///
/// The drain is **frame-by-frame** by design: an overwriting `replace` rule may
/// discard an arbitrarily large upstream body, so buffering it (`collect()` /
/// `to_bytes()`) would OOM the proxy. Dropping each frame before polling the next
/// keeps at most one frame resident.
fn drain_discarded_upstream_body<B>(body: B, permit: Option<OwnedSemaphorePermit>)
where
    B: Body + Send + Unpin + 'static,
    B::Data: Send,
    B::Error: Send,
{
    tokio::spawn(async move {
        let mut body = body;
        while let Some(frame) = body.frame().await {
            drop(frame);
        }
        drop(permit);
    });
}

fn rule_status(rule: &CaptureRule, fallback: StatusCode) -> StatusCode {
    rule.status_code
        .and_then(|code| StatusCode::from_u16(code).ok())
        .unwrap_or(fallback)
}

fn full_body(bytes: Bytes) -> UpstreamBody {
    Full::new(bytes)
        .map_err(|never| -> BoxError { match never {} })
        .boxed_unsync()
}

fn response_with(status: StatusCode, headers: HeaderMap, body: BridgeBody) -> Response<BridgeBody> {
    let mut out = Response::new(body);
    *out.status_mut() = status;
    *out.headers_mut() = headers;
    out
}

fn content_type_of(headers: &HeaderMap) -> String {
    headers
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string()
}

fn end_to_end_headers(headers: &HeaderMap) -> HeaderMap {
    let mut out = HeaderMap::new();
    for (name, value) in headers.iter() {
        if is_hop_by_hop(name) {
            continue;
        }
        out.append(name, value.clone());
    }
    out
}

/// Parse the rule's `respHeaders` text (`name: value` lines) and overlay each on
/// `headers`, replacing any upstream value of the same name. `Content-Length` is
/// framing the proxy owns: a body override recomputes it and a streamed body
/// keeps the upstream value, so a user-supplied length can never desync the body.
fn overlay_rule_headers(headers: &mut HeaderMap, text: &str) {
    for line in text.split(|c| c == '\n' || c == '\r') {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let Ok(name) = HeaderName::from_bytes(name.trim().as_bytes()) else {
            continue;
        };
        if is_hop_by_hop(&name) || name == CONTENT_LENGTH {
            continue;
        }
        let Ok(value) = HeaderValue::from_str(value.trim()) else {
            continue;
        };
        headers.insert(name, value);
    }
}

/// Force the response to describe a decoded-plaintext body: no content coding
/// and a recomputed `Content-Length`. Keeping an upstream `Content-Encoding:
/// gzip` while sending plaintext would corrupt the response.
fn force_plaintext_body_headers(headers: &mut HeaderMap, body_len: usize) {
    headers.insert(CONTENT_ENCODING, HeaderValue::from_static("identity"));
    if let Ok(value) = HeaderValue::from_str(&body_len.to_string()) {
        headers.insert(CONTENT_LENGTH, value);
    }
}

fn ws_over_h2_response() -> Response<BridgeBody> {
    crate::log_message(
        2,
        "proxy.mitm: ws-over-h2 unsupported (RFC8441 not implemented); responding 501",
    );
    let mut response = simple_response(StatusCode::NOT_IMPLEMENTED);
    response.headers_mut().insert(
        HeaderName::from_static("x-gstore-ws-over-h2"),
        HeaderValue::from_static("unsupported"),
    );
    response
}

/// True when `req` is an HTTP/1.1 WebSocket upgrade handshake.
fn is_websocket_upgrade(req: &Request<Incoming>) -> bool {
    let wants_websocket = req
        .headers()
        .get(UPGRADE)
        .and_then(|v| v.to_str().ok())
        .map(|v| {
            v.split(',')
                .any(|token| token.trim().eq_ignore_ascii_case("websocket"))
        })
        .unwrap_or(false);
    wants_websocket && req.headers().contains_key(SEC_WEBSOCKET_KEY)
}

/// True when the request carries an HTTP/1.1 `Upgrade: h2c` offer. Plaintext
/// HTTP/2 is unsupported, so the bridge strips the `HTTP2-Settings` header that
/// pairs with the offer before forwarding a plaintext request as H1.
fn is_h2c_upgrade(headers: &HeaderMap) -> bool {
    headers
        .get(UPGRADE)
        .and_then(|v| v.to_str().ok())
        .map(|v| {
            v.split(',')
                .any(|token| token.trim().eq_ignore_ascii_case("h2c"))
        })
        .unwrap_or(false)
}

/// Request headers preserved across the WebSocket upgrade. `Sec-WebSocket-
/// Extensions` is stripped in the client→upstream direction (no compression).
fn ws_forward_request_header(name: &HeaderName) -> bool {
    if name == SEC_WEBSOCKET_EXTENSIONS {
        return false;
    }
    !matches!(
        name.as_str(),
        "transfer-encoding" | "te" | "trailer" | "proxy-connection" | "keep-alive"
    )
}

/// Await both hyper upgrades, wrap the raw IO as WebSocket streams, and pump
/// frames until either side closes.
async fn bridge_websocket(
    client_upgrade: hyper::upgrade::OnUpgrade,
    upstream_upgrade: hyper::upgrade::OnUpgrade,
    host: String,
    conn_id: String,
    sink: Arc<dyn WsFrameSink>,
) -> Result<(), String> {
    let client_io = client_upgrade
        .await
        .map_err(|e| format!("client upgrade: {e}"))?;
    let upstream_io = upstream_upgrade
        .await
        .map_err(|e| format!("upstream upgrade: {e}"))?;
    let client = WebSocketStream::from_raw_socket(
        TokioIo::new(client_io),
        Role::Server,
        Some(ws_config()),
    )
    .await;
    let upstream = WebSocketStream::from_raw_socket(
        TokioIo::new(upstream_io),
        Role::Client,
        Some(ws_config()),
    )
    .await;
    run_ws_pump(client, upstream, &host, &conn_id, sink).await;
    Ok(())
}

/// Bidirectionally pump WebSocket messages, recording each complete message
/// before forwarding it verbatim. `client` is the server-role endpoint facing
/// the browser; `upstream` is the client-role endpoint facing the origin.
async fn run_ws_pump<CS, US>(
    mut client: WebSocketStream<CS>,
    mut upstream: WebSocketStream<US>,
    host: &str,
    conn_id: &str,
    sink: Arc<dyn WsFrameSink>,
) where
    CS: AsyncRead + AsyncWrite + Unpin,
    US: AsyncRead + AsyncWrite + Unpin,
{
    let mut client_open = true;
    let mut upstream_open = true;
    while client_open && upstream_open {
        tokio::select! {
            biased;
            message = client.next() => {
                match message {
                    Some(Ok(message)) => {
                        record_ws_frame(sink.as_ref(), host, conn_id, WsDirection::ClientToServer, &message);
                        let closing = message.is_close();
                        if upstream.send(message).await.is_err() || closing {
                            client_open = false;
                        }
                    }
                    _ => client_open = false,
                }
            }
            message = upstream.next() => {
                match message {
                    Some(Ok(message)) => {
                        record_ws_frame(sink.as_ref(), host, conn_id, WsDirection::ServerToClient, &message);
                        let closing = message.is_close();
                        if client.send(message).await.is_err() || closing {
                            upstream_open = false;
                        }
                    }
                    _ => upstream_open = false,
                }
            }
        }
    }
    let _ = client.close(None).await;
    let _ = upstream.close(None).await;
}

/// Record one frame with a bounded preview (≤ [`WS_PREVIEW_MAX_BYTES`]).
fn record_ws_frame(
    sink: &dyn WsFrameSink,
    host: &str,
    conn_id: &str,
    direction: WsDirection,
    message: &WsMessage,
) {
    let (opcode, payload): (&'static str, &[u8]) = match message {
        WsMessage::Text(text) => ("text", text.as_str().as_bytes()),
        WsMessage::Binary(data) => ("binary", data.as_ref()),
        WsMessage::Ping(data) => ("ping", data.as_ref()),
        WsMessage::Pong(data) => ("pong", data.as_ref()),
        WsMessage::Close(frame) => (
            "close",
            frame
                .as_ref()
                .map(|f| f.reason.as_str().as_bytes())
                .unwrap_or_default(),
        ),
        WsMessage::Frame(_) => ("frame", &[]),
    };
    let take = payload.len().min(WS_PREVIEW_MAX_BYTES);
    let record = WsFrameRecord {
        direction,
        opcode,
        payload_len: message.len() as u64,
        preview: payload[..take].to_vec(),
        truncated: payload.len() > WS_PREVIEW_MAX_BYTES,
        at_ms: crate::now_ms(),
    };
    sink.on_ws_frame(host, conn_id, &record);
}

struct ProxyService {
    state: Arc<BridgeState>,
}

impl Service<Request<Incoming>> for ProxyService {
    type Response = Response<BridgeBody>;
    type Error = Infallible;
    type Future = Pin<Box<dyn Future<Output = Result<Response<BridgeBody>, Infallible>> + Send>>;

    fn call(&self, req: Request<Incoming>) -> Self::Future {
        let state = Arc::clone(&self.state);
        Box::pin(async move { Ok(state.handle(req).await) })
    }
}

fn configure_h2_server<Ex>(builder: &mut server_http2::Builder<Ex>) {
    builder
        .initial_stream_window_size(Some(H2_INITIAL_STREAM_WINDOW_SIZE))
        .initial_connection_window_size(Some(H2_INITIAL_CONNECTION_WINDOW_SIZE))
        .max_send_buf_size(H2_MAX_SEND_BUF_SIZE)
        .max_header_list_size(H2_MAX_HEADER_LIST_SIZE);
}

fn configure_h2_client<Ex: Clone>(builder: &mut client_http2::Builder<Ex>) {
    builder
        .initial_stream_window_size(Some(H2_INITIAL_STREAM_WINDOW_SIZE))
        .initial_connection_window_size(Some(H2_INITIAL_CONNECTION_WINDOW_SIZE))
        .max_send_buf_size(H2_MAX_SEND_BUF_SIZE)
        .max_header_list_size(H2_MAX_HEADER_LIST_SIZE);
}

/// Bridge one terminated client TLS connection to one already-dialed upstream
/// TLS connection, capturing both directions. ALPN chooses h1/h2 per side.
pub(crate) async fn bridge<S, U>(
    client: TlsStream<S>,
    upstream: ClientTlsStream<U>,
    ctx: BridgeContext,
) -> Result<(), MitmFailure>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    U: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let client_proto = HttpProtocol::from_alpn(client.get_ref().1.alpn_protocol());
    let upstream_proto = HttpProtocol::from_alpn(upstream.get_ref().1.alpn_protocol());
    let upstream_client = UpstreamClient::establish(upstream, upstream_proto)
        .await
        .map_err(|e| MitmFailure::new(MitmStage::UpstreamHttp, e))?;
    serve_client(
        client,
        client_proto,
        "https",
        ctx,
        Some(EstablishedUpstream {
            client: upstream_client,
            proto: upstream_proto,
        }),
        None,
    )
    .await
}

/// Bridge a terminated client TLS connection whose upstream is dialed lazily on
/// the first request a `kind:"local"` rule does not short-circuit.
pub(crate) async fn bridge_deferred<S>(
    client: TlsStream<S>,
    dialer: Arc<dyn UpstreamDialer>,
    ctx: BridgeContext,
) -> Result<(), MitmFailure>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let client_proto = HttpProtocol::from_alpn(client.get_ref().1.alpn_protocol());
    serve_client(client, client_proto, "https", ctx, None, Some(dialer)).await
}

/// Bridge a **plaintext** client connection (no TLS termination) to an upstream
/// dialed lazily on the first request. The client side is forced to HTTP/1.1 and
/// captures are tagged `scheme="http"`.
pub(crate) async fn bridge_deferred_plain<S>(
    client: S,
    dialer: Arc<dyn UpstreamDialer>,
    ctx: BridgeContext,
) -> Result<(), MitmFailure>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    serve_client(client, HttpProtocol::H1, "http", ctx, None, Some(dialer)).await
}

async fn serve_client<S>(
    client: S,
    client_proto: HttpProtocol,
    scheme: &'static str,
    ctx: BridgeContext,
    upstream: Option<EstablishedUpstream>,
    dialer: Option<Arc<dyn UpstreamDialer>>,
) -> Result<(), MitmFailure>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let state = Arc::new(BridgeState {
        sink: ctx.sink.clone().unwrap_or_else(capture_sink),
        ws_sink: ctx.ws_sink.clone().unwrap_or_else(ws_frame_sink),
        host: ctx.host,
        scheme,
        conn_id: ctx.conn_id,
        request_record_id: ctx.request_record_id,
        capture_body: ctx.capture_body,
        capture_ws: ctx.capture_ws,
        capture_h2: ctx.capture_h2,
        body_cap: ctx.max_body_bytes,
        started_at_ms: ctx.started_at_ms,
        client_proto,
        rule_source: ctx.rule_source,
        upstream: AsyncMutex::new(upstream.map(Arc::new)),
        dialer,
        last_method: std::sync::Mutex::new(None),
    });
    let service = ProxyService {
        state: Arc::clone(&state),
    };
    let io = TokioIo::new(client);
    let result = match client_proto {
        HttpProtocol::H1 => {
            let mut builder = server_http1::Builder::new();
            builder.max_buf_size(H1_MAX_BUF_SIZE);
            builder.max_headers(H1_MAX_HEADERS);
            builder
                .serve_connection(io, service)
                .with_upgrades()
                .await
        }
        HttpProtocol::H2 => {
            let mut builder = server_http2::Builder::new(TokioExecutor::new());
            configure_h2_server(&mut builder);
            builder.serve_connection(io, service).await
        }
    };
    result.map_err(|e| client_http_failure(client_proto, &state, e))
}

fn client_http_failure(
    client_proto: HttpProtocol,
    state: &BridgeState,
    error: hyper::Error,
) -> MitmFailure {
    let failure = if error.is_shutdown() {
        MitmFailure::new(MitmStage::ClientAbort, error.to_string())
    } else {
        MitmFailure::new(MitmStage::ClientHttp, error.to_string())
    }
    .with_client_proto(client_proto);
    let last_method = state
        .last_method
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    let failure = match last_method {
        Some(method) => failure.with_method(method),
        None => failure,
    };
    let upstream_proto = state
        .upstream
        .try_lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(|upstream| upstream.proto));
    match upstream_proto {
        Some(proto) => failure.with_upstream_proto(proto),
        None => failure,
    }
}

#[cfg(test)]
mod mitm_http_tests {
    use super::mitm_upstream_tests::{trusted_roots, tunnel_with, RecordingProxy};
    use super::*;
    use crate::TEST_SERIAL as SERIAL;
    use http_body_util::{BodyExt, Full};
    use hyper::Version;
    use rustls::pki_types::ServerName;
    use rustls::RootCertStore;
    use std::net::SocketAddr;
    use std::sync::atomic::AtomicU64 as TestSeq;
    use std::sync::Mutex as StdMutex;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};
    use tokio_rustls::{TlsAcceptor, TlsConnector};

    static TEST_SEQ: TestSeq = TestSeq::new(0);

    fn temp_ca(tag: &str) -> Arc<CertificateAuthority> {
        let n = TEST_SEQ.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "gstore-mitm-http-{}-{}-{}",
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

    struct ChannelSink(tokio::sync::mpsc::UnboundedSender<CaptureRecord>);

    impl CaptureSink for ChannelSink {
        fn on_capture(&self, record: CaptureRecord) {
            let _ = self.0.send(record);
        }
    }

    fn recording_sink() -> (
        tokio::sync::mpsc::UnboundedReceiver<CaptureRecord>,
        Arc<dyn CaptureSink>,
    ) {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (rx, Arc::new(ChannelSink(tx)))
    }

    async fn next_record(
        rx: &mut tokio::sync::mpsc::UnboundedReceiver<CaptureRecord>,
    ) -> CaptureRecord {
        tokio::time::timeout(Duration::from_secs(10), rx.recv())
            .await
            .expect("capture must be emitted")
            .expect("capture channel open")
    }

    enum Fixture {
        RawH1(Vec<u8>),
        /// Raw h1 response that also records the first request head the origin
        /// saw, so a test can assert the *forwarded* request framing
        /// (`Content-Length` vs `Transfer-Encoding: chunked`).
        RawH1Recorded {
            response: Vec<u8>,
            observed: Arc<StdMutex<Option<String>>>,
        },
        H2 {
            status: u16,
            body: Vec<u8>,
            content_type: &'static str,
            observed: Arc<StdMutex<Option<Version>>>,
        },
    }

    fn header_end(buf: &[u8]) -> Option<usize> {
        buf.windows(4).position(|w| w == b"\r\n\r\n")
    }

    fn parse_content_length(head: &str) -> Option<usize> {
        head.lines().find_map(|line| {
            let (name, value) = line.split_once(':')?;
            if name.trim().eq_ignore_ascii_case("content-length") {
                value.trim().parse().ok()
            } else {
                None
            }
        })
    }

    async fn serve_raw_h1(
        mut tls: tokio_rustls::server::TlsStream<TcpStream>,
        response: Vec<u8>,
        observed: Option<Arc<StdMutex<Option<String>>>>,
    ) {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        loop {
            match tls.read(&mut tmp).await {
                Ok(0) => break,
                Ok(n) => {
                    buf.extend_from_slice(&tmp[..n]);
                    if header_end(&buf).is_some() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        if let Some(end) = header_end(&buf) {
            let head = String::from_utf8_lossy(&buf[..end]).to_ascii_lowercase();
            if let Some(slot) = observed {
                *slot.lock().unwrap_or_else(|e| e.into_inner()) = Some(head.clone());
            }
            if let Some(length) = parse_content_length(&head) {
                let mut remaining = length.saturating_sub(buf.len().saturating_sub(end + 4));
                while remaining > 0 {
                    match tls.read(&mut tmp).await {
                        Ok(0) => break,
                        Ok(n) => remaining = remaining.saturating_sub(n),
                        Err(_) => break,
                    }
                }
            }
        }
        let _ = tls.write_all(&response).await;
        let _ = tls.flush().await;
        let _ = tls.shutdown().await;
        let _ = tls.read(&mut tmp).await;
    }

    async fn serve_h2(
        tls: tokio_rustls::server::TlsStream<TcpStream>,
        status: u16,
        body: Vec<u8>,
        content_type: &'static str,
        observed: Arc<StdMutex<Option<Version>>>,
    ) {
        let service = hyper::service::service_fn(move |req: Request<Incoming>| {
            let body = body.clone();
            let observed = Arc::clone(&observed);
            async move {
                *observed.lock().unwrap_or_else(|e| e.into_inner()) = Some(req.version());
                let mut response = Response::new(Full::new(Bytes::from(body)));
                *response.status_mut() = StatusCode::from_u16(status).unwrap();
                response.headers_mut().insert(
                    CONTENT_TYPE,
                    HeaderValue::from_static(content_type),
                );
                Ok::<_, Infallible>(response)
            }
        });
        let mut builder = server_http2::Builder::new(TokioExecutor::new());
        configure_h2_server(&mut builder);
        let _ = builder
            .serve_connection(TokioIo::new(tls), service)
            .await;
    }

    async fn start_fixture(
        ca: Arc<CertificateAuthority>,
        host: &str,
        fixture: Fixture,
    ) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let host = host.to_string();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            match fixture {
                Fixture::RawH1(bytes) => {
                    let config = ca.server_config(&host).unwrap();
                    let tls = TlsAcceptor::from(config).accept(tcp).await.unwrap();
                    serve_raw_h1(tls, bytes, None).await;
                }
                Fixture::RawH1Recorded { response, observed } => {
                    let config = ca.server_config(&host).unwrap();
                    let tls = TlsAcceptor::from(config).accept(tcp).await.unwrap();
                    serve_raw_h1(tls, response, Some(observed)).await;
                }
                Fixture::H2 {
                    status,
                    body,
                    content_type,
                    observed,
                } => {
                    let config = ca.mitm_server_config(Some(&host)).unwrap();
                    let tls = TlsAcceptor::from(config).accept(tcp).await.unwrap();
                    serve_h2(tls, status, body, content_type, observed).await;
                }
            }
        });
        addr
    }

    async fn run_bridge(
        ca: Arc<CertificateAuthority>,
        host: &str,
        upstream_addr: SocketAddr,
        upstream_alpn: &[u8],
        ctx: BridgeContext,
    ) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let host = host.to_string();
        let alpn = upstream_alpn.to_vec();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let client = match terminate(tcp, &ca, Some(&host)).await {
                MitmTls::Terminated(tls) => tls,
                MitmTls::Passthrough(_) => panic!("expected TLS termination"),
                MitmTls::Failed(e) => panic!("terminate failed: {e}"),
            };
            let tcp_up = TcpStream::connect(upstream_addr).await.unwrap();
            let connector = TlsConnector::from(client_tls(&ca, &alpn));
            let sni = ServerName::try_from(host.clone()).unwrap();
            let upstream = connector.connect(sni, tcp_up).await.unwrap();
            let _ = bridge(client, upstream, ctx).await;
        });
        addr
    }

    /// Like [`run_bridge`], but returns the bridge task's own result so a test can
    /// assert a client-visible framing failure surfaces as a clean
    /// `MitmFailure` (and not a panic / silent pass-through).
    async fn run_bridge_returning(
        ca: Arc<CertificateAuthority>,
        host: &str,
        upstream_addr: SocketAddr,
        upstream_alpn: &[u8],
        ctx: BridgeContext,
    ) -> (SocketAddr, tokio::task::JoinHandle<Result<(), MitmFailure>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let host = host.to_string();
        let alpn = upstream_alpn.to_vec();
        let handle = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let client = match terminate(tcp, &ca, Some(&host)).await {
                MitmTls::Terminated(tls) => tls,
                MitmTls::Passthrough(_) => panic!("expected TLS termination"),
                MitmTls::Failed(e) => panic!("terminate failed: {e}"),
            };
            let tcp_up = TcpStream::connect(upstream_addr).await.unwrap();
            let connector = TlsConnector::from(client_tls(&ca, &alpn));
            let sni = ServerName::try_from(host.clone()).unwrap();
            let upstream = connector.connect(sni, tcp_up).await.unwrap();
            bridge(client, upstream, ctx).await
        });
        (addr, handle)
    }

    struct ClientOutcome {
        status: u16,
        headers: HeaderMap,
        body: Vec<u8>,
    }

    async fn client_send_h1(
        ca: &CertificateAuthority,
        addr: SocketAddr,
        host: &str,
        method: &str,
        path: &str,
        body: Option<Vec<u8>>,
    ) -> ClientOutcome {
        let tcp = TcpStream::connect(addr).await.unwrap();
        let connector = TlsConnector::from(client_tls(ca, b"http/1.1"));
        let tls = connector
            .connect(ServerName::try_from(host.to_string()).unwrap(), tcp)
            .await
            .unwrap();
        let mut builder = client_http1::Builder::new();
        builder.max_buf_size(H1_MAX_BUF_SIZE);
        let (mut sender, conn) = builder
            .handshake::<_, Full<Bytes>>(TokioIo::new(tls))
            .await
            .unwrap();
        tokio::spawn(async move {
            let _ = conn.await;
        });
        let payload = body.map(Bytes::from).unwrap_or_default();
        let request = Request::builder()
            .method(method)
            .uri(path)
            .header(HOST, host)
            .body(Full::new(payload))
            .unwrap();
        let response = sender.send_request(request).await.unwrap();
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let body = response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .to_vec();
        ClientOutcome {
            status,
            headers,
            body,
        }
    }

    /// h1 client that accepts extra request headers (used to send a head larger
    /// than the old 8 KiB buffer). Returns `Err` instead of panicking so a red
    /// run reports a value, and mirrors the production client's buffer bound.
    async fn client_send_h1_with_headers(
        ca: &CertificateAuthority,
        addr: SocketAddr,
        host: &str,
        path: &str,
        extra: &[(&str, &str)],
    ) -> Result<ClientOutcome, String> {
        let tcp = tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(addr))
            .await
            .map_err(|_| "connect timed out".to_string())?
            .map_err(|e| e.to_string())?;
        let connector = TlsConnector::from(client_tls(ca, b"http/1.1"));
        let tls = connector
            .connect(ServerName::try_from(host.to_string()).unwrap(), tcp)
            .await
            .map_err(|e| e.to_string())?;
        let mut builder = client_http1::Builder::new();
        builder.max_buf_size(H1_MAX_BUF_SIZE);
        builder.max_headers(H1_MAX_HEADERS);
        let (mut sender, conn) = builder
            .handshake::<_, Full<Bytes>>(TokioIo::new(tls))
            .await
            .map_err(|e| e.to_string())?;
        tokio::spawn(async move {
            let _ = conn.await;
        });
        let mut builder = Request::builder().method("GET").uri(path).header(HOST, host);
        for (name, value) in extra {
            builder = builder.header(*name, *value);
        }
        let request = builder.body(Full::new(Bytes::new())).unwrap();
        let response = tokio::time::timeout(Duration::from_secs(5), sender.send_request(request))
            .await
            .map_err(|_| "send timed out".to_string())?
            .map_err(|e| e.to_string())?;
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let body = response
            .into_body()
            .collect()
            .await
            .map_err(|e| e.to_string())?
            .to_bytes()
            .to_vec();
        Ok(ClientOutcome {
            status,
            headers,
            body,
        })
    }

    async fn client_send_h2(
        ca: &CertificateAuthority,
        addr: SocketAddr,
        host: &str,
        path: &str,
    ) -> ClientOutcome {
        let tcp = TcpStream::connect(addr).await.unwrap();
        let connector = TlsConnector::from(client_tls(ca, b"h2"));
        let tls = connector
            .connect(ServerName::try_from(host.to_string()).unwrap(), tcp)
            .await
            .unwrap();
        let (mut sender, conn) = client_http2::Builder::new(TokioExecutor::new())
            .handshake::<_, Full<Bytes>>(TokioIo::new(tls))
            .await
            .unwrap();
        tokio::spawn(async move {
            let _ = conn.await;
        });
        let request = Request::builder()
            .method("GET")
            .uri(format!("https://{host}{path}"))
            .body(Full::new(Bytes::new()))
            .unwrap();
        let response = sender.send_request(request).await.unwrap();
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let body = response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .to_vec();
        ClientOutcome {
            status,
            headers,
            body,
        }
    }

    /// h2 client that accepts extra request headers (used to prove a header list
    /// larger than the old 4 KiB bound is accepted).
    async fn client_send_h2_with_headers(
        ca: &CertificateAuthority,
        addr: SocketAddr,
        host: &str,
        path: &str,
        extra: &[(&str, &str)],
    ) -> Result<ClientOutcome, String> {
        let tcp = tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(addr))
            .await
            .map_err(|_| "connect timed out".to_string())?
            .map_err(|e| e.to_string())?;
        let connector = TlsConnector::from(client_tls(ca, b"h2"));
        let tls = connector
            .connect(ServerName::try_from(host.to_string()).unwrap(), tcp)
            .await
            .map_err(|e| e.to_string())?;
        let (mut sender, conn) = client_http2::Builder::new(TokioExecutor::new())
            .handshake::<_, Full<Bytes>>(TokioIo::new(tls))
            .await
            .map_err(|e| e.to_string())?;
        tokio::spawn(async move {
            let _ = conn.await;
        });
        let mut builder = Request::builder()
            .method("GET")
            .uri(format!("https://{host}{path}"));
        for (name, value) in extra {
            builder = builder.header(*name, *value);
        }
        let request = builder.body(Full::new(Bytes::new())).unwrap();
        let response = tokio::time::timeout(Duration::from_secs(5), sender.send_request(request))
            .await
            .map_err(|_| "send timed out".to_string())?
            .map_err(|e| e.to_string())?;
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let body = response
            .into_body()
            .collect()
            .await
            .map_err(|e| e.to_string())?
            .to_bytes()
            .to_vec();
        Ok(ClientOutcome {
            status,
            headers,
            body,
        })
    }

    fn gzip(data: &[u8]) -> Vec<u8> {
        use async_compression::tokio::write::GzipEncoder;
        block_on(async {
            let mut encoder = GzipEncoder::new(Vec::new());
            encoder.write_all(data).await.unwrap();
            encoder.shutdown().await.unwrap();
            encoder.into_inner()
        })
    }

    /// Serve several raw HTTP/1.1 responses on ONE keep-alive TLS connection:
    /// read a complete request (headers + `Content-Length` body) before writing
    /// each response, exactly as an origin that reuses its connection would.
    async fn serve_raw_h1_keepalive(
        mut tls: tokio_rustls::server::TlsStream<TcpStream>,
        responses: Vec<Vec<u8>>,
    ) {
        let mut buf: Vec<u8> = Vec::new();
        let mut tmp = [0u8; 4096];
        for response in responses {
            loop {
                if let Some(end) = header_end(&buf) {
                    let head = String::from_utf8_lossy(&buf[..end]).to_ascii_lowercase();
                    let body_len = parse_content_length(&head).unwrap_or(0);
                    if buf.len() >= end + 4 + body_len {
                        buf.drain(..end + 4 + body_len);
                        break;
                    }
                }
                match tls.read(&mut tmp).await {
                    Ok(0) | Err(_) => return,
                    Ok(n) => buf.extend_from_slice(&tmp[..n]),
                }
            }
            let _ = tls.write_all(&response).await;
            let _ = tls.flush().await;
        }
        // Hold the connection open so a poisoned reuse attempt is visible.
        let _ = tls.read(&mut tmp).await;
    }

    async fn start_keepalive_fixture(
        ca: Arc<CertificateAuthority>,
        host: &str,
        responses: Vec<Vec<u8>>,
    ) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let host = host.to_string();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let config = ca.server_config(&host).unwrap();
            let tls = TlsAcceptor::from(config).accept(tcp).await.unwrap();
            serve_raw_h1_keepalive(tls, responses).await;
        });
        addr
    }

    /// Origin fixture that accepts **any number of connections** and answers each
    /// with exactly one `Connection: close` response (body `{prefix}{n}` for the
    /// 1-based connection index), then closes. The listener keeps accepting so a
    /// re-dial reaches a fresh connection. Used to prove the bridge re-dials when
    /// its cached upstream sender has been closed by the origin.
    async fn start_closing_fixture(
        ca: Arc<CertificateAuthority>,
        host: &str,
        prefix: &'static str,
    ) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let host = host.to_string();
        tokio::spawn(async move {
            let config = ca.server_config(&host).unwrap();
            let mut seq = 0u64;
            loop {
                let Ok((tcp, _)) = listener.accept().await else {
                    break;
                };
                seq += 1;
                let n = seq;
                let config = Arc::clone(&config);
                tokio::spawn(async move {
                    let Ok(mut tls) = TlsAcceptor::from(config).accept(tcp).await else {
                        return;
                    };
                    let mut buf = Vec::new();
                    let mut tmp = [0u8; 1024];
                    loop {
                        match tls.read(&mut tmp).await {
                            Ok(0) | Err(_) => return,
                            Ok(k) => {
                                buf.extend_from_slice(&tmp[..k]);
                                if header_end(&buf).is_some() {
                                    break;
                                }
                            }
                        }
                    }
                    let body = format!("{prefix}{n}");
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = tls.write_all(response.as_bytes()).await;
                    let _ = tls.flush().await;
                    let _ = tls.shutdown().await;
                });
            }
        });
        addr
    }

    /// Send several requests sequentially over ONE client TLS connection and
    /// return each response, so a keep-alive regression cannot be hidden by a
    /// fresh connection per request.
    async fn client_send_h1_keepalive(
        ca: &CertificateAuthority,
        addr: SocketAddr,
        host: &str,
        paths: &[&str],
    ) -> Vec<ClientOutcome> {
        let tcp = TcpStream::connect(addr).await.unwrap();
        let connector = TlsConnector::from(client_tls(ca, b"http/1.1"));
        let tls = connector
            .connect(ServerName::try_from(host.to_string()).unwrap(), tcp)
            .await
            .unwrap();
        let (mut sender, conn) = client_http1::Builder::new()
            .handshake::<_, Full<Bytes>>(TokioIo::new(tls))
            .await
            .unwrap();
        tokio::spawn(async move {
            let _ = conn.await;
        });
        let mut out = Vec::new();
        for path in paths {
            let request = Request::builder()
                .method("GET")
                .uri(*path)
                .header(HOST, host)
                .body(Full::new(Bytes::new()))
                .unwrap();
            let response = sender.send_request(request).await.unwrap();
            let status = response.status().as_u16();
            let headers = response.headers().clone();
            let body = response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .to_vec();
            out.push(ClientOutcome {
                status,
                headers,
                body,
            });
            // Let an origin that closed after this response propagate its FIN to
            // the bridge's cached upstream sender, so the next request exercises
            // the reuse-vs-re-dial decision deterministically (D11a).
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        out
    }

    #[test]
    fn mitm_http_h2_window_budget_is_bounded() {
        assert_eq!(H1_MAX_BUF_SIZE, 65_536);
        assert_eq!(H1_MAX_HEADERS, 256);
        assert_eq!(H2_PER_CONNECTION_BUDGET_BYTES, 102_400);
        assert!(H2_PER_CONNECTION_BUDGET_BYTES <= 102_400);
    }

    /// Device defect 5: a real app request head larger than the old 8 KiB bound
    /// (a large `Cookie`/token) must traverse the bridge end to end and be
    /// captured — not merely avoid a local error.
    #[test]
    fn mitm_http_h1_accepts_request_head_over_8kib() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("h1bighead");
            let host = "flow.test";
            let observed = Arc::new(StdMutex::new(None::<String>));
            let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_vec();
            let upstream = start_fixture(
                Arc::clone(&ca),
                host,
                Fixture::RawH1Recorded {
                    response: raw,
                    observed: Arc::clone(&observed),
                },
            )
            .await;
            let (mut rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-big-head", 0).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"http/1.1", ctx).await;

            let cookie = format!("c={}", "a".repeat(12 * 1024));
            assert!(
                cookie.len() > 8 * 1024,
                "precondition: the request head must exceed the old 8 KiB bound"
            );
            let out = client_send_h1_with_headers(
                &ca,
                bridge_addr,
                host,
                "/bank",
                &[("cookie", cookie.as_str())],
            )
            .await
            .expect("a request head over the old 8 KiB bound must succeed");
            assert_eq!(out.status, 200);
            assert_eq!(out.body, b"ok");

            // Traversal proof: the origin really parsed the oversized head.
            let forwarded = observed
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone()
                .expect("origin must have observed the request head");
            assert!(
                forwarded.len() > 8 * 1024,
                "forwarded head was {} B, expected > 8 KiB",
                forwarded.len()
            );
            assert!(forwarded.contains(&format!("cookie: {cookie}")));

            // Capture proof: the exchange was recorded, not just forwarded.
            let rec = next_record(&mut rx).await;
            assert_eq!(rec.method, "GET");
            assert_eq!(rec.url, "https://flow.test/bank");
            assert_eq!(rec.status_code, 200);
            assert!(!rec.mitm_failed);
            reset_capture_sink();
        });
    }

    /// The cap must stay a hard gate: a head beyond the new 64 KiB bound fails as
    /// a clean `client_http` `MitmFailure` (never a panic, never forwarded).
    #[test]
    fn mitm_http_h1_request_head_beyond_limit_fails_cleanly() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("h1toobig");
            let host = "flow.test";
            let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_vec();
            let upstream = start_fixture(Arc::clone(&ca), host, Fixture::RawH1(raw)).await;
            let ctx = BridgeContext::new(host, "conn-too-big", 0);
            let (bridge_addr, handle) =
                run_bridge_returning(Arc::clone(&ca), host, upstream, b"http/1.1", ctx).await;

            let tcp = TcpStream::connect(bridge_addr).await.unwrap();
            let connector = TlsConnector::from(client_tls(&ca, b"http/1.1"));
            let mut tls = connector
                .connect(ServerName::try_from(host.to_string()).unwrap(), tcp)
                .await
                .unwrap();
            let cookie = "a".repeat(H1_MAX_BUF_SIZE + 1024);
            let head =
                format!("GET /toobig HTTP/1.1\r\nHost: {host}\r\nCookie: {cookie}\r\n\r\n");
            assert!(head.len() > H1_MAX_BUF_SIZE);
            // Trickle the head so it accumulates across reads and trips the size
            // check (a single large read can complete past the cap).
            for chunk in head.as_bytes().chunks(4096) {
                let _ = tls.write_all(chunk).await;
                let _ = tls.flush().await;
                tokio::time::sleep(Duration::from_millis(2)).await;
            }

            let outcome = tokio::time::timeout(Duration::from_secs(10), handle)
                .await
                .expect("bridge must finish, not hang")
                .expect("bridge task must not panic");
            let failure = outcome.expect_err("an over-limit head must not be forwarded");
            assert_eq!(failure.stage(), MitmStage::ClientHttp);
            assert!(
                failure.message().to_ascii_lowercase().contains("too large"),
                "expected a 'too large' parse failure, got: {}",
                failure.message()
            );
            drop(tls);
            reset_capture_sink();
        });
    }

    /// Device defect 5: an h2 request header list over the old 4 KiB bound must be
    /// accepted (and reach the origin), not rejected by
    /// `SETTINGS_MAX_HEADER_LIST_SIZE`.
    #[test]
    fn mitm_http_h2_accepts_header_list_over_4kib() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("h2bighead");
            let host = "flow.test";
            let observed = Arc::new(StdMutex::new(None::<Version>));
            let upstream = start_fixture(
                Arc::clone(&ca),
                host,
                Fixture::H2 {
                    status: 200,
                    body: b"ok".to_vec(),
                    content_type: "text/plain",
                    observed: Arc::clone(&observed),
                },
            )
            .await;
            let (mut rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-h2-big-head", 0).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"h2", ctx).await;

            let cookie = format!("c={}", "a".repeat(8 * 1024));
            assert!(
                cookie.len() > 4 * 1024,
                "precondition: the header list must exceed the old 4 KiB bound"
            );
            let out = client_send_h2_with_headers(
                &ca,
                bridge_addr,
                host,
                "/bank",
                &[("cookie", cookie.as_str())],
            )
            .await
            .expect("an h2 header list over the old 4 KiB bound must be accepted");
            assert_eq!(out.status, 200);
            assert_eq!(out.body, b"ok");
            assert_eq!(
                *observed.lock().unwrap_or_else(|e| e.into_inner()),
                Some(Version::HTTP_2),
                "origin must have received the h2 request"
            );

            let rec = next_record(&mut rx).await;
            assert_eq!(rec.method, "GET");
            assert_eq!(rec.url, "https://flow.test/bank");
            assert_eq!(rec.status_code, 200);
            assert!(!rec.mitm_failed);
            reset_capture_sink();
        });
    }

    #[test]
    fn mitm_http_h1_get_captures_request_and_response() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("h1get");
            let host = "flow.test";
            let raw = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nX-Extra: yes\r\n\r\nhello".to_vec();
            let upstream = start_fixture(Arc::clone(&ca), host, Fixture::RawH1(raw)).await;
            let (mut rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-h1", 7).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"http/1.1", ctx).await;
            let out = client_send_h1(&ca, bridge_addr, host, "GET", "/path?q=1", None).await;
            assert_eq!(out.status, 200);
            assert_eq!(out.body, b"hello");
            assert_eq!(out.headers.get("x-extra").unwrap().to_str().unwrap(), "yes");

            let rec = next_record(&mut rx).await;
            assert_eq!(rec.method, "GET");
            assert_eq!(rec.url, "https://flow.test/path?q=1");
            assert_eq!(rec.host, "flow.test");
            assert_eq!(rec.scheme, "https");
            assert_eq!(rec.status_code, 200);
            assert_eq!(rec.protocol, "h1");
            assert_eq!(rec.request_record_id, 7);
            assert!(rec.req_headers.to_lowercase().contains("host: flow.test"));
            assert!(rec.resp_headers.to_lowercase().contains("x-extra: yes"));
            assert_eq!(rec.resp_body, b"hello");
            assert!(!rec.truncated);
            assert!(!rec.mitm_failed);
            reset_capture_sink();
        });
    }

    #[test]
    fn mitm_http_h1_post_captures_request_body() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("h1post");
            let host = "flow.test";
            let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_vec();
            let upstream = start_fixture(Arc::clone(&ca), host, Fixture::RawH1(raw)).await;
            let (mut rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-post", 0).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"http/1.1", ctx).await;
            let out = client_send_h1(
                &ca,
                bridge_addr,
                host,
                "POST",
                "/submit",
                Some(b"data=1".to_vec()),
            )
            .await;
            assert_eq!(out.status, 200);
            assert_eq!(out.body, b"ok");

            let rec = next_record(&mut rx).await;
            assert_eq!(rec.method, "POST");
            assert_eq!(rec.url, "https://flow.test/submit");
            assert_eq!(rec.req_body, b"data=1");
            assert_eq!(rec.req_body_preview, b"data=1");
            assert_eq!(rec.req_bytes, 6);
            reset_capture_sink();
        });
    }

    #[test]
    fn mitm_forward_request_headers_preserve_content_length() {
        let mut src = HeaderMap::new();
        src.insert(CONTENT_LENGTH, HeaderValue::from_static("6"));
        src.insert("x-test", HeaderValue::from_static("1"));
        let mut dst = HeaderMap::new();
        copy_forward_request_headers(&src, &mut dst);
        assert_eq!(
            dst.get(CONTENT_LENGTH).and_then(|v| v.to_str().ok()),
            Some("6"),
            "an unchanged byte-for-byte request body must keep its Content-Length"
        );
        assert_eq!(
            dst.get("x-test").and_then(|v| v.to_str().ok()),
            Some("1"),
            "end-to-end headers must be forwarded"
        );
    }

    #[test]
    fn mitm_forward_request_headers_drop_content_length_when_reframed() {
        let mut src = HeaderMap::new();
        src.insert(CONTENT_LENGTH, HeaderValue::from_static("6"));
        src.insert(TRANSFER_ENCODING, HeaderValue::from_static("chunked"));
        let mut dst = HeaderMap::new();
        copy_forward_request_headers(&src, &mut dst);
        assert!(
            dst.get(CONTENT_LENGTH).is_none(),
            "a client Transfer-Encoding re-frames the tee, so a stale Content-Length must be dropped"
        );
        assert!(
            dst.get(TRANSFER_ENCODING).is_none(),
            "hop-by-hop Transfer-Encoding is never forwarded"
        );
    }

    #[test]
    fn mitm_http_h1_post_forwards_content_length_framing() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("h1post-cl");
            let host = "flow.test";
            let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_vec();
            let observed = Arc::new(StdMutex::new(None));
            let upstream = start_fixture(
                Arc::clone(&ca),
                host,
                Fixture::RawH1Recorded {
                    response: raw,
                    observed: Arc::clone(&observed),
                },
            )
            .await;
            let (_rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-post-cl", 0).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"http/1.1", ctx).await;
            let out = client_send_h1(
                &ca,
                bridge_addr,
                host,
                "POST",
                "/submit",
                Some(b"data=1".to_vec()),
            )
            .await;
            assert_eq!(out.status, 200);
            assert_eq!(out.body, b"ok");

            let head = observed
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone()
                .expect("the origin must have observed the forwarded request head");
            assert!(
                head.contains("content-length: 6"),
                "an h1 upstream POST with a body must keep Content-Length framing: {head}"
            );
            assert!(
                !head.contains("transfer-encoding"),
                "the forwarded POST must not be re-framed as chunked: {head}"
            );
            reset_capture_sink();
        });
    }

    #[test]
    fn mitm_http_h1_get_is_unaffected_by_content_length_preservation() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("h1get-framing");
            let host = "flow.test";
            let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".to_vec();
            let observed = Arc::new(StdMutex::new(None));
            let upstream = start_fixture(
                Arc::clone(&ca),
                host,
                Fixture::RawH1Recorded {
                    response: raw,
                    observed: Arc::clone(&observed),
                },
            )
            .await;
            let (_rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-get-framing", 0).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"http/1.1", ctx).await;
            let out = client_send_h1(&ca, bridge_addr, host, "GET", "/plain", None).await;
            assert_eq!(out.status, 200);
            assert_eq!(out.body, b"hello");

            let head = observed
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone()
                .expect("the origin must have observed the forwarded request head");
            assert!(
                !head.contains("transfer-encoding"),
                "a bodyless GET must never be re-framed as chunked: {head}"
            );
            reset_capture_sink();
        });
    }

    #[test]
    fn mitm_http_h2_get_uses_alpn_h2() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("h2get");
            let host = "flow.test";
            let observed = Arc::new(StdMutex::new(None));
            let upstream = start_fixture(
                Arc::clone(&ca),
                host,
                Fixture::H2 {
                    status: 201,
                    body: b"hello-h2".to_vec(),
                    content_type: "text/plain",
                    observed: Arc::clone(&observed),
                },
            )
            .await;
            let (mut rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-h2", 9).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"h2", ctx).await;
            let out = client_send_h2(&ca, bridge_addr, host, "/h2path").await;
            assert_eq!(out.status, 201);
            assert_eq!(out.body, b"hello-h2");

            let rec = next_record(&mut rx).await;
            assert_eq!(rec.method, "GET");
            assert_eq!(rec.url, "https://flow.test/h2path");
            assert_eq!(rec.status_code, 201);
            assert_eq!(rec.protocol, "h2");
            assert_eq!(rec.resp_body, b"hello-h2");
            assert!(!rec.mitm_failed);
            assert_eq!(
                *observed.lock().unwrap_or_else(|e| e.into_inner()),
                Some(Version::HTTP_2),
                "upstream must have been spoken to over HTTP/2"
            );
            reset_capture_sink();
        });
    }

    #[test]
    fn mitm_http_gzip_is_decoded_only_in_the_capture_copy() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("gzip");
            let host = "flow.test";
            let plaintext = "hello-gzip-".repeat(200);
            let plaintext = plaintext.as_bytes();
            let compressed = gzip(plaintext);
            let mut raw = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\n\r\n",
                compressed.len()
            )
            .into_bytes();
            raw.extend_from_slice(&compressed);
            let upstream = start_fixture(Arc::clone(&ca), host, Fixture::RawH1(raw)).await;
            let (mut rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-gzip", 0).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"http/1.1", ctx).await;
            let out = client_send_h1(&ca, bridge_addr, host, "GET", "/gz", None).await;
            assert_eq!(out.status, 200);
            assert_eq!(
                out.body, compressed,
                "forwarded bytes must be the untouched gzip body"
            );
            assert_eq!(
                out.headers.get("content-encoding").unwrap().to_str().unwrap(),
                "gzip",
                "Content-Encoding must be preserved unchanged"
            );

            let rec = next_record(&mut rx).await;
            assert_eq!(rec.resp_body, plaintext, "capture copy is decompressed");
            assert_eq!(rec.resp_body_preview, &plaintext[..CAPTURE_PREVIEW_MAX_BYTES]);
            assert_eq!(rec.resp_bytes, compressed.len() as u64);
            assert!(!rec.truncated);
            reset_capture_sink();
        });
    }

    #[test]
    fn mitm_http_chunked_body_is_captured() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("chunked");
            let host = "flow.test";
            let raw = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".to_vec();
            let upstream = start_fixture(Arc::clone(&ca), host, Fixture::RawH1(raw)).await;
            let (mut rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-chunk", 0).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"http/1.1", ctx).await;
            let out = client_send_h1(&ca, bridge_addr, host, "GET", "/chunked", None).await;
            assert_eq!(out.status, 200);
            assert_eq!(out.body, b"hello world");

            let rec = next_record(&mut rx).await;
            assert_eq!(rec.resp_body, b"hello world");
            assert!(!rec.truncated);
            reset_capture_sink();
        });
    }

    #[test]
    fn mitm_http_over_limit_body_is_truncated_and_flagged() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("limit");
            let host = "flow.test";
            let total = CAPTURE_BODY_MAX_BYTES + 4096;
            let payload = vec![b'x'; total];
            let mut raw = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {total}\r\n\r\n"
            )
            .into_bytes();
            raw.extend_from_slice(&payload);
            let upstream = start_fixture(Arc::clone(&ca), host, Fixture::RawH1(raw)).await;
            let (mut rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-limit", 0).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"http/1.1", ctx).await;
            let out = client_send_h1(&ca, bridge_addr, host, "GET", "/big", None).await;
            assert_eq!(out.status, 200);
            assert_eq!(out.body.len(), total, "forwarding is never truncated");

            let rec = next_record(&mut rx).await;
            assert_eq!(rec.resp_bytes, total as u64);
            assert_eq!(rec.resp_body.len(), CAPTURE_BODY_MAX_BYTES);
            assert!(rec.truncated, "over-limit capture must set the truncated flag");
            reset_capture_sink();
        });
    }

    #[test]
    fn mitm_http_malformed_response_degrades_without_panic() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("malformed");
            let host = "flow.test";
            let raw = b"THIS IS NOT HTTP\r\n\r\n".to_vec();
            let upstream = start_fixture(Arc::clone(&ca), host, Fixture::RawH1(raw)).await;
            let (mut rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-bad", 0).with_sink(sink);
            let bridge_addr = run_bridge(Arc::clone(&ca), host, upstream, b"http/1.1", ctx).await;
            let out = client_send_h1(&ca, bridge_addr, host, "GET", "/bad", None).await;
            assert_eq!(
                out.status, 502,
                "a malformed upstream response degrades to a structured 502"
            );

            let rec = next_record(&mut rx).await;
            assert!(rec.mitm_failed, "the failed exchange is recorded as mitmFailed");
            reset_capture_sink();
        });
    }

    #[test]
    fn mitm_upstream_failure_returns_502_status_to_client() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("upstream-502");
            let host = "flow.test";
            let (mut rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-502", 0).with_sink(sink);
            let dialer: Arc<dyn UpstreamDialer> = Arc::new(FailingDialer);
            let addr = run_bridge_dialer(Arc::clone(&ca), host, dialer, ctx).await;

            let out = client_send_h1(&ca, addr, host, "GET", "/dead", None).await;
            assert_eq!(
                out.status, UPSTREAM_FAILURE_STATUS,
                "an unreachable upstream must surface the documented status to the client"
            );
            assert_eq!(out.status, 502, "the documented upstream-failure status is 502");

            let rec = next_record(&mut rx).await;
            assert!(
                rec.mitm_failed,
                "the failed exchange is recorded as mitmFailed"
            );
            assert!(
                !rec.failure_reason.is_empty(),
                "a failed exchange must carry its failure reason, got {:?}",
                rec.failure_reason
            );
            reset_capture_sink();
        });
    }

    #[test]
    fn exchange_capture_failure_reason_keeps_the_first_non_empty_reason() {
        let (mut rx, sink) = recording_sink();
        let req_body = BodyCapture::new(false, BodyEncoding::Identity, 0);
        let exchange = ExchangeCapture::new(
            sink,
            HttpProtocol::H1,
            "https",
            "flow.test",
            "conn-reason",
            0,
            "GET",
            "https://flow.test/dead",
            &HeaderMap::new(),
            req_body,
            0,
        );
        exchange.mark_failed("dial timed out");
        exchange.mark_failed("later reason");
        exchange.mark_failed("   ");
        exchange.emit(true);

        let rec = rx.try_recv().expect("emit must push exactly one capture");
        assert!(rec.mitm_failed);
        assert_eq!(rec.failure_reason, "dial timed out");
    }

    // ==================== Todo 15: rewrite matching + execution ====================

    struct TestRuleSource {
        rules: StdMutex<Vec<CaptureRule>>,
    }

    impl TestRuleSource {
        fn new(rules: Vec<CaptureRule>) -> Arc<Self> {
            Arc::new(Self {
                rules: StdMutex::new(rules),
            })
        }

        fn hit_count(&self, id: &str) -> u64 {
            self.rules
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .iter()
                .find(|r| r.id == id)
                .map(|r| r.hit_count)
                .unwrap_or(0)
        }
    }

    impl CaptureRuleSource for TestRuleSource {
        fn match_rule(&self, method: &str, url: &str) -> Option<CaptureRule> {
            let mut rules = self.rules.lock().unwrap_or_else(|e| e.into_inner());
            let idx = rules
                .iter()
                .position(|r| crate::captures::rule_matches(r, method, url))?;
            rules[idx].hit_count += 1;
            Some(rules[idx].clone())
        }
    }

    struct TunnelDialer {
        inner: Arc<meow_tunnel::tunnel::TunnelInner>,
        target: UpstreamTarget,
        tls: UpstreamTlsConfig,
    }

    impl UpstreamDialer for TunnelDialer {
        fn dial(
            &self,
        ) -> Pin<Box<dyn Future<Output = Result<EstablishedUpstream, MitmFailure>> + Send>> {
            let inner = Arc::clone(&self.inner);
            let target = self.target.clone();
            let tls = self.tls.clone();
            Box::pin(async move {
                let stream = open_upstream(&inner, &target, &tls)
                    .await
                    .map_err(|e| MitmFailure::new(e.stage(), e.to_string()))?;
                let proto = HttpProtocol::from_alpn(stream.get_ref().1.alpn_protocol());
                let client = UpstreamClient::establish(stream, proto)
                    .await
                    .map_err(|e| MitmFailure::new(MitmStage::UpstreamHttp, e))?;
                Ok(EstablishedUpstream { client, proto })
            })
        }
    }

    struct FailingDialer;

    impl UpstreamDialer for FailingDialer {
        fn dial(
            &self,
        ) -> Pin<Box<dyn Future<Output = Result<EstablishedUpstream, MitmFailure>> + Send>> {
            Box::pin(async {
                Err(MitmFailure::new(
                    MitmStage::UpstreamDial,
                    "test: upstream unreachable",
                ))
            })
        }
    }

    fn rewrite_rule(
        id: &str,
        kind: &str,
        url: &str,
        status: Option<u16>,
        headers: Option<&str>,
        body: Option<&str>,
    ) -> CaptureRule {
        CaptureRule {
            id: id.to_string(),
            enabled: true,
            method: None,
            url: url.to_string(),
            kind: kind.to_string(),
            status_code: status,
            resp_headers: headers.map(str::to_string),
            resp_body: body.map(str::to_string),
            remark: None,
            delay_ms: 0,
            created_at_ms: 1,
            hit_count: 0,
            match_type: "exact".to_string(),
        }
    }

    fn recording_dialer(
        ca: &Arc<CertificateAuthority>,
        proxy: Arc<RecordingProxy>,
        target_port: u16,
    ) -> Arc<dyn UpstreamDialer> {
        let inner = tunnel_with(
            &["DOMAIN-SUFFIX,flow.test,PROXY"],
            vec![("PROXY", Arc::clone(&proxy) as Arc<dyn meow_common::Proxy>)],
        );
        let target = UpstreamTarget::new("flow.test", target_port);
        let tls = UpstreamTlsConfig::with_roots(trusted_roots(ca));
        Arc::new(TunnelDialer { inner, target, tls })
    }

    async fn closed_forward() -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        format!("127.0.0.1:{}", listener.local_addr().unwrap().port())
            .parse()
            .unwrap()
    }

    async fn run_bridge_dialer(
        ca: Arc<CertificateAuthority>,
        host: &str,
        dialer: Arc<dyn UpstreamDialer>,
        ctx: BridgeContext,
    ) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let host = host.to_string();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let client = match terminate(tcp, &ca, Some(&host)).await {
                MitmTls::Terminated(tls) => tls,
                MitmTls::Passthrough(_) => panic!("expected TLS termination"),
                MitmTls::Failed(e) => panic!("terminate failed: {e}"),
            };
            let _ = bridge_deferred(client, dialer, ctx).await;
        });
        addr
    }

    #[test]
    fn mitm_rewrite_local_short_circuits_without_upstream_dial() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("rewrite-local");
            let host = "flow.test";
            let source = TestRuleSource::new(vec![rewrite_rule(
                "r1",
                "local",
                "https://flow.test/local",
                Some(418),
                Some("content-type: text/plain"),
                Some("local-body"),
            )]);
            let (mut _rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-rw-local", 0)
                .with_sink(sink)
                .with_rule_source(Arc::clone(&source) as Arc<dyn CaptureRuleSource>);
            let forward = closed_forward().await;
            let proxy = RecordingProxy::new("PROXY", forward);
            let dialer = recording_dialer(&ca, Arc::clone(&proxy), 443);
            let addr = run_bridge_dialer(Arc::clone(&ca), host, dialer, ctx).await;

            let out = client_send_h1(&ca, addr, host, "GET", "/local", None).await;
            assert_eq!(out.status, 418);
            assert_eq!(out.body, b"local-body");
            assert_eq!(
                out.headers
                    .get("content-encoding")
                    .unwrap()
                    .to_str()
                    .unwrap(),
                "identity"
            );
            assert_eq!(
                out.headers
                    .get("content-length")
                    .unwrap()
                    .to_str()
                    .unwrap(),
                "10"
            );
            assert_eq!(
                out.headers
                    .get("content-type")
                    .unwrap()
                    .to_str()
                    .unwrap(),
                "text/plain"
            );
            assert!(
                proxy.recorded().is_empty(),
                "a local rewrite must open ZERO upstream dials (saw {:?})",
                proxy.recorded()
            );
            assert_eq!(source.hit_count("r1"), 1, "hitCount increments per hit");
        });
    }

    #[test]
    fn mitm_rewrite_local_repeated_requests_open_zero_upstream_sockets() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("rewrite-local-repeat");
            let host = "flow.test";
            let source = TestRuleSource::new(vec![rewrite_rule(
                "r1",
                "local",
                "https://flow.test/local",
                Some(200),
                Some("content-type: text/plain"),
                Some("local-body"),
            )]);
            let (mut _rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-rw-local-repeat", 0)
                .with_sink(sink)
                .with_rule_source(Arc::clone(&source) as Arc<dyn CaptureRuleSource>);
            let forward = closed_forward().await;
            let proxy = RecordingProxy::new("PROXY", forward);
            let dialer = recording_dialer(&ca, Arc::clone(&proxy), 443);
            let addr = run_bridge_dialer(Arc::clone(&ca), host, dialer, ctx).await;

            let out = client_send_h1_keepalive(&ca, addr, host, &["/local", "/local"]).await;
            assert_eq!(out.len(), 2, "both local requests must complete");
            for o in &out {
                assert_eq!(o.status, 200);
                assert_eq!(o.body, b"local-body");
            }
            assert!(
                proxy.recorded().is_empty(),
                "a local rewrite must open ZERO upstream sockets on every request (saw {:?})",
                proxy.recorded()
            );
            assert_eq!(source.hit_count("r1"), 2, "each request matches the local rule");
        });
    }

    #[test]
    fn mitm_rewrite_glob_and_regex_rules_hit_through_bridge() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("rewrite-match-types");
            let host = "flow.test";
            let mut glob = rewrite_rule(
                "glob",
                "local",
                "https://flow.test/glob/*/end",
                Some(418),
                None,
                Some("glob-body"),
            );
            glob.match_type = "glob".to_string();
            let mut regex = rewrite_rule(
                "regex",
                "local",
                r"^https://flow\.test/re/[0-9]+$",
                Some(419),
                None,
                Some("regex-body"),
            );
            regex.match_type = "regex".to_string();
            let source = TestRuleSource::new(vec![glob, regex]);
            let (mut _rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-rw-match-types", 0)
                .with_sink(sink)
                .with_rule_source(Arc::clone(&source) as Arc<dyn CaptureRuleSource>);
            let forward = closed_forward().await;
            let proxy = RecordingProxy::new("PROXY", forward);
            let dialer = recording_dialer(&ca, Arc::clone(&proxy), 443);
            let addr = run_bridge_dialer(Arc::clone(&ca), host, dialer, ctx).await;

            let g = client_send_h1_keepalive(&ca, addr, host, &["/glob/mid/end", "/re/123"]).await;
            assert_eq!(g.len(), 2, "both match-type requests must complete");
            assert_eq!(g[0].status, 418, "glob rule must hit the mid path");
            assert_eq!(g[0].body, b"glob-body");
            assert_eq!(g[1].status, 419, "regex rule must hit the numeric path");
            assert_eq!(g[1].body, b"regex-body");
            assert!(
                proxy.recorded().is_empty(),
                "local match-type rules open ZERO upstream dials (saw {:?})",
                proxy.recorded()
            );
            assert_eq!(source.hit_count("glob"), 1);
            assert_eq!(source.hit_count("regex"), 1);
        });
    }

    #[test]
    fn mitm_rewrite_replace_overrides_gzip_response_with_plaintext() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("rewrite-replace");
            let host = "flow.test";
            let compressed = gzip(b"upstream-gzip-body");
            let mut raw = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\nX-Upstream: keep\r\n\r\n",
                compressed.len()
            )
            .into_bytes();
            raw.extend_from_slice(&compressed);
            let upstream = start_fixture(Arc::clone(&ca), host, Fixture::RawH1(raw)).await;
            let upstream_port = upstream.port();
            let source = TestRuleSource::new(vec![rewrite_rule(
                "r1",
                "replace",
                "https://flow.test/replace",
                Some(201),
                Some("x-rule: yes"),
                Some("replaced-plain"),
            )]);
            let (mut _rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-rw-replace", 0)
                .with_sink(sink)
                .with_rule_source(Arc::clone(&source) as Arc<dyn CaptureRuleSource>);
            let forward: SocketAddr = format!("127.0.0.1:{upstream_port}").parse().unwrap();
            let proxy = RecordingProxy::new("PROXY", forward);
            let dialer = recording_dialer(&ca, Arc::clone(&proxy), upstream_port);
            let addr = run_bridge_dialer(Arc::clone(&ca), host, dialer, ctx).await;

            let out = client_send_h1(&ca, addr, host, "GET", "/replace", None).await;
            assert_eq!(out.status, 201, "rule status overrides upstream 200");
            assert_eq!(out.body, b"replaced-plain");
            assert_eq!(
                out.headers
                    .get("content-encoding")
                    .unwrap()
                    .to_str()
                    .unwrap(),
                "identity",
                "plaintext override must not keep upstream gzip"
            );
            assert_eq!(
                out.headers
                    .get("content-length")
                    .unwrap()
                    .to_str()
                    .unwrap(),
                "14"
            );
            assert_eq!(out.headers.get("x-rule").unwrap().to_str().unwrap(), "yes");
            assert_eq!(
                out.headers.get("x-upstream").unwrap().to_str().unwrap(),
                "keep",
                "non-overridden upstream headers are preserved"
            );
            assert_eq!(
                proxy.recorded(),
                vec!["flow.test".to_string()],
                "replace dials upstream"
            );
            assert_eq!(source.hit_count("r1"), 1);
        });
    }

    #[test]
    fn mitm_rewrite_replace_body_does_not_poison_h1_keepalive() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("rewrite-keepalive");
            let host = "flow.test";
            let big = vec![b'x'; 64 * 1024];
            let mut first = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\n\r\n",
                big.len()
            )
            .into_bytes();
            first.extend_from_slice(&big);
            let second =
                b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nsecond-ok".to_vec();
            let upstream =
                start_keepalive_fixture(Arc::clone(&ca), host, vec![first, second]).await;
            let upstream_port = upstream.port();
            let source = TestRuleSource::new(vec![rewrite_rule(
                "r1",
                "replace",
                "https://flow.test/first",
                Some(200),
                None,
                Some("replaced-body"),
            )]);
            let (mut _rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-rw-keepalive", 0)
                .with_sink(sink)
                .with_rule_source(Arc::clone(&source) as Arc<dyn CaptureRuleSource>);
            let forward: SocketAddr = format!("127.0.0.1:{upstream_port}").parse().unwrap();
            let proxy = RecordingProxy::new("PROXY", forward);
            let dialer = recording_dialer(&ca, Arc::clone(&proxy), upstream_port);
            let addr = run_bridge_dialer(Arc::clone(&ca), host, dialer, ctx).await;

            let out = client_send_h1_keepalive(&ca, addr, host, &["/first", "/second"]).await;
            assert_eq!(out.len(), 2, "two responses on ONE client connection");
            assert_eq!(out[0].status, 200);
            assert_eq!(out[0].body, b"replaced-body");
            assert_eq!(
                out[1].status, 200,
                "the second keep-alive request must reuse the upstream h1 connection (not 502)"
            );
            assert_eq!(out[1].body, b"second-ok");
        });
    }

    /// Device defect 6 (D11a): an origin that closes the cached upstream after
    /// the first response must not poison the bridge for the next request on the
    /// SAME client TLS connection. The bridge must re-dial and serve `resp-2`
    /// from a fresh origin connection — never a 502 from hyper's `Kind::Canceled`.
    #[test]
    fn mitm_http_re_dials_closed_upstream_on_same_client_connection() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("redial");
            let host = "flow.test";
            let upstream = start_closing_fixture(Arc::clone(&ca), host, "resp-").await;
            let upstream_port = upstream.port();

            let (_rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-redial", 0).with_sink(sink);
            let forward: SocketAddr = format!("127.0.0.1:{upstream_port}").parse().unwrap();
            let proxy = RecordingProxy::new("PROXY", forward);
            let dialer = recording_dialer(&ca, Arc::clone(&proxy), upstream_port);
            let addr = run_bridge_dialer(Arc::clone(&ca), host, dialer, ctx).await;

            let out = client_send_h1_keepalive(&ca, addr, host, &["/one", "/two"]).await;
            assert_eq!(out.len(), 2, "both requests on ONE client connection must complete");
            assert_eq!(out[0].status, 200, "the first request must succeed");
            assert_eq!(out[0].body, b"resp-1");
            assert_ne!(
                out[1].status, 502,
                "reusing the closed upstream must not surface as a 502 Canceled"
            );
            assert_eq!(out[1].status, 200, "the second request must re-dial and succeed");
            assert_eq!(
                out[1].body, b"resp-2",
                "the second response must come from a fresh origin connection"
            );
            assert_eq!(
                proxy.recorded(),
                vec!["flow.test".to_string(), "flow.test".to_string()],
                "the closed cached upstream must be re-dialed exactly once"
            );
        });
    }

    #[test]
    fn mitm_rewrite_replace_without_body_keeps_content_length_consistent() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("rewrite-clen");
            let host = "flow.test";
            let raw = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello".to_vec();
            let upstream = start_fixture(Arc::clone(&ca), host, Fixture::RawH1(raw)).await;
            let upstream_port = upstream.port();
            let source = TestRuleSource::new(vec![rewrite_rule(
                "r1",
                "replace",
                "https://flow.test/clen",
                None,
                Some("content-length: 999"),
                None,
            )]);
            let (mut _rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-rw-clen", 0)
                .with_sink(sink)
                .with_rule_source(Arc::clone(&source) as Arc<dyn CaptureRuleSource>);
            let forward: SocketAddr = format!("127.0.0.1:{upstream_port}").parse().unwrap();
            let proxy = RecordingProxy::new("PROXY", forward);
            let dialer = recording_dialer(&ca, Arc::clone(&proxy), upstream_port);
            let addr = run_bridge_dialer(Arc::clone(&ca), host, dialer, ctx).await;

            let out = client_send_h1(&ca, addr, host, "GET", "/clen", None).await;
            assert_eq!(out.status, 200);
            assert_eq!(out.body, b"hello", "the streamed upstream body is unchanged");
            assert_eq!(
                out.headers.get("content-length").unwrap().to_str().unwrap(),
                "5",
                "a user Content-Length must not desync the streamed body framing"
            );
        });
    }

    #[test]
    fn mitm_rewrite_unmatched_traffic_is_byte_for_byte_unchanged() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("rewrite-unmatched");
            let host = "flow.test";
            let compressed = gzip(b"untouched-gzip");
            let mut raw = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\nX-Extra: yes\r\n\r\n",
                compressed.len()
            )
            .into_bytes();
            raw.extend_from_slice(&compressed);
            let upstream = start_fixture(Arc::clone(&ca), host, Fixture::RawH1(raw)).await;
            let upstream_port = upstream.port();
            let source = TestRuleSource::new(vec![rewrite_rule(
                "r1",
                "local",
                "https://flow.test/other",
                Some(500),
                None,
                Some("nope"),
            )]);
            let (mut _rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-rw-unmatched", 0)
                .with_sink(sink)
                .with_rule_source(Arc::clone(&source) as Arc<dyn CaptureRuleSource>);
            let forward: SocketAddr = format!("127.0.0.1:{upstream_port}").parse().unwrap();
            let proxy = RecordingProxy::new("PROXY", forward);
            let dialer = recording_dialer(&ca, Arc::clone(&proxy), upstream_port);
            let addr = run_bridge_dialer(Arc::clone(&ca), host, dialer, ctx).await;

            let out = client_send_h1(&ca, addr, host, "GET", "/untouched", None).await;
            assert_eq!(out.status, 200);
            assert_eq!(
                out.body, compressed,
                "an unmatched response must be byte-for-byte identical"
            );
            assert_eq!(
                out.headers
                    .get("content-encoding")
                    .unwrap()
                    .to_str()
                    .unwrap(),
                "gzip"
            );
            assert_eq!(out.headers.get("x-extra").unwrap().to_str().unwrap(), "yes");
            assert_eq!(source.hit_count("r1"), 0, "an unmatched rule is never counted");
        });
    }

    #[test]
    fn mitm_rewrite_empty_and_non_json_bodies_returned_as_is() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("rewrite-bodies");
            let host = "flow.test";
            for (path, body, expected_len) in
                [("/empty", "", 0usize), ("/nonjson", "not json {", 10)]
            {
                let source = TestRuleSource::new(vec![rewrite_rule(
                    "r1",
                    "local",
                    &format!("https://flow.test{path}"),
                    Some(200),
                    None,
                    Some(body),
                )]);
                let (mut _rx, sink) = recording_sink();
                let ctx = BridgeContext::new(host, "conn-rw-bodies", 0)
                    .with_sink(sink)
                    .with_rule_source(Arc::clone(&source) as Arc<dyn CaptureRuleSource>);
                let forward = closed_forward().await;
                let proxy = RecordingProxy::new("PROXY", forward);
                let dialer = recording_dialer(&ca, Arc::clone(&proxy), 443);
                let addr = run_bridge_dialer(Arc::clone(&ca), host, dialer, ctx).await;

                let out = client_send_h1(&ca, addr, host, "GET", path, None).await;
                assert_eq!(out.status, 200, "empty/non-JSON bodies must not crash");
                assert_eq!(out.body, body.as_bytes(), "rule body is returned verbatim");
                assert_eq!(
                    out.headers
                        .get("content-length")
                        .unwrap()
                        .to_str()
                        .unwrap(),
                    expected_len.to_string()
                );
                assert!(proxy.recorded().is_empty());
            }
        });
    }

    #[test]
    fn mitm_rewrite_matches_store_and_bumps_hit_count() {
        let _g = crate::captures::rules_test_guard();
        crate::captures::rules_reset_for_tests();
        let rule = crate::captures::rules_set(
            br#"{"enabled":true,"method":"get","url":"https://hit.test/a","kind":"replace"}"#,
        )
        .unwrap();
        assert!(
            crate::captures::match_enabled_rule("GET", "https://hit.test/a").is_some(),
            "enabled + method + exact url matches"
        );
        assert!(
            crate::captures::match_enabled_rule("POST", "https://hit.test/a").is_none(),
            "the method filter excludes other methods"
        );
        assert!(
            crate::captures::match_enabled_rule("GET", "https://hit.test/b").is_none(),
            "the url must match exactly"
        );
        let hit = crate::captures::rules_get()
            .into_iter()
            .find(|r| r.id == rule.id)
            .unwrap();
        assert_eq!(hit.hit_count, 1, "each hit increments hitCount");

        crate::captures::rules_set(
            format!(
                r#"{{"id":"{}","enabled":false,"url":"https://hit.test/a","kind":"replace"}}"#,
                rule.id
            )
            .as_bytes(),
        )
        .unwrap();
        assert!(
            crate::captures::match_enabled_rule("GET", "https://hit.test/a").is_none(),
            "a disabled rule never matches"
        );
        crate::captures::rules_reset_for_tests();
    }

    /// One h1 client connection that stays open, so the hot-apply test can send
    /// several requests over the *same* connection (no reconnect).
    async fn client_h1_session(
        ca: &CertificateAuthority,
        addr: SocketAddr,
        host: &str,
    ) -> client_http1::SendRequest<Full<Bytes>> {
        let tcp = TcpStream::connect(addr).await.unwrap();
        let connector = TlsConnector::from(client_tls(ca, b"http/1.1"));
        let tls = connector
            .connect(ServerName::try_from(host.to_string()).unwrap(), tcp)
            .await
            .unwrap();
        let mut builder = client_http1::Builder::new();
        builder.max_buf_size(H1_MAX_BUF_SIZE);
        let (sender, conn) = builder
            .handshake::<_, Full<Bytes>>(TokioIo::new(tls))
            .await
            .unwrap();
        tokio::spawn(async move {
            let _ = conn.await;
        });
        sender
    }

    async fn send_h1_on(
        sender: &mut client_http1::SendRequest<Full<Bytes>>,
        host: &str,
        method: &str,
        path: &str,
    ) -> ClientOutcome {
        let request = Request::builder()
            .method(method)
            .uri(path)
            .header(HOST, host)
            .body(Full::new(Bytes::new()))
            .unwrap();
        let response = sender.send_request(request).await.unwrap();
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let body = response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .to_vec();
        ClientOutcome {
            status,
            headers,
            body,
        }
    }

    /// T16 hot-apply (data plane): a runtime `capture.rules.set` / `remove` is
    /// observed on the very next request over the SAME connection, through the
    /// live `StoreRuleSource` — no engine restart and no reconnect.
    #[test]
    fn capture_rules_hot_engine_set_takes_effect_without_reconnect() {
        let _g = crate::captures::rules_test_guard();
        crate::captures::rules_reset_for_tests();
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = temp_ca("hot-apply");
            let host = "flow.test";
            let observed = Arc::new(StdMutex::new(None));
            let upstream = start_fixture(
                Arc::clone(&ca),
                host,
                Fixture::H2 {
                    status: 200,
                    body: b"upstream".to_vec(),
                    content_type: "text/plain",
                    observed,
                },
            )
            .await;
            let (mut _rx, sink) = recording_sink();
            let ctx = BridgeContext::new(host, "conn-hot", 0).with_sink(sink);
            let addr = run_bridge(Arc::clone(&ca), host, upstream, b"h2", ctx).await;

            let mut sender = client_h1_session(&ca, addr, host).await;
            let before = send_h1_on(&mut sender, host, "GET", "/hot").await;
            assert_eq!(before.status, 200, "no rule yet -> serviced upstream");
            assert_eq!(before.body, b"upstream");

            let rule = crate::captures::rules_set(
                br#"{"enabled":true,"url":"https://flow.test/hot","kind":"local","statusCode":418,"body":"hot"}"#,
            )
            .unwrap();
            let after = send_h1_on(&mut sender, host, "GET", "/hot").await;
            assert_eq!(
                after.status, 418,
                "the very next hit must use the freshly set rule"
            );
            assert_eq!(after.body, b"hot");
            let hit = crate::captures::rules_get()
                .into_iter()
                .find(|r| r.id == rule.id)
                .unwrap();
            assert_eq!(hit.hit_count, 1, "the hot hit was counted via the live snapshot");

            crate::captures::rules_remove(format!(r#"{{"id":"{}"}}"#, rule.id).as_bytes()).unwrap();
            let restored = send_h1_on(&mut sender, host, "GET", "/hot").await;
            assert_eq!(
                restored.status, 200,
                "remove invalidates on the very next hit"
            );
            assert_eq!(restored.body, b"upstream");
        });
        crate::captures::rules_reset_for_tests();
    }

    // ==================== Plaintext-HTTP e2e (todo 7) ====================

    fn current_thread() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("current-thread runtime")
    }

    /// A plaintext (non-TLS) HTTP/1.1 fixture over a bare `TcpStream`: a hyper
    /// `server_http1` connection with no `TlsAcceptor`, so a dialer that tried a
    /// TLS handshake could not talk to it.
    async fn start_plain_http_fixture(body: Vec<u8>) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let service = hyper::service::service_fn(move |_req: Request<Incoming>| {
                let body = body.clone();
                async move {
                    let mut response = Response::new(Full::new(Bytes::from(body)));
                    response.headers_mut().insert(
                        CONTENT_TYPE,
                        HeaderValue::from_static("text/plain"),
                    );
                    Ok::<_, Infallible>(response)
                }
            });
            let _ = server_http1::Builder::new()
                .keep_alive(false)
                .serve_connection(TokioIo::new(tcp), service)
                .await;
        });
        addr
    }

    /// Plaintext counterpart of [`client_send_h1`]: no TLS handshake, HTTP/1.1
    /// spoken directly over the socket.
    async fn client_send_h1_plain(
        addr: SocketAddr,
        host: &str,
        method: &str,
        path: &str,
        body: Option<Vec<u8>>,
    ) -> ClientOutcome {
        let tcp = TcpStream::connect(addr).await.unwrap();
        let mut builder = client_http1::Builder::new();
        builder.max_buf_size(H1_MAX_BUF_SIZE);
        let (mut sender, conn) = builder
            .handshake::<_, Full<Bytes>>(TokioIo::new(tcp))
            .await
            .unwrap();
        tokio::spawn(async move {
            let _ = conn.await;
        });
        let payload = body.map(Bytes::from).unwrap_or_default();
        let request = Request::builder()
            .method(method)
            .uri(path)
            .header(HOST, host)
            .body(Full::new(payload))
            .unwrap();
        let response = sender.send_request(request).await.unwrap();
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let body = response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .to_vec();
        ClientOutcome {
            status,
            headers,
            body,
        }
    }

    /// Serve one plaintext client connection through the production plaintext
    /// bridge entry ([`bridge_deferred_plain`]), returning the bound address.
    async fn run_bridge_plain(
        dialer: Arc<dyn UpstreamDialer>,
        ctx: BridgeContext,
    ) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let _ = bridge_deferred_plain(tcp, dialer, ctx).await;
        });
        addr
    }

    /// (a) End-to-end: a plaintext HTTP/1.1 exchange driven through
    /// `bridge_deferred_plain` is captured with `scheme == "http"`, the real
    /// method/url/status/bodies, and the non-zero skeleton id it was opened with.
    #[test]
    fn plaintext_http_e2e_is_captured_with_scheme_http() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            crate::requests::reset_for_tests();

            let host = "flow.test";
            let upstream = start_plain_http_fixture(b"plain-upstream".to_vec()).await;
            let inner = tunnel_with(&["DOMAIN,flow.test,DIRECT"], vec![]);
            let target = UpstreamTarget::new(host, upstream.port())
                .with_dst_ip("127.0.0.1".parse().unwrap());
            let dialer: Arc<dyn UpstreamDialer> =
                Arc::new(PlainUpstreamDialer::new(inner, target));

            let (mut rx, sink) = recording_sink();
            let src: SocketAddr = "10.0.0.2:40000".parse().unwrap();
            let dst: SocketAddr = format!("127.0.0.1:{}", upstream.port()).parse().unwrap();
            let rid = crate::requests::open_mitm_flow(
                "conn-plain-e2e",
                host,
                src,
                dst,
                crate::now_ms(),
            );
            assert_ne!(rid, 0, "the session skeleton id must be minted");
            let ctx = BridgeContext::new(host, "conn-plain-e2e", rid)
                .with_scheme("http")
                .with_sink(sink);

            let bridge_addr = run_bridge_plain(dialer, ctx).await;
            let out = client_send_h1_plain(
                bridge_addr,
                host,
                "POST",
                "/hello",
                Some(b"req-body".to_vec()),
            )
            .await;
            assert_eq!(out.status, 200);
            assert_eq!(out.body, b"plain-upstream");

            let rec = next_record(&mut rx).await;
            assert_eq!(rec.scheme, "http");
            assert_eq!(rec.method, "POST");
            assert_eq!(rec.url, "http://flow.test/hello");
            assert_eq!(rec.status_code, 200);
            assert_eq!(rec.req_body, b"req-body");
            assert_eq!(rec.resp_body, b"plain-upstream");
            assert_eq!(
                rec.request_record_id, rid,
                "the capture must link to the session's request skeleton"
            );
            assert_ne!(rec.request_record_id, 0);

            crate::requests::reset_for_tests();
        });
    }

    /// (c) `PlainUpstreamDialer::dial` reaches the plaintext fixture and yields an
    /// `EstablishedUpstream { proto: H1 }`. The fixture is a bare `server_http1`,
    /// and the dialer only calls `dial_upstream` + `establish`, never
    /// `connect_upstream_tls`, so no TLS handshake is attempted.
    #[test]
    fn plain_upstream_dialer_dials_plaintext_fixture_as_h1() {
        let rt = current_thread();
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let host = "flow.test";
            let upstream = start_plain_http_fixture(b"plain-ok".to_vec()).await;
            let inner = tunnel_with(&["DOMAIN,flow.test,DIRECT"], vec![]);
            let target = UpstreamTarget::new(host, upstream.port())
                .with_dst_ip("127.0.0.1".parse().unwrap());
            let dialer = PlainUpstreamDialer::new(inner, target);

            let established = dialer
                .dial()
                .await
                .expect("plaintext upstream dial must succeed against a plain fixture");
            assert_eq!(
                established.proto,
                HttpProtocol::H1,
                "a plaintext upstream is always HTTP/1.1"
            );
        });
    }
}

#[cfg(test)]
mod mitm_ws_tests {
    use super::*;
    use rustls::pki_types::ServerName;
    use rustls::RootCertStore;
    use std::net::SocketAddr;
    use std::sync::atomic::AtomicU64 as WsSeq;
    use std::sync::Mutex as StdMutex;
    use std::time::Duration;
    use tokio::net::{TcpListener, TcpStream};
    use tokio::sync::mpsc;
    use tokio_rustls::{TlsAcceptor, TlsConnector};
    use tokio_tungstenite::tungstenite::handshake::server as ws_server;
    use tokio_tungstenite::tungstenite::ClientRequestBuilder;
    use tokio_tungstenite::{accept_hdr_async_with_config, client_async_with_config};

    static WS_SEQ: WsSeq = WsSeq::new(0);

    fn ws_temp_ca(tag: &str) -> Arc<CertificateAuthority> {
        let n = WS_SEQ.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "gstore-mitm-ws-{}-{}-{}",
            std::process::id(),
            tag,
            n
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Arc::new(CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate CA"))
    }

    fn ws_roots(ca: &CertificateAuthority) -> RootCertStore {
        let mut store = RootCertStore::empty();
        store.add(ca.der().clone()).expect("trust CA");
        store
    }

    fn ws_client_tls(ca: &CertificateAuthority, alpn: &[u8]) -> Arc<rustls::ClientConfig> {
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let mut config = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("versions")
            .with_root_certificates(ws_roots(ca))
            .with_no_client_auth();
        config.alpn_protocols = vec![alpn.to_vec()];
        Arc::new(config)
    }

    struct WsChannelSink(mpsc::UnboundedSender<WsFrameRecord>);

    impl WsFrameSink for WsChannelSink {
        fn on_ws_frame(&self, _host: &str, _conn_id: &str, frame: &WsFrameRecord) {
            let _ = self.0.send(frame.clone());
        }
    }

    fn ws_recording_sink() -> (mpsc::UnboundedReceiver<WsFrameRecord>, Arc<dyn WsFrameSink>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (rx, Arc::new(WsChannelSink(tx)))
    }

    async fn ws_collect_until<F>(
        rx: &mut mpsc::UnboundedReceiver<WsFrameRecord>,
        done: F,
    ) -> Vec<WsFrameRecord>
    where
        F: Fn(&[WsFrameRecord]) -> bool,
    {
        let mut out = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while tokio::time::Instant::now() < deadline {
            match tokio::time::timeout_at(deadline, rx.recv()).await {
                Ok(Some(frame)) => {
                    out.push(frame);
                    if done(&out) {
                        break;
                    }
                }
                _ => break,
            }
        }
        out
    }

    async fn ws_next_msg<S>(ws: &mut WebSocketStream<S>) -> WsMessage
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        tokio::time::timeout(Duration::from_secs(10), ws.next())
            .await
            .expect("ws next must not hang")
            .expect("ws stream open")
            .expect("ws frame parses")
    }

    fn has_frame(frames: &[WsFrameRecord], direction: WsDirection, opcode: &str) -> bool {
        frames
            .iter()
            .any(|f| f.direction == direction && f.opcode == opcode)
    }

    #[test]
    fn mitm_ws_session_buffer_budget_is_bounded() {
        assert_eq!(WS_PER_SIDE_BUDGET_BYTES, 53_248);
        assert_eq!(MITM_WS_TWO_SIDES_BYTES, 106_496);
        assert_eq!(MITM_RUSTLS_TWO_CONNS_BYTES, 32_768);
        assert_eq!(MITM_H1_TWO_CONNS_BYTES, 262_144);
        assert_eq!(MITM_H2_TWO_CONNS_BYTES, 204_800);
        assert_eq!(MITM_SESSION_BUDGET_BYTES, 606_208);
        assert!(MITM_SESSION_BUDGET_BYTES <= crate::limits::MITM_SESSION_BUFFER_MAX_BYTES);

        let config = ws_config();
        assert_eq!(config.read_buffer_size, WS_READ_BUFFER_SIZE);
        assert_eq!(config.write_buffer_size, WS_WRITE_BUFFER_SIZE);
        assert_eq!(config.max_write_buffer_size, WS_MAX_WRITE_BUFFER_SIZE);
        assert_eq!(config.max_message_size, Some(WS_MAX_MESSAGE_SIZE));
        assert_eq!(config.max_frame_size, Some(WS_MAX_FRAME_SIZE));
        assert!(
            config.write_buffer_size < config.max_write_buffer_size,
            "tungstenite would panic if this invariant were violated"
        );
    }

    #[test]
    fn mitm_ws_frames_recorded_with_direction_preview_and_boundaries() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let (client_side, client_peer) = tokio::io::duplex(1 << 16);
            let (upstream_side, fixture_peer) = tokio::io::duplex(1 << 16);
            let bridge_client =
                WebSocketStream::from_raw_socket(client_side, Role::Server, Some(ws_config())).await;
            let mut client =
                WebSocketStream::from_raw_socket(client_peer, Role::Client, Some(ws_config())).await;
            let bridge_upstream =
                WebSocketStream::from_raw_socket(upstream_side, Role::Client, Some(ws_config())).await;
            let mut fixture =
                WebSocketStream::from_raw_socket(fixture_peer, Role::Server, Some(ws_config())).await;

            let (mut rx, sink) = ws_recording_sink();
            let pump = tokio::spawn(run_ws_pump(
                bridge_client,
                bridge_upstream,
                "flow.test",
                "conn-ws",
                sink,
            ));

            client.send(WsMessage::text("hello")).await.unwrap();
            client.send(WsMessage::binary(vec![1u8, 2, 3])).await.unwrap();
            client.send(WsMessage::binary(vec![4u8, 5, 6])).await.unwrap();
            client.send(WsMessage::Ping(vec![9u8].into())).await.unwrap();

            // The fixture must receive the client's messages unmerged (frame
            // boundaries preserved) and echo each back.
            let expected = [
                WsMessage::text("hello"),
                WsMessage::binary(vec![1u8, 2, 3]),
                WsMessage::binary(vec![4u8, 5, 6]),
                WsMessage::Ping(vec![9u8].into()),
            ];
            let mut echoed = 0;
            for want in expected.iter() {
                let got = ws_next_msg(&mut fixture).await;
                assert_eq!(&got, want, "frame boundary preserved on forward");
                fixture.send(got).await.unwrap();
                echoed += 1;
            }
            assert_eq!(echoed, 4);

            fixture.send(WsMessage::text("from-server")).await.unwrap();
            fixture.send(WsMessage::binary(vec![0u8; 1024])).await.unwrap();
            fixture.send(WsMessage::Ping(vec![1u8].into())).await.unwrap();

            let frames = ws_collect_until(&mut rx, |f| {
                has_frame(f, WsDirection::ClientToServer, "text")
                    && has_frame(f, WsDirection::ClientToServer, "binary")
                    && has_frame(f, WsDirection::ClientToServer, "ping")
                    && has_frame(f, WsDirection::ServerToClient, "text")
                    && has_frame(f, WsDirection::ServerToClient, "binary")
                    && has_frame(f, WsDirection::ServerToClient, "ping")
                    && f.iter().any(|x| x.payload_len == 1024)
            })
            .await;

            let c2s_texts: Vec<Vec<u8>> = frames
                .iter()
                .filter(|f| f.direction == WsDirection::ClientToServer && f.opcode == "text")
                .map(|f| f.preview.clone())
                .collect();
            assert_eq!(c2s_texts, vec![b"hello".to_vec()]);

            let s2c_texts: Vec<Vec<u8>> = frames
                .iter()
                .filter(|f| f.direction == WsDirection::ServerToClient && f.opcode == "text")
                .map(|f| f.preview.clone())
                .collect();
            assert!(s2c_texts.contains(&b"hello".to_vec()), "echo recorded as S2C");
            assert!(
                s2c_texts.contains(&b"from-server".to_vec()),
                "origin text recorded as S2C"
            );
            assert!(
                !c2s_texts.contains(&b"from-server".to_vec()),
                "origin frame must not be mislabelled client→server"
            );

            let c2s_bins: Vec<Vec<u8>> = frames
                .iter()
                .filter(|f| f.direction == WsDirection::ClientToServer && f.opcode == "binary")
                .map(|f| f.preview.clone())
                .collect();
            assert_eq!(c2s_bins, vec![vec![1u8, 2, 3], vec![4u8, 5, 6]]);

            let big = frames
                .iter()
                .find(|f| f.direction == WsDirection::ServerToClient && f.payload_len == 1024)
                .expect("the over-limit frame is recorded");
            assert_eq!(big.opcode, "binary");
            assert_eq!(big.preview.len(), WS_PREVIEW_MAX_BYTES, "preview is bounded");
            assert!(big.truncated, "over-limit payload flagged truncated");

            pump.abort();
        });
    }

    #[test]
    fn mitm_ws_close_is_recorded_and_closes_cleanly() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let (client_side, client_peer) = tokio::io::duplex(1 << 16);
            let (upstream_side, fixture_peer) = tokio::io::duplex(1 << 16);
            let bridge_client =
                WebSocketStream::from_raw_socket(client_side, Role::Server, Some(ws_config())).await;
            let mut client =
                WebSocketStream::from_raw_socket(client_peer, Role::Client, Some(ws_config())).await;
            let bridge_upstream =
                WebSocketStream::from_raw_socket(upstream_side, Role::Client, Some(ws_config())).await;
            let _fixture =
                WebSocketStream::from_raw_socket(fixture_peer, Role::Server, Some(ws_config())).await;

            let (mut rx, sink) = ws_recording_sink();
            let pump = tokio::spawn(run_ws_pump(
                bridge_client,
                bridge_upstream,
                "flow.test",
                "conn-close",
                sink,
            ));

            client.send(WsMessage::Close(None)).await.unwrap();
            let frames = ws_collect_until(&mut rx, |f| {
                has_frame(f, WsDirection::ClientToServer, "close")
            })
            .await;
            let close = frames
                .iter()
                .find(|f| f.direction == WsDirection::ClientToServer && f.opcode == "close")
                .expect("client close frame recorded");
            assert!(!close.truncated);

            let outcome = tokio::time::timeout(Duration::from_secs(10), pump)
                .await
                .expect("the pump must finish after a close, not hang")
                .expect("the pump must not panic");
            assert_eq!(outcome, ());
        });
    }

    async fn spawn_ws_fixture(
        ca: Arc<CertificateAuthority>,
        host: &str,
        seen_extensions: Arc<StdMutex<Option<bool>>>,
    ) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let config = ca.server_config(host).unwrap();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let tls = TlsAcceptor::from(config).accept(tcp).await.unwrap();
            let probe = Arc::clone(&seen_extensions);
            let callback = move |
                request: &ws_server::Request,
                mut response: ws_server::Response,
            | -> Result<ws_server::Response, ws_server::ErrorResponse> {
                let has = request.headers().contains_key("sec-websocket-extensions");
                *probe.lock().unwrap_or_else(|e| e.into_inner()) = Some(has);
                response.headers_mut().insert(
                    HeaderName::from_static("sec-websocket-extensions"),
                    HeaderValue::from_static("permessage-deflate"),
                );
                Ok(response)
            };
            let mut ws = accept_hdr_async_with_config(tls, callback, Some(ws_config()))
                .await
                .expect("origin accepts the websocket handshake");
            let _ = ws.send(WsMessage::text("srv-hello")).await;
            while let Some(Ok(message)) = ws.next().await {
                if message.is_close() {
                    break;
                }
                if ws.send(message).await.is_err() {
                    break;
                }
            }
        });
        addr
    }

    async fn spawn_mitm_ws_bridge(
        ca: Arc<CertificateAuthority>,
        host: &str,
        upstream_addr: SocketAddr,
        sink: Arc<dyn WsFrameSink>,
    ) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let host_owned = host.to_string();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let client = match terminate(tcp, &ca, Some(&host_owned)).await {
                MitmTls::Terminated(tls) => tls,
                MitmTls::Passthrough(_) => panic!("expected TLS termination"),
                MitmTls::Failed(e) => panic!("terminate failed: {e}"),
            };
            let tcp_up = TcpStream::connect(upstream_addr).await.unwrap();
            let connector = TlsConnector::from(ws_client_tls(&ca, b"http/1.1"));
            let sni = ServerName::try_from(host_owned.clone()).unwrap();
            let upstream = connector.connect(sni, tcp_up).await.unwrap();
            let ctx = BridgeContext::new(host_owned, "conn-ws-int", 0).with_ws_sink(sink);
            let _ = bridge(client, upstream, ctx).await;
        });
        addr
    }

    #[test]
    fn mitm_ws_permessage_deflate_extensions_are_stripped_both_ways() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = ws_temp_ca("deflate");
            let host = "flow.test";
            let seen_extensions = Arc::new(StdMutex::new(None));
            let upstream = spawn_ws_fixture(
                Arc::clone(&ca),
                host,
                Arc::clone(&seen_extensions),
            )
            .await;
            let (mut rx, sink) = ws_recording_sink();
            let bridge_addr = spawn_mitm_ws_bridge(Arc::clone(&ca), host, upstream, sink).await;

            let tcp = TcpStream::connect(bridge_addr).await.unwrap();
            let tls = TlsConnector::from(ws_client_tls(&ca, b"http/1.1"))
                .connect(ServerName::try_from(host.to_string()).unwrap(), tcp)
                .await
                .unwrap();
            let uri: Uri = format!("ws://{host}/socket").parse().unwrap();
            let request = ClientRequestBuilder::new(uri)
                .with_header("Sec-WebSocket-Extensions", "permessage-deflate");
            let (mut ws, response) = client_async_with_config(request, tls, Some(ws_config()))
                .await
                .expect("a permessage-deflate client must still connect (extensions stripped)");
            assert_eq!(response.status(), 101);
            assert!(
                response.headers().get("sec-websocket-extensions").is_none(),
                "the origin's extension answer must be stripped before reaching the client"
            );
            assert_eq!(
                *seen_extensions.lock().unwrap_or_else(|e| e.into_inner()),
                Some(false),
                "the client's extension offer must never reach the origin"
            );

            ws.send(WsMessage::text("hello-ws")).await.unwrap();
            let mut got_echo = false;
            for _ in 0..3 {
                let message = ws_next_msg(&mut ws).await;
                if message == WsMessage::text("hello-ws") {
                    got_echo = true;
                    break;
                }
            }
            assert!(got_echo, "uncompressed frames must round-trip through the MITM");

            let frames = ws_collect_until(&mut rx, |f| {
                f.iter().any(|x| {
                    x.direction == WsDirection::ClientToServer
                        && x.opcode == "text"
                        && x.preview == b"hello-ws"
                }) && f.iter().any(|x| {
                    x.direction == WsDirection::ServerToClient
                        && x.opcode == "text"
                        && x.preview == b"hello-ws"
                })
            })
            .await;
            assert!(
                frames.iter().any(|f| {
                    f.direction == WsDirection::ClientToServer
                        && f.opcode == "text"
                        && f.preview == b"hello-ws"
                }),
                "the MITM path must record the client text frame"
            );
            assert!(
                frames.iter().any(|f| {
                    f.direction == WsDirection::ServerToClient
                        && f.opcode == "text"
                        && f.preview == b"hello-ws"
                }),
                "the MITM path must record the origin echo as server→client"
            );
        });
    }
}

// R6 regression: the drain must consume a lazy many-frame body one frame at a
// time. The body reports how many frames the consumer holds at once, so the
// frame-by-frame drain (1 resident) and a buffering `collect()` (all resident)
// produce different observables.
#[cfg(test)]
mod mitm_drain_tests {
    use super::*;
    use hyper::body::Buf;
    use std::io::IoSlice;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    struct TrackedBuf {
        inner: Bytes,
        live_bytes: Arc<AtomicUsize>,
        live_frames: Arc<AtomicUsize>,
        size: usize,
    }

    impl Buf for TrackedBuf {
        fn remaining(&self) -> usize {
            self.inner.remaining()
        }
        fn chunk(&self) -> &[u8] {
            self.inner.chunk()
        }
        fn advance(&mut self, cnt: usize) {
            self.inner.advance(cnt)
        }
        fn copy_to_bytes(&mut self, len: usize) -> Bytes {
            self.inner.copy_to_bytes(len)
        }
        fn chunks_vectored<'a>(&'a self, dst: &mut [IoSlice<'a>]) -> usize {
            self.inner.chunks_vectored(dst)
        }
    }

    impl Drop for TrackedBuf {
        fn drop(&mut self) {
            self.live_bytes.fetch_sub(self.size, Ordering::SeqCst);
            self.live_frames.fetch_sub(1, Ordering::SeqCst);
        }
    }

    /// Lazily yields `remaining` data frames of `frame_bytes` each without ever
    /// holding more than the frame currently being produced.
    struct LazyTrackedBody {
        remaining: usize,
        frame_bytes: usize,
        live_bytes: Arc<AtomicUsize>,
        live_frames: Arc<AtomicUsize>,
        max_live_bytes: Arc<AtomicUsize>,
        max_live_frames: Arc<AtomicUsize>,
        emitted: Arc<AtomicUsize>,
    }

    impl Body for LazyTrackedBody {
        type Data = TrackedBuf;
        type Error = Infallible;

        fn poll_frame(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
        ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
            let this = self.get_mut();
            if this.remaining == 0 {
                return Poll::Ready(None);
            }
            this.remaining -= 1;
            let buf = TrackedBuf {
                inner: Bytes::from(vec![0u8; this.frame_bytes]),
                live_bytes: Arc::clone(&this.live_bytes),
                live_frames: Arc::clone(&this.live_frames),
                size: this.frame_bytes,
            };
            let live_bytes =
                this.live_bytes.fetch_add(this.frame_bytes, Ordering::SeqCst) + this.frame_bytes;
            let live_frames = this.live_frames.fetch_add(1, Ordering::SeqCst) + 1;
            this.max_live_bytes.fetch_max(live_bytes, Ordering::SeqCst);
            this.max_live_frames.fetch_max(live_frames, Ordering::SeqCst);
            this.emitted.fetch_add(1, Ordering::SeqCst);
            Poll::Ready(Some(Ok(Frame::data(buf))))
        }
    }

    #[test]
    fn drain_discarded_upstream_body_never_buffers_the_discarded_body() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            const FRAMES: usize = 10_000;
            const FRAME_BYTES: usize = 64 * 1024;

            let live_bytes = Arc::new(AtomicUsize::new(0));
            let live_frames = Arc::new(AtomicUsize::new(0));
            let max_live_bytes = Arc::new(AtomicUsize::new(0));
            let max_live_frames = Arc::new(AtomicUsize::new(0));
            let emitted = Arc::new(AtomicUsize::new(0));
            let body = LazyTrackedBody {
                remaining: FRAMES,
                frame_bytes: FRAME_BYTES,
                live_bytes: Arc::clone(&live_bytes),
                live_frames: Arc::clone(&live_frames),
                max_live_bytes: Arc::clone(&max_live_bytes),
                max_live_frames: Arc::clone(&max_live_frames),
                emitted: Arc::clone(&emitted),
            };

            // The drain takes the gate permit and must not release it until the
            // body is fully consumed: the test holds the semaphore's only slot
            // and can only re-acquire it once the drain is done.
            let sem = Arc::new(Semaphore::new(1));
            let permit = Arc::clone(&sem).acquire_owned().await.expect("permit");
            let start = Instant::now();
            drain_discarded_upstream_body(body, Some(permit));

            let _permit = tokio::time::timeout(Duration::from_secs(30), sem.acquire())
                .await
                .expect("drain must finish promptly")
                .expect("drain releases the gate permit");
            let elapsed = start.elapsed();

            assert_eq!(
                emitted.load(Ordering::SeqCst),
                FRAMES,
                "every frame of the discarded body must be consumed"
            );
            assert_eq!(
                live_bytes.load(Ordering::SeqCst),
                0,
                "nothing may remain resident after the drain"
            );
            assert_eq!(
                max_live_frames.load(Ordering::SeqCst),
                1,
                "the drain must hold exactly one frame at a time (a buffering \
                 collect() would hold all {FRAMES})"
            );
            assert!(
                max_live_bytes.load(Ordering::SeqCst) <= FRAME_BYTES,
                "resident bytes {:?} exceeded one frame {FRAME_BYTES}",
                max_live_bytes.load(Ordering::SeqCst)
            );
            assert!(
                elapsed < Duration::from_secs(10),
                "streaming drain took {elapsed:?}"
            );
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64 as Seq, Ordering as SeqOrd};

    static TEMP_SEQ: Seq = Seq::new(0);

    fn temp_dir(tag: &str) -> PathBuf {
        let n = TEMP_SEQ.fetch_add(1, SeqOrd::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "gstore-mitm-{}-{}-{}",
            std::process::id(),
            tag,
            n
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn ca_path(dir: &Path) -> PathBuf {
        dir.join(MITM_DIR).join(CA_CERT_FILE)
    }

    fn key_path(dir: &Path) -> PathBuf {
        dir.join(MITM_DIR).join(CA_KEY_FILE)
    }

    /// Happy: generate → persist → reload must reproduce the exact same
    /// certificate (identical DER and fingerprint).
    #[test]
    fn mitm_ca_generate_reload_keeps_identical_fingerprint() {
        let dir = temp_dir("reload");
        let ca = CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate");
        let fp = ca.fingerprint_sha256();
        let der = ca.der().as_ref().to_vec();
        let pem = ca.pem().to_string();
        assert_eq!(fp.len(), 64, "sha256 hex");
        assert!(ca_path(&dir).exists(), "ca.pem persisted");
        assert!(key_path(&dir).exists(), "ca.key persisted");

        let reloaded = CertificateAuthority::load(dir.to_str().unwrap())
            .expect("load")
            .expect("ca present after generate");
        assert_eq!(reloaded.fingerprint_sha256(), fp, "fingerprint stable across reload");
        assert_eq!(reloaded.der().as_ref(), der.as_slice());
        assert_eq!(reloaded.pem(), pem);
        assert!(reloaded.pem().starts_with("-----BEGIN CERTIFICATE-----"));
        assert!(reloaded.pem().len() <= MITM_PEM_BUFFER_MAX_BYTES);
    }

    /// Dirty worktree guard: the CA private key must be mode `0600`.
    #[test]
    #[cfg(unix)]
    fn mitm_ca_key_file_is_0600() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = temp_dir("mode");
        let _ca = CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate");
        let mode = std::fs::metadata(key_path(&dir)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "ca.key must be 0600, got {:o}", mode & 0o777);
        // The cert is public material and need not be secret.
        let cert_mode = std::fs::metadata(ca_path(&dir)).unwrap().permissions().mode();
        assert_ne!(cert_mode & 0o777, 0o600, "ca.pem is not a secret");
    }

    /// Misleading-success guard: a second request for the same host MUST be a
    /// cache hit — the signing counter must not move and the same `ServerConfig`
    /// `Arc` must be returned.
    #[test]
    fn mitm_ca_same_host_second_request_is_cache_hit() {
        let dir = temp_dir("hit");
        let ca = CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate");

        let first = ca.server_config("a.example").expect("first leaf");
        assert_eq!(ca.signings(), 1, "one signing after one cold request");

        let second = ca.server_config("a.example").expect("second leaf");
        assert_eq!(ca.signings(), 1, "cache hit must NOT re-sign");
        assert!(Arc::ptr_eq(&first, &second), "cache hit must return the same config");
        assert_eq!(ca.cache_len(), 1);

        // A different host is a miss and does sign.
        let _other = ca.server_config("b.example").expect("other leaf");
        assert_eq!(ca.signings(), 2, "a distinct host signs once");
        assert_eq!(ca.cache_len(), 2);
    }

    /// `reset` removes the on-disk CA and drops the cached leaf, so the old leaf
    /// is no longer served and a new one is signed.
    #[test]
    fn mitm_ca_reset_invalidates_old_leaf() {
        let dir = temp_dir("reset");
        let ca = CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate");
        let first = ca.server_config("a.example").expect("leaf");
        assert_eq!(ca.signings(), 1);
        assert_eq!(ca.cache_len(), 1);

        assert!(ca.reset().expect("reset"), "reset reports it cleared state");
        assert!(!ca_path(&dir).exists(), "ca.pem removed");
        assert!(!key_path(&dir).exists(), "ca.key removed");
        assert_eq!(ca.cache_len(), 0, "leaf cache dropped");
        assert!(
            CertificateAuthority::load(dir.to_str().unwrap()).unwrap().is_none(),
            "no CA after reset"
        );

        let rebuilt = ca.server_config("a.example").expect("re-signed leaf");
        assert_eq!(ca.signings(), 2, "old cached leaf was not reused");
        assert!(!Arc::ptr_eq(&first, &rebuilt), "a fresh ServerConfig was built");
        assert!(!CertificateAuthority::reset_at(dir.to_str().unwrap()).expect("reset_at"));
    }

    /// Unbounded-growth guard: over the cap the oldest entry is evicted exactly
    /// once and the cache stays bounded.
    #[test]
    fn mitm_ca_cache_evicts_oldest_over_cap() {
        let dir = temp_dir("evict");
        let ca = CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate");
        let total = MITM_CERT_CACHE_CAP + 1;
        for i in 0..total {
            ca.server_config(&format!("h{i}.example")).expect("leaf");
        }
        assert_eq!(ca.cache_len(), MITM_CERT_CACHE_CAP, "cache bounded to the cap");
        assert_eq!(ca.evicted(), 1, "exactly the oldest entry was evicted");
        assert_eq!(ca.signings(), total as u64);

        let keys: Vec<String> = {
            let cache = ca.cache.lock().unwrap_or_else(|e| e.into_inner());
            cache.entries.keys().cloned().collect()
        };
        assert!(!keys.iter().any(|k| k == "h0.example"), "oldest (h0) evicted");
        assert!(keys.iter().any(|k| k == "h1.example"), "second-oldest retained");
        assert!(keys.iter().any(|k| k.as_str() == format!("h{}.example", total - 1)));
    }

    /// Failure scenario: a corrupted `ca.pem` is treated as not-generated, with
    /// no panic.
    #[test]
    fn mitm_ca_corrupt_pem_is_not_generated() {
        let dir = temp_dir("corrupt");
        let _ca = CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate");
        std::fs::write(ca_path(&dir), "-----BEGIN CERTIFICATE-----\nnot base64!!!\n").unwrap();
        let loaded = CertificateAuthority::load(dir.to_str().unwrap()).expect("load must not error");
        assert!(loaded.is_none(), "corrupt ca.pem => not generated");

        // Missing key is likewise not-generated.
        let dir2 = temp_dir("missing-key");
        let _ca2 = CertificateAuthority::generate(dir2.to_str().unwrap()).expect("generate");
        std::fs::remove_file(key_path(&dir2)).unwrap();
        assert!(CertificateAuthority::load(dir2.to_str().unwrap()).unwrap().is_none());

        // Empty data dir never panics.
        assert!(CertificateAuthority::load("").unwrap().is_none());
    }

    /// The accounted entry size must fit the cap the memory budget charges.
    #[test]
    fn mitm_ca_entry_size_within_cap() {
        let dir = temp_dir("size");
        let ca = CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate");
        // Worst-case host length (DNS name upper bound).
        let host = "a".repeat(253);
        let leaf = ca.issue_leaf(&host).expect("leaf");
        let size = estimate_entry_bytes(&host, &leaf.0);
        assert!(
            size <= MITM_CERT_ENTRY_MAX_BYTES,
            "entry {size} B exceeds cap {MITM_CERT_ENTRY_MAX_BYTES} B"
        );
    }

    /// Host normalization: ports, brackets, case and trailing dots are removed
    /// so the same logical host always maps to one cache entry.
    #[test]
    fn mitm_ca_host_normalization() {
        assert_eq!(normalize_host("Example.COM.").unwrap(), "example.com");
        assert_eq!(normalize_host("example.com:443").unwrap(), "example.com");
        assert_eq!(normalize_host("[2606:4700::1111]:443").unwrap(), "2606:4700::1111");
        assert!(normalize_host("   ").is_err());
    }

    /// PEM round-trip used by persistence.
    #[test]
    fn mitm_ca_pem_roundtrip() {
        let der: Vec<u8> = (0u8..=255).collect();
        let pem = pem_encode("CERTIFICATE", &der);
        assert_eq!(pem_decode(&pem).unwrap(), der);
        assert!(pem_decode("garbage").is_none());
    }

    /// The six stage labels are a diagnostic contract: a device log grep and
    /// the session-failure line depend on these exact spellings.
    #[test]
    fn mitm_stage_labels_are_stable() {
        assert_eq!(MitmStage::ClientTls.as_str(), "client_tls");
        assert_eq!(MitmStage::UpstreamDial.as_str(), "upstream_dial");
        assert_eq!(MitmStage::UpstreamTls.as_str(), "upstream_tls");
        assert_eq!(MitmStage::UpstreamHttp.as_str(), "upstream_http");
        assert_eq!(MitmStage::ClientHttp.as_str(), "client_http");
        assert_eq!(MitmStage::ClientAbort.as_str(), "client_abort");
        let failure = MitmFailure::new(MitmStage::UpstreamHttp, "boom");
        assert!(failure.to_string().contains("stage=upstream_http"));
        assert_eq!(failure.message(), "boom");
        assert!(!failure.is_client_abort());
    }

    #[test]
    fn mitm_client_abort_failure_is_classified_and_carries_diagnostics() {
        let failure = MitmFailure::new(MitmStage::ClientAbort, "error shutting down connection")
            .with_client_proto(HttpProtocol::H1)
            .with_method("POST")
            .with_upstream_proto(HttpProtocol::H2);
        assert!(failure.is_client_abort());
        assert_eq!(failure.stage().as_str(), "client_abort");
        let rendered = failure.diagnostics().render();
        assert!(rendered.contains("client_proto=h1"), "{rendered}");
        assert!(rendered.contains("method=POST"), "{rendered}");
        assert!(rendered.contains("upstream_proto=h2"), "{rendered}");
    }

    /// A forced upstream failure maps to the right stage: a refused/hung dial is
    /// `upstream_dial`, a certificate/handshake rejection is `upstream_tls`.
    #[test]
    fn mitm_upstream_error_stage_mapping() {
        assert_eq!(UpstreamError::dial("boom").stage(), MitmStage::UpstreamDial);
        assert_eq!(UpstreamError::no_route().stage(), MitmStage::UpstreamDial);
        assert_eq!(UpstreamError::tls("bad cert").stage(), MitmStage::UpstreamTls);
    }
}

/// Todo 5 acceptance: rustls TLS termination with a per-SNI certificate
/// resolver, ALPN `h2`/`http/1.1`, the fixed no-host passthrough decision, and
/// clean handshake-failure handling. A **real** rustls client drives the
/// acceptor over a loopback socket (no lwIP), so the assertions are on the
/// actually negotiated leaf/SAN and ALPN, not merely that a handshake finished.
#[cfg(test)]
mod mitm_tls_tests {
    use super::*;
    use rustls::client::danger::{
        HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier,
    };
    use rustls::pki_types::{ServerName, UnixTime};
    use rustls::{DigitallySignedStruct, RootCertStore, SignatureScheme};
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};
    use tokio_rustls::TlsConnector;

    static TLS_SEQ: AtomicU64 = AtomicU64::new(0);

    fn tls_temp_dir(tag: &str) -> PathBuf {
        let n = TLS_SEQ.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "gstore-mitm-tls-{}-{}-{}",
            std::process::id(),
            tag,
            n
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn ca_at(tag: &str) -> Arc<CertificateAuthority> {
        let dir = tls_temp_dir(tag);
        Arc::new(CertificateAuthority::generate(dir.to_str().unwrap()).expect("generate CA"))
    }

    fn provider() -> Arc<rustls::crypto::CryptoProvider> {
        Arc::new(rustls::crypto::aws_lc_rs::default_provider())
    }

    /// What the *client* observed after a completed handshake.
    struct Observed {
        alpn: Option<Vec<u8>>,
        leaf: Vec<u8>,
    }

    fn observe(tls: &tokio_rustls::client::TlsStream<TcpStream>) -> Observed {
        let (_, conn) = tls.get_ref();
        Observed {
            alpn: conn.alpn_protocol().map(|p| p.to_vec()),
            leaf: conn
                .peer_certificates()
                .and_then(|chain| chain.first())
                .map(|cert| cert.as_ref().to_vec())
                .unwrap_or_default(),
        }
    }

    /// True when `der` (a certificate or chain) carries a SAN `dNSName` equal to
    /// `name`. A dNSName is an ASN.1 `[2] IA5String` GeneralName, wire-encoded
    /// `0x82 <len> <ascii>`; a raw byte search asserts the SAN text itself
    /// without pulling in an X.509 parser.
    fn san_contains_dns(der: &[u8], name: &str) -> bool {
        assert!(name.len() < 128, "test host names are short single-byte lengths");
        let mut needle = vec![0x82u8, name.len() as u8];
        needle.extend_from_slice(name.as_bytes());
        der.windows(needle.len()).any(|window| window == needle.as_slice())
    }

    fn client_config(ca: &CertificateAuthority, alpn: &[u8]) -> Arc<rustls::ClientConfig> {
        let mut roots = RootCertStore::empty();
        roots.add(ca.der().clone()).expect("trust the MITM CA");
        let mut cfg = rustls::ClientConfig::builder_with_provider(provider())
            .with_safe_default_protocol_versions()
            .expect("protocol versions")
            .with_root_certificates(roots)
            .with_no_client_auth();
        cfg.alpn_protocols = vec![alpn.to_vec()];
        Arc::new(cfg)
    }

    /// Run one handshake: server terminates over a loopback socket using the
    /// *known flow host* `flow_host`; client connects with SNI `sni`.
    async fn handshake(
        ca: &Arc<CertificateAuthority>,
        flow_host: &str,
        sni: &'static str,
        alpn: &'static [u8],
    ) -> Result<Observed, String> {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|e| e.to_string())?;
        let addr = listener.local_addr().map_err(|e| e.to_string())?;
        let ca_server = Arc::clone(ca);
        let flow = Some(flow_host.to_string());
        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.map_err(|e| e.to_string())?;
            match terminate(tcp, &ca_server, flow.as_deref()).await {
                MitmTls::Terminated(_tls) => Ok::<(), String>(()),
                MitmTls::Passthrough(_) => Err("server took the passthrough path".to_string()),
                MitmTls::Failed(e) => Err(format!("server handshake failed: {e}")),
            }
        });

        let connector = TlsConnector::from(client_config(ca, alpn));
        let tcp = TcpStream::connect(addr).await.map_err(|e| e.to_string())?;
        let tls = connector
            .connect(
                ServerName::try_from(sni).map_err(|e| e.to_string())?,
                tcp,
            )
            .await
            .map_err(|e| format!("client handshake: {e}"))?;
        let observed = observe(&tls);
        server.await.map_err(|e| format!("server join: {e}"))??;
        Ok(observed)
    }

    /// Adversarial: each SNI must receive **its own** leaf (asserted via the SAN)
    /// and must not be served a stale leaf issued for a different host.
    #[test]
    fn mitm_tls_sni_selects_matching_leaf() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = ca_at("sni");
            let a = handshake(&ca, "a.example", "a.example", b"h2")
                .await
                .expect("handshake for a.example");
            assert!(
                san_contains_dns(&a.leaf, "a.example"),
                "a.example must get a leaf whose SAN is a.example"
            );
            assert!(
                !san_contains_dns(&a.leaf, "b.example"),
                "a.example must NOT get b.example's leaf"
            );

            let b = handshake(&ca, "b.example", "b.example", b"h2")
                .await
                .expect("handshake for b.example");
            assert!(
                san_contains_dns(&b.leaf, "b.example"),
                "b.example must get a leaf whose SAN is b.example"
            );
            assert!(
                !san_contains_dns(&b.leaf, "a.example"),
                "stale-state guard: b.example must NOT be served a.example's cached leaf"
            );
            assert_ne!(a.leaf, b.leaf, "distinct hosts must yield distinct leaves");
            assert_eq!(ca.signings(), 2, "one signing per distinct host");
        });
    }

    /// ALPN must negotiate both advertised branches.
    #[test]
    fn mitm_tls_alpn_negotiates_h2_and_http11() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = ca_at("alpn");
            let h2 = handshake(&ca, "a.example", "a.example", b"h2")
                .await
                .expect("h2 handshake");
            assert_eq!(
                h2.alpn.as_deref(),
                Some(b"h2".as_slice()),
                "server must negotiate h2 when offered"
            );
            let h1 = handshake(&ca, "a.example", "a.example", b"http/1.1")
                .await
                .expect("http/1.1 handshake");
            assert_eq!(
                h1.alpn.as_deref(),
                Some(b"http/1.1".as_slice()),
                "server must negotiate http/1.1 when offered"
            );
            assert_eq!(ca.signings(), 1, "same host reuses the cached leaf");
        });
    }

    /// Fixed no-SNI decision: an unknown flow host must take the passthrough
    /// path without reading a byte and without issuing a certificate.
    #[test]
    fn mitm_tls_unknown_host_is_passthrough() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = ca_at("no-host");
            let (mut client, server) = tokio::io::duplex(64);
            client.write_all(b"hello").await.expect("pre-write");
            match terminate(server, &ca, None).await {
                MitmTls::Passthrough(mut stream) => {
                    let mut buf = [0u8; 5];
                    stream.read_exact(&mut buf).await.expect("bytes preserved");
                    assert_eq!(&buf, b"hello", "passthrough must not consume bytes");
                }
                _ => panic!("unknown host must pass through, never MITM"),
            }
            assert_eq!(ca.signings(), 0, "no leaf may be issued without a host");
            assert_eq!(ca.cache_len(), 0);
        });
    }

    /// A known flow host with a client that sends no SNI is still signed for
    /// that host (the resolver's fallback), and the leaf's SAN is that host.
    #[test]
    fn mitm_tls_known_host_without_sni_uses_flow_host() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = ca_at("fallback");
            let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
            let addr = listener.local_addr().expect("addr");
            let ca_server = Arc::clone(&ca);
            let server = tokio::spawn(async move {
                let (tcp, _) = listener.accept().await.map_err(|e| e.to_string())?;
                match terminate(tcp, &ca_server, Some("fallback.example")).await {
                    MitmTls::Terminated(_tls) => Ok::<(), String>(()),
                    MitmTls::Passthrough(_) => Err("unexpected passthrough".to_string()),
                    MitmTls::Failed(e) => Err(format!("server failed: {e}")),
                }
            });

            let provider = provider();
            let mut cfg = rustls::ClientConfig::builder_with_provider(Arc::clone(&provider))
                .with_safe_default_protocol_versions()
                .expect("versions")
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(AcceptAnyCert(provider)))
                .with_no_client_auth();
            cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
            let connector = TlsConnector::from(Arc::new(cfg));
            let tcp = TcpStream::connect(addr).await.expect("connect");
            // An IP-literal ServerName is never sent as SNI.
            let sni = ServerName::try_from("127.0.0.1").expect("ip server name");
            let tls = connector
                .connect(sni, tcp)
                .await
                .map_err(|e| format!("client handshake: {e}"))
                .expect("no-SNI handshake");
            let observed = observe(&tls);
            server.await.expect("join").expect("server");
            assert!(
                san_contains_dns(&observed.leaf, "fallback.example"),
                "no-SNI flow must be signed for the known flow host"
            );
            assert_eq!(ca.signings(), 1, "exactly one leaf for the fallback host");
        });
    }

    /// Malformed ClientHello: garbage bytes must fail the handshake cleanly, the
    /// connection must close, and nothing may panic.
    #[test]
    fn mitm_tls_garbage_client_bytes_fail_cleanly() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let ca = ca_at("garbage");
            let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
            let addr = listener.local_addr().expect("addr");
            let ca_server = Arc::clone(&ca);
            let server = tokio::spawn(async move {
                let (tcp, _) = listener.accept().await.expect("accept");
                terminate(tcp, &ca_server, Some("g.example")).await
            });

            let mut client = TcpStream::connect(addr).await.expect("connect");
            client.write_all(&[0xffu8; 32]).await.expect("garbage write");
            client.flush().await.expect("flush");

            let result = tokio::time::timeout(Duration::from_secs(10), server)
                .await
                .expect("server must not hang")
                .expect("server must not panic");
            assert!(
                matches!(result, MitmTls::Failed(_)),
                "garbage ClientHello must report a clean handshake failure"
            );

            let mut sink = [0u8; 64];
            let closed = tokio::time::timeout(Duration::from_secs(10), async {
                loop {
                    match client.read(&mut sink).await {
                        Ok(0) => break true,
                        Ok(_) => continue,
                        Err(_) => break false,
                    }
                }
            })
            .await
            .expect("client must not hang");
            assert!(closed, "server must close the connection after a failed handshake");
        });
    }

    /// Test-only verifier that accepts any leaf, used solely to drive a client
    /// that deliberately sends no SNI.
    #[derive(Debug)]
    struct AcceptAnyCert(Arc<rustls::crypto::CryptoProvider>);

    impl ServerCertVerifier for AcceptAnyCert {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp_response: &[u8],
            _now: UnixTime,
        ) -> Result<ServerCertVerified, rustls::Error> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            self.0.signature_verification_algorithms.supported_schemes()
        }
    }
}

/// Todo 7 acceptance: upstream re-origination through the tunnel.
///
/// A [`RecordingProxy`] outbound proves the **configured route** was taken — the
/// target it observed and the TCP connection it opened — rather than a bare dial
/// around the rules engine; a `DIRECT` rule dials directly (a rule *result*); the
/// TLS client handshakes over the tunneled connection with the same `aws_lc_rs`
/// provider; and an unreachable upstream is a structured 502-style
/// `PROXY_CAPTURE_UPSTREAM_FAILED` with no panic.
#[cfg(test)]
mod mitm_upstream_tests {
    use super::*;
    use meow_common::{
        AdapterType, DelayHistory, Metadata, Proxy, ProxyAdapter, ProxyConn, ProxyHealth,
        ProxyPacketConn, Rule,
    };
    use std::collections::HashMap;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::sync::atomic::AtomicBool;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};
    use tokio_rustls::TlsAcceptor;

    use crate::TEST_SERIAL as SERIAL;

    /// A local TLS fixture that accepts one connection, completes the handshake
    /// with the CA's leaf for `host`, and then drops. Returns the bound port and
    /// the server task (awaited so a handshake panic would surface).
    async fn tls_fixture(
        ca: &Arc<CertificateAuthority>,
        host: &str,
    ) -> Result<(u16, tokio::task::JoinHandle<()>), String> {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|e| format!("fixture bind: {e}"))?;
        let port = listener.local_addr().map_err(|e| e.to_string())?.port();
        let cfg = ca.server_config(host).map_err(|e| e.to_string())?;
        let handle = tokio::spawn(async move {
            if let Ok((tcp, _)) = listener.accept().await {
                let _ = TlsAcceptor::from(cfg).accept(tcp).await;
            }
        });
        Ok((port, handle))
    }

    pub(super) fn trusted_roots(ca: &CertificateAuthority) -> RootCertStore {
        let mut roots = RootCertStore::empty();
        roots.add(ca.der().clone()).expect("trust the test CA");
        roots
    }

    pub(super) fn test_resolver() -> Arc<meow_dns::Resolver> {
        Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ))
    }

    /// Build a live tunnel with `lines` rules and `name -> proxy` entries, as
    /// `Tunnel::new` + `update_rules` + `update_proxies` (never a bare adapter).
    pub(super) fn tunnel_with(
        lines: &[&str],
        proxies: Vec<(&str, Arc<dyn Proxy>)>,
    ) -> Arc<meow_tunnel::tunnel::TunnelInner> {
        tunnel_with_resolver(test_resolver(), lines, proxies)
    }

    /// [`tunnel_with`] over a caller-supplied resolver, so a FakeIp-mode test
    /// can drive the real `DirectAdapter` re-resolution path.
    pub(super) fn tunnel_with_resolver(
        resolver: Arc<meow_dns::Resolver>,
        lines: &[&str],
        proxies: Vec<(&str, Arc<dyn Proxy>)>,
    ) -> Arc<meow_tunnel::tunnel::TunnelInner> {
        let tunnel = meow_tunnel::Tunnel::new(resolver);
        let rules: Vec<Box<dyn Rule>> = lines
            .iter()
            .map(|line| {
                meow_rules::parser::parse_rule(line, &meow_rules::ParserContext::empty())
                    .expect("test rule parses")
            })
            .collect();
        tunnel.update_rules(rules);
        let mut map: HashMap<smol_str::SmolStr, Arc<dyn Proxy>> = HashMap::new();
        for (name, proxy) in proxies {
            map.insert(smol_str::SmolStr::from(name), proxy);
        }
        tunnel.update_proxies(map);
        tunnel.inner().clone()
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let n = TLS_SEQ.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "gstore-mitm-upstream-{}-{}-{}",
            std::process::id(),
            tag,
            n
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    static TLS_SEQ: AtomicU64 = AtomicU64::new(0);

    /// Outbound test adapter that records the target it was asked to reach and
    /// forwards the connection to a fixed local fixture. Its presence in the
    /// dial path is the proof the tunnel selected *this* configured outbound.
    pub(super) struct RecordingProxy {
        name: String,
        health: ProxyHealth,
        dials: Mutex<Vec<String>>,
        observations: Mutex<Vec<(String, Option<IpAddr>)>>,
        forward: SocketAddr,
    }

    impl RecordingProxy {
        pub(super) fn new(name: &str, forward: SocketAddr) -> Arc<Self> {
            Arc::new(Self {
                name: name.to_string(),
                health: ProxyHealth::new(),
                dials: Mutex::new(Vec::new()),
                observations: Mutex::new(Vec::new()),
                forward,
            })
        }

        pub(super) fn recorded(&self) -> Vec<String> {
            self.dials.lock().unwrap_or_else(|e| e.into_inner()).clone()
        }

        /// The `(rule_host, dst_ip)` pair observed at dial time. Lets a test
        /// assert the fake-IP rewrite actually cleared `dst_ip`.
        pub(super) fn observed(&self) -> Vec<(String, Option<IpAddr>)> {
            self.observations
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone()
        }
    }

    #[async_trait::async_trait]
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
        async fn dial_tcp(&self, metadata: &Metadata) -> meow_common::Result<Box<dyn ProxyConn>> {
            self.dials
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(metadata.rule_host().to_string());
            self.observations
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push((metadata.rule_host().to_string(), metadata.dst_ip));
            let stream = TcpStream::connect(self.forward).await?;
            Ok(Box::new(stream))
        }
        async fn dial_udp(
            &self,
            _metadata: &Metadata,
        ) -> meow_common::Result<Box<dyn ProxyPacketConn>> {
            Err(meow_common::MeowError::NotSupported("recording".into()))
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

    /// Happy path: the rule engine selects the configured `PROXY`, whose
    /// `RecordingProxy::dial_tcp` records `upstream.test`, and the TLS client
    /// then handshakes over that tunneled connection to the fixture. Asserting
    /// the recorded target is what distinguishes a real outbound from a bare
    /// dial that ignored the rules.
    #[test]
    fn mitm_upstream_dial_selects_configured_outbound_and_handshakes() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let dir = temp_dir("outbound");
            let ca = Arc::new(CertificateAuthority::generate(dir.to_str().unwrap()).expect("ca"));
            let (port, fixture) = tls_fixture(&ca, "upstream.test").await.expect("fixture");
            let forward: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
            let proxy = RecordingProxy::new("PROXY", forward);
            let inner = tunnel_with(
                &["DOMAIN-SUFFIX,upstream.test,PROXY"],
                vec![("PROXY", Arc::clone(&proxy) as Arc<dyn Proxy>)],
            );

            let target = UpstreamTarget::new("upstream.test", port)
                .with_dst_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));
            let tls = UpstreamTlsConfig::with_roots(trusted_roots(&ca));

            let stream = open_upstream(&inner, &target, &tls)
                .await
                .expect("upstream handshake through the configured outbound");
            assert!(
                stream
                    .get_ref()
                    .1
                    .peer_certificates()
                    .map(|c| !c.is_empty())
                    .unwrap_or(false),
                "a completed handshake must expose the fixture's leaf chain"
            );
            let _ = fixture.await;

            assert_eq!(
                proxy.recorded(),
                vec!["upstream.test".to_string()],
                "the configured outbound must have been dialed for the target (not a bare dial)"
            );
        });
    }

    /// A `DIRECT` rule is a rule *result*: the dial goes direct (no proxy in the
    /// registry) and still reaches the fixture over TLS.
    #[test]
    fn mitm_upstream_direct_rule_dials_directly() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let dir = temp_dir("direct");
            let ca = Arc::new(CertificateAuthority::generate(dir.to_str().unwrap()).expect("ca"));
            let (port, fixture) = tls_fixture(&ca, "direct.test").await.expect("fixture");
            let inner = tunnel_with(&["DOMAIN,direct.test,DIRECT"], Vec::new());

            let target =
                UpstreamTarget::new("direct.test", port).with_dst_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));
            let tls = UpstreamTlsConfig::with_roots(trusted_roots(&ca));

            let stream = open_upstream(&inner, &target, &tls)
                .await
                .expect("DIRECT rule must dial and handshake");
            assert!(
                stream.get_ref().1.peer_certificates().is_some(),
                "DIRECT TLS handshake must expose the fixture leaf"
            );
            let _ = fixture.await;
        });
    }

    /// Adversarial fake-IP proof. Under FakeIp mode the TUN path injects the
    /// synthetic address as `dst_ip`; `dial_upstream` must rewrite it to the
    /// host and re-resolve the REAL address. The fake pool is a loopback subnet
    /// here, so an un-rewritten dial is caught by a decoy fixture listening on
    /// the fake IP instead of merely failing — the assertion is on which
    /// fixture received the dialed bytes, not that no error occurred.
    #[test]
    fn mitm_upstream_fake_ip_dst_is_rewritten_to_real_address() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let host = "flow.test";
            let real_ip = IpAddr::V4(Ipv4Addr::LOCALHOST);

            let resolver = fake_ip_resolver().await;
            let fake_ip = resolver.lookup_ipv4(host).await.expect("synthesise fake IP");
            assert!(resolver.is_fake_ip(fake_ip), "synthesised IP must be fake");
            assert_eq!(resolver.reverse_lookup(fake_ip).as_deref(), Some(host));
            resolver.preload_cache(host, &[real_ip], Duration::from_secs(60));

            let real_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
            let port = real_listener.local_addr().unwrap().port();
            let decoy_listener = TcpListener::bind(SocketAddr::new(fake_ip, port))
                .await
                .expect("fake-IP loopback address must be bindable");

            let real_hit = Arc::new(AtomicBool::new(false));
            let decoy_hit = Arc::new(AtomicBool::new(false));
            let real_flag = Arc::clone(&real_hit);
            let real_task = tokio::spawn(async move {
                let Ok((mut tcp, _)) = real_listener.accept().await else {
                    return;
                };
                real_flag.store(true, Ordering::SeqCst);
                let mut buf = [0u8; 4];
                let _ = tcp.read_exact(&mut buf).await;
                let _ = tcp.write_all(b"real").await;
            });
            let decoy_flag = Arc::clone(&decoy_hit);
            let decoy_task = tokio::spawn(async move {
                if decoy_listener.accept().await.is_ok() {
                    decoy_flag.store(true, Ordering::SeqCst);
                }
            });

            let inner =
                tunnel_with_resolver(resolver, &["DOMAIN,flow.test,DIRECT"], Vec::new());
            let target = UpstreamTarget::new(host, port).with_dst_ip(fake_ip);
            let mut conn = dial_upstream(&inner, &target)
                .await
                .expect("dial must use the resolved real address");

            conn.write_all(b"ping").await.unwrap();
            let mut reply = [0u8; 4];
            conn.read_exact(&mut reply).await.unwrap();
            assert_eq!(&reply, b"real", "the resolved-real-IP fixture answered");

            tokio::time::timeout(Duration::from_secs(5), real_task)
                .await
                .expect("real fixture must be reached")
                .unwrap();
            tokio::time::sleep(Duration::from_millis(100)).await;
            assert!(real_hit.load(Ordering::SeqCst), "real IP was dialed");
            assert!(
                !decoy_hit.load(Ordering::SeqCst),
                "the fake IP must never be dialed"
            );
            decoy_task.abort();
        });
    }

    /// The rewrite must be observable as a cleared `dst_ip`: a configured
    /// outbound receiving the dial metadata sees `dst_ip = None` and the
    /// recovered host, so `DirectAdapter::resolve_targets` cannot prefer the
    /// dead fake address.
    #[test]
    fn mitm_upstream_fake_ip_dst_is_cleared_at_dial() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let host = "flow.test";
            let resolver = fake_ip_resolver().await;
            let fake_ip = resolver.lookup_ipv4(host).await.expect("synthesise fake IP");

            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let forward = listener.local_addr().unwrap();
            let proxy = RecordingProxy::new("PROXY", forward);
            let inner = tunnel_with_resolver(
                resolver,
                &["DOMAIN,flow.test,PROXY"],
                vec![("PROXY", Arc::clone(&proxy) as Arc<dyn Proxy>)],
            );
            let target = UpstreamTarget::new(host, forward.port()).with_dst_ip(fake_ip);
            drop(dial_upstream(&inner, &target).await);

            assert_eq!(
                proxy.observed(),
                vec![(host.to_string(), None)],
                "dial metadata must carry the real host and a cleared dst_ip"
            );
        });
    }

    /// A FakeIp resolver over a bindable loopback subnet, so the synthetic IP
    /// can be listened on by a decoy. The resolver has no upstream nameservers;
    /// callers seed the real answer via `preload_cache`.
    async fn fake_ip_resolver() -> Arc<meow_dns::Resolver> {
        let mut resolver = meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::FakeIp,
            meow_trie::DomainTrie::new(),
            true,
            true,
        );
        let net = "127.18.0.0/16".parse::<ipnet::IpNet>().unwrap();
        resolver.set_fakeip_v4(Arc::new(
            meow_dns::Pool::new(net, Arc::new(meow_dns::MemoryStore::new(1024))).unwrap(),
        ));
        Arc::new(resolver)
    }

    /// A forced upstream TLS failure (TCP accepted then reset before the
    /// handshake completes) is tagged `upstream_tls`, not a generic dial error.
    #[test]
    fn mitm_upstream_tcp_reset_maps_to_upstream_tls_stage() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let dir = temp_dir("stage-tls");
            let ca = Arc::new(CertificateAuthority::generate(dir.to_str().unwrap()).expect("ca"));
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            tokio::spawn(async move {
                if let Ok((tcp, _)) = listener.accept().await {
                    drop(tcp);
                }
            });
            let inner = tunnel_with(&["DOMAIN,stall.test,DIRECT"], Vec::new());
            let target = UpstreamTarget::new("stall.test", port)
                .with_dst_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));
            let dialer = TunnelUpstreamDialer::new(
                inner,
                target,
                UpstreamTlsConfig::with_roots(trusted_roots(&ca)),
            );
            let failure = dialer
                .dial()
                .await
                .err()
                .expect("a reset TCP must fail the upstream TLS handshake");
            assert_eq!(failure.stage().as_str(), "upstream_tls");
        });
    }

    /// The default is strict: `skip_cert_verify == false`, and an untrusted leaf
    /// (empty trust anchors) is rejected with the structured error.
    #[test]
    fn mitm_upstream_default_is_strict_and_rejects_untrusted() {
        assert!(
            !UpstreamTlsConfig::default().skip_cert_verify(),
            "skipCertVerify must default to STRICT"
        );
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let dir = temp_dir("strict");
            let ca = Arc::new(CertificateAuthority::generate(dir.to_str().unwrap()).expect("ca"));
            let (port, fixture) = tls_fixture(&ca, "untrusted.test").await.expect("fixture");
            let inner = tunnel_with(&["DOMAIN,untrusted.test,DIRECT"], Vec::new());

            let target = UpstreamTarget::new("untrusted.test", port)
                .with_dst_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));
            let strict = UpstreamTlsConfig::default();

            let err = open_upstream(&inner, &target, &strict)
                .await
                .err()
                .expect("strict default must reject an untrusted upstream leaf");
            assert_eq!(err.kind(), "tls", "rejection must be a TLS failure");
            assert_eq!(err.status(), 502, "upstream failures are 502-style");
            assert_eq!(err.code(), ERR_CAPTURE_UPSTREAM_FAILED);
            let _ = fixture.await;
        });
    }

    /// `skipCertVerify` is an explicit opt-in: with it set, an otherwise
    /// untrusted leaf handshakes. This is never the default.
    #[test]
    fn mitm_upstream_skip_cert_verify_is_opt_in() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let dir = temp_dir("skip");
            let ca = Arc::new(CertificateAuthority::generate(dir.to_str().unwrap()).expect("ca"));
            let (port, fixture) = tls_fixture(&ca, "skip.test").await.expect("fixture");
            let inner = tunnel_with(&["DOMAIN,skip.test,DIRECT"], Vec::new());

            let target =
                UpstreamTarget::new("skip.test", port).with_dst_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));
            let tls = UpstreamTlsConfig::default().with_skip_cert_verify(true);

            let stream = open_upstream(&inner, &target, &tls)
                .await
                .expect("opt-in skipCertVerify must handshake");
            assert!(stream.get_ref().1.peer_certificates().is_some());
            let _ = fixture.await;
        });
    }

    /// Failure path: an unreachable upstream returns a structured 502-style
    /// `PROXY_CAPTURE_UPSTREAM_FAILED` without hanging or panicking.
    #[test]
    fn mitm_upstream_unreachable_is_502_upstream_failed() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            // A bound-then-dropped port is reliably refused on loopback.
            let closed = {
                let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
                listener.local_addr().expect("addr").port()
            };
            let inner = tunnel_with(&["DOMAIN,dead.test,DIRECT"], Vec::new());
            let target =
                UpstreamTarget::new("dead.test", closed).with_dst_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));

            let started = Instant::now();
            let err = tokio::time::timeout(
                Duration::from_secs(5),
                open_upstream(&inner, &target, &UpstreamTlsConfig::default()),
            )
            .await
            .expect("an unreachable upstream must fail fast, not hang")
            .err()
            .expect("a closed port must fail the dial");
            assert!(
                started.elapsed() < Duration::from_secs(5),
                "dial timeout budget exceeded"
            );
            assert_eq!(err.status(), 502);
            assert_eq!(err.code(), ERR_CAPTURE_UPSTREAM_FAILED);
            assert_eq!(err.kind(), "dial");
        });
    }

    /// Client TLS config trusting the test CA, negotiating h1.
    fn client_tls_config(ca: &CertificateAuthority) -> Arc<ClientConfig> {
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let mut roots = RootCertStore::empty();
        roots.add(ca.der().clone()).expect("trust test CA");
        let mut config = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("protocol versions")
            .with_root_certificates(roots)
            .with_no_client_auth();
        config.alpn_protocols = vec![b"http/1.1".to_vec()];
        Arc::new(config)
    }

    /// A production [`TunnelUpstreamDialer`] over `inner`, pointed at
    /// `host:port`, trusting the test CA. Its dials go through
    /// `dial_upstream`, so the dial and TLS ceilings apply.
    fn production_dialer_for(
        inner: Arc<meow_tunnel::tunnel::TunnelInner>,
        host: &str,
        port: u16,
        ca: &CertificateAuthority,
    ) -> Arc<dyn UpstreamDialer> {
        let target = UpstreamTarget::new(host, port).with_dst_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));
        Arc::new(TunnelUpstreamDialer::new(
            inner,
            target,
            UpstreamTlsConfig::with_roots(trusted_roots(ca)),
        ))
    }

    /// Drive one HTTP/1.1 request over a fresh client TLS connection and return
    /// the response status; the connection is closed before returning.
    async fn send_h1_request(
        ca: &CertificateAuthority,
        client_io: tokio::io::DuplexStream,
        host: &str,
        path: &str,
    ) -> u16 {
        let tls = TlsConnector::from(client_tls_config(ca))
            .connect(ServerName::try_from(host.to_string()).unwrap(), client_io)
            .await
            .expect("client TLS handshake");
        let (mut sender, conn) = client_http1::Builder::new()
            .handshake::<_, Full<Bytes>>(TokioIo::new(tls))
            .await
            .expect("client h1 handshake");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        let request = Request::builder()
            .method("GET")
            .uri(path)
            .header(HOST, host)
            .body(Full::new(Bytes::new()))
            .unwrap();
        let response = sender.send_request(request).await.expect("response");
        let status = response.status().as_u16();
        drop(response);
        drop(sender);
        status
    }

    async fn wait_inflight_zero(what: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while inflight_count() != 0 && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert_eq!(
            inflight_count(),
            0,
            "{what} must release the in-flight slot"
        );
    }

    /// D12a: a ~6 s DIRECT dial that the old compile-time 5 s meow ceiling cut
    /// now succeeds under the 12 s own deadline. The bytes moved through the
    /// returned connection are the proof the dial *completed*, not merely that
    /// no error was returned.
    #[test]
    fn slow_dial_beyond_old_5s_deadline_succeeds() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let forward = listener.local_addr().unwrap();
            let fixture = tokio::spawn(async move {
                let (mut tcp, _) = listener.accept().await.unwrap();
                let mut buf = [0u8; 4];
                tcp.read_exact(&mut buf).await.unwrap();
                assert_eq!(&buf, b"ping");
                tcp.write_all(b"pong").await.unwrap();
            });

            let proxy = RetryProxy::new(Duration::from_secs(6), forward);
            let inner = tunnel_with(
                &["DOMAIN-SUFFIX,slow.test,RETRY"],
                vec![("RETRY", Arc::clone(&proxy) as Arc<dyn Proxy>)],
            );
            let target = UpstreamTarget::new("slow.test", forward.port())
                .with_dst_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));

            let mut conn = dial_upstream(&inner, &target)
                .await
                .expect("a 6 s dial must beat the 12 s deadline");
            conn.write_all(b"ping").await.unwrap();
            let mut reply = [0u8; 4];
            conn.read_exact(&mut reply).await.unwrap();
            assert_eq!(
                &reply, b"pong",
                "the 6 s-dialed connection must be live, not just non-Error"
            );
            fixture.await.unwrap();
            assert_eq!(
                proxy.dial_count(),
                1,
                "a dial under the deadline must not be retried"
            );
        });
    }

    /// D12a: the first attempt times out, the single retry completes, and the
    /// overall dial succeeds. The recorded second connection is proven live.
    #[test]
    fn timed_out_dial_is_retried_once_and_succeeds() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let _reset = DialTimeoutReset;
            set_upstream_dial_timeout_for_tests(150);

            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let forward = listener.local_addr().unwrap();
            let fixture = tokio::spawn(async move {
                let (mut tcp, _) = listener.accept().await.unwrap();
                tcp.write_all(b"ok").await.unwrap();
            });

            let proxy = RetryProxy::new(Duration::from_millis(400), forward);
            let inner = tunnel_with(
                &["DOMAIN,retry.test,RETRY"],
                vec![("RETRY", Arc::clone(&proxy) as Arc<dyn Proxy>)],
            );
            let target = UpstreamTarget::new("retry.test", forward.port())
                .with_dst_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));

            let mut conn = dial_upstream(&inner, &target)
                .await
                .expect("the retry must succeed");
            let mut reply = [0u8; 2];
            conn.read_exact(&mut reply).await.unwrap();
            assert_eq!(&reply, b"ok", "the retried connection must be the live one");
            fixture.await.unwrap();
            assert_eq!(
                proxy.dial_count(),
                2,
                "exactly one retry after the first timeout"
            );
        });
    }

    /// D12a: both attempts timing out yields the `upstream_dial` stage and the
    /// registered 502 / `PROXY_CAPTURE_UPSTREAM_FAILED` shape.
    #[test]
    fn double_dial_timeout_maps_to_upstream_dial_stage() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let _reset = DialTimeoutReset;
            set_upstream_dial_timeout_for_tests(100);

            let hang = hanging_proxy();
            let inner = tunnel_with(
                &["DOMAIN,dead.test,HANG"],
                vec![("HANG", Arc::clone(&hang) as Arc<dyn Proxy>)],
            );
            let target = UpstreamTarget::new("dead.test", 443)
                .with_dst_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));

            let err = dial_upstream(&inner, &target)
                .await
                .err()
                .expect("both attempts must time out");
            assert_eq!(err.stage().as_str(), "upstream_dial");
            assert_eq!(err.kind(), "dial");
            assert_eq!(err.status(), 502);
            assert_eq!(err.code(), ERR_CAPTURE_UPSTREAM_FAILED);
            assert_eq!(
                hang.dial_count(),
                2,
                "a timeout must be retried exactly once, then surface the failure"
            );
        });
    }

    /// A `ProxyAdapter` whose `dial_tcp` never resolves: `dial_upstream`'s own
    /// timeout must cut it (twice, with one retry), so a hung outbound cannot
    /// pin a session slot.
    struct HangingProxy {
        health: ProxyHealth,
        dials: AtomicUsize,
    }

    fn hanging_proxy() -> Arc<HangingProxy> {
        Arc::new(HangingProxy {
            health: ProxyHealth::new(),
            dials: AtomicUsize::new(0),
        })
    }

    impl HangingProxy {
        fn dial_count(&self) -> usize {
            self.dials.load(Ordering::SeqCst)
        }
    }

    #[async_trait::async_trait]
    impl ProxyAdapter for HangingProxy {
        fn name(&self) -> &str {
            "HANG"
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
        async fn dial_tcp(&self, _metadata: &Metadata) -> meow_common::Result<Box<dyn ProxyConn>> {
            self.dials.fetch_add(1, Ordering::SeqCst);
            std::future::pending().await
        }
        async fn dial_udp(
            &self,
            _metadata: &Metadata,
        ) -> meow_common::Result<Box<dyn ProxyPacketConn>> {
            Err(meow_common::MeowError::NotSupported("hanging".into()))
        }
        fn health(&self) -> &ProxyHealth {
            &self.health
        }
    }

    impl Proxy for HangingProxy {
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

    /// Restores the production session deadline even if the test panics.
    struct DeadlineReset;

    impl Drop for DeadlineReset {
        fn drop(&mut self) {
            reset_session_deadline_for_tests();
        }
    }

    /// Restores the production upstream dial deadline even if a test panics.
    struct DialTimeoutReset;

    impl Drop for DialTimeoutReset {
        fn drop(&mut self) {
            reset_upstream_dial_timeout_for_tests();
        }
    }

    /// A test outbound whose **first** `dial_tcp` sleeps for `first_dial_delay`
    /// before connecting and whose later dials connect at once. The dial count
    /// proves whether a timeout was retried.
    struct RetryProxy {
        health: ProxyHealth,
        dials: AtomicUsize,
        first_dial_delay: Duration,
        forward: SocketAddr,
    }

    impl RetryProxy {
        fn new(first_dial_delay: Duration, forward: SocketAddr) -> Arc<Self> {
            Arc::new(Self {
                health: ProxyHealth::new(),
                dials: AtomicUsize::new(0),
                first_dial_delay,
                forward,
            })
        }

        fn dial_count(&self) -> usize {
            self.dials.load(Ordering::SeqCst)
        }
    }

    #[async_trait::async_trait]
    impl ProxyAdapter for RetryProxy {
        fn name(&self) -> &str {
            "RETRY"
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
        async fn dial_tcp(&self, _metadata: &Metadata) -> meow_common::Result<Box<dyn ProxyConn>> {
            if self.dials.fetch_add(1, Ordering::SeqCst) == 0 {
                tokio::time::sleep(self.first_dial_delay).await;
            }
            let stream = TcpStream::connect(self.forward).await?;
            Ok(Box::new(stream))
        }
        async fn dial_udp(
            &self,
            _metadata: &Metadata,
        ) -> meow_common::Result<Box<dyn ProxyPacketConn>> {
            Err(meow_common::MeowError::NotSupported("retry".into()))
        }
        fn health(&self) -> &ProxyHealth {
            &self.health
        }
    }

    impl Proxy for RetryProxy {
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


    /// A client that opens the TLS connection and then sends nothing must not
    /// pin its slot: the 10 s client-TLS ceiling ends the session.
    #[test]
    fn stalled_client_tls_handshake_releases_slot() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            reset_gate_counters_for_tests();
            let ca = Arc::new(
                CertificateAuthority::generate(temp_dir("stall-client").to_str().unwrap())
                    .expect("ca"),
            );
            install_ca(Arc::clone(&ca));
            let inner = tunnel_with(&["DOMAIN,flow.test,DIRECT"], Vec::new());
            let dialer = production_dialer_for(inner, "flow.test", 443, &ca);

            let (client, server) = tokio::io::duplex(4096);
            let ctx = BridgeContext::new("flow.test", "stall-client", 0);
            crate::dispatch::begin_mitm(server, Some("flow.test"), dialer, ctx)
                .expect("session must start");
            assert_eq!(inflight_count(), 1);
            tokio::time::sleep(Duration::from_secs(11)).await;
            assert_eq!(
                inflight_count(),
                0,
                "a stalled client handshake must release the slot after its ceiling"
            );
            drop(client);
            clear_ca();
        });
    }

    /// An outbound whose dial never completes must be cut by the dial ceiling
    /// (twice — one retry), and the session must release its slot.
    #[test]
    fn hung_upstream_dial_releases_slot() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let _reset = DialTimeoutReset;
            set_upstream_dial_timeout_for_tests(150);
            reset_gate_counters_for_tests();
            let ca = Arc::new(
                CertificateAuthority::generate(temp_dir("hang-dial").to_str().unwrap())
                    .expect("ca"),
            );
            install_ca(Arc::clone(&ca));
            let hang = hanging_proxy();
            let inner = tunnel_with(
                &["DOMAIN,flow.test,HANG"],
                vec![("HANG", Arc::clone(&hang) as Arc<dyn Proxy>)],
            );
            let dialer = production_dialer_for(inner, "flow.test", 443, &ca);

            let (client_io, server_io) = tokio::io::duplex(1 << 16);
            let ctx = BridgeContext::new("flow.test", "hang-dial", 0);
            crate::dispatch::begin_mitm(server_io, Some("flow.test"), dialer, ctx)
                .expect("session must start");
            let status = send_h1_request(&ca, client_io, "flow.test", "/hang").await;
            assert_eq!(status, 502, "a hung dial must degrade to a structured 502");
            assert_eq!(
                hang.dial_count(),
                2,
                "a dial that times out must be retried exactly once"
            );
            wait_inflight_zero("the timed-out dial").await;
            clear_ca();
        });
    }

    /// An upstream that completes the TCP dial but never speaks TLS must be cut
    /// by the 10 s upstream-TLS ceiling, and the session must release its slot.
    #[test]
    fn stalled_upstream_tls_handshake_releases_slot() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            reset_gate_counters_for_tests();
            let ca = Arc::new(
                CertificateAuthority::generate(temp_dir("stall-upstream").to_str().unwrap())
                    .expect("ca"),
            );
            install_ca(Arc::clone(&ca));
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            tokio::spawn(async move {
                let _held = listener.accept().await;
                std::future::pending::<()>().await;
            });
            let inner = tunnel_with(&["DOMAIN,flow.test,DIRECT"], Vec::new());
            let dialer = production_dialer_for(inner, "flow.test", port, &ca);

            let (client_io, server_io) = tokio::io::duplex(1 << 16);
            let ctx = BridgeContext::new("flow.test", "stall-upstream", 0);
            crate::dispatch::begin_mitm(server_io, Some("flow.test"), dialer, ctx)
                .expect("session must start");
            let status = send_h1_request(&ca, client_io, "flow.test", "/stall").await;
            assert_eq!(
                status, 502,
                "a stalled upstream TLS handshake must yield a 502"
            );
            wait_inflight_zero("the timed-out upstream TLS handshake").await;
            clear_ca();
        });
    }

    /// An idle but fully-handshaken session has no per-stage timeout left; only
    /// the whole-session deadline can reclaim its slot.
    #[test]
    fn session_deadline_releases_slot() {
        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            reset_gate_counters_for_tests();
            let _deadline = DeadlineReset;
            set_session_deadline_for_tests(500);
            let ca = Arc::new(
                CertificateAuthority::generate(temp_dir("deadline").to_str().unwrap())
                    .expect("ca"),
            );
            install_ca(Arc::clone(&ca));
            let inner = tunnel_with(&["DOMAIN,flow.test,DIRECT"], Vec::new());
            let dialer = production_dialer_for(inner, "flow.test", 443, &ca);

            let (client_io, server_io) = tokio::io::duplex(1 << 16);
            let ctx = BridgeContext::new("flow.test", "deadline", 0);
            crate::dispatch::begin_mitm(server_io, Some("flow.test"), dialer, ctx)
                .expect("session must start");
            let _tls = TlsConnector::from(client_tls_config(&ca))
                .connect(ServerName::try_from("flow.test").unwrap(), client_io)
                .await
                .expect("client TLS handshake");
            assert_eq!(inflight_count(), 1);
            tokio::time::sleep(Duration::from_millis(900)).await;
            assert_eq!(
                inflight_count(),
                0,
                "the whole-session deadline must release the slot"
            );
            clear_ca();
        });
    }
}
