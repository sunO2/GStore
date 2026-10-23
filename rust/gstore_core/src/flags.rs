//! Rust-owned feature flags.
//!
//! The Rust core is the source of truth. Dart only mirrors the snapshot through
//! `CoreFlags` and never writes it directly. The process-global default is
//! [`Flags::WAVE06B_CUTOVER`] (download + install owned by the core); every
//! other flag is still `false`, and [`Flags::DISABLED`] remains available so
//! tests can opt back into the all-off world.
//!
//! `core_writes` is a *projection* of the `core_writes` table, not an operator
//! switch: [`set_flags`] still rejects `Some(true)`, while
//! [`set_core_writes_armed`] is the internal setter used whenever the core
//! writes a domain marker or hydrates the projection at init/snapshot restore.

use std::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

use serde::{Deserialize, Serialize};

use crate::error::Error;

/// Process-global flag snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Flags {
    /// Channel subsystem is enabled.
    pub channels: bool,
    /// Catalog reads are served by the Rust core.
    pub catalog: bool,
    /// Update checks are served by the Rust core.
    pub update: bool,
    /// Downloads are served by the Rust core.
    pub download: bool,
    /// Installs are served by the Rust core.
    pub install: bool,
    /// Local JavaScript channels are enabled.
    pub js_channel: bool,
    /// Rust core writes are authoritative (projected from `core_writes`).
    pub core_writes: bool,
}

impl Flags {
    /// All flags disabled.
    pub const DISABLED: Self = Self {
        channels: false,
        catalog: false,
        update: false,
        download: false,
        install: false,
        js_channel: false,
        core_writes: false,
    };

    /// Wave 6B durable cutover: only `download` + `install` are core-owned.
    ///
    /// This is the initial value of [`GLOBAL_FLAGS`]. `channels`, `catalog`,
    /// `update`, `js_channel` and the `core_writes` projection stay off.
    pub const WAVE06B_CUTOVER: Self = Self {
        channels: false,
        catalog: false,
        update: false,
        download: true,
        install: true,
        js_channel: false,
        core_writes: false,
    };
}

impl Default for Flags {
    fn default() -> Self {
        Self::DISABLED
    }
}

/// Partial update accepted by [`set_flags`]. `None` leaves a flag unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct FlagsPatch {
    /// New value for [`Flags::channels`].
    pub channels: Option<bool>,
    /// New value for [`Flags::catalog`].
    pub catalog: Option<bool>,
    /// New value for [`Flags::update`].
    pub update: Option<bool>,
    /// New value for [`Flags::download`].
    pub download: Option<bool>,
    /// New value for [`Flags::install`].
    pub install: Option<bool>,
    /// New value for [`Flags::js_channel`].
    pub js_channel: Option<bool>,
    /// New value for [`Flags::core_writes`]; `Some(true)` is rejected by
    /// [`set_flags`]. Only [`set_core_writes_armed`] may arm it.
    pub core_writes: Option<bool>,
}

impl FlagsPatch {
    /// Whether this patch would change nothing.
    pub const fn is_empty(&self) -> bool {
        self.channels.is_none()
            && self.catalog.is_none()
            && self.update.is_none()
            && self.download.is_none()
            && self.install.is_none()
            && self.js_channel.is_none()
            && self.core_writes.is_none()
    }
}

impl Flags {
    fn apply(&mut self, patch: FlagsPatch) -> &mut Self {
        if let Some(value) = patch.channels {
            self.channels = value;
        }
        if let Some(value) = patch.catalog {
            self.catalog = value;
        }
        if let Some(value) = patch.update {
            self.update = value;
        }
        if let Some(value) = patch.download {
            self.download = value;
        }
        if let Some(value) = patch.install {
            self.install = value;
        }
        if let Some(value) = patch.js_channel {
            self.js_channel = value;
        }
        if let Some(value) = patch.core_writes {
            self.core_writes = value;
        }
        self
    }
}

static GLOBAL_FLAGS: RwLock<Flags> = RwLock::new(Flags::WAVE06B_CUTOVER);

fn read_guard() -> RwLockReadGuard<'static, Flags> {
    match GLOBAL_FLAGS.read() {
        Ok(guard) => guard,
        // A poisoned lock still holds a valid snapshot; recover it instead of
        // panicking. (No fallible path may `unwrap()`.)
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn write_guard() -> RwLockWriteGuard<'static, Flags> {
    match GLOBAL_FLAGS.write() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// Returns the current process-global snapshot.
pub fn flags() -> Flags {
    *read_guard()
}

/// Applies a partial update and returns the resulting snapshot.
///
/// # Errors
/// Returns [`Error::Unsupported`] when the patch tries to arm `core_writes`;
/// only the DB-backed projection may do that.
pub fn set_flags(patch: FlagsPatch) -> Result<Flags, Error> {
    if patch.core_writes == Some(true) {
        return Err(Error::Unsupported(
            "core_writes is projected from the core_writes table and cannot be set directly"
                .to_string(),
        ));
    }
    if patch.is_empty() {
        return Ok(flags());
    }
    let mut guard = write_guard();
    guard.apply(patch);
    Ok(*guard)
}

/// Arms or clears the `core_writes` projection directly.
///
/// Trusted core code calls this after a marker row is written and when the
/// projection is hydrated from the database. It deliberately bypasses the
/// [`set_flags`] rejection; Dart-facing patches never reach it.
pub fn set_core_writes_armed(armed: bool) {
    let mut guard = write_guard();
    guard.core_writes = armed;
}

/// Whether the Rust core is authoritative for `domain` (its flag is flipped).
///
/// This gates the first-write marker so schema/apply/import paths that reuse
/// store code before the cutover never arm the legacy-write guard. Reserved
/// domains (currently `js_channel`) map to their own flag and stay inert until
/// a writer exists.
pub fn domain_authoritative(domain: &str) -> bool {
    let snapshot = flags();
    match domain {
        "channel" => snapshot.channels,
        "catalog" => snapshot.catalog,
        "update" => snapshot.update,
        "download" => snapshot.download,
        "install" => snapshot.install,
        "js_channel" => snapshot.js_channel,
        _ => false,
    }
}

/// Resets every flag to `false` and returns the resulting snapshot.
pub fn reset_flags() -> Flags {
    let mut guard = write_guard();
    *guard = Flags::DISABLED;
    *guard
}

/// FRB-facing facade over the process-global flags.
#[derive(Debug, Default, Clone, Copy)]
pub struct FlagsApi;

impl FlagsApi {
    /// Creates the facade.
    pub fn new() -> Self {
        Self
    }

    /// Returns the current snapshot.
    pub fn get(&self) -> Flags {
        flags()
    }

    /// Applies a partial update and returns the resulting snapshot.
    pub fn set(&self, patch: FlagsPatch) -> Result<Flags, Error> {
        set_flags(patch)
    }

    /// Resets every flag to `false` and returns the resulting snapshot.
    pub fn reset(&self) -> Flags {
        reset_flags()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wave06b_cutover_flips_only_download_and_install() {
        let cutover = Flags::WAVE06B_CUTOVER;
        assert!(cutover.download);
        assert!(cutover.install);
        assert!(!cutover.channels);
        assert!(!cutover.catalog);
        assert!(!cutover.update);
        assert!(!cutover.js_channel);
        assert!(!cutover.core_writes);
        // The opt-out default stays all-off.
        assert_eq!(Flags::DISABLED, Flags::default());
        assert!(!Flags::DISABLED.download);
        assert!(!Flags::DISABLED.install);
    }
}
