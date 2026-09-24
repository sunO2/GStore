//! In-process capture/MITM gating configuration (`proxy-http-capture` Todo 6).
//!
//! This module owns the **process-level** [`CaptureConfig`] the TUN TCP flow
//! dispatch consults *before* it decides whether to decrypt a flow. It is the
//! only thing the gate reads, so the dispatch path has **no dependency on the
//! host contract**: Todo 10 later exposes/persists this structure as
//! `capture.config.*` (the direction is one-way, todo 10 -> here).
//!
//! ## Gate rule (frozen)
//!
//! A flow is MITM'd iff:
//!
//! ```text
//! cfg.enabled
//!   && dst_port ∈ cfg.tls_ports
//!   && host is known (from sniff/DNS)
//!   && ( domainAllowlist hit
//!        || ( domainAllowlist is empty && appAllowlist hit ) )
//! ```
//!
//! * **Domain is primary**: the flow host comes from `sniff_prefix` (todo 6 runs
//!   it before the gate; see [`crate::dispatch`]).
//! * **App is best-effort** via UID ([`AppUidResolver`]). An **unknown UID can
//!   only deny** MITM — it must never trigger decryption, even when the app
//!   allowlist is non-empty.
//! * No allowlist configured at all (`enabled` alone) decrypts **nothing**.
//!
//! ## Bounds
//!
//! The allowlists are configuration, not per-traffic accumulators, so they are
//! **not** charged to [`crate::limits::worst_case_bytes`] (Todo 4's budget
//! enumerated the MITM/capture *traffic* structures only). They are still
//! trimmed to [`MAX_ALLOWLIST_ENTRIES`] entries of
//! [`MAX_ALLOWLIST_ENTRY_BYTES`] bytes at `set_config` time so a hostile/buggy
//! caller cannot retain unbounded config, and the whole config is stored behind
//! an `Arc` so a per-flow read is a pointer clone, never a deep copy.

use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use gstore_contract::error::{ModuleError, StatusCode};
use serde::{Deserialize, Serialize};

use crate::limits::CAPTURE_BODY_MAX_BYTES;

/// `capture.config.set` payload invalid (422, `rust/ERROR_CODES.md`).
pub(crate) const ERR_CAPTURE_CONFIG_INVALID: &str = "PROXY_CAPTURE_CONFIG_INVALID";

/// Persisted capture config filename, beside the other module JSON stores.
const CAPTURE_CONFIG_FILE: &str = "capture_config.json";

/// Upper bound on allowlist entries retained from a `set_config` call.
const MAX_ALLOWLIST_ENTRIES: usize = 256;
/// Longest allowlist entry retained (the DNS name upper bound). Longer entries
/// cannot match a sniffed host anyway.
const MAX_ALLOWLIST_ENTRY_BYTES: usize = 253;
/// Best-effort app (UID) resolution deadline for the gate. A resolver that
/// exceeds it is treated as [`AppAttribution::Unknown`] (deny), so a slow host
/// can never stall the TUN dataplane or force decryption.
const APP_RESOLVE_TIMEOUT: Duration = Duration::from_millis(200);

/// Discriminator for **how** the app allowlist is scoped. The Rust gate cannot
/// see the VPN split-tunnel mode, so scope-by-routing (A) and scope-by-UID (B)
/// need this explicit field to coexist. `app_allowlist` stays the single source
/// of truth for **which** apps.
///
/// `#[serde(default)]` on [`CaptureConfig::app_scope`] plus the `Uid` default
/// here means an old `capture_config.json` without the field migrates to
/// today's semantics automatically.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum AppScope {
    /// The TUN is already limited to the allowed apps by VPN routing, so the
    /// gate does not need a UID. Zero UID cost; the primary path (A).
    Routing,
    /// Resolve the flow's UID and match `app_allowlist`. The fallback path (B).
    #[default]
    Uid,
}

