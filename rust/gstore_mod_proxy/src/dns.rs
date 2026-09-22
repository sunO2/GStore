//! DNS subsystem (Todo 8).
//!
//! Wires meow's `meow_dns::Resolver` behind a typed [`DnsConfig`] (fake-IP or
//! redir-host mode, plain / DoH / DoT nameservers, bootstrap `default-nameserver`
//! list, fake-IP pools + filter) and exposes the TUN DNS-hijack answer path.
//!
//! Design decisions recorded in `API.md` §9:
//!
//! * **DoH/DoT** are meow transports (`NameServerUrl::Https` / `Tls`); their
//!   upstream hostnames are resolved by meow's own bootstrap path using the
//!   configured `default-nameserver` (outside the tunnel).
//! * **Every DNS socket** (bootstrap UDP/TCP, DoH/DoT) is created through
//!   [`ProtectedSocketFactory`], which dials via [`crate::protect`]. This is
//!   what makes requirement (a) true on both host and device: the bootstrap
//!   resolver's sockets go through the host `protect_fd`, not a raw socket.
//! * **Query logging**: each query answered through [`DnsEngine::query`] emits
//!   one JSON record via the module log path (`proxy.dns.query` log line +
//!   `proxy.dns` event) carrying domain/qtype/rcode/answers/resolver/latency,
//!   and records the domain→IP mapping for the Todo 16 domain-statistics path.
//!
//! Methods and error codes: `API.md` §2.7, `rust/ERROR_CODES.md`.

use std::collections::{BTreeMap, VecDeque};
use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Once, OnceLock};
use std::time::{Duration, Instant};

use gstore_contract::error::{ModuleError, StatusCode};
use hickory_proto::op::{Message, MessageType, OpCode, Query, ResponseCode};
use hickory_proto::rr::{RData, RecordType};
use ipnet::IpNet;
use meow_common::DnsMode;
use meow_dns::{
    DnsServer, MemoryStore, NameServerUrl, Pool, Resolver, Skipper, SkipperMode,
};
use meow_trie::DomainTrie;
use serde::{Deserialize, Serialize};
use tokio::net::{TcpStream, UdpSocket};

use crate::protect;

pub(crate) const ERR_DNS_CONFIG_INVALID: &str = "PROXY_DNS_CONFIG_INVALID";
pub(crate) const ERR_DNS_BOOTSTRAP_FAILED: &str = "PROXY_DNS_BOOTSTRAP_FAILED";
#[allow(dead_code)]
pub(crate) const ERR_DNS_TIMEOUT: &str = "PROXY_DNS_TIMEOUT";

const DEFAULT_V4_RANGE: &str = "198.18.0.0/16";
pub(crate) const FAKEIP_STORE_SIZE: usize = 4096;
pub(crate) const QUERY_RING_CAPACITY: usize = 256;
pub(crate) const MAPPING_RING_CAPACITY: usize = 1024;
const DNS_PORT: u16 = 53;

/// Resolver mode. Serializes as `fake-ip` / `redir-host` / `normal`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DnsModeKind {
    Normal,
    RedirHost,
    FakeIp,
}

impl Default for DnsModeKind {
    fn default() -> Self {
        Self::FakeIp
    }
}

impl DnsModeKind {
    fn to_mode(self) -> DnsMode {
        match self {
            DnsModeKind::Normal => DnsMode::Normal,
            DnsModeKind::RedirHost => DnsMode::Mapping,
            DnsModeKind::FakeIp => DnsMode::FakeIp,
        }
    }

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            DnsModeKind::Normal => "normal",
            DnsModeKind::RedirHost => "redir-host",
            DnsModeKind::FakeIp => "fake-ip",
        }
    }
}

/// `fake-ip-filter-mode` selector.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FakeIpFilterMode {
    Blacklist,
    Whitelist,
}

impl Default for FakeIpFilterMode {
    fn default() -> Self {
        Self::Blacklist
    }
}

impl FakeIpFilterMode {
    fn to_skipper(self) -> SkipperMode {
        match self {
            FakeIpFilterMode::Blacklist => SkipperMode::BlackList,
            FakeIpFilterMode::Whitelist => SkipperMode::WhiteList,
        }
    }
}

/// Typed DNS configuration. JSON field names are camelCase (see `API.md` §2.7).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DnsConfig {
    pub mode: DnsModeKind,
    /// Primary plain nameservers (`udp://` / `tcp://` / bare IP).
    pub nameservers: Vec<String>,
    /// Fallback nameservers, used when the primary result fails the filter or
    /// every primary upstream fails.
    pub fallback: Vec<String>,
    /// Convenience DoH list; merged into the primary set (meow `https://`).
    pub doh: Vec<String>,
    /// Convenience DoT list; merged into the primary set (meow `tls://`).
    pub dot: Vec<String>,
    /// Bootstrap resolvers for the upstreams' own hostnames. Must be plain
    /// (UDP/TCP) IP-literal entries, outside the tunnel.
    pub default_nameservers: Vec<String>,
    pub fake_ip_range: Option<String>,
    pub fake_ip_range_v6: Option<String>,
    pub fake_ip_ttl_ms: Option<u64>,
    pub fake_ip_filter: Vec<String>,
    pub fake_ip_filter_mode: FakeIpFilterMode,
    pub use_hosts: bool,
    pub ipv6: bool,
    /// Intercept UDP/53 arriving on the TUN and answer from the resolver.
    pub hijack: bool,
    /// Static `hosts:` mappings (domain → IP list).
    pub hosts: BTreeMap<String, Vec<String>>,
}

