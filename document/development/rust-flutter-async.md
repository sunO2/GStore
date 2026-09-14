# Rust ⇄ Flutter 异步：诊断、Task 模型与落地记录

> 记录时间：2026-09-13
> 涉及：`rust/gstore_host`（宿主 + FRB 桥）、`rust/gstore_mod_repo`、`lib/core/rust/RustTask.dart`

## 一、诊断：为什么"异步"是槽点

问题不是 FRB 不支持异步，而是**我们把"长任务"当成了"同步调用"**。

代码级证据：

1. **宿主暴露给 Dart 的全是同步 `pub fn`**（`rust/gstore_host/src/bridge.rs` 无一个 `async fn`）。
   FRB 把同步函数放到**任务池线程**执行 → 长调用占用线程整个时长。
2. **模块契约是同步 C ABI**，长任务只能 `block_on`。`gstore_mod_repo/src/lib.rs` 注释即写明：
   「download_repo async 经 `runtime.block_on` 同步返回（C ABI 同步契约）」。
3. **最严重的一处**：`gstore_mod_repo::call` 里
   ```rust
   let inst = inst_arc.lock().unwrap();   // 无差别锁住整个实例
   ...
   "download_repo" => inst.runtime.block_on(...)   // 全程持锁
   ```
   → 下载期间同模块的 `search_apps` / `get_app_count` **全部阻塞**，连读 DB 都不行。
4. 推送方向其实**本来就是成熟的**：FRB `StreamSink`（`logs_stream` / `events_stream`）已在用，
   LLM 的流式 token 也走 `emit_event`。
5. 缺的是**任务生命周期**：取消是"尽力 cancel + 504"，没有 started/progress/done/failed/cancelled
   状态机，Dart 侧也没有 `request_id → Future` 关联层。

## 二、P0：修 repo 实例锁（`rust/gstore_mod_repo/src/lib.rs`）

`RepoManager` 内部**本来就是** `db: Arc<Mutex<Connection>>`（`repo.rs`），
所以外层 `Arc<Mutex<RepoInstance>>` 是多余的，正是它造成"下载时整个模块不可用"。

改法：
- `instances()` 由 `HashMap<u64, Arc<Mutex<RepoInstance>>>` → `HashMap<u64, Arc<RepoInstance>>`
- `call` 只克隆 `Arc`，**不再持有实例级锁**；DB 访问仍由内部 `db: Mutex<Connection>` 保护（短锁）
- 新增 `download_serial: Mutex<()>`：**只串行化下载**（取消标志是实例级的），
  读操作（搜索/计数）不再被下载阻塞

效果：**下载期间仍可搜索/计数**（可真机验证）。

## 三、P1：Task 模型（宿主 + Dart）

### 心智模型

不是"每个任务一条长连接"，而是 **HTTP/2 或 SSE 的多路复用**：

| 网络概念 | 本设计 |
|---|---|
| 连接 | 一条 FRB 事件流（进程内 FFI，不会"断线"） |
| 发起请求 | `start_task` —— **本地同步调用，无握手** |
| stream id | `task_id` |
| 响应分块 | `kind: started/progress/chunk/done/error/cancelled` + `seq` |
| RST_STREAM | `cancel_task`（**协作式**） |
| keepalive | 不需要（不会断）；但需要 **task 上限 + TTL** |
| 客户端解复用 | Dart 侧按 `task_id` 消费各自的 `Stream<TaskEvent>` |

### 关键设计决定

1. **`start_task` 与 `watch_task` 分离**（而不是一个带 `StreamSink` 的函数）：
   FRB 中带 `StreamSink` 参数的函数**返回值必须是 unit**，拿不到 `task_id`；
   分开后 `start` 同步返回 id，`watch` 再订阅，**取消无需等首个事件**。
2. **未订阅先缓冲**：事件在无订阅者时进有界 `VecDeque`（丢最旧），`watch` 时先补发再转实时。
   与既有 `event_bridge` 的日志缓冲同构。
3. **`Arc<TaskSlot>` + 独立 sink 互斥锁**：发事件时「先克隆 Arc、释放注册表锁、再 `add`」，
   **不在持注册表锁时跨 FFI**（避免 Dart 监听器回调任务 API 造成死锁）。
