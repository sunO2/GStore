// 宿主 JNI 桥：Kotlin `ProxyVpnService` ↔ Rust。
//
// 这是 gstore_host 的第一个 JNI 接口。Android 上 VpnService.protect(int) 是防
// 路由环路的唯一手段（不用 addDisallowedApplication），而它只能由持有
// `VpnService` 实例的 Kotlin 侧调用；因此 Kotlin 在服务建立时把自身引用交给
// 宿主，宿主缓存 `JavaVM` + 服务 `GlobalRef`，并通过 Todo 3 的 ABI v3
// `protect_fd` seam（`dl_adapter::set_socket_protector`）把每次出站 socket 的
// 保护请求转成 JNI `VpnService.protect(fd)`。
//
// ## fd 所有权规则（钉死，Todo 6 必须遵守）
// - Kotlin 持有 `ParcelFileDescriptor`；**不** `detachFd`，只把 `pfd.fd` 的原始
//   整数交给 Rust。
// - Rust 只读该 fd：如需独立生命周期必须自行 `dup()`，并设置 `O_NONBLOCK`；
//   **永远不 close Kotlin 的 fd**。
// - 拆除顺序：模块停止读取循环 → 线程 join → 宿主 `nativeClear` → Kotlin 关闭
//   `ParcelFileDescriptor`。宿主只在 `nativeClear` 里清缓存，不触碰 fd。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, RwLock};

use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::time::{Duration, Instant};

use jni::objects::{GlobalRef, JObject, JObjectArray, JString, JValue};
use jni::{JNIEnv, JavaVM};

/// protect 回调返回值：0 = 已保护 / 无需保护（无 VPN 时放行），非 0 = 失败。
/// 与 Todo 3 的 `socket_protect_stub`（返回 0）约定一致，模块据此把非 0 当错误。
const PROTECT_OK: c_int = 0;
const PROTECT_ERR: c_int = -1;

/// 进程内唯一的 `JavaVM`（首次 `nativeSetService` 时缓存；重启服务不复用旧 VM）。
static JVM: OnceLock<JavaVM> = OnceLock::new();

/// 当前 `VpnService` 实例的全局引用（`nativeClear` 置空）。`GlobalRef` 保证对象
/// 不被 GC，跨线程安全。
static SERVICE: Mutex<Option<GlobalRef>> = Mutex::new(None);

/// 最近一次 `nativeSetTunFd` 收到的 TUN fd（-1 = 无）。Todo 6 的 TUN 读取循环
/// 通过 [`current_tun_fd`] 取用；本 todo 只负责接收与记录。
static TUN_FD: AtomicI32 = AtomicI32::new(-1);

/// 无服务时的空保护实现（`nativeClear` 还原到此；返回 0 = 放行）。
extern "C" fn no_protect(_fd: c_int) -> c_int {
    PROTECT_OK
}

/// ABI v3 `protect_fd` 的真实实现：把 fd 交给 `VpnService.protect(int)`。
///
/// 无 VM / 无服务时返回 0（当前没有隧道，放行）；`protect` 返回 false 或 JNI
/// 调用失败时返回 -1。任何失败都只记录日志，绝不让进程 panic（release 下
/// `panic = "abort"`，一次 panic 会杀掉整个 App）。
extern "C" fn vpn_protect_fd(fd: c_int) -> c_int {
    if fd < 0 {
        return PROTECT_ERR;
    }
    let Some(jvm) = JVM.get() else {
        return PROTECT_OK;
    };
    let slot = SERVICE.lock().unwrap_or_else(|e| e.into_inner());
    let Some(service) = slot.as_ref() else {
        return PROTECT_OK;
    };

    // 每个（可能未附加的）Rust 线程在调用 JNI 前显式 attach；AttachGuard drop 时
    // 自动 detach（`call_method` 期间线程保持附加）。
    let mut env = match jvm.attach_current_thread() {
        Ok(env) => env,
        Err(e) => {
            crate::log_bridge::push_host_log(3, format!("ProxyVpnService.protect: JNI attach 失败: {e}"));
            return PROTECT_ERR;
        }
    };
    let result = env.call_method(service.as_obj(), "protect", "(I)Z", &[JValue::Int(fd)]);
    match result {
        Ok(value) => match value.z() {
            Ok(true) => PROTECT_OK,
            Ok(false) => {
                crate::log_bridge::push_host_log(2, format!("ProxyVpnService.protect({fd}) 返回 false"));
                PROTECT_ERR
            }
            Err(e) => {
                crate::log_bridge::push_host_log(3, format!("ProxyVpnService.protect({fd}) 返回值非 bool: {e}"));
                PROTECT_ERR
            }
        },
        Err(e) => {
            crate::log_bridge::push_host_log(3, format!("ProxyVpnService.protect({fd}) JNI 调用失败: {e}"));
            PROTECT_ERR
        }
    }
}

/// 缓存 service 引用并安装真实 protect 实现（`nativeSetService` 的实体）。
pub(crate) fn install_service(env: &JNIEnv, service: &JObject) -> Result<(), String> {
    if service.is_null() {
        return Err("service 引用为 null".to_string());
    }
    let jvm = env
        .get_java_vm()
        .map_err(|e| format!("get_java_vm 失败: {e}"))?;
    let global = env
        .new_global_ref(service)
        .map_err(|e| format!("new_global_ref 失败: {e}"))?;

    // VM 进程内恒定：已缓存则忽略（重启服务只替换 GlobalRef，不换 VM）。
    let _ = JVM.set(jvm);
    {
        let mut slot = SERVICE.lock().unwrap_or_else(|e| e.into_inner());
        *slot = Some(global);
    }
    crate::dl_adapter::set_socket_protector(vpn_protect_fd);
    crate::log_bridge::push_host_log(
        1,
        "ProxyVpnService: 已缓存 VpnService 引用，出站 socket 保护 -> VpnService.protect".to_string(),
    );
    Ok(())
}

