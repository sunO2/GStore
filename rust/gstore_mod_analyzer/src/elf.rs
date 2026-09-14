//! APK 内 ELF `.so` 元数据与 16KB 页对齐检测
//!
//! 输入：APK 路径（可选 ABI 过滤）。输出：`lib/<abi>/<name>.so` 与
//! `assets/*.so` 的：
//! - ELF 类型（`e_type`）、最小页对齐（PT_LOAD `p_align`）、是否 16KB 对齐；
//! - `DT_NEEDED` 动态依赖、JNI 导出入口（`Java_*`/`JNI_*`）、是否剥离符号表。
//!
//! 与 LibChecker 的对齐说明：
//! - 页对齐 = `ElfParser.getMinPageSize()`：遍历程序头全部 PT_LOAD 取 `p_align` 最小值。
//! - 16KB 判定 = `PackageInfoExtensions.is16KBAligned()`：页对齐是 16KB 的倍数，
//!   **且** zip 数据偏移对齐满足（未压缩存放时 ≥0x4000；压缩存放或未知则跳过该条件）。
//! - `DT_NEEDED` / JNI 入口 / stripped 对齐 `AppElfDetail`（deps / entryPoints / isStripped）。
//!
//! 只解析 ELF 头 / 程序头 / 节区头 / 动态段 / 动态符号表，不解析指令、不做重定位。
//! 任何解析失败都只影响该库自身（记为失败值），不中断整包扫描。

use std::fs::File;
use std::io::Read;

use zip::ZipArchive;

/// 单个 ELF `.so` 的检测结果
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct ElfSoInfo {
    /// 所在分组：ABI 目录名（如 `arm64-v8a`）或 `assets`
    pub abi: String,
    /// .so 文件名（如 `libfoo.so`）
    pub so_name: String,
    /// zip 内完整路径
    pub path: String,
    /// 解压后字节数
    pub size: u64,
    /// PT_LOAD 段最小 p_align；-1 表示非 ELF / 无 PT_LOAD / 解析失败
    pub min_page_size: i64,
    /// STORED 条目数据起始偏移的最大 2 的幂因子；0 = 压缩存放或未知
    pub zip_alignment: u64,
    /// 最终 16KB 判定（页对齐 + zip 对齐两个条件都满足）
    pub aligned_16kb: bool,
    /// `e_type`：2=ET_EXEC / 3=ET_DYN / 4=ET_CORE；-1 非 ELF
    pub elf_type: i32,
    /// `DT_NEEDED` 依赖库名（上限 [`MAX_LIST`] 条）
    pub needed: Vec<String>,
    /// JNI 导出入口符号（`Java_*` / `JNI_*`，上限 [`MAX_LIST`] 条）
    pub jni_entry_points: Vec<String>,
    /// 是否已剥离符号表（无 SHT_SYMTAB 节）
    pub stripped: bool,
    /// 解压后内容的 SHA-256（小写 hex）——判定"是否同一个文件"的强指纹
    pub sha256: String,
    /// `.note.gnu.build-id`（小写 hex）；链接器未写入时为空。
    /// 与 sha256 搭配可区分「同一份产物」/「同一构建重新链接」/「完全不同的构建」
    pub build_id: String,
}

/// 整包扫描结果
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct ApkElfScanResult {
    /// 命中的 `lib/<abi>/*.so` 与 `assets/*.so` 检测结果列表
    pub so_files: Vec<ElfSoInfo>,
}

/// 依赖与 JNI 入口的返回条数上限（避免超大 .so 撑爆响应）
const MAX_LIST: usize = 64;

/// 16KB 页大小（LibChecker 常量 0x4000）
const PAGE_16KB: i64 = 0x4000;

/// 扫描 APK 内 `.so` 并解析 ELF 元数据。
///
/// `abi_filter` 非空时只扫描这些 ABI 分组（对齐 LibChecker 的「只解析选中 ABI」，
/// 避免把所有 ABI 的库全部解压）。`assets` 分组始终扫描。
pub fn scan_elf_page_sizes(
    apk_path: &str,
    abi_filter: Option<&[String]>,
) -> Result<ApkElfScanResult, String> {
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;
    scan_elf_from(&mut archive, abi_filter)
}

