# 下载内核（Rust 模块 `gstore_mod_download`）

## 1. 背景与目标

现有下载栈全在 Dart：`DownloadManager` + `dio` 引擎 + Floor 任务库 + 策略层 + 通知服务，
面板见 `lib/page/download/`。

在排查「下载任务没有防重复」时，确认缺口属于**逻辑层**（不是线程/语言能力），
但也确立了长期方向：把**传输与任务管理**收敛到一个原生内核，并用它承载更细的传输细节。

本模块就是该内核，目标：

- 任务管理、任务查询、进度回调三者由 Rust 统一承载；
- **面板不改**——通过 `IDownloadService` 与模型映射接入；
- 达到工业级下载器的必备能力，而非演示级实现。

## 2. 架构与边界

```
Flutter(Dart) ──FRB──► gstore_host ──C ABI(gstore_contract v2)──► gstore_mod_download
                                                                        │
   Dart 侧按 taskId 解复用 ◄── emit_event(广播总线) ◄── 内核 emit_event ──┘
```

- **零 ABI 变更**：只用 `create(ModuleContext)` + `call` + `emit_event` + `on_event`，
  未新增能力槽（ABI 是严格相等校验，加槽会让用户机上已下载模块全部注册失败）。
- **DB 路径来自 `ModuleContext`**（`data_dir/db_path`），模块自带 SQLite，不依赖宿主。
- **不进 APK**：作为可下载模块随 `rust/release-modules` 分发
  （repo 模块实测 3.75 MB，本模块同量级）。
- **事件走广播总线**：内核自带调度器，任务不是由宿主 `start_task` 拉起的，
  因此 `emit_event` 落在广播总线上、载荷带 `taskId`，Dart 侧解复用为每任务流。
  这正是 `rust-flutter-async.md` §七 预判的「形态 B」，未新造机制。
- **通知 / 前台保活仍在 Dart/Android 侧**：模块是按需加载的 `.so`，无法拥有前台服务。

## 3. 判重设计（核心决定）

### 3.1 id 与判重键分离

| | 是什么 | 谁定 |
|---|---|---|
| `id` | **代理键**：DB 自增，稳定、不透明、与业务无关 | Rust（模块）|
| `dedup_key` | **逻辑唯一键**：「什么算同一个下载」 | 调用方指定，或按规则派生 |
| `conflict` | 撞键策略：`keep` / `replace` / `append` | 调用方 |

对齐 Android **WorkManager** 的范式：`enqueueUniqueWork(name, ExistingWorkPolicy, …)`
——框架管 id，调用方管语义。

### 3.2 键里**不放**哪些字段（都有具体代价）

- **不放 `app_name`**：它是展示元数据且**随语言变化**（汉化后同一个包在中文/英文下名字不同）
  → 会被算成两个下载。
- **不放 `url`**：URL 是**来源**不是身份；国内要走镜像，切镜像会给同一个
  `包名+版本` 算出不同键 → 重复下载。

### 3.3 派生优先级

1. 调用方显式 `dedupKey`（只有调用方知道「什么算同一个」）
2. `kind:resourceId[:resourceVersion]` → `app:com.x:1.2.3`、`model:qwen2-0.5b-q4`
3. 兜底：`url:<sha256(规范化URL + 目标路径)>`

URL 规范化：去 `#fragment`、scheme/host 小写、去尾斜杠；**刻意保留 query**
（同路径带不同 query 往往是不同产物）。

### 3.4 通用资源（不只下载应用）

`resource` 是通用描述符，`kind` 表示资源类型；应用只是其中一种：

```json
{ "kind": "app",   "resourceId": "com.x", "resourceVersion": "1.2.3" }
{ "kind": "model", "resourceId": "qwen2-0.5b-q4" }
{ "kind": "asset", "resourceId": "fonts/Noto.ttf" }
```

### 3.5 正确性兜底：落盘路径

两件事被刻意分开：

- **语义**（要不要复用）→ `dedup_key`
- **正确性**（能不能同时写）→ `file_path`

```sql
CREATE UNIQUE INDEX ux_download_task_dedup       ON download_task(dedup_key);
CREATE UNIQUE INDEX ux_download_task_active_dest ON download_task(file_path)
    WHERE status IN (0, 1, 2);            -- 只约束活动态，保留历史行
```

