//! Subscription fetching and multi-format parsing (Todo 11 of the proxy kernel
//! plan).
//!
//! Three entry points feed the canonical profile model in [`model`]:
//!
//! * [`import_url`] — fetch a subscription over **meow's protect-aware
//!   transport** (never a raw `reqwest` client, which would bypass
//!   `VpnService.protect` and loop inside the tunnel), then parse it.
//! * [`import_text`] — parse an already-fetched body.
//! * [`import_link`] — parse a single share link.
//!
//! ## Why not `meow_config::internal_http::fetch`?
//!
//! meow's client is body-only: it returns `Vec<u8>` and discards the response
//! headers, so `Subscription-Userinfo` and `Content-Disposition` cannot be
//! read. Its body cap is also fixed at 256 MiB (`fetch_capped` is private), so
//! a stricter pre-cap cannot be requested. We therefore reuse meow's
//! **transport** primitives directly — `meow_common::connect_tcp_host`
//! (applies the host `SocketProtector` / resolver hook) and
//! `meow_transport::tls::TlsLayer` (the same BoringSSL stack, certificate
//! verification always on) — while delegating all YAML parsing to
//! `meow_config::subscription::parse_subscription_yaml` (no second parser).
//!
//! ## Security invariants (untrusted external text)
//!
//! See `fetch` for the network hardening and `parse` for the content
//! whitelisting.

mod fetch;
mod link;
mod model;
mod parse;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_fetch;
#[cfg(test)]
mod tests_pipeline;

pub(crate) use fetch::redact_url;
pub(crate) use link::parse_share_link;
pub(crate) use model::*;
pub(crate) use parse::parse_subscription_text;

use gstore_contract::error::{ModuleError, StatusCode};
use serde::Deserialize;
use std::sync::OnceLock;

pub(crate) const ERR_URL_INVALID: &str = "PROXY_SUB_URL_INVALID";
pub(crate) const ERR_SSRF_BLOCKED: &str = "PROXY_SUB_SSRF_BLOCKED";
pub(crate) const ERR_FETCH_FAILED: &str = "PROXY_SUB_FETCH_FAILED";
pub(crate) const ERR_TOO_LARGE: &str = "PROXY_SUB_TOO_LARGE";
pub(crate) const ERR_FORMAT_UNKNOWN: &str = "PROXY_SUB_FORMAT_UNKNOWN";
pub(crate) const ERR_PARSE_FAILED: &str = "PROXY_SUB_PARSE_FAILED";
pub(crate) const ERR_NODE_INVALID: &str = "PROXY_SUB_NODE_INVALID";
pub(crate) const ERR_SCHEME_UNSUPPORTED: &str = "PROXY_SUB_SCHEME_UNSUPPORTED";
pub(crate) const ERR_NO_NODES: &str = "PROXY_SUB_NO_NODES";

const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;
const MAX_TEXT_BYTES: usize = 16 * 1024 * 1024;
const MAX_LINK_BYTES: usize = 16 * 1024;
const MAX_NODES: usize = 4096;

/// Providers vary their output by `User-Agent`; a Clash-style UA gets Clash
/// YAML, a browser UA often gets a base64 URI list. Retried in order until one
/// yields an importable node set.
const USER_AGENTS: [&str; 3] = [
    "clash.meta/1.19.0",
    "mihomo/1.19.0",
    "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36",
];

static SUB_RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn sub_runtime() -> Result<&'static tokio::runtime::Runtime, ModuleError> {
    if let Some(rt) = SUB_RUNTIME.get() {
        return Ok(rt);
    }
    let rt = crate::bounded_runtime()
        .map_err(|e| ModuleError::internal(format!("subscription runtime build: {e}")))?;
    let _ = SUB_RUNTIME.set(rt);
    Ok(SUB_RUNTIME.get().expect("runtime set above"))
}

fn url_invalid(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_URL_INVALID, message)
}

fn ssrf_blocked(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_SSRF_BLOCKED, message)
}

fn fetch_failed(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InternalError, ERR_FETCH_FAILED, message)
}

fn too_large(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::ResourceExhausted, ERR_TOO_LARGE, message)
}

fn format_unknown(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_FORMAT_UNKNOWN, message)
}

fn parse_failed(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_PARSE_FAILED, message)
}

fn node_invalid(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_NODE_INVALID, message)
}

fn no_nodes(message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InvalidArgument, ERR_NO_NODES, message)
}

fn parse_json<T: for<'de> Deserialize<'de>>(payload: &[u8]) -> Result<T, ModuleError> {
    if payload.is_empty() {
        return Err(ModuleError::invalid_arg("payload must be a JSON object"));
    }
    serde_json::from_slice(payload)
        .map_err(|e| ModuleError::invalid_arg(format!("payload JSON: {e}")))
}

pub(crate) fn import_url(payload: &[u8]) -> Result<ImportedProfile, ModuleError> {
    import_url_policy(payload, false)
}

