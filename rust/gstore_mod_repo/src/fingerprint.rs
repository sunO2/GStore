//! 从仓库签名里提取**真实指纹**（仓库身份）
//!
//! 为什么重要：F-Droid 的仓库身份是**签名密钥**，不是地址。有了指纹才能判断
//! 「不同 URL / 不同镜像其实指向同一个源」，也才能在换域名后仍然认出同一个仓库。
//!
//! 关键取舍：提取指纹**只需要把证书的 DER 解出来再算 SHA-256**，
//! 不需要做密码学校验（签名验证是另一个更大的课题）。因此这里**不引入任何
//! 密码学库**，只写一个最小 DER walker，避免给模块增加几百 KB。
//!
//! 结构（PKCS#7 / CMS）：
//! ```text
//! ContentInfo ::= SEQUENCE {
//!   contentType OID,
//!   content [0] EXPLICIT SignedData }
//! SignedData ::= SEQUENCE {
//!   version INTEGER, digestAlgorithms SET, encapContentInfo SEQUENCE,
//!   certificates [0] IMPLICIT SET OF Certificate OPTIONAL, ... }
//! ```
//! JAR 签名文件（`META-INF/*.RSA|.DSA|.EC`）就是这个 ContentInfo 的 DER。

use sha2::{Digest, Sha256};

/// 单个 TLV：`(tag, header_start, value_start, value_end)`
type Tlv = (u8, usize, usize, usize);

/// 读一个 DER TLV（只支持定长编码，够用且更严格）
fn read_tlv(b: &[u8], head: usize) -> Option<Tlv> {
    if head + 2 > b.len() {
        return None;
    }
    let tag = b[head];
    let l0 = b[head + 1];
    let (len, vs) = if l0 & 0x80 == 0 {
        (l0 as usize, head + 2)
    } else {
        let n = (l0 & 0x7f) as usize;
        if n == 0 || n > 4 || vs_len(b, head) < 2 + n {
            return None;
        }
        let mut v = 0usize;
        for i in 0..n {
            v = (v << 8) | b[head + 2 + i] as usize;
        }
        (v, head + 2 + n)
    };
    let ve = vs.checked_add(len)?;
    if ve > b.len() {
        return None;
    }
    Some((tag, head, vs, ve))
}

fn vs_len(b: &[u8], head: usize) -> usize {
    b.len().saturating_sub(head)
}

/// 遍历 `[start, end)` 内的连续 TLV
fn children(b: &[u8], start: usize, end: usize) -> Vec<Tlv> {
    let mut out = Vec::new();
    let mut off = start;
    while off < end {
        match read_tlv(b, off) {
            Some(t) if t.3 <= end => {
                out.push(t);
                off = t.3;
            }
            _ => break,
        }
    }
    out
}

/// 从 PKCS#7 ContentInfo 里取出**第一张证书的完整 DER**
pub fn certificate_der(pkcs7: &[u8]) -> Option<&[u8]> {
    let (t, _, v, e) = read_tlv(pkcs7, 0)?;
    if t != 0x30 {
        return None;
    }
    // content [0] EXPLICIT
    let content = children(pkcs7, v, e)
        .into_iter()
        .find(|c| c.0 == 0xa0)?;
    // SignedData SEQUENCE
    let (t1, _, v1, e1) = read_tlv(pkcs7, content.2)?;
    if t1 != 0x30 {
        return None;
    }
    // 找 certificates [0] IMPLICIT
    let certs = children(pkcs7, v1, e1)
        .into_iter()
        .find(|c| c.0 == 0xa0)?;
    // 集合里第一个 Certificate = SEQUENCE，取它的**完整 TLV 字节**做哈希
    let cert = children(pkcs7, certs.2, certs.3).into_iter().next()?;
    if cert.0 != 0x30 {
        return None;
    }
    pkcs7.get(cert.1..cert.3)
}

/// 指纹 = **证书 DER 的 SHA-256**，大写十六进制以冒号分隔（与 F-Droid 展示形式一致）
pub fn fingerprint_of(cert_der: &[u8]) -> String {
    let digest = Sha256::digest(cert_der);
    let hex: Vec<String> = digest.iter().map(|b| format!("{b:02X}")).collect();
    hex.join(":")
}

/// 从 JAR 签名字节（zip 内的 `META-INF/*.RSA|.DSA|.EC`）提取指纹
pub fn fingerprint_from_signature_file(bytes: &[u8]) -> Option<String> {
    certificate_der(bytes).map(fingerprint_of)
}

