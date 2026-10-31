// gstore_contract：模块 C ABI 契约（单 .so 过渡期：宿主内实现，未来抽独立 crate）
//
// 本模块只包含 #[repr(C)] 结构体 + 函数指针类型，宿主与（未来）模块 .so 共享。
// 任何结构体布局变更都必须递增 GSTORE_MODULE_ABI_VERSION。

use std::os::raw::{c_char, c_int, c_void};

/// 模块 ABI 版本：任何一端结构体布局变更都必须 +1
///
/// v2：`GStoreModuleApi` 追加 `on_event`（宿主→模块事件下发）。
/// v3：`GStoreModuleEntry` 追加 `protect_fd`（宿主→模块 socket 保护服务）。
/// v4：`GStoreModuleEntry` 追加 `platform: *const GStorePlatformApiV1`
///     （宿主平台服务注入表；模块经 [`GStoreModuleEntry::platform_if_present`]
///     守卫后按 `PLATFORM_CAP_*` 能力位取用，`NULL`/缺槽走无平台服务降级路径）。
/// v5：`GStoreModuleEntry` 追加 `config: *const GStoreConfigApiV1`
///     （宿主配置 vtable；模块经 [`GStoreModuleEntry::config_if_present`] 守卫后
///     按 [`CONFIG_CAP_*`] 能力位取用。缺失/`NULL` 时模块不得读写配置）。
pub const GSTORE_MODULE_ABI_VERSION: u32 = 5;

/// 宿主必须支持的最低 ABI 版本（**默认**值，模块可按需收紧）。
///
/// 为什么默认仍是 3 而布局是 5：布局版本描述「宿主注入表长什么样」——v4 追加
/// `platform`、v5 追加 `config`，只有对应版本的宿主才会填充这些槽；`min_host_abi`
/// 描述「模块能容忍的最老宿主」——不消费新槽的模块只用 v1–v3 的既有槽位
/// （`log`/`alloc`/`free`/`emit_event`/`context`/`protect_fd`），`platform`/`config`
/// 都是可选的（`NULL`/缺槽时走高降级路径），因此一个 ABI 3 宿主足以挂载它们。
/// 设为 3 保证老宿主不被误拒，且不因布局版本升到 5 而收紧。
///
/// **消费配置 vtable 的模块必须显式设置 `GStoreModuleApi::min_host_abi = 5`**
/// （见该字段文档）。这类模块在 v4 宿主上会在 probe 握手阶段被
/// [`host_abi_satisfies`] 拒绝，而不是「加载后 `has_config() == false` 再静默降级」
/// ——配置是模块运行的硬依赖，缺失即不可用。
pub const MIN_HOST_ABI: u32 = 3;

/// 宿主 → 模块：宿主服务的注入表（按值注入，模块只读保存，不 dlsym 宿主符号）
///
/// **ABI 演进规则（与 v2 `on_event` 一致）：只允许在结构体末尾追加字段**，
/// 绝不重排/重命名/删除既有字段。模块侧读取新增槽前，必须先用
/// [`GStoreModuleEntry::protect_fd_if_present`] / [`GStoreModuleEntry::platform_if_present`]
/// 按 `entry_size` 守卫，旧宿主（更小的 `entry_size`）下不得越界读取。
///
/// 当前为 **v5 布局**：v3 末尾为 `protect_fd`，v4 追加 `platform`，
/// v5 再追加 `config`。
#[repr(C)]
pub struct GStoreModuleEntry {
    pub abi_version: u32,
    pub entry_size: u32, // 向前兼容：模块用 size 判断宿主支持到哪一版
    pub log: Option<extern "C" fn(level: c_int, msg: *const c_char)>,
    pub alloc: Option<extern "C" fn(size: usize) -> *mut c_void>,
    pub free: Option<extern "C" fn(ptr: *mut c_void)>,
    pub emit_event: Option<extern "C" fn(
        module_id: u64,
        instance_id: u64,
        data: *const u8,
        len: usize,
    )>,
    pub context: *mut c_void, // 宿主上下文（回调时原样传回）
    /// 宿主 → 模块 socket 保护服务（ABI v3 追加，**必须保持在结构体末尾**）。
    ///
    /// 代理域模块把此函数指针包装成 meow `SocketProtector` 并 `set_socket_protector()`
    /// 安装，使每条出站 socket（TCP/UDP/DNS/libc 解析）经**一个钩子**完成保护；
    /// 宿主侧委托到 JNI `VpnService.protect(fd)`（Todo 4 接线，当前为返回 0 的 stub）。
    /// 返回语义：0 = 成功/已处理，非 0 = 保护失败（模块应关闭/拒绝该 socket）。
    ///
    /// 旧宿主（ABI < 3）不设置此槽且 `entry_size` 更小：
    /// 模块必须先 `protect_fd_if_present()` 守卫，绝不对小 entry 越界读取。
    pub protect_fd: Option<extern "C" fn(fd: c_int) -> c_int>,
    /// 宿主平台服务注入表（ABI v4 追加，**必须保持在结构体末尾**）。
    ///
    /// 指向 `GStorePlatformApiV1` vtable：模块凭 `PLATFORM_CAP_*` 能力位查询
    /// 宿主能提供的平台服务（已装应用列表/安装/卸载/启动/通知/前台服务/文件/
    /// 在线状态/设备信息）。`NULL` 或 `has_platform()` 为 false 表示宿主未注入
    /// （ABI < 4 或未填槽），模块走无平台服务的降级路径。
    ///
    /// 旧宿主（ABI < 4）不设置此槽且 `entry_size` 更小：
    /// 模块必须先 `platform_if_present()` 守卫，绝不对小 entry 越界读取。
    pub platform: *const GStorePlatformApiV1,
    /// 宿主配置 vtable（ABI v5 追加，**必须保持在结构体末尾**）。
    ///
    /// 指向 [`GStoreConfigApiV1`]：模块凭 [`CONFIG_CAP_*`] 能力位查询宿主提供的
    /// 配置读写/订阅能力。`NULL` 或 `has_config()` 为 false 表示宿主未注入
    /// （ABI < 5 或未填槽）——模块不得读写配置。
    ///
    /// 旧宿主（ABI < 5）不设置此槽且 `entry_size` 更小：
    /// 模块必须先 `config_if_present()` 守卫，绝不对小 entry 越界读取。
    pub config: *const GStoreConfigApiV1,
}

