//! End-to-end pipeline tests over the fully synthetic provider fixture:
//!
//! ```text
//! Clash YAML ──meow parser──▶ canonical model (import_text)
//!            ──ProfileStore──▶ persisted profile + refresh re-parse
//!            ──config::build_registry──▶ live proxy map
//!            ──nodes::select──▶ active outbound
//! ```
//!
//! The fixture (`tests/fixtures/synthetic_provider.yaml`) is entirely
//! fabricated — no real subscription content is read, fetched, or referenced.

use std::collections::BTreeSet;

use super::*;
use crate::profile::ProfileStore;

const FIXTURE: &str = include_str!("../../tests/fixtures/synthetic_provider.yaml");

fn fixture_payload() -> Vec<u8> {
    serde_json::json!({ "text": FIXTURE, "name": "Synthetic Provider" })
        .to_string()
        .into_bytes()
}

/// Import the fixture through the **same** production path the module uses for
/// `profile.import_text` (Clash YAML → meow → canonical model → finalize).
fn import_fixture() -> ImportedProfile {
    import_text(&fixture_payload()).expect("synthetic fixture must import")
}

#[test]
fn no_proxy_groups_synthesizes_proxy_and_flags_false() {
    let yaml = "\
proxies:
  - name: solo-ss
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-256-gcm
    password: pw
";
    let payload = serde_json::json!({ "text": yaml, "name": "No Groups" })
        .to_string()
        .into_bytes();
    let profile = import_text(&payload).expect("minimal no-group config must import");

    assert!(!profile.has_proxy_groups, "no declared proxy-groups");
    assert_eq!(profile.groups.len(), 1, "exactly one synthesized group");
    assert_eq!(profile.groups[0].name, "PROXY");
    assert_eq!(profile.groups[0].group_type, "select");
    assert_eq!(profile.groups[0].members, vec!["solo-ss".to_string()]);
    assert!(profile.warnings.iter().any(|w| w.contains("synthesized")));

    assert!(
        import_fixture().has_proxy_groups,
        "the fixture declares proxy-groups"
    );
}

fn tmp_dir(tag: &str) -> std::path::PathBuf {
    use std::sync::atomic::{AtomicU32, Ordering};
    static SEQ: AtomicU32 = AtomicU32::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("gstore-pipeline-{tag}-{nanos}-{seq}"));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn create_profile(store: &ProfileStore, profile: &ImportedProfile) {
    let payload = serde_json::to_vec(&serde_json::json!({ "profile": profile })).unwrap();
    store.create(&payload).expect("profile.create");
}

