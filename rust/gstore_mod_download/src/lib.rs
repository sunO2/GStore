//! gstore_mod_download：下载内核模块（P0 传输引擎 + P1 任务管理）。
//!
//! ## 与宿主的对接形态
//!
//! 本模块**不走**宿主的 `start_task` 包裹：它自带调度器（队列/并发/优先级），
//! 任务由模块内部按需拉起，而不是"一次 call 跑一个任务"。
//! 因此进度/终态经 `emit_event` 上广播总线，**载荷里带 `taskId`**，
//! Dart 侧按 `taskId` 解复用成每任务流（见 rust-flutter-async.md §七 的「形态 B」）。
//!
//! ## 方法（payload 一律 JSON）
//!
//! | method | 入参 | 出参 |
//! |---|---|---|
//! | `ping` | — | `"pong"`（静态，无需实例）|
//! | `download.start` | `{appId,appName,version,fileName,url,filePath,headers?,expectedSha256?,priority?,connections?}` | `TaskDto` |
//! | `download.list` | `{statuses?:[int]}` | `[TaskDto]` |
//! | `download.get` | `{id}` | `TaskDto` \| `null` |
//! | `download.pause` / `resume` / `cancel` / `retry` / `remove` | `{id}` | `{ok:true}` |
//! | `download.stats` | — | `{active,queued,completed,failed,maxConcurrent,speedLimitBps}` |
//! | `download.config` | `{maxConcurrent?,speedLimitBps?,connections?}` | 当前配置 |
//!
//! 事件：`download.progress`（节流）/ `download.done`（终态），载荷为 JSON 且含 `taskId`。

pub mod dedup;
#[cfg(test)]
mod dedup_tests;
mod engine;
pub mod model;
pub mod scheduler;
pub mod store;

#[cfg(test)]
pub mod test_support;

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use gstore_contract::abi::{
    ABI_ERR_ABI_MISMATCH, ABI_ERR_DETAIL, ABI_ERR_INTERNAL, ABI_ERR_NO_INSTANCE, ABI_ERR_NULL,
    ABI_ERR_PANIC, ABI_OK, GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
};
use gstore_contract::context::ModuleContext;
use gstore_contract::error::ModuleError;

use model::{ProgressEvent, Task, TaskDto, TaskStatus};
use scheduler::{NewTask, Scheduler, SchedulerConfig, TaskEmitter};

/// 事件类型（宿主/Dart 侧按此过滤）
const EVT_PROGRESS: &str = "download.progress";
const EVT_DONE: &str = "download.done";

/// 实例：调度器 + 专用 tokio Runtime（多连接分段下载）。
///
/// Runtime 必须由实例持有：`Scheduler` 用它的 `Handle` 派发任务，
/// Runtime 被 drop 会让在跑任务全部中止。
/// （`ModuleContext` 只在 create 时用于解析任务库路径，之后不再需要，故不驻留。）
pub struct DownloadInstance {
    scheduler: Arc<Scheduler>,
    _runtime: tokio::runtime::Runtime,
}

static INSTANCES: OnceLock<Mutex<HashMap<u64, Arc<DownloadInstance>>>> = OnceLock::new();
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);
static HOST_LOG: OnceLock<extern "C" fn(c_int, *const c_char)> = OnceLock::new();
static HOST_EMIT: OnceLock<extern "C" fn(u64, u64, *const u8, usize)> = OnceLock::new();

fn instances() -> &'static Mutex<HashMap<u64, Arc<DownloadInstance>>> {
    INSTANCES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 上报模块事件（宿主 `host_emit_event` 的负载约定：前 4 字节为类型长度，小端）。
///
/// 本模块的任务不在宿主 `start_task` 的线程上下文里，因此事件走**广播总线**，
/// 由载荷里的 `taskId` 让 Dart 侧完成解复用。
fn emit_event(instance_id: u64, event_type: &str, payload: &[u8]) {
    let Some(f) = HOST_EMIT.get() else { return };
    let type_bytes = event_type.as_bytes();
    let mut buf = Vec::with_capacity(4 + type_bytes.len() + payload.len());
    buf.extend_from_slice(&(type_bytes.len() as u32).to_le_bytes());
    buf.extend_from_slice(type_bytes);
    buf.extend_from_slice(payload);
    f(0, instance_id, buf.as_ptr(), buf.len());
}

