//! Protect-aware HTTP fetch for subscription URLs.
//!
//! Dials through `meow_common::connect_tcp_host` (so the host
//! `SocketProtector` / resolver hook applies on every hop) and upgrades HTTPS
//! with `meow_transport::tls::TlsLayer` (BoringSSL, certificate verification
//! always on). No `reqwest`, no `danger_accept_invalid_certs`.
//!
//! Hardening: scheme allow-list, SSRF guard re-checked per redirect hop,
//! redirect cap, connect/read timeouts, streaming body cap, and rejection of
//! any `Content-Encoding` other than `identity` (so a gzip bomb is never
//! decompressed).

use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

use meow_transport::tls::{TlsConfig, TlsLayer};
use meow_transport::{Stream, Transport as _};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use url::Url;

use super::{
    fetch_failed, finalize, parse_failed, parse_subscription_text, ssrf_blocked, strip_extension,
    too_large, url_invalid, ImportSource, ImportedProfile, SubscriptionUserinfo, ERR_SSRF_BLOCKED,
    ERR_TOO_LARGE, ERR_URL_INVALID,
};

const MAX_REDIRECTS: u8 = 5;
const MAX_HEADER_BYTES: usize = 64 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const READ_TIMEOUT: Duration = Duration::from_secs(60);

pub(crate) struct FetchOptions {
    pub(crate) allow_private_targets: bool,
    pub(crate) max_bytes: usize,
    pub(crate) user_agents: Vec<String>,
}

struct HttpResponse {
    headers: Vec<(String, String)>,
    body: Vec<u8>,
    final_url: String,
}

struct RawResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

fn is_hard_error(err: &gstore_contract::error::ModuleError) -> bool {
    let code = err.code.as_ref();
    code == ERR_URL_INVALID || code == ERR_SSRF_BLOCKED || code == ERR_TOO_LARGE
}

pub(crate) async fn fetch_and_parse(
    url: &str,
    name: Option<&str>,
    opts: &FetchOptions,
) -> Result<ImportedProfile, gstore_contract::error::ModuleError> {
    use gstore_contract::error::ModuleError;
    let mut last_err: Option<ModuleError> = None;
    for ua in &opts.user_agents {
        let resp = match fetch_with_headers(url, ua, opts).await {
            Ok(resp) => resp,
            Err(e) => {
                if is_hard_error(&e) {
                    return Err(e);
                }
                last_err = Some(e);
                continue;
            }
        };
        let userinfo = header_value(&resp.headers, "subscription-userinfo")
            .and_then(parse_subscription_userinfo);
        let filename =
            header_value(&resp.headers, "content-disposition").and_then(parse_content_disposition);
        let content_type = header_value(&resp.headers, "content-type").map(str::to_string);
        let text = match std::str::from_utf8(&resp.body) {
            Ok(text) => text.trim_start_matches('\u{feff}'),
            Err(e) => {
                last_err = Some(parse_failed(format!(
                    "subscription body is not UTF-8: {e}"
                )));
                continue;
            }
        };
        match parse_subscription_text(text, content_type.as_deref(), "url") {
            Ok(parsed) => {
                let source = ImportSource {
                    origin: "url".to_string(),
                    url: Some(url.to_string()),
                    final_url: Some(resp.final_url.clone()),
                    filename: filename.clone(),
                    user_agent: Some(ua.clone()),
                    fetched_at_ms: Some(crate::now_ms()),
                    bytes: Some(resp.body.len()),
                    content_type,
                };
                let fallback = filename
                    .as_deref()
                    .map(strip_extension)
                    .or_else(|| {
                        Url::parse(url)
                            .ok()
                            .and_then(|parsed| parsed.host_str().map(str::to_string))
                    })
                    .unwrap_or_else(|| "subscription".to_string());
                return finalize(name, &fallback, parsed, source, userinfo);
            }
            Err(e) => {
                last_err = Some(e);
            }
        }
    }
    Err(last_err.unwrap_or_else(|| fetch_failed("no user agents configured")))
}

