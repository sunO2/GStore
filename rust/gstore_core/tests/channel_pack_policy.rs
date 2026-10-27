//! Local-pack decode policy: strict by default, explicit legacy tolerance.
//!
//! The legacy policy mirrors the old Dart `ChannelPackage.decode` so historical
//! local packs keep loading, while every tolerance names the pack key and the
//! reason in a `log::warn!`. Safety bounds (paths, entry count, sizes) still
//! apply to both policies.

use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, Once};

use gstore_core::channel::{PackLimits, PackPolicy, PackStore};
use gstore_core::db::DbHandle;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);
static LOGS: Mutex<Vec<String>> = Mutex::new(Vec::new());
static LOG_GUARD: Mutex<()> = Mutex::new(());

struct CaptureLogger;

impl log::Log for CaptureLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.level() <= log::Level::Warn
    }

    fn log(&self, record: &log::Record<'_>) {
        LOGS.lock()
            .expect("log lock")
            .push(format!("{}: {}", record.level(), record.args()));
    }

    fn flush(&self) {}
}

static LOGGER: CaptureLogger = CaptureLogger;

fn locked() -> MutexGuard<'static, ()> {
    let guard = LOG_GUARD.lock().unwrap_or_else(|error| error.into_inner());
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let _ = log::set_logger(&LOGGER);
        log::set_max_level(log::LevelFilter::Warn);
    });
    LOGS.lock().expect("log lock").clear();
    guard
}

fn logs() -> String {
    LOGS.lock().expect("log lock").join("\n")
}

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_pack_policy_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("temp dir");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn store(root: &Path, db: &DbHandle, policy: PackPolicy) -> PackStore {
    PackStore::new(root, db.clone()).with_policy(policy)
}

fn write_pack(path: &Path, entries: &[(&str, &[u8])], directory: Option<&str>) {
    let mut cursor = Cursor::new(Vec::new());
    {
        let mut writer = ZipWriter::new(&mut cursor);
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .unix_permissions(0o644);
        if let Some(name) = directory {
            writer
                .add_directory(name, options)
                .expect("directory entry");
        }
        for (name, data) in entries {
            writer.start_file(*name, options).expect("zip entry");
            writer.write_all(data).expect("zip write");
        }
        writer.finish().expect("finish zip");
    }
    std::fs::write(path, cursor.into_inner()).expect("write zip");
}

fn db(dir: &TempDir) -> DbHandle {
    DbHandle::open(&dir.path().join("data")).expect("open core db")
}

#[test]
fn pack_policy_default_is_strict_and_rejects_unknown_entries() {
    let _guard = locked();
    let dir = TempDir::new("strict");
    let packs = PackStore::new(dir.path().join("packs"), db(&dir));
    assert_eq!(packs.policy(), PackPolicy::Strict);

    let zip = dir.path().join("strict.zip");
    write_pack(
        &zip,
        &[("entry.js", b"// ok\n"), ("notes.txt", b"ignored by Dart")],
        None,
    );
    let error = packs.import_pack(&zip).expect_err("strict rejects layout");
    assert_eq!(error.code(), "pack_layout", "{error}");
    println!("strict default: {error}");
}

#[test]
fn pack_policy_legacy_loads_dart_permissive_pack_with_warnings() {
    let _guard = locked();
    let dir = TempDir::new("legacy");
    let packs = store(
        &dir.path().join("packs"),
        &db(&dir),
        PackPolicy::LegacyPermissive,
    );

    let zip = dir.path().join("legacy.zip");
    write_pack(
        &zip,
        &[
            ("entry.js", b""),
            ("detail.js", &[0xff, 0xfe]),
            ("notes.txt", b"old root file"),
            ("meta.json", b"{not json"),
        ],
        Some("docs/"),
    );

    let installed = packs.import_pack(&zip).expect("legacy pack loads");
    assert_eq!(installed.key.as_str(), "js_legacy");
    assert!(installed.pack.entry_js.is_empty());
    assert!(
        installed
            .pack
            .detail_js
            .as_deref()
            .is_some_and(|text| text.contains('\u{FFFD}')),
        "lossy decode expected: {:?}",
        installed.pack.detail_js
    );
    assert!(installed.pack.meta_json.is_empty(), "invalid meta ignored");

    let warnings = logs();
    for expected in [
        "js_legacy",
        "skipping directory",
        "ignoring unknown entry",
        "entry.js is empty",
        "not valid UTF-8",
        "meta.json is not a JSON object",
    ] {
        assert!(
            warnings.contains(expected),
            "missing {expected:?} in warnings:\n{warnings}"
        );
    }
    println!("legacy warnings:\n{warnings}");
}

#[test]
fn pack_policy_legacy_still_enforces_size_limits() {
    let _guard = locked();
    let dir = TempDir::new("limit");
    let packs = store(
        &dir.path().join("packs"),
        &db(&dir),
        PackPolicy::LegacyPermissive,
    )
    .with_limits(PackLimits {
        max_entries: 16,
        max_entry_bytes: 1024,
        max_total_bytes: 4096,
        max_pack_bytes: 1024 * 1024,
    });

    let zip = dir.path().join("big.zip");
    let big = vec![0x41u8; 4096];
    write_pack(
        &zip,
        &[("entry.js", b"// ok\n"), ("icons/big.bin", &big)],
        None,
    );
    let error = packs.import_pack(&zip).expect_err("size limit applies");
    assert_eq!(error.code(), "pack_too_large", "{error}");
    println!("legacy size limit: {error}");
}
