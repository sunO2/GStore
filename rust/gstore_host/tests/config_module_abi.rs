//! Todo 13 real-surface tests: ABI v5 module configuration end-to-end.
//!
//! Every test here dlopen's a real fixture `.so` compiled from
//! `tests/fixtures/config_module.c` (no mock module, no network, no device) and
//! drives the host through `ModuleHandle::mount_from_so` + the ABI v5 config
//! vtable. The fixture exports a unique path per test so its static record
//! buffer starts empty; `FIXTURE_AUTO_SUBSCRIBE=0` lets each test install the
//! exact filters it asserts on.
//!
//! The module binding, host pump, and config store are process-global, so all
//! tests take [`SERIAL`]. They must also drop every `ModuleHandle` before they
//! finish; `unref` then removes the module from the manager for the next test.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, Once};
use std::time::{Duration, Instant};

use gstore_contract::abi::{
    host_abi_satisfies, GStoreConfigApiV1, GStoreModuleApi, GStoreModuleEntry,
    ABI_ERR_ABI_MISMATCH, ABI_ERR_CONFIG_BAD_TOKEN, ABI_ERR_CONFIG_FORBIDDEN,
    ABI_ERR_CONFIG_INVALID, ABI_ERR_CONFIG_NOT_FOUND, CONFIG_CAP_ALL, GSTORE_MODULE_ABI_VERSION,
};
use gstore_host::bridge::{ConfigApi, CoreApi, EventBridge, HostInspector, InstanceHandle, ModuleHandle};
use serde_json::Value;

static SERIAL: Mutex<()> = Mutex::new(());

fn serial() -> MutexGuard<'static, ()> {
    SERIAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn scratch(tag: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "gstore_config_module_abi_{tag}_{}_{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0)
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).expect("create scratch dir");
    root
}

fn init_core(root: &Path) -> CoreApi {
    CoreApi::init(
        root.join("data").to_string_lossy().into_owned(),
        root.join("files").to_string_lossy().into_owned(),
        root.join("cache").to_string_lossy().into_owned(),
    )
    .expect("CoreApi::init")
}

fn build_fixture(
    tag: &str,
    name: &str,
    abi: u32,
    min_host_abi: u32,
    auto_subscribe: bool,
) -> PathBuf {
    build_fixture_impl(tag, name, abi, min_host_abi, auto_subscribe, false)
}

fn build_fixture_with_on_event(
    tag: &str,
    name: &str,
    abi: u32,
    min_host_abi: u32,
    auto_subscribe: bool,
) -> PathBuf {
    build_fixture_impl(tag, name, abi, min_host_abi, auto_subscribe, true)
}

fn build_fixture_impl(
    tag: &str,
    name: &str,
    abi: u32,
    min_host_abi: u32,
    auto_subscribe: bool,
    on_event: bool,
) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target/config_module_abi_fixtures")
        .join(tag);
    std::fs::create_dir_all(&dir).expect("create fixture dir");
    let output = dir.join(format!("libgstore_mod_{name}.so"));
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/config_module.c");
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let status = std::process::Command::new(cc)
        .args([
            "-shared", "-fPIC", "-std=c99", "-Wall", "-Wextra", "-Werror",
        ])
        .arg(format!("-DFIXTURE_NAME={name}"))
        .arg(format!("-DFIXTURE_ABI={abi}"))
        .arg(format!("-DFIXTURE_MIN_HOST_ABI={min_host_abi}"))
        .arg(format!(
            "-DFIXTURE_AUTO_SUBSCRIBE={}",
            u8::from(auto_subscribe)
        ))
        .arg(format!("-DFIXTURE_ON_EVENT={}", u8::from(on_event)))
        .arg("-o")
        .arg(&output)
        .arg(&source)
        .status()
        .expect("spawn C compiler for config fixture");
    assert!(status.success(), "C fixture compile failed: {status}");
    output
}

/// Builds the real `gstore_mod_download` `.so` (its crate is outside the host
/// workspace and has its own target dir, so a nested `cargo build` cannot race
/// the outer `cargo test` target lock). The test that uses it is deterministic:
/// a missing/stale artifact is rebuilt instead of skipped.
fn build_download_module() -> PathBuf {
    static BUILD: Once = Once::new();
    let manifest =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../gstore_mod_download/Cargo.toml");
    let so = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../gstore_mod_download/target/debug/libgstore_mod_download.so");
    BUILD.call_once(|| {
        let status = std::process::Command::new("cargo")
            .args(["build", "--manifest-path"])
            .arg(&manifest)
            .args(["--lib"])
            .status()
            .unwrap_or_else(|error| {
                panic!("spawn cargo build for {}: {error}", manifest.display())
            });
        assert!(
            status.success(),
            "cargo build --manifest-path {} --lib failed: {status}",
            manifest.display()
        );
    });
    assert!(
        so.exists(),
        "download module .so missing after build: {}",
        so.display()
    );
    so
}

fn download_stats(instance: &InstanceHandle) -> Value {
    let raw = instance
        .call("download.stats".to_string(), Vec::new())
        .expect("download.stats");
    serde_json::from_slice(&raw).expect("download.stats is JSON")
}

fn mount(tag: &str, name: &str) -> ModuleHandle {
    let path = build_fixture(tag, name, 5, 5, false);
    ModuleHandle::mount_from_so(path.to_string_lossy().into_owned())
        .unwrap_or_else(|error| panic!("mount {name}: {error}"))
}

