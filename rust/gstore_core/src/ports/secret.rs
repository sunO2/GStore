//! File-backed secret store and the portable secret port.
//!
//! Values are written under a dedicated root with `0600` permissions on Unix,
//! using a temporary file plus `rename` so readers never observe a partial
//! value. Secret values are never logged, formatted, or included in errors.

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::error::Error;

/// Maximum accepted secret key length.
pub const MAX_SECRET_KEY_LEN: usize = 128;

/// Portable secret port.
pub trait FileSecretPort {
    /// Reads a secret. `None` means the key is absent.
    fn get(&self, key: &str) -> Result<Option<String>, Error>;

    /// Writes (or atomically replaces) a secret.
    fn set(&self, key: &str, value: &str) -> Result<(), Error>;

    /// Removes a secret. Returns `true` when it existed.
    fn remove(&self, key: &str) -> Result<bool, Error>;

    /// Lists secret keys in stable order (never values).
    fn list(&self) -> Result<Vec<String>, Error>;
}

/// Validates a secret key.
///
/// Keys are used as file names, so anything path-like is rejected before any
/// filesystem work happens.
///
/// # Errors
/// Returns [`Error::InvalidArgument`] for empty, overlong, hidden, or path-like
/// keys.
pub fn validate_secret_key(key: &str) -> Result<(), Error> {
    if key.is_empty() {
        return Err(Error::InvalidArgument(
            "secret key must not be empty".to_string(),
        ));
    }
    if key.len() > MAX_SECRET_KEY_LEN {
        return Err(Error::InvalidArgument(format!(
            "secret key exceeds {MAX_SECRET_KEY_LEN} bytes"
        )));
    }
    if key.starts_with('.') {
        return Err(Error::InvalidArgument(format!(
            "secret key must not start with '.': {key:?}"
        )));
    }
    if !key
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
    {
        return Err(Error::InvalidArgument(format!(
            "secret key contains unsupported characters: {key:?}"
        )));
    }
    // `..` cannot appear inside a validated key, but reject it explicitly so a
    // future relaxation of the character class cannot reintroduce traversal.
    if key.contains("..") {
        return Err(Error::InvalidArgument(format!(
            "secret key must not contain '..': {key:?}"
        )));
    }
    Ok(())
}

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// File-backed [`FileSecretPort`].
#[derive(Debug, Clone)]
pub struct FileSecretStore {
    root: PathBuf,
}

impl FileSecretStore {
    /// Creates a store rooted at `root`. The directory is created lazily.
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Secret root directory.
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn path_for(&self, key: &str) -> Result<PathBuf, Error> {
        validate_secret_key(key)?;
        Ok(self.root.join(key))
    }

    fn ensure_root(&self) -> Result<(), Error> {
        fs::create_dir_all(&self.root)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&self.root, fs::Permissions::from_mode(0o700))?;
        }
        Ok(())
    }

    fn temp_path(&self, key: &str) -> PathBuf {
        let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        self.root
            .join(format!(".tmp-{}-{}-{counter}", std::process::id(), key))
    }

    fn write_atomic(&self, path: &Path, temp: &Path, value: &str) -> Result<(), Error> {
        let result = (|| -> Result<(), Error> {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(temp)?;
            use std::io::Write;
            file.write_all(value.as_bytes())?;
            file.sync_all()?;
            drop(file);
            fs::rename(temp, path)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temp);
        }
        result
    }
}

impl FileSecretPort for FileSecretStore {
    fn get(&self, key: &str) -> Result<Option<String>, Error> {
        let path = self.path_for(key)?;
        match fs::read_to_string(path) {
            Ok(value) => Ok(Some(value)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(Error::Io(format!("read secret {key}: {error}"))),
        }
    }

    fn set(&self, key: &str, value: &str) -> Result<(), Error> {
        let path = self.path_for(key)?;
        self.ensure_root()?;
        let temp = self.temp_path(key);
        self.write_atomic(&path, &temp, value)
    }

    fn remove(&self, key: &str) -> Result<bool, Error> {
        let path = self.path_for(key)?;
        match fs::remove_file(path) {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(Error::Io(format!("remove secret {key}: {error}"))),
        }
    }

    fn list(&self) -> Result<Vec<String>, Error> {
        let entries = match fs::read_dir(&self.root) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(Error::Io(format!("list secrets: {error}"))),
        };
        let mut keys = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|error| Error::Io(format!("list secrets: {error}")))?;
            let file_type = entry
                .file_type()
                .map_err(|error| Error::Io(format!("list secrets: {error}")))?;
            if !file_type.is_file() {
                continue;
            }
            let name = entry.file_name();
            let Some(key) = name.to_str() else {
                continue;
            };
            if validate_secret_key(key).is_ok() {
                keys.push(key.to_string());
            }
        }
        keys.sort();
        Ok(keys)
    }
}

/// In-memory implementation used by tests and by hosts without a secret root.
#[derive(Debug, Default)]
pub struct InMemorySecretPort {
    values: std::sync::RwLock<BTreeMap<String, String>>,
}

impl InMemorySecretPort {
    /// Creates an empty port.
    pub fn new() -> Self {
        Self::default()
    }

    fn read(&self) -> Result<std::sync::RwLockReadGuard<'_, BTreeMap<String, String>>, Error> {
        self.values
            .read()
            .map_err(|_| Error::Internal("secret port lock poisoned".to_string()))
    }

    fn write(&self) -> Result<std::sync::RwLockWriteGuard<'_, BTreeMap<String, String>>, Error> {
        self.values
            .write()
            .map_err(|_| Error::Internal("secret port lock poisoned".to_string()))
    }
}

impl FileSecretPort for InMemorySecretPort {
    fn get(&self, key: &str) -> Result<Option<String>, Error> {
        validate_secret_key(key)?;
        Ok(self.read()?.get(key).cloned())
    }

    fn set(&self, key: &str, value: &str) -> Result<(), Error> {
        validate_secret_key(key)?;
        self.write()?.insert(key.to_string(), value.to_string());
        Ok(())
    }

    fn remove(&self, key: &str) -> Result<bool, Error> {
        validate_secret_key(key)?;
        Ok(self.write()?.remove(key).is_some())
    }

    fn list(&self) -> Result<Vec<String>, Error> {
        Ok(self.read()?.keys().cloned().collect())
    }
}