fn log_message(level: c_int, msg: &str) {
    if let Some(f) = HOST_LOG.get() {
        if let Ok(cmsg) = CString::new(msg) {
            f(level, cmsg.as_ptr());
        }
    }
}

/// 静默 panic hook（与 repo 模块同策略：避免 Android 上 backtrace 符号化器把 panic
/// 放大成 SIGSEGV）。每个 C ABI 入口都重装，防止被 FRB 覆盖。
fn install_panic_hook() {
    let _ = std::env::set_var("RUST_BACKTRACE", "0");
    std::panic::set_hook(Box::new(|info| {
        let msg = if let Some(s) = info.payload().downcast_ref::<&str>() {
            (*s).to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "unknown panic".to_string()
        };
        let loc = info
            .location()
            .map(|l| format!("{}:{}", l.file(), l.line()))
            .unwrap_or_else(|| "?".to_string());
        log_message(3, &format!("download module panic at {loc}: {msg}"));
    }));
}

/// 事件出口实现：把调度器事件桥到 C ABI `emit_event`。
struct HostEmitter {
    instance_id: u64,
}

impl TaskEmitter for HostEmitter {
    fn progress(&self, ev: ProgressEvent) {
        match serde_json::to_vec(&ev) {
            Ok(b) => emit_event(self.instance_id, EVT_PROGRESS, &b),
            Err(e) => log_message(3, &format!("download: 进度序列化失败 {e}")),
        }
    }

    fn terminal(&self, task: &Task) {
        match serde_json::to_vec(&TaskDto::from(task)) {
            Ok(b) => emit_event(self.instance_id, EVT_DONE, &b),
            Err(e) => log_message(3, &format!("download: 终态序列化失败 {e}")),
        }
    }

    fn log(&self, msg: &str) {
        log_message(1, msg);
    }
}

// ==================== 方法实现 ====================

fn create_impl(config: *const u8, config_len: usize) -> Result<u64, c_int> {
    let bytes: &[u8] = if config.is_null() || config_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(config, config_len) }
    };
    let ctx = ModuleContext::parse(bytes);
    log_message(
        1,
        &format!(
            "download module create: data_dir={} cache_dir={} db_path={} abi={}",
            ctx.data_dir, ctx.cache_dir, ctx.db_path, ctx.abi
        ),
    );

    let db_path = ctx.resolve_db_path("download.db");
    let conn = store::open(&db_path).map_err(|e| {
        log_message(3, &format!("download: 打开任务库失败 {e}"));
        ABI_ERR_INTERNAL
    })?;

    // 崩溃恢复：重启后 downloading/connecting 已无执行者 → 降级为 paused，交用户决定
    match store::recover_after_restart(&conn) {
        Ok((paused, queued)) => log_message(
            1,
            &format!("download: 重启恢复完成 paused={paused} queued={queued}"),
        ),
        Err(e) => log_message(3, &format!("download: 重启恢复失败 {e}")),
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("gstore-download")
        .build()
        .map_err(|e| {
            log_message(3, &format!("download: 构建 runtime 失败 {e}"));
            ABI_ERR_INTERNAL
        })?;

    let id = NEXT_INSTANCE.fetch_add(1, Ordering::SeqCst);
    let emitter: Arc<dyn TaskEmitter> = Arc::new(HostEmitter { instance_id: id });
    let scheduler = Scheduler::new(
        conn,
        runtime.handle().clone(),
        SchedulerConfig::default(),
        emitter,
    );
    scheduler.start();

    let inst = Arc::new(DownloadInstance {
        scheduler,
        _runtime: runtime,
    });
    instances().lock().unwrap().insert(id, inst);
    Ok(id)
}

/// 取 payload 字节（空 → 空切片）
fn payload_bytes<'a>(payload: *const u8, len: usize) -> &'a [u8] {
    if payload.is_null() || len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(payload, len) }
    }
}

fn parse_json<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, ModuleError> {
    serde_json::from_slice::<T>(bytes).map_err(|e| ModuleError::invalid_arg(format!("参数解析失败: {e}")))
}

