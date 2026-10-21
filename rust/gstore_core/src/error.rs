//! Typed, stable errors for the public `gstore_core` API.
//!
//! Every fallible public path returns [`Error`] (or a module error that wraps
//! it); no `Box<dyn Error>` is exposed to callers. The `code` strings are the
//! machine-readable contract and must not change once published.

use serde::{Deserialize, Serialize};

/// Stable machine codes for [`Error`].
pub const CODE_NOT_FOUND: &str = "not_found";
pub const CODE_INVALID_ARGUMENT: &str = "invalid_argument";
pub const CODE_CONFLICT: &str = "conflict";
pub const CODE_IO: &str = "io";
pub const CODE_NETWORK: &str = "network";
pub const CODE_UNAUTHORIZED: &str = "unauthorized";
pub const CODE_FORBIDDEN: &str = "forbidden";
pub const CODE_RATE_LIMITED: &str = "rate_limited";
pub const CODE_SERIALIZATION: &str = "serialization";
pub const CODE_UNSUPPORTED: &str = "unsupported";
pub const CODE_INTERNAL: &str = "internal";

/// Typed core error with a stable machine code and a human-readable message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "code", content = "message", rename_all = "snake_case")]
pub enum Error {
    /// A requested entity does not exist.
    NotFound(String),
    /// The caller supplied an invalid value.
    InvalidArgument(String),
    /// The operation conflicts with current state.
    Conflict(String),
    /// Filesystem or other local I/O failure.
    Io(String),
    /// Remote/network failure (including 5xx responses and timeouts).
    Network(String),
    /// Authentication is missing or rejected (HTTP 401).
    Unauthorized(String),
    /// Authenticated but not allowed (HTTP 403 without a rate-limit signal).
    Forbidden(String),
    /// Remote rate limit (HTTP 429, or 403 whose body says rate limit).
    RateLimited(String),
    /// JSON/encoding/decoding failure.
    Serialization(String),
    /// The operation is not supported in this wave.
    Unsupported(String),
    /// Unexpected internal failure.
    Internal(String),
}

impl Error {
    /// Stable machine-readable code for this error.
    pub const fn code(&self) -> &'static str {
        match self {
            Self::NotFound(_) => CODE_NOT_FOUND,
            Self::InvalidArgument(_) => CODE_INVALID_ARGUMENT,
            Self::Conflict(_) => CODE_CONFLICT,
            Self::Io(_) => CODE_IO,
            Self::Network(_) => CODE_NETWORK,
            Self::Unauthorized(_) => CODE_UNAUTHORIZED,
            Self::Forbidden(_) => CODE_FORBIDDEN,
            Self::RateLimited(_) => CODE_RATE_LIMITED,
            Self::Serialization(_) => CODE_SERIALIZATION,
            Self::Unsupported(_) => CODE_UNSUPPORTED,
            Self::Internal(_) => CODE_INTERNAL,
        }
    }

    /// Human-readable message.
    pub fn message(&self) -> &str {
        match self {
            Self::NotFound(message)
            | Self::InvalidArgument(message)
            | Self::Conflict(message)
            | Self::Io(message)
            | Self::Network(message)
            | Self::Unauthorized(message)
            | Self::Forbidden(message)
            | Self::RateLimited(message)
            | Self::Serialization(message)
            | Self::Unsupported(message)
            | Self::Internal(message) => message,
        }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.code(), self.message())
    }
}

impl std::error::Error for Error {}

impl From<serde_json::Error> for Error {
    fn from(error: serde_json::Error) -> Self {
        Self::Serialization(error.to_string())
    }
}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.to_string())
    }
}
