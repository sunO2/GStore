// gstore_contract：模块 C ABI 契约（单 .so 过渡期：宿主内实现，未来抽独立 crate）
//
// 本模块只包含 #[repr(C)] 结构体 + 函数指针类型，宿主与（未来）模块 .so 共享。
// 任何结构体布局变更都必须递增 GSTORE_MODULE_ABI_VERSION。

use std::os::raw::{c_char, c_int, c_void};

/// 模块 ABI 版本：任何一端结构体布局变更都必须 +1
pub const GSTORE_MODULE_ABI_VERSION: u32 = 1;

/// 宿主 → 模块：宿主服务的注入表（按值注入，模块只读保存，不 dlsym 宿主符号）
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
}

/// 模块 → 宿主：模块导出的能力表
#[repr(C)]
pub struct GStoreModuleApi {
    pub name: *const c_char, // 模块自己报名字，宿主不猜
    pub version: u32,        // 模块功能版本
    pub min_host_abi: u32,   // 要求宿主的最低 ABI 版本
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
