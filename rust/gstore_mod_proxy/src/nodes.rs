//! Node/group selection and latency tests (Todo 10 of the proxy kernel plan).
//!
//! meow owns the group machinery: `meow_proxy::{SelectorGroup, UrlTestGroup,
//! FallbackGroup}` implement `Proxy`/`ProxySelection`, and `meow_tunnel::Tunnel`
//! keeps the live `name -> Arc<dyn Proxy>` registry in `RouteTable.proxies`.
//! This module only:
//!
//! * resolves a group and applies a selection through `ProxySelection::set`
//!   (selector / url-test / fallback), so the choice is meow's state;
//! * runs HTTP HEAD delay probes with `meow_proxy::health` on a **separate
//!   bounded runtime**, never the tunnel loop, and turns every unreachable node
//!   into a per-node `timeout` result (never a top-level error or a panic);
//! * persists selector/url-test/fallback choices through meow's
//!   `SelectorStore`, the same JSON side-channel meow-config wires into rebuilt
//!   groups (`rebuild_from_raw_runtime` reads `SelectorStore::global()`).
//!
//! Proxies/groups are attached by Todo 13's config generator (see
//! [`install_proxies`]); until then the registry is empty and `node.*` reports a
//! structured `PROXY_NOT_CONFIGURED`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use gstore_contract::error::{ModuleError, StatusCode};
use meow_common::Proxy;
use meow_proxy::health::{probe_many_bounded_detailed, NamedProbeResult, UrlTestError};
use meow_proxy::SelectorStore;
use serde::Deserialize;
use serde_json::{json, Value};

pub(crate) const ERR_NODE_NOT_FOUND: &str = "PROXY_NODE_NOT_FOUND";
pub(crate) const ERR_NOT_SELECTABLE: &str = "PROXY_GROUP_NOT_SELECTABLE";
pub(crate) const ERR_NOT_CONFIGURED: &str = "PROXY_NOT_CONFIGURED";
pub(crate) const EVT_NODE_DELAY: &str = "proxy.node.delay";

/// Clash's standard connectivity-check URL.
pub(crate) const DEFAULT_TEST_URL: &str = "https://www.gstatic.com/generate_204";
const DEFAULT_TIMEOUT_MS: u64 = 5_000;
const MIN_TIMEOUT_MS: u64 = 100;
const MAX_TIMEOUT_MS: u64 = 120_000;

/// Off-tunnel-loop runtime for delay probes and async selection. Built once with
/// the crate's bounded shape; never the tunnel loop's runtime, so a slow probe
/// cannot stall frame I/O.
static OPS_RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn ops_runtime() -> Result<&'static tokio::runtime::Runtime, ModuleError> {
    if let Some(rt) = OPS_RUNTIME.get() {
        return Ok(rt);
    }
    let rt = crate::bounded_runtime()
        .map_err(|e| ModuleError::internal(format!("node ops runtime build: {e}")))?;
    let _ = OPS_RUNTIME.set(rt);
    Ok(OPS_RUNTIME.get().expect("runtime set above"))
}

/// Open the process-wide persistent selection store once, under the module data
/// dir. meow-config's runtime rebuild reads `SelectorStore::global()` when it
/// constructs selector/url-test/fallback groups, so the first `open()` must
/// happen before Todo 13 builds them.
pub(crate) fn ensure_selector_store(data_dir: &str) -> Arc<SelectorStore> {
    if let Some(store) = SelectorStore::global() {
        return store;
    }
    SelectorStore::open(PathBuf::from(data_dir).join("selector.json"))
}

/// Attach the generated proxies/groups to the live tunnel. Todo 13 calls this
/// (through `tun::start_with_proxies`) right after the engine is built; build
/// the map with `name -> Arc<dyn Proxy>` for both leaf nodes and groups, and
/// build groups through the store returned by [`ensure_selector_store`] so
/// selection persists across reloads.
pub(crate) fn install_proxies(
    tunnel: &meow_tunnel::Tunnel,
    proxies: HashMap<smol_str::SmolStr, Arc<dyn Proxy>>,
) {
    tunnel.update_proxies(proxies);
}

