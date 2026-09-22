//! Generated engine config (Todo 13 of the proxy kernel plan).
//!
//! `config.generate` / `profile.export_clash` render a Clash-compatible YAML
//! document from the persisted canonical profile ([`crate::profile`]) plus the
//! module's live overlays: the DNS config (Todo 8), the rule lines (Todo 9) and
//! a `tun` block carrying only `stack`/`mtu`. The engine never receives raw
//! provider YAML: the template is authored here, and the only fields that
//! survive from a stored profile are the whitelisted node/group fields.
//!
//! ## Template guarantees (pinned)
//!
//! * `external-controller` and `secret` are **never** emitted (the module runs
//!   no control server). A subscription cannot configure a control port/secret.
//! * `proxy-providers`, `rule-providers`, `script` nodes and any `dns`/`tun`
//!   override carried by imported content are not merged — the DNS/tun blocks
//!   come from module-owned config, never from the profile. The profile's
//!   captured `rules:` are re-emitted through this template (see
//!   [`resolve_rules`]); nothing else from the provider document is.
//! * `tun.file-descriptor` is **not** emitted: meow's `RawTun` has no such
//!   field (the TUN fd is injected out-of-band into our netstack pump, Todo 6).
//! * `tun` carries only `enable`, `stack` and `mtu`.
//!
//! ## Registry build
//!
//! [`build_registry`] turns the parsed raw config into the
//! `HashMap<SmolStr, Arc<dyn Proxy>>` meow's tunnel expects, wiring
//! selector/url-test/fallback groups to the process-wide [`SelectorStore`]
//! opened by [`crate::nodes::ensure_selector_store`], and returns structured
//! warnings for nodes/groups the enabled protocol set cannot build. A node that
//! cannot be built is skipped, never fatal.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use gstore_contract::error::{ModuleError, StatusCode};
use meow_common::Proxy;
use meow_config::proxy_parser::{
    parse_proxy_group_lenient_with_store, parse_proxy_provider_node, WrappedProxy,
};
use meow_config::raw::{RawConfig, RawProxyGroup};
use meow_proxy::{DirectAdapter, RejectAdapter, SelectorStore};
use serde::Deserialize;
use serde_json::{json, Value};
use serde_yaml::{Mapping, Value as Yaml};
use smol_str::SmolStr;

use crate::dns::{DnsConfig, FakeIpFilterMode};
use crate::profile::{ProfileStore, StoredProfile};
use crate::subscription::{ProxyGroup, ProxyNode};

pub(crate) const ERR_CONFIG_PROFILE_REQUIRED: &str = "PROXY_CONFIG_PROFILE_REQUIRED";
pub(crate) const ERR_CONFIG_INVALID: &str = "PROXY_CONFIG_INVALID";
pub(crate) const ERR_CONFIG_NODE_UNSUPPORTED: &str = "PROXY_CONFIG_NODE_UNSUPPORTED";

pub(crate) const TEMPLATE_ID: &str = "gstore-controlled-v1";
pub(crate) const DEFAULT_STACK: &str = "gvisor";
pub(crate) const DEFAULT_MTU: u16 = 1500;
const MIN_MTU: u16 = 1280;
const MAX_STACK_LEN: usize = 32;

/// `HashMap` meow's route table uses for its proxy registry.
pub(crate) type ProxyMap = HashMap<SmolStr, Arc<dyn Proxy>>;

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GenerateRequest {
    #[serde(default)]
    pub profile_id: Option<String>,
    #[serde(default)]
    pub stack: Option<String>,
    #[serde(default)]
    pub mtu: Option<u16>,
    #[serde(default)]
    pub dns: Option<Value>,
    #[serde(default)]
    pub rules: Option<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExportRequest {
    #[serde(alias = "profileId")]
    pub id: String,
    #[serde(default)]
    pub stack: Option<String>,
    #[serde(default)]
    pub mtu: Option<u16>,
    #[serde(default)]
    pub dns: Option<Value>,
    #[serde(default)]
    pub rules: Option<Vec<String>>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ConfigWarning {
    pub code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub node: Option<String>,
    pub message: String,
}

impl ConfigWarning {
    fn node(node: &str, message: impl Into<String>) -> Self {
        Self {
            code: ERR_CONFIG_NODE_UNSUPPORTED.to_string(),
            node: Some(node.to_string()),
            message: message.into(),
        }
    }

    fn group(group: &str, message: impl Into<String>) -> Self {
        Self {
            code: ERR_CONFIG_INVALID.to_string(),
            node: Some(group.to_string()),
            message: message.into(),
        }
    }
}

#[derive(Debug)]
pub(crate) struct GeneratedConfig {
    pub yaml: String,
    pub raw: RawConfig,
    pub profile_id: Option<String>,
    pub profile_name: String,
    pub node_count: usize,
    pub group_count: usize,
    pub rule_count: usize,
    pub warnings: Vec<ConfigWarning>,
    pub hash: String,
    pub generated_at_ms: u64,
    pub stack: String,
    pub mtu: u16,
}

impl GeneratedConfig {
    pub(crate) fn to_data(&self) -> Value {
        json!({
            "config": self.yaml,
            "format": "clash",
            "template": TEMPLATE_ID,
            "profileId": self.profile_id,
            "profileName": self.profile_name,
            "hash": self.hash,
            "generatedAtMs": self.generated_at_ms,
            "counts": {
                "proxies": self.node_count,
                "groups": self.group_count,
                "rules": self.rule_count,
            },
            "overlays": {
                "stack": self.stack,
                "mtu": self.mtu,
            },
            "warnings": self.warnings,
        })
    }
}

pub(crate) fn parse_request(payload: &[u8]) -> Result<GenerateRequest, ModuleError> {
    if payload.is_empty() {
        return Ok(GenerateRequest::default());
    }
    let value: Value = serde_json::from_slice(payload)
        .map_err(|e| invalid(format!("payload must be a JSON object: {e}")))?;
    if !value.is_object() {
        return Err(invalid("payload must be a JSON object"));
    }
    serde_json::from_value(value)
        .map_err(|e| invalid(format!("invalid config request: {e}")))
}

pub(crate) fn parse_export_request(payload: &[u8]) -> Result<ExportRequest, ModuleError> {
    if payload.is_empty() {
        return Err(invalid("profile.export_clash requires {id}"));
    }
    serde_json::from_slice(payload)
        .map_err(|e| invalid(format!("profile.export_clash payload: {e}")))
}

pub(crate) fn reload_payload(yaml: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({ "config": yaml })).unwrap_or_default()
}

fn invalid(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_CONFIG_INVALID, message)
}