/// Process-level MITM capture configuration. Defaults are the shipping
/// no-capture posture: `enabled:false` means every flow keeps the existing
/// tunnel pass-through, byte for byte.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CaptureConfig {
    /// Master switch. `false` => never MITM (default).
    pub enabled: bool,
    /// Destination ports eligible for MITM termination.
    pub tls_ports: Vec<u16>,
    /// Primary allowlist: sniffed SNI/host. When non-empty, only a hit allows.
    pub domain_allowlist: Vec<String>,
    /// Best-effort allowlist: package name / UID string. When
    /// `domain_allowlist` is empty, this is consulted according to `app_scope`.
    pub app_allowlist: Vec<String>,
    /// How `app_allowlist` is evaluated (routing vs UID). Missing field on load
    /// defaults to [`AppScope::Uid`], preserving pre-`appScope` behavior.
    #[serde(default)]
    pub app_scope: AppScope,
    /// Capture request/response bodies (todo 8).
    pub capture_body: bool,
    /// Capture WebSocket frames (todo 9).
    pub capture_ws: bool,
    /// Capture HTTP/2 (todo 8).
    pub capture_h2: bool,
    /// Disk-side body ceiling (SQLite only; never resident in memory).
    pub max_body_bytes: usize,
}

impl Default for CaptureConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            tls_ports: vec![443, 8443],
            domain_allowlist: Vec::new(),
            app_allowlist: Vec::new(),
            app_scope: AppScope::Uid,
            capture_body: true,
            capture_ws: true,
            capture_h2: true,
            max_body_bytes: CAPTURE_BODY_MAX_BYTES,
        }
    }
}

impl CaptureConfig {
    /// Trim/clean both allowlists in place. Entries are kept in order, so the
    /// first [`MAX_ALLOWLIST_ENTRIES`] survive a truncation.
    fn sanitized(mut self) -> Self {
        sanitize_list(&mut self.domain_allowlist);
        sanitize_list(&mut self.app_allowlist);
        self
    }
}

fn sanitize_list(list: &mut Vec<String>) {
    list.retain(|entry| !entry.trim().is_empty());
    for entry in list.iter_mut() {
        if entry.len() > MAX_ALLOWLIST_ENTRY_BYTES {
            let mut cut = MAX_ALLOWLIST_ENTRY_BYTES;
            while cut > 0 && !entry.is_char_boundary(cut) {
                cut -= 1;
            }
            entry.truncate(cut);
        }
    }
    if list.len() > MAX_ALLOWLIST_ENTRIES {
        list.truncate(MAX_ALLOWLIST_ENTRIES);
    }
}

static CAPTURE_CONFIG: OnceLock<Mutex<Arc<CaptureConfig>>> = OnceLock::new();

fn config_cell() -> &'static Mutex<Arc<CaptureConfig>> {
    CAPTURE_CONFIG.get_or_init(|| Mutex::new(Arc::new(CaptureConfig::default())))
}

/// Snapshot the current config as an `Arc` (a pointer clone, never a deep copy).
pub(crate) fn config() -> Arc<CaptureConfig> {
    config_cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Replace the process-level config (sanitized). Todo 10's `capture.config.set`
/// is the only production caller.
pub(crate) fn set_config(config: CaptureConfig) {
    let config = Arc::new(config.sanitized());
    *config_cell().lock().unwrap_or_else(|e| e.into_inner()) = config;
}

/// Reset the process-level config to defaults (tests).
#[cfg(test)]
pub(crate) fn reset_for_tests() {
    set_config(CaptureConfig::default());
    set_app_uid_resolver(None);
}

// ── Contract surface: `capture.config.*` (Todo 10) ───────────────────────────

/// Partial update for [`CaptureConfig`]; absent fields keep the current value.
/// Unknown fields are rejected so a typo is a structured 422, not a silent no-op.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CaptureConfigPatch {
    enabled: Option<bool>,
    tls_ports: Option<Vec<u16>>,
    domain_allowlist: Option<Vec<String>>,
    app_allowlist: Option<Vec<String>>,
    app_scope: Option<AppScope>,
    capture_body: Option<bool>,
    capture_ws: Option<bool>,
    capture_h2: Option<bool>,
    max_body_bytes: Option<usize>,
}

fn invalid(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_CAPTURE_CONFIG_INVALID, message)
}

impl CaptureConfig {
    /// Validate the wire shape. Never panics.
    fn validate(&self) -> Result<(), ModuleError> {
        if self.tls_ports.is_empty() {
            return Err(invalid("tlsPorts must not be empty"));
        }
        if self.tls_ports.contains(&0) {
            return Err(invalid("tlsPorts must be within [1, 65535]"));
        }
        if self.max_body_bytes == 0 || self.max_body_bytes > CAPTURE_BODY_MAX_BYTES {
            return Err(invalid(format!(
                "maxBodyBytes must be within [1, {CAPTURE_BODY_MAX_BYTES}] (got {})",
                self.max_body_bytes
            )));
        }
        Ok(())
    }