fn active_tunnel() -> Result<Arc<meow_tunnel::Tunnel>, ModuleError> {
    crate::rules::active_tunnel().ok_or_else(|| {
        ModuleError::new(
            StatusCode::InvalidArgument,
            ERR_NOT_CONFIGURED,
            "engine is not running; start the tunnel before selecting nodes",
        )
    })
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SelectRequest {
    pub group: String,
    pub node: String,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DelayRequest {
    #[serde(default)]
    pub node: Option<String>,
    #[serde(default)]
    pub group: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub expected_status: Option<String>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

/// Result of a successful `node.select`, surfaced so the caller can emit the
/// `proxy.state` event with the effective outbound.
#[derive(Debug)]
pub(crate) struct Selection {
    pub group: String,
    pub node: String,
    pub active: String,
}

/// `node.select`: apply a user choice to a selector/url-test/fallback group.
/// Online uses the live tunnel; offline rebuilds from the persisted profile and
/// persists through `SelectorStore` so the next `core.start` picks it up.
pub(crate) fn select(
    payload: &[u8],
    data_dir: &str,
    cache_dir: &str,
) -> Result<(Value, Selection), ModuleError> {
    let req: SelectRequest = if payload.is_empty() {
        return Err(ModuleError::invalid_arg(
            "node.select requires {group, node}",
        ));
    } else {
        serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!("node.select payload must be a JSON object: {e}"))
        })?
    };
    if req.group.trim().is_empty() || req.node.trim().is_empty() {
        return Err(ModuleError::invalid_arg(
            "node.select requires non-empty `group` and `node`",
        ));
    }

    match crate::rules::active_tunnel() {
        Some(tunnel) => apply_selection(|group| tunnel.proxy(group), req),
        None => {
            let store = if data_dir.trim().is_empty() {
                None
            } else {
                Some(ensure_selector_store(data_dir))
            };
            select_offline(data_dir, cache_dir, store, req)
        }
    }
}

/// Offline `node.select`: validate against a registry rebuilt from the persisted
/// profile and persist through `store` (the same seam `core.start` reads back).
fn select_offline(
    data_dir: &str,
    cache_dir: &str,
    store: Option<Arc<SelectorStore>>,
    req: SelectRequest,
) -> Result<(Value, Selection), ModuleError> {
    let generated = crate::config::try_generate(
        data_dir,
        cache_dir,
        &crate::config::GenerateRequest::default(),
    )?
    .ok_or_else(|| {
        ModuleError::new(
            StatusCode::InvalidArgument,
            ERR_NOT_CONFIGURED,
            "no profile is stored; import a profile before selecting nodes",
        )
    })?;
    let (proxies, _warnings) = crate::config::build_registry(&generated.raw, store.as_ref());
    apply_selection(|group| proxies.get(group).cloned(), req)
}

/// Shared selection body for the online and offline paths: resolve the group,
/// apply through `ProxySelection::set`, and shape `{group,node,active}`.
fn apply_selection<F>(
    resolve: F,
    req: SelectRequest,
) -> Result<(Value, Selection), ModuleError>
where
    F: FnOnce(&str) -> Option<Arc<dyn Proxy>>,
{
    let SelectRequest { group, node } = req;

    let proxy = resolve(&group).ok_or_else(|| {
        ModuleError::new(
            StatusCode::ModuleNotFound,
            ERR_NODE_NOT_FOUND,
            format!("group or node not found: {group}"),
        )
    })?;
    let selection = proxy.selection().ok_or_else(|| {
        ModuleError::new(
            StatusCode::InvalidArgument,
            ERR_NOT_SELECTABLE,
            format!("'{group}' is not a selectable group (selector/url-test/fallback)"),
        )
    })?;

    ops_runtime()?
        .block_on(async { selection.set(&node).await })
        .map_err(|e| {
            ModuleError::new(
                StatusCode::ModuleNotFound,
                ERR_NODE_NOT_FOUND,
                format!("node '{node}' not in group '{group}': {e}"),
            )
        })?;

    let active = proxy.current().unwrap_or_else(|| node.clone());
    log_message(format!(
        "proxy: node.select group={group} node={node} active={active}"
    ));
    let data = json!({
        "ok": true,
        "group": group.clone(),
        "node": node.clone(),
        "active": active.clone(),
    });
    Ok((data, Selection { group, node, active }))
}

