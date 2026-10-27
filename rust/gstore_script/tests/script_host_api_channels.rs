//! Channel isolation: the runtime channel is the only DB/env key a host sees,
//! script-supplied `channelCode` values are discarded, and runtimes never share
//! state.

mod support;

use serde_json::json;

use support::{fake_host, recorded, runtime, CallDetail};

#[test]
fn script_host_api_channel_isolation_has_no_cross_talk() {
    let (host, calls) = fake_host();
    let first = runtime("js.a", host.clone());
    let second = runtime("js.b", host);

    let first_env = first.eval("host.env.all()").expect("first env");
    assert_eq!(first_env, json!({ "ok": true, "data": { "NAME": "A" } }));
    let second_env = second.eval("host.env.all()").expect("second env");
    assert_eq!(second_env, json!({ "ok": true, "data": { "NAME": "B" } }));

    let inserted = first
        .eval("host.database.insertApps([{appId:'app-a', name:'A', channelCode:'js.b'}])")
        .expect("insert on first");
    assert_eq!(inserted, json!({ "ok": true, "data": 1 }));

    let first_apps = first
        .eval("host.database.getAppsByChannel()")
        .expect("first apps");
    assert_eq!(first_apps["data"][0]["appId"], json!("app-a"));
    // The bridge drops the script-supplied channelCode; the host pins the
    // runtime channel when it stores the row.
    assert_eq!(first_apps["data"][0]["channelCode"], json!("js.a"));
    // Exact `_channelAppToJson` field set (nulls preserved).
    let app = first_apps["data"][0].as_object().expect("app object");
    assert_eq!(app.len(), 11, "unexpected appJson keys: {app:?}");
    for key in [
        "appId",
        "name",
        "user",
        "repositories",
        "apprepo",
        "icon",
        "description",
        "category",
        "addTime",
        "channelCode",
        "extra",
    ] {
        assert!(app.contains_key(key), "missing appJson key {key}");
    }
    assert!(app["apprepo"].is_null());
    assert!(app["category"].is_null());
    assert!(app["extra"].is_null());

    let second_apps = second
        .eval("host.database.getAppsByChannel()")
        .expect("second apps");
    assert_eq!(second_apps, json!({ "ok": true, "data": [] }));

    let other = second
        .eval("host.database.getApp('app-a')")
        .expect("second getApp");
    assert_eq!(other, json!({ "ok": true, "data": null }));

    let calls = recorded(&calls);
    // Every call carries exactly one of the two runtime channels.
    assert!(calls
        .iter()
        .all(|call| call.channel == "js.a" || call.channel == "js.b"));
    // Insert payloads never contain a script-provided channelCode.
    for call in &calls {
        if let CallDetail::DbInsert { apps } = &call.detail {
            for app in apps {
                assert!(
                    app.get("channelCode").is_none(),
                    "bridge leaked script channelCode: {app}"
                );
            }
        }
    }
    // The DB/env calls of each runtime stayed on that runtime's channel.
    assert!(calls
        .iter()
        .any(|call| { call.channel == "js.a" && call.detail == CallDetail::EnvAll }));
    assert!(calls
        .iter()
        .any(|call| { call.channel == "js.b" && call.detail == CallDetail::EnvAll }));
}
