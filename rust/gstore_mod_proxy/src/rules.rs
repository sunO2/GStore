//! Clash rule engine + routing (Todo 9 of `.omo/plans/vpn-proxy-kernel.md`).
//!
//! This module owns the *orchestration* around meow's rule engine, never a
//! second engine: every rule line is compiled by
//! [`meow_config::rule_parser::parse_one_rule_or_subrule`] (which delegates to
//! `meow_rules::parse_rule`), rule-sets are `meow_rules::RuleSet` values, and
//! the compiled list is published through `meow_tunnel::Tunnel::update_rules`.
//! What lives here is only the Clash-facing policy:
//!
//! * parse `rules:` / `rule-providers:` / `proxy-groups:` from a Clash config
//!   using meow-config's own `raw::RawConfig` schema;
//! * load `inline`/`file` rule-providers eagerly and `http` providers on a
//!   background thread (a `ProviderSlot` is a live `RuleSet` whose inner set is
//!   swapped on completion, so `RULE-SET` rules keep matching the newest
//!   payload without a rebuild);
//! * resolve the required GeoIP/ASN/Geosite assets under `<data_dir>/geo`,
//!   sha256-verifying anything installed and downloading missing assets
//!   asynchronously (startup never blocks on a geo download);
//! * reject a malformed rule line with a structured `PROXY_RULE_INVALID` that
//!   names the line, while every other line still loads.
//!
//! Nothing here builds proxies or groups (Todos 10/13): a rule whose target is
//! not yet in the route table is skipped by meow's own `target_usable`
//! predicate, exactly like mihomo.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use gstore_contract::error::{ModuleError, StatusCode};
use meow_common::{Metadata, Rule, RuleMatchHelper};
use meow_rules::{ParserContext, RuleSet, RuleSetBehavior};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub(crate) const ERR_RULE_INVALID: &str = "PROXY_RULE_INVALID";
pub(crate) const ERR_RULE_PROVIDER: &str = "PROXY_RULE_PROVIDER_FAILED";
pub(crate) const ERR_RULE_GEO: &str = "PROXY_GEO_UNAVAILABLE";

const GEOIP_FILE: &str = "country.mmdb";
const GEOIP_URL: &str =
    "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb";
const ASN_FILE: &str = "GeoLite2-ASN.mmdb";
const ASN_URL: &str =
    "https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download/GeoLite2-ASN.mmdb";
const GEOSITE_FILE: &str = "geosite.dat";
const GEOSITE_URL: &str =
    "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat";

#[derive(Clone, Serialize)]
pub(crate) struct RuleEntry {
    pub index: usize,
    #[serde(rename = "lineNumber")]
    pub line_number: usize,
    pub line: String,
    #[serde(rename = "type")]
    pub rule_type: String,
    pub value: String,
    pub target: String,
    pub source: String,
}

#[derive(Clone, Serialize)]
pub(crate) struct RuleIssue {
    #[serde(rename = "lineNumber")]
    pub line_number: usize,
    pub line: String,
    pub code: String,
    pub message: String,
}

#[derive(Clone, Serialize)]
pub(crate) struct GeoAsset {
    pub kind: String,
    pub file: String,
    pub path: String,
    pub status: String,
    pub verified: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone, Serialize)]
struct ProviderStatus {
    name: String,
    #[serde(rename = "type")]
    provider_type: String,
    behavior: String,
    url: String,
    status: String,
    count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(rename = "updatedAtMs")]
    updated_at_ms: u64,
}

/// A rule-provider exposed as a live [`RuleSet`]. The inner set is empty until
/// the provider loads; swapping it is seen by the very next match, so a
/// `RULE-SET` rule needs no re-parse when its provider finishes.
pub(crate) struct ProviderSlot {
    pub name: String,
    behavior: RuleSetBehavior,
    inner: RwLock<Arc<dyn RuleSet>>,
    status: Mutex<ProviderStatus>,
}

impl ProviderSlot {
    fn new(
        name: String,
        provider_type: String,
        behavior: RuleSetBehavior,
        behavior_str: String,
        url: String,
    ) -> Self {
        let empty = meow_rules::build_rule_set(behavior, &[], &ParserContext::empty());
        Self {
            name: name.clone(),
            behavior,
            inner: RwLock::new(Arc::from(empty)),
            status: Mutex::new(ProviderStatus {
                name,
                provider_type,
                behavior: behavior_str,
                url,
                status: "pending".to_string(),
                count: 0,
                code: None,
                error: None,
                updated_at_ms: 0,
            }),
        }
    }

    fn install(&self, set: Arc<dyn RuleSet>, count: usize, updated_at_secs: u64) {
        *self.inner.write().unwrap_or_else(|e| e.into_inner()) = set;
        let mut status = self.status.lock().unwrap_or_else(|e| e.into_inner());
        status.status = "loaded".to_string();
        status.count = count;
        status.code = None;
        status.error = None;
        status.updated_at_ms = updated_at_secs.saturating_mul(1000);
    }

    fn set_loading(&self) {
        self.status.lock().unwrap_or_else(|e| e.into_inner()).status = "loading".to_string();
    }

    fn fail(&self, message: impl Into<String>) {
        let mut status = self.status.lock().unwrap_or_else(|e| e.into_inner());
        status.status = "failed".to_string();
        status.code = Some(ERR_RULE_PROVIDER.to_string());
        status.error = Some(message.into());
    }

    fn status_json(&self) -> serde_json::Value {
        let status = self.status.lock().unwrap_or_else(|e| e.into_inner());
        serde_json::to_value(&*status).unwrap_or(serde_json::Value::Null)
    }
}