/// Render the controlled template. Requires a stored profile (explicit
/// `profileId`, else the first profile in stable store order).
pub(crate) fn generate_for(
    data_dir: &str,
    _cache_dir: &str,
    req: &GenerateRequest,
) -> Result<GeneratedConfig, ModuleError> {
    let store = open_store(data_dir)?;
    let record = resolve_profile(&store, req.profile_id.as_deref())?;
    generate_record(&record, req)
}

/// Like [`generate_for`] but returns `None` when no profile exists and the
/// caller did not name one — used by `core.start`/`core.restart` so a profile-less
/// engine can still start with the built-in DIRECT fallback.
pub(crate) fn try_generate(
    data_dir: &str,
    _cache_dir: &str,
    req: &GenerateRequest,
) -> Result<Option<GeneratedConfig>, ModuleError> {
    if data_dir.trim().is_empty() {
        return Ok(None);
    }
    let store = open_store(data_dir)?;
    let explicit = req
        .profile_id
        .as_deref()
        .map(str::trim)
        .filter(|id| !id.is_empty());
    if explicit.is_none() {
        let list = store.list()?;
        if list.profiles.is_empty() {
            return Ok(None);
        }
    }
    let record = resolve_profile(&store, explicit)?;
    Ok(Some(generate_record(&record, req)?))
}

pub(crate) fn export(record: &StoredProfile, req: &ExportRequest) -> Result<GeneratedConfig, ModuleError> {
    generate_record(
        record,
        &GenerateRequest {
            profile_id: Some(record.id.clone()),
            stack: req.stack.clone(),
            mtu: req.mtu,
            dns: req.dns.clone(),
            rules: req.rules.clone(),
        },
    )
}

fn open_store(data_dir: &str) -> Result<ProfileStore, ModuleError> {
    if data_dir.trim().is_empty() {
        return Err(ModuleError::new(
            StatusCode::InvalidArgument,
            ERR_CONFIG_PROFILE_REQUIRED,
            "module data_dir is empty; a profile must be stored before generating a config",
        ));
    }
    ProfileStore::open(data_dir)
}

fn resolve_profile(
    store: &ProfileStore,
    profile_id: Option<&str>,
) -> Result<StoredProfile, ModuleError> {
    let explicit = profile_id.map(str::trim).filter(|id| !id.is_empty());
    let id = match explicit {
        Some(id) => id.to_string(),
        None => store
            .list()?
            .profiles
            .first()
            .map(|summary| summary.id.clone())
            .ok_or_else(|| {
                ModuleError::new(
                    StatusCode::InvalidArgument,
                    ERR_CONFIG_PROFILE_REQUIRED,
                    "no profile is stored; import or create one before generating a config",
                )
            })?,
    };
    let payload = serde_json::to_vec(&json!({ "id": id })).unwrap_or_default();
    store.get(&payload)
}

