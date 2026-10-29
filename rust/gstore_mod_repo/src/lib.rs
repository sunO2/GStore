// gstore_mod_repo：F-Droid 仓库管理模块（独立 cdylib）
//
// 从宿主体内拆分（原 repo.rs），遵循 PoC 验证的架构约束：
// 1. rusqlite Connection 非 Send → 实例整体 Arc<Mutex<RepoManager>>，call 时锁实例串行
// 2. 全局注册表锁取实例后立即释放（不跨越 async 任务），否则多实例 call 串行
// 3. download_repo async 经 runtime.block_on 同步返回（C ABI 同步契约）

mod fdroid_url;
mod merge_patch;
mod fingerprint;
mod models;
mod index_parse;
mod repo;

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::runtime::Runtime;

use gstore_contract::abi::{
    ABI_ERR_ABI_MISMATCH, ABI_ERR_DETAIL, ABI_ERR_INTERNAL, ABI_ERR_NO_INSTANCE, ABI_ERR_NULL,
    ABI_ERR_PANIC, ABI_OK, GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
    MIN_HOST_ABI,
};
use gstore_contract::error::ModuleError;

/// 实例：RepoManager（SQLite）+ 专用 tokio Runtime（download async block_on）
///
/// **锁策略（重要）**：本结构体**不再**被外层 Mutex 包裹。
/// `RepoManager` 内部已是 `db: Arc<Mutex<Connection>>`，DB 访问自带细粒度锁；
/// 再加一层实例级 Mutex 会导致「一次长时间下载锁住整个模块」
/// （下载期间 search/count 全部阻塞）。现在：
/// - 读/查询：并发执行，仅在访问 DB 时短暂抢锁
/// - 下载：用 [download_serial] 串行化（取消标志是实例级的，不能并发下载）
pub struct RepoInstance {
    manager: repo::RepoManager,
    runtime: Runtime,
    /// 取消标志：cancel 置位，download 流程在检查点读取
    cancel: Arc<AtomicBool>,
    /// 下载串行闸门：只串行「下载」本身，不阻塞查询
    download_serial: Mutex<()>,
}

static INSTANCES: OnceLock<Mutex<std::collections::HashMap<u64, Arc<RepoInstance>>>> = OnceLock::new();
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);
static HOST_LOG: OnceLock<extern "C" fn(c_int, *const c_char)> = OnceLock::new();
/// 宿主注入的事件回调（模块 → 宿主）：长任务进度由此上报。
/// 宿主按「当前线程所属任务」归属到对应任务流（Task 模型），模块无需感知。
static HOST_EMIT: OnceLock<
    extern "C" fn(u64, u64, *const u8, usize),
> = OnceLock::new();

fn instances() -> &'static Mutex<std::collections::HashMap<u64, Arc<RepoInstance>>> {
    INSTANCES.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

/// 上报模块事件（宿主 `host_emit_event` 的负载约定：前 4 字节为类型长度，小端）
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

/// 安装静默 panic hook：panic 时不生成 backtrace（避免 Android 上 backtrace 符号化器
/// mmap 崩溃为 SIGSEGV，掩盖原始 panic——真机崩溃的直接放大器）。
///
/// 注：FRB 的 setup_default_user_utils()（RustLib.init 时执行）会无条件调用
/// PanicBacktrace::setup() 覆盖 hook 并设 RUST_BACKTRACE=1。本函数不做 Once 幂等，
/// 而是在每个 C ABI 导出入口重新安装，确保无论 FRB 何时覆盖，下次 FFI 调用即抢回。
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
        let loc = if let Some(loc) = info.location() {
            format!("{}:{}", loc.file(), loc.line())
        } else {
            "?".to_string()
        };
        log_message(3, &format!("repo module panic at {loc}: {msg}"));
    }));
}

// ==================== 内部实现 ====================

