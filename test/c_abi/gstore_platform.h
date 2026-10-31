#ifndef GSTORE_PLATFORM_H
#define GSTORE_PLATFORM_H

/* 警告：本文件由 cbindgen 自动生成，请勿手动编辑。
 * 源：rust/gstore_contract/src/abi.rs
 * 重新生成：scripts/dev/generate_c_header.sh */

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * 模块 ABI 版本：任何一端结构体布局变更都必须 +1
 *
 * v2：`GStoreModuleApi` 追加 `on_event`（宿主→模块事件下发）。
 * v3：`GStoreModuleEntry` 追加 `protect_fd`（宿主→模块 socket 保护服务）。
 * v4：`GStoreModuleEntry` 追加 `platform: *const GStorePlatformApiV1`
 *     （宿主平台服务注入表；模块经 [`GStoreModuleEntry::platform_if_present`]
 *     守卫后按 `PLATFORM_CAP_*` 能力位取用，`NULL`/缺槽走无平台服务降级路径）。
 * v5：`GStoreModuleEntry` 追加 `config: *const GStoreConfigApiV1`
 *     （宿主配置 vtable；模块经 [`GStoreModuleEntry::config_if_present`] 守卫后
 *     按 [`CONFIG_CAP_*`] 能力位取用。缺失/`NULL` 时模块不得读写配置）。
 */
#define GSTORE_MODULE_ABI_VERSION 5

/**
 * 宿主必须支持的最低 ABI 版本（**默认**值，模块可按需收紧）。
 *
 * 为什么默认仍是 3 而布局是 5：布局版本描述「宿主注入表长什么样」——v4 追加
 * `platform`、v5 追加 `config`，只有对应版本的宿主才会填充这些槽；`min_host_abi`
 * 描述「模块能容忍的最老宿主」——不消费新槽的模块只用 v1–v3 的既有槽位
 * （`log`/`alloc`/`free`/`emit_event`/`context`/`protect_fd`），`platform`/`config`
 * 都是可选的（`NULL`/缺槽时走高降级路径），因此一个 ABI 3 宿主足以挂载它们。
 * 设为 3 保证老宿主不被误拒，且不因布局版本升到 5 而收紧。
 *
 * **消费配置 vtable 的模块必须显式设置 `GStoreModuleApi::min_host_abi = 5`**
 * （见该字段文档）。这类模块在 v4 宿主上会在 probe 握手阶段被
 * [`host_abi_satisfies`] 拒绝，而不是「加载后 `has_config() == false` 再静默降级」
 * ——配置是模块运行的硬依赖，缺失即不可用。
 */
#define MIN_HOST_ABI 3

/**
 * 平台能力位：`capabilities` 位图的位定义（按能力逐位置位，u64 位图）。
 */
#define PLATFORM_CAP_LIST_INSTALLED (1 << 0)

#define PLATFORM_CAP_GET_INSTALLED (1 << 1)

#define PLATFORM_CAP_INSTALL (1 << 2)

#define PLATFORM_CAP_UNINSTALL (1 << 3)

#define PLATFORM_CAP_LAUNCH (1 << 4)

#define PLATFORM_CAP_NOTIFY (1 << 5)

#define PLATFORM_CAP_START_FOREGROUND (1 << 6)

#define PLATFORM_CAP_STOP_FOREGROUND (1 << 7)

#define PLATFORM_CAP_OPEN_FILE (1 << 8)

#define PLATFORM_CAP_READ_FILE (1 << 9)

#define PLATFORM_CAP_IS_ONLINE (1 << 10)

#define PLATFORM_CAP_DEVICE_INFO (1 << 11)

/**
 * 全部 12 个能力的位掩码（低 12 位全置位）。
 */
#define PLATFORM_CAP_ALL ((1 << 12) - 1)

/**
 * 配置能力位：`capabilities` 位图的位定义（u64 位图）。
 */
#define CONFIG_CAP_GET (1 << 0)

#define CONFIG_CAP_SET (1 << 1)

#define CONFIG_CAP_LIST (1 << 2)

#define CONFIG_CAP_SUBSCRIBE (1 << 3)

/**
 * 全部 4 个配置能力的位掩码（低 4 位全置位）。
 */
#define CONFIG_CAP_ALL ((1 << 4) - 1)

/**
 * C ABI 层错误码（模块 extern "C" 函数返回；为未来模块 .so 契约预留）
 */
#define ABI_OK 0

#define ABI_ERR_NULL -1

#define ABI_ERR_ABI_MISMATCH -2

#define ABI_ERR_ALREADY -3

#define ABI_ERR_NO_INSTANCE -4

#define ABI_ERR_NO_METHOD -5

#define ABI_ERR_PANIC -6

#define ABI_ERR_INTERNAL -7

