//! Shared fake host + helpers for the `script_host_api_*` integration tests.
#![allow(dead_code)] // Shared fixture: each integration-test crate uses a subset.
mod call;
mod fake_host;

#[allow(unused_imports)] // Shared fixture: each integration-test crate uses a subset.
pub use call::{Call, CallDetail, SharedCalls};
#[allow(unused_imports)] // Shared fixture: each integration-test crate uses a subset.
pub use fake_host::FakeHost;

use std::sync::Arc;
use std::time::Duration;

use gstore_script::{ScriptChannel, ScriptHost, ScriptOptions, ScriptRuntime};

/// Build a fake host plus the shared call log.
pub fn fake_host() -> (Arc<FakeHost>, SharedCalls) {
    use gstore_script::EnvSnapshot;
    use std::collections::{BTreeMap, HashMap};

    let mut env: HashMap<String, EnvSnapshot> = HashMap::new();
    env.insert(
        "js.a".to_owned(),
        BTreeMap::from([("NAME".to_owned(), "A".to_owned())]),
    );
    env.insert(
        "js.b".to_owned(),
        BTreeMap::from([("NAME".to_owned(), "B".to_owned())]),
    );
    let calls: SharedCalls = Arc::new(std::sync::Mutex::new(Vec::new()));
    let host = Arc::new(fake_host::new(Arc::clone(&calls), env));
    (host, calls)
}

/// Spawn a runtime with a short, deterministic budget.
pub fn runtime(channel: &str, host: Arc<dyn ScriptHost>) -> ScriptRuntime {
    let channel = ScriptChannel::new(channel).expect("valid channel key");
    let options = ScriptOptions::default().with_eval_timeout(Duration::from_millis(2_000));
    ScriptRuntime::spawn(channel, options, host).expect("runtime spawns")
}

/// Snapshot the recorded calls.
pub fn recorded(calls: &SharedCalls) -> Vec<Call> {
    calls.lock().expect("call log lock").clone()
}