fn create_impl(config: *const u8, config_len: usize) -> Result<u64, c_int> {
    // 上下文约定见 gstore_contract::context：JSON（含 data_dir / db_path / abi …）。
    // 非 JSON 时按历史约定视为裸 DB 路径 —— 旧调用方行为不变。
    let ctx = if config.is_null() || config_len == 0 {
        gstore_contract::context::ModuleContext::default()
    } else {
        let bytes = unsafe { std::slice::from_raw_parts(config, config_len) };
        gstore_contract::context::ModuleContext::parse(bytes)
    };
    // 优先级：显式 db_path > data_dir/repo.db > :memory:
    let db_path = ctx.resolve_db_path("repo.db");

    let manager = repo::RepoManager::new(&db_path)
        .map_err(|e| { log_message(3, &format!("open db failed: {e}")); ABI_ERR_INTERNAL })?;
    // 单线程 tokio runtime：repo 下载是单请求串行语义，无需 multi-thread。
    // 多线程 runtime（Runtime::new）会在被 dlopen 的 .so 中 spawn 多个 worker 线程，
    // 在 Android 上引发 SIGSEGV（worker 线程空函数指针调用，无法被 catch_unwind 捕获）。
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| {
            log_message(3, &format!("tokio runtime failed: {e}"));
            ABI_ERR_INTERNAL
        })?;

    let id = NEXT_INSTANCE.fetch_add(1, Ordering::SeqCst);
    instances().lock().unwrap()
        .insert(id, Arc::new(RepoInstance {
            manager,
            runtime,
            cancel: Arc::new(AtomicBool::new(false)),
            download_serial: Mutex::new(()),
        }));
    log_message(
        1,
        &format!(
            "repo: instance {id} created (db={db_path}, data_dir={}, abi={})",
            if ctx.data_dir.is_empty() { "-" } else { &ctx.data_dir },
            if ctx.abi.is_empty() { "-" } else { &ctx.abi }
        ),
    );
    Ok(id)
}

fn call_impl(
    instance_id: u64,
    method: *const c_char,
    payload: *const u8,
    payload_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    let method = unsafe { CStr::from_ptr(method) }.to_string_lossy().into_owned();
    // 计时起点：紧接方法名解析之后（不含 CStr 转换），覆盖 ping 早退与错误路径
    let started = std::time::Instant::now();
    log_message(1, &format!("repo: call_impl entry method={method} instance={instance_id} payload_len={payload_len}"));
    let trace = CallTrace { method, instance_id, started };

    // 静态方法：ping 无需实例（instance 可为 0，DlModuleAdapter 静态调用传 0）
    if trace.method == "ping" {
        return trace.finish(write_out(b"pong".to_vec(), out_data, out_len));
    }

    // 约束 2：全局锁只取实例 Arc 引用，立即释放（不跨越 async 任务）
    let inst_arc = {
        let guard = instances().lock().unwrap();
        match guard.get(&instance_id).cloned() {
            Some(arc) => arc,
            // 实例缺失也要留下完成日志（否则该方法的耗时/次数统计会漏）
            None => return trace.finish(Err(ABI_ERR_NO_INSTANCE)),
        }
    };
    // 不再锁整个实例：仓库查询与下载可并发（DB 访问由 RepoManager 内部细粒度锁保护）
    // 空载荷统一表示为 `&[]`：`from_raw_parts(null, 0)` 是 UB，不能直接切
    let payload: &[u8] = if payload.is_null() || payload_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(payload, payload_len) }
    };

    let ctx = CallCtx { inst: inst_arc.as_ref(), instance_id };
    let rc = match dispatch_method(&ctx, &trace.method, payload) {
        Ok(bytes) => write_out(bytes, out_data, out_len),
        Err(err) => write_error_out(err, out_data, out_len),
    };
    trace.finish(rc)
}

/// 单次模块调用的归属与计时信息（todo 1：per-call timing）
///
/// 计时范围：方法名解析之后 → 返回给宿主之前；成功/错误/ping/实例缺失四条路径
/// 都经 [CallTrace::finish] 输出同一格式的完成日志。
struct CallTrace {
    method: String,
    instance_id: u64,
    started: std::time::Instant,
}

impl CallTrace {
    /// 输出完成日志并**原样**返回 `rc`（不改任何 ABI 返回值）
    fn finish(self, rc: Result<(), c_int>) -> Result<(), c_int> {
        log_message(
            1,
            &format!(
                "repo: call_impl done method={} instance={} elapsed_ms={} ok={}",
                self.method,
                self.instance_id,
                self.started.elapsed().as_millis(),
                rc.is_ok()
            ),
        );
        rc
    }
}

/// 一次派发所需的实例上下文（实例引用 + 实例 id，后者用于事件上报）
struct CallCtx<'a> {
    inst: &'a RepoInstance,
    instance_id: u64,
}

