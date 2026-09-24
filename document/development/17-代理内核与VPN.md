# 代理内核与 VPN（Rust 模块 `gstore_mod_proxy` + Kotlin `ProxyVpnService`）

> 关联实现：`rust/gstore_mod_proxy/`（模块）、`rust/gstore_host/src/tun_bridge.rs`、
> `rust/gstore_host/src/jni_bridge.rs`、
> `android/app/src/main/kotlin/com/suno2/gstore/ProxyVpnService.kt`、
> `android/app/src/main/kotlin/com/suno2/gstore/VpnConsentActivity.kt`、
> `lib/core/service/proxy_vpn_service.dart`、`lib/core/rust/proxy/`、`lib/page/proxy/`。
> **模块方法/事件契约（权威）：[`rust/gstore_mod_proxy/API.md`](../../rust/gstore_mod_proxy/API.md)。**
> 架构风险与 ABI 契约：[`rust/ARCHITECTURE.md`](../../rust/ARCHITECTURE.md)。跨编译 spike：
> [`rust/gstore_mod_proxy/SPIKE.md`](../../rust/gstore_mod_proxy/SPIKE.md)。
> 错误码总表：[`rust/ERROR_CODES.md`](../../rust/ERROR_CODES.md)。计划来源：
> [`.omo/plans/vpn-proxy-kernel.md`](../../.omo/plans/vpn-proxy-kernel.md)。

本文是**运维与开发导览**：讲清架构、契约与边界，**不复制** [`API.md`](../../rust/gstore_mod_proxy/API.md)
的方法/事件表。要查某个方法的请求/响应 schema 或事件载荷，一律以 `API.md` 为准。

## 1. 目标与边界

目标：把「订阅导入 → 节点选择 → 连接 → 全设备流量经代理出站」收敛进一个原生内核，
Dart 侧只做展示与触发。

- **网络/解析/路由全在 Rust**（`gstore_mod_proxy`）：订阅抓取与解析、配置生成、
  meow 引擎、DNS、规则、节点/组、连接与统计、日志。
- **Kotlin 只负责 TUN 生命周期**：请求/建立 `VpnService` 隧道、持有
  `ParcelFileDescriptor`、前台服务存活、拆除时释放 fd。**不读取 TUN 数据**。
- **Dart 只负责触发与展示**：`ProxyVpnTrigger` 拉起授权/服务；页面消费信封与事件。
- 内核底座是 **meow-rs**，以 pinned rev `0e718f587442caaac00b221efc91c84907aeb0e0`
  以库形式消费，**不 fork**（见 `SPIKE.md` §8 的 HARD GATE 结论）。

## 2. 总体架构

```
Dart（展示/触发）
  ProxyVpnTrigger.prepare()  ──MethodChannel 'gstore/proxy_vpn'──►  MainActivity
  ProxyModule.invoke(...)    ──FRB─────────────────────────────►  gstore_host
                                                                     │
Kotlin（TUN 生命周期）                                                │
  VpnConsentActivity（系统授权）→ VpnService.Builder.establish()      │
  ProxyVpnService ─ nativeSetTunFd(fd) ──────────────────────────────┤
       ▲  nativeClear()                                      jni_bridge::TUN_FD
       │                                                          │
       │                                              tun_bridge::deliver_tun_fd_to
       │                                                          │ call "tun.set_fd"
       │                                                          ▼
       │                          ┌──────── gstore_mod_proxy（纯 Rust cdylib）────────┐
       │                          │  meow_tunnel::Tunnel（proxies / rules / dns）     │
       │                          │  meow_lwip::NetStack（TUN ingress/egress pump）   │
       │                          │  dispatch：TcpListener / UdpSocket → handle_tcp/udp│
       │                          │  Set SocketProtector（每条出站 socket）           │
       └── proxy.tun.released ◄───┤  事件：proxy.state / proxy.stats / proxy.conn …    │
                                  └───────────────────────────────────────────────────┘
                                              │ 出站 socket（经 protect seam）
                                              ▼
                                        真实网络 / 代理节点
```

关键分工：