impl Default for DnsConfig {
    fn default() -> Self {
        Self {
            mode: DnsModeKind::FakeIp,
            // CN-reachable plain-UDP primaries; 1.1.1.1/8.8.8.8 are often blocked on CN networks, so they are fallback only (plain IPs keep the bootstrap list unnecessary).
            nameservers: vec!["223.5.5.5".to_string(), "119.29.29.29".to_string()],
            // International fallback, used when every primary upstream fails.
            fallback: vec!["1.1.1.1".to_string(), "8.8.8.8".to_string()],
            doh: Vec::new(),
            dot: Vec::new(),
            default_nameservers: Vec::new(),
            fake_ip_range: Some(DEFAULT_V4_RANGE.to_string()),
            fake_ip_range_v6: None,
            fake_ip_ttl_ms: None,
            fake_ip_filter: Vec::new(),
            fake_ip_filter_mode: FakeIpFilterMode::Blacklist,
            use_hosts: true,
            ipv6: true,
            hijack: true,
            hosts: BTreeMap::new(),
        }
    }
}

impl DnsConfig {
    fn parse_cfg_err(message: impl Into<String>) -> ModuleError {
        ModuleError::new(StatusCode::InvalidArgument, ERR_DNS_CONFIG_INVALID, message)
    }

    /// Merge a partial JSON object over `self` (used by `dns.set`).
    pub fn apply_patch(&mut self, patch: &[u8]) -> Result<(), ModuleError> {
        if patch.is_empty() {
            return Ok(());
        }
        let value: serde_json::Value = serde_json::from_slice(patch)
            .map_err(|e| Self::parse_cfg_err(format!("dns.set payload must be JSON: {e}")))?;
        if !value.is_object() {
            return Err(Self::parse_cfg_err("dns.set payload must be a JSON object"));
        }
        let mut base = serde_json::to_value(&*self)
            .map_err(|e| ModuleError::internal(format!("dns config encode: {e}")))?;
        let (Some(base_obj), serde_json::Value::Object(patch_obj)) = (base.as_object_mut(), value)
        else {
            return Err(Self::parse_cfg_err("dns.set payload must be a JSON object"));
        };
        for (k, v) in patch_obj {
            base_obj.insert(k, v);
        }
        *self = serde_json::from_value(base)
            .map_err(|e| Self::parse_cfg_err(format!("invalid dns config: {e}")))?;
        self.validate()
    }

    fn validate(&self) -> Result<(), ModuleError> {
        if self.mode == DnsModeKind::FakeIp && self.fake_ip_range_v6.is_none() {
            if let Some(range) = &self.fake_ip_range {
                range
                    .parse::<IpNet>()
                    .map_err(|e| Self::parse_cfg_err(format!("fakeIpRange '{range}': {e}")))?;
            }
        }
        for (label, list) in [
            ("nameservers", &self.nameservers),
            ("fallback", &self.fallback),
            ("doh", &self.doh),
            ("dot", &self.dot),
            ("defaultNameservers", &self.default_nameservers),
        ] {
            for entry in list {
                parse_nameserver(entry)
                    .map_err(|e| Self::parse_cfg_err(format!("{label}: {e}")))?;
            }
        }
        Ok(())
    }

    /// Main nameserver set actually handed to meow (plain + DoH + DoT).
    fn main_urls(&self) -> Result<Vec<NameServerUrl>, ModuleError> {
        let mut out = Vec::new();
        for entry in self.nameservers.iter().chain(self.doh.iter()).chain(self.dot.iter()) {
            out.push(parse_nameserver(entry)?);
        }
        if out.is_empty() {
            return Err(Self::parse_cfg_err("no nameservers configured"));
        }
        Ok(out)
    }

    fn fallback_urls(&self) -> Result<Vec<NameServerUrl>, ModuleError> {
        self.fallback.iter().map(|s| parse_nameserver(s)).collect()
    }

    fn default_urls(&self) -> Result<Vec<NameServerUrl>, ModuleError> {
        self.default_nameservers
            .iter()
            .map(|s| parse_nameserver(s))
            .collect()
    }
}

fn parse_nameserver(entry: &str) -> Result<NameServerUrl, ModuleError> {
    NameServerUrl::parse(entry).map_err(|e| {
        DnsConfig::parse_cfg_err(format!("nameserver '{entry}': {e}"))
    })
}

