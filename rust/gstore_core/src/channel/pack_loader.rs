//! Local channel-pack import: legacy flat zips, zip safety, and atomic install.
//!
//! A legacy pack is a zip with `entry.js` at the root, optional `detail.js`
//! and `meta.json`, and optional `icons/...` bytes. The channel key follows the
//! Dart loader: `js_<zip file stem>` (the stem must match
//! `^[a-zA-Z_][a-zA-Z0-9_]*$`).
//!
//! ## Safety model
//!
//! Path safety is structural: every entry name is split into path components
//! and rejected unless every component is a plain [`std::path::Component::Normal`].
//! Absolute paths, `..`, `.`, empty components, backslashes, drive letters /
//! `:` and Unix special-file modes (symlinks, FIFOs, devices, ...) are rejected
//! as [`PackError::UnsafeEntry`]. ZIP has no distinct hardlink file type; any
//! non-regular mode is rejected for the same reason. Entries are also bounded
//! by count and byte limits so a zip bomb cannot cause unbounded writes.
//!
//! ## Install model
//!
//! The verified pack is materialised into a hidden temp directory on the same
//! filesystem, fsynced, then renamed to `<root>/<key>/<sha256>`. A new artifact
//! therefore never touches the previously installed version directory; the
//! `channel_packs` row is upserted only after the rename succeeds. Any failure
//! removes the temp directory and, if the rename had already happened but the
//! DB write failed, the new version directory as well. The old version and the
//! old row remain intact.
//!
//! There is deliberately **no** signature, trust-root, verification, consent,
//! or marketplace surface here. `meta.json` is opaque JSON: extra v2-style
//! fields round-trip in the `meta_json` column and `ChannelPack::meta_json`,
//! but no field is interpreted beyond `requiredEnvVars`.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::fs::{self, File, OpenOptions};
use std::io::{Cursor, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, OptionalExtension, TransactionBehavior};
use sha2::{Digest, Sha256};
use zip::ZipArchive;

use crate::db::DbHandle;
use crate::dto::ChannelKey;
use crate::error::Error;

use super::pack::{validate_channel_key, ChannelPack, PackIconSource};

static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);
static INSTALL_LOCK: Mutex<()> = Mutex::new(());

/// True when the bytes start with a ZIP local/central/end/spanned signature.
const ZIP_MAGICS: [&[u8; 4]; 4] = [b"PK\x03\x04", b"PK\x05\x06", b"PK\x06\x06", b"PK\x07\x08"];

/// Bounds applied while inspecting and extracting a pack.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PackLimits {
    /// Maximum number of zip entries (directories included).
    pub max_entries: usize,
    /// Maximum uncompressed bytes for one entry.
    pub max_entry_bytes: u64,
    /// Maximum uncompressed bytes for the whole pack.
    pub max_total_bytes: u64,
    /// Maximum size of the `.zip` file itself.
    pub max_pack_bytes: u64,
}

impl Default for PackLimits {
    fn default() -> Self {
        Self {
            max_entries: 1024,
            max_entry_bytes: 8 * 1024 * 1024,
            max_total_bytes: 32 * 1024 * 1024,
            max_pack_bytes: 64 * 1024 * 1024,
        }
    }
}

/// Typed local-pack failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PackError {
    /// The input is not a zip at all.
    NotZip(String),
    /// The zip is truncated, malformed, or an entry cannot be decoded.
    Corrupt(String),
    /// An entry would escape the target root or has a dangerous file type.
    UnsafeEntry(String),
    /// The archive layout is not a legacy flat pack.
    Layout(String),
    /// `entry.js` is absent or empty.
    MissingEntry(String),
    /// `meta.json` is not a JSON object or `requiredEnvVars` is malformed.
    InvalidMeta(String),
    /// A file, entry, or total size limit was exceeded.
    TooLarge(String),
    /// The zip file name cannot produce a valid legacy channel key.
    InvalidKey(String),
    /// No installed pack exists for the requested key.
    NotFound(String),
    /// Filesystem failure; the temp directory and any partial install are gone.
    Io(String),
    /// SQLite failure; the previous pack and row are untouched.
    Db(String),
    /// Lock poisoning or another unexpected internal state.
    Internal(String),
}