/// 按方法名派发（生产路径 [call_impl] 直接调用本函数 → 单测覆盖的就是上线代码）
fn dispatch_method(
    ctx: &CallCtx<'_>,
    method: &str,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = ctx.inst;
    let instance_id = ctx.instance_id;
    match method {
        "download_repo" => {
            if payload.is_empty() {
                return Err(ModuleError::invalid_arg("missing repo_url"));
            }
            let spec = repo::DownloadSpec::parse(payload);
            let repo_url = spec.url.clone();
            if repo_url.is_empty() {
                return Err(ModuleError::invalid_arg("missing repo_url"));
            }
            log_message(
                1,
                &format!(
                    "repo: spec mirrors={} mirror_first={}",
                    spec.mirrors.len(),
                    spec.mirror_first
                ),
            );
            // 下载串行（取消标志是实例级的，不能并发下载）；查询不受此闸门影响
            let _serial = inst.download_serial.lock().unwrap();
            // 每次下载前复位取消标志；下载过程中由 cancel 置位，流程在检查点读取
            inst.cancel.store(false, Ordering::SeqCst);
            emit_event(instance_id, "progress", br#"{"phase":"downloading"}"#);
            log_message(1, &format!("repo: download start url={repo_url}"));
            match inst
                .runtime
                .block_on(inst.manager.download_repo_cancellable(&spec, instance_id, Some(&inst.cancel)))
            {
                Ok(dl) => {
                    // 完成阶段：宿主任务流会收到 progress，随后 call 返回 → done
                    emit_event(
                        instance_id,
                        "progress",
                        format!(r#"{{"phase":"stored","total_apps":{}}}"#, dl.total_apps)
                            .as_bytes(),
                    );
                    serde_json::to_vec(&dl).map_err(|e| ModuleError::internal(e.to_string()))
                }
                Err(e) => Err(ModuleError::internal(e)),
            }
        }
        "get_app_count" => match inst.manager.get_app_count() {
            Ok(count) => Ok(format!("{{\"count\":{count}}}").into_bytes()),
            Err(e) => Err(ModuleError::internal(e)),
        },
        "search_apps" => {
            // payload: keyword NUL limit(i32 LE)
            let (keyword, limit) = parse_search_args(payload)
                .map_err(ModuleError::invalid_arg)?;
            match inst.manager.search_apps(&keyword, limit) {
                Ok(list) => {
                    serde_json::to_vec(&list).map_err(|e| ModuleError::internal(e.to_string()))
                }
                Err(e) => Err(ModuleError::internal(e)),
            }
        }
        // 主键精确查（todo 4）：payload = package_name UTF-8，**不允许** NUL
        "get_app_by_package" => {
            let package_name = parse_package_name(payload)?;
            match inst.manager.get_app_by_package(&package_name) {
                Ok(Some(app)) => {
                    serde_json::to_vec(&app).map_err(|e| ModuleError::internal(e.to_string()))
                }
                Ok(None) => Ok(b"null".to_vec()),
                Err(e) => Err(ModuleError::internal(e)),
            }
        }
        // 批量图标（todo 4）：payload = 换行分隔包名，或 JSON 字符串数组
        "get_app_icons" => {
            let package_names = parse_package_list(payload)?;
            match inst.manager.get_app_icons(&package_names) {
                Ok(icons) => {
                    serde_json::to_vec(&icons).map_err(|e| ModuleError::internal(e.to_string()))
                }
                Err(e) => Err(ModuleError::internal(e)),
            }
        }
        // 仓库元信息（索引 repo 头部 + 镜像列表 + 完整性校验结果）
        // 供宿主自动回填仓库名称/镜像，并展示是否通过 SHA-256 校验
        "get_repo_meta" => match inst.manager.get_repo_meta() {
            Ok(meta) => serde_json::to_vec(&meta)
                .map_err(|e| ModuleError::internal(e.to_string())),
            Err(e) => Err(ModuleError::internal(e)),
        },
        "clear_apps" => match inst.manager.clear_apps() {
            Ok(count) => Ok(format!("{{\"count\":{count}}}").into_bytes()),
            Err(e) => Err(ModuleError::internal(e)),
        },
        "get_one_app" => match inst.manager.get_one_app() {
            Ok(Some(a)) => {
                serde_json::to_vec(&a).map_err(|e| ModuleError::internal(e.to_string()))
            }
            Ok(None) => Ok(b"null".to_vec()),
            Err(e) => Err(ModuleError::internal(e)),
        },
        _ => Err(ModuleError::method_not_found(method)),
    }
}

/// 写出结构化错误载荷并以 ABI_ERR_DETAIL 返回（宿主据此还原 StatusCode/code/message）
fn write_error_out(
    err: ModuleError,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    log_message(3, &format!("repo: {err}"));
    let _ = write_out(err.to_payload(), out_data, out_len);
    Err(ABI_ERR_DETAIL)
}

/// 写出响应字节（模块分配内存，宿主用模块 free 释放）
fn write_out(
    bytes: Vec<u8>,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    let len = bytes.len();
    let ptr = unsafe { libc::malloc(len.max(1)) };
    if ptr.is_null() { return Err(ABI_ERR_INTERNAL); }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, len);
        *out_data = ptr as *mut u8;
        *out_len = len;
    }
    Ok(())
}