/// 复用已打开的 archive（聚合入口用：一次打开产出全部节）
pub fn scan_elf_from(
    archive: &mut ZipArchive<File>,
    abi_filter: Option<&[String]>,
) -> Result<ApkElfScanResult, String> {
    let mut so_files = Vec::new();
    for i in 0..archive.len() {
        let mut entry = match archive.by_index(i) {
            Ok(e) => e,
            Err(_) => continue,
        };
        let Some((abi, so_name)) = parse_lib_path(entry.name()) else {
            continue;
        };
        if !abi_selected(&abi, abi_filter) {
            continue;
        }
        let path = entry.name().to_string();
        let size = entry.size();
        let stored = entry.compression() == zip::CompressionMethod::Stored;
        let zip_alignment = if stored {
            zip_alignment(entry.data_start())
        } else {
            0
        };

        let mut bytes = Vec::new();
        if entry.read_to_end(&mut bytes).is_err() {
            so_files.push(ElfSoInfo {
                abi,
                so_name,
                path,
                size,
                min_page_size: -1,
                zip_alignment,
                aligned_16kb: false,
                elf_type: -1,
                needed: Vec::new(),
                jni_entry_points: Vec::new(),
                stripped: false,
                sha256: String::new(),
                build_id: String::new(),
            });
            continue;
        }

        // 内容强指纹：字节已在内存，纯 CPU 开销（本机 29 个 .so / 59MB ≈ 0.2s）
        let sha256 = sha256_hex(&bytes);
        let elf = parse_elf(&bytes);
        let aligned_16kb = is_16kb_aligned(elf.min_page_size, zip_alignment);
        so_files.push(ElfSoInfo {
            abi,
            so_name,
            path,
            size,
            min_page_size: elf.min_page_size,
            zip_alignment,
            aligned_16kb,
            elf_type: elf.elf_type,
            needed: elf.needed,
            jni_entry_points: elf.jni_entry_points,
            stripped: elf.stripped,
            sha256,
            build_id: elf.build_id,
        });
    }

    Ok(ApkElfScanResult { so_files })
}

/// 16KB 判定：页对齐是 16KB 的倍数，且 zip 对齐满足。
/// zip 对齐为 0（压缩存放 / 未知）时不参与判定（对齐 LibChecker 语义）。
fn is_16kb_aligned(min_page_size: i64, zip_alignment: u64) -> bool {
    if min_page_size <= 0 || min_page_size % PAGE_16KB != 0 {
        return false;
    }
    if zip_alignment == 0 {
        return true;
    }
    zip_alignment >= PAGE_16KB as u64
}

/// `lib/<abi>/<name>.so` → (abi, name)；`assets/<name>.so` → ("assets", name)
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

/// ABI 过滤：无过滤时全选；有过滤时只保留列出的 ABI（`assets` 始终保留）
fn abi_selected(abi: &str, filter: Option<&[String]>) -> bool {
    match filter {
        None => true,
        Some(list) if list.is_empty() => true,
        Some(list) => abi == "assets" || list.iter().any(|a| a == abi),
    }
}

fn zip_alignment(data_start: u64) -> u64 {
    if data_start == 0 {
        return 0;
    }
    1u64 << data_start.trailing_zeros()
}

// ==================== ELF 解析 ====================

/// 解析结果（失败时为默认值）
#[derive(Default)]
struct ElfParsed {
    min_page_size: i64,
    elf_type: i32,
    needed: Vec<String>,
    jni_entry_points: Vec<String>,
    stripped: bool,
    /// `.note.gnu.build-id`（小写 hex）；编辑器/链接器未写入时为空
    build_id: String,
}

/// 字节内容的 SHA-256（小写 hex）
fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// 从 SHT_NOTE 节里取 `.note.gnu.build-id` 的描述符（构建身份）
///
/// note 布局：namesz(4) descsz(4) type(4) name(namesz，按 4 对齐) desc(descsz，按 4 对齐)
fn build_id_of_note(bytes: &[u8], off: usize, size: usize, big: bool) -> Option<String> {
    if size == 0 || off.checked_add(size)? > bytes.len() {
        return None;
    }
    let end = off + size;
    let mut cursor = off;
    while cursor + 12 <= end {
        let namesz = read_u32(bytes, cursor, big)? as usize;
        let descsz = read_u32(bytes, cursor + 4, big)? as usize;
        let ntype = read_u32(bytes, cursor + 8, big)?;
        let name_start = cursor + 12;
        let name_end = name_start.checked_add(namesz)?;
        let name = bytes.get(name_start..name_end)?;
        let desc_start = name_start + ((namesz + 3) & !3);
        let desc_end = desc_start.checked_add(descsz)?;
        if name == b"GNU\0" && ntype == 3 {
            let desc = bytes.get(desc_start..desc_end)?;
            if !desc.is_empty() {
                return Some(desc.iter().map(|b| format!("{b:02x}")).collect());
            }
        }
        cursor = desc_start + ((descsz + 3) & !3);
    }
    None
}

