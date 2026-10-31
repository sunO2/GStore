//! Canonical module-scoped configuration model.
//!
//! A configuration key is the pair `(module, key)`. The wire form is
//! `module.key`; parsing splits on the **first** dot so the key itself may
//! contain dots (`download.multi_segment.enabled`). Both halves are validated
//! at construction, so a [`ConfigKey`] that exists is always well formed.

use std::fmt;
use std::str::FromStr;

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

use super::error::{ConfigAccess, ConfigError};

/// Maximum accepted module length.
pub const MAX_MODULE_LEN: usize = 64;
/// Maximum accepted key length.
pub const MAX_KEY_LEN: usize = 64;
/// Placeholder shown instead of a secret value on untrusted surfaces.
pub const MASKED_VALUE: &str = "***";

/// Identity of one configuration entry: an owning module plus a dotted key.
///
/// Fields are private so every instance has passed [`ConfigKey::new`] (or
/// [`ConfigKey::parse`]); equality, ordering, and hashing use both halves.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ConfigKey {
    module: String,
    key: String,
}

impl ConfigKey {
    /// Creates a key, validating the module and key halves.
    ///
    /// # Errors
    /// Returns [`ConfigError::InvalidModule`] when the module is empty,
    /// overlong, or not `[a-z0-9_-]+`, and [`ConfigError::InvalidKey`] when the
    /// key is empty, overlong, has a leading/trailing dot, contains `..` or a
    /// path separator, or is not `[a-z0-9_.-]+`.
    pub fn new(module: impl Into<String>, key: impl Into<String>) -> Result<Self, ConfigError> {
        let module = module.into();
        let key = key.into();
        validate_module(&module)?;
        validate_key(&key)?;
        Ok(Self { module, key })
    }

    /// Parses the wire form `module.key`, splitting on the first dot.
    ///
    /// # Errors
    /// Returns [`ConfigError::InvalidWireName`] when the wire value has no
    /// dot, and propagates the [`ConfigKey::new`] validation errors otherwise.
    pub fn parse(wire: &str) -> Result<Self, ConfigError> {
        let Some((module, key)) = wire.split_once('.') else {
            return Err(ConfigError::InvalidWireName {
                wire: wire.to_string(),
                reason: "expected `module.key`".to_string(),
            });
        };
        Self::new(module, key)
    }

    /// Owning module name.
    pub fn module(&self) -> &str {
        &self.module
    }

    /// Key within the module.
    pub fn key(&self) -> &str {
        &self.key
    }

    /// Canonical wire form `module.key`.
    pub fn wire(&self) -> String {
        format!("{}.{}", self.module, self.key)
    }
}

impl fmt::Display for ConfigKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}", self.module, self.key)
    }
}

impl FromStr for ConfigKey {
    type Err = ConfigError;

    fn from_str(wire: &str) -> Result<Self, Self::Err> {
        Self::parse(wire)
    }
}

impl Serialize for ConfigKey {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.wire())
    }
}

impl<'de> Deserialize<'de> for ConfigKey {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = String::deserialize(deserializer)?;
        Self::parse(&wire).map_err(D::Error::custom)
    }
}

fn validate_module(module: &str) -> Result<(), ConfigError> {
    let reason = if module.is_empty() {
        "module must not be empty"
    } else if module.len() > MAX_MODULE_LEN {
        "module must be at most 64 bytes"
    } else if !module.bytes().all(|byte| {
        byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
    }) {
        "module must match [a-z0-9_-] and must not contain '.'"
    } else {
        return Ok(());
    };
    Err(ConfigError::InvalidModule {
        module: module.to_string(),
        reason: reason.to_string(),
    })
}

