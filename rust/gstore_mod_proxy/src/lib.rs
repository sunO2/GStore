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
use std::ffi::{c_char, c_int, c_void, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use gstore_contract::abi::{
    ABI_ERR_ABI_MISMATCH, ABI_ERR_DETAIL, ABI_ERR_INTERNAL, ABI_ERR_NO_INSTANCE, ABI_ERR_NULL,
    ABI_ERR_PANIC, ABI_OK, GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
};
use gstore_contract::context::ModuleContext;
use gstore_contract::error::{ModuleError, StatusCode};

mod config;
mod conn;
mod controller;
mod dispatch;
mod dns;
mod lan;
mod limits;
mod logging;
mod nodes;
mod profile;
mod protect;
mod rules;
mod stats;
mod subscription;
mod supervisor;
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
        let _g = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
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
pub(crate) const EVT_STATE: &str = "proxy.state";
#[allow(dead_code)]
const EVT_MODE: &str = "proxy.mode";
#[allow(dead_code)]
const EVT_NODE_DELAY: &str = "proxy.node.delay";
#[allow(dead_code)]
const EVT_STATS: &str = "proxy.stats";
const EVT_SUBSCRIPTION: &str = "proxy.subscription.added";
const EVT_SUBSCRIPTION_UPDATED: &str = "proxy.subscription.updated";
const EVT_SUBSCRIPTION_REMOVED: &str = "proxy.subscription.removed";
/// Module → host: a subscription refresh is in flight (started/succeeded/failed).
const EVT_SUBSCRIPTION_PROGRESS: &str = "proxy.subscription.progress";
/// Module → host: a subscription refresh failed; the previous profile is kept.
const EVT_SUBSCRIPTION_FAILED: &str = "proxy.subscription.failed";
/// 模块 → 宿主：TUN 读取循环已停止且线程已 join，宿主可清缓存 fd（Kotlin 可关闭）。
const EVT_TUN_RELEASED: &str = "proxy.tun.released";
/// 模块 → 宿主：`config.apply` 已在运行的引擎上热应用新配置（无需进程重启）。
const EVT_CONFIG_APPLIED: &str = "proxy.config.applied";
/// 模块 → 宿主：一次显式连接控制事件（`conn.close` / `conn.close_all`）。
const EVT_CONN: &str = "proxy.conn";

/// Every method the `call` dispatch accepts, in the order `API.md` §2 lists it.
///
/// This is the **machine-checkable** frozen contract (Todo 18): the accompanying
/// tests assert (a) each name is actually dispatchable (never
/// `METHOD_NOT_FOUND`) and (b) each name appears verbatim in `API.md`. Keep it in
/// lockstep with the `match method.as_str()` arms and the documentation.
#[allow(dead_code)]
pub(crate) const DISPATCH_METHODS: &[&str] = &[
    "ping",
    "version",
    "tun.set_fd",
    "core.start",
    "core.stop",
    "core.restart",
    "core.get_mode",
    "core.set_mode",
    "dns.get",
    "dns.set",
    "dns.clear_cache",
    "dns.flush_cache",
    "log.get",
    "log.set_level",
    "log.clear",
    "rules.get",
    "rules.reload",
    "config.generate",
    "config.apply",
    "profile.export_clash",
    "profile.import_url",
    "profile.import_text",
    "profile.import_link",
    "profile.list",
    "profile.get",
    "profile.create",
    "profile.update",
    "profile.delete",
    "profile.refresh",
    "profile.refresh_all",
    "profile.set_schedule",
    "node.select",
    "node.delay_test",
    "conn.list",
    "conn.close",
    "conn.close_all",
    "stats.domain.get",
    "stats.domain.reset",
    "stats.traffic.get",
    "stats.get",
    "stats.reset",
    "lan.get",
    "lan.set",
    "lan.status",
    "diagnostics.clash_api.start",
    "diagnostics.clash_api.stop",
    "diagnostics.clash_api.status",
];

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

pub(crate) fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Single module log entry point. Every line is retained in the bounded ring
/// ([`logging`]) and forwarded to the host `log` callback (LogBridge → Dart
/// `LogManager`); the ring level set by `log.set_level` filters at the source.
pub(crate) fn log_message(level: c_int, msg: &str) {
    logging::record_message_int(level, msg);
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
///
/// Tests DO NOT install it: the silent hook hides the first failure's message
/// and location, which makes a poisoned shared test lock undebuggable. The
/// shipping module keeps the silent hook.
#[cfg(not(test))]
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

#[cfg(test)]
fn install_panic_hook() {}

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
pub(crate) fn ok_data(data: serde_json::Value) -> Result<Vec<u8>, ModuleError> {
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
            let (spawned, summary) = start_engine(&inst, payload)?;
            set_state(&inst, ProxyRunState::Running);
            set_mode(&inst, ProxyMode::Vpn);
            log_message(
                1,
                &format!("proxy: core.start vpn instance={} spawned={spawned}", inst.id),
            );
            emit_state(inst.id, ProxyRunState::Running, ProxyMode::Vpn, None);
            let mut data = serde_json::json!({
                "state": "running", "mode": "vpn", "instanceId": inst.id, "spawned": spawned,
            });
            merge_engine_summary(&mut data, &summary);
            ok_data(data)
        }
        ProxyMode::Off => core_stop_arm(instance_id, Some(inst)),
        ProxyMode::LanProxy => Err(ModuleError::new(
            StatusCode::InvalidArgument,
            "PROXY_NO_INBOUND",
            "lanProxy inbound listener is not implemented yet (Todo 28)",
        )),
    }
}

/// Start-order (pinned, `core.start` vpn): generated profile config → proxy
/// registry (leaves + groups, via Todo 10's `install_proxies`) → rules →
/// DNS → ring the TUN loop, which consumes the already-installed fd last.
fn start_engine(
    inst: &Arc<ProxyInstance>,
    payload: &[u8],
) -> Result<(bool, Option<serde_json::Value>), ModuleError> {
    stats::configure(&inst.data_dir);
    let req = config::parse_request(payload)?;
    let generated = config::try_generate(&inst.data_dir, &inst.cache_dir, &req)?;
    let Some(generated) = generated else {
        let spawned = tun::start_with_proxies(inst.id, None)?;
        lan::reconcile();
        return Ok((spawned, None));
    };

    apply_dns_overlay(req.dns.as_ref())?;
    rules::reload(
        &inst.data_dir,
        &inst.cache_dir,
        &config::reload_payload(&generated.yaml),
    )?;
    let (map, mut warnings) = config::build_registry(&generated.raw, selector_store(inst).as_ref());
    warnings.extend(generated.warnings.iter().cloned());
    let spawned = tun::start_with_proxies(inst.id, Some(map))?;
    lan::reconcile();
    log_message(
        1,
        &format!(
            "proxy: core.start generated profile={:?} nodes={} groups={} rules={} warnings={}",
            generated.profile_id,
            generated.node_count,
            generated.group_count,
            generated.rule_count,
            warnings.len()
        ),
    );
    Ok((spawned, Some(engine_summary(&generated, &warnings))))
}

fn selector_store(inst: &Arc<ProxyInstance>) -> Option<Arc<meow_proxy::SelectorStore>> {
    if inst.data_dir.trim().is_empty() {
        return None;
    }
    Some(nodes::ensure_selector_store(&inst.data_dir))
}

fn apply_dns_overlay(overlay: Option<&serde_json::Value>) -> Result<(), ModuleError> {
    let Some(value) = overlay else {
        return Ok(());
    };
    let mut cfg = dns::config();
    let bytes = serde_json::to_vec(value)
        .map_err(|e| ModuleError::invalid_arg(format!("dns overlay encode: {e}")))?;
    cfg.apply_patch(&bytes)?;
    dns::set_config(cfg)?;
    Ok(())
}

fn engine_summary(generated: &config::GeneratedConfig, warnings: &[config::ConfigWarning]) -> serde_json::Value {
    serde_json::json!({
        "profileId": generated.profile_id,
        "profileName": generated.profile_name,
        "hash": generated.hash,
        "template": config::TEMPLATE_ID,
        "proxies": generated.node_count,
        "groups": generated.group_count,
        "rules": generated.rule_count,
        "overlays": { "stack": generated.stack, "mtu": generated.mtu },
        "warnings": warnings,
    })
}

fn merge_engine_summary(data: &mut serde_json::Value, summary: &Option<serde_json::Value>) {
    let Some(summary) = summary else { return };
    let Some(object) = summary.as_object() else { return };
    for (key, value) in object {
        data[key] = value.clone();
    }
}

fn core_stop_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    // Diagnostics controller is bound to the live engine; stop it with the engine.
    controller::stop();
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
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    // A restart builds a fresh tunnel; the previous controller would hold the
    // stale one, so drop it (a developer re-enables diagnostics explicitly).
    controller::stop();
    if let Some(s) = tun::stop() {
        emit_tun_released(s.instance_id, s.host_fd);
    }
    // The previous loop consumed (and closed) our pending dup; re-duplicate the
    // last known host fd if it is still open, so restart works without a new
    // nativeSetTunFd (if Kotlin already closed it we surface PROXY_TUN_FD_INVALID).
    tun::ensure_pending_from_last()?;
    let (spawned, summary) = start_engine(&inst, payload)?;
    set_state(&inst, ProxyRunState::Running);
    set_mode(&inst, ProxyMode::Vpn);
    emit_state(inst.id, ProxyRunState::Running, ProxyMode::Vpn, Some("restart"));
    let mut data = serde_json::json!({ "state": "running", "mode": "vpn", "spawned": spawned });
    merge_engine_summary(&mut data, &summary);
    ok_data(data)
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

/// `config.generate` (Todo 13): render the controlled Clash template for a
/// stored profile without touching the running engine.
fn config_generate_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let generated = config::generate_for(
        &inst.data_dir,
        &inst.cache_dir,
        &config::parse_request(payload)?,
    )?;
    ok_data(generated.to_data())
}