    /// Merge a partial JSON object over this config and validate the result.
    /// An empty payload validates the current config; a non-object or an unknown
    /// field is a structured 422 (`lan.rs`/`shaper.rs` convention).
    pub(crate) fn apply_patch(&mut self, payload: &[u8]) -> Result<(), ModuleError> {
        if payload.is_empty() {
            return self.validate();
        }
        let value: serde_json::Value = serde_json::from_slice(payload)
            .map_err(|e| invalid(format!("payload must be a JSON object: {e}")))?;
        if !value.is_object() {
            return Err(invalid("payload must be a JSON object"));
        }
        let patch: CaptureConfigPatch = serde_json::from_value(value)
            .map_err(|e| invalid(format!("invalid capture config: {e}")))?;
        if let Some(v) = patch.enabled {
            self.enabled = v;
        }
        if let Some(v) = patch.tls_ports {
            self.tls_ports = v;
        }
        if let Some(v) = patch.domain_allowlist {
            self.domain_allowlist = v;
        }
        if let Some(v) = patch.app_allowlist {
            self.app_allowlist = v;
        }
        if let Some(v) = patch.app_scope {
            self.app_scope = v;
        }
        if let Some(v) = patch.capture_body {
            self.capture_body = v;
        }
        if let Some(v) = patch.capture_ws {
            self.capture_ws = v;
        }
        if let Some(v) = patch.capture_h2 {
            self.capture_h2 = v;
        }
        if let Some(v) = patch.max_body_bytes {
            self.max_body_bytes = v;
        }
        self.validate()
    }
}

/// The frozen `capture.config.get` / `capture.config.set` response shape (the
/// serialized process-level config, all-camelCase).
pub(crate) fn config_json() -> serde_json::Value {
    serde_json::to_value(&*config()).unwrap_or(serde_json::Value::Null)
}

/// Read and validate `capture_config.json`, falling back to the default config
/// on ANY failure, so a corrupt store can never brick module creation.
fn load_config(data_dir: &str) -> CaptureConfig {
    let dir = data_dir.trim();
    if dir.is_empty() {
        return CaptureConfig::default();
    }
    let path = std::path::Path::new(dir).join(CAPTURE_CONFIG_FILE);
    let Ok(bytes) = std::fs::read(&path) else {
        return CaptureConfig::default();
    };
    let Ok(config) = serde_json::from_slice::<CaptureConfig>(&bytes) else {
        return CaptureConfig::default();
    };
    if config.validate().is_err() {
        return CaptureConfig::default();
    }
    config
}

/// Persist `config` as `capture_config.json`; an empty data dir is a no-op.
/// Atomic (`tmp` + rename), matching the rules store, so a crash mid-write can
/// never leave a truncated config behind.
fn persist(data_dir: &str, config: &CaptureConfig) {
    let dir = data_dir.trim();
    if dir.is_empty() {
        return;
    }
    let path = std::path::Path::new(dir).join(CAPTURE_CONFIG_FILE);
    let Ok(bytes) = serde_json::to_vec(config) else {
        return;
    };
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, &bytes).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

/// Install the persisted capture config on module create (mounted from
/// `lib.rs::create_impl` next to `shaper::configure`).
pub(crate) fn configure(data_dir: &str) {
    set_config(load_config(data_dir));
}

/// `capture.config.set`: merge `payload`, validate, publish and persist.
///
/// The current config is cloned BEFORE `apply_patch` mutates it, so a rejected
/// (422) patch never publishes or persists a half-applied config.
pub(crate) fn set(data_dir: &str, payload: &[u8]) -> Result<CaptureConfig, ModuleError> {
    let mut next = (*config()).clone();
    next.apply_patch(payload)?;
    let next = next.sanitized();
    set_config(next.clone());
    persist(data_dir, &next);
    Ok(next)
}

// ── App (UID) attribution ────────────────────────────────────────────────────

/// Best-effort application attribution for a TUN flow.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum AppAttribution {
    /// UID could not be resolved (no resolver, timeout, or unresolved). The
    /// gate MUST deny in this state.
    Unknown,
    /// UID known; `packages` may be empty (best-effort).
    Known { uid: u32, packages: Vec<String> },
}

