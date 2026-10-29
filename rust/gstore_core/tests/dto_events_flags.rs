//! Todo 2 contract: DTO serde, event wire names, and Rust-owned flags.

use std::sync::Mutex;

use gstore_core::dto::{
    AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelKind, ChannelMeta,
    ChannelState, DetailSection,
};
use gstore_core::error::Error;
use gstore_core::event::CoreEvent;
use gstore_core::facts::{InstallRequest, VariantChoice};
use gstore_core::flags::{flags, reset_flags, set_flags, Flags, FlagsApi, FlagsPatch};

/// Serializes the global-flag tests. Cargo runs integration tests in parallel.
static FLAGS_TEST_LOCK: Mutex<()> = Mutex::new(());

fn key() -> ChannelKey {
    ChannelKey::new("local_db").expect("valid key")
}

fn sample_download() -> AppDownload {
    AppDownload {
        url: "https://example.com/app.apk".to_string(),
        name: "app.apk".to_string(),
        size: Some(1024),
        download_count: Some(7),
        version: Some("1.2.3".to_string()),
        version_code: Some(123),
        published_at: Some(1_700_000_000_000),
        platform: Some("arm64-v8a".to_string()),
        hash: Some("abc123".to_string()),
        hash_type: Some("sha256".to_string()),
        downloadable: true,
        note: None,
        extra: None,
    }
}

fn sample_detail() -> AppDetail {
    let mut extra = serde_json::Map::new();
    extra.insert("stars".to_string(), serde_json::json!(42));
    AppDetail {
        app_id: "owner/repo".to_string(),
        name: "Demo".to_string(),
        icon: "https://example.com/icon.png".to_string(),
        description: "demo app".to_string(),
        version: Some("1.2.3".to_string()),
        developer: Some("owner".to_string()),
        package_name: Some("com.example.demo".to_string()),
        project_url: Some("https://example.com".to_string()),
        channel: ChannelKind::Github,
        sections: vec![DetailSection::Version, DetailSection::Downloads],
        downloads: vec![sample_download()],
        extra,
        labels: Vec::new(),
    }
}

fn sample_summary() -> AppSummary {
    AppSummary {
        app_id: "owner/repo".to_string(),
        package_name: Some("com.example.demo".to_string()),
        name: "Demo".to_string(),
        user: "owner".to_string(),
        repositories: "demo".to_string(),
        icon: "https://example.com/icon.png".to_string(),
        des: "demo app".to_string(),
        readme: Some("# Demo".to_string()),
        category: Some(vec!["tools".to_string()]),
        extra: None,
        labels: Vec::new(),
    }
}

fn sample_update() -> AppUpdate {
    AppUpdate {
        app_id: "owner/repo".to_string(),
        package_name: "com.example.demo".to_string(),
        name: "Demo".to_string(),
        icon: Some("https://example.com/icon.png".to_string()),
        latest_version: Some("2.0.0".to_string()),
        latest_download: Some(sample_download()),
        detail: sample_detail(),
    }
}

fn sample_meta() -> ChannelMeta {
    ChannelMeta {
        kind: ChannelKind::Github,
        name: "GitHub".to_string(),
        description: "GitHub API".to_string(),
        enabled: true,
        priority: 2,
        support_offline: false,
        last_update_time: Some(1_700_000_000_000),
        version: Some("v1".to_string()),
    }
}

fn sample_state() -> ChannelState {
    ChannelState {
        key: key(),
        kind: ChannelKind::LocalDb,
        enabled: true,
        ready: false,
        last_refresh_at: None,
        app_count: 0,
        last_error: None,
    }
}

