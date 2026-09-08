//! APK 内 ELF .so 的 16KB 页对齐检测
//!
//! 输入：APK 路径。输出：`lib/<abi>/<name>.so` 每个文件的 ELF 最小页对齐
//! （min_page_size）与是否 16KB 对齐（aligned_16kb）。
//!
//! 与 LibChecker 的对齐说明：
//! - 逻辑对齐 `ElfParser.getMinPageSize()`：遍历程序头中全部 PT_LOAD 段，
//!   取 p_align 最小值；无 PT_LOAD 段返回 -1。
//! - 仅解析 ELF 头 + 程序头（不解析节区/符号表），纯字节切片读取：
//!   失败（非 ELF / 越界 / 非法 class 或字节序）对该库记为
//!   min_page_size=-1、aligned_16kb=false，不中断整包扫描。
//! - p_align 0/1 视为未知，不判定为 16KB 对齐。

use std::fs::File;
use std::io::Read;

use zip::ZipArchive;

/// 单个 ELF .so 的页对齐检测结果
#[derive(Clone, Debug, Default)]
pub struct ElfSoInfo {
    /// 所在 ABI 目录（如 `arm64-v8a`）
    pub abi: String,
    /// .so 文件名（如 `libfoo.so`）
    pub so_name: String,
    /// PT_LOAD 段最小 p_align；-1 表示非 ELF / 无 PT_LOAD / 解析失败
    pub min_page_size: i64,
    /// min_page_size > 0 且能被 16384 整除
    pub aligned_16kb: bool,
}

/// 整包扫描结果
#[derive(Clone, Debug, Default)]
pub struct ApkElfScanResult {
    /// 命中的 `lib/<abi>/*.so` 检测结果列表
    pub so_files: Vec<ElfSoInfo>,
}

/// 扫描 APK 内所有 `lib/<abi>/<name>.so` 与 `assets/<name>.so`，
/// 逐文件检测 ELF 16KB 页对齐（assets 下的库归入 `assets` 分组）。
///
/// 单个库读取/解析失败不中断整包扫描（记为 min_page_size=-1、aligned_16kb=false）。
pub fn scan_elf_page_sizes(apk_path: &str) -> Result<ApkElfScanResult, String> {
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;

    let mut so_files = Vec::new();
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let Some((abi, so_name)) = parse_lib_path(entry.name()) else {
            continue;
        };

        let mut bytes = Vec::new();
        if entry.read_to_end(&mut bytes).is_err() {
            so_files.push(ElfSoInfo {
                abi,
                so_name,
                min_page_size: -1,
                aligned_16kb: false,
            });
            continue;
        }

        let min_page_size = parse_elf_min_page_size(&bytes);
        let aligned_16kb = min_page_size > 0 && min_page_size % 16384 == 0;
        so_files.push(ElfSoInfo {
            abi,
            so_name,
            min_page_size,
            aligned_16kb,
        });
    }

    Ok(ApkElfScanResult { so_files })
}

/// `lib/<abi>/<name>.so` → (abi, so_name)；`assets/<name>.so` → ("assets", name)；
/// 其余路径返回 None。
fn parse_lib_path(path: &str) -> Option<(String, String)> {
    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() == 2 && parts[0] == "assets" && parts[1].ends_with(".so") {
        return Some(("assets".to_string(), parts[1].to_string()));
    }
    if parts.len() != 3 || parts[0] != "lib" || parts[1].is_empty() || !parts[2].ends_with(".so") {
        return None;
    }
    Some((parts[1].to_string(), parts[2].to_string()))
}

