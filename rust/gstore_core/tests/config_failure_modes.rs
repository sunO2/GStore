//! Todo 37 registry failure-mode scan (plan C19 item 14).
//!
//! The authoritative registry lives in `gstore_core::config::schema`. This
//! integration test can only see the public surface, which is exactly what the
//! Dart mirror, FRB façade, and module ABI resolve against. It guards against
//! key drift by checking the full 11 proxy keys + 11 module toggles are
//! registered, that every registry entry resolves through the lookup helpers,
//! and that misspellings / legacy bare keys are not silently registered.

use std::collections::BTreeSet;

use gstore_core::config::{entries, entry, has, ConfigKey, MODULE_NAMES};

const PROXY_KEYS: [&str; 11] = [
    "engine_stack",
    "engine_mtu",
    "routing_mode",
    "run_mode",
    "active_node_label",
    "active_profile_id",
    "sheet_view_mode",
    "split_mode",
    "split_apps",
    "always_on_intent",
    "log_level",
];

#[test]
fn every_proxy_key_and_module_toggle_is_registered_and_typos_are_not() {
    for key in PROXY_KEYS {
        let parsed = ConfigKey::new("proxy", key).expect("valid proxy key");
        assert!(
            has(&parsed),
            "proxy.{key} is unregistered; the Dart mirror and ABI would reject it"
        );
        assert!(
            entry(&parsed).is_some(),
            "proxy.{key} has no registry metadata"
        );
    }
    assert_eq!(
        entries()
            .iter()
            .filter(|entry| entry.key.module() == "proxy")
            .count(),
        PROXY_KEYS.len(),
        "the proxy module must expose exactly the 11 persisted keys"
    );

    for name in MODULE_NAMES {
        let key = ConfigKey::new("module", format!("{name}.enabled")).expect("toggle key");
        assert!(has(&key), "module.{name}.enabled is unregistered");
        assert!(entry(&key).is_some(), "module.{name}.enabled has no metadata");
    }
    assert_eq!(MODULE_NAMES.len(), 11, "there must be exactly 11 module toggles");
    assert_eq!(
        entries()
            .iter()
            .filter(|entry| {
                entry.key.module() == "module" && entry.key.key().ends_with(".enabled")
            })
            .count(),
        MODULE_NAMES.len(),
        "the module namespace must expose exactly the 11 toggles"
    );

    // Unregistered keys must never resolve, even when they look plausible.
    for (module, key) in [
        ("proxy", "engine_stak"),
        ("proxy", "routing_mod"),
        ("proxy", "split_apps_extra"),
        ("module", "chanel.enabled"),
        ("module", "download.enable"),
        ("module", "agent_tools.enabled2"),
    ] {
        let parsed = ConfigKey::new(module, key).expect("syntactically valid");
        assert!(!has(&parsed), "{module}.{key} unexpectedly registered");
        assert!(entry(&parsed).is_none(), "{module}.{key} unexpectedly resolved");
    }

    // Legacy bare / prefixed aliases are migration-only and must not be
    // registered as runtime keys.
    for legacy in [
        "theme_mode",
        "proxy_url",
        "config_proxy_url",
        "config_module_download_enabled",
        "agent_models",
    ] {
        assert!(
            ConfigKey::parse(legacy).is_err(),
            "legacy key {legacy} must not parse as a wire key"
        );
        assert!(
            !entries().iter().any(|entry| entry.key.wire() == legacy),
            "legacy key {legacy} must not be registered at runtime"
        );
    }

    let mut seen = BTreeSet::new();
    for entry in entries() {
        let wire = entry.key.wire();
        assert!(seen.insert(wire.clone()), "duplicate registry key {wire}");
        let parsed = ConfigKey::parse(&wire).expect("registry wire key round-trips");
        assert_eq!(parsed, entry.key);
        assert!(has(&parsed), "registry key {wire} is not reachable via has()");
    }
}