#[test]
fn dto_events_flags_dto_serde_roundtrip() {
    let summary = sample_summary();
    let encoded = serde_json::to_string(&summary).expect("serialize summary");
    let decoded: AppSummary = serde_json::from_str(&encoded).expect("deserialize summary");
    assert_eq!(decoded, summary, "AppSummary must round-trip");

    let detail = sample_detail();
    let encoded = serde_json::to_string(&detail).expect("serialize detail");
    let decoded: AppDetail = serde_json::from_str(&encoded).expect("deserialize detail");
    assert_eq!(decoded, detail, "AppDetail must round-trip");

    let update = sample_update();
    let encoded = serde_json::to_string(&update).expect("serialize update");
    let decoded: AppUpdate = serde_json::from_str(&encoded).expect("deserialize update");
    assert_eq!(decoded, update, "AppUpdate must round-trip");

    let meta = sample_meta();
    let encoded = serde_json::to_string(&meta).expect("serialize meta");
    let decoded: ChannelMeta = serde_json::from_str(&encoded).expect("deserialize meta");
    assert_eq!(decoded, meta, "ChannelMeta must round-trip");

    let state = sample_state();
    let encoded = serde_json::to_string(&state).expect("serialize state");
    let decoded: ChannelState = serde_json::from_str(&encoded).expect("deserialize state");
    assert_eq!(decoded, state, "ChannelState must round-trip");

    // ChannelKey is transparent on the wire.
    let encoded = serde_json::to_string(&key()).expect("serialize key");
    assert_eq!(encoded, "\"local_db\"");
    assert_eq!(
        ChannelKind::from_code("local_db").expect("kind"),
        ChannelKind::LocalDb
    );
}

#[test]
fn dto_events_flags_event_wire_names_are_exact() {
    let events = vec![
        (
            CoreEvent::ChannelChanged {
                key: key(),
                kind: ChannelKind::LocalDb,
            },
            "channel.changed",
        ),
        (
            CoreEvent::CatalogChanged {
                key: key(),
                app_id: Some("app-1".to_string()),
                removed: false,
            },
            "catalog.changed",
        ),
        (
            CoreEvent::UpdateFound {
                key: key(),
                app_id: "app-1".to_string(),
                update: Box::new(sample_update()),
            },
            "update.found",
        ),
        (
            CoreEvent::DownloadProgress {
                task_id: "task-1".to_string(),
                app_id: Some("app-1".to_string()),
                bytes_done: 512,
                total: 1024,
                fraction: 0.5,
            },
            "download.progress",
        ),
        (
            CoreEvent::DownloadDone {
                task_id: "task-1".to_string(),
                app_id: Some("app-1".to_string()),
                success: true,
                path: Some("/tmp/app.apk".to_string()),
                error: None,
            },
            "download.done",
        ),
        (
            CoreEvent::InstallResult {
                app_id: "app-1".to_string(),
                package_name: Some("com.example.demo".to_string()),
                success: true,
                message: None,
            },
            "install.result",
        ),
        (
            CoreEvent::ScriptUiRequest {
                key: key(),
                app_id: Some("app-1".to_string()),
                request_id: "req-1".to_string(),
                kind: "form".to_string(),
                title: "Need credentials".to_string(),
                message: Some("Enter username".to_string()),
                fields: vec![],
            },
            "script.ui_request",
        ),
        (
            CoreEvent::InventoryChanged {
                source_id: "android".to_string(),
                seq: 7,
                count: 3,
            },
            "inventory.changed",
        ),
        (
            CoreEvent::InstallUnknown {
                session_id: "session-1".to_string(),
                module_task_id: Some("task-1".to_string()),
            },
            "install.unknown",
        ),
        (
            CoreEvent::InstallRequested {
                request: InstallRequest {
                    module_task_id: "task-1".to_string(),
                    session_id: "session-1".to_string(),
                    package_name: "com.example.demo".to_string(),
                    version_name: "1.2.3".to_string(),
                    apk_path: "/data/cache/demo.apk".to_string(),
                    method: "shizuku".to_string(),
                    variant: VariantChoice {
                        abi: "arm64-v8a".to_string(),
                        url: "https://example.com/demo-arm64.apk".to_string(),
                        fallback_chain: vec!["https://example.com/demo.apk".to_string()],
                    },
                },
            },
            "install.requested",
        ),
    ];

    let mut wire_names = Vec::new();
    for (event, expected) in events {
        wire_names.push(event.wire_name());
        assert_eq!(event.wire_name(), expected, "wire_name mismatch");
        let value = serde_json::to_value(&event).expect("serialize event");
        assert_eq!(
            value.get("event").and_then(|v| v.as_str()),
            Some(expected),
            "serde event name mismatch for {expected}"
        );
        let round_trip: CoreEvent =
            serde_json::from_value(value).expect("deserialize event round-trip");
        assert_eq!(round_trip, event, "event must round-trip: {expected}");
    }
    println!("event wire names: {}", wire_names.join(", "));
}

