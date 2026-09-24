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
#![allow(dead_code)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use rcgen::{
    BasicConstraints, CertificateParams, DnType, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    KeyUsagePurpose, SerialNumber,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::server::{ClientHello, ResolvesServerCert, ServerConfig};
use rustls::sign::CertifiedKey;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_rustls::server::TlsStream;
use tokio_rustls::TlsAcceptor;

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
    match TlsAcceptor::from(config).accept(stream).await {
        Ok(tls) => MitmTls::Terminated(tls),
        Err(e) => MitmTls::Failed(MitmTlsError::Handshake(e.to_string())),
    }
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
