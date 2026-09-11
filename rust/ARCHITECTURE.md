# GStore Rust 模块化架构设计

> 状态：**讨论定稿（设计阶段，未实施）** · 适用范围：`rust/` 下所有 Rust 代码及 `lib/core/rust/` FFI 层
> 相关代码：`rust/fdroid_repo/`（当前单 crate）· 桥接：flutter_rust_bridge 2.11.1（配置在根 `pubspec.yaml`）

---

## 1. 背景与目标

### 1.1 现状

- 单个 crate `fdroid_repo`，产出一个 `libfdroid_repo.so`（jniLibs 4 个 ABI）
- 已有 6 个功能域，内部已按模块分文件，但**桥接层是单点咽喉**：全部挂在 `bridge.rs` 的 `FdroidRepoManager` opaque 上（仓库管理 + APK/DEX/components/ELF 五个方法），另有独立 `QrDecoder`
- 桥接配置：根 `pubspec.yaml` 的 `flutter_rust_bridge:` 段（`rust_input: fdroid_repo::bridge`）

| 域 | 源文件 | 有无状态 | 使用频率 | 依赖特征 |
|---|---|---|---|---|
| F-Droid 仓库下载/解析/搜索 | `repo.rs` | **有**（SQLite） | 高频（主功能） | reqwest + rusqlite + tokio（async） |
| APK 元数据提取 | `apk.rs` | 无 | 低频 | zip + apk-info-axml |
| Manifest 组件枚举 | `components.rs` | 无 | 低频 | quick-xml |
| DEX 类扫描 | `dex_scan.rs` | 无 | 低频 | 纯解析 |
| ELF 16KB 页对齐扫描 | `elf.rs` | 无 | 低频 | 纯解析 |
| 二维码解码 | `qr_decode.rs` | 无 | 低频（工具） | zxing-cpp（bundled C++，体积大头） |

### 1.2 目标

1. **按需下载 / 裁剪体积**：低频可选功能（qr / analyzer）不进 APK，首次使用时下载 .so 并动态挂载
2. **模块化扩展**：未来新功能按"模块"加入，不膨胀上帝对象，不动已有代码
3. **统一契约**：所有 Rust↔Flutter 交互走统一数据模型（信封 + 状态码 + 错误码），错误规则单点定义
4. **生命周期管理**：多实例的创建/释放由代理对象内部维护，外部调用不携带任何 id

### 1.3 设计原则

| 原则 | 内容 |
|---|---|
| 有状态 → opaque | 只有仓库域（SQLite）需要；新域按此判断 |
| 无状态 → 自由函数/静态调用 | 新功能默认纯函数，不预设 opaque |
| 模块契约 → C ABI | 跨 .so 只用 `#[repr(C)]` 结构体 + 函数指针，不传 trait 对象/裸指针 |
| 分配器纪律 | 跨边界内存"谁分配谁释放"，绝不交叉 free |
| 永不 dlclose | 模块 mount-once，仅进程退出时随进程回收 |
| 单一调度点 | Dart 只经宿主 FRB 调用，绝不直接 dlopen 模块 |

---

## 2. 总体架构

```
┌─ Dart 层 ─────────────────────────────────────────────────┐
│  调用方（语义化，类型安全）                                 │
│  QrDecoder.decodeLuma(...) / AnalyzerApi.scanDex(...)      │
│        ↓ 内部                                              │
│  Dart 薄封装（protobuf 生成类 encode/decode + 统一路由）     │
│  统一异常 GStoreException + 全局错误处理/日志               │
│  日志查看器（LogManager ← 订阅 Rust 日志 Stream，见 6.8）    │
└──────────────┬─────────────────────────────────────────────┘
               │ FRB（唯一桥面，少量 opaque 方法；含 logs_stream）
┌──────────────▼─────────────────────────────────────────────┐
│ 宿主 libgstore_host.so（常驻，编译进 APK）                   │
│  ┌─ FRB 层：loadModule / createInstance / call / dispose ─┐ │
│  ├─ ModuleManager（注册表 + 路由 + 句柄/refcount 管理）     │ │
│  ├─ LogBridge（Rust 日志/事件 → FRB Stream → LogManager）   │ │
│  ├─ 契约层：Envelope 解析/编码 + 版本/ABI 校验 + 签名验证    │ │
│  └─ HostServices：log / alloc-free / emit-event（注入模块） │ │
└──────────────┬─────────────────────────────────────────────┘
               │ dlopen + C ABI 握手（gstore_mod_<domain>_* 符号）
┌──────────────▼─────────────────────────────────────────────┐
│ 模块层（纯 Rust cdylib，无 FRB）                            │
│  常驻：repo（编译进 APK，预注册 preload）                    │
│  按需：libgstore_mod_qr.so / libgstore_mod_analyzer.so      │
│  （单 .so 过渡 = 宿主内 crate，同一 trait，Dart API 不变）   │
└─────────────────────────────────────────────────────────────┘
```

**关键决策：全部域统一走路由**——**包括 repo 在内**，所有功能域都是模块形态，统一走 `ModuleHandle`/`InstanceHandle` + 信封协议。repo 是唯一的"常驻模块"（编译进 APK，`preload: true` 预注册，不走按需下载）。FRB 桥面收窄为一套通用路由，Dart 侧只有一种调用模式；代价是现有 repo 强类型接口（`FdroidRustRepoManager`）需迁移为信封调用（见附录 B 迁移清单）。

---

## 3. 模块契约（C ABI，多 .so 场景）

### 3.1 握手协议

模块 .so 独立编译，不知道宿主注册表在哪，注册是一次**双向握手**：

```
宿主                                      模块 .so
 │ 1. dlopen(path) + dlsym("gstore_mod_<name>_register")
 ├─────────────────────────────────────────►
 │ 2. 传 GStoreModuleEntry（宿主服务：log/alloc/event回调/版本）
 ├─────────────────────────────────────────►
 │ 3. 模块校验 ABI → 保存宿主服务 → 填充 GStoreModuleApi（自身能力）
 │ ◄────────────────────────────────────────
 │ 4. 宿主包装成 DlModuleAdapter → 插入注册表 → 分配 module_id
```

### 3.2 契约定义（公共 crate `gstore_contract`，宿主与所有模块共享）

