# Android Wave 2 — completion record

- **Scope:** Rust core catalog/update surface (`gstore-rust-core-android-wave02`).
  Wave 3/5/6 are explicitly **not started**.
- **Repo / branch:** `GStore-wave02` @ `wave02/rust-core-catalog`
- **Base:** `9d5b41f3` (`9d5b41f3726fd733dc843f6069fd19c7ab14e3ae`, Wave 0/1 closeout)
- **Feature HEAD (before closeout fixes):**
  `3c59e5dc3e247f2d636002c9cb13302bd141998c`
  (`feat(catalog): expose catalog/added/update APIs behind flags`)
- **Closeout fix commit:**
  `6906005fb7ff32826a0e54c199afc0142f35eae0`
  (`fix(test): align host bridge schema expectations with V2`, `Plan-Todo: 11`)
- **Final HEAD (closeout record):**
  `e631ff4f8b29c4fd52f5cf00a1b4ab5756a30773`
  (`docs(catalog): record Wave 2 closeout fix hash`, `Plan-Todo: 11`)
- **Commit count `9d5b41f3..e631ff4f`:** **17** (14 feature/fix + Gate closeout
  doc + the schema-alignment fix + the closeout record)
- **Date:** 2026-10-22
- **Toolchain:** rustc/cargo 1.92.0, Flutter 3.44.8 (stable), FRB codegen 2.11.1

## Scope delivered

- V2 schema (`catalog` / `update`) with refinery migration and canonical
  `docs/core-schema.sql` kept in sync.
- Live/seed catalog import (apps, categories, config, FTS) and atomic catalog
  refresh with backup + rollback on corrupt sources.
- Catalog queries, FTS5 + LIKE parity, category rows, app detail.
- Added-apps/tags service and aggregation/paged queries.
- Update state/service and update-prefs migration handoff.
- Package inventory bridge (Android) + Rust contract/gating (Todo 8 — **DEFERRED /
  BLOCKED**, owner deferred; contract/device split; see residuals).
- FRB/facades for catalog/added/update exposed **behind flags**; all flags
  remain disabled and the legacy Dart paths stay in place.

## Commits (`9d5b41f3..e631ff4f`)

| Commit | Todo | Subject |
|---|---|---|
| `5bf82aeb` | 1 | feat(core): add catalog/update V2 schema |
| `7310d499` | 1 fix | fix(core): keep Dart FTS shape and back up before V2 |
| `9a4e5c1f` | 5 | feat(core): add added-apps and tags service |
| `b10749b0` | 2 | feat(core): import live/seed catalog with category/config mappings |
| `27eabe43` | 3 | feat(core): add atomic catalog refresh |
| `e8942d8f` | 4 | feat(core): add catalog queries and FTS parity |
| `c36f3633` | 6 | feat(core): add aggregation and paged catalog queries |
| `1362c9b9` | 6 fix | fix(core): make aggregation dedup opt-in and Dart-compatible |
| `7f624d3e` | 7 | feat(core): add update state and service |
| `9b8e6caf` | 7 fix | fix(core): harden update cache timestamp arithmetic |
| `507837d9` | 9 | feat(core): migrate update prefs via handoff |
| `9fa7e514` | 8 | feat(android): add package inventory bridge |
| `1a55f535` | 3/5/6 fix | fix(test): align core api expectations with V2 schema |
| `3c59e5dc` | 10 | feat(catalog): expose catalog/added/update APIs behind flags |
| `12ca93e7` | 11 | test(catalog): close Wave 2 Gate |
| `6906005f` | 11 fix | fix(test): align host bridge schema expectations with V2 |
| `e631ff4f` | 11 (record) | docs(catalog): record Wave 2 closeout fix hash |

## Gate 2 matrix

Evidence: `target/test-evidence/70-gate2.txt` (commands, exit codes, outputs)
and `target/test-evidence/70-gate2-fail.txt` (failure injection + blocked text).