fn generate_record(
    record: &StoredProfile,
    req: &GenerateRequest,
) -> Result<GeneratedConfig, ModuleError> {
    let stack = resolve_stack(req.stack.as_deref());
    let mtu = resolve_mtu(req.mtu)?;
    let dns = merged_dns(req.dns.as_ref())?;

    let mut warnings = Vec::new();
    let profile = &record.profile;
    let rules = resolve_rules(req.rules.as_ref(), &profile.rules, !profile.nodes.is_empty());

    let proxies: Vec<Yaml> = profile
        .nodes
        .iter()
        .map(|node| {
            if !representable(&node.node_type) {
                warnings.push(ConfigWarning::node(
                    &node.name,
                    format!(
                        "node type '{}' is not reconstructable from the canonical model; \
                         the engine will skip it",
                        node.node_type
                    ),
                ));
            }
            proxy_value(node)
        })
        .collect();

    let groups = group_values(profile);
    let node_names: Vec<String> = profile.nodes.iter().map(|n| n.name.clone()).collect();

    let mut root = Mapping::new();
    root.insert(ys("mode"), ys("rule"));
    root.insert(ys("log-level"), ys("warning"));
    root.insert(ys("proxies"), Yaml::Sequence(proxies));
    root.insert(ys("proxy-groups"), Yaml::Sequence(groups));
    root.insert(
        ys("rules"),
        Yaml::Sequence(rules.iter().map(|line| ys(line)).collect()),
    );
    root.insert(ys("dns"), dns_value(&dns));
    root.insert(ys("tun"), tun_value(&stack, mtu));
    if !dns.hosts.is_empty() {
        root.insert(ys("hosts"), hosts_value(&dns));
    }

    let value = Yaml::Mapping(root);
    let yaml = serde_yaml::to_string(&value)
        .map_err(|e| ModuleError::internal(format!("config serialize: {e}")))?;
    let raw: RawConfig = parse_raw(&yaml)?;
    let hash = sha256_hex(&yaml);
    let group_count = raw.proxy_groups.as_deref().map(|groups| groups.len()).unwrap_or(0);

    Ok(GeneratedConfig {
        yaml,
        raw,
        profile_id: Some(record.id.clone()),
        profile_name: profile.name.clone(),
        node_count: node_names.len(),
        group_count,
        rule_count: rules.len(),
        warnings,
        hash,
        generated_at_ms: crate::now_ms(),
        stack,
        mtu,
    })
}

fn resolve_stack(raw: Option<&str>) -> String {
    match raw.map(str::trim).filter(|s| !s.is_empty()) {
        Some(s) if s.len() <= MAX_STACK_LEN => s.to_string(),
        Some(s) => {
            crate::log_message(
                3,
                &format!("proxy: tun stack '{s}' exceeds {MAX_STACK_LEN} chars; using {DEFAULT_STACK}"),
            );
            DEFAULT_STACK.to_string()
        }
        None => DEFAULT_STACK.to_string(),
    }
}

fn resolve_mtu(raw: Option<u16>) -> Result<u16, ModuleError> {
    let mtu = raw.unwrap_or(DEFAULT_MTU);
    if mtu < MIN_MTU {
        return Err(invalid(format!(
            "mtu {mtu} is below the {MIN_MTU} minimum accepted by the engine"
        )));
    }
    Ok(mtu)
}

/// Terminal target; `group_values` always emits this select group when nodes exist.
const DEFAULT_MATCH_GROUP: &str = "PROXY";

/// Source priority: overlay → captured profile rules → current lines, plus an appended terminal MATCH when absent.
fn resolve_rules(
    overlay: Option<&Vec<String>>,
    profile_rules: &[String],
    has_nodes: bool,
) -> Vec<String> {
    let lines = match overlay {
        Some(lines) => lines.clone(),
        None if !profile_rules.is_empty() => profile_rules.to_vec(),
        None => crate::rules::current_lines(),
    };
    let mut cleaned: Vec<String> = lines
        .into_iter()
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .collect();
    if !cleaned.iter().any(|line| is_terminal_match(line)) {
        cleaned.push(if has_nodes {
            format!("MATCH,{DEFAULT_MATCH_GROUP}")
        } else {
            "MATCH,DIRECT".to_string()
        });
    }
    cleaned
}

fn is_terminal_match(line: &str) -> bool {
    let head = line.split(',').next().unwrap_or("").trim();
    head.eq_ignore_ascii_case("MATCH") || head.eq_ignore_ascii_case("FINAL")
}

fn merged_dns(overlay: Option<&Value>) -> Result<DnsConfig, ModuleError> {
    let mut cfg = crate::dns::config();
    if let Some(value) = overlay {
        let bytes = serde_json::to_vec(value)
            .map_err(|e| invalid(format!("dns overlay encode: {e}")))?;
        cfg.apply_patch(&bytes)?;
    }
    Ok(cfg)
}

fn dns_value(cfg: &DnsConfig) -> Yaml {
    let mut m = Mapping::new();
    m.insert(ys("enable"), Yaml::Bool(true));
    m.insert(ys("enhanced-mode"), ys(cfg.mode.as_str()));
    if let Some(range) = &cfg.fake_ip_range {
        m.insert(ys("fake-ip-range"), ys(range.clone()));
    }
    if !cfg.fake_ip_filter.is_empty() {
        m.insert(
            ys("fake-ip-filter"),
            Yaml::Sequence(cfg.fake_ip_filter.iter().map(ys).collect()),
        );
    }
    m.insert(
        ys("fake-ip-filter-mode"),
        ys(match cfg.fake_ip_filter_mode {
            FakeIpFilterMode::Blacklist => "blacklist",
            FakeIpFilterMode::Whitelist => "whitelist",
        }),
    );
    let mut nameservers: Vec<&String> = Vec::new();
    nameservers.extend(cfg.nameservers.iter());
    nameservers.extend(cfg.doh.iter());
    nameservers.extend(cfg.dot.iter());
    m.insert(
        ys("nameserver"),
        Yaml::Sequence(nameservers.into_iter().map(|s| ys(s.clone())).collect()),
    );
    if !cfg.fallback.is_empty() {
        m.insert(
            ys("fallback"),
            Yaml::Sequence(cfg.fallback.iter().map(|s| ys(s.clone())).collect()),
        );
    }
    if !cfg.default_nameservers.is_empty() {
        m.insert(
            ys("default-nameserver"),
            Yaml::Sequence(cfg.default_nameservers.iter().map(|s| ys(s.clone())).collect()),
        );
    }
    m.insert(ys("use-hosts"), Yaml::Bool(cfg.use_hosts));
    Yaml::Mapping(m)
}