| 层 | 职责 | 入口 |
|---|---|---|
| Dart | 触发授权/服务、调用模块、渲染 | `lib/core/service/proxy_vpn_service.dart`、`lib/core/rust/proxy/`、`lib/page/proxy/` |
| Kotlin | 建立/持有/关闭 TUN，前台服务，protect 实现 | `ProxyVpnService.kt`、`VpnConsentActivity.kt` |
| 宿主（`gstore_host`） | JNI fd 接收、fd 推送到模块、事件拦截 | `tun_bridge.rs`、`jni_bridge.rs` |
| 模块（`gstore_mod_proxy`） | 引擎、netstack pump、路由、DNS、规则、统计、日志 | `rust/gstore_mod_proxy/src/` |
| meow-rs | tunnel / lwip / config / proxy / dns / listener / api | pinned rev，见 `SPIKE.md` |

## 3. ABI v3 `protect_fd` 契约

`GSTORE_MODULE_ABI_VERSION = 3`（定义于 `rust/gstore_contract/src/abi.rs`）。

- v2 追加 `Api::on_event`（宿主→模块事件）；**v3 追加 `Entry::protect_fd`**
  （宿主→模块 socket 保护），是严格**末尾追加、禁止重排**。
- 宿主握手 gate：`min_host_abi > GSTORE_MODULE_ABI_VERSION` 才拒绝挂载，**无精确匹配**；
  末尾追加字段因此对**宿主侧握手**前向兼容。
- **但既有模块在 register 时还做模块侧精确匹配** `e.abi_version != GSTORE_MODULE_ABI_VERSION`
  （`rust/gstore_mod_qr/src/lib.rs`:443、`rust/gstore_mod_repo/src/lib.rs`:372、
  `rust/gstore_mod_llm/src/lib.rs`:236、`rust/gstore_mod_download/src/lib.rs`:595、
  `rust/gstore_mod_analyzer/src/lib.rs`:405）。因此**预编译/缓存下来的 ABI-2 `.so` 会被
  v3 宿主拒绝**（`ABI_ERR_ABI_MISMATCH`）；只有针对 ABI 3 重新编译的模块才能挂上。
  本模块 `gstore_mod_proxy` 是新模块，已用放宽的 `e.abi_version < GSTORE_MODULE_ABI_VERSION`。
- **决策（rebuild-on-update）**：升级到宿主 ABI v3 时，内置模块随 `build_android_rust.sh`
  统一重编为 ABI 3（**不删除**用户缓存模块）；**仅远程分发的下载型模块（`gstore_mod_llm`）
  升级后必须重新下载**，旧的 ABI-2 `.so` 不再挂载。
  > 运维提示：升级到宿主 ABI v3 后，重新拉取下载型模块。
- **未来可选**：把模块侧 `!=` 放宽为 `e.abi_version < GSTORE_MODULE_ABI_VERSION`，即可让
  v2 `.so` 真正兼容 v3 宿主（本次决策不改 ABI / 模块侧检查）。
- 模块读新槽前**必须**用 `entry.entry_size` 守卫（`protect_fd_if_present()`），
  旧宿主下不得越界读。
- 决策记录见 `rust/ARCHITECTURE.md` §10 决策 #7；`proxy` 模块 `min_host_abi = 3`
  （`ping`/`version` 会回报 `minHostAbi`）。

`protect_fd` 是代理域把 `VpnService.protect()` 接进 meow **唯一**的宿主钩子：模块
在 `core.start` 时把它装成 meow 的全局 `SocketProtector`，停止时清除（见 §4.3）。

## 4. fd / protect 契约（钉死项）

### 4.1 fd 所有权

- **Kotlin 持有 `ParcelFileDescriptor` 作为唯一所有者**；**不** `detachFd`，只把
  `pfd.fd` 原始整数交给 Rust（`nativeSetTunFd`）。
- 模块 `dup()` 该 fd、在副本上设 `O_NONBLOCK`，**永不 close 宿主 fd**。
  `O_NONBLOCK` 是 file-status flag、由文件描述共享，所以宿主 fd 上同样可见。
- 拆除顺序：模块 `core.stop` 停止读取循环 → join 线程 → 发 `proxy.tun.released` →
  宿主清缓存 → Kotlin `nativeClear()` → `ParcelFileDescriptor.close()`。
- `proxy.tun.released` 由模块在**读取循环完全停止并 join 之后**发出，宿主
  `tun_bridge::on_module_event` 只清对应 fd 的缓存，不替 Kotlin 关 fd。

