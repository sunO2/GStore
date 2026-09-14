//! DEX 文件统计：每个 `classes*.dex` 的类数量与 CRC32
//!
//! 类数量来自 DEX 头的 `class_defs_size`（offset 0x60），因此**只需读前 0x70 字节**
//! 即可，无需解压整个 DEX —— 对大包（几十 MB DEX）差别明显。
//! CRC32 取自 zip 中央目录，同样零解压成本。
//!
//! 对齐 LibChecker `DexStatsCollector`：`DexEntryInfo(name, size, classCount, crc32)`。

use std::fs::File;
use std::io::Read;

use zip::ZipArchive;

/// DEX 头长度（dex 035/037/038/039）
/// 单个 dex 读入上限（防御异常包）
const MAX_DEX_BYTES: u64 = 256 * 1024 * 1024;

const DEX_HEADER_SIZE: usize = 0x70;

/// 单个 DEX 条目统计
///
/// 除类数量外，头部还带着**编译期算好的内容指纹**（checksum/signature）与
/// 各类 id 数量——全部位于前 0x70 字节内，读一次头即可，无需解压整个 DEX。
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct DexStatEntry {
    /// 条目名（如 `classes2.dex`）
    pub name: String,
    /// 解压后字节数
    pub size: u64,
    /// 压缩后字节数
    pub compressed_size: u64,
    /// 条目 CRC32
    pub crc32: u32,
    /// `class_defs_size`；解析失败为 -1
    pub class_count: i64,
    /// DEX 头 `checksum`（adler32，offset 0x08）
    pub checksum: u32,
    /// DEX 头 `signature`（SHA-1，offset 0x0C..0x20，小写 hex）——内容指纹
    pub header_sha1: String,
    /// DEX 头 `file_size`（offset 0x20）
    pub header_file_size: u64,
    /// `string_ids_size`（offset 0x38）
    pub string_ids: u32,
    /// `type_ids_size`（offset 0x40）
    pub type_ids: u32,
    /// `proto_ids_size`（offset 0x48）
    pub proto_ids: u32,
    /// `field_ids_size`（offset 0x50）
    pub field_ids: u32,
    /// `method_ids_size`（offset 0x58）
    pub method_ids: u32,
    /// `data_size`（offset 0x68）
    pub data_size: u64,
    /// **类集合指纹**：对排序后的类描述符列表取 SHA-256（小写 hex）。
    ///
    /// 只落一个 64 字符的哈希而不是成千上万个类名（单包 5 个 dex 的类名清单原文约 1MB），
    /// 却足以判定"这份 dex 的类集合没变，只是换了个 dex 文件"——即 multidex 分包/类搬迁。
    pub class_digest: String,
}

/// 整包 DEX 统计
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct ApkDexStats {
    /// 各 DEX 文件统计（按名字排序）
    pub dex_files: Vec<DexStatEntry>,
    /// 类总数（解析失败的 DEX 不计入）
    pub total_class_count: u64,
}

/// 扫描 APK 内全部 `classes*.dex` 的类数量与 CRC32
pub fn scan_dex_stats(apk_path: &str) -> Result<ApkDexStats, String> {
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;
    scan_dex_stats_from(&mut archive)
}

