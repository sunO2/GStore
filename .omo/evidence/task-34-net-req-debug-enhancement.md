# Task 34 — Contract: request/response intercept breakpoints (frozen sketch)

`[contract-gated]` C5, last/highest-risk item (depends on T33, done). Prior commits
preserved through `3455063`.

## Decision

**`sketch-only`.** The CONTRACT SKETCH was frozen and shipped green; the MITM
pause/resume dataplane and the Dart list/edit UI are **deferred** to a follow-up
plan. This is the task's explicit decide-and-fallback option (a):
"deliver the frozen CONTRACT SKETCH ONLY … (API.md + ProxyContract.dart +
ProxyModule.dart + consistency test + Rust method stubs returning a clear
NOT_IMPLEMENTED, all green)".

Why not the full dataplane in this wave: this is a **large dataplane feature**.
A correct implementation needs (1) buffering hyper `Incoming` request/response
bodies, (2) a process-global pause registry with `oneshot` resolution reachable
from the dispatch thread, (3) event emission with an instance-id threaded into
the MITM `BridgeContext`, (4) timeout-triggered auto-release, and (5)
request/response reconstruction across h1/h2 — plus a live-bridge async test
harness and a new Dart page + edit sheet. Attempting that within budget risked a
broken/half delivery, which the task explicitly forbids. The frozen shape is
independently useful: the follow-up dataplane work needs **no second contract
change**.

## What was delivered

### Frozen contract (`captures.breakpoint.*` + `proxy.capture.breakpoint`)

- `rust/gstore_mod_proxy/API.md` **§2.20** documents the frozen shape:
  - Methods: `captures.breakpoint.get` / `set` / `list` / `resume` / `cancel`.
  - `BreakpointConfig`: `{ enabled:false, timeoutMs:15000, scope:"both",
    urlPattern:"", matchType:"exact" }` — **DEFAULT OFF**, `timeoutMs` clamped
    `[1000,120000]`; a paused flow is auto-released on expiry (never blocks the
    dataplane past the timeout).
  - `BreakpointPending` (**flow/handle correlation id + pending request/response
    payload to edit**): `handle`, `phase`, `method`, `url`, `host`, `connId`,
    `requestRecordId`, `statusCode`, `headers`, `body` (base64), `truncated`,
    `createdAtMs`, `expiresAtMs`.
  - `BreakpointList` `{ pending, count }`; `BreakpointResumeResult`
    `{ ok, handle, resumed, phase }`; `BreakpointCancelResult`
    `{ ok, handle, cancelled, phase }`.
  - `resume` request carries the **edited** `method`/`url`/`headers`/`body`
    (each optional; omitted keeps the captured value).
  - Event `proxy.capture.breakpoint` = the `BreakpointPending` payload, emitted
    once per paused flow (default OFF).
  - Error code `PROXY_CAPTURE_BREAKPOINT_NOT_IMPLEMENTED` (500) for this wave.
- `rust/gstore_mod_proxy/src/breakpoint.rs` (**new**): explicit NOT_IMPLEMENTED
  stub (`stub_arm`) + frozen constants `DEFAULT_BREAKPOINT_ENABLED=false`,
  `DEFAULT_BREAKPOINT_TIMEOUT_MS=15000`, `MIN/MAX_BREAKPOINT_TIMEOUT_MS`
  (`1000`/`120000`) + `mod tests`.
- `rust/gstore_mod_proxy/src/lib.rs`: `mod breakpoint;`; 5 entries appended to
  `DISPATCH_METHODS`; 5 dispatch arms that `require_instance` then return
  `breakpoint::stub_arm(..)`.
- `rust/gstore_mod_proxy/API.md` §3: `proxy.capture.breakpoint` event row; §5:
  the error-code row.
- `rust/ERROR_CODES.md`: `PROXY_CAPTURE_BREAKPOINT_NOT_IMPLEMENTED` row.
- `lib/core/rust/proxy/ProxyContract.dart`: `ProxyMethods.capturesBreakpoint*`
  (5) + `all`; `ProxyEvents.captureBreakpoint` + `all`; models
  `ProxyBreakpointConfig` (defaults OFF) / `ProxyBreakpointPending` /
  `ProxyBreakpointList` / `ProxyBreakpointResumeRequest` /
  `ProxyBreakpointCancelRequest` / `ProxyBreakpointResumeResult` /
  `ProxyBreakpointCancelResult`; 5 decoders; 3 request encoders.
- `lib/core/rust/proxy/ProxyModule.dart`: `ProxyCaptureBreakpointEvent` +
  decode case + 5 facade methods (`capturesBreakpointGet/Set/List/Resume/Cancel`).
