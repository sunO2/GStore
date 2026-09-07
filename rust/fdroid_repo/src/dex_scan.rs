//! DEX 类名扫描（LibChecker DEX 规则检测的 Rust 实现）
//!
//! 输入：APK 路径 + 模式列表（LibChecker `matchesClassPattern` 语义：
//! 以 `*` 结尾 → 前缀匹配 [`pattern` 去掉 `*`]，否则整串精确匹配）。
//! 输出：APK 内所有 class_defs 中以点分形式（`androidx.lifecycle.LiveData`）
//! 命中的类名集合。
//!
//! 与 LibChecker StreamingDexClassScanner 的对齐说明：
//! - 同样只读 class_defs → type_ids → string_ids 三个标识表，不解析指令；
//! - 差异：LibChecker 在描述符形式（`L...;`）上匹配，本实现把规则（点分、
//!   rules_db 中 DEX 规则 name 列的原始格式）与类名统一转点分形式后匹配，
//!   语义等价（`com.foo.bar` ⇔ `Lcom/foo/bar;`，仅分隔符不同）。

use std::collections::HashSet;
use std::fs::File;
use std::io::Read;

use zip::ZipArchive;

const DEX_HEADER_SIZE: usize = 0x70;
const DEX_CONTAINER_HEADER_SIZE: usize = 0x78;
const STRING_ITEM_SIZE: usize = 4; // string_ids 项大小：string_data_off（uint）
const TYPE_ITEM_SIZE: usize = 4; // type_ids 项大小：descriptor_idx（uint）
const CLASS_DEF_ITEM_SIZE: usize = 32; // class_def 项大小

const MAGIC_BYTES: &[u8] = b"dex\n";

/// 顶层入口：扫描 APK 所有 classes*.dex，返回命中的点分类名。
pub fn scan_dex_classes(apk_path: &str, patterns: &[String]) -> Result<Vec<String>, String> {
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive =
        ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;

    let mut matched: HashSet<String> = HashSet::new();
    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|e| format!("读取 zip 条目失败: {e}"))?;
        if !is_dex_entry(entry.name()) {
            continue;
        }
        let mut bytes = Vec::with_capacity(entry.size() as usize);
        entry
            .read_to_end(&mut bytes)
            .map_err(|e| format!("读取 {} 失败: {e}", entry.name()))?;
        // 单个 dex 解析失败只跳过该文件，不中断整体扫描
        if let Err(e) = scan_dex_bytes(&bytes, patterns, &mut matched) {
            log::warn!("DEX 扫描跳过 {}: {}", entry.name(), e);
        }
    }

    let mut result: Vec<String> = matched.into_iter().collect();
    result.sort();
    Ok(result)
}

/// zip 条目名形如 classes.dex / classes2.dex / classes10.dex
fn is_dex_entry(name: &str) -> bool {
    let Some(rest) = name.strip_suffix(".dex") else {
        return false;
    };
    let Some(mid) = rest.strip_prefix("classes") else {
        return false;
    };
    mid.is_empty() || mid.bytes().all(|b| b.is_ascii_digit())
}

fn read_u32_at(buf: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        buf[offset],
        buf[offset + 1],
        buf[offset + 2],
        buf[offset + 3],
    ])
}

/// 解析单个 dex 的 class_defs，把命中的类名（点分形式）塞入 matched。
fn scan_dex_bytes(
    dex: &[u8],
    patterns: &[String],
    matched: &mut HashSet<String>,
) -> Result<(), String> {
    if dex.len() < DEX_HEADER_SIZE {
        return Err("DEX 文件过小".into());
    }
    if dex.get(0..4) != Some(MAGIC_BYTES) || dex[7] != 0 {
        return Err("不是合法 DEX 头".into());
    }
    let version = parse_version(&dex[4..7])?;
    // dex 041：容器头多 8 字节（0x78），data 上限取容器大小
    let is_container = version == 41;
    let header_size = if is_container {
        DEX_CONTAINER_HEADER_SIZE
    } else {
        DEX_HEADER_SIZE
    };
    if dex.len() < header_size {
        return Err("DEX 头长度不足".into());
    }
    let file_size = read_u32_at(dex, 0x20) as usize;
    let data_limit = if is_container {
        read_u32_at(dex, 0x70) as usize
    } else {
        file_size
    };
    if dex.len() < data_limit.min(dex.len()) {
        return Err("DEX 数据超界".into());
    }

    let string_ids_size = read_u32_at(dex, 0x38) as usize;
    let string_ids_off = read_u32_at(dex, 0x3c) as usize;
    let type_ids_size = read_u32_at(dex, 0x40) as usize;
    let type_ids_off = read_u32_at(dex, 0x44) as usize;
    let class_defs_size = read_u32_at(dex, 0x60) as usize;
    let class_defs_off = read_u32_at(dex, 0x64) as usize;

    if class_defs_size == 0 {
        return Ok(());
    }

    // 三张表都应在 [header_size, data_limit) 内且不越界
    let si_end = addr_checked(
        string_ids_off,
        string_ids_size.checked_mul(STRING_ITEM_SIZE).ok_or("表大小溢出")?,
    )?;
    let ti_end = addr_checked(
        type_ids_off,
        type_ids_size.checked_mul(TYPE_ITEM_SIZE).ok_or("表大小溢出")?,
    )?;
    let cd_end = addr_checked(
        class_defs_off,
        class_defs_size.checked_mul(CLASS_DEF_ITEM_SIZE).ok_or("表大小溢出")?,
    )?;
    for end in [si_end, ti_end, cd_end] {
        if !(header_size..=data_limit).contains(&end) {
            return Err("DEX 标识表越界".into());
        }
    }

    // string_ids：每个条目是 string_data_off（uint）
    let mut string_offsets = Vec::with_capacity(string_ids_size);
    for i in 0..string_ids_size {
        string_offsets.push(read_u32_at(dex, string_ids_off + i * STRING_ITEM_SIZE) as usize);
    }
    // type_ids：每个条目是 descriptor 的 string_id 索引
    let mut descriptor_indexes = Vec::with_capacity(type_ids_size);
    for i in 0..type_ids_size {
        descriptor_indexes.push(read_u32_at(dex, type_ids_off + i * TYPE_ITEM_SIZE) as usize);
    }
    // class_defs：每项 32 字节，首字段 class_idx（type_id 索引）
    let mut descriptor_offsets = Vec::with_capacity(class_defs_size);
    for i in 0..class_defs_size {
        let class_idx = read_u32_at(dex, class_defs_off + i * CLASS_DEF_ITEM_SIZE) as usize;
        let Some(&descriptor_idx) = descriptor_indexes.get(class_idx) else {
            continue;
        };
        let Some(&string_off) = string_offsets.get(descriptor_idx) else {
            continue;
        };
        descriptor_offsets.push(string_off);
    }
    descriptor_offsets.sort_unstable();
    descriptor_offsets.dedup();

    for offset in descriptor_offsets {
        let Some(desc) = read_string(dex, offset) else {
            continue;
        };
        let Some(class_name) = descriptor_to_class_name(&desc) else {
            continue;
        };
        if patterns.iter().any(|p| pattern_matches(&class_name, p)) {
            matched.insert(class_name);
        }
    }
    Ok(())
}