/// 复用已打开的 archive（聚合入口用：一次打开产出全部节）
pub fn scan_dex_stats_from(archive: &mut ZipArchive<File>) -> Result<ApkDexStats, String> {
    let mut dex_files = Vec::new();
    let mut total_class_count = 0u64;
    for i in 0..archive.len() {
        let mut entry = match archive.by_index(i) {
            Ok(e) => e,
            Err(_) => continue,
        };
        let name = entry.name().to_string();
        if !is_dex_entry(&name) {
            continue;
        }
        let size = entry.size();
        let compressed_size = entry.compressed_size();
        let crc32 = entry.crc32();

        // 类集合指纹需要整份 dex（读入 → 算完即释放）；超大 dex 退化为只读头
        let mut bytes = Vec::new();
        if size <= MAX_DEX_BYTES && entry.read_to_end(&mut bytes).is_err() {
            bytes.clear();
        }
        drop(entry); // 释放对 archive 的可变借用，供退化路径重开条目

        let parsed = if !bytes.is_empty() {
            parse_dex_header(&bytes)
        } else {
            let mut header = vec![0u8; DEX_HEADER_SIZE];
            match archive.by_index(i) {
                Ok(mut e2) => match e2.read_exact(&mut header) {
                    Ok(()) => parse_dex_header(&header),
                    Err(_) => None,
                },
                Err(_) => None,
            }
        };
        let class_digest = if parsed.is_some() && !bytes.is_empty() {
            class_set_digest(&bytes)
        } else {
            String::new()
        };
        let class_count = parsed
            .as_ref()
            .map(|p| p.class_count as i64)
            .unwrap_or(-1);
        if class_count > 0 {
            total_class_count = total_class_count.saturating_add(class_count as u64);
        }

        dex_files.push(DexStatEntry {
            name,
            size,
            compressed_size,
            crc32,
            class_count,
            class_digest,
            checksum: parsed.as_ref().map(|p| p.checksum).unwrap_or(0),
            header_sha1: parsed
                .as_ref()
                .map(|p| p.header_sha1.clone())
                .unwrap_or_default(),
            header_file_size: parsed.as_ref().map(|p| p.file_size).unwrap_or(0),
            string_ids: parsed.as_ref().map(|p| p.string_ids).unwrap_or(0),
            type_ids: parsed.as_ref().map(|p| p.type_ids).unwrap_or(0),
            proto_ids: parsed.as_ref().map(|p| p.proto_ids).unwrap_or(0),
            field_ids: parsed.as_ref().map(|p| p.field_ids).unwrap_or(0),
            method_ids: parsed.as_ref().map(|p| p.method_ids).unwrap_or(0),
            data_size: parsed.as_ref().map(|p| p.data_size).unwrap_or(0),
        });
    }
    dex_files.sort_by(|a, b| a.name.cmp(&b.name));

    Ok(ApkDexStats {
        dex_files,
        total_class_count,
    })
}

/// 类描述符集合的 SHA-256（排序后），用于识别"类集合搬迁"
fn class_set_digest(dex: &[u8]) -> String {
    let class_count = dex_class_count(dex);
    if class_count == 0 {
        return String::new();
    }
    let mut names = Vec::new();
    for i in 0..class_count.min(200_000) as usize {
        let def_off = match dex_header_u32(dex, 0x64) {
            Some(v) => v as usize + i * 32,
            None => break,
        };
        let Some(class_idx) = read_u32(dex, def_off) else {
            break;
        };
        if let Some(desc) = class_descriptor(dex, class_idx) {
            names.push(desc);
        }
    }
    names.sort();
    names.dedup();
    use std::fmt::Write as _;
    let mut hasher = {
        use sha2::{Digest, Sha256};
        Sha256::new()
    };
    for n in &names {
        use sha2::Digest;
        hasher.update(n.as_bytes());
        hasher.update([0u8]);
    }
    use sha2::Digest;
    hasher
        .finalize()
        .iter()
        .fold(String::with_capacity(64), |mut acc, b| {
            let _ = write!(acc, "{b:02x}");
            acc
        })
}

fn dex_class_count(dex: &[u8]) -> u32 {
    read_u32(dex, 0x60).unwrap_or(0)
}

fn dex_header_u32(dex: &[u8], off: usize) -> Option<u32> {
    read_u32(dex, off)
}

fn read_u32(bytes: &[u8], off: usize) -> Option<u32> {
    Some(u32::from_le_bytes([
        *bytes.get(off)?,
        *bytes.get(off + 1)?,
        *bytes.get(off + 2)?,
        *bytes.get(off + 3)?,
    ]))
}

/// class_def → type_ids → string_ids → MUTF-8 字符串（类描述符）
///
/// 三级链路各取一次即可：`class_def.class_idx` → `type_ids[..]`（得到字符串下标）
/// → `string_ids[..]`（得到字符串数据偏移）。多取一次会读到表外。
fn class_descriptor(dex: &[u8], class_idx: u32) -> Option<String> {
    let type_ids_off = read_u32(dex, 0x44)? as usize;
    let string_ids_off = read_u32(dex, 0x3C)? as usize;
    // type_ids[class_idx] = 该类型描述符在字符串表里的下标
    let string_idx = read_u32(dex, type_ids_off.checked_add(class_idx as usize * 4)?)?;
    // string_ids[string_idx] = 字符串数据的字节偏移
    let data_off = read_u32(
        dex,
        string_ids_off.checked_add(string_idx as usize * 4)?,
    )? as usize;
    // 字符串数据：ULEB128 utf16 长度 + MUTF-8 字节 + NUL
    let mut p = data_off;
    for _ in 0..5 {
        let b = *dex.get(p)?;
        p += 1;
        if b & 0x80 == 0 {
            break;
        }
    }
    let start = p;
    while let Some(b) = dex.get(p) {
        if *b == 0 {
            break;
        }
        p += 1;
    }
    let raw = dex.get(start..p)?;
    if raw.len() > 512 {
        return None;
    }
    Some(String::from_utf8_lossy(raw).into_owned())
}