### 4.2 单一读取者（single-reader invariant）

- 进程内**恰好一个 TUN 读取循环**：模块状态最多持有一个 `ActiveLoop`。
- `core.start` 运行中幂等；`tun.set_fd` 在替换 fd 前会**完整 join** 旧循环。
- fd 交付与「Dart 何时挂载模块」**顺序无关**：`nativeSetTunFd` 立即尝试调用
  `proxy` 模块的 `tun.set_fd`；若模块尚未挂载，fd 保留在宿主，待
  `ModuleManager::register_inner` 时补发（host-push with pending retention +
  flush-on-mount，见 `rust/gstore_host/src/tun_bridge.rs`）。`tun.set_fd` 是
  **实例无关**的模块级方法（一个代理进程只有一个 tunnel，lwIP 的 pcb 列表是进程全局）。

### 4.3 protect seam（出站 socket 保护）

- 模块在 `core.start`（引擎初始化）时把宿主注入的 `entry.protect_fd` 装为 meow 的
  全局 `SocketProtector`（Android-only API）；每条出站 `connect()`/`bind()` 前 meow 都会调用它。
- 解析走独立的 `HostResolver` 钩子（`meow_dns::ResolverHostHook`），使
  `connect_tcp_host` 不回落 libc `getaddrinfo`（否则其 DNS socket 未保护、会绕回隧道）。
- `protect_fd` 返回非 0 时中止拨号并返回 `PROXY_PROTECT_FAILED` (500)，socket 在任何
  流量前丢弃——**不会静默跳过保护**。
- 模块自身**无裸出站 client**（无 `reqwest`/`hyper`/`ureq`，无直接 `TcpStream::connect`）；
  订阅/geo 抓取必须走 meow 的 protect-aware transport 或模块 `protect::connect_tcp` /
  `protect::bind_udp`。不做 `addDisallowedApplication(self)` 修环路，**`protect_fd` 是唯一机制**。

### 4.4 bounded runtime（有界运行时）

- 模块**只允许**一种运行时形态：`tokio::runtime::Builder::new_multi_thread()
  .worker_threads(4)`，由 `rust/gstore_mod_proxy/src/lib.rs::bounded_runtime` 构建。
- **绝不 `Runtime::new()`**：CPU 默认 worker 数在 dlopen 的 `.so` 内曾在 Android
  触发 SIGSEGV（同 `rust/gstore_mod_repo/src/lib.rs` 的教训；`gstore_mod_download`
  亦用同一 bounded 模式）。`SPIKE.md` §9 证明 meow 库 crate 不自建运行时，只会
  `tokio::spawn` 到当前 handle（本模块的 4-worker 池）。TUN loop 的运行时在专属线程内构建。
- 延迟探测/DNS 下载等在**独立** bounded runtime 上跑，绝不阻塞 tunnel loop。

## 5. 模块方法与事件（指针，不复制）

方法/事件的**权威表在 [`rust/gstore_mod_proxy/API.md`](../../rust/gstore_mod_proxy/API.md)**。
本文只给分组导航，避免两处维护同一份契约：

| 分组 | 方法 | 看 API.md |
|---|---|---|
| 生命周期/模式 | `ping`、`version`、`core.start/stop/restart/get_mode/set_mode`、`tun.set_fd` | §2.1–§2.3.1 |
| 订阅与配置 | `profile.*`、`config.generate/apply`、`profile.export_clash` | §2.4–§2.5 |
| 路由/选择 | `node.*`、`rules.*` | §2.6、§2.11 |
| DNS | `dns.get/set/clear_cache/flush_cache` | §2.7 |
| 诊断/可观测 | `log.*`、`stats.*`、`conn.*`、`diagnostics.clash_api.*` | §2.8–§2.10、§2.13 |
| 请求采集/导出 | `requests.get`、`requests.reset`、`requests.export`（每请求时间线：游标分页、筛选、CSV/JSON 导出） | §2.14 |
| 抓包与改写 | `capture.config.*`、`capture.ca.*`、`captures.*`、`capture.rules.*`（MITM 抓包时间线、CA 生命周期、HTTP 改写规则） | §2.16–§2.19 |
| 事件（模块→宿主） | `proxy.state`、`proxy.mode`、`proxy.stats`、`proxy.conn`、`proxy.dns`、`proxy.request`、`proxy.subscription.*`、`proxy.tun.released`、`proxy.config.applied` 等 | §3 |
| 宿主内部事件（方向见 §4） | **模块→宿主、宿主消费、不进 Dart 事件环**：`proxy.uid.query`（`requests::tick` 在 VPN 模式下为 TCP 流发起的归属查询，宿主消费并丢弃，Dart 永远收不到）；**宿主→模块回填**（`on_event` kind）：`uid.result`（宿主回填 `uid`/`packages`，模块据此把 `uidState` 从 `pending` 收敛为 `known`/`unknown`） | §4 |

