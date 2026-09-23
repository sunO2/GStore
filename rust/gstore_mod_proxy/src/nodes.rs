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
use futures::StreamExt;
use meow_common::Proxy;
use meow_proxy::health::{probe_and_record, NamedProbeResult, UrlTestError};
use meow_proxy::SelectorStore;
use serde::Deserialize;
use serde_json::{json, Value};

pub(crate) const ERR_NODE_NOT_FOUND: &str = "PROXY_NODE_NOT_FOUND";
pub(crate) const ERR_NOT_SELECTABLE: &str = "PROXY_GROUP_NOT_SELECTABLE";
pub(crate) const ERR_NOT_CONFIGURED: &str = "PROXY_NOT_CONFIGURED";
pub(crate) const EVT_NODE_DELAY: &str = "proxy.node.delay";

/// Clash's standard connectivity-check URL.
pub(crate) const DEFAULT_TEST_URL: &str = "https://www.gstatic.com/generate_204";
/// One probe is a full node handshake (REALITY is heavy) plus a client-side
/// end-to-end TLS handshake to the test URL and a GET; 5s is routinely exceeded
/// on mobile, so the default is 10s.
const DEFAULT_TIMEOUT_MS: u64 = 10_000;
const MIN_TIMEOUT_MS: u64 = 100;
const MAX_TIMEOUT_MS: u64 = 120_000;
/// Meow's group default is 16; a phone firing 16 concurrent TLS handshakes
/// starves its own uplink/CPU and manufactures false timeouts on a large
/// subscription, so probe a queue of exactly 5 at a time.
const DELAY_PROBE_CONCURRENCY: usize = 5;

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
    pub targets: Option<Vec<String>>,
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

    // Serialize resolve+set with the single mode/lifecycle lane: `core.*` /
    // `config.apply` / `lan.set` hold it while they swap the whole proxy
    // registry. Without it, select can resolve a group from the old registry and
    // then `set` on that stale `Arc` after the swap (choice lost, or a group only
    // present in the newer registry 404s). Re-entrancy safe: `select` is only
    // reached from the `node.select` dispatch arm, which holds no lane.
    let _lane = crate::mode::lane();

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

/// A resolved probe target: either a live proxy to probe, or a name that did
/// not resolve. Missing names travel as their own per-node `not found` result
/// so one stale name in a batch never aborts the whole call.
pub(crate) enum ProbeTarget {
    Proxy(Arc<dyn Proxy>),
    Missing,
}

struct ResolvedTargets {
    targets: Vec<(String, ProbeTarget)>,
    group: Option<String>,
    url: String,
    expected: Option<String>,
}

