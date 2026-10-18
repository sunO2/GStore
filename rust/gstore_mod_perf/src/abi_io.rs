//! C ABI 边界 I/O：输出缓冲分配（`libc::malloc`）、结构化错误载荷、统一成功信封。

use std::ffi::c_int;

use gstore_contract::abi::{ABI_ERR_DETAIL, ABI_ERR_INTERNAL};
use gstore_contract::error::ModuleError;

use crate::state::log_message;

/// 写出响应字节（模块分配内存，宿主用模块 `free` 释放；统一 `libc::malloc`）。
pub fn write_out(bytes: Vec<u8>, out_data: *mut *mut u8, out_len: *mut usize) -> Result<(), c_int> {
    let len = bytes.len();
    let ptr = unsafe { libc::malloc(len.max(1)) };
    if ptr.is_null() {
        return Err(ABI_ERR_INTERNAL);
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, len);
        *out_data = ptr as *mut u8;
        *out_len = len;
    }
    Ok(())
}

/// 写出结构化错误载荷并以 `ABI_ERR_DETAIL` 返回（宿主据此还原 StatusCode/code/message）。
pub fn write_error_out(
    err: ModuleError,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    log_message(3, &format!("perf: {err}"));
    let _ = write_out(err.to_payload(), out_data, out_len);
    Err(ABI_ERR_DETAIL)
}

/// 安全取载荷切片（空指针/零长 → 空切片）。
pub fn payload_bytes<'a>(payload: *const u8, len: usize) -> &'a [u8] {
    if payload.is_null() || len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(payload, len) }
    }
}

/// 统一成功信封：`{"ok":true,"data":{...}}`。
pub fn ok_data(data: serde_json::Value) -> Result<Vec<u8>, ModuleError> {
    serde_json::to_vec(&serde_json::json!({ "ok": true, "data": data }))
        .map_err(|e| ModuleError::internal(e.to_string()))
}