impl GStoreModuleEntry {
    /// `protect_fd` 槽在结构体中的起始偏移（= v2 布局的 `entry_size`）。
    pub const PROTECT_FD_OFFSET: usize = std::mem::offset_of!(GStoreModuleEntry, protect_fd);

    /// 宿主 `entry_size` 是否已覆盖 `protect_fd` 槽（ABI v3+）。
    ///
    /// 模块侧读取 `protect_fd` 前必须调用此守卫：旧宿主的 `entry_size`
    /// 小于 v3 布局时返回 false，模块走降级路径，绝不越界读取。
    pub fn has_protect_fd(&self) -> bool {
        self.entry_size as usize
            >= Self::PROTECT_FD_OFFSET
                + std::mem::size_of::<Option<extern "C" fn(fd: c_int) -> c_int>>()
    }

    /// 安全读取 `protect_fd`：宿主 `entry_size` 不足（旧 ABI）返回 `None`。
    ///
    /// 这是模块侧的标准读取姿势——先守卫再取值，避免对更小的 entry 越界解引用。
    pub fn protect_fd_if_present(&self) -> Option<extern "C" fn(fd: c_int) -> c_int> {
        if self.has_protect_fd() {
            self.protect_fd
        } else {
            None
        }
    }

    /// `platform` 槽在结构体中的起始偏移（= v3 布局的 `entry_size`，x86_64 下为 56）。
    pub const PLATFORM_OFFSET: usize = std::mem::offset_of!(GStoreModuleEntry, platform);

    /// 宿主 `entry_size` 是否已覆盖 `platform` 槽（ABI v4+）。
    ///
    /// 模块侧读取 `platform` 前必须调用此守卫：旧宿主的 `entry_size`
    /// 小于 v4 布局时返回 false，模块走无平台服务降级路径，绝不越界读取。
    pub fn has_platform(&self) -> bool {
        self.entry_size as usize
            >= Self::PLATFORM_OFFSET + std::mem::size_of::<*const GStorePlatformApiV1>()
    }

    /// 安全读取 `platform`：宿主 `entry_size` 不足（旧 ABI）或槽为 `NULL` 返回 `None`。
    ///
    /// 这是模块侧的标准读取姿势——先守卫再取值，避免对更小的 entry 越界解引用；
    /// `NULL` 同样视为「宿主未注入平台服务」，与缺槽统一降级。
    pub fn platform_if_present(&self) -> Option<*const GStorePlatformApiV1> {
        if self.has_platform() {
            let platform = self.platform;
            if platform.is_null() {
                None
            } else {
                Some(platform)
            }
        } else {
            None
        }
    }

    /// `config` 槽在结构体中的起始偏移（= v4 布局的 `entry_size`，x86_64 下为 64）。
    pub const CONFIG_OFFSET: usize = std::mem::offset_of!(GStoreModuleEntry, config);

    /// 宿主 `entry_size` 是否已覆盖 `config` 槽（ABI v5+）。
    ///
    /// v4 及更旧的宿主（`entry_size` 小于 v5 布局）返回 false——即使宿主注入表
    /// 是 v5 结构体，也不会把 v5 的 `entry_size` 报给 v4 模块。
    pub fn has_config(&self) -> bool {
        self.entry_size as usize
            >= Self::CONFIG_OFFSET + std::mem::size_of::<*const GStoreConfigApiV1>()
    }

