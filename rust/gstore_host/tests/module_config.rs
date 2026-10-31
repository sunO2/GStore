//! Todo 11 real-surface tests: an ABI v5 `.so` module consumes the injected
//! config vtable through `mount_from_so`, and Dart-side commits reach only the
//! authorized matching subscriptions.
//!
//! The fixture is compiled from `tests/fixtures/config_module.c` at test time
//! (no committed binary, no network/device). Its module name and minimum host
//! ABI are compile-time parameters, which lets the same source exercise a
//! duplicate mount and a subscribe-then-failed handshake.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use gstore_host::bridge::{ConfigApi, CoreApi, HostInspector, ModuleHandle};
use serde_json::Value;

static SERIAL: Mutex<()> = Mutex::new(());

fn serial() -> MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn scratch(tag: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "gstore_module_config_so_{tag}_{}_{}",
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

fn build_fixture(name: &str, min_host_abi: u32) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/module_config_fixtures");
    std::fs::create_dir_all(&dir).expect("create fixture dir");
    let output = dir.join(format!("libgstore_mod_{name}.so"));
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/config_module.c");
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let status = std::process::Command::new(cc)
        .args(["-shared", "-fPIC", "-std=c99", "-Wall", "-Wextra", "-Werror"])
        .arg(format!("-DFIXTURE_NAME={name}"))
        .arg(format!("-DFIXTURE_MIN_HOST_ABI={min_host_abi}"))
        .arg("-o")
        .arg(&output)
        .arg(&source)
        .status()
        .expect("spawn C compiler for config fixture");
    assert!(status.success(), "C fixture compile failed: {status}");
    output
}

fn copy_fixture(source: &Path, dir: &Path) -> PathBuf {
    std::fs::create_dir_all(dir).expect("create fixture copy dir");
    let destination = dir.join(source.file_name().expect("fixture filename"));
    std::fs::copy(source, &destination).expect("copy fixture");
    destination
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
    wait_for_prefix_count(path, prefix, 1)
}

fn wait_for_prefix_count(path: &Path, prefix: &str, expected: usize) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if count_prefixed(path, prefix) >= expected {
            return true;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    false
}

fn deliveries(module: &ModuleHandle) -> Vec<Value> {
    let raw = module
        .call_static("dump".to_string(), Vec::new())
        .expect("dump delivered changes");
    String::from_utf8(raw)
        .expect("dump is UTF-8")
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_str::<Value>(line).expect("recorded change is JSON"))
        .collect()
}

fn keys(changes: &[Value]) -> Vec<String> {
    changes
        .iter()
        .filter_map(|change| {
            let module = change.get("module")?.as_str()?;
            let key = change.get("key")?.as_str()?;
            Some(format!("{module}.{key}"))
        })
        .collect()
}

#[test]
fn module_config_real_v5_module_so_delivers_filtered_changes() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("real");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let module = ModuleHandle::mount_from_so(build_fixture("download", 5).to_string_lossy().into_owned())
        .expect("mount ABI v5 fixture");

    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            "5".to_string(),
            "user".to_string(),
        )
        .expect("own-module write");
    config
        .set(
            "theme".to_string(),
            "config".to_string(),
            r#"{"dark":true}"#.to_string(),
            "user".to_string(),
        )
        .expect("foreign Owner write");
    config
        .set(
            "theme".to_string(),
            "mode".to_string(),
            "2".to_string(),
            "user".to_string(),
        )
        .expect("PublicRead write");

    let before = deliveries(&module);
    let observed = keys(&before);
    assert!(observed.contains(&"download.max_concurrent".to_string()));
    assert!(
        observed.contains(&"theme.mode".to_string()),
        "PublicRead cross-module change must be delivered: {observed:?}"
    );
    assert!(
        !observed.contains(&"theme.config".to_string()),
        "foreign Owner change must not be delivered: {observed:?}"
    );

    let invalid = module
        .call_static("set_invalid".to_string(), Vec::new())
        .expect("malformed set call");
    assert_eq!(
        String::from_utf8(invalid).unwrap(),
        "-11",
        "malformed JSON must return ABI_ERR_CONFIG_INVALID"
    );

    let double = module
        .call_static("unsubscribe_own_twice".to_string(), Vec::new())
        .expect("double unsubscribe call");
    assert_eq!(
        String::from_utf8(double).unwrap(),
        "0,-12",
        "the second unsubscribe of the same token must be rejected"
    );

    HostInspector::new().reset_bridges();
    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            "6".to_string(),
            "user".to_string(),
        )
        .expect("write after reset");
    let after = deliveries(&module);
    assert_eq!(
        after.len(),
        before.len(),
        "reset_bridges must clear every native config sink (zero deliveries after)"
    );

    drop(module);
    let _ = std::fs::remove_dir_all(&scratch);
}

#[test]
fn module_config_duplicate_mount_reuses_module_and_delivers_exactly_once() {
    let _guard = serial();
    clear_record_file();
    let scratch = scratch("duplicate");
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let built = build_fixture("download", 5);
    let first_path = copy_fixture(&built, &scratch.join("a"));
    let second_path = copy_fixture(&built, &scratch.join("b"));

    let first = ModuleHandle::mount_from_so(first_path.to_string_lossy().into_owned())
        .expect("first mount");
    let second = ModuleHandle::mount_from_so(second_path.to_string_lossy().into_owned())
        .expect("duplicate mount must reuse the id without dlopen/register");
    let loaded = HostInspector::new()
        .loaded_modules()
        .into_iter()
        .filter(|module| module.name == "download")
        .count();
    assert_eq!(loaded, 1, "duplicate mount must not add a second module entry");

    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            "5".to_string(),
            "user".to_string(),
        )
        .expect("config set after duplicate mount");

    let observed = keys(&deliveries(&first));
    assert_eq!(
        observed,
        vec!["download.max_concurrent".to_string()],
        "the surviving module must receive exactly one delivery: {observed:?}"
    );

    drop(second);
    drop(first);
    let _ = std::fs::remove_dir_all(&scratch);
}