/// 解析单个 ELF 文件 PT_LOAD 段的最小 p_align（LibChecker getMinPageSize 语义）。
///
/// 规则：
/// 1. 魔数 `0x7F 45 4C 46`；byte4 class（1=ELF32，2=ELF64）；byte5 data（1=LE，2=BE）。
/// 2. ELF32：e_phoff@0x1C(u32)、e_phentsize@0x2A(u16)、e_phnum@0x2C(u16)、phdr=32B；
///    ELF64：e_phoff@0x20(u64)、e_phentsize@0x36(u16)、e_phnum@0x38(u16)、phdr=56B。
/// 3. 程序头 p_type@0(u32)==1（PT_LOAD）时收集 p_align：
///    ELF32 p_align@28(u32)、ELF64 p_align@48(u64)。
/// 4. 返回全部 PT_LOAD 中最小 p_align；无 PT_LOAD 或任何解析失败返回 -1。
fn parse_elf_min_page_size(bytes: &[u8]) -> i64 {
    if bytes.len() < 6 || bytes.get(0..4) != Some(&[0x7F, b'E', b'L', b'F']) {
        return -1;
    }
    let class = bytes[4]; // 1=ELF32，2=ELF64
    let data = bytes[5]; // 1=LE，2=BE
    if (class != 1 && class != 2) || (data != 1 && data != 2) {
        return -1;
    }
    let big = data == 2;
    let is_elf64 = class == 2;

    let (phoff, phentsize, phnum, align_off, align_size) = if is_elf64 {
        let phoff = match read_u64(bytes, 0x20, big) {
            Some(v) => v,
            None => return -1,
        };
        let phentsize = match read_u16(bytes, 0x36, big) {
            Some(v) => v,
            None => return -1,
        };
        let phnum = match read_u16(bytes, 0x38, big) {
            Some(v) => v,
            None => return -1,
        };
        (phoff, phentsize, phnum, 48usize, 8usize)
    } else {
        let phoff = match read_u32(bytes, 0x1C, big) {
            Some(v) => v as u64,
            None => return -1,
        };
        let phentsize = match read_u16(bytes, 0x2A, big) {
            Some(v) => v,
            None => return -1,
        };
        let phnum = match read_u16(bytes, 0x2C, big) {
            Some(v) => v,
            None => return -1,
        };
        (phoff, phentsize, phnum, 28usize, 4usize)
    };
    // 表项必须大到能读 p_align，否则视为失败
    if (phentsize as usize) < align_off + align_size {
        return -1;
    }

    let mut min_align: Option<i64> = None;
    for i in 0..phnum {
        let Some(offset) = (phentsize as u64)
            .checked_mul(i as u64)
            .and_then(|s| phoff.checked_add(s))
        else {
            continue;
        };
        let offset = offset as usize;
        let Some(p_type) = read_u32(bytes, offset, big) else {
            continue;
        };
        if p_type != 1 {
            continue; // 非 PT_LOAD
        }
        let Some(align) = read_align(bytes, offset + align_off, big, align_size) else {
            continue;
        };
        min_align = Some(match min_align {
            Some(m) => m.min(align),
            None => align,
        });
    }

    min_align.unwrap_or(-1)
}

fn read_align(buf: &[u8], off: usize, big: bool, size: usize) -> Option<i64> {
    if size == 8 {
        read_u64(buf, off, big).map(|v| v as i64)
    } else {
        read_u32(buf, off, big).map(|v| v as i64)
    }
}

fn read_u16(buf: &[u8], off: usize, big: bool) -> Option<u16> {
    let arr: [u8; 2] = buf.get(off..off + 2)?.try_into().ok()?;
    Some(if big {
        u16::from_be_bytes(arr)
    } else {
        u16::from_le_bytes(arr)
    })
}

fn read_u32(buf: &[u8], off: usize, big: bool) -> Option<u32> {
    let arr: [u8; 4] = buf.get(off..off + 4)?.try_into().ok()?;
    Some(if big {
        u32::from_be_bytes(arr)
    } else {
        u32::from_le_bytes(arr)
    })
}