async fn fetch_with_headers(
    raw_url: &str,
    user_agent: &str,
    opts: &FetchOptions,
) -> Result<HttpResponse, gstore_contract::error::ModuleError> {
    let mut current = parse_http_url(raw_url)?;
    for _ in 0..=MAX_REDIRECTS {
        let resp = fetch_one(&current, user_agent, opts).await?;
        if (300..400).contains(&resp.status) {
            let location = header_value(&resp.headers, "location").ok_or_else(|| {
                fetch_failed(format!(
                    "HTTP {} redirect without Location header",
                    resp.status
                ))
            })?;
            let next = current
                .join(location)
                .map_err(|e| url_invalid(format!("bad redirect Location '{location}': {e}")))?;
            if next.scheme() != "http" && next.scheme() != "https" {
                return Err(url_invalid(format!(
                    "redirect to unsupported scheme '{}'",
                    next.scheme()
                )));
            }
            current = next;
            continue;
        }
        if !(200..300).contains(&resp.status) {
            return Err(fetch_failed(format!("HTTP {} from {current}", resp.status)));
        }
        return Ok(HttpResponse {
            headers: resp.headers,
            body: resp.body,
            final_url: current.to_string(),
        });
    }
    Err(fetch_failed(format!("too many redirects (> {MAX_REDIRECTS})")))
}

async fn fetch_one(
    url: &Url,
    user_agent: &str,
    opts: &FetchOptions,
) -> Result<RawResponse, gstore_contract::error::ModuleError> {
    ensure_target_allowed(url, opts.allow_private_targets).await?;
    let is_https = url.scheme() == "https";
    let host = url
        .host_str()
        .ok_or_else(|| url_invalid(format!("URL has no host: {url}")))?
        .to_string();
    let port = url
        .port_or_known_default()
        .ok_or_else(|| url_invalid(format!("URL has no port: {url}")))?;
    let path_and_query = match url.query() {
        Some(query) => format!("{}?{query}", url.path()),
        None => url.path().to_string(),
    };

    let conn = tokio::time::timeout(CONNECT_TIMEOUT, meow_common::connect_tcp_host(&host, port))
        .await
        .map_err(|_| {
            fetch_failed(format!(
                "connect to {host}:{port} timed out after {CONNECT_TIMEOUT:?}"
            ))
        })?
        .map_err(|e| fetch_failed(format!("connect to {host}:{port}: {e}")))?;

    let mut stream: Box<dyn Stream> = if is_https {
        let tls = TlsLayer::new(&TlsConfig::new(host.clone()))
            .map_err(|e| fetch_failed(format!("TLS init for '{host}': {e}")))?;
        tokio::time::timeout(CONNECT_TIMEOUT, tls.connect(Box::new(conn)))
            .await
            .map_err(|_| fetch_failed(format!("TLS handshake to {host} timed out")))?
            .map_err(|e| fetch_failed(format!("TLS handshake to {host}: {e}")))?
    } else {
        Box::new(conn)
    };

    let default_port = if is_https { 443 } else { 80 };
    let host_header = if port == default_port {
        host.clone()
    } else {
        format!("{host}:{port}")
    };
    let request = format!(
        "GET {path_and_query} HTTP/1.1\r\nHost: {host_header}\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\nUser-Agent: {user_agent}\r\n\r\n"
    );
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|e| fetch_failed(format!("write request: {e}")))?;
    stream
        .flush()
        .await
        .map_err(|e| fetch_failed(format!("flush request: {e}")))?;

    let read_cap = opts.max_bytes.saturating_add(MAX_HEADER_BYTES);
    let raw = tokio::time::timeout(READ_TIMEOUT, read_capped(&mut stream, read_cap))
        .await
        .map_err(|_| fetch_failed(format!("response read timed out after {READ_TIMEOUT:?}")))??;
    parse_http_response(&raw, opts.max_bytes)
}

async fn read_capped<S: AsyncReadExt + Unpin>(
    stream: &mut S,
    cap: usize,
) -> Result<Vec<u8>, gstore_contract::error::ModuleError> {
    let mut buf: Vec<u8> = Vec::with_capacity(16 * 1024);
    let mut tmp = [0u8; 16 * 1024];
    loop {
        let n = stream
            .read(&mut tmp)
            .await
            .map_err(|e| fetch_failed(format!("read response: {e}")))?;
        if n == 0 {
            break;
        }
        if buf.len().saturating_add(n) > cap {
            return Err(too_large(format!(
                "response exceeds max body size ({cap} bytes)"
            )));
        }
        buf.extend_from_slice(&tmp[..n]);
    }
    Ok(buf)
}

