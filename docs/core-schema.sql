-- Canonical Wave 0/1/2/3/4 schema for gstore_core.
--
-- This file is the canonical DDL text. The embedded refinery migrations
-- `rust/gstore_core/migrations/V1__core_schema.sql`,
-- `V2__catalog_update.sql`, `V3__download_install.sql`, and
-- `V4__inventory_facts.sql` must produce
-- exactly this structure; `rust/gstore_core/tests/schema_contract.rs` asserts
-- that by normalizing sqlite_master + PRAGMA table_info/index_list/index_info/
-- foreign_key_list dumps for a migrated database and for a database created by
-- executing this file. V3 adds the durable install-state columns and the
-- partial pending-install index on `download_task`; V4 adds installed-app
-- inventory, the single-row platform facts, versioned frontend rules, and the
-- five install-request columns on `download_task`.
--
-- refinery owns the `schema_migrations` ledger; its exact DDL is reproduced
-- first so this file is self-contained.
--
-- `download_task.status` vocabulary mirrors the Dart `DownloadStatusEnum`
-- (lib/core/download/model/download_task.dart) and the Rust
-- `gstore_mod_download::model::TaskStatus` predicates:
--   ACTIVE   : queued, connecting, downloading   (TaskStatus::is_active)
--   TERMINAL : completed, failed, cancelled      (TaskStatus::is_terminal)
--   PAUSED   : resumable/waiting; neither active nor terminal
-- The partial unique index only covers ACTIVE rows, so a new task may reuse a
-- dedup_key once the previous row is terminal (or paused).

CREATE TABLE IF NOT EXISTS schema_migrations(
    version INT4 PRIMARY KEY,
    name VARCHAR(255),
    applied_on VARCHAR(255),
    checksum VARCHAR(255)
);

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

-- Contentless FTS5 index mirroring the Dart `AppInfoDatabase._setupFts5`.
-- Searches use `apps_fts MATCH ?`; the triggers below keep it in sync.
CREATE VIRTUAL TABLE IF NOT EXISTS apps_fts USING fts5(
    appId UNINDEXED,
    name,
    des,
    content=''
);

CREATE TRIGGER IF NOT EXISTS apps_fts_insert AFTER INSERT ON apps BEGIN
    INSERT INTO apps_fts(rowid, appId, name, des)
    VALUES (new.rowid, new.appId, new.name, new.des);
END;

CREATE TRIGGER IF NOT EXISTS apps_fts_delete AFTER DELETE ON apps BEGIN
    INSERT INTO apps_fts(apps_fts, rowid, appId, name, des)
    VALUES ('delete', old.rowid, old.appId, old.name, old.des);
END;

CREATE TRIGGER IF NOT EXISTS apps_fts_update AFTER UPDATE ON apps BEGIN
    INSERT INTO apps_fts(apps_fts, rowid, appId, name, des)
    VALUES ('delete', old.rowid, old.appId, old.name, old.des);
    INSERT INTO apps_fts(rowid, appId, name, des)
    VALUES (new.rowid, new.appId, new.name, new.des);
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
    updated_at INTEGER NOT NULL DEFAULT 0,
    install_status TEXT NOT NULL DEFAULT 'none',
    install_method TEXT,
    install_session_id TEXT,
    install_error TEXT,
    installed_at INTEGER,
    installed_version TEXT,
    package_name TEXT,
    abi TEXT,
    variant_url TEXT,
    fallback_json TEXT,
    install_requested_at INTEGER
);

CREATE INDEX IF NOT EXISTS ix_download_task_status
    ON download_task(status, priority DESC, id ASC);

-- Reconciliation only scans pending installs.
CREATE INDEX IF NOT EXISTS ix_download_task_install_status
    ON download_task(install_status) WHERE install_status = 'pending';

-- Dedup contract: at most one ACTIVE row per dedup_key. Once the previous row
-- is TERMINAL (completed/failed/cancelled), re-inserting the same dedup_key is
-- allowed. NULL dedup_key rows never collide.
CREATE UNIQUE INDEX IF NOT EXISTS ux_download_task_active_dedup
    ON download_task(dedup_key)
    WHERE dedup_key IS NOT NULL AND status IN ('queued', 'connecting', 'downloading', 'running');

-- The timeout sweep only scans by request time.
CREATE INDEX IF NOT EXISTS ix_download_task_install_requested_at
    ON download_task(install_requested_at);

-- Wave 4: frontend-pushed inventory and platform facts, plus versioned rules.
CREATE TABLE IF NOT EXISTS installed_app(
    source_id TEXT NOT NULL,
    package_name TEXT NOT NULL,
    app_name TEXT,
    version_name TEXT NOT NULL,
    version_code INTEGER NOT NULL,
    signature_sha256 TEXT,
    source_dir TEXT,
    installer TEXT,
    is_system INTEGER NOT NULL DEFAULT 0 CHECK(is_system IN (0,1)),
    target_sdk INTEGER NOT NULL DEFAULT 0,
    min_sdk INTEGER NOT NULL DEFAULT 0,
    abis_json TEXT NOT NULL DEFAULT '[]',
    captured_at INTEGER NOT NULL,
    PRIMARY KEY(source_id, package_name)
);

CREATE INDEX IF NOT EXISTS ix_installed_app_package
    ON installed_app(package_name);

CREATE TABLE IF NOT EXISTS inventory_source(
    source_id TEXT NOT NULL PRIMARY KEY,
    seq INTEGER NOT NULL,
    captured_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS platform_facts(
    id INTEGER PRIMARY KEY CHECK(id=1),
    json TEXT NOT NULL,
    source_id TEXT NOT NULL,
    captured_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS frontend_rules(
    kind TEXT NOT NULL PRIMARY KEY,
    version INTEGER NOT NULL,
    json TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

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

-- Wave 2 catalog/update tables. These carry legacy flat ids and deliberately
-- declare no foreign keys (compatibility with older app databases).
CREATE TABLE IF NOT EXISTS added_apps(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id TEXT NOT NULL,
    app_id TEXT NOT NULL,
    add_time INTEGER NOT NULL,
    sort_order INTEGER NOT NULL,
    is_enabled INTEGER NOT NULL DEFAULT 1,
    UNIQUE(channel_id, app_id)
);

CREATE TABLE IF NOT EXISTS added_app_tags(
    channel_id TEXT NOT NULL,
    app_id TEXT NOT NULL,
    tag TEXT NOT NULL,
    add_time INTEGER NOT NULL,
    PRIMARY KEY(channel_id, app_id, tag)
);

CREATE TABLE IF NOT EXISTS update_state(
    app_id TEXT NOT NULL,
    channel_key TEXT NOT NULL,
    latest_version TEXT,
    status TEXT NOT NULL,
    checked_at INTEGER,
    payload_json TEXT,
    PRIMARY KEY(app_id, channel_key)
);

CREATE TABLE IF NOT EXISTS update_log(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id TEXT NOT NULL,
    channel_key TEXT NOT NULL,
    from_version TEXT,
    to_version TEXT,
    status TEXT NOT NULL,
    checked_at INTEGER NOT NULL,
    payload_json TEXT
);

CREATE TABLE IF NOT EXISTS outbox(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

PRAGMA user_version = 5;
