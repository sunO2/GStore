//! Share-link parsers (`ss://`, `ss2022://`, `vmess://`, `vless://`,
//! `trojan://`, `hysteria2://`) that normalize into the canonical
//! [`ProxyNode`] model. meow does not parse share links, so this is ours.

use std::collections::HashMap;

use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine as _;
use gstore_contract::error::{ModuleError, StatusCode};

use super::{
    node_invalid, ERR_SCHEME_UNSUPPORTED, GrpcParams, NodeSource, ProxyNode, RealityParams, WsParams,
};

pub(crate) fn parse_share_link(
    link: &str,
    index: usize,
    format: &str,
    origin: &str,
) -> Result<ProxyNode, ModuleError> {
    let separator = link
        .find("://")
        .ok_or_else(|| node_invalid("share link is missing the '://' separator"))?;
    let scheme = link[..separator].to_ascii_lowercase();
    let rest = &link[separator + 3..];
    match scheme.as_str() {
        "ss" => parse_ss(rest, false, index, format, origin),
        "ss2022" => parse_ss(rest, true, index, format, origin),
        "vmess" => parse_vmess(rest, index, format, origin),
        "vless" => parse_vless(rest, index, format, origin),
        "trojan" => parse_trojan(rest, index, format, origin),
        "hysteria2" | "hy2" => parse_hysteria2(rest, index, format, origin),
        other => Err(ModuleError::new(
            StatusCode::InvalidArgument,
            ERR_SCHEME_UNSUPPORTED,
            format!("unsupported share-link scheme '{other}'"),
        )),
    }
}

fn source(format: &str, origin: &str, index: usize) -> NodeSource {
    NodeSource {
        format: format.to_string(),
        origin: origin.to_string(),
        index,
    }
}

fn name_or_default(name: Option<String>, server: &str, port: u16) -> String {
    name.filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| format!("{server}:{port}"))
}

fn parse_ss(
    rest: &str,
    is_2022: bool,
    index: usize,
    format: &str,
    origin: &str,
) -> Result<ProxyNode, ModuleError> {
    let (body, name) = split_fragment(rest);
    let (body, query) = split_query(&body);
    if let Some(query) = query {
        let query = query_map(Some(query));
        if query.get("plugin").is_some_and(|plugin| !plugin.trim().is_empty()) {
            return Err(node_invalid(
                "ss link declares an external SIP003 plugin (rejected)",
            ));
        }
    }
    let (method, password, host_port) = if let Some(at) = body.rfind('@') {
        let userinfo = &body[..at];
        let host_port = &body[at + 1..];
        let decoded = b64_decode_flexible(userinfo)
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .or_else(|| Some(percent_decode(userinfo)));
        let (method, password) = decoded
            .as_deref()
            .and_then(|decoded| decoded.split_once(':'))
            .ok_or_else(|| node_invalid("ss userinfo must be base64(method:password)"))?;
        (method.to_string(), password.to_string(), host_port.to_string())
    } else {
        let decoded = b64_decode_flexible(&body)
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .ok_or_else(|| node_invalid("ss legacy link must be base64(method:password@host:port)"))?;
        let (credentials, host_port) = decoded
            .rsplit_once('@')
            .ok_or_else(|| node_invalid("ss legacy link is missing '@host'"))?;
        let (method, password) = credentials
            .split_once(':')
            .ok_or_else(|| node_invalid("ss legacy link is missing 'method:password'"))?;
        (method.to_string(), password.to_string(), host_port.to_string())
    };
    let (server, port) = parse_host_port(&host_port)?;
    let method = method.trim().to_string();
    if method.is_empty() {
        return Err(node_invalid("ss link is missing the cipher method"));
    }
    let cipher = if is_2022 && !method.contains("2022") {
        format!("2022-blake3-{method}")
    } else {
        method
    };
    Ok(ProxyNode {
        name: name_or_default(name, &server, port),
        node_type: "ss".to_string(),
        server,
        port,
        cipher: Some(cipher),
        password: Some(password),
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
        source: source(format, origin, index),
    })
}