    /// 安全读取 `config`：宿主 `entry_size` 不足（ABI < 5）或槽为 `NULL` 返回 `None`。
    ///
    /// 这是模块侧的标准读取姿势——先守卫再取值，避免对更小的 entry 越界解引用。
    pub fn config_if_present(&self) -> Option<*const GStoreConfigApiV1> {
        if self.has_config() {
            let config = self.config;
            if config.is_null() {
                None
            } else {
                Some(config)
            }
        } else {
            None
        }
    }
}

/// 跨 ABI 边界的**自有缓冲**（宿主平台服务分配、模块读取后经 `free_buf` 交还）。
///
/// 所有权约定：分配方（宿主）负责释放，读取方只读拷贝、不得 free；
/// `ptr == null` 且 `len == 0` 表示空结果。
#[repr(C)]
pub struct ByteBuf {
    pub ptr: *mut u8,
    pub len: usize,
}

/// 结构化平台错误（宿主平台服务回传）：`code` 为平台域错误码，
/// `message` 为宿主分配的错误描述（归宿主 `free_buf` 所有）。
#[repr(C)]
pub struct GStorePlatformError {
    pub code: c_int,
    pub message: ByteBuf,
}

/// 宿主平台服务 vtable（ABI v4 追加，经 `GStoreModuleEntry::platform` 注入）。
///
/// **演进规则（与 `GStoreModuleEntry` 一致）：只允许在末尾追加字段**。
/// 头部 `abi_version`/`struct_size`/`capabilities` 是模块判断「宿主支持到哪一版、
/// 提供哪些能力」的唯一依据：
/// - `struct_size` 过小（宿主比本版旧）→ 模块不得读取其后的槽位；
/// - `capabilities` 位图按 `PLATFORM_CAP_*` 置位，模块必须先 `has_capability` 探测
///   再调用对应回调（fail-closed：位缺失即视为「该能力不适用/不可用」）。
/// - `context` 为宿主上下文，回调时原样传回（与 `GStoreModuleEntry::context` 同约定）。
///
/// 回调约定：`ctx` 一律是 `context` 原样回传；成功返回 0，非 0 为错误；
/// JSON 类结果经 `out_json`（`ByteBuf`）回传；`free_buf` 释放宿主分配的所有缓冲
/// （谁分配谁释放，模块侧不得代 free）。
#[repr(C)]
pub struct GStorePlatformApiV1 {
    pub abi_version: u32,
    pub struct_size: u32,  // 宿主此 vtable 的实际大小（向前兼容守卫）
    pub capabilities: u64, // 平台能力位图（PLATFORM_CAP_*）
    pub context: *mut c_void,
    /// 枚举已安装应用 → JSON 列表（out_json）。
    pub list_installed:
        Option<extern "C" fn(ctx: *mut c_void, out_json: *mut ByteBuf) -> c_int>,
    /// 查询单个已安装应用 → JSON（out_json）。
    pub get_installed: Option<
        extern "C" fn(ctx: *mut c_void, package: *const c_char, out_json: *mut ByteBuf) -> c_int,
    >,
    /// 安装 APK（path）→ JSON 结果（out_json）。
    pub install: Option<
        extern "C" fn(ctx: *mut c_void, apk_path: *const c_char, out_json: *mut ByteBuf) -> c_int,
    >,
    /// 卸载应用（package）→ JSON 结果（out_json）。
    pub uninstall: Option<
        extern "C" fn(ctx: *mut c_void, package: *const c_char, out_json: *mut ByteBuf) -> c_int,
    >,
    /// 启动应用（package）→ JSON 结果（out_json）。
    pub launch: Option<
        extern "C" fn(ctx: *mut c_void, package: *const c_char, out_json: *mut ByteBuf) -> c_int,
    >,
    /// 发通知（channel_id/title/body）。
    pub notify: Option<
        extern "C" fn(
            ctx: *mut c_void,
            channel_id: *const c_char,
            title: *const c_char,
            body: *const c_char,
        ) -> c_int,
    >,
    /// 启动前台服务（notification_json 为通知描述 JSON）。
    pub start_foreground: Option<extern "C" fn(ctx: *mut c_void, notification_json: *const c_char) -> c_int>,
    /// 停止前台服务。
    pub stop_foreground: Option<extern "C" fn(ctx: *mut c_void) -> c_int>,
    /// 打开文件（uri + mime）→ JSON 结果（out_json）。
    pub open_file: Option<
        extern "C" fn(
            ctx: *mut c_void,
            uri: *const c_char,
            mime: *const c_char,
            out_json: *mut ByteBuf,
        ) -> c_int,
    >,
    /// 读文件内容 → JSON 结果（out_json）。
    pub read_file: Option<
        extern "C" fn(ctx: *mut c_void, uri: *const c_char, out_json: *mut ByteBuf) -> c_int,
    >,
    /// 在线状态探测 → out_online（0/1）。
    pub is_online: Option<extern "C" fn(ctx: *mut c_void, out_online: *mut c_int) -> c_int>,
    /// 设备信息 → JSON（out_json）。
    pub device_info: Option<extern "C" fn(ctx: *mut c_void, out_json: *mut ByteBuf) -> c_int>,
    /// 释放宿主分配的自有缓冲（**必须保持在 vtable 末尾**；谁分配谁释放）。
    pub free_buf: Option<extern "C" fn(buf: ByteBuf)>,
}

