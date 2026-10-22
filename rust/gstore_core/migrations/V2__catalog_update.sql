-- Wave 2 catalog/update schema for gstore_core.
--
-- Creates the added-apps/tags, update state/log, and outbox tables, and
-- rebuilds `apps_fts` to the contentless shape the Dart app uses
-- ("Mirror AppInfoDatabase._setupFts5"). No foreign keys are declared here on
-- purpose: these tables carry legacy flat ids and must stay compatible with
-- databases created by older app versions.
--
-- Every statement is idempotent. The FTS block drops the V1 external-content
-- table and its triggers before recreating them, then backfills from `apps`
-- so re-running this migration never duplicates FTS rows.

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

-- Rebuild the FTS index to the Dart contentless shape. Drop the V1 triggers
-- first (they reference the old table), then the table itself.
DROP TRIGGER IF EXISTS apps_ai;
DROP TRIGGER IF EXISTS apps_ad;
DROP TRIGGER IF EXISTS apps_au;
DROP TRIGGER IF EXISTS apps_fts_insert;
DROP TRIGGER IF EXISTS apps_fts_delete;
DROP TRIGGER IF EXISTS apps_fts_update;
DROP TABLE IF EXISTS apps_fts;

-- `contentless_delete=1` keeps the Dart delete-by-rowid triggers working:
-- stock SQLite rejects DELETE on a plain contentless FTS5 table.
CREATE VIRTUAL TABLE apps_fts USING fts5(
    appId UNINDEXED,
    name,
    des,
    content='',
    contentless_delete=1
);

CREATE TRIGGER IF NOT EXISTS apps_fts_insert AFTER INSERT ON apps BEGIN
    INSERT INTO apps_fts(rowid, appId, name, des)
    VALUES (new.rowid, new.appId, new.name, new.des);
END;

CREATE TRIGGER IF NOT EXISTS apps_fts_delete AFTER DELETE ON apps BEGIN
    DELETE FROM apps_fts WHERE rowid = old.rowid;
END;

CREATE TRIGGER IF NOT EXISTS apps_fts_update AFTER UPDATE ON apps BEGIN
    DELETE FROM apps_fts WHERE rowid = old.rowid;
    INSERT INTO apps_fts(rowid, appId, name, des)
    VALUES (new.rowid, new.appId, new.name, new.des);
END;

INSERT INTO apps_fts(rowid, appId, name, des)
    SELECT rowid, appId, name, des FROM apps ORDER BY rowid;

PRAGMA user_version = 2;
