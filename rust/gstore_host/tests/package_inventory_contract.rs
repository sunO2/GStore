//! Todo 8 contract: package inventory decoders, JNI error mapping, cache, and
//! capability gating. The tests are deterministic and never touch a device.

use gstore_core::ports::platform::{
    AppComponent, AppComponents, AppPermissionState, AppSignature, Capability, CapabilitySet,
    InstalledApp, PlatformHost,
};
use gstore_core::Error;
use gstore_host::platform_host::{
    cached_package_count, decode_optional_installed_app, invalidate_cache, is_inventory_denied,
    map_inventory_jni_error, parse_components, parse_device_info, parse_installed_app,
    parse_installed_apps, parse_permissions, parse_signatures, AndroidPlatformHost, InventoryCache,
};

const INSTALLED_JSON: &str = r#"[
  {
    "package_name": "com.example.one",
    "app_name": "Example One",
    "version_name": "1.2.3",
    "version_code": 123,
    "icon": "res://icon/one",
    "system": false
  },
  {
    "package_name": "com.example.system",
    "app_name": "System App",
    "version_name": "",
    "version_code": 1,
    "icon": null,
    "system": true
  }
]"#;

const SIGNATURES_JSON: &str = r#"[
  {
    "algorithm": "SHA256withRSA",
    "subject": "CN=GStore,O=Example",
    "sha256": "aa:bb",
    "sha1": "cc:dd",
    "kind": "current"
  },
  {
    "algorithm": "SHA256withRSA",
    "subject": "CN=Old,O=Example",
    "sha256": "ee:ff",
    "sha1": "11:22",
    "kind": "history"
  }
]"#;

const COMPONENTS_JSON: &str = r#"{
  "components": [
    {
      "kind": "ACTIVITY",
      "name": "com.example.one.MainActivity",
      "exported": true,
      "enabled": true,
      "process_name": "com.example.one"
    },
    {
      "kind": "SERVICE",
      "name": "com.example.one.SyncService",
      "exported": false,
      "enabled": false,
      "process_name": null
    }
  ],
  "permission_states": [
    {
      "name": "android.permission.INTERNET",
      "granted": true,
      "never_for_location": false
    }
  ]
}"#;

const DEVICE_JSON: &str = r#"{
  "manufacturer": "Example",
  "model": "Phone",
  "device": "example",
  "android_version": "15",
  "sdk_int": 35,
  "abis": ["arm64-v8a", "armeabi-v7a"]
}"#;

fn sample_app() -> InstalledApp {
    InstalledApp {
        package_name: "com.example.one".to_string(),
        app_name: "Example One".to_string(),
        version_name: "1.2.3".to_string(),
        version_code: 123,
        icon: Some("res://icon/one".to_string()),
        system: false,
    }
}

fn sample_signature() -> AppSignature {
    AppSignature {
        algorithm: "SHA256withRSA".to_string(),
        subject: "CN=GStore".to_string(),
        sha256: "aa:bb".to_string(),
        sha1: "cc:dd".to_string(),
        kind: "current".to_string(),
    }
}