| # | Check | Result | Evidence / note |
|---|---|---|---|
| 1 | Schema/migration: `migration_v2_contract`, `catalog_import_live_and_seed`, `added_apps_parity`, `schema_contract` docs match | **PASS** | all exit 0 |
| 2 | Refresh preserves core tables; corrupt-source injection keeps old catalog | **PASS** | 6 corrupt sources rejected with typed `CORE_E_CATALOG_REFRESH_*`; catalog/non-catalog snapshots unchanged |
| 3 | Real-Dart parity `--catalog` and `--channel` (FTS5+LIKE, categories, detail) | **PASS** | both `parity OK: getAllApps=17 searchApps=2 getAppInfoMissing=None`; `catalog_query_parity` also passes |
| 4 | Update service/prefs: `update_parity`, Flutter prefs migration, `update_prefs_roundtrip` | **PASS** | Flutter 10/10 after rebuilding a stale native `.so` (build-state only) |
| 5 | Inventory contract + `package-inventory.sh` + `adb devices` | **DEFERRED / BLOCKED** (owner deferred; contract/device split) | contract & visibility tests pass at contract level only; `adb devices` empty; the Todo 8 outcome is deferred by the owner, so it is not a pass. `scripts/qa/package-inventory.sh` now exits 3 `RESULT: DEFERRED (no positive inventory evidence)` on init-only logcat and only passes on a positive inventory marker (`target/test-evidence/74-inventory-script-fix.txt`) |
| 6 | FRB/facades: Rust `catalog_update_api`, Flutter API test, codegen idempotency | **PASS** | 1/1 Rust, 4/4 Flutter, codegen + `git diff --exit-code` clean |
| 7 | Flags all false; flag-off old path | **PASS** | `dto_events_flags_defaults_all_false` (6/6); “flag off” test routes to legacy backends only |
| 8 | Release APK `android-arm64` | **PASS** | `flutter build apk --release --target-platform android-arm64` exit 0; `build/app/outputs/flutter-apk/app-release.apk` is 150572442 bytes, sha256 `0cad05e1f3cfce9ce445eb4435300a9fc790ca2018b84f0563e2ddf564006db5`; evidence `target/test-evidence/76-release-apk-closeout.txt`. The earlier `:integration_test:extractReleaseAnnotations` / `androidx.test:runner:1.2+` Maven/TLS block was transient and did not reproduce; no Gradle/pubspec/env change was made. |
| 8b | Dart compile proof (`flutter build bundle --debug`) | **PASS** | exit 0, `kernel_blob.bin` produced |
| 8c | App-module Kotlin compile (`:app:compileDebugKotlin`) | **PASS** | `BUILD SUCCESSFUL`, 334 tasks |
| 9 | Full regression: `gstore_core` | **PASS** | 21 test binaries, 141 tests, 0 failed |
| 9b | Full regression: `gstore_host` | **PASS** | `87 passed / 0 failed / 0 ignored` (harness lines 84+1+2+0), `cargo test --manifest-path rust/gstore_host/Cargo.toml` exit 0; the module `.so` files (`libgstore_mod_qr.so`, `libgstore_mod_analyzer.so`, `libgstore_mod_repo.so`) were built by `rust/build_all.sh`; evidence `target/test-evidence/71-host-suite.txt`. The 2 stale V2 bridge assertions were fixed in `6906005f`. (The pre-fix run was 74/10.) |
| 9c | Flutter regression (prefs + handoff + core API) | **PASS** | 18/18 |
| 9d | `flutter analyze` on Wave 2 changed Dart | **PASS** | 13 items, “No issues found!” |
| 10 | Scope fidelity (flags/version/deletions/Wave 3+) | **PASS** | no flag-default diff, version stays `1.0.34+1`, no deleted files, Android diff only the package-inventory bridge |

## Known residuals

1. **Todo 8 — DEFERRED / BLOCKED (owner deferred; contract/device split).**
   The owner deferred Todo 8, so the work splits in two. The Rust inventory
   contract, visibility-denial mapping and cache-invalidation tests pass at the
   contract level, but no ADB device/emulator run was performed (`adb devices`
   empty; `package-inventory.sh` exits 3 with `RESULT: BLOCKED (no device)`).
   Neither the on-device run nor Todo 8 as a whole is claimed as a pass.
