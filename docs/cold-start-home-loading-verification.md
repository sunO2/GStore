# 冷启动首页 loading 优化 — 交付验证记录

- 交付对象：`.omo/plans/gstore-cold-start-home-loading.md`（v2，momus + oracle 双审后修订）
- 基线提交：`e429be12`（`e429be121cdecf7db8fda610b4e6bbcc4a644661`，2026-10-29 21:34:16 +0800）
- 记录日期：2026-10-30
- 交付方式：直接落盘、不 push；本文件只记录证据，不改任何代码

## 1. 验收门（F1–F5）

| 门 | 实测结果 | 证据 |
|---|---|---|
| F1 `gstore_core` | **326 passed / 1 failed**；唯一失败 `catalog_query_perf_10k`（p95 **56.17 ms > 50 ms**，基线既有，`NEW=0`） | `/tmp/f1.log` ↔ `docs/rust-baseline-core.txt` |
| F2 `gstore_host`（串行） | **160 passed / 0 failed**（`--test-threads=1`） | `/tmp/f2.log` ↔ `docs/rust-baseline-host.txt` |
| F2 并行伪失败裁决 | 仅并行出现的 bridge 失败（如 `channel_api_script_detail_action_runs_pack_jscall`）在**纯净基线** `e429be12` 上 **6 次复现 2 次**，同样 ~30 s `showUAPicker` 超时 panic；失败身份在两棵树间漂移（基线 2/6 vs 当前 3/4）→ **既有顺序依赖共享全局竞态，非本次回归** | `/tmp/f2-adjudication.md`、`/tmp/flake-baseline-{1..6}.log`、`/tmp/flake-current-{1..4}.log` |
| F3 release 单测 | **62 passed / 0 failed / 1 ignored**（`#[ignore]` = 计时基准） | `/tmp/f3.log` |
| F3 计时基准 | `new=18ms legacy=7ms`（4000 行，**warm cache，不是门禁**） | `docs/rust-bench-mod-repo.txt`（较早一轮记 16 ms / 8 ms，结论相同：两步查询 CPU 上更慢，收益在冷页缓存下不读 `metadata`/`versions`） |
| F3 查询计划（这才是门禁） | ① `SCAN apps USING COVERING INDEX idx_apps_search`；② `SEARCH apps USING INDEX sqlite_autoindex_apps_1` | 同上 |
| F4 `flutter analyze lib/` | **0 errors / 81 warnings / 587 info（668）** == 基线，逐项相同 | `docs/dart-baseline.txt` |
| F5 `flutter test` | **NEW=0 / GONE=0 / STILL_FAILING=51**（4677 passed / 51 failed / 10 skipped） | `docs/flutter-test-baseline.txt`、`/tmp/f5b-diff.txt` |

### 基线出处（provenance）

全部在 `e429be12` 的纯净 worktree `GStore-baseline`（detached、改动前）采集：

| 文件 | 内容 |
|---|---|
| `docs/rust-baseline-core.txt` | 47 个 target：**319 passed / 1 failed / 0 ignored**；唯一失败 `catalog_query_perf_10k` |
| `docs/rust-baseline-host.txt` | 并行 142/9；**串行 151/0**；9 个并行失败定位为全局态污染（`channel_changed_pushed` → 8 个 `PoisonError` 级联） |
| `docs/dart-baseline.txt` | `flutter analyze lib/`：0 error / 81 warning / 587 info / 668 |
| `docs/flutter-test-baseline.txt` | 455 suites / 4734 tests：4673 passed / **51 failed** / 10 skipped |
| `docs/rust-bench-mod-repo.txt` | F3 release 套件 + 计时基准 + 3 条 EXPLAIN 原文 |

## 2. F6 / F7 真机门：BLOCKED

- **F6**（旧机冷启动 `开始加载应用数据` → `✅ 获取到 N 个聚合应用` < 200 ms、`repo: instance N created` 仅 1 次、per-method 计数、无新增 `download_repo`）与 **F7**（首页/发现页/GStore/详情页图标一致，含无本地索引的干净安装）**BLOCKED**：`adb devices` 为空，无物理 ARM64 设备；x86_64 宿主机起不了 ARM64 AVD（QEMU2 直接拒绝，`-machine virt` 变通在 guest `system_server` 启动阶段 SIGSEGV）。
- x86_64 模拟器**代理**（`/tmp/f6-proxy-evidence.md`）只证明了：
  - debug x64 APK 可构建/安装，包内 `.so` 与重建的 jniLibs 同批次（AGP 重写 ELF trailer，program headers 一致）；
  - 两次**并发** `ModuleBootstrap.acquire(official)` 只产生 **1 条** `repo: instance 1 created` → 双实例（D-B）修复在真实进程内生效；
  - 新 `call_impl` 日志上线（`repo: call_impl done method=get_app_count instance=1 elapsed_ms=0 ok=true`）；
  - 首页加载 52 ms wall / `elapsedMs=50`，但只有 **0 行**（模拟器 repo DB 为空）。
