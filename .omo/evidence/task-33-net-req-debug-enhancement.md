# Task 33 — Contract: regex / wildcard rule URL matching

`[contract-gated]` C5 (depends on T32, done). Prior commits preserved through `b71714f`.

## What changed

- **Rust contract** (`rust/gstore_mod_proxy/src/captures.rs`): `CaptureRule` and
  `CaptureRuleSetRequest` gained `matchType: String` (`#[serde(default = "default_match_type")]`,
  camelCase wire `matchType`). Values: `exact` (default) / `prefix` / `glob` / `regex`.
  `upsert()` validates the type + the pattern before mutating; `rule_matches()` now dispatches on
  the match type so the **MITM data path hits by match type**. Existing fields were **not**
  reordered (the new field is appended).
- **Matcher** (`captures.rs`): `exact` = whole-URL equality; `prefix` = `url.starts_with(pattern)`;
  `glob` = `*` (any run incl. empty, across `/`) / `?` (one char) two-pointer match; `regex` =
  Rust `regex` search behind a small bounded compile cache. `regex` is linear-time (no catastrophic
  backtracking); an invalid regex is rejected at `set` time (422), so the dataplane never compiles a
  broken pattern.
- **Dart contract** (`lib/core/rust/proxy/ProxyContract.dart`): `CaptureRule` gained `matchType`
  (default `'exact'`; absent decodes to `exact`); `CaptureRuleSetRequest` gained optional
  `matchType` (omitted when null → backend default `exact`).
- **Dart request-debug** (`lib/core/request_debug/debug_models.dart`): new
  `DebugRewriteMatch { exact, prefix, glob, regex }`; `DebugRewriteRule` gained `matchType`
  (ctor / `copyWith` / `toJson` omits `exact` / `fromJson` tolerant).
- **Port mapping** (`lib/page/request_debug/proxy_capture_rules_port.dart`):
  `debugRewriteRuleFromContract` maps `matchType`.
- **Editor** (`lib/page/request_debug/rules_section.dart`): `debugRuleToSetRequest` carries
  `matchType` (non-`exact` only); new match-type segmented selector
  (`request-debug-rule-match-{exact,prefix,glob,regex}`); dynamic URL label/hint;
  `validateRulePattern()` pre-validates (http(s) for exact/prefix/glob, compilable regex for regex);
  list subtitle shows the match type.
- **`API.md` §2.19**: request shape, `CaptureRule` example, field table, error note and the
  matching/execution paragraph document `matchType`.
- **Module delivery**: `Cargo.toml` 0.2.1 → 0.2.2 + direct `regex = "1"` (already transitive),
  rebuilt all 4 ABIs, replaced the tracked `jniLibs/<abi>/libgstore_mod_proxy.so`, regenerated
  manifests, CI asserts green.
- **No new dispatch method** (field-only change): `DISPATCH_METHODS` / `ProxyMethods.all` are
  unchanged and the T32 bidirectional consistency test still locks them together.

## decide-and-fallback: regex vs wildcard-only

**Decision: implement BOTH regex and wildcard (glob) — no fallback needed.**

Rationale:
1. The `regex` crate is **already in the transitive dependency graph** (present in
   `Cargo.lock` via meow), so declaring it directly adds no new compiled crate and no new
   `DT_NEEDED` entry (asserted by the 4-ABI artifact gate).
2. The Rust `regex` crate is **linear-time by construction** — it cannot catastrophically
   backtrack (ReDoS), so arbitrary operator patterns are safe on the dataplane.
3. The only residual cost was per-request compilation; that is removed by a **bounded compile
   cache** (`compiled_regex`, cap 256), and by validating the regex at `set` time so the
   dataplane only ever sees compilable patterns.
4. `prefix` and `glob` remain allocation-light pure string matching for the common cases.

The WILDCARD-ONLY fallback was therefore **not** taken; full regex + wildcard scope is delivered.

## Failing-first proof (TDD)

Tests were added to `captures.rs` `mod tests` before the implementation. `cargo test` then failed
to compile because the new field/constants did not exist yet:

```
error[E0425]: cannot find value `RULE_MATCH_REGEX` in this scope
    --> src/captures.rs:3105:39
error[E0609]: no field `match_type` on type `captures::CaptureRule`
    --> src/captures.rs:3027:23
error[E0609]: no field `match_type` on type `captures::CaptureRule`
    --> src/captures.rs:3040:32
...
error: could not compile `gstore_mod_proxy` (lib test) due to 9 previous errors
```

