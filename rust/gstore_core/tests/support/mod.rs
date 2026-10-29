//! Shared fakes for the ScriptChannel/ScriptDetail integration tests.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use gstore_core::channel::ScriptChannelStore;
use gstore_core::dto::{AppSummary, ChannelKey};
use gstore_core::error::Error;
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

/// Deterministic in-memory `ScriptChannelStore` for driver parity tests.
#[derive(Default)]
pub struct MemoryStore {
    rows: Mutex<BTreeMap<(String, String), AppSummary>>,
}

impl MemoryStore {
    pub fn seed(&self, channel: &str, apps: Vec<AppSummary>) {
        let mut rows = self.rows.lock().expect("memory store lock");
        for app in apps {
            rows.insert((channel.to_owned(), app.app_id.clone()), app);
        }
    }

    pub fn rows(&self, channel: &str) -> Vec<AppSummary> {
        self.rows
            .lock()
            .expect("memory store lock")
            .iter()
            .filter(|((key, _), _)| key == channel)
            .map(|(_, app)| app.clone())
            .collect()
    }

    pub fn contains(&self, channel: &str, app_id: &str) -> bool {
        self.rows
            .lock()
            .expect("memory store lock")
            .contains_key(&(channel.to_owned(), app_id.to_owned()))
    }
}

impl ScriptChannelStore for MemoryStore {
    fn list_apps(&self, channel: &ChannelKey) -> Result<Vec<AppSummary>, Error> {
        Ok(self.rows(channel.as_str()))
    }

    fn get_app(&self, channel: &ChannelKey, app_id: &str) -> Result<Option<AppSummary>, Error> {
        Ok(self
            .rows
            .lock()
            .expect("memory store lock")
            .get(&(channel.as_str().to_owned(), app_id.to_owned()))
            .cloned())
    }

    fn insert_apps(&self, channel: &ChannelKey, apps: &[AppSummary]) -> Result<(), Error> {
        self.seed(channel.as_str(), apps.to_vec());
        Ok(())
    }

    fn remove_app(&self, channel: &ChannelKey, app_id: &str) -> Result<(), Error> {
        self.rows
            .lock()
            .expect("memory store lock")
            .remove(&(channel.as_str().to_owned(), app_id.to_owned()));
        Ok(())
    }
}

pub fn memory_store() -> Arc<MemoryStore> {
    Arc::new(MemoryStore::default())
}

pub fn sample_app(app_id: &str, name: &str) -> AppSummary {
    AppSummary {
        app_id: app_id.to_owned(),
        package_name: Some(app_id.to_owned()),
        name: name.to_owned(),
        user: "Example Team".to_owned(),
        repositories: name.to_lowercase(),
        icon: format!("https://example.test/{app_id}.png"),
        des: format!("{name} description"),
        readme: Some(format!("# {name}")),
        category: Some(vec!["tools".to_owned()]),
        extra: None,
        labels: Vec::new(),
    }
}

pub mod parity;
