# gstore-rust-core-spike — Baseline（Todo 1）

计划：`gstore-rust-core-spike` / Todo 1「创建 spike worktree、分支与基线报告」。

- 基线提交（v3 树，fixture 构建源）：`9ec5132`（`9ec51320c0d2af107379744463325d36cdcd661c`）
- 当前分支 HEAD：`a68a3c3`（`a68a3c3ece1c006228b775201ad05648fabb2624`，`spike/rust-core-contracts`）
- 说明：本分支在 `9ec5132` 之后已落地 Todo 2–5/14/16 等提交，`GSTORE_MODULE_ABI_VERSION` 已由 3 提升为 4，因此**本分支不是干净的 v3 树**。

## Dart 分析基线（`dart analyze lib/`）

| 项 | 值 | 计划预期 | delta |
| --- | --- | --- | --- |
| exit code | 2 | 2 | 无 |
| errors | 0 | 0 | 无 |
| warnings | 95 | 95 | 无 |
| infos | 635 | 635 | 无 |
| 合计 | 730 | 730 | 无 |

证据：`target/spike-evidence/01-dart-analyze.txt`（由 QA happy 命令生成，任务未重新运行）。

## Flutter 测试基线（`flutter test`）

| 项 | 值 |
| --- | --- |
| exit code | 1（`04:21 +4381 ~2 -125: Some tests failed.`） |
| passed / skipped / failed | 4381 / 2 / 125 |

证据：`target/spike-evidence/01-flutter-test.txt`（`Failing tests:` 列表截断为前 4 个 + `... and 121 more`）。

**失败根因（环境问题，非产品缺陷）**：

1. **缺失宿主 `libsqlite3.so`**：证据中 85 行提及该文件名（`sqflite_common_ffi` DatabaseException 的 `sqflite_common_ffi` 相关失败，证据中 `sqflite_common_ffi` 共 149 处），测试环境未安装 SQLite 宿主动态库。
2. **缺失 `libgstore_host.so`**：基线时刻 release 宿主桥尚未构建，涉及宿主桥的测试无法加载（证据中 `libgstore_host` 共 283 处提及）。

**证据中 4 个字面失败测试名**（均来自 `test/added_app_tags_test.dart`，其余 121 个在截断之外）：

- `AppTagDao（v5 全新库） clearChannel / clearAll 清理`
- `AppTagDao（v5 全新库） insertTag + getTags 往返：写入 2 个标签可完整读出（含 addTime）`
- `AppTagDao（v5 全新库） insertTags 批量写入`
- `AppTagDao（v5 全新库） removeTagsOfApp：清理应用全部标签，其他应用不受影响`

## Rust 测试基线（per-crate `cargo test`）

命令统一为 `timeout 240 cargo test --manifest-path rust/<crate>/Cargo.toml`；`gstore_host` 仅单元测试：`timeout 240 cargo test --manifest-path rust/gstore_host/Cargo.toml --lib`（集成测试需预构建模块 `.so`，不在基线范围）。

| crate | 命令 | exit | test result |
| --- | --- | --- | --- |
| gstore_mod_perf | cargo test | 0 | ok. 11 passed; 0 failed |
| gstore_mod_llm | cargo test | 0 | ok. 11 passed; 0 failed |
| gstore_mod_repo | cargo test | 0 | ok. 45 passed; 0 failed |
| gstore_mod_download | cargo test | 0 | ok. 57 passed; 0 failed |
| gstore_mod_analyzer | cargo test | 0 | ok. 128 passed; 0 failed |
| gstore_mod_qr | cargo test | 0 | ok. 7 passed; 0 failed |
| gstore_host | cargo test --lib | 0 | ok. 74 passed; 0 failed |
| gstore_mod_proxy | **不构建** | — | **ENV-BLOCKED**（bindgen 缺 `libclang`，见下） |
| gstore_contract | 既有记录 | 0 | 23 passed; 0 failed |
| gstore_core | 既有记录 | 0 | 4 passed; 0 failed |

- 无 crate 触发 240s 超时。
- `gstore_mod_proxy`：不构建；记录 **ENV-BLOCKED (missing libclang for bindgen)**，一行错误为 `bindgen-0.72.1 ... Unable to find libclang: "couldn't find any valid shared libraries matching: ['libclang.so', 'libclang-*.so', ...]"`（证据 `target/spike-evidence/04-proxy-env-blocked.txt`）。

证据：`target/spike-evidence/01-cargo-test.txt`。

## ABI 状态

- 本分支 `GSTORE_MODULE_ABI_VERSION = 4`（`rust/gstore_contract/src/abi.rs:15`）。
- 不可变的 v3 fixture 位于 `rust/test-fixtures/v3/linux-x86_64/libgstore_mod_repo.so`，sha256 = `bdd4a79f94098af19430ef4af8dbbe61977382448b6903f4b64b1640963cbbce`，构建于 `9ec5132`（bump 之前）。
- 结论：本分支 **NOT a clean v3 tree**（ABI 常量已升到 4，v3 fixture 为基线期构建的对照样本）。

## 带入 spike 报告的既有发现（pre-existing findings）

1. Dart 静态分析 730 issues（0 errors / 95 warnings / 635 infos），与 `docs/qa-baseline.json` 基线一致（14-quality 验证 PASS）。
2. `flutter test` 125 失败，全部为环境问题（缺 `libsqlite3.so` / `libgstore_host.so`），非产品代码缺陷。
3. `gstore_mod_proxy` clippy 与 test 均 ENV-BLOCKED（缺 `libclang`，bindgen 无法运行）。
4. Rust `unexpected_cfgs` rustc 警告在多个 crate 编译输出中可见（如 `02-v3-fixture.txt`、`03-abi-guard.txt`、`04-contract.txt`），为既有警告。
5. 既有 crate clippy 基线：dart=730、clippy=99（`14-quality.txt`）。

## QA 记录

- 证据：`target/spike-evidence/01-baseline.txt`（本摘要）；`target/spike-evidence/01-clean.txt`（`git status --porcelain`，任务改动仅限 `docs/spike/baseline.md`，`target/` 不出现）。