impl RuleSet for ProviderSlot {
    fn behavior(&self) -> RuleSetBehavior {
        self.behavior
    }

    fn matches(&self, metadata: &Metadata, helper: &RuleMatchHelper) -> bool {
        self.inner
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .matches(metadata, helper)
    }

    fn len(&self) -> usize {
        self.inner.read().unwrap_or_else(|e| e.into_inner()).len()
    }

    fn should_resolve_ip(&self) -> bool {
        self.inner
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .should_resolve_ip()
    }

    fn should_find_process(&self) -> bool {
        self.inner
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .should_find_process()
    }

    fn is_empty(&self) -> bool {
        self.inner.read().unwrap_or_else(|e| e.into_inner()).is_empty()
    }

    fn matches_domain(&self, domain: &str) -> bool {
        self.inner
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .matches_domain(domain)
    }
}

#[derive(Clone, Default)]
struct GeoNeeds {
    geoip: HashSet<String>,
    asn: HashSet<u32>,
    geosite: HashSet<String>,
}

struct RulesState {
    revision: u64,
    data_dir: String,
    raw_rules: Vec<String>,
    slots: Vec<Arc<ProviderSlot>>,
    provider_map: HashMap<String, Arc<dyn RuleSet>>,
    groups: Vec<String>,
    parser_ctx: ParserContext,
    geo_needs: GeoNeeds,
    assets: Vec<GeoAsset>,
    entries: Vec<RuleEntry>,
    errors: Vec<RuleIssue>,
    warnings: Vec<RuleIssue>,
    final_target: String,
}

impl Default for RulesState {
    fn default() -> Self {
        Self {
            revision: 0,
            data_dir: String::new(),
            raw_rules: Vec::new(),
            slots: Vec::new(),
            provider_map: HashMap::new(),
            groups: Vec::new(),
            parser_ctx: ParserContext::empty(),
            geo_needs: GeoNeeds::default(),
            assets: Vec::new(),
            entries: Vec::new(),
            errors: Vec::new(),
            warnings: Vec::new(),
            final_target: "DIRECT".to_string(),
        }
    }
}

static STATE: OnceLock<Mutex<RulesState>> = OnceLock::new();
static ACTIVE_TUNNEL: OnceLock<Mutex<Option<Arc<meow_tunnel::Tunnel>>>> = OnceLock::new();

fn state() -> &'static Mutex<RulesState> {
    STATE.get_or_init(|| Mutex::new(RulesState::default()))
}

fn tunnel_cell() -> &'static Mutex<Option<Arc<meow_tunnel::Tunnel>>> {
    ACTIVE_TUNNEL.get_or_init(|| Mutex::new(None))
}

/// The live tunnel, if the engine is running. Todo 10 (`node.*` / `conn.*`)
/// reads the proxy registry and statistics through this handle.
pub(crate) fn active_tunnel() -> Option<Arc<meow_tunnel::Tunnel>> {
    tunnel_cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Store the tunnel and publish the currently-parsed rules into it. Called by
/// `dispatch::build_engine` right after `Tunnel::new`.
pub(crate) fn attach_tunnel(tunnel: meow_tunnel::Tunnel) -> Arc<meow_tunnel::Tunnel> {
    let tunnel = Arc::new(tunnel);
    let compiled = {
        let st = state().lock().unwrap_or_else(|e| e.into_inner());
        compile(&st).rules
    };
    tunnel.update_rules(compiled);
    *tunnel_cell().lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&tunnel));
    tunnel
}

/// Drop the tunnel handle on teardown (`dispatch::Dispatcher::shutdown`).
pub(crate) fn detach_tunnel() {
    *tunnel_cell().lock().unwrap_or_else(|e| e.into_inner()) = None;
}

