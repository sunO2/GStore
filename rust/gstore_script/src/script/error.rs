//! Typed script-runtime errors and their stable `CORE_E_SCRIPT_*` machine codes.
//!
//! The code string is part of the cross-layer contract (Dart/FRB consumers branch
//! on it), so it must never be derived from `Display` text or reordered here.

use std::error::Error as StdError;
use std::fmt;

/// Evaluation failed: the script raised, or the source did not compile.
pub const CODE_EVAL: &str = "CORE_E_SCRIPT_EVAL";
/// The wall-clock budget expired (interrupt handler fired).
pub const CODE_TIMEOUT: &str = "CORE_E_SCRIPT_TIMEOUT";
/// The runtime was already disposed (or its thread is gone).
pub const CODE_DISPOSED: &str = "CORE_E_SCRIPT_DISPOSED";
/// A sandbox limit was hit (memory / stack).
pub const CODE_LIMIT: &str = "CORE_E_SCRIPT_LIMIT";
/// A `sendMessage` host callback failed or panicked.
pub const CODE_HOST: &str = "CORE_E_SCRIPT_HOST";
/// Internal wiring failure (thread spawn, engine construction, JSON round-trip).
pub const CODE_INTERNAL: &str = "CORE_E_SCRIPT_INTERNAL";
/// Caller passed something the runtime cannot use.
pub const CODE_INVALID_ARGUMENT: &str = "CORE_E_SCRIPT_INVALID_ARGUMENT";

/// Stable classification of a [`ScriptError`], independent of its message text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScriptErrorKind {
    Eval,
    Timeout,
    Disposed,
    Limit,
    Host,
    Internal,
    InvalidArgument,
}

impl ScriptErrorKind {
    /// Machine-readable error code for this kind.
    pub const fn code(self) -> &'static str {
        match self {
            Self::Eval => CODE_EVAL,
            Self::Timeout => CODE_TIMEOUT,
            Self::Disposed => CODE_DISPOSED,
            Self::Limit => CODE_LIMIT,
            Self::Host => CODE_HOST,
            Self::Internal => CODE_INTERNAL,
            Self::InvalidArgument => CODE_INVALID_ARGUMENT,
        }
    }
}

/// Error returned by every public `gstore_script` entry point.
///
/// Variants are exhaustive on purpose: callers match on [`ScriptError::kind`] or
/// [`ScriptError::code`], never on message text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScriptError {
    Eval {
        message: String,
    },
    /// `timeout_ms == 0` means the timeout was reported by a layered host call.
    Timeout {
        timeout_ms: u64,
    },
    Disposed,
    Limit {
        message: String,
    },
    Host {
        message: String,
    },
    Internal {
        message: String,
    },
    InvalidArgument {
        message: String,
    },
}

impl ScriptError {
    pub fn eval(message: impl Into<String>) -> Self {
        Self::Eval {
            message: message.into(),
        }
    }

    pub fn timeout(timeout_ms: u64) -> Self {
        Self::Timeout { timeout_ms }
    }

    pub fn limit(message: impl Into<String>) -> Self {
        Self::Limit {
            message: message.into(),
        }
    }

    pub fn host(message: impl Into<String>) -> Self {
        Self::Host {
            message: message.into(),
        }
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::Internal {
            message: message.into(),
        }
    }

    pub fn invalid_argument(message: impl Into<String>) -> Self {
        Self::InvalidArgument {
            message: message.into(),
        }
    }

    /// Stable classification for programmatic handling.
    pub const fn kind(&self) -> ScriptErrorKind {
        match self {
            Self::Eval { .. } => ScriptErrorKind::Eval,
            Self::Timeout { .. } => ScriptErrorKind::Timeout,
            Self::Disposed => ScriptErrorKind::Disposed,
            Self::Limit { .. } => ScriptErrorKind::Limit,
            Self::Host { .. } => ScriptErrorKind::Host,
            Self::Internal { .. } => ScriptErrorKind::Internal,
            Self::InvalidArgument { .. } => ScriptErrorKind::InvalidArgument,
        }
    }

    /// Stable `CORE_E_SCRIPT_*` machine string for this error.
    pub const fn code(&self) -> &'static str {
        self.kind().code()
    }

    /// Rebuild an error from a JS exception message that starts with one of the
    /// stable codes (as produced by the `sendMessage` bridge).
    pub(crate) fn from_js_message(message: String) -> Self {
        let trimmed = message.trim();
        let (code, detail) = match trimmed.split_once(':') {
            Some((code, rest)) => (code.trim(), rest.trim()),
            None => (trimmed, ""),
        };
        let detail = if detail.is_empty() {
            trimmed.to_owned()
        } else {
            detail.to_owned()
        };
        match code {
            CODE_EVAL => Self::eval(detail),
            CODE_TIMEOUT => Self::timeout(0),
            CODE_DISPOSED => Self::Disposed,
            CODE_LIMIT => Self::limit(detail),
            CODE_HOST => Self::host(detail),
            CODE_INTERNAL => Self::internal(detail),
            CODE_INVALID_ARGUMENT => Self::invalid_argument(detail),
            _ => Self::eval(message),
        }
    }
}

impl fmt::Display for ScriptError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Eval { message } => write!(f, "{CODE_EVAL}: {message}"),
            Self::Timeout { timeout_ms } => {
                write!(f, "{CODE_TIMEOUT}: evaluation exceeded {timeout_ms} ms")
            }
            Self::Disposed => write!(f, "{CODE_DISPOSED}: runtime disposed"),
            Self::Limit { message } => write!(f, "{CODE_LIMIT}: {message}"),
            Self::Host { message } => write!(f, "{CODE_HOST}: {message}"),
            Self::Internal { message } => write!(f, "{CODE_INTERNAL}: {message}"),
            Self::InvalidArgument { message } => {
                write!(f, "{CODE_INVALID_ARGUMENT}: {message}")
            }
        }
    }
}

impl StdError for ScriptError {}