fn parse_elf(bytes: &[u8]) -> ElfParsed {
    let mut out = ElfParsed {
        min_page_size: -1,
        elf_type: -1,
        ..Default::default()
    };
    if bytes.len() < 0x34 || bytes.get(0..4) != Some(&[0x7F, b'E', b'L', b'F']) {
        return out;
    }
    let class = bytes[4]; // 1=ELF32, 2=ELF64
    let data = bytes[5]; // 1=LE, 2=BE
    if (class != 1 && class != 2) || (data != 1 && data != 2) {
        return out;
    }
    let big = data == 2;
    let is64 = class == 2;

    out.elf_type = read_u16(bytes, 0x10, big).map(|v| v as i32).unwrap_or(-1);

    let (phoff, phentsize, phnum) = if is64 {
        (
            read_u64(bytes, 0x20, big),
            read_u16(bytes, 0x36, big),
            read_u16(bytes, 0x38, big),
        )
    } else {
        (
            read_u32(bytes, 0x1C, big).map(|v| v as u64),
            read_u16(bytes, 0x2A, big),
            read_u16(bytes, 0x2C, big),
        )
    };
    let (shoff, shentsize, shnum) = if is64 {
        (
            read_u64(bytes, 0x28, big),
            read_u16(bytes, 0x3A, big),
            read_u16(bytes, 0x3C, big),
        )
    } else {
        (
            read_u32(bytes, 0x20, big).map(|v| v as u64),
            read_u16(bytes, 0x2E, big),
            read_u16(bytes, 0x30, big),
        )
    };

    // 节区名表下标（用于按名字找 .note.gnu.build-id）
    let shstrndx = if is64 {
        read_u16(bytes, 0x3E, big)
    } else {
        read_u16(bytes, 0x32, big)
    };

    // 程序头：取 PT_LOAD 的最小 p_align
    if let (Some(phoff), Some(phentsize), Some(phnum)) = (phoff, phentsize, phnum) {
        let align_off = if is64 { 48 } else { 28 };
        let align_size = if is64 { 8 } else { 4 };
        if (phentsize as usize) >= align_off + align_size {
            let mut min_align: Option<i64> = None;
            for i in 0..phnum {
                let Some(off) = (phentsize as u64)
                    .checked_mul(i as u64)
                    .and_then(|s| phoff.checked_add(s))
                    .map(|v| v as usize)
                else {
                    continue;
                };
                if read_u32(bytes, off, big) != Some(1) {
                    continue; // 非 PT_LOAD
                }
                let align = if is64 {
                    read_u64(bytes, off + align_off, big).map(|v| v as i64)
                } else {
                    read_u32(bytes, off + align_off, big).map(|v| v as i64)
                };
                if let Some(a) = align {
                    min_align = Some(min_align.map_or(a, |m: i64| m.min(a)));
                }
            }
            out.min_page_size = min_align.unwrap_or(-1);
        }
    }

    // 节区头：找 SHT_SYMTAB（2，→ stripped）、SHT_DYNAMIC（6，→ DT_NEEDED）、
    // SHT_DYNSYM（11，→ JNI 入口）
    let (Some(shoff), Some(shentsize), Some(shnum)) = (shoff, shentsize, shnum) else {
        return out;
    };
    if shnum == 0 || (shentsize as usize) < 40 {
        return out;
    }
    // 节区头字段偏移（按 class 区分）
    let (sh_type_off, sh_off_off, sh_size_off, sh_link_off) = if is64 {
        (4usize, 24usize, 32usize, 40usize)
    } else {
        (4usize, 16usize, 20usize, 24usize)
    };
    let size_size = if is64 { 8 } else { 4 };

    let mut symtab_found = false;
    let mut dynamic: Option<(usize, usize, usize)> = None; // (offset, size, link)
    let mut dynsym: Option<(usize, usize, usize)> = None;
    let mut build_id: Option<String> = None;

    // 按节区名表取节名（SHT_NOTE 需要按名字筛选）
    let name_of = |sh_name: usize| -> Option<(usize, usize)> {
        let idx = shstrndx? as usize;
        if idx == 0 || idx >= shnum as usize {
            return None;
        }
        let base = (shentsize as u64)
            .checked_mul(idx as u64)
            .and_then(|v| shoff.checked_add(v))
            .map(|v| v as usize)?;
        let off = read_addr(bytes, base + sh_off_off, big, size_size).map(|v| v as usize)?;
        let size = read_addr(bytes, base + sh_size_off, big, size_size).map(|v| v as usize)?;
        let start = off.checked_add(sh_name)?;
        let end = off.checked_add(size)?;
        if start >= end || end > bytes.len() {
            return None;
        }
        Some((start, end))
    };

    for i in 0..shnum {
        let Some(base) = (shentsize as u64)
            .checked_mul(i as u64)
            .and_then(|s| shoff.checked_add(s))
            .map(|v| v as usize)
        else {
            continue;
        };
        let Some(sh_type) = read_u32(bytes, base + sh_type_off, big) else {
            continue;
        };
        let Some(off) = read_addr(bytes, base + sh_off_off, big, size_size).map(|v| v as usize)
        else {
            continue;
        };
        let Some(size) = read_addr(bytes, base + sh_size_off, big, size_size).map(|v| v as usize)
        else {
            continue;
        };
        let link = read_u32(bytes, base + sh_link_off, big).unwrap_or(0) as usize;
        match sh_type {
            2 => symtab_found = true,               // SHT_SYMTAB
            6 => dynamic = Some((off, size, link)),  // SHT_DYNAMIC
            11 => dynsym = Some((off, size, link)),  // SHT_DYNSYM
            7 => {
                // SHT_NOTE：**按节名**筛出 .note.gnu.build-id（构建身份）
                if build_id.is_none() {
                    let sh_name = read_u32(bytes, base, big).unwrap_or(0) as usize;
                    // 节名表里是 NUL 结尾的字符串：截到 NUL 再精确比较
                    let is_build_id = name_of(sh_name)
                        .and_then(|(s, e)| bytes.get(s..e))
                        .map(|n| {
                            let end = n.iter().position(|b| *b == 0).unwrap_or(n.len());
                            &n[..end] == b".note.gnu.build-id"
                        })
                        .unwrap_or(false);
                    if is_build_id {
                        build_id = build_id_of_note(bytes, off, size, big);
                    }
                }
            }
            _ => {}
        }
    }
    out.stripped = !symtab_found;
    out.build_id = build_id.unwrap_or_default();

    // sh_link 指向节区索引：按下标重新读该节区的 offset/size，作为关联字符串表
    let strtab_by_link = |link: usize| -> Option<(usize, usize)> {
        let base = (shentsize as u64)
            .checked_mul(link as u64)
            .and_then(|s| shoff.checked_add(s))
            .map(|v| v as usize)?;
        if base >= bytes.len() {
            return None;
        }
        let off = read_addr(bytes, base + sh_off_off, big, size_size)? as usize;
        let size = read_addr(bytes, base + sh_size_off, big, size_size)? as usize;
        Some((off, size))
    };

    // DT_NEEDED（tag=1）：d_val 是 strtab（sh_link）内的偏移
    if let Some((dyn_off, dyn_size, link)) = dynamic {
        let entsize = if is64 { 16 } else { 8 };
        if let Some((str_off, str_size)) = strtab_by_link(link) {
            let count = dyn_size / entsize;
            for k in 0..count.min(4096) {
                let e = dyn_off + k * entsize;
                let Some(tag) = read_addr(bytes, e, big, size_size) else {
                    break;
                };
                if tag == 0 {
                    break; // DT_NULL
                }
                if tag == 1 {
                    if let Some(val) = read_addr(bytes, e + size_size, big, size_size) {
                        if let Some(s) = read_cstr(bytes, str_off + val as usize, str_size) {
                            if out.needed.len() < MAX_LIST {
                                out.needed.push(s);
                            }
                        }
                    }
                }
            }
        }
    }

    // JNI 入口（SHT_DYNSYM 中 STT_FUNC 且名字以 Java_/JNI_ 开头）
    if let Some((sym_off, sym_size, link)) = dynsym {
        let entsize = if is64 { 24 } else { 16 };
        let info_off = if is64 { 4 } else { 12 };
        if let Some((str_off, str_size)) = strtab_by_link(link) {
            let count = sym_size / entsize;
            for k in 0..count.min(200_000) {
                if out.jni_entry_points.len() >= MAX_LIST {
                    break;
                }
                let e = sym_off + k * entsize;
                let Some(name_off) = read_u32(bytes, e, big) else {
                    break;
                };
                let Some(info) = bytes.get(e + info_off).copied() else {
                    break;
                };
                if info & 0x0F != 2 {
                    continue; // 非 STT_FUNC
                }
                if let Some(name) = read_cstr(bytes, str_off + name_off as usize, str_size) {
                    if name.starts_with("Java_") || name.starts_with("JNI_") {
                        out.jni_entry_points.push(name);
                    }
                }
            }
        }
    }

    out
}

