//! gstore_mod_proxy — Android cross-compile spike for the meow-rs proxy kernel.
//!
//! **This is Todo 1 of `.omo/plans/vpn-proxy-kernel.md`: a risk-first spike.**
//! Its only job is to prove that meow-rs can be consumed as *libraries* from an
//! external crate, cross-compiled for Android with the project NDK, and that the
//! netstack (lwIP) datapath is reachable **without forking meow**.
//!
//! What lives here:
//!  * [`gstore_mod_proxy_probe`] — the required `#[no_mangle]` export. It also
//!    address-takes the whole meow API surface so the Android link step really
//!    resolves meow/BoringSSL/lwIP symbols (LTO cannot drop address-taken fns).
//!  * [`bounded_runtime`] — the only runtime construction allowed in this
//!    project (`new_multi_thread().worker_threads(N <= 4)`), never
//!    `Runtime::new()` / CPU-default workers (Android SIGSEGV, see
//!    `rust/gstore_mod_repo/src/lib.rs:117-120`).
//!  * [`datapath_selftest`] — the HARD GATE: builds `meow_lwip::NetStack` on our
//!    bounded runtime and shuttles real IP frames between the stack and a real
//!    fd (a `socketpair`), both directions.
//!
//! No Dart/Flutter/FRB symbols are referenced here (module crates are pure
//! Rust cdylibs — `rust/ARCHITECTURE.md` §3.6).

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
use gstore_contract::error::{ModuleError, StatusCode};

mod dispatch;
mod dns;
mod protect;
mod rules;
mod tun;

/// Required spike export: proves the crate loads as `libgstore_mod_proxy.so`.
/// Address-taking the meow API surface inside makes the Android link step a
/// genuine proof that every entry point the real module will use resolves.
#[no_mangle]
pub extern "C" fn gstore_mod_proxy_probe() -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        meow_api_surface();
        1
    })) {
        Ok(v) => v,
        Err(_) => 0,
    }
}

/// The **only** permitted async runtime shape for GStore modules on Android.
///
/// `worker_threads` is bounded (<= 4). `Runtime::new()` uses the CPU-default
/// worker count and has been observed to SIGSEGV inside a dlopen'ed `.so` on
/// Android (see `rust/gstore_mod_repo/src/lib.rs:117-120`). A bounded
/// multi-thread runtime is the pattern already shipping in
/// `rust/gstore_mod_download/src/lib.rs:173-181`.
pub fn bounded_runtime() -> std::io::Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .thread_name("gstore-proxy")
        .build()
}

/// References every meow entry point the real module will call. The key
/// constructors are coerced to concrete `fn` pointers and passed through
/// `black_box`, which forces LTO to emit them — and therefore link the C deps
/// they pull in (lwIP for the netstack, BoringSSL for the proxy layer). The
/// remaining references guarantee the API stays public and type-checks under
/// the Android configuration. Either way, a loss of public visibility, a
/// feature-flag regression, or a C-link failure breaks the cross-compile
/// instead of surfacing at integration time.
#[inline(never)]
fn meow_api_surface() {
    let tunnel_new: fn(std::sync::Arc<meow_dns::Resolver>) -> meow_tunnel::Tunnel =
        meow_tunnel::Tunnel::new;
    std::hint::black_box(tunnel_new);
    std::hint::black_box(meow_tunnel::Tunnel::inner);
    std::hint::black_box(meow_tunnel::Tunnel::update_proxies);
    std::hint::black_box(meow_tunnel::Tunnel::update_rules);
    std::hint::black_box(meow_tunnel::tcp::handle_tcp);
    std::hint::black_box(meow_tunnel::udp::handle_udp);

    std::hint::black_box(meow_config::subscription::fetch_subscription);
    std::hint::black_box(meow_config::subscription::parse_subscription_yaml);
    std::hint::black_box(meow_config::rebuild_from_raw);

    let mixed_new: fn(meow_tunnel::Tunnel, std::net::SocketAddr, String) -> meow_listener::MixedListener =
        meow_listener::MixedListener::new;
    std::hint::black_box(mixed_new);
    std::hint::black_box(meow_listener::MixedListener::run);

    std::hint::black_box(meow_api::routes::create_router);
    std::hint::black_box(meow_api::ApiServer::run);

    let netstack_parts = || Result::<
        (meow_lwip::NetStack, meow_lwip::TcpListener, Box<meow_lwip::UdpSocket>),
        meow_lwip::Error,
    >::Ok;
    let _ = netstack_parts;
    let netstack_new: fn() -> Result<
        (meow_lwip::NetStack, meow_lwip::TcpListener, Box<meow_lwip::UdpSocket>),
        meow_lwip::Error,
    > = meow_lwip::NetStack::new;
    std::hint::black_box(netstack_new);
    let netstack_buf: fn(usize, usize) -> Result<
        (meow_lwip::NetStack, meow_lwip::TcpListener, Box<meow_lwip::UdpSocket>),
        meow_lwip::Error,
    > = meow_lwip::NetStack::with_buffer_size;
    std::hint::black_box(netstack_buf);
    std::hint::black_box(meow_lwip::NetStack::core_done);

    let resolver_slot: fn(std::sync::Arc<meow_dns::Resolver>) -> meow_dns::ResolverSlot =
        meow_dns::new_resolver_slot;
    std::hint::black_box(resolver_slot);
    std::hint::black_box(std::any::type_name::<meow_proxy::DirectAdapter>());

    // Android-only: `meow_common::set_socket_protector` / `SocketProtector` are
    // re-exported under `#[cfg(target_os = "android")]` only. This is the single
    // hook the host JNI bridge installs so *every* outbound socket (TCP/UDP/DNS/
    // libc getaddrinfo) bypasses the VPN.
    #[cfg(target_os = "android")]
    {
        use std::os::fd::RawFd;

        struct HostFdProtector;
        impl meow_common::SocketProtector for HostFdProtector {
            fn protect(&self, _fd: RawFd) -> std::io::Result<()> {
                Ok(())
            }
        }
        std::hint::black_box(&HostFdProtector as &dyn meow_common::SocketProtector);
        std::hint::black_box(meow_common::set_socket_protector);
    }
}