#[test]
fn module_config_subscribe_then_failed_handshake_leaves_no_sink() {
    let _guard = serial();
    let scratch = scratch("fail-handshake");
    let record = scratch.join("deliveries.log");
    set_record_file(&record);
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");

    let error = match ModuleHandle::mount_from_so(
        build_fixture("faildemo", 6).to_string_lossy().into_owned(),
    ) {
        Ok(_) => panic!("min_host_abi=6 must be rejected after register"),
        Err(error) => error,
    };
    assert!(
        error.contains("requires host ABI") || error.contains("ABI"),
        "expected the ABI gate error, got: {error}"
    );
    assert!(
        HostInspector::new()
            .loaded_modules()
            .iter()
            .all(|module| module.name != "faildemo"),
        "failed module must not stay registered"
    );

    config
        .set(
            "theme".to_string(),
            "mode".to_string(),
            "2".to_string(),
            "user".to_string(),
        )
        .expect("config set after failed mount");
    assert_eq!(
        count_prefixed(&record, "enter "),
        0,
        "a subscribe-then-fail module must receive zero deliveries"
    );

    clear_record_file();
    let _ = std::fs::remove_dir_all(&scratch);
}

#[test]
fn module_config_real_so_unload_during_delivery_orders_shutdown_after_callback() {
    let _guard = serial();
    let scratch = scratch("unload-order");
    let record = scratch.join("deliveries.log");
    set_record_file(&record);
    let _core = init_core(&scratch);
    let config = ConfigApi::init().expect("ConfigApi::init");
    let module = ModuleHandle::mount_from_so(
        build_fixture("download", 5).to_string_lossy().into_owned(),
    )
    .expect("mount ABI v5 fixture");
    module
        .call_static("slow_on".to_string(), Vec::new())
        .expect("enable slow callback");

    let setter = std::thread::spawn(|| {
        let config = ConfigApi::init().expect("ConfigApi::init in setter");
        config
            .set(
                "download".to_string(),
                "max_concurrent".to_string(),
                "4".to_string(),
                "user".to_string(),
            )
            .expect("slow set");
    });
    assert!(
        wait_for_prefix(&record, "enter "),
        "callback must enter before the unload"
    );
    drop(module);
    setter.join().expect("slow setter joined");

    let lines = record_lines(&record);
    let enter = lines
        .iter()
        .position(|line| line.starts_with("enter "))
        .expect("enter marker");
    let shutdown = lines
        .iter()
        .position(|line| line == "shutdown")
        .expect("shutdown marker");
    assert!(
        enter < shutdown,
        "module shutdown must run after the callback returns: {lines:?}"
    );
    let delivered = count_prefixed(&record, "deliver ");

    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            "3".to_string(),
            "user".to_string(),
        )
        .expect("post-unload write");
    assert_eq!(
        count_prefixed(&record, "deliver "),
        delivered,
        "no callback may run after unload"
    );

    clear_record_file();
    let _ = std::fs::remove_dir_all(&scratch);
}

#[test]
fn module_config_reinit_clears_stale_bus_subscriptions() {
    let _guard = serial();
    let scratch_one = scratch("reinit-one");
    let scratch_two = scratch("reinit-two");
    let record = scratch_one.join("deliveries.log");
    set_record_file(&record);

    let core_one = init_core(&scratch_one);
    let config_one = ConfigApi::init().expect("ConfigApi::init #1");
    let module = ModuleHandle::mount_from_so(
        build_fixture("download", 5).to_string_lossy().into_owned(),
    )
    .expect("mount ABI v5 fixture");
    config_one
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            "5".to_string(),
            "user".to_string(),
        )
        .expect("write on core #1");
    assert_eq!(count_prefixed(&record, "deliver "), 1);

    drop(core_one);
    let _core_two = init_core(&scratch_two);
    let config_two = ConfigApi::init().expect("ConfigApi::init #2");
    let stale_baseline = count_prefixed(&record, "deliver ");
    config_two
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            "3".to_string(),
            "user".to_string(),
        )
        .expect("write on core #2");
    assert_eq!(
        count_prefixed(&record, "deliver "),
        stale_baseline,
        "a module bound to the old bus must not receive new-store changes"
    );

    // Modules must resubscribe after a core re-init: the old subscriptions were
    // detached, but the vtable/binding itself is still usable.
    module
        .call_static("resubscribe".to_string(), Vec::new())
        .expect("resubscribe after re-init");
    config_two
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            "2".to_string(),
            "user".to_string(),
        )
        .expect("write after resubscribe");
    assert_eq!(
        count_prefixed(&record, "deliver "),
        stale_baseline + 1,
        "an explicit resubscribe must attach the module to the new bus"
    );

    drop(module);
    clear_record_file();
    let _ = std::fs::remove_dir_all(&scratch_one);
    let _ = std::fs::remove_dir_all(&scratch_two);
}


