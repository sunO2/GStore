# gstore-rust-core-spike — 契约 / ABI / 端到端验证报告（Todo 15）

- Worktree：`/home/hezhihu89/develop/flutter/project/GStore-spike`
- 分支：`spike/rust-core-contracts`
- 日期：2026-10-21
- 证据目录：`target/spike-evidence/`（本报告引用的每个数字都来自其中的文件）
- 状态：**改动未提交**（orchestrator 负责提交）。生产 Dart/Rust 源码未改动；生成物
  （`lib/core/rust/generated/**`、`rust/gstore_host/src/frb_generated.rs`）由 codegen 刷新，
  生产二进制改动是重建的 `android/app/src/main/jniLibs/arm64-v8a/libgstore_host.so`。

---

## 1. TL;DR + 结论

**结论（明确）**

1. 对「据此修订 `gstore-rust-core-migration.md`」：**GO（无条件 GO，仅指修订主计划）**。
   理由：ABI v3/v4 双向矩阵、CoreApi 握手/迁移、`core_writes` 失败关闭、下载迁移与恢复、
   Dart/Rust parity、C ABI 生成与消费、最终 Rust/parity/C-ABI 回归**全部通过**；计划门
   **G5（worktree release APK）已在本 worktree 通过**（§7.2，exit 0）。
2. 对「执行 cutover / 打开 `CoreFlags` / 删除旧 Dart 写入路径」：**NO-GO**。
   **本 spike 不授权 cutover。** 所有 `CoreFlags` 保持默认 `false`，旧 Dart 路径仍是权威路径；
   spike 没有删除任何旧写入器。

> **判定标签：GO（无条件，仅限修订主计划） / NO-GO（cutover）**。
> 计划门 **G5 = PASSED**（worktree release APK 已生成，见 §7.2）；其余契约/ABI/parity/C-ABI
> 门同样全部 PASS。修订主计划无阻断项；cutover 仍被 `NO-GO` 与 C2/C3 约束。

**条件（必须写进主计划）**

- **C1（RESOLVED）**：**FRB codegen 漂移已修复。** 根因：HEAD 的
  `lib/core/rust/generated/` 与 `rust/gstore_host/src/frb_generated.rs` 来自一次不完整的
  codegen（33 个 wire 函数），而用仓库的 `frb_config.yaml` 干净重生成得到 43 个，缺 10 个
  API（§3.3）。修复：在 worktree 运行
  `cd rust/gstore_host && flutter_rust_bridge_codegen generate --config-file frb_config.yaml`
  （exit 0）后重建 Android arm64 `.so`；`grep -c 'fn wire__'` = **43**，release APK **exit 0**。
  证据：`15-build-pre-fix.txt`（修复前 exit 1）vs `15-build.txt`（修复后 exit 0）。
- C2（仍为条件/注意事项）：CI 的质量门不能把既有环境缺口当回归：`gstore_mod_proxy` 的
  clippy/test 需要 libclang；`flutter test` 需要 `libsqlite3.so` 与 `libgstore_host.so`。
- C3（仍为条件/注意事项）：下载 payload 的 snake_case / camelCase 双发是 spike 兼容层，
  主计划必须与真实 `gstore_mod_download`（camelCase）对齐并只保留一种序列化契约（§4、§9-8）。

---

## 2. ABI v3 / v4 矩阵

**常量与布局**（`rust/gstore_contract/src/abi.rs`）

| 项 | 值 | 证据 |
| --- | --- | --- |
| `GSTORE_MODULE_ABI_VERSION` | 4 | `03-abi-layout.txt`（`abi.rs:15`） |
| `MIN_HOST_ABI` | 3 | `03-abi-layout.txt`（`abi.rs:26`） |
| 布局版本 | 4（`abi_v4_layout` ok） | `03-abi-layout.txt` |
| v3 宿主 entry_size（x86_64） | **56**（= `PLATFORM_OFFSET`，无 `platform` 槽） | `05-handshake.txt`（`old_module_handshake` 断言） |
| v4 宿主 entry_size（x86_64） | **64**（= `sizeof(GStoreModuleEntry)`） | `05-handshake.txt`（`v3_module_rejects_v4_entry` 断言） |
| v3 模块拒绝 abi 4 的返回码 | **-2** = `ABI_ERR_ABI_MISMATCH` | `05-v3-reject.txt` |
| 冻结 v3 fixture | `rust/test-fixtures/v3/linux-x86_64/libgstore_mod_repo.so`，sha256 `bdd4a79f94098af19430ef4af8dbbe61977382448b6903f4b64b1640963cbbce`，构建于 `9ec5132`（ABI=3，**不导出** `gstore_mod_repo_abi`） | `02-v3-fixture.txt`、`05-handshake.txt` |