/// DEX 头里可白拿的统计（全部位于前 0x70 字节）
#[derive(Clone, Debug, Default)]
struct DexHeaderStats {
    class_count: u32,
    checksum: u32,
    header_sha1: String,
    file_size: u64,
    string_ids: u32,
    type_ids: u32,
    proto_ids: u32,
    field_ids: u32,
    method_ids: u32,
    data_size: u64,
}

fn u32_at(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]])
}

/// 解析 DEX 头（校验魔数 / version 末字节后读 checksum、signature 与各类 id 数量）
fn parse_dex_header(header: &[u8]) -> Option<DexHeaderStats> {
    if header.len() < DEX_HEADER_SIZE {
        return None;
    }
    if header.get(0..4)? != b"dex\n" || header.get(7) != Some(&0) {
        return None;
    }
    Some(DexHeaderStats {
        checksum: u32_at(header, 0x08),
        header_sha1: header[0x0C..0x20]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
        file_size: u32_at(header, 0x20) as u64,
        string_ids: u32_at(header, 0x38),
        type_ids: u32_at(header, 0x40),
        proto_ids: u32_at(header, 0x48),
        field_ids: u32_at(header, 0x50),
        method_ids: u32_at(header, 0x58),
        class_count: u32_at(header, 0x60),
        data_size: u32_at(header, 0x68) as u64,
    })
}