契约已冻结并被机械校验：Rust 测试保证 `DISPATCH_METHODS` 每个名字都可调度且在
`API.md` 中出现；Dart 测试解析 `API.md` 并断言其方法/事件集等于
`lib/core/rust/proxy/ProxyContract.dart` 的注册表。**改契约必须三处同步**
（dispatch、`API.md`、Dart registry），否则测试失败。

本次请求采集新增的契约共**三个原子单元**，均已同步落下：**Todo 5** 方法层
（`requests.get`/`requests.reset`）、**Todo 10** 导出（`requests.export`，挂在 `API.md §2.14`）、
**Todo 6** 事件层（`proxy.request` 脏信号 + §4 的 `proxy.uid.query`/`uid.result` 文档）。
其中 `proxy.request` 进 Dart 事件注册表，而 `proxy.uid.query`/`uid.result` 是宿主↔模块内部
lane，**不进** Dart 事件环。

### 5.1 MITM / 抓包 / 改写（`capture.config.*` / `capture.ca.*` / `captures.*` / `capture.rules.*`）

**做什么。** 在 TUN 的 TCP 数据面内联 TLS 终止，按白名单**只解密选定流量**，其余
逐字节直通（绝不越权拦截）。解密后的 HTTP/1.1、HTTP/2 与 WebSocket 记入 `captures.*`
时间线；`capture.rules.*` 把命中的请求改写为「替换响应」或「本地响应（不请求上游）」。
方法、字段与状态码 schema 一律以 `API.md` §2.16 至 §2.19 为准，本节只讲机制与边界。

**抓包开关与范围（`capture.config.*`，默认全 OFF）。**

- `enabled` 是总开关：`false` 时每条流都保持隧道直通，不做任何 TLS 终止。
- `domainAllowlist` 是**主白名单**（按嗅探到的 SNI / host 匹配），非空时只有命中的 host
  才解密；`appAllowlist` 是**尽力而为**白名单（包名 / UID 字符串），**仅在
  `domainAllowlist` 为空时生效**。
- `tlsPorts`（默认 `[443, 8443]`）决定参与 MITM 的目标端口；`captureBody` /
  `captureWs` / `captureH2` 逐项开关内容；`maxBodyBytes` 是**落盘** Body 上限
  （SQLite 专用，不驻留内存）。
- 配置变更**只作用于新流**：进行中的 MITM 会话保留其启动时的配置快照，中途改设置
  不会让一个会话处于自相矛盾的抓包状态。

**CA 生命周期（`capture.ca.*`）。** CA 由 `rcgen` 生成；叶证书按 SNI 由 `rustls` 的
自定义 `ResolvesServerCert` 动态签发并有界缓存。CA 私钥以 `0600` 存放在
`<dataDir>/mitm/ca.key`，**绝不进入日志或事件载荷**。`capture.ca.get` 在尚未生成时
**不是错误**（返回 `generated:false` 与空字段）；`capture.ca.generate` 幂等（带
`regenerate:true` 才轮换，并连同按 host 的叶证书缓存一起丢弃）；`capture.ca.reset`
删除材料并丢弃进程内句柄，旧叶证书立即不再被服务。

**抓包时间线（`captures.*`）。** 有界内存环 + SQLite（`proxy_captures.db`）滚动持久化，
**拉取式**读取：`captures.get` 游标分页，`proxy.request` 是唯一脏信号，绝不逐条推送。
`CaptureRecord.requestRecordId` 关联同一条流的 `requests.*` 记录（唯一 join key；`0`
表示跨 tick 的短命流，抓包记录独立存在）；`captures.detail` 按 `recordId` 读取完整
Body / 头 / WS 帧。