**矩阵结果**（`cargo test --manifest-path rust/gstore_host/Cargo.toml abi_handshake`，3 passed / exit 0；以及 `abi_v3_compat_tests`，7 passed / exit 0）

| 宿主 \ 模块 | v3 模块（冻结 fixture） | v4 模块（新构建） |
| --- | --- | --- |
| **v3 宿主**（entry_size 56） | **可挂载**：`old_module_handshake` 端到端 `DlModuleAdapter::load` 成功；探测符缺失 → 回退 entry 3 | **可挂载**：`v4_module_accepts_v3_host` 证明 v4 模块接受 `abi=3` / entry_size 56（`min_host_abi <= 3`） |
| **v4 宿主**（entry_size 64） | **生产路径可挂载**：探测符缺失 → `probe_abi` 回退 3 → 选择 v3 entry → 挂载成功。**原始 v4 entry 直调会被模块拒绝**：`v3_module_rejects_v4_entry` 断言模块返回 `code=-2`，且不是宿主侧 name/min_host_abi 错误 | **可挂载**：探针（dlsym 自真实 `.so`）返回 4，`handshake_with(..., 4)` 成功 |

**探测符回退规则**（`rust/gstore_host/src/dl_adapter.rs:71,111,289-303`）

- 模块可选导出 `gstore_mod_<name>_abi`（名字由 `.so` 文件名推导：`libgstore_mod_qr.so` → `qr`）。
- 符号存在 → 使用其返回值作为目标 ABI；**缺失 → 回退 3**。
- 唯一宿主 gate 是 `min_host_abi > GSTORE_MODULE_ABI_VERSION` 时拒绝；**不做精确匹配**，因此
  v4 模块能被 v3 宿主挂载、v3 模块能被 v4 宿主以 v3 entry 挂载。
- 负向证据：v3 模块收到 v4 entry 时返回 `-2`（`05-v3-reject.txt`），而不是宿主 gate 错误。

其他 ABI 守卫测试（`03-abi-layout.txt`，23 passed）：

- `platform_guard_rejects_short_entry`、`smaller_entry_size_skips_protect_fd_without_reading`、
  `capability_probe_fails_closed`、`host_abi_gate_is_forward_compatible`、`v3_entry_exposes_protect_fd`。
- `abi_v3_compat_tests` 还覆盖：`v2_module_still_mounts_on_v3_host_and_gets_protect_fd`、
  `v2_host_rejects_min_host_abi_3_module`、`rejects_future_abi`、`host_entry_selects_v3_and_v4`。

---

## 3. CoreApi / handoff / core_writes

### 3.1 FRB 暴露面

`CoreApi` 是 opaque 类型（`lib/core/rust/generated/bridge.dart`，证据 `06-frb.txt`、`06-core-api.txt`）：

| 方法 | 签名 | 语义 |
| --- | --- | --- |
| `CoreApi.init` | `(dataDir, filesDir, cacheDir)` → `Future<CoreApi>` | 打开/创建 core DB，返回 schema v1 |
| `migratePaths` | `()` → `Future<CoreInitResult>` | 迁移目录；`CoreInitResult{schemaVersion, dbPath, dataDir, filesDir}` |
| `importFile` | `(pathOrFd)` → `Future<BigInt>` | 导入旧数据文件 |
| `exportSnapshot` | `(path)` → `Future<BigInt>` | `VACUUM INTO` 快照 |
| `importSnapshot` | `(path)` → `Future<int>` | 导入快照（校验 `user_version`/表） |
| `coreWrites` | `(domain)` → `Future<CoreWritesMarker?>` | 读写入标记；无标记返回 `null` |

Dart 测试（`test/core_api_test.dart`）4 passed：init/migratePaths schema v1、snapshot round-trip、
缺文件 typed error、`core_writes` 在变更前写入（`07-core-writes.txt`、`06-dart.txt`）。

### 3.2 错误码

统一前缀 `CORE_E_*`（grep 自 `rust/`、`lib/`、`test/`）：

`CORE_E_NOT_INITIALIZED`、`CORE_E_INIT`、`CORE_E_MIGRATE`、`CORE_E_IMPORT_NOT_FOUND`、
`CORE_E_IMPORT_SNAPSHOT`、`CORE_E_IMPORT_MIGRATION`、`CORE_E_EXPORT`、`CORE_E_WRITES`、
`CORE_E_WRITE_BLOCKED`、`CORE_E_MIGRATION_VERSION`、`CORE_E_MIGRATION_KIND`、
`CORE_E_MIGRATION_SHAPE`、`CORE_E_MIGRATION_WRITE`、`CORE_E_MIGRATION_READ`、
`CORE_E_MIGRATION_JSON`。