```rust
// gstore_contract/src/abi.rs —— 只有 #[repr(C)] 结构体 + 函数指针类型

/// 模块 ABI 版本：任何一端的结构体布局变更都必须 +1
pub const GSTORE_MODULE_ABI_VERSION: u32 = 1;

/// 宿主 → 模块：宿主服务的注入表
#[repr(C)]
pub struct GStoreModuleEntry {
    pub abi_version: u32,
    pub entry_size: u32,                     // 向前兼容：模块用 size 判断宿主支持到哪一版
    pub log: Option<extern "C" fn(level: i32, msg: *const c_char)>, // 日志回调（详见 6.8）；模块 log! 经此汇入 Flutter 日志查看器
    pub alloc: Option<extern "C" fn(size: usize) -> *mut c_void>,   // 宿主分配器（请求内存用）
    pub free: Option<extern "C" fn(ptr: *mut c_void)>,
    pub emit_event: Option<extern "C" fn(module_id: u64, instance_id: u64,
                                         data: *const u8, len: usize)>,  // 事件通道（与日志共用宿主→Dart 管道，见 6.8）
    pub context: *mut c_void,                // 宿主上下文（回调时原样传回）
}

/// 模块 → 宿主：模块导出的能力表
#[repr(C)]
pub struct GStoreModuleApi {
    pub name: *const c_char,                 // "qr" —— 模块自己报名字，宿主不猜
    pub version: u32,                        // 模块功能版本
    pub min_host_abi: u32,                   // 要求宿主的最低 ABI 版本
    pub init: Option<extern "C" fn() -> i32>,
    pub create: Option<extern "C" fn(config: *const u8, config_len: usize,
                                     out_instance: *mut u64) -> i32>,
    pub call: Option<extern "C" fn(instance: u64, method: *const c_char,
                                   payload: *const u8, payload_len: usize,
                                   out_data: *mut *mut u8, out_len: *mut usize) -> i32>,
    pub destroy: Option<extern "C" fn(instance: u64) -> i32>,
    pub cancel: Option<extern "C" fn(instance: u64, request_id: *const c_char) -> i32>, // 取消 in-flight 调用
    pub shutdown: Option<extern "C" fn() -> i32>,
    pub alloc: Option<extern "C" fn(size: usize) -> *mut c_void>,   // 模块分配器（响应内存用）
    pub free: Option<extern "C" fn(ptr: *mut c_void)>,
}
```

### 3.3 内存规则（谁分配谁释放，绝不交叉 free）

- **请求内存**：宿主 `Vec<u8>` 直接传 ptr+len，模块**只读**，宿主自己释放
- **响应内存**：模块用自己的 `alloc` 分配并写 `out_data`，宿主**立即拷贝**进自己的 `Vec<u8>` 后调**模块的 `free`** 释放
- 禁止跨边界传递任何 Rust 集合（`Vec`/`Box`/`String`）的裸指针

### 3.4 符号命名（防符号内插）

- 模块导出符号一律 `gstore_mod_<domain>_` 前缀（如 `gstore_mod_qr_register`）
- 模块内部不导出其他 `#[no_mangle]` 符号（Rust 默认 `-fvisibility=hidden`，内部符号不泄漏）
- 宿主服务**按值注入**（Entry 结构体传函数指针），绝不 dlsym 宿主符号——避免与 Flutter engine / 其他模块的符号互相解析

### 3.5 panic 策略（关键）

- 模块 crate profile **必须** `panic = "unwind"`（覆盖宿主当前 `panic = "abort"`）
- 每个 `extern "C"` 入口（register / call / destroy…）整体包 `catch_unwind(AssertUnwindSafe(...))`，panic 转错误码返回
- Rust ≥1.81：panic 若穿过 `extern "C"` 边界会直接 abort 进程——所以 catch 必须在模块内部、边界之前
- 宿主保持 `panic = "abort"`（混合策略跨 .so 安全，因为 panic 从不越过边界）

### 3.6 模块 crate 形态

```toml
[lib]
crate-type = ["cdylib"]        # 仅 cdylib；无 FRB、无 Flutter 依赖，纯 Rust + libc

[profile.release]
panic = "unwind"               # 必须覆盖宿主的 abort
opt-level = "z"
lto = true
codegen-units = 1
strip = true                   # 保留 dynsym + unwind 表（readelf 验证）
```

---

## 4. 宿主模块管理（ModuleManager）

### 4.1 注册表结构

```rust
pub struct ModuleManager {
    modules: RwLock<HashMap<u64, ModuleEntry>>,
    next_module_id: AtomicU64,
}

pub struct ModuleEntry {
    pub name: String,                       // "qr" / "analyzer"
    pub module: Arc<dyn GStoreModule>,      // 单 .so 直接 trait；多 .so 是 DlModuleAdapter
    pub refcount: AtomicUsize,              // 当前 Dart 侧持有的 ModuleHandle 数
    pub version: u32,
}
```

`DlModuleAdapter` 实现 `GStoreModule` trait，每个方法转发到 api 表的函数指针（响应内存拷贝 + 用模块 free 释放）。**持有 `libloading::Library` 句柄，保持 .so 驻留**。

### 4.2 模块 trait（Rust 内部统一接口）

```rust
pub trait GStoreModule: Send + Sync {
    fn name(&self) -> &'static str;
    /// 创建实例，返回模块内部管理的句柄（u64 id，不跨边界传裸指针）
    fn create(&self, config: &[u8]) -> Result<u64, ModuleError>;
    /// 静态调用（instance == None）或多实例调用（instance == Some(id)）
    fn call(&self, instance: Option<u64>, method: &str, payload: &[u8])
        -> Result<Vec<u8>, ModuleError>;
    fn destroy(&self, instance: u64) -> Result<(), ModuleError>;
    fn shutdown(&self) {}
}
```

### 4.3 加载流程

```rust
fn load_module(&self, name: &str) -> Result<u64, String> {
    // 0. 幂等：同名模块已注册 → refcount+1，直接返回已有 module_id
    // 1. 发现：查模块清单 modules.json（name/abi/version/sha256/URL/.so文件名）；
    //    未下载则先下载 + 哈希校验
    // 2. dlopen（绝对路径，app 私有目录 filesDir/modules/<abi>/）
    // 3. dlsym 注册入口（"gstore_mod_" + name + "_register"）
    // 4. 握手：传 Entry → 收 Api；校验 abi_version / entry_size / min_host_abi / name 一致
    // 5. 包装 DlModuleAdapter → 插入注册表 → 分配 module_id → 返回
}
```

### 4.4 两种触发时机

| 时机 | 触发 | 适用场景 |
|---|---|---|
| **按需注册**（主） | Dart `loadModule('qr')` → 宿主查注册表 → 无则下载+dlopen+握手 | 低频工具模块（qr/analyzer），首次使用才拉取——体积方案核心 |
| **预注册**（可选） | 宿主启动扫描 manifest 里 `preload: true` 的模块（已打进 APK） | 高频但想模块化的域；启动即挂载，调用零延迟 |

---