/// 平台能力位：`capabilities` 位图的位定义（按能力逐位置位，u64 位图）。
pub const PLATFORM_CAP_LIST_INSTALLED: u64 = 1 << 0;
pub const PLATFORM_CAP_GET_INSTALLED: u64 = 1 << 1;
pub const PLATFORM_CAP_INSTALL: u64 = 1 << 2;
pub const PLATFORM_CAP_UNINSTALL: u64 = 1 << 3;
pub const PLATFORM_CAP_LAUNCH: u64 = 1 << 4;
pub const PLATFORM_CAP_NOTIFY: u64 = 1 << 5;
pub const PLATFORM_CAP_START_FOREGROUND: u64 = 1 << 6;
pub const PLATFORM_CAP_STOP_FOREGROUND: u64 = 1 << 7;
pub const PLATFORM_CAP_OPEN_FILE: u64 = 1 << 8;
pub const PLATFORM_CAP_READ_FILE: u64 = 1 << 9;
pub const PLATFORM_CAP_IS_ONLINE: u64 = 1 << 10;
pub const PLATFORM_CAP_DEVICE_INFO: u64 = 1 << 11;
/// 全部 12 个能力的位掩码（低 12 位全置位）。
pub const PLATFORM_CAP_ALL: u64 = (1 << 12) - 1;

impl GStorePlatformApiV1 {
    /// 宿主是否声明支持某能力位（fail-closed）。
    ///
    /// `struct_size` 过小（宿主比本版旧、未写满本版槽位布局）或位未置位 → false；
    /// 模块据此**先探测再调用**，绝不调用未声明的回调。
    pub fn has_capability(&self, cap: u64) -> bool {
        if (self.struct_size as usize) < std::mem::size_of::<GStorePlatformApiV1>() {
            return false;
        }
        (self.capabilities & cap) == cap
    }
}

/// 配置 vtable 的上下文绑定（宿主为每个已加载模块各分配一份，按模块生命周期存活）。
///
/// [`GStoreConfigApiV1::context`] 指向本结构：回调拿到的 `ctx` 可解引用为
/// `GStoreConfigContextV1`，其中 `module_id`/`module_name` 是宿主为该模块绑定的
/// **权威身份**——模块不能靠参数自报模块名绕过可见性检查。`host` 是宿主私有
/// 指针（模块不得解引用），用于宿主侧恢复配置服务。
#[repr(C)]
pub struct GStoreConfigContextV1 {
    pub module_id: u64,
    /// 宿主分配的模块名（NUL 结尾，生命周期同 context）。
    pub module_name: *const c_char,
    /// 宿主私有句柄（模块不得解引用）。
    pub host: *mut c_void,
}

