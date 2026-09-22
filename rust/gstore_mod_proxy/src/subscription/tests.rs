//! Unit tests for format detection, share-link parsers, header parsing and the
//! untrusted-content whitelist. Network/fetch integration lives in
//! `tests_fetch`.

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;

use super::fetch::{
    is_blocked_ip, parse_content_disposition, parse_subscription_userinfo, redact_url,
};
use super::*;

fn b64(value: &str) -> String {
    STANDARD.encode(value)
}

const CLASH_FIXTURE: &str = r#"
port: 7890
proxies:
  - {name: "ss-1", type: ss, server: 1.2.3.4, port: 8388, cipher: aes-256-gcm, password: pw}
  - {name: "vmess-1", type: vmess, server: 1.2.3.5, port: 443, uuid: "11111111-1111-1111-1111-111111111111", alterId: 0, cipher: auto, tls: true, servername: example.com}
  - {name: "vless-1", type: vless, server: 1.2.3.6, port: 443, uuid: "22222222-2222-2222-2222-222222222222", tls: true, network: ws, ws-opts: {path: /ws, headers: {Host: ws.example.com}}}
  - {name: "trojan-1", type: trojan, server: 1.2.3.7, port: 443, password: pw, sni: example.com}
  - {name: "hy2-1", type: hysteria2, server: 1.2.3.8, port: 443, password: pw, sni: example.com}
  - {name: "script-1", type: script, server: 9.9.9.9, port: 1}
  - {name: "unknown-1", type: made-up-proto, server: 9.9.9.9, port: 2}
proxy-groups:
  - {name: PROXY, type: select, proxies: ["ss-1", "vmess-1", "vless-1"]}
"#;

fn ss_link(method: &str, password: &str, host: &str, port: u16, name: &str) -> String {
    format!(
        "ss://{}@{}:{}#{}",
        b64(&format!("{method}:{password}")),
        host,
        port,
        name
    )
}

#[test]
fn parses_clash_fixture_through_meow_with_groups_and_whitelist() {
    let parsed = parse_subscription_text(CLASH_FIXTURE, None, "text").unwrap();
    assert_eq!(parsed.format, "clash");
    assert_eq!(parsed.nodes.len(), 5, "script/unknown nodes must be dropped");
    let names: Vec<&str> = parsed.nodes.iter().map(|n| n.name.as_str()).collect();
    assert!(names.contains(&"ss-1"));
    assert!(!names.contains(&"script-1"));
    assert!(!names.contains(&"unknown-1"));
    assert!(parsed.warnings.iter().any(|w| w.contains("script")));
    assert!(parsed.warnings.iter().any(|w| w.contains("whitelist")));

    let group = parsed
        .groups
        .iter()
        .find(|g| g.name == "PROXY")
        .expect("proxy group parsed");
    assert_eq!(group.group_type, "select");
    assert!(group.members.contains(&"ss-1".to_string()));

    let ss = parsed.nodes.iter().find(|n| n.name == "ss-1").unwrap();
    assert_eq!(ss.node_type, "ss");
    assert_eq!(ss.cipher.as_deref(), Some("aes-256-gcm"));
    assert_eq!(ss.source.format, "clash");

    let vless = parsed.nodes.iter().find(|n| n.name == "vless-1").unwrap();
    assert_eq!(vless.ws.as_ref().and_then(|w| w.path.as_deref()), Some("/ws"));
}

#[test]
fn clash_provider_dns_tun_and_controller_are_stripped() {
    let yaml = r#"
external-controller: 0.0.0.0:9090
tun: {enable: true, stack: gvisor}
dns: {enable: true, nameserver: [1.1.1.1]}
proxy-providers:
  evil: {type: script, path: /tmp/evil.js}
proxies:
  - {name: "ok", type: ss, server: 1.2.3.4, port: 8388, cipher: aes-256-gcm, password: pw}
"#;
    let profile = import_text(
        serde_json::json!({"text": yaml}).to_string().as_bytes(),
    )
    .unwrap();
    assert_eq!(profile.node_count, 1);
    let json = serde_json::to_value(&profile).unwrap();
    let text = json.to_string();
    for forbidden in ["external-controller", "\"tun\"", "\"dns\"", "\"script\"", "proxy-providers"] {
        assert!(!text.contains(forbidden), "leaked {forbidden}: {text}");
    }
}