## 5. 句柄与生命周期（多实例管理）

### 5.1 三层句柄，Dart 只持有代理对象

```
Dart:  final qr = await RustLib.instance.api.loadModule('qr');   // ModuleHandle（模块代理）
       final decoder = qr.createInstance(configBytes);           // InstanceHandle（实例代理）
       final result = await decoder.call('decode_luma', payload); // 直接调，不携带任何 id
       decoder.dispose();                                        // 显式释放实例
       qr.dispose();                                             // 释放模块引用
```

id 关联全部发生在 Rust 侧 opaque 对象内部，FRB 自动把 opaque（内含 `module_id`/`instance_id`）传给宿主，宿主内部路由。**外部零感知**。

### 5.2 两个 FRB opaque 句柄

```rust
/// Dart 侧 = 模块代理对象
#[frb(opaque)]
pub struct ModuleHandle {
    pub id: u64,
}

impl ModuleHandle {
    /// 实例化：宿主转发给模块 create()，返回实例代理对象
    pub fn create_instance(&self, config: Vec<u8>) -> Result<InstanceHandle, String> {
        let instance_id = MANAGER.call_create(self.id, &config)?;
        Ok(InstanceHandle { module_id: self.id, instance_id })
    }
    /// 模块级静态调用
    pub fn call_static(&self, method: String, payload: Vec<u8>) -> Result<Vec<u8>, String> {
        MANAGER.call(self.id, None, &method, &payload)
    }
}

/// Dart 侧 = 实例代理对象
#[frb(opaque)]
pub struct InstanceHandle {
    pub module_id: u64,
    pub instance_id: u64,
}

impl InstanceHandle {
    /// 实例方法调用 —— 外部不用带任何 id
    pub fn call(&self, method: String, payload: Vec<u8>) -> Result<Vec<u8>, String> {
        MANAGER.call(self.module_id, Some(self.instance_id), &method, &payload)
    }
    /// 显式释放
    pub fn dispose(&self) -> Result<(), String> {
        MANAGER.call_destroy(self.module_id, self.instance_id)
    }
}
```

### 5.3 生命周期双保险：显式 dispose + Drop/finalizer 兜底

- **主路径**：Dart 显式 `dispose()`（确定的时序，业务代码走这条）
- **兜底路径**：对象被 GC → Rust `Drop` 自动清理（防泄漏；**幂等设计**——dispose 后再次 drop 不报错）

```rust
impl Drop for InstanceHandle {
    fn drop(&mut self) {
        let _ = MANAGER.call_destroy(self.module_id, self.instance_id); // 幂等
    }
}
impl Drop for ModuleHandle {
    fn drop(&mut self) {
        MANAGER.unref_module(self.id); // refcount-1，归零时回收模块状态
    }
}
```

### 5.4 id 分配规则

| 层级 | id 空间 | 分配者 |
|---|---|---|
| `module_id` | 全局唯一（自增 u64） | 宿主注册表，`load_module` 时分配 |
| `instance_id` | **模块内唯一**（自增 u64） | **模块内部自己分配**（自己的实例 map） |

`(module_id, instance_id)` 组合全局唯一。instance_id 归模块分配的原因：**实例对象活在模块内部**（`HashMap<u64, Box<dyn Any>>`），宿主只转发数字，不持有对象——保持跨 .so 不传裸指针原则。

### 5.5 生命周期状态机

```
loadModule('qr') → 分配 module_id → 注册表登记（refcount=1）→ 返回 ModuleHandle
createInstance(config) → 模块内部分配 instance_id + 建实例 → 返回 InstanceHandle
call(method, payload) ×N → 宿主查模块 → 转发 (instance_id, method, payload) → 模块执行
dispose() / GC → 转发 destroy → 模块删除实例（幂等）
qr.dispose() / GC → refcount-- → 归零：从注册表移除 + shutdown 清理模块状态
                   （多 .so：.so 保持 resident 不 dlclose，仅回收状态）
```

**refcount 意义**：Dart 侧多处持有同一模块 handle 时（如两个页面都 `loadModule('qr')`），最后一个引用释放才真正回收模块状态，避免提前卸载导致悬垂句柄。

### 5.6 异步/长任务与取消

- 模块 trait 方法**保持同步签名**（`Result<Vec<u8>, ModuleError>`），模块内部自己用 tokio + 内部 runtime 处理异步
- 宿主用 `tokio::task::spawn_blocking` 包住模块调用，长任务不阻塞 FRB 的 async worker 线程池
- 模块实例状态用 `RwLock`/`Mutex` 保证 `Send + Sync`（trait 约束已强制）
- **取消**：Dart 发 `EnvelopeCancel(request_id, module, instance, method, reason)` → 宿主查 in-flight 表 → 调模块 api 表 `cancel(instance, request_id)` → 模块内部中止对应任务，其响应以 `ABORTED` 状态返回（`status=499, error_code=CANCELLED`）；超时由宿主 tokio timeout 兜底，同样触发 cancel 流程

---

## 6. 统一数据模型（信封 + 状态码 + 错误码）

**核心：仿 HTTP 的 request/response 契约。** 协议层统一，业务层自治。宿主只强解析信封层，payload 透传。

### 6.1 信封（protobuf，`contract/envelope.proto`）

```proto
// ============ 请求信封（类似 HTTP Request）============
message EnvelopeRequest {
  uint32 protocol_version = 1;      // 协议版本（1）

  // --- 路由头（代替 URL）---
  string module   = 2;              // 目标模块："qr" / "analyzer"
  string instance = 3;              // 实例句柄（空 = 模块级静态调用）
  string method   = 4;              // 方法名："decode_luma"

  // --- 元数据 ---
  string request_id = 5;            // 追踪ID：跨 Dart/Rust/模块日志关联
  int64  timestamp_ms = 6;          // 客户端时间戳
  Format payload_format = 7;        // body 编码：PROTOBUF / JSON / RAW_BYTES
  map<string, string> metadata = 8; // 扩展（timeout_ms、重试次数、trace 上下文…）
  bytes  payload = 10;              // body：域自定义 schema 的编码
}

// ============ 响应信封（类似 HTTP Response）============
message EnvelopeResponse {
  uint32 protocol_version = 1;
  string request_id = 2;            // 回声，调用方据此关联请求/响应

  // --- 状态（类似 HTTP status + reason phrase）---
  StatusCode status = 3;            // 机器可读状态码
  string error_code    = 4;         // 具体错误码："MODULE_NOT_FOUND" / "QR_INVALID_LUMA"
  string error_message = 5;         // 人类可读信息（可展示给用户）

  // --- 元数据 ---
  int64  timestamp_ms  = 6;         // 服务端时间戳
  int64  duration_ms   = 7;         // 模块内实际执行耗时
  map<string, string> metadata = 8; // 扩展（模块版本、降级标记…）
  bytes  payload = 10;              // body：成功时的域响应编码
}

enum Format { PROTOBUF = 0; JSON = 1; RAW_BYTES = 2; }  // 默认 PROTOBUF

// ============ 取消消息（主动中断长任务）============
message EnvelopeCancel {
  uint32 protocol_version = 1;
  string request_id = 2;            // 要取消的请求 ID（宿主据此定位 in-flight 调用）
  string module   = 3;
  string instance = 4;
  string method   = 5;              // 目标方法（可为空 = 取消该实例所有 in-flight）
  CancelReason reason = 6;
}
enum CancelReason { USER = 0; TIMEOUT = 1; SHUTDOWN = 2; }
```