/// Outcome of [`datapath_selftest`], for logging/evidence.
#[derive(Debug, Clone)]
pub struct DatapathReport {
    /// `meow_lwip::NetStack::new()` succeeded on the bounded runtime.
    pub stack_built: bool,
    /// Bytes of the IP frame lwIP emitted (egress path).
    pub egress_frame_bytes: usize,
    /// IP version nibble of the emitted frame (4 for IPv4).
    pub egress_ip_version: u8,
    /// Bytes of that frame actually delivered through the real fd.
    pub fd_delivered_bytes: usize,
    /// The frame read back from the fd was accepted by the stack ingress `Sink`.
    pub ingress_accepted: bool,
    /// The `TcpListener` accept stream stayed open/pollable (flow-dispatch handle).
    pub tcp_listener_pollable: bool,
    /// TCP/UDP flow-dispatch entry points are public (compile-time proof).
    pub tcp_flow_api_public: bool,
    pub udp_flow_api_public: bool,
}

/// **HARD GATE.** Prove the Android datapath is viable without forking meow:
///
/// 1. Build `meow_lwip::NetStack` on the bounded runtime.
/// 2. Push a UDP datagram into the netstack; lwIP emits a real IP frame on the
///    egress stream.
/// 3. Write that frame to a real fd (`socketpair`); the peer receives it.
/// 4. Send the frame back through the fd, read it, and feed it to the netstack
///    ingress `Sink` (fd -> stack path).
/// 5. Poll the `TcpListener` accept stream to confirm the flow-dispatch handle
///    is alive and public.
///
/// A host `socketpair` stands in for the Android TUN fd; the same code path runs
/// on-device. All work happens inside one bounded runtime, never `Runtime::new()`.
#[cfg(unix)]
pub fn datapath_selftest() -> Result<DatapathReport, String> {
    use std::net::SocketAddr;
    use std::time::Duration;

    use futures::{SinkExt, StreamExt};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let rt = bounded_runtime().map_err(|e| format!("bounded_runtime: {e}"))?;

    rt.block_on(async {
        // A real fd pair: `fd_side` is the "TUN" endpoint our loop owns,
        // `device_side` is the kernel/peer. On device the fd comes from
        // `VpnService.establish()`; here a socketpair is equivalent.
        let (mut fd_side, mut device_side) =
            tokio::net::UnixStream::pair().map_err(|e| format!("socketpair: {e}"))?;

        // NetStack must be built *inside* a runtime (it spawns its core task).
        let (mut stack, mut tcp_listener, udp) =
            meow_lwip::NetStack::new().map_err(|e| format!("NetStack::new: {e}"))?;

        let udp_local = udp.local_addr();
        let (udp_send, _udp_recv) = udp.split();
        // Keep `_udp_recv` alive: dropping the UdpSocket removes the lwIP pcb.

        // ---- egress: std UDP call -> lwIP -> IP frame on the egress stream ----
        let src: SocketAddr = if udp_local.ip().is_unspecified() {
            "127.0.0.1:40000".parse().unwrap()
        } else {
            udp_local
        };
        let dst: SocketAddr = "8.8.8.8:53".parse().unwrap();
        udp_send
            .send_to(b"gstore-spike", &src, &dst)
            .map_err(|e| format!("UdpSocket::send_to: {e}"))?;

        let frame = tokio::time::timeout(Duration::from_secs(5), stack.next())
            .await
            .map_err(|_| "timeout waiting for egress IP frame".to_string())?
            .ok_or_else(|| "netstack egress stream closed".to_string())?
            .map_err(|e| format!("netstack egress error: {e}"))?;

        if frame.is_empty() {
            return Err("netstack emitted an empty frame".to_string());
        }
        let egress_ip_version = frame[0] >> 4;

        // ---- fd path: write the frame to the real fd, peer must receive it ----
        fd_side
            .write_all(&frame)
            .await
            .map_err(|e| format!("fd write: {e}"))?;
        fd_side.flush().await.map_err(|e| format!("fd flush: {e}"))?;

        let mut rbuf = vec![0u8; 65_536];
        let n = tokio::time::timeout(Duration::from_secs(5), device_side.read(&mut rbuf))
            .await
            .map_err(|_| "timeout reading IP frame from fd".to_string())?
            .map_err(|e| format!("fd peer read: {e}"))?;
        if rbuf[..n] != frame[..] {
            return Err(format!(
                "fd delivered {n} bytes but expected {} bytes (content mismatch)",
                frame.len()
            ));
        }

        // ---- ingress: fd -> stack (feed a real frame into the ingress Sink) ----
        device_side
            .write_all(&frame)
            .await
            .map_err(|e| format!("device write: {e}"))?;
        device_side
            .flush()
            .await
            .map_err(|e| format!("device flush: {e}"))?;

        let mut ibuf = vec![0u8; 65_536];
        let m = tokio::time::timeout(Duration::from_secs(5), fd_side.read(&mut ibuf))
            .await
            .map_err(|_| "timeout reading IP frame back from fd".to_string())?
            .map_err(|e| format!("fd read: {e}"))?;
        let ingress_accepted = stack.send(ibuf[..m].to_vec()).await.is_ok();

        // ---- flow-dispatch handles: TcpListener accept stream is alive ----
        // No inbound SYN exists, so expect the poll to time out (not close) —
        // a timely timeout proves the stream is open and pollable.
        let tcp_listener_pollable =
            tokio::time::timeout(Duration::from_millis(100), tcp_listener.next())
                .await
                .is_err();

        Ok(DatapathReport {
            stack_built: true,
            egress_frame_bytes: frame.len(),
            egress_ip_version,
            fd_delivered_bytes: n,
            ingress_accepted,
            tcp_listener_pollable,
            // Public reachability is proven by `meow_api_surface` compiling.
            tcp_flow_api_public: true,
            udp_flow_api_public: true,
        })
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn probe_is_one() {
        assert_eq!(gstore_mod_proxy_probe(), 1);
    }

    #[test]
    fn hard_gate_datapath_shuttles_packets_over_real_fd() {
        let _g = TEST_SERIAL.lock().unwrap();
        let report = datapath_selftest().expect("datapath selftest failed");
        eprintln!("datapath report: {report:?}");
        assert!(report.stack_built);
        assert!(report.egress_frame_bytes > 0, "no egress frame emitted");
        assert_eq!(report.egress_ip_version, 4, "expected an IPv4 frame");
        assert_eq!(
            report.fd_delivered_bytes, report.egress_frame_bytes,
            "fd did not deliver the full frame"
        );
        assert!(report.ingress_accepted, "netstack ingress rejected the frame");
        assert!(report.tcp_listener_pollable, "tcp accept stream closed");
        assert!(report.tcp_flow_api_public);
        assert!(report.udp_flow_api_public);
    }
}

// ==================== 模块 ABI（gstore_contract v3） ====================
//
// Todo 2：只搭出 register/create/call/cancel/destroy/shutdown/alloc/free/on_event
// 全量骨架 + `ping`/`version` 两个方法。**不 spawn 线程、不建 runtime、不碰 TUN**
// （TUN 读循环见 Todo 6，proxy runtime 见 Todo 7/29）。
// 方法/事件的完整规划见 `rust/gstore_mod_proxy/API.md`（Waves 2-3 的唯一事实来源）。

/// 模块名：宿主按 `api.name == "proxy"` 校验（`gstore_host/src/dl_adapter.rs`）。
const MODULE_NAME: &str = "proxy";

/// 模块功能版本（宿主 `module_version` 用于热更新提示）。
const MODULE_VERSION: u32 = 1;

/// 要求宿主最低 ABI：v3（`protect_fd` 槽）。
const PROXY_MIN_HOST_ABI: u32 = GSTORE_MODULE_ABI_VERSION;

/// 上游 meow-rs 精确 rev（与 Cargo.toml 的 pin 一致，经 `version` 回报诊断）。
const MEOW_REV: &str = "0e718f587442caaac00b221efc91c84907aeb0e0";

// 事件类型（宿主/Dart 侧按 `proxy.` 前缀过滤；完整清单见 API.md）
#[allow(dead_code)]
const EVT_STATE: &str = "proxy.state";
#[allow(dead_code)]
const EVT_MODE: &str = "proxy.mode";
#[allow(dead_code)]
const EVT_NODE_DELAY: &str = "proxy.node.delay";
#[allow(dead_code)]
const EVT_STATS: &str = "proxy.stats";
#[allow(dead_code)]
const EVT_SUBSCRIPTION: &str = "proxy.subscription";
/// 模块 → 宿主：TUN 读取循环已停止且线程已 join，宿主可清缓存 fd（Kotlin 可关闭）。
const EVT_TUN_RELEASED: &str = "proxy.tun.released";

/// 运行状态机（Todo 2 占位；Todo 6/29 驱动真实 start/stop）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyRunState {
    Stopped,
    Starting,
    Running,
    Stopping,
}

impl ProxyRunState {
    fn as_str(self) -> &'static str {
        match self {
            ProxyRunState::Stopped => "stopped",
            ProxyRunState::Starting => "starting",
            ProxyRunState::Running => "running",
            ProxyRunState::Stopping => "stopping",
        }
    }
}

