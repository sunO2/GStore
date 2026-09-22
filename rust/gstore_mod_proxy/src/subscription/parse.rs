//! Subscription format detection and parsers for Clash YAML (delegated to
//! meow), base64 URI lists, and plain URI lists.

use std::collections::HashMap;

use serde_yaml::Value as YamlValue;

use super::link::{b64_decode_flexible, parse_share_link};
use super::{
    format_unknown, no_nodes, parse_failed, too_large, GrpcParams, NodeSource, ProxyGroup, ProxyNode,
    RealityParams, WsParams,
};

const ALLOWED_CLASH_TYPES: [&str; 13] = [
    "ss",
    "ssr",
    "vmess",
    "vless",
    "trojan",
    "hysteria",
    "hysteria2",
    "anytls",
    "tuic",
    "snell",
    "http",
    "socks5",
    "wireguard",
];

pub(crate) const MAX_NODES: usize = 4096;

#[derive(Debug, Clone)]
pub(crate) struct ParsedContent {
    pub(crate) format: String,
    pub(crate) nodes: Vec<ProxyNode>,
    pub(crate) groups: Vec<ProxyGroup>,
    pub(crate) rules: Vec<String>,
    pub(crate) warnings: Vec<String>,
}

pub(crate) fn parse_subscription_text(
    text: &str,
    content_type: Option<&str>,
    origin: &str,
) -> Result<ParsedContent, gstore_contract::error::ModuleError> {
    let body = text.trim_start_matches('\u{feff}').trim();
    if body.is_empty() {
        return Err(parse_failed("empty subscription body"));
    }

    let wants_yaml = content_type
        .map(|ct| {
            let ct = ct.to_ascii_lowercase();
            ct.contains("yaml") || ct.contains("yml")
        })
        .unwrap_or(false);
    if wants_yaml || looks_like_clash(body) {
        let parsed = parse_clash(body, origin)?;
        if parsed.nodes.is_empty() {
            return Err(no_nodes("Clash subscription contained no importable proxies"));
        }
        return Ok(parsed);
    }

    if let Some(decoded) = decode_base64_text(body) {
        if decoded.contains("://") {
            return parse_uri_list(&decoded, "base64", origin);
        }
    }
    if body.contains("://") {
        return parse_uri_list(body, "uriList", origin);
    }
    Err(format_unknown(
        "could not detect Clash YAML, a base64 URI list, or a plain URI list",
    ))
}

fn looks_like_clash(body: &str) -> bool {
    body.lines().any(|line| {
        let line = line.trim_start();
        line.starts_with("proxies:")
            || line.starts_with("\"proxies\":")
            || line.starts_with("'proxies':")
    })
}

fn parse_clash(
    body: &str,
    origin: &str,
) -> Result<ParsedContent, gstore_contract::error::ModuleError> {
    let data = meow_config::subscription::parse_subscription_yaml(body)
        .map_err(|e| parse_failed(format!("Clash YAML parse error: {e}")))?;
    let mut nodes = Vec::new();
    let mut warnings = Vec::new();
    for (index, proxy) in data.proxies.iter().enumerate() {
        match node_from_clash_map(proxy, index, origin) {
            Ok(node) => nodes.push(node),
            Err(reason) => warnings.push(format!("proxies[{index}]: dropped node: {reason}")),
        }
    }
    let groups = data
        .proxy_groups
        .iter()
        .map(|group| ProxyGroup {
            name: group.name.clone(),
            group_type: group.group_type.clone(),
            members: group.proxies.clone().unwrap_or_default(),
        })
        .collect();
    Ok(ParsedContent {
        format: "clash".to_string(),
        nodes,
        groups,
        rules: data.rules,
        warnings,
    })
}

fn node_from_clash_map(
    map: &HashMap<String, YamlValue>,
    index: usize,
    origin: &str,
) -> Result<ProxyNode, String> {
    let node_type = map
        .get("type")
        .and_then(yaml_str)
        .ok_or_else(|| "missing 'type'".to_string())?;
    if node_type.eq_ignore_ascii_case("script") || map.contains_key("script") {
        return Err("script-type node rejected".to_string());
    }
    if !ALLOWED_CLASH_TYPES
        .iter()
        .any(|allowed| allowed.eq_ignore_ascii_case(&node_type))
    {
        return Err(format!("type '{node_type}' is not in the import whitelist"));
    }
    let server = map
        .get("server")
        .and_then(yaml_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "missing 'server'".to_string())?;
    let port = map
        .get("port")
        .and_then(yaml_u16)
        .filter(|port| *port != 0)
        .ok_or_else(|| "missing/invalid 'port'".to_string())?;
    let name = map
        .get("name")
        .and_then(yaml_str)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| format!("{server}:{port}"));
    let reality = map.get("reality-opts").map(|_| RealityParams {
        public_key: yaml_map_str(map, "reality-opts", "public-key"),
        short_id: yaml_map_str(map, "reality-opts", "short-id"),
        spider_x: yaml_map_str(map, "reality-opts", "spider-x"),
    });
    let tls = map.get("tls").and_then(yaml_bool).unwrap_or(false)
        || reality.is_some()
        || matches!(node_type.as_str(), "hysteria" | "hysteria2" | "trojan");
    let network = map
        .get("network")
        .or_else(|| map.get("net"))
        .and_then(yaml_str);
    let ws = map.get("ws-opts").map(|_| WsParams {
        path: yaml_map_str(map, "ws-opts", "path"),
        host: yaml_map_str(map, "ws-opts", "headers")
            .or_else(|| yaml_nested_map_str(map, "ws-opts", "headers", "Host")),
    });
    let grpc = map.get("grpc-opts").map(|_| GrpcParams {
        service_name: yaml_map_str(map, "grpc-opts", "grpc-service-name"),
    });
    Ok(ProxyNode {
        name,
        node_type,
        server,
        port,
        cipher: map.get("cipher").and_then(yaml_str),
        password: map.get("password").and_then(yaml_str),
        uuid: map.get("uuid").and_then(yaml_str),
        alter_id: map
            .get("alterId")
            .or_else(|| map.get("alter-id"))
            .and_then(yaml_u32),
        security: map
            .get("encryption")
            .or_else(|| map.get("security"))
            .or_else(|| map.get("cipher"))
            .and_then(yaml_str),
        flow: map.get("flow").and_then(yaml_str),
        network,
        tls,
        sni: map
            .get("sni")
            .or_else(|| map.get("servername"))
            .and_then(yaml_str),
        skip_cert_verify: map.get("skip-cert-verify").and_then(yaml_bool),
        alpn: map.get("alpn").and_then(yaml_string_list).unwrap_or_default(),
        fingerprint: map.get("client-fingerprint").and_then(yaml_str),
        reality,
        ws,
        grpc,
        obfs: map.get("obfs").and_then(yaml_str),
        obfs_password: map.get("obfs-password").and_then(yaml_str),
        groups: Vec::new(),
        source: NodeSource {
            format: "clash".to_string(),
            origin: origin.to_string(),
            index,
        },
    })
}