**payload_format 设计**：默认 PROTOBUF（域 schema 也是 proto）；RAW_BYTES 给纯字节场景（QR 的 luma 帧直接裸传，省一次编解码）；JSON 给调试/快速原型。

### 6.2 状态码规范（仿 HTTP 语义分层）

```proto
enum StatusCode {
  // ===== 2xx 成功 =====
  OK                    = 200;
  CREATED               = 201;   // 实例创建成功

  // ===== 3xx 需要客户端配合（不是错误，是流程）=====
  MODULE_NOT_LOADED     = 301;   // 模块未下载/未挂载 → Dart 触发下载后重试
  INSTANCE_EXPIRED      = 302;   // 实例已释放/失效 → Dart 重建实例后重试

  // ===== 4xx 调用方错误（Dart 侧 bug / 参数问题）=====
  BAD_REQUEST           = 400;   // 信封解析失败 / payload 解码失败
  MODULE_NOT_FOUND      = 404;
  METHOD_NOT_FOUND      = 405;
  INSTANCE_NOT_FOUND    = 410;   // 实例 ID 不存在（可能已被释放）
  INVALID_ARGUMENT      = 422;   // 业务参数校验失败
  VERSION_MISMATCH      = 426;   // 模块/宿主/协议版本不兼容

  // ===== 499 主动取消（区别于 5xx 错误）=====
  ABORTED               = 499;   // 调用被 EnvelopeCancel 中断（用户取消/超时）

  // ===== 5xx 模块内部错误（模块自身问题，可重试或降级）=====
  INTERNAL_ERROR        = 500;
  PANIC_CAUGHT          = 5001;  // 模块内 panic 被 catch_unwind 捕获
  RESOURCE_EXHAUSTED    = 507;   // 内存/OOM/句柄耗尽
  TIMEOUT               = 504;

  // ===== 9xxx 域自定义码起点（status 保持大类，error_code 细化）=====
}
```

**为什么 status 与 error_code 分离**：和 HTTP 同理——`status` 决定**处理策略**（重试/降级/提示/报 bug），`error_code` 决定**具体原因**（日志与排障）。策略与原因分离，规则才能统一。

### 6.3 状态码 → Dart 处理策略固定映射（宿主实现一次，所有模块受益）

| status 范围 | Dart 侧统一处理 |
|---|---|
| 2xx | 正常返回 payload |
| 3xx | 不抛异常，触发对应流程（下载模块 / 重建实例）后**自动重试一次** |
| 4xx | 抛 `GStoreApiException`（调用方问题，不自动重试，记日志） |
| 499 | 抛 `GStoreCancelledException`（主动取消，业务按取消语义处理，不算错误） |
| 5xx | 抛 `GStoreModuleException`（模块问题，可手动重试/降级到空结果） |

### 6.4 错误码分层

```
错误码 = 归属前缀 + 具体码
                    │
协议层（宿主定义）  │  MODULE_NOT_FOUND, METHOD_NOT_FOUND, PANIC_CAUGHT,
  固定，不可改       │  VERSION_MISMATCH, INSTANCE_EXPIRED, TIMEOUT ...
────────────────────┼──────────────────────────────────────────
域层（模块自定义）  │  QR_DECODE_FAILED, QR_INVALID_LUMA_SIZE,
  带域前缀，模块管  │  ANALYZER_DEX_PARSE_FAILED, ANALYZER_ELF_MALFORMED ...
```

- 协议层错误码：宿主兜底产生，所有模块通用，枚举固定、文档化
- 域层错误码：模块在 `error_code` 字段自填，约定以 `模块名_` 为前缀，禁止裸码
- 归属规则：**谁产生谁填**，宿主不猜模块错误原因，模块不占用协议层命名空间

### 6.5 Rust 侧统一错误模型

```rust
// gstore_contract/src/error.rs —— 宿主和模块共用

#[derive(Debug, thiserror::Error)]
pub enum ModuleError {
    #[error("module error: {code}")]
    E {
        status: StatusCode,          // 大类 → 决定 Dart 处理策略
        code: &'static str,          // 域层/协议层错误码
        message: String,             // 人类可读
        #[source] cause: Option<Box<dyn Error + Send + Sync>>,  // 保留内部根因
    },
}

impl ModuleError {
    pub fn not_found(module: &str) -> Self { ... }
    pub fn invalid_arg(msg: impl Into<String>) -> Self { ... }
    pub fn internal(cause: impl Error + Send + Sync + 'static) -> Self { ... }
}

/// 从 thiserror/anyhow 错误自动映射（内部错误 → 统一码，根因不丢）
pub trait IntoModuleError {
    fn into_module_error(self, code: &'static str) -> ModuleError;
}
```

**规则**：模块内部随便用 `thiserror`/`anyhow`，**每个 extern "C" 边界统一收敛**为 `ModuleError` → 编码进 `EnvelopeResponse`。panic 被捕获 → `status=5001, error_code=PANIC_CAUGHT`，Dart 收到结构化错误而非进程崩溃。

### 6.6 Dart 侧统一异常模型

```dart
// lib/core/rust/module_exception.dart

sealed class GStoreException implements Exception {
  final StatusCode status;
  final String errorCode;
  final String message;
  final String requestId;   // 与日志/trace 关联
}

/// 4xx：调用方问题
class GStoreApiException extends GStoreException { ... }

/// 5xx：模块内部问题（retryable: TIMEOUT/RESOURCE_EXHAUSTED → true）
class GStoreModuleException extends GStoreException {
  final bool retryable;
}

/// 3xx：需要流程配合（下载模块/重建实例），由内部封装消费，通常不冒泡到业务层
class GStoreFlowException extends GStoreException { ... }
```

**Dart 统一处理函数**（内部封装，业务代码几乎不 catch）：

