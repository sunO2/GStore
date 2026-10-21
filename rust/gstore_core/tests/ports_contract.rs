//! Todo 6 contract: PlatformHost and the Wave 0/1 ports.
//!
//! Every test name is prefixed with `ports_contract` so the plan's QA command
//! (`cargo test --manifest-path rust/gstore_core/Cargo.toml ports_contract`)
//! selects this integration test binary. The tests are deterministic: no
//! sleeps, no network, and the metadata TTL is proven with an injected clock.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use gstore_core::ports::{
    CachedMetadataPort, Capability, CapabilitySet, CoreConfig, FakeHttpPort, FakeMetadataPort,
    FakePlatformHost, FakeRepoPort, FileSecretPort, FileSecretStore, HttpOptions, HttpPort,
    InMemorySecretPort, InstalledApp, Notification, PackageMetadata, PlatformHost, RepoApp,
    RepoMeta, RepoPort,
};
use gstore_core::Error;

fn app(package_name: &str) -> InstalledApp {
    InstalledApp {
        package_name: package_name.to_string(),
        app_name: format!("App {package_name}"),
        version_name: "1.0.0".to_string(),
        version_code: 1,
        icon: None,
        system: false,
    }
}

fn notification() -> Notification {
    Notification {
        channel_id: "gstore.default".to_string(),
        title: "GStore".to_string(),
        body: "hello".to_string(),
    }
}

fn meta(package_name: &str, app_name: &str, icon: &str) -> PackageMetadata {
    PackageMetadata {
        package_name: Some(package_name.to_string()),
        app_name: Some(app_name.to_string()),
        icon_url: Some(icon.to_string()),
    }
}

fn repo_meta(source: &str) -> RepoMeta {
    RepoMeta {
        source: source.to_string(),
        name: "F-Droid".to_string(),
        description: Some("free software".to_string()),
        version: Some("2000000".to_string()),
        timestamp: Some(1_700_000_000),
        app_count: 2,
    }
}

fn repo_app(package_name: &str, name: &str) -> RepoApp {
    RepoApp {
        package_name: package_name.to_string(),
        name: name.to_string(),
        summary: format!("{name} summary"),
        version: Some("1.2.3".to_string()),
        version_code: Some(1_020_300),
        icon: Some(format!("{package_name}.png")),
        apk_url: Some(format!("https://example.test/{package_name}.apk")),
        size: Some(42),
        categories: vec!["tools".to_string()],
    }
}

