# Android Wave 2 — evidence index

- **Branch:** `wave02/rust-core-catalog` in worktree `GStore-wave02`
- **Wave 2 code range:** `9d5b41f3..e631ff4f` = **17** commits
- **Closeout HEAD:** current branch HEAD carries closeout commits (`6906005f`,
  `e631ff4f`, `9b0b4129`, `26982727`) on top of the code range; that framing is
  intentionally unchanged.
- **Date:** 2026-10-22

## How to read this index

The raw logs live under `target/test-evidence/`. That directory is **local-only
and gitignored** (`/target/` in `.gitignore`). This file is the tracked pointer,
not a copy of the logs. Each sha256 below was computed with `sha256sum` against
the local file at the time this index was written; a log regenerated later may
hash differently, so treat a hash mismatch as "new run", not necessarily "wrong
result".

No hash is invented here. If an evidence file is missing, the cell says
`ABSENT (local-only)` and the row's dependency is stated.

## Evidence table

| Gate 2 row | Command(s) | Exit code | Evidence file | sha256 of evidence file | Notes |
|---|---|---|---|---|---|
| 1 | `cargo test --manifest-path rust/gstore_core/Cargo.toml migration_v2_contract`; `... catalog_import_live_and_seed`; `... added_apps_parity`; `... schema_contract_docs_sql_matches_migrated_schema` | 0 | `target/test-evidence/60-v2.txt` | `16217f71b8163f9aa14354e8a7f9bd4319dc2c1bcfa54536239ecbb4812b28c1` | Schema/migration contract; see also the import and added-apps runs below. |
| 1 | `cargo test ... catalog_import_live_and_seed` (and companion import probes) | 0 | `target/test-evidence/61-catalog-import.txt` | `a0506b1f0983666211033f1884b2fdab5ad999b85d67430379de40591caea2cb` | Live/seed catalog import. |
| 1 | `cargo test ... added_apps_parity` (and added-apps service probes) | 0 | `target/test-evidence/64-added.txt` | `109dc1b2a0d779465aff07866965972bcaf6bf3432aeba5b7d8da363aa8b0021` | Added-apps/tags parity. |
| 2 | `cargo test ... catalog_refresh_preserves_core_tables -- --nocapture` | 0 | `target/test-evidence/62-catalog-refresh.txt` | `8aa32c882350abe271ea749ffb85525d660ee1aba3293ad65bf26d6126aa490f` | Refresh keeps core tables; backup recorded. |
| 2 | `cargo test ... catalog_refresh_failure_keeps_old_catalog -- --nocapture` | 0 | `target/test-evidence/62-catalog-refresh-fail.txt` | `3355283aa925371fac0701b5b63040bf52a8f4043cf801a01b7287c046f91a4c` | 6 corrupt sources rejected with typed `CORE_E_CATALOG_REFRESH_*`; old catalog preserved. |
| 3 | `bash scripts/qa/parity.sh --catalog`; `bash scripts/qa/parity.sh --channel` | 0 | `target/test-evidence/63-catalog-query.txt` | `6f57453ae7bbf5c27161b41c925b3e5388713a05438704d5efb490bd58a28e42` | Real-Dart parity, FTS5 + LIKE, categories, detail. |
| 3 | Unicode query probe in the parity suite | 0 | `target/test-evidence/63-catalog-unicode.txt` | `64debd3e1574fe6c5f7c0f0bcc4a702f8ee00aa6152c1888f0a90f9b0b9f5835` | Unicode search parity. |
| 3 | Gate 2 consolidated run (CHECK 3) | 0 | `target/test-evidence/70-gate2.txt` | `eeb03fbb4e5fc81a1b8d192bf486fb6dfb2d16422c931a468cc4192965951cfc` | `parity OK: getAllApps=17 searchApps=2 getAppInfoMissing=None`; `catalog_query_parity` also passes. |
| 4 | `cargo test ... update_parity`; `flutter test test/update_prefs_migration_test.dart`; `cargo test ... update_prefs_roundtrip` | 0 | `target/test-evidence/68-update-prefs.txt` | `705d8f518902e40d6baaddea21f9680b30cf9059c344a5b8d718e6e28c14bc0c` | Flutter 10/10 after rebuilding a stale native `.so` (build-state only). |
| 4 | Update retry probe | 0 | `target/test-evidence/68-update-retry.txt` | `8f358119b4a65f58257f3d9c21f61a885c8ae09206002dd22ac49e4c33678cc9` | Retry path. |
| 4 | Gate 2 consolidated run (CHECK 4) | 0 | `target/test-evidence/70-gate2.txt` | `eeb03fbb4e5fc81a1b8d192bf486fb6dfb2d16422c931a468cc4192965951cfc` | Supersedes the first stale-`.so` failure noted inside the log. |
| 5 | `cargo test --manifest-path rust/gstore_host/Cargo.toml package_inventory_contract`; `bash scripts/qa/package-inventory.sh`; `adb devices` | 0 (contract); 3 (script) | `target/test-evidence/67-package.txt` | `41a96b77afba9076fc4392dfb89265e2af4f8ca93b471d9008ee4f61f3ffb28f` | Contract level passes; device run `RESULT: BLOCKED (no device)`; **Todo 8 is DEFERRED / BLOCKED, not a pass**. |
| 5 | Visibility denial + cache invalidation | 0 | `target/test-evidence/67-package-denied.txt` | `a02fbc631f8d28e3f026a0e725a7598c91ae18fca8e6018b67a1ec4431801811` | `CORE_E_PACKAGE_INVENTORY_DENIED`, not-found mapping, cache cleared. |
| 5 | `bash -n scripts/qa/package-inventory.sh`; deterministic `--check-logcat` probes (init-only, empty, positive marker) | 0 (syntax); 3 (init-only/empty, `RESULT: DEFERRED`); 0 (positive control) | `target/test-evidence/74-inventory-script-fix.txt` | `75c179213c236efff6618fdae0987060dcde0117be328a9cab111d666a2eb82d` | Fix makes init-only logcat exit 3 `DEFERRED (no positive inventory evidence)`; only a positive marker passes. |
| 6 | `cargo test ... catalog_update_api`; `flutter test test/catalog_update_api_test.dart`; `flutter_rust_bridge_codegen generate`; `git diff --exit-code` | 0 | `target/test-evidence/69-frb-api.txt` | `af3c1626b39a5914cd1c77f913a5b7029ff07785aca888388bcf5cf71f19e4c6` | 1/1 Rust, 4/4 Flutter, codegen idempotent. |
| 6 | Codegen idempotency re-check | 0 | `target/test-evidence/60-v2-idempotent.txt` | `fb6fdb591b15d3d1428316dc48f69919c384de90cbd68050e2127b2a7d0ba0d1` | No generated diff. |
| 7 | `cargo test --manifest-path rust/gstore_core/Cargo.toml --test dto_events_flags`; `flutter test test/catalog_update_api_test.dart --plain-name "flag off"` | 0 | `target/test-evidence/69-flag-off.txt` | `250d8507ecef3f42f8f54a7825aa860b280e3291af39b69240fb4a084922f555` | All six flag defaults false; flag-off routes to legacy backends. |
| 7 | Gate 2 consolidated run (CHECK 7) | 0 | `target/test-evidence/70-gate2.txt` | `eeb03fbb4e5fc81a1b8d192bf486fb6dfb2d16422c931a468cc4192965951cfc` | Same result recorded in the consolidated log. |
| 8 | `flutter build apk --release --target-platform android-arm64` | 0 | `target/test-evidence/76-release-apk-closeout.txt` | `fb961a61a755d018fb8d0915af9d40ec2f2811cece7695c0579996cf545851d9` | APK `build/app/outputs/flutter-apk/app-release.apk`, 150572442 bytes, sha256 `0cad05e1f3cfce9ce445eb4435300a9fc790ca2018b84f0563e2ddf564006db5`. The earlier TLS block did not reproduce. |
| 8b | `flutter build bundle --debug` | 0 | `target/test-evidence/70-gate2.txt` | `eeb03fbb4e5fc81a1b8d192bf486fb6dfb2d16422c931a468cc4192965951cfc` | `kernel_blob.bin` produced. |
| 8c | `./gradlew :app:compileDebugKotlin -x :integration_test:compileDebugJavaWithJavac` | 0 | `target/test-evidence/70-gate2.txt` | `eeb03fbb4e5fc81a1b8d192bf486fb6dfb2d16422c931a468cc4192965951cfc` | `BUILD SUCCESSFUL`, 334 tasks. |
| 9 | `cargo test --manifest-path rust/gstore_core/Cargo.toml` | 0 | `target/test-evidence/70-gate2.txt` | `eeb03fbb4e5fc81a1b8d192bf486fb6dfb2d16422c931a468cc4192965951cfc` | 21 test binaries, 141 tests, 0 failed. |
| 9b | `bash rust/build_all.sh`; `cargo test --manifest-path rust/gstore_host/Cargo.toml` | 0 | `target/test-evidence/71-host-suite.txt` | `aefbc356deb71481fdadd240baf2d7f123e576da1e2b2fca6261ccf634251b63` | 7/7 crates built (47.5s); harness lines 84+1+2+0 = **87 passed / 0 failed / 0 ignored**. Module `.so` files built by `build_all.sh`; independent rerun matched. |
| 9c | `flutter test test/update_prefs_migration_test.dart test/migration_handoff_test.dart test/core_api_test.dart` | 0 | `target/test-evidence/70-gate2.txt` | `eeb03fbb4e5fc81a1b8d192bf486fb6dfb2d16422c931a468cc4192965951cfc` | 18/18. |
| 9d | `flutter analyze <13 Wave 2 changed Dart files>` | 0 | `target/test-evidence/70-gate2.txt` | `eeb03fbb4e5fc81a1b8d192bf486fb6dfb2d16422c931a468cc4192965951cfc` | 13 items, `No issues found!`. |
| 10 | `git log --oneline 9d5b41f3..HEAD`; `git diff --stat 9d5b41f3..HEAD`; `git diff --diff-filter=D --name-only 9d5b41f3..HEAD`; `grep '^version:' pubspec.yaml`; `git show 9d5b41f3:pubspec.yaml \| grep '^version:'` | 0 | `target/test-evidence/70-gate2.txt` | `eeb03fbb4e5fc81a1b8d192bf486fb6dfb2d16422c931a468cc4192965951cfc` | Scope fidelity was verified by these git scope commands: no flag-default change, version stays `1.0.34+1`, no deleted files, Android diff limited to the Todo 8 inventory bridge. |
| Closeout 73 | `git rev-list --count 9d5b41f3..e631ff4f`; `git log --oneline 9d5b41f3..HEAD`; `git diff -- docs/wave02-completion.md` | 0 | `target/test-evidence/73-completion-record-fix.txt` | `eb08699660a2830b32de7143b50381cd65fc9eac271a1029fdaac7a931b13635` | Plan Todo 1 correction evidence: commit count 17, closeout fix hash recorded, Todo 1 corrections intact. `73-closeout.txt` does not exist; this is the actual file for the 73 step. |
| Closeout 74 | `bash -n` plus deterministic `package-inventory.sh --check-logcat` matrices | 0 / 3 / 0 (see notes) | `target/test-evidence/74-inventory-script-fix.txt` | `75c179213c236efff6618fdae0987060dcde0117be328a9cab111d666a2eb82d` | Same log also supports row 5: syntactic pass, init-only DEFERRED (3), positive control PASS (0). |
| Closeout 75 | `for f in docs/wave02-final/F1.md F2.md F3.md; do test -s "$f"; done`; `grep -n "PASS\|BLOCKED\|DEFERRED" docs/wave02-final/*.md`; report content checks | 0 | `target/test-evidence/75-f1f2f3-reports.txt` | `fd87d5e5f5799c010dbd880a4594823746aa7992f8a155bfdf1566e5bd9aa226` | F1/F2/F3 reports exist and are non-empty (8171 / 7331 / 5044 bytes). Reports live at `docs/wave02-final/`. |
| Closeout 76 | `flutter build apk --release --target-platform android-arm64` (plus independent rerun) | 0 | `target/test-evidence/76-release-apk-closeout.txt` | `fb961a61a755d018fb8d0915af9d40ec2f2811cece7695c0579996cf545851d9` | 150572442 bytes; sha256 `0cad05e1...`; sha1 `0e214f...`; rerun reproduced the sha256 in 26s. |

## Status summary

- Code-level checks (rows 1-7, 8b, 8c, 9, 9b, 9c, 9d, 10): **PASS**, each with
  an evidence path above.
- Release APK (row 8): **PASS**, sha256
  `0cad05e1f3cfce9ce445eb4435300a9fc790ca2018b84f0563e2ddf564006db5`.
- Todo 8 (row 5 device half): **DEFERRED / BLOCKED (owner deferred;
  contract/device split)**. Not a pass, and never labelled as one.
