// gstore_contract：统一数据模型信封（架构文档 6.1）——P3 prost 实现
//
// 本模块是 prost 生成消息（src/pb/envelope.rs）的封装层：
// - 对宿主暴露与 P1 serde 版相同的 API（new/encode/decode/ok/err/is_ok），宿主零改动
// - wire 格式为 protobuf（EnvelopeRequest/Response/Cancel + 状态码枚举）
// - StatusCode 语义枚举见 error.rs（Rust 内部错误模型），此处经 i32 桥接

use prost::Message as _;

use super::error::{ModuleError, StatusCode};
use crate::pb;

pub use crate::pb::{CancelReason, PayloadFormat};

/// 协议版本
pub const PROTOCOL_VERSION: u32 = 1;

/// 请求信封（类似 HTTP Request）
#[derive(Debug, Clone, PartialEq)]
pub struct EnvelopeRequest {
    inner: pb::EnvelopeRequest,
}

impl EnvelopeRequest {
    pub fn new(module: &str, instance: Option<&str>, method: &str, payload: Vec<u8>) -> Self {
        Self {
            inner: pb::EnvelopeRequest {
                protocol_version: PROTOCOL_VERSION,
                module: module.to_string(),
                instance: instance.unwrap_or("").to_string(),
                method: method.to_string(),
                request_id: String::new(),
                timestamp_ms: 0,
                payload_format: pb::PayloadFormat::PayloadJson as i32,
                metadata: Default::default(),
                payload,
            },
        }
    }

    pub fn module(&self) -> &str {
        &self.inner.module
    }
    pub fn instance(&self) -> &str {
        &self.inner.instance
    }
    pub fn method(&self) -> &str {
        &self.inner.method
    }
    pub fn request_id(&self) -> &str {
        &self.inner.request_id
    }
    pub fn payload(&self) -> &[u8] {
        &self.inner.payload
    }
    pub fn with_request_id(mut self, id: &str) -> Self {
        self.inner.request_id = id.to_string();
        self
    }

    pub fn encode(&self) -> Result<Vec<u8>, ModuleError> {
        Ok(self.inner.encode_to_vec())
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, ModuleError> {
        pb::EnvelopeRequest::decode(bytes)
            .map(|inner| Self { inner })
            .map_err(|e| {
                ModuleError::new(
                    StatusCode::BadRequest,
                    super::error::ERR_BAD_REQUEST,
                    "envelope decode failed",
                )
                .with_cause(e)
            })
    }
}

/// 响应信封（类似 HTTP Response）
#[derive(Debug, Clone, PartialEq)]
pub struct EnvelopeResponse {
    inner: pb::EnvelopeResponse,
}

impl EnvelopeResponse {
    pub fn ok(request_id: &str, payload: Vec<u8>) -> Self {
        Self {
            inner: pb::EnvelopeResponse {
                protocol_version: PROTOCOL_VERSION,
                request_id: request_id.to_string(),
                status: pb::StatusCode::StatusOk as i32,
                error_code: String::new(),
                error_message: String::new(),
                timestamp_ms: 0,
                duration_ms: 0,
                metadata: Default::default(),
                payload,
            },
        }
    }

    pub fn err(request_id: &str, err: &ModuleError) -> Self {
        Self {
            inner: pb::EnvelopeResponse {
                protocol_version: PROTOCOL_VERSION,
                request_id: request_id.to_string(),
                status: status_to_pb(err.status),
                error_code: err.code.to_string(),
                error_message: err.message.clone(),
                timestamp_ms: 0,
                duration_ms: 0,
                metadata: Default::default(),
                payload: Vec::new(),
            },
        }
    }

    pub fn is_ok(&self) -> bool {
        self.inner.status >= 200 && self.inner.status < 300
    }

    pub fn status(&self) -> i32 {
        self.inner.status
    }
    pub fn error_code(&self) -> &str {
        &self.inner.error_code
    }
    pub fn error_message(&self) -> &str {
        &self.inner.error_message
    }
    pub fn request_id(&self) -> &str {
        &self.inner.request_id
    }
    pub fn payload(&self) -> &[u8] {
        &self.inner.payload
    }

    pub fn encode(&self) -> Result<Vec<u8>, ModuleError> {
        Ok(self.inner.encode_to_vec())
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, ModuleError> {
        pb::EnvelopeResponse::decode(bytes)
            .map(|inner| Self { inner })
            .map_err(|e| {
                ModuleError::new(
                    StatusCode::BadRequest,
                    super::error::ERR_BAD_REQUEST,
                    "envelope decode failed",
                )
                .with_cause(e)
            })
    }
}

/// 取消消息（主动中断长任务）
#[derive(Debug, Clone, PartialEq)]
pub struct EnvelopeCancel {
    inner: pb::EnvelopeCancel,
}

impl EnvelopeCancel {
    pub fn new(module: &str, instance: Option<&str>, method: &str) -> Self {
        Self {
            inner: pb::EnvelopeCancel {
                protocol_version: PROTOCOL_VERSION,
                request_id: String::new(),
                module: module.to_string(),
                instance: instance.unwrap_or("").to_string(),
                method: method.to_string(),
                reason: pb::CancelReason::CancelUser as i32,
            },
        }
    }

    pub fn with_request_id(mut self, id: &str) -> Self {
        self.inner.request_id = id.to_string();
        self
    }