impl PackError {
    /// Stable machine-readable code.
    pub const fn code(&self) -> &'static str {
        match self {
            Self::NotZip(_) => "pack_not_zip",
            Self::Corrupt(_) => "pack_corrupt",
            Self::UnsafeEntry(_) => "pack_unsafe_entry",
            Self::Layout(_) => "pack_layout",
            Self::MissingEntry(_) => "pack_missing_entry",
            Self::InvalidMeta(_) => "pack_invalid_meta",
            Self::TooLarge(_) => "pack_too_large",
            Self::InvalidKey(_) => "pack_invalid_key",
            Self::NotFound(_) => "pack_not_found",
            Self::Io(_) => "io",
            Self::Db(_) => "db",
            Self::Internal(_) => "internal",
        }
    }

    /// Human-readable message.
    pub fn message(&self) -> &str {
        match self {
            Self::NotZip(message)
            | Self::Corrupt(message)
            | Self::UnsafeEntry(message)
            | Self::Layout(message)
            | Self::MissingEntry(message)
            | Self::InvalidMeta(message)
            | Self::TooLarge(message)
            | Self::InvalidKey(message)
            | Self::NotFound(message)
            | Self::Io(message)
            | Self::Db(message)
            | Self::Internal(message) => message,
        }
    }
}

impl std::fmt::Display for PackError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.code(), self.message())
    }
}

impl std::error::Error for PackError {}

impl From<Error> for PackError {
    fn from(error: Error) -> Self {
        match error {
            Error::Io(message) => Self::Io(message),
            Error::Serialization(message) => Self::InvalidMeta(message),
            other => Self::InvalidMeta(other.message().to_string()),
        }
    }
}

/// A pack that was imported into the store.
#[derive(Debug, Clone, PartialEq)]
pub struct InstalledPack {
    /// Channel identity (`js_<stem>`).
    pub key: ChannelKey,
    /// Lower-case SHA-256 of the whole `.zip` artifact (64 hex characters).
    pub pack_hash: String,
    /// Millisecond timestamp persisted in `channel_packs.installed_at`.
    pub installed_at: i64,
    /// Versioned install directory (`<root>/<key>/<pack_hash>`).
    pub dir: PathBuf,
    /// Validated in-memory pack (scripts, metadata, embedded icons).
    pub pack: ChannelPack,
}

/// Local pack store with a configurable root directory.
pub struct PackStore {
    root: PathBuf,
    db: DbHandle,
    limits: PackLimits,
    clock: Arc<dyn Fn() -> i64 + Send + Sync>,
}

impl PackStore {
    /// Creates a store rooted at `root` using wall-clock time.
    pub fn new(root: impl Into<PathBuf>, db: DbHandle) -> Self {
        Self::with_clock(root, db, system_now_millis)
    }

    /// Creates a store with an injectable millisecond clock (tests/evidence).
    pub fn with_clock<F>(root: impl Into<PathBuf>, db: DbHandle, clock: F) -> Self
    where
        F: Fn() -> i64 + Send + Sync + 'static,
    {
        Self {
            root: root.into(),
            db,
            limits: PackLimits::default(),
            clock: Arc::new(clock),
        }
    }

    /// Overrides the default extraction bounds.
    pub fn with_limits(mut self, limits: PackLimits) -> Self {
        self.limits = limits;
        self
    }

    /// Root directory containing installed packs and transient `.tmp-*` dirs.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Core database handle used for the `channel_packs` row.
    pub fn db(&self) -> &DbHandle {
        &self.db
    }

