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

/// 校验模块文件。
/// - 无 `<so>.sig` → Ok（内置/未签名，随包信任）
/// - 有 `<so>.sig` → 必须有钉死公钥 + `<so>.meta`，且签名与 sha256 匹配，否则 Err
pub fn verify_module_file(so_path: &Path) -> Result<(), String> {
    let so_str = so_path.to_string_lossy().to_string();
    let sig_path = format!("{so_str}.sig");
    if !Path::new(&sig_path).exists() {
        return Ok(()); // 未签名：按内置模块处理
    }

    let public_key = pinned_pubkey()
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
}
