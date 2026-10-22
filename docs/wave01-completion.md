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
- **APK (historically phone-tested):** `build/app/outputs/flutter-apk/app-debug.apk`,
  **261,002,945 bytes**,
  sha256 `5a585b6a0b2459a21e34d126546d20927997d5bd0c1028db6c357d7f170cf524`.
  This is the APK behind the 11/0/0 phone PASS above.
- **APK (rebuilt during the host `.so` refresh, not phone-verified):** same
  path and same **261,002,945 bytes**, but sha256
  `21580a2875ec03a5d6d82e0eb358c6ca521b5df3207a5f47896298cf82d08180`. The
  packaged `lib/arm64-v8a/libgstore_host.so` is sha256 `d93506dc…` — the
  deterministic `llvm-strip --strip-unneeded` result of the tracked jniLibs copy
  `1d898dca…` (8-byte AGP strip delta, not a stale binary). See
  `target/test-evidence/50-so-verify.txt`.
- **Marker commit:** the phone log lives under gitignored `target/`, so history
  carries the empty commit `test(qa): run F3 phone smoke with core fixtures`
  (`80ff423c`, `Plan-Todo: 3`). The proof is the log, not the commit tree.

## Host `.so` refresh (2026-10-22)

Rebuilt the four tracked host libraries from current Wave 0/1 source with NDK
`26.3.11579264`:

```bash
GSTORE_PROJECT_DIR=$PWD/rust/gstore_host \
GSTORE_LIB_DIR=$PWD/android/app/src/main/jniLibs \
GSTORE_NDK_PATH=$NDK \
bash build_android_rust.sh --host-only
```

| ABI | New size (bytes) | sha256 |
|---|---|---|
| `arm64-v8a` | 5,923,992 | `1d898dca689b8362b52b641707f62e8f0f1035f683a1d71c5f444848646b3a53` |
| `armeabi-v7a` | 3,951,704 | `5150aa85be7dacc4291c296af38ef4c82555ac3dc5e8e3188d7d3ce50c912eb5` |
| `x86_64` | 6,748,496 | `68743892995a778a06bc20222428461ef2a8136a18b58463fdc77a9512fd5f48` |
| `x86` | 6,448,200 | `f07656d5587a44904a08bfb818505077f090f5279ac07a1c124a6024c886b3e0` |

Static `llvm-objdump` proof: `frb_get_rust_content_hash` decodes to
`0x736d7af6` (`1936554742`) on all four ABIs. Module `.so`
(qr/analyzer/repo/download/proxy/perf/llm) are separate and untouched.

Evidence: `target/test-evidence/48-so-before.txt`,
`49-so-build.txt`, `50-so-verify.txt`, `51-so-commit.txt`. Per risk #2 below,
all of `target/` is gitignored.

## What is not done

- Wave 2: catalog, update, download, install cutover, JsChannel/rquickjs.
- No `CoreFlags` flip; the old Dart paths remain authoritative and
  `core_writes=0`.
- No desktop, HarmonyOS, iOS, or CLI work.
- No pack signatures.
- No version bump and no release.

## Residual risks

1. **Tracked host `.so` files are refreshed (resolved for host).** The four
   checked-in host libraries — `libgstore_host.so` for `arm64-v8a`,
   `armeabi-v7a`, `x86_64`, and `x86` under `android/app/src/main/jniLibs/` —
   were rebuilt from current Wave 0/1 source and now embed the current FRB
   content hash `0x736d7af6` (`1936554742`), replacing the stale `0x32512c08`.
   They are committed as `build(android): refresh tracked host libs for current FRB`,
   which sits on top of `989e6bb9`. The module `.so`
   (qr/analyzer/repo/download/proxy/perf/llm) are separate and untouched. This
   refresh is **static-only**: F3 was not rerun because no ARM64 device was
   attached (`F3 not rerun — no ARM64 device attached`), and the prior phone
   PASS (11/0/0) in `target/final/F3-device.log` is historical evidence for the
   earlier APK, not for this rebuild.
2. **Evidence is gitignored.** `target/` (including `target/final/F3-device.log`
   and `target/test-evidence/`) is not tracked. This document is the durable,
   tracked record; the raw logs live only on this machine/worktree.
3. **F3 is a debug harness, not a UI tap-through.** It runs
   `lib/debug/core_smoke.dart` under `GSTORE_CORE_SMOKE=true` and checks SQLite
   rows. It proves the core path, not end-user UI flows, and not Wave 2 behavior.

## Next plan

`gstore-rust-core-android.md` **Wave 2** — not started in this closeout.