/// `config.apply` (Todo 13): regenerate the config from a profile and hot-apply
/// it to the running engine — rules, then the proxy registry — without a
/// process restart.
fn config_apply_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let tunnel = rules::active_tunnel().ok_or_else(|| {
        ModuleError::new(
            StatusCode::InvalidArgument,
            nodes::ERR_NOT_CONFIGURED,
            "engine is not running; call core.start before config.apply",
        )
    })?;
    let req = config::parse_request(payload)?;
    let generated = config::generate_for(&inst.data_dir, &inst.cache_dir, &req)?;
    apply_dns_overlay(req.dns.as_ref())?;
    let snapshot = rules::reload(
        &inst.data_dir,
        &inst.cache_dir,
        &config::reload_payload(&generated.yaml),
    )?;
    let (map, mut warnings) = config::build_registry(&generated.raw, selector_store(&inst).as_ref());
    warnings.extend(generated.warnings.iter().cloned());
    nodes::install_proxies(&tunnel, map);
    emit_json(
        inst.id,
        EVT_CONFIG_APPLIED,
        &serde_json::json!({
            "profileId": generated.profile_id,
            "hash": generated.hash,
            "template": config::TEMPLATE_ID,
        }),
    );
    log_message(
        1,
        &format!(
            "proxy: config.apply profile={:?} nodes={} groups={} warnings={}",
            generated.profile_id,
            generated.node_count,
            generated.group_count,
            warnings.len()
        ),
    );
    let mut data = engine_summary(&generated, &warnings);
    data["applied"] = serde_json::json!(true);
    data["rules"] = snapshot
        .get("count")
        .cloned()
        .unwrap_or_else(|| serde_json::json!(0));
    ok_data(data)
}

/// `profile.export_clash` (Todo 13): the generated config for one stored
/// profile, addressed by `{ "id": ... }`.
fn profile_export_clash_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let req = config::parse_export_request(payload)?;
    let store = profile::ProfileStore::open(&inst.data_dir)?;
    let id_payload = serde_json::to_vec(&serde_json::json!({ "id": req.id })).unwrap_or_default();
    let record = store.get(&id_payload)?;
    ok_data(config::export(&record, &req)?.to_data())
}

/// `profile.import_*`: run the import, emit `proxy.subscription.added`, and
/// return the canonical [`subscription::ImportedProfile`] as `data`.
fn profile_import_arm<F>(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    import: F,
) -> Result<Vec<u8>, ModuleError>
where
    F: FnOnce() -> Result<subscription::ImportedProfile, ModuleError>,
{
    let inst = require_instance(instance_id, instance)?;
    let profile = import()?;
    let event = serde_json::json!({
        "action": "imported",
        "format": profile.format,
        "name": profile.name,
        "nodeCount": profile.node_count,
        "url": profile.source.url,
    });
    if let Ok(bytes) = serde_json::to_vec(&event) {
        emit_event(inst.id, EVT_SUBSCRIPTION, &bytes);
    }
    let data = serde_json::to_value(&profile)
        .map_err(|e| ModuleError::internal(format!("profile serialize: {e}")))?;
    ok_data(data)
}

/// Serialize a value into the module `ok` envelope's `data`.
fn to_value<T: serde::Serialize>(value: &T) -> Result<serde_json::Value, ModuleError> {
    serde_json::to_value(value).map_err(|e| ModuleError::internal(format!("serialize: {e}")))
}

/// Emit a JSON event, ignoring serialization failures (events are best-effort).
fn emit_json(instance_id: u64, event_type: &str, value: &serde_json::Value) {
    if let Ok(bytes) = serde_json::to_vec(value) {
        emit_event(instance_id, event_type, &bytes);
    }
}

/// `profile.list` (Todo 12): the stored profiles in stable `(createdAtMs, id)`
/// order plus non-fatal warnings for corrupt/missing siblings.
fn profile_list_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let store = profile::ProfileStore::open(&inst.data_dir)?;
    ok_data(to_value(&store.list()?)?)
}

/// `profile.get` (Todo 12): one stored profile by id.
fn profile_get_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let store = profile::ProfileStore::open(&inst.data_dir)?;
    ok_data(to_value(&store.get(payload)?)?)
}

/// `profile.create` (Todo 12): persist an already-parsed canonical profile and
/// emit `proxy.subscription.added`.
fn profile_create_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let store = profile::ProfileStore::open(&inst.data_dir)?;
    let record = store.create(payload)?;
    emit_json(
        inst.id,
        EVT_SUBSCRIPTION,
        &serde_json::json!({ "profileId": record.id, "name": record.profile.name }),
    );
    ok_data(to_value(&record)?)
}

/// Traffic projection shared by `proxy.subscription.updated` and refresh
/// results: upload/download plus a derived `usedBytes` and the total cap.
fn userinfo_traffic(userinfo: &subscription::SubscriptionUserinfo) -> serde_json::Value {
    let upload = userinfo.upload.unwrap_or(0);
    let download = userinfo.download.unwrap_or(0);
    let total = userinfo.total.unwrap_or(0);
    let used = upload.saturating_add(download);
    serde_json::json!({
        "uploadBytes": upload,
        "downloadBytes": download,
        "totalBytes": total,
        "usedBytes": if total == 0 { used } else { used.min(total) },
    })
}

/// Build the `proxy.subscription.updated` payload for a stored record,
/// including the per-profile scheduling metadata (Todo 14).
fn subscription_updated_event(record: &profile::StoredProfile) -> serde_json::Value {
    let userinfo = record.profile.userinfo.clone().unwrap_or_default();
    let refresh = record.refresh.clone().unwrap_or_default();
    serde_json::json!({
        "profileId": record.id,
        "nodeCount": record.profile.node_count,
        "traffic": userinfo_traffic(&userinfo),
        "expireAtMs": userinfo.expire.unwrap_or(0).saturating_mul(1000),
        "lastUpdatedAtMs": refresh.last_updated_at_ms,
        "intervalMs": refresh.interval_ms,
        "nextRefreshAtMs": refresh.next_refresh_at_ms,
    })
}

/// `profile.update` (Todo 12): replace profile content/metadata; emits
/// `proxy.subscription.updated` carrying the userinfo traffic/expiry.
fn profile_update_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let store = profile::ProfileStore::open(&inst.data_dir)?;
    let record = store.update(payload)?;
    emit_json(inst.id, EVT_SUBSCRIPTION_UPDATED, &subscription_updated_event(&record));
    ok_data(to_value(&record)?)
}

/// `profile.delete` (Todo 12): remove the payload and index entry; emits
/// `proxy.subscription.removed`.
fn profile_delete_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let store = profile::ProfileStore::open(&inst.data_dir)?;
    let outcome = store.delete(payload)?;
    emit_json(
        inst.id,
        EVT_SUBSCRIPTION_REMOVED,
        &serde_json::json!({ "profileId": outcome.id }),
    );
    ok_data(to_value(&outcome)?)
}

/// Fetch one subscription URL through Todo 11's protect-aware importer.
fn fetch_import_via_url(fetch: &profile::FetchSpec) -> Result<subscription::ImportedProfile, ModuleError> {
    let payload = serde_json::to_vec(&serde_json::json!({
        "url": fetch.url,
        "name": fetch.name,
        "userAgent": fetch.user_agent,
    }))
    .map_err(|e| ModuleError::internal(format!("refresh fetch payload: {e}")))?;
    subscription::import_url(&payload)
}

/// The refresh state machine shared by `profile.refresh` and
/// `profile.refresh_all`: begin (with backoff) → fetch via `import` →
/// persist success/failure + emit the event sequence. Returns the outcome even
/// on refresh failure (the attempt was recorded and surfaced); only
/// begin-step errors (not found / not refreshable / backoff) propagate as
/// `Err`.
fn perform_refresh<F>(
    inst: &Arc<ProxyInstance>,
    store: &profile::ProfileStore,
    id: &str,
    force: bool,
    import: F,
) -> Result<profile::RefreshResult, ModuleError>
where
    F: FnOnce(&profile::FetchSpec) -> Result<subscription::ImportedProfile, ModuleError>,
{
    let begin = serde_json::to_vec(&serde_json::json!({ "id": id, "force": force }))
        .map_err(|e| ModuleError::internal(format!("refresh begin payload: {e}")))?;
    let plan = store.refresh(&begin)?;
    emit_json(
        inst.id,
        EVT_SUBSCRIPTION_PROGRESS,
        &serde_json::json!({
            "profileId": plan.profile_id,
            "phase": "fetch",
            "state": "started",
            "attempts": plan.attempts,
        }),
    );
    let fetch = plan.fetch.clone().ok_or_else(|| {
        ModuleError::new(
            StatusCode::InvalidArgument,
            profile::ERR_PROFILE_NOT_REFRESHABLE,
            format!("profile '{}' has no fetch spec", plan.profile_id),
        )
    })?;

    match import(&fetch) {
        Ok(parsed) => {
            let record = store.apply_refresh_success(&plan.profile_id, parsed)?;
            emit_json(
                inst.id,
                EVT_SUBSCRIPTION_PROGRESS,
                &serde_json::json!({
                    "profileId": plan.profile_id,
                    "phase": "persist",
                    "state": "succeeded",
                    "attempts": plan.attempts,
                }),
            );
            emit_json(inst.id, EVT_SUBSCRIPTION_UPDATED, &subscription_updated_event(&record));
            let refresh = record.refresh.clone().unwrap_or_default();
            Ok(profile::RefreshResult {
                profile_id: record.id.clone(),
                state: "done".to_string(),
                attempts: refresh.attempts,
                node_count: record.profile.node_count,
                userinfo: record.profile.userinfo.clone(),
                last_updated_at_ms: refresh.last_updated_at_ms,
                interval_ms: refresh.interval_ms,
                next_refresh_at_ms: refresh.next_refresh_at_ms,
                retry_after_ms: None,
                error: None,
                profile: record,
            })
        }
        Err(err) => {
            let record = store.apply_refresh_failure(&plan.profile_id, &err.code, &err.message)?;
            let refresh = record.refresh.clone().unwrap_or_default();
            emit_json(
                inst.id,
                EVT_SUBSCRIPTION_PROGRESS,
                &serde_json::json!({
                    "profileId": plan.profile_id,
                    "phase": "fetch",
                    "state": "failed",
                    "attempts": plan.attempts,
                }),
            );
            emit_json(
                inst.id,
                EVT_SUBSCRIPTION_FAILED,
                &serde_json::json!({
                    "profileId": record.id,
                    "attempts": refresh.attempts,
                    "consecutiveFailures": refresh.consecutive_failures,
                    "lastAttemptMs": refresh.last_attempt_ms,
                    "nextRefreshAtMs": refresh.next_refresh_at_ms,
                    "error": { "code": err.code, "message": err.message },
                }),
            );
            Ok(profile::RefreshResult {
                profile_id: record.id.clone(),
                state: "failed".to_string(),
                attempts: refresh.attempts,
                node_count: record.profile.node_count,
                userinfo: record.profile.userinfo.clone(),
                last_updated_at_ms: refresh.last_updated_at_ms,
                interval_ms: refresh.interval_ms,
                next_refresh_at_ms: refresh.next_refresh_at_ms,
                retry_after_ms: refresh
                    .next_refresh_at_ms
                    .map(|next| next.saturating_sub(now_ms())),
                error: Some(profile::RefreshError {
                    code: err.code.to_string(),
                    message: err.message.clone(),
                }),
                profile: record,
            })
        }
    }
}