/// 运行模式（Todo 29）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyMode {
    Off,
    Vpn,
    LanProxy,
}

impl ProxyMode {
    fn as_str(self) -> &'static str {
        match self {
            ProxyMode::Off => "off",
            ProxyMode::Vpn => "vpn",
            ProxyMode::LanProxy => "lanProxy",
        }
    }
}

/// 实例状态：Todo 2 只保存创建上下文与运行态占位。
///
/// **故意不持有 tokio runtime / 不 spawn 线程**：Todo 2 的验收只覆盖 ABI 与
/// ping/version；带线程的 datapath 由 Todo 6 引入，且必须复用
/// [`bounded_runtime`]（`worker_threads(4)`，绝不 `Runtime::new()`）。
pub struct ProxyInstance {
    pub id: u64,
    pub created_at_ms: u64,
    pub state: Mutex<ProxyRunState>,
    pub mode: Mutex<ProxyMode>,
    /// `now_ms()` when `state` last changed (drives `core.get_mode.sinceMs`).
    pub state_since_ms: Mutex<u64>,
    pub data_dir: String,
    pub cache_dir: String,
    pub abi: String,
    pub app_version: String,
    /// 宿主注入的 socket 保护服务（ABI v3，经 `entry_size` 守卫读取）。
    /// Todo 7 会包装成 meow `SocketProtector` 并在 Android 上安装。
    pub host_protect_fd: Option<extern "C" fn(c_int) -> c_int>,
}

static INSTANCES: OnceLock<Mutex<HashMap<u64, Arc<ProxyInstance>>>> = OnceLock::new();

/// 单进程单元测试共享 `INSTANCES` 与 TUN 全局态，必须串行执行。
#[cfg(test)]
pub(crate) static TEST_SERIAL: Mutex<()> = Mutex::new(());

static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);
static HOST_LOG: OnceLock<extern "C" fn(c_int, *const c_char)> = OnceLock::new();
static HOST_EMIT: OnceLock<extern "C" fn(u64, u64, *const u8, usize)> = OnceLock::new();
static HOST_ABI: OnceLock<u32> = OnceLock::new();
static HOST_PROTECT_FD: OnceLock<Option<extern "C" fn(c_int) -> c_int>> = OnceLock::new();

/// The host-injected `protect_fd` (ABI v3) captured at register time, or `None`
/// on an older host / non-VPN run. The engine installs it as meow's global
/// `SocketProtector` at init ([`protect::install`]).
pub(crate) fn host_protect_fd() -> Option<extern "C" fn(c_int) -> c_int> {
    HOST_PROTECT_FD.get().copied().flatten()
}

fn instances() -> &'static Mutex<HashMap<u64, Arc<ProxyInstance>>> {
    INSTANCES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub(crate) fn log_message(level: c_int, msg: &str) {
    if let Some(f) = HOST_LOG.get() {
        if let Ok(cmsg) = CString::new(msg) {
            f(level, cmsg.as_ptr());
        }
    }
}

/// 上报模块事件（宿主负载约定：前 4 字节为事件类型长度，小端）。
pub(crate) fn emit_event(instance_id: u64, event_type: &str, payload: &[u8]) {
    let Some(f) = HOST_EMIT.get() else { return };
    let type_bytes = event_type.as_bytes();
    let mut buf = Vec::with_capacity(4 + type_bytes.len() + payload.len());
    buf.extend_from_slice(&(type_bytes.len() as u32).to_le_bytes());
    buf.extend_from_slice(type_bytes);
    buf.extend_from_slice(payload);
    f(0, instance_id, buf.as_ptr(), buf.len());
}

/// 静默 panic hook（与 download/repo 模块同策略：避免 Android 上 backtrace
/// 符号化器把 panic 放大成 SIGSEGV）。每个 C ABI 入口都重装。
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
        log_message(3, &format!("proxy module panic at {loc}: {msg}"));
    }));
}

fn payload_bytes<'a>(payload: *const u8, len: usize) -> &'a [u8] {
    if payload.is_null() || len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(payload, len) }
    }
}

fn to_json<T: serde::Serialize>(v: &T) -> Result<Vec<u8>, ModuleError> {
    serde_json::to_vec(v).map_err(|e| ModuleError::internal(e.to_string()))
}

