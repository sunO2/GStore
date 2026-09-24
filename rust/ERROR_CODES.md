# 错误码总表（协议层）

> 权威定义：`rust/gstore_contract/src/error.rs`（`StatusCode` + `ERR_*` 常量）。
> 本文件为决策 #6 要求的随代码同步文档；**以代码为准**。

## 状态码（信封 `EnvelopeResponse.status`，仿 HTTP 语义）

| status | StatusCode | 语义 |
|---|---|---|
| 200 | `Ok` | 成功 |
| 201 | `Created` | 已创建 |
| 301 | `ModuleNotLoaded` | 模块未加载（客户端应触发加载，非错误） |
| 302 | `InstanceExpired` | 实例已失效 |
| 400 | `BadRequest` | 请求不可解析（信封解码失败等） |
| 404 | `ModuleNotFound` | 模块不存在 |
| 405 | `MethodNotFound` | 域内方法不存在 |
| 410 | `InstanceNotFound` | 实例不存在 |
| 422 | `InvalidArgument` | 参数非法 |
| 426 | `VersionMismatch` | 版本不匹配（ABI/功能版本降级被拒） |
| 499 | `Aborted` | 主动取消 |
| 500 | `InternalError` | 模块内部错误 |
| 5001 | `PanicCaught` | 模块 panic 被 `catch_unwind` 捕获 |
| 507 | `ResourceExhausted` | 资源耗尽 |
| 504 | `Timeout` | 调用超时 |

## 错误码（`error_code` 字段）

协议层（宿主兜底，所有模块通用）：

| code | 常量 | 通常 status |
|---|---|---|
| `MODULE_NOT_FOUND` | `ERR_MODULE_NOT_FOUND` | 404 |
| `METHOD_NOT_FOUND` | `ERR_METHOD_NOT_FOUND` | 405 |
| `INSTANCE_NOT_FOUND` | `ERR_INSTANCE_NOT_FOUND` | 410 |
| `BAD_REQUEST` | `ERR_BAD_REQUEST` | 400 |
| `INVALID_ARGUMENT` | `ERR_INVALID_ARGUMENT` | 422 |
| `VERSION_MISMATCH` | `ERR_VERSION_MISMATCH` | 426 |
| `INTERNAL_ERROR` | `ERR_INTERNAL` | 500 |
| `PANIC_CAUGHT` | `ERR_PANIC_CAUGHT` | 5001 |
| `CANCELLED` | `ERR_CANCELLED` | 499 |

域层（模块自填，建议 `模块名_` 前缀，避免与协议层冲突）。

