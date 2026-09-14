//! APK 签名方案检测（V1 / V2 / V3 / V3.1 / V3.2 / V4）
//!
//! 对齐 LibChecker `ApkSignatureSchemeDetector`：
//! - **V1**：zip 中央目录中存在 `META-INF/*.RSA|.DSA|.EC`（大小写不敏感后缀）
//! - **V2 / V3 / V3.1 / V3.2**：APK Signing Block（`APK Sig Block 42`）中的 ID-value 对
//! - **V4**：同名 `.idsig` 侧车文件存在
//!
//! **只做方案检测，不做密码学校验**（与 LibChecker 一致，避免引入 X.509/RSA 依赖）。

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};



const ZIP_EOCD_SIGNATURE: u32 = 0x0605_4b50;
const ZIP_CD_SIGNATURE: u32 = 0x0201_4b50;
const ZIP_CD_HEADER_SIZE: u64 = 46;
const ZIP_EOCD_MIN_SIZE: usize = 22;
const ZIP_MAX_COMMENT_SIZE: u64 = 65535;

const APK_SIGNING_BLOCK_MAGIC: &[u8; 16] = b"APK Sig Block 42";
/// 签名块尾部：[block_size u64][magic 16]
const APK_SIGNING_BLOCK_FOOTER_SIZE: u64 = 24;
const MAX_APK_SIGNING_BLOCK_SIZE: u64 = 32 * 1024 * 1024;
/// 中央目录逐条流式读取时的单条名字上限（防御异常长度）
const MAX_ENTRY_NAME_SIZE: u64 = 1 << 20;

const SCHEME_V2_ID: u32 = 0x7109_871a;
const SCHEME_V3_ID: u32 = 0xf053_68c0;
const SCHEME_V31_ID: u32 = 0x1b93_ad61;
const SCHEME_V32_ID: u32 = 0x70e1_c89f;

/// 签名方案检测结果
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct SignatureSchemeInfo {
    pub has_v1: bool,
    pub has_v2: bool,
    pub has_v3: bool,
    pub has_v31: bool,
    pub has_v32: bool,
    pub has_v4: bool,
    /// 命中的方案标签（如 `["V2","V3"]`），便于直接展示
    pub schemes: Vec<String>,
    /// 签名块内出现的全部 ID（诊断用）
    pub signing_block_ids: Vec<u32>,
}

/// 检测 APK 的签名方案
pub fn detect_signature_schemes(apk_path: &str) -> Result<SignatureSchemeInfo, String> {
    let mut file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let file_len = file
        .metadata()
        .map_err(|e| format!("无法读取 APK 信息: {e}"))?
        .len();

    let mut info = SignatureSchemeInfo::default();
    // V4：`.idsig` 侧车文件
    info.has_v4 = std::path::Path::new(&format!("{apk_path}.idsig")).exists();

    if file_len < ZIP_EOCD_MIN_SIZE as u64 {
        return Ok(info);
    }

    let Some((cd_offset, cd_size)) = find_central_directory(&mut file, file_len)? else {
        return Ok(info);
    };

    info.has_v1 = has_jar_signature(&mut file, cd_offset, cd_size)?;

    info.signing_block_ids = read_signing_block_ids(&mut file, cd_offset)?;
    info.has_v2 = info.signing_block_ids.contains(&SCHEME_V2_ID);
    info.has_v3 = info.signing_block_ids.contains(&SCHEME_V3_ID);
    info.has_v31 = info.signing_block_ids.contains(&SCHEME_V31_ID);
    info.has_v32 = info.signing_block_ids.contains(&SCHEME_V32_ID);

    for (flag, label) in [
        (info.has_v1, "V1"),
        (info.has_v2, "V2"),
        (info.has_v3, "V3"),
        (info.has_v31, "V3.1"),
        (info.has_v32, "V3.2"),
        (info.has_v4, "V4"),
    ] {
        if flag {
            info.schemes.push(label.to_string());
        }
    }

    Ok(info)
}