**实时改写（`capture.rules.*`，执行在 MITM 路径）。** 解密后的 h1/h2 请求按**精确 URL
（+ 可选 method）**匹配**启用**规则（规则默认 OFF）。`kind:"local"` 不请求上游、直接返回
规则的状态 / 头 / Body；`kind:"replace"` 正常请求上游后覆盖状态 / 头 / Body，未覆盖的头
保留上游值。规则 `respBody` 视为**已解码明文**，任何 Body 覆写都会强制
`Content-Encoding: identity` 并重算 `Content-Length`（绝不会保留上游 gzip 却发送明文，
避免损坏响应）。命中 `hitCount++`。未命中流量**逐字节原样转发**。`delayMs` 仅存储、
**不注入延迟**。

**限制（务必如实告知用户，UI 也必须诚实提示）。**

- **非 root 抓不到任意 App**：MITM 依赖设备信任我们的 CA。无 root 只能引导安装**用户
  证书**；Android 7+ 默认不信任用户证书的应用（大量第三方 App）无法被解密。**不绕过
  证书固定（pinning）**。
- **UDP / QUIC 不抓**：只处理 TCP；HTTP/3（QUIC/UDP）流量不终止、不记录。
- **WS 只抓帧、不支持改写**：WebSocket 帧可捕获展示，但 `capture.rules.*` **不改写** WS 帧。

## 6. 运行模式（off / vpn / lanProxy）

- `core.set_mode` / `core.get_mode` 暴露模式；模式状态机与切换序列在**计划 Todo 29**
  落地（当前 `lanProxy` 尚无入站，Todo 28 提供 LAN listener 前返回 `PROXY_NO_INBOUND`）。
- `vpn`：起 `VpnService` → `establish()` → fd → Rust TUN reader，并安装
  `SocketProtector`（每条出站受保护）。
- `lanProxy`：**无 `VpnService`、无 TUN reader、不装 protect**，只跑引擎 + LAN 入站。
- `off`：引擎停止、listener 关闭、服务停止。
- 切换必须在**单一变更通道串行**：先完整停当前模式（停 reader → join → 清 protect →
  停服务）再起下一个；幂等；**只重启 tunnel + engine，绝不重启进程**。
- 细节与验收以 [`API.md`](../../rust/gstore_mod_proxy/API.md) §2.3 与计划 Todo 29 为准。

## 7. 构建与分发

```bash
# 只构建代理模块（4 个 ABI；产物进 rust/release-modules/<abi>/，不进 APK）
./build_android_rust.sh --module gstore_mod_proxy

# 全量构建也会带上本模块（已列入脚本 MODULES）
./build_android_rust.sh
```

- 构建配置全在 `rust/gstore_mod_proxy/.cargo/config.toml`：per-target NDK linker、
  `LIBCLANG_PATH`、`CMAKE_TOOLCHAIN_FILE`；BoringSSL/lwIP 的 Android CMake 摩擦由
  `rust/gstore_mod_proxy/cmake/android-toolchain-wrapper.cmake` 解决（`SPIKE.md` §5）。
- 依赖：`cmake`、`ninja`、`libclang`（NDK 自带）、`perl`、`go`（BoringSSL 构建工具链）。
- 生成发布清单与内置清单：

  ```bash
  ./generate_modules_manifest.sh
  ```

  产出 `rust/release-modules/modules.json`（Flat 清单 v2，含 sha256/size、per-ABI）
  与 `assets/app/modules_builtin.json`。
- **分发决策（当前）**：`proxy` 是**可下载模块**（GitHub Release 资产，经
  `ModuleBootstrap` 获取），**不进完整包/精简包**；`scripts/ci/assert_apk_module_payload.sh`
  以负向断言强制排除 `libgstore_mod_proxy.so`。Todo 25 负责打包/manifest/CI 断言
  与可能的策略翻转，翻转时必须同步 `API.md` §6 与断言。体积预算见 `API.md` §6。

## 8. 失败模式

