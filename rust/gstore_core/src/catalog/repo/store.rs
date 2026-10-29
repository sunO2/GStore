//! Low-level filesystem helpers for the catalog repository.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use sha2::{Digest, Sha256};

use crate::catalog::refresh::validate_source;
use crate::error::Error;

pub(super) fn is_valid_catalog(path: &Path) -> bool {
    path.is_file() && validate_source(path, false).is_ok()
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

pub(super) fn sanitize_component(value: &str) -> String {
    let cleaned: String = value
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "unknown".to_string()
    } else {
        cleaned
    }
}

pub(super) fn atomic_write(dest: &Path, bytes: &[u8]) -> Result<(), Error> {
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            Error::Io(format!(
                "CORE_E_CATALOG_REPO_COPY: create {}: {e}",
                parent.display()
            ))
        })?;
    }
    let name = dest
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            Error::Io(format!(
                "CORE_E_CATALOG_REPO_COPY: invalid path {}",
                dest.display()
            ))
        })?;
    let tmp = dest.with_file_name(format!(".{name}.tmp"));
    fs::write(&tmp, bytes).map_err(|e| {
        Error::Io(format!(
            "CORE_E_CATALOG_REPO_COPY: write {}: {e}",
            tmp.display()
        ))
    })?;
    fs::rename(&tmp, dest).map_err(|e| {
        Error::Io(format!(
            "CORE_E_CATALOG_REPO_COPY: rename {}: {e}",
            tmp.display()
        ))
    })
}

pub(super) fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
        })
}

pub(super) struct TempFile {
    path: PathBuf,
}

impl TempFile {
    pub(super) fn create(dir: &Path, bytes: &[u8]) -> Result<Self, Error> {
        fs::create_dir_all(dir).map_err(|e| {
            Error::Io(format!(
                "CORE_E_CATALOG_REPO_TEMP: create {}: {e}",
                dir.display()
            ))
        })?;
        let mut attempt = 0_u32;
        loop {
            let name = if attempt == 0 {
                format!("download-{}.db", now_millis())
            } else {
                format!("download-{}-{attempt}.db", now_millis())
            };
            let candidate = dir.join(name);
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&candidate)
            {
                Ok(mut file) => {
                    let guard = Self {
                        path: candidate.clone(),
                    };
                    file.write_all(bytes).map_err(|e| {
                        Error::Io(format!(
                            "CORE_E_CATALOG_REPO_TEMP: write {}: {e}",
                            candidate.display()
                        ))
                    })?;
                    return Ok(guard);
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    attempt += 1;
                }
                Err(error) => {
                    return Err(Error::Io(format!(
                        "CORE_E_CATALOG_REPO_TEMP: create {}: {error}",
                        candidate.display()
                    )));
                }
            }
        }
    }

    pub(super) fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub(super) fn core_count(db: &crate::db::DbHandle, table: &str) -> Result<usize, Error> {
    let count: i64 = db
        .with_reader(|conn| {
            conn.query_row(&format!("SELECT COUNT(*) FROM \"{table}\""), [], |row| {
                row.get(0)
            })
            .map_err(|e| crate::db::DbError(format!("CORE_E_CATALOG_REPO_CORE: {e}")))
        })
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_REPO_CORE: {e}")))?;
    usize::try_from(count).map_err(|e| Error::Internal(format!("CORE_E_CATALOG_REPO_CORE: {e}")))
}