/// 从文件尾部定位 EOCD，返回 (中央目录偏移, 中央目录长度)
fn find_central_directory<R: Read + Seek>(
    file: &mut R,
    file_len: u64,
) -> Result<Option<(u64, u64)>, String> {
    let read_size = file_len.min(ZIP_EOCD_MIN_SIZE as u64 + ZIP_MAX_COMMENT_SIZE) as usize;
    let mut buf = vec![0u8; read_size];
    file.seek(SeekFrom::Start(file_len - read_size as u64))
        .map_err(|e| e.to_string())?;
    file.read_exact(&mut buf).map_err(|e| e.to_string())?;

    Ok(find_eocd(&buf).map(|offset| {
        (
            read_u32(&buf, offset + 16) as u64,
            read_u32(&buf, offset + 12) as u64,
        )
    }))
}

/// 在尾部缓冲区里从后向前找 EOCD（注释长度需与剩余长度一致）
fn find_eocd(buf: &[u8]) -> Option<usize> {
    if buf.len() < ZIP_EOCD_MIN_SIZE {
        return None;
    }
    for offset in (0..=(buf.len() - ZIP_EOCD_MIN_SIZE)).rev() {
        if read_u32(buf, offset) != ZIP_EOCD_SIGNATURE {
            continue;
        }
        let comment_len = read_u16(buf, offset + 20) as usize;
        if comment_len == buf.len() - offset - ZIP_EOCD_MIN_SIZE {
            return Some(offset);
        }
    }
    None
}

/// V1：中央目录中是否存在 `META-INF/*.RSA|.DSA|.EC`。
/// 逐条流式读取，内存占用与中央目录大小无关。
fn has_jar_signature<R: Read + Seek>(
    file: &mut R,
    cd_offset: u64,
    cd_size: u64,
) -> Result<bool, String> {
    if cd_size == 0 {
        return Ok(false);
    }
    let mut pos = cd_offset;
    let end = cd_offset.saturating_add(cd_size);
    let mut header = [0u8; ZIP_CD_HEADER_SIZE as usize];
    while pos + ZIP_CD_HEADER_SIZE <= end {
        file.seek(SeekFrom::Start(pos)).map_err(|e| e.to_string())?;
        if file.read_exact(&mut header).is_err() {
            return Ok(false);
        }
        if read_u32(&header, 0) != ZIP_CD_SIGNATURE {
            return Ok(false);
        }
        let name_len = read_u16(&header, 28) as u64;
        let extra_len = read_u16(&header, 30) as u64;
        let comment_len = read_u16(&header, 32) as u64;
        let entry_size = ZIP_CD_HEADER_SIZE + name_len + extra_len + comment_len;
        if pos + entry_size > end || name_len > MAX_ENTRY_NAME_SIZE {
            return Ok(false);
        }
        let mut name = vec![0u8; name_len as usize];
        if file.read_exact(&mut name).is_err() {
            return Ok(false);
        }
        if let Ok(name) = std::str::from_utf8(&name) {
            if is_jar_signature_name(name) {
                return Ok(true);
            }
        }
        pos += entry_size;
    }
    Ok(false)
}

/// `META-INF/` 前缀 + 大小写不敏感的 `.RSA` / `.DSA` / `.EC` 后缀
fn is_jar_signature_name(name: &str) -> bool {
    if !name.starts_with("META-INF/") {
        return false;
    }
    let upper = name.to_ascii_uppercase();
    upper.ends_with(".RSA") || upper.ends_with(".DSA") || upper.ends_with(".EC")
}

/// 读取 APK Signing Block 中的全部 ID
fn read_signing_block_ids<R: Read + Seek>(
    file: &mut R,
    cd_offset: u64,
) -> Result<Vec<u32>, String> {
    if cd_offset < APK_SIGNING_BLOCK_FOOTER_SIZE {
        return Ok(Vec::new());
    }
    let mut footer = [0u8; APK_SIGNING_BLOCK_FOOTER_SIZE as usize];
    file.seek(SeekFrom::Start(cd_offset - APK_SIGNING_BLOCK_FOOTER_SIZE))
        .map_err(|e| e.to_string())?;
    if file.read_exact(&mut footer).is_err() {
        return Ok(Vec::new());
    }
    if &footer[8..24] != APK_SIGNING_BLOCK_MAGIC {
        return Ok(Vec::new());
    }
    let block_size = read_u64(&footer, 0);
    let total_size = match block_size.checked_add(8) {
        Some(v) => v,
        None => return Ok(Vec::new()),
    };
    if block_size < APK_SIGNING_BLOCK_FOOTER_SIZE
        || total_size > cd_offset
        || total_size > MAX_APK_SIGNING_BLOCK_SIZE
    {
        return Ok(Vec::new());
    }

    let mut block = vec![0u8; total_size as usize];
    file.seek(SeekFrom::Start(cd_offset - total_size))
        .map_err(|e| e.to_string())?;
    if file.read_exact(&mut block).is_err() {
        return Ok(Vec::new());
    }
    if read_u64(&block, 0) != block_size {
        return Ok(Vec::new());
    }
    Ok(parse_signing_block_ids(&block))
}