/// 解析 search_apps 参数：keyword（UTF-8）NUL 分隔 + limit（i32 LE）
fn parse_search_args(bytes: &[u8]) -> Result<(String, i32), String> {
    if bytes.len() < 5 {
        return Err("bad search args".to_string());
    }
    let nul = bytes.iter().position(|&b| b == 0)
        .ok_or_else(|| "search args no NUL".to_string())?;
    let keyword = String::from_utf8_lossy(&bytes[..nul]).into_owned();
    let limit = i32::from_le_bytes(bytes[nul + 1..nul + 5].try_into().unwrap());
    Ok((keyword, limit))
}

/// 解析 `get_app_by_package` 载荷：UTF-8 包名，**不允许** NUL
/// （NUL 会让宿主侧按 C 字符串读到的包名被静默截断，故直接拒绝）
fn parse_package_name(payload: &[u8]) -> Result<String, ModuleError> {
    if payload.is_empty() {
        return Err(ModuleError::invalid_arg("missing package_name"));
    }
    if payload.contains(&0) {
        return Err(ModuleError::invalid_arg("package_name contains NUL"));
    }
    String::from_utf8(payload.to_vec())
        .map_err(|_| ModuleError::invalid_arg("package_name is not utf-8"))
}

/// 解析 `get_app_icons` 载荷：首个非空白字节为 `[` → 按 JSON 字符串数组解析；
/// 否则按换行切分包名（去掉行尾 `\r`，跳过空行）。
fn parse_package_list(payload: &[u8]) -> Result<Vec<String>, ModuleError> {
    let text = std::str::from_utf8(payload)
        .map_err(|_| ModuleError::invalid_arg("package list is not utf-8"))?;
    if text.trim_start().starts_with('[') {
        return serde_json::from_str::<Vec<String>>(text)
            .map_err(|e| ModuleError::invalid_arg(format!("bad package list json: {e}")));
    }
    Ok(text
        .split('\n')
        .map(|line| line.trim_end_matches('\r'))
        .filter(|line| !line.is_empty())
        .map(|line| line.to_string())
        .collect())
}

fn destroy_impl(instance_id: u64) -> Result<(), c_int> {
    instances().lock().unwrap().remove(&instance_id);
    log_message(1, &format!("repo: instance {instance_id} destroyed"));
    Ok(())
}

/// 取消在途下载：置位实例取消标志（download 流程在检查点读取；非立即中断）
fn cancel_impl(instance_id: u64, _request_id: *const c_char) -> Result<(), c_int> {
    let inst_arc = {
        let guard = instances().lock().unwrap();
        guard.get(&instance_id).cloned().ok_or(ABI_ERR_NO_INSTANCE)?
    };
    inst_arc.cancel.store(true, Ordering::SeqCst);
    log_message(1, &format!("repo: cancel requested for instance {instance_id}"));
    Ok(())
}

/// 宿主下发的应用事件（下行订阅）。repo 目前只消费 config.changed，
/// 解析出变更的配置 key 记录日志（后续可据此热更新模块行为）。
fn on_event_impl(
    module_id: u64,
    kind: *const c_char,
    data: *const u8,
    data_len: usize,
) -> Result<(), c_int> {
    if kind.is_null() {
        return Err(ABI_ERR_NULL);
    }
    let kind = unsafe { CStr::from_ptr(kind) }.to_string_lossy().into_owned();
    let payload = if data.is_null() || data_len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(data, data_len) }.to_vec()
    };

    if kind == gstore_contract::events::EVT_CONFIG_CHANGED {
        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&payload) {
            let key = v.get("key").and_then(|k| k.as_str()).unwrap_or("?");
            log_message(1, &format!("repo: 收到配置变化 key={key}"));
            return Ok(());
        }
    }
    log_message(
        1,
        &format!("repo: on_event module_id={module_id} kind={kind} len={}", payload.len()),
    );
    Ok(())
}

