//! `sendMessage` + `host.*` contract tests (Dart parity of shapes and semantics).

mod support;

use serde_json::json;

use support::{fake_host, recorded, runtime, CallDetail};

#[test]
fn script_host_api_send_message_accepts_json_string_payload() {
    let (host, calls) = fake_host();
    let runtime = runtime("js.a", host);

    let out = runtime
        .eval(r#"sendMessage('host.config.get', '{"key":"theme"}')"#)
        .expect("JSON-string payload is accepted");
    assert_eq!(out, json!({ "ok": true, "data": "config-value" }));
    assert!(recorded(&calls).iter().any(|call| {
        call.method == "host.config.get"
            && call.channel == "js.a"
            && call.detail
                == CallDetail::Config {
                    key: "theme".to_owned(),
                }
    }));
}

#[test]
fn script_host_api_send_message_accepts_object_payload() {
    let (host, calls) = fake_host();
    let runtime = runtime("js.a", host);

    let out = runtime
        .eval(r#"sendMessage('host.config.get', {key: 'theme'})"#)
        .expect("object payload is accepted");
    assert_eq!(out, json!({ "ok": true, "data": "config-value" }));
    assert!(recorded(&calls)
        .iter()
        .any(|call| call.method == "host.config.get"));
}

#[test]
fn script_host_api_returns_envelope_verbatim_including_ok_false() {
    let (host, _calls) = fake_host();
    let runtime = runtime("js.a", host);

    // `{ok:false}` is returned, never thrown and never unwrapped to `.data`.
    let denied = runtime
        .eval("host.ui.call('missing', {a: 1})")
        .expect("unregistered native is an envelope, not a throw");
    assert_eq!(
        denied,
        json!({ "ok": false, "error": "host.native.ui.missing 未注册" })
    );

    let wrapped = runtime
        .eval("sendMessage('host.native.call', {ns:'ui',method:'show',payload:{x:1}})")
        .expect("registered native call");
    assert_eq!(wrapped, json!({ "ok": true, "data": { "shown": true } }));
}

#[test]
fn script_host_api_network_non_2xx_passthrough() {
    let (host, _calls) = fake_host();
    let runtime = runtime("js.a", host);

    let not_found = runtime
        .eval("host.network.get('https://example.com/500', {params: {q: 'x'}})")
        .expect("non-2xx does not throw");
    assert_eq!(
        not_found,
        json!({
            "ok": false,
            "status": 500,
            "data": { "msg": "server error" },
            "error": "HTTP 500",
        })
    );
    println!("non-2xx envelope: {not_found}");

    let unauthorized = runtime
        .eval("host.network.post('https://example.com/401', {json: {a: 1}})")
        .expect("401 does not throw");
    assert_eq!(unauthorized["status"], json!(401));
    assert_eq!(unauthorized["data"]["msg"], json!("unauthorized"));
    assert_eq!(unauthorized["error"], json!("HTTP 401"));

    let ok = runtime
        .eval("host.network.get('https://example.com/ok', {params: {q: 'x'}})")
        .expect("2xx returns");
    assert_eq!(ok["ok"], json!(true));
    assert_eq!(ok["status"], json!(200));
    assert!(ok.get("error").is_none(), "2xx must not carry error: {ok}");
}

#[test]
fn script_host_api_network_denied_is_typed_envelope() {
    let (host, _calls) = fake_host();
    let runtime = runtime("js.a", host);

    let out = runtime
        .eval("host.network.get('https://example.com/denied', {})")
        .expect("network failure must not throw");
    assert_eq!(
        out,
        json!({ "ok": false, "error": "CORE_E_SCRIPT_HOST: network denied" })
    );
    println!("network denied envelope: {out}");
}

#[test]
fn script_host_api_dispatches_all_thirteen_methods() {
    let (host, calls) = fake_host();
    let runtime = runtime("js.a", host);

    runtime
        .eval("host.network.get('https://example.com/a', {params: {q: 1}})")
        .expect("network.get");
    runtime
        .eval("host.network.post('https://example.com/b', {body: {a: 1}})")
        .expect("network.post");
    let apps = runtime
        .eval("host.database.getAppsByChannel()")
        .expect("getAppsByChannel");
    assert_eq!(apps, json!({ "ok": true, "data": [] }));
    let app = runtime
        .eval("host.database.getApp('app-x')")
        .expect("getApp");
    assert_eq!(app, json!({ "ok": true, "data": null }));
    let inserted = runtime
        .eval("host.database.insertApps([{appId:'app-a', name:'A'}])")
        .expect("insertApps");
    assert_eq!(inserted, json!({ "ok": true, "data": 1 }));
    let config = runtime
        .eval("host.config.get('theme')")
        .expect("config.get");
    assert_eq!(config, json!({ "ok": true, "data": "config-value" }));
    let env = runtime.eval("host.env.get('NAME')").expect("env.get");
    assert_eq!(env, json!({ "ok": true, "data": "A" }));
    let all = runtime.eval("host.env.all()").expect("env.all");
    assert_eq!(all, json!({ "ok": true, "data": { "NAME": "A" } }));
    let has = runtime.eval("host.env.has('NAME')").expect("env.has");
    assert_eq!(has, json!({ "ok": true, "data": true }));
    let info = runtime.eval("host.log.info('hello')").expect("log.info");
    assert_eq!(info, json!({ "ok": true }));
    let error = runtime.eval("host.log.error('oops')").expect("log.error");
    assert_eq!(error, json!({ "ok": true }));
    let version = runtime
        .eval("host.utils.call('checkVersion', {packageName: 'com.example'})")
        .expect("checkVersion");
    assert_eq!(
        version,
        json!({
            "ok": true,
            "data": {
                "installed": true,
                "version": "1.2.3",
                "versionCode": 42,
                "name": "Fake App",
            },
        })
    );
    let native = runtime
        .eval("host.core.call('ping', {})")
        .expect("native.call");
    assert_eq!(native, json!({ "ok": true, "data": "pong" }));

    let calls = recorded(&calls);
    let methods: Vec<&str> = calls.iter().map(|call| call.method).collect();
    for expected in [
        "host.network.get",
        "host.network.post",
        "host.database.getAppsByChannel",
        "host.database.getApp",
        "host.database.insertApps",
        "host.config.get",
        "host.env.get",
        "host.env.all",
        "host.env.has",
        "host.log.info",
        "host.log.error",
        "host.utils.checkVersion",
        "host.native.call",
    ] {
        assert!(
            methods.contains(&expected),
            "missing {expected} in {methods:?}"
        );
    }
    assert!(calls.iter().all(|call| call.channel == "js.a"));
}

#[test]
fn script_host_api_check_version_empty_package_skips_host() {
    let (host, calls) = fake_host();
    let runtime = runtime("js.a", host);

    let out = runtime
        .eval("host.utils.call('checkVersion', {packageName: ''})")
        .expect("empty package");
    assert_eq!(out, json!({ "ok": true, "data": { "installed": false } }));
    assert!(!recorded(&calls)
        .iter()
        .any(|call| call.method == "host.utils.checkVersion"));
}

#[test]
fn script_host_api_prelude_is_installed_before_user_script() {
    let (host, _calls) = fake_host();
    let runtime = runtime("js.a", host);

    let installed = runtime
        .eval(
            "typeof sendMessage === 'function' \
             && typeof host.network.get === 'function' \
             && typeof host.network.post === 'function' \
             && typeof host.database.getAppsByChannel === 'function' \
             && typeof host.database.getApp === 'function' \
             && typeof host.database.insertApps === 'function' \
             && typeof host.config.get === 'function' \
             && typeof host.env.get === 'function' \
             && typeof host.env.all === 'function' \
             && typeof host.env.has === 'function' \
             && typeof host.log.info === 'function' \
             && typeof host.log.error === 'function' \
             && typeof host.utils.call === 'function' \
             && typeof host.ui.call === 'function' \
             && typeof host.core.call === 'function' \
             && typeof host.alert.call === 'function'",
        )
        .expect("prelude globals");
    assert_eq!(installed, json!(true));
}

#[test]
fn script_host_api_unregistered_native_lists_namespace_and_method() {
    let (host, calls) = fake_host();
    let runtime = runtime("js.a", host);

    let out = runtime
        .eval("host.alert.call('toast', {text: 'hi'})")
        .expect("unregistered native");
    assert_eq!(
        out,
        json!({ "ok": false, "error": "host.native.alert.toast 未注册" })
    );
    println!("unregistered native envelope: {out}");
    assert!(recorded(&calls).iter().any(|call| matches!(
        &call.detail,
        CallDetail::Native { namespace, method, .. }
            if namespace == "alert" && method == "toast"
    )));
}