#[test]
fn package_inventory_contract_decodes_and_gates() {
    let apps = parse_installed_apps(INSTALLED_JSON).expect("installed json");
    assert_eq!(apps.len(), 2);
    assert_eq!(apps[0], sample_app());
    assert_eq!(apps[1].package_name, "com.example.system");
    assert_eq!(apps[1].version_code, 1);
    assert!(apps[1].system);
    assert!(apps[1].icon.is_none());

    let one = parse_installed_app(INSTALLED_JSON).expect_err("an array is not a single app");
    assert_eq!(one.code(), "serialization");
    assert!(decode_optional_installed_app(None)
        .expect("null payload")
        .is_none());
    assert_eq!(
        decode_optional_installed_app(Some(r#"{"package_name":"com.example.one"}"#))
            .expect_err("missing required fields")
            .code(),
        "serialization"
    );

    let signatures = parse_signatures(SIGNATURES_JSON).expect("signatures json");
    assert_eq!(signatures.len(), 2);
    assert_eq!(signatures[0].algorithm, "SHA256withRSA");
    assert_eq!(signatures[0].kind, "current");
    assert_eq!(signatures[1].kind, "history");

    let permissions =
        parse_permissions(r#"["android.permission.INTERNET","android.permission.CAMERA"]"#)
            .expect("permissions json");
    assert_eq!(
        permissions,
        vec!["android.permission.INTERNET", "android.permission.CAMERA"]
    );

    let components = parse_components(COMPONENTS_JSON).expect("components json");
    assert_eq!(components.components.len(), 2);
    assert_eq!(components.components[0].kind, "ACTIVITY");
    assert!(components.components[0].exported);
    assert_eq!(components.components[1].process_name.as_deref(), None);
    assert_eq!(components.permission_states.len(), 1);
    assert!(components.permission_states[0].granted);

    let device = parse_device_info(DEVICE_JSON).expect("device json");
    assert_eq!(device.sdk_int, 35);
    assert_eq!(device.abis, vec!["arm64-v8a", "armeabi-v7a"]);

    assert!(parse_installed_apps("[]").expect("empty array").is_empty());
    assert!(parse_signatures("[]").expect("empty signatures").is_empty());
    assert!(parse_permissions("[]")
        .expect("empty permissions")
        .is_empty());
    assert_eq!(
        parse_components(r#"{"components":[],"permission_states":[]}"#)
            .expect("empty components")
            .components
            .len(),
        0
    );
    assert_eq!(
        parse_installed_apps("{not json")
            .expect_err("malformed")
            .code(),
        "serialization"
    );

    let host = AndroidPlatformHost::new();
    let caps = host.capabilities();
    assert!(caps.supports(Capability::Inventory));
    assert!(caps.supports(Capability::DeviceInfo));
    assert!(caps.supports(Capability::Install));
    assert!(!caps.supports(Capability::StoragePaths));
    assert!(!caps.supports(Capability::Connectivity));
    assert!(!caps.supports(Capability::Secrets));

    let list_error = host.list_installed().expect_err("no VM in tests");
    assert_eq!(list_error.code(), "unsupported");
    assert!(matches!(
        list_error,
        Error::Unsupported(message) if message == "CORE_E_PLATFORM_NOT_INITIALIZED"
    ));
    let get_error = host
        .get_installed("com.example.one")
        .expect_err("no VM in tests");
    assert_eq!(get_error.code(), "unsupported");
    let installed_error = host
        .is_installed("com.example.one")
        .expect_err("no VM in tests");
    assert_eq!(installed_error.code(), "unsupported");
    let source_error = host
        .get_source_dir("com.example.one")
        .expect_err("no VM in tests");
    assert_eq!(source_error.code(), "unsupported");
    let signature_error = host
        .get_signatures("com.example.one")
        .expect_err("no VM in tests");
    assert_eq!(signature_error.code(), "unsupported");
    let permission_error = host
        .get_permissions("com.example.one")
        .expect_err("no VM in tests");
    assert_eq!(permission_error.code(), "unsupported");
    let component_error = host
        .get_components("com.example.one")
        .expect_err("no VM in tests");
    assert_eq!(component_error.code(), "unsupported");

    let oversized = format!(
        "[{}]",
        (0..2000)
            .map(|index| format!(
                r#"{{"package_name":"com.example.{index}","app_name":"App {index}","version_name":"1.0","version_code":{index},"icon":null,"system":false}}"#
            ))
            .collect::<Vec<_>>()
            .join(",")
    );
    assert_eq!(
        parse_installed_apps(&oversized).expect("oversized").len(),
        2000
    );
    println!(
        "decoded apps={} signatures={} permissions={} components={} device_sdk={}",
        apps.len(),
        signatures.len(),
        permissions.len(),
        components.components.len(),
        device.sdk_int
    );
}

#[test]
fn package_inventory_visibility_denied_and_cache_invalidation() {
    let denied = map_inventory_jni_error(
        "java.lang.SecurityException: Package visibility denied for com.example.one",
    );
    assert_eq!(denied.code(), "forbidden");
    assert!(matches!(
        &denied,
        Error::Forbidden(message) if message.contains("CORE_E_PACKAGE_INVENTORY_DENIED")
    ));
    assert!(is_inventory_denied(
        "java.lang.SecurityException: Permission Denial: not allowed to query"
    ));
    assert!(!is_inventory_denied("java.io.IOException: disk"));

    let missing = map_inventory_jni_error(
        "android.content.pm.PackageManager$NameNotFoundException: com.example.gone",
    );
    assert_eq!(missing.code(), "not_found");

    let host = gstore_core::ports::FakePlatformHost::new(CapabilitySet::empty())
        .with_installed(vec![sample_app()]);
    assert_eq!(
        host.is_installed("com.example.one")
            .expect_err("inventory missing")
            .code(),
        "unsupported"
    );
    assert_eq!(
        host.get_source_dir("com.example.one")
            .expect_err("inventory missing")
            .code(),
        "unsupported"
    );
    assert_eq!(
        host.get_signatures("com.example.one")
            .expect_err("inventory missing")
            .code(),
        "unsupported"
    );
    assert_eq!(
        host.get_permissions("com.example.one")
            .expect_err("inventory missing")
            .code(),
        "unsupported"
    );
    assert_eq!(
        host.get_components("com.example.one")
            .expect_err("inventory missing")
            .code(),
        "unsupported"
    );
    for operation in [
        "is_installed",
        "get_source_dir",
        "get_signatures",
        "get_permissions",
        "get_components",
    ] {
        assert_eq!(
            host.calls(operation),
            0,
            "{operation} ran without capability"
        );
    }

    let granted = gstore_core::ports::FakePlatformHost::new(CapabilitySet::from_caps([
        Capability::Inventory,
    ]))
    .with_installed(vec![sample_app()])
    .with_source_dir("com.example.one", "/data/app/com.example.one/base.apk")
    .with_signatures("com.example.one", vec![sample_signature()])
    .with_permissions(
        "com.example.one",
        vec!["android.permission.INTERNET".to_string()],
    )
    .with_components(
        "com.example.one",
        AppComponents {
            components: vec![AppComponent {
                kind: "ACTIVITY".to_string(),
                name: "com.example.one.MainActivity".to_string(),
                exported: true,
                enabled: true,
                process_name: Some("com.example.one".to_string()),
            }],
            permission_states: vec![AppPermissionState {
                name: "android.permission.INTERNET".to_string(),
                granted: true,
                never_for_location: false,
            }],
        },
    );
    assert!(granted.is_installed("com.example.one").expect("granted"));
    assert_eq!(
        granted
            .get_source_dir("com.example.one")
            .expect("source dir")
            .as_deref(),
        Some("/data/app/com.example.one/base.apk")
    );
    assert_eq!(
        granted
            .get_signatures("com.example.one")
            .expect("signatures")
            .len(),
        1
    );
    assert_eq!(
        granted
            .get_permissions("com.example.one")
            .expect("permissions")
            .len(),
        1
    );
    assert_eq!(
        granted
            .get_components("com.example.one")
            .expect("components")
            .permission_states
            .len(),
        1
    );
    assert_eq!(granted.calls("is_installed"), 1);
    assert_eq!(granted.calls("get_components"), 1);

    let mut cache = InventoryCache::new();
    assert!(cache.is_empty());
    cache.insert(sample_app());
    assert_eq!(cache.len(), 1);
    assert!(cache.get("com.example.one").is_some());
    cache.invalidate();
    assert!(cache.is_empty());
    invalidate_cache();
    assert_eq!(cached_package_count(), 0);
    println!(
        "denied={denied} missing={missing} cache_after_invalidate={}",
        cache.len()
    );
}
