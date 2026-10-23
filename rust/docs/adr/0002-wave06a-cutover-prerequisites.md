# ADR 0002: Wave 6A cutover prerequisites and their consequences

- Status: accepted
- Date: 2026-10-23
- Related: `.omo/plans/gstore-rust-core-wave06a.md` (base `wave04-boundary` / `00b85a31`)

## Context

Wave 6A built and proved the cutover machinery without flipping any flag: a failure-safe
`importSnapshot` restore, per-domain `core_writes` markers projected into the flags read path, a
`LegacyWriteGuard` driven by the marker, one production `gstore/install_events` subscriber, a
three-way download resync, and partial flag flips with a bootstrap refresh. Those mechanisms
impose constraints that later waves must respect; this ADR records them.

## Consequences

### 1. The core reads the module DB only read-only, only from resync

`CoreApi.resyncDownloads` is the only place `gstore_core` opens the download module's SQLite file,
and it does so through `legacy::open_read_only` (`SQLITE_OPEN_READ_ONLY`). The host never owns that
handle; the module opens it read-write for its own lifecycle.

- Resync cannot mutate module state; the module stays authoritative for live progress.
- A crashed module WAL without `-shm` can make a dry run create a `-shm` sidecar (filesystem-only;
  DB content and WAL bytes are unchanged). Dry-run "no writes" is therefore a statement about the
  databases, not about every inode.

### 2. The core mirror lags the module between sweeps

Live module progress reaches the core `download_task` mirror only after a reconcile sweep
(`HostDownloadPort::refresh_and_list` → `reconcile`; `snapshot` deliberately does not reconcile).

- `resync`'s `core_rows` can lag the module by up to one sweep, so `missing` may be transiently
  non-zero; it does not converge to zero for core-only rows by design.

### 3. Divergent dedup lineage is a hard conflict, not a merge

Floor rows derive `legacy:<url>|<dest_path>` while module/Dart rows derive
`app:<app_id>:<version>:<file_name>`. The resync conflict rule treats one logical
`(app_id, version, file_name)` carrying two different `dedup_key`s as a conflict and aborts with
`CORE_E_DOWNLOAD_RESYNC_CONFLICT` before any write.

- After a legacy Floor import, resync aborts until the legacy lineage is normalized or the stale
  rows are removed. This is fail-closed on purpose: resync never guesses which lineage wins.

### 4. `needs_restart` is a one-way door

When the module DB is absent, non-terminal core rows are marked `needs_restart` (no error). If a
fresh, empty module DB later appears, those rows still carry their old `module_task_id`, and the
absent-task conflict rule aborts subsequent runs.

- Recovery requires clearing/null-ing those `module_task_id`s or restoring a module DB with
  matching ids.

### 5. Snapshot restore is failure-safe, not crash-safe

`DbHandle::replace_from_snapshot` validates before touching the live DB, takes a
`files_dir/migration/backups/pre-restore-*.db` backup, swaps under the writer mutex, and
compensates on any error path. It does not fsync directories, so a process death mid-swap is not
covered.

- Recovery points after a crash are the `.restore-old` file and the pre-restore backup.

### 6. The per-domain marker is authoritative, the global flag is advisory

`LegacyWriteGuard` probes `CoreApi.coreWriteMarker(domain)` even when
`CoreFlags.coreWrites` is false; there is no client-side marker cache. The global projection is a
mirror, not a gate.

- A marker transaction that rolls back can leave the process projection armed while the row is
  absent. That direction is fail-closed (legacy writes are blocked early); the DB marker remains
  the authority.
- Init-time reconcile/seeding runs under a suppression guard so no marker is written during
  `init`, matching the migration/import/snapshot rule.

### 7. Wave 6A flips nothing

`CoreFlags.set(...)` exists and forwards a partial patch, but 6A has no production call site.
`DownloadCoreConfig.resolve` still ignores `CoreFlags.download`, and `LazyDownloadService` remains
the bound download implementation. A flag flip alone cannot switch behaviour until 6B changes the
binding.

## Next step

Wave 5 (`gstore-rust-core-android-wave05`) must complete first. 6B
(`gstore-rust-core-wave06b`) is blocked until the Wave 5 closeout tag exists.