| code | 模块 | 通常 status | 含义 |
|---|---|---|---|
| `PROXY_TUN_FD_INVALID` | proxy | 422 | TUN fd 非法（<0 / 已关闭 / `dup` 失败）或 `core.start` 时无可用 fd（Todo 6） |
| `PROXY_NO_INBOUND` | proxy | 422 | 选择 `lanProxy` 运行模式但 LAN 监听未启用（`lan.get().enabled==false`）。**在拆除当前模式之前**校验，返回结构化错误而非静默 no-op（Todo 29） |
| `PROXY_MODE_INVALID` | proxy | 422 | `core.set_mode`/`core.start`/`core.restart` 收到未知 `mode` 字符串（仅接受 `off`/`vpn`/`lanProxy`；缺字段或非 JSON 载荷按历史兼容默认 `vpn`）（Todo 29） |
| `PROXY_LAN_CONFIG_INVALID` | proxy | 422 | `lan.set` 载荷非法（`bindAddress`/`allowedIps` CIDR/`port` 非法，或 `auth.user`/`auth.pass` 为空），或 LAN 监听绑定失败（Todo 28） |
| `PROXY_LAN_DISABLED` | proxy | 422 | 在 LAN 未启用时请求 LAN 能力（Todo 28）。`gstore_contract::StatusCode` 无 409 变体，沿用本模块 422 域错误约定 |
| `PROXY_LAN_NO_AUTH` | proxy | —（行内 warning） | LAN 监听已启用但未配置 `auth`：`proxy.state` 事件与 `lan.*` 响应的 `warning` 字段回传（Todo 28） |
| `PROXY_SHAPER_CONFIG_INVALID` | proxy | 422 | `net.shaper.set` 载荷非法：非 JSON 对象、未知字段、字段越界（如 `rateBps` 非 `0` 且不在 `[1000, 1000000000]`、`reorderGap>255`）或跨字段冲突（`order=reorder` 且 `reorderPct>0` 且 `rateBps==0`）；校验失败时**不改动**内存/磁盘上的既有配置（Todo 15） |
| `PROXY_PROTECT_FAILED` | proxy | 500 | 宿主 `protect_fd(fd)` 返回非 0：拒绝使用未受保护的出站 socket（Todo 7） |
| `PROXY_DNS_CONFIG_INVALID` | proxy | 422 | DNS 配置非法（nameserver/DoH/DoT URL 解析失败、fake-ip range 非法、空 nameserver 列表）（Todo 8） |
| `PROXY_DNS_BOOTSTRAP_FAILED` | proxy | 500 | DNS bootstrap/加密上游构建失败；`default-nameserver` 非明文时为 422（Todo 8） |
| `PROXY_DNS_TIMEOUT` | proxy | 504 | DNS 查询无应答（上游不可达 / 无 fallback），已写入失败日志记录（Todo 8） |
| `PROXY_RULE_INVALID` | proxy | 422 | 规则行解析失败（未知类型/缺列/非法 CIDR）或整个 Clash 配置/`rules.reload` 载荷不可解析；报告会点名具体 `line`，其余规则仍加载。仅整配置不可解析时作为顶层 422，单行失败在 `rules.get.errors[]` 内回报（Todo 9） |
| `PROXY_RULE_PROVIDER_FAILED` | proxy | —（行内） | `rule-providers` 加载失败；该 provider 对应的 `RULE-SET` 规则保持空集（不匹配），`rules.get` 的 `providers[].code` 回报（Todo 9） |
| `PROXY_GEO_UNAVAILABLE` | proxy | —（行内） | `GEOIP`/`GEOSITE`/`IP-ASN` 规则所需地理库未就绪（缺失/下载中/校验失败）；该行记入 `rules.get` 的 `errors[]`，其余规则仍加载（Todo 9） |
| `PROXY_NODE_NOT_FOUND` | proxy | 404 | `node.select`/`node.delay_test` 指定的 group 不存在，或 node 不在该 group 内（Todo 10）；亦可能来自构建期级联丢弃（见下方注记） |
| `PROXY_GROUP_NOT_SELECTABLE` | proxy | 422 | 目标不是可选择的 group（selector/url-test/fallback）：叶子节点、load-balance、relay 均无 `ProxySelection`（Todo 10） |
| `PROXY_NOT_CONFIGURED` | proxy | 409 | engine/tunnel 未运行即调用 `node.*`/`conn.list`（Todo 10）；`core.start` 前需先由 Todo 13 注入 proxies 并启动 TUN |
| `PROXY_SUB_URL_INVALID` | proxy | 422 | 订阅 URL 非法：非 `http(s)` scheme（`file://`/`ftp://` 等）、URL 不可解析或无 host（Todo 11） |
| `PROXY_SUB_SSRF_BLOCKED` | proxy | 422 | 用户提供的订阅 URL 指向 loopback/private/link-local/CGNAT 地址（SSRF 守卫；每一跳重定向都会复检）（Todo 11） |
| `PROXY_SUB_FETCH_FAILED` | proxy | 500 | 订阅抓取失败：连接/读取/TLS 错误、非 2xx、重定向缺 `Location`、重定向超限，或 `Content-Encoding` 非 `identity`（Todo 11） |
| `PROXY_SUB_TOO_LARGE` | proxy | 507 | 订阅 body/text/link 超过硬上限，或声明 `Content-Length` 超上限，或节点数超限（Todo 11） |
| `PROXY_SUB_FORMAT_UNKNOWN` | proxy | 422 | 内容既非 Clash YAML、也非 base64 URI 列表或明文 URI 列表（Todo 11） |
| `PROXY_SUB_PARSE_FAILED` | proxy | 422 | 已识别格式解析失败（YAML 畸形、body 非 UTF-8）（Todo 11） |
| `PROXY_SUB_NODE_INVALID` | proxy | 422 | 分享链接畸形或缺必填字段（server/port/密钥，外部 SIP003 `plugin`）（Todo 11） |
| `PROXY_SUB_SCHEME_UNSUPPORTED` | proxy | 422 | 分享链接 scheme 不在支持集合（`ss`/`ss2022`/`vmess`/`vless`/`trojan`/`hysteria2`）（Todo 11） |
| `PROXY_SUB_NO_NODES` | proxy | 422 | 解析成功但无可导入节点（Todo 11） |
| `PROXY_PROFILE_NOT_FOUND` | proxy | 404 | `profile.get/update/delete/refresh` 指定的 profile id 不存在（Todo 12） |
| `PROXY_PROFILE_INVALID` | proxy | 422 | profile 存储请求非法：缺 `profile`、profile 名为空/无节点、id 非 `[A-Za-z0-9_-]{1,64}`、显式 id 重复、`refresh.state` 非 `requested\|done\|failed`（Todo 12） |
| `PROXY_PROFILE_NOT_REFRESHABLE` | proxy | 422 | 对非 URL 来源（text/link）的 profile 调用 `profile.refresh`（Todo 12） |
| `PROXY_PROFILE_REFRESH_BACKOFF` | proxy | 507 | 非 force 的 `profile.refresh` 落在失败退避窗口内（30s→6h 指数退避，封顶 6h）；`force:true` 可绕过（Todo 14） |
| `PROXY_PROFILE_SCHEMA_UNSUPPORTED` | proxy | 422 | 磁盘上的 profile schema 版本高于当前模块支持版本（拒读，避免旧模块截断新数据）（Todo 12） |
| `PROXY_PROFILE_TOO_LARGE` | proxy | 507 | profile/index 载荷超硬上限、profile 数超 4096、单 profile 节点数超 4096（Todo 12） |
| `PROXY_PROFILE_STORE_FAILED` | proxy | 500 | profile 存储 I/O / 原子写（temp+fsync+rename）失败（Todo 12） |
| `PROXY_PROFILE_CORRUPT` | proxy | —（`list` 行内 warning）/ 500（`get`） | 单个 payload/index 文件不可解析；`profile.list` 跳过该文件并回报结构化 warning，`profile.get` 返回 500（Todo 12） |
| `PROXY_PROFILE_MISSING` | proxy | —（`list` 行内 warning） | index 引用的 payload 文件已不存在；`profile.list` 回报结构化 warning（Todo 12） |
| `PROXY_CONFIG_PROFILE_REQUIRED` | proxy | 422 | `config.generate`/`profile.export_clash` 时既无 `profileId` 也无已存储 profile（或实例 `data_dir` 为空）（Todo 13） |
| `PROXY_CONFIG_INVALID` | proxy | 422 | 配置 overlay 非法（如 `mtu` 低于 1280）或生成的文档解析失败（Todo 13） |
| `PROXY_CONFIG_NODE_UNSUPPORTED` | proxy | —（行内 warning） | 规范模型中的节点类型无法由当前启用的协议集重建/构建；该节点仍写入 YAML，但在 registry 构建时被跳过，不中断启动（Todo 13） |
| `PROXY_LOG_LEVEL_INVALID` | proxy | 422 | `log.set_level` / `log.get` 指定了未知日志级别（应为 `debug`\|`info`\|`warn`\|`error`）（Todo 15） |
| `PROXY_STATS_SORT_INVALID` | proxy | 422 | `stats.domain.get` 指定了未知排序键（应为 `bytes`\|`connections`\|`lastSeen`\|`domain`）（Todo 16） |
| `PROXY_REQUEST_EXPORT_TOO_LARGE` | proxy | 507 | `requests.export` 单个导出的总字节数（CSV + JSON）超过硬上限 `REQUEST_EXPORT_MAX_BYTES`（64 MiB）；**在写任何文件之前**拒绝，绝不留下半写文件（Todo 10） |
| `PROXY_REQUEST_EXPORT_FILTER_INVALID` | proxy | 422 | `requests.export` 的 `filter` 不是合法的 `RequestFilter` 对象（非对象或字段类型错误，如 `uid` 非数字）（Todo 10） |
| `PROXY_REQUEST_CURSOR_INVALID` | proxy | 422 | `requests.get` 的 `cursor` 存在但非非负整数（Todo 10） |
| `PROXY_CONN_NOT_FOUND` | proxy | 404 | `conn.close` 收到本模块从未跟踪过的连接 id（既不在活动表，也不在「最近关闭」墓碑内）（Todo 17） |
| `PROXY_CLASH_API_FAILED` | proxy | 500 | `diagnostics.clash_api.start` 无法绑定 `127.0.0.1:<port>` 或无法启动其 runtime/线程（Todo 18） |
| `PROXY_DATAPLANE_DEAD` | proxy | —（supervisor 事件） | TUN 数据面 worker（reader/egress/ingress）在隧道存活时意外结束或 panic：以结构化 `proxy.state` 的 `error.code` 上报**原始**原因并触发有界退避重启；预算耗尽后置为 `dataplane_failed`（Todo 24） |

