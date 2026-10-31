//! Canonical secret policy for module-scoped configuration (C3 / C10 / C23).
//!
//! The store already knows *how* to persist a secret (versioned
//! `FileSecretPort` key, `secret_ref` + `secret_hash`, `NULL` `value_json`).
//! This module owns *where a value may be seen*: every non-trusted surface —
//! `config_change_log`, bus/FRB payloads, `list`/`snapshots`, Agent tool output,
//! and the Dart mirror — must go through the helpers below. They are pure
//! (no I/O, no clock, no store handle) so every layer can share one policy.
//!
//! Trusted surfaces are explicit and few: [`ConfigCaller::Host`],
//! [`ConfigCaller::Dart`], and the *owning* module may read raw values (needed
//! by `AgentModelStore` and the WebDAV UI); only the backup `export` may write
//! raw values into an artifact. [`trusted_read_allowed`] is the single
//! authorization predicate.
//!
//! # Why `sensitive` alone means "secret"
//!
//! [`is_secret_entry`] treats `sensitive: true` as a secret even when
//! visibility is [`ConfigVisibility::Owner`]. The WebDAV URL/username fields
//! are `Owner` + `sensitive`: they must live out-of-row and be masked on every
//! non-trusted surface, but Todo 31 still reads them raw through the trusted
//! path to drive the WebDAV client. Keeping one predicate avoids a second,
//! weaker definition drifting from the store.
//!
//! allow: SIZE_OK — the policy surface and its cross-surface acceptance tests
//! are deliberately colocated (Todo 5 owns only this file, `mod.rs`, and
//! `store.rs`).

use serde_json::Value;

use super::model::ConfigKey;
use super::model::{ConfigChange, ConfigEntry, ConfigVisibility};
use crate::ports::secret::MAX_SECRET_KEY_LEN;

/// Redaction marker used on every non-trusted surface.
pub const MASKED: &str = "***";

/// Guidance for the Dart config mirror (C2 / C3).
///
/// The mirror may cache metadata and plain values, but **never** a secret
/// plaintext: cache [`MASKED`] and fetch raw values on demand from the trusted
/// `ConfigApi.get(masked: false)` path. This constant is documentation for the
/// Dart layer; the enforceable seam is [`dart_mirror_value`].
pub const DART_MIRROR_GUIDANCE: &str =
    "Dart mirror: cache masked values only; never cache secret plaintext";

/// Caller class for config access decisions.
///
/// Mirrors the FRB/bus caller vocabulary: the host and trusted Dart are
/// trusted; a module is trusted only for its own entries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigCaller {
    /// Native host / core-owned code.
    Host,
    /// Trusted Dart/Flutter code (raw reads are an explicit opt-in).
    Dart,
    /// A configuration module identified by name.
    Module(String),
}

impl ConfigCaller {
    /// Builds a module caller.
    pub fn module(name: impl Into<String>) -> Self {
        Self::Module(name.into())
    }

    /// Whether this caller is globally trusted.
    pub const fn is_trusted(&self) -> bool {
        matches!(self, Self::Host | Self::Dart)
    }
}

/// Whether `entry` must be stored out-of-row and redacted off the trusted path.
///
/// `sensitive: true` is sufficient: sensitive-but-`Owner` WebDAV fields are
/// still secrets for storage and masking, while remaining readable raw by their
/// owner/host/Dart caller.
pub fn is_secret_entry(entry: &ConfigEntry) -> bool {
    entry.sensitive || matches!(entry.visibility, ConfigVisibility::Secret)
}

/// Masks `value` when `entry` is a secret, preserving JSON `null` as "unset".
///
/// `null` is the wire marker for "no stored value"; masking it to `***` would
/// turn an unset key into a set one.
pub fn mask_if_secret(entry: &ConfigEntry, value: &Value) -> Value {
    if is_secret_entry(entry) && !value.is_null() {
        Value::String(MASKED.to_string())
    } else {
        value.clone()
    }
}

/// Redacts an optional stored value for a report (`list`/`snapshots` DTO).
///
/// `None` stays `None` (unset), `null` stays `null` (unset), and any set secret
/// becomes `***`.
pub fn masked_report(entry: &ConfigEntry, value: Option<&Value>) -> Option<Value> {
    value.map(|value| mask_if_secret(entry, value))
}