- `test/proxy_contract_test.dart`: 5 method fixtures + 1 event fixture.
- `test/proxy_breakpoint_test.dart` (**new**): focused sketch-shape coverage
  (config defaults/round-trip, pending/list, resume/cancel requests+results,
  event decode, registry consistency).

### Scope review (changes kept, and why each is required)

- `lib/page/proxy/proxy_home_page.dart` (+1 line) — **required**: adding the
  `ProxyCaptureBreakpointEvent` subclass makes Dart's sealed `ProxyEvent`
  switch non-exhaustive; the new event is added to the existing ignore/`break`
  list (it is not a UI entry point this wave).
- `lib/page/proxy/proxy_profiles_page.dart` (+1 line) — **required**, same
  sealed-switch exhaustiveness reason.
- `rust/ERROR_CODES.md` (+1 line) — **required**: the contract rule is "New codes
  are registered in `rust/ERROR_CODES.md`" (API.md §5); the new domain code is
  registered there.
- No other files changed; `dist/` is untracked and excluded.

## Failing-first (RED) proof

The bidirectional consistency guard (`DISPATCH_METHODS ↔ ProxyMethods.all`) was
exercised by temporarily removing `"captures.breakpoint.list"` from
`DISPATCH_METHODS` and re-running the guard (then restoring):

```
$ LD_LIBRARY_PATH=/tmp flutter test test/proxy_contract_test.dart \
    --plain-name 'DISPATCH_METHODS ↔ ProxyMethods.all 双向一致（任一侧漏改即红）'
00:00 +0 -1: ... [E]
  Expected: empty
    Actual: Set:['captures.breakpoint.list']
  Dart ProxyMethods.all 有但 Rust DISPATCH_METHODS 缺失的方法: {captures.breakpoint.list}
Failing tests:
  ...: DISPATCH_METHODS ↔ ProxyMethods.all 双向一致（任一侧漏改即红）
```

This proves the guard catches a one-sided contract edit; with the entry restored
the guard is green (below).

## Acceptance commands + raw output

### 1. Rust stub tests

```
$ cd rust/gstore_mod_proxy && ~/.cargo/bin/cargo test --lib breakpoint
test breakpoint::tests::breakpoint_defaults_are_off_and_bounded ... ok
test breakpoint::tests::breakpoint_stub_returns_not_implemented ... ok
test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 526 filtered out
```

Full crate lib suite (no regression):

```
$ ~/.cargo/bin/cargo test --lib
test result: ok. 524 passed; 0 failed; 4 ignored; 0 measured; 0 filtered out; finished in 55.83s
```

### 2. Dart contract + sketch tests + consistency

```
$ LD_LIBRARY_PATH=/tmp flutter test test/proxy_breakpoint_test.dart test/proxy_contract_test.dart
00:00 +44: All tests passed!
```

Covers: 5 new methods present in `ProxyMethods.all`, `proxyResponseDecoders`
(one per method), `proxyRequestEncoders` (set/resume/cancel), the event decode,
fixtures, and the `DISPATCH_METHODS ↔ ProxyMethods.all` bidirectional guard.

### 3. Static gate

```
$ dart analyze lib/core/rust/proxy/ProxyContract.dart lib/core/rust/proxy/ProxyModule.dart \
    lib/page/proxy/proxy_home_page.dart lib/page/proxy/proxy_profiles_page.dart \
    test/proxy_breakpoint_test.dart test/proxy_contract_test.dart
2 issues found.   # only pre-existing `file_names` info on ProxyContract.dart / ProxyModule.dart
```

### 4. Full Flutter suite

```
$ LD_LIBRARY_PATH=/tmp flutter test
03:44 +3422: All tests passed!
```

### 5. Module rebuild (all ABIs)

```
$ ./build_android_rust.sh --module gstore_mod_proxy
[SUCCESS] ✓ gstore_mod_proxy/arm64-v8a: 17M
[SUCCESS] ✓ gstore_mod_proxy/x86_64: 19M
[SUCCESS] ✓ gstore_mod_proxy/armeabi-v7a: 11M
[SUCCESS] ✓ gstore_mod_proxy/x86: 19M
```

Fresh `.so` copied to `android/app/src/main/jniLibs/<abi>/` (sha256 verified equal
to `rust/release-modules/<abi>/` for all 4 ABIs).

> Note: the first rebuild raced with the temporary RED-proof edit of `lib.rs`
> (x86_64 built during that window → stale fingerprint). A second rebuild with
> sources final fixed it; all 4 ABIs now embed the current fingerprint.

### 6. Manifests regenerated