/// 宿主配置 vtable（ABI v5 追加，经 `GStoreModuleEntry::config` 注入）。
///
/// **演进规则**：只允许在末尾追加字段；`abi_version`/`struct_size`/`capabilities`
/// 是模块判断「宿主配置能力到哪一版」的唯一依据（先探测再调用，fail-closed）。
///
/// **所有权**：所有 `ByteBuf` 结果由宿主分配，模块只读拷贝，随后必须交给
/// [`GStoreConfigApiV1::free_buf`] 释放（谁分配谁释放；模块不得代为 free，
/// 也不得把 `free_buf` 用在平台 vtable 分配的缓冲上）。失败时 `out_json`
/// 保持 `{null, 0}`，模块无需释放。
///
/// **可见性**：`get`/`list`/`subscribe` 都可指向外模块，但除本模块外只放行
/// `PublicRead` 条目；`Owner`/`Secret` 返回 [`ABI_ERR_CONFIG_FORBIDDEN`]。
/// `set` 永远是本模块写入。`subscribe` 的 `key == NULL`（整模块）不是越权授权：
/// 宿主对**每一条送达的变更**按该条目的可见性重新裁决，后续新增的 `Owner`
/// key 不会被送达。
#[repr(C)]
pub struct GStoreConfigApiV1 {
    pub abi_version: u32,
    pub struct_size: u32,
    pub capabilities: u64,
    /// 指向 [`GStoreConfigContextV1`]（宿主按模块绑定）。
    pub context: *mut c_void,
    /// 读配置：`module_or_null == NULL` 为本模块；否则为跨模块读取（仅 `PublicRead`）。
    /// 成功时 `out_json` 为 JSON 值；未知 key → [`ABI_ERR_CONFIG_NOT_FOUND`]，
    /// 可见性拒绝 → [`ABI_ERR_CONFIG_FORBIDDEN`]，参数非法 → [`ABI_ERR_CONFIG_INVALID`]。
    pub get: Option<
        extern "C" fn(
            ctx: *mut c_void,
            module_or_null: *const c_char,
            key: *const c_char,
            out_json: *mut ByteBuf,
        ) -> c_int,
    >,
    /// 写本模块配置（`key` + `value_json`）。跨模块写入一律
    /// [`ABI_ERR_CONFIG_FORBIDDEN`]。
    pub set: Option<
        extern "C" fn(ctx: *mut c_void, key: *const c_char, value_json: *const c_char) -> c_int,
    >,
    /// 列配置：本模块全部条目；外模块仅 `PublicRead` 条目（JSON 数组）。
    pub list: Option<
        extern "C" fn(
            ctx: *mut c_void,
            module_or_null: *const c_char,
            out_json: *mut ByteBuf,
        ) -> c_int,
    >,
    /// 订阅变更：`module_or_null == NULL` 为本模块；外模块 `key == NULL` 表示
    /// 「该模块中我有权看到的条目」，逐条送达时再按可见性过滤。显式外模块 key
    /// 若非 `PublicRead` 则在此处直接返回 [`ABI_ERR_CONFIG_FORBIDDEN`]。
    /// 成功时 `out_token` 为本模块拥有的订阅令牌。
    pub subscribe: Option<
        extern "C" fn(
            ctx: *mut c_void,
            module_or_null: *const c_char,
            key_or_null: *const c_char,
            user_ctx: *mut c_void,
            callback: Option<extern "C" fn(user_ctx: *mut c_void, change_json: *const c_char) -> c_int>,
            out_token: *mut u64,
        ) -> c_int,
    >,
    /// 取消订阅：只接受 `context` 所属模块自己创建、仍有效的令牌，
    /// 否则 [`ABI_ERR_CONFIG_BAD_TOKEN`]。
    pub unsubscribe: Option<extern "C" fn(ctx: *mut c_void, token: u64) -> c_int>,
    /// 释放本 vtable 分配的缓冲（**必须保持在 vtable 末尾**）。
    pub free_buf: Option<extern "C" fn(buf: ByteBuf)>,
}

/// 配置能力位：`capabilities` 位图的位定义（u64 位图）。
pub const CONFIG_CAP_GET: u64 = 1 << 0;
pub const CONFIG_CAP_SET: u64 = 1 << 1;
pub const CONFIG_CAP_LIST: u64 = 1 << 2;
pub const CONFIG_CAP_SUBSCRIBE: u64 = 1 << 3;
/// 全部 4 个配置能力的位掩码（低 4 位全置位）。
pub const CONFIG_CAP_ALL: u64 = (1 << 4) - 1;

impl GStoreConfigApiV1 {
    /// 宿主是否声明支持某配置能力位（fail-closed）。
    ///
    /// `struct_size` 过小（宿主比本版旧）或位未置位 → false。
    pub fn has_capability(&self, cap: u64) -> bool {
        if (self.struct_size as usize) < std::mem::size_of::<GStoreConfigApiV1>() {
            return false;
        }
        (self.capabilities & cap) == cap
    }
}

