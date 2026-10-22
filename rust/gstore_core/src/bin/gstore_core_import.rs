//! Manual import harness for the live/seed catalog.
//!
//! ```text
//! gstore_core_import --db <core.db> --seed <apps.db> [--live <apps.db>] [--dry-run]
//! ```
//!
//! Prints the [`CatalogImportReport`] as pretty JSON on success (exit 0) and the
//! typed error on stderr (exit 2).

use std::path::PathBuf;
use std::process::ExitCode;

use gstore_core::catalog::import::{import_catalog, CatalogImportOptions, CatalogImportReport};
use gstore_core::db::DbHandle;
use gstore_core::error::Error;

const USAGE: &str = "usage: gstore_core_import --db <core.db> --seed <apps.db> \
                     [--live <apps.db>] [--dry-run]";

struct Args {
    db: PathBuf,
    seed: PathBuf,
    live: Option<PathBuf>,
    dry_run: bool,
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("gstore_core_import: {error}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<(), Error> {
    let args = parse_args()?;
    let handle = DbHandle::open_at(&args.db).map_err(|e| {
        Error::Io(format!(
            "CORE_E_CATALOG_DB: open {}: {e}",
            args.db.display()
        ))
    })?;
    let report = import_catalog(
        &handle,
        args.live.as_deref(),
        &args.seed,
        &CatalogImportOptions {
            dry_run: args.dry_run,
        },
    )?;
    print_report(&report)
}

fn print_report(report: &CatalogImportReport) -> Result<(), Error> {
    let json = serde_json::to_string_pretty(report)?;
    println!("{json}");
    Ok(())
}

fn parse_args() -> Result<Args, Error> {
    let mut db = None;
    let mut seed = None;
    let mut live = None;
    let mut dry_run = false;
    let mut args = std::env::args().skip(1);

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--db" => db = Some(PathBuf::from(next_value(&mut args, "--db")?)),
            "--seed" => seed = Some(PathBuf::from(next_value(&mut args, "--seed")?)),
            "--live" => live = Some(PathBuf::from(next_value(&mut args, "--live")?)),
            "--dry-run" => dry_run = true,
            other => {
                return Err(Error::InvalidArgument(format!(
                    "{USAGE}: unknown argument {other}"
                )))
            }
        }
    }

    Ok(Args {
        db: db.ok_or_else(|| Error::InvalidArgument(format!("{USAGE}: --db is required")))?,
        seed: seed.ok_or_else(|| Error::InvalidArgument(format!("{USAGE}: --seed is required")))?,
        live,
        dry_run,
    })
}

fn next_value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, Error> {
    args.next()
        .ok_or_else(|| Error::InvalidArgument(format!("{USAGE}: {flag} requires a value")))
}
