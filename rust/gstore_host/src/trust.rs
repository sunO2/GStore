// 模块信任根：下载模块的签名校验（架构文档第 7 章安全模型）
//
// 设计要点：
// - 公钥编译期钉死（[MODULE_SIGNING_PUBKEY_HEX]），绝不网络获取，否则退化为 TLS。
// - 校验时机：宿主 dlopen 之前（本模块被 bridge::mount_from_so 调用）。
// - 信任分层：**没有** `.sig` 侧车文件的模块视为"随包内置"（与 APK 同信任锚）直接放行；
//   一旦携带 `.sig`，则必须通过 Ed25519 校验，否则拒绝加载（fail-closed）。
//   这样远程下载路径（Dart 会写入 .sig/.meta）强制签名，内置 jniLibs 路径零开销。

use std::path::Path;

use gstore_contract::security::{sha256_hex, verify_module_signature};

/// 发布端模块签名公钥（hex，32 字节）。为空 = 未配置（此时任何携带签名的模块都会被拒绝）。
/// 发布流程见 `rust/sign_module.py`；公钥由发布者离线生成后填入此处并随版本固化。
pub const MODULE_SIGNING_PUBKEY_HEX: &str = "";

/// 解析钉死公钥；空/非法 → None
fn pinned_pubkey() -> Option<[u8; 32]> {
    let hex = MODULE_SIGNING_PUBKEY_HEX.trim();
    if hex.is_empty() {
        return None;
    }
    let bytes = hex_decode(hex)?;
    if bytes.len() != 32 {
        return None;
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&bytes);
    Some(key)
}

/// 侧车元数据（`<so>.meta`，JSON）：签名覆盖的字段
#[derive(serde::Deserialize)]
struct ModuleMeta {
    name: String,
    version: String,
    abi: String,
}

/// 校验模块文件（生产入口）：使用编译期钉死的公钥 [MODULE_SIGNING_PUBKEY_HEX]。
/// - 无 `<so>.sig` → Ok（内置/未签名，随包信任）
/// - 有 `<so>.sig` → 必须有钉死公钥 + `<so>.meta`，且签名与 sha256 匹配，否则 Err
pub fn verify_module_file(so_path: &Path) -> Result<(), String> {
    verify_module_file_with_key(so_path, pinned_pubkey())
}

/// 可测校验入口：语义与 [verify_module_file] 完全一致，但显式传入公钥，
/// 便于单测用固定测试密钥覆盖 `.meta`/签名失败分支，而不依赖钉死常量。
/// `public_key == None`（未配置）时，任何携带 `.sig` 的模块一律拒绝（fail-closed）。
pub fn verify_module_file_with_key(
    so_path: &Path,
    public_key: Option<[u8; 32]>,
) -> Result<(), String> {
    let so_str = so_path.to_string_lossy().to_string();
    let sig_path = format!("{so_str}.sig");
    if !Path::new(&sig_path).exists() {
        return Ok(()); // 未签名：按内置模块处理
    }

    let public_key = public_key
        .ok_or_else(|| "module is signed but no pinned public key is configured".to_string())?;

    let signature_hex = std::fs::read_to_string(&sig_path)
        .map_err(|e| format!("read signature failed: {e}"))?
        .trim()
        .to_string();
    if signature_hex.is_empty() {
        return Err("empty signature file".to_string());
    }

    let meta_path = format!("{so_str}.meta");
    let meta_raw = std::fs::read_to_string(&meta_path)
        .map_err(|e| format!("read module meta failed ({meta_path}): {e}"))?;
    let meta: ModuleMeta =
        serde_json::from_str(&meta_raw).map_err(|e| format!("parse module meta failed: {e}"))?;

    let so_bytes = std::fs::read(so_path).map_err(|e| format!("read module .so failed: {e}"))?;
    let sha = sha256_hex(&so_bytes);

    verify_module_signature(
        &meta.name,
        &meta.version,
        &meta.abi,
        &sha,
        &signature_hex,
        &public_key,
    )
    .map(|_| ())
    .map_err(|e| format!("module signature rejected: {e}"))
}