/// 模块 → 宿主：模块导出的能力表
#[repr(C)]
pub struct GStoreModuleApi {
    pub name: *const c_char, // 模块自己报名字，宿主不猜
    pub version: u32,        // 模块功能版本
    /// 要求宿主的最低 ABI 版本。默认 [`MIN_HOST_ABI`]（3）；**消费配置 vtable 的
    /// 模块必须设为 5**，使其在 v4 宿主上于 probe 阶段被拒绝（配置是硬依赖）。
    pub min_host_abi: u32,
    pub init: Option<extern "C" fn() -> c_int>,
    pub create: Option<extern "C" fn(
        config: *const u8,
        config_len: usize,
        out_instance: *mut u64,
    ) -> c_int>,
    pub call: Option<extern "C" fn(
        instance: u64,
        method: *const c_char,
        payload: *const u8,
        payload_len: usize,
        out_data: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int>,
    pub cancel: Option<extern "C" fn(instance: u64, request_id: *const c_char) -> c_int>,
    pub destroy: Option<extern "C" fn(instance: u64) -> c_int>,
    pub shutdown: Option<extern "C" fn() -> c_int>,
    pub alloc: Option<extern "C" fn(size: usize) -> *mut c_void>,
    pub free: Option<extern "C" fn(ptr: *mut c_void)>,
    /// 宿主 → 模块 事件下发（下行订阅，ABI v2 追加）：
    /// [kind] 为事件类型（如 "config.changed"），[data] 为 JSON 载荷。
    /// 旧宿主不读取此槽；旧模块不提供（None → 宿主跳过下发）。
    pub on_event: Option<extern "C" fn(
        module_id: u64,
        kind: *const c_char,
        data: *const u8,
        data_len: usize,
    ) -> c_int>,
}

/// C ABI 层错误码（模块 extern "C" 函数返回；为未来模块 .so 契约预留）
#[allow(dead_code)]
pub const ABI_OK: c_int = 0;
pub const ABI_ERR_NULL: c_int = -1;
pub const ABI_ERR_ABI_MISMATCH: c_int = -2;
pub const ABI_ERR_ALREADY: c_int = -3;
pub const ABI_ERR_NO_INSTANCE: c_int = -4;
pub const ABI_ERR_NO_METHOD: c_int = -5;
pub const ABI_ERR_PANIC: c_int = -6;
pub const ABI_ERR_INTERNAL: c_int = -7;
/// 模块把结构化错误（`ModuleError::to_payload` 的 JSON）写入 out 缓冲后返回此码；
/// 宿主据此还原 StatusCode/code/message，避免域错误在 ABI 边界塌成通用内部错误。
pub const ABI_ERR_DETAIL: c_int = -8;

// 配置 vtable 的**类型化错误码**（区别于通用内部错误，模块可据此决定重试/降级）。

/// 跨模块访问被可见性拒绝（`Owner`/`Secret`），或跨模块写入。
pub const ABI_ERR_CONFIG_FORBIDDEN: c_int = -9;
/// 目标 `(module, key)` 不存在。
pub const ABI_ERR_CONFIG_NOT_FOUND: c_int = -10;
/// 参数非法（空指针、非 UTF-8、非法 JSON、非法模块名）。
pub const ABI_ERR_CONFIG_INVALID: c_int = -11;
/// `unsubscribe` 令牌不存在或不属于调用模块。
pub const ABI_ERR_CONFIG_BAD_TOKEN: c_int = -12;

/// 校验宿主 ABI 是否满足模块要求（模块侧握手调用）。
/// 返回 true = 兼容。
pub fn host_abi_satisfies(min_host_abi: u32, host_abi: u32) -> bool {
    min_host_abi <= host_abi
}

#[cfg(test)]
mod tests {
    use super::*;

    extern "C" fn dummy_protect(_fd: c_int) -> c_int {
        0
    }

    /// 编译期不变量：槽位严格按 v3 -> v4 -> v5 追加。
    const _: () = assert!(
        GStoreModuleEntry::PROTECT_FD_OFFSET < GStoreModuleEntry::PLATFORM_OFFSET
    );
    const _: () = assert!(
        GStoreModuleEntry::PLATFORM_OFFSET < GStoreModuleEntry::CONFIG_OFFSET
    );

    /// 构造一条带指定 entry_size/protect_fd/platform/config 的注入表（测试辅助）。
    fn entry_with(
        entry_size: u32,
        protect_fd: Option<extern "C" fn(c_int) -> c_int>,
        platform: *const GStorePlatformApiV1,
        config: *const GStoreConfigApiV1,
    ) -> GStoreModuleEntry {
        GStoreModuleEntry {
            abi_version: GSTORE_MODULE_ABI_VERSION,
            entry_size,
            log: None,
            alloc: None,
            free: None,
            emit_event: None,
            context: std::ptr::null_mut(),
            protect_fd,
            platform,
            config,
        }
    }

    /// 构造一条可寻址的（全字段填零）平台服务 vtable，测试里取它的指针。
    fn dummy_platform_api() -> GStorePlatformApiV1 {
        GStorePlatformApiV1 {
            abi_version: GSTORE_MODULE_ABI_VERSION,
            struct_size: std::mem::size_of::<GStorePlatformApiV1>() as u32,
            capabilities: PLATFORM_CAP_ALL,
            context: std::ptr::null_mut(),
            list_installed: None,
            get_installed: None,
            install: None,
            uninstall: None,
            launch: None,
            notify: None,
            start_foreground: None,
            stop_foreground: None,
            open_file: None,
            read_file: None,
            is_online: None,
            device_info: None,
            free_buf: None,
        }
    }

