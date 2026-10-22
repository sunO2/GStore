//! Installer port: the durable install contract used by [`crate::install`].
//!
//! `InstallerPort` is the only path an install may take. [`PlatformInstaller`]
//! adapts the portable [`PlatformHost`] compatibility hook, while Android can
//! provide Shizuku / PackageInstaller / Intent implementations without changing
//! the service. The service never calls `PlatformHost` directly.

use std::fmt;
use std::path::Path;
use std::sync::Arc;

use crate::error::Error;
use crate::ports::platform::{Capability, PlatformHost};

/// How an install was performed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallMethod {
    /// Silent install through Shizuku.
    Shizuku,
    /// Android `PackageInstaller` session.
    PackageInstaller,
    /// `ACTION_INSTALL_PACKAGE` / `ACTION_VIEW` intent.
    Intent,
    /// Portable platform-host compatibility hook.
    Platform,
}

impl InstallMethod {
    /// Stable machine-readable id stored in `download_task.install_method`.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Shizuku => "shizuku",
            Self::PackageInstaller => "package_installer",
            Self::Intent => "intent",
            Self::Platform => "platform",
        }
    }

    /// Parses a stable id.
    ///
    /// # Errors
    /// Returns [`Error::InvalidArgument`] for an unknown id.
    pub fn from_id(id: &str) -> Result<Self, Error> {
        match id {
            "shizuku" => Ok(Self::Shizuku),
            "package_installer" => Ok(Self::PackageInstaller),
            "intent" => Ok(Self::Intent),
            "platform" => Ok(Self::Platform),
            other => Err(Error::InvalidArgument(format!(
                "unknown install method: {other}"
            ))),
        }
    }
}

impl fmt::Display for InstallMethod {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Terminal install outcome reported by an installer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallOutcome {
    /// Installation succeeded.
    Installed {
        /// Installed package name, when known.
        package_name: Option<String>,
        /// Installed version name, when known.
        version_name: Option<String>,
    },
    /// The user rejected the install. This is terminal: no silent fallback.
    Denied {
        /// Rejection message.
        message: String,
    },
    /// The installer session timed out.
    Timeout {
        /// Optional timeout detail.
        message: Option<String>,
    },
    /// Installation failed for another reason.
    Failed {
        /// Failure message.
        message: String,
    },
}

impl InstallOutcome {
    /// Stable status stored in `download_task.install_status`.
    pub const fn status_str(&self) -> &'static str {
        match self {
            Self::Installed { .. } => "installed",
            Self::Denied { .. } => "denied",
            Self::Timeout { .. } => "timeout",
            Self::Failed { .. } => "failed",
        }
    }

    /// Whether this outcome succeeded.
    pub const fn is_success(&self) -> bool {
        matches!(self, Self::Installed { .. })
    }

    /// Package name, when the installer reported one.
    pub fn package_name(&self) -> Option<&str> {
        match self {
            Self::Installed { package_name, .. } => package_name.as_deref(),
            Self::Denied { .. } | Self::Timeout { .. } | Self::Failed { .. } => None,
        }
    }

    /// Version name, when the installer reported one.
    pub fn version_name(&self) -> Option<&str> {
        match self {
            Self::Installed { version_name, .. } => version_name.as_deref(),
            Self::Denied { .. } | Self::Timeout { .. } | Self::Failed { .. } => None,
        }
    }

    /// Human-readable message for failures.
    pub fn message(&self) -> Option<&str> {
        match self {
            Self::Installed { .. } => None,
            Self::Denied { message } | Self::Failed { message } => Some(message),
            Self::Timeout { message } => message.as_deref(),
        }
    }
}

/// Result of starting an install.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallTicket {
    /// Method used by the installer.
    pub method: InstallMethod,
    /// `Some` for a synchronous result, `None` for an asynchronous session.
    pub outcome: Option<InstallOutcome>,
}

/// Durable installer contract.
///
/// `begin_install` is called with the caller-owned session id so the service
/// can persist it before the asynchronous install completes.
pub trait InstallerPort: Send + Sync {
    /// Whether this host can install packages at all.
    fn can_install(&self) -> bool;

    /// Starts installing `apk_path` under `session_id`.
    ///
    /// Returns a synchronous [`InstallTicket::outcome`] when the installer
    /// completes immediately, or `None` when the caller must poll
    /// [`InstallerPort::install_result`].
    fn begin_install(&self, apk_path: &Path, session_id: &str) -> Result<InstallTicket, Error>;

    /// Polls an asynchronous install session.
    ///
    /// `Ok(None)` means the session is still pending. Unknown sessions also
    /// report `Ok(None)` so a lost installer state cannot fabricate a result.
    fn install_result(&self, session_id: &str) -> Result<Option<InstallOutcome>, Error>;

    /// Uninstalls `package_name`.
    fn uninstall(&self, package_name: &str) -> Result<(), Error>;

    /// Launches `package_name`.
    fn launch(&self, package_name: &str) -> Result<(), Error>;

    /// Session ids the installer still considers pending.
    fn pending_sessions(&self) -> Result<Vec<String>, Error>;
}

/// [`InstallerPort`] backed by the portable [`PlatformHost`] compatibility hook.
pub struct PlatformInstaller {
    platform: Arc<dyn PlatformHost>,
}

impl PlatformInstaller {
    /// Wraps a platform host.
    pub fn new(platform: Arc<dyn PlatformHost>) -> Self {
        Self { platform }
    }
}

impl InstallerPort for PlatformInstaller {
    fn can_install(&self) -> bool {
        self.platform.capabilities().supports(Capability::Install)
    }

    fn begin_install(&self, apk_path: &Path, _session_id: &str) -> Result<InstallTicket, Error> {
        if apk_path.as_os_str().is_empty() {
            return Err(Error::InvalidArgument(
                "CORE_E_INSTALL_APK_MISSING: empty apk path".to_string(),
            ));
        }
        if !apk_path.is_file() {
            return Err(Error::InvalidArgument(format!(
                "CORE_E_INSTALL_APK_MISSING: {}",
                apk_path.display()
            )));
        }
        self.platform.install(apk_path)?;
        Ok(InstallTicket {
            method: InstallMethod::Platform,
            outcome: Some(InstallOutcome::Installed {
                package_name: None,
                version_name: None,
            }),
        })
    }

    fn install_result(&self, _session_id: &str) -> Result<Option<InstallOutcome>, Error> {
        Ok(None)
    }

    fn uninstall(&self, package_name: &str) -> Result<(), Error> {
        self.platform.uninstall(package_name)
    }

    fn launch(&self, package_name: &str) -> Result<(), Error> {
        self.platform.launch(package_name)
    }

    fn pending_sessions(&self) -> Result<Vec<String>, Error> {
        Ok(Vec::new())
    }
}
