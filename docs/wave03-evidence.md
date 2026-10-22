# Android Wave 3 — evidence index

- **Branch:** `wave02/rust-core-catalog` in worktree `GStore-wave02`
- **Wave 3 code range:** `e5692829..6ea4de02` = **12** commits (Todo 1-7),
  followed by the Todo 8 Gate 3 docs commit `test(download): close Wave 3 Gate`.
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
| 8 | `target/test-evidence/87-gate3.txt` | 11576 | `1f59dcb66dbc67bfd7a28b79bdb4b01f9f5cd18135fa0a913d0db58496c4e8c7` |
| 8 | `target/test-evidence/87-gate3-fail.txt` | 3815 | `9bd145b49b024d1f6171aba5fcc1393c03edd543f53945f1cbd56b5b76634f93` |

## Gate 3 (Todo 8) mapping

- `87-gate3.txt` — full Gate 3 matrix: Rust core/host totals, focused Flutter
  suite (50/50), parity `--download` (`rows=14`, idempotent second migration),
  `--channel` / `--catalog`, baseline-aware `f2-quality.sh` (`NEW findings 0`),
  strict core clippy, FRB codegen idempotency, Kotlin compile, release APK
  (150589102 bytes, sha256
  `bf6d90eb67cbbf6a77daf549c2fc394e5eef06e31f27df23a47acf4b02340382`),
  `adb devices` (BLOCKED, no device), flags/old-path proof, and scope audit.
- `87-gate3-fail.txt` — injected field/path parity drift (both EXIT 1 with exact
  diff lines), mutually exclusive suite selection (EXIT 2), and the explicit
  device BLOCKED record.

## Status summary

- Code/release gates: **PASS** (see `docs/wave03-completion.md`).
- Device QA: **BLOCKED** (`adb devices` empty). Not a pass; no on-device
  install/notification/FGS claim is made.
- All flags stay false by default; the legacy Dart path remains authoritative;
  no old writer was deleted; no version bump.
