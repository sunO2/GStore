# Android Wave 0/1 — completion record

- **Scope:** Android Wave 0/1 only (`gstore-rust-core-android-wave01`). Wave 2 is
  explicitly **not started**.
- **Repo / branch:** `GStore-wave01` @ `wave01/rust-core-channels`
- **Base:** `9ec5132` (`9ec51320c0d2af107379744463325d36cdcd661c`)
- **Final HEAD (closeout, before this doc commit):**
  `80ff423c7d1c452eacf0373ddc3a4424848712ef`
  (`test(qa): run F3 phone smoke with core fixtures` — empty marker, see below)
- **Commit count `9ec5132..80ff423c`:** **43**
- **Date:** 2026-10-22

## Gates

| Gate | Result | Evidence |
|---|---|---|
| F1 — plan compliance audit | **PASS** | `target/final/F1.md` (`f1_plan_audit_ok`, exit 0) |
| F2 — baseline-aware quality | **PASS** | `target/final/F2.md` (exit 0, 0 NEW findings) |
| Gate 1 — LocalDb parity / channel flag off | **PASS** | `target/test-evidence/14-gate1.txt` (parity OK twice, inject-diff exits 1, flags off) |
| F3 — ARM64 phone smoke (**F3 PASS**) | **PASS** | `target/final/F3-device.log`, `target/final/F3.md` |

### F3 detail

- **Device serial:** `10AFAL21AG00348`
- **ABI:** `arm64-v8a`
- **API level:** not captured in the authoritative log (device disconnected at
  closeout). No value is inferred.
- **Result:** `passed=11 failed=0 skipped=0` (**11/0/0**), `RESULT: PASS`
- **What ran:** install PASS, launch PASS (cold), process alive `pid=11407`, no
  `FATAL EXCEPTION`, channel-list=1, channel-search=1,
  channel-detail=`smoke/app`, local-pack=1, env-migration=1,
  parity `user_version=1` / `integrity=ok`, flags-off `core_writes=0`.
- **APK:** `build/app/outputs/flutter-apk/app-debug.apk`,
  **261,002,945 bytes**,
  sha256 `5a585b6a0b2459a21e34d126546d20927997d5bd0c1028db6c357d7f170cf524`.
- **Marker commit:** the phone log lives under gitignored `target/`, so history
  carries the empty commit `test(qa): run F3 phone smoke with core fixtures`
  (`80ff423c`, `Plan-Todo: 3`). The proof is the log, not the commit tree.

## What is not done

- Wave 2: catalog, update, download, install cutover, JsChannel/rquickjs.
- No `CoreFlags` flip; the old Dart paths remain authoritative and
  `core_writes=0`.
- No desktop, HarmonyOS, iOS, or CLI work.
- No pack signatures.
- No version bump and no release.

## Residual risks

1. **Tracked `.so` files are stale.** The checked-in
   `android/app/src/main/jniLibs/arm64-v8a/libgstore_host.so` (and the other
   checked-in host/module libraries) predate the regenerated FRB bridge and do
   not match the Dart-side codegen content hash. They **must be rebuilt from
   current source before shipping** any release APK. The F3 phone APK was built
   with a freshly rebuilt arm64 library; the tracked copy was not updated.
2. **Evidence is gitignored.** `target/` (including `target/final/F3-device.log`
   and `target/test-evidence/`) is not tracked. This document is the durable,
   tracked record; the raw logs live only on this machine/worktree.
3. **F3 is a debug harness, not a UI tap-through.** It runs
   `lib/debug/core_smoke.dart` under `GSTORE_CORE_SMOKE=true` and checks SQLite
   rows. It proves the core path, not end-user UI flows, and not Wave 2 behavior.

## Next plan

`gstore-rust-core-android.md` **Wave 2** — not started in this closeout.