    /// 构造一条可寻址的（全字段填零）配置 vtable，测试里取它的指针。
    fn dummy_config_api() -> GStoreConfigApiV1 {
        GStoreConfigApiV1 {
            abi_version: GSTORE_MODULE_ABI_VERSION,
            struct_size: std::mem::size_of::<GStoreConfigApiV1>() as u32,
            capabilities: CONFIG_CAP_ALL,
            context: std::ptr::null_mut(),
            get: None,
            set: None,
            list: None,
            subscribe: None,
            unsubscribe: None,
            free_buf: None,
        }
    }

    /// ABI v5 布局断言（具体偏移来自实测，非自我参照）。
    ///
    /// x86_64/64-bit 实测：u32×2（0,4）+ 6 个指针槽（8..48）→ v3 到 protect_fd@48、
    /// 大小 56B；v4 追加 `platform` @56，大小 64B；v5 追加 `config` @64，整体 72B、
    /// 无尾部填充。字段挪动任何一个都会使下方具体数值断言失败。
    #[test]
    fn abi_v5_layout() {
        assert_eq!(GSTORE_MODULE_ABI_VERSION, 5);
        assert_eq!(MIN_HOST_ABI, 3);

        #[cfg(target_pointer_width = "64")]
        {
            assert_eq!(
                GStoreModuleEntry::PROTECT_FD_OFFSET, 48,
                "v3 布局（protect_fd 槽）偏移被移动"
            );
            assert_eq!(GStoreModuleEntry::PLATFORM_OFFSET, 56, "platform 槽偏移被移动");
            assert_eq!(GStoreModuleEntry::CONFIG_OFFSET, 64, "config 槽偏移被移动");
        }

        // 末尾追加、无尾部填充：size == CONFIG_OFFSET + 一个裸指针槽。
        let config_slot = std::mem::size_of::<*const GStoreConfigApiV1>();
        assert_eq!(
            std::mem::size_of::<GStoreModuleEntry>(),
            GStoreModuleEntry::CONFIG_OFFSET + config_slot
        );

        // free_buf 是 GStorePlatformApiV1 的最后一个字段。
        let platform_free = std::mem::offset_of!(GStorePlatformApiV1, free_buf);
        assert_eq!(
            platform_free,
            std::mem::size_of::<GStorePlatformApiV1>()
                - std::mem::size_of::<Option<extern "C" fn(ByteBuf)>>(),
            "free_buf 必须是平台 vtable 最后一个字段"
        );

        // free_buf 同样是 GStoreConfigApiV1 的最后一个字段。
        let config_free = std::mem::offset_of!(GStoreConfigApiV1, free_buf);
        assert_eq!(
            config_free,
            std::mem::size_of::<GStoreConfigApiV1>()
                - std::mem::size_of::<Option<extern "C" fn(ByteBuf)>>(),
            "free_buf 必须是配置 vtable 最后一个字段"
        );

        // ByteBuf = 一个指针 + 一个 usize（64 位 = 16 字节）。
        assert_eq!(std::mem::size_of::<ByteBuf>(), 2 * std::mem::size_of::<usize>());
        #[cfg(target_pointer_width = "64")]
        assert_eq!(std::mem::size_of::<ByteBuf>(), 16);
    }

    /// platform 槽守卫：v3 大小 entry 不得暴露 platform；满尺寸 entry 且指针非空 → 暴露。
    #[test]
    fn platform_guard_rejects_short_entry() {
        let v3 = entry_with(
            GStoreModuleEntry::PLATFORM_OFFSET as u32,
            None,
            std::ptr::null(),
            std::ptr::null(),
        );
        assert!(!v3.has_platform(), "v3 entry 必须被守卫拦下");
        assert!(v3.platform_if_present().is_none());

        let api = dummy_platform_api();
        let full = entry_with(
            std::mem::size_of::<GStoreModuleEntry>() as u32,
            Some(dummy_protect),
            &api as *const GStorePlatformApiV1,
            std::ptr::null(),
        );
        assert!(full.has_platform());
        assert!(full.platform_if_present().is_some());
    }

    /// v4 大小 entry（= CONFIG_OFFSET，64B）必须被 config 守卫拦下，但仍暴露 platform。
    #[test]
    fn config_guard_rejects_v4_entry() {
        let api = dummy_config_api();
        let v4 = entry_with(
            GStoreModuleEntry::CONFIG_OFFSET as u32,
            Some(dummy_protect),
            std::ptr::null(),
            &api as *const GStoreConfigApiV1,
        );
        assert!(!v4.has_config(), "v4 entry 必须被 config 守卫拦下");
        assert!(
            v4.config_if_present().is_none(),
            "v4 entry 不得暴露 config（不得越过 entry_size 读取）"
        );
        assert!(v4.has_platform(), "v4 entry 仍覆盖 platform 槽");
    }