fn validate_key(key: &str) -> Result<(), ConfigError> {
    let reason = if key.is_empty() {
        "key must not be empty"
    } else if key.len() > MAX_KEY_LEN {
        "key must be at most 64 bytes"
    } else if key.starts_with('.') {
        "key must not start with '.'"
    } else if key.ends_with('.') {
        "key must not end with '.'"
    } else if key.contains("..") {
        "key must not contain '..'"
    } else if key.contains('/') || key.contains('\\') {
        "key must not contain a path separator"
    } else if !key.bytes().all(|byte| {
        byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-' | b'.')
    }) {
        "key must match [a-z0-9_.-]"
    } else {
        return Ok(());
    };
    Err(ConfigError::InvalidKey {
        key: key.to_string(),
        reason: reason.to_string(),
    })
}

/// Who may read or subscribe to a configuration entry.
///
/// The owner module may always read, subscribe, and write its own entries.
/// `PublicRead` widens reads/subscriptions to every module, but writes stay
/// owner/host/trusted-Dart only. `Secret` keeps reads, subscriptions, and
/// writes to the owner/host/trusted Dart and masks the value (`***`) for
/// everyone else.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConfigVisibility {
    /// Only the owner module, host, and trusted Dart may access it.
    #[default]
    Owner,
    /// Any module may read or subscribe; only the owner/host/trusted Dart may write.
    PublicRead,
    /// Only the owner/host/trusted Dart may read; values are masked for everyone else.
    Secret,
}

impl ConfigVisibility {
    /// Stable wire code.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::PublicRead => "public_read",
            Self::Secret => "secret",
        }
    }

    /// Whether a module other than the owner may read or subscribe.
    pub const fn allows_foreign_read(self) -> bool {
        matches!(self, Self::PublicRead)
    }

    /// Whether a module other than the owner may write.
    ///
    /// Always `false`: visibility never grants a foreign write.
    pub const fn allows_foreign_write(self) -> bool {
        false
    }

    /// Whether a foreign reader must receive a masked value.
    pub const fn masks_foreign_value(self) -> bool {
        matches!(self, Self::Secret)
    }
}

impl fmt::Display for ConfigVisibility {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Declared JSON value type of a configuration entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConfigValueType {
    /// JSON boolean.
    Bool,
    /// JSON integer (no fractional part).
    Int,
    /// JSON number (integer or fractional), matching Dart `num`.
    Double,
    /// JSON string.
    String,
    /// JSON array whose items are all strings.
    StringList,
    /// JSON object or array (Dart `Map`/`List`).
    Json,
}

impl ConfigValueType {
    /// Stable wire code.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Bool => "bool",
            Self::Int => "int",
            Self::Double => "double",
            Self::String => "string",
            Self::StringList => "string_list",
            Self::Json => "json",
        }
    }

    /// Whether `value` is a legal value for this type.
    pub fn accepts(self, value: &Value) -> bool {
        match self {
            Self::Bool => value.is_boolean(),
            Self::Int => value.as_i64().is_some() || value.as_u64().is_some(),
            // Dart `double` accepts an integer literal too; JSON has one number type.
            Self::Double => value.is_number(),
            Self::String => value.is_string(),
            Self::StringList => value
                .as_array()
                .is_some_and(|items| items.iter().all(Value::is_string)),
            Self::Json => value.is_object() || value.is_array(),
        }
    }
}

impl fmt::Display for ConfigValueType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Origin of a configuration change.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConfigSource {
    /// System-initiated change.
    #[default]
    Internal,
    /// User interface change.
    User,
    /// Agent tool change.
    Agent,
    /// Native module change.
    Module,
    /// Legacy-data migration.
    Migration,
    /// Backup restore.
    Restore,
}

impl ConfigSource {
    /// Stable wire code.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Internal => "internal",
            Self::User => "user",
            Self::Agent => "agent",
            Self::Module => "module",
            Self::Migration => "migration",
            Self::Restore => "restore",
        }
    }
}

impl fmt::Display for ConfigSource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for ConfigSource {
    type Err = ConfigError;

    fn from_str(code: &str) -> Result<Self, Self::Err> {
        match code {
            "internal" => Ok(Self::Internal),
            "user" => Ok(Self::User),
            "agent" => Ok(Self::Agent),
            "module" => Ok(Self::Module),
            "migration" => Ok(Self::Migration),
            "restore" => Ok(Self::Restore),
            other => Err(ConfigError::InvalidSource {
                source: other.to_string(),
            }),
        }
    }
}