/// 记录 TUN fd（`nativeSetTunFd` 的实体）。fd < 0 视为非法。
/// 记录后立即尝试转发给已加载的 `proxy` 模块（`tun.set_fd`）；模块尚未挂载时
/// fd 保留在宿主，待模块注册时由 `manager` 侧补发（见 `tun_bridge`）。
pub(crate) fn set_tun_fd_impl(fd: i32) -> Result<(), String> {
    if fd < 0 {
        return Err(format!("invalid TUN fd: {fd}"));
    }
    TUN_FD.store(fd, Ordering::SeqCst);
    crate::log_bridge::push_host_log(
        1,
        format!("ProxyVpnService: 宿主收到 TUN fd={fd}（转发给 proxy 模块）"),
    );
    if !crate::tun_bridge::deliver_tun_fd_to(crate::manager::ModuleManager::global(), fd) {
        crate::log_bridge::push_host_log(
            2,
            format!("ProxyVpnService: TUN fd={fd} 暂存，待 proxy 模块挂载后补发"),
        );
    }
    Ok(())
}

/// 当前 TUN fd（-1 = 无）。Todo 6 启动读取循环时取用。
pub(crate) fn current_tun_fd() -> i32 {
    TUN_FD.load(Ordering::SeqCst)
}

/// 模块侧 `proxy.tun.released`：读取循环已停止且线程已 join，宿主可清缓存。
/// 仅当缓存的 fd 与释放的 fd 一致（或事件未携带有效 fd）时清除，避免陈旧事件
/// 误清新会话的 fd。
pub(crate) fn note_tun_released(fd: i32) {
    let current = TUN_FD.load(Ordering::SeqCst);
    if fd < 0 || current == fd {
        TUN_FD.store(-1, Ordering::SeqCst);
        crate::log_bridge::push_host_log(
            1,
            format!("ProxyVpnService: 模块已释放 TUN fd={fd}，宿主清缓存"),
        );
    }
}

/// 清空 service 引用 + TUN fd，并把 protect seam 还原为空实现
/// （`nativeClear` 的实体）。幂等；不做任何 fd close（fd 归 Kotlin）。
pub(crate) fn clear_impl() {
    {
        let mut slot = SERVICE.lock().unwrap_or_else(|e| e.into_inner());
        *slot = None;
    }
    TUN_FD.store(-1, Ordering::SeqCst);
    crate::dl_adapter::set_socket_protector(no_protect);
    crate::log_bridge::push_host_log(1, "ProxyVpnService: 已清空 service/TUN fd，protect 还原为空实现".to_string());
}

/// Bounded wait for the module's `proxy.tun.released` (emitted **after** the
/// reader thread is joined). Keeps Kotlin's `stopVpn` ordering honest:
/// stop loop → join → host clears → Kotlin closes the PFD.
const STOP_JOIN_TIMEOUT: Duration = Duration::from_millis(800);

/// Kotlin `VpnService` lifecycle event → structured `proxy.state` for the UI.
///
/// `revoked` uses the pre-existing `PROXY_PERMISSION_DENIED` contract code;
/// `start_failed` uses `PROXY_ENGINE_START_FAILED`; `network_changed` is a
/// non-error notification (the datapath keeps running, Kotlin rebuilt the
/// default interface). Emitted with module id 0 (host-originated) so the Dart
/// `proxy.`-prefix filter still sees it.
pub(crate) fn vpn_event_impl(kind: &str, detail: &str) {
    let (state, mode, reason, code) = match kind {
        "revoked" => ("stopped", "off", "vpn_revoked", "PROXY_PERMISSION_DENIED"),
        "start_failed" => (
            "stopped",
            "off",
            "vpn_start_failed",
            "PROXY_ENGINE_START_FAILED",
        ),
        "network_changed" => ("running", "vpn", "network_changed", ""),
        _ => ("running", "vpn", "vpn_event", ""),
    };
    let message = if detail.is_empty() {
        kind.to_string()
    } else {
        detail.to_string()
    };
    crate::log_bridge::push_host_log(
        if code.is_empty() { 1 } else { 3 },
        format!("ProxyVpnService: {kind}: {message}"),
    );
    let mut payload = serde_json::json!({
        "state": state,
        "mode": mode,
        "reason": reason,
        "source": "kotlin",
    });
    if !code.is_empty() {
        payload["error"] = serde_json::json!({ "code": code, "message": message });
    }
    if let Ok(bytes) = serde_json::to_vec(&payload) {
        crate::event_bridge::push_event(0, 0, "proxy.state", bytes);
    }
}

