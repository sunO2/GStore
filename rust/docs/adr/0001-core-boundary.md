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