    /// Imports a legacy flat pack from `zip_path`.
    ///
    /// The channel key is `js_<file stem>` (for example `alpha.zip` becomes
    /// `js_alpha`). Re-importing the same key upserts exactly one
    /// `channel_packs` row and prunes superseded version directories.
    pub fn import_pack(&self, zip_path: impl AsRef<Path>) -> Result<InstalledPack, PackError> {
        let zip_path = zip_path.as_ref();
        let key = legacy_key_from_path(zip_path)?;
        let artifact = read_bounded_file(zip_path, self.limits.max_pack_bytes)?;
        let pack_hash = sha256_hex(&artifact);
        let inspected = InspectedPack::from_zip(&key, &artifact, &self.limits)?;
        let installed_at = (self.clock)();

        let _install_guard = INSTALL_LOCK
            .lock()
            .map_err(|_| PackError::Internal("pack install lock poisoned".to_string()))?;
        fs::create_dir_all(&self.root)
            .map_err(|e| PackError::Io(format!("create pack root {}: {e}", self.root.display())))?;

        let key_dir = self.root.join(key.as_str());
        let target = key_dir.join(&pack_hash);
        let mut created_target = false;

        // An identical artifact is already installed: only the row timestamp
        // is refreshed by the upsert below.
        if !target.is_dir() {
            if target.exists() {
                return Err(PackError::Io(format!(
                    "pack target exists but is not a directory: {}",
                    target.display()
                )));
            }
            let mut temp = TempInstall::create(&self.root)?;
            inspected.write_to(temp.path())?;
            sync_tree(temp.path())?;
            fs::create_dir_all(&key_dir)
                .map_err(|e| PackError::Io(format!("create key dir {}: {e}", key_dir.display())))?;
            fs::rename(temp.path(), &target).map_err(|e| {
                PackError::Io(format!(
                    "rename {} -> {}: {e}",
                    temp.path().display(),
                    target.display()
                ))
            })?;
            temp.disarm();
            created_target = true;
            if let Err(error) = sync_dir(&key_dir) {
                let _ = fs::remove_dir_all(&target);
                return Err(error);
            }
        }

        if let Err(error) =
            self.upsert_row(&key, &pack_hash, &inspected.meta_json_column, installed_at)
        {
            if created_target {
                let _ = fs::remove_dir_all(&target);
            }
            return Err(error);
        }

        prune_old_versions(&key_dir, &pack_hash);

        Ok(InstalledPack {
            key,
            pack_hash,
            installed_at,
            dir: target,
            pack: inspected.pack,
        })
    }

    /// Reads the currently installed pack row for `key`.
    ///
    /// Returns [`PackError::NotFound`] when no row exists.
    pub fn installed_pack(
        &self,
        key: &ChannelKey,
    ) -> Result<(String, i64, PathBuf), PackError> {
        validate_channel_key(key).map_err(|error| {
            PackError::InvalidKey(error.message().to_string())
        })?;
        let conn = self
            .db
            .reader()
            .map_err(|error| PackError::Db(error.to_string()))?;
        let row = conn
            .query_row(
                "SELECT pack_hash, installed_at FROM channel_packs WHERE key=?1",
                [key.as_str()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()
            .map_err(|error| PackError::Db(error.to_string()))?;
        let Some((pack_hash, installed_at)) = row else {
            return Err(PackError::NotFound(format!(
                "pack not installed: {key}"
            )));
        };
        let dir = self.root.join(key.as_str()).join(&pack_hash);
        if !dir.is_dir() {
            return Err(PackError::NotFound(format!(
                "pack files missing: {key} ({})",
                dir.display()
            )));
        }
        Ok((pack_hash, installed_at, dir))
    }

    /// Exports an installed pack as a legacy flat zip at `dest`.
    ///
    /// The archive contains exactly the versioned install directory contents
    /// (`entry.js`, optional `detail.js`/`meta.json`, and `icons/...`). The
    /// export is written to a sibling temp file and renamed into place, so a
    /// failed export never leaves a partial destination. Returns the number of
    /// bytes written.
    pub fn export_pack(
        &self,
        key: &ChannelKey,
        dest: impl AsRef<Path>,
    ) -> Result<u64, PackError> {
        let (_hash, _installed_at, dir) = self.installed_pack(key)?;
        let dest = dest.as_ref();
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                PackError::Io(format!("create export dir {}: {error}", parent.display()))
            })?;
        }
        let n = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
        let temp = dest.with_file_name(format!(
            ".tmp-export-{}-{n}.zip",
            std::process::id()
        ));
        let result = (|| -> Result<u64, PackError> {
            let file = File::create(&temp).map_err(|error| {
                PackError::Io(format!("create export {}: {error}", temp.display()))
            })?;
            let mut writer = zip::ZipWriter::new(file);
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            for entry in collect_pack_files(&dir)? {
                let name = entry
                    .strip_prefix(&dir)
                    .map_err(|_| {
                        PackError::Io("export entry escaped pack root".to_string())
                    })?
                    .to_string_lossy()
                    .replace('\\', "/");
                let bytes = fs::read(&entry).map_err(|error| {
                    PackError::Io(format!("read export entry {}: {error}", entry.display()))
                })?;
                writer.start_file(name, options).map_err(|error| {
                    PackError::Io(format!("zip entry {}: {error}", entry.display()))
                })?;
                writer.write_all(&bytes).map_err(|error| {
                    PackError::Io(format!("zip write {}: {error}", entry.display()))
                })?;
            }
            let file = writer
                .finish()
                .map_err(|error| PackError::Io(format!("finish export zip: {error}")))?;
            file.sync_all().map_err(|error| {
                PackError::Io(format!("fsync export {}: {error}", temp.display()))
            })?;
            drop(file);
            fs::rename(&temp, dest).map_err(|error| {
                PackError::Io(format!(
                    "rename export {} -> {}: {error}",
                    temp.display(),
                    dest.display()
                ))
            })?;
            Ok(fs::metadata(dest)
                .map_err(|error| PackError::Io(format!("stat export: {error}")))?
                .len())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp);
        }
        result
    }

    /// Removes an installed pack (row first, then version directories).
    ///
    /// Returns [`PackError::NotFound`] when no pack is installed for `key`.
    pub fn remove_pack(&self, key: &ChannelKey) -> Result<(), PackError> {
        self.installed_pack(key)?;
        let mut conn = self
            .db
            .writer()
            .map_err(|error| PackError::Db(error.to_string()))?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| PackError::Db(error.to_string()))?;
        tx.execute("DELETE FROM channel_packs WHERE key=?1", [key.as_str()])
            .map_err(|error| PackError::Db(error.to_string()))?;
        tx.commit().map_err(|error| PackError::Db(error.to_string()))?;
        let key_dir = self.root.join(key.as_str());
        if key_dir.exists() {
            fs::remove_dir_all(&key_dir).map_err(|error| {
                PackError::Io(format!(
                    "remove pack dir {}: {error}",
                    key_dir.display()
                ))
            })?;
        }
        Ok(())
    }

    fn upsert_row(
        &self,
        key: &ChannelKey,
        pack_hash: &str,
        meta_json: &str,
        installed_at: i64,
    ) -> Result<(), PackError> {
        let mut conn = self.db.writer().map_err(|e| PackError::Db(e.to_string()))?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| PackError::Db(e.to_string()))?;
        tx.execute(
            "INSERT INTO channel_packs(key, pack_hash, meta_json, installed_at) \
             VALUES (?1, ?2, ?3, ?4) \
             ON CONFLICT(key) DO UPDATE SET \
                 pack_hash = excluded.pack_hash, \
                 meta_json = excluded.meta_json, \
                 installed_at = excluded.installed_at",
            params![key.as_str(), pack_hash, meta_json, installed_at],
        )
        .map_err(|e| PackError::Db(e.to_string()))?;
        tx.commit().map_err(|e| PackError::Db(e.to_string()))?;
        Ok(())
    }
}