/// 极简 hex 解码（避免为 host 引入额外依赖；输入应为偶数长度十六进制）
fn hex_decode(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    if s.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let hi = (bytes[i] as char).to_digit(16)?;
        let lo = (bytes[i + 1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
        i += 2;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    use ed25519_dalek::{Signer, SigningKey};

    fn test_key() -> SigningKey {
        SigningKey::from_bytes(&[0x2a; 32])
    }

    fn test_pubkey() -> [u8; 32] {
        test_key().verifying_key().to_bytes()
    }

    fn hex_encode(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    struct TestDir(PathBuf);

    impl TestDir {
        fn new(tag: &str) -> Self {
            use std::sync::atomic::{AtomicU64, Ordering};
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            let dir = std::env::temp_dir().join(format!(
                "gstore_trust_{tag}_{}_{}_{}",
                std::process::id(),
                seq,
                nanos
            ));
            std::fs::create_dir_all(&dir).unwrap();
            TestDir(dir)
        }

        fn so_path(&self) -> PathBuf {
            self.0.join("libgstore_mod_qr_1.0.0.so")
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn meta_json(name: &str, version: &str, abi: &str) -> String {
        format!(r#"{{"name":"{name}","version":"{version}","abi":"{abi}"}}"#)
    }

    fn sign_for(name: &str, version: &str, abi: &str, sha: &str) -> String {
        let payload = gstore_contract::security::signing_payload(name, version, abi, sha);
        hex_encode(&test_key().sign(&payload).to_bytes())
    }

    fn write_module(
        dir: &TestDir,
        so_bytes: &[u8],
        meta: Option<&str>,
        signature_hex: Option<&str>,
    ) -> PathBuf {
        let so_path = dir.so_path();
        std::fs::write(&so_path, so_bytes).unwrap();
        if let Some(sig) = signature_hex {
            std::fs::write(format!("{}.sig", so_path.display()), sig).unwrap();
        }
        if let Some(meta) = meta {
            std::fs::write(format!("{}.meta", so_path.display()), meta).unwrap();
        }
        so_path
    }

    #[test]
    fn hex_decode_roundtrip() {
        assert_eq!(hex_decode("00ff10"), Some(vec![0x00, 0xff, 0x10]));
        assert_eq!(hex_decode("abc"), None); // 奇数长度
        assert_eq!(hex_decode("zz"), None); // 非十六进制
    }

    #[test]
    fn unsigned_module_is_allowed() {
        // 不存在的路径且无 .sig → 视为未签名，放行
        let p = std::path::Path::new("/nonexistent/libgstore_mod_x.so");
        assert!(verify_module_file(p).is_ok());
    }

    #[test]
    fn valid_signature_with_test_key_is_allowed() {
        let dir = TestDir::new("valid");
        let so_bytes = b"\x7fELF fake qr module payload";
        let sha = sha256_hex(so_bytes);
        let sig = sign_for("qr", "1.0.0", "arm64-v8a", &sha);
        let so_path = write_module(
            &dir,
            so_bytes,
            Some(&meta_json("qr", "1.0.0", "arm64-v8a")),
            Some(&sig),
        );
        assert!(verify_module_file_with_key(&so_path, Some(test_pubkey())).is_ok());
    }

    #[test]
    fn signed_missing_meta_is_rejected() {
        let dir = TestDir::new("missing-meta");
        let so_bytes = b"payload-without-meta";
        let sha = sha256_hex(so_bytes);
        let sig = sign_for("qr", "1.0.0", "arm64-v8a", &sha);
        let so_path = write_module(&dir, so_bytes, None, Some(&sig));
        let err = verify_module_file_with_key(&so_path, Some(test_pubkey())).unwrap_err();
        assert!(err.contains("read module meta failed"), "unexpected error: {err}");
    }

    #[test]
    fn signed_malformed_meta_is_rejected() {
        let dir = TestDir::new("malformed-meta");
        let so_bytes = b"payload-malformed-meta";
        let sha = sha256_hex(so_bytes);
        let sig = sign_for("qr", "1.0.0", "arm64-v8a", &sha);
        let so_path = write_module(&dir, so_bytes, Some("{ not valid json"), Some(&sig));
        let err = verify_module_file_with_key(&so_path, Some(test_pubkey())).unwrap_err();
        assert!(err.contains("parse module meta failed"), "unexpected error: {err}");
    }

    #[test]
    fn signed_meta_abi_mismatch_is_rejected() {
        let dir = TestDir::new("abi-mismatch");
        let so_bytes = b"payload-abi-mismatch";
        let sha = sha256_hex(so_bytes);
        // 签名覆盖 abi=arm64-v8a，但 .meta 声称 armeabi-v7a → 签名失配 → 拒绝
        let sig = sign_for("qr", "1.0.0", "arm64-v8a", &sha);
        let so_path = write_module(
            &dir,
            so_bytes,
            Some(&meta_json("qr", "1.0.0", "armeabi-v7a")),
            Some(&sig),
        );
        let err = verify_module_file_with_key(&so_path, Some(test_pubkey())).unwrap_err();
        assert!(err.contains("module signature rejected"), "unexpected error: {err}");
    }

    #[test]
    fn signed_meta_version_tamper_is_rejected() {
        let dir = TestDir::new("version-tamper");
        let so_bytes = b"payload-version-tamper";
        let sha = sha256_hex(so_bytes);
        let sig = sign_for("qr", "1.0.0", "arm64-v8a", &sha);
        let so_path = write_module(
            &dir,
            so_bytes,
            Some(&meta_json("qr", "9.9.9", "arm64-v8a")),
            Some(&sig),
        );
        let err = verify_module_file_with_key(&so_path, Some(test_pubkey())).unwrap_err();
        assert!(err.contains("module signature rejected"), "unexpected error: {err}");
    }

    #[test]
    fn signature_mismatch_is_rejected() {
        let dir = TestDir::new("sig-mismatch");
        let so_bytes = b"payload-signature-mismatch";
        // 签名针对其他内容 sha，而非实际 .so 字节
        let sig = sign_for("qr", "1.0.0", "arm64-v8a", "deadbeef");
        let so_path = write_module(
            &dir,
            so_bytes,
            Some(&meta_json("qr", "1.0.0", "arm64-v8a")),
            Some(&sig),
        );
        let err = verify_module_file_with_key(&so_path, Some(test_pubkey())).unwrap_err();
        assert!(err.contains("module signature rejected"), "unexpected error: {err}");
    }

    #[test]
    fn truncated_signature_is_rejected() {
        let dir = TestDir::new("truncated-sig");
        let so_bytes = b"payload-truncated-sig";
        let sha = sha256_hex(so_bytes);
        let full = sign_for("qr", "1.0.0", "arm64-v8a", &sha);
        let so_path = write_module(
            &dir,
            so_bytes,
            Some(&meta_json("qr", "1.0.0", "arm64-v8a")),
            Some(&full[..16]),
        );
        let err = verify_module_file_with_key(&so_path, Some(test_pubkey())).unwrap_err();
        assert!(err.contains("module signature rejected"), "unexpected error: {err}");
    }

    #[test]
    fn empty_signature_is_rejected() {
        let dir = TestDir::new("empty-sig");
        let so_bytes = b"payload-empty-sig";
        let so_path = write_module(
            &dir,
            so_bytes,
            Some(&meta_json("qr", "1.0.0", "arm64-v8a")),
            Some("   \n"),
        );
        let err = verify_module_file_with_key(&so_path, Some(test_pubkey())).unwrap_err();
        assert!(err.contains("empty signature"), "unexpected error: {err}");
    }

    #[test]
    fn signed_module_without_key_is_rejected() {
        let dir = TestDir::new("no-key");
        let so_bytes = b"payload-no-key";
        let sha = sha256_hex(so_bytes);
        let sig = sign_for("qr", "1.0.0", "arm64-v8a", &sha);
        let so_path = write_module(
            &dir,
            so_bytes,
            Some(&meta_json("qr", "1.0.0", "arm64-v8a")),
            Some(&sig),
        );
        // 公钥缺失绝不等于跳过校验
        let err = verify_module_file_with_key(&so_path, None).unwrap_err();
        assert!(err.contains("no pinned public key"), "unexpected error: {err}");
    }

    #[test]
    fn wrong_public_key_is_rejected() {
        let dir = TestDir::new("wrong-key");
        let so_bytes = b"payload-wrong-key";
        let sha = sha256_hex(so_bytes);
        let sig = sign_for("qr", "1.0.0", "arm64-v8a", &sha);
        let so_path = write_module(
            &dir,
            so_bytes,
            Some(&meta_json("qr", "1.0.0", "arm64-v8a")),
            Some(&sig),
        );
        let other_key = SigningKey::from_bytes(&[0x11; 32]);
        let err = verify_module_file_with_key(&so_path, Some(other_key.verifying_key().to_bytes()))
            .unwrap_err();
        assert!(err.contains("module signature rejected"), "unexpected error: {err}");
    }

    #[test]
    fn verify_module_file_delegates_to_pinned_key() {
        let dir = TestDir::new("pinned-delegate");
        let so_bytes = b"payload-pinned-delegate";
        let sha = sha256_hex(so_bytes);
        let sig = sign_for("qr", "1.0.0", "arm64-v8a", &sha);
        let so_path = write_module(
            &dir,
            so_bytes,
            Some(&meta_json("qr", "1.0.0", "arm64-v8a")),
            Some(&sig),
        );
        // 无论钉死公钥是否配置，测试密钥签名的模块都不应通过生产入口
        assert!(verify_module_file(&so_path).is_err());
    }
}