> **`PROXY_NODE_NOT_FOUND` 的构建期级联与引擎对齐。** 除上表的直接原因外，该 404 还可能在
> registry 构建阶段产生：当某声明的 proxy-group 依赖的兄弟 group 无法构建（例如节点类型
> 不受支持）时，依赖它的 group 会一并被丢弃，`node.select` 因此报 `group not found` ——
> 这是**构建期级联**，不是客户端请求错误。此外，运行中的引擎在 `profile.refresh` 或切换
> 订阅后可能持有**过期 registry**；当 UI 展示的 profile 含某 group 而活动引擎没有时，节点
> 选择会触发一次 `config.apply` 重放当前 profile 以对齐活动引擎，**无需手动重连**（引擎
> 停止时的离线选择不受影响）。构建结果见诊断日志
> `proxy: registry groups built=[...] missing=[...]`：`built` 列出成功进入 registry 的声明
> group，`missing` 列出被丢弃者，即上述 404 的潜在来源。

## 跨 ABI 错误透传

C ABI `call` 返回 `ABI_ERR_DETAIL (-8)` 时，模块在 out 缓冲写入
`ModuleError::to_payload()` 的 JSON（`{status, code, message}`），宿主
`DlModuleAdapter` 据此还原为完整错误。**未实现该约定的旧模块返回通用 `-1`，
宿主回退为 `INTERNAL_ERROR`。** 这使得 404/405/422 等域错误不再在 ABI 边界塌成 500。