fn parse_http_response(
    raw: &[u8],
    max_body: usize,
) -> Result<RawResponse, gstore_contract::error::ModuleError> {
    let header_end = find_subslice(raw, b"\r\n\r\n")
        .ok_or_else(|| fetch_failed("incomplete HTTP response (no header terminator)"))?;
    let head = std::str::from_utf8(&raw[..header_end])
        .map_err(|e| fetch_failed(format!("non-UTF-8 HTTP headers: {e}")))?;
    let body_raw = &raw[header_end + 4..];

    let mut lines = head.split("\r\n");
    let status_line = lines.next().unwrap_or_default();
    let status = status_line
        .splitn(3, ' ')
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or_else(|| fetch_failed("missing HTTP status code"))?;
    let mut headers: Vec<(String, String)> = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| fetch_failed(format!("malformed HTTP header line: {line}")))?;
        headers.push((name.trim().to_string(), value.trim().to_string()));
    }

    if let Some(encoding) = header_value(&headers, "content-encoding") {
        if !encoding.eq_ignore_ascii_case("identity") {
            return Err(fetch_failed(format!(
                "unsupported Content-Encoding '{encoding}' (refusing to decompress untrusted bodies)"
            )));
        }
    }

    let chunked = header_value(&headers, "transfer-encoding")
        .map(|value| {
            value
                .split(',')
                .any(|token| token.trim().eq_ignore_ascii_case("chunked"))
        })
        .unwrap_or(false);
    let body = if chunked {
        decode_chunked(body_raw, max_body)?
    } else {
        if let Some(declared) = header_value(&headers, "content-length") {
            let declared: u64 = declared
                .trim()
                .parse()
                .map_err(|_| fetch_failed("invalid Content-Length header"))?;
            if declared > max_body as u64 {
                return Err(too_large(format!(
                    "response exceeds max body size ({max_body} bytes)"
                )));
            }
            if body_raw.len() as u64 != declared {
                return Err(fetch_failed(
                    "response body length does not match Content-Length",
                ));
            }
        }
        if body_raw.len() > max_body {
            return Err(too_large(format!(
                "response exceeds max body size ({max_body} bytes)"
            )));
        }
        body_raw.to_vec()
    };
    Ok(RawResponse {
        status,
        headers,
        body,
    })
}

fn decode_chunked(
    mut input: &[u8],
    limit: usize,
) -> Result<Vec<u8>, gstore_contract::error::ModuleError> {
    let mut body: Vec<u8> = Vec::new();
    loop {
        let line_end = find_subslice(input, b"\r\n")
            .ok_or_else(|| fetch_failed("incomplete chunk-size line"))?;
        let size_text = std::str::from_utf8(&input[..line_end])
            .map_err(|e| fetch_failed(format!("non-UTF-8 chunk size: {e}")))?;
        let size =
            usize::from_str_radix(size_text.split(';').next().unwrap_or_default().trim(), 16)
                .map_err(|e| fetch_failed(format!("invalid chunk size '{size_text}': {e}")))?;
        input = &input[line_end + 2..];
        if size == 0 {
            return Ok(body);
        }
        if size > limit.saturating_sub(body.len()) {
            return Err(too_large(format!(
                "response exceeds max body size ({limit} bytes)"
            )));
        }
        if input.len() < size + 2 {
            return Err(fetch_failed("incomplete chunk data"));
        }
        body.extend_from_slice(&input[..size]);
        input = &input[size + 2..];
    }
}

pub(crate) fn parse_http_url(raw: &str) -> Result<Url, gstore_contract::error::ModuleError> {
    let url = Url::parse(raw).map_err(|e| url_invalid(format!("invalid URL '{raw}': {e}")))?;
    match url.scheme() {
        "http" | "https" => {}
        other => {
            return Err(url_invalid(format!(
                "unsupported URL scheme '{other}' (only http/https accepted)"
            )))
        }
    }
    if url.host_str().is_none() {
        return Err(url_invalid(format!("URL has no host: {url}")));
    }
    Ok(url)
}