fn read_u64(buf: &[u8], off: usize, big: bool) -> Option<u64> {
    let arr: [u8; 8] = buf.get(off..off + 8)?.try_into().ok()?;
    Some(if big {
        u64::from_be_bytes(arr)
    } else {
        u64::from_le_bytes(arr)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造最小 ELF64：e_phoff=64、e_phentsize=56、e_phnum=1，
    /// 单个 PT_LOAD phdr p_align=p_align。
    fn elf64(p_align: u64, big_endian: bool) -> Vec<u8> {
        let mut buf = vec![0u8; 64 + 56];
        buf[0..4].copy_from_slice(&[0x7F, b'E', b'L', b'F']);
        buf[4] = 2; // ELF64
        buf[5] = if big_endian { 2 } else { 1 };
        buf[6] = 1; // EI_VERSION
        let phoff = 64u64;
        if big_endian {
            buf[0x20..0x28].copy_from_slice(&phoff.to_be_bytes());
            buf[0x36..0x38].copy_from_slice(&56u16.to_be_bytes());
            buf[0x38..0x3A].copy_from_slice(&1u16.to_be_bytes());
            buf[64..68].copy_from_slice(&1u32.to_be_bytes()); // p_type = PT_LOAD
            buf[64 + 48..64 + 56].copy_from_slice(&p_align.to_be_bytes());
        } else {
            buf[0x20..0x28].copy_from_slice(&phoff.to_le_bytes());
            buf[0x36..0x38].copy_from_slice(&56u16.to_le_bytes());
            buf[0x38..0x3A].copy_from_slice(&1u16.to_le_bytes());
            buf[64..68].copy_from_slice(&1u32.to_le_bytes()); // p_type = PT_LOAD
            buf[64 + 48..64 + 56].copy_from_slice(&p_align.to_le_bytes());
        }
        buf
    }

    #[test]
    fn elf64_le_16kb_aligned() {
        let min = parse_elf_min_page_size(&elf64(16384, false));
        assert_eq!(min, 16384);
    }

    #[test]
    fn elf64_le_4kb_not_aligned() {
        let min = parse_elf_min_page_size(&elf64(4096, false));
        assert_eq!(min, 4096);
    }

    #[test]
    fn non_elf_returns_minus_one() {
        assert_eq!(parse_elf_min_page_size(&[0u8; 64]), -1);
        assert_eq!(parse_elf_min_page_size(&[]), -1);
        assert_eq!(parse_elf_min_page_size(b"MZ\x90\x00..."), -1);
    }

    #[test]
    fn elf64_be_0x4000_aligned() {
        let min = parse_elf_min_page_size(&elf64(0x4000, true));
        assert_eq!(min, 16384);
    }

    #[test]
    fn scan_apk_elf_files() {
        let dir = std::env::temp_dir().join(format!(
            "gstore_elf_test_{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).ok();
        let apk_path = dir.join("scan_test.apk");
        let file = File::create(&apk_path).ok();
        if let Some(file) = file {
            let mut zip = zip::ZipWriter::new(file);
            let opts = zip::write::SimpleFileOptions::default();
            // 16KB 对齐库
            zip.start_file("lib/arm64-v8a/liba.so", opts).ok();
            std::io::Write::write_all(&mut zip, &elf64(16384, false)).ok();
            // 4KB 库
            zip.start_file("lib/arm64-v8a/libb.so", opts).ok();
            std::io::Write::write_all(&mut zip, &elf64(4096, false)).ok();
            // assets 下的 .so（归入 assets 分组）
            zip.start_file("assets/libembedded.so", opts).ok();
            std::io::Write::write_all(&mut zip, &elf64(16384, false)).ok();
            // 非 lib 文件，应被跳过
            zip.start_file("res/xml/config.xml", opts).ok();
            std::io::Write::write_all(&mut zip, b"<xml/>").ok();
            zip.finish().ok();
        }

        let result = scan_elf_page_sizes(apk_path.to_str().unwrap()).unwrap();
        assert_eq!(result.so_files.len(), 3);

        let by_name = |n: &str| result.so_files.iter().find(|f| f.so_name == n).unwrap();
        let a = by_name("liba.so");
        assert_eq!(a.abi, "arm64-v8a");
        assert_eq!(a.min_page_size, 16384);
        assert!(a.aligned_16kb);

        let b = by_name("libb.so");
        assert_eq!(b.abi, "arm64-v8a");
        assert_eq!(b.min_page_size, 4096);
        assert!(!b.aligned_16kb);

        let embedded = by_name("libembedded.so");
        assert_eq!(embedded.abi, "assets");
        assert_eq!(embedded.min_page_size, 16384);
        assert!(embedded.aligned_16kb);
    }
}