/// `classes.dex` / `classes<N>.dex`
fn is_dex_entry(path: &str) -> bool {
    let Some(rest) = path.strip_suffix(".dex") else {
        return false;
    };
    let Some(mid) = rest.strip_prefix("classes") else {
        return false;
    };
    mid.is_empty() || mid.bytes().all(|b| b.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 合成一个最小 DEX 头：魔数 + version + 各类 id 数量
    fn fake_dex(class_defs_size: u32) -> Vec<u8> {
        let mut v = vec![0u8; DEX_HEADER_SIZE + 16];
        v[0..8].copy_from_slice(b"dex\n035\0");
        v[0x60..0x64].copy_from_slice(&class_defs_size.to_le_bytes());
        v
    }

    #[test]
    fn reads_class_defs_size() {
        assert_eq!(
            parse_dex_header(&fake_dex(1234)).unwrap().class_count,
            1234
        );
    }

    #[test]
    fn reads_header_fingerprint_and_id_counts() {
        let mut dex = fake_dex(7);
        dex[0x08..0x0C].copy_from_slice(&0xDEADBEEFu32.to_le_bytes());
        // signature：20 字节递增，便于断言 hex 形态
        for i in 0..20u8 {
            dex[0x0C + i as usize] = i;
        }
        dex[0x20..0x24].copy_from_slice(&4096u32.to_le_bytes());
        dex[0x38..0x3C].copy_from_slice(&11u32.to_le_bytes()); // string_ids
        dex[0x40..0x44].copy_from_slice(&22u32.to_le_bytes()); // type_ids
        dex[0x48..0x4C].copy_from_slice(&33u32.to_le_bytes()); // proto_ids
        dex[0x50..0x54].copy_from_slice(&44u32.to_le_bytes()); // field_ids
        dex[0x58..0x5C].copy_from_slice(&55u32.to_le_bytes()); // method_ids
        dex[0x68..0x6C].copy_from_slice(&66u32.to_le_bytes()); // data_size

        let p = parse_dex_header(&dex).unwrap();
        assert_eq!(p.checksum, 0xDEADBEEF);
        assert_eq!(
            p.header_sha1,
            "000102030405060708090a0b0c0d0e0f10111213"
        );
        assert_eq!(p.file_size, 4096);
        assert_eq!(
            (p.string_ids, p.type_ids, p.proto_ids, p.field_ids, p.method_ids),
            (11, 22, 33, 44, 55)
        );
        assert_eq!(p.class_count, 7);
        assert_eq!(p.data_size, 66);
    }

    #[test]
    fn rejects_non_dex() {
        let mut bad = fake_dex(1);
        bad[0] = 0;
        assert!(parse_dex_header(&bad).is_none());
        // 长度不足
        assert!(parse_dex_header(&[0u8; 8]).is_none());
        // version 末字节必须为 0
        let mut bad2 = fake_dex(1);
        bad2[7] = b'1';
        assert!(parse_dex_header(&bad2).is_none());
    }

    #[test]
    fn scans_multiple_dex_and_totals() {
        let dir = std::env::temp_dir().join(format!("gstore_dexstat_{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok();
        let apk = dir.join("t.apk");
        {
            let f = File::create(&apk).unwrap();
            let mut zip = zip::ZipWriter::new(f);
            let opts = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip.start_file("classes.dex", opts).unwrap();
            std::io::Write::write_all(&mut zip, &fake_dex(100)).unwrap();
            zip.start_file("classes2.dex", opts).unwrap();
            std::io::Write::write_all(&mut zip, &fake_dex(50)).unwrap();
            zip.start_file("AndroidManifest.xml", opts).unwrap();
            std::io::Write::write_all(&mut zip, &[0u8; 32]).unwrap();
            zip.finish().unwrap();
        }

        let stats = scan_dex_stats(apk.to_str().unwrap()).unwrap();
        assert_eq!(stats.dex_files.len(), 2);
        assert_eq!(stats.dex_files[0].name, "classes.dex");
        assert_eq!(stats.dex_files[0].class_count, 100);
        assert_eq!(stats.dex_files[1].name, "classes2.dex");
        assert_eq!(stats.dex_files[1].class_count, 50);
        assert_eq!(stats.total_class_count, 150);
        assert!(stats.dex_files[0].size > 0);
    }

    #[test]
    fn broken_dex_reports_minus_one() {
        let dir = std::env::temp_dir().join(format!("gstore_dexstat_bad_{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok();
        let apk = dir.join("t.apk");
        {
            let f = File::create(&apk).unwrap();
            let mut zip = zip::ZipWriter::new(f);
            let opts = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip.start_file("classes.dex", opts).unwrap();
            // 不足 0x70 字节 → 判定失败，但不中断
            std::io::Write::write_all(&mut zip, &[0u8; 16]).unwrap();
            zip.finish().unwrap();
        }
        let stats = scan_dex_stats(apk.to_str().unwrap()).unwrap();
        assert_eq!(stats.dex_files.len(), 1);
        assert_eq!(stats.dex_files[0].class_count, -1);
        assert_eq!(stats.total_class_count, 0);
    }

    /// 构造一份含 1 个类定义的最小 DEX：
    /// string_ids → "Lcom/demo/A;"，type_ids → 该字符串，class_defs → 该 type
    fn fake_dex_with_class(desc: &str) -> Vec<u8> {
        let data_off = 0x70usize;
        // ULEB128 长度 + MUTF-8 + NUL
        let mut data = vec![desc.len() as u8];
        data.extend_from_slice(desc.as_bytes());
        data.push(0);
        let string_ids_off = data_off + data.len();
        let type_ids_off = string_ids_off + 4;
        let class_defs_off = type_ids_off + 4;
        let total = class_defs_off + 32;
        let mut v = vec![0u8; total];
        v[0..8].copy_from_slice(b"dex\n035\0");
        v[0x38..0x3C].copy_from_slice(&1u32.to_le_bytes()); // string_ids_size
        v[0x3C..0x40].copy_from_slice(&(string_ids_off as u32).to_le_bytes());
        v[0x40..0x44].copy_from_slice(&1u32.to_le_bytes()); // type_ids_size
        v[0x44..0x48].copy_from_slice(&(type_ids_off as u32).to_le_bytes());
        v[0x60..0x64].copy_from_slice(&1u32.to_le_bytes()); // class_defs_size
        v[0x64..0x68].copy_from_slice(&(class_defs_off as u32).to_le_bytes());
        v[data_off..data_off + data.len()].copy_from_slice(&data);
        v[string_ids_off..string_ids_off + 4].copy_from_slice(&(data_off as u32).to_le_bytes());
        v[type_ids_off..type_ids_off + 4].copy_from_slice(&0u32.to_le_bytes()); // type → string 0
        v[class_defs_off..class_defs_off + 4].copy_from_slice(&0u32.to_le_bytes()); // class → type 0
        v
    }

    #[test]
    fn class_digest_is_stable_and_content_sensitive() {
        let a = class_set_digest(&fake_dex_with_class("Lcom/demo/A;"));
        let b = class_set_digest(&fake_dex_with_class("Lcom/demo/A;"));
        let c = class_set_digest(&fake_dex_with_class("Lcom/demo/B;"));
        assert_eq!(a.len(), 64, "SHA-256 hex");
        assert_eq!(a, b, "同一类集合 → 同一指纹（分包搬迁可识别）");
        assert_ne!(a, c, "类不同 → 指纹必须不同");
    }

    #[test]
    fn class_digest_empty_for_non_dex() {
        assert!(class_set_digest(&[0u8; 32]).is_empty());
    }
}