/// 统一成功载荷：`{ok:true,data:{...}}`（本模块 call 的 JSON 契约，见 API.md）。
fn ok_data(data: serde_json::Value) -> Result<Vec<u8>, ModuleError> {
    to_json(&serde_json::json!({ "ok": true, "data": data }))
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

/// 把结构化 `ModuleError` 写入 out 缓冲并返回 `ABI_ERR_DETAIL(-8)`：
/// 宿主据此还原 405/422 等域错误，不在 ABI 边界塌成 500。
fn write_error_out(
    err: ModuleError,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    log_message(3, &format!("proxy: {err}"));
    let _ = write_out(err.to_payload(), out_data, out_len);
    Err(ABI_ERR_DETAIL)
}

fn instance_of(id: u64) -> Result<Arc<ProxyInstance>, c_int> {
    instances()
        .lock()
        .unwrap()
        .get(&id)
        .cloned()
        .ok_or(ABI_ERR_NO_INSTANCE)
}

fn require_instance(id: u64, instance: Option<Arc<ProxyInstance>>) -> Result<Arc<ProxyInstance>, ModuleError> {
    instance.ok_or_else(|| ModuleError::instance_not_found(id))
}

fn set_state(inst: &ProxyInstance, state: ProxyRunState) {
    *inst.state.lock().unwrap_or_else(|e| e.into_inner()) = state;
    *inst.state_since_ms.lock().unwrap_or_else(|e| e.into_inner()) = now_ms();
}

fn set_mode(inst: &ProxyInstance, mode: ProxyMode) {
    *inst.mode.lock().unwrap_or_else(|e| e.into_inner()) = mode;
}

fn current_state(inst: &ProxyInstance) -> ProxyRunState {
    *inst.state.lock().unwrap_or_else(|e| e.into_inner())
}

fn current_mode(inst: &ProxyInstance) -> ProxyMode {
    *inst.mode.lock().unwrap_or_else(|e| e.into_inner())
}

fn emit_state(instance_id: u64, state: ProxyRunState, mode: ProxyMode, reason: Option<&str>) {
    let mut v = serde_json::json!({ "state": state.as_str(), "mode": mode.as_str() });
    if let Some(r) = reason {
        v["reason"] = serde_json::json!(r);
    }
    if let Ok(bytes) = serde_json::to_vec(&v) {
        emit_event(instance_id, EVT_STATE, &bytes);
    }
}

fn emit_tun_released(instance_id: u64, fd: c_int) {
    if let Ok(bytes) = serde_json::to_vec(&serde_json::json!({ "fd": fd })) {
        emit_event(instance_id, EVT_TUN_RELEASED, &bytes);
    }
}

fn parse_fd(payload: &[u8]) -> Result<c_int, ModuleError> {
    let v: serde_json::Value = serde_json::from_slice(payload)
        .map_err(|e| ModuleError::invalid_arg(format!("tun.set_fd payload must be JSON: {e}")))?;
    v.get("fd")
        .and_then(|f| f.as_i64())
        .map(|f| f as c_int)
        .ok_or_else(|| ModuleError::invalid_arg("tun.set_fd requires integer field `fd`"))
}

fn parse_mode(payload: &[u8]) -> ProxyMode {
    let v: serde_json::Value =
        serde_json::from_slice(payload).unwrap_or(serde_json::Value::Null);
    match v.get("mode").and_then(|m| m.as_str()) {
        Some("off") => ProxyMode::Off,
        Some("lanProxy") => ProxyMode::LanProxy,
        _ => ProxyMode::Vpn,
    }
}

/// `tun.set_fd`：宿主把 TUN fd 交给模块；校验 + dup + O_NONBLOCK 后暂存，
/// 真正的单读者循环由 `core.start` 启动。
fn tun_set_fd_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let fd = parse_fd(payload)?;
    let info = tun::install_fd(fd)?;
    log_message(
        1,
        &format!(
            "proxy: tun.set_fd host_fd={} nonblocking=true replacedRunning={}",
            info.host_fd, info.replaced_running
        ),
    );
    ok_data(serde_json::json!({
        "fd": info.host_fd,
        "nonblocking": true,
        "replacedRunning": info.replaced_running,
    }))
}

fn core_start_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let mode = parse_mode(payload);
    match mode {
        ProxyMode::Vpn => {
            let spawned = tun::start(inst.id)?;
            set_state(&inst, ProxyRunState::Running);
            set_mode(&inst, ProxyMode::Vpn);
            log_message(
                1,
                &format!("proxy: core.start vpn instance={} spawned={spawned}", inst.id),
            );
            emit_state(inst.id, ProxyRunState::Running, ProxyMode::Vpn, None);
            ok_data(serde_json::json!({
                "state": "running", "mode": "vpn", "instanceId": inst.id,
            }))
        }
        ProxyMode::Off => core_stop_arm(instance_id, Some(inst)),
        ProxyMode::LanProxy => Err(ModuleError::new(
            StatusCode::InvalidArgument,
            "PROXY_NO_INBOUND",
            "lanProxy inbound listener is not implemented yet (Todo 28)",
        )),
    }
}

fn core_stop_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let was_running = current_state(&inst) != ProxyRunState::Stopped;
    let stopped = tun::stop();
    set_state(&inst, ProxyRunState::Stopped);
    set_mode(&inst, ProxyMode::Off);
    if let Some(s) = &stopped {
        // Tell the host it may clear (and Kotlin may close) the fd: the reader
        // loop is stopped and its thread has been joined.
        emit_tun_released(s.instance_id, s.host_fd);
        log_message(1, &format!("proxy: core.stop instance={} fd released", inst.id));
    }
    if stopped.is_some() || was_running {
        emit_state(inst.id, ProxyRunState::Stopped, ProxyMode::Off, None);
    }
    ok_data(serde_json::json!({ "state": "stopped" }))
}

fn core_restart_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    _payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    if let Some(s) = tun::stop() {
        emit_tun_released(s.instance_id, s.host_fd);
    }
    // The previous loop consumed (and closed) our pending dup; re-duplicate the
    // last known host fd if it is still open, so restart works without a new
    // nativeSetTunFd (if Kotlin already closed it we surface PROXY_TUN_FD_INVALID).
    tun::ensure_pending_from_last()?;
    tun::start(inst.id)?;
    set_state(&inst, ProxyRunState::Running);
    set_mode(&inst, ProxyMode::Vpn);
    emit_state(inst.id, ProxyRunState::Running, ProxyMode::Vpn, Some("restart"));
    ok_data(serde_json::json!({ "state": "running", "mode": "vpn" }))
}