/// Resolve the probe targets for a `node.delay_test` request.
fn resolve_targets(
    tunnel: &meow_tunnel::Tunnel,
    req: &DelayRequest,
) -> Result<(Vec<(String, Arc<dyn Proxy>)>, Option<String>, String, Option<String>), ModuleError> {
    let (targets, group_label, test_url, expected) = if let Some(group) = &req.group {
        let proxy = tunnel.proxy(group).ok_or_else(|| {
            ModuleError::new(
                StatusCode::ModuleNotFound,
                ERR_NODE_NOT_FOUND,
                format!("group not found: {group}"),
            )
        })?;
        let members = proxy.member_proxies().ok_or_else(|| {
            ModuleError::new(
                StatusCode::InvalidArgument,
                ERR_NOT_SELECTABLE,
                format!("'{group}' is not a group with latency-testable members"),
            )
        })?;
        let targets: Vec<(String, Arc<dyn Proxy>)> = match &req.node {
            Some(node) => members
                .into_iter()
                .filter(|p| p.name() == node)
                .map(|p| (p.name().to_string(), p))
                .collect(),
            None => members
                .into_iter()
                .map(|p| (p.name().to_string(), p))
                .collect(),
        };
        if targets.is_empty() {
            return Err(ModuleError::new(
                StatusCode::ModuleNotFound,
                ERR_NODE_NOT_FOUND,
                match &req.node {
                    Some(node) => format!("node '{node}' not in group '{group}'"),
                    None => format!("group '{group}' has no members"),
                },
            ));
        }
        (
            targets,
            Some(group.clone()),
            proxy.test_url().map(str::to_string),
            proxy.expected_status().map(str::to_string),
        )
    } else if let Some(node) = &req.node {
        let proxy = tunnel.proxy(node).ok_or_else(|| {
            ModuleError::new(
                StatusCode::ModuleNotFound,
                ERR_NODE_NOT_FOUND,
                format!("node not found: {node}"),
            )
        })?;
        (vec![(node.clone(), proxy)], None, None, None)
    } else {
        return Err(ModuleError::invalid_arg(
            "node.delay_test requires `node` and/or `group`",
        ));
    };

    let url = req
        .url
        .clone()
        .or(test_url)
        .unwrap_or_else(|| DEFAULT_TEST_URL.to_string());
    let expected = req.expected_status.clone().or(expected);
    Ok((targets, group_label, url, expected))
}

/// Run the probes on the off-loop runtime. Pure: no events, no tunnel mutation.
pub(crate) fn run_delay(
    targets: Vec<(String, Arc<dyn Proxy>)>,
    url: &str,
    expected: Option<&str>,
    timeout: Duration,
) -> Vec<NamedProbeResult> {
    let rt = match ops_runtime() {
        Ok(rt) => rt,
        Err(e) => {
            log_message(format!("proxy: node.delay_test runtime unavailable: {e}"));
            return targets
                .into_iter()
                .map(|(name, _)| NamedProbeResult {
                    name,
                    delay: 0,
                    error: Some(UrlTestError::Transport("runtime unavailable".to_string())),
                })
                .collect();
        }
    };
    rt.block_on(probe_many_bounded_detailed(
        targets,
        url,
        expected,
        timeout,
        meow_proxy::health::GROUP_DELAY_CONCURRENCY,
    ))
}

fn error_label(error: Option<&UrlTestError>) -> Option<String> {
    match error {
        None => None,
        Some(UrlTestError::Timeout) => Some("timeout".to_string()),
        Some(UrlTestError::Transport(m)) => Some(m.clone()),
    }
}

/// `node.delay_test` arm: probe every resolved target, emit one
/// `proxy.node.delay` event per node, and return a per-node result list. An
/// unreachable node is a `timeout` result, not a failed call.
pub(crate) fn delay_test_arm(instance_id: u64, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let req: DelayRequest = if payload.is_empty() {
        return Err(ModuleError::invalid_arg(
            "node.delay_test requires {node} and/or {group}",
        ));
    } else {
        serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!("node.delay_test payload must be JSON: {e}"))
        })?
    };
    let timeout_ms = req
        .timeout_ms
        .unwrap_or(DEFAULT_TIMEOUT_MS)
        .clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);

    let tunnel = active_tunnel()?;
    let (targets, group_label, url, expected) = resolve_targets(&tunnel, &req)?;

    let results = run_delay(
        targets,
        &url,
        expected.as_deref(),
        Duration::from_millis(timeout_ms),
    );

    let mut out = Vec::with_capacity(results.len());
    for r in &results {
        let error = error_label(r.error.as_ref());
        let event = json!({
            "group": group_label.clone().unwrap_or_default(),
            "node": r.name,
            "delayMs": if error.is_none() { r.delay as u64 } else { 0 },
            "error": error,
        });
        if let Ok(bytes) = serde_json::to_vec(&event) {
            crate::emit_event(instance_id, EVT_NODE_DELAY, &bytes);
        }
        out.push(json!({
            "node": r.name,
            "delayMs": if error.is_none() { r.delay as u64 } else { 0 },
            "alive": error.is_none(),
            "error": error,
        }));
    }
    log_message(format!(
        "proxy: node.delay_test url={url} timeoutMs={timeout_ms} nodes={}",
        out.len()
    ));
    crate::ok_data(json!({
        "results": out,
        "url": url,
        "timeoutMs": timeout_ms,
        "group": group_label,
    }))
}