/// One emitted DNS query record (module log path + `proxy.dns` event).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DnsQueryRecord {
    pub ts_ms: u64,
    pub domain: String,
    pub qtype: String,
    pub rcode: String,
    pub answers: Vec<String>,
    pub resolver: String,
    pub latency_ms: u64,
    pub ok: bool,
    pub mode: String,
    pub note: Option<String>,
}

/// One domain→IP mapping fed to the Todo 16 domain-statistics path.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DnsMapping {
    pub domain: String,
    pub ip: String,
    pub fake: bool,
    pub ts_ms: u64,
    /// `false` when the domain was not known at query time (redir-host relies
    /// on this being true; see `API.md` §9.4).
    pub domain_known: bool,
}

pub(crate) struct DnsEngine {
    config: DnsConfig,
    resolver: Arc<Resolver>,
    records: Mutex<VecDeque<DnsQueryRecord>>,
    mappings: Mutex<VecDeque<DnsMapping>>,
    queries: AtomicU64,
    failures: AtomicU64,
}

/// The installed engine (process-global, rebuilt by `dns.set`).
static ENGINE: OnceLock<Mutex<Option<Arc<DnsEngine>>>> = OnceLock::new();
/// Last config applied, returned by `dns.get` even before the engine exists.
static CONFIG: OnceLock<Mutex<Option<DnsConfig>>> = OnceLock::new();

fn engine_cell() -> &'static Mutex<Option<Arc<DnsEngine>>> {
    ENGINE.get_or_init(|| Mutex::new(None))
}

fn config_cell() -> &'static Mutex<Option<DnsConfig>> {
    CONFIG.get_or_init(|| Mutex::new(None))
}

/// The installed engine's resolver, if any.
pub(crate) fn engine() -> Option<Arc<DnsEngine>> {
    engine_cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Current effective config (explicitly set, else the default).
pub(crate) fn config() -> DnsConfig {
    config_cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_default()
}

/// Build (or rebuild) and install the engine. Sync wrapper for the C ABI: the
/// resolver build is async, so it runs on a fresh bounded runtime and the
/// resulting resolver holds no live sockets (meow's `DnsClient` opens its
/// sockets per exchange, on whichever runtime runs the query).
pub(crate) fn set_config(cfg: DnsConfig) -> Result<Arc<DnsEngine>, ModuleError> {
    cfg.validate()?;
    let rt = crate::bounded_runtime()
        .map_err(|e| ModuleError::internal(format!("dns runtime build: {e}")))?;
    let engine = rt.block_on(DnsEngine::build(cfg))?;
    drop(rt);
    *config_cell().lock().unwrap_or_else(|e| e.into_inner()) = Some(engine.config.clone());
    let engine = Arc::new(engine);
    *engine_cell().lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&engine));
    Ok(engine)
}

/// Get the installed engine, building one from the default config if needed.
/// Called from the TUN loop (already inside a runtime).
pub(crate) async fn ensure_engine() -> Arc<DnsEngine> {
    if let Some(e) = engine() {
        return e;
    }
    let cfg = config();
    match DnsEngine::build(cfg).await {
        Ok(engine) => {
            let engine = Arc::new(engine);
            *engine_cell().lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&engine));
            engine
        }
        Err(e) => {
            crate::log_message(3, &format!("proxy: DNS engine build failed, using empty resolver: {e}"));
            let resolver = Arc::new(Resolver::new(
                Vec::new(),
                Vec::new(),
                DnsMode::Normal,
                DomainTrie::new(),
                false,
                false,
            ));
            Arc::new(DnsEngine {
                config: DnsConfig::default(),
                resolver,
                records: Mutex::new(VecDeque::new()),
                mappings: Mutex::new(VecDeque::new()),
                queries: AtomicU64::new(0),
                failures: AtomicU64::new(0),
            })
        }
    }
}

fn install_socket_factory() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = meow_dns::set_socket_factory(Arc::new(ProtectedSocketFactory));
    });
}