2. **Release APK — RESOLVED during closeout.** `flutter build apk --release
   --target-platform android-arm64` now exits 0. The artifact
   `build/app/outputs/flutter-apk/app-release.apk` is 150572442 bytes, sha256
   `0cad05e1f3cfce9ce445eb4435300a9fc790ca2018b84f0563e2ddf564006db5`, sha1
   `0e214f199cd038f97671c1d44ce66a7d853777bb`. An independent rerun (26s)
   reproduced the identical sha256. The earlier
   `:integration_test:extractReleaseAnnotations` /
   `androidx.test:runner:1.2+` Maven/TLS block did **not** reproduce, and no
   Gradle/pubspec/env change was made; evidence
   `target/test-evidence/76-release-apk-closeout.txt`. Residual risk: the
   transient network/TLS block may recur in a clean environment (for example a
   cold Gradle cache behind a strict proxy), in which case rerun the build or
   pre-warm the Gradle cache.
3. **Build-state `gstore_host` lib-test failures — RESOLVED.** `bash
   rust/build_all.sh` exits 0 (7/7 crates, 47.5s) and builds the module `.so`
   files (`libgstore_mod_qr.so`, `libgstore_mod_analyzer.so`,
   `libgstore_mod_repo.so`); `cargo test --manifest-path
   rust/gstore_host/Cargo.toml` then exits 0 with harness lines 84+1+2+0 =
   **87 passed / 0 failed / 0 ignored**. An independent rerun reproduced the
   same counts, and the 8 previously failing analyzer/repo/qr module tests now
   pass; evidence `target/test-evidence/71-host-suite.txt`. The 2 stale
   schema-v1 assertions in `bridge.rs` (`core_api_contract`,
   `core_writes_empty_after_init_and_migration`), which expected
   `schema_version`/`import_snapshot` to return `1`, were **fixed in the
   closeout fix commit** `6906005fb7ff32826a0e54c199afc0142f35eae0`
   (`fix(test): align host bridge schema expectations with V2`,
   `Plan-Todo: 11`).
4. **Stale native `.so` for Flutter native tests (resolved during the gate).**
   The first `update_prefs_migration_test.dart` run failed on an FRB content-hash
   mismatch because `rust/gstore_host/target/release/libgstore_host.so` predated
   the checked-in generated bindings. A release rebuild resolved it; codegen
   idempotency is clean, so no source change was needed.
5. **No behavior/flag changes.** `Flags::DISABLED` / `Flags::default()` and
   `CoreFlagsSnapshot.disabled` remain all-`false`; old Dart writers are intact;
   `pubspec.yaml` stays `1.0.34+1`. Android Wave 2 changes are limited to the
   Todo 8 inventory bridge (`InventoryInspector.kt`, `PlatformHostBridge.kt`,
   `MainActivity.kt` cache/receiver wiring); no Gradle/release/manifest or
   version-code changes.

## Wave 2 code-level gate status

**PASS at the code level for Todos 1-7 and 9-11, and PASS for the release APK**
(`android-arm64`, 150572442 bytes, sha256
`0cad05e1f3cfce9ce445eb4435300a9fc790ca2018b84f0563e2ddf564006db5`), with
**Todo 8 DEFERRED / BLOCKED (owner deferred; contract/device split)**. Schema,
refresh/rollback, parity, update/prefs, inventory-contract, FRB, flag and scope
checks pass. `gstore_core` and the Flutter regression suites pass in full, and
`gstore_host` is **87 passed / 0 failed / 0 ignored** after `rust/build_all.sh`
built the module `.so` artifacts. Todo 8 remains DEFERRED / BLOCKED because the
owner deferred it: only the contract level passed and the on-device
instrumentation was not run (no ADB device). The production
bootstrap/FRB-caller gap remains **DEFERRED** before any flag flip. Neither
Todo 8 nor the on-device instrumentation is reported as a pass.

