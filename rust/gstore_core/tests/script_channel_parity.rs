//! Dart `JsChannel` read-path parity, one row per (method, script state).

mod support;

use support::parity::{report, run, run_without_store, State};

const MISSING_DETAIL: &str = "err:脚本未返回详情数据（脚本未实现或数据获取失败）";
const MISSING_UPDATE: &str = "err:脚本未返回更新信息且渠道库无该应用";
const MISSING_SEARCH: &str = "err:脚本未实现 searchApps 和 getAllApps";
const MISSING_APP: &str =
    "err:script channel `js.parity` returned no app `store.only` and has no saved row";
const MISSING_STORE: &str = "err:script channel has no bound app store";

const STATES: [(&str, State); 8] = [
    ("success", State::Success),
    ("null", State::Null),
    ("ok-false", State::OkFalse),
    ("throw", State::Throw),
    ("search-fallback", State::SearchFallback),
    ("do-update-fallback", State::DoUpdateFallback),
    ("non-list", State::NonList),
    ("non-bool", State::NonBool),
];

#[test]
fn parity_get_all_apps_is_store_only() {
    for (label, state) in STATES {
        let hit = run("getAllApps", state, true, false);
        report("getAllApps", label, "store.only", &hit);
        assert_eq!(hit.calls, 0, "getAllApps must never call the script");

        let miss = run("getAllApps", state, false, true);
        report("getAllApps", &format!("{label}/store-miss"), "", &miss);
        assert_eq!(miss.calls, 0, "getAllApps must never call the script");
    }
}

#[test]
fn parity_get_app_info_store_then_script_then_store() {
    for (label, state) in STATES {
        let cached = run("getAppInfo", state, true, false);
        report(
            "getAppInfo",
            &format!("{label}/cached"),
            "store.only",
            &cached,
        );
        assert_eq!(cached.calls, 0, "cached read must skip the script");

        let expected = if matches!(state, State::Success) {
            "script.only"
        } else {
            "store.only"
        };
        let forced = run("getAppInfo", state, true, true);
        report("getAppInfo", &format!("{label}/forced"), expected, &forced);

        let missing = run("getAppInfo", state, false, false);
        let expected = if matches!(state, State::Success) {
            "script.only"
        } else {
            MISSING_APP
        };
        report(
            "getAppInfo",
            &format!("{label}/store-miss"),
            expected,
            &missing,
        );
    }
}

#[test]
fn parity_get_app_detail_never_falls_back_to_store() {
    for (label, state) in STATES {
        let expected = if matches!(state, State::Success) {
            "9.9"
        } else {
            MISSING_DETAIL
        };
        let hit = run("getAppDetail", state, true, true);
        report(
            "getAppDetail",
            &format!("{label}/store-hit"),
            expected,
            &hit,
        );

        let miss = run("getAppDetail", state, false, true);
        report(
            "getAppDetail",
            &format!("{label}/store-miss"),
            expected,
            &miss,
        );
    }
}

#[test]
fn parity_search_apps_falls_back_to_filtered_get_all_apps() {
    for (label, state) in STATES {
        let expected = match state {
            State::Success => "script.only",
            State::SearchFallback | State::DoUpdateFallback | State::NonBool => "app.dolphin",
            State::Null | State::OkFalse | State::Throw | State::NonList => MISSING_SEARCH,
        };
        let result = run("searchApps", state, true, false);
        report("searchApps", label, expected, &result);
    }
    let upper = run("searchApps", State::SearchFallback, true, false);
    println!(
        "INFO | searchApps         | lower-case filter       | expected=app.dolphin | rust={}",
        upper.result
    );
}

const UNSUPPORTED_SEARCH_BY_CATEGORY: &str = "err:channel does not support search_by_category";
const UNSUPPORTED_GET_ALL_CATEGORIES: &str = "err:channel does not support get_all_categories";

#[test]
fn parity_category_methods_are_typed_unsupported_not_empty() {
    for (label, state) in STATES {
        let categories = run("searchByCategory", state, true, false);
        report(
            "searchByCategory",
            label,
            UNSUPPORTED_SEARCH_BY_CATEGORY,
            &categories,
        );
        assert_eq!(
            categories.calls, 0,
            "category methods must never call the script"
        );

        let all = run("getAllCategories", state, true, false);
        report(
            "getAllCategories",
            label,
            UNSUPPORTED_GET_ALL_CATEGORIES,
            &all,
        );
        assert_eq!(all.calls, 0, "category methods must never call the script");
    }
}

#[test]
fn parity_check_app_update_script_then_store() {
    for (label, state) in STATES {
        let expected = if matches!(state, State::Success) {
            "script.only/3.0/script.only"
        } else {
            "store.only/none/store.only"
        };
        let hit = run("checkAppUpdate", state, true, false);
        report(
            "checkAppUpdate",
            &format!("{label}/store-hit"),
            expected,
            &hit,
        );

        let miss = run("checkAppUpdate", state, false, false);
        let expected = if matches!(state, State::Success) {
            "script.only/3.0/script.only"
        } else {
            MISSING_UPDATE
        };
        report(
            "checkAppUpdate",
            &format!("{label}/store-miss"),
            expected,
            &miss,
        );
    }
}

#[test]
fn parity_check_update_defaults_to_false() {
    for (label, state) in STATES {
        let expected = if matches!(state, State::Success) {
            "true"
        } else {
            "false"
        };
        let result = run("checkUpdate", state, true, false);
        report("checkUpdate", label, expected, &result);
    }
}

#[test]
fn parity_without_store_lists_nothing_and_rejects_writes() {
    let apps = run_without_store("getAllApps", State::Success, false);
    report("getAllApps", "no-store", "", &apps);

    let info = run_without_store("getAppInfo", State::Success, true);
    report("getAppInfo", "no-store/success", "script.only", &info);

    let missing = run_without_store("getAppInfo", State::Null, true);
    report("getAppInfo", "no-store/null", MISSING_APP, &missing);

    let add = run_without_store("addApp", State::Null, false);
    report("addApp", "no-store", MISSING_STORE, &add);

    let remove = run_without_store("removeApp", State::Null, false);
    report("removeApp", "no-store", MISSING_STORE, &remove);
}