| 现象 | 根因方向 | 证据/处理 |
|---|---|---|
| `core.start` 无 fd / fd 非法 | Kotlin 未 `establish()`，或 fd 已关闭/不可 `dup` | `PROXY_TUN_FD_INVALID` (422)，`API.md` §2.3.1 |
| 出站全部失败、`PROXY_PROTECT_FAILED` | `protect_fd` 返回非 0（同意被撤/服务未起） | §4.3；`PROXY_PERMISSION_DENIED` (403) |
| 拨号绕回隧道（环路） | protect 未安装 / `addDisallowedApplication` 被误当机制 | §4.3，排查 meow hook 安装与 teardown 清除 |
| Android 上 SIGSEGV | 模块用了 `Runtime::new()` / CPU 默认 worker | §4.4，检查 `bounded_runtime` |
| 两个读取者 / fd 竞争 | `tun.set_fd` 未先 join 旧循环；或重复 `core.start` | §4.2 单一读取者 |
| 停止后 fd 泄漏/崩溃 | 拆除顺序错（先 close 后 `nativeClear`） | §4.1 顺序；`proxy.tun.released` 未发出 |
| 进程存活但网络不通（数据面静默死亡） | reader/ingress/egress 线程 panic 或提前结束，无人感知 | Todo 24 守护：结构化 `proxy.state`（`error.code=PROXY_DATAPLANE_DEAD` + 原始原因）+ 有界退避重启；`API.md` §18 |
| VPN 权限被别的 VPN 抢占 | 系统回调 `onRevoke` | Kotlin 发结构化 `proxy.state`（`reason:"vpn_revoked"`）+ 干净停止；`API.md` §18.4 |
| 切 Wi-Fi/蜂窝/飞行模式后断流 | 底层默认网络变化 | Kotlin `setUnderlyingNetworks(null)` 重建默认接口（事件驱动，无重试循环）；`network_changed` 事件 |
| 进程被系统杀死后隧道不在 | always-on null-Intent 重启 | 读持久化配置重建隧道 + `always_on_restart` 事件；Flutter 首帧检测「服务在跑但引擎已停」→ `core.start` 恢复；`API.md` §18.4 |
| Flutter engine / isolate 重启后收不到事件 | 宿主仍持有上一个 isolate 的失效端口 | `HostInspector.reset_bridges` 只丢 log/event/task 订阅端口，**不拆隧道**；新 isolate 重订阅补发；`API.md` §18.3 |
| 订阅抓取失败/被 SSRF 拦截 | URL 非 http(s)、指向私网、超时、体积超限 | `PROXY_SUB_*`，`API.md` §5 与 `ERROR_CODES.md` |
| 节点未生效 | 协议 feature 未编译进去（`hysteria2` 等）| `PROXY_CONFIG_NODE_UNSUPPORTED` 警告，`API.md` §13.2 |
| DNS 无应答/超时 | 上游不可达、bootstrap 非明文、加密上游构建失败 | `PROXY_DNS_*`，`API.md` §9、§5 |
| `conn.close` 报 404 | id 从未被本模块跟踪 | `PROXY_CONN_NOT_FOUND`，`API.md` §2.10 |
| 未知方法 405 | 方法名不在冻结 dispatch | `METHOD_NOT_FOUND`，`API.md` §17 |
| Clash 面板起不来 | 无运行中 tunnel 或 `127.0.0.1` 绑定失败 | `PROXY_NOT_CONFIGURED` (409) / `PROXY_CLASH_API_FAILED` (500)，`API.md` §2.13 |
| 模块挂不上 | ABI 不匹配/`min_host_abi` 过高/签名/哈希 | `rust/ARCHITECTURE.md` §7、`rust/ERROR_CODES.md` 协议层码 |

通用原则：`extern "C"` 入口全部 `catch_unwind`，panic 转 `PANIC_CAUGHT` (5001)，
不炸进程；模块 `panic = "unwind"`，宿主保持 `abort`（跨 `.so` 边界安全）。

## 9. 如何替换引擎：meow-rs → clash-rs

模块把 meow 当作**可替换的库底座**，替换面被刻意收敛（这也是「引擎可换而不动 Dart」
的验收条件）：

1. **契约面不变**：Dart 只经 FRB 信封与 `proxy.*` 事件交互，不直接 speak meow 的
   任何 API（normal operation 不调用 Clash HTTP API）。替换引擎**不改 Dart**。