/// `profile.refresh` (Todo 14): performs the fetch via Todo 11's protect-aware
/// importer, emits the progress/updated/failed sequence, and keeps the previous
/// profile when the fetch fails. Returns the outcome (`state: done|failed`).
fn profile_refresh_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let store = profile::ProfileStore::open(&inst.data_dir)?;
    let req: serde_json::Value = if payload.is_empty() {
        return Err(ModuleError::invalid_arg("profile.refresh requires a JSON object payload"));
    } else {
        serde_json::from_slice(payload)
            .map_err(|e| ModuleError::invalid_arg(format!("profile.refresh payload JSON: {e}")))?
    };
    let id = req
        .get("id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| ModuleError::invalid_arg("profile.refresh requires `id`"))?;
    let force = req.get("force").and_then(|v| v.as_bool()).unwrap_or(false);
    let result = perform_refresh(&inst, &store, id, force, fetch_import_via_url)?;
    ok_data(to_value(&result)?)
}

const REFRESH_ALL_DEFAULT_LIMIT: usize = 8;
const REFRESH_ALL_MAX_LIMIT: usize = 32;

/// `profile.refresh_all` (Todo 14): user-triggered batch update. Skips
/// profiles that are not due (interval not elapsed / failure backoff) unless
/// `force`, and never attempts more than `limit` (default 8, max 32) respites
/// per call — no retry storms, no silent background loop.
fn profile_refresh_all_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let store = profile::ProfileStore::open(&inst.data_dir)?;
    let req: profile::RefreshAllRequest = if payload.is_empty() {
        profile::RefreshAllRequest { force: false, limit: None }
    } else {
        serde_json::from_slice(payload)
            .map_err(|e| ModuleError::invalid_arg(format!("profile.refresh_all payload JSON: {e}")))?
    };
    let limit = req
        .limit
        .map(|l| (l as usize).clamp(1, REFRESH_ALL_MAX_LIMIT))
        .unwrap_or(REFRESH_ALL_DEFAULT_LIMIT);
    let now = now_ms();

    let list = store.list()?;
    let mut refreshed: Vec<profile::RefreshResult> = Vec::new();
    let mut skipped: Vec<serde_json::Value> = Vec::new();
    let mut attempted = 0usize;

    for summary in &list.profiles {
        if attempted >= limit {
            skipped.push(serde_json::json!({
                "profileId": summary.id,
                "reason": "limit",
            }));
            continue;
        }
        let refreshable = summary.source_origin.as_deref() == Some("url")
            && summary.source_url.as_deref().map(|u| !u.trim().is_empty()).unwrap_or(false);
        if !refreshable {
            skipped.push(serde_json::json!({
                "profileId": summary.id,
                "reason": "not_refreshable",
            }));
            continue;
        }
        if !req.force {
            if let Some(refresh) = &summary.refresh {
                if refresh.consecutive_failures > 0 {
                    let next = refresh.next_refresh_at_ms.unwrap_or(0);
                    if next > now {
                        skipped.push(serde_json::json!({
                            "profileId": summary.id,
                            "reason": "backoff",
                            "nextRefreshAtMs": next,
                        }));
                        continue;
                    }
                }
                if refresh.consecutive_failures == 0 {
                    if let (Some(interval), Some(last)) = (refresh.interval_ms, refresh.last_updated_at_ms) {
                        let next = refresh
                            .next_refresh_at_ms
                            .unwrap_or_else(|| last.saturating_add(interval));
                        if next > now {
                            skipped.push(serde_json::json!({
                                "profileId": summary.id,
                                "reason": "interval",
                                "nextRefreshAtMs": next,
                            }));
                            continue;
                        }
                    }
                }
            }
        }
        attempted += 1;
        match perform_refresh(&inst, &store, &summary.id, req.force, fetch_import_via_url) {
            Ok(result) => refreshed.push(result),
            Err(err) => skipped.push(serde_json::json!({
                "profileId": summary.id,
                "reason": "error",
                "code": err.code,
                "message": err.message,
            })),
        }
    }

    let failed: Vec<&profile::RefreshResult> =
        refreshed.iter().filter(|r| r.state == "failed").collect();
    ok_data(serde_json::json!({
        "force": req.force,
        "limit": limit,
        "attempted": attempted,
        "count": refreshed.len(),
        "failedCount": failed.len(),
        "refreshed": refreshed,
        "skipped": skipped,
    }))
}

/// `profile.set_schedule` (Todo 14): set (0 clears) a profile's auto-update
/// interval and recompute its next due time.
fn profile_set_schedule_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let store = profile::ProfileStore::open(&inst.data_dir)?;
    ok_data(to_value(&store.set_schedule(payload)?)?)
}

fn node_select_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let (data, sel) = nodes::select(payload)?;
    let event = serde_json::json!({
        "state": current_state(&inst).as_str(),
        "mode": current_mode(&inst).as_str(),
        "reason": "node.select",
        "group": sel.group,
        "node": sel.node,
        "active": sel.active,
    });
    if let Ok(bytes) = serde_json::to_vec(&event) {
        emit_event(inst.id, EVT_STATE, &bytes);
    }
    ok_data(data)
}

fn parse_clash_api_port(payload: &[u8]) -> Result<u16, ModuleError> {
    if payload.is_empty() {
        return Ok(0);
    }
    let v: serde_json::Value = serde_json::from_slice(payload).map_err(|e| {
        ModuleError::invalid_arg(format!(
            "diagnostics.clash_api.start payload must be a JSON object: {e}"
        ))
    })?;
    match v.get("port") {
        None | Some(serde_json::Value::Null) => Ok(0),
        Some(p) => p
            .as_u64()
            .filter(|n| *n <= u16::MAX as u64)
            .map(|n| n as u16)
            .ok_or_else(|| {
                ModuleError::invalid_arg(
                    "diagnostics.clash_api.start `port` must be an integer 0..=65535",
                )
            }),
    }
}

/// `diagnostics.clash_api.start` (Todo 18): embed meow's mihomo-compatible
/// controller bound to `127.0.0.1` with a random per-run secret. Requires a
/// running engine (it serves the live tunnel); the secret is never returned.
fn clash_api_start_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let port = parse_clash_api_port(payload)?;
    let tunnel = rules::active_tunnel().ok_or_else(|| {
        ModuleError::new(
            StatusCode::InvalidArgument,
            nodes::ERR_NOT_CONFIGURED,
            "engine is not running; call core.start before diagnostics.clash_api.start",
        )
    })?;
    let status = controller::start(port, &inst.data_dir, (*tunnel).clone())?;
    ok_data(to_value(&status)?)
}

/// `lan.get` (Todo 28): effective LAN config + security warning.
fn lan_get_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
) -> Result<Vec<u8>, ModuleError> {
    let _inst = require_instance(instance_id, instance)?;
    ok_data(lan::get_json())
}

/// `lan.status` (Todo 28): bound/listening/addresses/activeConns + warning.
fn lan_status_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
) -> Result<Vec<u8>, ModuleError> {
    let _inst = require_instance(instance_id, instance)?;
    ok_data(lan::status_json())
}

/// `lan.set` (Todo 28): merge/validate/persist + start/restart/stop listener.
///
/// Enabling without `auth` also emits a `proxy.state` no-auth warning.
fn lan_set_arm(
    instance_id: u64,
    instance: Option<Arc<ProxyInstance>>,
    payload: &[u8],
) -> Result<Vec<u8>, ModuleError> {
    let inst = require_instance(instance_id, instance)?;
    let config = lan::set(&inst.data_dir, &inst.cache_dir, payload)?;
    let warning = lan::warning_for(&config);
    if config.enabled {
        if let Some(warning) = &warning {
            emit_lan_warning(&inst, warning);
        }
    }
    ok_data(serde_json::json!({
        "config": config,
        "status": lan::status_json(),
        "warning": warning,
    }))
}

