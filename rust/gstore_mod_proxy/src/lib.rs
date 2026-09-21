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
use gstore_contract::error::ModuleError;

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
    pub data_dir: String,
    pub cache_dir: String,
    pub abi: String,
    pub app_version: String,
    /// 宿主注入的 socket 保护服务（ABI v3，经 `entry_size` 守卫读取）。
    /// Todo 7 会包装成 meow `SocketProtector` 并在 Android 上安装。
    pub host_protect_fd: Option<extern "C" fn(c_int) -> c_int>,
}

static INSTANCES: OnceLock<Mutex<HashMap<u64, Arc<ProxyInstance>>>> = OnceLock::new();
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);
static HOST_LOG: OnceLock<extern "C" fn(c_int, *const c_char)> = OnceLock::new();
static HOST_EMIT: OnceLock<extern "C" fn(u64, u64, *const u8, usize)> = OnceLock::new();
static HOST_ABI: OnceLock<u32> = OnceLock::new();
static HOST_PROTECT_FD: OnceLock<Option<extern "C" fn(c_int) -> c_int>> = OnceLock::new();

fn instances() -> &'static Mutex<HashMap<u64, Arc<ProxyInstance>>> {
    INSTANCES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn log_message(level: c_int, msg: &str) {
    if let Some(f) = HOST_LOG.get() {
        if let Ok(cmsg) = CString::new(msg) {
            f(level, cmsg.as_ptr());
        }
    }
}

/// 上报模块事件（宿主负载约定：前 4 字节为事件类型长度，小端）。
#[allow(dead_code)]
fn emit_event(instance_id: u64, event_type: &str, payload: &[u8]) {
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
    instances().lock().unwrap().remove(&instance_id);
    log_message(1, &format!("proxy: instance {instance_id} destroyed"));
    Ok(())
}

fn shutdown_impl() -> Result<(), c_int> {
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
    /// 同进程内多个测试共享 INSTANCES/NEXT_INSTANCE，故用例串行执行。
    static ABI_LOCK: Mutex<()> = Mutex::new(());

    type CallFn = extern "C" fn(u64, *const c_char, *const u8, usize, *mut *mut u8, *mut usize) -> c_int;

    extern "C" fn dummy_protect(_fd: c_int) -> c_int {
        0
    }

    fn register_api() -> GStoreModuleApi {
        let entry = GStoreModuleEntry {
            abi_version: GSTORE_MODULE_ABI_VERSION,
            entry_size: std::mem::size_of::<GStoreModuleEntry>() as u32,
            log: None,
            alloc: None,
            free: None,
            emit_event: None,
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
        let m = CString::new(method).unwrap();
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        let code = call(inst, m.as_ptr(), std::ptr::null(), 0, &mut ptr, &mut len);
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

        let (code, out) = call_json(call, inst, "core.start");
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
}