fn parse_vmess(
    rest: &str,
    index: usize,
    format: &str,
    origin: &str,
) -> Result<ProxyNode, ModuleError> {
    let (body, fragment_name) = split_fragment(rest);
    let decoded =
        b64_decode_flexible(&body).ok_or_else(|| node_invalid("vmess link must be base64(JSON)"))?;
    let json: serde_json::Value =
        serde_json::from_slice(&decoded).map_err(|e| node_invalid(format!("vmess JSON: {e}")))?;
    let server = json_str(&json, "add").ok_or_else(|| node_invalid("vmess JSON missing 'add'"))?;
    let port = json_u16(&json, "port").ok_or_else(|| node_invalid("vmess JSON missing 'port'"))?;
    let uuid = json_str(&json, "id").ok_or_else(|| node_invalid("vmess JSON missing 'id'"))?;
    let network = json_str(&json, "net");
    let ws = (network.as_deref() == Some("ws")).then(|| WsParams {
        path: json_str(&json, "path"),
        host: json_str(&json, "host"),
    });
    let grpc = (network.as_deref() == Some("grpc")).then(|| GrpcParams {
        service_name: json_str(&json, "path"),
    });
    let name = fragment_name
        .filter(|value| !value.trim().is_empty())
        .or_else(|| json_str(&json, "ps"))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| format!("{server}:{port}"));
    let tls = json_bool(&json, "tls").unwrap_or(false)
        || json_str(&json, "tls").is_some_and(|value| value.eq_ignore_ascii_case("tls"));
    Ok(ProxyNode {
        name,
        node_type: "vmess".to_string(),
        server,
        port,
        cipher: None,
        password: None,
        uuid: Some(uuid),
        alter_id: json_u32(&json, "aid"),
        security: json_str(&json, "scy"),
        flow: None,
        network,
        tls,
        sni: json_str(&json, "sni").or_else(|| json_str(&json, "host")),
        skip_cert_verify: None,
        alpn: json_str(&json, "alpn").as_deref().map(split_csv).unwrap_or_default(),
        fingerprint: json_str(&json, "fp"),
        reality: None,
        ws,
        grpc,
        obfs: None,
        obfs_password: None,
        udp: None,
        groups: Vec::new(),
        source: source(format, origin, index),
    })
}

fn parse_vless(
    rest: &str,
    index: usize,
    format: &str,
    origin: &str,
) -> Result<ProxyNode, ModuleError> {
    let (body, fragment_name) = split_fragment(rest);
    let (body, query) = split_query(&body);
    let (uuid, host_port) = body
        .rsplit_once('@')
        .ok_or_else(|| node_invalid("vless link is missing 'uuid@host:port'"))?;
    let (server, port) = parse_host_port(host_port)?;
    let query = query_map(query);
    let security = query_get(&query, &["security"]).unwrap_or("none").to_string();
    let reality = (security == "reality").then(|| RealityParams {
        public_key: query_get(&query, &["pbk"]).map(str::to_string),
        short_id: query_get(&query, &["sid"]).map(str::to_string),
        spider_x: query_get(&query, &["spx"]).map(str::to_string),
    });
    let network = query_get(&query, &["type"]).unwrap_or("tcp").to_string();
    let ws = (network == "ws").then(|| WsParams {
        path: query_get(&query, &["path"]).map(str::to_string),
        host: query_get(&query, &["host"]).map(str::to_string),
    });
    let grpc = (network == "grpc").then(|| GrpcParams {
        service_name: query_get(&query, &["serviceName"]).map(str::to_string),
    });
    let tls = matches!(security.as_str(), "tls" | "reality" | "xtls")
        || query_get(&query, &["sni", "peer"]).is_some();
    Ok(ProxyNode {
        name: name_or_default(fragment_name, &server, port),
        node_type: "vless".to_string(),
        server,
        port,
        cipher: None,
        password: None,
        uuid: Some(uuid.to_string()),
        alter_id: None,
        security: query_get(&query, &["encryption"]).map(str::to_string),
        flow: query_get(&query, &["flow"]).map(str::to_string),
        network: Some(network),
        tls,
        sni: query_get(&query, &["sni", "peer"]).map(str::to_string),
        skip_cert_verify: query_bool(&query, &["allowInsecure", "insecure"]),
        alpn: query_list(&query, &["alpn"]),
        fingerprint: query_get(&query, &["fp"]).map(str::to_string),
        reality,
        ws,
        grpc,
        obfs: None,
        obfs_password: None,
        udp: None,
        groups: Vec::new(),
        source: source(format, origin, index),
    })
}

