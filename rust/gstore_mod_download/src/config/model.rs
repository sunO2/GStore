//! Typed parsing of config values plus the projection onto scheduler knobs.

use serde_json::Value;

use crate::scheduler::SchedulerConfig;

use super::keys::{
    KEY_DEFAULT_CONNECTIONS, KEY_MAX_CONCURRENT, KEY_MAX_RETRIES, KEY_MULTI_SEGMENT_ENABLED,
    KEY_SPEED_LIMIT_BPS, REGISTRY_DEFAULT_CONNECTIONS, REGISTRY_DEFAULT_MAX_CONCURRENT,
    REGISTRY_DEFAULT_MAX_RETRIES, REGISTRY_DEFAULT_MULTI_SEGMENT_ENABLED,
    REGISTRY_DEFAULT_SPEED_LIMIT_BPS,
};

/// The module's view of its own configuration, with registry-compatible defaults.
///
/// Only used when the host does not inject a config vtable. When the vtable is
/// present every field is re-read from the authoritative store (which returns
/// the registry default for unset keys).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleConfig {
    pub multi_segment_enabled: bool,
    pub max_concurrent: usize,
    pub default_connections: u32,
    pub max_retries: u32,
    pub speed_limit_bps: Option<u64>,
    /// `network.proxy_url` (GitHub URL prefix), read for observability only.
    pub proxy_url: Option<String>,
}

impl Default for ModuleConfig {
    fn default() -> Self {
        let base = SchedulerConfig::default();
        Self {
            multi_segment_enabled: base.multi_segment_enabled,
            max_concurrent: base.max_concurrent,
            default_connections: base.default_connections,
            max_retries: base.max_retries,
            speed_limit_bps: base.speed_limit_bps,
            proxy_url: None,
        }
    }
}

impl ModuleConfig {
    /// Projects the authoritative config onto the live scheduler knobs.
    pub fn to_scheduler(&self) -> SchedulerConfig {
        SchedulerConfig {
            multi_segment_enabled: self.multi_segment_enabled,
            max_concurrent: self.max_concurrent,
            default_connections: self.default_connections,
            speed_limit_bps: self.speed_limit_bps,
            max_retries: self.max_retries,
        }
    }
}

pub fn parse_bool(value: &Value) -> Option<bool> {
    value.as_bool()
}

/// `download.max_concurrent` — schema range is 1..=10.
pub fn parse_max_concurrent(value: &Value) -> Option<usize> {
    let n = usize::try_from(value.as_u64()?).ok()?;
    (1..=10).contains(&n).then_some(n)
}

/// `download.default_connections` — schema minimum is 1.
pub fn parse_default_connections(value: &Value) -> Option<u32> {
    let n = u32::try_from(value.as_u64()?).ok()?;
    (n >= 1).then_some(n)
}

/// `download.max_retries` — schema range is 0..=5.
pub fn parse_max_retries(value: &Value) -> Option<u32> {
    let n = u32::try_from(value.as_u64()?).ok()?;
    (n <= 5).then_some(n)
}

/// `download.speed_limit_bps` — `0` means unlimited. Outer `None` = invalid.
pub fn parse_speed_limit(value: &Value) -> Option<Option<u64>> {
    let n = value.as_u64()?;
    Some(if n == 0 { None } else { Some(n) })
}

/// `network.proxy_url` — empty string means disabled.
pub fn parse_proxy_url(value: &Value) -> Option<Option<String>> {
    let text = value.as_str()?;
    let trimmed = text.trim();
    Some(if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    })
}

/// Applies a single delivered change to `cfg`. Returns `true` when the key was
/// recognized and applied; `false` for an unknown key or a malformed value,
/// which leaves `cfg` untouched.
///
/// An explicit JSON `null` is the wire shape of `clear` (`ConfigChangePayload`
/// has no `skip_serializing_if`), so it is normalized to "unset" here: every
/// consumed key then falls back to its registry default (or, for
/// `speed_limit_bps`, to "unlimited"). Without this normalization the module
/// would try to parse `null` and keep the stale value.
pub fn apply_key(cfg: &mut SchedulerConfig, key: &str, value: Option<&Value>) -> bool {
    let value = value.filter(|value| !value.is_null());
    let Some(value) = value else {
        // A cleared entry (absent or explicit JSON null) falls back to the
        // registry default for that key. These constants MUST match
        // `gstore_core/src/config/schema.rs`; deriving them from
        // `SchedulerConfig::default()` would silently use engine defaults
        // (e.g. max_retries = 4 instead of the registry's 3).
        match key {
            KEY_MULTI_SEGMENT_ENABLED => {
                cfg.multi_segment_enabled = REGISTRY_DEFAULT_MULTI_SEGMENT_ENABLED
            }
            KEY_MAX_CONCURRENT => cfg.max_concurrent = REGISTRY_DEFAULT_MAX_CONCURRENT,
            KEY_DEFAULT_CONNECTIONS => cfg.default_connections = REGISTRY_DEFAULT_CONNECTIONS,
            KEY_MAX_RETRIES => cfg.max_retries = REGISTRY_DEFAULT_MAX_RETRIES,
            KEY_SPEED_LIMIT_BPS => {
                cfg.speed_limit_bps = (REGISTRY_DEFAULT_SPEED_LIMIT_BPS != 0)
                    .then_some(REGISTRY_DEFAULT_SPEED_LIMIT_BPS)
            }
            _ => return false,
        }
        return true;
    };
    match key {
        KEY_MULTI_SEGMENT_ENABLED => match parse_bool(value) {
            Some(v) => cfg.multi_segment_enabled = v,
            None => return false,
        },
        KEY_MAX_CONCURRENT => match parse_max_concurrent(value) {
            Some(v) => cfg.max_concurrent = v,
            None => return false,
        },
        KEY_DEFAULT_CONNECTIONS => match parse_default_connections(value) {
            Some(v) => cfg.default_connections = v,
            None => return false,
        },
        KEY_MAX_RETRIES => match parse_max_retries(value) {
            Some(v) => cfg.max_retries = v,
            None => return false,
        },
        KEY_SPEED_LIMIT_BPS => match parse_speed_limit(value) {
            Some(v) => cfg.speed_limit_bps = v,
            None => return false,
        },
        _ => return false,
    }
    true
}

