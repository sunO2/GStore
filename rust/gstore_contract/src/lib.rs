// gstore_contract：宿主与模块共享的契约层（架构文档第 3/6 章）
//
// 独立 crate，供 gstore_host 宿主与未来模块 .so 共享：
// abi.rs（C ABI 结构体）、envelope.rs（信封模型）、error.rs（统一错误）、logging.rs（日志桥）。
// 本层是面向模块的公共契约 API，宿主主流程当前不全部调用属预期
// （如 abi.rs 的 C 结构体、envelope 的编解码、logging 的 HostLogger），
// 模块拆分后即被消费，故模块级禁用 dead_code 告警。
#![allow(dead_code)]

pub mod abi;
pub mod envelope;
pub mod error;
pub mod logging;
pub mod security;

/// prost 生成的 protobuf 代码（build.rs 编译 proto/envelope.proto 输出到此；
/// 生成并提交，Android 交叉编译使用提交的副本 src/pb/envelope.rs）
#[path = "pb/envelope.rs"]
pub mod pb;

/// 从 build.rs 的 OUT_DIR 动态生成的副本（常规开发构建用；编译失败时用提交的 src/pb）
#[cfg(feature = "dynamic-pb")]
pub mod pb_dynamic {
    include!(concat!(env!("OUT_DIR"), "/gstore.contract.rs"));
}