    /// 满尺寸 entry + 非空 config → 暴露；config 槽为 NULL → None（不是悬垂指针）。
    #[test]
    fn full_entry_exposes_config() {
        let api = dummy_config_api();
        let full = entry_with(
            std::mem::size_of::<GStoreModuleEntry>() as u32,
            None,
            std::ptr::null(),
            &api as *const GStoreConfigApiV1,
        );
        assert!(full.has_config());
        let ptr = full.config_if_present().expect("v5 entry must expose config");
        assert!(!ptr.is_null());

        let null_slot = entry_with(
            std::mem::size_of::<GStoreModuleEntry>() as u32,
            None,
            std::ptr::null(),
            std::ptr::null(),
        );
        assert!(null_slot.has_config());
        assert!(null_slot.config_if_present().is_none());
    }

    /// 配置能力位 fail-closed：struct_size 过小或位未置位 → false。
    #[test]
    fn config_capability_probe_fails_closed() {
        let mut api = dummy_config_api();
        assert!(api.has_capability(CONFIG_CAP_GET));
        assert!(api.has_capability(CONFIG_CAP_ALL));

        api.capabilities = CONFIG_CAP_GET | CONFIG_CAP_LIST;
        assert!(!api.has_capability(CONFIG_CAP_SET));
        assert!(!api.has_capability(CONFIG_CAP_ALL));

        api.capabilities = CONFIG_CAP_ALL;
        api.struct_size = (std::mem::size_of::<GStoreConfigApiV1>() - 8) as u32;
        assert!(!api.has_capability(CONFIG_CAP_GET));
    }

    /// 满尺寸 entry 但 platform 槽为 NULL → 视为无平台服务。
    #[test]
    fn null_platform_slot_is_absent() {
        let full = entry_with(
            std::mem::size_of::<GStoreModuleEntry>() as u32,
            None,
            std::ptr::null(),
            std::ptr::null(),
        );
        assert!(full.has_platform());
        assert!(full.platform_if_present().is_none());
    }

    /// 能力位 fail-closed：struct_size 过小或位未置位 → false。
    #[test]
    fn capability_probe_fails_closed() {
        let mut api = dummy_platform_api();
        assert!(api.has_capability(PLATFORM_CAP_LIST_INSTALLED));

        api.capabilities = 0;
        assert!(!api.has_capability(PLATFORM_CAP_LIST_INSTALLED));

        api.capabilities = PLATFORM_CAP_ALL;
        api.struct_size = (std::mem::size_of::<GStorePlatformApiV1>() - 8) as u32;
        assert!(!api.has_capability(PLATFORM_CAP_DEVICE_INFO));
        assert!(!api.has_capability(PLATFORM_CAP_ALL));
    }

    /// protect_fd 是末尾追加字段：v2 布局的 entry_size 恰好等于它的偏移。
    #[test]
    fn smaller_entry_size_skips_protect_fd_without_reading() {
        let v2_size = GStoreModuleEntry::PROTECT_FD_OFFSET as u32;
        assert!(v2_size >= (std::mem::size_of::<u32>() * 2) as u32);
        let old = entry_with(v2_size, None, std::ptr::null(), std::ptr::null());
        assert!(!old.has_protect_fd());
        assert!(old.protect_fd_if_present().is_none());
    }

    /// v3 entry：守卫放行，读到函数指针且调用语义正确。
    #[test]
    fn v3_entry_exposes_protect_fd() {
        let full = std::mem::size_of::<GStoreModuleEntry>() as u32;
        let entry = entry_with(full, Some(dummy_protect), std::ptr::null(), std::ptr::null());
        assert!(entry.has_protect_fd());
        let f = entry.protect_fd_if_present().expect("v3 entry must expose protect_fd");
        assert_eq!(f(42), 0);
    }

    /// 唯一 ABI gate：`min_host_abi > host_abi` 拒绝；旧模块装新宿主放行。
    #[test]
    fn host_abi_gate_is_forward_compatible() {
        assert!(host_abi_satisfies(2, 5), "v2 模块必须能装在 v5 宿主");
        assert!(host_abi_satisfies(3, 5), "v3 模块必须能装在 v5 宿主");
        assert!(host_abi_satisfies(4, 5), "v4 模块必须能装在 v5 宿主");
        assert!(host_abi_satisfies(5, 5));
        assert!(
            !host_abi_satisfies(5, 4),
            "min_host_abi=5（消费配置）的模块必须被 v4 宿主在 probe 阶段拒绝"
        );
        assert!(!host_abi_satisfies(4, 3), "min_host_abi=4 的模块必须被 v3 宿主拒绝");
        assert!(
            !host_abi_satisfies(MIN_HOST_ABI, 2),
            "MIN_HOST_ABI=3 的模块必须被 v2 宿主拒绝"
        );
    }
}