同一落盘路径**不允许两个活动任务**——两个 writer 必然互相破坏。
前一个进入终态后同一路径可再下（升级覆盖），历史行保留。

> 实现顺序上有个坑：路径检查必须放在**判重查找之后**并排除自身，
> 否则「准备复用的那条任务」会被当成冲突对象，防重复直接失效。测试已覆盖。

## 4. 工业级能力清单

| 能力 | 实现要点 |
|---|---|
| 多连接分段 | `Range: bytes=0-0` 探测 206 + 解析 `Content-Range`；分段严格覆盖 `[0,total)` 无重叠无缺口，余数归末段；单段下限 1 MiB |
| 断点续传 | 每段独立 `.part{i}`，按已落盘偏移续传；已落盘 > 段长判脏整段重下 |
| 服务端变更检测 | ETag / Last-Modified / 长度任一漂移 → 中止并**清理旧段**（否则拼接出损坏文件）|
| 暂停/恢复/取消 | 检查点协作式取消；暂停**保留分段**，恢复即续传 |
| 并发队列 + 上限 | 活动数真源是 DB（`status IN (1,2)` 计数），避免内存计数器漂移 |
| 优先级 | `priority DESC, id ASC`（同优先级 FIFO，防饿死）|
| 防重复任务 | 同键处于活动态 → 复用，不起第二个 run |
| 重试退避 | 指数退避 300ms→19.2s + **按段号抖动**（避免同时重试打爆服务端）|
| 失败分类 | HTTP 状态码 / 超时 / 连接 / DNS / TLS / 磁盘 / 校验 / 取消 / 服务端变更，带 `is_retryable` |
| 限速 | 令牌桶（全局 + 单任务）|
| 速度/ETA | 3 秒滚动窗口首尾差算平均速率（分段并发下瞬时值会乱跳）|
| 磁盘预检 | `statvfs` + 16 MiB 余量 |
| 原子落盘 | 合并到临时文件 → `rename`；校验失败**删除临时文件**，不留半成品 |
| 进度节流 | 200ms ticker，非每 chunk 跨 FFI（背压要求）；分段快照仅在变化时下发 |
| 崩溃恢复 | 重启后在途任务降级为**暂停 + 注明原因**，不静默续跑 |
| 任务持久化/查询 | SQLite，schema v2（含判重键与落盘路径索引）|
| 排队原因 | 落库 `queue_reason`，面板可展示「为什么还没开始」|

## 5. 面板接入

面板读 Dart 模型，模块真源在自己库里，二者之间只有**一个翻译点**：
`lib/core/download/rust/rust_download_mapper.dart`。

契约要点（改这里等于改契约）：

- `status` 是 **Dart 枚举索引**（Rust `TaskStatus` 判别值与之逐一对齐），错位会让状态张冠李戴；
- 时间戳是**毫秒**；
- 越界状态索引**直接抛错**，不静默给出错乱状态。

## 6. 构建与分发

```bash
./build_android_rust.sh --module-download   # 只构建本模块
./build_android_rust.sh --module <crate>    # 通用形式
./build_android_rust.sh                     # 全量（已把本模块加入 MODULES）
```

产物进 `rust/release-modules/<abi>/`，**不进 APK**。

## 7. 验证记录

**Rust 侧（`cargo test`）：49 个用例全过，0 警告。**

覆盖：分段规划、续传、服务端变更清理、取消、退避抖动、限速、校验、原子落盘、
磁盘预检、崩溃恢复、判重（换镜像不重复 / 展示名不进键 / 路径冲突拒绝 /
replace / append / 通用资源）、schema v1→v2 迁移。

开发过程中被测试抓出并修掉的**真 bug**：

1. `cleanup_parts(...)` **漏 `.await`** → 清理是空操作 → 旧段残留会拼接出损坏文件；
2. 段任务返回 `Err(Cancelled)` 被归到 `Failed` → 用户点暂停会看到「失败」；
3. 路径冲突检查顺序错误 → 防重复失效（见 §3.5 注）。

**Dart 侧**：`test/rust_download_mapper_test.dart` 9 个用例全过（契约锁定）。

## 8. 已知限制 / 未闭环