证据：`06-core-api.txt` 断言缺文件 → 含 `CORE_E_IMPORT_NOT_FOUND`；`07-old-write-blocked.txt`
打印 `CORE_E_WRITE_BLOCKED: channel`；`08-handoff-rust.txt` 覆盖迁移文档错误码。

### 3.3 codegen 漂移（已发现并修复）

- 同一配置下连续两次 codegen **字节一致**：`rust/gstore_host/src/frb_generated.rs` +
  16 个 Dart 生成文件 sha256 两次运行完全相同，`cargo check` exit 0（`08-frb-drift.txt`、`06-frb.txt`）。
  这证明 codegen 本身可复现；但当时签入的产物与 `bridge.rs` **不一致**，见下。
- **漂移实测**：修复前 HEAD 的 `rust/gstore_host/src/frb_generated.rs` 只有 **33** 个
  `fn wire__*`；用仓库配置干净重生成得到 **43** 个；缺 **10** 个 API：
  `battery_power_interactive`、`battery_read_json`、`device_state_read_json`、
  `foreground_read_json`、`frame_metrics_read_json`、`install_host_panic_hook`、
  `ModuleHandle` get/set id、`shizuku_available`、`shizuku_exec`。
- **根因**：签入的生成物来自一次不完整的 codegen 运行。复现要点：必须使用仓库的
  `rust/gstore_host/frb_config.yaml`（`rust_input: crate::bridge`）；
  从 worktree 根使用 `pubspec.yaml` 内嵌配置（`rust_input: gstore_host::bridge`）运行
  `flutter_rust_bridge_codegen generate` 只会重新生成 **33** 个 wire 函数，并打印
  `crate::*` 与 `gstore_host::*` 的重复对象告警。因此修复命令必须显式指定 config file。
- **修复**（在本 worktree 执行，未改生产源码）：
  `cd rust/gstore_host && flutter_rust_bridge_codegen generate --config-file frb_config.yaml`
  → exit 0；`grep -c 'fn wire__' rust/gstore_host/src/frb_generated.rs` = **43**；
  `crateBridgeBatteryReadJson` / `crateBridgeBatteryPowerInteractive` /
  `crateBridgeDeviceStateReadJson` / `crateBridgeForegroundReadJson` /
  `crateBridgeFrameMetricsReadJson` 在生成的 Dart 中均为声明 + 实现各 1 处（grep count = 2）。
  随后重建 Android arm64 `.so`（§7.1）。
- **证明**：修复前 `flutter build apk --release --target-platform android-arm64` 在
  `kernel_snapshot` 失败（7 个 `The method 'crateBridge…' isn't defined…`），日志保留在
  `15-build-pre-fix.txt`；修复后同一命令 **exit 0**，见 `15-build.txt`（§7.2）。
- 结论：主计划仍须把「FRB 生成物与 `bridge.rs` 同步」纳入 CI 漂移门（§9-12），并固定
  FRB 2.11.1 与 codegen 使用的 config file。

### 3.4 顺序：export → migratePaths → import → delete

`MigrationHandoff.start` 的强制顺序（`08-handoff-rust.txt`、`08-handoff-dart.txt`）：

1. ensure / export `channel_env.json`、`update_prefs.json`（version 1 文档，`0600`）；
2. `CoreApi.migratePaths()`；
3. import `channel_env`；
4. import `update_prefs`；
5. **每个文件只在其自身 import 成功后删除**。

失败时保留全部文件；重试复用保留文件、**不重新 export**。Dart 测试 4 passed（含
`start retains files after failure and resumes without re-export`，exit 0）。

### 3.5 core_writes

- `mark_core_write(domain, snapshot_id)`：`INSERT OR IGNORE`，first-write-wins，幂等
  （`rust/gstore_core/src/migration.rs`）。
- **写入发生在变更之前**：`test/core_api_test.dart` 的
  `init writes core_writes markers before mutation`（4 passed，`07-core-writes.txt`）。
- 旧写路径失败关闭：`ensure_legacy_write_allowed(conn, domain)` 在 marker 存在时返回
  `CORE_E_WRITE_BLOCKED: <domain>`（`07-old-write-blocked.txt`，测试 `core_writes_guard` ok）。
  未标记的域（例如 `update`）仍可写（`core_writes_guard` 测试内断言）。
- Dart 侧 `LegacyWriteGuard.assertAllowed`：`CoreFlags.coreWrites == false` 时**直接 no-op**，
  旧路径权威；仅 flag 打开后才探测 marker 并抛 `LegacyWriteBlocked`。
