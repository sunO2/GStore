//! Todo 9: local channel-pack import contract.
//!
//! Test names carry the `pack_import_legacy` prefix so the plan's QA command
//! (`cargo test ... pack_import_legacy`) selects the whole file.
//!
//! The tests print the real stored hash, `channel_packs` row, and extracted
//! bytes so a green run cannot hide a misleading success. Every fixture lives
//! under a private temp directory and is removed on drop.

use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::channel::{PackLimits, PackStore};
use gstore_core::db::DbHandle;
use sha2::{Digest, Sha256};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_pack_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
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

struct ZipEntry<'a> {
    name: &'a str,
    data: &'a [u8],
}

fn zip_bytes(entries: &[ZipEntry<'_>]) -> Vec<u8> {
    let mut cursor = Cursor::new(Vec::new());
    {
        let mut writer = ZipWriter::new(&mut cursor);
        for entry in entries {
            let options = SimpleFileOptions::default()
                .compression_method(CompressionMethod::Deflated)
                .unix_permissions(0o644);
            writer.start_file(entry.name, options).unwrap();
            writer.write_all(entry.data).unwrap();
        }
        writer.finish().unwrap();
    }
    cursor.into_inner()
}

fn write_zip(path: &Path, entries: &[ZipEntry<'_>]) -> Vec<u8> {
    let bytes = zip_bytes(entries);
    std::fs::write(path, &bytes).unwrap();
    bytes
}

/// Rewrites the central-directory Unix mode for one entry.
///
/// `SimpleFileOptions::unix_permissions` masks the file-type bits, so symlink
/// and other special-file entries have to be produced by patching the central
/// directory header (`version made by` = Unix, `external attributes` =
/// `mode << 16`). This is exactly what an attacker-crafted zip can contain.
fn patch_central_unix_mode(zip: &mut [u8], name: &str, mode: u32) {
    let mut offset = 0usize;
    while offset + 46 <= zip.len() {
        if &zip[offset..offset + 4] == b"PK\x01\x02" {
            let name_len = u16::from_le_bytes([zip[offset + 28], zip[offset + 29]]) as usize;
            let extra_len = u16::from_le_bytes([zip[offset + 30], zip[offset + 31]]) as usize;
            let comment_len = u16::from_le_bytes([zip[offset + 32], zip[offset + 33]]) as usize;
            let name_start = offset + 46;
            if name_start + name_len <= zip.len()
                && &zip[name_start..name_start + name_len] == name.as_bytes()
            {
                // version made by: low byte = spec version, high byte = Unix (3)
                zip[offset + 4] = 20;
                zip[offset + 5] = 3;
                let attrs = mode << 16;
                zip[offset + 38..offset + 42].copy_from_slice(&attrs.to_le_bytes());
                return;
            }
            offset += 46 + name_len + extra_len + comment_len;
        } else {
            offset += 1;
        }
    }
    panic!("entry {name:?} not found in zip central directory");
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

fn store(root: &Path, db: &DbHandle) -> PackStore {
    PackStore::new(root, db.clone())
}

fn clock(start: i64) -> (Arc<AtomicI64>, impl Fn() -> i64 + Send + Sync + 'static) {
    let value = Arc::new(AtomicI64::new(start));
    let handle = Arc::clone(&value);
    (value, move || handle.fetch_add(1000, Ordering::SeqCst))
}

fn row(store: &PackStore, key: &str) -> (String, String, i64) {
    store
        .db()
        .with_reader(|conn| {
            let count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM channel_packs WHERE key=?1",
                    [key],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(count, 1, "expected exactly one channel_packs row for {key}");
            conn.query_row(
                "SELECT pack_hash, meta_json, installed_at FROM channel_packs WHERE key=?1",
                [key],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .map_err(|e| gstore_core::db::DbError(e.to_string()))
        })
        .unwrap()
}

fn temp_entries(root: &Path) -> Vec<String> {
    let mut found = Vec::new();
    if let Ok(entries) = std::fs::read_dir(root) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with(".tmp-") {
                found.push(name);
            }
        }
    }
    found.sort();
    found
}

#[test]
fn pack_import_legacy_happy_preserves_bytes_and_row() {
    let dir = TempDir::new("happy");
    let db = DbHandle::open(&dir.path().join("data")).unwrap();
    let (_clock, now) = clock(1_700_000_000_000);
    let packs = PackStore::with_clock(dir.path().join("packs"), db.clone(), now);

    let entry = b"// entry.js\nfunction main() { return 'legacy'; }\n".to_vec();
    let detail = b"// detail.js\nfunction detail() { return 42; }\n".to_vec();
    let meta = b"{\n  \"name\": \"Alpha\",\n  \"description\": \"legacy pack\",\n  \"icon\": \"icons/alpha.png\",\n  \"requiredEnvVars\": [\"ALPHA_TOKEN\", \"ALPHA_REGION\"]\n}\n".to_vec();
    let alpha_icon = vec![0u8, 1, 2, 3, 255, 254, 128, 127];
    let nested_icon = b"\x89PNG\r\n\x1a\nnested".to_vec();

    let zip_path = dir.path().join("alpha.zip");
    let zip = write_zip(
        &zip_path,
        &[
            ZipEntry {
                name: "entry.js",
                data: &entry,
            },
            ZipEntry {
                name: "detail.js",
                data: &detail,
            },
            ZipEntry {
                name: "meta.json",
                data: &meta,
            },
            ZipEntry {
                name: "icons/alpha.png",
                data: &alpha_icon,
            },
            ZipEntry {
                name: "icons/sub/nested.bin",
                data: &nested_icon,
            },
        ],
    );

    let installed = packs.import_pack(&zip_path).expect("legacy pack imports");

    assert_eq!(installed.key.as_str(), "js_alpha");
    assert_eq!(
        installed.pack.entry_js,
        String::from_utf8(entry.clone()).unwrap()
    );
    assert_eq!(
        installed.pack.detail_js.as_deref(),
        Some(String::from_utf8(detail.clone()).unwrap().as_str())
    );
    assert_eq!(
        installed.pack.required_env_vars,
        vec!["ALPHA_TOKEN".to_string(), "ALPHA_REGION".to_string()]
    );
    assert_eq!(
        installed.pack.icon("icons/alpha.png"),
        Some(&gstore_core::channel::PackIconSource::Bytes(
            alpha_icon.clone()
        ))
    );

    assert_eq!(
        std::fs::read(installed.dir.join("entry.js")).unwrap(),
        entry
    );
    assert_eq!(
        std::fs::read(installed.dir.join("detail.js")).unwrap(),
        detail
    );
    assert_eq!(
        std::fs::read(installed.dir.join("meta.json")).unwrap(),
        meta
    );
    assert_eq!(
        std::fs::read(installed.dir.join("icons/alpha.png")).unwrap(),
        alpha_icon
    );
    assert_eq!(
        std::fs::read(installed.dir.join("icons/sub/nested.bin")).unwrap(),
        nested_icon
    );

    let expected_hash = sha256_hex(&zip);
    assert_eq!(installed.pack_hash.len(), 64);
    assert!(installed.pack_hash.chars().all(|c| c.is_ascii_hexdigit()));
    assert_eq!(installed.pack_hash, expected_hash);

    let (hash, meta_json, installed_at) = row(&packs, "js_alpha");
    assert_eq!(hash, expected_hash);
    assert_eq!(meta_json, String::from_utf8(meta.clone()).unwrap());
    assert_eq!(installed_at, 1_700_000_000_000);
    assert_eq!(installed.installed_at, installed_at);
    assert!(temp_entries(packs.root()).is_empty());

    println!(
        "happy: key={} hash={} installed_at={} dir={}",
        installed.key,
        installed.pack_hash,
        installed_at,
        installed.dir.display()
    );
    println!(
        "row: hash={} meta_bytes={} requiredEnvVars={:?}",
        hash,
        meta_json.len(),
        installed.pack.required_env_vars
    );
    println!(
        "bytes: entry={} detail={} icon={} nested={}",
        entry.len(),
        detail.len(),
        alpha_icon.len(),
        nested_icon.len()
    );
}

#[test]
fn pack_import_legacy_reimport_updates_single_row_and_prunes_old() {
    let dir = TempDir::new("reimport");
    let db = DbHandle::open(&dir.path().join("data")).unwrap();
    let (tick, now) = clock(1_000);
    let packs = PackStore::with_clock(dir.path().join("packs"), db.clone(), now);
    let zip_path = dir.path().join("alpha.zip");

    let v1 = write_zip(
        &zip_path,
        &[ZipEntry {
            name: "entry.js",
            data: b"// v1\n",
        }],
    );
    let first = packs.import_pack(&zip_path).unwrap();
    let first_hash = sha256_hex(&v1);
    assert_eq!(first.pack_hash, first_hash);

    let v2 = write_zip(
        &zip_path,
        &[
            ZipEntry {
                name: "entry.js",
                data: b"// v2 changed\n",
            },
            ZipEntry {
                name: "meta.json",
                data: b"{\"name\":\"Alpha v2\"}",
            },
        ],
    );
    let second = packs.import_pack(&zip_path).unwrap();
    let second_hash = sha256_hex(&v2);
    assert_ne!(first_hash, second_hash);
    assert_eq!(first.key, second.key);
    assert_eq!(second.pack_hash, second_hash);
    assert_ne!(first.dir, second.dir);
    assert!(!first.dir.exists(), "old version dir must be pruned");
    assert!(second.dir.exists());

    let (hash, meta_json, installed_at) = row(&packs, "js_alpha");
    assert_eq!(hash, second_hash);
    assert_eq!(meta_json, "{\"name\":\"Alpha v2\"}");
    assert_eq!(installed_at, tick.load(Ordering::SeqCst) - 1000);
    assert_eq!(
        std::fs::read(second.dir.join("entry.js")).unwrap(),
        b"// v2 changed\n"
    );

    let versions: Vec<String> = std::fs::read_dir(packs.root().join("js_alpha"))
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    assert_eq!(
        versions.len(),
        1,
        "only one installed version expected: {versions:?}"
    );

    println!(
        "reimport: key={} v1={} v2={} rows=1 installed_at={} versions={versions:?}",
        second.key, first_hash, second_hash, installed_at
    );
}

#[test]
fn pack_import_legacy_tolerates_v2_metadata_without_trust_surface() {
    let dir = TempDir::new("v2");
    let db = DbHandle::open(&dir.path().join("data")).unwrap();
    let packs = store(&dir.path().join("packs"), &db);
    let zip_path = dir.path().join("v2pack.zip");
    let meta = b"{\"schemaVersion\":2,\"name\":\"V2 Pack\",\"publisher\":{\"name\":\"example\"},\"capabilities\":[\"search\",\"detail\"],\"requiredEnvVars\":[\"V2_KEY\"],\"extra\":{\"nested\":[1,2,3]}}";
    write_zip(
        &zip_path,
        &[
            ZipEntry {
                name: "entry.js",
                data: b"// v2 entry\n",
            },
            ZipEntry {
                name: "meta.json",
                data: meta,
            },
        ],
    );

    let installed = packs.import_pack(&zip_path).expect("v2 metadata tolerated");
    assert_eq!(installed.key.as_str(), "js_v2pack");
    assert_eq!(installed.pack.required_env_vars, vec!["V2_KEY".to_string()]);
    assert_eq!(
        installed.pack.meta_json.get("schemaVersion"),
        Some(&serde_json::json!(2))
    );
    assert_eq!(
        installed.pack.meta_json.get("capabilities"),
        Some(&serde_json::json!(["search", "detail"]))
    );
    assert_eq!(
        installed.pack.meta_json.get("publisher"),
        Some(&serde_json::json!({"name": "example"}))
    );

    let (hash, meta_json, _) = row(&packs, "js_v2pack");
    assert_eq!(meta_json, String::from_utf8(meta.to_vec()).unwrap());
    println!(
        "v2: key={} hash={} meta_keys={:?} required={:?} (no signature/trust field in ChannelPack)",
        installed.key,
        hash,
        installed.pack.meta_json.keys().collect::<Vec<_>>(),
        installed.pack.required_env_vars
    );
}

#[test]
fn pack_import_legacy_rejects_unsafe_entries() {
    let dir = TempDir::new("unsafe");
    let db = DbHandle::open(&dir.path().join("data")).unwrap();
    let packs = store(&dir.path().join("packs"), &db);
    let zip_path = dir.path().join("evil.zip");

    let unsafe_names = [
        "../evil.js",
        "/absolute/entry.js",
        "\\absolute\\entry.js",
        "icons\\..\\evil.js",
        "icons/../../evil.js",
        "C:/evil.js",
        "C:\\evil.js",
        "//server/share/entry.js",
        "entry.js/../../evil.js",
        "icons/..",
    ];
    for name in unsafe_names {
        write_zip(
            &zip_path,
            &[
                ZipEntry {
                    name: "entry.js",
                    data: b"// ok\n",
                },
                ZipEntry {
                    name,
                    data: b"attack",
                },
            ],
        );
        let error = packs
            .import_pack(&zip_path)
            .expect_err(&format!("unsafe entry {name:?} must be rejected"));
        assert_eq!(
            error.code(),
            "pack_unsafe_entry",
            "unexpected code for {name:?}: {error}"
        );
        assert!(
            !packs.root().join("js_evil").exists(),
            "no key dir after rejected {name:?}"
        );
        assert!(temp_entries(packs.root()).is_empty());
        println!("rejected unsafe entry {name:?}: {error}");
    }

    // Symlink entry (Unix S_IFLNK in the central directory).
    let mut symlink_zip = zip_bytes(&[
        ZipEntry {
            name: "entry.js",
            data: b"// ok\n",
        },
        ZipEntry {
            name: "icons/link",
            data: b"../../entry.js",
        },
    ]);
    patch_central_unix_mode(&mut symlink_zip, "icons/link", 0o120777);
    std::fs::write(&zip_path, &symlink_zip).unwrap();
    let error = packs.import_pack(&zip_path).expect_err("symlink rejected");
    assert_eq!(error.code(), "pack_unsafe_entry", "{error}");
    println!("rejected symlink entry: {error}");

    // Non-regular special file (the zip format has no separate hardlink type;
    // any non-regular type is rejected structurally).
    let mut fifo_zip = zip_bytes(&[
        ZipEntry {
            name: "entry.js",
            data: b"// ok\n",
        },
        ZipEntry {
            name: "icons/fifo",
            data: b"",
        },
    ]);
    patch_central_unix_mode(&mut fifo_zip, "icons/fifo", 0o010644);
    std::fs::write(&zip_path, &fifo_zip).unwrap();
    let error = packs
        .import_pack(&zip_path)
        .expect_err("special file rejected");
    assert_eq!(error.code(), "pack_unsafe_entry", "{error}");
    println!("rejected non-regular entry: {error}");

    assert!(temp_entries(packs.root()).is_empty());
}

#[test]
fn pack_import_legacy_rejects_corrupt_and_truncated_zip() {
    let dir = TempDir::new("corrupt");
    let db = DbHandle::open(&dir.path().join("data")).unwrap();
    let packs = store(&dir.path().join("packs"), &db);
    let zip_path = dir.path().join("broken.zip");

    for (label, bytes) in [
        ("empty", Vec::new()),
        ("random", b"this is definitely not a zip file".to_vec()),
    ] {
        std::fs::write(&zip_path, &bytes).unwrap();
        let error = packs
            .import_pack(&zip_path)
            .expect_err(&format!("{label} bytes rejected"));
        assert_eq!(error.code(), "pack_not_zip", "{label}: {error}");
        println!("rejected {label} zip: {error}");
    }

    let whole = zip_bytes(&[
        ZipEntry {
            name: "entry.js",
            data: b"// ok\n",
        },
        ZipEntry {
            name: "icons/large.bin",
            data: &[7u8; 4096],
        },
    ]);
    let truncated = whole[..whole.len() / 2].to_vec();
    std::fs::write(&zip_path, &truncated).unwrap();
    let error = packs
        .import_pack(&zip_path)
        .expect_err("truncated zip rejected");
    assert_eq!(error.code(), "pack_corrupt", "{error}");
    println!(
        "rejected truncated zip ({} bytes): {error}",
        truncated.len()
    );

    assert!(temp_entries(packs.root()).is_empty());
}

#[test]
fn pack_import_legacy_rejects_missing_entry_and_invalid_meta_and_layout() {
    let dir = TempDir::new("invalid");
    let db = DbHandle::open(&dir.path().join("data")).unwrap();
    let packs = store(&dir.path().join("packs"), &db);
    let zip_path = dir.path().join("bad.zip");

    write_zip(
        &zip_path,
        &[ZipEntry {
            name: "meta.json",
            data: b"{\"name\":\"no entry\"}",
        }],
    );
    let error = packs.import_pack(&zip_path).expect_err("missing entry.js");
    assert_eq!(error.code(), "pack_missing_entry", "{error}");
    println!("missing entry.js: {error}");

    write_zip(
        &zip_path,
        &[ZipEntry {
            name: "entry.js",
            data: b"   \n\t",
        }],
    );
    let error = packs.import_pack(&zip_path).expect_err("empty entry.js");
    assert_eq!(error.code(), "pack_missing_entry", "{error}");
    println!("empty entry.js: {error}");

    for bad_meta in ["{not json", "[]", "{\"requiredEnvVars\":\"nope\"}"] {
        write_zip(
            &zip_path,
            &[
                ZipEntry {
                    name: "entry.js",
                    data: b"// ok\n",
                },
                ZipEntry {
                    name: "meta.json",
                    data: bad_meta.as_bytes(),
                },
            ],
        );
        let error = packs
            .import_pack(&zip_path)
            .expect_err("invalid meta rejected");
        assert_eq!(error.code(), "pack_invalid_meta", "{bad_meta:?}: {error}");
        println!("invalid meta {bad_meta:?}: {error}");
    }

    for unexpected in ["sub/script.js", "README.md", "nested/entry.js"] {
        write_zip(
            &zip_path,
            &[
                ZipEntry {
                    name: "entry.js",
                    data: b"// ok\n",
                },
                ZipEntry {
                    name: unexpected,
                    data: b"x",
                },
            ],
        );
        let error = packs.import_pack(&zip_path).expect_err("unexpected layout");
        assert_eq!(error.code(), "pack_layout", "{unexpected:?}: {error}");
        println!("unexpected layout {unexpected:?}: {error}");
    }

    assert!(temp_entries(packs.root()).is_empty());
}

#[test]
fn pack_import_legacy_rejects_oversized_entry() {
    let dir = TempDir::new("huge");
    let db = DbHandle::open(&dir.path().join("data")).unwrap();
    let packs = store(&dir.path().join("packs"), &db).with_limits(PackLimits {
        max_entries: 16,
        max_entry_bytes: 1024,
        max_total_bytes: 4096,
        max_pack_bytes: 1024 * 1024,
    });
    let zip_path = dir.path().join("huge.zip");
    let big = vec![0x41u8; 4096];
    write_zip(
        &zip_path,
        &[
            ZipEntry {
                name: "entry.js",
                data: b"// ok\n",
            },
            ZipEntry {
                name: "icons/big.bin",
                data: &big,
            },
        ],
    );

    let error = packs
        .import_pack(&zip_path)
        .expect_err("oversized entry rejected");
    assert_eq!(error.code(), "pack_too_large", "{error}");
    assert!(!packs.root().join("js_huge").exists());
    assert!(temp_entries(packs.root()).is_empty());
    println!("oversized entry: {error} (entry bytes={})", big.len());
}

#[test]
fn pack_import_legacy_rollback_mid_install_keeps_prior_pack() {
    let dir = TempDir::new("rollback");
    let db = DbHandle::open(&dir.path().join("data")).unwrap();
    let (_tick, now) = clock(5_000);
    let packs = PackStore::with_clock(dir.path().join("packs"), db.clone(), now);
    let zip_path = dir.path().join("alpha.zip");
    let v1_entry = b"// v1 remains intact\n".to_vec();
    let v1_zip = write_zip(
        &zip_path,
        &[
            ZipEntry {
                name: "entry.js",
                data: &v1_entry,
            },
            ZipEntry {
                name: "meta.json",
                data: b"{\"name\":\"v1\"}",
            },
        ],
    );
    let prior = packs.import_pack(&zip_path).unwrap();
    let prior_hash = sha256_hex(&v1_zip);
    let (prior_row_hash, prior_meta, prior_at) = row(&packs, "js_alpha");
    assert_eq!(prior_row_hash, prior_hash);

    // This zip passes structural validation but fails while materialising:
    // `icons/a` is written as a file, then `icons/a/b` needs `icons/a` to be a
    // directory. The failure happens after the temp dir exists and after the
    // first new file was written, i.e. genuinely mid-install.
    write_zip(
        &zip_path,
        &[
            ZipEntry {
                name: "entry.js",
                data: b"// v2 partial\n",
            },
            ZipEntry {
                name: "icons/a",
                data: b"a",
            },
            ZipEntry {
                name: "icons/a/b",
                data: b"b",
            },
        ],
    );

    let error = packs
        .import_pack(&zip_path)
        .expect_err("mid-install failure must roll back");
    assert_eq!(error.code(), "io", "{error}");
    println!("mid-install failure: {error}");

    assert!(prior.dir.join("entry.js").exists());
    assert_eq!(
        std::fs::read(prior.dir.join("entry.js")).unwrap(),
        v1_entry,
        "previous pack bytes must remain intact"
    );
    let (after_hash, after_meta, after_at) = row(&packs, "js_alpha");
    assert_eq!(after_hash, prior_row_hash);
    assert_eq!(after_meta, prior_meta);
    assert_eq!(after_at, prior_at);
    assert!(temp_entries(packs.root()).is_empty(), "no orphan temp dirs");
    let versions: Vec<String> = std::fs::read_dir(packs.root().join("js_alpha"))
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    assert_eq!(versions.len(), 1, "no partial new version: {versions:?}");

    println!(
        "rollback: retained_hash={} installed_at={} versions={versions:?} temp_dirs={:?}",
        after_hash,
        after_at,
        temp_entries(packs.root())
    );
}