fn parse_version(bytes: &[u8]) -> Result<u32, String> {
    if bytes.len() != 3 || !bytes.iter().all(|b| b.is_ascii_digit()) {
        return Err("非法的 DEX 版本号".into());
    }
    Ok((bytes[0] - b'0') as u32 * 100 + (bytes[1] - b'0') as u32 * 10 + (bytes[2] - b'0') as u32)
}

fn addr_checked(base: usize, len: usize) -> Result<usize, String> {
    base.checked_add(len).ok_or("地址溢出".into())
}

/// 从 dex 偏移读出 MUTF-8 字符串（跳过 ULEB128 的 string_data_size，读到 \0）。
fn read_string(dex: &[u8], offset: usize) -> Option<Vec<u8>> {
    // ULEB128：utf16_size
    let mut pos = offset;
    for _ in 0..5 {
        let byte = *dex.get(pos)?;
        pos += 1;
        if byte & 0x80 == 0 {
            break;
        }
    }
    let start = pos;
    while *dex.get(pos)? != 0 {
        pos += 1;
    }
    Some(dex[start..pos].to_vec())
}

/// 描述符 `Landroidx/lifecycle/LiveData;` → 点分类名 `androidx.lifecycle.LiveData`。
/// 数组类型（`[L...;`）等非类描述符返回 None。
fn descriptor_to_class_name(desc: &[u8]) -> Option<String> {
    if desc.first() != Some(&b'L') || desc.last() != Some(&b';') {
        return None;
    }
    let inner = &desc[1..desc.len() - 1];
    let lossy = String::from_utf8_lossy(inner);
    Some(lossy.replace('/', "."))
}

/// LibChecker matchesClassPattern 语义（点分形式）：
/// 模式以 `*` 结尾 → 类名以 `模式去掉 *` 开头；否则整串相等。
fn pattern_matches(class_name: &str, pattern: &str) -> bool {
    if let Some(prefix) = pattern.strip_suffix('*') {
        class_name.starts_with(prefix)
    } else {
        class_name == pattern
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_conversion() {
        assert_eq!(
            descriptor_to_class_name(b"Landroidx/lifecycle/LiveData;"),
            Some("androidx.lifecycle.LiveData".to_string())
        );
        assert_eq!(descriptor_to_class_name(b"[Lcom/foo/Bar;"), None);
        assert_eq!(descriptor_to_class_name(b"Ljava/lang/String;"), Some("java.lang.String".to_string()));
    }

    #[test]
    fn dex_entry_match() {
        assert!(is_dex_entry("classes.dex"));
        assert!(is_dex_entry("classes2.dex"));
        assert!(is_dex_entry("classes10.dex"));
        assert!(!is_dex_entry("classes.dex.part"));
        assert!(!is_dex_entry("AndroidManifest.xml"));
        assert!(!is_dex_entry("classesx.dex"));
    }

    #[test]
    fn pattern_semantics() {
        assert!(pattern_matches("androidx.lifecycle.LiveData", "androidx.lifecycle.*"));
        assert!(!pattern_matches("androidx.lifecycle.LiveData", "androidx.core.*"));
        assert!(pattern_matches("com.foo.Bar", "com.foo.Bar"));
        assert!(!pattern_matches("com.foo.BarBaz", "com.foo.Bar"));
    }
}