fn core_get_mode_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let since = *inst.state_since_ms.lock().unwrap_or_else(|e| e.into_inner());
    ok_data(serde_json::json!({
        "mode": current_mode(&inst).as_str(),
        "state": current_state(&inst).as_str(),
        "sinceMs": since,
    }))
}

fn core_set_mode_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let mode = parse_mode(payload);
    let previous = current_mode(&inst);
    match mode {
        ProxyMode::Off => {
            let stopped = tun::stop();
            set_state(&inst, ProxyRunState::Stopped);
            if let Some(s) = &stopped {
                emit_tun_released(s.instance_id, s.host_fd);
            }
        }
        ProxyMode::Vpn => {
            tun::start(inst.id)?;
            set_state(&inst, ProxyRunState::Running);
        }
        ProxyMode::LanProxy => {
            return Err(ModuleError::new(
                StatusCode::InvalidArgument,
                "PROXY_NO_INBOUND",
                "lanProxy inbound listener is not implemented yet (Todo 28)",
            ))
        }
    }
    set_mode(&inst, mode);
    let bytes = serde_json::to_vec(&serde_json::json!({
        "mode": mode.as_str(), "previous": previous.as_str(),
    }))
    .unwrap_or_default();
    emit_event(inst.id, EVT_MODE, &bytes);
    ok_data(serde_json::json!({
        "ok": true, "mode": mode.as_str(), "previous": previous.as_str(),
    }))
}

/// `dns.get`: effective DNS config plus query/cache stats and the recent
/// domain→IP mappings the Todo 16 domain-statistics path consumes.
fn dns_get_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
) -> Result<Vec<u8>, ModuleError> {
    let _inst = require_instance(instance_id, instance)?;
    let engine = dns::engine();
    let cfg = engine.as_ref().map(|e| e.config().clone()).unwrap_or_else(dns::config);
    let stats = engine
        .as_ref()
        .map(|e| e.stats_json())
        .unwrap_or_else(|| {
            serde_json::json!({
                "queries": 0, "failures": 0, "cacheEntries": 0,
                "fakeIpActive": false, "fakeIpRange": serde_json::Value::Null,
            })
        });
    let mappings = engine.as_ref().map(|e| e.mappings(64)).unwrap_or_default();
    let recent = engine.as_ref().map(|e| e.recent_records(64)).unwrap_or_default();
    ok_data(serde_json::json!({
        "mode": cfg.mode.as_str(),
        "config": cfg,
        "stats": stats,
        "mappings": mappings,
        "recentQueries": recent,
    }))
}

/// `dns.set`: merge a partial config, rebuild and install the resolver.
fn dns_set_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let _inst = require_instance(instance_id, instance)?;
    let mut cfg = dns::config();
    cfg.apply_patch(payload)?;
    let engine = dns::set_config(cfg)?;
    log_message(
        1,
        &format!(
            "proxy: dns.set mode={} nameservers={} fallback={} doh={} dot={} hijack={}",
            engine.config().mode.as_str(),
            engine.config().nameservers.len(),
            engine.config().fallback.len(),
            engine.config().doh.len(),
            engine.config().dot.len(),
            engine.config().hijack,
        ),
    );
    ok_data(serde_json::json!({ "ok": true, "config": engine.config() }))
}

/// `dns.clear_cache` / `dns.flush_cache`: drop the resolver cache and every
/// fake-IP allocation. Returns the number of forward entries flushed.
fn dns_clear_cache_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
) -> Result<Vec<u8>, ModuleError> {
    let _inst = require_instance(instance_id, instance)?;
    let flushed = dns::engine().map(|e| e.clear_cache()).unwrap_or(0);
    log_message(1, &format!("proxy: dns.clear_cache flushed={flushed}"));
    ok_data(serde_json::json!({ "ok": true, "flushed": flushed }))
}

/// `rules.get`: read-only ordered snapshot of the parsed rules, provider status
/// and geo-asset status (Todo 9).
fn rules_get_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
) -> Result<Vec<u8>, ModuleError> {
    let _inst = require_instance(instance_id, instance)?;
    ok_data(rules::snapshot())
}

/// `rules.reload`: parse a Clash config (`{config}` YAML string or
/// `{configPath}`), (re)load rule-providers and publish the compiled ruleset
/// into the tunnel. Never blocks on geo/provider downloads (Todo 9).
fn rules_reload_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let snapshot = rules::reload(&inst.data_dir, &inst.cache_dir, payload)?;
    ok_data(snapshot)
}

fn create_impl(config: *const u8, config_len: usize) -> Result<u64, c_int> {
    let ctx = ModuleContext::parse(payload_bytes(config, config_len));
    log_message(
        1,
        &format!(
            "proxy module create: data_dir={} cache_dir={} abi={} app_version={} protect_fd={}",
            ctx.data_dir,
            ctx.cache_dir,
            ctx.abi,
            ctx.app_version,
            HOST_PROTECT_FD.get().copied().flatten().is_some()
        ),
    );

    let id = NEXT_INSTANCE.fetch_add(1, Ordering::SeqCst);
    let inst = Arc::new(ProxyInstance {
        id,
        created_at_ms: now_ms(),
        state: Mutex::new(ProxyRunState::Stopped),
        mode: Mutex::new(ProxyMode::Off),
        state_since_ms: Mutex::new(now_ms()),
        data_dir: ctx.data_dir,
        cache_dir: ctx.cache_dir,
        abi: ctx.abi,
        app_version: ctx.app_version,
        host_protect_fd: HOST_PROTECT_FD.get().copied().flatten(),
    });
    instances().lock().unwrap().insert(id, inst);
    Ok(id)
}