- 默认关闭：`lib/core/core_flags.dart` 定义 `static bool coreWrites = false;`、
  `static bool download = false;`；`grep -rn "CoreFlags.coreWrites = true|CoreFlags.download = true" lib/`
  **无命中**（`15-flags-off.txt`）。

---

## 4. Download

### 4.1 端口契约

`rust/gstore_core/src/download/port.rs`：

- `ModuleBridge`：`call(method, payload) -> Result<Vec<u8>, String>`。
  **core 不链接模块 cdylib**，只经此 seam 调用下载模块（C-ABI/FRB 由宿主实现）。
- `DownloadPort`：`db_path`、`start`、`list`、`get`、`pause`、`resume`、`cancel`、`retry`、
  `restart`、`remove`、`watch_all`、`snapshot`、`reconcile`。
- `start`：先 `download.start`，再 upsert core `download_task` 行（`status` 映射）；
  `cancel` 等先调模块再更新 core 状态。
- 错误：`PortError::{Module, Db, UnknownTask, NeedsRestart}`；未知模块任务 id →
  `NeedsRestart("999")`（`09-download-error.txt`）。
- `watch_all` 在 spike 内退化为 `snapshot()`；实时事件流留给主计划（代码注释明确）。

测试：`download_port_contract` 1 passed / exit 0；`gstore_core` 全量 14 passed
（`09-download-port.txt`、`15-final-tests.txt`）。

### 4.2 迁移（legacy Floor + module DB）

`rust/gstore_core/src/download/legacy.rs`：

- Floor DB：不假定表名，取第一个同时有 `url` 与 `filePath`/`file_path` 列的表；camelCase /
  snake_case 都接受。结果计数：首次 `inserted=1, updated=0, skipped=0`；**重跑 `skipped=1`**
  （幂等，测试 `download_legacy_and_reconcile_floor_and_module_db`）。
- Module DB：要求 `download_task` 表（`download_segment` 可选），module id → `module_task_id`，
  segments 折叠为 `segments_json`；已存在 core 行只补缺失字段。结果：`updated=1`，重跑
  `skipped=1`，**core 的非空元数据不被覆盖**（same test）。
- 缺表/缺库 → `PortError::Db`（`download_legacy_and_reconcile_absent_table_is_db_error`）。

证据：`10-download-db.txt`（4 passed / exit 0）。

### 4.3 缺模块 DB → `needs_restart`

- `with_module_db_path(path)` 记录模块 DB 位置；文件缺失时 `reconcile()` 不询问模块，直接把
  所有非终态行标为 `needs_restart`，返回 `ReconcileReport{checked, needs_restart}`。
- 证据：`10-download-recover.txt` 打印
  `missing module db reconcile -> ReconcileReport { checked: 1, needs_restart: ["7"] }`；
  `09-download-error.txt` 打印 `["42"]`；`NEEDS_RESTART = "needs_restart"`。
- 行状态确实落库为 `needs_restart`；`download_task_ddl_has_reconcile_columns` 通过。

### 4.4 本地 HTTP fixture（明确：测试替身）

`download_legacy_and_reconcile_local_http_completes` 用 `TcpListener` 起本机 HTTP 服务，测试
内 `HttpBridge` 实现 `ModuleBridge` 并完成真实 GET/写文件。**这是测试替身**：生产字节传输
仍在 `gstore_mod_download`，core 的 DownloadPort 不负责传输。证据：`10-download-db.txt`；
源码注释 `rust/gstore_core/src/download/port.rs` 的 `This test double performs the real HTTP GET
only to prove the port completes a local transfer end-to-end.`

### 4.5 序列化注意事项（主计划必须收敛）

`start_payload` 对每个字段同时发 snake_case 与 camelCase（`app_id`/`appId`、`dedup_key`/`dedupKey`、
`file_path`/`filePath` …），源码注释写明：`gstore_mod_download` 用 camelCase 反序列化，而 core
契约用 snake_case，故双发。spike 测试同时断言两种拼写（`FakeBridge` 断言 `dedup_key`/`file_path`）。
主计划应只保留真实模块的 camelCase（或给模块加 `alias`），不能长期双发（§9-8）。

---

## 5. Parity

命令与结果：

```bash
bash scripts/qa/parity.sh
# exit 0
# parity OK: getAllApps=3 searchApps=2 getAppInfoMissing=None
```

- `12-parity.txt`：Rust `gstore_core_parity` 与 Dart `dump_dart_parity_test` 的 JSON 归一化后
  完全一致；正常化器打印 `getAllApps=3 searchApps=2 getAppInfoMissing=None`。
- 注入漂移负向证明：

```bash
bash scripts/qa/parity.sh --inject-field-diff
# injected drift: rust getAllApps[0].name += " (drift)"
# diff ... -"Demo Alpha" / +"Demo Alpha (drift)"
# exit=1
```

