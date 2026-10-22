# Android Wave 3 — completion record

- **Scope:** Rust-core download/install orchestration (`gstore-rust-core-android-wave03`).
  Wave 4/5/6 are explicitly **not started**.
- **Repo / branch:** `GStore-wave02` @ `wave02/rust-core-catalog`
- **Base:** `e5692829` (`e5692829407a3c98ba4f9fc5ed4bdf9fbec59620`, Wave 2 HEAD)
- **Feature HEAD:** `6ea4de02e0acaa4b697d42746ca76d907020da70`
  (`fix(download): import legacy before any core read`)
- **Final code HEAD:** `42dfde34f5896ab588ffa701c1ee776baafbbe5d`
  (`docs(download): record final-wave fixes`). This is the HEAD whose tree
  contains all final Wave-3 code; its own diff is docs-only, and the last
  code-changing commit is `e918c77a` (the fixes `ce7ef133` and `e918c77a`
  precede it).
- **Wave 3 docs HEAD at close:** `2915f462b49d03c483a3dac1c1fefbe1501866af`
  (`docs(download): rebuild release APK for final HEAD`). Docs-only; superseded
  by the later docs reconciliation commits on the same branch. It is after the
  release rebuild and its only changes are `docs/wave03-completion.md` and
  `docs/wave03-evidence.md`.
- **Gate 3 close commit:** `8a9c759f` (`test(download): close Wave 3 Gate`,
  `Plan-Todo: 8`), on the same branch.
- **Date:** 2026-10-22
- **Toolchain:** rustc/cargo 1.92.0, Flutter 3.44.8 (stable), FRB codegen 2.11.1

## TL;DR

Wave 3 is wired and gated at code/release level. `ModuleDownloadPort` is hosted
by `gstore_host`, `download_task` is the authoritative core table with the module
DB as an internal engine store, `InstallService` + Android `InstallerBridge`
provide durable install results, and notification/FGS is Rust-owned through the
existing `PlatformHost` capabilities. Dart `RustDownloadService`, `InstallManager`,
`DownloadTaskWatcher`, and `DownloadNotificationService` delegate only behind
their flags; **all flags remain false by default** and the legacy Dart path stays
authoritative and undeleted.

Gate 3 result: **PASS** on Rust, Flutter focused regression, parity (download,
channel, catalog), baseline-aware quality, clippy, FRB codegen idempotency,
Kotlin compile, and the release APK. **Device QA is BLOCKED (no ADB device)** —
no on-device install/notification/FGS claim is made.

The release APK was rebuilt at/after code HEAD `42dfde34` after the final-wave
fixes (`ce7ef133`, `e918c77a`): 150589102 bytes, sha256
`0bab385b600bc7d6f8fec419a2760083c22d01fd85291e4c9a3a85e81dcd38b3`, mtime
2026-10-22 22:40:57 +0800. The earlier pre-rebuild APK hash
`bf6d90eb67cbbf6a77daf549c2fc394e5eef06e31f27df23a47acf4b02340382` is **superseded**
(predates `ce7ef133`/`e918c77a`; mtime 21:43) and is kept only as history
(see `docs/wave03-evidence.md`).

Evidence: `target/test-evidence/87-gate3.txt` (matrix) and
`target/test-evidence/87-gate3-fail.txt` (injected failures).
`target/` is local-only/gitignored; see `docs/wave03-evidence.md`.

## Scope delivered

- Host wiring for existing `ModuleDownloadPort` / `DownloadPort`; core
  `download_task` populated by start/get/reconcile and reconciled with the
  module DB.
- FRB `DownloadApi` (`start/list/get/pause/resume/cancel/retry/restart/remove/
  watchAll`, 500 ms change-only terminal-correct stream). Every `list` and every
  watch tick runs a best-effort `reconcile()` first, so module progress/terminal
  state is reflected in the core rows; an unmounted/failing module is logged and
  the authoritative core rows are still returned.
- FRB `InstallApi` (`install/get/uninstall/launch/canInstall/listPending/
  reconcile`); `InstallApi::init` pumps `reconcile()` every 500 ms so async
  PackageInstaller/Intent results become durable without an explicit caller.
- V3 `download_task` install state (`install_status`, `install_method`,
  `install_session_id`, `install_error`, `installed_at`, `installed_version`)
  plus durable `InstallService` results and `install.result` events.
- Android `InstallerBridge`: Shizuku first, PackageInstaller session second,
  system Intent fallback; typed denial/timeout results and durable pending
  sessions; no Activity `onActivityResult` dependency.
- Notification/FGS via `PlatformHost::notify/start_foreground/stop_foreground`
  (channels reused, FGS id `997`, 500 ms progress throttle, permission-gated).
- Legacy Floor/module migration and path/status parity with real Dart; injected
  field/path drift fails the parity gate.

## Commits (`e5692829..6ea4de02`)

