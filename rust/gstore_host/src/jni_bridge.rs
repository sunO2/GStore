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

use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Mutex, OnceLock};

use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::time::{Duration, Instant};

use jni::objects::{GlobalRef, JObject, JString, JValue};
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