```dart
/// 统一响应处理：信封解包 + 状态分发 + 重试逻辑 + 日志埋点
Future<Uint8List> callModule(
  String module, String? instance, String method, Uint8List payload,
) async {
  final envelope = EnvelopeRequest(module: ..., method: ..., requestId: _newRequestId(), ...);
  final resp = await _manager.callEnvelope(envelope.writeToBuffer());
  final decoded = EnvelopeResponse.fromBuffer(resp);

  switch (decoded.status) {
    case 2xx:      return decoded.payload;
    case 301:      await _downloadModule(module); return _retry(decoded); // 下载后重试
    case 302:      final inst = await _rebuildInstance(); return _retry(decoded);
    case 4xx:      throw GStoreApiException(...);                        // 不重试
    case 5xx:      throw GStoreModuleException(retryable: ...);
  }
}
```

所有 `GStoreException` 统一进入全局错误上报（日志 + 可选的 Sentry 类服务），错误格式永远一致。

### 6.7 端到端示例

```
Dart:  QrDecoder.decodeLuma(luma, w, h)
  → EnvelopeRequest { request_id: "req_9f2c", module: "qr", instance: "42",
                      method: "decode_luma", payload: <QrDecodeRequest 编码> }
  → FRB callEnvelope(bytes) → 宿主
宿主:  解析信封 → 注册表查 module_id → InstanceHandle 路由 → DlModuleAdapter
  → C ABI → 模块
模块:  call_impl 内 catch_unwind：
        反序列化 QrDecodeRequest → 校验 luma 尺寸失败
        → Err(ModuleError::invalid_arg("luma size != w*h"))
  → EnvelopeResponse { status: 422, error_code: "QR_INVALID_LUMA_SIZE",
                       error_message: "...", request_id: "req_9f2c" }
Dart:  callModule 统一处理：4xx → 抛 GStoreApiException
  → 日志: "req_9f2c qr.decode_luma 422 QR_INVALID_LUMA_SIZE ..."
```

`request_id` 让 Dart 日志、宿主日志、模块日志（经 log/event 回调）全链路可关联。

### 6.8 日志与事件通道（宿主→Flutter 单向管道）

**目标**：宿主和所有模块的 `log!` 日志都能在 App 日志查看器（`LogManager`，`lib/core/logger/LogManager.dart`）中查看，模块零通道代码。

**原则：通道宿主一份，模块零代码。** 模块通过 `GStoreModuleEntry.log` 回调把日志交给宿主，宿主经 FRB Stream 汇入 `LogManager`。`emit_event`（模块→宿主→Dart 的事件推送，如进度/流式）与日志共用同一条宿主→Dart 管道，只是消息类型不同。

```
模块 .so（无 FRB）                     宿主 gstore_host.so              Flutter
┌──────────────────────┐  log! 宏  ┌──────────────────────────┐ FRB Stream ┌────────────┐
│ log! → HostLogger     │──────────►│ LogBridge（收集+级别映射+ │───────────►│ 监听 →      │
│ （gstore_contract 的  │           │  模块来源标记）           │            │ LogManager │
│  现成 helper）        │           │ StreamSink.add           │            │ .log(...)  │
└──────────────────────┘           └──────────────────────────┘            └─────┬──────┘
     ↑ 握手时收到                                                               │
     GStoreModuleEntry.log                                                日志查看器显示
```

**宿主侧（唯一真正的通道实现）**：新增 FRB opaque `LogBridge`，暴露 `logs_stream()` 返回 `Stream<LogMessage>`；`LogMessage = { level, message, module, timestamp_ms }`。宿主实现注入给模块的 `host_log` 回调（`LogBridge::push`，内部 Mutex + StreamSink，线程安全、自动 marshal 到 Dart isolate；Dart 未订阅时进环形缓冲如 200 条，订阅时补发，与 `LogManager` 的快照+流模式对齐）。宿主自身日志也走同一 LogBridge（可保留 android_logger 双写 logcat 或不保留，日志查看器成为统一出口）。

**模块侧适配（一行挂接，`gstore_contract` 提供 helper）**：

```rust
// gstore_contract/src/logging.rs
pub struct HostLogger { log_fn: extern "C" fn(i32, *const c_char) }
impl log::Log for HostLogger {
    fn log(&self, record: &log::Record) {
        (self.log_fn)(record.level() as i32, cstr!(record.args()));
    }
}
/// 模块在 register 握手后调用一次
pub fn attach_host_logger(entry: &GStoreModuleEntry, module_name: &str) {
    let logger = HostLogger { log_fn: entry.log.unwrap() };
    log::set_boxed_logger(Box::new(logger)).ok();
    log::set_max_level(LevelFilter::Info);
}
```

模块内用标准 `log::info!(...)` 宏即可，**开发者不感知日志通道存在**。这里利用了 Oracle 风险 #9（logger 静态是每 .so 独立）：模块 `log::set_boxed_logger` 设置的是模块自己 .so 里的 logger 静态，但指向宿主注入的函数指针，日志最终汇入宿主通道。

| 关键细节 | 设计 |
|---|---|
| 级别映射 | Rust `Trace/Debug/Info/Warn/Error` → Dart `debug/info/warning/error`（trace 归 debug） |
| 来源区分 | `LogMessage.module` 字段 + Dart 侧 `[模块名]` 前缀，查看器可按模块筛选 |
| 多模块 | 每模块 `log::set_boxed_logger` 指向同一宿主回调，宿主按调用线程/上下文标记来源 |
| 性能 | 日志高频可加简单限流；StreamSink 异步不阻塞模块执行 |
| 事件复用 | `emit_event` 与日志共用同一宿主→Dart Stream 管道（消息类型区分），不另开通道 |
| request_id 关联 | 模块处理请求时可在日志中附带 `request_id`，与 6.7 全链路日志关联对齐 |

---

## 7. 安全模型

| 阶段 | 内容 |
|---|---|
| **最小可用（先上）** | 模块走 HTTPS（GitHub Release 附件）+ SHA-256 清单；下载后**且 dlopen 前**各校验一次（校验即将执行的字节） |
| **推荐（二期）** | Ed25519 签名覆盖 `(abi \| module_name \| version \| sha256)`，**公钥编译期钉死在 App 内**（绝不网络获取，否则退化为 TLS）；宿主 Rust 用 `ed25519-dalek` v2（纯 Rust，避免 ring 的 NDK 坑） |
| **拒绝规则** | 未知 abi_version、ABI 不匹配、**版本降级**（持久化 last-known-good 版本）、name 不匹配 → 一律拒绝 mount |
| **存储** | 模块存 app 私有 `filesDir`（默认权限即可） |

