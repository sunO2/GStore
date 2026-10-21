//! LocalDb parity harness (spike, todo 12).
//!
//! Reads a real SQLite fixture database with the same `apps` table shape as the
//! Floor `db.AppInfo` entity and writes canonical JSON for the Dart side to
//! compare against. Run through `scripts/qa/parity.sh`; the script is the gate.
//!
//! Fixture DB is built by `sqlite3 test/fixtures/parity/localdb.db <
//! test/fixtures/parity/localdb.sql`. FTS5 is deliberately not exercised: the
//! `searchApps` query mirrors the DAO LIKE fallback only.

use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use rusqlite::Connection;
use serde_json::{json, Value};

use gstore_core::download::port::status_label;

const APP_COLUMNS: &str = "appId, name, user, repositories, icon, des, readme, category, extra";

struct Args {
    db: PathBuf,
    out: PathBuf,
}

struct RawApp {
    app_id: String,
    name: String,
    user: String,
    repositories: String,
    icon: String,
    des: String,
    readme: Option<String>,
    category: Option<String>,
    extra: Option<String>,
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("gstore_core_parity: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let args = parse_args()?;
    let conn = Connection::open(&args.db)
        .map_err(|e| format!("open {}: {e}", args.db.display()))?;

    let all = query_apps(
        &conn,
        &format!("SELECT {APP_COLUMNS} FROM apps ORDER BY rowid"),
    )?;
    let mut seen = HashSet::new();
    let search = query_apps(
        &conn,
        &format!(
            "SELECT {APP_COLUMNS} FROM apps \
             WHERE name LIKE '%demo%' OR des LIKE '%demo%' ORDER BY rowid"
        ),
    )?
    .into_iter()
    .filter(|app| seen.insert(app.app_id.clone()))
    .collect::<Vec<_>>();

    let get_app_info = all.first().map_or(Value::Null, app_json);
    let download_lifecycle = [0_i64, 2, 4]
        .into_iter()
        .map(|code| Value::String(status_label(code).to_string()))
        .collect::<Vec<_>>();

    let document = json!({
        "getAllApps": all.iter().map(app_json).collect::<Vec<_>>(),
        "searchApps": search.iter().map(app_json).collect::<Vec<_>>(),
        "getAppInfo": get_app_info,
        "getAppInfoMissing": Value::Null,
        "downloadLifecycle": download_lifecycle,
    });

    if let Some(parent) = args.out.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    let bytes = serde_json::to_vec_pretty(&document)
        .map_err(|e| format!("serialize parity json: {e}"))?;
    fs::write(&args.out, bytes)
        .map_err(|e| format!("write {}: {e}", args.out.display()))?;
    Ok(())
}

fn parse_args() -> Result<Args, String> {
    let mut db = None;
    let mut out = None;
    let mut iter = env::args().skip(1);
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--db" => db = Some(iter.next().ok_or("--db requires a path")?),
            "--out" => out = Some(iter.next().ok_or("--out requires a path")?),
            "--help" | "-h" => {
                return Err("usage: gstore_core_parity --db <path> --out <path>".to_string())
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(Args {
        db: Path::new(&db.ok_or("missing --db <path>")?).to_path_buf(),
        out: Path::new(&out.ok_or("missing --out <path>")?).to_path_buf(),
    })
}

fn query_apps(conn: &Connection, sql: &str) -> Result<Vec<RawApp>, String> {
    let mut stmt = conn.prepare(sql).map_err(|e| format!("prepare: {e}"))?;
    let rows = stmt
        .query_map([], |row| {
            Ok(RawApp {
                app_id: row.get(0)?,
                name: row.get(1)?,
                user: row.get(2)?,
                repositories: row.get(3)?,
                icon: row.get(4)?,
                des: row.get(5)?,
                readme: row.get(6)?,
                category: row.get(7)?,
                extra: row.get(8)?,
            })
        })
        .map_err(|e| format!("query: {e}"))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("read rows: {e}"))
}

fn app_json(app: &RawApp) -> Value {
    let category = app
        .category
        .as_deref()
        .and_then(|text| serde_json::from_str::<Value>(text).ok())
        .filter(Value::is_array);
    let extra = app
        .extra
        .as_deref()
        .and_then(|text| serde_json::from_str::<Value>(text).ok())
        .filter(Value::is_object);
    let package_name = extra
        .as_ref()
        .and_then(|value| value.get("packageName"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);

    json!({
        "appId": app.app_id.clone(),
        "packageName": package_name,
        "name": app.name.clone(),
        "user": app.user.clone(),
        "repositories": app.repositories.clone(),
        "icon": app.icon.clone(),
        "des": app.des.clone(),
        "readme": app.readme.clone(),
        "category": category,
        "extra": extra,
    })
}