/// 实例 `call` 分发。
///
/// 成功一律返回 `{ok:true,data:{...}}`；未知方法返回结构化
/// `METHOD_NOT_FOUND`（HTTP-405 等价），**绝不 panic**。
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
    let _payload = payload_bytes(payload, payload_len);
    let host_abi = *HOST_ABI.get().unwrap_or(&GSTORE_MODULE_ABI_VERSION);
    // 实例可选：ping/version 作为健康检查/能力查询，无实例也应答。
    let instance = instance_of(instance_id).ok();

    let result: Result<Vec<u8>, ModuleError> = match method.as_str() {
        "ping" => {
            let mut data = serde_json::json!({
                "pong": true,
                "module": MODULE_NAME,
                "moduleVersion": env!("CARGO_PKG_VERSION"),
                "apiVersion": MODULE_VERSION,
                "minHostAbi": PROXY_MIN_HOST_ABI,
                "hostAbi": host_abi,
            });
            if let Some(inst) = &instance {
                data["instanceId"] = serde_json::json!(inst.id);
                data["state"] = serde_json::json!(inst.state.lock().unwrap().as_str());
                data["mode"] = serde_json::json!(inst.mode.lock().unwrap().as_str());
                data["protectFdPresent"] = serde_json::json!(inst.host_protect_fd.is_some());
            }
            data["protectInstalled"] = serde_json::json!(protect::is_installed());
            ok_data(data)
        }
        "version" => ok_data(serde_json::json!({
            "module": MODULE_NAME,
            "moduleVersion": env!("CARGO_PKG_VERSION"),
            "apiVersion": MODULE_VERSION,
            "minHostAbi": PROXY_MIN_HOST_ABI,
            "hostAbi": host_abi,
            "meowRev": MEOW_REV,
            "targetArch": std::env::consts::ARCH,
        })),
        "tun.set_fd" => tun_set_fd_arm(_payload),
        "core.start" => core_start_arm(instance_id, instance.clone(), _payload),
        "core.stop" => core_stop_arm(instance_id, instance.clone()),
        "core.restart" => core_restart_arm(instance_id, instance.clone(), _payload),
        "core.get_mode" => core_get_mode_arm(instance_id, instance.clone()),
        "core.set_mode" => core_set_mode_arm(instance_id, instance.clone(), _payload),
        "dns.get" => dns_get_arm(instance_id, instance.clone()),
        "dns.set" => dns_set_arm(instance_id, instance.clone(), _payload),
        "dns.clear_cache" | "dns.flush_cache" => {
            dns_clear_cache_arm(instance_id, instance.clone())
        }
        "rules.get" => rules_get_arm(instance_id, instance.clone()),
        "rules.reload" => rules_reload_arm(instance_id, instance.clone(), _payload),
        other => Err(ModuleError::method_not_found(other)),
    };

    match result {
        Ok(b) => write_out(b, out_data, out_len),
        Err(e) => write_error_out(e, out_data, out_len),
    }
}

fn cancel_impl(instance_id: u64, _request_id: *const c_char) -> Result<(), c_int> {
    let _ = instance_of(instance_id)?;
    Ok(())
}

fn destroy_impl(instance_id: u64) -> Result<(), c_int> {
    if let Some(s) = tun::stop_for_instance(instance_id) {
        emit_tun_released(s.instance_id, s.host_fd);
    }
    let remaining = {
        let mut map = instances().lock().unwrap();
        map.remove(&instance_id);
        map.len()
    };
    if remaining == 0 {
        // Last instance: also drop any still-pending (unstarted) fd.
        tun::shutdown();
    }
    log_message(1, &format!("proxy: instance {instance_id} destroyed"));
    Ok(())
}

fn shutdown_impl() -> Result<(), c_int> {
    tun::shutdown();
    instances().lock().unwrap().clear();
    log_message(1, "proxy: shutdown");
    Ok(())
}

/// 宿主下行事件（ABI v2 `on_event`）。Todo 2 仅记录；Todo 8+ 订阅配置/网络变化。
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
            "proxy: on_event module_id={module_id} kind={kind_s} len={}",
            payload.len()
        ),
    );
    Ok(())
}

// ==================== C ABI 导出 ====================

#[no_mangle]
pub extern "C" fn gstore_mod_proxy_register(
    entry: *const GStoreModuleEntry,
    out: *mut GStoreModuleApi,
) -> c_int {
    install_panic_hook();
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        if entry.is_null() || out.is_null() {
            return Err(ABI_ERR_NULL);
        }
        let e = unsafe { &*entry };
        // 只拒绝更旧的宿主；末尾追加字段对更新宿主前向兼容（不做精确匹配）。
        if e.abi_version < GSTORE_MODULE_ABI_VERSION {
            return Err(ABI_ERR_ABI_MISMATCH);
        }
        let _ = HOST_ABI.set(e.abi_version);
        if let Some(f) = e.log {
            let _ = HOST_LOG.set(f);
        }
        if let Some(f) = e.emit_event {
            let _ = HOST_EMIT.set(f);
        }
        // ABI v3 槽：先按 entry_size 守卫再读，旧宿主下绝不越界。
        let _ = HOST_PROTECT_FD.set(e.protect_fd_if_present());
        log_message(
            1,
            &format!(
                "proxy module register: abi={} size={} built={}",
                e.abi_version,
                e.entry_size,
                env!("CARGO_PKG_VERSION")
            ),
        );
        let api = unsafe { &mut *out };
        api.name = c"proxy".as_ptr();
        api.version = MODULE_VERSION;
        api.min_host_abi = PROXY_MIN_HOST_ABI;
        api.init = Some(proxy_init_export);
        api.create = Some(proxy_create_export);
        api.call = Some(proxy_call_export);
        api.cancel = Some(proxy_cancel_export);
        api.destroy = Some(proxy_destroy_export);
        api.shutdown = Some(proxy_shutdown_export);
        api.alloc = Some(proxy_alloc_export);
        api.free = Some(proxy_free_export);
        api.on_event = Some(proxy_on_event_export);
        Ok(ABI_OK)
    }));
    result.unwrap_or(Err(ABI_ERR_PANIC)).unwrap_or_else(|code| code)
}

#[no_mangle]
pub extern "C" fn proxy_init_export() -> c_int {
    install_panic_hook();
    ABI_OK
}

#[no_mangle]
pub extern "C" fn proxy_create_export(config: *const u8, config_len: usize, out: *mut u64) -> c_int {
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
pub extern "C" fn proxy_call_export(
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
pub extern "C" fn proxy_cancel_export(instance: u64, request_id: *const c_char) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| cancel_impl(instance, request_id))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn proxy_destroy_export(instance: u64) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| destroy_impl(instance))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn proxy_shutdown_export() -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(shutdown_impl)) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn proxy_alloc_export(size: usize) -> *mut c_void {
    match catch_unwind(AssertUnwindSafe(|| unsafe { libc::malloc(size.max(1)) })) {
        Ok(p) => p,
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn proxy_free_export(ptr: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !ptr.is_null() {
            unsafe { libc::free(ptr) }
        }
    }));
}