SHA-256 单独即可自洽的理由：GStore 走 GitHub Release 分发（不经 Play 政策），APK 本身同信任锚；Ed25519 增加的是"谁发布的"证明 + 防降级。清单必须含 per-ABI + version 字段，防"加载错二进制"类错误。

---

## 8. 关键技术风险与对策（Oracle 验证结论）

| # | 风险 | 严重度 | 对策 |
|---|---|---|---|
| 1 | **panic=abort 在模块中 → 整个进程 SIGABRT** | 致命 | 模块 `panic="unwind"` + 每个 extern "C" 入口 `catch_unwind`；Rust≥1.81 panic 穿过 extern "C" 直接 abort，catch 必须在边界前 |
| 2 | **跨 .so 内存所有权** | 致命 | 默认 System 分配器（同 libc malloc）；跨边界数据统一走 entry/api 表里的 alloc/free，谁分配谁释放 |
| 3 | **dlclose 崩溃**（运行中线程/TLS 析构/JNI 注册） | 高 | mount-once **永不 unload**；仅进程退出回收；.so 文本页 file-backed，驻留几乎零成本 |
| 4 | **符号内插**（Android 默认 namespace 近似全局，模块未定义符号会解析到进程内任意已加载 .so） | 高 | 导出符号唯一前缀 `gstore_mod_<domain>_`；宿主服务按值注入（Entry 结构体），不 dlsym |
| 5 | **dlopen 路径 & 设备矩阵** | 高 | `nativeLibraryDir` 现代 Android **只读**（`useLegacyPackaging=false` 时直接从 APK 加载）→ 模块必须放 `filesDir` 绝对路径 dlopen；`Build.SUPPORTED_ABIS` 映射 4 个 Rust target；API 23-26 真机矩阵 |
| 6 | **zxing-cpp C++ 运行时** | 中 | 先 `readelf -d libfdroid_repo.so` 查 DT_NEEDED 是否含 `libc++_shared.so`（Flutter 插件自动打包）；模块与宿主**零 DT_NEEDED 依赖**（CI readelf 检查） |
| 7 | **unwind 表 vs strip** | 中 | aarch64 用 `.eh_frame`、armv7 用 `.ARM.exidx`；`strip=true` 保留 dynsym+unwind 表，需 readelf 验证；panic 路径**每个 ABI 在 CI 至少执行一次** |
| 8 | **FRB 互动** | 中 | 模块纯 C ABI 不引用 FRB/Dart 符号；宿主先加载、模块后挂载；**Dart 不直接 dlopen 模块**，全部经宿主 FRB |
| 9 | **重复 std 静态** | 低 | Rust 隐藏可见性使重复静态基本无害；但 `env::set_var`、logger、TLS 是每 .so 独立 → 日志走宿主注入的 log 回调，模块不自行初始化 |
| 10 | **损坏文件** | 低 | dlopen 失败返回 null 句柄（不崩溃）；SHA-256 在 dlopen **前**校验，mount 错误经 Dart 明确上报 |

---

## 9. 实施路线（分阶段）

| 阶段 | 内容 | 里程碑 / 退出条件 |
|---|---|---|
| **P0 体积卫生** ✅ 已完成 2026-09-11（核实+量化：CI 已实践 per-ABI 拆分发布，本轮补齐验证） | GitHub Releases **per-ABI 拆分 APK**（CI build.yml 已用 `--split-per-abi` 构建 arm64/armv7/x86_64 三包并上传，x86 仅本地调试分发）；**16KB 对齐验证**：`.so` 以 Stored（未压缩）进包，`zipalign -c -P 16` 确认 arm64 APK 内全部 10 个 `.so` 对齐 (OK)——满足 Android 15+ 16KB 页面设备硬性要求；**量化基线**：arm64 单包 45MB vs 全量 66MB（**省 ~30%**），armv7 40MB，x86_64 48MB；`useLegacyPackaging=false`（Flutter 默认，无显式配置，.so 不压缩对齐存储）；`build_android_rust.sh` 关键路径支持环境变量覆盖（`GSTORE_NDK_PATH`/`GSTORE_PROJECT_DIR`/`GSTORE_LIB_DIR`/`GSTORE_MODULE_DIR`），供 CI runner 复用模块构建 | 单 ABI APK 发布流程确认跑通；Release 附件为 3 个 ABI APK + AAB（`GStore-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`） |
| **P1 框架落地** ✅ 已完成 2026-09-11 | `gstore_contract` 模块（abi.rs + envelope.rs + error.rs + logging.rs，5 测试）；ModuleManager（注册表 + GStoreModule trait，4 测试）；ModuleHandle/InstanceHandle/LogBridge FRB 桥面；LogBridge → `LogManager` 日志订阅；全链路生命周期测试（register→load→create→call→destroy→卸载） | `cargo test` 25 passed；`dart analyze` 0 error；APK 构建成功 |
| **P2 QR 试点（全链路）** ✅ 已完成 2026-09-11 | 拆 `qr_decode.rs` → `gstore_mod_qr` 独立 crate（cdylib，C ABI 导出 `gstore_mod_qr_register`）；`gstore_contract` 抽独立 crate；宿主 `DlModuleAdapter`（libloading 握手）+ `ModuleManager.load_module_from_so` + `ModuleHandle.mount_from_so`；Dart `RustModuleLoader`（内置 jniLibs 检索 → 本地私有目录 → 远程下载三级；SHA-256 清单校验）；`QrRustDecoder` 模块路径（JSON 响应 + 降级旧路径）；构建脚本支持模块 4 ABI 输出；`generate_modules_manifest.sh` 清单生成 | `cargo test` 27 passed（含 Linux dlopen 集成测试 2 个）；`dart analyze` 0 error；flutter test 通过；APK 构建成功（70.9MB，内置 `libgstore_mod_qr.so` 3 ABI） |
| **P3 协议完善** ✅ 已完成 2026-09-11 | protobuf envelope 全量落地（`proto/envelope.proto` → prost 生成提交版 `src/pb/envelope.rs` + Dart `envelope.pb.dart`；`gstore_contract::envelope` 为 prost 封装层，API 与 serde 版兼容，宿主零改动）；Dart `GStoreException` 分层异常（Api/Flow/Cancelled/Module + `statusCodeToException` 策略映射）+ `RustModuleManager.callModule` 统一信封调用（request ID 埋点 + 日志）；`InstanceHandle.instance_id()` 信封路由；`QrRustDecoder` 走统一 callModule（异常降级）；`security.rs` Ed25519 签名验证（ed25519-dalek v2，公钥编译期钉死）+ SHA-256 + 版本降级拒绝策略 | `cargo test` 32 passed（contract 10 含 security 3 + host 22）；`dart analyze` 0 error；flutter test 相关通过；APK 构建成功（70.9MB） |
> **P3 补充说明**：`protoc-bin-vendored`（build.rs）与系统的 `protoc` 均无需安装——proto 代码**生成并提交**（`src/pb/envelope.rs` + `lib/core/rust/generated/contract/`），Android 交叉编译无 protoc 依赖；Dart 侧 protoc_plugin 版本须匹配 protobuf 运行时（项目锁 protobuf 3.x → protoc_plugin 21.x，非最新 25.x）。