/// Resolve the probe targets for a `node.delay_test` request.
///
/// Selector precedence: `group` (optionally narrowed by `node`) -> `node` ->
/// `targets` (an explicit name list) -> error. The resolver closure abstracts
/// the online (`Tunnel::proxy`) and offline (`build_registry`) registry so both
/// paths share this logic.
fn resolve_targets<F>(resolve: F, req: &DelayRequest) -> Result<ResolvedTargets, ModuleError>
where
    F: Fn(&str) -> Option<Arc<dyn Proxy>>,
{
    let (targets, group_label, test_url, expected) = if let Some(group) = &req.group {
        let proxy = resolve(group).ok_or_else(|| {
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
        let targets: Vec<(String, ProbeTarget)> = match &req.node {
            Some(node) => members
                .into_iter()
                .filter(|p| p.name() == node)
                .map(|p| (p.name().to_string(), ProbeTarget::Proxy(p)))
                .collect(),
            None => members
                .into_iter()
                .map(|p| (p.name().to_string(), ProbeTarget::Proxy(p)))
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
        let proxy = resolve(node).ok_or_else(|| {
            ModuleError::new(
                StatusCode::ModuleNotFound,
                ERR_NODE_NOT_FOUND,
                format!("node not found: {node}"),
            )
        })?;
        (
            vec![(node.clone(), ProbeTarget::Proxy(proxy))],
            None,
            None,
            None,
        )
    } else if let Some(names) = &req.targets {
        if names.is_empty() {
            return Err(ModuleError::invalid_arg(
                "node.delay_test requires `node`, `group`, and/or `targets`",
            ));
        }
        let targets: Vec<(String, ProbeTarget)> = names
            .iter()
            .map(|name| match resolve(name) {
                Some(proxy) => (name.clone(), ProbeTarget::Proxy(proxy)),
                None => (name.clone(), ProbeTarget::Missing),
            })
            .collect();
        if !targets
            .iter()
            .any(|(_, target)| matches!(target, ProbeTarget::Proxy(_)))
        {
            return Err(ModuleError::new(
                StatusCode::ModuleNotFound,
                ERR_NODE_NOT_FOUND,
                format!("none of the requested targets were found: {}", names.join(", ")),
            ));
        }
        (targets, None, None, None)
    } else {
        return Err(ModuleError::invalid_arg(
            "node.delay_test requires `node`, `group`, and/or `targets`",
        ));
    };

    let url = req
        .url
        .clone()
        .or(test_url)
        .unwrap_or_else(|| DEFAULT_TEST_URL.to_string());
    let expected = req.expected_status.clone().or(expected);
    Ok(ResolvedTargets {
        targets,
        group: group_label,
        url,
        expected,
    })
}

/// Probe every target with a sliding window of [`DELAY_PROBE_CONCURRENCY`]
/// in-flight probes, calling `on_probe` the moment each probe completes
/// (completion order) and returning every result once the window drains.
///
/// This is a streaming counterpart to meow's collect-all probe helper: the
/// callback lets `delay_test_arm` forward each node's `proxy.node.delay` event
/// immediately instead of bursting them all at the end. The per-probe work
/// (dial -> TLS -> GET, `ProxyHealth` recording, the global probe semaphore) is
/// still meow's `probe_and_record`, so success/error semantics are unchanged.
fn probe_delay_streaming<F>(
    targets: Vec<(String, Arc<dyn Proxy>)>,
    url: &str,
    expected: Option<&str>,
    timeout: Duration,
    mut on_probe: F,
) -> Vec<NamedProbeResult>
where
    F: FnMut(&NamedProbeResult),
{
    let rt = match ops_runtime() {
        Ok(rt) => rt,
        Err(e) => {
            log_message(format!("proxy: node.delay_test runtime unavailable: {e}"));
            let results: Vec<NamedProbeResult> = targets
                .into_iter()
                .map(|(name, _)| NamedProbeResult {
                    name,
                    delay: 0,
                    error: Some(UrlTestError::Transport("runtime unavailable".to_string())),
                })
                .collect();
            for result in &results {
                on_probe(result);
            }
            return results;
        }
    };
    let url = Arc::<str>::from(url.to_owned());
    let expected = expected.map(Arc::<str>::from);
    let concurrency = DELAY_PROBE_CONCURRENCY.max(1);

    rt.block_on(async move {
        let mut pending = futures::stream::iter(targets.into_iter().map(|(name, proxy)| {
            let url = Arc::clone(&url);
            let expected = expected.clone();
            async move {
                match probe_and_record(&proxy, url.as_ref(), expected.as_deref(), timeout).await {
                    Ok(delay) => NamedProbeResult {
                        name,
                        delay,
                        error: None,
                    },
                    Err(error) => NamedProbeResult {
                        name,
                        delay: 0,
                        error: Some(error),
                    },
                }
            }
        }))
        .buffer_unordered(concurrency);

        let mut results = Vec::new();
        while let Some(result) = pending.next().await {
            on_probe(&result);
            results.push(result);
        }
        results
    })
}

fn error_label(error: Option<&UrlTestError>) -> Option<String> {
    match error {
        None => None,
        Some(UrlTestError::Timeout) => Some("timeout".to_string()),
        Some(UrlTestError::Transport(m)) => Some(m.clone()),
    }
}

/// Emit one `proxy.node.delay` event for a probe result. Field names are the
/// frozen wire contract: `{group,node,delayMs,error?}`.
fn emit_delay_event(instance_id: u64, group: Option<&str>, result: &NamedProbeResult) {
    let error = error_label(result.error.as_ref());
    let event = json!({
        "group": group.unwrap_or_default(),
        "node": result.name.as_str(),
        "delayMs": if error.is_none() { result.delay as u64 } else { 0 },
        "error": error,
    });
    if let Ok(bytes) = serde_json::to_vec(&event) {
        crate::emit_event(instance_id, EVT_NODE_DELAY, &bytes);
    }
}

/// `node.delay_test` arm: probe every resolved target, emit one
/// `proxy.node.delay` event per node, and return a per-node result list. An
/// unreachable node is a `timeout` result, not a failed call.
pub(crate) fn delay_test_arm(
    instance_id: u64,
    payload: &[u8],
    data_dir: &str,
    cache_dir: &str,
) -> Result<Vec<u8>, ModuleError> {
    let req: DelayRequest = if payload.is_empty() {
        return Err(ModuleError::invalid_arg(
            "node.delay_test requires `node`, `group`, and/or `targets`",
        ));
    } else {
        serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!("node.delay_test payload must be JSON: {e}"))
        })?
    };
    if req.node.is_none() && req.group.is_none() && req.targets.is_none() {
        return Err(ModuleError::invalid_arg(
            "node.delay_test requires `node`, `group`, and/or `targets`",
        ));
    }
    let timeout_ms = req
        .timeout_ms
        .unwrap_or(DEFAULT_TIMEOUT_MS)
        .clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);

    // Probing only needs an outbound dial through the node, never a TUN, so fall
    // back to the offline registry when the engine is stopped (mirrors
    // `select_offline`).
    let (resolved, offline, profile_id) = match crate::rules::active_tunnel() {
        Some(tunnel) => (resolve_targets(|name| tunnel.proxy(name), &req)?, false, None),
        None => {
            let store = if data_dir.trim().is_empty() {
                None
            } else {
                Some(ensure_selector_store(data_dir))
            };
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
            let profile_id = generated.profile_id.clone();
            let (proxies, _warnings) =
                crate::config::build_registry(&generated.raw, store.as_ref());
            (
                resolve_targets(|name| proxies.get(name).cloned(), &req)?,
                true,
                profile_id,
            )
        }
    };
    let ResolvedTargets {
        targets,
        group: group_label,
        url,
        expected,
    } = resolved;

    let probes: Vec<(String, Arc<dyn Proxy>)> = targets
        .iter()
        .filter_map(|(name, target)| match target {
            ProbeTarget::Proxy(proxy) => Some((name.clone(), Arc::clone(proxy))),
            ProbeTarget::Missing => None,
        })
        .collect();
    let group_for_event = group_label.as_deref();
    let mut probed: HashMap<String, NamedProbeResult> = probe_delay_streaming(
        probes,
        &url,
        expected.as_deref(),
        Duration::from_millis(timeout_ms),
        |result| emit_delay_event(instance_id, group_for_event, result),
    )
    .into_iter()
    .map(|r| (r.name.clone(), r))
    .collect();

    let mut out = Vec::with_capacity(targets.len());
    for (name, target) in &targets {
        let result = match target {
            ProbeTarget::Proxy(_) => probed.remove(name).unwrap_or(NamedProbeResult {
                name: name.clone(),
                delay: 0,
                error: Some(UrlTestError::Transport("probe did not complete".to_string())),
            }),
            ProbeTarget::Missing => {
                let result = NamedProbeResult {
                    name: name.clone(),
                    delay: 0,
                    error: Some(UrlTestError::Transport("not found".to_string())),
                };
                emit_delay_event(instance_id, group_for_event, &result);
                result
            }
        };
        let error = error_label(result.error.as_ref());
        out.push(json!({
            "node": result.name,
            "delayMs": if error.is_none() { result.delay as u64 } else { 0 },
            "alive": error.is_none(),
            "error": error,
        }));
    }
    log_message(format!(
        "proxy: node.delay_test url={url} timeoutMs={timeout_ms} nodes={} path={} profile={}",
        out.len(),
        if offline { "offline" } else { "online" },
        profile_id.as_deref().unwrap_or("-")
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

    /// In-flight probe counter shared by every `StubProxy`, plus its high-water
    /// mark. Each proxy dials once, so only a global counter can observe the
    /// pool's width. Reset by the pool-bound test before it measures.
    static PROBE_INFLIGHT: AtomicU32 = AtomicU32::new(0);
    static PROBE_MAX_INFLIGHT: AtomicU32 = AtomicU32::new(0);

    /// Stub outbound: optionally records dials, optionally hangs forever (to
    /// exercise the delay-test timeout path without touching the network).
    pub(crate) struct StubProxy {
        name: String,
        health: ProxyHealth,
        hangs: bool,
        hold: Option<Duration>,
        dials: Mutex<Vec<String>>,
    }

    impl StubProxy {
        pub(crate) fn new(name: &str) -> Arc<StubProxy> {
            Self::build(name, false, None)
        }

        pub(crate) fn hanging(name: &str) -> Arc<StubProxy> {
            Self::build(name, true, None)
        }

        pub(crate) fn with_delay(name: &str, hold: Duration) -> Arc<StubProxy> {
            Self::build(name, false, Some(hold))
        }

        fn build(name: &str, hangs: bool, hold: Option<Duration>) -> Arc<StubProxy> {
            Arc::new(Self {
                name: name.to_string(),
                health: ProxyHealth::new(),
                hangs,
                hold,
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
            let inflight = PROBE_INFLIGHT.fetch_add(1, Ordering::SeqCst) + 1;
            PROBE_MAX_INFLIGHT.fetch_max(inflight, Ordering::SeqCst);
            if let Some(hold) = self.hold {
                tokio::time::sleep(hold).await;
            }
            if self.hangs {
                std::future::pending::<()>().await;
            }
            PROBE_INFLIGHT.fetch_sub(1, Ordering::SeqCst);
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
        let tunnel = crate::rules::active_tunnel().unwrap();

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

    /// Concurrency QA: `node.select` and a registry swap are serialized on the
    /// single mode lane, so a select can never resolve against the pre-swap
    /// registry and land its `set` on a stale group. The swapper thread takes the
    /// lane and holds it while a select is started; the select must park on the
    /// lane (proven by it not completing) instead of resolving the old group, and
    /// once the swap is applied and the lane released, it must succeed against
    /// the fresh registry. The old group stays untouched.
    #[test]
    fn select_serializes_with_registry_swap_on_lane() {
        use std::sync::mpsc;

        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let _ = crate::dispatch::build_engine(empty_resolver());
        let tunnel = crate::rules::active_tunnel().unwrap();

        // v1: the registry a racing select must NOT be allowed to resolve from.
        let store = SelectorStore::open(tmp_dir("swap-lane").join("selector.json"));
        let a1 = StubProxy::new("A");
        let b1 = StubProxy::new("B");
        let old_group = selector_group("G", &[&a1, &b1], &store);
        let mut old_map: HashMap<smol_str::SmolStr, Arc<dyn Proxy>> = HashMap::new();
        old_map.insert(smol_str::SmolStr::from("G"), Arc::clone(&old_group));
        old_map.insert(smol_str::SmolStr::from("A"), Arc::clone(&a1) as Arc<dyn Proxy>);
        old_map.insert(smol_str::SmolStr::from("B"), Arc::clone(&b1) as Arc<dyn Proxy>);
        tunnel.update_proxies(old_map);
        assert_eq!(old_group.current().as_deref(), Some("A"));

        // v2: a fresh registry with brand-new group/leaf objects (default "A").
        let a2 = StubProxy::new("A");
        let b2 = StubProxy::new("B");
        let new_group = selector_group("G", &[&a2, &b2], &store);
        let mut new_map: HashMap<smol_str::SmolStr, Arc<dyn Proxy>> = HashMap::new();
        new_map.insert(smol_str::SmolStr::from("G"), Arc::clone(&new_group));
        new_map.insert(smol_str::SmolStr::from("A"), Arc::clone(&a2) as Arc<dyn Proxy>);
        new_map.insert(smol_str::SmolStr::from("B"), Arc::clone(&b2) as Arc<dyn Proxy>);

        let (lane_held_tx, lane_held_rx) = mpsc::channel();
        let (swap_done_tx, swap_done_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();

        // The `config.apply` side: take the lane, then swap the registry while it
        // is still held (until main confirms the select is parked on the lane).
        let swapper_tunnel = Arc::clone(&tunnel);
        let swapper = std::thread::spawn(move || {
            let _lane = crate::mode::lane();
            lane_held_tx.send(()).unwrap();
            let _ = release_rx.recv_timeout(Duration::from_secs(5));
            swapper_tunnel.update_proxies(new_map);
            swap_done_tx.send(()).unwrap();
        });
        lane_held_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("swapper grabbed the lane");

        // The user side: `node.select` must park on the lane, not resolve v1.
        let (sel_tx, sel_rx) = mpsc::channel();
        let selector = std::thread::spawn(move || {
            let req = serde_json::to_vec(&json!({ "group": "G", "node": "B" })).unwrap();
            sel_tx.send(select(&req, "", "")).unwrap();
        });
        assert!(
            sel_rx.recv_timeout(Duration::from_millis(300)).is_err(),
            "select must wait for the lane, not resolve the pre-swap registry"
        );

        release_tx.send(()).expect("release the swapper");
        swap_done_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("registry swap completed");

        let (data, selection) = sel_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("select completed after the swap")
            .expect("select must succeed against the post-swap registry");
        assert_eq!(data["ok"], true);
        assert_eq!(data["active"], "B");
        assert_eq!(selection.active, "B");
        assert_eq!(
            new_group.current().as_deref(),
            Some("B"),
            "post-swap registry group must carry the selection"
        );
        assert_eq!(
            old_group.current().as_deref(),
            Some("A"),
            "the stale pre-swap group must be untouched"
        );

        selector.join().unwrap();
        swapper.join().unwrap();
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
        let results = probe_delay_streaming(
            targets,
            "http://127.0.0.1:1/",
            None,
            Duration::from_millis(100),
            |_| {},
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
            let results = probe_delay_streaming(
                targets,
                "http://127.0.0.1:1/",
                None,
                Duration::from_millis(50),
                |_| {},
            );
            assert_eq!(results.len(), 1);
            assert!(matches!(results[0].error, Some(UrlTestError::Timeout)));
        }
    }

    /// Incremental-emission QA: a slow probe must not hold back the events of
    /// faster probes — every result is delivered to the callback as it
    /// completes, long before the whole batch returns.
    #[test]
    fn delay_probe_emits_each_result_as_it_completes() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let start = std::time::Instant::now();
        let targets: Vec<(String, Arc<dyn Proxy>)> = vec![
            (
                "slow".to_string(),
                StubProxy::with_delay("slow", Duration::from_millis(300)) as Arc<dyn Proxy>,
            ),
            (
                "fast-1".to_string(),
                StubProxy::with_delay("fast-1", Duration::from_millis(0)) as Arc<dyn Proxy>,
            ),
            (
                "fast-2".to_string(),
                StubProxy::with_delay("fast-2", Duration::from_millis(0)) as Arc<dyn Proxy>,
            ),
            (
                "fast-3".to_string(),
                StubProxy::with_delay("fast-3", Duration::from_millis(0)) as Arc<dyn Proxy>,
            ),
            (
                "fast-4".to_string(),
                StubProxy::with_delay("fast-4", Duration::from_millis(0)) as Arc<dyn Proxy>,
            ),
        ];
        let mut emitted: Vec<(String, Duration)> = Vec::new();
        let results = probe_delay_streaming(
            targets,
            "http://127.0.0.1:1/",
            None,
            Duration::from_secs(5),
            |r| emitted.push((r.name.clone(), start.elapsed())),
        );
        let batch_done = start.elapsed();

        assert_eq!(results.len(), 5);
        assert_eq!(emitted.len(), 5, "one event per completed probe");
        let first_event = emitted.first().expect("at least one event").1;
        assert!(
            first_event + Duration::from_millis(100) < batch_done,
            "first event must fire well before the batch returns: first={first_event:?} batch={batch_done:?}"
        );
        assert_eq!(
            emitted.last().map(|(name, _)| name.as_str()),
            Some("slow"),
            "the slow probe must complete (and emit) last: {emitted:?}"
        );
    }

    /// Pool-bound QA: at most [`DELAY_PROBE_CONCURRENCY`] probes are ever in
    /// flight at once, no matter how many targets are queued.
    #[test]
    fn delay_probe_bounds_inflight_probes_to_five() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        PROBE_INFLIGHT.store(0, Ordering::SeqCst);
        PROBE_MAX_INFLIGHT.store(0, Ordering::SeqCst);
        let nodes: Vec<Arc<StubProxy>> = (0..12)
            .map(|i| StubProxy::with_delay(&format!("n{i}"), Duration::from_millis(50)))
            .collect();
        let targets: Vec<(String, Arc<dyn Proxy>)> = nodes
            .iter()
            .enumerate()
            .map(|(i, p)| (format!("n{i}"), Arc::clone(p) as Arc<dyn Proxy>))
            .collect();

        let results = probe_delay_streaming(
            targets,
            "http://127.0.0.1:1/",
            None,
            Duration::from_secs(5),
            |_| {},
        );
        assert_eq!(results.len(), 12);
        assert_eq!(DELAY_PROBE_CONCURRENCY, 5, "the queue width is exactly 5");
        let peak = PROBE_MAX_INFLIGHT.load(Ordering::SeqCst);
        assert_eq!(peak, 5, "exactly 5 probes run concurrently at peak");
    }

    /// Build a live engine and install a `name -> proxy` map, the online path.
    fn live_tunnel_with(entries: Vec<(&str, Arc<dyn Proxy>)>) -> Arc<meow_tunnel::Tunnel> {
        let _ = crate::dispatch::build_engine(empty_resolver());
        let tunnel = crate::rules::active_tunnel().unwrap();
        let mut map: HashMap<smol_str::SmolStr, Arc<dyn Proxy>> = HashMap::new();
        for (name, proxy) in entries {
            map.insert(smol_str::SmolStr::from(name), proxy);
        }
        tunnel.update_proxies(map);
        tunnel
    }

    /// `targets` probes exactly the named nodes and returns one result per name.
    #[test]
    fn delay_test_targets_list_probes_each_named_node() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        live_tunnel_with(vec![
            ("A", StubProxy::hanging("A") as Arc<dyn Proxy>),
            ("B", StubProxy::hanging("B") as Arc<dyn Proxy>),
        ]);

        let payload = br#"{"targets":["A","B"],"timeoutMs":100,"url":"http://127.0.0.1:1/"}"#;
        let out = delay_test_arm(0, payload, "", "").expect("targets batch must not fail");
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["timeoutMs"], 100);
        let results = v["data"]["results"].as_array().unwrap();
        assert_eq!(results.len(), 2, "one result per named target");
        assert_eq!(results[0]["node"], "A");
        assert_eq!(results[1]["node"], "B");
        assert!(
            results
                .iter()
                .all(|r| r["error"] == "timeout" && r["alive"] == false),
            "hanging targets are per-node timeouts: {v}"
        );

        crate::rules::reset_for_tests();
    }

    /// One stale name in `targets` becomes its own `not found` result while the
    /// known names still probe; the batch is never aborted.
    #[test]
    fn delay_test_targets_unknown_name_is_per_node_not_found() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        live_tunnel_with(vec![("A", StubProxy::hanging("A") as Arc<dyn Proxy>)]);

        let payload = br#"{"targets":["A","GHOST"],"timeoutMs":100,"url":"http://127.0.0.1:1/"}"#;
        let out = delay_test_arm(0, payload, "", "")
            .expect("one stale name must not abort the batch");
        let v: Value = serde_json::from_slice(&out).unwrap();
        let results = v["data"]["results"].as_array().unwrap();
        assert_eq!(results.len(), 2);
        let known = results.iter().find(|r| r["node"] == "A").unwrap();
        let ghost = results.iter().find(|r| r["node"] == "GHOST").unwrap();
        assert_eq!(known["error"], "timeout", "known node still probes: {v}");
        assert_eq!(ghost["error"], "not found");
        assert_eq!(ghost["alive"], false);

        crate::rules::reset_for_tests();
    }

    /// An empty selector is a structured 422 naming every accepted selector.
    #[test]
    fn delay_test_empty_selector_is_a_clear_422() {
        let err = delay_test_arm(0, b"{}", "", "").unwrap_err();
        assert_eq!(err.status, StatusCode::InvalidArgument);
        for option in ["node", "group", "targets"] {
            assert!(
                err.message.contains(option),
                "message must mention `{option}`: {}",
                err.message
            );
        }
    }

    /// With no engine but a stored profile, `delay_test` resolves targets from
    /// the offline registry instead of 422ing with `PROXY_NOT_CONFIGURED`.
    #[test]
    fn delay_test_offline_uses_stored_profile_without_engine() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        assert!(
            crate::rules::active_tunnel().is_none(),
            "precondition: engine must be stopped"
        );

        let data_dir = profile_dir("offline-delay", Vec::new());
        let payload = br#"{"node":"node-a","timeoutMs":100,"url":"http://127.0.0.1:1/"}"#;
        let out = delay_test_arm(0, payload, &data_dir, &data_dir)
            .expect("offline delay_test must resolve from the stored profile");
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["ok"], true);
        let results = v["data"]["results"].as_array().unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["node"], "node-a");
        assert_eq!(results[0]["alive"], false);

        crate::rules::reset_for_tests();
    }

    /// Regression: the offline `node.delay_test` path must resolve against the
    /// persisted active profile, not the earliest-imported one.
    #[test]
    fn offline_delay_test_uses_active_profile_not_first() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        assert!(
            crate::rules::active_tunnel().is_none(),
            "precondition: engine must be stopped"
        );

        let data_dir = profile_dir_with_active("offline-active-delay");

        let payload = br#"{"node":"new-node","timeoutMs":100,"url":"http://127.0.0.1:1/"}"#;
        let out = delay_test_arm(0, payload, &data_dir, &data_dir)
            .expect("the active profile's node must resolve offline");
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["results"][0]["node"], "new-node");

        let payload = br#"{"node":"old-node","timeoutMs":100,"url":"http://127.0.0.1:1/"}"#;
        let err = delay_test_arm(0, payload, &data_dir, &data_dir).unwrap_err();
        assert_eq!(
            err.code, ERR_NODE_NOT_FOUND,
            "the first profile's node must not resolve once a later profile is active"
        );

        crate::rules::reset_for_tests();
    }

    /// An omitted `timeoutMs` resolves to the 10s default.
    #[test]
    fn delay_test_default_timeout_is_ten_seconds() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        // The stub fails its dial immediately, so this does not wait 10s.
        live_tunnel_with(vec![("A", StubProxy::new("A") as Arc<dyn Proxy>)]);

        let payload = br#"{"node":"A","url":"http://127.0.0.1:1/"}"#;
        let out = delay_test_arm(0, payload, "", "").expect("fast-failing node is a per-node result");
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["timeoutMs"], 10_000);

        crate::rules::reset_for_tests();
    }

    /// A selector without a store still selects in-memory (only persistence is
    /// lost), and a non-selectable/leaf target is a structured error.
    #[test]
    fn select_errors_are_structured() {        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        let _ = crate::dispatch::build_engine(empty_resolver());
        let tunnel = crate::rules::active_tunnel().unwrap();
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
        let has_proxy_groups = !groups.is_empty();
        let profile = crate::subscription::ImportedProfile {
            name: "Offline".to_string(),
            format: "clash".to_string(),
            node_count: 2,
            nodes: vec![offline_node("node-a", 0), offline_node("node-b", 1)],
            groups,
            has_proxy_groups,
            rules: Vec::new(),
            userinfo: None,
            source: crate::subscription::ImportSource::default(),
            warnings: Vec::new(),
        };
        let payload = serde_json::to_vec(&json!({ "profile": &profile })).unwrap();
        store.create(&payload).unwrap();
        dir.display().to_string()
    }

    /// Persist two one-node profiles (`old-node` first, `new-node` later) and
    /// mark the later one active, returning its data dir. The later profile is
    /// deliberately NOT the first, so only the active pointer can select it.
    fn profile_dir_with_active(tag: &str) -> String {
        let dir = tmp_dir(tag);
        let data_dir = dir.display().to_string();
        let store = crate::profile::ProfileStore::open(&data_dir).unwrap();
        let create = |node: &str| {
            let profile = crate::subscription::ImportedProfile {
                name: format!("Profile-{node}"),
                format: "clash".to_string(),
                node_count: 1,
                nodes: vec![offline_node(node, 0)],
                groups: Vec::new(),
                has_proxy_groups: false,
                rules: Vec::new(),
                userinfo: None,
                source: crate::subscription::ImportSource::default(),
                warnings: Vec::new(),
            };
            let payload = serde_json::to_vec(&json!({ "profile": &profile })).unwrap();
            store.create(&payload).unwrap().id
        };
        create("old-node");
        let active = create("new-node");
        store.write_active_profile_id(&active);
        data_dir
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
        let tunnel = crate::rules::active_tunnel().unwrap();

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