证据：`12-parity-fail.txt`（exit 1，非零）。

**范围限制（必须诚实记录）**

1. `searchApps` 只镜像 DAO 的 **LIKE 回退**查询（`WHERE name LIKE '%demo%' OR des LIKE '%demo%'`）；
   **未覆盖 FTS5**（`rust/gstore_core/src/bin/gstore_core_parity.rs` 头注释明确）。
2. 下载 parity 不是字节级 parity，而是**状态映射** parity（status/字段映射）；真实传输在模块内。
3. 本机 Dart 侧无法打开 SQLite：环境缺 `libsqlite3.so`（基线 125 个失败的主因之一，
   `01-flutter-test.txt` 中 85 处 `libsqlite3`）；因此 Dart fixture 走纯 Dart 数据路径，不做真实
   SQLite 查询对比。真实 Dart channel parity 留给主计划（§9-9）。

---

## 6. C ABI

- 头文件由 **cbindgen 0.29.2** 从 `rust/gstore_contract` 生成：
  `scripts/dev/generate_c_header.sh` → `test/c_abi/gstore_platform.h`。
- 漂移检查：重新生成到临时目录，与签入头文件 **byte-identical**（`13-c-abi.txt`）。
- C99 consumer（`test/c_abi/consumer.c`，`-std=c99 -Wall -Wextra -Werror`）编译并运行：

| 项 | 值 |
| --- | --- |
| `sizeof(ByteBuf)` | 16 |
| `sizeof(GStorePlatformError)` | 24 |
| `sizeof(GStorePlatformApiV1)` | 128 |
| `sizeof(GStoreModuleEntry)` | **64** |
| `offsetof(GStorePlatformApiV1, free_buf)` | **120** |
| `offsetof(GStoreModuleEntry, protect_fd)` | **48** |
| `offsetof(GStoreModuleEntry, platform)` | **56** |
| 运行结果 | `abi_version = 4, struct_size = 128, capabilities = 4` |
| 真实 `free_buf` 调用 | `free_buf calls = 1, preserved len = 13` → `consumer_ok` |

- 注入错误偏移：`scripts/dev/check_c_abi.sh --inject-wrong-offset` → 编译期
  `_Static_assert` 失败、`deliberate compile exit code: 1`，脚本 exit 0
  （**错误偏移被拒绝**，`13-c-abi-fail.txt`）。
- 正常检查 `bash scripts/dev/check_c_abi.sh` → exit 0，`c_abi_check_ok`（`15-final-tests.txt`）。

---

## 7. 构建

### 7.1 Android arm64 宿主 `.so`（NDK 26.3.11579264）

实际命令（在 `rust/gstore_host`）：

```bash
CC_aarch64_linux_android=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang \
AR_aarch64_linux_android=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar \
cargo build --release --target aarch64-linux-android \
  --config 'target.aarch64-linux-android.linker=".../aarch64-linux-android33-clang"' \
  --config 'target.aarch64-linux-android.ar=".../llvm-ar"'
```

- **exit 0**，`Finished release profile ... in 21.07s`（`15-ndk-build.txt`）。
  `gstore_host` 现已依赖 `gstore_core` + `rusqlite bundled`，产物包含 core。
- codegen 修复前的首次构建（`15-ndk-build.txt`）产物为 2,146,872 bytes /
  `021f3f43…d191b80`；**修复后按同一命令重建**（bug 修复的权威产物）：
  `rust/gstore_host/target/aarch64-linux-android/release/libgstore_host.so`
  - size **2,175,920 bytes**
  - sha256 **`1b64f3ee4c2a1ff6dc649eafc3d9e0f2b075167d77ac58ec8e631b81c8394f2e`**
- 已覆盖到 `android/app/src/main/jniLibs/arm64-v8a/libgstore_host.so`，复制后 size/hash 相同。
  旧预置产物为 1,023,304 bytes / `cd89412b…5720ec`（重建后体积增大，因合入 core+SQLite）。

### 7.2 Release APK（计划门 G5）— PASSED

**worktree 权威命令与结果（PASSED）**

```bash
flutter build apk --release --target-platform android-arm64
# Running Gradle task 'assembleRelease'...                          233.1s
# ✓ Built build/app/outputs/flutter-apk/app-release.apk (138.0MB)
# BUILD_EXIT=0
```

- 证据：`15-build.txt`（完整输出 tail + exit code + APK/sha/`.so` 明细）。
- APK：`build/app/outputs/flutter-apk/app-release.apk`
  - size **137,989,530 bytes**（138.0MB）
  - sha256 **`814eb8b2228bc83ce56355a93d766bf2c7fd224467ca6e45fa140007687a473b`**