/// Kotlin-initiated teardown (`nativeStopTunnel`). Asks the mounted `proxy`
/// module to stop its TUN loop, waits — bounded — for `proxy.tun.released`
/// (host clears the fd only after the reader thread joins), then clears the
/// host service/fd/protect state. Fully idempotent; never blocks longer than
/// [`STOP_JOIN_TIMEOUT`].
pub(crate) fn stop_tunnel_impl() {
    let mgr = crate::manager::ModuleManager::global();
    let mounted = mgr.module_id_by_name(crate::tun_bridge::PROXY_MODULE).is_some();
    if mounted {
        mgr.broadcast_event("vpn.stop", b"{}");
        if current_tun_fd() >= 0 {
            let deadline = Instant::now() + STOP_JOIN_TIMEOUT;
            while current_tun_fd() >= 0 && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(10));
            }
            if current_tun_fd() >= 0 {
                crate::log_bridge::push_host_log(
                    2,
                    format!(
                        "ProxyVpnService: proxy.tun.released 等待超时（{}ms）；Rust 持有 dup，Kotlin 可安全关闭",
                        STOP_JOIN_TIMEOUT.as_millis()
                    ),
                );
            }
        }
    }
    clear_impl();
}

fn jstring_to_string(env: &mut JNIEnv, value: &JString) -> String {
    if value.is_null() {
        return String::new();
    }
    env.get_string(value)
        .map(|s| s.into())
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// UID / package resolution（模块 `proxy.uid.query` → 宿主 → Kotlin VpnService）
// ---------------------------------------------------------------------------
//
// 查询发生在**流建立之后**（模块在 `record_open` 后异步发起），因此短命流可能
// 在宿主向 `ConnectivityManager.getConnectionOwnerUid` 查询时已被拆除——这是
// 设计上接受的 late-query 覆盖缺口，本路径为 **best-effort**：查不到一律
// `uid=None`（`unknown`），绝不因此报错、重试或 panic。
//
// 与 protect 桥同一降级策略：无 `JavaVM` / 无 service `GlobalRef` /
// `queryOwnerUid` 方法缺失 / 任何 JNI 失败都只记日志并返回 unknown。

/// 一次 UID 解析请求，镜像模块 `proxy.uid.query` 的线形状
/// `{recordId, protocol, srcIp, srcPort, dstIp, dstPort}`。
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UidQueryHost {
    pub record_id: u64,
    /// `"tcp"` | `"udp"`（当前采集仅产生 TCP）。
    pub protocol: String,
    pub src_ip: String,
    pub src_port: u16,
    pub dst_ip: String,
    pub dst_port: u16,
}

/// 解析结果，镜像 `{recordId, uid, packages}`。`uid == None` 即 `unknown`
/// （无 VM / 无服务 / 方法缺失 / SDK<29 / 异常 / 未命中）。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UidAnswer {
    pub record_id: u64,
    pub uid: Option<u32>,
    pub packages: Vec<String>,
}

/// `queryOwnerUid(Int, String, Int, String, Int): Int` 的 JVM 签名。
const QUERY_OWNER_UID: &str = "queryOwnerUid";
const UID_QUERY_SIG: &str = "(ILjava/lang/String;ILjava/lang/String;I)I";
/// `packagesForUid(Int): Array<String>` 的 JVM 签名。
const PACKAGES_FOR_UID: &str = "packagesForUid";
const PACKAGES_SIG: &str = "(I)[Ljava/lang/String;";

/// JNI UID 通道可用性。抽成纯值，使三种 no-op 降级路径在无 JVM 的测试主机上
/// 仍可被完整覆盖。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum UidChannelStatus {
    /// 未缓存 `JavaVM`。
    NoVm,
    /// 有 VM 但服务对象已清空（`nativeClear` 之后）。
    NoService,
    /// 有服务对象但其类上没有 `queryOwnerUid`（旧 APK）。
    MethodMissing,
    /// 可调用。
    Available,
}

impl UidChannelStatus {
    /// 供运行时诊断直接打印的稳定标签（勿改字面值：日志判定依赖）。
    pub(crate) fn label(self) -> &'static str {
        match self {
            UidChannelStatus::NoVm => "NoVm",
            UidChannelStatus::NoService => "NoService",
            UidChannelStatus::MethodMissing => "MethodMissing",
            UidChannelStatus::Available => "Available",
        }
    }
}

type UidStatusFn = fn() -> UidChannelStatus;
static UID_STATUS: RwLock<UidStatusFn> = RwLock::new(platform_uid_status);

fn current_uid_status() -> UidChannelStatus {
    UID_STATUS.read().unwrap_or_else(|e| e.into_inner())()
}

#[cfg(test)]
fn set_uid_status_for_tests(f: UidStatusFn) {
    *UID_STATUS.write().unwrap_or_else(|e| e.into_inner()) = f;
}

/// 探测真实 JNI 通道状态：无 VM → `NoVm`；无服务 → `NoService`；服务类上无
/// `queryOwnerUid` → `MethodMissing`；否则 `Available`。绝不 panic。
fn platform_uid_status() -> UidChannelStatus {
    let Some(jvm) = JVM.get() else {
        return UidChannelStatus::NoVm;
    };
    let slot = SERVICE.lock().unwrap_or_else(|e| e.into_inner());
    let Some(service) = slot.as_ref() else {
        return UidChannelStatus::NoService;
    };
    let Ok(mut env) = jvm.attach_current_thread() else {
        return UidChannelStatus::NoService;
    };
    let Ok(class) = env.get_object_class(service.as_obj()) else {
        return UidChannelStatus::MethodMissing;
    };
    match env.get_method_id(&class, QUERY_OWNER_UID, UID_QUERY_SIG) {
        Ok(_) => UidChannelStatus::Available,
        Err(e) => {
            crate::log_bridge::push_host_log(
                2,
                format!("ProxyVpnService.queryOwnerUid 不可用: {e}"),
            );
            UidChannelStatus::MethodMissing
        }
    }
}

