//! Built-in configuration registry.
//!
//! Every shipping configuration key is declared here exactly once, grouped by
//! owning module (`module.key`), together with its JSON type, default, numeric
//! range, enum set, descriptions, and visibility. Later waves (store, bus,
//! import, ABI, Dart mirror) read this registry instead of hard-coding keys.
//!
//! The registry is a lazily-initialized [`OnceLock`]; after the first call it is
//! an immutable `&'static [ConfigEntry]` and there is no mutation API. Entries
//! are sorted by [`ConfigKey`] so lookups are a binary search and
//! [`module_entries`] yields a contiguous, deterministic slice.

use std::sync::OnceLock;

use serde_json::{json, Value};

use super::model::{ConfigEntry, ConfigKey, ConfigValueType, ConfigVisibility};

/// The eleven built-in module toggles (`module.<name>.enabled`).
pub const MODULE_NAMES: [&str; 11] = [
    "channel",
    "download",
    "backup",
    "webdav",
    "fdroid",
    "theme",
    "install",
    "aggregate",
    "agent_tools",
    "update",
    "badge",
];

static REGISTRY: OnceLock<Vec<ConfigEntry>> = OnceLock::new();

/// All registered entries, sorted by [`ConfigKey`].
///
/// The slice is allocated once and never mutated; repeated calls return the
/// same backing storage.
pub fn entries() -> &'static [ConfigEntry] {
    REGISTRY.get_or_init(build_registry).as_slice()
}

/// Looks an entry up by its canonical key.
pub fn entry(key: &ConfigKey) -> Option<&'static ConfigEntry> {
    let all = entries();
    all.binary_search_by(|candidate| candidate.key.cmp(key))
        .ok()
        .map(|index| &all[index])
}

/// Whether `key` is a registered entry.
pub fn has(key: &ConfigKey) -> bool {
    entry(key).is_some()
}

/// Iterates the entries owned by `module`, in wire-key order.
pub fn module_entries(module: &str) -> impl Iterator<Item = &'static ConfigEntry> + '_ {
    entries()
        .iter()
        .filter(move |candidate| candidate.key.module() == module)
}

/// Builder used only to keep the declaration table readable.
struct EntrySpec {
    module: &'static str,
    key: String,
    value_type: ConfigValueType,
    default_json: Value,
    sensitive: bool,
    agent_accessible: bool,
    visibility: ConfigVisibility,
    description_zh: &'static str,
    description_en: &'static str,
    category: &'static str,
    unit: Option<&'static str>,
    min: Option<f64>,
    max: Option<f64>,
    enum_values: &'static [&'static str],
    example: Option<&'static str>,
}

impl EntrySpec {
    fn new(module: &'static str, key: impl Into<String>, value_type: ConfigValueType) -> Self {
        Self {
            module,
            key: key.into(),
            value_type,
            default_json: Value::Null,
            sensitive: false,
            agent_accessible: false,
            visibility: ConfigVisibility::Owner,
            description_zh: "",
            description_en: "",
            category: module,
            unit: None,
            min: None,
            max: None,
            enum_values: &[],
            example: None,
        }
    }

    fn default_json(mut self, value: Value) -> Self {
        self.default_json = value;
        self
    }

    fn sensitive(mut self) -> Self {
        self.sensitive = true;
        self
    }

    fn agent(mut self) -> Self {
        self.agent_accessible = true;
        self
    }

    fn public_read(mut self) -> Self {
        self.visibility = ConfigVisibility::PublicRead;
        self
    }

    fn secret(mut self) -> Self {
        self.visibility = ConfigVisibility::Secret;
        self
    }

    fn docs(mut self, zh: &'static str, en: &'static str) -> Self {
        self.description_zh = zh;
        self.description_en = en;
        self
    }

    fn unit(mut self, unit: &'static str) -> Self {
        self.unit = Some(unit);
        self
    }

    fn range(mut self, min: f64, max: f64) -> Self {
        self.min = Some(min);
        self.max = Some(max);
        self
    }

    fn min(mut self, min: f64) -> Self {
        self.min = Some(min);
        self
    }