- APK 内 `lib/arm64-v8a/libgstore_host.so` 未压缩大小 **2,175,912 bytes**
  （`unzip -l`）；源 `jniLibs` 产物 2,175,920 bytes，相差 8 字节来自 AGP strip，属预期。

**Pre-fix 失败历史（保留，不删除）**

- 修复 codegen 前，同一命令在 `Target kernel_snapshot_program failed` 处以 **exit 1** 结束
  （47s，无 APK），7 处 `Error` 全部是 FRB 生成物缺函数（`crateBridgeBatteryReadJson`、
  `crateBridgeBatteryPowerInteractive`、`crateBridgeShizukuExec`、`crateBridgeShizukuAvailable`、
  `foregroundReadJson`、`crateBridgeDeviceStateReadJson`、`frameMetricsReadJson`）。
  原始日志保存在 **`15-build-pre-fix.txt`**。
- 修复前另做过一次**诊断副本**构建：worktree `rsync` 到 `/tmp/opencode/gstore-spike-diag`
  （排除 `.git/build/.dart_tool/target`），仅在副本中重生成 FRB 后 APK 构建 exit 0
  （`15-build-diagnostic.txt`，APK 137,973,146 bytes / `de27926b…d04d2`，副本
  `diag-app-release.apk`，打包 `.so` 2,146,864 bytes）。该副本仅作历史证明；
  **权威证据是 worktree 的 `15-build.txt`（exit 0）**。

### 7.3 flags-off 证明

命令与结果（`15-flags-off.txt`）：

```bash
grep -n "static bool coreWrites = false\|static bool download = false" lib/core/core_flags.dart
# 6:  static bool coreWrites = false;
# 7:  static bool download = false;

grep -rn "CoreFlags.coreWrites = true\|CoreFlags.download = true" lib/ || echo "no flag flips in lib/"
# no flag flips in lib/

flutter test test/core_api_test.dart test/core_writes_guard_test.dart test/download_path_parity_test.dart
# 00:00 +16: All tests passed!   TEST_EXIT=0
```

- 16 passed / 0 failed / exit 0。
- gating 点（`grep -rn "CoreFlags\." lib/`）：
  - `lib/core/download/core_download_builder.dart:98-100` → flag off 时 `return null`，
    调用方继续走旧 Dart 路径（关闭时绝不触碰 api）。
  - `lib/core/service/legacy_write_guard.dart:35` → `if (!CoreFlags.coreWrites) return;`
  - `lib/core/core_flags.dart:6-7` 定义默认值 `false`。
- **结论：所有 `CoreFlags` 默认 false；旧 Dart 路径仍权威；spike 未删除任何旧 writer。**

---

## 8. 基线 / 环境

| 项 | 结果 | 证据 |
| --- | --- | --- |
| `dart analyze lib/` | exit 2（语义：有 info）；**0 errors / 95 warnings / 635 infos**（合计 730） | `01-dart-analyze.txt`（730 issues, EXIT 2）；拆分见 `docs/spike/baseline.md`；`14-quality.txt` 复核 findings=730 |
| `flutter test`（基线） | **4381 passed / 2 skipped / 125 failed**，exit 1 | `01-flutter-test.txt`（`+4381 ~2 -125`） |
| 失败根因 1 | 缺 `libsqlite3.so`（`sqflite_common_ffi` DatabaseException；证据中 85 处提及） | `01-flutter-test.txt` |
| 失败根因 2 | 基线时刻缺 `libgstore_host.so`（证据中 283 处提及）；本次已重建 arm64 `.so`，但未重跑全量 `flutter test` | `01-flutter-test.txt`、`15-ndk-build.txt` |
| `gstore_mod_proxy` clippy/test | **ENV-BLOCKED**：bindgen 0.72.1 找不到 `libclang.so` | `04-proxy-env-blocked.txt`、`14-quality.txt` |
| clippy 基线 | 99 findings（`gstore_host` 34、`repo` 19、`download` 16、`analyzer` 13、`qr` 8、`llm` 7、`contract` 1、`perf` 1；proxy 不可用） | `14-quality.txt` |

**判定**：上述失败均为既有环境问题，不由本 spike 引入；`14-quality` 的基线感知门在两次运行中
均 PASS（`14-quality.txt`），说明 spike 没有新增 dart/clippy findings。G5 曾因本分支签入的
codegen 漂移而失败（不属于环境基线），该漂移已在本 worktree 修复并重跑通过（§3.3、§7.2）。

---

## 9. 主计划需要的确切修订（编号）