#[test]
fn base64_uri_list_fixture_parses() {
    let list = format!(
        "{}\n{}\n",
        ss_link("aes-256-gcm", "p1", "1.2.3.4", 8388, "A"),
        ss_link("chacha20-ietf-poly1305", "p2", "5.6.7.8", 1080, "B"),
    );
    let encoded = b64(&list);
    let parsed = parse_subscription_text(&encoded, None, "url").unwrap();
    assert_eq!(parsed.format, "base64");
    assert_eq!(parsed.nodes.len(), 2);
    assert_eq!(parsed.nodes[0].name, "A");
    assert_eq!(parsed.nodes[1].source.format, "base64");
}

#[test]
fn plain_uri_list_fixture_parses() {
    let list = format!(
        "# comment\n{}\n// another comment\n{}\n",
        ss_link("aes-128-gcm", "p1", "1.2.3.4", 8388, "A"),
        ss_link("aes-128-gcm", "p2", "5.6.7.8", 1080, "B"),
    );
    let parsed = parse_subscription_text(&list, None, "text").unwrap();
    assert_eq!(parsed.format, "uriList");
    assert_eq!(parsed.nodes.len(), 2);
}

#[test]
fn share_link_ss_variants() {
    let modern = parse_share_link(&ss_link("aes-256-gcm", "secret", "1.2.3.4", 8388, "SS%20A"), 0, "uriList", "url").unwrap();
    assert_eq!(modern.name, "SS A");
    assert_eq!(modern.cipher.as_deref(), Some("aes-256-gcm"));
    assert_eq!(modern.password.as_deref(), Some("secret"));
    assert_eq!(modern.server, "1.2.3.4");
    assert_eq!(modern.port, 8388);

    let legacy_payload = b64("aes-128-gcm:legacy@5.6.7.8:1080");
    let legacy = parse_share_link(&format!("ss://{legacy_payload}#Legacy"), 0, "uriList", "url").unwrap();
    assert_eq!(legacy.name, "Legacy");
    assert_eq!(legacy.server, "5.6.7.8");
    assert_eq!(legacy.port, 1080);

    let ss2022 = parse_share_link(
        &format!("ss2022://{}@1.2.3.4:8388#SS2022", b64("2022-blake3-aes-128-gcm:pass")),
        0,
        "uriList",
        "url",
    )
    .unwrap();
    assert_eq!(ss2022.cipher.as_deref(), Some("2022-blake3-aes-128-gcm"));

    let ss2022_raw = parse_share_link(
        &format!("ss2022://{}@1.2.3.4:8388#SS2022", b64("aes-128-gcm:pass")),
        0,
        "uriList",
        "url",
    )
    .unwrap();
    assert_eq!(ss2022_raw.cipher.as_deref(), Some("2022-blake3-aes-128-gcm"));
}

#[test]
fn share_link_ss_rejects_external_plugin() {
    let link = format!(
        "ss://{}@1.2.3.4:8388?plugin=obfs-local%3Bobfs%3Dhttp#P",
        b64("aes-256-gcm:pw")
    );
    let err = parse_share_link(&link, 0, "uriList", "url").unwrap_err();
    assert_eq!(err.code, ERR_NODE_INVALID);
}

#[test]
fn share_link_vmess() {
    let json = r#"{"v":"2","ps":"VMess A","add":"1.2.3.4","port":"443","id":"33333333-3333-3333-3333-333333333333","aid":"0","scy":"auto","net":"ws","type":"none","host":"example.com","path":"/ws","tls":"tls","sni":"example.com"}"#;
    let link = format!("vmess://{}#", b64(json));
    let node = parse_share_link(&link, 0, "uriList", "url").unwrap();
    assert_eq!(node.node_type, "vmess");
    assert_eq!(node.name, "VMess A");
    assert_eq!(node.uuid.as_deref(), Some("33333333-3333-3333-3333-333333333333"));
    assert!(node.tls);
    assert_eq!(node.network.as_deref(), Some("ws"));
    assert_eq!(node.ws.as_ref().and_then(|w| w.path.as_deref()), Some("/ws"));
}

#[test]
fn share_link_vless_with_reality() {
    let link = "vless://44444444-4444-4444-4444-444444444444@1.2.3.4:443?security=reality&pbk=PUBKEY&sid=SID&spx=%2F&fp=chrome&sni=www.example.com&flow=xtls-rprx-vision&type=tcp#Reality";
    let node = parse_share_link(link, 0, "uriList", "url").unwrap();
    assert_eq!(node.node_type, "vless");
    assert_eq!(node.name, "Reality");
    assert!(node.tls);
    assert_eq!(node.flow.as_deref(), Some("xtls-rprx-vision"));
    assert_eq!(node.fingerprint.as_deref(), Some("chrome"));
    let reality = node.reality.expect("reality params");
    assert_eq!(reality.public_key.as_deref(), Some("PUBKEY"));
    assert_eq!(reality.short_id.as_deref(), Some("SID"));
    assert_eq!(reality.spider_x.as_deref(), Some("/"));
}

