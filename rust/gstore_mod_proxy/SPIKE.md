# gstore_mod_proxy — meow-rs Android cross-compile spike (Todo 1)

Risk-first spike for `.omo/plans/vpn-proxy-kernel.md` (Todo 1). Its job: prove the
meow-rs proxy kernel can be consumed as **libraries** from an external crate,
cross-compiled for Android with the project NDK, and that the lwIP netstack
datapath is reachable **without forking meow**.

- **Verdict (HARD GATE): the datapath IS viable without forking meow.** See §8.
- **On-device runtime: UNVERIFIED.** No adb device is attached; only the host
  `cargo test` selftest + cross-compile were run. See §7.

---

## 1. Pinned meow-rs revision

| | |
|---|---|
| Repo | `https://github.com/meow-rs/meow-rs.git` |
| Rev (exact) | `0e718f587442caaac00b221efc91c84907aeb0e0` |
| Short | `0e718f58` |
| Version | `0.21.2` (`[workspace.package].version`) |
| Pin style | `rev = "0e718f..."` on every dependency in `Cargo.toml` — **never a branch** |
| Why not a tag | **No git tag exists at this rev.** Upstream publishes no `v*` tag at `0e718f58`; a floating branch would silently move. An exact `rev` is the only reproducible pin. |

Dependencies pinned to this rev (`rust/gstore_mod_proxy/Cargo.toml`):
`meow-common`, `meow-tunnel`, `meow-config` (no-default-features),
`meow-proxy` (no-default-features), `meow-dns` (no-default-features),
`meow-api`, `meow-listener` (features `["listener-mixed"]`), and the netstack
crate `meow-lwip` (lib name `lwip`, renamed to `meow_lwip` in our manifest so the
spike can name it explicitly).

## 2. meow API surface actually available and callable

meow is a **library-first** workspace. `gstore_mod_proxy/src/lib.rs::meow_api_surface()`
address-takes every entry point the real module will use, so the Android link
step genuinely resolves each one (LTO cannot drop address-taken fns). Concrete
symbols (all public at `0e718f58`):

**Config build / subscription**
- `meow_config::subscription::fetch_subscription`
- `meow_config::subscription::parse_subscription_yaml`
- `meow_config::rebuild_from_raw`

**Tunnel dispatch**
- `meow_tunnel::Tunnel::{new, inner, update_proxies, update_rules}`
- `meow_tunnel::tcp::handle_tcp`, `meow_tunnel::udp::handle_udp`
- `meow_listener::MixedListener::{new, run}` (feature `listener-mixed`)

**DNS**
- `meow_dns::Resolver`, `meow_dns::ResolverSlot`, `meow_dns::new_resolver_slot`
- `Tunnel::new(resolver: Arc<meow_dns::Resolver>)` / `Tunnel::new_with_slot(ResolverSlot)`

**Stats**
- `meow_tunnel::statistics::Statistics` (published as `meow_tunnel::Statistics`),
  reachable as `tunnel.inner().stats: Arc<Statistics>`; per-connection
  `upload_bytes()` / `download_bytes()` / `snapshot()`.

**API server**
- `meow_api::routes::create_router`, `meow_api::ApiServer::run`

**Netstack (lwIP) — the datapath pieces the module drives directly**
- `meow_lwip::NetStack::{new, with_buffer_size, core_done}`
- `meow_lwip::{TcpListener, UdpSocket, TcpStream, UdpPkt}`
- `meow_proxy::DirectAdapter` (direct/proxy adapter type)

**Socket-protector hook (Android-only)**
- `meow_common::SocketProtector` (trait), `meow_common::set_socket_protector`
  (plus `clear_socket_protector`, `socket_protector`) — re-exported **only** under
  `#[cfg(target_os = "android")]` (`crates/meow-common/src/lib.rs:49-52`). The
  module installs a host-JNI `SocketProtector` so *every* outbound socket
  (TCP/UDP/DNS/libc `getaddrinfo`) is `VpnService.protect()`-ed through one hook.

