// gstore_contract：统一错误模型（协议层 + 域层错误码，见架构文档 6.4/6.5）

use std::fmt;
use std::error::Error as StdError;

/// 状态码大类（对应信封 EnvelopeResponse.status，仿 HTTP 语义分层）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum StatusCode {
    // 2xx 成功
    Ok = 200,
    Created = 201,
    // 3xx 需要客户端配合（流程，非错误）
    ModuleNotLoaded = 301,
    InstanceExpired = 302,
    // 4xx 调用方错误
    BadRequest = 400,
    ModuleNotFound = 404,
    MethodNotFound = 405,
    InstanceNotFound = 410,
    InvalidArgument = 422,
    VersionMismatch = 426,
    // 499 主动取消
    Aborted = 499,
    // 5xx 模块内部错误
    InternalError = 500,
    PanicCaught = 5001,
    ResourceExhausted = 507,
    Timeout = 504,
}

/// 协议层错误码（宿主兜底，所有模块通用；域层错误码由模块以 `模块名_` 前缀自填）
pub const ERR_MODULE_NOT_FOUND: &str = "MODULE_NOT_FOUND";
pub const ERR_METHOD_NOT_FOUND: &str = "METHOD_NOT_FOUND";
pub const ERR_INSTANCE_NOT_FOUND: &str = "INSTANCE_NOT_FOUND";
pub const ERR_BAD_REQUEST: &str = "BAD_REQUEST";
pub const ERR_INVALID_ARGUMENT: &str = "INVALID_ARGUMENT";
pub const ERR_VERSION_MISMATCH: &str = "VERSION_MISMATCH";
pub const ERR_INTERNAL: &str = "INTERNAL_ERROR";
pub const ERR_PANIC_CAUGHT: &str = "PANIC_CAUGHT";
pub const ERR_CANCELLED: &str = "CANCELLED";

/// 统一模块错误：模块内部所有错误（thiserror/anyhow）最终收敛为此类型
#[derive(Debug)]
pub struct ModuleError {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: String,
    pub cause: Option<Box<dyn StdError + Send + Sync>>,
}

impl ModuleError {
    pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self { status, code, message: message.into(), cause: None }
    }

    pub fn invalid_arg(message: impl Into<String>) -> Self {
        Self::new(StatusCode::InvalidArgument, ERR_INVALID_ARGUMENT, message)
    }

    pub fn module_not_found(module: &str) -> Self {
        Self::new(StatusCode::ModuleNotFound, ERR_MODULE_NOT_FOUND, format!("module not found: {module}"))
    }

    pub fn method_not_found(method: &str) -> Self {
        Self::new(StatusCode::MethodNotFound, ERR_METHOD_NOT_FOUND, format!("method not found: {method}"))
    }

    pub fn instance_not_found(instance: u64) -> Self {
        Self::new(StatusCode::InstanceNotFound, ERR_INSTANCE_NOT_FOUND, format!("instance not found: {instance}"))
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(StatusCode::InternalError, ERR_INTERNAL, message)
    }

    pub fn panic(message: impl Into<String>) -> Self {
        Self::new(StatusCode::PanicCaught, ERR_PANIC_CAUGHT, message)
    }

    pub fn cancelled() -> Self {
        Self::new(StatusCode::Aborted, ERR_CANCELLED, "call aborted")
    }

    pub fn with_cause(mut self, cause: impl StdError + Send + Sync + 'static) -> Self {
        self.cause = Some(Box::new(cause));
        self
    }
}

impl fmt::Display for ModuleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}: {}", self.status as i32, self.code, self.message)
    }
}

impl StdError for ModuleError {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        self.cause.as_deref().map(|e| e as &(dyn StdError + 'static))
    }
}

impl From<ModuleError> for String {
    fn from(e: ModuleError) -> Self {
        e.to_string()
    }
}

/// 便捷：把 anyhow 类错误转换为统一 ModuleError（根因保留；供未来模块错误映射使用）
#[allow(dead_code)]
pub fn into_module_error(cause: impl StdError + Send + Sync + 'static, code: &'static str, message: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::InternalError, code, message).with_cause(cause)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn module_error_roundtrip() {
        let e = ModuleError::invalid_arg("bad luma size");
        let s = e.to_string();
        assert!(s.contains("422"));
        assert!(s.contains(ERR_INVALID_ARGUMENT));
        assert_eq!(e.status as i32, 422);
    }

    #[test]
    fn status_codes_match_http_semantics() {
        assert_eq!(StatusCode::Ok as i32, 200);
        assert_eq!(StatusCode::ModuleNotFound as i32, 404);
        assert_eq!(StatusCode::Aborted as i32, 499);
        assert_eq!(StatusCode::InternalError as i32, 500);
    }
}