4. **任务归属靠线程本地上下文**：`start_task` 在该执行线程设置 `CURRENT_TASK`，
   宿主 `host_emit_event` **优先**把事件归到当前任务；无任务上下文时仍走旧的广播总线。
   → **模块零改动**即可让 `emit_event` 的进度进入任务流。
5. **结束靠 drop 而非 `close()`**：FRB `StreamSink`（Rust2Dart codec）无 `close`，
   从注册表移除槽位即释放最后一个 sink 引用 → Dart 侧流自然结束。
6. **协作式取消、无抢占**：Rust 不能中断正在跑的紧循环，取消只在模块的**检查点**生效
   （repo 的下载已经是这种实现）。

### 线程与重入规则（必须遵守）

- 模块回调（`emit_event` / `on_event`）**不得持锁**、**不得同步等待 Dart**
- 宿主分发事件前先快照 `(id, Arc)` 再释放注册表锁（既有 `on_event` 就是这么做）
- 长任务一律走 Task，**不在 FRB 池里 `block_on`**

## 四、改造后的用法

```dart
// 启动长任务：立即拿到句柄
final task = await FdroidRustRepoManager.downloadRepositoryTask(repoUrl: url);

// 真实阶段进度（不再是硬编码 0.5）
task.progress.listen((p) {
  final phase = p.json?['phase'];            // downloading / stored
});

// 完成（done / error / cancelled 三态，不会悬挂）
final result = await task.completion;
if (!result.isOk) { /* result.error / result.errorCode */ }

// 协作式取消
await task.cancel();
```

模块侧上报进度只需 `emit_event(instance_id, "progress", br#"{"phase":"..."}"#)`，
**不需要感知任务的存在**。

## 五、踩坑记录

1. **FRB 重新生成会改入口类名**：`--dart-entrypoint-class-name` 一旦改动，
   生成类从 `RustLib` 变成别的名字，整个 Dart 侧编译失败。**默认名就是 `RustLib`，不要动**。
2. **`InstanceHandle` 字段与方法同名冲突**：`#[frb(opaque)]` 下 `pub module_id/instance_id`
   字段仍会生成 getter，与手写的 `instance_id()` 冲突（`instanceId` 重复声明）。
   把字段改为 `pub(crate)` 即可。
3. **repo 模块重编需要 `CC_*/CXX_*/AR_*`**：repo 含 C 代码（ring / libsqlite3-sys），
   cc-rs 为每个 target 找编译器，而 NDK 只提供带 API 后缀的 clang
   （`x86_64-linux-android33-clang`），故需显式导出 `CC_x86_64_linux_android` 等。
   见 `build_repo_all.sh`。
4. **`dart analyze` 在本机不可靠**（会静默失败或挂起），验证以 `flutter test` 编译为准。

## 六、验证

- 宿主：`cargo test` 23 项通过（含任务生命周期 3 项：start→watch→done 载荷透传、cancel 终态、缓冲补发）
- Dart：`test/rust_task_test.dart` 7 项通过（done/chunk 流式/error 错误码/cancelled/乱序丢弃/流意外关闭兜底/完成后事件不影响结果）
- 模块：`cargo test` 3 项通过
- 端到端：repo 下载走 Task，阶段进度真实上报

## 七、后续（P2）

- 把 DB / 网络能力做成 HostServices 槽位时，**挂在 Task 模型下**（"一个任务 + 完成事件"），
  不需要发明新的同步回调语义
- 任务量级上升后可从「每任务一条流」演进到「单一事件流 + Dart 侧解复用」（形态 B），
  两者共用同一套事件 schema，迁移成本低
- 背压：高频 chunk 需合并发送（如 50ms 批量），避免淹没 Dart 事件队列

---

## 八、P2：宿主能力（DB / 网络）——结论与取舍

### 结论：**能力槽不做，只做零 ABI 变更的地基**

三条理由（都有实证）：

1. **今天没有任何模块需要宿主提供 DB/网络**。`repo` 自带 `rusqlite(bundled)` + `reqwest/rustls`
   并自己开 SQLite；`analyzer` / `qr` 不需要；`llm` 自带模型文件管理。做出来是**无人使用的能力**。
