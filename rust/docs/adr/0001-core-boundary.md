# ADR 0001: The core is a data service, not a platform driver

- Status: accepted
- Date: 2026-10-23
- Supersedes: the wave-04 platform-adapter direction

## Context

The migration plan injected Android capabilities into Rust (`PlatformHost`, JNI bridges,
`InstallerPort`) so the core could act headlessly. In practice the core depended on a JavaVM and
on Android class layouts, every future frontend would have had to re-implement the same adapters
inside Rust, and seven FRB functions only forwarded raw JSON from Dart to Kotlin and back.

## Decision

The core receives FACTS and returns DECISIONS/EVENTS. No edge inside `gstore_core` calls
platform code.

- Frontend -> core: `PlatformFacts`, `InventorySnapshot`, `InstallReport`, `InstallRules`,
  `UpdateRules`, `setOnline`.
- Core -> frontend: `UpdateCandidate[]`, `InstallStart`, `InstallRequest` (also via
  `install.requested`), `DownloadTask`, `inventory.changed`, `install.unknown`.
- Core owns: catalog, channels, packs, inventory, facts, update judgement, variant selection,
  download queue, database.
- Frontend owns: installed-app query, install/uninstall/launch execution, notifications,
  foreground service, permission UI, file picker, `content://` materialisation, secret keys.

Frontend rules are data (`frontend_rules`, versioned), never callbacks.

## Exceptions (module level, allowlisted)

`gstore_mod_proxy` creates sockets and resolves packet UIDs inside Rust. Two primitives stay:
`protect_fd(fd) -> bool` and `uid -> package` lookup. They are injected through the module ABI
(`gstore_contract`) and the host allowlist (`jvm.rs`, `jni_bridge.rs`, `tun_bridge.rs`,
`dl_adapter.rs`). `gstore_core` never sees them.

## Consequences

- `gstore_core` builds and tests on any host; a TUI/macOS/Linux frontend is first-class.
- Install becomes request/response with an enumerated status, a read-driven timeout and a
  late-report path.
- Platform data can be stale; the core fails closed per app (`inventory_missing` /
  `inventory_stale`) instead of deciding on old data, and a global missing `PlatformFacts`
  aborts.
- One extra hop for install results (Kotlin -> Dart -> core) in exchange for zero platform
  coupling in the core.
- `PerfOverlayService.kt` keeps its own `/proc` + Shizuku path for the native HUD; it is a
  known duplicate and out of scope.

## Wave 6B cutover (2026-10-23)

Download and install are now core-owned in production. This section records the cutover as
shipped; the decisions above are unchanged.

- No Dart fallback and no runtime kernel selector. `IDownloadService` is bound directly to
  `RustDownloadService`; `DownloadCoreConfig` / `LazyDownloadService` and the module-direct
  branches were deleted. A missing download module is the typed
  `CORE_E_DOWNLOAD_MODULE_UNAVAILABLE`, never a switch back to the Dart `DownloadManager`.
- Install is core-only: `installTask` always goes through the core install facade. A missing
  mirror row is `CORE_E_INSTALL_NOT_FOUND`. A user-picked APK still uses the direct
  Shizuku/AppInstaller path (`_installApkDirect`), which creates no core state.
- The process default is `Flags::WAVE06_CLOSEOUT`: all six domains (channels, js_channel,
  catalog, update, download, install) are core-owned. `Flags::DISABLED` remains the all-off
  opt-out, and `CoreFlags.set` is a test seam, not a durable switch; the durable one-time
  cutover (single `pre-closeout-<millis>.db` snapshot, ordered resync, atomic
  `cutover_v6.done` marker) lives in the Dart `CoreCutover`/`CoreBootstrap`. Rust stays the
  source of truth and `core_writes` is never operator-settable.

### Download is two layers

Dart adapter -> facade -> FRB -> core port -> module:

1. `RustDownloadService` (Dart adapter; the only `IDownloadService` binding) shapes requests,
   forwards `headers`, and implements `forceDownload` by restarting the newest same-`destPath`
   core row.
2. `DownloadFacade` (typed Dart boundary over FRB) maps core errors, including the
   module-unavailable marker, onto typed Dart exceptions.
3. FRB `DownloadApi` enforces the `CORE_E_DOWNLOAD_*` contract.
4. The `gstore_core` download port owns queue state and the SQLite mirror.
5. `gstore_mod_download` performs the transfer.

Two databases follow from this split. The core owns the mirror DB (`gstore_core.db`); the
module owns its own DB (`gstore_mods/download/download.db`). The core treats the module DB as
read-only: it opens it only through `legacy::open_read_only` for parity/reconcile/resync and
never mutates module rows. The module remains authoritative for live progress, so the mirror
can lag by one reconcile sweep and `resync` must never "fix" module state.
