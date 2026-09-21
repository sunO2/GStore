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
pub(crate) fn select(payload: &[u8]) -> Result<(Value, Selection), ModuleError> {
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

    let tunnel = active_tunnel()?;
    let proxy = tunnel.proxy(&req.group).ok_or_else(|| {
        ModuleError::new(
            StatusCode::ModuleNotFound,
            ERR_NODE_NOT_FOUND,
            format!("group or node not found: {}", req.group),
        )
    })?;
    let selection = proxy.selection().ok_or_else(|| {
        ModuleError::new(
            StatusCode::InvalidArgument,
            ERR_NOT_SELECTABLE,
            format!("'{}' is not a selectable group (selector/url-test/fallback)", req.group),
        )
    })?;

    ops_runtime()?
        .block_on(async { selection.set(&req.node).await })
        .map_err(|e| {
            ModuleError::new(
                StatusCode::ModuleNotFound,
                ERR_NODE_NOT_FOUND,
                format!("node '{}' not in group '{}': {e}", req.node, req.group),
            )
        })?;

    let active = proxy.current().unwrap_or_else(|| req.node.clone());
    log_message(format!(
        "proxy: node.select group={} node={} active={active}",
        req.group, req.node
    ));
    let data = json!({
        "ok": true,
        "group": req.group,
        "node": req.node,
        "active": active,
    });
    Ok((
        data,
        Selection {
            group: req.group,
            node: req.node,
            active,
        },
    ))
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
            self.dials.lock().unwrap().push(metadata.rule_host().to_string());
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
        let _g = SERIAL.lock().unwrap();
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
        let (data, selection) = select(&req).expect("select should succeed");
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
        let _g = SERIAL.lock().unwrap();
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
        let _g = SERIAL.lock().unwrap();
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
        let _g = SERIAL.lock().unwrap();
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
        let _g = SERIAL.lock().unwrap();
        crate::rules::reset_for_tests();
        let _ = crate::dispatch::build_engine(empty_resolver());
        let tunnel = active_tunnel().unwrap();
        let leaf = StubProxy::new("LEAF");
        let mut map: HashMap<smol_str::SmolStr, Arc<dyn Proxy>> = HashMap::new();
        map.insert(smol_str::SmolStr::from("LEAF"), Arc::clone(&leaf) as Arc<dyn Proxy>);
        tunnel.update_proxies(map);

        let missing = select(br#"{"group":"NOPE","node":"A"}"#).unwrap_err();
        assert_eq!(missing.status, StatusCode::ModuleNotFound);
        assert_eq!(missing.code, ERR_NODE_NOT_FOUND);

        let not_selectable = select(br#"{"group":"LEAF","node":"A"}"#).unwrap_err();
        assert_eq!(not_selectable.code, ERR_NOT_SELECTABLE);

        let bad_payload = select(br#"{"group":"G"}"#).unwrap_err();
        assert_eq!(bad_payload.status, StatusCode::InvalidArgument);

        crate::rules::reset_for_tests();
    }
}
