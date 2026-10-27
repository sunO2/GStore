//! Fake host covering all twelve capabilities and recording every call.

use std::collections::HashMap;
use std::sync::Mutex;

use gstore_script::{
    ChannelApp, CheckVersionRequest, ConfigGetRequest, DatabaseAppRequest, DatabaseAppsRequest,
    DatabaseInsertRequest, EnvAllRequest, EnvGetRequest, EnvHasRequest, EnvSnapshot, HttpMethod,
    HttpRequest, HttpResponse, InstalledInfo, LogLevel, LogRequest, NativeCallRequest,
    ScriptChannel, ScriptError, ScriptHost, UiRequest,
};
use serde_json::{json, Value as JsonValue};

use super::call::{app_from_raw, push, CallDetail, SharedCalls};

pub struct FakeHost {
    calls: SharedCalls,
    env: HashMap<String, EnvSnapshot>,
    apps: Mutex<HashMap<String, Vec<ChannelApp>>>,
}

pub(crate) fn new(calls: SharedCalls, env: HashMap<String, EnvSnapshot>) -> FakeHost {
    FakeHost {
        calls,
        env,
        apps: Mutex::new(HashMap::new()),
    }
}

impl FakeHost {
    fn record(&self, method: &'static str, channel: &ScriptChannel, detail: CallDetail) {
        push(&self.calls, method, channel, detail);
    }

    fn env_for(&self, channel: &ScriptChannel) -> EnvSnapshot {
        self.env.get(channel.as_str()).cloned().unwrap_or_default()
    }
}

impl ScriptHost for FakeHost {
    fn http(
        &self,
        channel: &ScriptChannel,
        request: HttpRequest,
    ) -> Result<HttpResponse, ScriptError> {
        self.record(
            match request.method {
                HttpMethod::Get => "host.network.get",
                HttpMethod::Post => "host.network.post",
            },
            channel,
            CallDetail::Http {
                http_method: request.method,
                url: request.url.clone(),
                opts: request.opts.clone(),
            },
        );
        if request.url.contains("denied") {
            return Err(ScriptError::host("network denied"));
        }
        if request.url.contains("500") {
            return Ok(HttpResponse::new(500, json!({ "msg": "server error" })));
        }
        if request.url.contains("401") {
            return Ok(HttpResponse::new(401, json!({ "msg": "unauthorized" })));
        }
        if request.url.contains("/search") {
            return Ok(HttpResponse::new(
                200,
                json!([{
                    "packageName": "org.example.dolphin",
                    "name": "Dolphin",
                    "developer": "dev",
                    "repo": "org/dolphin",
                    "description": "emulator",
                    "versionName": "1.0",
                }]),
            ));
        }
        Ok(HttpResponse::new(
            200,
            json!({ "echo": request.url, "opts": request.opts }),
        ))
    }

    fn db_get_apps(
        &self,
        channel: &ScriptChannel,
        _request: DatabaseAppsRequest,
    ) -> Result<Vec<ChannelApp>, ScriptError> {
        self.record(
            "host.database.getAppsByChannel",
            channel,
            CallDetail::DbApps,
        );
        let apps = self.apps.lock().expect("app store lock");
        Ok(apps.get(channel.as_str()).cloned().unwrap_or_default())
    }

    fn db_get_app(
        &self,
        channel: &ScriptChannel,
        request: DatabaseAppRequest,
    ) -> Result<Option<ChannelApp>, ScriptError> {
        self.record(
            "host.database.getApp",
            channel,
            CallDetail::DbApp {
                app_id: request.app_id.clone(),
            },
        );
        let apps = self.apps.lock().expect("app store lock");
        Ok(apps
            .get(channel.as_str())
            .and_then(|rows| rows.iter().find(|row| row.app_id == request.app_id))
            .cloned())
    }

    fn db_insert_apps(
        &self,
        channel: &ScriptChannel,
        request: DatabaseInsertRequest,
    ) -> Result<usize, ScriptError> {
        self.record(
            "host.database.insertApps",
            channel,
            CallDetail::DbInsert {
                apps: request.apps.clone(),
            },
        );
        let mut apps = self.apps.lock().expect("app store lock");
        let rows = apps.entry(channel.as_str().to_owned()).or_default();
        for raw in &request.apps {
            rows.push(app_from_raw(channel, raw));
        }
        Ok(request.apps.len())
    }

    fn config_get(
        &self,
        channel: &ScriptChannel,
        request: ConfigGetRequest,
    ) -> Result<JsonValue, ScriptError> {
        self.record(
            "host.config.get",
            channel,
            CallDetail::Config {
                key: request.key.clone(),
            },
        );
        match request.key.as_str() {
            "panic" => panic!("fake host panic"),
            "error" => Err(ScriptError::host("config refused")),
            "missing" => Ok(JsonValue::Null),
            _ => Ok(json!("config-value")),
        }
    }

    fn env_get(
        &self,
        channel: &ScriptChannel,
        request: EnvGetRequest,
    ) -> Result<Option<String>, ScriptError> {
        self.record(
            "host.env.get",
            channel,
            CallDetail::EnvGet {
                name: request.name.clone(),
            },
        );
        Ok(self.env_for(channel).get(&request.name).cloned())
    }

    fn env_all(
        &self,
        channel: &ScriptChannel,
        _request: EnvAllRequest,
    ) -> Result<EnvSnapshot, ScriptError> {
        self.record("host.env.all", channel, CallDetail::EnvAll);
        Ok(self.env_for(channel))
    }

    fn env_has(
        &self,
        channel: &ScriptChannel,
        request: EnvHasRequest,
    ) -> Result<bool, ScriptError> {
        self.record(
            "host.env.has",
            channel,
            CallDetail::EnvHas {
                name: request.name.clone(),
            },
        );
        Ok(self.env_for(channel).contains_key(&request.name))
    }

    fn check_version(
        &self,
        channel: &ScriptChannel,
        request: CheckVersionRequest,
    ) -> Result<InstalledInfo, ScriptError> {
        self.record(
            "host.utils.checkVersion",
            channel,
            CallDetail::CheckVersion {
                package: request.package_name.clone(),
            },
        );
        Ok(InstalledInfo::installed(
            Some("1.2.3".to_owned()),
            Some(42),
            Some("Fake App".to_owned()),
        ))
    }

    fn log(&self, channel: &ScriptChannel, request: LogRequest) -> Result<(), ScriptError> {
        self.record(
            match request.level {
                LogLevel::Info => "host.log.info",
                LogLevel::Error => "host.log.error",
            },
            channel,
            CallDetail::Log {
                level: request.level,
                message: request.message,
            },
        );
        Ok(())
    }

    fn native_call(
        &self,
        channel: &ScriptChannel,
        request: NativeCallRequest,
    ) -> Result<Option<JsonValue>, ScriptError> {
        self.record(
            "host.native.call",
            channel,
            CallDetail::Native {
                namespace: request.namespace.clone(),
                method: request.method.clone(),
                payload: request.payload.clone(),
            },
        );
        match (request.namespace.as_str(), request.method.as_str()) {
            ("ui", "show") => Ok(Some(json!({ "shown": true }))),
            ("core", "ping") => Ok(Some(json!("pong"))),
            _ => Ok(None),
        }
    }

    fn ui_request(
        &self,
        channel: &ScriptChannel,
        request: UiRequest,
    ) -> Result<JsonValue, ScriptError> {
        self.record(
            "script.ui_request",
            channel,
            CallDetail::Ui {
                method: request.method,
                payload: request.payload,
            },
        );
        Ok(json!({ "accepted": true }))
    }
}