    pub fn request_id(&self) -> &str {
        &self.inner.request_id
    }
    pub fn module(&self) -> &str {
        &self.inner.module
    }

    pub fn encode(&self) -> Result<Vec<u8>, ModuleError> {
        Ok(self.inner.encode_to_vec())
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, ModuleError> {
        pb::EnvelopeCancel::decode(bytes)
            .map(|inner| Self { inner })
            .map_err(|e| {
                ModuleError::new(
                    StatusCode::BadRequest,
                    super::error::ERR_BAD_REQUEST,
                    "cancel decode failed",
                )
                .with_cause(e)
            })
    }
}

/// Rust 内部 StatusCode → proto StatusCode（数值一致）
pub(crate) fn status_to_pb(status: StatusCode) -> i32 {
    match status {
        StatusCode::Ok => pb::StatusCode::StatusOk as i32,
        StatusCode::Created => pb::StatusCode::StatusCreated as i32,
        StatusCode::ModuleNotLoaded => pb::StatusCode::StatusModuleNotLoaded as i32,
        StatusCode::InstanceExpired => pb::StatusCode::StatusInstanceExpired as i32,
        StatusCode::BadRequest => pb::StatusCode::StatusBadRequest as i32,
        StatusCode::ModuleNotFound => pb::StatusCode::StatusModuleNotFound as i32,
        StatusCode::MethodNotFound => pb::StatusCode::StatusMethodNotFound as i32,
        StatusCode::InstanceNotFound => pb::StatusCode::StatusInstanceNotFound as i32,
        StatusCode::InvalidArgument => pb::StatusCode::StatusInvalidArgument as i32,
        StatusCode::VersionMismatch => pb::StatusCode::StatusVersionMismatch as i32,
        StatusCode::Aborted => pb::StatusCode::StatusAborted as i32,
        StatusCode::InternalError => pb::StatusCode::StatusInternalError as i32,
        StatusCode::PanicCaught => pb::StatusCode::StatusPanicCaught as i32,
        StatusCode::ResourceExhausted => pb::StatusCode::StatusResourceExhausted as i32,
        StatusCode::Timeout => pb::StatusCode::StatusTimeout as i32,
    }
}

/// 反向：i32 → Rust 内部 StatusCode（未知值归 InternalError）
pub fn status_from_i32(v: i32) -> StatusCode {
    match v {
        200 => StatusCode::Ok,
        201 => StatusCode::Created,
        301 => StatusCode::ModuleNotLoaded,
        302 => StatusCode::InstanceExpired,
        400 => StatusCode::BadRequest,
        404 => StatusCode::ModuleNotFound,
        405 => StatusCode::MethodNotFound,
        410 => StatusCode::InstanceNotFound,
        422 => StatusCode::InvalidArgument,
        426 => StatusCode::VersionMismatch,
        499 => StatusCode::Aborted,
        500 => StatusCode::InternalError,
        5001 => StatusCode::PanicCaught,
        507 => StatusCode::ResourceExhausted,
        504 => StatusCode::Timeout,
        _ => StatusCode::InternalError,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_response_roundtrip() {
        let req = EnvelopeRequest::new("qr", Some("42"), "decode_luma", vec![1, 2, 3])
            .with_request_id("req-1");
        let bytes = req.encode().unwrap();
        let decoded = EnvelopeRequest::decode(&bytes).unwrap();
        assert_eq!(decoded.module(), "qr");
        assert_eq!(decoded.instance(), "42");
        assert_eq!(decoded.method(), "decode_luma");
        assert_eq!(decoded.payload(), &[1, 2, 3]);
        assert_eq!(decoded.request_id(), "req-1");
    }

    #[test]
    fn error_response_carries_status_and_code() {
        let err = ModuleError::invalid_arg("luma size != w*h");
        let resp = EnvelopeResponse::err("req-1", &err);
        assert_eq!(resp.status(), 422);
        assert_eq!(resp.error_code(), crate::error::ERR_INVALID_ARGUMENT);
        assert!(!resp.is_ok());

        // 信封往返保持错误信息
        let bytes = resp.encode().unwrap();
        let decoded = EnvelopeResponse::decode(&bytes).unwrap();
        assert_eq!(decoded.status(), 422);
        assert_eq!(decoded.error_message(), "luma size != w*h");
    }

    #[test]
    fn ok_response_is_ok() {
        let resp = EnvelopeResponse::ok("req-1", vec![9]);
        assert!(resp.is_ok());
        assert_eq!(resp.status(), 200);

        let decoded = EnvelopeResponse::decode(&resp.encode().unwrap()).unwrap();
        assert_eq!(decoded.payload(), &[9]);
    }

    #[test]
    fn status_mapping_roundtrip() {
        for s in [
            StatusCode::Ok,
            StatusCode::InvalidArgument,
            StatusCode::ModuleNotFound,
            StatusCode::Aborted,
            StatusCode::PanicCaught,
        ] {
            assert_eq!(s, status_from_i32(status_to_pb(s)));
        }
    }

    #[test]
    fn cancel_roundtrip() {
        let cancel = EnvelopeCancel::new("qr", Some("42"), "decode_luma").with_request_id("req-2");
        let decoded = EnvelopeCancel::decode(&cancel.encode().unwrap()).unwrap();
        assert_eq!(decoded.module(), "qr");
        assert_eq!(decoded.request_id(), "req-2");
    }
}