1. **采用 ABI v4 布局 + 探测符 + `MIN_HOST_ABI`**：冻结 `GSTORE_MODULE_ABI_VERSION=4`、
   `MIN_HOST_ABI=3`、entry 56/64 与 `platform`/`protect_fd` 守卫；把 §2 矩阵四象限写成验收测试，
   并把「探测符缺失 → 回退 3」写成规范（不是实现细节）。
2. **钉死并刷新 v3 fixture**：提交 `rust/test-fixtures/v3/**` 与 sha256
   `bdd4a79f…cbbce`；在 CI 校验 sha；任何重建必须来自 `9ec5132`（ABI=3）且刷新策略需审批。
   同时保留负向断言：fixture 不导出 `gstore_mod_repo_abi`，v4 entry → `-2`。
3. **固化 `CORE_E_*` 错误码**：把 §3.2 列表写成跨语言常量/文档；Dart 只按前缀分类，
   不得解析自由文本；新增 `CORE_E_*` 必须同时更新 Rust/Dart/文档与测试。
4. **定义 `core_writes` 域与 guard 范围**：明确哪些 domain（channel/update/prefs/…）由 core 接管；
   `mark_core_write` 必须在 mutation 之前；guard 在 flag off 时 no-op、flag on 时失败关闭；
   写清回滚/清除 marker 的管理操作（spike 未实现）。
5. **迁移文档 v1 格式 + commit 后删除规则**：固定 `{"version":1,"exported_at",…}` 的
   `channel_env` / `update_prefs` schema；顺序 export → migratePaths → import →
   **每文件成功后删除**；失败保留、重试不重导；`0600` 权限与原子写要进实现规范。
6. **`DownloadPort` / `ModuleBridge` seam**：core **不得**链接模块 cdylib；宿主实现 bridge
   （C ABI/FRB）；`start` 的 core 行 upsert 与模块调用失败时的补偿要明确；`watch_all` 的实时
   事件流必须在主计划实现（spike 只是 snapshot）。
7. **模块 DB 对账（`needs_restart`）**：把 `with_module_db_path` 的语义写成契约：模块 DB 缺失时
   不询问模块，所有非终态行落 `needs_restart`；终态（completed/cancelled/removed）不动；
   `reconcile` 必须幂等并可重复调用。
8. **下载 payload 序列化与真实模块对齐**：spike 的 snake_case+camelCase 双发只是过渡；主计划
   必须选定一种（真实模块目前 camelCase），或给模块字段加 `alias` 并删除重复键；补一条
   「payload 键集合」的契约测试，避免双发长期化。
9. **Parity harness 扩围**：当前只覆盖 LIKE 回退，必须补 FTS5、真实 Dart channel、下载字节
   生命周期（start→progress→complete→file 存在/校验和）；注入漂移必须保持非零退出。
   同时记录本机无法开 SQLite（缺 `libsqlite3.so`）这一环境限制。
10. **C 头文件所有权 / CI 生成**：`test/c_abi/gstore_platform.h` 由 cbindgen 生成、禁止手改；
    CI 必须跑 `scripts/dev/check_c_abi.sh`（漂移 + C99 编译/运行 + `--inject-wrong-offset`）。
11. **基线感知质量门**：把 `dart analyze` 的 exit 2（有 info）与 findings 数、clippy 的既有
    findings、`gstore_mod_proxy` 的 libclang 不可用、`flutter test` 的 `libsqlite3.so`/宿主 `.so`
    依赖写成「环境基线」，避免 CI 把环境缺口当回归；proxy 必须在有 libclang 的镜像里补跑。
12. **CI 增加 Android 宿主 `.so` 重建步骤**：Gradle 不会重建 Rust；CI 必须执行 §7.1 的 NDK
    cross-compile、复制到 `jniLibs/arm64-v8a/`、记录 sha，并在 release APK 内校验该 `.so` 的
    未压缩大小/哈希；同时加 FRB 生成物与 `bridge.rs` 的一致性门（C1）。

---

## 10. 未决问题 / 残余风险

1. **codegen 漂移的复发风险（G5 已通过）**：worktree release APK 已 exit 0（§7.2），但当前仍
   没有 CI 门检查「生成物 ↔ `bridge.rs`」；主计划必须加上该门并固定 codegen config file，
   否则同类漂移会再次让 kernel 编译失败。
2. **双发 payload 的歧义**：若真实模块未来对 snake_case 做严格校验，当前双发可能在未知字段
   策略变化时破裂；契约测试只覆盖了测试替身，未覆盖真实模块反序列化。
3. **下载字节生命周期未做端到端**：本地 HTTP 只证明 port 能完成一次 GET，未覆盖分段、断点续传、
   `.part` 原子改名、校验和失败清理；这些是 cutover 前的必测项。
