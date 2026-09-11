// gstore_contract：模块签名验证与版本策略（架构文档第 7 章安全模型）
//
// 安全升级（Phase 2）：Ed25519 签名覆盖 (abi | module_name | version | sha256)，
// 宿主内置公钥编译期钉死（绝不网络获取，否则退化为 TLS）。
// 验证时机：模块 .so 下载校验后、dlopen 前。

use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};

use super::error::{ModuleError, StatusCode, ERR_VERSION_MISMATCH};

/// 签名内容构造（与发布端签名脚本约定的字节序列）：
///   "GSTORE_MODULE_V1" || module_name || '\0' || version || '\0' || abi || '\0' || sha256_hex
/// 注：abi + sha256 在清单 msg 中已含，此处按固定顺序拼接防重排。
pub fn signing_payload(module_name: &str, version: &str, abi: &str, sha256_hex: &str) -> Vec<u8> {
    let mut buf = Vec::with_capacity(64 + module_name.len() + version.len() + abi.len() + sha256_hex.len());
    buf.extend_from_slice(b"GSTORE_MODULE_V1");
    buf.push(0);
    buf.extend_from_slice(module_name.as_bytes());
    buf.push(0);
    buf.extend_from_slice(version.as_bytes());
    buf.push(0);
    buf.extend_from_slice(abi.as_bytes());
    buf.push(0);
    buf.extend_from_slice(sha256_hex.as_bytes());
    buf
}

/// 验证模块签名。公钥为发布端签名公钥（编译期钉死，32 字节）。
/// 签名签名的是 [signing_payload] 字节（发布端经 base64/hex 序列化）
pub fn verify_module_signature(
    module_name: &str,
    version: &str,
    abi: &str,
    sha256_hex: &str,
    signature_hex: &str,
    public_key: &[u8; 32],
) -> Result<(), ModuleError> {
    // 1. 公钥
    let verifying_key = VerifyingKey::from_bytes(public_key).map_err(|e| {
        ModuleError::internal(format!("invalid public key: {e}"))
    })?;

    // 2. 签名（hex → bytes）
    let sig_bytes = hex::decode(signature_hex)
        .map_err(|e| ModuleError::internal(format!("invalid signature hex: {e}")))?;
    let signature = Signature::from_slice(&sig_bytes)
        .map_err(|e| ModuleError::internal(format!("invalid signature: {e}")))?;

    // 3. 验证
    let payload = signing_payload(module_name, version, abi, sha256_hex);
    verifying_key
        .verify(&payload, &signature)
        .map_err(|_| ModuleError::new(
            StatusCode::InternalError,
            "SIGNATURE_MISMATCH",
            "module signature verification failed",
        ))
}

/// 模块 .so 的 SHA-256（hex）
pub fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

/// 版本降级拒绝策略：新版本号整体低于已记录版本则拒绝（防降级攻击）。
/// 语义比较点分版本 "1.2.3"（不支持预发布后缀）。
pub fn is_version_downgrade(new_version: &str, last_known_good: Option<&str>) -> bool {
    match last_known_good {
        None => false,
        Some(prev) => parse_version(new_version) < parse_version(prev),
    }
}

fn parse_version(v: &str) -> (u64, u64, u64) {
    let mut parts = v.split('.');
    let major = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    let minor = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    let patch = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    (major, minor, patch)
}

pub fn version_mismatch_err(msg: impl Into<String>) -> ModuleError {
    ModuleError::new(StatusCode::VersionMismatch, ERR_VERSION_MISMATCH, msg)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use rand_core::OsRng;

    fn hex_bytes(bytes: &[u8]) -> String {
        hex::encode(bytes)
    }

    #[test]
    fn signature_verify_roundtrip() {
        let signing_key = SigningKey::generate(&mut OsRng);
        let verifying_key = signing_key.verifying_key();
        let pub_bytes: [u8; 32] = verifying_key.to_bytes();

        let msg = signing_payload("qr", "0.1.0", "arm64-v8a", "abc123");
        let signature = signing_key.sign(&msg);
        let sig_hex = hex_bytes(&signature.to_bytes());

        // 正确签名 → 通过
        assert!(verify_module_signature("qr", "0.1.0", "arm64-v8a", "abc123", &sig_hex, &pub_bytes).is_ok());

        // 篡改 payload → 拒绝
        assert!(verify_module_signature("qr", "0.1.0", "arm64-v8a", "abc124", &sig_hex, &pub_bytes).is_err());
        // 篡改 module 名 → 拒绝
        assert!(verify_module_signature("analyzer", "0.1.0", "arm64-v8a", "abc123", &sig_hex, &pub_bytes).is_err());
    }

    #[test]
    fn sha256_hex_is_stable() {
        assert_eq!(sha256_hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    #[test]
    fn version_downgrade_detection() {
        assert!(!is_version_downgrade("0.1.0", None));
        assert!(!is_version_downgrade("0.2.0", Some("0.1.0")));
        assert!(!is_version_downgrade("1.0.0", Some("0.9.9")));
        assert!(is_version_downgrade("0.1.0", Some("0.2.0")));
        assert!(is_version_downgrade("0.5.3", Some("0.9.9")));
        assert!(!is_version_downgrade("0.10.0", Some("0.9.0"))); // 点分：10 > 9
    }
}