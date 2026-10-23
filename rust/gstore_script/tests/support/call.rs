//! Recorded host call model shared by the fake host and the tests.

use std::sync::{Arc, Mutex};

use gstore_script::{ChannelApp, HttpMethod, LogLevel, ScriptChannel};
use serde_json::Value as JsonValue;

pub type SharedCalls = Arc<Mutex<Vec<Call>>>;

/// One recorded host call: method string, channel, and typed arguments.
#[derive(Debug, Clone, PartialEq)]
pub struct Call {
    pub method: &'static str,
    pub channel: String,
    pub detail: CallDetail,
}

#[derive(Debug, Clone, PartialEq)]
pub enum CallDetail {
    Http {
        http_method: HttpMethod,
        url: String,
        opts: JsonValue,
    },
    DbApps,
    DbApp {
        app_id: String,
    },
    DbInsert {
        apps: Vec<JsonValue>,
    },
    Config {
        key: String,
    },
    EnvGet {
        name: String,
    },
    EnvAll,
    EnvHas {
        name: String,
    },
    CheckVersion {
        package: String,
    },
    Log {
        level: LogLevel,
        message: String,
    },
    Native {
        namespace: String,
        method: String,
        payload: JsonValue,
    },
    Ui {
        method: String,
        payload: JsonValue,
    },
}

/// Append one recorded call.
pub(crate) fn push(
    calls: &SharedCalls,
    method: &'static str,
    channel: &ScriptChannel,
    detail: CallDetail,
) {
    calls.lock().expect("call log lock").push(Call {
        method,
        channel: channel.as_str().to_owned(),
        detail,
    });
}

/// Build a stored app from a script row, pinning the runtime channel.
pub(crate) fn app_from_raw(channel: &ScriptChannel, raw: &JsonValue) -> ChannelApp {
    let text = |key: &str| {
        raw.get(key)
            .and_then(JsonValue::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    ChannelApp {
        app_id: text("appId"),
        name: text("name"),
        user: text("user"),
        repositories: text("repositories"),
        apprepo: raw
            .get("apprepo")
            .and_then(JsonValue::as_str)
            .map(str::to_owned),
        icon: text("icon"),
        description: text("description"),
        category: raw
            .get("category")
            .and_then(JsonValue::as_str)
            .map(str::to_owned),
        add_time: raw.get("addTime").and_then(JsonValue::as_i64).unwrap_or(0),
        channel_code: channel.as_str().to_owned(),
        extra: raw.get("extra").cloned(),
    }
}