#[no_mangle]
pub extern "C" fn proxy_on_event_export(
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

#[cfg(test)]
mod abi_tests {
    use super::*;
    use gstore_contract::abi::host_abi_satisfies;

    /// ping/version 是静态方法，可无实例调用；实例状态由 create 建立。
    /// 同进程内多个测试共享 INSTANCES/NEXT_INSTANCE/TUN 全局态，故用例串行执行。
    use super::TEST_SERIAL as ABI_LOCK;

    type CallFn = extern "C" fn(u64, *const c_char, *const u8, usize, *mut *mut u8, *mut usize) -> c_int;

    extern "C" fn dummy_protect(_fd: c_int) -> c_int {
        0
    }

    /// 捕获模块经 `emit_event` 上报的事件（隔离 `HOST_EMIT` 全局单次设置）。
    static EMITTED: Mutex<Vec<(String, Vec<u8>)>> = Mutex::new(Vec::new());

    extern "C" fn record_event(_module_id: u64, _instance_id: u64, data: *const u8, len: usize) {
        if data.is_null() || len < 4 {
            return;
        }
        let raw = unsafe { std::slice::from_raw_parts(data, len) };
        let tlen = u32::from_le_bytes(raw[0..4].try_into().unwrap()) as usize;
        if raw.len() < 4 + tlen {
            return;
        }
        let event_type = String::from_utf8_lossy(&raw[4..4 + tlen]).into_owned();
        let payload = raw[4 + tlen..].to_vec();
        if let Ok(mut v) = EMITTED.lock() {
            v.push((event_type, payload));
        }
    }

    fn take_events() -> Vec<(String, Vec<u8>)> {
        std::mem::take(&mut *EMITTED.lock().unwrap())
    }

    fn register_api() -> GStoreModuleApi {
        let entry = GStoreModuleEntry {
            abi_version: GSTORE_MODULE_ABI_VERSION,
            entry_size: std::mem::size_of::<GStoreModuleEntry>() as u32,
            log: None,
            alloc: None,
            free: None,
            emit_event: Some(record_event),
            context: std::ptr::null_mut(),
            protect_fd: Some(dummy_protect),
        };
        let mut api = std::mem::MaybeUninit::<GStoreModuleApi>::zeroed();
        let code = gstore_mod_proxy_register(&entry, api.as_mut_ptr());
        assert_eq!(code, ABI_OK, "register must succeed");
        unsafe { api.assume_init() }
    }

    /// 用模块的 free 释放 out 缓冲（谁分配谁释放），避免测试内二次释放。
    fn call_json(call: CallFn, inst: u64, method: &str) -> (c_int, Vec<u8>) {
        call_with_payload(call, inst, method, &[])
    }

    fn call_with_payload(call: CallFn, inst: u64, method: &str, payload: &[u8]) -> (c_int, Vec<u8>) {
        let m = CString::new(method).unwrap();
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        let code = call(
            inst,
            m.as_ptr(),
            payload.as_ptr(),
            payload.len(),
            &mut ptr,
            &mut len,
        );
        let bytes = if ptr.is_null() {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(ptr, len).to_vec() }
        };
        if !ptr.is_null() {
            proxy_free_export(ptr as *mut c_void);
        }
        (code, bytes)
    }

    #[test]
    fn register_reports_proxy_name_and_min_host_abi_3() {
        let _g = ABI_LOCK.lock().unwrap();
        let api = register_api();
        let name = unsafe { CStr::from_ptr(api.name) }.to_str().unwrap();
        assert_eq!(name, "proxy");
        assert_eq!(api.version, MODULE_VERSION);
        assert_eq!(api.min_host_abi, 3);
        assert!(host_abi_satisfies(api.min_host_abi, GSTORE_MODULE_ABI_VERSION));
        assert!(api.init.is_some(), "init slot required");
        assert!(api.create.is_some(), "create slot required");
        assert!(api.call.is_some(), "call slot required");
        assert!(api.cancel.is_some(), "cancel slot required");
        assert!(api.destroy.is_some(), "destroy slot required");
        assert!(api.shutdown.is_some(), "shutdown slot required");
        assert!(api.alloc.is_some(), "alloc slot required");
        assert!(api.free.is_some(), "free slot required");
        assert!(api.on_event.is_some(), "on_event slot required");
    }

    #[test]
    fn register_create_call_ping_and_version_destroy() {
        let _g = ABI_LOCK.lock().unwrap();
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let mut inst: u64 = 0;
        assert_eq!(create(std::ptr::null(), 0, &mut inst), ABI_OK);
        assert!(inst > 0, "create must return a valid instance id");

        let (code, out) = call_json(call, inst, "ping");
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["ok"], true, "ping must return ok envelope");
        assert_eq!(v["data"]["pong"], true);
        assert_eq!(v["data"]["module"], "proxy");
        assert_eq!(v["data"]["instanceId"], inst);

        let (code, out) = call_json(call, inst, "version");
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["minHostAbi"], 3);
        assert_eq!(v["data"]["meowRev"], MEOW_REV);

        assert_eq!(destroy(inst), ABI_OK);
        assert_eq!(destroy(inst), ABI_OK, "destroy 幂等");
    }

    /// 失败 QA：未知方法必须是结构化 405，而不是 panic 或 500。
    #[test]
    fn unknown_method_returns_405_method_not_found() {
        let _g = ABI_LOCK.lock().unwrap();
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let mut inst: u64 = 0;
        assert_eq!(create(std::ptr::null(), 0, &mut inst), ABI_OK);

        let (code, out) = call_json(call, inst, "core.no_such_method");
        assert_eq!(code, ABI_ERR_DETAIL, "域错误应经 ABI_ERR_DETAIL 透传");
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["status"], 405);
        assert_eq!(v["code"], "METHOD_NOT_FOUND");

        assert_eq!(destroy(inst), ABI_OK);
    }

    #[test]
    fn alloc_free_and_on_event_are_panic_safe() {
        let _g = ABI_LOCK.lock().unwrap();
        let api = register_api();
        let p = proxy_alloc_export(16);
        assert!(!p.is_null());
        proxy_free_export(p);
        proxy_free_export(std::ptr::null_mut());
        let kind = CString::new("config.changed").unwrap();
        let payload = br#"{"key":"proxy.mode","value":"vpn"}"#;
        assert_eq!(
            (api.on_event.unwrap())(1, kind.as_ptr(), payload.as_ptr(), payload.len()),
            ABI_OK
        );
    }

    /// Happy/failure QA over the real C ABI: invalid fd → structured error;
    /// valid fd → loop reads once → `proxy.state=running`; stop → joined +
    /// `proxy.tun.released`.
    #[test]
    fn abi_tun_fd_start_stop_and_release_event() {
        use std::io::Write as _;
        let _g = ABI_LOCK.lock().unwrap();
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();
        let _ = take_events();

        let mut inst: u64 = 0;
        assert_eq!(create(std::ptr::null(), 0, &mut inst), ABI_OK);

        // Failure QA: fd = -1 → structured PROXY_TUN_FD_INVALID, never a panic.
        let (code, out) = call_with_payload(call, inst, "tun.set_fd", br#"{"fd":-1}"#);
        assert_eq!(code, ABI_ERR_DETAIL);
        let err: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(err["code"], "PROXY_TUN_FD_INVALID");
        assert_eq!(err["status"], 422);

        // Happy QA: a real socketpair stands in for the VpnService TUN fd.
        let (loop_end, mut peer) = std::os::unix::net::UnixStream::pair().unwrap();
        let payload = format!(r#"{{"fd":{}}}"#, std::os::fd::AsRawFd::as_raw_fd(&loop_end));
        let (code, out) = call_with_payload(call, inst, "tun.set_fd", payload.as_bytes());
        assert_eq!(code, ABI_OK, "tun.set_fd: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["nonblocking"], true);

        let (code, out) = call_with_payload(call, inst, "core.start", br#"{"mode":"vpn"}"#);
        assert_eq!(code, ABI_OK, "core.start: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["state"], "running");
        assert_eq!(tun::running_count(), 1, "exactly one loop thread");

        let events = take_events();
        assert!(
            events
                .iter()
                .any(|(t, p)| t == "proxy.state"
                    && String::from_utf8_lossy(p).contains("\"running\"")),
            "proxy.state=running must be emitted; got {events:?}"
        );

        tun::reset_read_count();
        peer.write_all(&[0x45u8; 40]).unwrap();
        peer.flush().unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while tun::read_count() < 1 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert_eq!(tun::read_count(), 1, "frame must be read exactly once");

        let (code, out) = call_json(call, inst, "core.stop");
        assert_eq!(code, ABI_OK, "core.stop: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["state"], "stopped");
        assert_eq!(tun::running_count(), 0, "loop thread joined on stop");
        let events = take_events();
        assert!(
            events.iter().any(|(t, _)| t == "proxy.tun.released"),
            "proxy.tun.released must fire after join; got {events:?}"
        );

        assert_eq!(destroy(inst), ABI_OK);
    }

    /// `dns.set` → `dns.get` round-trip over the real C ABI, plus
    /// `dns.clear_cache`. Uses IP-literal nameservers so no network is touched.
    #[test]
    fn abi_dns_set_get_and_clear_cache() {
        let _g = ABI_LOCK.lock().unwrap();
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let mut inst: u64 = 0;
        assert_eq!(create(std::ptr::null(), 0, &mut inst), ABI_OK);

        let (code, out) = call_json(call, inst, "dns.get");
        assert_eq!(code, ABI_OK, "dns.get: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["mode"], "fake-ip", "default mode is fake-ip");

        let payload = br#"{"mode":"redir-host","nameservers":["127.0.0.1"],
            "doh":["https://1.1.1.1/dns-query"],"fallback":["8.8.8.8"]}"#;
        let (code, out) = call_with_payload(call, inst, "dns.set", payload);
        assert_eq!(code, ABI_OK, "dns.set: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["config"]["mode"], "redir-host");
        assert_eq!(v["data"]["config"]["nameservers"][0], "127.0.0.1");
        assert_eq!(v["data"]["config"]["doh"][0], "https://1.1.1.1/dns-query");

        let (code, out) = call_json(call, inst, "dns.get");
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["mode"], "redir-host", "dns.get must reflect dns.set");
        assert_eq!(v["data"]["config"]["fallback"][0], "8.8.8.8");
        assert!(v["data"]["stats"]["cacheEntries"].is_number());

        let (code, out) = call_json(call, inst, "dns.clear_cache");
        assert_eq!(code, ABI_OK, "dns.clear_cache: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["ok"], true);
        assert!(v["data"]["flushed"].is_number());

        // Invalid nameserver is a structured 422, never a panic.
        let (code, out) = call_with_payload(
            call,
            inst,
            "dns.set",
            br#"{"nameservers":["not a nameserver!!"]}"#,
        );
        assert_eq!(code, ABI_ERR_DETAIL);
        let err: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(err["code"], "PROXY_DNS_CONFIG_INVALID");
        assert_eq!(err["status"], 422);

        assert_eq!(destroy(inst), ABI_OK);
    }

    /// `rules.reload` → `rules.get` over the real C ABI with an inline fixture
    /// config (no providers on disk, no network), plus a malformed line that
    /// must come back as a structured `PROXY_RULE_INVALID`.
    #[test]
    fn abi_rules_reload_and_get() {
        let _g = ABI_LOCK.lock().unwrap();
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("gstore-rules-abi-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let config = serde_json::json!({
            "data_dir": dir.display().to_string(),
            "cache_dir": dir.display().to_string(),
        });
        let config = serde_json::to_vec(&config).unwrap();

        let mut inst: u64 = 0;
        assert_eq!(
            create(config.as_ptr(), config.len(), &mut inst),
            ABI_OK,
            "create with a data dir"
        );

        let yaml = "proxy-groups:\n  - name: G1\n    type: select\n    proxies: [DIRECT]\n\
                    rules:\n  - DOMAIN-SUFFIX,abi.example,G1\n  - BROKEN,x,DIRECT\n\
                    \x20 - MATCH,DIRECT\n";
        let payload = serde_json::to_vec(&serde_json::json!({ "config": yaml })).unwrap();
        let (code, out) = call_with_payload(call, inst, "rules.reload", &payload);
        assert_eq!(code, ABI_OK, "rules.reload: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["rules"].as_array().unwrap().len(), 2);
        assert_eq!(v["data"]["rules"][0]["type"], "DOMAIN-SUFFIX");
        assert_eq!(v["data"]["rules"][0]["target"], "G1");
        assert_eq!(v["data"]["errors"][0]["code"], "PROXY_RULE_INVALID");
        assert_eq!(v["data"]["errors"][0]["line"], "BROKEN,x,DIRECT");

        let (code, out) = call_json(call, inst, "rules.get");
        assert_eq!(code, ABI_OK, "rules.get: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["count"], 2);
        assert_eq!(v["data"]["final"], "DIRECT");
        assert_eq!(v["data"]["groups"][0], "G1");

        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(destroy(inst), ABI_OK);
    }
}
