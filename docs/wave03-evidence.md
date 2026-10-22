# Android Wave 3 — evidence index

- **Branch:** `wave02/rust-core-catalog` in worktree `GStore-wave02`
- **Wave 3 code range:** `e5692829..6ea4de02` = **12** commits (Todo 1-7),
  followed by the Todo 8 Gate 3 docs commit `test(download): close Wave 3 Gate`.
- **Feature HEAD:** `6ea4de02e0acaa4b697d42746ca76d907020da70`
  (`fix(download): import legacy before any core read`).
- **Final code HEAD:** `42dfde34f5896ab588ffa701c1ee776baafbbe5d`
  (`docs(download): record final-wave fixes`), the last code commit after the
  final-wave fixes `ce7ef133` and `e918c77a`.
- **Current docs-only HEAD:** `2915f462b49d03c483a3dac1c1fefbe1501866af`
  (`docs(download): rebuild release APK for final HEAD`); its only changes are
  `docs/wave03-completion.md` and `docs/wave03-evidence.md`.
- **Date:** 2026-10-22

## How to read this index

The raw logs live under `target/test-evidence/`. That directory is
**local-only and gitignored** (`/target/` in `.gitignore`). This file is the
tracked pointer, not a copy of the logs. Each sha256 and byte size below was
computed with `sha256sum` / `stat -c %s` against the local file at the time this
index was written; a log regenerated later may hash differently, so treat a hash
mismatch as "new run", not necessarily "wrong result". No hash is invented here.

## Evidence table (`80-*` through `87-*`)

| Plan-Todo | File | Bytes | sha256 |
|---|---|---|---|
| 1 | `target/test-evidence/80-download-host.txt` | 45565 | `7d57fe7ebe049e79978f0a6a073095f3408c57374aff9ae5f139b269f9e80841` |
| 1 | `target/test-evidence/80-download-recover.txt` | 11824 | `182a36b375f1c490c2f060ea3726fec6ed630255bdf76c42f161249da0f8c769` |
| 2 | `target/test-evidence/81-download-api.txt` | 30424 | `a56d2943e5f3b287d0f95a0777c7392140356c374dca4aa029e518cd97f1df0b` |
| 2 | `target/test-evidence/81-watch-terminal.txt` | 6559 | `4106b5d69c635bec86161b09c67c279fa8b01d226dc5676064ae2f77bf773c3f` |
| 3 | `target/test-evidence/82-install-state.txt` | 33478 | `2c60dfecff3e023fa863fa5d1e3bccc6ba24ac6968a8ae826c83e54b65f8a6e2` |
| 3 | `target/test-evidence/82-install-idempotent.txt` | 44184 | `b4d966cfd70175020d7923abf90d6f8dceae72f246ea0d43a68d5e04f5dd7cc6` |
| 4 | `target/test-evidence/83-install.txt` | 7952 | `242c7b6af4a30df9a11fde541daa14c694670316de1310d770eebda939fa1e11` |
| 4 | `target/test-evidence/83-install-denied.txt` | 7568 | `1f0d23c965b2653efda797863f05cca75bb5b449d6b0e86fa10e01c6fcdd3ac4` |
| 5 | `target/test-evidence/84-notify.txt` | 5099 | `6fd28908fd315c555fe83b55051e88eb715e9b361aa471dffdbad4f09b7990f0` |
| 5 | `target/test-evidence/84-notify-denied.txt` | 2175 | `19955ff15220220389f349c04e85da1b1b3d558ab3f8662cc6583b813279f42a` |
| 6 | `target/test-evidence/85-facades.txt` | 24947 | `ed0de5a579c09224c11df44bf9b73bc85baaa338e31da2176cbf5ab47a545d8e` |
| 6 | `target/test-evidence/85-flag-off.txt` | 23228 | `40c050c569ccf1caa8887aaa85a5b70dbab564d5ef1a73d9d78d35b8fe1fc556` |
| 7 | `target/test-evidence/86-download-parity.txt` | 7793 | `b48435f1f649e6d6d097b5f419501d5b7c678d28e7a9e96a16dd4c84fd12f67a` |
| 7 | `target/test-evidence/86-download-parity-fail.txt` | 1849 | `49257571d456d56e912d06ea673630dda0ec605d47e0707435e58809efb01752` |
| 8 | `target/test-evidence/87-gate3.txt` | 12826 | `5104e6622b84e2fdd3e7dbe96b498492bce982120f0418ba63235cfdb9c78339` |
| 8 | `target/test-evidence/87-gate3-fail.txt` | 3815 | `9bd145b49b024d1f6171aba5fcc1393c03edd543f53945f1cbd56b5b76634f93` |
| Final-wave | `target/test-evidence/88-final-wave-fix.txt` | 7391 | `2f7727e391a6ca8be11231575a5cbab411529be2aff9115b2e69b209adf0fcb0` |