## ABI 返回码（模块 `extern "C"` 返回）

| code | 常量 | 含义 |
|---|---|---|
| 0 | `ABI_OK` | 成功 |
| -1 | `ABI_ERR_NULL` | 空指针参数 |
| -2 | `ABI_ERR_ABI_MISMATCH` | ABI 版本不兼容（握手/加载被拒） |
| -3 | `ABI_ERR_ALREADY` | 已存在 |
| -4 | `ABI_ERR_NO_INSTANCE` | 实例不存在 |
| -5 | `ABI_ERR_NO_METHOD` | 方法不存在 |
| -6 | `ABI_ERR_PANIC` | 模块 panic 被捕获 |
| -7 | `ABI_ERR_INTERNAL` | 内部错误 |
| -8 | `ABI_ERR_DETAIL` | 错误明细在 out 缓冲（见上） |

## MITM 上游重发起（Todo 7，`proxy-http-capture.md`）

| code | 模块 | 通常 status | 含义 |
|---|---|---|---|
| `PROXY_CAPTURE_UPSTREAM_FAILED` | proxy | —（数据面 HTTP 502） | MITM 解密后的请求经 tunnel outbound 重发起失败：`resolve_proxy_lazy` → `dial_tcp`（经 rules/protect seam）拨号失败，或上游 TLS 握手失败；捕获层返回 502 风格响应，不 panic。`skipCertVerify` 默认严验（Todo 7） |


> **域层并发追加区。** 后续各原子提交（Wave 3）在此追加各自新增的域层错误码行，
> 均不重写上文的既有错误码表。

| code | 模块 | 通常 status | 含义 |
|---|---|---|---|
| `PROXY_CAPTURE_CONFIG_INVALID` | proxy | 422 | `capture.config.set` 载荷非法：非 JSON 对象、未知字段、`tlsPorts` 含 `0` 或为空、`maxBodyBytes` 越界（不在 `[1, 1048576]`）；校验失败时**不改动**内存或磁盘上的既有配置（Todo 10） |
| `PROXY_CAPTURE_CA_FAILED` | proxy | 422 / 500 | `capture.ca.generate` 载荷非法（`regenerate` 非 bool、非对象、未知字段 → 422），或 CA 生成/读取/重置失败（`rcgen` 签发 / I/O → 500）；`capture.ca.get` 未生成**不是**错误（`generated:false`），`reset` 无 CA 时 `cleared:false`（Todo 11） |
| `PROXY_CAPTURE_NOT_FOUND` | proxy | 404 | `captures.detail` 请求的 `recordId` 不在保留窗口（环 / 待刷盘队列 / SQLite 表）中（Todo 12） |
| `PROXY_CAPTURE_CURSOR_INVALID` | proxy | 422 | `captures.get` 的 `cursor` 存在但非非负整数（Todo 12） |
| `PROXY_CAPTURE_STORE_FAILED` | proxy | 500 | captures 持久层读/写失败（SQLite）；内存摘要环保持不变、不回滚（Todo 12） |
| `PROXY_CAPTURE_BODY_TOO_LARGE` | proxy | 507 | `captures.detail` 请求的 Body 超过读盘上限（`CAPTURE_BODY_MAX_BYTES`）的防御性守卫（Todo 12） |