fn hosts_value(cfg: &DnsConfig) -> Yaml {
    let mut m = Mapping::new();
    for (domain, ips) in &cfg.hosts {
        m.insert(
            ys(domain.clone()),
            Yaml::Sequence(ips.iter().map(|ip| ys(ip.clone())).collect()),
        );
    }
    Yaml::Mapping(m)
}

fn tun_value(stack: &str, mtu: u16) -> Yaml {
    let mut m = Mapping::new();
    m.insert(ys("enable"), Yaml::Bool(true));
    m.insert(ys("stack"), ys(stack));
    m.insert(ys("mtu"), Yaml::Number(u64::from(mtu).into()));
    Yaml::Mapping(m)
}

const REPRESENTABLE: [&str; 7] =
    ["ss", "vmess", "vless", "trojan", "hysteria2", "http", "socks5"];

fn representable(node_type: &str) -> bool {
    REPRESENTABLE
        .iter()
        .any(|supported| supported.eq_ignore_ascii_case(node_type))
}

fn proxy_value(node: &ProxyNode) -> Yaml {
    let node_type = node.node_type.to_ascii_lowercase();
    let mut m = Mapping::new();
    m.insert(ys("name"), ys(node.name.clone()));
    m.insert(ys("type"), ys(node_type.clone()));
    m.insert(ys("server"), ys(node.server.clone()));
    m.insert(
        ys("port"),
        Yaml::Number(u64::from(node.port).into()),
    );

    match node_type.as_str() {
        "ss" => {
            put_opt(&mut m, "cipher", node.cipher.as_deref());
            put_opt(&mut m, "password", node.password.as_deref());
            m.insert(ys("udp"), Yaml::Bool(true));
        }
        "vmess" => {
            put_opt(&mut m, "uuid", node.uuid.as_deref());
            m.insert(
                ys("alterId"),
                Yaml::Number(u64::from(node.alter_id.unwrap_or(0)).into()),
            );
            m.insert(
                ys("cipher"),
                ys(node.security.clone().unwrap_or_else(|| "auto".to_string())),
            );
            put_tls(&mut m, node);
            put_transport(&mut m, node);
        }
        "vless" => {
            put_opt(&mut m, "uuid", node.uuid.as_deref());
            put_opt(&mut m, "flow", node.flow.as_deref());
            m.insert(
                ys("encryption"),
                ys(node.security.clone().unwrap_or_else(|| "none".to_string())),
            );
            put_tls(&mut m, node);
            if let Some(reality) = &node.reality {
                let mut r = Mapping::new();
                put_opt(&mut r, "public-key", reality.public_key.as_deref());
                put_opt(&mut r, "short-id", reality.short_id.as_deref());
                put_opt(&mut r, "spider-x", reality.spider_x.as_deref());
                m.insert(ys("reality-opts"), Yaml::Mapping(r));
            }
            put_transport(&mut m, node);
        }
        "trojan" => {
            put_opt(&mut m, "password", node.password.as_deref());
            put_opt(&mut m, "sni", node.sni.as_deref());
            put_skip_cert_verify(&mut m, node);
            m.insert(ys("tls"), Yaml::Bool(true));
        }
        "hysteria2" => {
            put_opt(&mut m, "password", node.password.as_deref());
            put_opt(&mut m, "sni", node.sni.as_deref());
            put_skip_cert_verify(&mut m, node);
            put_opt(&mut m, "obfs", node.obfs.as_deref());
            put_opt(&mut m, "obfs-password", node.obfs_password.as_deref());
            m.insert(ys("udp"), Yaml::Bool(true));
        }
        "http" => {
            put_tls(&mut m, node);
        }
        "socks5" => {
            put_tls(&mut m, node);
            m.insert(ys("udp"), Yaml::Bool(true));
        }
        _ => {}
    }
    Yaml::Mapping(m)
}

fn put_tls(m: &mut Mapping, node: &ProxyNode) {
    if node.tls {
        m.insert(ys("tls"), Yaml::Bool(true));
    }
    put_opt(m, "servername", node.sni.as_deref());
    put_opt(m, "client-fingerprint", node.fingerprint.as_deref());
    put_skip_cert_verify(m, node);
    if !node.alpn.is_empty() {
        m.insert(
            ys("alpn"),
            Yaml::Sequence(node.alpn.iter().map(|a| ys(a.clone())).collect()),
        );
    }
}