impl DnsEngine {
    async fn build(config: DnsConfig) -> Result<Self, ModuleError> {
        install_socket_factory();

        let mode = config.mode.to_mode();
        let main = config.main_urls()?;
        let fallback = config.fallback_urls()?;
        let default_ns = config.default_urls()?;
        let hosts = hosts_trie(&config.hosts);

        let mut resolver = Resolver::new_with_bootstrap(
            main,
            fallback,
            default_ns,
            mode,
            hosts,
            config.use_hosts,
            config.ipv6,
            None,
            None,
        )
        .await
        .map_err(bootstrap_err)?;

        if mode == DnsMode::FakeIp {
            if let Some(range) = &config.fake_ip_range {
                let net = parse_net(range)?;
                let pool = Pool::new(net, Arc::new(MemoryStore::new(FAKEIP_STORE_SIZE)))
                    .map_err(|e| ModuleError::new(StatusCode::InvalidArgument, ERR_DNS_CONFIG_INVALID, format!("fakeIpRange '{range}': {e}")))?;
                resolver.set_fakeip_v4(Arc::new(pool));
            }
            if let Some(range) = &config.fake_ip_range_v6 {
                let net = parse_net(range)?;
                let pool = Pool::new(net, Arc::new(MemoryStore::new(FAKEIP_STORE_SIZE)))
                    .map_err(|e| ModuleError::new(StatusCode::InvalidArgument, ERR_DNS_CONFIG_INVALID, format!("fakeIpRangeV6 '{range}': {e}")))?;
                resolver.set_fakeip_v6(Arc::new(pool));
            }
            if !config.fake_ip_filter.is_empty() {
                resolver.set_fakeip_skipper(Skipper::new(
                    &config.fake_ip_filter,
                    config.fake_ip_filter_mode.to_skipper(),
                ));
            }
            if let Some(ms) = config.fake_ip_ttl_ms {
                resolver.set_fakeip_ttl(Duration::from_millis(ms.max(1)));
            }
        }

        let resolver = Arc::new(resolver);
        // Route outbound hostname dials (proxy server hostnames, DoH/DoT
        // upstream hostnames) through this resolver instead of libc.
        meow_common::set_host_resolver(Arc::new(meow_dns::ResolverHostHook::new(Arc::clone(
            &resolver,
        ))));

        Ok(Self {
            config,
            resolver,
            records: Mutex::new(VecDeque::new()),
            mappings: Mutex::new(VecDeque::new()),
            queries: AtomicU64::new(0),
            failures: AtomicU64::new(0),
        })
    }

    pub(crate) fn config(&self) -> &DnsConfig {
        &self.config
    }

    pub(crate) fn resolver(&self) -> Arc<Resolver> {
        Arc::clone(&self.resolver)
    }

    /// True when a TUN UDP datagram to `dst` should be answered by us.
    pub(crate) fn is_hijacked(&self, dst: &SocketAddr) -> bool {
        self.config.hijack && dst.port() == DNS_PORT
    }

    /// Answer a raw DNS query and emit the log record. Always returns the wire
    /// response (SERVFAIL on failure) so the client is never left hanging.
    pub(crate) async fn query(&self, wire: &[u8]) -> (Vec<u8>, DnsQueryRecord) {
        let (domain, qtype) = parse_question(wire);
        let started = Instant::now();
        let response = match DnsServer::handle_query(wire, &self.resolver).await {
            Ok(bytes) => bytes,
            Err(e) => {
                crate::log_message(3, &format!("proxy.dns: handle_query failed: {e}"));
                Vec::new()
            }
        };
        let latency_ms = started.elapsed().as_millis() as u64;
        let (rcode, answers) = summarize_response(&response);
        let ok = rcode == ResponseCode::NoError && (!response.is_empty());
        let resolver_label = self.resolver_label(&domain, &answers);
        let note = if self.resolver.fake_ip_active_for(&domain) && !answers.is_empty() {
            Some("fake-ip".to_string())
        } else {
            None
        };

        let record = DnsQueryRecord {
            ts_ms: now_ms(),
            domain: domain.clone(),
            qtype: qtype_label(qtype),
            rcode: format!("{rcode:?}"),
            answers: answers.iter().map(ToString::to_string).collect(),
            resolver: resolver_label,
            latency_ms,
            ok,
            mode: self.config.mode.as_str().to_string(),
            note: note.clone(),
        };

        self.queries.fetch_add(1, Ordering::SeqCst);
        if !ok {
            self.failures.fetch_add(1, Ordering::SeqCst);
        }
        for ip in &answers {
            self.record_mapping(&domain, *ip);
        }
        self.push_record(record.clone());
        self.emit(&record);

        if response.is_empty() {
            let servfail = build_servfail(wire);
            return (servfail, record);
        }
        (response, record)
    }

    /// Diagnostic single-query path: build an A/AAAA query, resolve it, and
    /// return a structured [`ERR_DNS_TIMEOUT`] when no answer came back (this
    /// is the "unreachable resolver" failure contract).
    #[allow(dead_code)]
    pub(crate) async fn resolve(
        &self,
        domain: &str,
        rtype: RecordType,
    ) -> Result<DnsQueryRecord, ModuleError> {
        let wire = build_query(domain, rtype);
        let (_, record) = self.query(&wire).await;
        if record.ok {
            Ok(record)
        } else {
            Err(ModuleError::new(
                StatusCode::Timeout,
                ERR_DNS_TIMEOUT,
                format!(
                    "DNS query for '{domain}' ({}) failed with rcode {}",
                    record.qtype, record.rcode
                ),
            ))
        }
    }

    /// Clear the forward/reverse cache and every fake-IP allocation.
    pub(crate) fn clear_cache(&self) -> usize {
        let before = self.resolver.dns_results(None, usize::MAX).len();
        self.resolver.clear_cache();
        let _ = self.resolver.flush_fake_ip();
        before
    }

