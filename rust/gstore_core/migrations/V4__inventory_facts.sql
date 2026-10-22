-- Wave 4 core-boundary schema: platform facts, inventory, and frontend rules.
--
-- The core is a data service: the frontend pushes inventory snapshots and
-- platform facts in, and reads decisions back. These tables are the durable
-- store for that data and for the versioned frontend rule overrides.
--
-- As in V3, `ALTER TABLE ... ADD COLUMN` cannot be guarded with
-- `IF NOT EXISTS` in SQLite. This is safe because refinery applies each
-- migration exactly once (the ledger table records the applied version), so
-- these statements never run twice on the same database.
--
-- `installed_app` is keyed by `(source_id, package_name)` and is replaced per
-- source on every accepted snapshot. `inventory_source` keeps the accepted
-- sequence and capture time per source, which is what the stale-seq policy
-- compares against even when a snapshot carries an empty app list.
-- `platform_facts` is a single row (`id=1`). `frontend_rules` stores one JSON
-- document per rule kind (`install` / `update`), versioned in the row.

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

ALTER TABLE download_task ADD COLUMN package_name TEXT;
ALTER TABLE download_task ADD COLUMN abi TEXT;
ALTER TABLE download_task ADD COLUMN variant_url TEXT;
ALTER TABLE download_task ADD COLUMN fallback_json TEXT;
ALTER TABLE download_task ADD COLUMN install_requested_at INTEGER;

-- The timeout sweep only scans by request time.
CREATE INDEX IF NOT EXISTS ix_download_task_install_requested_at
    ON download_task(install_requested_at);

PRAGMA user_version = 4;