/// Static metadata for one registered configuration entry.
///
/// The current value lives in the store; this type only carries the registry
/// shape (type, default, flags, descriptions, constraints, visibility).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConfigEntry {
    /// Canonical `(module, key)` identity.
    pub key: ConfigKey,
    /// Declared JSON value type.
    pub value_type: ConfigValueType,
    /// Last committed revision (0 until first write).
    pub revision: u64,
    /// Whether the value is a secret and must be masked on untrusted surfaces.
    pub sensitive: bool,
    /// Whether the Agent may read/write this entry.
    pub agent_accessible: bool,
    /// Read/subscribe/write policy.
    pub visibility: ConfigVisibility,
    /// Default value restored by `reset`.
    pub default_json: Value,
    /// Chinese description.
    pub description_zh: String,
    /// English description.
    pub description_en: String,
    /// Grouping used for display (for example `download`).
    pub category: String,
    /// Unit label for numeric entries (for example `MB`).
    pub unit: Option<String>,
    /// Inclusive numeric minimum.
    pub min: Option<f64>,
    /// Inclusive numeric maximum.
    pub max: Option<f64>,
    /// Allowed string values; empty means unconstrained.
    pub enum_values: Vec<String>,
    /// Example value shown to users/agents.
    pub example: Option<String>,
}

impl ConfigEntry {
    /// Validates `value` against this entry's type, numeric range, and enum.
    ///
    /// # Errors
    /// Returns [`ConfigError::TypeMismatch`] for a wrong JSON type and
    /// [`ConfigError::Validation`] for an out-of-range number or a string not
    /// present in [`ConfigEntry::enum_values`].
    pub fn validate_value(&self, value: &Value) -> Result<(), ConfigError> {
        if !self.value_type.accepts(value) {
            return Err(ConfigError::TypeMismatch {
                module: self.key.module().to_string(),
                key: self.key.key().to_string(),
                expected: self.value_type,
                actual: json_kind(value).to_string(),
            });
        }
        if let Some(number) = value.as_f64() {
            if self.min.is_some_and(|min| number < min) {
                return Err(ConfigError::Validation {
                    module: self.key.module().to_string(),
                    key: self.key.key().to_string(),
                    reason: format!(
                        "value {number} is below the minimum {}",
                        self.min.unwrap_or_default()
                    ),
                });
            }
            if self.max.is_some_and(|max| number > max) {
                return Err(ConfigError::Validation {
                    module: self.key.module().to_string(),
                    key: self.key.key().to_string(),
                    reason: format!(
                        "value {number} is above the maximum {}",
                        self.max.unwrap_or_default()
                    ),
                });
            }
        }
        if let Some(text) = value.as_str() {
            if !self.enum_values.is_empty()
                && !self.enum_values.iter().any(|allowed| allowed == text)
            {
                return Err(ConfigError::Validation {
                    module: self.key.module().to_string(),
                    key: self.key.key().to_string(),
                    reason: format!(
                        "value {text:?} is not one of {}",
                        self.enum_values.join("/")
                    ),
                });
            }
        }
        Ok(())
    }

    /// Whether a caller from `caller_module` may read this entry.
    pub fn readable_by(&self, caller_module: &str) -> bool {
        caller_module == self.key.module() || self.visibility.allows_foreign_read()
    }

    /// Whether a caller from `caller_module` may write this entry.
    pub fn writable_by(&self, caller_module: &str) -> bool {
        caller_module == self.key.module() || self.visibility.allows_foreign_write()
    }