    fn resolver_label(&self, domain: &str, answers: &[IpAddr]) -> String {
        if !answers.is_empty() && self.resolver.fake_ip_active_for(domain) {
            return "fake-ip".to_string();
        }
        if let Some(entry) = self.resolver.dns_results(Some(domain), 1).first() {
            if let Some(source) = &entry.source {
                return source.clone();
            }
        }
        self.config
            .nameservers
            .first()
            .cloned()
            .unwrap_or_else(|| "unknown".to_string())
    }

    fn record_mapping(&self, domain: &str, ip: IpAddr) {
        let mapping = DnsMapping {
            domain: domain.to_string(),
            ip: ip.to_string(),
            fake: self.resolver.is_fake_ip(ip),
            ts_ms: now_ms(),
            domain_known: true,
        };
        push_bounded(&self.mappings, mapping, MAPPING_RING_CAPACITY);
    }

    fn push_record(&self, record: DnsQueryRecord) {
        push_bounded(&self.records, record, QUERY_RING_CAPACITY);
    }

    fn emit(&self, record: &DnsQueryRecord) {
        let level = if record.ok {
            crate::logging::LogLevel::Info
        } else {
            crate::logging::LogLevel::Error
        };
        // Todo 15: the DNS record enters the bounded module log ring (kind=dns)
        // and is forwarded to the host LogBridge as `proxy.dns.query|failure`.
        crate::logging::record_dns(level, record);
        if let Ok(json) = serde_json::to_string(record) {
            crate::dispatch::emit_dns_event(&json);
        }
    }

    pub(crate) fn stats_json(&self) -> serde_json::Value {
        serde_json::json!({
            "queries": self.queries.load(Ordering::SeqCst),
            "failures": self.failures.load(Ordering::SeqCst),
            "cacheEntries": self.resolver.dns_results(None, usize::MAX).len(),
            "fakeIpActive": self.resolver.fake_ip_active_for("example.com") || self.resolver.fake_ip_v4_net().is_some(),
            "fakeIpRange": self.resolver.fake_ip_v4_net().map(|n| n.to_string()),
        })
    }

    pub(crate) fn recent_records(&self, limit: usize) -> Vec<DnsQueryRecord> {
        let ring = self.records.lock().unwrap_or_else(|e| e.into_inner());
        ring.iter().rev().take(limit).cloned().collect()
    }

    /// Domain→IP mappings for the Todo 16 domain-statistics path.
    pub(crate) fn mappings(&self, limit: usize) -> Vec<DnsMapping> {
        let ring = self.mappings.lock().unwrap_or_else(|e| e.into_inner());
        ring.iter().rev().take(limit).cloned().collect()
    }

    /// Reverse lookup for the Todo 16 domain-statistics fallback: map a flow's
    /// destination IP back to the domain we recorded for it. Checks the bounded
    /// mapping ring (newest first, so the freshest attribution wins) and then
    /// the resolver's own fake-IP reverse mapping. `None` means the domain is
    /// unavailable (plain-IP / ECH / ESNI / QUIC-without-SNI) and the caller
    /// must fall back to the IP with `domainKnown:false`.
    pub(crate) fn domain_for_ip(&self, ip: IpAddr) -> Option<DnsMapping> {
        {
            let ring = self.mappings.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(hit) = ring
                .iter()
                .rev()
                .find(|m| m.ip.parse::<IpAddr>().ok() == Some(ip))
            {
                return Some(hit.clone());
            }
        }
        self.resolver.reverse_lookup(ip).map(|domain| DnsMapping {
            domain: domain.to_string(),
            ip: ip.to_string(),
            fake: true,
            ts_ms: now_ms(),
            domain_known: true,
        })
    }
}

fn push_bounded<T>(ring: &Mutex<VecDeque<T>>, item: T, capacity: usize) {
    let mut guard = ring.lock().unwrap_or_else(|e| e.into_inner());
    if guard.len() >= capacity {
        guard.pop_front();
    }
    guard.push_back(item);
}

/// DNS sockets created by meow's resolver go through OUR protect-aware
/// constructors, so bootstrap/DoH/DoT dials apply the host `protect_fd` on
/// device (and are countable on host).
struct ProtectedSocketFactory;

impl meow_dns::SocketFactory for ProtectedSocketFactory {
    fn bind_udp(&self) -> Pin<Box<dyn Future<Output = std::io::Result<UdpSocket>> + Send + '_>> {
        Box::pin(async {
            protect::bind_udp("0.0.0.0:0".parse().expect("valid unspecified addr")).await
        })
    }

    fn connect_tcp(
        &self,
        addr: SocketAddr,
    ) -> Pin<Box<dyn Future<Output = std::io::Result<TcpStream>> + Send + '_>> {
        Box::pin(async move { protect::connect_tcp(addr).await })
    }
}

fn hosts_trie(hosts: &BTreeMap<String, Vec<String>>) -> DomainTrie<meow_dns::HostEntry> {
    let mut trie = DomainTrie::new();
    for (domain, ips) in hosts {
        let parsed: Vec<IpAddr> = ips.iter().filter_map(|s| s.parse().ok()).collect();
        if !parsed.is_empty() {
            trie.insert(domain, meow_dns::HostEntry::Addresses(parsed));
        }
    }
    trie
}