2. **加槽位必须递增 ABI，而当前模块侧是严格相等校验**
   （`if e.abi_version != GSTORE_MODULE_ABI_VERSION { return Err(ABI_ERR_ABI_MISMATCH) }`）。
   ABI 升到 v3 会让**所有既有模块注册失败**，包括用户机上**已经下载好的 .so** →
   必须全量重编 + 强制重新分发。代价远大于收益。
3. **体积方向是反的**：`libgstore_host.so` 内置在 APK 里（818 KB），塞进 host 等于
   **所有用户无条件**多付 ~2–3 MB；而「模块自带」已有生产先例（repo 3.75 MB 是实测参照）。

### 将来真需要时的更优路线：**走已有 v2 通道做请求/响应**（零 ABI 变更）

模块 `emit_event` 发 `capability.request` → 宿主**以 Task 执行** → 结果经 `on_event` 回送。
复用 Task 模型即是：
- 天然异步、可取消、带进度（不需要发明同步回调语义，也避开重入死锁）
- 不需要新槽位、不需要升 ABI
- 前提是先把模块侧的 ABI 校验从「严格相等」改成 `host_abi >= module_abi`（仅当真的要升 ABI 时才做）

### 本次实际落地：`ModuleContext`（零 ABI 变更的地基）

`rust/gstore_contract/src/context.rs` + `lib/core/rust/ModuleContext.dart`

- 标准上下文：`data_dir` / `cache_dir` / `db_path` / `abi` / `app_version` / `extras`
- 通道复用既有 `create(config)` 字节流 → **不动注入表、不升 ABI**
- **向后兼容**：非 JSON 字节按历史约定视为裸 DB 路径，旧调用方行为不变
- DB 路径优先级：显式 `db_path` > `data_dir/<name>` > `:memory:`
- `repo` 已消费；Dart 侧按模块名分配 `<docs>/gstore_mods/<name>` 作为数据目录

**验证**：契约 16 项（新增 6：JSON 解析/裸路径回退/空输入/路径优先级/编码往返/部分字段容忍）、
repo 3 项、Dart `test/module_context_test.dart` 4 项，全量 `flutter test` **1562 全过**；
APK 内已确认 repo `.so` 含 `data_dir`/`db_path` 解析、Dart 含 `ModuleContext`。

---

## 九、把上下文约定推广到全部模块（qr / analyzer / repo）

### 问题

`qr` 与 `analyzer` 的 `create_impl` 之前是**空配置**创建（`instances().insert(id, ())`），
`analyzer` 甚至直接 `let _ = (config, config_len)` 忽略入参；`repo` 虽通过 config 拿 DB 路径，
但走的是「裸路径」私有约定 —— **每个模块一套隐式约定**。

### 改动

**Rust（qr / analyzer）**
- 实例表由 `HashMap<u64, ()>` 改为 `HashMap<u64, ModuleContext>`：上下文**存入实例**，
  供后续能力（数据目录/缓存）直接取用
- `create_impl` 用 `ModuleContext::parse` 解析（非 JSON 自动回退裸路径）
- create 日志输出 `data_dir / cache_dir / abi` → **路径与 ABI 问题可直接从日志定位**
- 各补 2 个测试：JSON 上下文被解析并落入实例、无配置时用默认上下文

**Dart（统一入口）**
- 新增 `RustModuleInstance.createWithContext(moduleName, module, {dbPath})`：
  统一构造并注入标准上下文
- **三处调用点全部改走它**（analyzer / qr / repo），后续新模块一律用它 → 不会再出现各自的隐式约定
- repo 显式 `db_path` 保持不变（数据库路径不迁移）

### 验证

| 范围 | 结果 |
|---|---|
| `gstore_mod_qr` | 5 通过（新增 2） |
| `gstore_mod_analyzer` | 74 通过（新增 2，为其新建了 lib 级测试模块） |
| `gstore_mod_repo` | 3 通过 |
| `gstore_contract` | 16 通过 |
| 全量 `flutter test` | 通过 |
| APK 内确认 | qr / analyzer / repo 三个 `.so` 均含 `data_dir`/`cache_dir`/`ModuleContext`；Dart 含 `createWithContext` |

**收益**：上下文通道对**全部模块**统一；模块能拿到宿主分配的 `data_dir`/`cache_dir`/`abi`，
未来需要持久化或缓存时不再各自猜路径；且**零 ABI 变更**（不需要升 ABI、不需要重编既有模块以兼容旧 ABI）。