- 代理**没有**证明：57 s 冷启动复现、19 行首页的 per-method 计数与 `channels={fdroid:…}` 分布、真实冷页缓存 I/O、ARM64 二进制正确性、真机图标一致性。因此 F6/F7 记 **BLOCKED**，不记 PASS。

## 3. 计划规定的提交（本次未创建）

1. `perf(repo): exact package lookup, batch icon probe, two-step search with covering index`
2. `perf(core): page-scoped icon prefetch, drop redundant update-path index ensure`
3. `fix(host): make ChannelApi::init idempotent so one repo module instance is shared`
4. `feat(applist): non-blocking refresh with re-entrancy guard`
5. 可选 hygiene：`chore(repo): WAL + busy_timeout`

`jniLibs` 下的 8 个 `.so` 随提交 1 入库（该目录是仓库既有约定）；不 push。

## 4. 工作树清单与提交分组（只读盘点）

### 4.1 `git status --short`（原文）

```
 M android/app/src/main/jniLibs/arm64-v8a/libgstore_host.so
 M android/app/src/main/jniLibs/arm64-v8a/libgstore_mod_repo.so
 M android/app/src/main/jniLibs/armeabi-v7a/libgstore_host.so
 M android/app/src/main/jniLibs/armeabi-v7a/libgstore_mod_repo.so
 M android/app/src/main/jniLibs/x86/libgstore_host.so
 M android/app/src/main/jniLibs/x86/libgstore_mod_repo.so
 M android/app/src/main/jniLibs/x86_64/libgstore_host.so
 M android/app/src/main/jniLibs/x86_64/libgstore_mod_repo.so
 M lib/page/home/tab/applist/logic.dart
 M lib/page/home/tab/applist/state.dart
 M lib/page/home/tab/applist/view.dart
 M rust/ARCHITECTURE.md
 M rust/gstore_core/src/aggregate/service.rs
 M rust/gstore_core/src/channel/driver.rs
 M rust/gstore_core/src/channel/fdroid.rs
 M rust/gstore_core/src/ports/repo.rs
 M rust/gstore_core/tests/fdroid_home_vs_detail_icon.rs
 M rust/gstore_host/src/bridge.rs
 M rust/gstore_host/src/repo_port.rs
 M rust/gstore_mod_repo/src/lib.rs
 M rust/gstore_mod_repo/src/repo.rs
 M test/live_refresh_test.dart
?? dist/
?? docs/cold-start-home-loading-verification.md
?? docs/dart-baseline.txt
?? docs/flutter-test-baseline.txt
?? docs/rust-baseline-core.txt
?? docs/rust-baseline-host.txt
?? docs/rust-bench-mod-repo.txt
?? test/applist_refresh_non_blocking_test.dart
```

未跟踪文件仅：`dist/`（**禁止入库**）、5 个 `docs/*baseline*.txt` / `rust-bench-mod-repo.txt`（证据）、本文件、`test/applist_refresh_non_blocking_test.dart`。没有其它新增文件。

### 4.2 `git diff --stat`（原文）

