//! Channel-scoped environment snapshots for `ScriptApi`.
//!
//! Env is persisted exactly like `ChannelApi` does it: non-sensitive names live
//! in the plaintext `channel_env.env_json` row keyed by the channel, sensitive
//! names (the same case-insensitive substring rule the core uses) go to the
//! [`FileSecretStore`] under `channel.<key>.<NAME>` and never reach the row.
//! Loading reconstructs the snapshot from the row plus the pack's
//! `requiredEnvVars` secrets, so a sensitive value removed from the row is still
//! visible to its own channel after a restart.
//!
//! The live `ScriptHost` reads the snapshot behind a shared mutex, which is what
//! makes `set_env` a hot update: the next capability call sees the new map
//! without rebuilding the QuickJS runtime.

use std::collections::BTreeMap;

use gstore_core::channel_migration::is_sensitive_key;
use gstore_core::db::DbHandle;
use gstore_core::dto::ChannelKey;
use gstore_core::ports::{validate_secret_key, FileSecretPort, FileSecretStore};
use gstore_core::Error;
use rusqlite::OptionalExtension;

/// Snapshot type shared with the script host.
pub type EnvMap = BTreeMap<String, String>;

fn core_err(error: Error) -> String {
    format!("{}: {}", error.code(), error.message())
}

fn secret_name(key: &ChannelKey, name: &str) -> String {
    format!("channel.{}.{}", key.as_str(), name)
}

fn read_plain(
    db: &DbHandle,
    key: &ChannelKey,
) -> Result<serde_json::Map<String, serde_json::Value>, String> {
    let conn = db.reader().map_err(|error| core_err(Error::Io(error.0)))?;
    let raw: Option<String> = conn
        .query_row(
            "SELECT env_json FROM channel_env WHERE channel_key=?1",
            [key.as_str()],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| format!("io: read channel_env: {error}"))?;
    let Some(raw) = raw.filter(|value| !value.trim().is_empty()) else {
        return Ok(serde_json::Map::new());
    };
    let value: serde_json::Value = serde_json::from_str(&raw)
        .map_err(|error| format!("serialization: channel env is not valid JSON: {error}"))?;
    value
        .as_object()
        .cloned()
        .ok_or_else(|| "serialization: channel env must be a JSON object".to_string())
}

/// Rebuilds the snapshot for `key` from the plaintext row plus every secret
/// stored under `channel.<key>.`.
pub(crate) fn load(
    db: &DbHandle,
    secrets: &FileSecretStore,
    key: &ChannelKey,
) -> Result<EnvMap, String> {
    let mut env = EnvMap::new();
    for (name, value) in read_plain(db, key)? {
        let text = match value {
            serde_json::Value::String(text) => text,
            serde_json::Value::Null => continue,
            other => other.to_string(),
        };
        env.insert(name, text);
    }
    for name in channel_secret_names(secrets, key)? {
        if let Some(secret) = secrets.get(&secret_name(key, &name)).map_err(core_err)? {
            env.insert(name, secret);
        }
    }
    Ok(env)
}

fn channel_secret_names(
    secrets: &FileSecretStore,
    key: &ChannelKey,
) -> Result<Vec<String>, String> {
    let prefix = format!("channel.{}.", key.as_str());
    let mut names = Vec::new();
    for secret_key in secrets.list().map_err(core_err)? {
        if let Some(name) = secret_key.strip_prefix(&prefix) {
            names.push(name.to_owned());
        }
    }
    Ok(names)
}

/// Replaces the persisted env for `key` and returns the new snapshot.
pub(crate) fn save(
    db: &DbHandle,
    secrets: &FileSecretStore,
    key: &ChannelKey,
    values: &EnvMap,
) -> Result<EnvMap, String> {
    for name in values.keys() {
        validate_secret_key(name).map_err(core_err)?;
    }
    for name in channel_secret_names(secrets, key)? {
        if !values.contains_key(&name) {
            secrets.remove(&secret_name(key, &name)).map_err(core_err)?;
        }
    }
    let mut plain = serde_json::Map::new();
    for (name, value) in values {
        if is_sensitive_key(name) {
            secrets
                .set(&secret_name(key, name), value)
                .map_err(core_err)?;
        } else {
            plain.insert(name.clone(), serde_json::Value::String(value.clone()));
        }
    }
    let json = serde_json::Value::Object(plain).to_string();
    db.with_writer(|conn| {
        conn.execute(
            "INSERT INTO channel_env(channel_key, env_json, imported_at) \
             VALUES (?1, ?2, strftime('%s','now')) \
             ON CONFLICT(channel_key) DO UPDATE SET \
                 env_json = excluded.env_json, imported_at = excluded.imported_at",
            rusqlite::params![key.as_str(), json],
        )
        .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
        Ok(())
    })
    .map_err(|error| core_err(Error::Io(error.0)))?;
    Ok(values.clone())
}

/// Removes the row and every required secret for `key`.
pub(crate) fn clear(
    db: &DbHandle,
    secrets: &FileSecretStore,
    key: &ChannelKey,
) -> Result<(), String> {
    db.with_writer(|conn| {
        conn.execute(
            "DELETE FROM channel_env WHERE channel_key=?1",
            [key.as_str()],
        )
        .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
        Ok(())
    })
    .map_err(|error| core_err(Error::Io(error.0)))?;
    for name in channel_secret_names(secrets, key)? {
        secrets.remove(&secret_name(key, &name)).map_err(core_err)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sensitive_names_use_the_secret_rule() {
        assert!(is_sensitive_key("PASSWORD"));
        assert!(is_sensitive_key("api_token"));
        assert!(!is_sensitive_key("REGION"));
    }
}