```
$ ./generate_modules_manifest.sh
  - proxy/arm64-v8a: libgstore_mod_proxy_0.2.3-arm64-v8a.so (16948584B)
  - proxy/armeabi-v7a: libgstore_mod_proxy_0.2.3-armeabi-v7a.so (11104172B)
  - proxy/x86: libgstore_mod_proxy_0.2.3-x86.so (19478388B)
  - proxy/x86_64: libgstore_mod_proxy_0.2.3-x86_64.so (19619520B)
✓ 随包副本已生成: assets/app/modules.json
✓ 内置清单已生成: assets/app/modules_builtin.json
```

`Cargo.toml` 0.2.2 → 0.2.3 (so device `version()` distinguishes this binary).

### 7. CI asserts

```
$ ./scripts/ci/assert_proxy_module_artifacts.sh
OK    : [proxy/arm64-v8a] 16948584 bytes, DT_NEEDED=[libc++_shared.so libdl.so libm.so libc.so ]
OK    : [proxy/armeabi-v7a] 11104172 bytes, DT_NEEDED=[...]
OK    : [proxy/x86] 19478388 bytes, DT_NEEDED=[...]
OK    : [proxy/x86_64] 19619520 bytes, DT_NEEDED=[...]
OK    : modules.json 'proxy' 4 ABIs, asset 命名+sha256+size 一致
OK    : 随包清单 assets/app/modules.json == 发布清单
OK    : modules_builtin.json 含 proxy（临时内置）
OK    : [proxy/jniLibs/arm64-v8a] 16948584 bytes
...
   expected: GS_PROXY_CONTRACT_FP=d318929244733152
OK    : [arm64-v8a] GS_PROXY_CONTRACT_FP=d318929244733152
OK    : [armeabi-v7a] GS_PROXY_CONTRACT_FP=d318929244733152
OK    : [x86] GS_PROXY_CONTRACT_FP=d318929244733152
OK    : [x86_64] GS_PROXY_CONTRACT_FP=d318929244733152
PASS: 4 ABI 随包模块均由当前合约源码构建（指纹 GS_PROXY_CONTRACT_FP=d318929244733152）
PASS: proxy 深度产物断言全部通过

$ ./scripts/ci/assert_module_artifacts.sh
PASS: 20 个产物全部存在且非零字节
```

`assert_apk_module_payload.sh` needs an APK dir argument (post-`flutter build
apk`); not run here (no APK build in this session — the F-wave owns the build
gate).

## Behavioral guards honored

- **Default OFF**: `BreakpointConfig.enabled` defaults `false` in Rust constants,
  API.md, and Dart; the stubs never touch the dataplane, so traffic is
  **byte-for-byte unchanged**.
- **Never blocks past timeout**: no dataplane entry exists; the frozen contract
  pins `timeoutMs ∈ [1000,120000]` with auto-release semantics for the future
  implementation.
- Contract expansion is limited to breakpoints; no unrelated pages touched
  (the two page edits are the mandatory sealed-switch exhaustiveness cases for
  the new event); no version bump of the app (`pubspec.yaml` untouched).

## Deferral recommendation (follow-up plan)

Move the T34 dataplane + UI into a dedicated plan (do **not** delete scope):
1. `breakpoint.rs`: real global config (persist `<dataDir>/breakpoint.json`),
   match by `urlPattern`/`matchType` (reuse §2.19 semantics), pending registry
   (`handle` → `oneshot::Sender<Resolution>`), `Resolution` carrying edited
   request/response; `list`/`resume`/`cancel` real arms.
2. `mitm.rs`: request-side pause (buffer `Incoming` bounded by `maxBodyBytes`,
   emit `proxy.capture.breakpoint`, `tokio::time::timeout`, rebuild request) and
   response-side pause (buffer upstream body, overlay edited status/headers/body).
3. Thread `instance_id` into `BridgeContext` (`dispatch.rs::bridge_context`) so
   the event carries the right id.
4. Dart: a breakpoint list page + edit bottom sheet (via `AppSheet`), consuming
   `proxy.capture.breakpoint`, with `captures.breakpoint.resume/cancel`.
5. Tests: `cargo test --lib breakpoint` covering pause→edit→resume, timeout
   auto-release, and passthrough when off; `flutter test
   test/proxy_breakpoint_test.dart` for the UI; device smoke in F3.

## Risks

- The stub methods return `NOT_IMPLEMENTED` (500) until the dataplane lands; the
  shipped `.so` (0.2.3) dispatches them but cannot pause flows. This is
  intentional and documented in API.md §2.20 + §5.
- The contract shape is now frozen; the follow-up must not reorder/rename fields
  without a new C5 sync.
- `rust/release-modules/` and `assets/app/modules.json` are gitignored; only
  `assets/app/modules_builtin.json` + the jniLibs `.so` are committed.