/// 把显式 `null` 也当作"未提供"。
///
/// `#[serde(default)]` **只在字段缺失时生效**；跨语言调用里客户端显式发 `null`
/// 很常见，会直接变成 "invalid type: null, expected a map" 把整条请求打回。
/// 这里统一兜住，避免一个空字段废掉整次调用。
fn null_as_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Default + serde::Deserialize<'de>,
{
    Ok(<Option<T> as serde::Deserialize>::deserialize(d)?.unwrap_or_default())
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct StartReq {
    #[serde(default)]
    strict_dedup: bool,
    /// 下载完成后是否自动安装（Dart 侧据此触发安装）
    #[serde(default, deserialize_with = "null_as_default")]
    install_after_download: bool,
    /// 资源类型与标识（通用：下载不只服务应用）；都留空时退回 URL+目标路径 指纹
    #[serde(default, deserialize_with = "null_as_default")]
    kind: String,
    #[serde(default, deserialize_with = "null_as_default")]
    resource_id: String,
    #[serde(default, deserialize_with = "null_as_default")]
    resource_version: String,
    /// 调用方显式指定的判重键（最优先）
    #[serde(default, deserialize_with = "null_as_default")]
    dedup_key: Option<String>,
    /// 撞键策略：keep（默认）/ replace / append
    #[serde(default, deserialize_with = "null_as_default")]
    conflict: crate::dedup::ConflictPolicy,
    app_id: String,
    #[serde(default, deserialize_with = "null_as_default")]
    app_name: String,
    #[serde(default, deserialize_with = "null_as_default")]
    version: String,
    file_name: String,
    url: String,
    file_path: String,
    #[serde(default, deserialize_with = "null_as_default")]
    headers: HashMap<String, String>,
    #[serde(default, deserialize_with = "null_as_default")]
    expected_sha256: Option<String>,
    #[serde(default, deserialize_with = "null_as_default")]
    priority: i32,
    #[serde(default, deserialize_with = "null_as_default")]
    connections: Option<u32>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct IdReq {
    id: u64,
}

#[derive(serde::Deserialize)]
struct ListReq {
    #[serde(default)]
    statuses: Vec<i32>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigReq {
    #[serde(default)]
    max_concurrent: Option<usize>,
    #[serde(default)]
    speed_limit_bps: Option<u64>,
    #[serde(default)]
    connections: Option<u32>,
}

fn scheduler_of(instance_id: u64) -> Result<SchedArc, c_int> {
    let inst = {
        let guard = instances().lock().unwrap();
        guard.get(&instance_id).cloned()
    };
    inst.map(|i| SchedArc(i.scheduler.clone()))
        .ok_or(ABI_ERR_NO_INSTANCE)
}

/// 调度器的薄包装：`add`/`resume` 需要 `&Arc<Self>`，包一层便于在 `call_impl` 里直接调用。
struct SchedArc(Arc<Scheduler>);

impl SchedArc {
    fn add(&self, spec: NewTask) -> Result<Task, ModuleError> {
        self.0.add(spec)
    }
    fn resume(&self, id: u64) -> Result<(), ModuleError> {
        self.0.resume(id)
    }
    fn pause(&self, id: u64) -> Result<(), ModuleError> {
        self.0.pause(id)
    }
    fn cancel(&self, id: u64) -> Result<(), ModuleError> {
        self.0.cancel(id)
    }
    fn retry(&self, id: u64) -> Result<(), ModuleError> {
        self.0.retry(id)
    }
    fn restart(&self, id: u64) -> Result<(), ModuleError> {
        self.0.restart(id)
    }
    fn remove(&self, id: u64) -> Result<(), ModuleError> {
        self.0.remove(id)
    }
    fn get(&self, id: u64) -> Result<Option<Task>, ModuleError> {
        self.0.get(id)
    }
    fn list(&self, filter: &[TaskStatus]) -> Result<Vec<Task>, ModuleError> {
        self.0.list(filter)
    }
    fn config(&self) -> SchedulerConfig {
        self.0.config()
    }
    fn set_config(&self, cfg: SchedulerConfig) {
        self.0.set_config(cfg)
    }
}

fn call_impl(
    instance_id: u64,
    method: *const c_char,
    payload: *const u8,
    payload_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    if method.is_null() {
        return Err(ABI_ERR_NULL);
    }
    let method = unsafe { CStr::from_ptr(method) }.to_string_lossy().into_owned();

    // 静态方法：无需实例
    if method == "ping" {
        return write_out(b"pong".to_vec(), out_data, out_len);
    }

    let bytes = payload_bytes(payload, payload_len);
    let handle = scheduler_of(instance_id)?;

    let result: Result<Vec<u8>, ModuleError> = (|| {
        match method.as_str() {
            "download.start" => {
                let req: StartReq = parse_json(bytes)?;
                let spec = NewTask {
                    kind: req.kind,
                    resource_id: req.resource_id,
                    resource_version: req.resource_version,
                    dedup_key: req.dedup_key,
                    conflict: req.conflict,
            strict_dedup: req.strict_dedup,
                    app_id: req.app_id,
                    app_name: req.app_name,
                    version: req.version,
                    file_name: req.file_name,
                    url: req.url,
                    file_path: req.file_path,
                    headers: req.headers.into_iter().collect(),
                    expected_sha256: req.expected_sha256,
                    priority: req.priority,
                    connections: req.connections,
                    install_after_download: req.install_after_download,
                };
                let task = handle.add(spec)?;
                to_json(&TaskDto::from(&task))
            }
            "download.list" => {
                let req: ListReq = parse_json(bytes).unwrap_or(ListReq { statuses: vec![] });
                let filter: Vec<TaskStatus> = req.statuses.iter().map(|i| TaskStatus::from_i32(*i)).collect();
                let list = handle.list(&filter)?;
                to_json(&list.iter().map(TaskDto::from).collect::<Vec<_>>())
            }
            "download.get" => {
                let req: IdReq = parse_json(bytes)?;
                match handle.get(req.id)? {
                    Some(t) => to_json(&TaskDto::from(&t)),
                    None => Ok(b"null".to_vec()),
                }
            }
            "download.pause" => {
                let req: IdReq = parse_json(bytes)?;
                handle.pause(req.id)?;
                Ok(br#"{"ok":true}"#.to_vec())
            }
            "download.resume" => {
                let req: IdReq = parse_json(bytes)?;
                handle.resume(req.id)?;
                Ok(br#"{"ok":true}"#.to_vec())
            }
            "download.cancel" => {
                let req: IdReq = parse_json(bytes)?;
                handle.cancel(req.id)?;
                Ok(br#"{"ok":true}"#.to_vec())
            }
            "download.restart" => {
                let req: IdReq = parse_json(bytes)?;
                handle.restart(req.id)?;
                Ok(br#"{"ok":true}"#.to_vec())
            }
            "download.retry" => {
                let req: IdReq = parse_json(bytes)?;
                handle.retry(req.id)?;
                Ok(br#"{"ok":true}"#.to_vec())
            }
            "download.remove" => {
                let req: IdReq = parse_json(bytes)?;
                handle.remove(req.id)?;
                Ok(br#"{"ok":true}"#.to_vec())
            }
            "download.config" => {
                let req: ConfigReq = parse_json(bytes).unwrap_or(ConfigReq {
                    max_concurrent: None,
                    speed_limit_bps: None,
                    connections: None,
                });
                let mut cfg = handle.config();
                if let Some(v) = req.max_concurrent {
                    cfg.max_concurrent = v.max(1);
                }
                if let Some(v) = req.speed_limit_bps {
                    cfg.speed_limit_bps = if v == 0 { None } else { Some(v) };
                }
                if let Some(v) = req.connections {
                    cfg.default_connections = v.max(1);
                }
                handle.set_config(cfg.clone());
                to_json(&serde_json::json!({
                    "maxConcurrent": cfg.max_concurrent,
                    "speedLimitBps": cfg.speed_limit_bps,
                    "connections": cfg.default_connections,
                    "maxRetries": cfg.max_retries,
                }))
            }
            "download.stats" => {
                let all = handle.list(&[])?;
                let active = all.iter().filter(|t| t.status.is_active()).count();
                let queued = all.iter().filter(|t| t.status == TaskStatus::Queued).count();
                let completed = all.iter().filter(|t| t.status == TaskStatus::Completed).count();
                let failed = all.iter().filter(|t| t.status == TaskStatus::Failed).count();
                let cfg = handle.config();
                to_json(&serde_json::json!({
                    "active": active,
                    "queued": queued,
                    "completed": completed,
                    "failed": failed,
                    "maxConcurrent": cfg.max_concurrent,
                    "speedLimitBps": cfg.speed_limit_bps,
                }))
            }
            _ => Err(ModuleError::method_not_found(&method)),
        }
    })();

    match result {
        Ok(b) => write_out(b, out_data, out_len),
        Err(e) => write_error_out(e, out_data, out_len),
    }
}

fn to_json<T: serde::Serialize>(v: &T) -> Result<Vec<u8>, ModuleError> {
    serde_json::to_vec(v).map_err(|e| ModuleError::internal(e.to_string()))
}

fn write_out(bytes: Vec<u8>, out_data: *mut *mut u8, out_len: *mut usize) -> Result<(), c_int> {
    let len = bytes.len();
    let ptr = unsafe { libc::malloc(len.max(1)) };
    if ptr.is_null() {
        return Err(ABI_ERR_INTERNAL);
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, len);
        *out_data = ptr as *mut u8;
        *out_len = len;
    }
    Ok(())
}

fn write_error_out(
    err: ModuleError,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    log_message(3, &format!("download: {err}"));
    let _ = write_out(err.to_payload(), out_data, out_len);
    Err(ABI_ERR_DETAIL)
}

fn destroy_impl(instance_id: u64) -> Result<(), c_int> {
    if let Some(inst) = instances().lock().unwrap().remove(&instance_id) {
        inst.scheduler.shutdown();
    }
    log_message(1, &format!("download: instance {instance_id} destroyed"));
    Ok(())
}

/// 取消：`request_id` 为任务 id 的十进制字符串；空 → 取消全部在跑任务。
fn cancel_impl(instance_id: u64, request_id: *const c_char) -> Result<(), c_int> {
    let inst = {
        let guard = instances().lock().unwrap();
        guard.get(&instance_id).cloned().ok_or(ABI_ERR_NO_INSTANCE)?
    };
    if request_id.is_null() {
        inst.scheduler.shutdown();
        return Ok(());
    }
    let raw = unsafe { CStr::from_ptr(request_id) }.to_string_lossy().into_owned();
    let id: u64 = raw
        .trim()
        .parse()
        .map_err(|_| {
            log_message(3, &format!("download: cancel 参数非法 request_id={raw}"));
            ABI_ERR_INTERNAL
        })?;
    inst.scheduler
        .cancel(id)
        .map_err(|_| ABI_ERR_INTERNAL)?;
    Ok(())
}

/// 宿主下行事件：目前只处理 `config.changed`（并发/限速热更新）。
fn on_event_impl(
    module_id: u64,
    kind: *const c_char,
    data: *const u8,
    data_len: usize,
) -> Result<(), c_int> {
    let kind_s = if kind.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(kind) }.to_string_lossy().into_owned()
    };
    let payload = payload_bytes(data, data_len);
    log_message(
        1,
        &format!(
            "download: on_event module_id={module_id} kind={kind_s} len={}",
            payload.len()
        ),
    );

    if kind_s == "config.changed" {
        let req: ConfigReq = serde_json::from_slice(payload).unwrap_or(ConfigReq {
            max_concurrent: None,
            speed_limit_bps: None,
            connections: None,
        });
        // 广播到所有实例（宿主不知道模块有几个实例）
        for (_, inst) in instances().lock().unwrap().iter() {
            let mut cfg = inst.scheduler.config();
            if let Some(v) = req.max_concurrent {
                cfg.max_concurrent = v.max(1);
            }
            if let Some(v) = req.speed_limit_bps {
                cfg.speed_limit_bps = if v == 0 { None } else { Some(v) };
            }
            if let Some(v) = req.connections {
                cfg.default_connections = v.max(1);
            }
            inst.scheduler.set_config(cfg);
        }
    }
    Ok(())
}

// ==================== C ABI 导出 ====================

#[no_mangle]
pub extern "C" fn gstore_mod_download_register(
    entry: *const GStoreModuleEntry,
    out: *mut GStoreModuleApi,
) -> c_int {
    install_panic_hook();
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        if entry.is_null() || out.is_null() {
            return Err(ABI_ERR_NULL);
        }
        let e = unsafe { &*entry };
        if e.abi_version != GSTORE_MODULE_ABI_VERSION {
            return Err(ABI_ERR_ABI_MISMATCH);
        }
        if let Some(f) = e.log {
            let _ = HOST_LOG.set(f);
        }
        if let Some(f) = e.emit_event {
            let _ = HOST_EMIT.set(f);
        }
        install_panic_hook();
        log_message(
            1,
            &format!(
                "download module register: abi={} size={} built={}",
                e.abi_version,
                e.entry_size,
                env!("CARGO_PKG_VERSION")
            ),
        );
        let api = unsafe { &mut *out };
        api.name = c"download".as_ptr();
        api.version = 1;
        api.min_host_abi = GSTORE_MODULE_ABI_VERSION;
        api.init = Some(init_export);
        api.create = Some(create_export);
        api.call = Some(call_export);
        api.cancel = Some(cancel_export);
        api.destroy = Some(destroy_export);
        api.shutdown = Some(shutdown_export);
        api.alloc = Some(alloc_export);
        api.free = Some(free_export);
        api.on_event = Some(on_event_export);
        Ok(ABI_OK)
    }));
    result.unwrap_or(Err(ABI_ERR_PANIC)).unwrap_or_else(|code| code)
}

#[no_mangle]
pub extern "C" fn init_export() -> c_int {
    install_panic_hook();
    ABI_OK
}

#[no_mangle]
pub extern "C" fn create_export(config: *const u8, config_len: usize, out: *mut u64) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| create_impl(config, config_len))) {
        Ok(Ok(id)) => {
            unsafe { *out = id };
            ABI_OK
        }
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn call_export(
    instance: u64,
    method: *const c_char,
    payload: *const u8,
    payload_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| {
        call_impl(instance, method, payload, payload_len, out_data, out_len)
    })) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn destroy_export(instance: u64) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| destroy_impl(instance))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn cancel_export(instance: u64, request_id: *const c_char) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| cancel_impl(instance, request_id))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn shutdown_export() -> c_int {
    for (_, inst) in instances().lock().unwrap().iter() {
        inst.scheduler.shutdown();
    }
    instances().lock().unwrap().clear();
    ABI_OK
}