2. **替换点集中在模块内部**：
   - 引擎装配与调度：`rust/gstore_mod_proxy/src/dispatch.rs`（`build_engine` /
     `Dispatcher` / TUN loop）与 `rust/gstore_mod_proxy/src/tun.rs`。
   - 网卡/socket 保护：`rust/gstore_mod_proxy/src/protect.rs`（`connect_tcp` /
     `bind_udp` + meow `SocketProtector` 安装）。
   - 配置/订阅/规则/节点：`config.rs`、`subscription/`、`rules.rs`、`nodes.rs`、`dns.rs`。
   - 出站 I/O 与 runtime：`bounded_runtime`（`lib.rs`）+ 各 adapter。
3. **clash-rs 对应能力**：clash-rs 亦为 lib+bin 结构，提供 tunnel/规则/DNS/统计，
   但 API 命名、netstack（clash-rs 用 tun-rs 的 fd 入口）与 protect 钩子不同。
   实际替换就是把上述模块内部文件换成 clash-rs 的等价装配；`fd` 交付仍走
   `tun.set_fd`（clash-rs 的 TUN 入口需要「从外部 fd 建 device」，与 meow 一样需自驱
   netstack/device，而不是调用其自带 listener 的 fd）。
4. **必须重验的不变量**：单读取者、fd 所有权（§4.1）、出站全保护（§4.3）、bounded
   runtime（§4.4，clash-rs 若自带运行时需评估其 worker 数）、`proxy.*` 事件/方法载荷
   与 `API.md` 一致。契约冻结测试（`API.md` ↔ dispatch ↔ Dart）应在替换后**无需改动**地
   继续通过——若它们要改，说明替换泄漏到了契约层，属于错误方向。
5. **Clash HTTP 控制器**不是替换点：`diagnostics.clash_api.*` 只是诊断用嵌入，不由
   Dart 用于正常业务；换引擎时该诊断面可整体去掉而不影响 UI。

## 10. 已知未验证项（务必阅读）

以下路径**无 adb 真机**，不得声称已通过；host 侧只用 Linux loopback / socketpair
harness 证明机制：

> **测试形态说明（计划偏差，设备前置条款）**：计划原定用**设备侧 `integration_test/`
> harness**（Todos 4/6/7/24/27/28/29 要求连接 adb 真机）验证隧道行为；本次开发环境
> **无可用 Android 设备**，故改由 **host Linux loopback / socketpair harness** 覆盖
> **fd 交付、protect seam、stats、teardown** 四条机制路径的断言，设备侧 `VpnService`
> 路径按下方清单标注为 **UNVERIFIED**。

- `VpnService.establish()` 真实 fd 的 ioctl/`dup`/`O_NONBLOCK` 行为与真机 VpnService 生命周期。
- 真机 `VpnService.protect()` 与 meow `set_socket_protector` 的集成（Android-only 编译路径）。
- 真机 TUN 数据面吞吐、稳定性与 ANR（Todo 27 明确）。
- 真机 Private DNS（DoT/853）行为与 fake-IP 的交互（`API.md` §9.3）。
- 真机订阅抓取/protect 下的 fetch、geo 下载、真实延迟探测。
- 真机模块 reload/卸载后的持久化状态（profile store、统计库）读回。
- 真机 Clash 面板绑定与第三方面板对接。
- 真机 VpnService 生命周期：`onRevoke` 撤销、飞行模式/网络切换重连、`am force-stop` 后
  always-on 重启、start→stop→start 线程基线（Todo 24；host 侧只能证明 fd/守护/桥重置机制）。
- **设备侧 CA 安装（Todo 17/19，UNVERIFIED）**：用户证书安装流
  （`KeyChain.createInstallIntent`（≤API 30）+ `Settings` 安全设置引导）与 root / 系统证书
  路径（Magisk / `nsenter` bind-mount；Android 14+ 按 NVISO 方案覆盖 APEX 的
  `/apex/com.android.conscrypt`）**无设备可验**。host 侧只证明 IPC 契约与安装状态回传；
  真机上目标 App 是否信任该证书、APEX 覆盖是否生效、非 root 下究竟哪些 App 抓不到，
  均未验证（对应 §5.1 已声明的限制）。
