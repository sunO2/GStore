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