#[cfg(test)]
mod parser_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn typed_parsers_reject_wrong_types_and_ranges() {
        assert_eq!(parse_max_concurrent(&json!(2)), Some(2));
        assert_eq!(parse_max_concurrent(&json!(0)), None);
        assert_eq!(parse_max_concurrent(&json!(11)), None);
        assert_eq!(parse_max_concurrent(&json!("2")), None);
        assert_eq!(parse_max_concurrent(&json!(2.5)), None);

        assert_eq!(parse_default_connections(&json!(1)), Some(1));
        assert_eq!(parse_default_connections(&json!(0)), None);

        assert_eq!(parse_max_retries(&json!(5)), Some(5));
        assert_eq!(parse_max_retries(&json!(6)), None);

        assert_eq!(parse_speed_limit(&json!(0)), Some(None));
        assert_eq!(parse_speed_limit(&json!(1024)), Some(Some(1024)));
        assert_eq!(parse_speed_limit(&json!(-1)), None);

        assert_eq!(parse_bool(&json!(false)), Some(false));
        assert_eq!(parse_bool(&json!(1)), None);

        assert_eq!(parse_proxy_url(&json!("")), Some(None));
        assert_eq!(
            parse_proxy_url(&json!("  https://gh-proxy.org/  ")),
            Some(Some("https://gh-proxy.org/".to_string()))
        );
        assert_eq!(parse_proxy_url(&json!(7)), None);
    }

    #[test]
    fn apply_key_treats_json_null_as_unset() {
        // Deliberately start every knob at a NON-default value so a no-op
        // clear cannot pass. Expected values are the registry-aligned module
        // constants, never `SchedulerConfig::default()` (whose max_retries is
        // the engine default 4, while the registry default is 3).
        let mut cfg = SchedulerConfig {
            multi_segment_enabled: false,
            max_concurrent: 7,
            default_connections: 9,
            max_retries: 4,
            speed_limit_bps: Some(1024),
        };
        for key in [
            KEY_MULTI_SEGMENT_ENABLED,
            KEY_MAX_CONCURRENT,
            KEY_DEFAULT_CONNECTIONS,
            KEY_MAX_RETRIES,
            KEY_SPEED_LIMIT_BPS,
        ] {
            assert!(
                apply_key(&mut cfg, key, Some(&Value::Null)),
                "{key} must accept an explicit JSON null as unset"
            );
        }
        assert_eq!(
            cfg.multi_segment_enabled,
            REGISTRY_DEFAULT_MULTI_SEGMENT_ENABLED
        );
        assert_eq!(cfg.max_concurrent, REGISTRY_DEFAULT_MAX_CONCURRENT);
        assert_eq!(cfg.default_connections, REGISTRY_DEFAULT_CONNECTIONS);
        assert_eq!(cfg.max_retries, REGISTRY_DEFAULT_MAX_RETRIES);
        assert_eq!(
            cfg.speed_limit_bps,
            (REGISTRY_DEFAULT_SPEED_LIMIT_BPS != 0).then_some(REGISTRY_DEFAULT_SPEED_LIMIT_BPS)
        );
        assert_eq!(cfg.max_retries, 3, "registry default, not engine default 4");
    }

    #[test]
    fn apply_key_keeps_previous_on_malformed_value() {
        let mut cfg = SchedulerConfig {
            max_concurrent: 4,
            ..Default::default()
        };
        assert!(!apply_key(
            &mut cfg,
            KEY_MAX_CONCURRENT,
            Some(&json!("nope"))
        ));
        assert_eq!(cfg.max_concurrent, 4, "malformed value must not overwrite");
        assert!(apply_key(&mut cfg, KEY_MAX_CONCURRENT, Some(&json!(2))));
        assert_eq!(cfg.max_concurrent, 2);
        assert!(!apply_key(&mut cfg, "unrelated", Some(&json!(1))));
    }
}