/**
 * 模块把结构化错误（`ModuleError::to_payload` 的 JSON）写入 out 缓冲后返回此码；
 * 宿主据此还原 StatusCode/code/message，避免域错误在 ABI 边界塌成通用内部错误。
 */
#define ABI_ERR_DETAIL -8

/**
 * 跨模块访问被可见性拒绝（`Owner`/`Secret`），或跨模块写入。
 */
#define ABI_ERR_CONFIG_FORBIDDEN -9

/**
 * 目标 `(module, key)` 不存在。
 */
#define ABI_ERR_CONFIG_NOT_FOUND -10

/**
 * 参数非法（空指针、非 UTF-8、非法 JSON、非法模块名）。
 */
#define ABI_ERR_CONFIG_INVALID -11

/**
 * `unsubscribe` 令牌不存在或不属于调用模块。
 */
#define ABI_ERR_CONFIG_BAD_TOKEN -12

/**
 * 跨 ABI 边界的**自有缓冲**（宿主平台服务分配、模块读取后经 `free_buf` 交还）。
 *
 * 所有权约定：分配方（宿主）负责释放，读取方只读拷贝、不得 free；
 * `ptr == null` 且 `len == 0` 表示空结果。
 */
typedef struct ByteBuf {
  uint8_t *ptr;
  size_t len;
} ByteBuf;

/**
 * 宿主平台服务 vtable（ABI v4 追加，经 `GStoreModuleEntry::platform` 注入）。
 *
 * **演进规则（与 `GStoreModuleEntry` 一致）：只允许在末尾追加字段**。
 * 头部 `abi_version`/`struct_size`/`capabilities` 是模块判断「宿主支持到哪一版、
 * 提供哪些能力」的唯一依据：
 * - `struct_size` 过小（宿主比本版旧）→ 模块不得读取其后的槽位；
 * - `capabilities` 位图按 `PLATFORM_CAP_*` 置位，模块必须先 `has_capability` 探测
 *   再调用对应回调（fail-closed：位缺失即视为「该能力不适用/不可用」）。
 * - `context` 为宿主上下文，回调时原样传回（与 `GStoreModuleEntry::context` 同约定）。
 *
 * 回调约定：`ctx` 一律是 `context` 原样回传；成功返回 0，非 0 为错误；
 * JSON 类结果经 `out_json`（`ByteBuf`）回传；`free_buf` 释放宿主分配的所有缓冲
 * （谁分配谁释放，模块侧不得代 free）。
 */
typedef struct GStorePlatformApiV1 {
  uint32_t abi_version;
  uint32_t struct_size;
  uint64_t capabilities;
  void *context;
  /**
   * 枚举已安装应用 → JSON 列表（out_json）。
   */
  int (*list_installed)(void *ctx, struct ByteBuf *out_json);
  /**
   * 查询单个已安装应用 → JSON（out_json）。
   */
  int (*get_installed)(void *ctx, const char *package, struct ByteBuf *out_json);
  /**
   * 安装 APK（path）→ JSON 结果（out_json）。
   */
  int (*install)(void *ctx, const char *apk_path, struct ByteBuf *out_json);
  /**
   * 卸载应用（package）→ JSON 结果（out_json）。
   */
  int (*uninstall)(void *ctx, const char *package, struct ByteBuf *out_json);
  /**
   * 启动应用（package）→ JSON 结果（out_json）。
   */
  int (*launch)(void *ctx, const char *package, struct ByteBuf *out_json);
  /**
   * 发通知（channel_id/title/body）。
   */
  int (*notify)(void *ctx, const char *channel_id, const char *title, const char *body);
  /**
   * 启动前台服务（notification_json 为通知描述 JSON）。
   */
  int (*start_foreground)(void *ctx, const char *notification_json);
  /**
   * 停止前台服务。
   */
  int (*stop_foreground)(void *ctx);
  /**
   * 打开文件（uri + mime）→ JSON 结果（out_json）。
   */
  int (*open_file)(void *ctx, const char *uri, const char *mime, struct ByteBuf *out_json);
  /**
   * 读文件内容 → JSON 结果（out_json）。
   */
  int (*read_file)(void *ctx, const char *uri, struct ByteBuf *out_json);
  /**
   * 在线状态探测 → out_online（0/1）。
   */
  int (*is_online)(void *ctx, int *out_online);
  /**
   * 设备信息 → JSON（out_json）。
   */
  int (*device_info)(void *ctx, struct ByteBuf *out_json);
  /**
   * 释放宿主分配的自有缓冲（**必须保持在 vtable 末尾**；谁分配谁释放）。
   */
  void (*free_buf)(struct ByteBuf buf);
} GStorePlatformApiV1;