- **面板已接线，默认仍走 Dart**：`app_modules.dart` 的 `DownloadModule.onRegister`
  改为经 `DownloadCoreConfig.resolve()` 选择实现——默认 `dart`（既有行为），
  用 `--dart-define=DOWNLOAD_CORE_RUST=true`（或运行时配置 `download.core=rust`）切到内核。
  内核不可用（未内置/未下载/ABI 不匹配）时**回落 Dart 并告警**，不会让下载整体不可用。
- **真机端到端未验证**：见 §10 的验证清单。
- **`installAfterDownload` 不由内核负责**：APK 安装仍在 Dart 侧流程；
  适配层遇到该参数会记录日志说明，**不假装已支持**。
- **与现有任务库尚未合并**：Dart 侧 Floor `download_task.db` 仍是面板真源；
  「谁是真源」的迁移（P1 的收敛目标）未开始。
- 速度/ETA 已由内核计算并随进度事件下发；面板若要画速度曲线需新增采样序列。

## 9. 落地过程中修掉的环境/脚本问题（都非本模块逻辑）

1. **模块缺 `.cargo/config.toml`** → `ring` 的 build script 找不到 NDK `ar`/`linker`，
   四个 ABI 全部编译失败。已对齐 `gstore_mod_repo` 的配置（含 16KB 页对齐 rustflags）。
   **产物：aarch64 4.0M / x86_64 4.4M / armeabi-v7a 2.7M / x86 4.3M。**
2. **`build_android_rust.sh` 的快速路径不可达**：`--module-qr` 等分支写在脚本末尾的
   `exit` 之后，**永远执行不到**，所以传 `--module-*` 实际会跑全量构建。已把这些分支
   移到主流程之前。
3. **汇总报"假成功"**：模块编译失败不计数，末尾仍打印
   `✓ All architectures built successfully!`。已加 `MODULE_FAILED` 并与宿主 `FAILED` 一并判定。
4. **体积上报错值**：用 `du -h` 曾报出 `1.0K`（实际 4.0M）。已改用 `ls -lh`。

> 说明：宿主侧 `rust/gstore_host/src/dl_adapter.rs` 是**动态加载（dlopen）适配器**
> （`DlModuleAdapter`），与"下载适配"无关，不存在重复实现问题。


## 10. 真机验证（A 方案：临时内置）

### 当前状态
模块 `.so` 已按 A 方案临时拷入 `android/app/src/main/jniLibs/<abi>/`（与既有
analyzer/qr/repo 模块的做法一致），因此**会进 APK**；已构建验证包：

```bash
flutter build apk --release --target-platform android-arm64 \
  --dart-define=DOWNLOAD_CORE_RUST=true
```

> ⚠️ **发布前必须移除** `jniLibs/*/libgstore_mod_download.so`，或至少不要带
> `DOWNLOAD_CORE_RUST=true` 构建。否则模块会随包分发，违背"重模块不进默认包"的约定。

### 验证清单（需在真机执行）
1. **模块加载**：日志出现「命中内置模块 …libgstore_mod_download.so」
2. **ABI 注册**：注册成功（严格相等校验，不匹配报 ABI_ERR）
3. **分段下载**：任务目录出现 `xxx.apk.part0/.part1`；完成后 `.part*` 消失、最终文件出现
4. **进度上屏**：进度条走动（验证 `moduleEvents` → `taskId` 解复用回路）
5. **暂停/续传**：暂停后 `.part{i}` **不被删除**；恢复从已落盘偏移继续（不是从 0）
6. **杀进程重启**：在途任务变「已暂停 + 原因」，不静默续跑
7. **取消 / 重试**
8. **并发上限**：同时开 4 个以上，第 4 个显示「等待并发额度」
9. **防重复**：同一应用同版本连点两次 → 只有一条任务、不重复下载
10. **完整性**：损坏的下载会失败，而不是留下"看起来完整"的文件

### 一次值得记的教训：`dart analyze` 报 clean 但编译失败
`rust_download_service.dart` 里我漏改一处（算了 `dest` 局部变量却仍传 `request.savePath`），
**`dart analyze` 报 clean，`flutter build apk` 的 AOT 编译才报出来**。
本机分析器有过挂起/超时史（内存紧张），状态可能是脏的——
**结论：本仓库的改动能以 `flutter build` 通过为准，不能只信 `dart analyze`。**
