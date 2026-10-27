//! Shared ladder for the Dart-parity table: one channel per (method, state).

use gstore_core::channel::{ChannelDriver, ScriptChannel};
use gstore_core::dto::{AppSummary, ChannelKey};
use gstore_core::ScriptChannelConfig;

use super::{fake_host, memory_store, sample_app, HostCall, SharedHost};

pub const KEY: &str = "js.parity";

#[derive(Clone, Copy)]
pub enum State {
    Success,
    Null,
    OkFalse,
    Throw,
    SearchFallback,
    DoUpdateFallback,
    NonList,
    NonBool,
}

const LOG: &str = "host.log.info('call:' + method);";

pub fn script(state: State) -> String {
    let body = match state {
        State::Success => SUCCESS,
        State::Null => "return null;",
        State::OkFalse => "return { ok: false, error: 'boom' };",
        State::Throw => "throw new Error('kaboom');",
        State::SearchFallback => SEARCH_FALLBACK,
        State::DoUpdateFallback => DO_UPDATE_FALLBACK,
        State::NonList => NON_LIST,
        State::NonBool => NON_BOOL,
    };
    format!("async function main(method, params) {{ {LOG} {body} }}")
}

const SUCCESS: &str = r#"
  switch (method) {
    case 'getAllApps': return { ok: true, data: [ROW_DOLPHIN, ROW_OTHER] };
    case 'searchApps': return { ok: true, data: [ROW_SCRIPT] };
    case 'getAppInfo': return { ok: true, data: ROW_SCRIPT };
    case 'getAppDetail': return { ok: true, data: DETAIL };
    case 'checkAppUpdate': return { ok: true, data: UPDATE };
    case 'checkUpdate': return { ok: true, data: true };
    case 'doUpdate': return { ok: true, data: true };
    case 'getConfig': return { ok: true, data: { version: '9', proxy: 'http://proxy' } };
    default: return null;
  }
"#;

const SEARCH_FALLBACK: &str = r#"
  if (method === 'searchApps') return null;
  if (method === 'getAllApps') return { ok: true, data: [ROW_DOLPHIN, ROW_OTHER] };
  return null;
"#;

const DO_UPDATE_FALLBACK: &str = r#"
  if (method === 'doUpdate') return null;
  if (method === 'getAllApps') return { ok: true, data: [ROW_DOLPHIN, ROW_OTHER] };
  return null;
"#;

const NON_LIST: &str = "return { ok: true, data: 'not-a-list' };";
const NON_BOOL: &str = r#"
  if (method === 'checkUpdate' || method === 'doUpdate') return { ok: true, data: 'yes' };
  if (method === 'getAllApps') return { ok: true, data: [ROW_DOLPHIN] };
  return null;
"#;

const ROWS: &str = r#"
const ROW_DOLPHIN = { appId: 'app.dolphin', name: 'Dolphin', des: 'flipper browser' };
const ROW_OTHER = { appId: 'app.other', name: 'Other', des: 'nothing here' };
const ROW_SCRIPT = { appId: 'script.only', name: 'Script Only', des: 'from script' };
const DETAIL = { appId: 'script.only', name: 'Script Only', version: '9.9', downloads: [] };
const UPDATE = { appId: 'script.only', name: 'Script Only', version: '3.0' };
"#;

pub struct Run {
    pub result: String,
    pub calls: usize,
    pub stored: Vec<String>,
    pub host: SharedHost,
}

pub fn run(method: &str, state: State, seed: bool, force: bool) -> Run {
    run_with(method, state, seed, force, true)
}

pub fn run_without_store(method: &str, state: State, force: bool) -> Run {
    run_with(method, state, false, force, false)
}

