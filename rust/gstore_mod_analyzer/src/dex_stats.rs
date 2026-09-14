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
const DEX_HEADER_SIZE: usize = 0x70;

/// 单个 DEX 条目统计
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

        // 只读前 0x70 字节：defalte 流按需解压，不会展开整个 DEX
        let mut header = vec![0u8; DEX_HEADER_SIZE];
        let class_count = match entry.read_exact(&mut header) {
            Ok(()) => read_class_defs_size(&header).map(|v| v as i64).unwrap_or(-1),
            Err(_) => -1,
        };
        if class_count > 0 {
            total_class_count = total_class_count.saturating_add(class_count as u64);
        }

        dex_files.push(DexStatEntry {
            name,
            size,
            compressed_size,
            crc32,
            class_count,
        });
    }
    dex_files.sort_by(|a, b| a.name.cmp(&b.name));

    Ok(ApkDexStats {
        dex_files,
        total_class_count,
    })
}

/// 校验 DEX 魔数并读 `class_defs_size`（offset 0x60）
fn read_class_defs_size(header: &[u8]) -> Option<u32> {
    if header.len() < DEX_HEADER_SIZE {
        return None;
    }
    if header.get(0..4)? != b"dex\n" || header.get(7) != Some(&0) {
        return None;
    }
    Some(u32::from_le_bytes([
        header[0x60],
        header[0x61],
        header[0x62],
        header[0x63],
    ]))
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

    /// 合成一个最小 DEX 头：魔数 + version + class_defs_size
    fn fake_dex(class_defs_size: u32) -> Vec<u8> {
        let mut v = vec![0u8; DEX_HEADER_SIZE + 16];
        v[0..8].copy_from_slice(b"dex\n035\0");
        v[0x60..0x64].copy_from_slice(&class_defs_size.to_le_bytes());
        v
    }

    #[test]
    fn reads_class_defs_size() {
        assert_eq!(read_class_defs_size(&fake_dex(1234)), Some(1234));
    }

    #[test]
    fn rejects_non_dex() {
        let mut bad = fake_dex(1);
        bad[0] = 0;
        assert_eq!(read_class_defs_size(&bad), None);
        // 长度不足
        assert_eq!(read_class_defs_size(&[0u8; 8]), None);
        // version 末字节必须为 0
        let mut bad2 = fake_dex(1);
        bad2[7] = b'1';
        assert_eq!(read_class_defs_size(&bad2), None);
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
}