/// 解析签名块的 ID-value 对（首尾各 8 字节 + 16 字节 magic 之外的部分）
fn parse_signing_block_ids(block: &[u8]) -> Vec<u32> {
    let mut ids = Vec::new();
    if block.len() < APK_SIGNING_BLOCK_FOOTER_SIZE as usize {
        return ids;
    }
    let pairs_end = block.len() - APK_SIGNING_BLOCK_FOOTER_SIZE as usize;
    let mut offset = 8usize;
    while offset + 8 <= pairs_end {
        let pair_size = read_u64(block, offset);
        offset += 8;
        if pair_size < 4 || pair_size > (pairs_end - offset) as u64 {
            break;
        }
        ids.push(read_u32(block, offset));
        offset += pair_size as usize;
    }
    ids
}

fn read_u16(buf: &[u8], off: usize) -> u16 {
    let arr: [u8; 2] = buf
        .get(off..off + 2)
        .and_then(|s| s.try_into().ok())
        .unwrap_or([0, 0]);
    u16::from_le_bytes(arr)
}

fn read_u32(buf: &[u8], off: usize) -> u32 {
    let arr: [u8; 4] = buf
        .get(off..off + 4)
        .and_then(|s| s.try_into().ok())
        .unwrap_or([0, 0, 0, 0]);
    u32::from_le_bytes(arr)
}