> **P2 关键经验（zxing-cpp Android 交叉编译）**：模块依赖 zxing-cpp（C++ bundled）时，构建**必须依赖 `CMAKE_TOOLCHAIN_FILE` 让 NDK android.toolchain.cmake 接管编译器**——手动设置 `CC_<target>`/`CXX_<target>`（如 `aarch64-linux-android33-clang`）会触发两个致命问题：① `__bsd_locale_fallbacks.h` 的 va_list 类型冲突（C++20 + NDK 26.3 libc++）；② 链接时 `crtbegin_dynamic.o` 找不到。宿主同样依赖此规则（`build_module` 已按此实现）。
>
> **P2 内置方案（当前激活）**：模块 .so 编译后放入 `android/app/src/main/jniLibs/<abi>/`（与宿主同目录）。**加载链路（2026-09-11 修复）**：`RustModuleLoader.ensureModule` 经 `extractModule` 平台通道从 **APK 内 `lib/<abi>/` 提取 .so 到 `filesDir/gstore_mods/<abi>/`** 再交给宿主 dlopen——因 `useLegacyPackaging=false`（Android 默认）时 `nativeLibraryDir` 无物理文件，`getSelfNativeLibraryDir` 检索不可用。ABI 匹配由平台侧 `Build.SUPPORTED_ABIS` 自动定位（适配 armv7/x86_64）。远程下载链路（`remoteBaseUrl` + modules.json）已实现但未配置——配置后即切换按需下载。
>
> **瘦身回归修复记录（2026-09-11）**：瘦身删除宿主内置 `QrDecoder`/APK 分析降级路径后，扫码曾失效——根因①模块加载依赖 `nativeLibraryDir`（useLegacyPackaging=false 下无物理文件）→ 改 `extractModule` 通道从 APK 显式提取；根因②`RustModuleInstance.instanceId` 强转 FRB 异步 `Future<String>` → 改异步 getter。修复后扫码恢复、Rust 日志正常。
| **P4 扩展** ✅ 已完成 2026-09-11 | analyzer 域拆分为 `gstore_mod_analyzer` crate（apk/components/dex_scan/elf 四个无状态域，C ABI 导出 `gstore_mod_analyzer_register`，已入 jniLibs 内置）；事件通道（`event_bridge.rs` ModuleEvent → FRB Stream，`DlModuleAdapter` 握手注入 `emit_event`，`RustModuleManager.setModuleEventHandler` 订阅）；预注册策略（`ModuleManager.register_preload` persistent 常驻 + `RustModuleManager.preloadModules`）；模块更新检查（`RustModuleLoader` 远端清单版本对比 + SHA-256 校验 + 拒绝降级） | `cargo test` 32 passed（contract 10 + host 10 + analyzer 12）；`dart analyze` 0 error；flutter test 相关通过；APK 构建成功 |
| **宿主体积瘦身** ✅ 2026-09-11 | 移除宿主机体内已拆域的实现代码（qr_decode/apk/components/dex_scan/elf）+ 依赖（zxing-cpp/apk-info-axml）；Dart 侧改用手写契约类型（`ModuleTypes.dart`，模块 JSON 契约定义类型不依赖 FRB）；`AnalyzerRustDecoder`/`QrRustDecoder` 降级路径改为直接返回 null（宿主已删内置实现） | 宿主机身 **5.2M → 3.7M**（arm64）；APK **73.1MB → 68.9MB**；`dart analyze` 0 error；相关 flutter test 通过 |

---

## 10. 决策记录（已定稿）

| # | 决策点 | 结论 | 影响 |
|---|---|---|---|
| 1 | 模块域 payload 编码 | **全 protobuf**（envelope + 每域 schema） | P1/P2 引入 protoc + prost + protobuf_dart 工具链 |
| 2 | repo 域形态 | **全部域统一走路由**（含 repo；repo 为常驻 preload 模块） | FRB 桥面收窄为通用路由；现有 `FdroidRustRepoManager` 需迁移（附录 B） |
| 3 | 模块回收语义 | **保持留驻**（仅释放实例，模块状态复用，不 dlclose） | 无额外成本 |
| 4 | 超时/取消 | **现在就设计 `EnvelopeCancel` 消息** | 协议含 EnvelopeCancel + api 表 cancel 槽位 + ABORTED(499) 状态 |
| 5 | crate 改名 | **现在改**（改名牵动 .so 名/jniLibs/stem/构建脚本，见附录 C） | P1 前置任务 |
| 6 | 错误码文档 | **生成**（协议层错误码 + 各域错误码登记表） | 交付物：`rust/ERROR_CODES.md`（协议层已在此文 6.2/6.4；域层随模块建立） |

---

## 附录 A：FRB 2.11 实证约束（P1 实测，实施 P2/P3 必须遵守）

P1 实施中通过 3 组实验确认的 flutter_rust_bridge 2.11.1 行为（`rust_input: gstore_host::bridge` 配置下）：

| # | 约束 | 实证结论 | 应对 |
|---|---|---|---|
| 1 | **自由函数不生成** | `pub fn call_envelope(...)`、`test_free_fn(...)` 等模块级自由函数均**不生成** Dart 绑定 | 所有暴露 API 必须是 opaque 类型的 `impl` 方法（如 `ModuleHandle::call_envelope`） |
| 2 | **跨模块 re-export 的 opaque 不生成** | `pub use crate::log_bridge::LogBridge`（opaque）不被跟随，0 生成 | opaque 类型必须**直接定义在 bridge.rs**；普通数据类（如 `LogMessage`）re-export 可被跟随 |
| 3 | **StreamSink 导入路径** | `flutter_rust_bridge::for_generated::StreamSink` 不存在（只有 `StreamSinkBase`）；正确路径是 `crate::frb_generated::StreamSink`（由生成宏定义） | 用 `use crate::frb_generated::StreamSink;` |
| 4 | **`#[frb(opaque)]` 必须显式标注** | 未标注的 `pub struct LogBridge;` 不被当作 opaque 处理 | opaque 类型必须 `#[frb(opaque)]` |