#[test]
fn synthetic_fixture_imports_24_nodes_and_three_groups() {
    let profile = import_fixture();

    assert_eq!(profile.format, "clash");
    assert_eq!(profile.node_count, 24, "16 vless + 8 hysteria2");
    assert_eq!(profile.nodes.len(), 24);

    let vless: Vec<&ProxyNode> = profile
        .nodes
        .iter()
        .filter(|n| n.node_type == "vless")
        .collect();
    assert_eq!(vless.len(), 16);
    let hy2: Vec<&ProxyNode> = profile
        .nodes
        .iter()
        .filter(|n| n.node_type == "hysteria2")
        .collect();
    assert_eq!(hy2.len(), 8);

    // The canonical model requires a non-zero port; every imported node has one.
    assert!(
        profile.nodes.iter().all(|n| n.port != 0),
        "every imported node must have a non-zero port"
    );

    // 3 groups: select + url-test + fallback.
    assert_eq!(profile.groups.len(), 3);
    let group_types: BTreeSet<&str> = profile
        .groups
        .iter()
        .map(|g| g.group_type.as_str())
        .collect();
    assert_eq!(
        group_types,
        BTreeSet::from(["fallback", "select", "url-test"])
    );
    let select = profile
        .groups
        .iter()
        .find(|g| g.group_type == "select")
        .expect("select group");
    assert_eq!(select.name, "PROXY");
    assert!(select.members.contains(&"vless-01".to_string()));
    assert!(select.members.contains(&"hy2-hop-port".to_string()));

    assert_eq!(
        profile.rules,
        vec![
            "DOMAIN-SUFFIX,example.com,PROXY",
            "GEOIP,LAN,DIRECT",
            "MATCH,PROXY",
        ],
        "the fixture's rules: must be captured at import"
    );

    // VLESS transport shape.
    for node in &vless {
        assert_eq!(
            node.flow.as_deref(),
            Some("xtls-rprx-vision"),
            "{} flow",
            node.name
        );
        assert!(node.tls, "{} must set tls", node.name);
        assert!(node.sni.is_some(), "{} needs servername/sni", node.name);
        assert!(
            node.fingerprint.is_some(),
            "{} needs client-fingerprint",
            node.name
        );
    }
    let ws: Vec<&&ProxyNode> = vless
        .iter()
        .filter(|n| n.network.as_deref() == Some("ws"))
        .collect();
    assert_eq!(ws.len(), 4, "exactly four vless nodes use ws");
    for node in ws {
        let ws = node.ws.as_ref().expect("ws-opts parsed");
        assert!(ws.path.is_some(), "{} ws path", node.name);
        assert!(ws.host.is_some(), "{} ws host", node.name);
    }
    let reality: Vec<&&ProxyNode> = vless.iter().filter(|n| n.reality.is_some()).collect();
    assert_eq!(reality.len(), 4, "exactly four vless nodes use reality-opts");
    for node in reality {
        let r = node.reality.as_ref().unwrap();
        assert!(r.public_key.is_some(), "{} reality public-key", node.name);
        assert!(r.short_id.is_some(), "{} reality short-id", node.name);
    }

    // Hysteria2 shape.
    for node in &hy2 {
        assert!(node.password.is_some(), "{} hy2 password", node.name);
        assert!(node.sni.is_some(), "{} hy2 sni", node.name);
        assert_eq!(
            node.skip_cert_verify,
            Some(true),
            "{} skip-cert-verify",
            node.name
        );
        assert!(node.tls, "{} hy2 forces tls", node.name);
    }
    assert!(
        hy2.iter()
            .filter(|n| n.obfs.as_deref() == Some("salamander"))
            .count()
            >= 2,
        "some hysteria2 nodes use obfs"
    );
    assert!(hy2.iter().any(|n| n.obfs_password.is_some()));

    // Hysteria2 is on the import whitelist: nothing names it as unsupported and
    // the only dropped node is the port-less port-hopping case.
    assert!(
        !profile.warnings.iter().any(|w| w.contains("hysteria2")),
        "hysteria2 must never be reported unsupported: {:?}",
        profile.warnings
    );
    let port_drops: Vec<&String> = profile
        .warnings
        .iter()
        .filter(|w| w.contains("missing/invalid 'port'"))
        .collect();
    assert_eq!(port_drops.len(), 1, "warnings: {:?}", profile.warnings);
    assert!(!profile.nodes.iter().any(|n| n.name == "hy2-no-port"));
}

#[test]
fn synthetic_fixture_port_hopping_edges() {
    let profile = import_fixture();

    // `ports:` range *with* a fixed `port` survives import with that port.
    let fixed = profile
        .nodes
        .iter()
        .find(|n| n.name == "hy2-hop-port")
        .expect("fixed-port port-hopping node must survive import");
    assert_eq!(fixed.node_type, "hysteria2");
    assert_eq!(fixed.port, 443, "the fixed port survives the ports: range");
    assert!(fixed.groups.contains(&"PROXY".to_string()));

    // `ports:` range with *no* fixed `port` is dropped (non-zero port required).
    assert!(
        !profile.nodes.iter().any(|n| n.name == "hy2-no-port"),
        "the port-less node must be dropped"
    );
    assert!(profile
        .warnings
        .iter()
        .any(|w| w.contains("missing/invalid 'port'")));
    assert!(
        profile
            .warnings
            .iter()
            .all(|w| !w.contains("hy2-hop-port")),
        "the surviving node must not be warned about"
    );
}

