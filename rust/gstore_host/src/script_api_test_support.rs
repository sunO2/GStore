//! Shared fixtures for the `ScriptApi` unit tests.
//!
//! Deliberately small and deterministic: every pack is built in memory, every
//! temp root is unique, and the UI responder polls the real event bridge ring
//! instead of reaching into internals.

use std::io::{Cursor, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use gstore_core::ports::fake::FakeHttpPort;
use serde_json::Value;

use crate::script_api::ScriptApiInner;

static SEQ: AtomicU64 = AtomicU64::new(0);

/// One isolated API + temp directory, removed on drop.
pub(crate) struct Harness {
    pub(crate) api: ScriptApiInner,
    pub(crate) root: PathBuf,
}

impl Drop for Harness {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

pub(crate) fn harness(tag: &str, ui_budget: Duration, eval_timeout: Duration) -> Harness {
    harness_with_cumulative(
        tag,
        ui_budget,
        eval_timeout,
        gstore_script::SandboxLimits::default().cumulative_eval_budget,
    )
}

pub(crate) fn harness_with_cumulative(
    tag: &str,
    ui_budget: Duration,
    eval_timeout: Duration,
    cumulative_budget: Duration,
) -> Harness {
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let root = std::env::temp_dir().join(format!(
        "gstore-script-api-{tag}-{}-{seq}",
        std::process::id()
    ));
    let data = root.join("data");
    let files = root.join("files");
    let cache = root.join("cache");
    let api = ScriptApiInner::init_with_ports(
        data.to_string_lossy().into_owned(),
        files.to_string_lossy().into_owned(),
        cache.to_string_lossy().into_owned(),
        std::sync::Arc::new(FakeHttpPort::new()),
        ui_budget,
        eval_timeout,
        cumulative_budget,
    )
    .expect("init ScriptApi");
    Harness { api, root }
}

/// Builds a legacy flat pack zip (`entry.js`, optional `detail.js`/`meta.json`).
pub(crate) fn zip_with(entry: &str, detail: Option<&str>, meta: Option<&str>) -> Vec<u8> {
    let mut buffer = Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        writer.start_file("entry.js", options).expect("zip entry");
        writer.write_all(entry.as_bytes()).expect("zip write");
        if let Some(detail) = detail {
            writer.start_file("detail.js", options).expect("zip detail");
            writer.write_all(detail.as_bytes()).expect("zip write");
        }
        if let Some(meta) = meta {
            writer.start_file("meta.json", options).expect("zip meta");
            writer.write_all(meta.as_bytes()).expect("zip write");
        }
        writer.finish().expect("zip finish");
    }
    buffer.into_inner()
}

/// Clears the UI registry and the module-event ring before a test case.
pub(crate) fn clear_ui_state() {
    crate::ui_api::reset_for_tests();
    crate::event_bridge::clear_buffer_for_tests();
}

/// Waits for a `script.ui_request` of `kind` on the real event ring.
pub(crate) fn wait_for_ui_request(
    kind: &str,
    timeout: Duration,
) -> Result<(String, Value), String> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some((event_type, data)) = crate::event_bridge::last_event_for_tests() {
            if event_type == "script.ui_request" {
                let value: Value = serde_json::from_slice(&data)
                    .map_err(|error| format!("ui event is not JSON: {error}"))?;
                let payload = &value["payload"];
                if payload["kind"].as_str() == Some(kind) {
                    let request_id = payload["request_id"]
                        .as_str()
                        .ok_or_else(|| "ui event has no request_id".to_string())?
                        .to_owned();
                    return Ok((request_id, payload.clone()));
                }
            }
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "no `script.ui_request` with kind `{kind}` was emitted"
            ));
        }
        thread::sleep(Duration::from_millis(2));
    }
}

/// Background UI lane: waits for `kind`, asserts the payload fragment, answers.
pub(crate) fn spawn_responder(
    kind: &'static str,
    response: String,
    delay: Duration,
    expected_fragment: Option<String>,
) -> JoinHandle<Result<(String, Value), String>> {
    thread::spawn(move || {
        let (request_id, payload) = wait_for_ui_request(kind, Duration::from_secs(5))?;
        if let Some(fragment) = expected_fragment {
            let message = payload["message"].as_str().unwrap_or_default();
            if !message.contains(&fragment) {
                return Err(format!(
                    "ui payload `{message}` does not contain `{fragment}`"
                ));
            }
        }
        if !delay.is_zero() {
            thread::sleep(delay);
        }
        crate::bridge::UiApi::new()
            .respond(request_id.clone(), response)
            .map_err(|error| error.to_string())?;
        Ok((request_id, payload))
    })
}