fn call(module: &ModuleHandle, method: &str, payload: impl AsRef<[u8]>) -> String {
    let raw = module
        .call_static(method.to_string(), payload.as_ref().to_vec())
        .unwrap_or_else(|error| panic!("module call {method}: {error}"));
    String::from_utf8(raw).expect("fixture response is UTF-8")
}

fn split_code_json(text: &str) -> (i32, String) {
    let (code, json) = text
        .split_once('|')
        .unwrap_or_else(|| panic!("expected `<code>|<json>`, got {text:?}"));
    (
        code.parse()
            .unwrap_or_else(|_| panic!("bad code in {text:?}")),
        json.to_string(),
    )
}

fn code_only(text: &str) -> i32 {
    text.parse().unwrap_or_else(|_| panic!("bad code {text:?}"))
}

fn fixture_get(module: &ModuleHandle, target: &str, key: &str) -> (i32, String) {
    split_code_json(&call(module, "get", format!("{target}|{key}")))
}

fn fixture_list(module: &ModuleHandle, target: &str) -> String {
    let (code, json) = split_code_json(&call(module, "list", target));
    assert_eq!(code, 0, "list({target:?}) failed: {json}");
    json
}

fn fixture_set(module: &ModuleHandle, key: &str, value_json: &str) -> i32 {
    code_only(&call(module, "set", format!("{key}|{value_json}")))
}

fn fixture_subscribe(module: &ModuleHandle, target: &str, key: &str) -> (i32, u64) {
    let (code, token) = split_code_json(&call(module, "subscribe", format!("{target}|{key}")));
    let token = token
        .parse()
        .unwrap_or_else(|_| panic!("bad subscribe token {token:?}"));
    (code, token)
}

fn fixture_unsubscribe(module: &ModuleHandle, token: u64) -> i32 {
    code_only(&call(module, "unsubscribe", token.to_string()))
}

fn fixture_entry_probe(module: &ModuleHandle) -> (u32, u32, bool) {
    let text = call(module, "entry_probe", Vec::new());
    let mut parts = text.split('|');
    (
        parts.next().unwrap().parse().unwrap(),
        parts.next().unwrap().parse().unwrap(),
        parts.next().unwrap() == "1",
    )
}

fn clear_records(module: &ModuleHandle) {
    assert_eq!(call(module, "clear_records", Vec::new()), "ok");
}

fn deliveries(module: &ModuleHandle) -> Vec<Value> {
    let raw = call(module, "dump", Vec::new());
    raw.lines()
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_str::<Value>(line).expect("recorded change is JSON"))
        .collect()
}

fn keys(changes: &[Value]) -> Vec<String> {
    changes
        .iter()
        .map(|change| {
            format!(
                "{}.{}",
                change
                    .get("module")
                    .and_then(Value::as_str)
                    .expect("module"),
                change.get("key").and_then(Value::as_str).expect("key")
            )
        })
        .collect()
}

fn values(changes: &[Value]) -> Vec<Value> {
    changes
        .iter()
        .map(|change| change.get("value").cloned().unwrap_or(Value::Null))
        .collect()
}

fn set_record_file(path: &Path) {
    std::env::set_var("GS_CONFIG_RECORD_FILE", path);
}

fn clear_record_file() {
    let _ = std::env::remove_var("GS_CONFIG_RECORD_FILE");
}