#[test]
fn share_link_trojan() {
    let link = "trojan://secret@1.2.3.4:443?sni=example.com&allowInsecure=1#Trojan";
    let node = parse_share_link(link, 0, "uriList", "url").unwrap();
    assert_eq!(node.node_type, "trojan");
    assert_eq!(node.name, "Trojan");
    assert_eq!(node.password.as_deref(), Some("secret"));
    assert!(node.tls);
    assert_eq!(node.skip_cert_verify, Some(true));
}

#[test]
fn share_link_hysteria2() {
    let link = "hysteria2://pass@1.2.3.4:443?sni=example.com&obfs=salamander&obfs-password=op#HY2";
    let node = parse_share_link(link, 0, "uriList", "url").unwrap();
    assert_eq!(node.node_type, "hysteria2");
    assert_eq!(node.name, "HY2");
    assert_eq!(node.password.as_deref(), Some("pass"));
    assert_eq!(node.obfs.as_deref(), Some("salamander"));
    assert_eq!(node.obfs_password.as_deref(), Some("op"));
    assert!(node.tls);
}

#[test]
fn share_links_leave_udp_unspecified() {
    let ss = parse_share_link(&ss_link("aes-256-gcm", "p", "1.2.3.4", 8388, "A"), 0, "uriList", "url")
        .unwrap();
    assert_eq!(ss.udp, None);
    let vless = parse_share_link(
        "vless://44444444-4444-4444-4444-444444444444@1.2.3.4:443#V",
        0,
        "uriList",
        "url",
    )
    .unwrap();
    assert_eq!(vless.udp, None);
}

#[test]
fn clash_udp_flag_is_carried_and_absent_stays_none() {
    let yaml = r#"
proxies:
  - {name: "u-on", type: ss, server: 1.2.3.4, port: 8388, cipher: aes-256-gcm, password: pw, udp: true}
  - {name: "u-off", type: vless, server: 1.2.3.5, port: 443, uuid: "11111111-1111-1111-1111-111111111111", udp: false}
  - {name: "u-none", type: trojan, server: 1.2.3.6, port: 443, password: pw}
"#;
    let parsed = parse_subscription_text(yaml, None, "text").unwrap();
    let find = |name: &str| parsed.nodes.iter().find(|n| n.name == name).unwrap();
    assert_eq!(find("u-on").udp, Some(true));
    assert_eq!(find("u-off").udp, Some(false));
    assert_eq!(find("u-none").udp, None);
}

#[test]
fn unknown_scheme_and_missing_separator_are_structured_errors() {
    let err = parse_share_link("xyz://a@b:1#c", 0, "uriList", "url").unwrap_err();
    assert_eq!(err.code, ERR_SCHEME_UNSUPPORTED);
    assert_eq!(err.status, gstore_contract::error::StatusCode::InvalidArgument);

    let err = parse_share_link("not-a-link", 0, "uriList", "url").unwrap_err();
    assert_eq!(err.code, ERR_NODE_INVALID);

    let payload = serde_json::json!({"link": "xyz://a@b:1#c"}).to_string();
    let err = import_link(payload.as_bytes()).unwrap_err();
    assert_eq!(err.code, ERR_SCHEME_UNSUPPORTED);
}

#[test]
fn malformed_yaml_is_a_parse_error() {
    let err = parse_subscription_text("proxies: [this is : not : valid", None, "text").unwrap_err();
    assert_eq!(err.code, ERR_PARSE_FAILED);
}

#[test]
fn undetectable_body_is_format_unknown() {
    let err = parse_subscription_text("just some text", None, "text").unwrap_err();
    assert_eq!(err.code, ERR_FORMAT_UNKNOWN);
}

#[test]
fn oversized_text_is_rejected_before_parsing() {
    let huge = "a".repeat(MAX_TEXT_BYTES + 1);
    let payload = serde_json::json!({"text": huge}).to_string();
    let err = import_text(payload.as_bytes()).unwrap_err();
    assert_eq!(err.code, ERR_TOO_LARGE);
}