/// Entry category in a legacy flat pack.
enum EntryKind {
    Entry,
    Detail,
    Meta,
    Icon,
}

struct InspectedPack {
    pack: ChannelPack,
    entry: Vec<u8>,
    detail: Option<Vec<u8>>,
    meta: Option<Vec<u8>>,
    meta_json_column: String,
    icons: BTreeMap<String, Vec<u8>>,
}

impl InspectedPack {
    fn from_zip(key: &ChannelKey, artifact: &[u8], limits: &PackLimits) -> Result<Self, PackError> {
        if !has_zip_magic(artifact) {
            return Err(PackError::NotZip(
                "pack is not a zip archive (missing PK signature)".to_string(),
            ));
        }

        let mut archive = ZipArchive::new(Cursor::new(artifact))
            .map_err(|e| PackError::Corrupt(format!("invalid zip: {e}")))?;
        if archive.is_empty() {
            return Err(PackError::Corrupt("zip archive has no entries".to_string()));
        }
        if archive.len() > limits.max_entries {
            return Err(PackError::TooLarge(format!(
                "zip has {} entries, limit is {}",
                archive.len(),
                limits.max_entries
            )));
        }

        let mut entry: Option<Vec<u8>> = None;
        let mut detail: Option<Vec<u8>> = None;
        let mut meta: Option<Vec<u8>> = None;
        let mut icons: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut total: u64 = 0;

        for index in 0..archive.len() {
            let file = archive
                .by_index(index)
                .map_err(|e| PackError::Corrupt(format!("read entry {index}: {e}")))?;
            let raw_name = file.name().to_string();
            let name = raw_name.strip_suffix('/').unwrap_or(&raw_name).to_string();
            validate_entry_path(&name)?;
            check_file_type(&name, &file)?;

            if file.is_dir() {
                if name != "icons" && !name.starts_with("icons/") {
                    return Err(PackError::Layout(format!(
                        "unexpected directory entry: {raw_name:?}"
                    )));
                }
                continue;
            }
            if file.encrypted() {
                return Err(PackError::Layout(format!(
                    "encrypted entry is not supported: {raw_name:?}"
                )));
            }
            if !seen.insert(name.clone()) {
                return Err(PackError::Layout(format!("duplicate entry: {raw_name:?}")));
            }
            let kind = classify(&name)?;

            let declared = file.size();
            if declared > limits.max_entry_bytes {
                return Err(PackError::TooLarge(format!(
                    "entry {name:?} declares {declared} bytes, per-entry limit is {}",
                    limits.max_entry_bytes
                )));
            }
            let remaining = limits.max_total_bytes.saturating_sub(total);
            if declared > remaining {
                return Err(PackError::TooLarge(format!(
                    "entry {name:?} declares {declared} bytes, total limit leaves {remaining}"
                )));
            }
            let cap = limits.max_entry_bytes.min(remaining).saturating_add(1);
            let mut limited = file.take(cap);
            let mut content = Vec::new();
            limited
                .read_to_end(&mut content)
                .map_err(|e| PackError::Corrupt(format!("decode entry {name:?}: {e}")))?;
            if content.len() as u64 > limits.max_entry_bytes {
                return Err(PackError::TooLarge(format!(
                    "entry {name:?} exceeds the per-entry limit of {} bytes",
                    limits.max_entry_bytes
                )));
            }
            if content.len() as u64 > remaining {
                return Err(PackError::TooLarge(format!(
                    "entry {name:?} exceeds the remaining total budget of {remaining} bytes"
                )));
            }
            if content.len() as u64 != declared {
                return Err(PackError::Corrupt(format!(
                    "entry {name:?} declared {declared} bytes but decoded {}",
                    content.len()
                )));
            }
            total = total.saturating_add(content.len() as u64);

            match kind {
                EntryKind::Entry => entry = Some(content),
                EntryKind::Detail => detail = Some(content),
                EntryKind::Meta => meta = Some(content),
                EntryKind::Icon => {
                    icons.insert(name, content);
                }
            }
        }

        let entry = entry
            .ok_or_else(|| PackError::MissingEntry("pack is missing root entry.js".to_string()))?;
        let entry_text = String::from_utf8(entry.clone())
            .map_err(|_| PackError::Corrupt("entry.js is not valid UTF-8".to_string()))?;
        if entry_text.trim().is_empty() {
            return Err(PackError::MissingEntry(
                "entry.js must not be empty".to_string(),
            ));
        }
        let detail_text = match &detail {
            Some(bytes) => Some(
                String::from_utf8(bytes.clone())
                    .map_err(|_| PackError::Corrupt("detail.js is not valid UTF-8".to_string()))?,
            ),
            None => None,
        };
        let (meta_text, meta_json_column) = match &meta {
            Some(bytes) if !bytes.iter().all(u8::is_ascii_whitespace) => {
                let text = std::str::from_utf8(bytes).map_err(|_| {
                    PackError::InvalidMeta("meta.json is not valid UTF-8".to_string())
                })?;
                (Some(text.to_string()), text.to_string())
            }
            Some(_) => (None, "{}".to_string()),
            None => (None, "{}".to_string()),
        };

        let pack_icons: BTreeMap<String, PackIconSource> = icons
            .iter()
            .map(|(name, bytes)| (name.clone(), PackIconSource::Bytes(bytes.clone())))
            .collect();
        let pack = ChannelPack::new(
            key.clone(),
            entry_text,
            detail_text,
            meta_text.as_deref(),
            pack_icons,
        )
        .map_err(|error| match error {
            Error::InvalidArgument(message) if message.contains("channel key") => {
                PackError::InvalidKey(message)
            }
            other => PackError::InvalidMeta(other.message().to_string()),
        })?;

        Ok(Self {
            pack,
            entry,
            detail,
            meta,
            meta_json_column,
            icons,
        })
    }