/// Pluggable **async** app resolver. Production wires this to the host's UID
/// lookup; the default is `None` (always [`AppAttribution::Unknown`]).
pub(crate) trait AppUidResolver: Send + Sync {
    fn resolve<'a>(
        &'a self,
        src: SocketAddr,
        dst: SocketAddr,
    ) -> Pin<Box<dyn Future<Output = AppAttribution> + Send + 'a>>;
}

static APP_RESOLVER: OnceLock<Mutex<Option<Arc<dyn AppUidResolver>>>> = OnceLock::new();

fn resolver_cell() -> &'static Mutex<Option<Arc<dyn AppUidResolver>>> {
    APP_RESOLVER.get_or_init(|| Mutex::new(None))
}

/// Install (or clear) the process-wide app resolver seam. Default is none.
pub(crate) fn set_app_uid_resolver(resolver: Option<Arc<dyn AppUidResolver>>) {
    *resolver_cell().lock().unwrap_or_else(|e| e.into_inner()) = resolver;
}

fn app_uid_resolver() -> Option<Arc<dyn AppUidResolver>> {
    resolver_cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Resolve the flow's app best-effort. A missing resolver or an over-deadline
/// resolver both yield [`AppAttribution::Unknown`] — which can only deny MITM.
pub(crate) async fn resolve_app(src: SocketAddr, dst: SocketAddr) -> AppAttribution {
    let Some(resolver) = app_uid_resolver() else {
        return AppAttribution::Unknown;
    };
    // The `Arc` is held across the await, not the mutex (never lock an await).
    match tokio::time::timeout(APP_RESOLVE_TIMEOUT, resolver.resolve(src, dst)).await {
        Ok(attribution) => attribution,
        Err(_) => AppAttribution::Unknown,
    }
}

/// True when the app allowlist is the only possible decider for this flow, so
/// the dispatcher should pay for an async UID resolution. Domain-primary hits
/// never need it.
pub(crate) fn needs_app_resolution(config: &CaptureConfig, dst_port: u16) -> bool {
    config.enabled
        && config.tls_ports.contains(&dst_port)
        && config.domain_allowlist.is_empty()
        && !config.app_allowlist.is_empty()
}

// ── Matching ─────────────────────────────────────────────────────────────────

/// Lowercase, strip a `host:port`/`[v6]:port` suffix and a trailing dot.
fn normalize_host(host: &str) -> String {
    let mut h = host.trim().to_ascii_lowercase();
    if h.starts_with('[') {
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
    h
}

/// Does `host` match any allowlist entry?
///
/// Entry semantics (case-insensitive):
/// * `*.example.com` / `.example.com` — subdomains of `example.com` only.
/// * `example.com` — the exact domain **or** any subdomain of it.
pub(crate) fn domain_allowed(host: &str, allowlist: &[String]) -> bool {
    let host = normalize_host(host);
    if host.is_empty() {
        return false;
    }
    allowlist
        .iter()
        .any(|entry| domain_entry_matches(&host, entry))
}

fn domain_entry_matches(host: &str, raw: &str) -> bool {
    let entry = normalize_host(raw);
    if entry.is_empty() {
        return false;
    }
    let wildcard = entry.starts_with("*.") || entry.starts_with('.');
    let base = entry
        .strip_prefix("*.")
        .or_else(|| entry.strip_prefix('.'))
        .unwrap_or(&entry);
    if base.is_empty() {
        return false;
    }
    let is_subdomain = host.len() > base.len()
        && host.ends_with(base)
        && host.as_bytes()[host.len() - base.len() - 1] == b'.';
    if wildcard {
        is_subdomain
    } else {
        host == base || is_subdomain
    }
}

/// Does the resolved app match the app allowlist? `Unknown` **always** denies.
/// Entries match a package name or the decimal UID.
pub(crate) fn app_allowed(app: &AppAttribution, allowlist: &[String]) -> bool {
    if allowlist.is_empty() {
        return false;
    }
    match app {
        AppAttribution::Unknown => false,
        AppAttribution::Known { uid, packages } => {
            let uid = uid.to_string();
            allowlist.iter().any(|entry| {
                let entry = entry.trim();
                !entry.is_empty() && (entry == uid || packages.iter().any(|p| p == entry))
            })
        }
    }
}

// ── Gate decision ────────────────────────────────────────────────────────────

/// The MITM gate. Returns `Some(host)` when the flow should be decrypted, or
/// `None` to keep the existing tunnel pass-through.
pub(crate) fn decide_mitm(
    config: &CaptureConfig,
    dst_port: u16,
    host: Option<&str>,
    app: &AppAttribution,
) -> Option<String> {
    if !config.enabled {
        return None;
    }
    if !config.tls_ports.contains(&dst_port) {
        return None;
    }
    // A host is required: without DNS/sniff there is nothing to certify and
    // todo 5's fixed no-SNI decision is pass-through anyway.
    let host = host.map(str::trim).filter(|h| !h.is_empty())?;
    if domain_allowed(host, &config.domain_allowlist) {
        return Some(host.to_string());
    }
    if config.domain_allowlist.is_empty() && app_allowed(app, &config.app_allowlist) {
        return Some(host.to_string());
    }
    None
}

#[cfg(test)]
mod mitm_gate_tests {
    use super::*;

    fn enabled(domains: &[&str], apps: &[&str]) -> CaptureConfig {
        CaptureConfig {
            enabled: true,
            domain_allowlist: domains.iter().map(|s| s.to_string()).collect(),
            app_allowlist: apps.iter().map(|s| s.to_string()).collect(),
            ..CaptureConfig::default()
        }
    }

    fn known(uid: u32, packages: &[&str]) -> AppAttribution {
        AppAttribution::Known {
            uid,
            packages: packages.iter().map(|s| s.to_string()).collect(),
        }
    }

    /// Shipping default is no-capture: everything passes through.
    #[test]
    fn capture_config_defaults_match_contract() {
        let cfg = CaptureConfig::default();
        assert!(!cfg.enabled);
        assert_eq!(cfg.tls_ports, vec![443, 8443]);
        assert!(cfg.domain_allowlist.is_empty());
        assert!(cfg.app_allowlist.is_empty());
        assert_eq!(cfg.app_scope, AppScope::Uid);
        assert!(cfg.capture_body && cfg.capture_ws && cfg.capture_h2);
        assert_eq!(cfg.max_body_bytes, CAPTURE_BODY_MAX_BYTES);
    }

    #[test]
    fn mitm_gate_disabled_never_mitm() {
        let mut cfg = enabled(&["a.example"], &["com.a"]);
        cfg.enabled = false;
        for port in [443u16, 8443, 80] {
            assert_eq!(
                decide_mitm(&cfg, port, Some("a.example"), &known(1, &["com.a"])),
                None
            );
        }
    }

    #[test]
    fn mitm_gate_domain_allowlist_hit_enables_mitm() {
        let cfg = enabled(&["a.example", "*.b.example"], &[]);
        assert_eq!(
            decide_mitm(&cfg, 443, Some("a.example"), &AppAttribution::Unknown).as_deref(),
            Some("a.example")
        );
        // Bare entry also matches a subdomain.
        assert_eq!(
            decide_mitm(&cfg, 8443, Some("www.a.example"), &AppAttribution::Unknown).as_deref(),
            Some("www.a.example")
        );
        // Wildcard matches subdomains, not the bare base.
        assert_eq!(
            decide_mitm(&cfg, 443, Some("x.b.example"), &AppAttribution::Unknown).as_deref(),
            Some("x.b.example")
        );
        assert_eq!(decide_mitm(&cfg, 443, Some("b.example"), &AppAttribution::Unknown), None);
        // Miss.
        assert_eq!(decide_mitm(&cfg, 443, Some("evil.example"), &AppAttribution::Unknown), None);
    }

    #[test]
    fn mitm_gate_non_tls_port_never_mitm() {
        let cfg = enabled(&["a.example"], &[]);
        assert_eq!(decide_mitm(&cfg, 80, Some("a.example"), &AppAttribution::Unknown), None);
        assert_eq!(decide_mitm(&cfg, 22, Some("a.example"), &AppAttribution::Unknown), None);
    }

    #[test]
    fn mitm_gate_no_host_never_mitm() {
        let cfg = enabled(&[], &["com.a"]);
        assert_eq!(decide_mitm(&cfg, 443, None, &known(1, &["com.a"])), None);
        assert_eq!(decide_mitm(&cfg, 443, Some("  "), &known(1, &["com.a"])), None);
    }

    /// Domain allowlist empty => the app allowlist may decide, but ONLY for a
    /// known UID. This is the primary app-allowlist path.
    #[test]
    fn mitm_gate_app_allowlist_decides_when_domain_empty() {
        let cfg = enabled(&[], &["com.allowed"]);
        assert_eq!(
            decide_mitm(&cfg, 443, Some("a.example"), &known(10101, &["com.allowed"])).as_deref(),
            Some("a.example")
        );
        // A known UID that does not match still denies.
        assert_eq!(
            decide_mitm(&cfg, 443, Some("a.example"), &known(10101, &["com.other"])),
            None
        );
        // Numeric UID entries match too.
        let by_uid = enabled(&[], &["10101"]);
        assert_eq!(
            decide_mitm(&by_uid, 443, Some("a.example"), &known(10101, &[])).as_deref(),
            Some("a.example")
        );
    }

    /// Unknown UID with an empty domain allowlist MUST NOT decrypt, even though
    /// the app allowlist is non-empty.
    #[test]
    fn mitm_gate_unknown_uid_empty_domain_never_mitm() {
        let cfg = enabled(&[], &["com.allowed"]);
        assert_eq!(decide_mitm(&cfg, 443, Some("a.example"), &AppAttribution::Unknown), None);
        assert!(!app_allowed(&AppAttribution::Unknown, &["com.allowed".to_string()]));
    }

    /// When the domain allowlist is non-empty, the app allowlist is irrelevant:
    /// a domain miss denies even with a matching app.
    #[test]
    fn mitm_gate_domain_list_nonempty_ignores_app() {
        let cfg = enabled(&["only.example"], &["com.allowed"]);
        assert_eq!(
            decide_mitm(&cfg, 443, Some("a.example"), &known(10101, &["com.allowed"])),
            None
        );
    }

    /// No allowlist at all decrypts nothing.
    #[test]
    fn mitm_gate_enabled_without_allowlists_decrypts_nothing() {
        let cfg = enabled(&[], &[]);
        assert_eq!(decide_mitm(&cfg, 443, Some("a.example"), &known(1, &["com.a"])), None);
    }

    #[test]
    fn mitm_gate_host_normalization_and_entry_semantics() {
        assert!(domain_allowed("Example.COM.", &["example.com".into()]));
        assert!(domain_allowed("a.example.com:443", &["example.com".into()]));
        assert!(!domain_allowed("notexample.com", &["example.com".into()]));
        assert!(domain_allowed("a.example.com", &[".example.com".into()]));
        assert!(!domain_allowed("example.com", &[".example.com".into()]));
        assert!(!domain_allowed("", &["example.com".into()]));
    }

    /// The async app resolver seam is honoured, and its `Unknown` default denies.
    #[test]
    fn mitm_gate_app_resolver_seam_is_async_and_denies_on_unknown() {
        struct Fixed(AppAttribution);
        impl AppUidResolver for Fixed {
            fn resolve<'a>(
                &'a self,
                _src: SocketAddr,
                _dst: SocketAddr,
            ) -> Pin<Box<dyn Future<Output = AppAttribution> + Send + 'a>> {
                let a = self.0.clone();
                Box::pin(async move { a })
            }
        }

        let rt = crate::bounded_runtime().expect("bounded_runtime");
        rt.block_on(async {
            let src: SocketAddr = "10.10.0.2:40000".parse().unwrap();
            let dst: SocketAddr = "1.1.1.1:443".parse().unwrap();

            set_app_uid_resolver(None);
            assert_eq!(resolve_app(src, dst).await, AppAttribution::Unknown);

            set_app_uid_resolver(Some(Arc::new(Fixed(known(10101, &["com.allowed"])))));
            let app = resolve_app(src, dst).await;
            assert_eq!(app, known(10101, &["com.allowed"]));
            let cfg = enabled(&[], &["com.allowed"]);
            assert_eq!(
                decide_mitm(&cfg, 443, Some("a.example"), &app).as_deref(),
                Some("a.example")
            );

            set_app_uid_resolver(None);
        });
    }

    #[test]
    fn capture_config_trims_unbounded_allowlists() {
        let many: Vec<String> = (0..(MAX_ALLOWLIST_ENTRIES + 50))
            .map(|i| format!("h{i}.example"))
            .collect();
        let long = "x".repeat(MAX_ALLOWLIST_ENTRY_BYTES + 100);
        let cfg = CaptureConfig {
            enabled: true,
            domain_allowlist: many.clone(),
            app_allowlist: vec![long.clone(), "  ".into()],
            ..CaptureConfig::default()
        }
        .sanitized();
        assert_eq!(cfg.domain_allowlist.len(), MAX_ALLOWLIST_ENTRIES);
        assert_eq!(cfg.app_allowlist.len(), 1, "blank entries dropped");
        assert_eq!(cfg.app_allowlist[0].len(), MAX_ALLOWLIST_ENTRY_BYTES);
    }
}

