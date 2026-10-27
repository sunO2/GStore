//! Parity with the real, unmodified `assets/channels/example.js`.

mod support;

use gstore_script::HttpMethod;
use serde_json::json;

use support::{fake_host, recorded, runtime, CallDetail};

#[test]
fn script_host_api_example_js_search_apps_parity() {
    let (host, calls) = fake_host();
    let runtime = runtime("js.parity", host);

    let source = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../assets/channels/example.js"
    ));
    runtime.eval(source).expect("example.js loads unmodified");

    let out = runtime
        .eval("searchApps('dolphin')")
        .expect("searchApps runs");
    assert_eq!(out["ok"], json!(true));
    assert_eq!(out["data"][0]["appId"], json!("org.example.dolphin"));
    assert_eq!(out["data"][0]["name"], json!("Dolphin"));

    let call = recorded(&calls)
        .into_iter()
        .find(|call| call.method == "host.network.get")
        .expect("example.js performed host.network.get");
    assert_eq!(call.channel, "js.parity");
    match call.detail {
        CallDetail::Http {
            http_method,
            url,
            opts,
        } => {
            assert_eq!(http_method, HttpMethod::Get);
            assert_eq!(url, "https://example.com/api/search");
            // Exactly the JSON the Dart `_hostPrefixJs` produces.
            assert_eq!(
                opts,
                json!({
                    "params": { "q": "dolphin", "page": 1, "size": 20 },
                    "headers": { "Accept": "application/json" },
                })
            );
        }
        other => panic!("unexpected call detail: {other:?}"),
    }
}