fn emit_lan_warning(inst: &ProxyInstance, warning: &serde_json::Value) {
    let event = serde_json::json!({
        "state": current_state(inst).as_str(),
        "mode": current_mode(inst).as_str(),
        "reason": "lan.no_auth",
        "warning": warning,
    });
    emit_json(inst.id, EVT_STATE, &event);
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
    // Open the persistent selection store before any config generator rebuilds
    // groups, so meow-config's runtime rebuild can wire it into them (Todo 10/13).
    if !ctx.data_dir.is_empty() {
        let _ = nodes::ensure_selector_store(&ctx.data_dir);
    }
    lan::configure(&ctx.data_dir, &ctx.cache_dir);
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
    instances().lock().unwrap_or_else(|e| e.into_inner()).insert(id, inst);
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
                data["state"] = serde_json::json!(inst.state.lock().unwrap_or_else(|e| e.into_inner()).as_str());
                data["mode"] = serde_json::json!(inst.mode.lock().unwrap_or_else(|e| e.into_inner()).as_str());
                data["protectFdPresent"] = serde_json::json!(inst.host_protect_fd.is_some());
            }
            data["protectInstalled"] = serde_json::json!(protect::is_installed());
            // Data-plane supervisor health (Todo 24): alive flag + bounded-restart
            // counters. Extra fields are tolerated by the Dart decoder.
            data["dataplaneAlive"] = serde_json::json!(supervisor::is_alive());
            data["health"] = serde_json::to_value(supervisor::snapshot())
                .unwrap_or(serde_json::Value::Null);
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
        "log.get" => logging::get_arm(_payload),
        "log.set_level" => logging::set_level_arm(_payload),
        "log.clear" => logging::clear_arm(),
        "rules.get" => rules_get_arm(instance_id, instance.clone()),
        "rules.reload" => rules_reload_arm(instance_id, instance.clone(), _payload),
        "config.generate" => config_generate_arm(instance_id, instance.clone(), _payload),
        "config.apply" => config_apply_arm(instance_id, instance.clone(), _payload),
        "profile.export_clash" => {
            profile_export_clash_arm(instance_id, instance.clone(), _payload)
        }
        "profile.import_url" => profile_import_arm(instance_id, instance.clone(), || {
            subscription::import_url(_payload)
        }),
        "profile.import_text" => profile_import_arm(instance_id, instance.clone(), || {
            subscription::import_text(_payload)
        }),
        "profile.import_link" => profile_import_arm(instance_id, instance.clone(), || {
            subscription::import_link(_payload)
        }),
        "profile.list" => profile_list_arm(instance_id, instance.clone()),
        "profile.get" => profile_get_arm(instance_id, instance.clone(), _payload),
        "profile.create" => profile_create_arm(instance_id, instance.clone(), _payload),
        "profile.update" => profile_update_arm(instance_id, instance.clone(), _payload),
        "profile.delete" => profile_delete_arm(instance_id, instance.clone(), _payload),
        "profile.refresh" => profile_refresh_arm(instance_id, instance.clone(), _payload),
        "profile.refresh_all" => profile_refresh_all_arm(instance_id, instance.clone(), _payload),
        "profile.set_schedule" => {
            profile_set_schedule_arm(instance_id, instance.clone(), _payload)
        }
        "node.select" => node_select_arm(instance_id, instance.clone(), _payload),
        "node.delay_test" => require_instance(instance_id, instance.clone())
            .and_then(|_| nodes::delay_test_arm(instance_id, _payload)),
        "conn.list" => {
            require_instance(instance_id, instance.clone()).and_then(|_| conn::list_arm(_payload))
        }
        "conn.close" => require_instance(instance_id, instance.clone())
            .and_then(|_| conn::close_arm(instance_id, _payload)),
        "conn.close_all" => require_instance(instance_id, instance.clone())
            .and_then(|_| conn::close_all_arm(instance_id)),
        "stats.domain.get" => stats::domain_get_arm(_payload),
        "stats.domain.reset" => stats::reset_arm(),
        "stats.traffic.get" => stats::traffic_get_arm(_payload),
        "stats.get" => stats::domain_get_arm(_payload),
        "stats.reset" => stats::reset_arm(),
        "lan.get" => lan_get_arm(instance_id, instance.clone()),
        "lan.set" => lan_set_arm(instance_id, instance.clone(), _payload),
        "lan.status" => lan_status_arm(instance_id, instance.clone()),
        "diagnostics.clash_api.start" => {
            clash_api_start_arm(instance_id, instance.clone(), _payload)
        }
        "diagnostics.clash_api.stop" => {
            let was_running = controller::stop();
            ok_data(serde_json::json!({ "enabled": false, "wasRunning": was_running }))
        }
        "diagnostics.clash_api.status" => to_value(&controller::status()).and_then(ok_data),
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
    controller::stop();
    if let Some(s) = tun::stop_for_instance(instance_id) {
        emit_tun_released(s.instance_id, s.host_fd);
    }
    let remaining = {
        let mut map = instances().lock().unwrap_or_else(|e| e.into_inner());
        map.remove(&instance_id);
        map.len()
    };
    if remaining == 0 {
        // Last instance: also drop any still-pending (unstarted) fd.
        tun::shutdown();
        lan::shutdown();
    }
    log_message(1, &format!("proxy: instance {instance_id} destroyed"));
    Ok(())
}