**TUN-fd injection — NOT exposed by meow's listener; the module owns the fd**
- meow's public TUN entrypoint is `meow_listener::{TunListener, TunListenerConfig}`
  (`crates/meow-listener/src/lib.rs:45`). `TunListener::run` builds its **own**
  device via `tun_rs::DeviceBuilder` (`crates/meow-listener/src/tun/mod.rs:411`)
  — it does not accept a caller-supplied fd.
- For Android `VpnService.establish()` there is therefore **no meow-level fd
  injection path** (and we don't enable `listener-tun`/`tun-rs` anyway). Instead
  the module takes the raw fd from the host and drives
  `meow_lwip::NetStack` ingress/egress itself — exactly what the HARD GATE proves.
  This is the "use the netstack directly, don't fork meow" integration.

## 3. C/C++ dependency graph and CI packages

Rust → C/C++ edges that actually compiled:

```
gstore_mod_proxy
├── meow-lwip  → lwIP C sources (madeye fork, vendored in-tree)
│                build.rs compiles 36 C files via the `cc` crate
│                + bindgen over lwIP headers        → needs libclang
├── meow-transport/tls → BoringSSL (boring-sys 5.2.0, `boring` 5.2.0)
│                built with CMake + the NDK toolchain → needs cmake
│                BoringSSL's go.cmake `find_program(GO_EXECUTABLE go)`
└── (quiche NOT compiled — see below)
```

- **lwIP** (`meow-lwip`): vendored madeye fork pinned at
  `5f6f0dfe025c967157ff328d94efe488852d8755` (`crates/meow-lwip/Cargo.toml`);
  36 `.c` files compiled per ABI.
- **BoringSSL**: unavoidable. Even with `meow-proxy` default-features off, it
  unconditionally requires `meow-transport = { features = ["tls", "ws"] }`, which
  pulls `boring-sys`. This is why every built `.so` carries C++ symbols and the
  final `DT_NEEDED` includes `libc++_shared.so`.
- **quiche is NOT compiled.** `hysteria2` (the only quiche user) is behind
  `meow-proxy`'s defaults; we set `default-features = false`, so `quiche` is
  absent from `Cargo.lock` and from every build log. quiche would only appear if
  Hysteria2 support is later enabled — it shares BoringSSL, not a second TLS stack.

**Extra CI packages needed** (all present locally; build passed):
`cmake` (3.22.1) + `ninja` (1.10.1) for BoringSSL; `libclang` for bindgen —
provided by the NDK itself at
`.../ndk/26.3.11579264/toolchains/llvm/prebuilt/linux-x86_64/lib/libclang.so`
(`LIBCLANG_PATH` + `BINDGEN_EXTRA_CLANG_ARGS` are set in `.cargo/config.toml`);
`perl` + `go` (go1.24.1) as BoringSSL build-time tooling.

> Note (accurate, not parroted): at this pinned BoringSSL rev,
> `deps/boringssl/cmake/go.cmake:15-17` states *"Go is an optional dependency …
> necessary if running tests or the FIPS build"*, and our wrapper forces
> `BUILD_TESTING=OFF` (non-FIPS), so Go is not strictly required for this exact
> config; no Perl references remain in BoringSSL's CMake at this rev. CI should
> still install cmake, ninja, libclang, perl **and** Go to stay compatible with
> default/FIPS builds and future rev bumps.

## 4. Toolchain compatibility

- meow workspace `rust-version = "1.89"` (`meow-rs/Cargo.toml`).
- Installed: `rustc 1.92.0` / `cargo 1.92.0` → **1.92 >= 1.89 satisfies it.**
- Android targets installed: `aarch64-linux-android`, `x86_64-linux-android`,
  `armv7-linux-androideabi`, `i686-linux-android`.
- Project NDK: `26.3.11579264`.

## 5. Exact build command that worked

The crate's `.cargo/config.toml` supplies everything (NDK linker per target,
`CC_*/CXX_*/AR_*`, `LIBCLANG_PATH`, `BINDGEN_EXTRA_CLANG_ARGS*`,
`CMAKE_TOOLCHAIN_FILE`), so no extra env is needed:

```bash
cd rust/gstore_mod_proxy
cargo build --release --target aarch64-linux-android
# identical command per target:
#   cargo build --release --target x86_64-linux-android
#   cargo build --release --target armv7-linux-androideabi
#   cargo build --release --target i686-linux-android
```

The BoringSSL/Android CMake friction is resolved by
`cmake/android-toolchain-wrapper.cmake`: boring-sys early-returns when
`CMAKE_TOOLCHAIN_FILE` is set (`boring-sys/build/main.rs:237`), the wrapper
selects `ANDROID_ABI` from `CARGO_CFG_TARGET_ARCH`, sets `ANDROID_PLATFORM
android-33`, and forces `BUILD_TESTING=OFF` + `HAVE_STD_REGEX=1` so BoringSSL's
bundled benchmark does not try to execute a cross-compiled probe.

## 6. Which ABIs actually build — ALL FOUR

The plan expected armv7 might fail ("record and propose arm64+x86_64"). **It did
not** — all four ABIs cross-compile cleanly for the same code:

> ⚠️ The prior interrupted run's `.so` files predated the final `src/lib.rs`
> (source mtime 15:41 > artifact mtime 15:38), so they were stale w.r.t. the
> source being verified. All four were rebuilt from the current source during
> this task; the sizes below are the current, source-matching artifacts.

| ABI | Target triple | Release `.so` size | `file` |
|---|---|---|---|
| arm64-v8a | `aarch64-linux-android` | **933,992 B** | ELF 64-bit LSB shared object, ARM aarch64 |
| x86_64 | `x86_64-linux-android` | **930,512 B** | ELF 64-bit LSB shared object, x86-64 |
| armeabi-v7a | `armv7-linux-androideabi` | **452,400 B** | ELF 32-bit LSB shared object, ARM EABI5 |
| x86 | `i686-linux-android` | **936,692 B** | ELF 32-bit LSB shared object, Intel 80386 |

All are `stripped`, `LOAD` segment `p_align = 0x4000` (**16 KiB**, from
`-Wl,-z,max-page-size=16384`), and their `DT_NEEDED` set is only Android system
libs — **no host-only library**:

- aarch64 / x86_64 / i686: `libc++_shared.so`, `libdl.so`, `libc.so`
- armv7: `libdl.so`, `libc.so`

(`libc++_shared.so` is the NDK C++ runtime, shipped in the APK — expected because
BoringSSL is C++.)

## 7. Bounded tokio runtime + worker count (UNVERIFIED on device)

Only one runtime shape is permitted in this module
(`rust/gstore_mod_proxy/src/lib.rs::bounded_runtime`):

```rust
tokio::runtime::Builder::new_multi_thread()
    .worker_threads(4)          // bounded, NOT the CPU-default of Runtime::new()
    .enable_all()
    .thread_name("gstore-proxy")
    .build()
```

Never `Runtime::new()` — the CPU-default worker count has been observed to
SIGSEGV inside a dlopen'ed `.so` on Android
(`rust/gstore_mod_repo/src/lib.rs:117-120`); the same bounded pattern already
ships in `rust/gstore_mod_download/src/lib.rs:173-181`.

> **UNVERIFIED — no adb device attached.** Only the **host** `cargo test`
> selftest ran. The on-device behaviour of this runtime (worker count, stability
> under dlopen, fd shuttling against a real `VpnService.establish()` fd, socket
> protect) has **not** been observed and must not be claimed as passing.

## 8. HARD GATE verdict

`cargo test` on the host runs both required tests:

```
running 2 tests
test tests::probe_is_one ... ok
test tests::hard_gate_datapath_shuttles_packets_over_real_fd ... ok
test result: ok. 2 passed; 0 failed
```

`datapath_selftest()` report (actual values):

```
DatapathReport {
  stack_built: true,
  egress_frame_bytes: 40,
  egress_ip_version: 4,
  fd_delivered_bytes: 40,
  ingress_accepted: true,
  tcp_listener_pollable: true,
  tcp_flow_api_public: true,
  udp_flow_api_public: true,
}
```