- **App 归属 / `UidResolver` 真机路径（Todo 11–13，UNVERIFIED）**：Android 上
  `ProxyVpnService.queryOwnerUid` 调用 `ConnectivityManager.getConnectionOwnerUid`
  （API 29，且仅活跃 `VpnService` 可调）+ `PackageManager.getPackagesForUid` 的完整链路
  **无设备可验**。host 侧只用可注入的 `UidResolver` 假实现（快/慢/超时/全未知/已关闭流/早到结果）
  证明批量、降级与回填；JNI 无 VM / 无 service 时批量返回 `unknown` 也已断言。Kotlin 的
  `SecurityException`/`IllegalArgumentException` 捕获与 SDK<29 分支仅有代码审查。
- **late-query 覆盖缺口（UNVERIFIED）**：归属查询发生在流建立之后，短命流可能在查询返回时
  已经关闭；这是 best-effort 路径，不做「每条流必有 UID」的保证。
- **LAN 内存降级（UNVERIFIED）**：LAN 独立路径若实例 `dataDir` 为空，`requests` 显式降级为
  纯内存环（不做 SQLite 持久化）。该降级后的 7 天/≤5 万行持久化语义未在设备侧验证。

**已知限制（设计范围，非缺陷，须显式声明）**

- **跨 tick 短命流不可见**：请求采集是**采样差量法**（每 `STATS_TICK_MS = 500ms` 一次
  meow `Statistics::connections` 对账）。若某流在**两次 tick 之间开启又关闭**，它不会出现在
  任何一次投影中，因此不产生 `RequestRecord`。这是已接受并测试固化的限制，不是缺陷。
- **UDP 流不在本次生产采集范围**：meow `Statistics::connections` **仅投影 TCP**
  （见 `API.md` §2.10；`udp.rs` 从不调用 `track_connection`）。故请求采集、`UidQuery` 与
  导出**只承诺 TCP**；`RequestRecord.network` 字段虽保留 `"tcp"|"udp"` 通用语义，但生产路径
  **不产生 `udp` 值**。不得据此声称 UDP 覆盖。

相关验证记录分散在各功能章节末尾（`API.md` §7–§16）与 `.omo/evidence/`。

## 11. 设备侧隧道冒烟 harness（`integration_test/`）

§10 记录的「设备侧 `integration_test/` harness 缺失」已补齐：仓库现提交
`integration_test/proxy_tunnel_test.dart` 与包装脚本
`scripts/ci/run_proxy_tunnel_device_test.sh`，供**连接 adb 真机**时把「流量是否真的
经代理内核转发」变成无需人工判断的断言。**本仓库 CI 无设备，故此 harness 在 CI 中
不执行**；它只在有人接了真机时手动/由 agent 驱动运行。

**怎么做（无真实网络依赖）**

1. 在回环起一个极简 **HTTP 代理 fixture**（`HttpServer`），对任何明文请求返回已知
   marker `GSTORE_TUNNEL_FIXTURE_MARKER`（既是 mock server，也是内核可拨号的 fixture）。
2. 程序化生成**本地合成** Clash 订阅（单个 `http` 节点指向该 fixture + `MATCH,PROXY`，
   风格同 `rust/gstore_mod_proxy/tests/fixtures/synthetic_provider.yaml`），经
   `profile.import_text` → `profile.create` 持久化。**绝不使用/打印真实订阅 URL 或 token。**
3. `lan.set {enabled:true, bindAddress:"127.0.0.1"}` 开仅回环 LAN 入站，`core.start`
   以 `lanProxy` 模式连接（**不需要 VpnService 授权**，故可在真机/模拟器确定性运行）。
4. 用 `HttpClient.findProxy` 经该入站请求 `http://tunnel-fixture.example.test/marker`，
   断言响应体含 marker（证明流量确实被代理）。
5. `stats.domain.get` 断言该域名被记录且 `connections >= 1`。

**怎么运行**

```bash
adb devices
flutter test integration_test/proxy_tunnel_test.dart -d <deviceId>
# 或（无设备时以 "NO DEVICE ATTACHED" 非零退出）：
scripts/ci/run_proxy_tunnel_device_test.sh [deviceId]
```

**覆盖边界（诚实声明）**：本 harness 只覆盖**无需系统 VPN 授权**的引擎/数据面/统计
路径。真机 `VpnService` 授权、TUN、`protect`、always-on 生命周期**仍为 §10 所列
UNVERIFIED**，本文件不声称其通过。依赖：`pubspec.yaml` 新增 `integration_test`
（Flutter SDK）dev 依赖，未改动应用版本与既有依赖。