    fn write_to(&self, dir: &Path) -> Result<(), PackError> {
        fs::create_dir_all(dir)
            .map_err(|e| PackError::Io(format!("create temp pack dir {}: {e}", dir.display())))?;
        write_new_file(&dir.join("entry.js"), &self.entry)?;
        if let Some(detail) = &self.detail {
            write_new_file(&dir.join("detail.js"), detail)?;
        }
        if let Some(meta) = &self.meta {
            write_new_file(&dir.join("meta.json"), meta)?;
        }
        for (name, bytes) in &self.icons {
            let relative = validate_entry_path(name)?;
            let path = dir.join(relative);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).map_err(|e| {
                    PackError::Io(format!("create icon dir {}: {e}", parent.display()))
                })?;
            }
            write_new_file(&path, bytes)?;
        }
        Ok(())
    }
}

/// Removes its directory on drop unless [`TempInstall::disarm`] was called.
struct TempInstall {
    path: PathBuf,
    armed: bool,
}

impl TempInstall {
    fn create(root: &Path) -> Result<Self, PackError> {
        loop {
            let n = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let path = root.join(format!(".tmp-{}-{n}", std::process::id()));
            match fs::create_dir(&path) {
                Ok(()) => {
                    return Ok(Self { path, armed: true });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(PackError::Io(format!(
                        "create temp dir {}: {error}",
                        path.display()
                    )));
                }
            }
        }
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for TempInstall {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

fn collect_pack_files(dir: &Path) -> Result<Vec<PathBuf>, PackError> {
    let mut files = Vec::new();
    collect_pack_files_into(dir, &mut files)?;
    files.sort();
    Ok(files)
}

fn collect_pack_files_into(dir: &Path, files: &mut Vec<PathBuf>) -> Result<(), PackError> {
    let entries = fs::read_dir(dir)
        .map_err(|error| PackError::Io(format!("read pack dir {}: {error}", dir.display())))?;
    for entry in entries {
        let entry = entry
            .map_err(|error| PackError::Io(format!("read pack dir entry: {error}")))?;
        let path = entry.path();
        let file_type = entry
            .file_type()
            .map_err(|error| PackError::Io(format!("stat pack entry: {error}")))?;
        if file_type.is_dir() {
            collect_pack_files_into(&path, files)?;
        } else if file_type.is_file() {
            files.push(path);
        }
    }
    Ok(())
}

fn legacy_key_from_path(path: &Path) -> Result<ChannelKey, PackError> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| PackError::InvalidKey("pack path has no valid file name".to_string()))?;
    let stem = file_name.strip_suffix(".zip").ok_or_else(|| {
        PackError::InvalidKey(format!("pack file must end with .zip: {file_name:?}"))
    })?;
    let mut chars = stem.chars();
    let first = chars
        .next()
        .ok_or_else(|| PackError::InvalidKey("pack file name must not be empty".to_string()))?;
    if !(first.is_ascii_alphabetic() || first == '_')
        || !chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
    {
        return Err(PackError::InvalidKey(format!(
            "pack file stem must match ^[a-zA-Z_][a-zA-Z0-9_]*$: {stem:?}"
        )));
    }
    ChannelKey::new(format!("js_{stem}"))
        .map_err(|error| PackError::InvalidKey(error.message().to_string()))
}

fn has_zip_magic(bytes: &[u8]) -> bool {
    bytes.len() >= 4 && ZIP_MAGICS.iter().any(|magic| bytes[..4] == magic[..])
}

fn read_bounded_file(path: &Path, max_bytes: u64) -> Result<Vec<u8>, PackError> {
    let metadata =
        fs::metadata(path).map_err(|e| PackError::Io(format!("stat {}: {e}", path.display())))?;
    if metadata.len() > max_bytes {
        return Err(PackError::TooLarge(format!(
            "pack file {} is {} bytes, limit is {max_bytes}",
            path.display(),
            metadata.len()
        )));
    }
    let file =
        File::open(path).map_err(|e| PackError::Io(format!("open {}: {e}", path.display())))?;
    let mut content = Vec::new();
    let mut limited = file.take(max_bytes.saturating_add(1));
    limited
        .read_to_end(&mut content)
        .map_err(|e| PackError::Io(format!("read {}: {e}", path.display())))?;
    if content.len() as u64 > max_bytes {
        return Err(PackError::TooLarge(format!(
            "pack file {} exceeds the {max_bytes}-byte limit",
            path.display()
        )));
    }
    Ok(content)
}

/// Structural path validation (no string-prefix shortcuts).
fn validate_entry_path(name: &str) -> Result<PathBuf, PackError> {
    if name.is_empty() {
        return Err(PackError::UnsafeEntry("empty entry name".to_string()));
    }
    if name.starts_with('/') || name.starts_with('\\') {
        return Err(PackError::UnsafeEntry(format!(
            "absolute entry path is not allowed: {name:?}"
        )));
    }
    if name.contains('\\') {
        return Err(PackError::UnsafeEntry(format!(
            "backslash in entry path is not allowed: {name:?}"
        )));
    }
    if name.as_bytes().contains(&0) || name.chars().any(char::is_control) {
        return Err(PackError::UnsafeEntry(format!(
            "control character in entry path: {name:?}"
        )));
    }
    let bytes = name.as_bytes();
    if bytes.len() >= 2 && bytes[1] == b':' {
        return Err(PackError::UnsafeEntry(format!(
            "drive-letter entry path is not allowed: {name:?}"
        )));
    }
    if name.contains(':') {
        return Err(PackError::UnsafeEntry(format!(
            "':' in entry path is not allowed: {name:?}"
        )));
    }

    let mut relative = PathBuf::new();
    for part in name.split('/') {
        if part.is_empty() || part == "." || part == ".." {
            return Err(PackError::UnsafeEntry(format!(
                "entry escapes the target root: {name:?}"
            )));
        }
        relative.push(part);
    }
    if relative.is_absolute()
        || relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(PackError::UnsafeEntry(format!(
            "entry escapes the target root: {name:?}"
        )));
    }
    Ok(relative)
}