fn shutdown_impl() -> Result<(), c_int> {
    controller::stop();
    tun::shutdown();
    lan::shutdown();
    instances().lock().unwrap_or_else(|e| e.into_inner()).clear();
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
    // §4 host → module events. `vpn.stop` is the host/Kotlin-initiated teardown
    // lane (Todo 24): it stops the active loop **without** a bounded restart, so
    // Kotlin can wait for `proxy.tun.released` before closing the PFD.
    match kind_s.as_str() {
        "vpn.stop" => {
            let signalled = tun::request_stop();
            log_message(
                1,
                &format!("proxy: on_event vpn.stop -> request_stop signalled={signalled}"),
            );
        }
        "vpn.network_changed" => {
            // Kotlin already rebuilt the default interface; the datapath keeps
            // running. Log for observability (no engine restart here).
            log_message(1, "proxy: on_event vpn.network_changed");
        }
        _ => {}
    }
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
            logging::set_sink_attached(true);
        }
        // Route this module's own `log::` macros through the contract's
        // HostLogger so third-party log lines in the dependency graph also land
        // in the host LogBridge. Best-effort: logger install succeeds only once
        // per .so, so a repeated register is a no-op.
        let _ = gstore_contract::logging::attach_host_logger(e, log::LevelFilter::Info);
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
    use std::ffi::CString;

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
        std::mem::take(&mut *EMITTED.lock().unwrap_or_else(|e| e.into_inner()))
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
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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

    /// Machine-checkable frozen contract (Todo 18): every name the module claims
    /// to dispatch must actually dispatch — i.e. it must never answer a 405
    /// `METHOD_NOT_FOUND`. A dead instance yields a 410/422 domain error (which
    /// proves the arm exists), and the static-safe arms answer `ABI_OK`.
    #[test]
    fn every_dispatch_method_is_actually_dispatchable() {
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let api = register_api();
        let call = api.call.unwrap();

        for method in super::DISPATCH_METHODS {
            let (code, out) = call_json(call, 0, method);
            let is_method_not_found = code == ABI_ERR_DETAIL
                && serde_json::from_slice::<serde_json::Value>(&out)
                    .ok()
                    .and_then(|v| v["code"].as_str().map(|c| c == "METHOD_NOT_FOUND"))
                    .unwrap_or(false);
            assert!(
                !is_method_not_found,
                "documented method `{method}` is not dispatchable"
            );
            assert!(
                code == ABI_OK || code == ABI_ERR_DETAIL,
                "method `{method}` returned unexpected ABI code {code}"
            );
        }
    }

    /// Reverse direction: every dispatchable method name is documented verbatim
    /// in `API.md`. Combined with the Dart doc-vs-code test this makes the
    /// documentation↔code contract fail closed on either side.
    #[test]
    fn api_md_documents_every_dispatch_method() {
        let api = include_str!("../API.md");
        for method in super::DISPATCH_METHODS {
            assert!(
                api.contains(&format!("`{method}`")),
                "API.md is missing a row/heading for `{method}`"
            );
        }
    }

    /// Failure QA: a truncated JSON request payload is a structured 422 domain
    /// error, never a panic and never a 500.
    #[test]
    fn malformed_payload_is_structured_422() {
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("gstore-malformed-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let cfg = serde_json::to_vec(&serde_json::json!({
            "data_dir": dir.display().to_string(),
            "cache_dir": dir.display().to_string(),
        }))
        .unwrap();
        let mut inst: u64 = 0;
        assert_eq!(create(cfg.as_ptr(), cfg.len(), &mut inst), ABI_OK);

        for (method, payload) in [
            ("dns.set", &br#"{"nameservers":["#[..]),
            ("conn.close", &br#"{"id":"#[..]),
            ("profile.refresh", &br#"{"id":"#[..]),
            ("node.select", &br#"{"group":"#[..]),
        ] {
            let (code, out) = call_with_payload(call, inst, method, payload);
            assert_eq!(code, ABI_ERR_DETAIL, "{method}: malformed payload must be a domain error");
            let err: serde_json::Value = serde_json::from_slice(&out).unwrap();
            assert_eq!(err["status"], 422, "{method}: expected 422, got {err}");
            assert!(
                err["code"].as_str().map(|c| !c.is_empty()).unwrap_or(false),
                "{method}: expected a non-empty error code, got {err}"
            );
        }

        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(destroy(inst), ABI_OK);
    }

    #[test]
    fn alloc_free_and_on_event_are_panic_safe() {
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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

    /// Todo 24: host `vpn.stop` stops the loop without a restart, and the
    /// supervisor reports a *structured* dead-data-plane error (never masking the
    /// verbatim root cause).
    #[test]
    fn abi_vpn_stop_event_and_supervisor_structured_error() {
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let on_event = api.on_event.unwrap();
        let _ = take_events();

        let mut inst: u64 = 0;
        assert_eq!(create(std::ptr::null(), 0, &mut inst), ABI_OK);
        let (loop_end, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
        let payload = format!(r#"{{"fd":{}}}"#, std::os::fd::AsRawFd::as_raw_fd(&loop_end));
        let _ = call_with_payload(call, inst, "tun.set_fd", payload.as_bytes());
        let (code, _) = call_with_payload(call, inst, "core.start", br#"{"mode":"vpn"}"#);
        assert_eq!(code, ABI_OK);
        assert_eq!(tun::running_count(), 1);
        let _ = take_events();

        supervisor::on_death(inst, "reader task panicked: boom");
        let events = take_events();
        let state = events
            .iter()
            .find(|(t, p)| {
                t == "proxy.state" && String::from_utf8_lossy(p).contains("dataplane_dead")
            })
            .map(|(_, p)| p.clone())
            .expect("supervisor must emit a structured proxy.state on death");
        let v: serde_json::Value = serde_json::from_slice(&state).unwrap();
        assert_eq!(v["error"]["code"], "PROXY_DATAPLANE_DEAD");
        assert!(
            v["error"]["message"].as_str().unwrap_or("").contains("boom"),
            "root panic must not be masked: {v}"
        );
        assert_eq!(v["health"]["lastError"], "reader task panicked: boom");

        let kind = CString::new("vpn.stop").unwrap();
        assert_eq!(on_event(0, kind.as_ptr(), std::ptr::null(), 0), ABI_OK);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while tun::running_count() > 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert_eq!(tun::running_count(), 0, "vpn.stop must stop the reader");
        let _ = call_json(call, inst, "core.stop");
        supervisor::reset_for_tests();
    }

    /// Happy/failure QA over the real C ABI: invalid fd → structured error;
    /// valid fd → loop reads once → `proxy.state=running`; stop → joined +
    /// `proxy.tun.released`.
    #[test]
    fn abi_tun_fd_start_stop_and_release_event() {
        use std::io::Write as _;
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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

    /// Happy/failure QA over the real C ABI (Todo 10): `node.select` flips the
    /// effective outbound and emits `proxy.state`; `node.delay_test` turns an
    /// unreachable group into per-node `timeout` results and emits
    /// `proxy.node.delay`; `conn.list` returns a tracked fixture connection and
    /// `conn.close` signals it.
    #[test]
    fn abi_node_select_delay_and_conn_list() {
        use std::collections::HashMap;
        use std::sync::Arc;

        use meow_common::{ConnType, Metadata, Network, Proxy};
        use smallvec::SmallVec;
        use smol_str::SmolStr;

        use crate::nodes::tests::StubProxy;

        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        crate::conn::reset_for_tests();
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("gstore-nodes-abi-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let config = serde_json::to_vec(&serde_json::json!({
            "data_dir": dir.display().to_string(),
            "cache_dir": dir.display().to_string(),
        }))
        .unwrap();
        let mut inst: u64 = 0;
        assert_eq!(create(config.as_ptr(), config.len(), &mut inst), ABI_OK);
        let _ = take_events();

        let resolver = Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ));
        let _ = crate::dispatch::build_engine(resolver);
        let tunnel = crate::rules::active_tunnel().unwrap();

        let a = StubProxy::hanging("A");
        let b = StubProxy::hanging("B");
        let group: Arc<dyn Proxy> = Arc::new(meow_proxy::SelectorGroup::new(
            "G",
            vec![Arc::clone(&a) as Arc<dyn Proxy>, Arc::clone(&b) as Arc<dyn Proxy>],
        ));
        let mut map: HashMap<SmolStr, Arc<dyn Proxy>> = HashMap::new();
        map.insert(SmolStr::from("G"), group);
        tunnel.update_proxies(map);

        let (code, out) = call_with_payload(call, inst, "node.select", br#"{"group":"G","node":"B"}"#);
        assert_eq!(code, ABI_OK, "node.select: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["active"], "B");
        let events = take_events();
        assert!(
            events.iter().any(|(t, p)| t == "proxy.state"
                && String::from_utf8_lossy(p).contains("node.select")),
            "node.select must emit proxy.state; got {events:?}"
        );

        let (code, out) =
            call_with_payload(call, inst, "node.delay_test", br#"{"group":"G","timeoutMs":100}"#);
        assert_eq!(code, ABI_OK, "node.delay_test: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        let results = v["data"]["results"].as_array().unwrap();
        assert_eq!(results.len(), 2, "one timeout result per node");
        assert!(results
            .iter()
            .all(|r| r["error"] == "timeout" && r["delayMs"] == 0));
        let events = take_events();
        assert_eq!(
            events.iter().filter(|(t, _)| t == "proxy.node.delay").count(),
            2,
            "one proxy.node.delay per node"
        );

        let stats = tunnel.statistics();
        let cid = stats.track_connection(
            Metadata {
                network: Network::Tcp,
                conn_type: ConnType::Tun,
                host: "fixture.example".into(),
                dst_ip: Some("1.2.3.4".parse().unwrap()),
                dst_port: 443,
                src_ip: Some("10.10.0.2".parse().unwrap()),
                src_port: 40000,
                ..Default::default()
            },
            SmolStr::new("MATCH"),
            SmolStr::new(""),
            SmallVec::from_vec(vec![Arc::<str>::from("G")]),
        );
        let (code, out) = call_json(call, inst, "conn.list");
        assert_eq!(code, ABI_OK, "conn.list: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["count"], 1);
        assert_eq!(v["data"]["connections"][0]["id"], cid.to_string());
        assert_eq!(v["data"]["connections"][0]["domain"], "fixture.example");
        assert_eq!(v["data"]["connections"][0]["dst"], "1.2.3.4:443");
        assert_eq!(v["data"]["connections"][0]["outbound"], "G");

        let close = format!(r#"{{"id":"{cid}"}}"#);
        let (code, out) = call_with_payload(call, inst, "conn.close", close.as_bytes());
        assert_eq!(code, ABI_OK, "conn.close: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["closed"], true);
        assert_eq!(stats.active_connection_count(), 0);

        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(destroy(inst), ABI_OK);
        crate::conn::reset_for_tests();
        crate::rules::reset_for_tests();
    }

    /// Todo 17 happy/failure QA over the real C ABI: `conn.list` filtering +
    /// pagination, `conn.close` of a live connection (disappears + `proxy.conn`
    /// event), the idempotent re-close, and a structured `PROXY_CONN_NOT_FOUND`
    /// for an unknown id.
    #[test]
    fn abi_conn_list_filter_pagination_and_close() {
        use std::sync::Arc;

        use meow_common::{ConnType, Metadata, Network};
        use smallvec::SmallVec;
        use smol_str::SmolStr;

        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        crate::rules::reset_for_tests();
        crate::conn::reset_for_tests();
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let mut inst: u64 = 0;
        assert_eq!(create(std::ptr::null(), 0, &mut inst), ABI_OK);
        let _ = take_events();

        let resolver = Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ));
        let _ = crate::dispatch::build_engine(resolver);
        let tunnel = crate::rules::active_tunnel().unwrap();
        let stats = tunnel.statistics();

        let track = |host: &str, outbound: &str| {
            stats.track_connection(
                Metadata {
                    network: Network::Tcp,
                    conn_type: ConnType::Tun,
                    host: host.into(),
                    dst_ip: Some("1.2.3.4".parse().unwrap()),
                    dst_port: 443,
                    src_ip: Some("10.10.0.2".parse().unwrap()),
                    src_port: 40000,
                    ..Default::default()
                },
                SmolStr::new("DOMAIN-SUFFIX"),
                SmolStr::new(host),
                SmallVec::from_vec(vec![Arc::<str>::from(outbound)]),
            )
        };
        let a = track("a.example", "proxy-a");
        let b = track("b.example", "DIRECT");
        let _c = track("a.example", "proxy-b");

        let (code, out) = call_with_payload(call, inst, "conn.list", b"{}");
        assert_eq!(code, ABI_OK, "conn.list: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["count"], 3);
        assert_eq!(v["data"]["returned"], 3);
        let ids_first: Vec<String> = v["data"]["connections"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["id"].as_str().unwrap().to_string())
            .collect();

        let (code, out) =
            call_with_payload(call, inst, "conn.list", br#"{"domain":"A.EXAMPLE"}"#);
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["count"], 2, "domain filter is case-insensitive substring");
        assert!(v["data"]["connections"]
            .as_array()
            .unwrap()
            .iter()
            .all(|c| c["domain"] == "a.example"));

        let (code, out) =
            call_with_payload(call, inst, "conn.list", br#"{"outbound":"DIRECT"}"#);
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["count"], 1);
        assert_eq!(v["data"]["connections"][0]["id"], b.to_string());

        let (code, out) =
            call_with_payload(call, inst, "conn.list", br#"{"limit":2,"offset":0}"#);
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!((v["data"]["count"].as_u64(), v["data"]["returned"].as_u64()), (Some(3), Some(2)));
        assert_eq!(v["data"]["hasMore"], true);
        assert_eq!(v["data"]["offset"], 0);
        assert_eq!(v["data"]["limit"], 2);

        let (code, out) =
            call_with_payload(call, inst, "conn.list", br#"{"limit":2,"offset":2}"#);
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["returned"], 1, "second page holds the remainder");
        assert_eq!(v["data"]["hasMore"], false);

        let (code, out) = call_with_payload(call, inst, "conn.list", b"{}");
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        let ids_second: Vec<String> = v["data"]["connections"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(ids_first, ids_second, "paged order is stable across calls");

        let close = format!(r#"{{"id":"{a}"}}"#);
        let (code, out) = call_with_payload(call, inst, "conn.close", close.as_bytes());
        assert_eq!(code, ABI_OK, "conn.close: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["closed"], true);
        assert_eq!(v["data"]["alreadyClosed"], false);
        assert!(stats.connection_counters(a).is_none());

        let events = take_events();
        assert!(
            events.iter().any(|(t, p)| t == "proxy.conn"
                && String::from_utf8_lossy(p).contains("\"action\":\"close\"")
                && String::from_utf8_lossy(p).contains(&a.to_string())),
            "conn.close must emit proxy.conn; got {events:?}"
        );

        let (code, out) =
            call_with_payload(call, inst, "conn.list", br#"{"limit":2,"offset":2}"#);
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["count"], 2, "the closed connection is gone");

        let close = format!(r#"{{"id":"{a}"}}"#);
        let (code, out) = call_with_payload(call, inst, "conn.close", close.as_bytes());
        assert_eq!(code, ABI_OK, "already-closed close is idempotent");
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["closed"], false);
        assert_eq!(v["data"]["alreadyClosed"], true);

        let unknown = uuid::Uuid::new_v4();
        let close = format!(r#"{{"id":"{unknown}"}}"#);
        let (code, out) = call_with_payload(call, inst, "conn.close", close.as_bytes());
        assert_eq!(code, ABI_ERR_DETAIL, "unknown id must be a structured error");
        let err: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(err["code"], "PROXY_CONN_NOT_FOUND");
        assert_eq!(err["status"], 404);

        assert_eq!(destroy(inst), ABI_OK);
        crate::conn::reset_for_tests();
        crate::rules::reset_for_tests();
    }

    /// Happy/failure QA over the real C ABI for `profile.import_text` /
    /// `profile.import_link`, including the `proxy.subscription.added` event
    /// and the structured unknown-scheme rejection.
    #[test]
    fn abi_profile_import_text_and_link() {
        use base64::engine::general_purpose::STANDARD;
        use base64::Engine as _;
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();
        let _ = take_events();

        let mut inst: u64 = 0;
        assert_eq!(create(std::ptr::null(), 0, &mut inst), ABI_OK);

        let ss = format!(
            "ss://{}@1.2.3.4:8388#A",
            STANDARD.encode("aes-256-gcm:pw")
        );
        let encoded = STANDARD.encode(ss.as_bytes());
        let payload = serde_json::json!({"text": encoded, "name": "From Text"}).to_string();
        let (code, out) = call_with_payload(call, inst, "profile.import_text", payload.as_bytes());
        assert_eq!(code, ABI_OK, "import_text: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["nodeCount"], 1);
        assert_eq!(v["data"]["format"], "base64");
        assert_eq!(v["data"]["name"], "From Text");

        let link = format!(
            "ss://{}@1.2.3.4:8388#B",
            STANDARD.encode("aes-256-gcm:pw")
        );
        let payload = serde_json::json!({"link": link}).to_string();
        let (code, out) = call_with_payload(call, inst, "profile.import_link", payload.as_bytes());
        assert_eq!(code, ABI_OK, "import_link: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["format"], "shareLink");
        assert_eq!(v["data"]["nodes"][0]["type"], "ss");

        let (code, out) = call_with_payload(
            call,
            inst,
            "profile.import_link",
            br#"{"link":"xyz://a@b:1#c"}"#,
        );
        assert_eq!(code, ABI_ERR_DETAIL);
        let err: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(err["code"], "PROXY_SUB_SCHEME_UNSUPPORTED");

        let events = take_events();
        assert!(
            events
                .iter()
                .any(|(event_type, _)| event_type == "proxy.subscription.added"),
            "proxy.subscription.added must be emitted; got {events:?}"
        );

        assert_eq!(destroy(inst), ABI_OK);
    }

    /// Happy/failure QA over the real C ABI for the persistent profile store
    /// (Todo 12): import → create → list → get → update → delete, with the
    /// subscription events and a structured not-found. The files live under the
    /// instance data dir and survive a second store read.
    #[test]
    fn abi_profile_store_crud() {
        use base64::engine::general_purpose::STANDARD;
        use base64::Engine as _;
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("gstore-profiles-abi-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let config = serde_json::to_vec(&serde_json::json!({
            "data_dir": dir.display().to_string(),
            "cache_dir": dir.display().to_string(),
        }))
        .unwrap();
        let mut inst: u64 = 0;
        assert_eq!(create(config.as_ptr(), config.len(), &mut inst), ABI_OK);
        let _ = take_events();

        // Empty store lists nothing.
        let (code, out) = call_json(call, inst, "profile.list");
        assert_eq!(code, ABI_OK, "profile.list: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["count"], 0);
        assert_eq!(v["data"]["schemaVersion"], 2);

        // Import (Todo 11) then persist the canonical profile (Todo 12).
        let ss = format!("ss://{}@1.2.3.4:8388#A", STANDARD.encode("aes-256-gcm:pw"));
        let import = serde_json::json!({"link": ss}).to_string();
        let (code, out) = call_with_payload(call, inst, "profile.import_link", import.as_bytes());
        assert_eq!(code, ABI_OK, "import_link: {}", String::from_utf8_lossy(&out));
        let imported: serde_json::Value = serde_json::from_slice(&out).unwrap();
        let profile = imported["data"].clone();

        let create_payload = serde_json::json!({"profile": profile}).to_string();
        let (code, out) = call_with_payload(call, inst, "profile.create", create_payload.as_bytes());
        assert_eq!(code, ABI_OK, "profile.create: {}", String::from_utf8_lossy(&out));
        let created: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(created["data"]["id"], "p1");
        assert_eq!(created["data"]["profile"]["nodeCount"], 1);

        let (code, out) = call_json(call, inst, "profile.list");
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["count"], 1);
        assert_eq!(v["data"]["profiles"][0]["id"], "p1");

        let (code, out) = call_with_payload(call, inst, "profile.get", br#"{"id":"p1"}"#);
        assert_eq!(code, ABI_OK, "profile.get: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["profile"]["nodes"][0]["type"], "ss");

        let (code, out) = call_with_payload(call, inst, "profile.update", br#"{"id":"p1","name":"Renamed"}"#);
        assert_eq!(code, ABI_OK, "profile.update: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["profile"]["name"], "Renamed");
        assert_eq!(v["data"]["revision"], 2);

        // Failure QA: unknown id is structured 404, never a panic.
        let (code, out) = call_with_payload(call, inst, "profile.get", br#"{"id":"nope"}"#);
        assert_eq!(code, ABI_ERR_DETAIL);
        let err: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(err["code"], "PROXY_PROFILE_NOT_FOUND");
        assert_eq!(err["status"], 404);

        let events = take_events();
        assert!(
            events.iter().any(|(t, p)| t == "proxy.subscription.added"
                && String::from_utf8_lossy(p).contains("p1")),
            "proxy.subscription.added must fire; got {events:?}"
        );
        assert!(
            events.iter().any(|(t, _)| t == "proxy.subscription.updated"),
            "proxy.subscription.updated must fire; got {events:?}"
        );

        let (code, out) = call_with_payload(call, inst, "profile.delete", br#"{"id":"p1"}"#);
        assert_eq!(code, ABI_OK, "profile.delete: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["deleted"], true);
        let (code, out) = call_json(call, inst, "profile.list");
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["count"], 0);

        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(destroy(inst), ABI_OK);
    }

    /// Todo 13 happy + failure QA over the real C ABI: generate a template from
    /// a stored profile, start the engine with a socketpair fd, select the
    /// active node, prove an unreachable node is reported (not fatal), hot-apply
    /// a config change without a process restart, then stop.
    #[test]
    fn abi_config_generate_start_reload_and_failure_qa() {
        use std::os::unix::net::UnixStream;
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("gstore-config-abi-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let config = serde_json::to_vec(&serde_json::json!({
            "data_dir": dir.display().to_string(),
            "cache_dir": dir.display().to_string(),
        }))
        .unwrap();
        let mut inst: u64 = 0;
        assert_eq!(create(config.as_ptr(), config.len(), &mut inst), ABI_OK);
        let _ = take_events();

        let yaml = r#"
proxies:
  - {name: t1, type: trojan, server: 127.0.0.1, port: 1, password: pw, sni: example.com, skip-cert-verify: true}
  - {name: v1, type: vless, server: 127.0.0.1, port: 1, uuid: 11111111-2222-3333-4444-555555555555, tls: true, servername: example.com, network: ws, ws-opts: {path: /ws, headers: {Host: example.com}}}
proxy-groups:
  - {name: PROXY, type: select, proxies: [t1, v1]}
rules:
  - MATCH,PROXY
"#;
        let import = serde_json::json!({"text": yaml, "name": "Fixture"}).to_string();
        let (code, out) = call_with_payload(call, inst, "profile.import_text", import.as_bytes());
        assert_eq!(code, ABI_OK, "import_text: {}", String::from_utf8_lossy(&out));
        let imported: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(imported["data"]["nodeCount"], 2);
        let profile = imported["data"].clone();

        let create_payload = serde_json::json!({"profile": profile}).to_string();
        let (code, out) = call_with_payload(call, inst, "profile.create", create_payload.as_bytes());
        assert_eq!(code, ABI_OK, "profile.create: {}", String::from_utf8_lossy(&out));

        let (code, out) = call_with_payload(call, inst, "config.generate", br#"{"profileId":"p1"}"#);
        assert_eq!(code, ABI_OK, "config.generate: {}", String::from_utf8_lossy(&out));
        let generated: serde_json::Value = serde_json::from_slice(&out).unwrap();
        let doc = generated["data"]["config"].as_str().unwrap();
        assert!(doc.contains("type: trojan"), "{doc}");
        assert!(doc.contains("type: vless"), "{doc}");
        assert!(doc.contains("proxy-groups"), "{doc}");
        assert!(doc.contains("dns:"), "{doc}");
        assert!(doc.contains("enable: true"), "{doc}");
        assert!(!doc.contains("external-controller"), "{doc}");
        assert!(!doc.contains("secret:"), "{doc}");
        assert!(!doc.contains("file-descriptor"), "{doc}");
        assert_eq!(generated["data"]["counts"]["proxies"], 2);

        let (code, out) =
            call_with_payload(call, inst, "profile.export_clash", br#"{"id":"p1"}"#);
        assert_eq!(code, ABI_OK, "export_clash: {}", String::from_utf8_lossy(&out));
        let exported: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(exported["data"]["profileId"], "p1");
        assert!(exported["data"]["config"].as_str().unwrap().contains("proxies"));

        let (code, out) = call_with_payload(
            call,
            inst,
            "core.start",
            br#"{"mode":"vpn","profileId":"p1"}"#,
        );
        assert_eq!(code, ABI_ERR_DETAIL, "start without an fd is a structured error");
        let err: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(err["code"], "PROXY_TUN_FD_INVALID");

        let (loop_end, _peer) = UnixStream::pair().unwrap();
        let payload = format!(r#"{{"fd":{}}}"#, std::os::fd::AsRawFd::as_raw_fd(&loop_end));
        let (code, out) = call_with_payload(call, inst, "tun.set_fd", payload.as_bytes());
        assert_eq!(code, ABI_OK, "tun.set_fd: {}", String::from_utf8_lossy(&out));

        let (code, out) = call_with_payload(
            call,
            inst,
            "core.start",
            br#"{"mode":"vpn","profileId":"p1"}"#,
        );
        assert_eq!(code, ABI_OK, "core.start: {}", String::from_utf8_lossy(&out));
        let started: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(started["data"]["state"], "running");
        assert_eq!(started["data"]["profileId"], "p1");
        assert_eq!(started["data"]["proxies"], 2);
        assert_eq!(tun::running_count(), 1);

        let (code, out) = call_with_payload(
            call,
            inst,
            "node.select",
            br#"{"group":"PROXY","node":"v1"}"#,
        );
        assert_eq!(code, ABI_OK, "node.select: {}", String::from_utf8_lossy(&out));
        let selected: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(selected["data"]["active"], "v1");

        let (code, out) = call_with_payload(
            call,
            inst,
            "node.delay_test",
            br#"{"group":"PROXY","timeoutMs":400}"#,
        );
        assert_eq!(
            code,
            ABI_OK,
            "unreachable nodes must not fail the call: {}",
            String::from_utf8_lossy(&out)
        );
        let probe: serde_json::Value = serde_json::from_slice(&out).unwrap();
        let results = probe["data"]["results"].as_array().unwrap();
        assert_eq!(results.len(), 2);
        assert!(
            results.iter().all(|r| r["alive"] == false),
            "unreachable nodes must be reported as failed: {probe}"
        );

        let _ = take_events();
        let (code, out) = call_with_payload(
            call,
            inst,
            "config.apply",
            br#"{"profileId":"p1","rules":["DOMAIN,example.com,PROXY","MATCH,DIRECT"]}"#,
        );
        assert_eq!(code, ABI_OK, "config.apply: {}", String::from_utf8_lossy(&out));
        let applied: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(applied["data"]["applied"], true);
        assert_eq!(applied["data"]["rules"], 2);
        assert_eq!(applied["data"]["proxies"], 2);
        assert_eq!(tun::running_count(), 1, "hot reload keeps the same loop");
        let events = take_events();
        assert!(
            events.iter().any(|(t, _)| t == "proxy.config.applied"),
            "proxy.config.applied must fire; got {events:?}"
        );

        let (code, out) = call_json(call, inst, "core.stop");
        assert_eq!(code, ABI_OK, "core.stop: {}", String::from_utf8_lossy(&out));
        assert_eq!(tun::running_count(), 0);

        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(destroy(inst), ABI_OK);
    }

    /// Build a canonical 2-node import result without touching the network.
    fn fixture_import_text(call: CallFn, inst: u64) -> serde_json::Value {
        let yaml = "proxies:\n  - {name: n1, type: ss, server: 1.1.1.1, port: 8388, cipher: aes-256-gcm, password: pw}\n  - {name: n2, type: ss, server: 1.1.1.2, port: 8388, cipher: aes-256-gcm, password: pw}\nproxy-groups:\n  - {name: PROXY, type: select, proxies: [n1, n2]}\n";
        let payload = serde_json::json!({ "text": yaml, "name": "Fixture" }).to_string();
        let (code, out) = call_with_payload(call, inst, "profile.import_text", payload.as_bytes());
        assert_eq!(code, ABI_OK, "import_text: {}", String::from_utf8_lossy(&out));
        let value: serde_json::Value = serde_json::from_slice(&out).unwrap();
        value["data"].clone()
    }

    /// Todo 14 happy + failure QA over the real refresh state machine:
    /// success emits progress(started)→progress(succeeded)→updated with the new
    /// node count + userinfo; a failure emits progress + a structured
    /// `proxy.subscription.failed` and **preserves the previous profile**; the
    /// next non-forced refresh is refused by the bounded backoff.
    #[test]
    fn abi_profile_refresh_success_failure_and_backoff() {
        use subscription::{ImportedProfile, SubscriptionUserinfo};
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("gstore-refresh-abi-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let config = serde_json::to_vec(&serde_json::json!({
            "data_dir": dir.display().to_string(),
            "cache_dir": dir.display().to_string(),
        }))
        .unwrap();
        let mut inst: u64 = 0;
        assert_eq!(create(config.as_ptr(), config.len(), &mut inst), ABI_OK);
        let _ = take_events();

        let imported = fixture_import_text(call, inst);
        assert_eq!(imported["nodeCount"], 2);
        let mut stored = imported.clone();
        stored["source"]["origin"] = serde_json::json!("url");
        stored["source"]["url"] = serde_json::json!("http://127.0.0.1:9/sub");
        stored["userinfo"] = serde_json::json!({
            "upload": 100, "download": 200, "total": 1000, "expire": 1_700_000_000,
        });
        let create_payload = serde_json::json!({ "profile": stored }).to_string();
        let (code, out) = call_with_payload(call, inst, "profile.create", create_payload.as_bytes());
        assert_eq!(code, ABI_OK, "profile.create: {}", String::from_utf8_lossy(&out));

        let inst_arc = instance_of(inst).expect("instance registered");
        let store = profile::ProfileStore::open(&inst_arc.data_dir).unwrap();
        let _ = take_events();

        // Success via an injected import (no network in this test). The injected
        // profile carries the URL source so the stored record stays refreshable.
        let mut fetched: ImportedProfile = serde_json::from_value(imported).unwrap();
        fetched.source.origin = "url".to_string();
        fetched.source.url = Some("http://127.0.0.1:9/sub".to_string());
        fetched.source.user_agent = Some("clash.meta/1.19.0".to_string());
        fetched.userinfo = Some(SubscriptionUserinfo {
            upload: Some(10),
            download: Some(20),
            total: Some(100),
            expire: Some(1_800_000_000),
        });
        let result = perform_refresh(&inst_arc, &store, "p1", true, |_| Ok(fetched.clone())).unwrap();
        assert_eq!(result.state, "done");
        assert_eq!(result.node_count, 2);
        assert_eq!(result.userinfo.as_ref().unwrap().total, Some(100));

        let events = take_events();
        let started = events
            .iter()
            .position(|(t, p)| {
                t == EVT_SUBSCRIPTION_PROGRESS
                    && String::from_utf8_lossy(p).contains("\"started\"")
            })
            .expect("progress(started) must fire");
        let updated = events
            .iter()
            .position(|(t, _)| t == EVT_SUBSCRIPTION_UPDATED)
            .expect("updated must fire");
        assert!(started < updated, "progress(started) precedes updated: {events:?}");
        let updated_payload: serde_json::Value =
            serde_json::from_slice(&events[updated].1).unwrap();
        assert_eq!(updated_payload["profileId"], "p1");
        assert_eq!(updated_payload["nodeCount"], 2);
        assert_eq!(updated_payload["traffic"]["uploadBytes"], 10);
        assert_eq!(updated_payload["traffic"]["downloadBytes"], 20);
        assert_eq!(updated_payload["traffic"]["totalBytes"], 100);
        assert_eq!(updated_payload["traffic"]["usedBytes"], 30);
        assert_eq!(updated_payload["expireAtMs"], 1_800_000_000_000u64);

        // Failure: the previous profile stays, the failure is surfaced.
        let before = store.get(br#"{"id":"p1"}"#).unwrap();
        let err = ModuleError::new(
            StatusCode::InternalError,
            subscription::ERR_FETCH_FAILED,
            "connect refused",
        );
        let result = perform_refresh(&inst_arc, &store, "p1", true, |_| Err(err)).unwrap();
        assert_eq!(result.state, "failed");
        assert_eq!(result.error.as_ref().unwrap().code, subscription::ERR_FETCH_FAILED);
        assert_eq!(result.node_count, 2, "previous profile must be preserved");
        assert!(result.retry_after_ms.unwrap() > 0, "backoff must be scheduled");

        let after = store.get(br#"{"id":"p1"}"#).unwrap();
        assert_eq!(after.profile.node_count, before.profile.node_count);
        assert_eq!(after.profile.nodes[0].name, before.profile.nodes[0].name);
        assert!(after.profile.userinfo.is_some(), "old userinfo preserved");
        let refresh = after.refresh.clone().unwrap();
        assert_eq!(refresh.state, "failed");
        assert_eq!(refresh.consecutive_failures, 1);
        assert_eq!(refresh.error_code.as_deref(), Some(subscription::ERR_FETCH_FAILED));
        assert!(refresh.next_refresh_at_ms.unwrap() > now_ms());

        let events = take_events();
        assert!(
            events.iter().any(|(t, p)| t == EVT_SUBSCRIPTION_FAILED
                && String::from_utf8_lossy(p).contains(subscription::ERR_FETCH_FAILED)),
            "structured failed event must fire; got {events:?}"
        );
        assert!(
            events.iter().any(|(t, p)| t == EVT_SUBSCRIPTION_PROGRESS
                && String::from_utf8_lossy(p).contains("\"failed\"")),
            "progress(failed) must fire; got {events:?}"
        );

        // Bounded backoff: a non-forced refresh is refused, force bypasses it.
        let backoff = store.refresh(br#"{"id":"p1"}"#).unwrap_err();
        assert_eq!(backoff.code, profile::ERR_PROFILE_REFRESH_BACKOFF);
        assert_eq!(backoff.status as i32, 507);
        assert!(store.refresh(br#"{"id":"p1","force":true}"#).is_ok());

        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(destroy(inst), ABI_OK);
    }

    /// Todo 14 update-all QA: `profile.refresh_all` attempts each due profile
    /// once, skips backed-off profiles (no retry storm), and honours the
    /// per-profile interval schedule set through `profile.set_schedule`.
    #[test]
    fn abi_profile_refresh_all_bounded_backoff_and_scheduling() {
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let api = register_api();
        let create = api.create.unwrap();
        let call = api.call.unwrap();
        let destroy = api.destroy.unwrap();

        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("gstore-refresh-all-abi-{nanos}"));
        std::fs::create_dir_all(&dir).unwrap();
        let config = serde_json::to_vec(&serde_json::json!({
            "data_dir": dir.display().to_string(),
            "cache_dir": dir.display().to_string(),
        }))
        .unwrap();
        let mut inst: u64 = 0;
        assert_eq!(create(config.as_ptr(), config.len(), &mut inst), ABI_OK);

        let imported = fixture_import_text(call, inst);
        for (id, url) in [("p1", "http://127.0.0.1:9/sub"), ("p2", "http://127.0.0.1:9/other")] {
            let mut stored = imported.clone();
            stored["source"]["origin"] = serde_json::json!("url");
            stored["source"]["url"] = serde_json::json!(url);
            let payload = serde_json::json!({ "id": id, "profile": stored }).to_string();
            let (code, out) = call_with_payload(call, inst, "profile.create", payload.as_bytes());
            assert_eq!(code, ABI_OK, "create {id}: {}", String::from_utf8_lossy(&out));
        }
        let _ = take_events();

        // Batch 1: both are due and fail (SSRF-blocked loopback URL), no panic.
        let (code, out) = call_json(call, inst, "profile.refresh_all");
        assert_eq!(code, ABI_OK, "refresh_all: {}", String::from_utf8_lossy(&out));
        let first: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(first["data"]["attempted"], 2);
        assert_eq!(first["data"]["failedCount"], 2);
        assert_eq!(first["data"]["refreshed"].as_array().unwrap().len(), 2);
        assert_eq!(
            first["data"]["refreshed"][0]["error"]["code"],
            subscription::ERR_SSRF_BLOCKED
        );

        // Batch 2: both are inside the failure backoff window -> skipped.
        let (code, out) = call_json(call, inst, "profile.refresh_all");
        assert_eq!(code, ABI_OK);
        let second: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(second["data"]["attempted"], 0, "backoff must stop retry storms");
        let skipped = second["data"]["skipped"].as_array().unwrap();
        assert_eq!(skipped.len(), 2);
        assert!(skipped.iter().all(|s| s["reason"] == "backoff"), "{skipped:?}");

        // p1: schedule a 1h interval and run an injected success; p2 stays failed.
        let (code, out) = call_with_payload(
            call,
            inst,
            "profile.set_schedule",
            br#"{"id":"p1","intervalMs":3600000}"#,
        );
        assert_eq!(code, ABI_OK, "set_schedule: {}", String::from_utf8_lossy(&out));
        let scheduled: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(scheduled["data"]["refresh"]["intervalMs"], 3_600_000i64);

        let inst_arc = instance_of(inst).expect("instance registered");
        let store = profile::ProfileStore::open(&inst_arc.data_dir).unwrap();
        let mut fetched: subscription::ImportedProfile = serde_json::from_value(imported).unwrap();
        fetched.source.origin = "url".to_string();
        fetched.source.url = Some("http://127.0.0.1:9/sub".to_string());
        let result = perform_refresh(&inst_arc, &store, "p1", true, |_| Ok(fetched.clone())).unwrap();
        assert_eq!(result.state, "done");
        assert_eq!(result.interval_ms, Some(3_600_000));

        // Batch 3: p1 is not due (interval), p2 is backing off -> zero attempts.
        let (code, out) = call_json(call, inst, "profile.refresh_all");
        assert_eq!(code, ABI_OK);
        let third: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(third["data"]["attempted"], 0);
        let reasons: Vec<&str> = third["data"]["skipped"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["reason"].as_str().unwrap())
            .collect();
        assert!(reasons.contains(&"interval"), "{reasons:?}");
        assert!(reasons.contains(&"backoff"), "{reasons:?}");

        // force=true ignores the schedule and attempts both again.
        let (code, out) = call_with_payload(call, inst, "profile.refresh_all", br#"{"force":true}"#);
        assert_eq!(code, ABI_OK);
        let forced: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(forced["data"]["attempted"], 2);

        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(destroy(inst), ABI_OK);
    }

    /// Todo 15: `log.set_level` filters at the source and `log.get` paginates by
    /// monotonic cursor over the real C ABI; an unknown level is a structured
    /// 422, never a panic.
    #[test]
    fn abi_log_set_level_get_and_clear() {
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let api = register_api();
        crate::logging::reset_for_tests();
        let call = api.call.unwrap();

        let (code, out) = call_with_payload(call, 0, "log.set_level", br#"{"level":"warn"}"#);
        assert_eq!(code, ABI_OK, "set_level: {}", String::from_utf8_lossy(&out));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["level"], "warn");

        crate::log_message(1, "info-filtered");
        crate::log_message(2, "warn-retained");
        crate::log_message(3, "error-retained");

        let (code, out) =
            call_with_payload(call, 0, "log.get", br#"{"sinceCursor":0,"limit":10}"#);
        assert_eq!(code, ABI_OK);
        let page: serde_json::Value = serde_json::from_slice(&out).unwrap();
        let records = page["data"]["records"].as_array().unwrap();
        assert!(records.iter().all(|r| r["level"] != "info"), "{records:?}");
        assert!(records.iter().any(|r| r["message"] == "warn-retained"));
        assert!(page["data"]["dropped"].as_u64().unwrap() >= 1);
        let next = page["data"]["nextCursor"].as_u64().unwrap();
        assert_eq!(next, records.last().unwrap()["cursor"].as_u64().unwrap());

        let (code, out) =
            call_with_payload(call, 0, "log.get", br#"{"sinceCursor":0,"limit":1}"#);
        assert_eq!(code, ABI_OK);
        let first: serde_json::Value = serde_json::from_slice(&out).unwrap();
        let c1 = first["data"]["records"][0]["cursor"].as_u64().unwrap();
        let body = format!(r#"{{"sinceCursor":{c1},"limit":10}}"#);
        let (code, out) = call_with_payload(call, 0, "log.get", body.as_bytes());
        assert_eq!(code, ABI_OK);
        let rest: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert!(rest["data"]["records"][0]["cursor"].as_u64().unwrap() > c1);

        let (code, out) = call_with_payload(call, 0, "log.set_level", br#"{"level":"loud"}"#);
        assert_eq!(code, ABI_ERR_DETAIL);
        let err: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(err["code"], "PROXY_LOG_LEVEL_INVALID");
        assert_eq!(err["status"], 422);

        // clear drops the records but never rewinds the cursor.
        let (code, _out) = call_json(call, 0, "log.clear");
        assert_eq!(code, ABI_OK);
        let (code, out) = call_with_payload(call, 0, "log.get", br#"{"sinceCursor":0}"#);
        assert_eq!(code, ABI_OK);
        let cleared: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert!(cleared["data"]["records"].as_array().unwrap().is_empty());
        assert!(cleared["data"]["cursor"].as_u64().unwrap() > c1);

        crate::logging::reset_for_tests();
    }

    /// Todo 16 ABI round-trip: `stats.domain.get`, `stats.traffic.get` and
    /// `stats.domain.reset` plus the structured sort error.
    #[test]
    fn abi_stats_domain_traffic_and_reset() {
        let _g = ABI_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let api = register_api();
        let call = api.call.unwrap();
        crate::stats::reset_for_tests();

        let rec = crate::conn::ConnRecord {
            id: "s1".into(),
            src: "10.10.0.2:40000".into(),
            dst: "1.2.3.4:443".into(),
            domain: "abi.example".into(),
            network: "tcp".into(),
            rule: "DOMAIN-SUFFIX".into(),
            rule_payload: "abi.example".into(),
            outbound: "proxy-a".into(),
            started_at_ms: 1_700_000_000_000,
            upload_bytes: 40,
            download_bytes: 60,
        };
        crate::stats::observe_for_tests(&[rec], &[], crate::now_ms());

        let (code, out) = call_json(call, 0, "stats.domain.get");
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["domains"][0]["domain"], "abi.example");
        assert_eq!(v["data"]["domains"][0]["uploadBytes"], 40);

        let (code, out) = call_json(call, 0, "stats.traffic.get");
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["uploadBytes"], 40);
        assert_eq!(v["data"]["downloadBytes"], 60);

        let (code, out) = call_with_payload(call, 0, "stats.domain.get", br#"{"sort":"nope"}"#);
        assert_eq!(code, ABI_ERR_DETAIL);
        let err: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(err["code"], "PROXY_STATS_SORT_INVALID");
        assert_eq!(err["status"], 422);

        let (code, out) = call_json(call, 0, "stats.domain.reset");
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["cleared"], 1);

        let (code, out) = call_json(call, 0, "stats.traffic.get");
        assert_eq!(code, ABI_OK);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["data"]["domainCount"], 0);

        crate::stats::reset_for_tests();
    }
}