fn temp_dir(tag: &str) -> PathBuf {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let dir = std::env::temp_dir().join(format!(
        "gstore_core_ports_{}_{}_{}",
        std::process::id(),
        tag,
        n
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

#[test]
fn ports_contract_capability_gating_fails_closed_before_work() {
    let host = FakePlatformHost::new(CapabilitySet::empty())
        .with_installed(vec![app("com.example.one")])
        .with_online(true);

    // Every capability-marked operation must fail closed with `Unsupported`
    // BEFORE the underlying hook runs. The fake's call counter is the witness
    // (stronger than merely observing an error).
    let errors: Vec<(&str, Error)> = vec![
        ("list_installed", host.list_installed().unwrap_err()),
        (
            "get_installed",
            host.get_installed("com.example.one").unwrap_err(),
        ),
        (
            "install",
            host.install(Path::new("/tmp/demo.apk")).unwrap_err(),
        ),
        ("uninstall", host.uninstall("com.example.one").unwrap_err()),
        ("launch", host.launch("com.example.one").unwrap_err()),
        ("notify", host.notify(&notification()).unwrap_err()),
        (
            "start_foreground",
            host.start_foreground(&notification()).unwrap_err(),
        ),
        ("stop_foreground", host.stop_foreground().unwrap_err()),
        ("storage_paths", host.storage_paths().unwrap_err()),
        ("connectivity", host.connectivity().unwrap_err()),
        ("is_online", host.is_online().unwrap_err()),
        ("device_info", host.device_info().unwrap_err()),
        ("secret_get", host.secret_get("token").unwrap_err()),
        ("secret_set", host.secret_set("token", "value").unwrap_err()),
        ("secret_remove", host.secret_remove("token").unwrap_err()),
        ("secret_list", host.secret_list().unwrap_err()),
    ];

    for (op, error) in &errors {
        println!("{op} without capability -> {error}");
        assert_eq!(error.code(), "unsupported", "{op} must be unsupported");
        assert!(
            matches!(error, Error::Unsupported(message) if message.contains("capability")),
            "{op} returned the wrong typed error: {error:?}"
        );
        assert_eq!(
            host.calls(op),
            0,
            "{op} must not reach the underlying operation when its capability is absent"
        );
    }
    assert_eq!(host.calls("list_installed"), 0);
    assert_eq!(host.calls("secret_set"), 0);
    assert_eq!(host.foreground_running(), false);
    assert!(
        host.notifications().is_empty(),
        "a denied notify must not enqueue a notification"
    );
    println!(
        "witness after denied batch: list_installed_calls={} install_calls={} secret_set_calls={} notifications={} foreground_running={}",
        host.calls("list_installed"),
        host.calls("install"),
        host.calls("secret_set"),
        host.notifications().len(),
        host.foreground_running()
    );

    // Capabilities that are genuinely present are allowed to run.
    host.set_capabilities(CapabilitySet::from_caps(Capability::ALL))
        .expect("grant capabilities");
    assert_eq!(host.list_installed().unwrap().len(), 1);
    assert_eq!(host.calls("list_installed"), 1);
    host.notify(&notification()).unwrap();
    assert_eq!(host.notifications().len(), 1);
    assert_eq!(host.calls("notify"), 1);

    let bits = host.capabilities().bits();
    println!("capabilities after grant: bits={bits:#x}");
}

#[test]
fn ports_contract_capability_malformed_and_absent_ids_fail_closed() {
    // A bogus capability id is a typed invalid-argument error, never a panic.
    let bogus = Capability::from_id("not-a-capability").unwrap_err();
    assert_eq!(bogus.code(), "invalid_argument");
    let bogus_set = CapabilitySet::from_ids(["inventory", "nope"]).unwrap_err();
    assert_eq!(bogus_set.code(), "invalid_argument");

    // Unknown ids are not capabilities: `supports_id` answers false (fail closed).
    let caps = CapabilitySet::from_caps([Capability::Inventory]);
    assert!(caps.supports(Capability::Inventory));
    assert!(!caps.supports(Capability::Install));
    assert!(!caps.supports_id("install"));
    assert!(!caps.supports_id("bogus-capability"));
    assert!(!caps.supports_id(""));

    // Bits outside the known capability set never turn into an accidental grant.
    let truncated = CapabilitySet::from_bits_truncate(u64::MAX);
    assert!(truncated.supports(Capability::Secrets));
    assert!(!truncated.supports_id("capability-from-the-future"));

    println!(
        "bogus capability -> {bogus}; supports(bogus)={}",
        caps.supports_id("bogus-capability")
    );
}

#[test]
fn ports_contract_http_fake_records_proxy_ca_timeout_and_validates() {
    let fake = FakeHttpPort::new();
    let ca = b"-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n".to_vec();
    let options = HttpOptions::new()
        .with_header("X-Test", "yes")
        .with_timeout(Duration::from_secs(7))
        .with_proxy("http://127.0.0.1:7890")
        .with_ca_pem(ca.clone());

    let response = fake
        .get("https://example.test/info.json", &options)
        .expect("fake get");
    assert_eq!(response.status, 200);

    let post_options = options.clone().with_timeout(Duration::from_secs(3));
    fake.post("https://example.test/api", b"payload", &post_options)
        .expect("fake post");

    let calls = fake.calls();
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0].method, "GET");
    assert_eq!(calls[0].url, "https://example.test/info.json");
    assert_eq!(calls[0].proxy.as_deref(), Some("http://127.0.0.1:7890"));
    assert_eq!(calls[0].ca_pem.as_deref(), Some(ca.as_slice()));
    assert_eq!(calls[0].timeout, Duration::from_secs(7));
    assert_eq!(
        calls[0].headers,
        vec![("X-Test".to_string(), "yes".to_string())]
    );
    assert_eq!(calls[1].method, "POST");
    assert_eq!(calls[1].body.as_deref(), Some(b"payload".as_slice()));
    assert_eq!(calls[1].timeout, Duration::from_secs(3));

    // Malformed proxy URLs are typed failures and are not sent.
    let bad_proxy = HttpOptions::new().with_proxy("not a proxy url");
    let error = fake
        .get("https://example.test/nope", &bad_proxy)
        .unwrap_err();
    assert_eq!(error.code(), "invalid_argument");
    assert_eq!(
        fake.calls().len(),
        2,
        "invalid options must not be recorded/sent"
    );

    let zero_timeout = HttpOptions::new().with_timeout(Duration::from_secs(0));
    assert_eq!(
        fake.get("https://example.test/zero", &zero_timeout)
            .unwrap_err()
            .code(),
        "invalid_argument"
    );

    println!(
        "http fake recorded proxy={:?} ca_bytes={} timeout={:?}",
        calls[0].proxy,
        calls[0].ca_pem.as_ref().map(Vec::len).unwrap_or(0),
        calls[0].timeout
    );
}

#[test]
fn ports_contract_file_secret_store_0600_and_atomic_replace() {
    let dir = temp_dir("secrets");
    let root = dir.join("secrets");
    let store = FileSecretStore::new(&root);

    store.set("github_token", "first-value").expect("set first");
    assert_eq!(
        store.get("github_token").expect("get first").as_deref(),
        Some("first-value")
    );
    assert_eq!(
        store.list().expect("list"),
        vec!["github_token".to_string()]
    );

    // Atomic replace: existing target is replaced with the new complete value,
    // and no temporary files are left behind.
    store.set("github_token", "second-value").expect("replace");
    assert_eq!(
        store.get("github_token").expect("get second").as_deref(),
        Some("second-value")
    );
    let leftovers: Vec<String> = std::fs::read_dir(&root)
        .expect("read secret root")
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with('.'))
        .collect();
    assert!(
        leftovers.is_empty(),
        "temp files must not survive: {leftovers:?}"
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(root.join("github_token"))
            .expect("secret metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "secret files must be 0600 on Unix");
        let root_mode = std::fs::metadata(&root)
            .expect("root metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(root_mode, 0o700, "secret root must be 0700 on Unix");
    }

    // Invalid keys are typed and never escape the root.
    for bad in ["", "../escape", "a/b", "with space", ".hidden", "nul\0byte"] {
        let error = store.set(bad, "value").unwrap_err();
        assert_eq!(error.code(), "invalid_argument", "key {bad:?}");
        assert_eq!(store.get(bad).unwrap_err().code(), "invalid_argument");
        assert_eq!(store.remove(bad).unwrap_err().code(), "invalid_argument");
    }

    // Removal is idempotent from the caller's perspective (bool signals presence).
    assert!(store.remove("github_token").expect("remove"));
    assert!(!store.remove("github_token").expect("remove missing"));
    assert_eq!(store.get("github_token").expect("missing get"), None);
    assert!(store.list().expect("empty list").is_empty());

    // The in-memory port follows the same key contract.
    let memory = InMemorySecretPort::new();
    memory.set("token", "v").expect("memory set");
    assert_eq!(memory.get("token").unwrap().as_deref(), Some("v"));
    assert_eq!(
        memory.set("../bad", "v").unwrap_err().code(),
        "invalid_argument"
    );

    println!(
        "secret store root={} mode=0600 atomic_replace=ok leftovers={}",
        root.display(),
        leftovers.len()
    );
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn ports_contract_metadata_ttl_cache_hit_then_refetch_after_ttl() {
    let inner = FakeMetadataPort::new();
    inner.set(
        "acme",
        "demo",
        Some(meta("com.example.one", "One", "https://icon/one.png")),
    );

    let base = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
    let clock = Arc::new(Mutex::new(base));
    let clock_ref = clock.clone();
    let port = CachedMetadataPort::new(inner.clone())
        .with_clock(Arc::new(move || *clock_ref.lock().expect("clock")));

    let first = port
        .resolve("acme", "demo")
        .expect("first resolve")
        .expect("metadata");
    assert_eq!(first.package_name.as_deref(), Some("com.example.one"));
    assert_eq!(inner.fetch_count(), 1);

    // Fresh data exists upstream, but the cache must keep serving the stale
    // value INSIDE the 24h TTL.
    inner.set(
        "acme",
        "demo",
        Some(meta("com.example.two", "Two", "https://icon/two.png")),
    );
    *clock.lock().expect("clock") = base + Duration::from_secs(23 * 60 * 60);
    let cached = port
        .resolve("acme", "demo")
        .expect("cached resolve")
        .expect("metadata");
    assert_eq!(cached.package_name.as_deref(), Some("com.example.one"));
    assert_eq!(cached.app_name.as_deref(), Some("One"));
    assert_eq!(inner.fetch_count(), 1, "TTL hit must not refetch");

    // One hour later the entry is older than 24h: refetch and observe the new
    // upstream value.
    *clock.lock().expect("clock") = base + Duration::from_secs(25 * 60 * 60);
    let refreshed = port
        .resolve("acme", "demo")
        .expect("refetch")
        .expect("metadata");
    assert_eq!(refreshed.package_name.as_deref(), Some("com.example.two"));
    assert_eq!(refreshed.app_name.as_deref(), Some("Two"));
    assert_eq!(inner.fetch_count(), 2, "TTL miss must refetch exactly once");

    // Override helpers fall back only when the metadata field is absent.
    let override_meta = PackageMetadata {
        package_name: Some("com.example.real".to_string()),
        app_name: None,
        icon_url: None,
    };
    assert_eq!(
        override_meta.package_name_or("fallback"),
        "com.example.real"
    );
    assert_eq!(override_meta.app_name_or("fallback"), "fallback");
    assert_eq!(override_meta.icon_or("fallback"), "fallback");

    // Malformed lookup keys are typed.
    assert_eq!(
        port.resolve("", "demo").unwrap_err().code(),
        "invalid_argument"
    );
    assert_eq!(
        port.resolve("acme", "demo/escape").unwrap_err().code(),
        "invalid_argument"
    );

    println!(
        "metadata cache fetched={} first={:?} cached={:?} refreshed={:?}",
        inner.fetch_count(),
        first.package_name,
        cached.package_name,
        refreshed.package_name
    );
}

#[test]
fn ports_contract_core_config_debug_redacts_token() {
    let config = CoreConfig::new(
        Some("http://user:password@127.0.0.1:7890".to_string()),
        Some("ghp_super_secret_value".to_string()),
    )
    .expect("valid config")
    .with_fdroid_sources(vec!["https://f-droid.org/repo".to_string()])
    .expect("valid source");

    let debug = format!("{config:?}");
    println!("redacted config Debug -> {debug}");
    assert!(
        !debug.contains("ghp_super_secret_value"),
        "Debug must not contain the GitHub token: {debug}"
    );
    assert!(
        !debug.contains("password"),
        "Debug must not leak proxy credentials: {debug}"
    );
    assert!(debug.contains("<redacted>"));
    assert_eq!(config.github_token(), Some("ghp_super_secret_value"));
    assert_eq!(
        config.proxy_url(),
        Some("http://user:password@127.0.0.1:7890")
    );
    assert_eq!(
        config.fdroid_sources(),
        &["https://f-droid.org/repo".to_string()]
    );

    // Missing token renders as an absent field, never as a fake secret.
    let no_token = CoreConfig::new(None, None).expect("empty config");
    assert_eq!(no_token.github_token(), None);
    assert!(!format!("{no_token:?}").contains("ghp_"));

    // Malformed input is typed.
    assert_eq!(
        CoreConfig::new(Some("not a proxy".to_string()), None)
            .unwrap_err()
            .code(),
        "invalid_argument"
    );
    assert_eq!(
        CoreConfig::new(None, Some(String::new()))
            .unwrap_err()
            .code(),
        "invalid_argument"
    );
    assert_eq!(
        no_token
            .clone()
            .with_fdroid_sources(vec!["ftp://example.test".to_string()])
            .unwrap_err()
            .code(),
        "invalid_argument"
    );
}

#[test]
fn ports_contract_repo_port_commands() {
    let fake = FakeRepoPort::new("/tmp/fake-repo.db");
    fake.add_repo(repo_meta("https://f-droid.org/repo"));
    fake.add_app(
        "https://f-droid.org/repo",
        repo_app("org.example.one", "One"),
    );
    fake.add_app(
        "https://f-droid.org/repo",
        repo_app("org.example.two", "Two"),
    );

    let downloaded = fake
        .download_repo("https://f-droid.org/repo")
        .expect("download repo");
    assert_eq!(downloaded.app_count, 2);
    assert_eq!(fake.download_count(), 1);
    assert_eq!(fake.get_app_count("https://f-droid.org/repo").unwrap(), 2);

    let found = fake
        .search_apps("https://f-droid.org/repo", "TWO", 10)
        .expect("search");
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].package_name, "org.example.two");

    let meta = fake
        .get_repo_meta("https://f-droid.org/repo")
        .expect("repo meta")
        .expect("downloaded repo");
    assert_eq!(meta.name, "F-Droid");
    assert_eq!(fake.get_repo_meta("https://unknown.test").unwrap(), None);

    let one = fake
        .get_one_app("https://f-droid.org/repo", "org.example.one")
        .expect("one app")
        .expect("present");
    assert_eq!(one.name, "One");
    assert_eq!(
        fake.get_one_app("https://f-droid.org/repo", "org.example.missing")
            .unwrap(),
        None
    );

    assert_eq!(fake.db_path(), Path::new("/tmp/fake-repo.db"));

    fake.clear_apps("https://f-droid.org/repo").expect("clear");
    assert_eq!(fake.get_app_count("https://f-droid.org/repo").unwrap(), 0);
    assert!(fake
        .search_apps("https://f-droid.org/repo", "One", 10)
        .unwrap()
        .is_empty());

    // Empty sources/queries are typed rather than panicking.
    assert_eq!(
        fake.get_app_count("").unwrap_err().code(),
        "invalid_argument"
    );
    assert_eq!(
        fake.search_apps("https://f-droid.org/repo", "x", 0)
            .unwrap_err()
            .code(),
        "invalid_argument"
    );

    println!(
        "repo port commands: count={} search_hits={} db={}",
        fake.get_app_count("https://f-droid.org/repo").unwrap(),
        found.len(),
        fake.db_path().display()
    );
}