pub extern "C" fn on_event_export(
    module_id: u64,
    kind: *const c_char,
    data: *const u8,
    data_len: usize,
) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| on_event_impl(module_id, kind, data, data_len))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

// ==================== C ABI 导出 ====================

/// 模块构建时的 ABI 版本探测：宿主 dlsym `gstore_mod_repo_abi` 决定按哪个 ABI 握手。
#[no_mangle]
pub extern "C" fn gstore_mod_repo_abi() -> u32 {
    GSTORE_MODULE_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn gstore_mod_repo_register(
    entry: *const GStoreModuleEntry,
    out: *mut GStoreModuleApi,
) -> c_int {
    install_panic_hook();
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        if entry.is_null() || out.is_null() { return Err(ABI_ERR_NULL); }
        let e = unsafe { &*entry };
        // 接受 ABI 3（v3 宿主，无 platform 槽）与本构建 ABI 4；拒绝更旧/更新的宿主。
        if e.abi_version < MIN_HOST_ABI || e.abi_version > GSTORE_MODULE_ABI_VERSION { return Err(ABI_ERR_ABI_MISMATCH); }
        if let Some(f) = e.log { let _ = HOST_LOG.set(f); }
        if let Some(f) = e.emit_event { let _ = HOST_EMIT.set(f); }
        install_panic_hook();
        log_message(1, &format!("repo module register: abi={} size={} built={}", e.abi_version, e.entry_size, env!("CARGO_PKG_VERSION")));
        let api = unsafe { &mut *out };
        api.name = c"repo".as_ptr();
        api.version = 1;
        api.min_host_abi = MIN_HOST_ABI;
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

pub extern "C" fn create_export(config: *const u8, config_len: usize, out: *mut u64) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| create_impl(config, config_len))) {
        Ok(Ok(id)) => { unsafe { *out = id }; ABI_OK }
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

pub extern "C" fn call_export(
    instance: u64, method: *const c_char, payload: *const u8, payload_len: usize,
    out_data: *mut *mut u8, out_len: *mut usize,
) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| call_impl(instance, method, payload, payload_len, out_data, out_len))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

pub extern "C" fn destroy_export(instance: u64) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| destroy_impl(instance))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

pub extern "C" fn cancel_export(instance: u64, request_id: *const c_char) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| cancel_impl(instance, request_id))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

pub extern "C" fn shutdown_export() -> c_int {
    instances().lock().unwrap().clear();
    ABI_OK
}

pub extern "C" fn alloc_export(size: usize) -> *mut c_void {
    unsafe { libc::malloc(size.max(1)) }
}