    /// Returns the typed error for an unauthorized read/write, if unauthorized.
    pub fn authorize(&self, caller_module: &str, access: ConfigAccess) -> Result<(), ConfigError> {
        let allowed = match access {
            ConfigAccess::Read | ConfigAccess::Subscribe => self.readable_by(caller_module),
            ConfigAccess::Write => self.writable_by(caller_module),
        };
        if allowed {
            Ok(())
        } else {
            Err(ConfigError::NotPermitted {
                module: self.key.module().to_string(),
                key: self.key.key().to_string(),
                access,
            })
        }
    }
}

/// A committed configuration change.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConfigChange {
    /// Owning module.
    pub module: String,
    /// Key within the module.
    pub key: String,
    /// Previous JSON value; `None` when the entry was unset.
    pub old_json: Option<Value>,
    /// New JSON value; `None` when the entry was cleared.
    pub new_json: Option<Value>,
    /// Revision after the change.
    pub revision: u64,
    /// Origin of the change.
    pub source: ConfigSource,
    /// Optional actor identity (user id, module id, backup id).
    pub actor: Option<String>,
}

impl ConfigChange {
    /// Canonical wire form of the changed key.
    pub fn wire_key(&self) -> String {
        format!("{}.{}", self.module, self.key)
    }
}