**推论**：P2 拆分模块 .so 时，模块自身是纯 Rust cdylib（不涉及 FRB），此约束不影响模块内部；但宿主侧新增桥面类型必须遵循上述规则。

**P1 交付物清单**（2026-09-11）：
- `rust/gstore_host/src/contract/`：abi.rs（C ABI 契约）+ envelope.rs（JSON 信封，proto 待切换）+ error.rs（ModuleError）+ logging.rs（HostLogger）——5 测试
- `rust/gstore_host/src/manager.rs`：ModuleManager（注册表 + refcount + register_by_name + call_envelope）——4 测试（含全链路生命周期）
- `rust/gstore_host/src/log_bridge.rs`：LogBridge 内部实现（环形缓冲 + subscribe + host_log + push_host_log）
- `rust/gstore_host/src/bridge.rs`：ModuleHandle / InstanceHandle / LogBridge FRB opaque（直接定义）+ call_envelope impl 方法
- `lib/core/rust/ModuleManager.dart`：RustModuleManager 门面（loadModule/isLoaded/releaseModule）+ RustModuleInstance（实例调用）+ LogManager 日志订阅
- `lib/core/rust/FdroidRustRepoManager.dart`：initialize 接入 `RustModuleManager.ensureReady()`

**P1 遗留项**：✅ envelope 已从 serde_json 切换为 prost（P3 完成），字段结构不变。

**P3 交付物清单**（2026-09-11）：
- `rust/gstore_contract/proto/envelope.proto`：统一信封协议（EnvelopeRequest/Response/Cancel + StatusCode/PayloadFormat/CancelReason）
- `rust/gstore_contract/src/pb/envelope.rs`：prost 生成代码（提交版，build.rs 用 protoc-bin-vendored 生成，Android 交叉编译无 protoc 依赖）
- `rust/gstore_contract/src/envelope.rs`：prost 封装层（API 与 serde 版兼容：new/encode/decode/ok/err/is_ok + status_to_pb/status_from_i32）——7 测试
- `rust/gstore_contract/src/security.rs`：Ed25519 签名验证（signing_payload + verify_module_signature）+ SHA-256 + 版本降级拒绝策略（is_version_downgrade）——3 测试
- `lib/core/rust/generated/contract/envelope.pb*.dart`：Dart protobuf 生成代码（protoc_plugin 21.x 匹配 protobuf 3.x）
- `lib/core/rust/contract/GStoreException.dart`：GStoreException 分层异常（Api/Flow/Cancelled/Module）+ statusCodeToException 策略映射
- `lib/core/rust/ModuleManager.dart`：`callModule` 统一信封调用（request ID + 日志埋点 + 异常映射）、`RustModuleInstance.callModule`、`instanceId` getter
- `rust/gstore_host/src/bridge.rs`：`InstanceHandle.instance_id()`（信封 instance 字段路由）
- `lib/core/rust/QrRustDecoder.dart`：模块路径走统一 callModule（GStoreException 降级）

---

## 附录 B：与现有代码的关系（迁移清单）

- **单 .so 过渡期**：`gstore_contract` + `ModuleManager` 先在 `fdroid_repo` 单 crate 内实现（`ModuleEntry.module` 直接是 `Arc<dyn GStoreModule>` 具体实现，不需要 DlModuleAdapter）；拆分 .so 时补 DlModuleAdapter，Dart API 形态不变
- **repo 域迁移清单**（决策 2：全路由后，现有强类型接口迁移为信封调用）：
  - `lib/core/rust/FdroidRustRepoManager.dart`：`FdroidRepoManager` opaque 用法 → `ModuleHandle`/`InstanceHandle` + `EnvelopeRequest`
  - `lib/core/fdroid/FdroidRepoManager.dart`（GetX 服务）：`initialize/downloadRepo/getAppCount/searchApps/clearApps/getOneApp/appInfoToMap` 改走统一 `callModule`
  - `lib/core/rust/QrRustDecoder.dart`：`QrDecoder` opaque → `ModuleHandle`（qr 模块）
  - `lib/core/service/apk_info_service.dart` / `apk_library_analyzer.dart` / `lib/page/installed_apps/sdk_analysis_page.dart`：`parseApkInfo/scanDexClasses/parseComponents/scanElfPageSizes` → analyzer 模块路由调用
  - 迁移期可保留薄壳兼容层（原方法签名不变、内部改走路由），调用方代码改动最小化
- **死代码清理**（与架构无关，建议尽快做）：
  - 删 `lib/core/rust/` 下旧生成绑定（`bridge.dart`、`frb_generated*.dart`、`models.dart`，2026-08-05 批次，无引用）
  - 删 `rust/fdroid_repo/rust/src/frb_generated.rs`（嵌套残留）
  - 删/决策 `getAppDetail`（已实现未使用）、`RepoManager`（空 opaque）、`FlutterProgressCallback`（占位符）
  - 修 `setup_rust.sh`（指向不存在的 `frb_config.yaml`，实际配置在 pubspec.yaml）
- **当前 Cargo.toml 冲突**：`[profile.release] panic = "abort"` 只适用于宿主；拆分模块时必须用 profile override 覆盖为 unwind

---

## 附录 C：crate 改名方案（决策 5，✅ 已完成 2026-09-11）

**目标**：`fdroid_repo` → `gstore_host`（与架构图宿主命名一致，产出 `libgstore_host.so`）——**已实施完毕**。

| 牵动面 | 状态 |
|---|---|
| Cargo.toml/Cargo.lock + 目录 | ✅ `rust/gstore_host/`，`[lib] name = "gstore_host"` |
| 构建产物 | ✅ `libgstore_host.so`（APK 内 arm64/armeabi-v7a/x86_64 已确认） |
| jniLibs | ✅ 4 ABI 全部重命名（git rename 跟踪） |
| FRB 生成 | ✅ 重新 codegen，`stem: 'gstore_host'`；清理 `repo.dart` 残留 |
| 构建脚本 | ✅ 4 个脚本（build_android_rust/simple/standalone/setup_rust）路径+产物名同步 |
| 文档 | ✅ README、rust/*.md、test 注释同步 |
| 占位符清理（联动） | ✅ 删除 `get_app_detail`/`FlutterProgressCallback`/`RepoManager` 空壳（`RepoManager` 改 `pub(crate)`） |
| 验证 | ✅ `dart analyze` 0 error；Rust 相关测试全通过；`flutter build apk --release --target-platform android-arm64` 成功（66.7MB） |

**遗留**：72 个既有测试失败与本次改动无关（`libsqlite3.so` 测试环境缺失，sqflite_ffi 问题）；`dart analyze` 的 769 条 info/warning 为既有代码质量债。
