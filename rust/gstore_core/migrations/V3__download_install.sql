-- Wave 3 install state for gstore_core.
--
-- Adds the durable install columns to `download_task`. Unlike the table
-- statements in V1/V2, `ALTER TABLE ... ADD COLUMN` cannot be guarded with
-- `IF NOT EXISTS` in SQLite; this is safe because refinery applies each
-- migration exactly once (the ledger table records the applied version).
--
-- `install_status` is the state machine:
--   none -> pending -> installed | failed | denied | timeout
-- A `pending` row carries `install_session_id` so the attempt survives process
-- death and can be reconciled by the installer port. `unknown` is written by
-- reconciliation when a pending row has lost its session id.

ALTER TABLE download_task ADD COLUMN install_status TEXT NOT NULL DEFAULT 'none';
ALTER TABLE download_task ADD COLUMN install_method TEXT;
ALTER TABLE download_task ADD COLUMN install_session_id TEXT;
ALTER TABLE download_task ADD COLUMN install_error TEXT;
ALTER TABLE download_task ADD COLUMN installed_at INTEGER;
ALTER TABLE download_task ADD COLUMN installed_version TEXT;

-- Reconciliation only scans pending rows, so keep that lookup partial.
CREATE INDEX IF NOT EXISTS ix_download_task_install_status
    ON download_task(install_status) WHERE install_status = 'pending';

PRAGMA user_version = 3;