/// 读字符串表内的 NUL 结尾字符串（限制在 strtab 范围内）
fn read_cstr(bytes: &[u8], offset: usize, strtab_size: usize) -> Option<String> {
    let end = offset.checked_add(strtab_size)?;
    let limit = end.min(bytes.len());
    if offset >= limit {
        return None;
    }
    let slice = &bytes[offset..limit];
    let nul = slice.iter().position(|&b| b == 0)?;
    let s = std::str::from_utf8(&slice[..nul]).ok()?;
    if s.is_empty() {
        return None;
    }
    Some(s.to_string())
}

fn read_addr(buf: &[u8], off: usize, big: bool, size: usize) -> Option<u64> {
    if size == 8 {
        read_u64(buf, off, big)
    } else {
        read_u32(buf, off, big).map(|v| v as u64)
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

    /// 构造最小 ELF64，用于验证 e_type / p_align / stripped / DT_NEEDED / JNI 入口。
    ///
    /// 节区布局（索引 → 用途）：
    /// 0 = NULL，1 = STRTAB（DT_NEEDED 用），2 = DYNAMIC（sh_link=1），
    /// 3 = STRTAB（符号名用），4 = DYNSYM（sh_link=3），5 = SYMTAB（可选，sh_link=1）
    fn build_elf64(p_align: u64, with_symtab: bool) -> Vec<u8> {
        let ehsize = 64usize;
        let phentsize = 56usize;
        let shentsize = 64usize;
        let phoff = ehsize;
        let after_ph = phoff + phentsize;

        let strtab = b"libc.so\0".to_vec();
        let strtab_off = after_ph;
        let dyn_off = strtab_off + strtab.len();
        let dyn_size = 32usize; // 2 项 × 16 字节：DT_NEEDED + DT_NULL
        let symstr = b"Java_com_example_Foo_bar\0notjni\0".to_vec();
        let symstr_off = dyn_off + dyn_size;
        let sym_off = symstr_off + symstr.len();
        let sym_size = 48usize; // 2 项 × 24 字节：NULL 符号 + 1 个 FUNC 符号
        let shoff = sym_off + sym_size;

        const NULL: usize = 0;
        const STR_DYN: usize = 1;
        const DYNAMIC: usize = 2;
        const STR_SYM: usize = 3;
        const DYNSYM: usize = 4;
        const SYMTAB: usize = 5;
        let n_shdrs = if with_symtab { 6 } else { 5 };
        let mut buf = vec![0u8; shoff + n_shdrs * shentsize];

        buf[0..4].copy_from_slice(&[0x7F, b'E', b'L', b'F']);
        buf[4] = 2; // ELF64
        buf[5] = 1; // 小端
        buf[6] = 1;
        buf[0x10..0x12].copy_from_slice(&3u16.to_le_bytes()); // e_type = ET_DYN
        buf[0x20..0x28].copy_from_slice(&(phoff as u64).to_le_bytes()); // e_phoff
        buf[0x28..0x30].copy_from_slice(&(shoff as u64).to_le_bytes()); // e_shoff
        buf[0x36..0x38].copy_from_slice(&(phentsize as u16).to_le_bytes());
        buf[0x38..0x3A].copy_from_slice(&1u16.to_le_bytes());
        buf[0x3A..0x3C].copy_from_slice(&(shentsize as u16).to_le_bytes());
        buf[0x3C..0x3E].copy_from_slice(&(n_shdrs as u16).to_le_bytes());

        // PT_LOAD：p_type=1，p_align@48
        buf[phoff..phoff + 4].copy_from_slice(&1u32.to_le_bytes());
        buf[phoff + 48..phoff + 56].copy_from_slice(&p_align.to_le_bytes());

        buf[strtab_off..strtab_off + strtab.len()].copy_from_slice(&strtab);
        // DT_NEEDED(tag=1, val=0) + DT_NULL
        buf[dyn_off..dyn_off + 8].copy_from_slice(&1i64.to_le_bytes());
        buf[dyn_off + 8..dyn_off + 16].copy_from_slice(&0u64.to_le_bytes());
        buf[symstr_off..symstr_off + symstr.len()].copy_from_slice(&symstr);
        // 符号 1：st_info=0x12（GLOBAL|FUNC），st_name=0 指向 "Java_com_example_Foo_bar"
        buf[sym_off + 24 + 4] = 0x12;

        let write_shdr =
            |buf: &mut Vec<u8>, idx: usize, sh_type: u32, off: u64, size: u64, link: u32| {
                let b = shoff + idx * shentsize;
                buf[b + 4..b + 8].copy_from_slice(&sh_type.to_le_bytes());
                buf[b + 24..b + 32].copy_from_slice(&off.to_le_bytes());
                buf[b + 32..b + 40].copy_from_slice(&size.to_le_bytes());
                buf[b + 40..b + 44].copy_from_slice(&link.to_le_bytes());
            };
        let _ = NULL;
        write_shdr(&mut buf, STR_DYN, 3, strtab_off as u64, strtab.len() as u64, 0);
        write_shdr(&mut buf, DYNAMIC, 6, dyn_off as u64, dyn_size as u64, STR_DYN as u32);
        write_shdr(&mut buf, STR_SYM, 3, symstr_off as u64, symstr.len() as u64, 0);
        write_shdr(&mut buf, DYNSYM, 11, sym_off as u64, sym_size as u64, STR_SYM as u32);
        if with_symtab {
            write_shdr(&mut buf, SYMTAB, 2, sym_off as u64, sym_size as u64, STR_DYN as u32);
        }
        buf
    }

    #[test]
    fn parse_elf64_basic_metadata() {
        let bytes = build_elf64(16384, false);
        let p = parse_elf(&bytes);
        assert_eq!(p.elf_type, 3, "e_type 应为 ET_DYN");
        assert_eq!(p.min_page_size, 16384);
        assert!(p.stripped, "无 SHT_SYMTAB 应判定为已剥离");
    }

    #[test]
    fn parse_elf64_with_symtab_not_stripped() {
        let bytes = build_elf64(4096, true);
        let p = parse_elf(&bytes);
        assert_eq!(p.min_page_size, 4096);
        assert!(!p.stripped);
    }

    #[test]
    fn dt_needed_is_parsed() {
        let bytes = build_elf64(16384, false);
        let p = parse_elf(&bytes);
        assert_eq!(p.needed, vec!["libc.so".to_string()]);
    }

    #[test]
    fn jni_entry_points_filtered_by_prefix() {
        let bytes = build_elf64(16384, false);
        let p = parse_elf(&bytes);
        // 构造的符号名以 Java_ 开头 → 命中；其余（"notjni" 未被符号引用）不入列
        assert_eq!(p.jni_entry_points, vec!["Java_com_example_Foo_bar".to_string()]);
    }

    #[test]
    fn non_elf_degrades() {
        let p = parse_elf(&[0u8; 128]);
        assert_eq!(p.min_page_size, -1);
        assert_eq!(p.elf_type, -1);
        assert!(p.needed.is_empty());
        assert!(!p.stripped, "非 ELF 不应误报为已剥离");
    }

    #[test]
    fn sixteen_kb_verdict() {
        // 页对齐 16KB + zip 对齐未知 → 兼容
        assert!(is_16kb_aligned(16384, 0));
        // 页对齐 16KB + zip 对齐 4KB → 不兼容
        assert!(!is_16kb_aligned(16384, 4096));
        // 页对齐 16KB + zip 对齐 16KB → 兼容
        assert!(is_16kb_aligned(16384, 16384));
        // 页对齐 4KB → 不兼容
        assert!(!is_16kb_aligned(4096, 16384));
        // 解析失败 → 不兼容
        assert!(!is_16kb_aligned(-1, 16384));
    }

    #[test]
    fn abi_filter_semantics() {
        let filter = vec!["arm64-v8a".to_string()];
        assert!(abi_selected("arm64-v8a", Some(&filter)));
        assert!(!abi_selected("x86", Some(&filter)));
        // assets 分组始终保留
        assert!(abi_selected("assets", Some(&filter)));
        // 无过滤全选
        assert!(abi_selected("x86", None));
        assert!(abi_selected("x86", Some(&[])));
    }

    /// 只含 [null, .note.gnu.build-id, .shstrtab] 三个节区的最小 ELF64，
    /// 用于验证"按节名筛 note → 取 build-id"的端到端路径
    fn build_elf64_with_build_id() -> Vec<u8> {
        let shstr = b"\0.shstrtab\0.note.gnu.build-id\0";
        let shstrtab_off = 100usize;
        let shoff = 160usize;
        let shentsize = 64usize;
        let mut buf = vec![0u8; shoff + 3 * shentsize];

        buf[0..4].copy_from_slice(&[0x7F, b'E', b'L', b'F']);
        buf[4] = 2; // ELF64
        buf[5] = 1; // 小端
        buf[6] = 1;
        // e_phoff/e_phnum 保持 0（无程序头）
        buf[0x28..0x30].copy_from_slice(&(shoff as u64).to_le_bytes());
        buf[0x3A..0x3C].copy_from_slice(&(shentsize as u16).to_le_bytes());
        buf[0x3C..0x3E].copy_from_slice(&3u16.to_le_bytes()); // e_shnum
        buf[0x3E..0x40].copy_from_slice(&2u16.to_le_bytes()); // e_shstrndx

        // note 节（offset 64）：namesz=4 descsz=20 type=3 "GNU\0" + 20 字节描述符
        let note_off = 64usize;
        let desc: Vec<u8> = (0..20u8).map(|i| 0xAA + i).collect();
        buf[note_off..note_off + 4].copy_from_slice(&4u32.to_le_bytes());
        buf[note_off + 4..note_off + 8].copy_from_slice(&20u32.to_le_bytes());
        buf[note_off + 8..note_off + 12].copy_from_slice(&3u32.to_le_bytes());
        buf[note_off + 12..note_off + 16].copy_from_slice(b"GNU\0");
        buf[note_off + 16..note_off + 36].copy_from_slice(&desc);
        let note_size = 36usize;

        buf[shstrtab_off..shstrtab_off + shstr.len()].copy_from_slice(shstr);

        let write_shdr =
            |buf: &mut Vec<u8>, idx: usize, name: u32, sh_type: u32, off: u64, size: u64| {
                let b = shoff + idx * shentsize;
                buf[b..b + 4].copy_from_slice(&name.to_le_bytes());
                buf[b + 4..b + 8].copy_from_slice(&sh_type.to_le_bytes());
                buf[b + 24..b + 32].copy_from_slice(&off.to_le_bytes());
                buf[b + 32..b + 40].copy_from_slice(&size.to_le_bytes());
            };
        // 节名表的字符串偏移：1=".shstrtab"，11=".note.gnu.build-id"
        write_shdr(&mut buf, 1, 11, 7, note_off as u64, note_size as u64);
        write_shdr(
            &mut buf,
            2,
            1,
            3,
            shstrtab_off as u64,
            shstr.len() as u64,
        );
        buf
    }

    #[test]
    fn extracts_gnu_build_id_from_note_section() {
        let p = parse_elf(&build_elf64_with_build_id());
        let expected: String = (0..20u8).map(|i| format!("{:02x}", 0xAA + i)).collect();
        assert_eq!(p.build_id, expected);
    }

    #[test]
    fn build_id_absent_when_no_note_section() {
        let p = parse_elf(&build_elf64(4096, false));
        assert!(p.build_id.is_empty());
    }

    #[test]
    fn sha256_is_known_answer() {
        // sha256("abc")
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        // 内容不同 → 指纹必须不同（"同名不同内容"判定依赖这一点）
        assert_ne!(sha256_hex(b"abc"), sha256_hex(b"abd"));
    }
}