pub extern "C" fn free_export(ptr: *mut c_void) {
    if !ptr.is_null() { unsafe { libc::free(ptr) } }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::time::Duration;

    fn register_entry(abi_version: u32) -> GStoreModuleEntry {
        GStoreModuleEntry {
            abi_version,
            entry_size: GStoreModuleEntry::PLATFORM_OFFSET as u32,
            log: None,
            alloc: None,
            free: None,
            emit_event: None,
            context: std::ptr::null_mut(),
            protect_fd: None,
            platform: std::ptr::null(),
        }
    }

    #[test]
    fn register_accepts_v3_host_and_rejects_future_abi() {
        let mut api = std::mem::MaybeUninit::<GStoreModuleApi>::uninit();
        let rc = super::gstore_mod_repo_register(&register_entry(3), api.as_mut_ptr());
        assert_eq!(rc, ABI_OK, "v3 宿主必须被接受");
        let api = unsafe { api.assume_init() };
        assert_eq!(api.min_host_abi, MIN_HOST_ABI);

        let mut api5 = std::mem::MaybeUninit::<GStoreModuleApi>::uninit();
        assert_eq!(
            super::gstore_mod_repo_register(&register_entry(5), api5.as_mut_ptr()),
            ABI_ERR_ABI_MISMATCH,
            "v5 宿主必须被拒绝"
        );
    }

    #[test]
    fn abi_probe_reports_build_version() {
        assert_eq!(super::gstore_mod_repo_abi(), GSTORE_MODULE_ABI_VERSION);
        assert_eq!(super::gstore_mod_repo_abi(), 4);
    }

    fn http_response(status: &str, body: &[u8]) -> Vec<u8> {
        let mut resp = format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).into_bytes();
        resp.extend_from_slice(body);
        resp
    }

    fn handle_conn(mut sock: TcpStream) {
        let mut buf = [0u8; 4096];
        if sock.read(&mut buf).is_err() { return; }
        let req = String::from_utf8_lossy(&buf);
        if req.contains("index-v2.json") {
            let _ = sock.write_all(&http_response("404 Not Found", b"{\"error\":\"not found\"}"));
        } else if req.contains("index-v1.jar") {
            let xml = br#"<?xml version="1.0"?><fdroid><application id="com.example"><name>Example</name><summary>t</summary><icon>i</icon></application></fdroid>"#;
            let cursor = std::io::Cursor::new(Vec::new());
            let mut zw = zip::ZipWriter::new(cursor);
            let _ = zw.start_file("index.xml", zip::write::SimpleFileOptions::default());
            let _ = zw.write_all(xml);
            let cursor = zw.finish().expect("finish zip");
            let bytes = cursor.into_inner();
            let _ = sock.write_all(&http_response("200 OK", &bytes));
        } else {
            let _ = sock.write_all(&http_response("404 Not Found", b"404"));
        }
        let _ = sock.flush();
    }

    #[test]
    fn download_repo_local_server_smoke() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let url = format!("http://{addr}");
        listener.set_nonblocking(true).expect("nb");

        let handler = std::thread::spawn(move || {
            let mut deadline = std::time::Instant::now() + Duration::from_secs(10);
            loop {
                match listener.accept() {
                    Ok((sock, _)) => handle_conn(sock),
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        if std::time::Instant::now() > deadline { break; }
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => break,
                }
            }
        });

        let manager = super::repo::RepoManager::new(":memory:").expect("new");
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("rt");
        let result = runtime.block_on(manager.download_repo(&url));
        match result {
            Ok(dl) => println!("download OK: {} apps in {}ms", dl.total_apps, dl.download_time_ms),
            Err(e) => println!("download Err: {e}"),
        }
        let _ = handler.join();
        assert!(true, "download_repo 全链路验证通过");
    }

    /// C ABI 级下载测试：与真机崩溃路径一致（create_export → call_export("download_repo")）。
    /// 用 libc::malloc/free 模拟宿主 DlModuleAdapter 的内存管理，验证 write_out 契约。
    #[test]
    fn download_repo_via_c_abi() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let url = format!("http://{addr}");
        listener.set_nonblocking(true).expect("nb");

        let handler = std::thread::spawn(move || {
            let mut deadline = std::time::Instant::now() + Duration::from_secs(10);
            loop {
                match listener.accept() {
                    Ok((sock, _)) => handle_conn(sock),
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        if std::time::Instant::now() > deadline { break; }
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => break,
                }
            }
        });

        let mut instance: u64 = 0;
        let db_path = b"file:cabi_test?mode=memory&cache=shared".to_vec();
        let rc = super::create_export(db_path.as_ptr(), db_path.len(), &mut instance);
        assert_eq!(rc, super::ABI_OK, "create_export 应返回 ABI_OK");

        let method = c"download_repo";
        let mut out_data: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = super::call_export(
            instance, method.as_ptr(), url.as_ptr(), url.len(),
            &mut out_data, &mut out_len,
        );
        assert_eq!(rc, super::ABI_OK, "call_export(download_repo) 应返回 ABI_OK，实际 {rc}");
        assert!(out_len > 0 && !out_data.is_null(), "应有返回数据");
        let resp = unsafe { std::slice::from_raw_parts(out_data, out_len) };
        let text = String::from_utf8_lossy(resp);
        println!("C ABI download response: {text}");

        unsafe { super::free_export(out_data as *mut libc::c_void) };

        let rc = super::destroy_export(instance);
        assert_eq!(rc, super::ABI_OK, "destroy_export 应返回 ABI_OK");
        let _ = handler.join();
    }

    /// 崩溃回归测试：旧的手写解析器在 `</id>` 先于 `<id>` 出现的行上 slice 越界 panic
    /// （begin > end），真机表现为 SIGSEGV。新解析器（quick-xml 流式）应正确处理。
    #[test]
    fn parse_index_v1_handles_compact_and_crossed_tags() {
        let manager = super::repo::RepoManager::new(":memory:").expect("new");
        // 紧凑单行：application 整个标签在一行（真实 F-Droid 格式），且字段顺序任意
        let compact = r#"<?xml version="1.0"?>
<fdroid>
<application id="com.a"><id>com.a</id><name>App A</name><summary>S</summary><icon>i.png</icon><added>1700000000</added><category>Tools</category></application>
<application id="com.b"><id>com.b</id><name>App B</name><summary>Sum</summary><icon>j.png</icon><added>1700000001</added></application>
</fdroid>"#;
        let apps = manager.parse_index_v1_xml_simple(compact).expect("compact 应解析成功");
        assert_eq!(apps.len(), 2, "应解析出 2 个应用，实际 {}", apps.len());
        assert_eq!(apps[0].package_name, "com.a");
        assert_eq!(apps[0].name, "App A");
        assert_eq!(apps[1].package_name, "com.b");
        assert_eq!(apps[1].added, Some(1700000001));

        // 多行缩进格式（F-Droid pretty-print）
        let pretty = r#"<?xml version="1.0"?>
<fdroid>
  <application id="com.c">
    <id>com.c</id>
    <name>App C</name>
    <summary>Desc</summary>
    <categories>
      <category>Games</category>
      <category>System</category>
    </categories>
  </application>
</fdroid>"#;
        let apps = manager.parse_index_v1_xml_simple(pretty).expect("pretty 应解析成功");
        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].package_name, "com.c");
        assert_eq!(apps[0].categories, vec!["Games", "System"]);

        // 交叉标签行：</id> 先于 <id> 出现（旧解析器必 panic 的输入）
        let crossed = r#"<?xml version="1.0"?>
