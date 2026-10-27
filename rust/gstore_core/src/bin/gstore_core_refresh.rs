//! Manual catalog refresh harness.
//!
//! ```text
//! gstore_core_refresh --db <core.db> --source <apps.db> [--allow-empty] [--json]
//! ```
//!
//! Replaces the catalog rows from an already-downloaded SQLite source using the
//! same validate/backup/transaction path as the network refresh. Prints the
//! [`CatalogRefreshReport`] as JSON on success (exit 0) and the typed error on
//! stderr (exit 2).

use std::path::PathBuf;
use std::process::ExitCode;

use gstore_core::catalog::refresh::{
    replace_catalog_from_db_with_options, CatalogRefreshOptions, CatalogRefreshReport,
};
use gstore_core::db::DbHandle;
use gstore_core::error::Error;

const USAGE: &str = "usage: gstore_core_refresh --db <core.db> --source <apps.db> \
                     [--allow-empty] [--json]";

struct Args {
    db: PathBuf,
    source: PathBuf,
    allow_empty: bool,
    json: bool,
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("gstore_core_refresh: {error}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<(), Error> {
    let args = parse_args()?;
    let handle = DbHandle::open_at(&args.db).map_err(|e| {
        Error::Io(format!(
            "CORE_E_CATALOG_REFRESH_DB: open {}: {e}",
            args.db.display()
        ))
    })?;
    let options = CatalogRefreshOptions {
        allow_empty: args.allow_empty,
    };
    let report = replace_catalog_from_db_with_options(
        &handle,
        &args.source,
        &args.source.display().to_string(),
        &options,
    )?;
    print_report(&report, args.json)
}

fn print_report(report: &CatalogRefreshReport, compact: bool) -> Result<(), Error> {
    let json = if compact {
        serde_json::to_string(report)?
    } else {
        serde_json::to_string_pretty(report)?
    };
    println!("{json}");
    Ok(())
}

fn parse_args() -> Result<Args, Error> {
    let mut db = None;
    let mut source = None;
    let mut allow_empty = false;
    let mut json = false;
    let mut args = std::env::args().skip(1);

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--db" => db = Some(PathBuf::from(next_value(&mut args, "--db")?)),
            "--source" => source = Some(PathBuf::from(next_value(&mut args, "--source")?)),
            "--allow-empty" => allow_empty = true,
            "--json" => json = true,
            other => {
                return Err(Error::InvalidArgument(format!(
                    "{USAGE}: unknown argument {other}"
                )))
            }
        }
    }

    Ok(Args {
        db: db.ok_or_else(|| Error::InvalidArgument(format!("{USAGE}: --db is required")))?,
        source: source
            .ok_or_else(|| Error::InvalidArgument(format!("{USAGE}: --source is required")))?,
        allow_empty,
        json,
    })
}

fn next_value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, Error> {
    args.next()
        .ok_or_else(|| Error::InvalidArgument(format!("{USAGE}: {flag} requires a value")))
}