#[cfg(test)]
pub(crate) fn reset_for_tests() {
    *state().lock().unwrap_or_else(|e| e.into_inner()) = RulesState::default();
    detach_tunnel();
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ReloadRequest {
    #[serde(default)]
    config: Option<String>,
    #[serde(default)]
    config_path: Option<String>,
    #[serde(default)]
    geo: Option<GeoRequest>,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase")]
struct GeoRequest {
    #[serde(default)]
    bundle_dir: Option<String>,
    #[serde(default)]
    download: Option<bool>,
    #[serde(default)]
    assets: HashMap<String, GeoAssetRequest>,
    #[serde(default)]
    urls: HashMap<String, String>,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase")]
struct GeoAssetRequest {
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    sha256: Option<String>,
}

struct PendingDownload {
    file: String,
    url: String,
    sha256: String,
    dest: PathBuf,
}

struct CompiledRules {
    rules: Vec<Box<dyn Rule>>,
    entries: Vec<RuleEntry>,
    errors: Vec<RuleIssue>,
    warnings: Vec<RuleIssue>,
    final_target: String,
}

/// `rules.reload`: parse a Clash config, load providers/geo lazily and publish
/// the compiled ruleset. Returns the same snapshot as `rules.get`.
pub(crate) fn reload(
    data_dir: &str,
    cache_dir: &str,
    payload: &[u8],
) -> Result<serde_json::Value, ModuleError> {
    let req: ReloadRequest = if payload.is_empty() {
        ReloadRequest::default()
    } else {
        serde_json::from_slice(payload).map_err(|e| {
            ModuleError::new(
                StatusCode::InvalidArgument,
                ERR_RULE_INVALID,
                format!("rules.reload payload must be a JSON object: {e}"),
            )
        })?
    };

    let yaml = match (&req.config, &req.config_path) {
        (Some(config), _) => config.clone(),
        (None, Some(path)) => std::fs::read_to_string(path).map_err(|e| {
            ModuleError::new(
                StatusCode::InvalidArgument,
                ERR_RULE_INVALID,
                format!("rules.reload cannot read configPath '{path}': {e}"),
            )
        })?,
        (None, None) => {
            return Err(ModuleError::new(
                StatusCode::InvalidArgument,
                ERR_RULE_INVALID,
                "rules.reload requires `config` (YAML string) or `configPath`",
            ));
        }
    };

    let raw = parse_raw_config(&yaml).map_err(|e| {
        ModuleError::new(
            StatusCode::InvalidArgument,
            ERR_RULE_INVALID,
            format!("Clash config parse failed: {e}"),
        )
    })?;

    let raw_rules = raw.rules.clone().unwrap_or_default();
    let raw_providers = raw.rule_providers.clone().unwrap_or_default();
    let groups: Vec<String> = raw
        .proxy_groups
        .as_ref()
        .map(|groups| groups.iter().map(|g| g.name.clone()).collect())
        .unwrap_or_default();

    let needs = scan_geo_needs(&raw_rules, &raw_providers);
    let (parser_ctx, assets, pending) = build_geo(data_dir, cache_dir, req.geo.as_ref(), &needs);
    let provider_cache = if cache_dir.is_empty() {
        data_dir.to_string()
    } else {
        cache_dir.to_string()
    };
    let (slots, provider_map, deferred) =
        build_provider_slots(&raw_providers, &provider_cache, &parser_ctx);

    {
        let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
        st.data_dir = data_dir.to_string();
        st.raw_rules = raw_rules;
        st.slots = slots;
        st.provider_map = provider_map;
        st.groups = groups;
        st.parser_ctx = parser_ctx.clone();
        st.geo_needs = needs;
        st.assets = assets;
        st.revision += 1;
    }

    recompute_and_apply();
    spawn_provider_loads(deferred, provider_cache, parser_ctx);
    spawn_geo_downloads(pending);

    let count = state()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .entries
        .len();
    crate::log_message(1, &format!("proxy: rules.reload compiled {count} rules"));
    Ok(snapshot())
}

/// `rules.get`: read-only snapshot of the parsed rules, provider statuses and
/// geo asset status.
pub(crate) fn snapshot() -> serde_json::Value {
    let st = state().lock().unwrap_or_else(|e| e.into_inner());
    serde_json::json!({
        "rules": &st.entries,
        "final": st.final_target,
        "count": st.entries.len(),
        "revision": st.revision,
        "providers": st.slots.iter().map(|s| s.status_json()).collect::<Vec<_>>(),
        "groups": &st.groups,
        "geo": {
            "status": geo_overall(&st.assets),
            "assets": &st.assets,
        },
        "errors": &st.errors,
        "warnings": &st.warnings,
    })
}

fn parse_raw_config(yaml: &str) -> Result<meow_config::raw::RawConfig, String> {
    let mut value: serde_yaml::Value = serde_yaml::from_str(yaml).map_err(|e| e.to_string())?;
    value.apply_merge().map_err(|e| e.to_string())?;
    serde_yaml::from_value(value).map_err(|e| e.to_string())
}

fn recompute_and_apply() {
    let compiled = {
        let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
        let compiled = compile(&st);
        st.entries = compiled.entries;
        st.errors = compiled.errors;
        st.warnings = compiled.warnings;
        st.final_target = compiled.final_target;
        compiled.rules
    };
    if let Some(tunnel) = active_tunnel() {
        tunnel.update_rules(compiled);
    }
}

fn compile(st: &RulesState) -> CompiledRules {
    let sub_rules: meow_config::sub_rules_parser::SubRuleBlocks = HashMap::new();
    let mut out = CompiledRules {
        rules: Vec::new(),
        entries: Vec::new(),
        errors: Vec::new(),
        warnings: Vec::new(),
        final_target: String::new(),
    };

    for (i, raw) in st.raw_rules.iter().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        match meow_config::rule_parser::parse_one_rule_or_subrule(
            line,
            &st.provider_map,
            &st.parser_ctx,
            &sub_rules,
        ) {
            Ok(rule) => {
                let rule_type = rule.rule_type().as_str().to_string();
                out.entries.push(RuleEntry {
                    index: out.entries.len(),
                    line_number: i + 1,
                    line: line.to_string(),
                    rule_type: rule_type.clone(),
                    value: rule.payload().to_string(),
                    target: rule.adapter().to_string(),
                    source: "config".to_string(),
                });
                if rule_type == "MATCH" {
                    out.final_target = rule.adapter().to_string();
                }
                out.rules.push(rule);
            }
            Err(message) => out.errors.push(RuleIssue {
                line_number: i + 1,
                line: line.to_string(),
                code: classify_rule_error(&message).to_string(),
                message,
            }),
        }
    }

    if out.final_target.is_empty() {
        out.final_target = "DIRECT".to_string();
    }
    out
}

fn classify_rule_error(message: &str) -> &'static str {
    let lower = message.to_ascii_lowercase();
    if lower.contains("geoip database")
        || lower.contains("asn database")
        || lower.contains("geosite")
    {
        ERR_RULE_GEO
    } else {
        ERR_RULE_INVALID
    }
}

fn scan_geo_needs(
    lines: &[String],
    providers: &HashMap<String, meow_config::raw::RawRuleProvider>,
) -> GeoNeeds {
    let mut needs = GeoNeeds::default();
    let mut all: Vec<&String> = lines.iter().collect();
    for cfg in providers.values() {
        if let Some(payload) = &cfg.payload {
            all.extend(payload.iter());
        }
    }
    for raw in all {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.splitn(4, ',');
        let rule_type = parts.next().unwrap_or("").trim().to_ascii_uppercase();
        let payload = parts.next().unwrap_or("").trim();
        match rule_type.as_str() {
            "GEOIP" | "SRC-GEOIP" => {
                if !payload.is_empty() {
                    needs.geoip.insert(payload.to_ascii_uppercase());
                }
            }
            "IP-ASN" | "SRC-IP-ASN" => {
                if let Ok(asn) = payload.parse::<u32>() {
                    needs.asn.insert(asn);
                }
            }
            "GEOSITE" => {
                let category = payload.split('@').next().unwrap_or("").trim();
                if !category.is_empty() {
                    needs.geosite.insert(category.to_ascii_lowercase());
                }
            }
            _ => {}
        }
    }
    needs
}

fn build_provider_slots(
    raw: &HashMap<String, meow_config::raw::RawRuleProvider>,
    provider_cache: &str,
    ctx: &ParserContext,
) -> (
    Vec<Arc<ProviderSlot>>,
    HashMap<String, Arc<dyn RuleSet>>,
    Vec<(Arc<ProviderSlot>, meow_config::raw::RawRuleProvider)>,
) {
    let mut names: Vec<&String> = raw.keys().collect();
    names.sort();

    let mut fast = HashMap::new();
    for (name, cfg) in raw {
        if cfg.provider_type != "http" {
            fast.insert(name.clone(), cfg.clone());
        }
    }
    let cache = (!provider_cache.is_empty()).then(|| Path::new(provider_cache));
    let loaded = meow_config::rule_provider::load_providers(&fast, cache, ctx, None);

    let mut slots = Vec::with_capacity(names.len());
    let mut provider_map: HashMap<String, Arc<dyn RuleSet>> = HashMap::new();
    let mut deferred = Vec::new();

    for name in names {
        let cfg = &raw[name];
        let behavior = cfg
            .behavior
            .parse::<RuleSetBehavior>()
            .unwrap_or(RuleSetBehavior::Domain);
        let slot = Arc::new(ProviderSlot::new(
            name.clone(),
            cfg.provider_type.clone(),
            behavior,
            cfg.behavior.clone(),
            cfg.url.clone().unwrap_or_default(),
        ));

        if cfg.provider_type == "http" {
            slot.set_loading();
            deferred.push((Arc::clone(&slot), cfg.clone()));
        } else if let Some(provider) = loaded.get(name) {
            let set: Arc<dyn RuleSet> = Arc::clone(provider) as Arc<dyn RuleSet>;
            slot.install(set, provider.rule_count(), provider.updated_at_secs());
        } else {
            slot.fail("rule-provider failed to load (see module logs)");
        }

        provider_map.insert(name.clone(), Arc::clone(&slot) as Arc<dyn RuleSet>);
        slots.push(slot);
    }

    (slots, provider_map, deferred)
}

fn spawn_provider_loads(
    deferred: Vec<(Arc<ProviderSlot>, meow_config::raw::RawRuleProvider)>,
    provider_cache: String,
    ctx: ParserContext,
) {
    if deferred.is_empty() {
        return;
    }
    std::thread::spawn(move || {
        let mut map = HashMap::new();
        for (slot, cfg) in &deferred {
            map.insert(slot.name.clone(), cfg.clone());
        }
        let cache = (!provider_cache.is_empty()).then(|| Path::new(provider_cache.as_str()));
        let loaded = meow_config::rule_provider::load_providers(&map, cache, &ctx, None);
        for (slot, _) in &deferred {
            match loaded.get(&slot.name) {
                Some(provider) => {
                    let set: Arc<dyn RuleSet> = Arc::clone(provider) as Arc<dyn RuleSet>;
                    slot.install(set, provider.rule_count(), provider.updated_at_secs());
                }
                None => slot.fail("rule-provider failed to load (see module logs)"),
            }
        }
        crate::log_message(1, "proxy: http rule-providers loaded");
        recompute_and_apply();
    });
}

fn geo_dir(data_dir: &str, cache_dir: &str) -> Option<PathBuf> {
    let base = if !data_dir.is_empty() {
        data_dir
    } else if !cache_dir.is_empty() {
        cache_dir
    } else {
        return None;
    };
    let dir = Path::new(base).join("geo");
    let _ = std::fs::create_dir_all(&dir);
    Some(dir)
}

fn build_geo(
    data_dir: &str,
    cache_dir: &str,
    request: Option<&GeoRequest>,
    needs: &GeoNeeds,
) -> (ParserContext, Vec<GeoAsset>, Vec<PendingDownload>) {
    let request = request.cloned().unwrap_or_default();
    let download_enabled = request.download.unwrap_or(true);
    let dir = geo_dir(data_dir, cache_dir);

    let mut ctx = ParserContext::empty();
    let mut assets = Vec::new();
    let mut pending = Vec::new();

    let kinds = [
        ("geoip", GEOIP_FILE, GEOIP_URL, !needs.geoip.is_empty()),
        ("asn", ASN_FILE, ASN_URL, !needs.asn.is_empty()),
        (
            "geosite",
            GEOSITE_FILE,
            GEOSITE_URL,
            !needs.geosite.is_empty(),
        ),
    ];

    for (kind, file, default_url, needed) in kinds {
        if !needed {
            continue;
        }
        let (asset, download) = prepare_asset(
            kind,
            file,
            default_url,
            &request,
            dir.as_deref(),
            download_enabled,
            needs,
            &mut ctx,
        );
        assets.push(asset);
        if let Some(download) = download {
            pending.push(download);
        }
    }

    (ctx, assets, pending)
}

#[allow(clippy::too_many_arguments)]
fn prepare_asset(
    kind: &str,
    file: &str,
    default_url: &str,
    request: &GeoRequest,
    dir: Option<&Path>,
    download_enabled: bool,
    needs: &GeoNeeds,
    ctx: &mut ParserContext,
) -> (GeoAsset, Option<PendingDownload>) {
    let sha = request
        .assets
        .get(file)
        .and_then(|asset| asset.sha256.clone())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let url = request
        .assets
        .get(file)
        .and_then(|asset| asset.url.clone())
        .or_else(|| request.urls.get(file).cloned())
        .unwrap_or_else(|| default_url.to_string());

    let dest = dir.map(|d| d.join(file));
    let mut asset = GeoAsset {
        kind: kind.to_string(),
        file: file.to_string(),
        path: dest
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_default(),
        status: "missing".to_string(),
        verified: false,
        sha256: sha.clone(),
        error: None,
    };

    let bundled = request
        .bundle_dir
        .as_ref()
        .map(|base| Path::new(base).join(file))
        .filter(|path| path.exists());
    let source = bundled
        .clone()
        .or_else(|| dest.as_ref().filter(|path| path.exists()).cloned());

    let Some(source) = source else {
        if !download_enabled {
            return (asset, None);
        }
        return match (sha, dest) {
            (Some(sha256), Some(dest)) => {
                asset.status = "downloading".to_string();
                (
                    asset,
                    Some(PendingDownload {
                        file: file.to_string(),
                        url,
                        sha256,
                        dest,
                    }),
                )
            }
            (None, _) => {
                asset.status = "checksum_required".to_string();
                asset.error =
                    Some("refusing to download a geo asset without a sha256 checksum".to_string());
                (asset, None)
            }
            (Some(_), None) => {
                asset.error = Some("no writable module data directory for geo assets".to_string());
                (asset, None)
            }
        };
    };

    if let Some(expected) = &sha {
        match verify_file(&source, expected) {
            Ok(true) => asset.verified = true,
            Ok(false) => {
                asset.status = "checksum_mismatch".to_string();
                asset.error = Some(format!(
                    "sha256 mismatch for {} (expected {expected})",
                    source.display()
                ));
                return (asset, None);
            }
            Err(error) => {
                asset.status = "failed".to_string();
                asset.error = Some(error);
                return (asset, None);
            }
        }
    }

    if let (Some(dest), true) = (dest.as_ref(), bundled.is_some()) {
        if !dest.exists() {
            if let Some(parent) = dest.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if let Err(error) = std::fs::copy(&source, dest) {
                asset.status = "failed".to_string();
                asset.error = Some(format!("copy bundled geo asset: {error}"));
                return (asset, None);
            }
        }
    }

    match load_geo_asset(kind, &source, needs, ctx) {
        Ok(()) => {
            asset.status = "ready".to_string();
            asset.path = source.display().to_string();
        }
        Err(error) => {
            asset.status = "failed".to_string();
            asset.error = Some(error);
        }
    }
    (asset, None)
}

fn load_geo_asset(
    kind: &str,
    path: &Path,
    needs: &GeoNeeds,
    ctx: &mut ParserContext,
) -> Result<(), String> {
    match kind {
        "geoip" => {
            let reader = open_mmdb(path, "GeoIP")?;
            let index = meow_rules::country_index::CountryIndex::build(&reader, &needs.geoip)
                .map_err(|e| format!("build GeoIP country index: {e}"))?;
            ctx.geoip = Some(Arc::new(index));
            Ok(())
        }
        "asn" => {
            let reader = open_mmdb(path, "GeoLite2-ASN")?;
            let index = meow_rules::asn_index::AsnIndex::build(&reader, &needs.asn)
                .map_err(|e| format!("build ASN index: {e}"))?;
            ctx.asn = Some(Arc::new(index));
            Ok(())
        }
        "geosite" => {
            let db = meow_rules::geosite::GeositeDB::load_from_path(path, Some(&needs.geosite))
                .map_err(|e| format!("load geosite database: {e}"))?;
            ctx.geosite = Some(Arc::new(db));
            Ok(())
        }
        other => Err(format!("unknown geo asset kind '{other}'")),
    }
}

fn open_mmdb(path: &Path, kind: &str) -> Result<maxminddb::Reader<maxminddb::Mmap>, String> {
    // Safety: the file is opened read-only and mmap-backed; we drop the reader
    // after building the in-memory range index, so no page outlives the file.
    unsafe { maxminddb::Reader::open_mmap(path) }
        .map_err(|e| format!("open {kind} database {}: {e}", path.display()))
}

fn load_ctx_from_assets(assets: &[GeoAsset], needs: &GeoNeeds) -> ParserContext {
    let mut ctx = ParserContext::empty();
    for asset in assets.iter().filter(|a| a.status == "ready") {
        if let Err(error) = load_geo_asset(&asset.kind, Path::new(&asset.path), needs, &mut ctx) {
            crate::log_message(
                3,
                &format!("proxy: geo asset '{}' load failed: {error}", asset.file),
            );
        }
    }
    ctx
}

fn spawn_geo_downloads(pending: Vec<PendingDownload>) {
    if pending.is_empty() {
        return;
    }
    std::thread::spawn(move || {
        for download in pending {
            let outcome = download_verified(&download);
            let mut st = state().lock().unwrap_or_else(|e| e.into_inner());
            if let Some(asset) = st.assets.iter_mut().find(|a| a.file == download.file) {
                match &outcome {
                    Ok(()) => {
                        asset.status = "ready".to_string();
                        asset.verified = true;
                        asset.error = None;
                    }
                    Err(error) => {
                        asset.status = "failed".to_string();
                        asset.error = Some(error.clone());
                    }
                }
            }
            let needs = st.geo_needs.clone();
            let assets = st.assets.clone();
            st.parser_ctx = load_ctx_from_assets(&assets, &needs);
            drop(st);
            recompute_and_apply();
        }
        crate::log_message(1, "proxy: geo assets resolved");
    });
}

fn download_verified(download: &PendingDownload) -> Result<(), String> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("geo download runtime: {e}"))?;
    let bytes = runtime
        .block_on(meow_config::internal_http::fetch(&download.url, None, &[]))
        .map_err(|e| format!("fetch {}: {e}", download.url))?;

    let actual = sha256_hex(&bytes);
    if !actual.eq_ignore_ascii_case(download.sha256.trim()) {
        return Err(format!(
            "sha256 mismatch for {}: expected {}, got {actual}",
            download.file, download.sha256
        ));
    }

    if let Some(parent) = download.dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    let tmp = download.dest.with_extension("tmp");
    std::fs::write(&tmp, &bytes).map_err(|e| format!("write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &download.dest)
        .map_err(|e| format!("rename {}: {e}", download.dest.display()))?;
    Ok(())
}

fn verify_file(path: &Path, expected: &str) -> Result<bool, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    Ok(sha256_hex(&bytes).eq_ignore_ascii_case(expected.trim()))
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

fn geo_overall(assets: &[GeoAsset]) -> &'static str {
    if assets.is_empty() {
        "idle"
    } else if assets.iter().any(|a| a.status == "downloading") {
        "downloading"
    } else if assets.iter().any(|a| {
        matches!(
            a.status.as_str(),
            "failed" | "checksum_mismatch" | "checksum_required"
        )
    }) {
        "failed"
    } else if assets
        .iter()
        .all(|a| a.status == "ready" || a.status == "unverified")
    {
        "ready"
    } else {
        "missing"
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use meow_common::{AdapterType, ConnType, DelayHistory, MeowError, Network, Proxy, ProxyAdapter,
        ProxyConn, ProxyHealth, ProxyPacketConn, Result as MeowResult};
    use smol_str::SmolStr;
    use std::io::{Read, Write};
    use std::sync::atomic::{AtomicU16, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::TEST_SERIAL as SERIAL;

    struct NamedProxy {
        name: String,
        health: ProxyHealth,
    }

    impl NamedProxy {
        fn new(name: &str) -> Self {
            Self {
                name: name.to_string(),
                health: ProxyHealth::new(),
            }
        }
    }

    #[async_trait::async_trait]
    impl ProxyAdapter for NamedProxy {
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

        async fn dial_tcp(&self, _metadata: &Metadata) -> MeowResult<Box<dyn ProxyConn>> {
            Err(MeowError::NotSupported("test proxy".into()))
        }

        async fn dial_udp(&self, _metadata: &Metadata) -> MeowResult<Box<dyn ProxyPacketConn>> {
            Err(MeowError::NotSupported("test proxy".into()))
        }

        fn health(&self) -> &ProxyHealth {
            &self.health
        }
    }

    impl Proxy for NamedProxy {
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

    const FIXTURE: &str = r#"
proxies:
  - {name: PROXY, type: direct}
proxy-groups:
  - name: PROXY
    type: select
    proxies: [DIRECT]
rule-providers:
  inline-domains:
    type: inline
    behavior: domain
    payload:
      - "fixture.example"
      - "+.rules.example"
  inline-cidr:
    type: inline
    behavior: ipcidr
    payload:
      - "10.0.0.0/8"
rules:
  - DOMAIN-SUFFIX,fixture.example,PROXY
  - DOMAIN,exact.example,DIRECT
  - DOMAIN-KEYWORD,keyword,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - DST-PORT,8080,DIRECT
  - PROCESS-NAME,curl,DIRECT
  - RULE-SET,inline-domains,PROXY
  - RULE-SET,inline-cidr,DIRECT
  - MATCH,DIRECT
"#;

    fn tmp_dir(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        static SEQ: AtomicU16 = AtomicU16::new(0);
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("gstore-rules-{tag}-{nanos}-{seq}"));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn reload_fixture(dir: &Path, yaml: &str, geo: Option<serde_json::Value>) -> serde_json::Value {
        let mut payload = serde_json::json!({ "config": yaml });
        if let Some(geo) = geo {
            payload["geo"] = geo;
        }
        reload(
            dir.to_str().unwrap(),
            dir.to_str().unwrap(),
            serde_json::to_vec(&payload).unwrap().as_slice(),
        )
        .expect("reload should succeed")
    }

    fn compiled() -> Vec<Box<dyn Rule>> {
        let st = state().lock().unwrap();
        compile(&st).rules
    }

    fn metadata(host: &str, port: u16) -> Metadata {
        Metadata {
            network: Network::Tcp,
            conn_type: ConnType::Tun,
            host: host.into(),
            dst_port: port,
            ..Default::default()
        }
    }

    fn index_of(rule_type: &str, value: &str) -> usize {
        let st = state().lock().unwrap();
        let compiled = compile(&st);
        compiled
            .entries
            .iter()
            .position(|e| e.rule_type == rule_type && e.value == value)
            .unwrap_or_else(|| panic!("no rule {rule_type},{value}"))
    }

    #[test]
    fn parses_fixture_in_order_and_returns_it_from_rules_get() {
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let dir = tmp_dir("order");
        let snap = reload_fixture(&dir, FIXTURE, None);

        let rules = snap["rules"].as_array().unwrap();
        let types: Vec<&str> = rules
            .iter()
            .map(|r| r["type"].as_str().unwrap())
            .collect();
        assert_eq!(
            types,
            vec![
                "DOMAIN-SUFFIX",
                "DOMAIN",
                "DOMAIN-KEYWORD",
                "IP-CIDR",
                "DST-PORT",
                "PROCESS-NAME",
                "RULE-SET",
                "RULE-SET",
                "MATCH",
            ]
        );
        assert_eq!(rules[0]["index"], 0);
        assert_eq!(rules[0]["lineNumber"], 1);
        assert_eq!(rules[0]["value"], "fixture.example");
        assert_eq!(rules[0]["target"], "PROXY");
        assert_eq!(rules[8]["type"], "MATCH");
        assert_eq!(snap["final"], "DIRECT");
        assert_eq!(snap["count"], 9);
        assert!(snap["errors"].as_array().unwrap().is_empty());

        let providers = snap["providers"].as_array().unwrap();
        assert_eq!(providers.len(), 2);
        assert!(providers.iter().all(|p| p["status"] == "loaded"));
        assert!(providers.iter().all(|p| p["count"].as_u64().unwrap() > 0));
    }

    #[test]
    fn matches_each_supported_rule_type() {
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let dir = tmp_dir("match");
        reload_fixture(&dir, FIXTURE, None);
        let rules = compiled();
        let helper = RuleMatchHelper;

        let suffix = index_of("DOMAIN-SUFFIX", "fixture.example");
        assert!(rules[suffix].match_metadata(&metadata("www.fixture.example", 443), &helper));
        assert!(rules[suffix].match_metadata(&metadata("fixture.example", 443), &helper));

        let domain = index_of("DOMAIN", "exact.example");
        assert!(rules[domain].match_metadata(&metadata("exact.example", 80), &helper));
        assert!(!rules[domain].match_metadata(&metadata("sub.exact.example", 80), &helper));

        let keyword = index_of("DOMAIN-KEYWORD", "keyword");
        assert!(rules[keyword].match_metadata(&metadata("a-keyword-b.example", 80), &helper));

        let ip = index_of("IP-CIDR", "192.168.0.0/16");
        let mut ip_meta = metadata("", 80);
        ip_meta.dst_ip = Some("192.168.5.5".parse().unwrap());
        assert!(rules[ip].match_metadata(&ip_meta, &helper));

        let port = index_of("DST-PORT", "8080");
        assert!(rules[port].match_metadata(&metadata("any.example", 8080), &helper));
        assert!(!rules[port].match_metadata(&metadata("any.example", 443), &helper));

        let process = index_of("PROCESS-NAME", "curl");
        let mut proc_meta = metadata("any.example", 443);
        proc_meta.process = "curl".into();
        assert!(rules[process].match_metadata(&proc_meta, &helper));

        let domains = index_of("RULE-SET", "inline-domains");
        assert!(rules[domains].match_metadata(&metadata("a.rules.example", 443), &helper));
        assert!(rules[domains].match_metadata(&metadata("fixture.example", 443), &helper));

        let cidr = index_of("RULE-SET", "inline-cidr");
        let mut cidr_meta = metadata("", 80);
        cidr_meta.dst_ip = Some("10.1.2.3".parse().unwrap());
        assert!(rules[cidr].match_metadata(&cidr_meta, &helper));

        let matcher = {
            let st = state().lock().unwrap();
            let compiled = compile(&st);
            compiled
                .entries
                .iter()
                .position(|e| e.rule_type == "MATCH")
                .expect("fixture has a MATCH rule")
        };
        assert!(rules[matcher].match_metadata(&metadata("random.example", 1234), &helper));
    }

    #[test]
    fn domain_suffix_fixture_routes_to_expected_outbound() {
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let dir = tmp_dir("route");
        reload_fixture(&dir, FIXTURE, None);

        let resolver = Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ));
        let tunnel = meow_tunnel::Tunnel::new(resolver);
        let mut proxies: HashMap<SmolStr, Arc<dyn Proxy>> = HashMap::new();
        proxies.insert(
            SmolStr::from("PROXY"),
            Arc::new(NamedProxy::new("PROXY")) as Arc<dyn Proxy>,
        );
        tunnel.update_proxies(proxies);
        tunnel.update_rules(compiled());

        let (outbound, rule, payload) = tunnel
            .inner()
            .resolve_proxy(&metadata("www.fixture.example", 443))
            .expect("rule mode always resolves");
        assert_eq!(outbound.name(), "PROXY");
        assert_eq!(&*rule, "DOMAIN-SUFFIX");
        assert_eq!(&*payload, "fixture.example");
    }

    #[test]
    fn malformed_rule_is_rejected_but_the_rest_loads() {
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let dir = tmp_dir("malformed");
        let yaml = "rules:\n  - DOMAIN-SUFFIX,ok.example,DIRECT\n  - \
                    BOGUS-TYPE,x,DIRECT\n  - DOMAIN,after.example,DIRECT\n";
        let snap = reload_fixture(&dir, yaml, None);

        assert_eq!(snap["rules"].as_array().unwrap().len(), 2);
        let errors = snap["errors"].as_array().unwrap();
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0]["code"], "PROXY_RULE_INVALID");
        assert_eq!(errors[0]["lineNumber"], 2);
        assert_eq!(errors[0]["line"], "BOGUS-TYPE,x,DIRECT");
        assert!(errors[0]["message"]
            .as_str()
            .unwrap()
            .contains("BOGUS-TYPE"));

        let st = state().lock().unwrap();
        assert_eq!(compile(&st).rules.len(), 2);
    }

    #[test]
    fn file_classical_provider_resolves_rule_set() {
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let dir = tmp_dir("classical");
        let provider = dir.join("classical.yaml");
        std::fs::write(&provider, "payload:\n  - DOMAIN,classical.example\n").unwrap();
        let yaml = format!(
            "rule-providers:\n  cls:\n    type: file\n    behavior: classical\n    path: {}\n\
             rules:\n  - RULE-SET,cls,DIRECT\n",
            provider.display()
        );
        let snap = reload_fixture(&dir, &yaml, None);
        assert_eq!(snap["rules"].as_array().unwrap().len(), 1);
        assert_eq!(snap["providers"][0]["status"], "loaded");

        let rules = compiled();
        let helper = RuleMatchHelper;
        assert!(rules[0].match_metadata(&metadata("classical.example", 443), &helper));
    }

    #[test]
    fn geosite_rule_matches_with_supplied_database() {
        let mut categories = HashMap::new();
        let mut trie = meow_trie::DomainTrie::new();
        trie.insert("synthetic.example", ());
        trie.seal();
        categories.insert("synthetic".to_string(), trie);
        let db = meow_rules::geosite::GeositeDB::from_parts(
            categories,
            HashMap::from([("synthetic".to_string(), 1)]),
            HashMap::new(),
            HashMap::new(),
        );
        let ctx = ParserContext {
            geosite: Some(Arc::new(db)),
            ..ParserContext::empty()
        };
        let rule = meow_rules::parse_rule("GEOSITE,synthetic,DIRECT", &ctx).unwrap();
        assert_eq!(rule.adapter(), "DIRECT");
        assert!(rule.match_metadata(&metadata("synthetic.example", 443), &RuleMatchHelper));
    }

    #[test]
    fn missing_geo_rule_is_reported_and_rest_loads_without_blocking() {
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let dir = tmp_dir("geo-missing");
        let yaml = "rules:\n  - GEOIP,CN,DIRECT\n  - DOMAIN,ok.example,DIRECT\n";
        let snap = reload_fixture(&dir, yaml, Some(serde_json::json!({ "download": false })));

        assert_eq!(snap["rules"].as_array().unwrap().len(), 1);
        assert_eq!(snap["rules"][0]["value"], "ok.example");
        let errors = snap["errors"].as_array().unwrap();
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0]["code"], "PROXY_GEO_UNAVAILABLE");
        assert_eq!(errors[0]["lineNumber"], 1);

        assert_eq!(snap["geo"]["status"], "missing");
        assert_eq!(snap["geo"]["assets"][0]["kind"], "geoip");
        assert_eq!(snap["geo"]["assets"][0]["file"], "country.mmdb");
        assert_eq!(snap["geo"]["assets"][0]["status"], "missing");
    }

    #[test]
    fn geo_checksum_missing_is_refused_without_download() {
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let dir = tmp_dir("geo-checksum-required");
        let yaml = "rules:\n  - GEOIP,CN,DIRECT\n  - DOMAIN,ok.example,DIRECT\n";
        let snap = reload_fixture(&dir, yaml, None);
        assert_eq!(snap["geo"]["assets"][0]["status"], "checksum_required");
        assert_eq!(snap["geo"]["status"], "failed");
        assert_eq!(snap["rules"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn geo_checksum_mismatch_rejects_asset_but_rest_loads() {
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let dir = tmp_dir("geo-checksum-mismatch");
        let geo_dir = dir.join("geo");
        std::fs::create_dir_all(&geo_dir).unwrap();
        std::fs::write(geo_dir.join("country.mmdb"), b"not-a-real-mmdb").unwrap();

        let yaml = "rules:\n  - GEOIP,CN,DIRECT\n  - DOMAIN,ok.example,DIRECT\n";
        let geo = serde_json::json!({
            "download": false,
            "assets": { "country.mmdb": { "sha256": sha256_hex(b"something-else") } }
        });
        let snap = reload_fixture(&dir, yaml, Some(geo));

        assert_eq!(snap["geo"]["assets"][0]["status"], "checksum_mismatch");
        assert_eq!(snap["geo"]["assets"][0]["verified"], false);
        assert_eq!(snap["rules"].as_array().unwrap().len(), 1);
        assert_eq!(snap["errors"][0]["code"], "PROXY_GEO_UNAVAILABLE");
    }

    #[test]
    fn sha256_hex_matches_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn geo_download_verifies_checksum_and_installs_asset() {
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let dir = tmp_dir("geo-download");

        let body = b"geo-asset-bytes".to_vec();
        let expected = sha256_hex(&body);
        let served = body.clone();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    served.len()
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.write_all(&served);
                let _ = stream.flush();
            }
        });

        let yaml = "rules:\n  - GEOIP,CN,DIRECT\n  - DOMAIN,ok.example,DIRECT\n";
        let geo = serde_json::json!({
            "download": true,
            "assets": {
                "country.mmdb": {
                    "url": format!("http://{addr}/country.mmdb"),
                    "sha256": expected,
                }
            }
        });
        let snap = reload_fixture(&dir, yaml, Some(geo));
        assert_eq!(snap["geo"]["assets"][0]["status"], "downloading");
        assert_eq!(snap["rules"].as_array().unwrap().len(), 1);

        let installed = dir.join("geo").join("country.mmdb");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            if installed.exists() {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "geo asset was not installed in time"
            );
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        server.join().unwrap();
        assert_eq!(std::fs::read(&installed).unwrap(), body);

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let status = state().lock().unwrap().assets[0].status.clone();
            if status == "ready" {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "geo asset status stayed {status}"
            );
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        let st = state().lock().unwrap();
        assert!(st.assets[0].verified);
        assert_eq!(st.assets[0].status, "ready");
    }

    #[test]
    fn snapshot_without_reload_is_empty_and_non_panicking() {
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let snap = snapshot();
        assert_eq!(snap["count"], 0);
        assert_eq!(snap["final"], "DIRECT");
        assert!(snap["rules"].as_array().unwrap().is_empty());
        assert!(snap["geo"]["assets"].as_array().unwrap().is_empty());
    }
}