fn parse_net(range: &str) -> Result<IpNet, ModuleError> {
    range.parse::<IpNet>().map_err(|e| {
        ModuleError::new(
            StatusCode::InvalidArgument,
            ERR_DNS_CONFIG_INVALID,
            format!("fake-ip range '{range}': {e}"),
        )
    })
}

fn bootstrap_err(e: meow_dns::BootstrapError) -> ModuleError {
    let message = e.to_string();
    let code = if matches!(e, meow_dns::BootstrapError::DefaultNameserverNotPlain { .. }) {
        StatusCode::InvalidArgument
    } else {
        StatusCode::InternalError
    };
    ModuleError::new(code, ERR_DNS_BOOTSTRAP_FAILED, message)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn parse_question(wire: &[u8]) -> (String, RecordType) {
    match Message::from_vec(wire) {
        Ok(msg) => match msg.queries.first() {
            Some(q) => (
                q.name().to_utf8().trim_end_matches('.').to_string(),
                q.query_type(),
            ),
            None => (String::new(), RecordType::A),
        },
        Err(_) => (String::new(), RecordType::A),
    }
}

fn summarize_response(response: &[u8]) -> (ResponseCode, Vec<IpAddr>) {
    let Ok(msg) = Message::from_vec(response) else {
        return (ResponseCode::ServFail, Vec::new());
    };
    let mut answers = Vec::new();
    for rec in &msg.answers {
        match &rec.data {
            RData::A(a) => answers.push(IpAddr::V4(a.0)),
            RData::AAAA(a) => answers.push(IpAddr::V6(a.0)),
            _ => {}
        }
    }
    (msg.metadata.response_code, answers)
}

fn qtype_label(qtype: RecordType) -> String {
    match qtype {
        RecordType::A => "A".to_string(),
        RecordType::AAAA => "AAAA".to_string(),
        other => format!("{other:?}"),
    }
}

#[allow(dead_code)]
fn build_query(domain: &str, rtype: RecordType) -> Vec<u8> {
    let name = match format!("{domain}.").parse() {
        Ok(n) => n,
        Err(_) => domain.parse().unwrap_or_else(|_| ".".parse().unwrap()),
    };
    let mut msg = Message::new(0x4242, MessageType::Query, OpCode::Query);
    msg.metadata.recursion_desired = true;
    msg.add_query(Query::query(name, rtype));
    msg.to_vec().unwrap_or_default()
}

fn build_servfail(query: &[u8]) -> Vec<u8> {
    let mut header = vec![0u8; 12];
    if query.len() >= 12 {
        header[0..2].copy_from_slice(&query[0..2]);
        header[2] = 0x80 | (query[2] & 0x79);
        header[3] = 0x82;
    } else {
        header[2] = 0x80;
        header[3] = 0x82;
    }
    header
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::TEST_SERIAL as SERIAL;
    use hickory_proto::rr::rdata::A;

    #[test]
    fn mode_kind_serializes_kebab_case() {
        assert_eq!(
            serde_json::to_string(&DnsModeKind::FakeIp).unwrap(),
            "\"fake-ip\""
        );
        assert_eq!(
            serde_json::to_string(&DnsModeKind::RedirHost).unwrap(),
            "\"redir-host\""
        );
    }

    #[test]
    fn partial_patch_merges_and_validates() {
        let mut cfg = DnsConfig::default();
        cfg.apply_patch(br#"{"mode":"redir-host","nameservers":["1.0.0.1"]}"#)
            .unwrap();
        assert_eq!(cfg.mode, DnsModeKind::RedirHost);
        assert_eq!(cfg.nameservers, vec!["1.0.0.1".to_string()]);
        // Other fields keep their defaults.
        assert!(cfg.ipv6);
        let err = cfg
            .apply_patch(br#"{"nameservers":["not a nameserver!!"]}"#)
            .unwrap_err();
        assert_eq!(err.code, ERR_DNS_CONFIG_INVALID);
    }

    #[test]
    fn default_config_exposes_cn_primary_and_international_fallback() {
        let cfg = DnsConfig::default();
        assert_eq!(
            cfg.nameservers,
            vec!["223.5.5.5".to_string(), "119.29.29.29".to_string()]
        );
        assert_eq!(
            cfg.fallback,
            vec!["1.1.1.1".to_string(), "8.8.8.8".to_string()]
        );
        assert!(
            cfg.default_nameservers.is_empty(),
            "plain-IP defaults need no bootstrap list"
        );
        for entry in cfg.nameservers.iter().chain(&cfg.fallback) {
            parse_nameserver(entry).expect("default upstreams are parseable plain IPs");
        }
    }

    #[test]
    fn apply_patch_round_trips_the_default_upstreams() {
        let cfg = DnsConfig::default();
        let patch = serde_json::to_vec(&cfg).unwrap();
        let mut merged = DnsConfig::default();
        merged.apply_patch(&patch).unwrap();
        assert_eq!(merged.nameservers, cfg.nameservers);
        assert_eq!(merged.fallback, cfg.fallback);
    }

    #[test]
    fn summarize_reads_a_record_and_rcode() {
        let mut msg = Message::new(1, MessageType::Response, OpCode::Query);
        msg.metadata.response_code = ResponseCode::NoError;
        msg.add_answer(hickory_proto::rr::Record::from_rdata(
            "example.com.".parse().unwrap(),
            60,
            RData::A(A::new(93, 184, 216, 34)),
        ));
        let (rcode, answers) = summarize_response(&msg.to_vec().unwrap());
        assert_eq!(rcode, ResponseCode::NoError);
        assert_eq!(answers, vec![IpAddr::from([93, 184, 216, 34])]);
    }

    #[test]
    fn parse_question_round_trips() {
        let wire = build_query("fixture.example", RecordType::A);
        let (domain, qtype) = parse_question(&wire);
        assert_eq!(domain, "fixture.example");
        assert_eq!(qtype, RecordType::A);
    }

    /// fake-IP allocation + reverse lookup through the real resolver.
    #[tokio::test]
    async fn fake_ip_allocates_and_reverse_looks_up() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let mut cfg = DnsConfig::default();
        cfg.mode = DnsModeKind::FakeIp;
        cfg.nameservers = vec!["127.0.0.1".to_string()];
        let engine = DnsEngine::build(cfg).await.expect("engine builds");

        let ip = engine
            .resolver
            .fakeip_pool_over("198.18.0.0/16".parse().unwrap())
            .expect("v4 pool installed")
            .lookup("fixture.example");
        assert!(engine.resolver.is_fake_ip(ip));
        let back = engine.resolver.reverse_lookup(ip).expect("reverse mapping");
        assert_eq!(back.as_str(), "fixture.example");

        // The same host must be stable, the next host gets a different IP.
        let again = engine
            .resolver
            .fakeip_pool_over("198.18.0.0/16".parse().unwrap())
            .unwrap()
            .lookup("fixture.example");
        assert_eq!(ip, again, "allocation is stable per host");
        let other = engine
            .resolver
            .fakeip_pool_over("198.18.0.0/16".parse().unwrap())
            .unwrap()
            .lookup("second.example");
        assert_ne!(ip, other);
    }

    /// fake-IP answers carry a query-log record + a domain→IP mapping.
    #[tokio::test]
    async fn fake_ip_query_logs_and_records_mapping() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let mut cfg = DnsConfig::default();
        cfg.mode = DnsModeKind::FakeIp;
        cfg.nameservers = vec!["127.0.0.1".to_string()];
        let engine = DnsEngine::build(cfg).await.expect("engine builds");

        let record = engine
            .resolve("fixture.example", RecordType::A)
            .await
            .expect("fake-ip A answer");
        assert!(record.ok);
        assert_eq!(record.qtype, "A");
        assert_eq!(record.rcode, "NoError");
        assert_eq!(record.note.as_deref(), Some("fake-ip"));
        assert_eq!(record.answers.len(), 1);
        let fake: IpAddr = record.answers[0].parse().unwrap();
        assert!(engine.resolver.is_fake_ip(fake));

        let mappings = engine.mappings(10);
        assert!(
            mappings
                .iter()
                .any(|m| m.domain == "fixture.example" && m.ip == record.answers[0] && m.fake),
            "domain→IP mapping must be recorded for Todo 16: {mappings:?}"
        );
        assert!(engine.recent_records(10).iter().any(|r| r.domain == "fixture.example"));
    }

    /// Cache clear drops forward entries (and fake-IP allocations).
    #[tokio::test]
    async fn clear_cache_empties_the_resolver_cache() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let mut cfg = DnsConfig::default();
        cfg.mode = DnsModeKind::Normal;
        cfg.nameservers = vec!["127.0.0.1".to_string()];
        let engine = DnsEngine::build(cfg).await.expect("engine builds");
        engine
            .resolver
            .preload_cache("cached.example", &["93.184.216.34".parse().unwrap()], Duration::from_secs(60));
        assert!(!engine.resolver.dns_results(None, usize::MAX).is_empty());
        let flushed = engine.clear_cache();
        assert!(flushed >= 1, "one entry was flushed, got {flushed}");
        assert!(engine.resolver.dns_results(None, usize::MAX).is_empty());
    }

    /// Happy path: a fixture query resolves against a stub UDP nameserver, and
    /// the resolver label in the record names the stub upstream.
    #[tokio::test]
    async fn fixture_query_resolves_via_stub_upstream() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let stub = crate::dns::tests::StubDns::start().await;
        let mut cfg = DnsConfig::default();
        cfg.mode = DnsModeKind::Normal;
        cfg.nameservers = vec![format!("udp://127.0.0.1:{}", stub.port)];
        cfg.ipv6 = false;
        let engine = DnsEngine::build(cfg).await.expect("engine builds");

        let record = engine
            .resolve("fixture.example", RecordType::A)
            .await
            .expect("stub answers");
        assert!(record.ok);
        assert_eq!(record.answers, vec![stub.answer.to_string()]);
        assert!(
            record.resolver.contains("127.0.0.1"),
            "record must name the stub resolver, got {}",
            record.resolver
        );
    }

    /// Failure path: an unreachable primary resolver falls back to the
    /// configured fallback, then a no-fallback setup surfaces a structured
    /// timeout + a logged failure record.
    #[tokio::test]
    async fn unreachable_primary_uses_fallback_then_times_out_without_one() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let stub = StubDns::start().await;
        let dead = dead_udp_addr().await;

        let mut cfg = DnsConfig::default();
        cfg.mode = DnsModeKind::Normal;
        cfg.ipv6 = false;
        cfg.nameservers = vec![format!("udp://127.0.0.1:{}", dead)];
        cfg.fallback = vec![format!("udp://127.0.0.1:{}", stub.port)];
        let engine = DnsEngine::build(cfg).await.expect("engine builds");
        let record = engine
            .resolve("fixture.example", RecordType::A)
            .await
            .expect("fallback answers");
        assert_eq!(record.answers, vec![stub.answer.to_string()]);

        let mut only_dead = DnsConfig::default();
        only_dead.mode = DnsModeKind::Normal;
        only_dead.ipv6 = false;
        only_dead.nameservers = vec![format!("udp://127.0.0.1:{}", dead)];
        let engine = DnsEngine::build(only_dead).await.expect("engine builds");
        let before = engine.stats_json()["failures"].as_u64().unwrap();
        let err = engine
            .resolve("fixture.example", RecordType::A)
            .await
            .expect_err("unreachable resolver must not answer");
        assert_eq!(err.code, ERR_DNS_TIMEOUT);
        assert_eq!(err.status, StatusCode::Timeout);
        let after = engine.stats_json()["failures"].as_u64().unwrap();
        assert_eq!(after, before + 1, "a DNS failure record must be counted/logged");
    }

    /// DoH wiring: a `https://` nameserver reaches a stub endpoint over the
    /// DoH transport and fails closed (structured timeout) rather than
    /// hanging, proving the URL is parsed and routed through the DoH client.
    ///
    /// Full offline DoH *resolution* is not possible with the pinned meow: its
    /// `meow_dns` DoH client hardcodes certificate verification against the
    /// Mozilla roots and exposes no `additional_roots` / `skip_cert_verify`
    /// hook, so a local self-signed stub can never be trusted (see API.md §9.3).
    #[tokio::test]
    async fn doh_url_reaches_stub_endpoint_and_fails_closed() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            // A plaintext listener: the DoH client's TLS handshake must fail.
            if let Ok((stream, _)) = listener.accept().await {
                drop(stream);
            }
        });

        let mut cfg = DnsConfig::default();
        cfg.mode = DnsModeKind::Normal;
        cfg.ipv6 = false;
        cfg.nameservers = vec![format!("https://127.0.0.1:{port}/dns-query#stub.example")];
        let engine = DnsEngine::build(cfg).await.expect("engine builds");

        let result = tokio::time::timeout(
            Duration::from_secs(10),
            engine.resolve("fixture.example", RecordType::A),
        )
        .await
        .expect("DoH query must not hang");
        let err = result.expect_err("untrusted DoH stub must fail closed");
        assert_eq!(err.code, ERR_DNS_TIMEOUT);
        assert!(engine.stats_json()["failures"].as_u64().unwrap() >= 1);
    }

    /// A stub UDP resolver: answers every A query with one fixed address.
    struct StubDns {
        port: u16,
        answer: IpAddr,
    }

    impl StubDns {
        async fn start() -> Self {
            let socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let port = socket.local_addr().unwrap().port();
            let answer: IpAddr = "203.0.113.7".parse().unwrap();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 1024];
                loop {
                    let Ok((n, peer)) = socket.recv_from(&mut buf).await else {
                        break;
                    };
                    let wire = &buf[..n];
                    if let Ok(msg) = Message::from_vec(wire) {
                        let mut resp = Message::new(
                            msg.metadata.id,
                            MessageType::Response,
                            OpCode::Query,
                        );
                        resp.metadata.response_code = ResponseCode::NoError;
                        resp.metadata.recursion_available = true;
                        for q in &msg.queries {
                            resp.add_query(q.clone());
                            if q.query_type() == RecordType::A {
                                resp.add_answer(hickory_proto::rr::Record::from_rdata(
                                    q.name().clone(),
                                    60,
                                    RData::A(A::new(203, 0, 113, 7)),
                                ));
                            }
                        }
                        if let Ok(bytes) = resp.to_vec() {
                            let _ = socket.send_to(&bytes, peer).await;
                        }
                    }
                }
            });
            Self { port, answer }
        }
    }

    /// Bind then drop a UDP socket to obtain a loopback port nothing listens on.
    async fn dead_udp_addr() -> u16 {
        let socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let port = socket.local_addr().unwrap().port();
        drop(socket);
        port
    }
}
