# Task 32 — Contract: capture rule `remark` + request-debug `DebugRewriteRule.delayMs`

`[contract-gated]` C5. Prior commits preserved through `62a9431`.

## What changed

- **Rust contract** (`rust/gstore_mod_proxy/src/captures.rs`): `CaptureRule` and
  `CaptureRuleSetRequest` gained `remark: Option<String>` (camelCase wire `remark`);
  `upsert()` persists it (empty string normalizes to `None`). Existing fields were
  **not** reordered; `delayMs` already existed on both Rust structs.
- **Dart contract** (`lib/core/rust/proxy/ProxyContract.dart`): `CaptureRule` +
  `CaptureRuleSetRequest` gained `remark` (`fromJson` / `toJson`).
- **Dart request-debug** (`lib/core/request_debug/debug_models.dart`):
  `DebugRewriteRule` gained `delayMs` (ctor / `copyWith` / `toJson` / `fromJson`).
- **Port mapping** (`lib/page/request_debug/proxy_capture_rules_port.dart`):
  `debugRewriteRuleFromContract` now maps `remark` + `delayMs` (previously dropped).
- **Editor** (`lib/page/request_debug/rules_section.dart`): `debugRuleToSetRequest`
  carries `remark` + `delayMs`; new `request-debug-rule-delay` field; `_save`
  validates non-negative integer.
- **`DISPATCH_METHODS` ↔ `ProxyMethods.all` bidirectional consistency test**
  (`test/proxy_contract_test.dart`): parses Rust `DISPATCH_METHODS` and asserts both
  directions (Rust ⊆ Dart and Dart ⊆ Rust) so a method missing on either side fails.
  No new dispatch method was added (field-only change), so `lib.rs` is unchanged —
  the new test locks the two lists together.
- **Module delivery**: `Cargo.toml` 0.2.0 → 0.2.1, rebuilt all 4 ABIs, replaced the
  tracked `jniLibs/<abi>/libgstore_mod_proxy.so`, regenerated manifests.

## Failing-first proof (TDD)

Before implementation, targeted `dart analyze` on the new tests reported the
not-yet-existing members (raw LSP diagnostics captured during the run):

```
ERROR [proxy_contract_test.dart:1375:19] The getter 'remark' isn't defined for the type 'CaptureRule'.
ERROR [proxy_contract_test.dart:1404:9]  The named parameter 'remark' isn't defined.
ERROR [request_debug_rules_test.dart:209:9]  The named parameter 'delayMs' isn't defined.
ERROR [request_debug_rules_test.dart:235:19] The getter 'delayMs' isn't defined for the type 'DebugRewriteRule'.
```

The `request_debug_rules_test.dart` run then failed on the new case
(`FormatException: 缺少必填字段 "id"` — test fixture corrected to supply `id`, which is
a required field by design), then went green after the implementation.

## Acceptance commands + raw output

### 1. Rust crate tests (`cargo test rules`, run from the crate dir)

No workspace root exists under `rust/` (`cargo -p` is unavailable), so the crate
test is run from `rust/gstore_mod_proxy` (equivalent package selection):

```
$ cd rust/gstore_mod_proxy && ~/.cargo/bin/cargo test rules
     Running unittests src/lib.rs (target/debug/deps/gstore_mod_proxy-28e4358ae0554132)
test result: ok. 34 passed; 0 failed; 0 ignored; 0 measured; 488 filtered out; finished in 0.19s
```

`capture_rules_upsert_remove_round_trip` was extended to assert `remark`/`delayMs`
round-trip through `capture.rules.set` → `capture.rules.get` and their reset on upsert.

### 2. Dart contract + rules tests

```
$ LD_LIBRARY_PATH=/tmp flutter test test/proxy_contract_test.dart test/request_debug_rules_test.dart
00:03 +54: All tests passed!
```

Covers: `remark` fixture round-trip, `CaptureRuleSetRequest` encoder emits `remark`,
bidirectional `DISPATCH_METHODS ↔ ProxyMethods.all` test, `DebugRewriteRule`
`delayMs` toJson/fromJson, port mapping of `remark`+`delayMs`, and the editor
delayMs stored/read-back widget tests.

### 3. Static gate

```
$ dart analyze <changed lib + test files>
1 issue found.   # pre-existing info: file_names on ProxyContract.dart (unchanged)
```

`dart analyze lib/` reports only pre-existing repo-wide `info` lints; the changed
files add no new diagnostics.

### 4. Module rebuild (all ABIs)

```
$ ./build_android_rust.sh --module gstore_mod_proxy
[SUCCESS] ✓ gstore_mod_proxy/arm64-v8a: 17M
[SUCCESS] ✓ gstore_mod_proxy/x86_64: 19M
[SUCCESS] ✓ gstore_mod_proxy/armeabi-v7a: 11M
[SUCCESS] ✓ gstore_mod_proxy/x86: 19M
```