fn run_with(method: &str, state: State, seed: bool, force: bool, bound: bool) -> Run {
    let host = fake_host();
    let store = memory_store();
    if seed {
        store.seed(KEY, vec![sample_app("store.only", "Store Only")]);
    }
    let mut config = ScriptChannelConfig::new(
        ChannelKey::new(KEY).expect("key"),
        format!("{ROWS}\n{}", script(state)),
        host.clone(),
    );
    if bound {
        config = config.with_store(store.clone());
    }
    let channel = ScriptChannel::new(config).expect("channel");
    let result = execute(&channel, method, force);
    let calls = host
        .calls()
        .into_iter()
        .filter(|call| matches!(call, HostCall::Log { channel, message } if channel == KEY && message.starts_with("call:")))
        .count();
    let stored = store.rows(KEY).into_iter().map(|app| app.app_id).collect();
    channel.dispose().expect("dispose");
    Run {
        result,
        calls,
        stored,
        host,
    }
}

fn execute(channel: &ScriptChannel, method: &str, force: bool) -> String {
    let outcome: Result<String, String> = match method {
        "getAllApps" => channel.get_all_apps(force).map(ids).map_err(error_text),
        "getAppInfo" => channel
            .get_app_info("store.only", force)
            .map(|app| app.app_id)
            .map_err(error_text),
        "getAppDetail" => channel
            .get_app_detail("store.only", force)
            .map(|detail| detail.version.unwrap_or_else(|| "none".to_owned()))
            .map_err(error_text),
        "searchApps" => channel
            .search_apps("dolphin", force)
            .map(ids)
            .map_err(error_text),
        "searchByCategory" => channel
            .search_by_category("tools", force)
            .map(ids)
            .map_err(error_text),
        "getAllCategories" => channel
            .get_all_categories(force)
            .map(|rows| rows.len().to_string())
            .map_err(error_text),
        "checkAppUpdate" => channel
            .check_app_update("store.only")
            .map(update)
            .map_err(error_text),
        "checkUpdate" => channel
            .check_update()
            .map(|flag| flag.to_string())
            .map_err(error_text),
        "doUpdate" => channel
            .do_update(None)
            .map(|flag| flag.to_string())
            .map_err(error_text),
        "getConfig" => channel
            .get_config(force)
            .map(|config| match config {
                Some(config) => format!(
                    "{}|{}",
                    config.version,
                    config.proxy.unwrap_or_else(|| "none".to_owned())
                ),
                None => "none".to_owned(),
            })
            .map_err(error_text),
        "addApp" => channel
            .add_app(&sample_app("app.added", "Added"))
            .map(|()| "ok".to_owned())
            .map_err(error_text),
        "removeApp" => channel
            .remove_app("store.only")
            .map(|()| "ok".to_owned())
            .map_err(error_text),
        "clearCache" => channel
            .clear_cache()
            .map(|()| "ok".to_owned())
            .map_err(error_text),
        "getCacheSize" => channel
            .get_cache_size()
            .map(|size| size.to_string())
            .map_err(error_text),
        other => panic!("unknown parity method `{other}`"),
    };
    outcome.unwrap_or_else(|message| format!("err:{message}"))
}

fn ids(apps: Vec<AppSummary>) -> String {
    apps.into_iter()
        .map(|app| app.app_id)
        .collect::<Vec<_>>()
        .join(",")
}

fn update(update: gstore_core::AppUpdate) -> String {
    format!(
        "{}/{}/{}",
        update.app_id,
        update.latest_version.unwrap_or_else(|| "none".to_owned()),
        update.package_name
    )
}

fn error_text(error: gstore_core::Error) -> String {
    error.message().to_owned()
}

pub fn report(method: &str, state: &str, expected: &str, run: &Run) {
    let verdict = if run.result == expected {
        "PASS"
    } else {
        "FAIL"
    };
    println!(
        "{verdict} | {method:<18} | {state:<22} | expected={expected:<48} | rust={} | script_calls={}",
        run.result, run.calls
    );
    assert_eq!(run.result, expected, "{method} / {state}");
}