/// `node.list`: read-only live view of every proxy group's current selection
/// (`now`) plus the routing group. Never errors when the engine is stopped — the
/// UI degrades on `engineRunning:false` instead of a 422.
pub(crate) fn list(data_dir: &str, cache_dir: &str) -> Result<Value, ModuleError> {
    let Some(tunnel) = crate::rules::active_tunnel() else {
        return Ok(json!({
            "engineRunning": false,
            "groups": [],
            "current": Value::Null,
        }));
    };

    // Group names/types come from the stored profile's generated groups (the
    // same source `select_offline` rebuilds from); anything else the live
    // registry exposes as a group is appended as a fallback.
    let raw_groups = crate::config::try_generate(
        data_dir,
        cache_dir,
        &crate::config::GenerateRequest::default(),
    )?
    .and_then(|generated| generated.raw.proxy_groups);

    let mut groups = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for raw in raw_groups.unwrap_or_default() {
        let Some(proxy) = tunnel.proxy(&raw.name) else {
            continue;
        };
        if proxy.member_proxies().is_none() {
            continue;
        }
        let members = raw
            .proxies
            .clone()
            .unwrap_or_else(|| proxy.members().unwrap_or_default());
        groups.push(json!({
            "name": raw.name,
            "type": raw.group_type,
            "now": proxy.current(),
            "members": members,
            "selectable": proxy.selection().is_some(),
        }));
        seen.insert(raw.name);
    }

    {
        let snapshot = tunnel.route_snapshot();
        let mut names: Vec<String> = snapshot.proxies.keys().map(ToString::to_string).collect();
        names.sort();
        for name in names {
            if seen.contains(&name) {
                continue;
            }
            let Some(proxy) = snapshot.proxies.get(name.as_str()) else {
                continue;
            };
            let Some(members) = proxy.members() else {
                continue; // leaf adapter, not a group
            };
            groups.push(json!({
                "name": name,
                "type": proxy.adapter_type().to_string().to_lowercase(),
                "now": proxy.current(),
                "members": members,
                "selectable": proxy.selection().is_some(),
            }));
        }
    }

    Ok(json!({
        "engineRunning": true,
        "groups": groups,
        "current": current_routing_group(&tunnel),
    }))
}

/// The `current` field: the live rules' terminal `MATCH`/`FINAL` target, when it
/// names a group. `node` resolves one level deeper so the UI can show a leaf
/// when the target's `now` is itself a nested group.
fn current_routing_group(tunnel: &meow_tunnel::Tunnel) -> Value {
    let Some(target) = terminal_match_target() else {
        return Value::Null;
    };
    let Some(proxy) = tunnel.proxy(&target) else {
        return Value::Null;
    };
    if proxy.member_proxies().is_none() {
        return Value::Null;
    }
    let now = proxy.current();
    let node = now.as_ref().and_then(|name| {
        tunnel
            .proxy(name)
            .filter(|inner| inner.member_proxies().is_some())
            .and_then(|inner| inner.current())
    });
    json!({ "group": target, "now": now, "node": node })
}

/// Last rule line whose head is `MATCH`/`FINAL`; returns the target after the
/// comma (the routing group), or `None` when there is no terminal rule.
fn terminal_match_target() -> Option<String> {
    crate::rules::current_lines()
        .into_iter()
        .rev()
        .find_map(|line| {
            let mut parts = line.splitn(2, ',');
            let head = parts.next()?.trim();
            if !(head.eq_ignore_ascii_case("MATCH") || head.eq_ignore_ascii_case("FINAL")) {
                return None;
            }
            parts
                .next()
                .map(|target| target.trim().to_string())
                .filter(|target| !target.is_empty())
        })
}