#[no_mangle]
pub extern "C" fn on_event_export(
    module_id: u64,
    kind: *const c_char,
    data: *const u8,
    data_len: usize,
) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| {
        on_event_impl(module_id, kind, data, data_len)
    })) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn alloc_export(size: usize) -> *mut c_void {
    unsafe { libc::malloc(size.max(1)) }
}

#[no_mangle]
pub extern "C" fn free_export(ptr: *mut c_void) {
    if !ptr.is_null() {
        unsafe { libc::free(ptr) }
    }
}

/// 跨语言参数的健壮性回归：客户端把可选字段发成 `null` 时必须被容忍。
#[cfg(test)]
mod null_tolerance_tests {
    use super::*;

    #[test]
    fn start_req_tolerates_explicit_nulls() {
        // 背景：serde 的 `default` 只在字段**缺失**时生效，显式 `null` 曾让
        // download.start 整条被判 INVALID_ARGUMENT（"expected a map"）。
        let json = br#"{
            "kind": null, "resourceId": null, "resourceVersion": null,
            "dedupKey": null, "conflict": null, "appName": null, "version": null,
            "headers": null, "expectedSha256": null, "priority": null, "connections": null,
            "appId": "com.example", "fileName": "a.apk",
            "url": "https://example.com/a.apk", "filePath": "/tmp/a.apk"
        }"#;
        let req: StartReq = serde_json::from_slice(json).expect("显式 null 必须被容忍");
        assert_eq!(req.app_id, "com.example");
        assert_eq!(req.conflict, crate::dedup::ConflictPolicy::Keep);
        assert!(req.headers.is_empty(), "null headers 应退化为空表");
        assert!(req.connections.is_none());
        assert!(req.dedup_key.is_none());
    }
}