fn parse_trojan(
    rest: &str,
    index: usize,
    format: &str,
    origin: &str,
) -> Result<ProxyNode, ModuleError> {
    let (body, fragment_name) = split_fragment(rest);
    let (body, query) = split_query(&body);
    let (password, host_port) = body
        .rsplit_once('@')
        .ok_or_else(|| node_invalid("trojan link is missing 'password@host:port'"))?;
    let (server, port) = parse_host_port(host_port)?;
    let query = query_map(query);
    let security = query_get(&query, &["security"]).unwrap_or("tls").to_string();
    Ok(ProxyNode {
        name: name_or_default(fragment_name, &server, port),
        node_type: "trojan".to_string(),
        server,
        port,
        cipher: None,
        password: Some(percent_decode(password)),
        uuid: None,
        alter_id: None,
        security: None,
        flow: None,
        network: query_get(&query, &["type"]).map(str::to_string),
        tls: security != "none",
        sni: query_get(&query, &["sni", "peer"]).map(str::to_string),
        skip_cert_verify: query_bool(&query, &["allowInsecure", "insecure"]),
        alpn: query_list(&query, &["alpn"]),
        fingerprint: query_get(&query, &["fp"]).map(str::to_string),
        reality: None,
        ws: None,
        grpc: None,
        obfs: None,
        obfs_password: None,
        udp: None,
        groups: Vec::new(),
        source: source(format, origin, index),
    })
}

fn parse_hysteria2(
    rest: &str,
    index: usize,
    format: &str,
    origin: &str,
) -> Result<ProxyNode, ModuleError> {
    let (body, fragment_name) = split_fragment(rest);
    let (body, query) = split_query(&body);
    let (credentials, host_port) = body
        .rsplit_once('@')
        .ok_or_else(|| node_invalid("hysteria2 link is missing 'password@host:port'"))?;
    let (server, port) = parse_host_port(host_port)?;
    let query = query_map(query);
    let password = credentials
        .rsplit_once(':')
        .map(|(_, password)| password)
        .unwrap_or(credentials);
    Ok(ProxyNode {
        name: name_or_default(fragment_name, &server, port),
        node_type: "hysteria2".to_string(),
        server,
        port,
        cipher: None,
        password: Some(percent_decode(password)),
        uuid: None,
        alter_id: None,
        security: None,
        flow: None,
        network: None,
        tls: true,
        sni: query_get(&query, &["sni", "peer"]).map(str::to_string),
        skip_cert_verify: query_bool(&query, &["insecure", "allowInsecure"]),
        alpn: query_list(&query, &["alpn"]),
        fingerprint: None,
        reality: None,
        ws: None,
        grpc: None,
        obfs: query_get(&query, &["obfs"]).map(str::to_string),
        obfs_password: query_get(&query, &["obfs-password", "obfsPassword"]).map(str::to_string),
        udp: None,
        groups: Vec::new(),
        source: source(format, origin, index),
    })
}

fn split_fragment(rest: &str) -> (String, Option<String>) {
    match rest.split_once('#') {
        Some((body, fragment)) => (body.to_string(), Some(percent_decode(fragment))),
        None => (rest.to_string(), None),
    }
}