/**
 * 宿主配置 vtable（ABI v5 追加，经 `GStoreModuleEntry::config` 注入）。
 *
 * **演进规则**：只允许在末尾追加字段；`abi_version`/`struct_size`/`capabilities`
 * 是模块判断「宿主配置能力到哪一版」的唯一依据（先探测再调用，fail-closed）。
 *
 * **所有权**：所有 `ByteBuf` 结果由宿主分配，模块只读拷贝，随后必须交给
 * [`GStoreConfigApiV1::free_buf`] 释放（谁分配谁释放；模块不得代为 free，
 * 也不得把 `free_buf` 用在平台 vtable 分配的缓冲上）。失败时 `out_json`
 * 保持 `{null, 0}`，模块无需释放。
 *
 * **可见性**：`get`/`list`/`subscribe` 都可指向外模块，但除本模块外只放行
 * `PublicRead` 条目；`Owner`/`Secret` 返回 [`ABI_ERR_CONFIG_FORBIDDEN`]。
 * `set` 永远是本模块写入。`subscribe` 的 `key == NULL`（整模块）不是越权授权：
 * 宿主对**每一条送达的变更**按该条目的可见性重新裁决，后续新增的 `Owner`
 * key 不会被送达。
 */
typedef struct GStoreConfigApiV1 {
  uint32_t abi_version;
  uint32_t struct_size;
  uint64_t capabilities;
  /**
   * 指向 [`GStoreConfigContextV1`]（宿主按模块绑定）。
   */
  void *context;
  /**
   * 读配置：`module_or_null == NULL` 为本模块；否则为跨模块读取（仅 `PublicRead`）。
   * 成功时 `out_json` 为 JSON 值；未知 key → [`ABI_ERR_CONFIG_NOT_FOUND`]，
   * 可见性拒绝 → [`ABI_ERR_CONFIG_FORBIDDEN`]，参数非法 → [`ABI_ERR_CONFIG_INVALID`]。
   */
  int (*get)(void *ctx, const char *module_or_null, const char *key, struct ByteBuf *out_json);
  /**
   * 写本模块配置（`key` + `value_json`）。跨模块写入一律
   * [`ABI_ERR_CONFIG_FORBIDDEN`]。
   */
  int (*set)(void *ctx, const char *key, const char *value_json);
  /**
   * 列配置：本模块全部条目；外模块仅 `PublicRead` 条目（JSON 数组）。
   */
  int (*list)(void *ctx, const char *module_or_null, struct ByteBuf *out_json);
  /**
   * 订阅变更：`module_or_null == NULL` 为本模块；外模块 `key == NULL` 表示
   * 「该模块中我有权看到的条目」，逐条送达时再按可见性过滤。显式外模块 key
   * 若非 `PublicRead` 则在此处直接返回 [`ABI_ERR_CONFIG_FORBIDDEN`]。
   * 成功时 `out_token` 为本模块拥有的订阅令牌。
   */
  int (*subscribe)(void *ctx,
                   const char *module_or_null,
                   const char *key_or_null,
                   void *user_ctx,
                   int (*callback)(void *user_ctx, const char *change_json),
                   uint64_t *out_token);
  /**
   * 取消订阅：只接受 `context` 所属模块自己创建、仍有效的令牌，
   * 否则 [`ABI_ERR_CONFIG_BAD_TOKEN`]。
   */
  int (*unsubscribe)(void *ctx, uint64_t token);
  /**
   * 释放本 vtable 分配的缓冲（**必须保持在 vtable 末尾**）。
   */
  void (*free_buf)(struct ByteBuf buf);
} GStoreConfigApiV1;

/**
 * 配置 vtable 的上下文绑定（宿主为每个已加载模块各分配一份，按模块生命周期存活）。
 *
 * [`GStoreConfigApiV1::context`] 指向本结构：回调拿到的 `ctx` 可解引用为
 * `GStoreConfigContextV1`，其中 `module_id`/`module_name` 是宿主为该模块绑定的
 * **权威身份**——模块不能靠参数自报模块名绕过可见性检查。`host` 是宿主私有
 * 指针（模块不得解引用），用于宿主侧恢复配置服务。
 */
typedef struct GStoreConfigContextV1 {
  uint64_t module_id;
  /**
   * 宿主分配的模块名（NUL 结尾，生命周期同 context）。
   */
  const char *module_name;
  /**
   * 宿主私有句柄（模块不得解引用）。
   */
  void *host;
} GStoreConfigContextV1;

/**
 * 结构化平台错误（宿主平台服务回传）：`code` 为平台域错误码，
 * `message` 为宿主分配的错误描述（归宿主 `free_buf` 所有）。
 */
typedef struct GStorePlatformError {
  int code;
  struct ByteBuf message;
} GStorePlatformError;