A first implementation run then surfaced two real behavioural bugs that the tests caught before
going green:
1. `invalid escape` — the test regex JSON needed a doubled backslash (`\\`).
2. an empty regex URL was accepted by `Regex::new("")`; `validate_rule_pattern` now rejects an
   empty URL for every type.

## Acceptance commands + raw output

### 1. Rust crate tests

No workspace root exists under `rust/` (`cargo -p` is unavailable), so tests run from the crate dir
(equivalent package selection), as in T32.

```
$ cd rust/gstore_mod_proxy && ~/.cargo/bin/cargo test --lib capture_rules
running 16 tests
...
test captures::tests::capture_rules_match_type_defaults_to_exact_and_round_trips ... ok
test captures::tests::capture_rules_match_types_hit_expected_urls ... ok
test captures::tests::capture_rules_invalid_match_type_and_regex_are_422 ... ok
test result: ok. 16 passed; 0 failed; 0 ignored; 0 measured; 510 filtered out
```

```
$ ~/.cargo/bin/cargo test --lib mitm_rewrite_glob_and_regex
test mitm::mitm_http_tests::mitm_rewrite_glob_and_regex_rules_hit_through_bridge ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 525 filtered out
```

Full crate suite (`cargo test` from `rust/gstore_mod_proxy`):

```
test result: ok. 522 passed; 0 failed; 4 ignored; 0 measured; 0 filtered out; finished in 53.64s
   (host_dlopen + mitm_spike integration tests also ok)
```

Coverage: exact / prefix / glob / regex hits and misses, whole-URL exactness, disabled-rule
non-match, default-exact round-trip, invalid `matchType`/regex/glob/empty → 422 (no store
mutation), plus a real MITM bridge test (`mitm_rewrite_glob_and_regex_rules_hit_through_bridge`)
that drives the live `CaptureRuleSource` seam and asserts the glob/regex rules serve locally with
zero upstream dials.

### 2. Dart contract + rules tests

```
$ LD_LIBRARY_PATH=/tmp flutter test test/proxy_contract_test.dart test/request_debug_rules_test.dart
00:04 +61: All tests passed!
```

Covers: `matchType` fixture round-trip (`glob`), `CaptureRuleSetRequest` encoder emits `matchType`
when set and omits it when absent, absent → `exact` decode, `DebugRewriteRule` toJson/fromJson,
port mapping, `validateRulePattern` pure cases, and editor widget tests (select glob → `setRule`
matchType; invalid regex → `showError` no save; edit prefills matchType). The
`DISPATCH_METHODS ↔ ProxyMethods.all` bidirectional consistency test passes unchanged.

### 3. Static gate

```
$ dart analyze lib/core/rust/proxy/ProxyContract.dart lib/core/request_debug/debug_models.dart \
    lib/page/request_debug/proxy_capture_rules_port.dart lib/page/request_debug/rules_section.dart \
    test/proxy_contract_test.dart test/request_debug_rules_test.dart
1 issue found.   # pre-existing info: file_names on ProxyContract.dart (unchanged)
```

`dart analyze lib/` reports only pre-existing repo-wide `info` lints (729, none in the changed
files).

### 4. Full Flutter suite

```
$ LD_LIBRARY_PATH=/tmp flutter test
03:09 +3412: All tests passed!
```

### 5. Module rebuild (all ABIs)

```
$ ./build_android_rust.sh --module gstore_mod_proxy
[SUCCESS] ✓ gstore_mod_proxy/arm64-v8a: 17M
[SUCCESS] ✓ gstore_mod_proxy/x86_64: 19M
[SUCCESS] ✓ gstore_mod_proxy/armeabi-v7a: 11M
[SUCCESS] ✓ gstore_mod_proxy/x86: 19M
```

Fresh `.so` copied to `android/app/src/main/jniLibs/<abi>/` (sha256 verified equal to
`rust/release-modules/<abi>/` for all 4 ABIs).

### 6. Manifests regenerated

```
$ ./generate_modules_manifest.sh
  - proxy/arm64-v8a: libgstore_mod_proxy_0.2.2-arm64-v8a.so (16947800B)
  - proxy/armeabi-v7a: libgstore_mod_proxy_0.2.2-armeabi-v7a.so (11102620B)
  - proxy/x86: libgstore_mod_proxy_0.2.2-x86.so (19476516B)
  - proxy/x86_64: libgstore_mod_proxy_0.2.2-x86_64.so (19618080B)
✓ 随包副本已生成: assets/app/modules.json
✓ 内置清单已生成: assets/app/modules_builtin.json
```