Interpretation: `meow_lwip::NetStack` built on our bounded runtime; a UDP
datagram pushed into the stack made lwIP emit a real **40-byte IPv4** frame; that
frame was written to a **real fd** (`socketpair`) and received byte-identically;
it was then fed back into the netstack ingress `Sink` (accepted); and the
`TcpListener` accept stream stayed open/pollable (flow-dispatch handle alive).

**Verdict: the Android datapath IS viable without forking meow.** A host
`socketpair` stands in for the Android TUN fd; the same code path runs on device.
The remaining on-device unknowns are in §7 and are marked UNVERIFIED.

## 9. meow runtime-construction audit (required)

Question: does meow build its own tokio runtime / spawn an unbounded or CPU-default
worker set, and how does our module guarantee the `.so` never does?

**Findings (grep over `/tmp/opencode/proxy-research/meow-rs`):**

| Pattern | Location | Assessment |
|---|---|---|
| `new_multi_thread()` | `crates/meow-app/src/main.rs:370` and `:382` | **Binary only.** The standalone `meow` app; CPU-default workers (`.enable_all()` only). **We do not depend on `meow-app`**, so this is not linked into the module. |
| `#[tokio::main]` | `crates/meow-bench/src/main.rs:440` | Bench binary; not linked. |
| `new_current_thread()` | `crates/meow-config/src/rule_provider.rs:764` | Library, but **bounded 1-worker** runtime, built on a dedicated `std::thread::spawn` (`:763`) for a blocking rule-provider HTTP fetch. Not CPU-default, not unbounded. |
| `new_current_thread()` | `crates/meow-transport/src/reality_tls.rs:1880`, tests | Not on our path (test/edge). |
| `tokio::spawn(...)` | meow-tunnel/listener/lwip/dns/api/common (production code) | **Runtime-agnostic**: uses the ambient tokio handle. |
| `Handle::current` | only `crates/meow-dns/tests/...` | Tests only. |
| `worker_threads = N` | only `#[tokio::test(...)]` attributes | Tests only; not in the `.so`. |

**Decisive evidence** — `meow-lwip`'s `NetStack::new` spawns its core task on the
*current* runtime, it does not create one:

```
crates/meow-lwip/rust/stack.rs:36-37
    /// Build the stack and spawn the single-owner core task on the current
    /// tokio runtime. Must be called from within a runtime context.
crates/meow-lwip/rust/stack.rs:57
    tokio::spawn(parts.core.run());
```

`meow_tunnel::Tunnel::new` likewise only builds an `Arc<TunnelInner>`
(`crates/meow-tunnel/src/tunnel.rs:418-442`) — **no runtime construction**.

**Guarantee:** the module constructs its one bounded runtime
(`new_multi_thread().worker_threads(4)`) and builds every meow object
(`Tunnel`, `NetStack`, listeners, `ApiServer`) **inside** it, so
`tokio::spawn` resolves to `Handle::current()` = our 4-worker pool. meow's
library crates never call `Runtime::new()`; the only CPU-default
`new_multi_thread()` lives in the `meow-app` binary we do not link. Therefore the
`.so` cannot spawn an unbounded/CPU-default worker set. (The one library runtime
we don't control, `meow-config`'s `fetch_http_blocking`, is a single-worker
`new_current_thread` on a spawned thread — bounded, not CPU-default.)

## 10. Failure-QA: the NDK linker config is load-bearing

Forcing a build that bypasses the configured linker fails loudly and nonzero:

```bash
cd rust/gstore_mod_proxy
CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=/nonexistent \
  cargo build --release --target aarch64-linux-android
# exit code 101
```

Observed:

```
error: linker `/nonexistent` not found
  |
  = note: No such file or directory (os error 2)
error: could not compile `meow-lwip` (lib) due to 1 previous error
warning: build failed, waiting for other jobs to finish...
```

Then the normal build (no override, config linker in effect) still succeeds:

```bash
cargo build --release --target aarch64-linux-android   # exit 0
```

This proves `.cargo/config.toml`'s per-target NDK linker is actually consumed and
load-bearing — removing it breaks the link rather than silently using a host
toolchain.