Fresh `.so` copied to `android/app/src/main/jniLibs/<abi>/` (sha256 verified equal
to `rust/release-modules/<abi>/`).

### 5. Manifests regenerated

```
$ ./generate_modules_manifest.sh
  - proxy/arm64-v8a: libgstore_mod_proxy_0.2.1-arm64-v8a.so (16936032B)
  - proxy/armeabi-v7a: libgstore_mod_proxy_0.2.1-armeabi-v7a.so (11094644B)
  - proxy/x86: libgstore_mod_proxy_0.2.1-x86.so (19460508B)
  - proxy/x86_64: libgstore_mod_proxy_0.2.1-x86_64.so (19604752B)
✓ 随包副本已生成: assets/app/modules.json
✓ 内置清单已生成: assets/app/modules_builtin.json
```

### 6. CI asserts

```
$ ./scripts/ci/assert_proxy_module_artifacts.sh
PASS: proxy 深度产物断言全部通过（4 ABI + 清单 + 命名）
== proxy module contract fingerprint guard ==
   expected: GS_PROXY_CONTRACT_FP=7cf0ec26a62bd979
OK    : [arm64-v8a] GS_PROXY_CONTRACT_FP=7cf0ec26a62bd979
OK    : [armeabi-v7a] GS_PROXY_CONTRACT_FP=7cf0ec26a62bd979
OK    : [x86] GS_PROXY_CONTRACT_FP=7cf0ec26a62bd979
OK    : [x86_64] GS_PROXY_CONTRACT_FP=7cf0ec26a62bd979
PASS: 4 ABI 随包模块均由当前合约源码构建
```

```
$ ./scripts/ci/assert_module_artifacts.sh
PASS: 20 个产物全部存在且非零字节
```

APK payload assert was run against **freshly rebuilt** full+slim APKs (CI commands,
see below), because the pre-existing `build/apk-release/` APKs predated the
temporary-bundle reversal and failed structurally:

```
$ ORG_GRADLE_PROJECT_gstoreSlimModules=false flutter build apk --no-shrink --target-platform android-arm,android-arm64,android-x64 --split-per-abi
$ ORG_GRADLE_PROJECT_gstoreSlimModules=true  flutter build apk --no-shrink --target-platform android-arm,android-arm64,android-x64 --split-per-abi
$ ./scripts/ci/assert_apk_module_payload.sh build/apk-release
OK    : [full/arm64-v8a] build/apk-release/GStore-arm64-v8a-release.apk
OK    : [slim/arm64-v8a] build/apk-release/GStore-slim-arm64-v8a-release.apk
OK    : [full/armeabi-v7a] build/apk-release/GStore-armeabi-v7a-release.apk
OK    : [slim/armeabi-v7a] build/apk-release/GStore-slim-armeabi-v7a-release.apk
OK    : [full/x86_64] build/apk-release/GStore-x86_64-release.apk
OK    : [slim/x86_64] build/apk-release/GStore-slim-x86_64-release.apk
PASS: 6 个 APK 载荷断言全部通过（完整包含模块 .so，精简仅 host + libc++）
```

## Touchpoints synced

1. `rust/gstore_mod_proxy/src/captures.rs` — `CaptureRule` + `CaptureRuleSetRequest`
   gain `remark`; `upsert()` persists it; `mod tests` extended.
   (`lib.rs` `DISPATCH_METHODS` unchanged: no new method; locked by the new test.)
2. `rust/gstore_mod_proxy/API.md` §2.19 — request shape, `CaptureRule` example,
   and field table document `remark`.
3. `lib/core/rust/proxy/ProxyContract.dart` — `CaptureRule` + `CaptureRuleSetRequest`
   `remark` (rule structs; `ProxyMethods`/decoders unchanged — no new method).
4. `lib/core/request_debug/debug_models.dart` + `proxy_capture_rules_port.dart` +
   `rules_section.dart` — `DebugRewriteRule.delayMs` + remark mapping/editor.
5. `test/proxy_contract_test.dart` + `test/request_debug_rules_test.dart` — fixtures
   + bidirectional consistency test.
6. Module delivery: `Cargo.toml` bump, 4-ABI rebuild, jniLibs replacement,
   manifest regeneration, CI asserts green.

## Notes / risks

- `captures.rs` is not part of the `build.rs` contract-fingerprint source list
  (only lib.rs/capture.rs/mitm.rs/dispatch.rs/limits.rs/API.md are). The fingerprint
  still changed because `API.md` and `mitm.rs` changed, so the guard verified the
  rebuild. This is a pre-existing property of the guard, not introduced here.
- `rust/release-modules/` and `assets/app/modules.json` are `.gitignore`d; only
  `assets/app/modules_builtin.json` + the jniLibs `.so` are committed.
- `delayMs` is stored/echoed only; MITM injection remains out of scope (documented).
