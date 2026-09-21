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
| `PROXY_NO_INBOUND` | proxy | 422 | 请求了尚未实现的入站（`lanProxy`，Todo 28） |
| `PROXY_PROTECT_FAILED` | proxy | 500 | 宿主 `protect_fd(fd)` 返回非 0：拒绝使用未受保护的出站 socket（Todo 7） |
| `PROXY_DNS_CONFIG_INVALID` | proxy | 422 | DNS 配置非法（nameserver/DoH/DoT URL 解析失败、fake-ip range 非法、空 nameserver 列表）（Todo 8） |
| `PROXY_DNS_BOOTSTRAP_FAILED` | proxy | 500 | DNS bootstrap/加密上游构建失败；`default-nameserver` 非明文时为 422（Todo 8） |
| `PROXY_DNS_TIMEOUT` | proxy | 504 | DNS 查询无应答（上游不可达 / 无 fallback），已写入失败日志记录（Todo 8） |
| `PROXY_RULE_INVALID` | proxy | 422 | 规则行解析失败（未知类型/缺列/非法 CIDR）或整个 Clash 配置/`rules.reload` 载荷不可解析；报告会点名具体 `line`，其余规则仍加载。仅整配置不可解析时作为顶层 422，单行失败在 `rules.get.errors[]` 内回报（Todo 9） |
| `PROXY_RULE_PROVIDER_FAILED` | proxy | —（行内） | `rule-providers` 加载失败；该 provider 对应的 `RULE-SET` 规则保持空集（不匹配），`rules.get` 的 `providers[].code` 回报（Todo 9） |
| `PROXY_GEO_UNAVAILABLE` | proxy | —（行内） | `GEOIP`/`GEOSITE`/`IP-ASN` 规则所需地理库未就绪（缺失/下载中/校验失败）；该行记入 `rules.get` 的 `errors[]`，其余规则仍加载（Todo 9） |
| `PROXY_NODE_NOT_FOUND` | proxy | 404 | `node.select`/`node.delay_test` 指定的 group 不存在，或 node 不在该 group 内（Todo 10） |
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