/// 批量解析请求的属主 uid 与包名。
///
/// 无 VM / 无服务 / 方法缺失 / 非法请求 → `UidAnswer { uid: None, packages: [] }`
/// （`unknown`），绝不 panic；返回顺序与入参一致。
pub fn resolve_uids(reqs: &[UidQueryHost]) -> Vec<UidAnswer> {
    let status = current_uid_status();
    log_uid_channel_once(status);
    let answers: Vec<UidAnswer> = reqs.iter().map(|q| answer_for(status, q)).collect();
    log_uid_summary(status, &answers);
    answers
}

/// uid 通道状态每个进程只记一次，供用户在「日志查看器」直接判读（无需调试器）。
/// `MethodMissing` 通常意味着随包 `libgstore_host.so` 过旧 / 装有旧 APK；`NoService`
/// 意味着 VPN 服务未连接；只有 `Available` 才可能真正解析出 uid。
static UID_STATUS_LOGGED: AtomicBool = AtomicBool::new(false);

fn log_uid_channel_once(status: UidChannelStatus) {
    if UID_STATUS_LOGGED.swap(true, Ordering::SeqCst) {
        return;
    }
    let level = if status == UidChannelStatus::Available {
        1
    } else {
        2
    };
    crate::log_bridge::push_host_log(
        level,
        format!(
            "uid 通道状态={}（Available 才能解析；MethodMissing=宿主 .so 过旧/旧 APK；\
             NoService=VPN 服务未连接；NoVm=JVM 未缓存）",
            status.label()
        ),
    );
}

/// 解析批次计数节流窗口：至多每 30s 汇总一次，避免随流量刷屏。
const UID_SUMMARY_WINDOW_MS: u64 = 30_000;
static UID_LAST_SUMMARY_MS: AtomicU64 = AtomicU64::new(0);

