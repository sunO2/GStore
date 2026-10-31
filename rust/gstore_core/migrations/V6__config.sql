-- V6: module-scoped configuration tables for the Rust config authority.
--
-- The Rust core becomes the single writer for user configuration, so the core
-- database must hold it durably. Values are grouped by `(module, key)`:
--
--   * `config_entry` is the current state. `value_json` holds the JSON-encoded
--     value for non-sensitive entries; sensitive entries keep `value_json` NULL
--     and only a `secret_ref` (key into the Rust file secret store, mode 0600)
--     plus `secret_hash` (SHA-256 of the value, used to detect a stale secret
--     after a snapshot restore). Plaintext secrets are never written here.
--   * `config_change_log` is an append-only audit trail. Sensitive rows store
--     NULL / "***" instead of the value, so the log is safe to read.
--   * `config_meta` holds cross-cutting markers (`revision`, migration markers).
--     There is deliberately no `config_module` table: module metadata lives in
--     the Rust code registry (C25) and module uninstall keeps rows.
--
-- Additive only: no existing table or row is touched, and every statement is
-- idempotent (`IF NOT EXISTS`) so a database created by the pre-refinery spike
-- is adopted without re-creating anything.

CREATE TABLE IF NOT EXISTS config_entry(
    module TEXT NOT NULL,
    key TEXT NOT NULL,
    value_json TEXT,
    secret_ref TEXT,
    secret_hash TEXT,
    value_type TEXT,
    revision INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    updated_by TEXT,
    PRIMARY KEY(module, key)
);

CREATE INDEX IF NOT EXISTS ix_config_entry_module
    ON config_entry(module);

CREATE TABLE IF NOT EXISTS config_change_log(
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    module TEXT NOT NULL,
    key TEXT NOT NULL,
    old_json TEXT,
    new_json TEXT,
    source TEXT,
    actor TEXT,
    at INTEGER
);

CREATE INDEX IF NOT EXISTS ix_config_change_log_module_key_seq
    ON config_change_log(module, key, seq);

CREATE TABLE IF NOT EXISTS config_meta(
    k TEXT NOT NULL PRIMARY KEY,
    v TEXT
);

PRAGMA user_version = 6;
