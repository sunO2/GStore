// gstore_contract：模块 C ABI 契约（单 .so 过渡期：宿主内实现，未来抽独立 crate）
//
// 本模块只包含 #[repr(C)] 结构体 + 函数指针类型，宿主与（未来）模块 .so 共享。
// 任何结构体布局变更都必须递增 GSTORE_MODULE_ABI_VERSION。

use std::os::raw::{c_char, c_int, c_void};

/// 模块 ABI 版本：任何一端结构体布局变更都必须 +1
///
/// v2：`GStoreModuleApi` 追加 `on_event`（宿主→模块事件下发）。
/// v3：`GStoreModuleEntry` 追加 `protect_fd`（宿主→模块 socket 保护服务）。
pub const GSTORE_MODULE_ABI_VERSION: u32 = 3;

/// 宿主 → 模块：宿主服务的注入表（按值注入，模块只读保存，不 dlsym 宿主符号）
///
/// **ABI 演进规则（与 v2 `on_event` 一致）：只允许在结构体末尾追加字段**，
/// 绝不重排/重命名/删除既有字段。模块侧读取新增槽前，必须先用
/// [`GStoreModuleEntry::protect_fd_if_present`] 按 `entry_size` 守卫，
/// 旧宿主（更小的 `entry_size`）下不得越界读取。
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

    fn entry_with_size(entry_size: u32, protect_fd: Option<extern "C" fn(c_int) -> c_int>) -> GStoreModuleEntry {
        GStoreModuleEntry {
            abi_version: GSTORE_MODULE_ABI_VERSION,
            entry_size,
            log: None,
            alloc: None,
            free: None,
            emit_event: None,
            context: std::ptr::null_mut(),
            protect_fd,
        }
    }

    /// 可 grep 的断言：ABI 已升到 v3（protect_fd 槽）。
    #[test]
    fn abi_version_is_3() {
        assert_eq!(GSTORE_MODULE_ABI_VERSION, 3);
    }

    /// protect_fd 是末尾追加字段：v2 布局的 entry_size 恰好等于它的偏移，
    /// 旧 entry 必须被守卫拦住、不得读取该槽。
    #[test]
    fn smaller_entry_size_skips_protect_fd_without_reading() {
        let v2_size = GStoreModuleEntry::PROTECT_FD_OFFSET as u32;
        assert!(v2_size >= (std::mem::size_of::<u32>() * 2) as u32);
        let old = entry_with_size(v2_size, None);
        assert!(!old.has_protect_fd());
        assert!(old.protect_fd_if_present().is_none());
    }

    /// v3 entry：守卫放行，读到函数指针且调用语义正确。
    #[test]
    fn v3_entry_exposes_protect_fd() {
        let full = std::mem::size_of::<GStoreModuleEntry>() as u32;
        let entry = entry_with_size(full, Some(dummy_protect));
        assert!(entry.has_protect_fd());
        let f = entry.protect_fd_if_present().expect("v3 entry must expose protect_fd");
        assert_eq!(f(42), 0);
    }

    /// 唯一 ABI gate：`min_host_abi > host_abi` 拒绝；v2 模块装 v3 宿主放行。
    #[test]
    fn host_abi_gate_is_forward_compatible() {
        assert!(host_abi_satisfies(2, 3), "v2 模块必须能装在 v3 宿主");
        assert!(host_abi_satisfies(3, 3));
        assert!(!host_abi_satisfies(3, 2), "min_host_abi=3 的模块必须被 v2 宿主拒绝");
    }
}