#[test]
fn dto_events_flags_defaults_all_false() {
    let _guard = FLAGS_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let snapshot = reset_flags();
    assert_eq!(
        snapshot,
        Flags::DISABLED,
        "reset must return the disabled snapshot"
    );
    assert!(!snapshot.channels);
    assert!(!snapshot.catalog);
    assert!(!snapshot.update);
    assert!(!snapshot.download);
    assert!(!snapshot.install);
    assert!(!snapshot.js_channel);
    assert!(!snapshot.core_writes, "core_writes must stay false");
    assert_eq!(flags(), Flags::DISABLED, "global default must be disabled");
}

#[test]
fn dto_events_flags_set_get_reset() {
    let _guard = FLAGS_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    reset_flags();

    let api = FlagsApi::new();
    let target = FlagsPatch {
        channels: Some(true),
        catalog: Some(true),
        update: None,
        download: Some(true),
        install: None,
        js_channel: Some(true),
        core_writes: None,
    };
    let snapshot = api.set(target).expect("set flags");
    println!("flag snapshot after set: {:?}", snapshot);
    assert!(snapshot.channels);
    assert!(snapshot.catalog);
    assert!(!snapshot.update);
    assert!(snapshot.download);
    assert!(!snapshot.install);
    assert!(snapshot.js_channel);
    assert!(!snapshot.core_writes);
    assert_eq!(
        api.get(),
        snapshot,
        "get must return the resulting snapshot"
    );
    assert_eq!(flags(), snapshot, "global accessor must observe set");

    let cleared = set_flags(FlagsPatch {
        download: Some(false),
        ..FlagsPatch::default()
    })
    .expect("partial set");
    assert!(cleared.channels, "partial set keeps untouched flags");
    assert!(!cleared.download);

    // core_writes is deliberately not armable in this wave.
    let rejected = set_flags(FlagsPatch {
        core_writes: Some(true),
        ..FlagsPatch::default()
    });
    assert!(
        matches!(rejected, Err(Error::Unsupported(_))),
        "arming core_writes must be rejected, got {rejected:?}"
    );
    assert!(!flags().core_writes);

    let reset = api.reset();
    println!("flag snapshot after reset: {:?}", reset);
    assert_eq!(reset, Flags::DISABLED);
    assert_eq!(api.get(), Flags::DISABLED);
    assert_eq!(flags(), Flags::DISABLED);
}

#[test]
fn dto_events_flags_concurrent_read_sanity() {
    let _guard = FLAGS_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    reset_flags();

    // No sleeps and no writer: every concurrent reader must see the disabled snapshot.
    std::thread::scope(|scope| {
        let mut handles = Vec::new();
        for _ in 0..8 {
            handles.push(scope.spawn(|| {
                let mut reads = 0u32;
                for _ in 0..200 {
                    let snapshot = flags();
                    assert_eq!(snapshot, Flags::DISABLED);
                    assert!(!snapshot.core_writes);
                    reads += 1;
                }
                reads
            }));
        }
        let total: u32 = handles
            .into_iter()
            .map(|h| h.join().expect("reader join"))
            .sum();
        assert_eq!(total, 8 * 200);
    });
}

#[test]
fn dto_events_flags_malformed_input_is_typed_error() {
    let malformed = CoreEvent::from_json("{not json");
    assert!(
        matches!(malformed, Err(Error::Serialization(_))),
        "malformed event JSON must be a typed serialization error, got {malformed:?}"
    );

    let unknown_event = CoreEvent::from_json(r#"{"event":"no.such.event","payload":{}}"#);
    assert!(
        matches!(unknown_event, Err(Error::Serialization(_))),
        "unknown event name must be a typed serialization error, got {unknown_event:?}"
    );

    let unknown_kind = serde_json::from_str::<ChannelKind>("\"no_such_kind\"").map_err(Error::from);
    assert!(
        matches!(unknown_kind, Err(Error::Serialization(_))),
        "unknown ChannelKind JSON must be a typed error, got {unknown_kind:?}"
    );
    assert!(matches!(
        ChannelKind::from_code("no_such_kind"),
        Err(Error::InvalidArgument(_))
    ));
    let malformed = CoreEvent::from_json("{not json").expect_err("malformed");
    let unknown = CoreEvent::from_json(r#"{"event":"no.such.event","payload":{}}"#)
        .expect_err("unknown event");
    let unknown_kind = ChannelKind::from_code("no_such_kind").expect_err("unknown kind");
    println!(
        "malformed error codes: {}, {}, {}",
        malformed.code(),
        unknown.code(),
        unknown_kind.code()
    );
}