fn check_file_type<R: Read>(name: &str, file: &zip::read::ZipFile<'_, R>) -> Result<(), PackError> {
    if file.is_symlink() {
        return Err(PackError::UnsafeEntry(format!(
            "symlink entry is not allowed: {name:?}"
        )));
    }
    if let Some(mode) = file.unix_mode() {
        let file_type = mode & 0o170000;
        if file_type != 0 {
            let expected = if file.is_dir() { 0o040000 } else { 0o100000 };
            if file_type != expected {
                return Err(PackError::UnsafeEntry(format!(
                    "non-regular file type {file_type:o} for entry {name:?}"
                )));
            }
        }
    }
    Ok(())
}

fn classify(name: &str) -> Result<EntryKind, PackError> {
    match name {
        "entry.js" => Ok(EntryKind::Entry),
        "detail.js" => Ok(EntryKind::Detail),
        "meta.json" => Ok(EntryKind::Meta),
        other if other.starts_with("icons/") => {
            if other.len() == "icons/".len() {
                return Err(PackError::Layout(format!(
                    "empty icon entry name: {name:?}"
                )));
            }
            Ok(EntryKind::Icon)
        }
        _ => Err(PackError::Layout(format!(
            "unexpected entry in legacy flat pack: {name:?}"
        ))),
    }
}