| Commit | Plan-Todo | Subject |
|---|---|---|
| `d7c8f4516c192de9b59dda92a0fe95e75afb26ba` | 1 | feat(download): wire core port into host |
| `b8d36e366bacb961bc95c5cff3442abc32adef4c` | 2 | feat(download): expose DownloadApi and watch stream |
| `d5c54b41494a57726b2af6e6a7bdc1ef49276d74` | 3 | feat(install): add install state and service |
| `496d78ae7f71d042b2168415826426f2fc6a94d1` | 3 fix | fix(install): preserve reconcile events and idempotent retries |
| `081c45553f1673d1f1ff0734e9eb4cda4ef3eb76` | 4 | feat(android): add installer bridge and durable results |
| `5c832f7240fdeb7ec2fe3617283de74e263a6eea` | 4 fix | fix(android): make installer recovery and timeouts durable |
| `d014e2ff8a291e9d3974bf6a46327de403c31921` | 4 fix | fix(installer): keep live pending sessions and drop id guessing |
| `7ebb7771c7be4182bb3b19ee8dc8c054241cd622` | 5 | feat(android): add notification and FGS bridge |
| `854b3b5ac7bf8dd969f583723c512c0d15361047` | 5 fix | fix(android): keep FGS notification ongoing and retry after denial |
| `522e43ef3f75a6c2d2169564fd635c777eab19be` | 6 | feat(download): expose DownloadApi/InstallApi behind flags |
| `c578b110dc73539311042b53df667c68eabccb77` | 7 | test(download): add legacy migration and parity |
| `6ea4de02e0acaa4b697d42746ca76d907020da70` | 7 fix | fix(download): import legacy before any core read |
| `8a9c759f` | 8 | test(download): close Wave 3 Gate |

The Todo 8 hash is not written into its own commit (self-reference); it is the
`test(download): close Wave 3 Gate` commit on the same branch.

## Final-wave fix commits (post-Gate 3)

| Commit | Plan-Todo | Subject |
|---|---|---|
| `ce7ef133` | 6 | `fix(install): remove flag-on legacy fallback and pump async results` |
| `e918c77a` | 2 | `fix(download): refresh core rows from the module` |
| `42dfde34` | 8 | `docs(download): record final-wave fixes` |

`42dfde34` is the final code-state HEAD: its tree contains all final Wave-3
code, while its own diff is docs-only and the last code-changing commit is
`e918c77a`. The later Wave 3 docs HEAD at close,
`2915f462` (`docs(download): rebuild release APK for final HEAD`), is docs-only:
it changes only `docs/wave03-completion.md` + `docs/wave03-evidence.md`.

## Gate 3 matrix

Evidence: `target/test-evidence/87-gate3.txt`; injected failures:
`target/test-evidence/87-gate3-fail.txt`.

All matrix counts below (core 161/161 across 23 binaries, host 119/119 across
9 binaries, Flutter focused 50/50) are the Gate 3 run at code HEAD
`6ea4de02e0acaa4b697d42746ca76d907020da70`. There was **no full-suite rerun**
at final code HEAD `42dfde34` or at docs-only HEAD `2915f462`; after `6ea4de02`
only the focused final-wave checks recorded in
`target/test-evidence/88-final-wave-fix.txt` were run.