#[test]
fn userinfo_header_variants() {
    let info = parse_subscription_userinfo("upload=100; download=200; total=1000; expire=1700000000")
        .expect("parsed");
    assert_eq!(info.upload, Some(100));
    assert_eq!(info.download, Some(200));
    assert_eq!(info.total, Some(1000));
    assert_eq!(info.expire, Some(1700000000));

    let info = parse_subscription_userinfo("upload=1, download=2, total=3, expire=1700000000000")
        .expect("parsed");
    assert_eq!(info.expire, Some(1700000000), "millisecond expire normalized");

    assert!(parse_subscription_userinfo("").is_none());
    assert!(parse_subscription_userinfo("garbage; nope=1").is_none());
    let partial = parse_subscription_userinfo("total=999").unwrap();
    assert_eq!(partial.total, Some(999));
    assert!(partial.upload.is_none());
}

#[test]
fn content_disposition_filename_variants() {
    assert_eq!(
        parse_content_disposition("attachment; filename=\"My Sub.yaml\"").as_deref(),
        Some("My Sub.yaml")
    );
    assert_eq!(
        parse_content_disposition("attachment; filename*=UTF-8''%E4%B8%AD%E6%96%87.yaml").as_deref(),
        Some("中文.yaml")
    );
    assert_eq!(
        parse_content_disposition("attachment; filename=\"old.yaml\"; filename*=UTF-8''new.yaml")
            .as_deref(),
        Some("new.yaml")
    );
    assert_eq!(
        parse_content_disposition("attachment; filename=\"../../etc/passwd\"").as_deref(),
        Some("passwd")
    );
    assert!(parse_content_disposition("attachment").is_none());
}

#[test]
fn url_scheme_allowlist_rejects_file_and_ftp() {
    assert!(super::fetch::parse_http_url("file:///etc/passwd").is_err());
    assert!(super::fetch::parse_http_url("ftp://example.com/x").is_err());
    assert!(super::fetch::parse_http_url("https://example.com/sub").is_ok());
}

#[test]
fn redact_url_strips_userinfo_path_and_query() {
    let u = url::Url::parse("https://user:pass@h/p?q=1").unwrap();
    assert_eq!(redact_url(&u), "https://h");
}

#[test]
fn redact_url_keeps_scheme_host_port_only() {
    let u = url::Url::parse("https://example.com:8443/sub?token=SECRET123&flag=meta").unwrap();
    let redacted = redact_url(&u);
    assert_eq!(redacted, "https://example.com:8443");
    assert!(!redacted.contains("SECRET123"));
    assert!(!redacted.contains("token="));

    let v6 = url::Url::parse("http://[::1]:1080/x").unwrap();
    assert_eq!(redact_url(&v6), "http://[::1]:1080");
}

#[test]
fn ssrf_guard_blocks_loopback_and_private_literals() {
    for url in [
        "http://127.0.0.1:9/x",
        "http://10.0.0.5/x",
        "http://192.168.1.1/x",
        "http://169.254.169.254/latest/meta-data",
        "http://[::1]:9/x",
        "http://localhost:9/x",
    ] {
        let payload = serde_json::json!({"url": url}).to_string();
        let err = import_url_policy(payload.as_bytes(), false).unwrap_err();
        assert_eq!(err.code, ERR_SSRF_BLOCKED, "expected SSRF block for {url}");
    }
}

#[test]
fn ssrf_guard_allows_loopback_only_when_explicitly_disabled() {
    let payload = serde_json::json!({"url": "http://127.0.0.1:1/x"}).to_string();
    let err = import_url_policy(payload.as_bytes(), false).unwrap_err();
    assert_eq!(err.code, ERR_SSRF_BLOCKED);
}

#[test]
fn ssrf_guard_blocks_ipv4_mapped_ipv6_literals() {
    for url in [
        "http://[::ffff:127.0.0.1]:9/x",
        "http://[::ffff:10.0.0.1]:9/x",
        "http://[::ffff:169.254.169.254]/latest/meta-data",
        "http://[::ffff:192.168.1.1]:9/x",
        "http://[::ffff:100.64.0.1]:9/x",
    ] {
        let payload = serde_json::json!({"url": url}).to_string();
        let err = import_url_policy(payload.as_bytes(), false).unwrap_err();
        assert_eq!(err.code, ERR_SSRF_BLOCKED, "expected SSRF block for {url}");
    }

    use std::net::IpAddr;
    for ip in [
        "::ffff:127.0.0.1",
        "::ffff:10.0.0.5",
        "::ffff:169.254.169.254",
        "::ffff:0.0.0.0",
    ] {
        let ip: IpAddr = ip.parse().unwrap();
        assert!(is_blocked_ip(ip), "mapped {ip} must be blocked");
    }
    let public: IpAddr = "::ffff:1.1.1.1".parse().unwrap();
    assert!(
        !is_blocked_ip(public),
        "public IPv4-mapped IPv6 must be allowed"
    );
}