/// 从完整的 JAR（zip）里找到签名文件并提取指纹；非 JAR / 无签名返回 None
pub fn fingerprint_from_jar(jar: &[u8]) -> Option<String> {
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(jar)).ok()?;
    // 先只读条目名，避免借用冲突
    let mut target: Option<String> = None;
    for i in 0..zip.len() {
        let Ok(e) = zip.by_index(i) else { continue };
        let name = e.name().to_string();
        if let Some(rest) = name.strip_prefix("META-INF/") {
            let upper = rest.to_uppercase();
            if upper.ends_with(".RSA") || upper.ends_with(".DSA") || upper.ends_with(".EC") {
                target = Some(name);
                break;
            }
        }
    }
    let name = target?;
    let mut entry = zip.by_name(&name).ok()?;
    let mut buf = Vec::new();
    use std::io::Read;
    entry.read_to_end(&mut buf).ok()?;
    fingerprint_from_signature_file(&buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 手工拼一个最小 PKCS#7：SEQ[ OID, [0]( SEQ[ INT, SET, SEQ, [0](SEQ[INT]) ] ) ]
    /// 其中 certificates[0] 里的第一个 SEQUENCE 就是"证书"
    fn der(tag: u8, body: &[u8]) -> Vec<u8> {
        let mut out = vec![tag];
        let n = body.len();
        if n < 0x80 {
            out.push(n as u8);
        } else {
            out.push(0x81);
            out.push(n as u8);
        }
        out.extend_from_slice(body);
        out
    }

    fn fake_pkcs7(cert_body: &[u8]) -> Vec<u8> {
        let oid = der(0x06, &[0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]);
        let version = der(0x02, &[0x03]);
        let algos = der(0x31, &[]);
        let encap = der(0x30, &[]);
        let cert = der(0x30, cert_body);
        let certs = der(0xa0, &cert);
        let signed_data = der(0x30, &[version, algos, encap, certs].concat());
        let content = der(0xa0, &signed_data);
        der(0x30, &[oid, content].concat())
    }

    #[test]
    fn extracts_certificate_der() {
        let pkcs7 = fake_pkcs7(&[0x01, 0x02, 0x03, 0x04]);
        let cert = certificate_der(&pkcs7).expect("should extract");
        // 证书的完整 TLV = 30 06 01 02 03 04
        assert_eq!(cert, &[0x30, 0x04, 0x01, 0x02, 0x03, 0x04]);
    }

    #[test]
    fn fingerprint_is_colon_separated_sha256_of_cert() {
        let cert = [0x30u8, 0x02, 0xAB, 0xCD];
        let fp = fingerprint_of(&cert);
        assert_eq!(fp.len(), 32 * 3 - 1, "sha256 → 32 组，31 个冒号");
        assert!(fp.split(':').all(|s| s.len() == 2));
        assert_eq!(fp, fp.to_uppercase());
    }

    #[test]
    fn rejects_non_pkcs7_and_garbage() {
        assert!(certificate_der(&[]).is_none());
        assert!(certificate_der(&[0x31, 0x02, 0x01, 0x02]).is_none());
        assert!(certificate_der(&[0x30, 0x7f, 0x00]).is_none());
    }

    #[test]
    fn fingerprint_from_synthetic_jar() {
        use std::io::Write;
        let pkcs7 = fake_pkcs7(&[0x11, 0x22, 0x33]);
        let cert = certificate_der(&pkcs7).unwrap().to_vec();
        let mut buf = Vec::new();
        {
            let mut w = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
            let opts = zip::write::SimpleFileOptions::default();
            w.start_file("META-INF/MANIFEST.MF", opts).unwrap();
            w.write_all(b"Manifest-Version: 1.0\n").unwrap();
            w.start_file("META-INF/CERT.RSA", opts).unwrap();
            w.write_all(&pkcs7).unwrap();
            w.finish().unwrap();
        }
        let fp = fingerprint_from_jar(&buf).expect("should extract from jar");
        assert_eq!(fp, fingerprint_of(&cert), "与直接对证书求哈希一致");
    }

    #[test]
    fn jar_without_signature_returns_none() {
        use std::io::Write;
        let mut buf = Vec::new();
        {
            let mut w = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
            let opts = zip::write::SimpleFileOptions::default();
            w.start_file("entry.json", opts).unwrap();
            w.write_all(b"{}").unwrap();
            w.finish().unwrap();
        }
        assert!(fingerprint_from_jar(&buf).is_none());
    }
}