fn record_lines(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .map(|text| {
            text.lines()
                .filter(|line| !line.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn count_prefixed(path: &Path, prefix: &str) -> usize {
    record_lines(path)
        .iter()
        .filter(|line| line.starts_with(prefix))
        .count()
}

fn wait_for_prefix(path: &Path, prefix: &str) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if count_prefixed(path, prefix) >= 1 {
            return true;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    false
}

const DOWNLOAD_KEYS: [&str; 6] = [
    "download.default_connections",
    "download.max_concurrent",
    "download.max_retries",
    "download.multi_segment.enabled",
    "download.speed_limit_bps",
    "download.wifi_only",
];

// ---------------------------------------------------------------------------
// 1. ABI v5 get/set/list round-trip + unregistered-key negatives (Todo 13 #1/#13)
// ---------------------------------------------------------------------------

#[test]
fn abi_v5_get_set_list_round_trip_and_unregistered_keys_are_typed() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("round-trip");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let module = mount("round-trip", "download");

    let (code, json) = fixture_get(&module, "", "max_concurrent");
    assert_eq!(code, 0, "own get must succeed: {json}");
    assert_eq!(json, "3", "registry default for download.max_concurrent");

    assert_eq!(fixture_set(&module, "max_concurrent", "7"), 0);
    assert_eq!(
        config
            .get("download".into(), "max_concurrent".into(), false)
            .unwrap(),
        "7"
    );
    let (code, json) = fixture_get(&module, "", "max_concurrent");
    assert_eq!(
        (code, json.as_str()),
        (0, "7"),
        "vtable must observe the committed value"
    );

    let listed: Vec<Value> = serde_json::from_str(&fixture_list(&module, "")).unwrap();
    let listed_keys: Vec<String> = listed
        .iter()
        .map(|entry| {
            entry
                .get("wireKey")
                .and_then(Value::as_str)
                .unwrap()
                .to_string()
        })
        .collect();
    assert_eq!(
        listed_keys,
        DOWNLOAD_KEYS.map(str::to_string).to_vec(),
        "list(NULL) returns every own-module registry entry in order"
    );
    let max_concurrent = listed
        .iter()
        .find(|entry| entry["wireKey"] == "download.max_concurrent")
        .expect("max_concurrent listed");
    assert_eq!(max_concurrent["value"], Value::from(7));
    assert_eq!(max_concurrent["visibility"], Value::from("owner"));
    assert!(max_concurrent["revision"].as_u64().unwrap() > 0);

    // Negative: unregistered keys are typed -10, not a silent success.
    assert_eq!(
        fixture_get(&module, "", "does_not_exist").0,
        ABI_ERR_CONFIG_NOT_FOUND
    );
    assert_eq!(
        fixture_get(&module, "network", "does_not_exist").0,
        ABI_ERR_CONFIG_NOT_FOUND
    );
    assert_eq!(
        fixture_set(&module, "does_not_exist", "1"),
        ABI_ERR_CONFIG_NOT_FOUND
    );
    let unknown_list: Value =
        serde_json::from_str(&fixture_list(&module, "no_such_module")).unwrap();
    assert_eq!(
        unknown_list,
        Value::Array(Vec::new()),
        "list(unknown module) is empty"
    );

    // Negative: out-of-range and malformed JSON keep the old committed value.
    assert_eq!(
        fixture_set(&module, "max_concurrent", "99"),
        ABI_ERR_CONFIG_INVALID
    );
    assert_eq!(
        fixture_set(&module, "max_concurrent", "{not-json"),
        ABI_ERR_CONFIG_INVALID
    );
    assert_eq!(
        config
            .get("download".into(), "max_concurrent".into(), false)
            .unwrap(),
        "7"
    );

    drop(module);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 2. Whole-module delivery is own-module only (Todo 13 #2/#4)
// ---------------------------------------------------------------------------

#[test]
fn whole_module_subscription_delivers_only_the_own_module() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("whole-module");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let download = mount("whole-module", "download");
    let theme = mount("whole-module", "theme");
    assert_eq!(fixture_subscribe(&download, "", "").0, 0);
    assert_eq!(fixture_subscribe(&theme, "", "").0, 0);
    clear_records(&download);
    clear_records(&theme);

    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "5".into(),
            "user".into(),
        )
        .unwrap();
    config
        .set(
            "download".into(),
            "max_retries".into(),
            "1".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        keys(&deliveries(&download)),
        vec!["download.max_concurrent", "download.max_retries"],
        "whole-module subscription sees each own change once, in commit order"
    );
    assert_eq!(
        deliveries(&theme),
        Vec::<Value>::new(),
        "theme must not receive download changes"
    );

    config
        .set("theme".into(), "mode".into(), "2".into(), "user".into())
        .unwrap();
    assert_eq!(keys(&deliveries(&theme)), vec!["theme.mode"]);
    assert_eq!(
        keys(&deliveries(&download)),
        vec!["download.max_concurrent", "download.max_retries"],
        "download must not receive a theme change"
    );

    drop(download);
    drop(theme);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 3. Exact-key delivery (Todo 13 #3)
// ---------------------------------------------------------------------------

#[test]
fn exact_key_subscription_delivers_only_that_key() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("exact-key");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let module = mount("exact-key", "download");
    assert_eq!(fixture_subscribe(&module, "", "max_concurrent").0, 0);
    assert_eq!(
        fixture_subscribe(&module, "", "does_not_exist").0,
        ABI_ERR_CONFIG_NOT_FOUND,
        "an unregistered exact key is rejected at subscription time"
    );
    clear_records(&module);

    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "4".into(),
            "user".into(),
        )
        .unwrap();
    config
        .set(
            "download".into(),
            "max_retries".into(),
            "2".into(),
            "user".into(),
        )
        .unwrap();
    config
        .set(
            "download".into(),
            "multi_segment.enabled".into(),
            "false".into(),
            "user".into(),
        )
        .unwrap();

    assert_eq!(
        keys(&deliveries(&module)),
        vec!["download.max_concurrent"],
        "exact-key filter must drop every other key"
    );

    drop(module);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 4. PublicRead cross-module get/subscribe succeeds (Todo 13 #5)
// ---------------------------------------------------------------------------

#[test]
fn public_read_cross_module_get_subscribe_and_list_succeed() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("public-read");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let module = mount("public-read", "download");

    config
        .set(
            "network".into(),
            "proxy_url".into(),
            serde_json::json!("https://p1.test/").to_string(),
            "user".into(),
        )
        .unwrap();
    let (code, json) = fixture_get(&module, "network", "proxy_url");
    assert_eq!(
        (code, json.as_str()),
        (0, "\"https://p1.test/\""),
        "PublicRead foreign get"
    );

    assert_eq!(fixture_subscribe(&module, "network", "proxy_url").0, 0);
    clear_records(&module);
    config
        .set(
            "network".into(),
            "proxy_url".into(),
            serde_json::json!("https://p2.test/").to_string(),
            "user".into(),
        )
        .unwrap();
    let changes = deliveries(&module);
    assert_eq!(keys(&changes), vec!["network.proxy_url"]);
    assert_eq!(values(&changes), vec![Value::from("https://p2.test/")]);

    let listed: Value = serde_json::from_str(&fixture_list(&module, "network")).unwrap();
    let entries = listed.as_array().expect("list array");
    assert_eq!(
        entries.len(),
        1,
        "foreign list returns only the PublicRead entry"
    );
    assert_eq!(entries[0]["wireKey"], "network.proxy_url");
    assert_eq!(entries[0]["visibility"], "public_read");
    assert_eq!(entries[0]["value"], "https://p2.test/");

    drop(module);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 5. Owner/Secret cross-module get + exact-key subscribe are rejected (Todo 13 #6)
// ---------------------------------------------------------------------------

#[test]
fn owner_and_secret_cross_module_access_is_forbidden() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("forbidden");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    config
        .set(
            "theme".into(),
            "config".into(),
            r#"{"dark":true}"#.into(),
            "user".into(),
        )
        .unwrap();
    config
        .set(
            "webdav".into(),
            "password".into(),
            serde_json::json!("s3cr3t").to_string(),
            "user".into(),
        )
        .unwrap();
    let module = mount("forbidden", "download");

    assert_eq!(
        fixture_get(&module, "theme", "config").0,
        ABI_ERR_CONFIG_FORBIDDEN,
        "foreign Owner read must be forbidden"
    );
    assert_eq!(
        fixture_get(&module, "webdav", "password").0,
        ABI_ERR_CONFIG_FORBIDDEN,
        "foreign Secret read must be forbidden"
    );
    assert_eq!(
        fixture_subscribe(&module, "theme", "config").0,
        ABI_ERR_CONFIG_FORBIDDEN,
        "explicit foreign Owner key subscription must be forbidden"
    );
    assert_eq!(
        fixture_subscribe(&module, "webdav", "password").0,
        ABI_ERR_CONFIG_FORBIDDEN,
        "explicit foreign Secret key subscription must be forbidden"
    );

    // Trusted Dart keeps the explicit raw read; the default read is masked.
    assert_eq!(
        config
            .get("webdav".into(), "password".into(), false)
            .unwrap(),
        "\"s3cr3t\""
    );
    assert_eq!(
        config
            .get("webdav".into(), "password".into(), true)
            .unwrap(),
        "\"***\""
    );

    drop(module);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 6. Foreign key=None is not a blanket grant (Todo 13 #7)
// ---------------------------------------------------------------------------

#[test]
fn foreign_whole_module_subscription_never_receives_owner_keys() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("foreign-whole");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let module = mount("foreign-whole", "download");
    assert_eq!(
        fixture_subscribe(&module, "theme", "").0,
        0,
        "foreign whole-module subscription is accepted at registration"
    );
    clear_records(&module);

    config
        .set("theme".into(), "mode".into(), "2".into(), "user".into())
        .unwrap();
    config
        .set(
            "theme".into(),
            "config".into(),
            r#"{"dark":true}"#.into(),
            "user".into(),
        )
        .unwrap();

    assert_eq!(
        keys(&deliveries(&module)),
        vec!["theme.mode"],
        "key=None delivers the PublicRead entry but never the later Owner key"
    );

    drop(module);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 7. Cross-module write is rejected (Todo 13 #8)
// ---------------------------------------------------------------------------

#[test]
fn cross_module_write_is_rejected_and_foreign_value_is_unchanged() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("foreign-write");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    config
        .set(
            "webdav".into(),
            "password".into(),
            serde_json::json!("original").to_string(),
            "user".into(),
        )
        .unwrap();
    let module = mount("foreign-write", "download");

    // `set` has no module parameter: the module identity is authoritative, so a
    // foreign wire key resolves to an unregistered own-module key.
    assert_eq!(
        fixture_set(&module, "webdav.password", "\"hacked\""),
        ABI_ERR_CONFIG_NOT_FOUND,
        "a module cannot write into another module's namespace"
    );
    assert_eq!(
        fixture_set(&module, "theme.config", "{}"),
        ABI_ERR_CONFIG_NOT_FOUND
    );
    assert_eq!(
        config
            .get("webdav".into(), "password".into(), false)
            .unwrap(),
        "\"original\"",
        "the rejected cross-module write must not mutate the foreign value"
    );

    drop(module);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 8. Unsubscribe validates token ownership (Todo 13 #9)
// ---------------------------------------------------------------------------

#[test]
fn unsubscribe_requires_ownership_of_the_token() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("token-owner");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let download = mount("token-owner", "download");
    let theme = mount("token-owner", "theme");
    let (code, download_token) = fixture_subscribe(&download, "", "");
    assert_eq!(code, 0);
    let (code, theme_token) = fixture_subscribe(&theme, "", "");
    assert_eq!(code, 0);
    assert_ne!(download_token, theme_token);

    assert_eq!(
        fixture_unsubscribe(&download, theme_token),
        ABI_ERR_CONFIG_BAD_TOKEN,
        "another module's token cannot be unsubscribed"
    );
    assert_eq!(
        fixture_unsubscribe(&theme, theme_token),
        0,
        "the owner can unsubscribe"
    );
    assert_eq!(fixture_unsubscribe(&download, download_token), 0);
    assert_eq!(
        fixture_unsubscribe(&download, download_token),
        ABI_ERR_CONFIG_BAD_TOKEN,
        "a consumed token is no longer valid"
    );

    clear_records(&download);
    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "4".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        deliveries(&download),
        Vec::<Value>::new(),
        "unsubscribed module receives nothing"
    );

    drop(download);
    drop(theme);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 9. Unload during delivery does not use freed code (Todo 13 #10)
// ---------------------------------------------------------------------------

#[test]
fn unload_during_delivery_orders_shutdown_after_the_callback() {
    let _guard = serial();
    let scratch = scratch("unload");
    let record = scratch.join("deliveries.log");
    set_record_file(&record);
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let module = mount("unload", "download");
    assert_eq!(fixture_subscribe(&module, "", "").0, 0);
    assert_eq!(call(&module, "slow_on", Vec::new()), "slow");

    let setter = std::thread::spawn(|| {
        let config = ConfigApi::init().expect("ConfigApi::init in setter");
        config
            .set(
                "download".into(),
                "max_concurrent".into(),
                "4".into(),
                "user".into(),
            )
            .unwrap();
    });
    assert!(
        wait_for_prefix(&record, "enter "),
        "callback must enter before unload"
    );
    drop(module);
    setter.join().expect("slow setter joined");

    let lines = record_lines(&record);
    let enter = lines
        .iter()
        .position(|line| line.starts_with("enter "))
        .expect("enter");
    let shutdown = lines
        .iter()
        .position(|line| line == "shutdown")
        .expect("shutdown");
    assert!(
        enter < shutdown,
        "shutdown must run after the in-flight callback: {lines:?}"
    );
    let delivered = count_prefixed(&record, "deliver ");

    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "3".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        count_prefixed(&record, "deliver "),
        delivered,
        "no callback may run after unload"
    );

    clear_record_file();
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 10. Secret masking in lists and delivery payloads (Todo 13 #11)
// ---------------------------------------------------------------------------

#[test]
fn secret_values_are_masked_in_lists_and_delivery_payloads() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("secret-mask");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let agent = mount("secret-mask", "agent");
    let webdav_owner = mount("secret-mask", "webdav");
    assert_eq!(fixture_subscribe(&agent, "", "").0, 0);
    assert_eq!(fixture_subscribe(&webdav_owner, "", "").0, 0);
    clear_records(&agent);
    clear_records(&webdav_owner);

    config
        .set(
            "webdav".into(),
            "password".into(),
            serde_json::json!("hunter2").to_string(),
            "user".into(),
        )
        .unwrap();
    config
        .set(
            "agent".into(),
            "models".into(),
            r#"[{"apiKey":"sk-secret"}]"#.into(),
            "user".into(),
        )
        .unwrap();

    assert_eq!(
        config
            .get("webdav".into(), "password".into(), true)
            .unwrap(),
        "\"***\""
    );
    assert_eq!(
        config
            .get("webdav".into(), "password".into(), false)
            .unwrap(),
        "\"hunter2\""
    );

    let password_payload = deliveries(&webdav_owner);
    assert_eq!(keys(&password_payload), vec!["webdav.password"]);
    assert_eq!(
        values(&password_payload),
        vec![Value::from("***")],
        "webdav.password owner callback payload is masked"
    );
    assert!(!call(&webdav_owner, "dump", Vec::new()).contains("hunter2"));

    let webdav = config.list(Some("webdav".into())).unwrap();
    let password = webdav
        .iter()
        .find(|entry| entry.key == "password")
        .expect("password entry");
    assert_eq!(password.value_json, "\"***\"");
    assert!(password.masked);

    let all = config.list(None).unwrap();
    let mut mirrored = String::new();
    for entry in &all {
        mirrored.push_str(&entry.value_json);
        mirrored.push_str(&entry.default_json);
    }
    assert!(
        !mirrored.contains("hunter2"),
        "ConfigApi.list must never expose the raw secret"
    );
    assert!(
        !mirrored.contains("sk-secret"),
        "ConfigApi.list must never expose agent API keys"
    );

    let changes = deliveries(&agent);
    assert_eq!(keys(&changes), vec!["agent.models"]);
    assert_eq!(
        values(&changes),
        vec![Value::from("***")],
        "module callback payload is masked"
    );
    let raw = call(&agent, "dump", Vec::new());
    assert!(
        !raw.contains("sk-secret"),
        "delivered payload must not contain the raw secret"
    );

    drop(agent);
    drop(webdav_owner);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 11. Two CoreApi::init calls never share a stale store (Todo 13 #12)
// ---------------------------------------------------------------------------

#[test]
fn two_core_inits_do_not_share_a_stale_config_store() {
    let _guard = serial();
    clear_record_file();
    let scratch_a = scratch("reinit-a");
    let scratch_b = scratch("reinit-b");
    let core_a = init_core(&scratch_a);
    assert!(core_a.shares_config_store_with_global_for_test());
    let config_a = ConfigApi::init().expect("ConfigApi::init A");
    config_a
        .set(
            "download".into(),
            "max_concurrent".into(),
            "9".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        config_a
            .get("download".into(), "max_concurrent".into(), false)
            .unwrap(),
        "9"
    );
    drop(core_a);

    let core_b = init_core(&scratch_b);
    assert!(core_b.shares_config_store_with_global_for_test());
    let config_b = ConfigApi::init().expect("ConfigApi::init B");
    assert_eq!(
        config_b
            .get("download".into(), "max_concurrent".into(), false)
            .unwrap(),
        "3",
        "a new CoreApi must load its own store, not the previous one's value"
    );
    config_b
        .set(
            "download".into(),
            "max_concurrent".into(),
            "4".into(),
            "user".into(),
        )
        .unwrap();
    drop(core_b);

    let core_c = init_core(&scratch_a);
    assert!(core_c.shares_config_store_with_global_for_test());
    let config_c = ConfigApi::init().expect("ConfigApi::init C");
    assert_eq!(
        config_c
            .get("download".into(), "max_concurrent".into(), false)
            .unwrap(),
        "9",
        "scratch A's DB keeps its own value; B's write must not leak into it"
    );

    drop(core_c);
    let _ = std::fs::remove_dir_all(&scratch_a);
    let _ = std::fs::remove_dir_all(&scratch_b);
}

// ---------------------------------------------------------------------------
// 12. clear delivers value:null (reset delivers the default) (Todo 13 ALSO)
// ---------------------------------------------------------------------------

#[test]
fn clear_delivers_null_and_reset_delivers_the_default() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("clear-null");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let module = mount("clear-null", "download");
    assert_eq!(fixture_subscribe(&module, "", "").0, 0);

    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "6".into(),
            "user".into(),
        )
        .unwrap();
    clear_records(&module);
    config
        .clear("download".into(), "max_concurrent".into(), "user".into())
        .unwrap();
    let cleared = deliveries(&module);
    assert_eq!(keys(&cleared), vec!["download.max_concurrent"]);
    assert_eq!(
        values(&cleared),
        vec![Value::Null],
        "clear delivers value:null"
    );
    assert_eq!(cleared[0]["oldValue"], Value::from(6));
    assert_eq!(
        config
            .get("download".into(), "max_concurrent".into(), false)
            .unwrap(),
        "3"
    );

    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "8".into(),
            "user".into(),
        )
        .unwrap();
    clear_records(&module);
    config
        .reset("download".into(), "max_concurrent".into(), "user".into())
        .unwrap();
    let reset = deliveries(&module);
    assert_eq!(keys(&reset), vec!["download.max_concurrent"]);
    assert_eq!(
        values(&reset),
        vec![Value::from(3)],
        "reset is a normal write of the registry default, not a null delivery"
    );

    // The wire payload above is only half the contract. Mount the real
    // download module and assert the LIVE scheduler applies clear/reset:
    // `ConfigChangePayload` serializes an absent value as explicit
    // `"value":null`, so the module callback must treat JSON null as unset.
    drop(module);
    let real = ModuleHandle::mount_from_so(build_download_module().to_string_lossy().into_owned())
        .expect("mount real download module");
    let data_dir = scratch.join("download-data");
    std::fs::create_dir_all(&data_dir).expect("download data dir");
    let instance_config = serde_json::to_vec(&serde_json::json!({
        "data_dir": data_dir.to_string_lossy(),
        "abi": "5",
    }))
    .expect("instance config JSON");
    let instance = real
        .create_instance(instance_config)
        .expect("create real download instance");

    let fresh = download_stats(&instance);
    assert_eq!(
        fresh["maxConcurrent"],
        Value::from(3),
        "live scheduler starts from the registry default"
    );
    assert_eq!(
        fresh["maxRetries"],
        Value::from(3),
        "fresh instance starts at the registry default 3, not engine default 4"
    );
    assert_eq!(fresh["defaultConnections"], Value::from(4));
    assert_eq!(fresh["multiSegmentEnabled"], Value::from(true));
    assert_eq!(
        fresh["speedLimitBps"],
        Value::Null,
        "registry 0 = unlimited"
    );
    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "6".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        download_stats(&instance)["maxConcurrent"],
        Value::from(6),
        "live scheduler applies an ordinary write"
    );
    config
        .clear("download".into(), "max_concurrent".into(), "user".into())
        .unwrap();
    assert_eq!(
        download_stats(&instance)["maxConcurrent"],
        Value::from(3),
        "clear must restore the registry default in the live scheduler, not keep 6"
    );

    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "8".into(),
            "user".into(),
        )
        .unwrap();
    config
        .reset("download".into(), "max_concurrent".into(), "user".into())
        .unwrap();
    assert_eq!(
        download_stats(&instance)["maxConcurrent"],
        Value::from(3),
        "reset restores the registry default in the live scheduler"
    );

    config
        .set(
            "download".into(),
            "multi_segment.enabled".into(),
            "false".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        download_stats(&instance)["multiSegmentEnabled"],
        Value::from(false)
    );
    config
        .clear(
            "download".into(),
            "multi_segment.enabled".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        download_stats(&instance)["multiSegmentEnabled"],
        Value::from(true),
        "clearing a key with a default also restores that default"
    );

    config
        .set(
            "download".into(),
            "max_retries".into(),
            "1".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(download_stats(&instance)["maxRetries"], Value::from(1));
    config
        .clear("download".into(), "max_retries".into(), "user".into())
        .unwrap();
    assert_eq!(
        download_stats(&instance)["maxRetries"],
        Value::from(3),
        "clear must restore the registry default 3, not the engine default 4"
    );

    config
        .set(
            "download".into(),
            "default_connections".into(),
            "7".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        download_stats(&instance)["defaultConnections"],
        Value::from(7)
    );
    config
        .clear(
            "download".into(),
            "default_connections".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        download_stats(&instance)["defaultConnections"],
        Value::from(4)
    );

    config
        .set(
            "download".into(),
            "speed_limit_bps".into(),
            "2048".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        download_stats(&instance)["speedLimitBps"],
        Value::from(2048)
    );
    config
        .clear("download".into(), "speed_limit_bps".into(), "user".into())
        .unwrap();
    assert_eq!(
        download_stats(&instance)["speedLimitBps"],
        Value::Null,
        "registry default 0 means unlimited (engine None)"
    );
    assert_eq!(
        config
            .get("download".into(), "speed_limit_bps".into(), false)
            .unwrap(),
        "0",
        "the authoritative store exposes the registry default 0"
    );

    drop(instance);
    drop(real);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 13. reset_bridges clears native config sinks (Todo 13 #15)
// ---------------------------------------------------------------------------

#[test]
fn reset_bridges_clears_module_config_sinks() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("reset-bridges");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let module = mount("reset-bridges", "download");
    assert_eq!(fixture_subscribe(&module, "", "").0, 0);
    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "5".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(deliveries(&module).len(), 1);

    HostInspector::new().reset_bridges();
    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "6".into(),
            "user".into(),
        )
        .unwrap();
    assert_eq!(
        deliveries(&module).len(),
        1,
        "reset_bridges must clear every native config sink"
    );

    assert_eq!(
        fixture_subscribe(&module, "", "").0,
        0,
        "a module can resubscribe"
    );
    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "7".into(),
            "user".into(),
        )
        .unwrap();
    let after = deliveries(&module);
    assert_eq!(after.len(), 2);
    assert_eq!(
        keys(&after),
        vec!["download.max_concurrent", "download.max_concurrent"],
        "only the post-resubscribe change is delivered"
    );

    drop(module);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 14. v4 module loads with the v4 entry size and no config slot (Todo 13 #14)
// ---------------------------------------------------------------------------

#[test]
fn v4_module_loads_with_v4_entry_size_and_no_config_slot() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("v4-load");
    let _core = init_core(&scratch);
    let path = build_fixture("v4-load", "vprobe4", 4, 4, false);
    let module = ModuleHandle::mount_from_so(path.to_string_lossy().into_owned())
        .expect("a v4 module must load on the v5 host");
    assert!(
        HostInspector::new()
            .loaded_modules()
            .iter()
            .any(|info| info.name == "vprobe4"),
        "v4 module is registered"
    );

    let (abi, entry_size, has_config) = fixture_entry_probe(&module);
    assert_eq!(abi, 4);
    assert_eq!(
        entry_size as usize,
        GStoreModuleEntry::CONFIG_OFFSET,
        "host_entry(4) must report the v4 layout size only"
    );
    assert_ne!(
        entry_size as usize,
        std::mem::size_of::<GStoreModuleEntry>(),
        "a v4 module must never see the v5 full entry size"
    );
    assert!(!has_config, "has_config() must be false for a v4 entry");
    assert_eq!(
        fixture_get(&module, "", "max_concurrent").0,
        ABI_ERR_CONFIG_INVALID,
        "a module mounted with a v4 entry has no config vtable"
    );

    drop(module);
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// 15. A v5-only module is rejected by a v4 host (Todo 13 #14)
// ---------------------------------------------------------------------------

type RegisterFn = extern "C" fn(*const GStoreModuleEntry, *mut GStoreModuleApi) -> i32;

#[test]
fn v5_only_module_is_rejected_when_the_host_is_v4() {
    let _guard = serial();
    clear_record_file();
    let path = build_fixture("v5-reject", "vprobe5", 5, 5, false);
    let library = unsafe {
        libloading::os::unix::Library::open(
            Some(&path),
            libloading::os::unix::RTLD_NOW | libloading::os::unix::RTLD_LOCAL,
        )
    }
    .expect("dlopen v5 fixture");
    let register: libloading::os::unix::Symbol<RegisterFn> =
        unsafe { library.get(b"gstore_mod_vprobe5_register\0") }.expect("register symbol");

    // The v4 host shape the production loader builds for ABI 4.
    let v4_entry = GStoreModuleEntry {
        abi_version: 4,
        entry_size: GStoreModuleEntry::CONFIG_OFFSET as u32,
        log: None,
        alloc: None,
        free: None,
        emit_event: None,
        context: std::ptr::null_mut(),
        protect_fd: None,
        platform: std::ptr::null(),
        config: std::ptr::null(),
    };
    let mut api = std::mem::MaybeUninit::<GStoreModuleApi>::zeroed();
    let code = register(&v4_entry, api.as_mut_ptr());
    assert_eq!(
        code, ABI_ERR_ABI_MISMATCH,
        "the v5-only module itself rejects the v4 entry with a typed code"
    );

    // The host-side gate is the same `host_abi_satisfies` check used by
    // `handshake_with_config`: min_host_abi=5 cannot be satisfied by host ABI 4.
    let vtable = GStoreConfigApiV1 {
        abi_version: GSTORE_MODULE_ABI_VERSION,
        struct_size: std::mem::size_of::<GStoreConfigApiV1>() as u32,
        capabilities: CONFIG_CAP_ALL,
        context: std::ptr::null_mut(),
        get: None,
        set: None,
        list: None,
        subscribe: None,
        unsubscribe: None,
        free_buf: None,
    };
    let v5_entry = GStoreModuleEntry {
        abi_version: GSTORE_MODULE_ABI_VERSION,
        entry_size: std::mem::size_of::<GStoreModuleEntry>() as u32,
        log: None,
        alloc: None,
        free: None,
        emit_event: None,
        context: std::ptr::null_mut(),
        protect_fd: None,
        platform: std::ptr::null(),
        config: &vtable,
    };
    let mut api = std::mem::MaybeUninit::<GStoreModuleApi>::zeroed();
    let code = register(&v5_entry, api.as_mut_ptr());
    assert_eq!(code, 0, "the same module accepts a full v5 entry");
    let api = unsafe { api.assume_init() };
    assert_eq!(api.min_host_abi, 5);
    assert!(
        !host_abi_satisfies(api.min_host_abi, 4),
        "a v4 host must reject this module at probe/handshake time"
    );
    assert!(host_abi_satisfies(
        api.min_host_abi,
        GSTORE_MODULE_ABI_VERSION
    ));
}

// ---------------------------------------------------------------------------
// 16. Config writes never take the legacy broadcast downlink (Todo 36 / C4)
// ---------------------------------------------------------------------------

#[test]
fn config_writes_never_reach_any_module_on_event_broadcast_path() {
    let _guard = serial();
    let scratch = scratch("no-broadcast");
    let record = scratch.join("on_event.log");
    set_record_file(&record);
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let probe = ModuleHandle::mount_from_so(
        build_fixture_with_on_event("no-broadcast", "probe", 5, 5, false)
            .to_string_lossy()
            .into_owned(),
    )
    .expect("mount on_event probe");
    let download = mount("no-broadcast", "download");
    assert_eq!(fixture_subscribe(&download, "", "").0, 0);
    clear_records(&download);
    let on_event_before = count_prefixed(&record, "on_event ");

    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "5".into(),
            "user".into(),
        )
        .unwrap();

    assert_eq!(
        keys(&deliveries(&download)),
        vec!["download.max_concurrent"],
        "the ABI-filtered subscription still receives its own config change"
    );
    assert_eq!(
        count_prefixed(&record, "on_event "),
        on_event_before,
        "a config write must never reach any module's on_event broadcast path"
    );
    assert_eq!(
        count_prefixed(&record, "on_event config.changed"),
        0,
        "zero legacy config.changed broadcast deliveries"
    );

    let config_write_on_event_delta = count_prefixed(&record, "on_event ") - on_event_before;
    let config_changed_on_event_delta = count_prefixed(&record, "on_event config.changed");
    assert_eq!(config_write_on_event_delta, 0);
    assert_eq!(config_changed_on_event_delta, 0);
    println!(
        "TRACE filtered config delivery (module.key): {:?}",
        keys(&deliveries(&download))
    );
    println!(
        "TRACE on_event deliveries from a config write: {config_write_on_event_delta} (config.changed: {config_changed_on_event_delta})"
    );

    EventBridge::new().broadcast("demo.changed".to_string(), br#"{"ok":true}"#.to_vec());
    assert_eq!(
        count_prefixed(&record, "on_event demo.changed"),
        1,
        "non-config broadcasts still reach on_event"
    );
    println!(
        "TRACE non-config broadcast demo.changed deliveries: {}",
        count_prefixed(&record, "on_event demo.changed")
    );

    drop(download);
    drop(probe);
    clear_record_file();
    let _ = std::fs::remove_dir_all(&scratch);
}

// ---------------------------------------------------------------------------
// Manual-QA trace (run with --nocapture): sequences, typed codes, probe sizes
// ---------------------------------------------------------------------------

#[test]
fn manual_qa_trace() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("trace");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let download = mount("trace", "download");
    let v4 = ModuleHandle::mount_from_so(
        build_fixture("trace", "trace4", 4, 4, false)
            .to_string_lossy()
            .into_owned(),
    )
    .expect("mount v4 probe");

    let v5_probe = fixture_entry_probe(&download);
    let v4_probe = fixture_entry_probe(&v4);
    println!(
        "TRACE v5 probe: abi={} entry_size={} has_config={}",
        v5_probe.0, v5_probe.1, v5_probe.2
    );
    println!(
        "TRACE v4 probe: abi={} entry_size={} has_config={}",
        v4_probe.0, v4_probe.1, v4_probe.2
    );
    println!(
        "TRACE constants: v4_size={} v5_size={}",
        GStoreModuleEntry::CONFIG_OFFSET,
        std::mem::size_of::<GStoreModuleEntry>()
    );

    assert_eq!(fixture_subscribe(&download, "", "").0, 0);
    assert_eq!(fixture_subscribe(&download, "network", "proxy_url").0, 0);
    clear_records(&download);
    config
        .set(
            "download".into(),
            "max_concurrent".into(),
            "4".into(),
            "user".into(),
        )
        .unwrap();
    config
        .set(
            "download".into(),
            "max_retries".into(),
            "1".into(),
            "user".into(),
        )
        .unwrap();
    config
        .set(
            "network".into(),
            "proxy_url".into(),
            serde_json::json!("https://trace.test/").to_string(),
            "user".into(),
        )
        .unwrap();
    for change in deliveries(&download) {
        println!(
            "TRACE delivered: module={} key={} value={}",
            change["module"], change["key"], change["value"]
        );
    }

    config
        .set(
            "theme".into(),
            "config".into(),
            r#"{"dark":true}"#.into(),
            "user".into(),
        )
        .unwrap();
    config
        .set(
            "webdav".into(),
            "password".into(),
            serde_json::json!("pw").to_string(),
            "user".into(),
        )
        .unwrap();
    let denied = [
        (
            "get foreign Owner",
            fixture_get(&download, "theme", "config").0,
        ),
        (
            "get foreign Secret",
            fixture_get(&download, "webdav", "password").0,
        ),
        (
            "subscribe foreign Owner",
            fixture_subscribe(&download, "theme", "config").0,
        ),
        (
            "subscribe foreign Secret",
            fixture_subscribe(&download, "webdav", "password").0,
        ),
        (
            "set foreign key",
            fixture_set(&download, "webdav.password", "\"x\""),
        ),
        ("get unregistered", fixture_get(&download, "", "nope").0),
        ("set unregistered", fixture_set(&download, "nope", "1")),
        (
            "set malformed",
            fixture_set(&download, "max_concurrent", "{bad"),
        ),
        (
            "unsubscribe bad token",
            fixture_unsubscribe(&download, 9_999_999),
        ),
    ];
    for (label, code) in denied {
        println!("TRACE denied: {label} -> code={code}");
    }

    drop(download);
    drop(v4);
    let _ = std::fs::remove_dir_all(&scratch);
}