4. **FTS5 / 真实 Dart channel 未进 parity**：LIKE 回退一致不代表 FTS 查询一致；Dart 侧因缺
   `libsqlite3.so` 无法在本机做真实 SQLite 对比。
5. **`watch_all` 是 snapshot 语义**：UI 若依赖流式进度，主计划必须实现事件流，否则会退化为轮询。
6. **ABI 负向证明绑定 linux x86_64**：entry_size 56/64 的断言是 x86_64 具体值；ARM64 上的
   `GStoreModuleEntry` 大小/对齐需在 Android 设备/CI 上再验一次（本报告只做了 host 侧测试）。
7. **`gstore_mod_proxy` 完全未验证**：clippy/test 均因缺 libclang ENV-BLOCKED；这是既有缺口，
   但会影响「全 crate 绿」的声明。
8. **flags-off 的覆盖面**：3 个 Dart 测试 + grep 证明默认关闭，但没有设备级「打开 flag 后旧路径
   拒绝写入」的真机验证；`LegacyWriteGuard` 目前只在测试 seam 下被验证。
9. **版本/发布**：本 spike 未改 `pubspec.yaml`、未 bump 版本；诊断 APK 仅供构建证据，不可当发布物。

---

## 附录：证据索引（`target/spike-evidence/`）

| 文件 | 内容 |
| --- | --- |
| `15-ndk-build.txt` | NDK arm64 宿主 `.so` 构建，exit 0 |
| `15-build.txt` | **权威** worktree `flutter build apk` **PASSED**（exit 0，含 APK size/sha 与打包 `.so` 大小） |
| `15-build-pre-fix.txt` | 修复 codegen 前的 worktree 构建失败原始日志（G5 pre-fix，exit 1） |
| `15-build-diagnostic.txt` | 诊断副本 codegen + APK 构建（历史证明，exit 0，APK size/sha/`.so` entry） |
| `15-flags-off.txt` | 默认 flag、无翻转、16 个 flag-off 测试、gating 点 |
| `15-final-tests.txt` | 最终回归快照（5 条 cargo + parity + C ABI，全部 exit 0） |
| `02-v3-fixture.txt` | v3 fixture sha256 / ABI=3 |
| `03-abi-layout.txt` | ABI v4 layout、`MIN_HOST_ABI=3`、23 passed |
| `05-handshake.txt` | 四象限矩阵（3 passed） |
| `05-v3-compat-regression.txt` | v3 兼容回归（7 passed） |
| `05-v3-reject.txt` | v3 模块拒绝 v4 entry → `-2` |
| `06-frb.txt` / `06-core-api.txt` / `06-dart.txt` | FRB 暴露面 / codegen / Dart CoreApi |
| `07-core-writes.txt` / `07-old-write-blocked.txt` | marker before mutation / `CORE_E_WRITE_BLOCKED` |
| `08-frb-drift.txt` | 同配置两次 codegen 字节一致 |
| `08-handoff-rust.txt` / `08-handoff-dart.txt` | 顺序 / 删除 / 重试 |
| `09-download-error.txt` / `09-download-port.txt` | port 契约 / `NeedsRestart` |
| `10-download-db.txt` / `10-download-recover.txt` | 迁移计数/幂等 / 缺模块 DB → `needs_restart` |
| `11-download-path*.txt` | 路径 parity / builder / fallback |
| `12-parity.txt` / `12-parity-fail.txt` | clean diff / 注入漂移 exit 1 |
| `13-c-abi.txt` / `13-c-abi-fail.txt` | header drift + C99 consumer / 错误偏移拒绝 |
| `14-quality.txt` | 基线感知质量门 PASS |
| `01-dart-analyze.txt` / `01-flutter-test.txt` | Dart/Flutter 基线 |

最终回归（`15-final-tests.txt`）逐项：

| 命令 | exit | 结果 |
| --- | --- | --- |
| `cargo test --manifest-path rust/gstore_contract/Cargo.toml` | 0 | 23 passed; 0 failed |
| `cargo test --manifest-path rust/gstore_core/Cargo.toml` | 0 | 14 passed; 0 failed |
| `cargo test --manifest-path rust/gstore_host/Cargo.toml core_api_contract` | 0 | 1 passed (74 filtered) |
| `cargo test --manifest-path rust/gstore_host/Cargo.toml abi_handshake` | 0 | 3 passed (72 filtered) |
| `cargo test --manifest-path rust/gstore_host/Cargo.toml abi_v3_compat_tests` | 0 | 7 passed (68 filtered) |
| `bash scripts/qa/parity.sh` | 0 | `getAllApps=3 searchApps=2 getAppInfoMissing=None` |
| `bash scripts/dev/check_c_abi.sh` | 0 | byte-identical header, consumer_ok, `c_abi_check_ok` |
