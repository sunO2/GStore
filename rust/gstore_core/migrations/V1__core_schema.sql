-- Wave 0/1 core schema for gstore_core.
--
-- `download_task.status` vocabulary mirrors the Dart `DownloadStatusEnum`
-- (lib/core/download/model/download_task.dart) and the Rust
-- `gstore_mod_download::model::TaskStatus` predicates:
--   ACTIVE   : queued, connecting, downloading   (TaskStatus::is_active)
--              plus the legacy core label `running` (module codes 0..=2)
--   TERMINAL : completed, failed, cancelled, removed
--   PAUSED   : paused, needs_restart; resumable/waiting, not active
-- The partial unique index below only covers ACTIVE rows, so a new task may
-- reuse a dedup_key once the previous row is terminal (or paused).
--
-- This migration is applied through refinery's `schema_migrations` ledger.
-- Every statement is also idempotent (`IF NOT EXISTS`) so a database created
-- by the pre-refinery spike can be adopted without re-creating tables.

CREATE TABLE IF NOT EXISTS channels(
    key TEXT NOT NULL PRIMARY KEY,
    kind TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    priority INTEGER NOT NULL DEFAULT 0,
    support_offline INTEGER NOT NULL DEFAULT 0 CHECK(support_offline IN (0,1)),
    last_update_time INTEGER,
    version TEXT,
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS ix_channels_priority
    ON channels(enabled, priority, key);

CREATE TABLE IF NOT EXISTS channel_env(
    channel_key TEXT NOT NULL PRIMARY KEY,
    env_json TEXT NOT NULL,
    imported_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS channel_apps(
    channel_key TEXT NOT NULL,
    app_id TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    user TEXT NOT NULL DEFAULT '',
    repositories TEXT NOT NULL DEFAULT '',
    apprepo TEXT,
    icon TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    category TEXT,
    add_time INTEGER NOT NULL DEFAULT 0,
    source_id TEXT,
    extra TEXT,
    PRIMARY KEY(channel_key, app_id)
);

CREATE INDEX IF NOT EXISTS ix_channel_apps_channel_time
    ON channel_apps(channel_key, add_time DESC);

CREATE TABLE IF NOT EXISTS channel_state(
    key TEXT NOT NULL PRIMARY KEY,
    ready INTEGER NOT NULL DEFAULT 0 CHECK(ready IN (0,1)),
    last_refresh_at INTEGER,
    app_count INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS channel_packs(
    key TEXT NOT NULL PRIMARY KEY,
    pack_hash TEXT NOT NULL,
    meta_json TEXT NOT NULL DEFAULT '{}',
    installed_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS apps(
    appId TEXT NOT NULL PRIMARY KEY,
    name TEXT NOT NULL,
    user TEXT,
    repositories TEXT,
    icon TEXT,
    des TEXT,
    readme TEXT,
    category TEXT,
    extra TEXT
);

CREATE INDEX IF NOT EXISTS ix_apps_category
    ON apps(category);

-- External-content FTS5 index over apps(name, des). The triggers below keep it
-- in sync; searches can use `apps_fts MATCH ?`.
CREATE VIRTUAL TABLE IF NOT EXISTS apps_fts USING fts5(
    name,
    des,
    content='apps',
    content_rowid='rowid'
);

CREATE TRIGGER IF NOT EXISTS apps_ai AFTER INSERT ON apps BEGIN
    INSERT INTO apps_fts(rowid, name, des) VALUES (new.rowid, new.name, new.des);
END;

CREATE TRIGGER IF NOT EXISTS apps_ad AFTER DELETE ON apps BEGIN
    INSERT INTO apps_fts(apps_fts, rowid, name, des)
        VALUES ('delete', old.rowid, old.name, old.des);
END;

CREATE TRIGGER IF NOT EXISTS apps_au AFTER UPDATE ON apps BEGIN
    INSERT INTO apps_fts(apps_fts, rowid, name, des)
        VALUES ('delete', old.rowid, old.name, old.des);
    INSERT INTO apps_fts(rowid, name, des) VALUES (new.rowid, new.name, new.des);
END;

CREATE TABLE IF NOT EXISTS categories(
    id TEXT NOT NULL PRIMARY KEY,
    description TEXT NOT NULL,
    icon TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS app_config(
    version TEXT NOT NULL PRIMARY KEY,
    proxy TEXT
);

-- Future-facing download state. Created in this wave but intentionally unused:
-- no read/write business logic ships until the download todos.
CREATE TABLE IF NOT EXISTS download_task(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    module_task_id TEXT UNIQUE,
    dedup_key TEXT,
    app_id TEXT,
    app_name TEXT,
    version TEXT,
    file_name TEXT,
    kind TEXT,
    resource_id TEXT,
    resource_version TEXT,
    url TEXT,
    dest_path TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    bytes_done INTEGER NOT NULL DEFAULT 0,
    total INTEGER NOT NULL DEFAULT 0,
    speed_bps INTEGER NOT NULL DEFAULT 0,
    eta_sec INTEGER,
    segments_json TEXT,
    retries INTEGER NOT NULL DEFAULT 0,
    server_meta TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    headers_json TEXT,
    expected_sha256 TEXT,
    install_after_download INTEGER NOT NULL DEFAULT 0 CHECK(install_after_download IN (0,1)),
    error TEXT,
    last_started_at INTEGER,
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS ix_download_task_status
    ON download_task(status, priority DESC, id ASC);

-- Dedup contract: at most one ACTIVE row per dedup_key. Once the previous row
-- is TERMINAL (completed/failed/cancelled), re-inserting the same dedup_key is
-- allowed. NULL dedup_key rows never collide.
CREATE UNIQUE INDEX IF NOT EXISTS ux_download_task_active_dedup
    ON download_task(dedup_key)
    WHERE dedup_key IS NOT NULL AND status IN ('queued', 'connecting', 'downloading', 'running');

CREATE TABLE IF NOT EXISTS core_writes(
    domain TEXT NOT NULL PRIMARY KEY,
    first_write_at INTEGER NOT NULL,
    snapshot_id TEXT
);

CREATE TABLE IF NOT EXISTS update_prefs(
    key TEXT NOT NULL PRIMARY KEY,
    value TEXT NOT NULL,
    imported_at INTEGER NOT NULL
);

PRAGMA user_version = 1;