### 7. CI asserts

```
$ ./scripts/ci/assert_proxy_module_artifacts.sh
OK    : [proxy/arm64-v8a] 16947800 bytes, DT_NEEDED=[libc++_shared.so libdl.so libm.so libc.so ]
OK    : [proxy/armeabi-v7a] 11102620 bytes, DT_NEEDED=[...]
OK    : [proxy/x86] 19476516 bytes, DT_NEEDED=[...]
OK    : [proxy/x86_64] 19618080 bytes, DT_NEEDED=[...]
OK    : modules.json 'proxy' 4 ABIs, asset 命名+sha256+size 一致
OK    : 随包清单 assets/app/modules.json == 发布清单
OK    : modules_builtin.json 含 proxy（临时内置）
OK    : [proxy/jniLibs/arm64-v8a] 16947800 bytes
...
   expected: GS_PROXY_CONTRACT_FP=ed633c0b171cea9e
OK    : [arm64-v8a] GS_PROXY_CONTRACT_FP=ed633c0b171cea9e
OK    : [armeabi-v7a] GS_PROXY_CONTRACT_FP=ed633c0b171cea9e
OK    : [x86] GS_PROXY_CONTRACT_FP=ed633c0b171cea9e
OK    : [x86_64] GS_PROXY_CONTRACT_FP=ed633c0b171cea9e
PASS: 4 ABI 随包模块均由当前合约源码构建（指纹 GS_PROXY_CONTRACT_FP=ed633c0b171cea9e）
PASS: proxy 深度产物断言全部通过

$ ./scripts/ci/assert_module_artifacts.sh
PASS: 20 个产物全部存在且非零字节
```

The contract fingerprint changed from T32's `7cf0ec26a62bd979` to `ed633c0b171cea9e`, proving the
shipped `.so` was rebuilt from the current contract sources (`mitm.rs` + `API.md` changed;
`captures.rs` is not part of the hashed source list — a pre-existing property of the guard noted in
T32, not introduced here).

## Touchpoints synced

1. `rust/gstore_mod_proxy/src/captures.rs` — `CaptureRule` + `CaptureRuleSetRequest` gain
   `match_type`; `upsert()` validation; `rule_matches()`/`url_matches()`/`glob_matches()`/
   `compiled_regex()`; `mod tests` extended. (`lib.rs` `DISPATCH_METHODS` unchanged — no new
   method; locked by the bidirectional consistency test.)
2. `rust/gstore_mod_proxy/src/mitm.rs` — fixture `match_type` + dataplane match-type bridge test.
3. `rust/gstore_mod_proxy/API.md` §2.19 — request shape, `CaptureRule` example, field table, error
   note and matching paragraph document `matchType`.
4. `lib/core/rust/proxy/ProxyContract.dart` — `CaptureRule` + `CaptureRuleSetRequest` `matchType`.
5. `lib/core/request_debug/debug_models.dart` + `lib/page/request_debug/proxy_capture_rules_port.dart`
   + `lib/page/request_debug/rules_section.dart` — `DebugRewriteMatch`, mapping, editor UI + validation.
6. `test/proxy_contract_test.dart` + `test/request_debug_rules_test.dart` — fixtures + round-trip +
   editor/validation tests.
7. Module delivery: `Cargo.toml` 0.2.1 → 0.2.2 + `regex`, 4-ABI rebuild, jniLibs replacement,
   manifest regeneration, CI asserts green.

## Notes / risks

- **`exact` default is preserved** end-to-end: Rust `#[serde(default)]` → `exact`; Dart `CaptureRule`
  defaults `'exact'`; Dart `DebugRewriteRule` defaults `DebugRewriteMatch.exact` and `toJson` /
  `debugRuleToSetRequest` omit the field for `exact`. An old client/rule never changes behaviour.
- **WS untouched**: no WS code path changed.
- `delayMs` remains stored/echoed only (unchanged from T32).
- `rust/release-modules/` and `assets/app/modules.json` are `.gitignore`d; only
  `assets/app/modules_builtin.json` + the jniLibs `.so` are committed.
- Dart-side regex validation uses ECMAScript `RegExp` (best-effort UX pre-check); the Rust `regex`
  crate remains the authority and returns the frozen 422 for anything it rejects.
