//! Optional `const CHANNEL_META = { name, description, icon }` reader.
//!
//! Dart `_readMeta` evaluates a single expression and silently keeps the
//! channel-key defaults when the script has no metadata or the read throws.
//! That degradation is deliberate: a metadata typo must never make a channel
//! unusable.

use gstore_script::ScriptRuntime;
use serde_json::Value as JsonValue;

use crate::dto::{ChannelKey, ChannelKind, ChannelMeta};

/// Metadata advertised by a script (all fields optional).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ScriptMeta {
    pub(crate) name: Option<String>,
    pub(crate) description: Option<String>,
    pub(crate) icon: Option<String>,
}

/// Reads `CHANNEL_META`, returning empty metadata on absence or failure.
pub(crate) fn read(runtime: &ScriptRuntime) -> ScriptMeta {
    let raw = runtime.eval("typeof CHANNEL_META !== 'undefined' ? CHANNEL_META : null");
    let Ok(JsonValue::Object(map)) = raw else {
        return ScriptMeta::default();
    };
    ScriptMeta {
        name: text(&map, "name"),
        description: text(&map, "description"),
        icon: text(&map, "icon"),
    }
}

/// Builds the driver metadata, defaulting name to the channel key.
pub(crate) fn build_meta(key: &ChannelKey, script_meta: &ScriptMeta) -> ChannelMeta {
    ChannelMeta {
        kind: ChannelKind::JsLocal,
        name: script_meta
            .name
            .clone()
            .unwrap_or_else(|| key.as_str().to_owned()),
        description: script_meta
            .description
            .clone()
            .unwrap_or_else(|| "脚本化渠道".to_string()),
        enabled: true,
        priority: 0,
        support_offline: false,
        last_update_time: None,
        version: None,
    }
}

fn text(map: &serde_json::Map<String, JsonValue>, key: &str) -> Option<String> {
    map.get(key)
        .and_then(JsonValue::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}