fn put_skip_cert_verify(m: &mut Mapping, node: &ProxyNode) {
    if let Some(skip) = node.skip_cert_verify {
        m.insert(ys("skip-cert-verify"), Yaml::Bool(skip));
    }
}

fn put_transport(m: &mut Mapping, node: &ProxyNode) {
    if let Some(network) = &node.network {
        m.insert(ys("network"), ys(network.clone()));
    }
    if let Some(ws) = &node.ws {
        let mut w = Mapping::new();
        if let Some(path) = &ws.path {
            w.insert(ys("path"), ys(path.clone()));
        }
        if let Some(host) = &ws.host {
            let mut headers = Mapping::new();
            headers.insert(ys("Host"), ys(host.clone()));
            w.insert(ys("headers"), Yaml::Mapping(headers));
        }
        m.insert(ys("ws-opts"), Yaml::Mapping(w));
    }
    if let Some(grpc) = &node.grpc {
        let mut g = Mapping::new();
        if let Some(service) = &grpc.service_name {
            g.insert(ys("grpc-service-name"), ys(service.clone()));
        }
        m.insert(ys("grpc-opts"), Yaml::Mapping(g));
    }
}

fn put_opt(m: &mut Mapping, key: &str, value: Option<&str>) {
    if let Some(value) = value.filter(|v| !v.is_empty()) {
        m.insert(ys(key), ys(value));
    }
}

fn group_values(profile: &crate::subscription::ImportedProfile) -> Vec<Yaml> {
    let node_names: Vec<String> = profile.nodes.iter().map(|n| n.name.clone()).collect();
    let mut groups: Vec<Yaml> = profile.groups.iter().map(group_value).collect();

    if !profile.groups.iter().any(|g| g.name == "PROXY") {
        groups.push(group_value(&ProxyGroup {
            name: "PROXY".to_string(),
            group_type: "select".to_string(),
            members: node_names,
        }));
    }
    groups
}

fn group_value(group: &ProxyGroup) -> Yaml {
    let mut m = Mapping::new();
    m.insert(ys("name"), ys(group.name.clone()));
    m.insert(ys("type"), ys(group.group_type.to_ascii_lowercase()));
    m.insert(
        ys("proxies"),
        Yaml::Sequence(group.members.iter().map(|member| ys(member.clone())).collect()),
    );
    Yaml::Mapping(m)
}

fn parse_raw(yaml: &str) -> Result<RawConfig, ModuleError> {
    let mut value: Yaml = serde_yaml::from_str(yaml)
        .map_err(|e| ModuleError::internal(format!("generated config parse: {e}")))?;
    value
        .apply_merge()
        .map_err(|e| ModuleError::internal(format!("generated config merge: {e}")))?;
    serde_yaml::from_value(value)
        .map_err(|e| ModuleError::internal(format!("generated config decode: {e}")))
}

fn sha256_hex(input: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())
}

/// Build meow's `name -> Arc<dyn Proxy>` registry from the generated raw config.
pub(crate) fn build_registry(
    raw: &RawConfig,
    store: Option<&Arc<SelectorStore>>,
) -> (ProxyMap, Vec<ConfigWarning>) {
    let mut warnings = Vec::new();
    let mut proxies = ProxyMap::new();
    proxies.insert(
        SmolStr::new_static("DIRECT"),
        Arc::new(WrappedProxy::new(Box::new(DirectAdapter::new()))),
    );
    proxies.insert(
        SmolStr::new_static("REJECT"),
        Arc::new(WrappedProxy::new(Box::new(RejectAdapter::new(false)))),
    );
    proxies.insert(
        SmolStr::new_static("REJECT-DROP"),
        Arc::new(WrappedProxy::new(Box::new(RejectAdapter::new(true)))),
    );

    let ipv6 = raw.ipv6.unwrap_or(true);
    let mut static_names: HashSet<SmolStr> = HashSet::new();
    for raw_proxy in raw.proxies.as_deref().unwrap_or(&[]) {
        let name = raw_proxy
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("?")
            .to_string();
        match parse_proxy_provider_node(raw_proxy, ipv6, false) {
            Ok(proxy) => {
                static_names.insert(SmolStr::from(name.as_str()));
                proxies.insert(SmolStr::from(name.as_str()), proxy);
            }
            Err(e) => warnings.push(ConfigWarning::node(
                &name,
                format!("node '{name}' was not built: {e}"),
            )),
        }
    }

    let mut include_all: Vec<(SmolStr, Arc<dyn Proxy>)> = static_names
        .iter()
        .filter_map(|name| proxies.get(name.as_str()).map(|p| (name.clone(), Arc::clone(p))))
        .collect();
    include_all.sort_by(|(left, _), (right, _)| left.cmp(right));
    let include_all: Vec<Arc<dyn Proxy>> =
        include_all.into_iter().map(|(_, proxy)| proxy).collect();

    let raw_groups = raw.proxy_groups.as_deref().unwrap_or(&[]);
    let declared: HashSet<String> = raw_groups.iter().map(|g| g.name.clone()).collect();
    let mut built: HashSet<String> = HashSet::new();
    let empty_providers: HashMap<String, Arc<meow_config::proxy_provider::ProxyProvider>> =
        HashMap::new();
    let mut remaining: Vec<&RawProxyGroup> = raw_groups.iter().collect();
    let mut passes = remaining.len() + 1;

    while !remaining.is_empty() && passes > 0 {
        passes -= 1;
        let mut still: Vec<&RawProxyGroup> = Vec::new();
        let mut progress = false;
        for group in &remaining {
            if has_unresolved_dependency(group, &declared, &built) {
                still.push(*group);
                continue;
            }
            match parse_proxy_group_lenient_with_store(
                group,
                &proxies,
                &include_all,
                &empty_providers,
                store,
            ) {
                Ok(value) => {
                    let name = value.name().to_string();
                    built.insert(name.clone());
                    proxies.insert(SmolStr::from(name.as_str()), value);
                    progress = true;
                }
                Err(e) => {
                    warnings.push(ConfigWarning::group(
                        &group.name,
                        format!("group '{}' was not built: {e}", group.name),
                    ));
                    still.push(*group);
                }
            }
        }
        if !progress {
            break;
        }
        remaining = still;
    }

    if !proxies.contains_key("GLOBAL") {
        let mut names: Vec<String> = proxies.keys().map(ToString::to_string).collect();
        names.sort();
        let global = RawProxyGroup {
            name: "GLOBAL".to_string(),
            group_type: "select".to_string(),
            proxies: Some(names),
            ..Default::default()
        };
        if let Ok(value) = parse_proxy_group_lenient_with_store(
            &global,
            &proxies,
            &include_all,
            &empty_providers,
            store,
        ) {
            proxies.insert(SmolStr::new_static("GLOBAL"), value);
        }
    }

    (proxies, warnings)
}