fn split_query(body: &str) -> (String, Option<String>) {
    match body.split_once('?') {
        Some((head, query)) => (head.to_string(), Some(query.to_string())),
        None => (body.to_string(), None),
    }
}

fn query_map(query: Option<String>) -> HashMap<String, String> {
    let mut map = HashMap::new();
    if let Some(query) = query {
        for pair in query.split('&') {
            if let Some((key, value)) = pair.split_once('=') {
                map.insert(key.trim().to_string(), percent_decode(value));
            } else if !pair.trim().is_empty() {
                map.insert(pair.trim().to_string(), String::new());
            }
        }
    }
    map
}

fn query_get<'a>(map: &'a HashMap<String, String>, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|key| map.get(*key))
        .map(String::as_str)
}

fn query_bool(map: &HashMap<String, String>, keys: &[&str]) -> Option<bool> {
    query_get(map, keys)
        .map(|value| matches!(value.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
}

fn query_list(map: &HashMap<String, String>, keys: &[&str]) -> Vec<String> {
    query_get(map, keys)
        .map(split_csv)
        .unwrap_or_default()
}

fn split_csv(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(|part| part.trim().to_string())
        .filter(|part| !part.is_empty())
        .collect()
}

pub(crate) fn parse_host_port(value: &str) -> Result<(String, u16), ModuleError> {
    let value = value.trim();
    if let Some(rest) = value.strip_prefix('[') {
        let (host, after) = rest
            .split_once(']')
            .ok_or_else(|| node_invalid("invalid IPv6 host in link"))?;
        let port = after
            .strip_prefix(':')
            .ok_or_else(|| node_invalid("link is missing the port"))?
            .parse::<u16>()
            .map_err(|_| node_invalid("link port is not a valid number"))?;
        if host.is_empty() || port == 0 {
            return Err(node_invalid("link has an empty host or port 0"));
        }
        return Ok((host.to_string(), port));
    }
    let (host, port) = value
        .rsplit_once(':')
        .ok_or_else(|| node_invalid("link is missing 'host:port'"))?;
    let port = port
        .parse::<u16>()
        .map_err(|_| node_invalid("link port is not a valid number"))?;
    if host.is_empty() || port == 0 {
        return Err(node_invalid("link has an empty host or port 0"));
    }
    Ok((host.to_string(), port))
}

pub(super) fn b64_decode_flexible(value: &str) -> Option<Vec<u8>> {
    let compact: String = value
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    if compact.is_empty() {
        return None;
    }
    for engine in [&STANDARD, &STANDARD_NO_PAD, &URL_SAFE, &URL_SAFE_NO_PAD] {
        if let Ok(bytes) = engine.decode(compact.as_bytes()) {
            return Some(bytes);
        }
    }
    None
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(high), Some(low)) = (hex_value(bytes[i + 1]), hex_value(bytes[i + 2])) {
                out.push(high * 16 + low);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn json_str(value: &serde_json::Value, key: &str) -> Option<String> {
    match value.get(key)? {
        serde_json::Value::String(text) => Some(text.clone()),
        serde_json::Value::Number(number) => Some(number.to_string()),
        serde_json::Value::Bool(flag) => Some(flag.to_string()),
        _ => None,
    }
}

fn json_u16(value: &serde_json::Value, key: &str) -> Option<u16> {
    match value.get(key)? {
        serde_json::Value::Number(number) => number.as_u64().and_then(|v| u16::try_from(v).ok()),
        serde_json::Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

fn json_u32(value: &serde_json::Value, key: &str) -> Option<u32> {
    match value.get(key)? {
        serde_json::Value::Number(number) => number.as_u64().and_then(|v| u32::try_from(v).ok()),
        serde_json::Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

fn json_bool(value: &serde_json::Value, key: &str) -> Option<bool> {
    match value.get(key)? {
        serde_json::Value::Bool(flag) => Some(*flag),
        serde_json::Value::String(text) => text.trim().parse().ok(),
        serde_json::Value::Number(number) => Some(number.as_u64().unwrap_or(0) != 0),
        _ => None,
    }
}