fn read_u64(buf: &[u8], off: usize) -> u64 {
    let arr: [u8; 8] = buf
        .get(off..off + 8)
        .and_then(|s| s.try_into().ok())
        .unwrap_or([0; 8]);
    u64::from_le_bytes(arr)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 手工拼一个 EOCD（可选注释）
    fn eocd(cd_offset: u32, cd_size: u32, comment_len: usize) -> Vec<u8> {
        let mut v = vec![0u8; ZIP_EOCD_MIN_SIZE + comment_len];
        v[0..4].copy_from_slice(&ZIP_EOCD_SIGNATURE.to_le_bytes());
        v[12..16].copy_from_slice(&cd_size.to_le_bytes());
        v[16..20].copy_from_slice(&cd_offset.to_le_bytes());
        v[20..22].copy_from_slice(&(comment_len as u16).to_le_bytes());
        v
    }

    #[test]
    fn finds_eocd_with_and_without_comment() {
        let plain = eocd(0x1234, 0x99, 0);
        assert_eq!(find_eocd(&plain), Some(0));

        // EOCD 前垫 10 字节 + 5 字节注释（注释写在 EOCD 尾部预留区内）
        let mut with_comment = vec![0xAAu8; 10];
        let mut e = eocd(0x20, 0x40, 5);
        e[ZIP_EOCD_MIN_SIZE..ZIP_EOCD_MIN_SIZE + 5].copy_from_slice(b"hello");
        with_comment.extend_from_slice(&e);
        assert_eq!(find_eocd(&with_comment), Some(10));
    }

    #[test]
    fn rejects_eocd_when_trailing_bytes_do_not_match_comment_length() {
        // 注释长度声明为 0，但实际后面还有 5 字节 → 不认（避免误判）
        let mut buf = vec![0xAAu8; 10];
        buf.extend_from_slice(&eocd(0x20, 0x40, 0));
        buf.extend_from_slice(b"hello");
        assert_eq!(find_eocd(&buf), None);
    }

    #[test]
    fn rejects_bogus_comment_length() {
        // 注释长度与实际剩余不符 → 不认
        let mut bad = eocd(0, 0, 0);
        bad[20..22].copy_from_slice(&7u16.to_le_bytes());
        assert_eq!(find_eocd(&bad), None);
    }

    #[test]
    fn jar_signature_name_matching() {
        assert!(is_jar_signature_name("META-INF/CERT.RSA"));
        assert!(is_jar_signature_name("META-INF/cert.rsa"));
        assert!(is_jar_signature_name("META-INF/ALIAS.DSA"));
        assert!(is_jar_signature_name("META-INF/KEY.EC"));
        assert!(!is_jar_signature_name("META-INF/MANIFEST.MF"));
        assert!(!is_jar_signature_name("assets/cert.rsa"));
        assert!(!is_jar_signature_name("META-INF/CERT.SF"));
    }

    #[test]
    fn parses_signing_block_id_pairs() {
        // 两个 ID-value 对：V2(4 字节值) + V3(6 字节值)
        let mut block = Vec::new();
        let mut pairs = Vec::new();
        for (id, value_len) in [(SCHEME_V2_ID, 4usize), (SCHEME_V3_ID, 6usize)] {
            let pair_size = (4 + value_len) as u64;
            pairs.extend_from_slice(&pair_size.to_le_bytes());
            pairs.extend_from_slice(&id.to_le_bytes());
            pairs.extend(std::iter::repeat(0u8).take(value_len));
        }
        let block_size = (pairs.len() + APK_SIGNING_BLOCK_FOOTER_SIZE as usize) as u64;
        block.extend_from_slice(&block_size.to_le_bytes());
        block.extend_from_slice(&pairs);
        block.extend_from_slice(&block_size.to_le_bytes());
        block.extend_from_slice(APK_SIGNING_BLOCK_MAGIC);

        let ids = parse_signing_block_ids(&block);
        assert_eq!(ids, vec![SCHEME_V2_ID, SCHEME_V3_ID]);
    }

    #[test]
    fn stops_on_malformed_pair_size() {
        let mut block = Vec::new();
        let block_size = 8u64 + 8 + 24; // 头部 + 一个坏对 + 尾部
        block.extend_from_slice(&block_size.to_le_bytes());
        block.extend_from_slice(&9999u64.to_le_bytes()); // 越界的 pair_size
        block.extend_from_slice(&SCHEME_V2_ID.to_le_bytes());
        block.extend_from_slice(&[0u8; 20]);
        block.extend_from_slice(&block_size.to_le_bytes());
        block.extend_from_slice(APK_SIGNING_BLOCK_MAGIC);
        assert!(parse_signing_block_ids(&block).is_empty());
    }

    #[test]
    fn detects_v1_from_real_zip_and_reports_no_v2() {
        let dir = std::env::temp_dir().join(format!("gstore_sig_{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok();
        let apk = dir.join("v1.apk");
        {
            let f = File::create(&apk).unwrap();
            let mut zip = zip::ZipWriter::new(f);
            let opts = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip.start_file("META-INF/MANIFEST.MF", opts).unwrap();
            std::io::Write::write_all(&mut zip, b"Manifest-Version: 1.0\n").unwrap();
            zip.start_file("META-INF/CERT.RSA", opts).unwrap();
            std::io::Write::write_all(&mut zip, &[0u8; 64]).unwrap();
            zip.finish().unwrap();
        }
        let info = detect_signature_schemes(apk.to_str().unwrap()).unwrap();
        assert!(info.has_v1, "含 META-INF/CERT.RSA 应判定 V1");
        assert!(!info.has_v2, "无签名块不应判定 V2");
        assert!(!info.has_v3);
        assert_eq!(info.schemes, vec!["V1".to_string()]);
    }

    #[test]
    fn plain_zip_has_no_scheme() {
        let dir = std::env::temp_dir().join(format!("gstore_sig_plain_{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok();
        let apk = dir.join("plain.apk");
        {
            let f = File::create(&apk).unwrap();
            let mut zip = zip::ZipWriter::new(f);
            zip.start_file("classes.dex", zip::write::SimpleFileOptions::default())
                .unwrap();
            std::io::Write::write_all(&mut zip, &[0u8; 16]).unwrap();
            zip.finish().unwrap();
        }
        let info = detect_signature_schemes(apk.to_str().unwrap()).unwrap();
        assert!(info.schemes.is_empty());
    }

    #[test]
    fn tiny_file_degrades() {
        let dir = std::env::temp_dir().join(format!("gstore_sig_tiny_{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok();
        let apk = dir.join("tiny.apk");
        std::fs::write(&apk, b"abc").unwrap();
        let info = detect_signature_schemes(apk.to_str().unwrap()).unwrap();
        assert!(info.schemes.is_empty());
    }
}
