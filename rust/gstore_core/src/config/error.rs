//! Typed domain errors for the module-scoped configuration model.
//!
//! These errors are part of the config contract: callers match on the variant
//! (and its fields), not on a message string. `code()` values are stable wire
//! codes and must not change once published, mirroring [`crate::error::Error`].

use std::fmt;

use super::model::ConfigValueType;

/// The access a caller is attempting; used by [`ConfigError::NotPermitted`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ConfigAccess {
    /// Read one value.
    Read,
    /// Write or clear one value.
    Write,
    /// Subscribe to changes.
    Subscribe,
}

impl ConfigAccess {
    /// Stable wire code.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Write => "write",
            Self::Subscribe => "subscribe",
        }
    }
}

impl fmt::Display for ConfigAccess {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Stable machine codes for [`ConfigError`].
pub const CODE_INVALID_MODULE: &str = "config_invalid_module";
pub const CODE_INVALID_KEY: &str = "config_invalid_key";
pub const CODE_INVALID_WIRE_NAME: &str = "config_invalid_wire_name";
pub const CODE_UNKNOWN_KEY: &str = "config_unknown_key";
pub const CODE_TYPE_MISMATCH: &str = "config_type_mismatch";
pub const CODE_NOT_PERMITTED: &str = "config_not_permitted";
pub const CODE_VALIDATION: &str = "config_validation";
pub const CODE_INVALID_SOURCE: &str = "config_invalid_source";

/// Typed errors raised by the config model, store, and bus.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    /// The module half of a key is empty, overlong, or not `[a-z0-9_-]+`.
    InvalidModule {
        /// Rejected module value.
        module: String,
        /// Why it was rejected.
        reason: String,
    },
    /// The key half is empty, overlong, dot-misplaced, path-like, or has bad characters.
    InvalidKey {
        /// Rejected key value.
        key: String,
        /// Why it was rejected.
        reason: String,
    },
    /// The wire form is not `module.key` (it has no dot).
    InvalidWireName {
        /// Rejected wire value.
        wire: String,
        /// Why it was rejected.
        reason: String,
    },
    /// No registry entry exists for the key.
    UnknownKey {
        /// Module half.
        module: String,
        /// Key half.
        key: String,
    },
    /// The JSON value does not match the entry's declared type.
    TypeMismatch {
        /// Module half.
        module: String,
        /// Key half.
        key: String,
        /// Declared value type.
        expected: ConfigValueType,
        /// JSON kind that was supplied.
        actual: String,
    },
    /// Visibility or ownership forbids the requested access.
    NotPermitted {
        /// Module half.
        module: String,
        /// Key half.
        key: String,
        /// Attempted access.
        access: ConfigAccess,
    },
    /// A change-source wire code is not recognized.
    InvalidSource {
        /// Rejected source code.
        source: String,
    },
    /// The value is the right type but violates a range or enum constraint.
    Validation {
        /// Module half.
        module: String,
        /// Key half.
        key: String,
        /// Why it was rejected.
        reason: String,
    },
}

impl ConfigError {
    /// Stable machine-readable code for this error.
    pub const fn code(&self) -> &'static str {
        match self {
            Self::InvalidModule { .. } => CODE_INVALID_MODULE,
            Self::InvalidKey { .. } => CODE_INVALID_KEY,
            Self::InvalidWireName { .. } => CODE_INVALID_WIRE_NAME,
            Self::UnknownKey { .. } => CODE_UNKNOWN_KEY,
            Self::TypeMismatch { .. } => CODE_TYPE_MISMATCH,
            Self::NotPermitted { .. } => CODE_NOT_PERMITTED,
            Self::Validation { .. } => CODE_VALIDATION,
            Self::InvalidSource { .. } => CODE_INVALID_SOURCE,
        }
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidModule { module, reason } => {
                write!(
                    f,
                    "[{}] invalid config module {module:?}: {reason}",
                    self.code()
                )
            }
            Self::InvalidKey { key, reason } => {
                write!(f, "[{}] invalid config key {key:?}: {reason}", self.code())
            }
            Self::InvalidWireName { wire, reason } => {
                write!(
                    f,
                    "[{}] invalid config wire name {wire:?}: {reason}",
                    self.code()
                )
            }
            Self::UnknownKey { module, key } => {
                write!(f, "[{}] unknown config key {module}.{key}", self.code())
            }
            Self::TypeMismatch {
                module,
                key,
                expected,
                actual,
            } => write!(
                f,
                "[{}] config {module}.{key} expects {expected}, got {actual}",
                self.code()
            ),
            Self::NotPermitted {
                module,
                key,
                access,
            } => write!(
                f,
                "[{}] {access} is not permitted for config {module}.{key}",
                self.code()
            ),
            Self::InvalidSource { source } => {
                write!(f, "[{}] unknown config source {source:?}", self.code())
            }
            Self::Validation {
                module,
                key,
                reason,
            } => write!(
                f,
                "[{}] invalid value for config {module}.{key}: {reason}",
                self.code()
            ),
        }
    }
}

impl std::error::Error for ConfigError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_codes_are_stable_per_variant() {
        assert_eq!(
            ConfigError::InvalidModule {
                module: "a.b".to_string(),
                reason: "bad".to_string()
            }
            .code(),
            CODE_INVALID_MODULE
        );
        assert_eq!(
            ConfigError::InvalidKey {
                key: "a..b".to_string(),
                reason: "bad".to_string()
            }
            .code(),
            CODE_INVALID_KEY
        );
        assert_eq!(
            ConfigError::InvalidWireName {
                wire: "download".to_string(),
                reason: "bad".to_string()
            }
            .code(),
            CODE_INVALID_WIRE_NAME
        );
        assert_eq!(
            ConfigError::UnknownKey {
                module: "download".to_string(),
                key: "nope".to_string()
            }
            .code(),
            CODE_UNKNOWN_KEY
        );
        assert_eq!(
            ConfigError::TypeMismatch {
                module: "download".to_string(),
                key: "max_concurrent".to_string(),
                expected: ConfigValueType::Int,
                actual: "string".to_string()
            }
            .code(),
            CODE_TYPE_MISMATCH
        );
        assert_eq!(
            ConfigError::NotPermitted {
                module: "download".to_string(),
                key: "max_concurrent".to_string(),
                access: ConfigAccess::Read
            }
            .code(),
            CODE_NOT_PERMITTED
        );
        assert_eq!(
            ConfigError::Validation {
                module: "download".to_string(),
                key: "max_concurrent".to_string(),
                reason: "out of range".to_string()
            }
            .code(),
            CODE_VALIDATION
        );
        assert_eq!(
            ConfigError::InvalidSource {
                source: "nope".to_string()
            }
            .code(),
            CODE_INVALID_SOURCE
        );
    }

    #[test]
    fn display_includes_code_and_context() {
        let error = ConfigError::NotPermitted {
            module: "webdav".to_string(),
            key: "password".to_string(),
            access: ConfigAccess::Read,
        };
        assert_eq!(
            error.to_string(),
            "[config_not_permitted] read is not permitted for config webdav.password"
        );
        let _: &dyn std::error::Error = &error;
    }
}