#[test]
fn synthetic_fixture_refresh_reparse_preserves_counts() {
    let dir = tmp_dir("refresh");
    let store = ProfileStore::open(&dir.display().to_string()).unwrap();
    let first = import_fixture();
    create_profile(&store, &first);

    let created = store.get(br#"{"id":"p1"}"#).expect("stored profile");
    assert_eq!(created.profile.node_count, 24);
    assert_eq!(created.profile.groups.len(), 3);

    // A refresh re-parses the same body through the same production path.
    let reparsed = import_fixture();
    assert_eq!(reparsed.node_count, first.node_count);
    assert_eq!(reparsed.nodes, first.nodes, "re-parse is stable");
    assert_eq!(reparsed.groups, first.groups);

    let record = store
        .apply_refresh_success(&created.id, reparsed)
        .expect("refresh success persists");
    assert_eq!(record.profile.node_count, 24);
    assert_eq!(record.profile.nodes.len(), 24);
    assert_eq!(record.profile.groups.len(), 3);
    assert_eq!(
        record.refresh.as_ref().map(|r| r.state.as_str()),
        Some("done")
    );

    // Reopen from disk: the refreshed profile (and its counts) persisted.
    let reloaded = ProfileStore::open(&dir.display().to_string()).unwrap();
    let got = reloaded.get(br#"{"id":"p1"}"#).expect("reloaded profile");
    assert_eq!(got.profile.node_count, 24);
    assert_eq!(
        got.profile
            .nodes
            .iter()
            .filter(|n| n.node_type == "vless")
            .count(),
        16
    );
    assert_eq!(
        got.profile
            .nodes
            .iter()
            .filter(|n| n.node_type == "hysteria2")
            .count(),
        8
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn synthetic_fixture_builds_hysteria2_without_unsupported_warning() {
    let dir = tmp_dir("registry");
    let store = ProfileStore::open(&dir.display().to_string()).unwrap();
    let profile = import_fixture();
    create_profile(&store, &profile);

    let generated = crate::config::try_generate(
        &dir.display().to_string(),
        &dir.display().to_string(),
        &crate::config::GenerateRequest::default(),
    )
    .unwrap()
    .expect("config generated from the stored fixture");
    assert_eq!(generated.node_count, 24);

    let (map, warnings) = crate::config::build_registry(&generated.raw, None);

    for node in profile.nodes.iter().filter(|n| n.node_type == "hysteria2") {
        assert!(
            map.contains_key(node.name.as_str()),
            "hysteria2 {} must build into the registry: {warnings:?}",
            node.name
        );
        assert!(
            !warnings
                .iter()
                .any(|w| w.node.as_deref() == Some(node.name.as_str())),
            "hysteria2 {} must not be reported unsupported: {warnings:?}",
            node.name
        );
    }
    // A ws vless node also builds, and all three groups wire up.
    assert!(map.contains_key("vless-13"), "ws vless builds: {warnings:?}");
    for group in ["PROXY", "AUTO", "FALLBACK"] {
        assert!(map.contains_key(group), "group {group} builds: {warnings:?}");
    }

    let _ = std::fs::remove_dir_all(&dir);
}

/// `node.select` over the fixture's select group flips the active outbound and
/// reports it. The group is built from the imported membership with stub
/// outbounds, so selection is exercised end-to-end without any network I/O.
#[cfg(unix)]
#[test]
fn synthetic_fixture_node_select_reports_active() {
    use std::collections::HashMap;
    use std::sync::Arc;

    use meow_common::Proxy;
    use smol_str::SmolStr;

    use crate::nodes::tests::StubProxy;
    use crate::TEST_SERIAL as SERIAL;

    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    crate::rules::reset_for_tests();
    let _ = crate::dispatch::build_engine(empty_resolver());
    let tunnel = crate::rules::active_tunnel().expect("engine tunnel");

    let profile = import_fixture();
    let select = profile
        .groups
        .iter()
        .find(|g| g.group_type == "select")
        .expect("select group");
    assert!(select.members.len() >= 2, "need two members to prove the flip");

    let members: Vec<Arc<dyn Proxy>> = select
        .members
        .iter()
        .map(|name| StubProxy::new(name) as Arc<dyn Proxy>)
        .collect();
    let group: Arc<dyn Proxy> = Arc::new(meow_proxy::SelectorGroup::new(
        select.name.as_str(),
        members,
    ));

    let mut map: HashMap<SmolStr, Arc<dyn Proxy>> = HashMap::new();
    map.insert(SmolStr::from(select.name.as_str()), Arc::clone(&group));
    tunnel.update_proxies(map);

    let chosen = select.members[1].clone();
    let payload =
        serde_json::to_vec(&serde_json::json!({ "group": select.name, "node": chosen })).unwrap();
    let (data, selection) = crate::nodes::select(&payload, "", "").expect("node.select");

    assert_eq!(data["active"], serde_json::json!(chosen));
    assert_eq!(selection.group, select.name);
    assert_eq!(selection.node, chosen);
    assert_eq!(selection.active, chosen);
    assert_eq!(group.current().as_deref(), Some(chosen.as_str()));

    crate::rules::reset_for_tests();
}

#[cfg(unix)]
fn empty_resolver() -> std::sync::Arc<meow_dns::Resolver> {
    use std::sync::Arc;
    Arc::new(meow_dns::Resolver::new(
        Vec::new(),
        Vec::new(),
        meow_common::DnsMode::Normal,
        meow_trie::DomainTrie::new(),
        false,
        false,
    ))
}