/// Redacts a value destined for `config_change_log`.
///
/// Secrets produce SQL `NULL` when unset and the literal `"***"` when set —
/// never plaintext. Non-secrets are returned unchanged.
pub fn redact_change_log_value(entry: &ConfigEntry, value: Option<&Value>) -> Option<Value> {
    match value {
        None => None,
        Some(_) if is_secret_entry(entry) => Some(Value::String(MASKED.to_string())),
        Some(value) => Some(value.clone()),
    }
}

/// Builds the publishable (masked) change event.
///
/// Pure and idempotent: applying it to an already-masked change leaves it
/// masked, so the bus can defend in depth without knowing who produced the
/// event.
pub fn masked_change_payload(entry: &ConfigEntry, change: &ConfigChange) -> ConfigChange {
    ConfigChange {
        module: change.module.clone(),
        key: change.key.clone(),
        old_json: redact_change_log_value(entry, change.old_json.as_ref()),
        new_json: redact_change_log_value(entry, change.new_json.as_ref()),
        revision: change.revision,
        source: change.source,
        actor: change.actor.clone(),
    }
}

/// Redacts one `list`/`snapshots` DTO value.
pub fn masked_snapshot_value(entry: &ConfigEntry, value: &Value) -> Value {
    mask_if_secret(entry, value)
}

/// Redacts one value returned by an Agent tool.
///
/// The Agent is a non-trusted caller even for `Owner` + `sensitive` entries.
pub fn masked_agent_tool_output(entry: &ConfigEntry, value: &Value) -> Value {
    mask_if_secret(entry, value)
}

/// The only value the Dart mirror may cache for `entry`.
pub fn dart_mirror_value(entry: &ConfigEntry, value: &Value) -> Value {
    mask_if_secret(entry, value)
}

/// Whether `caller` may read the raw (unmasked) value of `entry`.
///
/// * `Host` and `Dart` are trusted for every entry.
/// * A module may read its own entries (including secrets) raw.
/// * A foreign module may read raw only a non-secret `PublicRead` entry; it may
///   never read an `Owner`/`Secret` entry, and a sensitive `PublicRead` entry
///   would be masked even if one were ever registered.
pub fn trusted_read_allowed(caller: &ConfigCaller, entry: &ConfigEntry) -> bool {
    match caller {
        ConfigCaller::Host | ConfigCaller::Dart => true,
        ConfigCaller::Module(module) => {
            module == entry.key.module()
                || (!is_secret_entry(entry) && entry.visibility.allows_foreign_read())
        }
    }
}