async fn ensure_target_allowed(
    url: &Url,
    allow_private: bool,
) -> Result<(), gstore_contract::error::ModuleError> {
    if allow_private {
        return Ok(());
    }
    let host = url
        .host_str()
        .ok_or_else(|| url_invalid(format!("URL has no host: {url}")))?
        .to_string();
    let bare_host = host.trim_start_matches('[').trim_end_matches(']').to_string();
    if is_blocked_hostname(&bare_host) {
        return Err(ssrf_blocked(format!(
            "refusing user-supplied subscription URL to non-public host '{host}'"
        )));
    }
    if let Ok(ip) = bare_host.parse::<IpAddr>() {
        if is_blocked_ip(ip) {
            return Err(ssrf_blocked(format!(
                "refusing user-supplied subscription URL to non-public address '{host}'"
            )));
        }
        return Ok(());
    }
    let port = url.port_or_known_default().unwrap_or(443);
    if let Ok(addrs) = meow_common::resolve_host_all(&bare_host, port).await {
        if addrs.iter().any(|addr| is_blocked_ip(addr.ip())) {
            return Err(ssrf_blocked(format!(
                "host '{host}' resolves to a non-public address"
            )));
        }
    }
    Ok(())
}

fn is_blocked_hostname(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    host == "localhost"
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || host.ends_with(".internal")
        || host.ends_with(".home.arpa")
        || host == "metadata"
        || host == "metadata.google.internal"
}

/// IPv4 non-public predicate. Shared by the literal `V4` arm and the
/// IPv4-mapped IPv6 arm (`::ffff:a.b.c.d`) so a mapped literal cannot smuggle
/// loopback / RFC1918 / link-local / cloud-metadata through the SSRF guard.
fn is_blocked_ipv4(v4: Ipv4Addr) -> bool {
    let o = v4.octets();
    v4.is_loopback()
        || v4.is_private()
        || v4.is_link_local()
        || v4.is_unspecified()
        || v4.is_broadcast()
        || v4.is_multicast()
        || v4.is_documentation()
        || o[0] == 0
        || (o[0] == 100 && (64..=127).contains(&o[1]))
        || (o[0] == 198 && (o[1] == 18 || o[1] == 19))
}

pub(super) fn is_blocked_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_blocked_ipv4(v4),
        IpAddr::V6(v6) => {
            // `::ffff:127.0.0.1` / `::ffff:10.0.0.5` / `::ffff:169.254.169.254`
            // are none of the V6-native categories below; unwrap the embedded
            // IPv4 and run the exact V4 predicate first.
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_blocked_ipv4(v4);
            }
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || v6.is_unique_local()
                || v6.is_unicast_link_local()
        }
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn header_value<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

pub(crate) fn parse_subscription_userinfo(raw: &str) -> Option<SubscriptionUserinfo> {
    let mut info = SubscriptionUserinfo::default();
    for pair in raw.split([';', ',']) {
        let Some((key, value)) = pair.split_once('=') else {
            continue;
        };
        match key.trim().to_ascii_lowercase().as_str() {
            "upload" => info.upload = value.trim().parse().ok(),
            "download" => info.download = value.trim().parse().ok(),
            "total" => info.total = value.trim().parse().ok(),
            "expire" => {
                info.expire = value.trim().parse::<i64>().ok().map(|value| {
                    if value > 100_000_000_000 {
                        value / 1000
                    } else {
                        value
                    }
                })
            }
            _ => {}
        }
    }
    if info.is_empty() {
        None
    } else {
        Some(info)
    }
}

pub(crate) fn parse_content_disposition(raw: &str) -> Option<String> {
    let mut filename_star: Option<String> = None;
    let mut filename: Option<String> = None;
    for part in raw.split(';').skip(1) {
        let part = part.trim();
        let lower = part.to_ascii_lowercase();
        if lower.starts_with("filename*=") {
            filename_star = Some(decode_rfc5987(part["filename*=".len()..].trim()));
        } else if lower.starts_with("filename=") {
            filename = Some(part["filename=".len()..].trim().trim_matches('"').to_string());
        }
    }
    filename_star
        .or(filename)
        .map(|name| super::sanitize_name(&name))
        .filter(|name| !name.is_empty())
}

fn decode_rfc5987(value: &str) -> String {
    match value.split_once("''") {
        Some((_charset, encoded)) => percent_decode(encoded),
        None => percent_decode(value),
    }
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