#[cfg(test)]
mod config_io_tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::sync::atomic::{AtomicU32, Ordering};

    fn serial() -> std::sync::MutexGuard<'static, ()> {
        crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn tmp_dir(tag: &str) -> std::path::PathBuf {
        static SEQ: AtomicU32 = AtomicU32::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("gstore-capture-{tag}-{nanos}-{seq}"));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn capture_config_get_shape_is_camel_case_contract() {
        let _guard = serial();
        reset_for_tests();
        let json = config_json();
        let keys: BTreeSet<&str> = json
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.as_str())
            .collect();
        assert_eq!(
            keys,
            BTreeSet::from([
                "enabled",
                "tlsPorts",
                "domainAllowlist",
                "appAllowlist",
                "appScope",
                "captureBody",
                "captureWs",
                "captureH2",
                "maxBodyBytes",
            ])
        );
        assert_eq!(json["enabled"], serde_json::json!(false));
        assert_eq!(json["tlsPorts"], serde_json::json!([443, 8443]));
        assert_eq!(json["appScope"], serde_json::json!("uid"));
        assert_eq!(
            json["maxBodyBytes"],
            serde_json::json!(CAPTURE_BODY_MAX_BYTES)
        );
        reset_for_tests();
    }

    #[test]
    fn capture_config_persistence_round_trip() {
        let _guard = serial();
        reset_for_tests();
        let dir = tmp_dir("round-trip");
        let dir_str = dir.to_str().unwrap();

        let next = set(
            dir_str,
            br#"{"enabled":true,"tlsPorts":[443],"domainAllowlist":["a.example"],"captureH2":false}"#,
        )
        .unwrap();
        assert!(next.enabled);
        assert!(!next.capture_h2);
        assert_eq!(next.tls_ports, vec![443]);
        assert_eq!(next.domain_allowlist, vec!["a.example".to_string()]);
        assert_eq!(*config(), next);

        let path = dir.join(CAPTURE_CONFIG_FILE);
        assert!(path.exists(), "capture_config.json must be written");
        let on_disk: CaptureConfig = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(on_disk, next);

        reset_for_tests();
        configure(dir_str);
        assert_eq!(*config(), next);

        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn capture_config_invalid_is_422_and_does_not_persist() {
        let _guard = serial();
        reset_for_tests();
        let dir = tmp_dir("invalid");
        let dir_str = dir.to_str().unwrap();
        configure(dir_str);

        let good = set(dir_str, br#"{"enabled":true}"#).unwrap();
        let path = dir.join(CAPTURE_CONFIG_FILE);
        let before = std::fs::read(&path).unwrap();

        for payload in [
            br#"{"tlsPorts":[0]}"#.as_slice(),
            br#"{"tlsPorts":[]}"#.as_slice(),
            br#"{"maxBodyBytes":0}"#.as_slice(),
            br#"{"maxBodyBytes":2097153}"#.as_slice(),
            br#"{"bogus":true}"#.as_slice(),
        ] {
            let err = set(dir_str, payload).unwrap_err();
            assert_eq!(err.status, StatusCode::InvalidArgument);
            assert_eq!(err.code, ERR_CAPTURE_CONFIG_INVALID);
            assert_eq!(*config(), good, "rejected payload must not publish");
            assert_eq!(std::fs::read(&path).unwrap(), before, "…nor persist");
        }

        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn capture_config_corrupt_file_falls_back_to_default() {
        let _guard = serial();
        reset_for_tests();
        let dir = tmp_dir("corrupt");
        std::fs::write(dir.join(CAPTURE_CONFIG_FILE), b"{").unwrap();
        configure(dir.to_str().unwrap());
        assert_eq!(*config(), CaptureConfig::default());
        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn capture_config_persist_is_atomic_and_ignores_stale_tmp() {
        let _guard = serial();
        reset_for_tests();
        let dir = tmp_dir("atomic");
        let dir_str = dir.to_str().unwrap();
        let path = dir.join(CAPTURE_CONFIG_FILE);
        let tmp = path.with_extension("json.tmp");

        // A stale tmp from an interrupted write must never be loaded as config.
        std::fs::write(&tmp, br#"{"enabled":true}"#).unwrap();
        configure(dir_str);
        assert_eq!(*config(), CaptureConfig::default(), "tmp is not the config file");

        let next = set(dir_str, br#"{"enabled":true,"tlsPorts":[443]}"#).unwrap();
        assert!(!tmp.exists(), "the tmp file must be renamed away");
        let on_disk: CaptureConfig = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(on_disk, next, "the committed config is complete and parseable");

        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An old `capture_config.json` written before `appScope` existed must load
    /// as `app_scope = Uid` (today's semantics), never fail to load.
    #[test]
    fn capture_config_old_json_without_app_scope_migrates_to_uid() {
        let _guard = serial();
        reset_for_tests();
        let dir = tmp_dir("migrate-app-scope");
        let dir_str = dir.to_str().unwrap();
        let old = br#"{"enabled":true,"tlsPorts":[443,8443],"domainAllowlist":[],
                      "appAllowlist":["com.a"],"captureBody":true,"captureWs":true,
                      "captureH2":true,"maxBodyBytes":1048576}"#;
        std::fs::write(dir.join(CAPTURE_CONFIG_FILE), old).unwrap();

        configure(dir_str);
        let cfg = config();
        assert!(cfg.enabled);
        assert_eq!(cfg.app_scope, AppScope::Uid, "missing appScope must default to uid");
        assert_eq!(cfg.app_allowlist, vec!["com.a".to_string()]);

        // The same wire shape decodes directly (not only via `load_config`).
        let decoded: CaptureConfig = serde_json::from_slice(old).unwrap();
        assert_eq!(decoded.app_scope, AppScope::Uid);

        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `appScope` must survive both directions (routing and uid) through the
    /// publish path and the persisted `capture_config.json`.
    #[test]
    fn capture_config_app_scope_round_trips_routing_and_uid() {
        let _guard = serial();
        reset_for_tests();
        let dir = tmp_dir("app-scope");
        let dir_str = dir.to_str().unwrap();
        configure(dir_str);
        let path = dir.join(CAPTURE_CONFIG_FILE);

        let routing = set(dir_str, br#"{"appScope":"routing"}"#).unwrap();
        assert_eq!(routing.app_scope, AppScope::Routing);
        assert_eq!(config().app_scope, AppScope::Routing);
        assert_eq!(config_json()["appScope"], serde_json::json!("routing"));
        let on_disk: CaptureConfig = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(on_disk.app_scope, AppScope::Routing);

        let uid = set(dir_str, br#"{"appScope":"uid"}"#).unwrap();
        assert_eq!(uid.app_scope, AppScope::Uid);
        assert_eq!(config_json()["appScope"], serde_json::json!("uid"));
        let on_disk: CaptureConfig = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(on_disk.app_scope, AppScope::Uid);

        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A non-`routing`/`uid` value is a structured 422 that leaves the published
    /// and on-disk config untouched (no partial write, no corruption).
    #[test]
    fn capture_config_invalid_app_scope_is_422_and_does_not_corrupt_persisted() {
        let _guard = serial();
        reset_for_tests();
        let dir = tmp_dir("invalid-app-scope");
        let dir_str = dir.to_str().unwrap();
        configure(dir_str);
        let good = set(dir_str, br#"{"appScope":"routing"}"#).unwrap();
        let path = dir.join(CAPTURE_CONFIG_FILE);
        let before = std::fs::read(&path).unwrap();

        for payload in [
            br#"{"appScope":"bogus"}"#.as_slice(),
            br#"{"appScope":"Routing"}"#.as_slice(),
            br#"{"appScope":42}"#.as_slice(),
        ] {
            let err = set(dir_str, payload).unwrap_err();
            assert_eq!(err.status, StatusCode::InvalidArgument);
            assert_eq!(err.code, ERR_CAPTURE_CONFIG_INVALID);
            assert_eq!(*config(), good, "rejected appScope must not publish");
            assert_eq!(std::fs::read(&path).unwrap(), before, "…nor persist");
            let on_disk: CaptureConfig =
                serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            assert_eq!(on_disk.app_scope, AppScope::Routing, "file stays parseable and unchanged");
        }

        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
