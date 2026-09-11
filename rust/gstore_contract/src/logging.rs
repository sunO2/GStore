// gstore_contract：日志桥（架构文档 6.8）
//
// 通道宿主一份：模块通过 GStoreModuleEntry.log 回调把 log! 日志交给宿主，
// 宿主经 FRB Stream 汇入 Flutter LogManager。本模块提供模块侧的一行挂接 helper。

use std::os::raw::{c_char, c_int};
use std::ffi::CString;

/// Rust log::Level → 宿主约定的 int 等级（与 Dart LogLevel 对齐：0=debug,1=info,2=warn,3=error）
pub fn level_to_int(level: log::Level) -> c_int {
    match level {
        log::Level::Trace | log::Level::Debug => 0,
        log::Level::Info => 1,
        log::Level::Warn => 2,
        log::Level::Error => 3,
    }
}

/// 包裹宿主注入的 log 函数指针，实现 log::Log trait
pub struct HostLogger {
    log_fn: extern "C" fn(c_int, *const c_char),
}

impl HostLogger {
    pub fn new(log_fn: extern "C" fn(c_int, *const c_char)) -> Self {
        Self { log_fn }
    }
}

impl log::Log for HostLogger {
    fn enabled(&self, _metadata: &log::Metadata) -> bool {
        true
    }

    fn log(&self, record: &log::Record) {
        // 尽量不失败：CString 构造失败（内部 NUL）时静默丢弃该条日志
        if let Ok(msg) = CString::new(record.args().to_string()) {
            (self.log_fn)(level_to_int(record.level()), msg.as_ptr());
        }
    }

    fn flush(&self) {}
}

/// 模块在 register 握手后调用一次：把模块内 log! 宏汇入宿主日志通道。
/// 利用"logger 静态是每 .so 独立"的特性，各模块设置自己的 logger 但指向同一宿主回调。
pub fn attach_host_logger(
    entry: &crate::abi::GStoreModuleEntry,
    max_level: log::LevelFilter,
) -> Result<(), String> {
    let log_fn = entry.log.ok_or("host log callback not provided")?;
    log::set_boxed_logger(Box::new(HostLogger::new(log_fn)))
        .map_err(|e| format!("failed to attach host logger: {e}"))?;
    log::set_max_level(max_level);
    Ok(())
}