fn json_kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(number) if number.is_f64() => "number",
        Value::Number(_) => "integer",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn assert_invalid_module(result: Result<ConfigKey, ConfigError>) {
        assert!(
            matches!(result, Err(ConfigError::InvalidModule { .. })),
            "expected InvalidModule, got {result:?}"
        );
    }

    fn assert_invalid_key(result: Result<ConfigKey, ConfigError>) {
        assert!(
            matches!(result, Err(ConfigError::InvalidKey { .. })),
            "expected InvalidKey, got {result:?}"
        );
    }

    #[test]
    fn key_validation_rejects_empty_and_dotted_module() {
        assert_invalid_module(ConfigKey::new("", "enabled"));
        assert_invalid_module(ConfigKey::new("a.b", "enabled"));
    }

    #[test]
    fn key_validation_rejects_uppercase_and_bad_characters() {
        assert_invalid_module(ConfigKey::new("Download", "enabled"));
        assert_invalid_module(ConfigKey::new("down load", "enabled"));
        assert_invalid_module(ConfigKey::new("down/load", "enabled"));
    }

    #[test]
    fn key_validation_rejects_empty_uppercase_and_path_key() {
        assert_invalid_key(ConfigKey::new("download", ""));
        assert_invalid_key(ConfigKey::new("download", "Multi_Segment"));
        assert_invalid_key(ConfigKey::new("download", "a/b"));
        assert_invalid_key(ConfigKey::new("download", "a\\b"));
    }

    #[test]
    fn key_validation_rejects_dot_positions() {
        assert_invalid_key(ConfigKey::new("download", "a..b"));
        assert_invalid_key(ConfigKey::new("download", ".a"));
        assert_invalid_key(ConfigKey::new("download", "a."));
        assert_invalid_key(ConfigKey::new("download", "."));
    }

    #[test]
    fn key_validation_rejects_length_overflow() {
        let long = "a".repeat(MAX_MODULE_LEN + 1);
        assert_invalid_module(ConfigKey::new(long, "enabled"));
        let long = "a".repeat(MAX_KEY_LEN + 1);
        assert_invalid_key(ConfigKey::new("download", long));
    }

    #[test]
    fn key_validation_accepts_dotted_key_and_limits() {
        let key = ConfigKey::new("download", "multi_segment.enabled").unwrap();
        assert_eq!(key.module(), "download");
        assert_eq!(key.key(), "multi_segment.enabled");
        ConfigKey::new("a".repeat(MAX_MODULE_LEN), "a".repeat(MAX_KEY_LEN)).unwrap();
    }

    #[test]
    fn wire_form_round_trips_and_splits_on_first_dot() {
        let key = ConfigKey::new("download", "multi_segment.enabled").unwrap();
        assert_eq!(key.wire(), "download.multi_segment.enabled");
        assert_eq!(
            ConfigKey::parse("download.multi_segment.enabled").unwrap(),
            key
        );

        let nested = ConfigKey::parse("a.b.c.d").unwrap();
        assert_eq!(nested.module(), "a");
        assert_eq!(nested.key(), "b.c.d");
        assert_eq!(nested.wire(), "a.b.c.d");
    }

    #[test]
    fn wire_parse_requires_a_dot_and_valid_halves() {
        assert!(matches!(
            ConfigKey::parse("download"),
            Err(ConfigError::InvalidWireName { .. })
        ));
        assert!(matches!(
            ConfigKey::parse(".enabled"),
            Err(ConfigError::InvalidModule { .. })
        ));
        assert!(matches!(
            ConfigKey::parse("download..enabled"),
            Err(ConfigError::InvalidKey { .. })
        ));
        assert!(matches!(
            ConfigKey::parse("Download.enabled"),
            Err(ConfigError::InvalidModule { .. })
        ));
    }

    #[test]
    fn key_deserialization_validates_the_wire_form() {
        let ok: ConfigKey = serde_json::from_value(json!("download.max_concurrent")).unwrap();
        assert_eq!(ok.module(), "download");
        assert!(serde_json::from_value::<ConfigKey>(json!("download..bad")).is_err());
    }

    #[test]
    fn value_type_accepts_matching_json() {
        assert!(ConfigValueType::Bool.accepts(&json!(true)));
        assert!(ConfigValueType::Int.accepts(&json!(5)));
        assert!(ConfigValueType::Double.accepts(&json!(5)));
        assert!(ConfigValueType::Double.accepts(&json!(5.5)));
        assert!(ConfigValueType::String.accepts(&json!("text")));
        assert!(ConfigValueType::StringList.accepts(&json!(["a", "b"])));
        assert!(ConfigValueType::Json.accepts(&json!({"a": 1})));
        assert!(ConfigValueType::Json.accepts(&json!([1, 2])));
    }

    #[test]
    fn value_type_rejects_mismatched_json() {
        assert!(!ConfigValueType::Bool.accepts(&json!(1)));
        assert!(!ConfigValueType::Int.accepts(&json!(1.5)));
        assert!(!ConfigValueType::Int.accepts(&json!("1")));
        assert!(!ConfigValueType::Double.accepts(&json!("1.5")));
        assert!(!ConfigValueType::String.accepts(&json!(1)));
        assert!(!ConfigValueType::StringList.accepts(&json!(["a", 1])));
        assert!(!ConfigValueType::Json.accepts(&json!("text")));
        assert!(!ConfigValueType::Json.accepts(&json!(1)));
    }

    #[test]
    fn visibility_defaults_to_owner() {
        assert_eq!(ConfigVisibility::default(), ConfigVisibility::Owner);
        assert_eq!(ConfigVisibility::default().as_str(), "owner");
    }

    #[test]
    fn public_read_allows_foreign_read_but_not_write() {
        assert!(ConfigVisibility::PublicRead.allows_foreign_read());
        assert!(!ConfigVisibility::PublicRead.allows_foreign_write());
        assert!(!ConfigVisibility::PublicRead.masks_foreign_value());
    }

    #[test]
    fn owner_and_secret_deny_foreign_access() {
        for visibility in [ConfigVisibility::Owner, ConfigVisibility::Secret] {
            assert!(!visibility.allows_foreign_read());
            assert!(!visibility.allows_foreign_write());
        }
        assert!(ConfigVisibility::Secret.masks_foreign_value());
        assert!(!ConfigVisibility::Owner.masks_foreign_value());
    }

    #[test]
    fn entry_authorizes_owner_public_and_secret() {
        let owner = entry(ConfigVisibility::Owner);
        owner.authorize("download", ConfigAccess::Write).unwrap();
        assert!(matches!(
            owner.authorize("theme", ConfigAccess::Read),
            Err(ConfigError::NotPermitted {
                access: ConfigAccess::Read,
                ..
            })
        ));
        assert!(matches!(
            owner.authorize("theme", ConfigAccess::Write),
            Err(ConfigError::NotPermitted {
                access: ConfigAccess::Write,
                ..
            })
        ));

        let public = entry(ConfigVisibility::PublicRead);
        public.authorize("theme", ConfigAccess::Read).unwrap();
        public.authorize("theme", ConfigAccess::Subscribe).unwrap();
        assert!(matches!(
            public.authorize("theme", ConfigAccess::Write),
            Err(ConfigError::NotPermitted {
                access: ConfigAccess::Write,
                ..
            })
        ));

        let secret = entry(ConfigVisibility::Secret);
        assert!(matches!(
            secret.authorize("theme", ConfigAccess::Read),
            Err(ConfigError::NotPermitted {
                access: ConfigAccess::Read,
                ..
            })
        ));
    }

    #[test]
    fn entry_validate_value_checks_type_range_and_enum() {
        let mut entry = entry(ConfigVisibility::Owner);
        entry.value_type = ConfigValueType::Int;
        entry.min = Some(1.0);
        entry.max = Some(10.0);

        entry.validate_value(&json!(5)).unwrap();
        assert!(matches!(
            entry.validate_value(&json!("5")),
            Err(ConfigError::TypeMismatch { .. })
        ));
        assert!(matches!(
            entry.validate_value(&json!(0)),
            Err(ConfigError::Validation { .. })
        ));
        assert!(matches!(
            entry.validate_value(&json!(11)),
            Err(ConfigError::Validation { .. })
        ));

        let mut enum_entry = entry;
        enum_entry.value_type = ConfigValueType::String;
        enum_entry.min = None;
        enum_entry.max = None;
        enum_entry.enum_values = vec!["stable".to_string(), "beta".to_string()];
        enum_entry.validate_value(&json!("stable")).unwrap();
        assert!(matches!(
            enum_entry.validate_value(&json!("nightly")),
            Err(ConfigError::Validation { .. })
        ));
    }

    #[test]
    fn change_wire_key_joins_module_and_key() {
        let change = ConfigChange {
            module: "download".to_string(),
            key: "multi_segment.enabled".to_string(),
            old_json: None,
            new_json: Some(json!(true)),
            revision: 7,
            source: ConfigSource::Module,
            actor: Some("gstore_mod_download".to_string()),
        };
        assert_eq!(change.wire_key(), "download.multi_segment.enabled");
        assert_eq!(change.source.as_str(), "module");
    }

    #[test]
    fn source_round_trips_through_its_wire_code() {
        for source in [
            ConfigSource::Internal,
            ConfigSource::User,
            ConfigSource::Agent,
            ConfigSource::Module,
            ConfigSource::Migration,
            ConfigSource::Restore,
        ] {
            assert_eq!(source.as_str().parse::<ConfigSource>().unwrap(), source);
        }
        assert!("nope".parse::<ConfigSource>().is_err());
    }

    /// Backup restore must use `ConfigSource::Restore`'s canonical wire code.
    /// The host passes the Dart import `source` string straight into
    /// `ConfigSource::from_str`; a non-canonical value kills the whole import.
    #[test]
    fn restore_source_uses_the_canonical_wire_code() {
        let parsed = "restore"
            .parse::<ConfigSource>()
            .expect("the backup restore source code must parse");
        assert_eq!(parsed, ConfigSource::Restore);
        assert_eq!(parsed.as_str(), "restore");
        assert!(
            "backup_restore".parse::<ConfigSource>().is_err(),
            "backup_restore is not a ConfigSource wire code"
        );
    }

    fn entry(visibility: ConfigVisibility) -> ConfigEntry {
        ConfigEntry {
            key: ConfigKey::new("download", "multi_segment.enabled").unwrap(),
            value_type: ConfigValueType::Bool,
            revision: 0,
            sensitive: false,
            agent_accessible: false,
            visibility,
            default_json: json!(false),
            description_zh: "多段下载".to_string(),
            description_en: "Multi-segment download".to_string(),
            category: "download".to_string(),
            unit: None,
            min: None,
            max: None,
            enum_values: Vec::new(),
            example: None,
        }
    }
}