/**
 * 宿主 → 模块：宿主服务的注入表（按值注入，模块只读保存，不 dlsym 宿主符号）
 *
 * **ABI 演进规则（与 v2 `on_event` 一致）：只允许在结构体末尾追加字段**，
 * 绝不重排/重命名/删除既有字段。模块侧读取新增槽前，必须先用
 * [`GStoreModuleEntry::protect_fd_if_present`] / [`GStoreModuleEntry::platform_if_present`]
 * 按 `entry_size` 守卫，旧宿主（更小的 `entry_size`）下不得越界读取。
 *
 * 当前为 **v5 布局**：v3 末尾为 `protect_fd`，v4 追加 `platform`，
 * v5 再追加 `config`。
 */
typedef struct GStoreModuleEntry {
  uint32_t abi_version;
  uint32_t entry_size;
  void (*log)(int level, const char *msg);
  void *(*alloc)(size_t size);
  void (*free)(void *ptr);
  void (*emit_event)(uint64_t module_id, uint64_t instance_id, const uint8_t *data, size_t len);
  void *context;
  /**
   * 宿主 → 模块 socket 保护服务（ABI v3 追加，**必须保持在结构体末尾**）。
   *
   * 代理域模块把此函数指针包装成 meow `SocketProtector` 并 `set_socket_protector()`
   * 安装，使每条出站 socket（TCP/UDP/DNS/libc 解析）经**一个钩子**完成保护；
   * 宿主侧委托到 JNI `VpnService.protect(fd)`（Todo 4 接线，当前为返回 0 的 stub）。
   * 返回语义：0 = 成功/已处理，非 0 = 保护失败（模块应关闭/拒绝该 socket）。
   *
   * 旧宿主（ABI < 3）不设置此槽且 `entry_size` 更小：
   * 模块必须先 `protect_fd_if_present()` 守卫，绝不对小 entry 越界读取。
   */
  int (*protect_fd)(int fd);
  /**
   * 宿主平台服务注入表（ABI v4 追加，**必须保持在结构体末尾**）。
   *
   * 指向 `GStorePlatformApiV1` vtable：模块凭 `PLATFORM_CAP_*` 能力位查询
   * 宿主能提供的平台服务（已装应用列表/安装/卸载/启动/通知/前台服务/文件/
   * 在线状态/设备信息）。`NULL` 或 `has_platform()` 为 false 表示宿主未注入
   * （ABI < 4 或未填槽），模块走无平台服务的降级路径。
   *
   * 旧宿主（ABI < 4）不设置此槽且 `entry_size` 更小：
   * 模块必须先 `platform_if_present()` 守卫，绝不对小 entry 越界读取。
   */
  const struct GStorePlatformApiV1 *platform;
  /**
   * 宿主配置 vtable（ABI v5 追加，**必须保持在结构体末尾**）。
   *
   * 指向 [`GStoreConfigApiV1`]：模块凭 [`CONFIG_CAP_*`] 能力位查询宿主提供的
   * 配置读写/订阅能力。`NULL` 或 `has_config()` 为 false 表示宿主未注入
   * （ABI < 5 或未填槽）——模块不得读写配置。
   *
   * 旧宿主（ABI < 5）不设置此槽且 `entry_size` 更小：
   * 模块必须先 `config_if_present()` 守卫，绝不对小 entry 越界读取。
   */
  const struct GStoreConfigApiV1 *config;
} GStoreModuleEntry;

/**
 * 模块 → 宿主：模块导出的能力表
 */
typedef struct GStoreModuleApi {
  const char *name;
  uint32_t version;
  /**
   * 要求宿主的最低 ABI 版本。默认 [`MIN_HOST_ABI`]（3）；**消费配置 vtable 的
   * 模块必须设为 5**，使其在 v4 宿主上于 probe 阶段被拒绝（配置是硬依赖）。
   */
  uint32_t min_host_abi;
  int (*init)(void);
  int (*create)(const uint8_t *config, size_t config_len, uint64_t *out_instance);
  int (*call)(uint64_t instance,
              const char *method,
              const uint8_t *payload,
              size_t payload_len,
              uint8_t **out_data,
              size_t *out_len);
  int (*cancel)(uint64_t instance, const char *request_id);
  int (*destroy)(uint64_t instance);
  int (*shutdown)(void);
  void *(*alloc)(size_t size);
  void (*free)(void *ptr);
  /**
   * 宿主 → 模块 事件下发（下行订阅，ABI v2 追加）：
   * [kind] 为事件类型（如 "config.changed"），[data] 为 JSON 载荷。
   * 旧宿主不读取此槽；旧模块不提供（None → 宿主跳过下发）。
   */
  int (*on_event)(uint64_t module_id, const char *kind, const uint8_t *data, size_t data_len);
} GStoreModuleApi;

#endif  /* GSTORE_PLATFORM_H */