    fn enums(mut self, values: &'static [&'static str]) -> Self {
        self.enum_values = values;
        self
    }

    fn example(mut self, example: &'static str) -> Self {
        self.example = Some(example);
        self
    }

    fn build(self) -> ConfigEntry {
        let key = ConfigKey::new(self.module, self.key)
            .expect("built-in config keys are compile-time validated literals");
        ConfigEntry {
            key,
            value_type: self.value_type,
            revision: 0,
            sensitive: self.sensitive,
            agent_accessible: self.agent_accessible,
            visibility: self.visibility,
            default_json: self.default_json,
            description_zh: self.description_zh.to_string(),
            description_en: self.description_en.to_string(),
            category: self.category.to_string(),
            unit: self.unit.map(str::to_string),
            min: self.min,
            max: self.max,
            enum_values: self
                .enum_values
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
            example: self.example.map(str::to_string),
        }
    }
}

fn build_registry() -> Vec<ConfigEntry> {
    let mut registry = vec![
        // ---- theme ----
        EntrySpec::new("theme", "config", ConfigValueType::Json)
            .default_json(json!({}))
            .agent()
            .docs(
                "主题配置（颜色/字体/圆角等 JSON；字段值用数字索引，空对象表示使用默认主题）",
                "Theme config (colors/font/radius JSON; numeric field indices; empty object = defaults)",
            )
            .example(r#"{"fontStyle":3}"#)
            .build(),
        EntrySpec::new("theme", "mode", ConfigValueType::Int)
            .default_json(json!(0))
            .agent()
            .public_read()
            .enums(&["0", "1", "2"])
            .docs(
                "主题模式：0=跟随系统 1=浅色 2=深色",
                "Theme mode: 0=system 1=light 2=dark",
            )
            .build(),
        // ---- download ----
        EntrySpec::new("download", "multi_segment.enabled", ConfigValueType::Bool)
            .default_json(json!(true))
            .agent()
            .docs(
                "多段下载开关（关闭后单连接下载）",
                "Multi-segment download toggle (off = single connection)",
            )
            .build(),
        EntrySpec::new("download", "wifi_only", ConfigValueType::Bool)
            .default_json(json!(false))
            .agent()
            .docs("仅在 Wi-Fi 下下载", "Download only over Wi-Fi")
            .build(),
        EntrySpec::new("download", "max_concurrent", ConfigValueType::Int)
            .default_json(json!(3))
            .agent()
            .range(1.0, 10.0)
            .docs(
                "最大并发下载任务数（1-10）",
                "Maximum concurrent download tasks (1-10)",
            )
            .build(),
        EntrySpec::new("download", "default_connections", ConfigValueType::Int)
            .default_json(json!(4))
            .agent()
            .min(1.0)
            .docs(
                "启用多段下载时单任务默认连接数（分段数）",
                "Default per-task connections (segments) when multi-segment is enabled",
            )
            .build(),
        EntrySpec::new("download", "max_retries", ConfigValueType::Int)
            .default_json(json!(3))
            .agent()
            .range(0.0, 5.0)
            .docs("下载失败最大重试次数（0-5）", "Maximum download retries (0-5)")
            .build(),
        EntrySpec::new("download", "speed_limit_bps", ConfigValueType::Int)
            .default_json(json!(0))
            .agent()
            .min(0.0)
            .unit("B/s")
            .docs(
                "全局限速（字节/秒，0 表示不限速）",
                "Global speed limit in bytes/second (0 = unlimited)",
            )
            .build(),
        // ---- update ----
        EntrySpec::new("update", "channel", ConfigValueType::String)
            .default_json(json!("stable"))
            .agent()
            .enums(&["stable", "beta", "dev"])
            .docs(
                "更新渠道：stable / beta / dev",
                "Update channel: stable / beta / dev",
            )
            .build(),
        EntrySpec::new("update", "auto_update_policy", ConfigValueType::String)
            .default_json(json!("wifi_only"))
            .agent()
            .enums(&["never", "wifi_only", "always"])
            .docs(
                "自动更新策略：never / wifi_only / always（字符串，不使用枚举索引）",
                "Auto-update policy: never / wifi_only / always (strings, not enum indices)",
            )
            .build(),
        EntrySpec::new("update", "ignore_prerelease", ConfigValueType::Bool)
            .default_json(json!(true))
            .agent()
            .docs("忽略预发布版本", "Ignore prerelease versions")
            .build(),
        EntrySpec::new("update", "silent_update", ConfigValueType::Bool)
            .default_json(json!(false))
            .agent()
            .docs("静默更新（不弹提示）", "Silent update (no prompt)")
            .build(),
        EntrySpec::new("update", "check_interval_hours", ConfigValueType::Int)
            .default_json(json!(24))
            .agent()
            .docs("检查更新间隔（小时）", "Update check interval in hours")
            .build(),
        EntrySpec::new("update", "last_check_time", ConfigValueType::String)
            .default_json(json!(""))
            .agent()
            .docs(
                "上次检查更新时间（ISO-8601 字符串，空串表示从未检查）",
                "Last update check time (ISO-8601 string; empty = never checked)",
            )
            .build(),
        EntrySpec::new("update", "last_updated_version", ConfigValueType::String)
            .default_json(json!(""))
            .agent()
            .docs(
                "上次更新到的版本（空串表示从未更新）",
                "Last updated version (empty = never updated)",
            )
            .build(),
        // ---- webdav ----
        EntrySpec::new("webdav", "url", ConfigValueType::String)
            .default_json(json!(""))
            .sensitive()
            .agent()
            .docs("WebDAV 服务器地址", "WebDAV server URL")
            .example("https://dav.example.com/remote.php/dav/files/user")
            .build(),
        EntrySpec::new("webdav", "username", ConfigValueType::String)
            .default_json(json!(""))
            .sensitive()
            .agent()
            .docs("WebDAV 用户名", "WebDAV username")
            .build(),
        EntrySpec::new("webdav", "password", ConfigValueType::String)
            .default_json(json!(""))
            .sensitive()
            .secret()
            .docs("WebDAV 密码（仅 owner 可读，读取时脱敏）", "WebDAV password (owner-only, masked on read)")
            .build(),
        EntrySpec::new("webdav", "backup_path", ConfigValueType::String)
            .default_json(json!("/GStore"))
            .sensitive()
            .agent()
            .docs("WebDAV 备份路径", "WebDAV backup path")
            .build(),
        EntrySpec::new("webdav", "enable_https", ConfigValueType::Bool)
            .default_json(json!(true))
            .sensitive()
            .agent()
            .docs("是否启用 HTTPS", "Whether HTTPS is enabled")
            .build(),
        // ---- network / catalog ----
        EntrySpec::new("network", "proxy_url", ConfigValueType::String)
            .default_json(json!(""))
            .agent()
            .public_read()
            .docs(
                "GitHub 代理前缀（空串表示不使用）",
                "GitHub proxy prefix (empty = disabled)",
            )
            .example("https://gh-proxy.org/")
            .build(),
        EntrySpec::new("catalog", "source_url", ConfigValueType::String)
            .default_json(json!("https://github.com/sunO2/GStore-Repositorys"))
            .agent()
            .public_read()
            .docs(
                "目录库地址：GitHub 仓库地址或直接的 .db 下载地址（空串 = 未配置）",
                "Catalog source: GitHub repo URL or direct .db URL (empty = unset)",
            )
            .example("https://github.com/<owner>/<repo>")
            .build(),
        // ---- agent ----
        EntrySpec::new("agent", "models", ConfigValueType::Json)
            .default_json(json!([]))
            .sensitive()
            .secret()
            .docs(
                "Agent 模型列表（JSON 数组，含 API Key；仅 owner 可读）",
                "Agent model list (JSON array, includes API keys; owner-only)",
            )
            .build(),
        EntrySpec::new("agent", "selected_model_id", ConfigValueType::String)
            .default_json(json!(""))
            .agent()
            .docs("Agent 当前选中模型 ID", "Agent selected model ID")
            .build(),
        EntrySpec::new("agent", "model_catalog", ConfigValueType::Json)
            .default_json(json!({}))
            .docs(
                "Agent 模型列表缓存（Base URL → 模型 ID 列表）",
                "Agent model list cache (base URL -> model ID list)",
            )
            .build(),
        // ---- fdroid / discovery ----
        EntrySpec::new("fdroid", "sources", ConfigValueType::Json)
            .default_json(json!([]))
            .docs("F-Droid 源列表（JSON 数组）", "F-Droid source list (JSON array)")
            .build(),
        EntrySpec::new("fdroid", "last_source_id", ConfigValueType::String)
            .default_json(json!(""))
            .docs("F-Droid 当前源 ID", "F-Droid current source ID")
            .build(),
        EntrySpec::new("discovery", "selected_channels", ConfigValueType::StringList)
            .default_json(json!([]))
            .docs("发现页选中的渠道", "Selected channels on the discovery page")
            .build(),
        // ---- perf ----
        EntrySpec::new("perf", "profiles", ConfigValueType::Json)
            .default_json(json!({}))
            .docs(
                "每应用性能档案（JSON：包名 → 档案，空对象 = 无档案）",
                "Per-app performance profiles (JSON: package -> profile; empty = none)",
            )
            .example(r#"{"com.example.app":{"enabled":true,"gpu_level":2}}"#)
            .build(),
        EntrySpec::new("perf", "profiles.enabled", ConfigValueType::Bool)
            .default_json(json!(false))
            .docs(
                "按应用性能模式总开关（默认关闭）",
                "Per-app performance mode master switch (default off)",
            )
            .build(),
        EntrySpec::new("perf", "history.enabled", ConfigValueType::Bool)
            .default_json(json!(false))
            .docs(
                "电池/功耗历史采样器开关（默认关闭）",
                "Battery/power history sampler switch (default off)",
            )
            .build(),
        // ---- module toggles ----
        module_toggle("channel", "渠道模块开关", "Channel module toggle"),
        module_toggle("download", "下载模块开关", "Download module toggle"),
        module_toggle("backup", "备份模块开关", "Backup module toggle"),
        module_toggle("webdav", "WebDAV 模块开关", "WebDAV module toggle"),
        module_toggle("fdroid", "F-Droid 模块开关", "F-Droid module toggle"),
        module_toggle("theme", "主题模块开关", "Theme module toggle"),
        module_toggle("install", "安装模块开关", "Install module toggle"),
        module_toggle("aggregate", "聚合模块开关", "Aggregate module toggle"),
        module_toggle(
            "agent_tools",
            "Agent 工具模块开关",
            "Agent tools module toggle",
        ),
        module_toggle(
            "update",
            "更新模块开关（预留，接口就绪前恒启用）",
            "Update module toggle (reserved, always on)",
        ),
        module_toggle(
            "badge",
            "角标模块开关（预留，接口就绪前恒启用）",
            "Badge module toggle (reserved, always on)",
        ),
        // ---- proxy page persistence ----
        EntrySpec::new("proxy", "engine_stack", ConfigValueType::String)
            .default_json(json!("gvisor"))
            .enums(&["gvisor", "system"])
            .docs("代理隧道 stack：gvisor / system", "Proxy tunnel stack: gvisor / system")
            .build(),
        EntrySpec::new("proxy", "engine_mtu", ConfigValueType::Int)
            .default_json(json!(1500))
            .min(1280.0)
            .unit("bytes")
            .docs("代理隧道 MTU（最小 1280）", "Proxy tunnel MTU (minimum 1280)")
            .build(),
        EntrySpec::new("proxy", "routing_mode", ConfigValueType::String)
            .default_json(json!("rule"))
            .enums(&["direct", "rule", "global"])
            .docs(
                "用户选择的路由模式：direct / rule / global",
                "User-selected routing mode: direct / rule / global",
            )
            .build(),
        EntrySpec::new("proxy", "run_mode", ConfigValueType::String)
            .default_json(json!("vpn"))
            .enums(&["off", "vpn", "lanProxy"])
            .docs(
                "用户选择的运行模式：off / vpn / lanProxy",
                "User-selected run mode: off / vpn / lanProxy",
            )
            .build(),
        EntrySpec::new("proxy", "active_node_label", ConfigValueType::Json)
            .default_json(json!({}))
            .docs(
                "当前选中节点（JSON：{\"group\":...,\"node\":...}）",
                "Active node selection (JSON: {\"group\":...,\"node\":...})",
            )
            .build(),
        EntrySpec::new("proxy", "active_profile_id", ConfigValueType::String)
            .default_json(json!(""))
            .docs("当前选中订阅 profile id", "Active subscription profile id")
            .build(),
        EntrySpec::new("proxy", "sheet_view_mode", ConfigValueType::String)
            .default_json(json!("list"))
            .enums(&["grid", "list"])
            .docs(
                "节点弹层排布模式：grid / list（未设置回落到 list）",
                "Node sheet layout: grid / list (unset falls back to list)",
            )
            .build(),
        EntrySpec::new("proxy", "split_mode", ConfigValueType::String)
            .default_json(json!("full"))
            .enums(&["full", "allow", "disallow"])
            .docs(
                "VPN 分流模式：full / allow / disallow",
                "VPN split-tunnel mode: full / allow / disallow",
            )
            .build(),
        EntrySpec::new("proxy", "split_apps", ConfigValueType::StringList)
            .default_json(json!([]))
            .docs("分流选中的应用清单", "Selected apps for split tunneling")
            .build(),
        EntrySpec::new("proxy", "always_on_intent", ConfigValueType::Bool)
            .default_json(json!(false))
            .docs(
                "应用侧「始终开启」意图（不直接控制系统开关）",
                "App-side always-on intent (does not toggle the system switch)",
            )
            .build(),
        EntrySpec::new("proxy", "log_level", ConfigValueType::String)
            .default_json(json!("info"))
            .enums(&["debug", "info", "warn", "error"])
            .docs(
                "代理日志保留级别：debug / info / warn / error",
                "Proxy log level: debug / info / warn / error",
            )
            .build(),
    ];
    registry.sort_by(|left, right| left.key.cmp(&right.key));
    registry
}

fn module_toggle(name: &'static str, zh: &'static str, en: &'static str) -> ConfigEntry {
    EntrySpec::new("module", format!("{name}.enabled"), ConfigValueType::Bool)
        .default_json(json!(true))
        .docs(zh, en)
        .build()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    fn wire_set(predicate: impl Fn(&ConfigEntry) -> bool) -> BTreeSet<String> {
        entries()
            .iter()
            .filter(|entry| predicate(entry))
            .map(|entry| entry.key.wire())
            .collect()
    }

    fn key_of(module: &str, key: &str) -> ConfigKey {
        ConfigKey::new(module, key).expect("test key is valid")
    }

    #[test]
    fn registry_has_at_least_forty_entries() {
        assert!(
            entries().len() >= 40,
            "expected >= 40 registered entries, got {}",
            entries().len()
        );
    }

    #[test]
    fn every_entry_has_descriptions_category_and_visibility() {
        for entry in entries() {
            assert!(
                !entry.description_zh.trim().is_empty(),
                "{} has no zh description",
                entry.key.wire()
            );
            assert!(
                !entry.description_en.trim().is_empty(),
                "{} has no en description",
                entry.key.wire()
            );
            assert!(
                !entry.category.trim().is_empty(),
                "{} has no category",
                entry.key.wire()
            );
            assert!(
                matches!(
                    entry.visibility,
                    ConfigVisibility::Owner
                        | ConfigVisibility::PublicRead
                        | ConfigVisibility::Secret
                ),
                "{} has an invalid visibility",
                entry.key.wire()
            );
        }
    }

    #[test]
    fn public_read_set_is_exactly_the_three_public_keys() {
        let actual = wire_set(|entry| entry.visibility == ConfigVisibility::PublicRead);
        let expected: BTreeSet<String> = ["network.proxy_url", "theme.mode", "catalog.source_url"]
            .iter()
            .map(|wire| (*wire).to_string())
            .collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn module_toggles_proxy_keys_and_wifi_only_exist() {
        for name in MODULE_NAMES {
            let key = key_of("module", &format!("{name}.enabled"));
            assert!(entry(&key).is_some(), "missing module toggle {key}");
        }
        for key in [
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
        ] {
            let key = key_of("proxy", key);
            assert!(entry(&key).is_some(), "missing proxy key {key}");
        }
        assert!(entry(&key_of("download", "wifi_only")).is_some());
    }

    #[test]
    fn secret_entries_are_sensitive_and_never_public_read() {
        for entry in entries() {
            if entry.visibility == ConfigVisibility::Secret {
                assert_ne!(
                    entry.visibility,
                    ConfigVisibility::PublicRead,
                    "{} cannot be both Secret and PublicRead",
                    entry.key.wire()
                );
                assert!(
                    entry.sensitive,
                    "secret entry {} must be sensitive",
                    entry.key.wire()
                );
            }
        }

        let secrets = wire_set(|entry| entry.visibility == ConfigVisibility::Secret);
        let expected: BTreeSet<String> = ["webdav.password", "agent.models"]
            .iter()
            .map(|wire| (*wire).to_string())
            .collect();
        assert_eq!(secrets, expected);
    }

    #[test]
    fn download_multi_segment_enabled_exists_with_a_default() {
        let entry = entry(&key_of("download", "multi_segment.enabled"))
            .expect("download.multi_segment.enabled must be registered");
        assert!(!entry.default_json.is_null());
        assert_eq!(entry.default_json, json!(true));
        assert_eq!(entry.visibility, ConfigVisibility::Owner);
        assert_eq!(entry.value_type, ConfigValueType::Bool);
    }

    #[test]
    fn every_default_validates_against_its_declared_type_and_constraints() {
        for entry in entries() {
            assert!(
                !entry.default_json.is_null(),
                "{} has no default; use {{}}/[] for JSON entries",
                entry.key.wire()
            );
            entry
                .validate_value(&entry.default_json)
                .unwrap_or_else(|error| {
                    panic!(
                        "{} default {} is invalid: {error}",
                        entry.key.wire(),
                        entry.default_json
                    )
                });
        }
    }

    #[test]
    fn string_enum_defaults_are_declared_members() {
        for entry in entries() {
            if entry.enum_values.is_empty() {
                continue;
            }
            if let Some(default) = entry.default_json.as_str() {
                assert!(
                    entry.enum_values.iter().any(|value| value == default),
                    "{} default {default:?} is not in {:?}",
                    entry.key.wire(),
                    entry.enum_values
                );
            }
        }
    }

    #[test]
    fn lookup_helpers_resolve_every_entry_and_reject_typos() {
        for entry in entries() {
            let parsed = ConfigKey::parse(&entry.key.wire()).expect("wire form round-trips");
            assert_eq!(parsed, entry.key);
            assert_eq!(
                super::entry(&parsed).map(|found| &found.key),
                Some(&entry.key),
                "{} did not resolve through the entry() helper",
                entry.key.wire()
            );
            assert!(has(&parsed));
        }

        for (module, key) in [
            ("proxy", "engine_stak"),
            ("proxy", "routing_mod"),
            ("module", "chanel.enabled"),
            ("module", "backup.enable"),
            ("download", "multi_segment"),
        ] {
            assert!(
                super::entry(&key_of(module, key)).is_none(),
                "{module}.{key} unexpectedly resolved"
            );
        }
    }

    #[test]
    fn module_entries_only_yields_the_requested_module() {
        for module in ["proxy", "download", "module", "theme"] {
            let found: Vec<_> = module_entries(module).collect();
            assert!(!found.is_empty(), "no entries for module {module}");
            assert!(
                found.iter().all(|entry| entry.key.module() == module),
                "module_entries({module}) leaked another module"
            );
        }
        assert_eq!(module_entries("does_not_exist").count(), 0);
    }

    #[test]
    fn registry_is_an_immutable_shared_static() {
        let first = entries();
        let second = entries();
        assert!(
            std::ptr::eq(first.as_ptr(), second.as_ptr()),
            "registry must be initialized once and reused"
        );
        let mut sorted: Vec<_> = entries().iter().map(|entry| entry.key.wire()).collect();
        sorted.sort();
        assert_eq!(
            sorted,
            entries()
                .iter()
                .map(|entry| entry.key.wire())
                .collect::<Vec<_>>(),
            "registry is sorted by wire key"
        );
    }
}