| # | Check | Result | Evidence / note |
|---|---|---|---|
| 1 | `cargo test --manifest-path rust/gstore_core/Cargo.toml` | **PASS** | 23 test binaries, 161 passed / 0 failed / 0 ignored; EXIT 0 |
| 1b | `cargo test --manifest-path rust/gstore_host/Cargo.toml` | **PASS** | 9 test binaries, 119 passed / 0 failed / 0 ignored; module `.so` files already present; EXIT 0 |
| 2 | Focused Flutter download/install suite (7 files) | **PASS** | `00:08 +50: All tests passed!`; EXIT 0 |
| 3 | `bash scripts/qa/parity.sh --download` | **PASS** | `parity OK (download): rows=14`; second migration inserted 0 (idempotent); `path_rule_matches=true`; EXIT 0 |
| 3b | `bash scripts/qa/parity.sh --channel` / `--catalog` | **PASS** | both `parity OK: getAllApps=17 searchApps=2 getAppInfoMissing=None`; EXIT 0 |
| 4 | `bash scripts/qa/f2-quality.sh` (baseline-aware, not recaptured) | **PASS** | `NEW findings (0)`; `PASS: no new findings (baseline only: dart=731, clippy=99)`; EXIT 0. No Wave 3 lint fix required. |
| 4b | `cargo clippy --manifest-path rust/gstore_core/Cargo.toml --all-targets -- -D warnings` | **PASS** | `Finished dev profile`; EXIT 0 |
| 5 | FRB codegen idempotency | **PASS** | codegen `Done!`, EXIT 0; `git diff --exit-code` on `rust/gstore_host/src/frb_generated.rs` + `lib/core/rust/generated/` = empty, DIFF_EXIT 0; no leftover to commit |
| 6 | `./gradlew :app:compileDebugKotlin --offline` (integration_test excluded) | **PASS** | `BUILD SUCCESSFUL in 37s`, 334 tasks; EXIT 0 |
| 7 | `flutter build apk --release --target-platform android-arm64` | **PASS** | rebuilt at/after final code HEAD `42dfde34` (includes final-wave fixes `ce7ef133`/`e918c77a`/`42dfde34`); `✓ Built .../app-release.apk (150.6MB)`; EXIT 0; 150589102 bytes; sha256 `0bab385b600bc7d6f8fec419a2760083c22d01fd85291e4c9a3a85e81dcd38b3`; mtime 2026-10-22 22:40:57 +0800 (after the 22:25:27 +0800 docs-only `42dfde34`); known Maven/TLS issue did not reproduce |
| 8 | Device (`adb devices`) | **BLOCKED** | empty device list; `DEVICE_QA: BLOCKED (no ADB device)`; no device pass claimed |
| 9 | Flags default false + old path authoritative | **PASS** | `dto_events_flags_defaults_all_false ... ok`; `git diff e5692829..HEAD -- rust/gstore_core/src/flags.rs lib/core/core_flags.dart` empty; T6 group `install flag off keeps the legacy path` passes |
| 10 | Scope audit | **PASS** | 60 changed files at the Gate-3 code HEAD `6ea4de02` (the F3-noted count) and 64 changed files at final HEAD `42dfde34`; both sets are entirely in the Wave-3 download/install/notification surface; no Wave 4/5/6, no JsChannel/rquickjs, no resync/removal, no desktop/HarmonyOS/iOS/CLI, no pack signatures; `git diff --diff-filter=D` empty; `pubspec.yaml` diff empty (`1.0.34+1`) |
| 11 | Injected failure behavior | **PASS** | `--inject-field-diff` EXIT 1 with `status_code 0 -> 1`; `--inject-path-diff` EXIT 1 with `dest_path ...-drift`; `--download --channel` EXIT 2 |
| 12 | Final-wave audit fixes | **PASS** | Flag-on app installs have **no** legacy fallback (`CORE_E_INSTALL_NO_CORE_TASK`; module APKs pass `moduleInstall: true`); legacy import resolves before the first core list in `_findCoreTaskId`/`installTask`; `DownloadApi.list`/`watchAll` reconcile from the module each tick; async install results are pumped every 500 ms by `gstore-install-reconcile` plus a bounded Dart pending poller; evidence `target/test-evidence/88-final-wave-fix.txt` |

## BLOCKED / DEFERRED

- **BLOCKED — device QA.** No ADB device is attached (`adb devices` empty). The
  release APK was built and hashed but not installed or exercised on hardware.
  On-device install (Shizuku/PackageInstaller/Intent), notification permission
  and FGS start/stop, and process-death recovery are therefore **not** claimed
  as passes. Re-run the device matrix when a device/emulator is available.
- No gate was deflected into a false PASS; every environment-limited check says
  BLOCKED explicitly.

## Known residuals

1. **Resolved (final wave): core rows refresh from the module.** `DownloadApi.list`
   and every `watchAll` tick run a best-effort `HostDownloadPort::reconcile()`
   before reading `download_task`, so progress and terminal state are never
   stuck at the values captured by `start`. Reconcile failures are logged and
   polling continues; only a core read failure stops the watch thread.
2. **Resolved (final wave): two install findings.** (a) With
   `CoreFlags.install == true`, an app install that does not resolve to a core
   `download_task` logs `CORE_E_INSTALL_NO_CORE_TASK` and returns
   `(false, InstallMethod.system)` — it never calls Shizuku/AppInstaller. Only an
   explicitly module-owned APK (`installApk(..., moduleInstall: true)`) keeps
   the legacy path. (b) The legacy import runs before the first core list, and
   async install results are pumped every 500 ms (`InstallApi::init` thread plus
   a bounded 500 ms/180 s Dart pending poller).
3. **Core module default scheduler config.** Module download scheduler defaults
   remain owned by `gstore_mod_download`; the core does not yet carry a
   default scheduler configuration. Task orchestration and state are core-owned,
   but scheduling policy still depends on the module engine defaults.
4. **Host-vs-Dart module DB path / `needs_restart`.** Imported *active* tasks
   that reference the module DB can resolve to a different module DB path in
   the host than the Dart side used before migration. Such rows are reported as
   `needs_restart` instead of being silently resumed, so a restart (or explicit
   re-start) is required before the host can continue them.

## Explicitly not done (scope guard)

- No `CoreFlags` default flip and no cutover.
- No deletion of the old Dart download/install writers (`git diff
  --diff-filter=D` is empty).
- No version bump (`pubspec.yaml` stays `1.0.34+1`).
- No Wave 4 storage/connectivity/device/secret bridge work, no Wave 5
  JsChannel/rquickjs, no Wave 6 resync/removal, no desktop/HarmonyOS/iOS/CLI,
  no pack signatures.