```
 .../src/main/jniLibs/arm64-v8a/libgstore_host.so   | Bin 7664048 -> 7681888 bytes
 .../main/jniLibs/arm64-v8a/libgstore_mod_repo.so   | Bin 4181232 -> 4215760 bytes
 .../src/main/jniLibs/armeabi-v7a/libgstore_host.so | Bin 5295416 -> 5307240 bytes
 .../main/jniLibs/armeabi-v7a/libgstore_mod_repo.so | Bin 2823064 -> 2846160 bytes
 android/app/src/main/jniLibs/x86/libgstore_host.so | Bin 8735196 -> 8763756 bytes
 .../app/src/main/jniLibs/x86/libgstore_mod_repo.so | Bin 4482176 -> 4527016 bytes
 android/app/src/main/jniLibs/x86_64/libgstore_host.so  | Bin 8922328 -> 8951608 bytes
 .../src/main/jniLibs/x86_64/libgstore_mod_repo.so  | Bin 4597568 -> 4646800 bytes
 lib/page/home/tab/applist/logic.dart               |  85 ++-
 lib/page/home/tab/applist/state.dart               |   8 +-
 lib/page/home/tab/applist/view.dart                |  20 +-
 rust/ARCHITECTURE.md                               |  30 +
 rust/gstore_core/src/aggregate/service.rs          | 288 ++++++++-
 rust/gstore_core/src/channel/driver.rs             |  36 ++
 rust/gstore_core/src/channel/fdroid.rs             | 438 ++++++++++++-
 rust/gstore_core/src/ports/repo.rs                 |  68 ++
 .../tests/fdroid_home_vs_detail_icon.rs            |  95 ++-
 rust/gstore_host/src/bridge.rs                     | 191 +++++-
 rust/gstore_host/src/repo_port.rs                  | 296 ++++++++-
 rust/gstore_mod_repo/src/lib.rs                    | 450 +++++++++++---
 rust/gstore_mod_repo/src/repo.rs                   | 688 +++++++++++++++++++--
 test/live_refresh_test.dart                        |   7 +
 22 files changed, 2485 insertions(+), 215 deletions(-)
```

### 4.3 按计划 4 个提交 + hygiene 分组

| 提交 | 文件 |
|---|---|
| 1 `perf(repo)` | `rust/gstore_mod_repo/src/lib.rs`、`rust/gstore_mod_repo/src/repo.rs`（**仅搜索/主键/批量图标 hunks**）、`rust/gstore_host/src/repo_port.rs`、`rust/gstore_core/src/ports/repo.rs`、`android/app/src/main/jniLibs/*/{libgstore_host,libgstore_mod_repo}.so`（8 个，跨 4 ABI，构建产物不可按提交拆分，按计划随提交 1） |
| 2 `perf(core)` | `rust/gstore_core/src/channel/driver.rs`、`rust/gstore_core/src/channel/fdroid.rs`、`rust/gstore_core/src/aggregate/service.rs`、`rust/gstore_core/tests/fdroid_home_vs_detail_icon.rs` |
| 3 `fix(host)` | `rust/gstore_host/src/bridge.rs` |
| 4 `feat(applist)` | `lib/page/home/tab/applist/{logic,state,view}.dart`、`test/live_refresh_test.dart`（fake 对齐 `refreshSilently`）、**新增** `test/applist_refresh_non_blocking_test.dart` |
| hygiene `chore(repo)` | `rust/gstore_mod_repo/src/repo.rs` 的 WAL + `busy_timeout` hunks（与提交 1 同文件 → 必须 `git add -p` 拆分） |
| 文档/证据（计划未规定） | `rust/ARCHITECTURE.md`（附录 D）、`docs/*baseline*.txt`、`docs/rust-bench-mod-repo.txt`、本文件 —— 建议随 hygiene 或独立 `docs:` 提交，**不要**混进 1–4 |

### 4.4 禁入 / 风险项

- **`dist/`（未跟踪）禁止提交**：内含 2 个历史 APK + `apk-release/` 6 个 APK（约 240 MB / 合计 ~580 MB），与本次交付无关。
- **`frb_generated` 无改动**：`git status --short | grep -i frb_generated` 为空；4 个受跟踪文件（`lib/core/rust/generated/frb_generated{,.io,.web}.dart`、`rust/gstore_host/src/frb_generated.rs`）均未出现在清单中 → 本次无 FRB 签名变化，正确。
- **`rust/test-fixtures/v3/` 无改动**：`git diff --stat rust/test-fixtures/v3` 输出为空；ABI 仍为 4（冻结夹具未触碰）。
- `android/.../jniLibs/*.so` 的二进制改动是**允许**的（仓库既有约定，Must NOT Have 明确放行），但入库前应确认是最终 release 构建。
- `rust/gstore_mod_repo/src/repo.rs` 同时承载提交 1 与 hygiene 两类改动，禁止整文件 `git add`（会把 WAL 混进 perf 提交，破坏可独立回滚）。

### 4.5 禁入项校验命令与结果

```
$ git diff --stat rust/test-fixtures/v3
(空)

$ git status --short | grep -i frb_generated
(空)

$ git diff --name-only | grep -i frb_generated
(空)
```

结论：无生成物、无冻结夹具改动，无需重新 codegen。