fn has_unresolved_dependency(
    group: &RawProxyGroup,
    declared: &HashSet<String>,
    built: &HashSet<String>,
) -> bool {
    group
        .proxies
        .as_deref()
        .unwrap_or(&[])
        .iter()
        .any(|member| declared.contains(member) && !built.contains(member))
}

fn ys(value: impl Into<String>) -> Yaml {
    Yaml::String(value.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::subscription::{ImportSource, ImportedProfile, NodeSource};

    use crate::TEST_SERIAL as SERIAL;

    fn node(name: &str, node_type: &str, server: &str, port: u16, index: usize) -> ProxyNode {
        ProxyNode {
            name: name.to_string(),
            node_type: node_type.to_string(),
            server: server.to_string(),
            port,
            cipher: None,
            password: None,
            uuid: None,
            alter_id: None,
            security: None,
            flow: None,
            network: None,
            tls: false,
            sni: None,
            skip_cert_verify: None,
            alpn: Vec::new(),
            fingerprint: None,
            reality: None,
            ws: None,
            grpc: None,
            obfs: None,
            obfs_password: None,
            groups: Vec::new(),
            source: NodeSource {
                format: "clash".to_string(),
                origin: "text".to_string(),
                index,
            },
        }
    }

    fn trojan(name: &str, server: &str, port: u16, index: usize) -> ProxyNode {
        ProxyNode {
            password: Some("secret".to_string()),
            tls: true,
            sni: Some("example.com".to_string()),
            skip_cert_verify: Some(true),
            ..node(name, "trojan", server, port, index)
        }
    }

    fn vless(name: &str, server: &str, port: u16, index: usize) -> ProxyNode {
        ProxyNode {
            uuid: Some("11111111-2222-3333-4444-555555555555".to_string()),
            security: Some("none".to_string()),
            tls: true,
            sni: Some("example.com".to_string()),
            network: Some("ws".to_string()),
            ws: Some(crate::subscription::WsParams {
                path: Some("/ws".to_string()),
                host: Some("example.com".to_string()),
            }),
            ..node(name, "vless", server, port, index)
        }
    }

    fn hysteria2(name: &str, server: &str, port: u16, index: usize) -> ProxyNode {
        ProxyNode {
            password: Some("secret".to_string()),
            tls: true,
            sni: Some("example.com".to_string()),
            skip_cert_verify: Some(true),
            ..node(name, "hysteria2", server, port, index)
        }
    }

    fn stored(nodes: Vec<ProxyNode>, groups: Vec<ProxyGroup>) -> StoredProfile {
        stored_with_rules(nodes, groups, Vec::new())
    }

    fn stored_with_rules(
        nodes: Vec<ProxyNode>,
        groups: Vec<ProxyGroup>,
        rules: Vec<String>,
    ) -> StoredProfile {
        let names: Vec<String> = nodes.iter().map(|n| n.name.clone()).collect();
        let groups = if groups.is_empty() {
            vec![ProxyGroup {
                name: "PROXY".to_string(),
                group_type: "select".to_string(),
                members: names,
            }]
        } else {
            groups
        };
        StoredProfile {
            schema_version: crate::profile::SCHEMA_VERSION,
            id: "p1".to_string(),
            revision: 1,
            created_at_ms: 0,
            updated_at_ms: 0,
            refresh: None,
            app_backup: None,
            profile: ImportedProfile {
                name: "Fixture".to_string(),
                format: "clash".to_string(),
                node_count: nodes.len(),
                nodes,
                groups,
                rules,
                userinfo: None,
                source: ImportSource::default(),
                warnings: Vec::new(),
            },
        }
    }

    fn render(record: &StoredProfile, req: &GenerateRequest) -> GeneratedConfig {
        generate_record(record, req).expect("generation should succeed")
    }

    #[test]
    fn generated_config_has_required_keys_and_no_controller() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored(
            vec![
                trojan("t1", "192.0.2.10", 443, 0),
                vless("v1", "192.0.2.11", 8443, 1),
            ],
            Vec::new(),
        );
        let generated = render(&record, &GenerateRequest::default());
        let value: Yaml = serde_yaml::from_str(&generated.yaml).unwrap();

        for key in ["proxies", "proxy-groups", "rules", "dns", "tun"] {
            assert!(value.get(key).is_some(), "missing key `{key}`");
        }
        assert_eq!(value["tun"]["enable"], Yaml::Bool(true));
        assert_eq!(value["tun"]["stack"], Yaml::String("gvisor".to_string()));
        assert_eq!(value["tun"]["mtu"].as_u64(), Some(1500));
        assert!(
            value.get("external-controller").is_none(),
            "control port must never be emitted"
        );
        assert!(value.get("secret").is_none(), "secret must never be emitted");
        assert!(
            value.get("proxy-providers").is_none(),
            "the template is ours; no provider passthrough"
        );
        assert!(
            value["tun"].get("file-descriptor").is_none(),
            "meow RawTun has no file-descriptor field"
        );
        assert!(generated.raw.external_controller.is_none());
        assert!(generated.raw.secret.is_none());
        assert!(generated.raw.proxy_providers.is_none());

        let proxies = value["proxies"].as_sequence().unwrap();
        assert_eq!(proxies.len(), 2);
        let types: Vec<&str> = proxies
            .iter()
            .map(|p| p["type"].as_str().unwrap())
            .collect();
        assert_eq!(types, vec!["trojan", "vless"]);
        assert!(generated.warnings.is_empty(), "{:?}", generated.warnings);
        assert!(!generated.hash.is_empty());
        assert!(crate::rules::current_lines().is_empty());
    }

    #[test]
    fn dns_overlay_is_rendered_but_tun_overlay_has_no_fd() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored(vec![trojan("t1", "192.0.2.10", 443, 0)], Vec::new());
        let req = GenerateRequest {
            stack: Some("mixed".to_string()),
            mtu: Some(1400),
            dns: Some(serde_json::json!({"mode": "redir-host"})),
            rules: Some(vec!["DOMAIN,example.com,PROXY".to_string()]),
            ..GenerateRequest::default()
        };
        let generated = render(&record, &req);
        let value: Yaml = serde_yaml::from_str(&generated.yaml).unwrap();
        assert_eq!(value["dns"]["enhanced-mode"], Yaml::String("redir-host".to_string()));
        assert_eq!(value["tun"]["stack"], Yaml::String("mixed".to_string()));
        assert_eq!(value["tun"]["mtu"].as_u64(), Some(1400));
        assert_eq!(
            value["rules"].as_sequence().unwrap().len(),
            2,
            "explicit overlay has no terminal, so MATCH,PROXY is appended"
        );
        assert_eq!(value["rules"][0], Yaml::String("DOMAIN,example.com,PROXY".to_string()));
        assert_eq!(value["rules"][1], Yaml::String("MATCH,PROXY".to_string()));
    }

    fn rule_lines(value: &Yaml) -> Vec<String> {
        value["rules"]
            .as_sequence()
            .unwrap()
            .iter()
            .map(|r| r.as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn profile_rules_are_emitted_verbatim_with_their_terminal() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored_with_rules(
            vec![trojan("t1", "192.0.2.10", 443, 0)],
            Vec::new(),
            vec![
                "DOMAIN-SUFFIX,example.com,PROXY".to_string(),
                "GEOIP,LAN,DIRECT".to_string(),
                "MATCH,PROXY".to_string(),
            ],
        );
        let generated = render(&record, &GenerateRequest::default());
        let value: Yaml = serde_yaml::from_str(&generated.yaml).unwrap();
        assert_eq!(
            rule_lines(&value),
            vec!["DOMAIN-SUFFIX,example.com,PROXY", "GEOIP,LAN,DIRECT", "MATCH,PROXY"]
        );
    }

    #[test]
    fn profile_without_rules_but_nodes_terminates_in_proxy_not_direct() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored(vec![trojan("t1", "192.0.2.10", 443, 0)], Vec::new());
        let generated = render(&record, &GenerateRequest::default());
        let value: Yaml = serde_yaml::from_str(&generated.yaml).unwrap();
        assert_eq!(rule_lines(&value), vec!["MATCH,PROXY"]);
        assert!(
            !generated.yaml.contains("MATCH,DIRECT"),
            "a profile with nodes must never silently go direct:\n{}",
            generated.yaml
        );
    }

    #[test]
    fn profile_without_nodes_or_rules_terminates_in_direct() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored(Vec::new(), Vec::new());
        let generated = render(&record, &GenerateRequest::default());
        let value: Yaml = serde_yaml::from_str(&generated.yaml).unwrap();
        assert_eq!(rule_lines(&value), vec!["MATCH,DIRECT"]);
    }

    #[test]
    fn explicit_overlay_wins_over_profile_rules_and_gains_a_terminal() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored_with_rules(
            vec![trojan("t1", "192.0.2.10", 443, 0)],
            Vec::new(),
            vec![
                "DOMAIN-SUFFIX,profile.example,PROXY".to_string(),
                "MATCH,PROXY".to_string(),
            ],
        );
        let req = GenerateRequest {
            rules: Some(vec!["DOMAIN,overlay.example,PROXY".to_string()]),
            ..GenerateRequest::default()
        };
        let generated = render(&record, &req);
        let value: Yaml = serde_yaml::from_str(&generated.yaml).unwrap();
        assert_eq!(
            rule_lines(&value),
            vec!["DOMAIN,overlay.example,PROXY", "MATCH,PROXY"]
        );
    }

    #[test]
    fn mtu_below_minimum_is_rejected() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored(vec![trojan("t1", "192.0.2.10", 443, 0)], Vec::new());
        let err = generate_record(
            &record,
            &GenerateRequest {
                mtu: Some(500),
                ..GenerateRequest::default()
            },
        )
        .unwrap_err();
        assert_eq!(err.code, ERR_CONFIG_INVALID);
        assert_eq!(err.status, StatusCode::InvalidArgument);
    }

    #[test]
    fn build_registry_wires_leaves_groups_and_builtins() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored(
            vec![
                trojan("t1", "192.0.2.10", 443, 0),
                vless("v1", "192.0.2.11", 8443, 1),
            ],
            vec![
                ProxyGroup {
                    name: "AUTO".to_string(),
                    group_type: "select".to_string(),
                    members: vec!["t1".to_string(), "v1".to_string()],
                },
                ProxyGroup {
                    name: "PROXY".to_string(),
                    group_type: "select".to_string(),
                    members: vec!["AUTO".to_string(), "t1".to_string()],
                },
            ],
        );
        let generated = render(&record, &GenerateRequest::default());
        let (map, warnings) = build_registry(&generated.raw, None);

        assert!(warnings.is_empty(), "{warnings:?}");
        for name in ["DIRECT", "REJECT", "REJECT-DROP", "t1", "v1", "AUTO", "PROXY", "GLOBAL"] {
            assert!(map.contains_key(name), "registry missing `{name}`");
        }
        let proxy = map.get("PROXY").unwrap();
        assert_eq!(proxy.name(), "PROXY");
        assert_eq!(proxy.current().as_deref(), Some("AUTO"));
        assert_eq!(
            map.get("AUTO").unwrap().current().as_deref(),
            Some("t1")
        );
    }

    #[test]
    fn unsupported_node_is_warned_and_skipped_without_aborting() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored(
            vec![
                trojan("t1", "192.0.2.10", 443, 0),
                node("s1", "snell", "192.0.2.12", 443, 1),
            ],
            Vec::new(),
        );
        let generated = render(&record, &GenerateRequest::default());
        assert!(
            generated
                .warnings
                .iter()
                .any(|w| w.node.as_deref() == Some("s1")),
            "snell must be warned about: {:?}",
            generated.warnings
        );
        let (map, warnings) = build_registry(&generated.raw, None);
        assert!(map.contains_key("t1"), "valid node still builds");
        assert!(map.contains_key("DIRECT"), "fallback survives");
        assert!(
            warnings.iter().any(|w| w.node.as_deref() == Some("s1")),
            "registry must report the skipped node: {warnings:?}"
        );
    }

    #[test]
    fn group_with_reference_to_skipped_node_still_builds() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored(
            vec![
                trojan("t1", "192.0.2.10", 443, 0),
                node("s1", "snell", "192.0.2.12", 443, 1),
            ],
            Vec::new(),
        );
        let generated = render(&record, &GenerateRequest::default());
        let (map, _warnings) = build_registry(&generated.raw, None);
        let proxy = map.get("PROXY").expect("PROXY group must still build");
        assert!(proxy.current().is_some());
    }

    #[test]
    fn hysteria2_node_is_built_into_the_registry() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let record = stored(vec![hysteria2("h1", "192.0.2.12", 443, 0)], Vec::new());
        let generated = render(&record, &GenerateRequest::default());
        assert!(
            !generated
                .warnings
                .iter()
                .any(|w| w.node.as_deref() == Some("h1")),
            "hysteria2 must no longer be reported unsupported: {:?}",
            generated.warnings
        );
        let (map, warnings) = build_registry(&generated.raw, None);
        assert!(
            map.contains_key("h1"),
            "hysteria2 node must build: {warnings:?}"
        );
        assert!(
            !warnings.iter().any(|w| w.node.as_deref() == Some("h1")),
            "hysteria2 node must not warn during registry build: {warnings:?}"
        );
        assert!(map.contains_key("PROXY"), "group over the hy2 node builds");
    }
}