fn write_new_file(path: &Path, bytes: &[u8]) -> Result<(), PackError> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| PackError::Io(format!("create {}: {e}", path.display())))?;
    file.write_all(bytes)
        .map_err(|e| PackError::Io(format!("write {}: {e}", path.display())))?;
    file.sync_all()
        .map_err(|e| PackError::Io(format!("fsync {}: {e}", path.display())))?;
    Ok(())
}

fn sync_dir(dir: &Path) -> Result<(), PackError> {
    File::open(dir)
        .and_then(|file| file.sync_all())
        .map_err(|e| PackError::Io(format!("fsync dir {}: {e}", dir.display())))
}

fn sync_tree(dir: &Path) -> Result<(), PackError> {
    let entries = fs::read_dir(dir)
        .map_err(|e| PackError::Io(format!("read temp dir {}: {e}", dir.display())))?;
    for entry in entries {
        let entry = entry.map_err(|e| PackError::Io(format!("read temp dir entry: {e}")))?;
        if entry
            .file_type()
            .map_err(|e| PackError::Io(format!("stat temp entry: {e}")))?
            .is_dir()
        {
            sync_tree(&entry.path())?;
        }
    }
    sync_dir(dir)
}

fn prune_old_versions(key_dir: &Path, keep: &str) {
    let Ok(entries) = fs::read_dir(key_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name.to_string_lossy() == keep {
            continue;
        }
        let path = entry.path();
        if path.is_dir() {
            if let Err(error) = fs::remove_dir_all(&path) {
                log::warn!(
                    "pack: could not prune old version {}: {error}",
                    path.display()
                );
            }
        }
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for byte in digest {
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

fn system_now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}