/// Builds the versioned secret key for `(key, revision)` (C10 / C23).
///
/// The normal form is `config.<module>.<key>.<revision>`. When that exceeds
/// [`MAX_SECRET_KEY_LEN`], the base is SHA-256 hashed:
/// `config.h<sha256(module.key)>.<revision>`. Both forms end in the numeric
/// revision so the store's GC can classify them.
pub fn secret_ref_for(key: &ConfigKey, revision: u64) -> String {
    let base = format!("config.{}.{}", key.module(), key.key());
    let candidate = format!("{base}.{revision}");
    if candidate.len() <= MAX_SECRET_KEY_LEN {
        candidate
    } else {
        let hashed = sha256_hex(base.as_bytes());
        format!("config.h{hashed}.{revision}")
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

/// Namespace describing the four redaction seams.
///
/// Thin associated-function facade over the free functions so callers that
/// prefer a name (bus/FRB/Agent) can group them without duplicating policy.
#[derive(Debug, Clone, Copy, Default)]
pub struct ConfigRedactor;

impl ConfigRedactor {
    /// Masked change event (see [`masked_change_payload`]).
    pub fn change(entry: &ConfigEntry, change: &ConfigChange) -> ConfigChange {
        masked_change_payload(entry, change)
    }

    /// Masked `list`/`snapshots` value (see [`masked_snapshot_value`]).
    pub fn snapshot(entry: &ConfigEntry, value: &Value) -> Value {
        masked_snapshot_value(entry, value)
    }

    /// Masked Agent tool output (see [`masked_agent_tool_output`]).
    pub fn agent_tool(entry: &ConfigEntry, value: &Value) -> Value {
        masked_agent_tool_output(entry, value)
    }

    /// Value the Dart mirror may cache (see [`dart_mirror_value`]).
    pub fn dart_mirror(entry: &ConfigEntry, value: &Value) -> Value {
        dart_mirror_value(entry, value)
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;

    use rusqlite::Connection;
    use serde_json::json;

    use super::*;
    use crate::config::error::ConfigError;
    use crate::config::model::ConfigSource;
    use crate::config::schema;
    use crate::config::store::{ConfigStore, ConfigStoreError};
    use crate::db::DbHandle;
    use crate::ports::secret::{FileSecretPort, FileSecretStore, MAX_SECRET_KEY_LEN};

    fn key(module: &str, name: &str) -> ConfigKey {
        ConfigKey::new(module, name).expect("valid test key")
    }

    fn entry(module: &str, name: &str) -> &'static ConfigEntry {
        schema::entry(&key(module, name)).expect("registered entry")
    }

    struct Fixture {
        root: PathBuf,
        db: DbHandle,
        secrets: Arc<FileSecretStore>,
    }

    impl Fixture {
        fn new(tag: &str) -> Self {
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "gstore_cfg_secrets_{tag}_{}_{counter}",
                std::process::id()
            ));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).expect("create temp root");
            let db = DbHandle::open(&root.join("data")).expect("open core db");
            let secrets = Arc::new(FileSecretStore::new(root.join("secrets")));
            Self { root, db, secrets }
        }

        fn store(&self) -> ConfigStore {
            let store = ConfigStore::new(self.db.clone(), self.secrets.clone());
            store.load_all().expect("load all");
            store
        }

        fn conn(&self) -> Connection {
            Connection::open(self.db.path()).expect("open raw connection")
        }

        fn secret_keys(&self) -> Vec<String> {
            self.secrets.list().expect("list secrets")
        }

        fn assert_absent_from_data_dir(&self, plaintext: &str) {
            for item in
                fs::read_dir(self.db.path().parent().expect("data dir")).expect("read data dir")
            {
                let path = item.expect("dir entry").path();
                assert_absent(&read_text(&path), plaintext, &format!("db file {path:?}"));
            }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn read_text(path: &Path) -> String {
        String::from_utf8_lossy(&fs::read(path).unwrap_or_default()).into_owned()
    }

    fn assert_absent(haystack: &str, needle: &str, surface: &str) {
        assert!(
            !haystack.contains(needle),
            "{surface} leaked the secret plaintext: {haystack}"
        );
    }

    fn hexish(value: &str) -> bool {
        value.len() == 64 && value.chars().all(|c| c.is_ascii_hexdigit())
    }

    #[test]
    fn policy_predicates_follow_the_registry_entry() {
        let password = entry("webdav", "password");
        let models = entry("agent", "models");
        let url = entry("webdav", "url");
        let max_concurrent = entry("download", "max_concurrent");
        let proxy = entry("network", "proxy_url");

        assert!(is_secret_entry(password), "webdav.password is Secret");
        assert!(is_secret_entry(models), "agent.models is Secret");
        assert!(
            is_secret_entry(url),
            "sensitive Owner (webdav.url) must still be treated as a secret"
        );
        assert!(!is_secret_entry(max_concurrent), "plain Owner entry");
        assert!(!is_secret_entry(proxy), "PublicRead plain entry");
        assert_eq!(proxy.visibility, ConfigVisibility::PublicRead);

        assert_eq!(mask_if_secret(password, &json!("x")), json!(MASKED));
        assert_eq!(mask_if_secret(password, &Value::Null), Value::Null);
        assert_eq!(mask_if_secret(max_concurrent, &json!(5)), json!(5));
        assert_eq!(masked_report(password, None), None);
        assert_eq!(
            masked_report(password, Some(&Value::Null)),
            Some(Value::Null)
        );
        assert_eq!(
            masked_report(password, Some(&json!("x"))),
            Some(json!(MASKED))
        );
        assert_eq!(redact_change_log_value(password, None), None);
        assert_eq!(
            redact_change_log_value(password, Some(&json!("x"))),
            Some(json!(MASKED))
        );
        assert_eq!(
            redact_change_log_value(max_concurrent, Some(&json!(5))),
            Some(json!(5))
        );

        assert_eq!(
            ConfigRedactor::snapshot(password, &json!("x")),
            json!(MASKED)
        );
        assert_eq!(
            ConfigRedactor::agent_tool(url, &json!("https://dav.example")),
            json!(MASKED)
        );
        assert_eq!(dart_mirror_value(password, &json!("x")), json!(MASKED));
        assert!(DART_MIRROR_GUIDANCE.contains("never cache"));
    }

    #[test]
    fn secret_is_out_of_row_and_masked_on_every_non_trusted_surface() {
        let fx = Fixture::new("surface");
        let store = fx.store();
        let password = key("webdav", "password");
        let plaintext = "hunter2-todo5-plaintext";
        let change = store
            .set(
                &password,
                json!(plaintext),
                ConfigSource::User,
                Some("qa".into()),
            )
            .expect("set secret");

        let conn = fx.conn();
        let (value_json, secret_ref, secret_hash): (
            Option<String>,
            Option<String>,
            Option<String>,
        ) = conn
            .query_row(
                "SELECT value_json, secret_ref, secret_hash FROM config_entry \
                 WHERE module='webdav' AND key='password'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("raw row");
        assert_eq!(
            value_json, None,
            "secret plaintext must never be in value_json"
        );
        let reference = secret_ref.expect("secret_ref");
        assert!(
            reference.starts_with("config.webdav.password."),
            "ref {reference}"
        );
        assert!(hexish(&secret_hash.expect("secret_hash")), "sha256 hash");

        assert_eq!(store.get(&password).expect("trusted get"), json!(plaintext));
        assert_eq!(
            store.get_masked(&password).expect("masked get"),
            json!(MASKED)
        );

        let listed = store.list("webdav").expect("list");
        let listed = listed.iter().find(|s| s.key == password).expect("listed");
        assert!(listed.masked);
        assert_eq!(listed.value, Some(json!(MASKED)));

        let snapshot = store
            .snapshots(None)
            .expect("snapshots")
            .into_iter()
            .find(|s| s.key == password)
            .expect("snapshot");
        assert!(snapshot.masked);
        assert_eq!(snapshot.value, Some(json!(MASKED)));

        assert_absent(&format!("{change:?}"), plaintext, "change event");
        let republished = masked_change_payload(entry("webdav", "password"), &change);
        assert_absent(
            &format!("{republished:?}"),
            plaintext,
            "masked change payload",
        );
        assert_eq!(republished.new_json, Some(json!(MASKED)));
        assert_absent(
            &format!(
                "{:?}",
                masked_agent_tool_output(entry("webdav", "password"), &json!(plaintext))
            ),
            plaintext,
            "agent tool output",
        );
        assert_absent(
            &format!(
                "{:?}",
                dart_mirror_value(entry("webdav", "password"), &json!(plaintext))
            ),
            plaintext,
            "dart mirror",
        );

        let log_dump: String = conn
            .query_row(
                "SELECT COALESCE(group_concat(old_json), '') || '|' || \
                        COALESCE(group_concat(new_json), '') FROM config_change_log",
                [],
                |row| row.get(0),
            )
            .expect("log dump");
        assert_absent(&log_dump, plaintext, "config_change_log");
        let (old_json, new_json): (Option<String>, Option<String>) = conn
            .query_row(
                "SELECT old_json, new_json FROM config_change_log \
                 WHERE module='webdav' AND key='password'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("log row");
        assert_eq!(old_json, None);
        assert_eq!(new_json.as_deref(), Some(MASKED));
        fx.assert_absent_from_data_dir(plaintext);

        let exported = store.export().expect("export");
        assert_eq!(
            exported
                .iter()
                .find(|e| e.key == password)
                .expect("exported")
                .value,
            json!(plaintext),
            "the backup export is the intentional raw surface"
        );

        store
            .set(&password, json!("rotated-todo5"), ConfigSource::User, None)
            .expect("rotate");
        let snapshots = store.snapshots(None).expect("snapshots after rotation");
        assert_absent(
            &format!("{snapshots:?}"),
            plaintext,
            "snapshots after rotation",
        );
        assert_absent(
            &format!("{snapshots:?}"),
            "rotated-todo5",
            "snapshots after rotation",
        );
        let keys = fx.secret_keys();
        assert_eq!(keys.len(), 1, "the old versioned key is deleted: {keys:?}");
        assert_eq!(
            store.get(&password).expect("rotated get"),
            json!("rotated-todo5")
        );
    }

    #[test]
    fn agent_models_is_masked_everywhere_but_exported_raw() {
        let fx = Fixture::new("agent");
        let store = fx.store();
        let models = key("agent", "models");
        let api_key = "sk-todo5-agent-key";
        let value = json!([{"id": "gpt", "apiKey": api_key}]);
        store
            .set(&models, value.clone(), ConfigSource::Agent, None)
            .expect("set models");

        assert_eq!(store.get(&models).expect("raw get"), value);
        assert_eq!(
            store.get_masked(&models).expect("masked get"),
            json!(MASKED)
        );

        let listed = store.list("agent").expect("list");
        let listed = listed.iter().find(|s| s.key == models).expect("listed");
        assert!(listed.masked);
        assert_eq!(listed.value, Some(json!(MASKED)));

        let conn = fx.conn();
        let log_dump: String = conn
            .query_row(
                "SELECT COALESCE(group_concat(old_json), '') || '|' || \
                        COALESCE(group_concat(new_json), '') FROM config_change_log",
                [],
                |row| row.get(0),
            )
            .expect("log dump");
        assert_absent(&log_dump, api_key, "config_change_log");
        fx.assert_absent_from_data_dir(api_key);

        let exported = store.export().expect("export");
        assert_eq!(
            exported
                .iter()
                .find(|e| e.key == models)
                .expect("exported")
                .value,
            value,
            "the backup export is the intentional raw surface"
        );
    }

    #[test]
    fn oversized_secret_key_is_hashed_and_bounded() {
        let long = key(&"a".repeat(64), &"b".repeat(64));
        let reference = secret_ref_for(&long, 42);
        assert!(
            reference.len() <= MAX_SECRET_KEY_LEN,
            "ref {}",
            reference.len()
        );
        assert!(reference.starts_with("config.h"), "hashed ref {reference}");
        assert!(reference.ends_with(".42"));
        assert!(hexish(&reference["config.h".len()..reference.len() - 3]));
        assert_eq!(reference, secret_ref_for(&long, 42), "deterministic");
        let expected = format!(
            "config.h{}.42",
            sha256_hex(format!("config.{}.{}", long.module(), long.key()).as_bytes())
        );
        assert_eq!(reference, expected);
        assert_eq!(
            secret_ref_for(&key("webdav", "password"), 7),
            "config.webdav.password.7"
        );
    }

    #[test]
    fn trusted_read_allowed_matrix() {
        let host = ConfigCaller::Host;
        let dart = ConfigCaller::Dart;
        let owner = ConfigCaller::module("webdav");
        let foreign = ConfigCaller::module("theme");

        assert!(host.is_trusted() && dart.is_trusted());
        assert!(!owner.is_trusted(), "a module is not globally trusted");

        for entry in [
            entry("webdav", "password"),
            entry("webdav", "url"),
            entry("download", "max_concurrent"),
            entry("network", "proxy_url"),
        ] {
            assert!(trusted_read_allowed(&host, entry), "host: {}", entry.key);
            assert!(trusted_read_allowed(&dart, entry), "dart: {}", entry.key);
        }
        assert!(trusted_read_allowed(&owner, entry("webdav", "password")));
        assert!(trusted_read_allowed(&owner, entry("webdav", "url")));
        assert_eq!(owner, ConfigCaller::module("webdav"));

        assert!(!trusted_read_allowed(&foreign, entry("webdav", "password")));
        assert!(!trusted_read_allowed(&foreign, entry("webdav", "url")));
        assert!(
            !trusted_read_allowed(&foreign, entry("download", "max_concurrent")),
            "Owner is owner-only even when not sensitive"
        );
        assert!(trusted_read_allowed(
            &foreign,
            entry("network", "proxy_url")
        ));
    }

    #[test]
    fn malformed_input_is_rejected_without_a_write() {
        let fx = Fixture::new("malformed");
        let store = fx.store();

        let unknown = key("download", "nope");
        assert!(matches!(
            store.get(&unknown),
            Err(ConfigStoreError::Config(ConfigError::UnknownKey { .. }))
        ));
        assert!(matches!(
            store.set(
                &key("webdav", "password"),
                json!(42),
                ConfigSource::User,
                None
            ),
            Err(ConfigStoreError::Config(ConfigError::TypeMismatch { .. }))
        ));
        assert!(fx.secret_keys().is_empty());
        let conn = fx.conn();
        let rows: i64 = conn
            .query_row("SELECT COUNT(*) FROM config_entry", [], |row| row.get(0))
            .expect("count");
        assert_eq!(rows, 0);
    }
}