fn yaml_str(value: &YamlValue) -> Option<String> {
    match value {
        YamlValue::String(text) => Some(text.clone()),
        YamlValue::Number(number) => Some(number.to_string()),
        YamlValue::Bool(flag) => Some(flag.to_string()),
        _ => None,
    }
}

fn yaml_u16(value: &YamlValue) -> Option<u16> {
    match value {
        YamlValue::Number(number) => number.as_u64().and_then(|v| u16::try_from(v).ok()),
        other => yaml_str(other).and_then(|text| text.trim().parse().ok()),
    }
}

fn yaml_u32(value: &YamlValue) -> Option<u32> {
    match value {
        YamlValue::Number(number) => number.as_u64().and_then(|v| u32::try_from(v).ok()),
        other => yaml_str(other).and_then(|text| text.trim().parse().ok()),
    }
}

fn yaml_bool(value: &YamlValue) -> Option<bool> {
    match value {
        YamlValue::Bool(flag) => Some(*flag),
        other => yaml_str(other).and_then(|text| text.trim().parse().ok()),
    }
}

fn yaml_string_list(value: &YamlValue) -> Option<Vec<String>> {
    match value {
        YamlValue::Sequence(seq) => Some(seq.iter().filter_map(yaml_str).collect()),
        other => yaml_str(other).map(|text| {
            text.split(',')
                .map(|part| part.trim().to_string())
                .filter(|part| !part.is_empty())
                .collect()
        }),
    }
}

fn yaml_map_str(
    map: &HashMap<String, YamlValue>,
    outer: &str,
    inner: &str,
) -> Option<String> {
    map.get(outer)?
        .as_mapping()?
        .get(YamlValue::String(inner.to_string()))
        .and_then(yaml_str)
}

fn yaml_nested_map_str(
    map: &HashMap<String, YamlValue>,
    outer: &str,
    middle: &str,
    inner: &str,
) -> Option<String> {
    map.get(outer)?
        .as_mapping()?
        .get(YamlValue::String(middle.to_string()))?
        .as_mapping()?
        .get(YamlValue::String(inner.to_string()))
        .and_then(yaml_str)
}

fn parse_uri_list(
    text: &str,
    format: &str,
    origin: &str,
) -> Result<ParsedContent, gstore_contract::error::ModuleError> {
    let mut nodes = Vec::new();
    let mut warnings = Vec::new();
    let mut first_err: Option<gstore_contract::error::ModuleError> = None;
    for (line_index, raw_line) in text.lines().enumerate() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with("//") || line.starts_with(';')
        {
            continue;
        }
        match parse_share_link(line, nodes.len(), format, origin) {
            Ok(node) => nodes.push(node),
            Err(err) => {
                warnings.push(format!(
                    "line {}: {} ({})",
                    line_index + 1,
                    err.code,
                    err.message
                ));
                if first_err.is_none() {
                    first_err = Some(err);
                }
            }
        }
    }
    if nodes.is_empty() {
        return Err(first_err.unwrap_or_else(|| no_nodes("URI list contained no importable nodes")));
    }
    if nodes.len() > MAX_NODES {
        return Err(too_large(format!(
            "subscription contains more than {MAX_NODES} nodes"
        )));
    }
    Ok(ParsedContent {
        format: format.to_string(),
        nodes,
        groups: Vec::new(),
        rules: Vec::new(),
        warnings,
    })
}

fn decode_base64_text(value: &str) -> Option<String> {
    let compact: String = value
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    if compact.len() < 16 || !compact.bytes().all(is_base64_char) {
        return None;
    }
    b64_decode_flexible(&compact).and_then(|bytes| String::from_utf8(bytes).ok())
}

fn is_base64_char(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'=' | b'-' | b'_')
}