/// Test seam: `allow_private` disables the SSRF guard so a loopback fixture
/// server can be imported in `cargo test`. Production always calls
/// [`import_url`] with the guard on.
pub(crate) fn import_url_policy(
    payload: &[u8],
    allow_private: bool,
) -> Result<ImportedProfile, ModuleError> {
    let req: ImportUrlRequest = parse_json(payload)?;
    let url = req.url.trim().to_string();
    fetch::parse_http_url(&url)?;
    let opts = fetch::FetchOptions {
        allow_private_targets: allow_private,
        max_bytes: MAX_BODY_BYTES,
        user_agents: user_agents(req.user_agent.as_deref()),
    };
    sub_runtime()?.block_on(fetch::fetch_and_parse(&url, req.name.as_deref(), &opts))
}

pub(crate) fn import_text(payload: &[u8]) -> Result<ImportedProfile, ModuleError> {
    let req: ImportTextRequest = parse_json(payload)?;
    if req.text.len() > MAX_TEXT_BYTES {
        return Err(too_large(format!(
            "subscription text exceeds {MAX_TEXT_BYTES} bytes"
        )));
    }
    let parsed = parse_subscription_text(&req.text, req.content_type.as_deref(), "text")?;
    let source = ImportSource {
        origin: "text".to_string(),
        bytes: Some(req.text.len()),
        content_type: req.content_type,
        ..ImportSource::default()
    };
    finalize(req.name.as_deref(), "subscription", parsed, source, None)
}

pub(crate) fn import_link(payload: &[u8]) -> Result<ImportedProfile, ModuleError> {
    let req: ImportLinkRequest = parse_json(payload)?;
    let link = req.link.trim();
    if link.len() > MAX_LINK_BYTES {
        return Err(too_large(format!(
            "share link exceeds {MAX_LINK_BYTES} bytes"
        )));
    }
    let node = parse_share_link(link, 0, "shareLink", "link")?;
    let fallback = node.name.clone();
    let parsed = parse::ParsedContent {
        format: "shareLink".to_string(),
        nodes: vec![node],
        groups: Vec::new(),
        rules: Vec::new(),
        warnings: Vec::new(),
    };
    let source = ImportSource {
        origin: "link".to_string(),
        bytes: Some(link.len()),
        ..ImportSource::default()
    };
    finalize(req.name.as_deref(), &fallback, parsed, source, None)
}

fn user_agents(custom: Option<&str>) -> Vec<String> {
    match custom.map(str::trim).filter(|ua| !ua.is_empty()) {
        Some(ua) => vec![ua.to_string()],
        None => USER_AGENTS.iter().map(|s| (*s).to_string()).collect(),
    }
}

fn finalize(
    name: Option<&str>,
    fallback_name: &str,
    parsed: parse::ParsedContent,
    source: ImportSource,
    userinfo: Option<SubscriptionUserinfo>,
) -> Result<ImportedProfile, ModuleError> {
    let mut parsed = parsed;
    if parsed.nodes.len() > MAX_NODES {
        return Err(too_large(format!(
            "subscription contains more than {MAX_NODES} nodes"
        )));
    }
    if parsed.nodes.is_empty() {
        return Err(no_nodes("subscription contained no importable nodes"));
    }
    let has_proxy_groups = !parsed.groups.is_empty();
    if parsed.groups.is_empty() {
        parsed.groups.push(ProxyGroup {
            name: "PROXY".to_string(),
            group_type: "select".to_string(),
            members: parsed.nodes.iter().map(|node| node.name.clone()).collect(),
        });
        parsed
            .warnings
            .push("source declared no proxy-groups; synthesized a 'PROXY' select group".to_string());
    }
    let group_snapshot = parsed.groups.clone();
    for node in &mut parsed.nodes {
        node.groups = group_snapshot
            .iter()
            .filter(|group| group.members.iter().any(|member| member == &node.name))
            .map(|group| group.name.clone())
            .collect();
    }
    let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
    for node in &parsed.nodes {
        if !seen.insert(node.name.as_str()) {
            parsed.warnings.push(format!(
                "duplicate node name '{}' (the engine registry keeps the last one)",
                node.name
            ));
        }
    }
    let profile_name = name
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(sanitize_name)
        .unwrap_or_else(|| sanitize_name(fallback_name));
    let profile_name = if profile_name.is_empty() {
        "subscription".to_string()
    } else {
        profile_name
    };
    Ok(ImportedProfile {
        name: profile_name,
        format: parsed.format,
        node_count: parsed.nodes.len(),
        nodes: parsed.nodes,
        groups: parsed.groups,
        has_proxy_groups,
        rules: parsed.rules,
        userinfo,
        source,
        warnings: parsed.warnings,
    })
}

fn sanitize_name(raw: &str) -> String {
    let base = raw
        .rsplit(|c| c == '/' || c == '\\')
        .next()
        .unwrap_or(raw)
        .trim()
        .trim_matches('"');
    let cleaned: String = base.chars().filter(|c| !c.is_control()).collect();
    if cleaned.chars().count() > 128 {
        cleaned.chars().take(128).collect()
    } else {
        cleaned
    }
}

fn strip_extension(name: &str) -> String {
    for ext in [".yaml", ".yml", ".txt", ".json", ".conf"] {
        if let Some(stripped) = name.strip_suffix(ext) {
            return stripped.to_string();
        }
    }
    name.to_string()
}