fn log_uid_summary(status: UidChannelStatus, answers: &[UidAnswer]) {
    if answers.is_empty() {
        return;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let last = UID_LAST_SUMMARY_MS.load(Ordering::SeqCst);
    if last != 0 && now.saturating_sub(last) < UID_SUMMARY_WINDOW_MS {
        return;
    }
    UID_LAST_SUMMARY_MS.store(now, Ordering::SeqCst);
    let known = answers.iter().filter(|a| a.uid.is_some()).count();
    let unknown = answers.len() - known;
    crate::log_bridge::push_host_log(
        1,
        format!(
            "uid 解析批次: known={known} unknown={unknown} 通道={}",
            status.label()
        ),
    );
}

#[cfg(test)]
fn reset_uid_diag_for_tests() {
    UID_STATUS_LOGGED.store(false, Ordering::SeqCst);
    UID_LAST_SUMMARY_MS.store(0, Ordering::SeqCst);
}


fn answer_for(status: UidChannelStatus, q: &UidQueryHost) -> UidAnswer {
    let unknown = UidAnswer {
        record_id: q.record_id,
        uid: None,
        packages: Vec::new(),
    };
    if status != UidChannelStatus::Available || !is_queryable(q) {
        return unknown;
    }
    match owner_uid_fn()(q) {
        Some(uid) => UidAnswer {
            record_id: q.record_id,
            uid: Some(uid),
            packages: packages_cached(uid),
        },
        None => unknown,
    }
}

/// 请求是否具备发起 `getConnectionOwnerUid` 的必要字段（纯函数，主机可测）。
fn is_queryable(q: &UidQueryHost) -> bool {
    !q.src_ip.is_empty() && !q.dst_ip.is_empty() && protocol_number(&q.protocol).is_some()
}

/// 线协议字符串 → Java `IPPROTO_*` 值。未知协议返回 `None`（`is_queryable`
/// 据此降级为 `unknown`）。
fn protocol_number(protocol: &str) -> Option<i32> {
    match protocol {
        "tcp" => Some(6),
        "udp" => Some(17),
        _ => None,
    }
}

/// Kotlin 原始 uid → 可选 uid；`-1`（`Process.INVALID_UID`）及其它负值归 unknown。
fn valid_uid(raw: i32) -> Option<u32> {
    if raw < 0 {
        None
    } else {
        Some(raw as u32)
    }
}

/// 原始属主 uid 探针（生产实现 = JNI [`query_owner_uid_jni`]）。抽成可替换函数
/// 指针，使「已知 uid」装配路径可在无 JVM 的测试主机上被验证。
type OwnerUidFn = fn(&UidQueryHost) -> Option<u32>;
static OWNER_UID_FN: RwLock<OwnerUidFn> = RwLock::new(query_owner_uid_jni);

fn owner_uid_fn() -> OwnerUidFn {
    *OWNER_UID_FN.read().unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
fn set_owner_uid_fn_for_tests(f: OwnerUidFn) {
    *OWNER_UID_FN.write().unwrap_or_else(|e| e.into_inner()) = f;
}

/// 调用 Kotlin `queryOwnerUid`。无 VM / 无服务 / attach 失败 / 调用失败 / 非法
/// 返回值一律 `None`（不 panic、不重试）。
fn query_owner_uid_jni(q: &UidQueryHost) -> Option<u32> {
    let protocol = protocol_number(&q.protocol)?;
    let jvm = JVM.get()?;
    let slot = SERVICE.lock().unwrap_or_else(|e| e.into_inner());
    let service = slot.as_ref()?;
    let mut env = jvm.attach_current_thread().ok()?;
    let src = env.new_string(q.src_ip.as_str()).ok()?;
    let dst = env.new_string(q.dst_ip.as_str()).ok()?;
    let args = [
        JValue::Int(protocol),
        JValue::Object(&src),
        JValue::Int(q.src_port as i32),
        JValue::Object(&dst),
        JValue::Int(q.dst_port as i32),
    ];
    match env.call_method(service.as_obj(), QUERY_OWNER_UID, UID_QUERY_SIG, &args) {
        Ok(value) => valid_uid(value.i().ok()?),
        Err(e) => {
            crate::log_bridge::push_host_log(
                2,
                format!("ProxyVpnService.queryOwnerUid JNI 失败: {e}"),
            );
            None
        }
    }
}

/// `uid → packages` 长活缓存条目。
struct CachedPackages {
    packages: Vec<String>,
    fetched_at: Instant,
}

/// 缓存上限（按最旧淘汰，防 uid 集合无界增长）。
const PACKAGES_CACHE_CAP: usize = 512;
/// 兜底 TTL：即使漏掉一次包变更广播，条目也会过期后重取。
const PACKAGES_CACHE_TTL: Duration = Duration::from_secs(600);

static PACKAGES_CACHE: OnceLock<Mutex<HashMap<u32, CachedPackages>>> = OnceLock::new();

type PackagesFn = fn(u32) -> Vec<String>;
static PACKAGES_FN: RwLock<PackagesFn> = RwLock::new(jni_packages_for_uid);

fn packages_fn() -> PackagesFn {
    *PACKAGES_FN.read().unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
fn set_packages_fn_for_tests(f: PackagesFn) {
    *PACKAGES_FN.write().unwrap_or_else(|e| e.into_inner()) = f;
}

fn packages_cache() -> &'static Mutex<HashMap<u32, CachedPackages>> {
    PACKAGES_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 取（并缓存）某 uid 的包名。命中且未过期直接返回；否则查询并写回。
fn packages_cached(uid: u32) -> Vec<String> {
    let now = Instant::now();
    {
        let mut cache = packages_cache().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(entry) = cache.get(&uid) {
            if now.duration_since(entry.fetched_at) < PACKAGES_CACHE_TTL {
                return entry.packages.clone();
            }
            cache.remove(&uid);
        }
    }
    let packages = packages_fn()(uid);
    let mut cache = packages_cache().lock().unwrap_or_else(|e| e.into_inner());
    if cache.len() >= PACKAGES_CACHE_CAP {
        if let Some(oldest) = cache
            .iter()
            .min_by_key(|(_, entry)| entry.fetched_at)
            .map(|(key, _)| *key)
        {
            cache.remove(&oldest);
        }
    }
    cache.insert(
        uid,
        CachedPackages {
            packages: packages.clone(),
            fetched_at: now,
        },
    );
    packages
}

/// 包变更（Kotlin `nativePackageChanged`）时整体失效 `uid → packages` 缓存。
pub(crate) fn invalidate_package_cache() {
    packages_cache()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
}

/// 调用 Kotlin `packagesForUid`。任何失败（无 VM / 无服务 / 方法缺失 / 异常）
/// → 空列表，绝不 panic。
fn jni_packages_for_uid(uid: u32) -> Vec<String> {
    let Some(jvm) = JVM.get() else {
        return Vec::new();
    };
    let slot = SERVICE.lock().unwrap_or_else(|e| e.into_inner());
    let Some(service) = slot.as_ref() else {
        return Vec::new();
    };
    let Ok(mut env) = jvm.attach_current_thread() else {
        return Vec::new();
    };
    let value = match env.call_method(
        service.as_obj(),
        PACKAGES_FOR_UID,
        PACKAGES_SIG,
        &[JValue::Int(uid as i32)],
    ) {
        Ok(v) => v,
        Err(e) => {
            crate::log_bridge::push_host_log(
                2,
                format!("ProxyVpnService.packagesForUid JNI 失败: {e}"),
            );
            return Vec::new();
        }
    };
    let Ok(obj) = value.l() else {
        return Vec::new();
    };
    let array = JObjectArray::from(obj);
    let Ok(len) = env.get_array_length(&array) else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(len.max(0) as usize);
    for i in 0..len {
        let Ok(element) = env.get_object_array_element(&array, i) else {
            continue;
        };
        let name: JString = element.into();
        let parsed: Result<String, _> = env.get_string(&name).map(|s| s.into());
        if let Ok(s) = parsed {
            out.push(s);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// JNI 导出（Kotlin `ProxyVpnService.companion` 的 @JvmStatic external fun）
// ---------------------------------------------------------------------------

/// 把 JNI 导出体包进 `catch_unwind`：panic 绝不越过 `extern "system"` 边界
/// （未捕获的 unwind 跨 FFI 是 UB）。与模块 ABI 同策略，panic 时记一条日志并返回
/// 安全默认值；release 构建仍以 `panic = "abort"` 兜底。
fn guard_jni<F: FnOnce()>(export: &str, body: F) {
    if catch_unwind(AssertUnwindSafe(body)).is_err() {
        crate::log_bridge::push_host_log(
            3,
            format!("{export}: JNI 边界捕获 panic（已返回安全默认值）"),
        );
    }
}

/// Kotlin: `nativeSetService(service: VpnService)`（静态方法）。
#[no_mangle]
pub extern "system" fn Java_com_suno2_gstore_ProxyVpnService_nativeSetService(
    env: JNIEnv,
    _class: JObject,
    service: JObject,
) {
    guard_jni("nativeSetService", || {
        if let Err(e) = install_service(&env, &service) {
            crate::log_bridge::push_host_log(3, format!("nativeSetService 失败: {e}"));
        }
    });
}

/// Kotlin: `nativeSetTunFd(fd: Int)`（静态方法）。
#[no_mangle]
pub extern "system" fn Java_com_suno2_gstore_ProxyVpnService_nativeSetTunFd(
    _env: JNIEnv,
    _class: JObject,
    fd: jni::sys::jint,
) {
    guard_jni("nativeSetTunFd", || {
        if let Err(e) = set_tun_fd_impl(fd) {
            crate::log_bridge::push_host_log(3, format!("nativeSetTunFd 失败: {e}"));
        }
    });
}

/// Kotlin: `nativeClear()`（静态方法）。拆除时由 Kotlin 调用；调用方随后自行
/// 关闭 `ParcelFileDescriptor`。
#[no_mangle]
pub extern "system" fn Java_com_suno2_gstore_ProxyVpnService_nativeClear(
    _env: JNIEnv,
    _class: JObject,
) {
    guard_jni("nativeClear", clear_impl);
}

/// Kotlin: `nativeVpnEvent(kind: String, detail: String)`（静态方法）。上报
/// `onRevoke` / 网络切换 / 启动失败等生命周期事件，宿主转成结构化 `proxy.state`。
#[no_mangle]
pub extern "system" fn Java_com_suno2_gstore_ProxyVpnService_nativeVpnEvent(
    mut env: JNIEnv,
    _class: JObject,
    kind: JString,
    detail: JString,
) {
    guard_jni("nativeVpnEvent", || {
        let kind = jstring_to_string(&mut env, &kind);
        let detail = jstring_to_string(&mut env, &detail);
        vpn_event_impl(&kind, &detail);
    });
}

/// Kotlin: `nativeStopTunnel()`（静态方法）。Kotlin 主动拆除（用户停止 /
/// `onRevoke` / `onDestroy`）时调用；按「停循环 → join → 宿主清缓存 → Kotlin
/// 关 fd」顺序执行，有界等待。
#[no_mangle]
pub extern "system" fn Java_com_suno2_gstore_ProxyVpnService_nativeStopTunnel(
    _env: JNIEnv,
    _class: JObject,
) {
    guard_jni("nativeStopTunnel", stop_tunnel_impl);
}

/// Kotlin: `nativePackageChanged()`（静态方法）。系统包增删/替换广播到达时调用，
/// 使宿主 `uid → packages` 缓存整体失效，避免共享 uid 的包名列表陈旧。
#[no_mangle]
pub extern "system" fn Java_com_suno2_gstore_ProxyVpnService_nativePackageChanged(
    _env: JNIEnv,
    _class: JObject,
) {
    guard_jni("nativePackageChanged", invalidate_package_cache);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// TUN fd 状态机：非法值拒绝、往返、clear 复位。
    #[test]
    fn tun_fd_roundtrip_and_clear() {
        let _g = crate::TEST_SERIAL.lock().unwrap();
        clear_impl();
        assert_eq!(current_tun_fd(), -1);
        assert!(set_tun_fd_impl(-1).is_err(), "负 fd 必须拒绝");
        set_tun_fd_impl(4321).expect("合法 fd");
        assert_eq!(current_tun_fd(), 4321);
        clear_impl();
        assert_eq!(current_tun_fd(), -1);
    }

    /// 无 VM / 无服务时 protect 直接放行（0），不 attempt JNI、不 panic。
    #[test]
    fn protect_without_service_is_noop_success() {
        let _g = crate::TEST_SERIAL.lock().unwrap();
        clear_impl();
        assert_eq!(vpn_protect_fd(7), PROTECT_OK);
        assert_eq!(vpn_protect_fd(-1), PROTECT_ERR, "负 fd 视为失败");
    }

    /// clear 幂等（可重复调用，无副作用/无 panic）。
    #[test]
    fn clear_is_idempotent() {
        let _g = crate::TEST_SERIAL.lock().unwrap();
        clear_impl();
        clear_impl();
        assert_eq!(current_tun_fd(), -1);
    }

    /// Regression (F2): a panic inside a JNI export body is caught at the
    /// boundary and logged, never unwinding into Kotlin.
    #[test]
    fn jni_guard_catches_panic_and_logs() {
        let _g = crate::TEST_SERIAL.lock().unwrap();
        crate::log_bridge::clear_for_tests();
        guard_jni("nativeRegression", || panic!("boom from JNI body"));
        assert!(
            crate::log_bridge::buffered_for_tests()
                .iter()
                .any(|m| m.level == 3 && m.message.contains("nativeRegression")),
            "a panic at the JNI boundary must be logged"
        );
    }

    /// Fake `proxy` module: records down-events and simulates releasing the TUN
    /// fd once its reader has joined (on `vpn.stop`).
    struct RecordingProxy {
        events: Arc<Mutex<Vec<String>>>,
    }

    impl crate::manager::GStoreModule for RecordingProxy {
        fn name(&self) -> &'static str {
            "proxy"
        }
        fn create(
            &self,
            _config: &[u8],
        ) -> Result<u64, gstore_contract::error::ModuleError> {
            Ok(1)
        }
        fn call(
            &self,
            _instance: Option<u64>,
            method: &str,
            _payload: &[u8],
        ) -> Result<Vec<u8>, gstore_contract::error::ModuleError> {
            if method == "tun.set_fd" {
                return Ok(br#"{"ok":true,"data":{"nonblocking":true}}"#.to_vec());
            }
            Err(gstore_contract::error::ModuleError::method_not_found(method))
        }
        fn on_event(
            &self,
            _module_id: u64,
            kind: &str,
            _data: &[u8],
        ) -> Result<(), gstore_contract::error::ModuleError> {
            self.events
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(kind.to_string());
            if kind == "vpn.stop" {
                let fd = current_tun_fd();
                if fd >= 0 {
                    note_tun_released(fd);
                }
            }
            Ok(())
        }
        fn destroy(&self, _instance: u64) -> Result<(), gstore_contract::error::ModuleError> {
            Ok(())
        }
    }

    #[test]
    fn vpn_event_emits_structured_proxy_state() {
        let _g = crate::TEST_SERIAL
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        crate::event_bridge::clear_buffer_for_tests();
        clear_impl();
        vpn_event_impl("revoked", "VPN permission revoked by another app");
        let (event_type, data) = crate::event_bridge::last_event_for_tests().expect("event emitted");
        assert_eq!(event_type, "proxy.state");
        let v: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(v["reason"], "vpn_revoked");
        assert_eq!(v["error"]["code"], "PROXY_PERMISSION_DENIED");
        assert!(v["error"]["message"]
            .as_str()
            .unwrap_or("")
            .contains("revoked"));
    }

    #[test]
    fn start_failure_is_structured_and_network_change_is_not_an_error() {
        let _g = crate::TEST_SERIAL
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        clear_impl();
        vpn_event_impl("start_failed", "establish() returned null");
        let (_, data) = crate::event_bridge::last_event_for_tests().unwrap();
        let v: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(v["error"]["code"], "PROXY_ENGINE_START_FAILED");
        assert_eq!(v["state"], "stopped");

        vpn_event_impl("network_changed", "wlan0 -> rmnet0");
        let (_, data) = crate::event_bridge::last_event_for_tests().unwrap();
        let v: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(v["reason"], "network_changed");
        assert!(v.get("error").is_none(), "network change is not an error");
        assert_eq!(v["state"], "running");
    }

    #[test]
    fn stop_tunnel_broadcasts_vpn_stop_waits_for_release_and_clears() {
        let _g = crate::TEST_SERIAL
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        clear_impl();
        let mgr = crate::manager::ModuleManager::global();
        assert!(mgr.module_id_by_name("proxy").is_none(), "must start clean");
        let events = Arc::new(Mutex::new(Vec::new()));
        let id = mgr.register(Arc::new(RecordingProxy {
            events: events.clone(),
        }));

        set_tun_fd_impl(314).unwrap();
        assert_eq!(current_tun_fd(), 314);

        let started = Instant::now();
        stop_tunnel_impl();
        assert_eq!(current_tun_fd(), -1, "host clears the fd after release");
        assert!(
            started.elapsed() < STOP_JOIN_TIMEOUT,
            "must return via the release path, not the timeout"
        );
        assert_eq!(&*events.lock().unwrap_or_else(|e| e.into_inner()), &["vpn.stop".to_string()]);

        mgr.unref(id);
        clear_impl();
    }
}

#[cfg(test)]
mod uid_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn query(record_id: u64) -> UidQueryHost {
        UidQueryHost {
            record_id,
            protocol: "tcp".to_string(),
            src_ip: "10.10.0.2".to_string(),
            src_port: 40_000,
            dst_ip: "93.184.216.34".to_string(),
            dst_port: 443,
        }
    }

    /// Scenario 1 — no `JavaVM` cached. The Linux test host never installs one, so
    /// this exercises the real production path. The whole batch must degrade to
    /// all-unknown without panicking (release builds are `panic = "abort"`).
    #[test]
    fn no_vm_yields_all_unknown_without_panicking() {
        let _g = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        clear_impl();
        let reqs = vec![query(1), query(2)];
        let answers = resolve_uids(&reqs);
        assert_eq!(answers.len(), 2);
        assert!(
            answers.iter().all(|a| a.uid.is_none() && a.packages.is_empty()),
            "no VM must answer unknown for every request"
        );
        assert_eq!(
            answers.iter().map(|a| a.record_id).collect::<Vec<_>>(),
            vec![1, 2],
            "answers must preserve the request order and record ids"
        );
    }

    /// Scenario 2 — VM cached but `nativeClear` ran (no service `GlobalRef`).
    #[test]
    fn no_service_global_ref_yields_all_unknown() {
        let _g = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        set_uid_status_for_tests(|| UidChannelStatus::NoService);
        let answers = resolve_uids(&[query(11), query(12)]);
        set_uid_status_for_tests(platform_uid_status);
        assert!(
            answers.iter().all(|a| a.uid.is_none() && a.packages.is_empty()),
            "missing service GlobalRef must answer unknown"
        );
    }

    /// Scenario 3 — service cached but the installed APK predates
    /// `queryOwnerUid` (method lookup fails). Must answer unknown, never panic.
    #[test]
    fn missing_query_owner_uid_method_yields_all_unknown() {
        let _g = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        set_uid_status_for_tests(|| UidChannelStatus::MethodMissing);
        let answers = resolve_uids(&[query(21)]);
        set_uid_status_for_tests(platform_uid_status);
        assert!(
            answers.iter().all(|a| a.uid.is_none() && a.packages.is_empty()),
            "missing queryOwnerUid method must answer unknown"
        );
    }

    /// Malformed queries are rejected host-side before any JNI call.
    #[test]
    fn malformed_queries_are_not_queryable() {
        let mut blank_dst = query(1);
        blank_dst.dst_ip = String::new();
        assert!(!is_queryable(&blank_dst), "blank destination IP");

        let mut blank_src = query(2);
        blank_src.src_ip = String::new();
        assert!(!is_queryable(&blank_src), "blank source IP");

        let mut bad_protocol = query(3);
        bad_protocol.protocol = "icmp".to_string();
        assert!(!is_queryable(&bad_protocol), "unsupported protocol");

        let mut zero_ports = query(4);
        zero_ports.src_port = 0;
        zero_ports.dst_port = 0;
        assert!(is_queryable(&zero_ports), "port 0 is legal and must pass");

        assert!(is_queryable(&query(5)), "well-formed query");
    }

    /// `INVALID_UID` (-1) from Kotlin maps to `None`; real uids are preserved.
    #[test]
    fn invalid_uid_maps_to_unknown() {
        assert_eq!(valid_uid(-1), None);
        assert_eq!(valid_uid(0), Some(0));
        assert_eq!(valid_uid(10_123), Some(10_123));
    }

    /// An empty batch is a no-op (no JNI, no panic, empty result).
    #[test]
    fn empty_batch_is_a_noop() {
        let _g = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        assert!(resolve_uids(&[]).is_empty());
    }

    /// Success assembly: a resolved uid is returned with its packages, and the
    /// record id is preserved. The real JNI probe is device-only; this stubs the
    /// probe to lock the host-side assembly + cache integration.
    #[test]
    fn known_uid_is_assembled_with_packages() {
        let _g = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        fn found_uid(_q: &UidQueryHost) -> Option<u32> {
            Some(10_123)
        }
        fn found_packages(uid: u32) -> Vec<String> {
            vec![format!("com.example.{uid}"), "com.shared.uid".to_string()]
        }
        set_uid_status_for_tests(|| UidChannelStatus::Available);
        set_owner_uid_fn_for_tests(found_uid);
        set_packages_fn_for_tests(found_packages);
        invalidate_package_cache();

        let answers = resolve_uids(&[query(99)]);
        set_uid_status_for_tests(platform_uid_status);
        set_owner_uid_fn_for_tests(query_owner_uid_jni);
        set_packages_fn_for_tests(jni_packages_for_uid);
        invalidate_package_cache();

        assert_eq!(answers.len(), 1);
        assert_eq!(answers[0].record_id, 99);
        assert_eq!(answers[0].uid, Some(10_123));
        assert_eq!(
            answers[0].packages,
            vec!["com.example.10123".to_string(), "com.shared.uid".to_string()]
        );
    }

    /// A second lookup for the same uid is served from cache; a package-change
    /// invalidation forces exactly one refetch.
    #[test]
    fn package_cache_hits_then_invalidates_on_package_change() {
        let _g = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        static FETCHES: AtomicUsize = AtomicUsize::new(0);
        fn fake_packages(uid: u32) -> Vec<String> {
            FETCHES.fetch_add(1, Ordering::SeqCst);
            vec![format!("com.example.{uid}")]
        }

        invalidate_package_cache();
        set_packages_fn_for_tests(fake_packages);

        let first = packages_cached(10_123);
        let second = packages_cached(10_123);
        assert_eq!(first, vec!["com.example.10123".to_string()]);
        assert_eq!(second, first, "cache hit returns the same packages");
        assert_eq!(FETCHES.load(Ordering::SeqCst), 1, "cache hit must not refetch");

        invalidate_package_cache();
        let third = packages_cached(10_123);
        assert_eq!(third, first);
        assert_eq!(FETCHES.load(Ordering::SeqCst), 2, "invalidation forces one refetch");

        set_packages_fn_for_tests(jni_packages_for_uid);
        invalidate_package_cache();
    }

    /// Runtime-diagnostic regression: resolving a batch must log (a) the channel
    /// status once and (b) a known/unknown count summary, so the user can read the
    /// verdict in the log viewer without a debugger.
    #[test]
    fn uid_resolution_logs_channel_status_and_batch_counts() {
        let _g = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_uid_diag_for_tests();
        set_uid_status_for_tests(|| UidChannelStatus::MethodMissing);

        let answers = resolve_uids(&[query(41), query(42)]);

        set_uid_status_for_tests(platform_uid_status);
        assert!(answers.iter().all(|a| a.uid.is_none()), "non-Available => unknown");

        let logs = crate::log_bridge::buffered_for_tests();
        assert!(
            logs.iter()
                .any(|m| m.message.contains("uid 通道状态=MethodMissing")),
            "the once-per-session channel status must be logged, got: {:?}",
            logs.iter().map(|m| &m.message).collect::<Vec<_>>()
        );
        assert!(
            logs.iter().any(|m| m.message.contains("known=0 unknown=2")),
            "the throttled batch summary must be logged"
        );
    }
}