## Gate 3 (Todo 8) mapping

The full matrix counts in `87-gate3.txt` (core **161/161** across 23 binaries,
host **119/119** across 9 binaries, Flutter focused **50/50**) were produced at
code HEAD `6ea4de02e0acaa4b697d42746ca76d907020da70`. There was **no
full-suite rerun** at final code HEAD `42dfde34` or at docs-only HEAD
`2915f462`; after `6ea4de02` only the focused final-wave checks recorded in
`target/test-evidence/88-final-wave-fix.txt` were run.

- `87-gate3.txt` — full Gate 3 matrix: Rust core/host totals, focused Flutter
  suite (50/50), parity `--download` (`rows=14`, idempotent second migration),
  `--channel` / `--catalog`, baseline-aware `f2-quality.sh` (`NEW findings 0`),
  strict core clippy, FRB codegen idempotency, Kotlin compile, release APK
  (**rebuilt at final HEAD `42dfde34`**: 150589102 bytes, sha256
  `0bab385b600bc7d6f8fec419a2760083c22d01fd85291e4c9a3a85e81dcd38b3`),
  `adb devices` (BLOCKED, no device), flags/old-path proof, and scope audit.
  The original pre-rebuild Gate-3 APK is **superseded (historical)**. Its
  sha256 `bf6d90eb67cbbf6a77daf549c2fc394e5eef06e31f27df23a47acf4b02340382` (superseded, historical, pre-rebuild) is kept only as history;
  it predates `ce7ef133` / `e918c77a` (mtime 2026-10-22 21:43) and is not the
  current APK.
- `87-gate3-fail.txt` — injected field/path parity drift (both EXIT 1 with exact
  diff lines), mutually exclusive suite selection (EXIT 2), and the explicit
  device BLOCKED record.
- `88-final-wave-fix.txt` — FINAL-WAVE fix evidence: flag-on install has no
  legacy fallback (`CORE_E_INSTALL_NO_CORE_TASK`), import-before-list order,
  module-refresh proof for `DownloadApi.list`, 500 ms install pump and bounded
  Dart pending poller proof, plus the exact command exits above.

## Release rebuild (final HEAD)

- Built at/after code HEAD `42dfde34f5896ab588ffa701c1ee776baafbbe5d`
  (`docs(download): record final-wave fixes`; commit time
  2026-10-22 22:25:27 +0800, epoch 1792679127). The current branch HEAD is the
  later docs-only commit `2915f462b49d03c483a3dac1c1fefbe1501866af`
  (`docs(download): rebuild release APK for final HEAD`, 2026-10-22 22:41:50
  +0800), whose only changes are these two docs; the APK below was built before
  that docs commit and is unaffected by it.
- Command: `flutter build apk --release --target-platform android-arm64`
  (`EXIT: 0`, `assembleRelease` 76.9s).
- Artifact: `build/app/outputs/flutter-apk/app-release.apk`, 150589102 bytes,
  sha256 `0bab385b600bc7d6f8fec419a2760083c22d01fd85291e4c9a3a85e81dcd38b3`,
  mtime `2026-10-22 22:40:57 +0800` (epoch 1792680057 > 1792679127), so the
  artifact is newer than the final code commit and contains `ce7ef133`,
  `e918c77a`, and `42dfde34`.
- Recorded at the end of `target/test-evidence/87-gate3.txt` as
  `RELEASE REBUILD (final HEAD)` with `RESULT: PASS`; the `87-gate3.txt`
  sha256 in the table above was recomputed after that append.
- The prior Gate-3 APK hash `bf6d90eb67cbbf6a77daf549c2fc394e5eef06e31f27df23a47acf4b02340382` (superseded, historical, pre-rebuild)
  is kept only as history because it predates `ce7ef133`/`e918c77a`
  (150589102 bytes, mtime 2026-10-22 21:43). No code/flag/version change was
  made for this rebuild.

## Status summary

- Code/release gates: **PASS** (see `docs/wave03-completion.md`).
- Device QA: **BLOCKED** (`adb devices` empty). Not a pass; no on-device
  install/notification/FGS claim is made.
- All flags stay false by default; the legacy Dart path remains authoritative;
  no old writer was deleted; no version bump.