fn log_message(msg: String) {
    crate::log_message(1, &msg);
}

#[cfg(all(test, unix))]
pub(crate) mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Mutex;

    use async_trait::async_trait;
    use meow_common::{
        AdapterType, ConnType, DelayHistory, MeowError, Metadata, Network, ProxyAdapter, ProxyConn,
        ProxyHealth, ProxyPacketConn, Result as MeowResult,
    };

    use crate::TEST_SERIAL as SERIAL;

    /// Stub outbound: optionally records dials, optionally hangs forever (to
    /// exercise the delay-test timeout path without touching the network).
    pub(crate) struct StubProxy {
        name: String,
        health: ProxyHealth,
        hangs: bool,
        dials: Mutex<Vec<String>>,
    }

    impl StubProxy {
        pub(crate) fn new(name: &str) -> Arc<StubProxy> {
            Arc::new(Self {
                name: name.to_string(),
                health: ProxyHealth::new(),
                hangs: false,
                dials: Mutex::new(Vec::new()),
            })
        }

        pub(crate) fn hanging(name: &str) -> Arc<StubProxy> {
            Arc::new(Self {
                name: name.to_string(),
                health: ProxyHealth::new(),
                hangs: true,
                dials: Mutex::new(Vec::new()),
            })
        }
    }

    #[async_trait]
    impl ProxyAdapter for StubProxy {
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
            self.dials.lock().unwrap_or_else(|e| e.into_inner()).push(metadata.rule_host().to_string());
            if self.hangs {
                std::future::pending::<()>().await;
            }
            Err(MeowError::NotSupported("stub".into()))
        }
        async fn dial_udp(&self, _metadata: &Metadata) -> MeowResult<Box<dyn ProxyPacketConn>> {
            Err(MeowError::NotSupported("stub".into()))
        }
        fn health(&self) -> &ProxyHealth {
            &self.health
        }
    }

    impl Proxy for StubProxy {
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

    fn tmp_dir(tag: &str) -> PathBuf {
        static SEQ: AtomicU32 = AtomicU32::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("gstore-nodes-{tag}-{nanos}-{seq}"));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn empty_resolver() -> Arc<meow_dns::Resolver> {
        Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ))
    }

    fn selector_group(name: &str, members: &[&Arc<StubProxy>], store: &Arc<SelectorStore>) -> Arc<dyn Proxy> {
        let members: Vec<Arc<dyn Proxy>> = members
            .iter()
            .map(|p| Arc::clone(p) as Arc<dyn Proxy>)
            .collect();
        Arc::new(meow_proxy::SelectorGroup::new(name, members).with_store(Arc::clone(store)))
    }

    fn match_rule(target: &str) -> Vec<Box<dyn meow_common::Rule>> {
        let ctx = meow_rules::ParserContext::empty();
        let providers: HashMap<String, Arc<dyn meow_rules::RuleSet>> = HashMap::new();
        let sub: meow_config::sub_rules_parser::SubRuleBlocks = HashMap::new();
        vec![meow_config::rule_parser::parse_one_rule_or_subrule(
            &format!("MATCH,{target}"),
            &providers,
            &ctx,
            &sub,
        )
        .expect("MATCH rule parses")]
    }

    /// Happy QA: select a node in a selector group -> effective outbound changes
    /// (the group's `current()` flips and `resolve_proxy` keeps routing to the
    /// group whose selected member is the new one).
    #[test]
    fn select_changes_active_outbound_in_selector_group() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let _ = crate::dispatch::build_engine(empty_resolver());
        let tunnel = active_tunnel().unwrap();

        let a = StubProxy::new("A");
        let b = StubProxy::new("B");
        let store = SelectorStore::open(tmp_dir("sel").join("selector.json"));
        let group = selector_group("G", &[&a, &b], &store);
        let mut map: HashMap<smol_str::SmolStr, Arc<dyn Proxy>> = HashMap::new();
        map.insert(smol_str::SmolStr::from("G"), Arc::clone(&group));
        map.insert(smol_str::SmolStr::from("A"), Arc::clone(&a) as Arc<dyn Proxy>);
        map.insert(smol_str::SmolStr::from("B"), Arc::clone(&b) as Arc<dyn Proxy>);
        tunnel.update_proxies(map);
        tunnel.update_rules(match_rule("G"));

        assert_eq!(group.current().as_deref(), Some("A"));

        let req = serde_json::to_vec(&json!({ "group": "G", "node": "B" })).unwrap();
        let (data, selection) = select(&req, "", "").expect("select should succeed");
        assert_eq!(data["active"], "B");
        assert_eq!(selection.active, "B");
        assert_eq!(group.current().as_deref(), Some("B"));

        let metadata = Metadata {
            network: Network::Tcp,
            conn_type: ConnType::Tun,
            host: "example.com".into(),
            dst_port: 443,
            ..Default::default()
        };
        let (resolved, rule, _payload) = tunnel.inner().resolve_proxy(&metadata).unwrap();
        assert_eq!(resolved.name(), "G");
        assert_eq!(&*rule, "MATCH");

        crate::rules::reset_for_tests();
    }

    /// Selection persists across a reload: a group rebuilt from the same store
    /// (meow's persistence side-channel) restores the prior pick.
    #[test]
    fn selection_persists_across_reload() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let store = SelectorStore::open(tmp_dir("persist").join("selector.json"));

        let first = selector_group(
            "G",
            &[&StubProxy::new("A"), &StubProxy::new("B")],
            &store,
        );
        assert!(store.get("G").is_none(), "fresh store has no pick");
        ops_runtime()
            .unwrap()
            .block_on(async { first.selection().unwrap().set("B").await })
            .unwrap();
        assert_eq!(first.current().as_deref(), Some("B"));

        let rebuilt = selector_group(
            "G",
            &[&StubProxy::new("A"), &StubProxy::new("B")],
            &store,
        );
        assert_eq!(
            rebuilt.current().as_deref(),
            Some("B"),
            "rebuilt group must restore the persisted pick"
        );
        assert_eq!(store.get("G").as_deref(), Some("B"));

        crate::rules::reset_for_tests();
    }

    /// Failure QA: an unreachable node yields a per-node timeout result; the
    /// call never errors or blocks the tunnel.
    #[test]
    fn delay_test_returns_timeout_result_per_node() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let targets: Vec<(String, Arc<dyn Proxy>)> = vec![
            ("A".to_string(), StubProxy::hanging("A") as Arc<dyn Proxy>),
            ("B".to_string(), StubProxy::hanging("B") as Arc<dyn Proxy>),
        ];
        let results = run_delay(
            targets,
            "http://127.0.0.1:1/",
            None,
            Duration::from_millis(100),
        );
        assert_eq!(results.len(), 2, "one result per node");
        for r in &results {
            assert_eq!(r.delay, 0);
            assert!(
                matches!(r.error, Some(UrlTestError::Timeout)),
                "node {} should be a timeout result, got {:?}",
                r.name,
                r.error
            );
        }
    }

    /// A hanging probe must not be counted as alive and must leave the runtime
    /// usable for the next call (no poisoned runtime/thread leak).
    #[test]
    fn delay_test_is_repeatable_after_timeout() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        for _ in 0..3 {
            let targets: Vec<(String, Arc<dyn Proxy>)> =
                vec![("A".to_string(), StubProxy::hanging("A") as Arc<dyn Proxy>)];
            let results = run_delay(
                targets,
                "http://127.0.0.1:1/",
                None,
                Duration::from_millis(50),
            );
            assert_eq!(results.len(), 1);
            assert!(matches!(results[0].error, Some(UrlTestError::Timeout)));
        }
    }

    /// A selector without a store still selects in-memory (only persistence is
    /// lost), and a non-selectable/leaf target is a structured error.
    #[test]
    fn select_errors_are_structured() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let _ = crate::dispatch::build_engine(empty_resolver());
        let tunnel = active_tunnel().unwrap();
        let leaf = StubProxy::new("LEAF");
        let mut map: HashMap<smol_str::SmolStr, Arc<dyn Proxy>> = HashMap::new();
        map.insert(smol_str::SmolStr::from("LEAF"), Arc::clone(&leaf) as Arc<dyn Proxy>);
        tunnel.update_proxies(map);

        let missing = select(br#"{"group":"NOPE","node":"A"}"#, "", "").unwrap_err();
        assert_eq!(missing.status, StatusCode::ModuleNotFound);
        assert_eq!(missing.code, ERR_NODE_NOT_FOUND);

        let not_selectable = select(br#"{"group":"LEAF","node":"A"}"#, "", "").unwrap_err();
        assert_eq!(not_selectable.code, ERR_NOT_SELECTABLE);

        let bad_payload = select(br#"{"group":"G"}"#, "", "").unwrap_err();
        assert_eq!(bad_payload.status, StatusCode::InvalidArgument);

        crate::rules::reset_for_tests();
    }

    fn offline_node(name: &str, index: usize) -> crate::subscription::ProxyNode {
        crate::subscription::ProxyNode {
            name: name.to_string(),
            node_type: "ss".to_string(),
            server: "192.0.2.1".to_string(),
            port: 8388,
            cipher: Some("aes-256-gcm".to_string()),
            password: Some("secret".to_string()),
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
            udp: None,
            groups: Vec::new(),
            source: crate::subscription::NodeSource {
                format: "clash".to_string(),
                origin: "text".to_string(),
                index,
            },
        }
    }

    /// Persist a two-node profile with the given groups into a fresh temp
    /// `data_dir`, so the offline path can rebuild its registry from disk.
    fn profile_dir(tag: &str, groups: Vec<crate::subscription::ProxyGroup>) -> String {
        let dir = tmp_dir(tag);
        let store = crate::profile::ProfileStore::open(&dir.display().to_string()).unwrap();
        let profile = crate::subscription::ImportedProfile {
            name: "Offline".to_string(),
            format: "clash".to_string(),
            node_count: 2,
            nodes: vec![offline_node("node-a", 0), offline_node("node-b", 1)],
            groups,
            rules: Vec::new(),
            userinfo: None,
            source: crate::subscription::ImportSource::default(),
            warnings: Vec::new(),
        };
        let payload = serde_json::to_vec(&json!({ "profile": &profile })).unwrap();
        store.create(&payload).unwrap();
        dir.display().to_string()
    }

    /// Offline happy QA: with no active tunnel, `node.select` still succeeds,
    /// returns the frozen `{group,node,active}` shape, and persists the pick
    /// through the process-wide `SelectorStore` (the seam `core.start` reads).
    #[test]
    fn offline_select_persists_to_store_and_reports_active() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        assert!(
            crate::rules::active_tunnel().is_none(),
            "precondition: engine must be stopped"
        );

        let data_dir = profile_dir(
            "offline-sel",
            vec![crate::subscription::ProxyGroup {
                name: "OFFLINE_SEL".to_string(),
                group_type: "select".to_string(),
                members: vec!["node-a".to_string(), "node-b".to_string()],
            }],
        );

        let req = serde_json::to_vec(&json!({ "group": "OFFLINE_SEL", "node": "node-b" })).unwrap();
        let (data, selection) =
            select(&req, &data_dir, &data_dir).expect("offline select must succeed");

        assert_eq!(data["ok"], true);
        assert_eq!(data["group"], "OFFLINE_SEL");
        assert_eq!(data["node"], "node-b");
        assert_eq!(data["active"], "node-b");
        assert_eq!(selection.group, "OFFLINE_SEL");
        assert_eq!(selection.node, "node-b");
        assert_eq!(selection.active, "node-b");

        let store = SelectorStore::global().expect("offline select opened the global store");
        assert_eq!(
            store.get("OFFLINE_SEL").as_deref(),
            Some("node-b"),
            "offline pick must be persisted through SelectorStore"
        );

        crate::rules::reset_for_tests();
    }

    /// Offline pick survives a store reopen from disk: the injected store writes
    /// `selector.json`, and a fresh open of the same path reads it back.
    #[test]
    fn offline_select_persists_to_disk_and_survives_reopen() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        assert!(crate::rules::active_tunnel().is_none());

        let data_dir = profile_dir(
            "offline-disk",
            vec![crate::subscription::ProxyGroup {
                name: "OFFLINE_DISK".to_string(),
                group_type: "select".to_string(),
                members: vec!["node-a".to_string(), "node-b".to_string()],
            }],
        );
        let store_path = tmp_dir("offline-disk-store").join("selector.json");
        let store = SelectorStore::open(store_path.clone());

        let req = SelectRequest {
            group: "OFFLINE_DISK".to_string(),
            node: "node-b".to_string(),
        };
        let (data, _) = select_offline(&data_dir, &data_dir, Some(Arc::clone(&store)), req)
            .expect("offline select must succeed");
        assert_eq!(data["active"], "node-b");
        drop(store);

        let reopened = SelectorStore::open(store_path);
        assert_eq!(
            reopened.get("OFFLINE_DISK").as_deref(),
            Some("node-b"),
            "pick must be durable on disk"
        );

        crate::rules::reset_for_tests();
    }

    #[test]
    fn list_reports_group_now_and_reflects_select() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let _ = crate::dispatch::build_engine(empty_resolver());
        let tunnel = active_tunnel().unwrap();

        let a = StubProxy::new("A");
        let b = StubProxy::new("B");
        let store = SelectorStore::open(tmp_dir("list").join("selector.json"));
        let group = selector_group("G", &[&a, &b], &store);
        let mut map: HashMap<smol_str::SmolStr, Arc<dyn Proxy>> = HashMap::new();
        map.insert(smol_str::SmolStr::from("G"), Arc::clone(&group));
        map.insert(smol_str::SmolStr::from("A"), Arc::clone(&a) as Arc<dyn Proxy>);
        map.insert(smol_str::SmolStr::from("B"), Arc::clone(&b) as Arc<dyn Proxy>);
        tunnel.update_proxies(map);
        crate::rules::reload(
            "",
            "",
            br#"{"config":"rules:\n  - MATCH,G\n"}"#,
        )
        .expect("rules.reload with a terminal MATCH");

        let payload = list("", "").expect("node.list must not error when running");
        assert_eq!(payload["engineRunning"], true);
        let groups = payload["groups"].as_array().unwrap();
        let g = groups
            .iter()
            .find(|entry| entry["name"] == "G")
            .expect("group G is listed");
        assert_eq!(g["type"], "selector");
        assert_eq!(g["now"], "A");
        assert_eq!(g["selectable"], true);
        assert_eq!(g["members"], json!(["A", "B"]));
        assert_eq!(payload["current"]["group"], "G");
        assert_eq!(payload["current"]["now"], "A");
        assert_eq!(payload["current"]["node"], Value::Null);

        let req = serde_json::to_vec(&json!({ "group": "G", "node": "B" })).unwrap();
        select(&req, "", "").expect("select B");
        let payload = list("", "").unwrap();
        let g = payload["groups"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["name"] == "G")
            .unwrap();
        assert_eq!(g["now"], "B");
        assert_eq!(payload["current"]["now"], "B");

        crate::rules::reset_for_tests();
    }

    #[test]
    fn list_without_engine_is_a_non_error_empty_payload() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        assert!(crate::rules::active_tunnel().is_none());

        let payload = list("", "").expect("stopped engine must not error");
        assert_eq!(payload["engineRunning"], false);
        assert_eq!(payload["groups"], json!([]));
        assert_eq!(payload["current"], Value::Null);
    }

    /// Offline failure QA: an unknown group and a non-selectable group still
    /// produce the existing structured errors, never a silent accept.
    #[test]
    fn offline_select_unknown_and_unsupported_groups_are_structured() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        assert!(crate::rules::active_tunnel().is_none());

        let data_dir = profile_dir(
            "offline-err",
            vec![
                crate::subscription::ProxyGroup {
                    name: "OFFLINE_SEL".to_string(),
                    group_type: "select".to_string(),
                    members: vec!["node-a".to_string(), "node-b".to_string()],
                },
                crate::subscription::ProxyGroup {
                    name: "OFFLINE_LB".to_string(),
                    group_type: "load-balance".to_string(),
                    members: vec!["node-a".to_string(), "node-b".to_string()],
                },
            ],
        );

        let unknown = select(br#"{"group":"NOPE","node":"node-a"}"#, &data_dir, &data_dir).unwrap_err();
        assert_eq!(unknown.status, StatusCode::ModuleNotFound);
        assert_eq!(unknown.code, ERR_NODE_NOT_FOUND);

        let unsupported =
            select(br#"{"group":"OFFLINE_LB","node":"node-a"}"#, &data_dir, &data_dir).unwrap_err();
        assert_eq!(unsupported.status, StatusCode::InvalidArgument);
        assert_eq!(unsupported.code, ERR_NOT_SELECTABLE);

        let ghost =
            select(br#"{"group":"OFFLINE_SEL","node":"ghost"}"#, &data_dir, &data_dir).unwrap_err();
        assert_eq!(ghost.status, StatusCode::ModuleNotFound);
        assert_eq!(ghost.code, ERR_NODE_NOT_FOUND);

        let empty = select(br#"{"group":"","node":""}"#, &data_dir, &data_dir).unwrap_err();
        assert_eq!(empty.status, StatusCode::InvalidArgument);

        crate::rules::reset_for_tests();
    }
}
