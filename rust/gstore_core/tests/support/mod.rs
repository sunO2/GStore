//! Shared fakes for the ScriptChannel/ScriptDetail integration tests.

use std::sync::{Arc, Mutex};

use gstore_script::{
    HttpRequest, HttpResponse, LogRequest, ScriptChannel as EngineChannel, ScriptError, ScriptHost,
};
use serde_json::{json, Value as JsonValue};

#[derive(Debug, Clone, PartialEq)]
pub enum HostCall {
    Http { channel: String, url: String },
    Log { channel: String, message: String },
}

#[derive(Default)]
pub struct FakeHost {
    calls: Mutex<Vec<HostCall>>,
}

impl FakeHost {
    #[allow(dead_code)] // used by the example test crate only
    pub fn calls(&self) -> Vec<HostCall> {
        self.calls.lock().expect("fake host call lock").clone()
    }

    fn record(&self, call: HostCall) {
        self.calls.lock().expect("fake host call lock").push(call);
    }
}

impl ScriptHost for FakeHost {
    fn http(
        &self,
        channel: &EngineChannel,
        request: HttpRequest,
    ) -> Result<HttpResponse, ScriptError> {
        self.record(HostCall::Http {
            channel: channel.as_str().to_owned(),
            url: request.url.clone(),
        });
        Ok(HttpResponse::new(200, payload_for(&request.url)))
    }

    fn log(&self, channel: &EngineChannel, request: LogRequest) -> Result<(), ScriptError> {
        self.record(HostCall::Log {
            channel: channel.as_str().to_owned(),
            message: request.message,
        });
        Ok(())
    }
}

pub type SharedHost = Arc<FakeHost>;

pub fn fake_host() -> SharedHost {
    Arc::new(FakeHost::default())
}

fn payload_for(url: &str) -> JsonValue {
    if url.contains("/api/search") || url.contains("/api/apps") {
        json!([app_row()])
    } else if url.contains("/api/detail") {
        json!({
            "appId": "org.example.dolphin",
            "packageName": "org.example.dolphin",
            "name": "Dolphin",
            "icon": "https://example.test/dolphin.png",
            "description": "Flipper-powered browser",
            "versionName": "2.1.0",
            "developer": "Example Team",
            "homepage": "https://example.test/dolphin",
            "downloads": [{
                "url": "https://example.test/dolphin-2.1.0.apk",
                "name": "dolphin-2.1.0.apk",
                "size": 1234,
                "version": "2.1.0",
            }],
        })
    } else {
        app_row()
    }
}

fn app_row() -> JsonValue {
    json!({
        "packageName": "org.example.dolphin",
        "appId": "org.example.dolphin",
        "name": "Dolphin",
        "icon": "https://example.test/dolphin.png",
        "description": "Flipper-powered browser",
        "developer": "Example Team",
        "versionName": "2.1.0",
        "versionCode": 21,
        "rating": 4.5,
        "category": ["tools"],
        "repo": "dolphin",
    })
}