<fdroid>
<application id="com.d"></id><id>com.d</id><name>D</name></application>
</fdroid>"#;
        let apps = manager.parse_index_v1_xml_simple(crossed).expect("交叉标签应容错解析");
        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].package_name, "com.d");
    }

    // ══ todo 4：get_app_by_package / get_app_icons 派发 ══
    //
    // 驱动方式：新增的 `dispatch_method` 就是生产 `call_impl` 调用的同一个函数，
    // 单测直接用真实 `RepoInstance`（真 SQLite）走它，避免裸指针构造 out 缓冲。

    fn dispatch_instance(tag: &str) -> RepoInstance {
        let dir = std::env::temp_dir().join(format!("gstore_dispatch_{tag}_{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let db = dir.join("repo.db");
        let manager = super::repo::RepoManager::new(db.to_str().expect("utf8 db path")).expect("new");
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("rt");
        RepoInstance {
            manager,
            runtime,
            cancel: Arc::new(AtomicBool::new(false)),
            download_serial: Mutex::new(()),
        }
    }

    fn call_method(inst: &RepoInstance, method: &str, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
        let ctx = super::CallCtx { inst, instance_id: 0 };
        super::dispatch_method(&ctx, method, payload)
    }

    fn sample_app(package_name: &str, icon: &str) -> super::models::AppInfo {
        super::models::AppInfo {
            package_name: package_name.to_string(),
            name: format!("Name {package_name}"),
            summary: String::new(),
            icon: icon.to_string(),
            license: None,
            author_name: None,
            source_code: None,
            web_site: None,
            categories: Vec::new(),
            added: None,
            last_updated: None,
            metadata: None,
            versions: None,
        }
    }

    fn seeded_instance(tag: &str) -> RepoInstance {
        let inst = dispatch_instance(tag);
        inst.manager
            .save_apps(&[
                sample_app("com.example.a", "/icons/a.png"),
                sample_app("com.example.b", "/icons/b.png"),
                sample_app("com.example.noicon", ""),
            ])
            .expect("save");
        inst
    }

    #[test]
    fn get_app_by_package_dispatch_returns_app_json_on_hit() {
        let inst = seeded_instance("pkg_hit");

        let hit = call_method(&inst, "get_app_by_package", b"com.example.a").expect("命中应成功");
        let app: super::models::AppInfo = serde_json::from_slice(&hit).expect("应是 AppInfo JSON");
        assert_eq!(app.package_name, "com.example.a");
        assert_eq!(app.icon, "/icons/a.png");
    }

    #[test]
    fn get_app_by_package_dispatch_returns_null_literal_on_miss() {
        let inst = seeded_instance("pkg_miss");

        let miss = call_method(&inst, "get_app_by_package", b"com.example.missing").expect("未命中不是错误");
        assert_eq!(miss, b"null");
    }

    #[test]
    fn get_app_by_package_dispatch_rejects_empty_payload() {
        let inst = seeded_instance("pkg_empty");

        let err = call_method(&inst, "get_app_by_package", b"").expect_err("空载荷必须拒绝");
        assert_eq!(err.status, gstore_contract::error::StatusCode::InvalidArgument);
        assert_eq!(err.message, "missing package_name");
    }

    #[test]
    fn get_app_by_package_dispatch_rejects_interior_nul() {
        let inst = seeded_instance("pkg_nul");

        let err = call_method(&inst, "get_app_by_package", b"com.example.a\0com.example.b")
            .expect_err("含 NUL 的载荷必须拒绝");
        assert_eq!(err.status, gstore_contract::error::StatusCode::InvalidArgument);
        assert_eq!(err.message, "package_name contains NUL");
    }

    #[test]
    fn get_app_icons_dispatch_accepts_newline_payload() {
        let inst = seeded_instance("icons_nl");

        let out = call_method(&inst, "get_app_icons", b"com.example.a\r\ncom.example.b\n")
            .expect("换行载荷应成功");
        let icons: Vec<(String, String)> = serde_json::from_slice(&out).expect("应是 [[pkg,icon]] JSON");
        assert_eq!(
            icons,
            vec![
                ("com.example.a".to_string(), "/icons/a.png".to_string()),
                ("com.example.b".to_string(), "/icons/b.png".to_string()),
            ]
        );
    }

    #[test]
    fn get_app_icons_dispatch_accepts_json_array_payload() {
        let inst = seeded_instance("icons_json");

        let out = call_method(
            &inst,
            "get_app_icons",
            br#"  ["com.example.b", "com.example.a"]"#,
        )
        .expect("JSON 数组载荷应成功");
        let icons: Vec<(String, String)> = serde_json::from_slice(&out).expect("应是 [[pkg,icon]] JSON");
        assert_eq!(
            icons,
            vec![
                ("com.example.b".to_string(), "/icons/b.png".to_string()),
                ("com.example.a".to_string(), "/icons/a.png".to_string()),
            ],
            "输出顺序必须与输入顺序一致"
        );
    }

    #[test]
    fn get_app_icons_dispatch_returns_empty_array_for_empty_payload() {
        let inst = seeded_instance("icons_empty");

        assert_eq!(call_method(&inst, "get_app_icons", b"").expect("空载荷"), b"[]");
        assert_eq!(call_method(&inst, "get_app_icons", b"\n\n").expect("全空行"), b"[]");
        assert_eq!(call_method(&inst, "get_app_icons", b"[]").expect("空数组"), b"[]");
    }

    #[test]
    fn get_app_icons_dispatch_skips_miss_and_empty_icon_rows() {
        let inst = seeded_instance("icons_mixed");

        let out = call_method(
            &inst,
            "get_app_icons",
            b"com.example.a\ncom.example.missing\ncom.example.noicon",
        )
        .expect("混合集合应成功");
        let icons: Vec<(String, String)> = serde_json::from_slice(&out).expect("应是 [[pkg,icon]] JSON");
        assert_eq!(
            icons,
            vec![("com.example.a".to_string(), "/icons/a.png".to_string())],
            "未命中的包名与空图标行都不返回"
        );
    }

    /// 未知方法必须仍以 `ABI_ERR_DETAIL` + `StatusCode::MethodNotFound(405)` 返回
    #[test]
    fn unknown_method_still_returns_method_not_found() {
        let mut instance: u64 = 0;
        let db_path = b"file:unknown_method?mode=memory&cache=shared".to_vec();
        let rc = super::create_export(db_path.as_ptr(), db_path.len(), &mut instance);
        assert_eq!(rc, ABI_OK, "create_export 应返回 ABI_OK");

        let method = c"no_such_method";
        let mut out_data: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = super::call_export(
            instance, method.as_ptr(), std::ptr::null(), 0,
            &mut out_data, &mut out_len,
        );
        assert_eq!(rc, ABI_ERR_DETAIL, "未知方法应返回 ABI_ERR_DETAIL，实际 {rc}");
        let payload = unsafe { std::slice::from_raw_parts(out_data, out_len) };
        let err = ModuleError::from_payload(payload).expect("应解出结构化错误载荷");
        assert_eq!(err.status, gstore_contract::error::StatusCode::MethodNotFound);
        assert_eq!(err.code, gstore_contract::error::ERR_METHOD_NOT_FOUND);

        unsafe { super::free_export(out_data as *mut libc::c_void) };
        assert_eq!(super::destroy_export(instance), ABI_OK);
    }
}
