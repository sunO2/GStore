//! `resources.arsc` **浅解析**（只读头 + 字符串池 + 类型表，不逐条解资源）
//!
//! 目的：回答"资源表变了什么"，而不是"哪个资源 id 改了值"（后者见 P2 的资源级 diff）。
//! 可得到：包数与包名、资源类型数与类型名、全局字符串池规模、资源名（key）数量、
//! 类型条目实例数、出现过的**配置维度（语言/地区）**。
//!
//! 结构参考 AOSP `ResourceTypes.h`：
//! - `ResTable_header`（type 0x0002）：headerSize 后接 packageCount
//! - `ResStringPool`（0x0001）：stringCount/styleCount/flags/stringsStart/stylesStart
//! - `ResTable_package`（0x0200）：id + name(128 UTF-16) + typeStrings/keyStrings 偏移
//! - `ResTable_type`（0x0201）：id/flags/entryCount/entriesStart + `ResTable_config`
//! - `ResTable_typeSpec`（0x0202）
//!
//! 解析失败一律降级为"空结果"，绝不影响其余采集（老包/加固包形态各异）。

use serde::Serialize;

/// 类型名/资源名这类短池最多解出的字符串数（防御异常包）
const MAX_POOL_STRINGS: usize = 4096;
/// 配置维度（语言/地区）最多记录数
const MAX_CONFIGS: usize = 256;
/// 资源条目最多记录数（防御超大资源表；超出置 truncated）
const MAX_RESOURCES: usize = 20000;
/// 字符串型资源值的截断长度
const MAX_VALUE_CHARS: usize = 80;

/// 一个资源条目（**默认配置**下的声明）
///
/// 只取默认配置：同一资源在不同语言/密度下会重复出现，
/// 全量落库会让载荷膨胀数倍，而"资源是否增删改"用默认配置即可回答。
#[derive(Clone, Debug, Serialize)]
pub struct ArscResource {
    /// 资源 id：`0xPPTTEEEE`（包 / 类型 / 条目）
    pub id: u32,
    /// 类型名（如 string / drawable）
    pub type_name: String,
    /// 资源名（key 字符串，如 app_name）
    pub key: String,
    /// 值类型标签（string / int / bool / color / reference / map …）
    pub value_kind: String,
    /// 值字面量（字符串截断；其余为数值文本）
    pub value: String,
}

/// `ResTable_config` 中 locale 相对起始的偏移（size 4 + imsi 4）
const LOCALE_OFFSET: usize = 8;

const RES_STRING_POOL: u16 = 0x0001;
const RES_TABLE: u16 = 0x0002;
const RES_TABLE_PACKAGE: u16 = 0x0200;
const RES_TABLE_TYPE: u16 = 0x0201;
const RES_TABLE_TYPE_SPEC: u16 = 0x0202;

/// `resources.arsc` 浅解析结果
#[derive(Clone, Debug, Default, Serialize)]
pub struct ArscInfo {
    /// 是否解析到有效的资源表
    pub parsed: bool,
    /// 包数量
    pub package_count: usize,
    /// 包名（如 `com.example.app`）
    pub package_names: Vec<String>,
    /// 资源类型数量（与 `type_names` 等长）
    pub type_count: usize,
    /// 资源类型名（如 `string` / `drawable` / `mipmap`）
    pub type_names: Vec<String>,
    /// 全局字符串池的字符串数量
    pub global_string_count: usize,
    /// 资源名（key 字符串）数量
    pub key_count: usize,
    /// 类型条目**实例数**（同一资源在不同配置下会重复计数）
    pub entry_instances: usize,
    /// 出现过的配置维度（语言 / 地区，已去重）
    pub configs: Vec<String>,
    /// 默认配置下的资源条目（资源级 diff 的输入）
    pub resources: Vec<ArscResource>,
    /// 资源条目是否因上限被截断
    pub resources_truncated: bool,
}

/// `Res_value.dataType` → 展示标签与字面量
fn render_value(data_type: u8, data: u32, global: &[String]) -> (String, String, bool) {
    // 返回 (kind, value, is_string)
    match data_type {
        0x00 => ("null".into(), "—".into(), false),
        0x01 => ("reference".into(), format!("@{:08x}", data), false),
        0x02 => ("attribute".into(), format!("?{:08x}", data), false),
        0x03 => {
            let s = global.get(data as usize).cloned().unwrap_or_default();
            let truncated: String = s.chars().take(MAX_VALUE_CHARS).collect();
            ("string".into(), truncated, true)
        }
        0x04 => ("float".into(), format!("{data:08x}"), false),
        0x10 => ("int".into(), format!("{data}"), false),
        0x11 => ("hex".into(), format!("0x{data:x}"), false),
        0x12 => (
            "bool".into(),
            if data != 0 { "true" } else { "false" }.into(),
            false,
        ),
        0x1c => ("color".into(), format!("#{:08x}", data), false),
        other => (format!("type_0x{other:02x}"), format!("0x{data:08x}"), false),
    }
}

fn rd_u16(b: &[u8], off: usize) -> Option<u16> {
    Some(u16::from_le_bytes([*b.get(off)?, *b.get(off + 1)?]))
}

fn rd_u32(b: &[u8], off: usize) -> Option<u32> {
    Some(u32::from_le_bytes([
        *b.get(off)?,
        *b.get(off + 1)?,
        *b.get(off + 2)?,
        *b.get(off + 3)?,
    ]))
}

/// chunk 头：type(2) headerSize(2) size(4)
fn chunk_header(b: &[u8], off: usize) -> Option<(u16, usize, usize)> {
    let ty = rd_u16(b, off)?;
    let header = rd_u16(b, off + 2)? as usize;
    let size = rd_u32(b, off + 4)? as usize;
    if header < 8 || size < header {
        return None;
    }
    Some((ty, header, size))
}

/// 解析字符串池；`decode = false` 时只取数量（全局池可能上万条，不必解字面量）
fn read_string_pool(b: &[u8], off: usize, decode: bool) -> Option<(usize, Vec<String>)> {
    let (ty, _header, size) = chunk_header(b, off)?;
    if ty != RES_STRING_POOL {
        return None;
    }
    let count = rd_u32(b, off + 8)? as usize;
    let flags = rd_u32(b, off + 16)?;
    let strings_start = rd_u32(b, off + 20)? as usize;
    if !decode {
        return Some((count, Vec::new()));
    }
    // AOSP ResStringPool：SORTED_FLAG = 1<<0，UTF8_FLAG = **1<<8**（写成 1<<0 会把
    // UTF-8 池当 UTF-16 读，真机表现为类型名/资源名全乱码）
    let utf8 = flags & 0x100 != 0;
    let offsets_base = off + 0x1C;
    let data_base = off.checked_add(strings_start)?;
    let mut out = Vec::new();
    for i in 0..count.min(MAX_POOL_STRINGS) {
        let Some(rel) = rd_u32(b, offsets_base + i * 4) else {
            break;
        };
        let start = match data_base.checked_add(rel as usize) {
            Some(v) => v,
            None => break,
        };
        let Some(s) = read_pool_string(b, start, size, utf8) else {
            continue;
        };
        out.push(s);
    }
    Some((count, out))
}

/// 读一条池内字符串：UTF-8 为 [字节长度][字节][0]；UTF-16 为 [字符数][UTF-16][0]，
/// 长度字段在**高字节为 0 时占 1 字节**，否则占 2 字节（AOSP ResStringPool）
fn read_pool_string(b: &[u8], start: usize, chunk_size: usize, utf8: bool) -> Option<String> {
    let limit = (start + chunk_size).min(b.len());
    let mut p = start;
    let byte_len: usize;
    if utf8 {
        let (chars, n1) = read_var_len(b, p, limit)?;
        let (bytes, n2) = read_var_len(b, p + n1, limit)?;
        let _ = chars;
        p += n1 + n2;
        byte_len = bytes;
        let end = p.checked_add(byte_len)?;
        let slice = b.get(p..end)?;
        return Some(String::from_utf8_lossy(slice).into_owned());
    }
    // UTF-16 池的长度字段是 **u16**（UTF-8 池才是变长编码）——按变长读会整体错位，
    // 真机表现为类型名/资源名乱码（如 "anim" 读成 "愀渀椀洀"）
    let chars = rd_u16(b, p)? as usize;
    p += 2;
    let mut units = Vec::with_capacity(chars.min(limit.saturating_sub(p) / 2));
    for _ in 0..chars {
        let Some(u) = rd_u16(b, p) else {
            break;
        };
        if u == 0 || p + 2 > limit {
            break;
        }
        units.push(u);
        p += 2;
    }
    Some(String::from_utf16_lossy(&units))
}

/// 变长长度：首字节最高位为 0 → 1 字节；否则 2 字节（(hi<<8)|lo）
fn read_var_len(b: &[u8], off: usize, limit: usize) -> Option<(usize, usize)> {
    let first = *b.get(off)?;
    if off + 1 > limit {
        return None;
    }
    if first & 0x80 == 0 {
        Some((first as usize, 1))
    } else {
        let second = *b.get(off + 1)?;
        Some(((((first & 0x7F) as usize) << 8) | second as usize, 2))
    }
}

/// 包名：`ResTable_package.name` 是 128 个 UTF-16 码元（NUL 结尾）
fn read_package_name(b: &[u8], off: usize) -> String {
    let mut units = Vec::new();
    for i in 0..128 {
        let Some(u) = rd_u16(b, off + i * 2) else {
            break;
        };
        if u == 0 {
            break;
        }
        units.push(u);
    }
    String::from_utf16_lossy(&units)
}

/// 配置维度：只取 locale（language[2] / country[2]），空表示默认配置。
///
/// `ResTable_config` 布局：`size(4) + imsi(4) + locale(4)`，
/// 因此 language 在 **config 起始 + 8**（真机实测：用 +0 会读到 size 字节，得到 "@"）
fn read_config_locale(b: &[u8], config_off: usize) -> String {
    let off = config_off + LOCALE_OFFSET;
    let lang = [b.get(off).copied().unwrap_or(0), b.get(off + 1).copied().unwrap_or(0)];
    let country = [
        b.get(off + 2).copied().unwrap_or(0),
        b.get(off + 3).copied().unwrap_or(0),
    ];
    let lang: String = lang.iter().take_while(|c| **c != 0).map(|c| *c as char).collect();
    let country: String = country
        .iter()
        .take_while(|c| **c != 0)
        .map(|c| *c as char)
        .collect();
    match (lang.is_empty(), country.is_empty()) {
        (true, _) => "默认".to_string(),
        (false, true) => lang,
        (false, false) => format!("{lang}-{country}"),
    }
}

/// 解析一个 type chunk 下的资源条目（仅"常规 u32 偏移"布局）
///
/// 条目 id 按 AOSP 规则拼装：`pkgId << 24 | typeId << 16 | entryIndex`。
/// `FLAG_SPARSE` / `FLAG_OFFSET16`（多用于大资源表）本轮跳过——宁可少报也不误报。
#[allow(clippy::too_many_arguments)]
fn collect_type_resources(
    bytes: &[u8],
    chunk_off: usize,
    header_size: usize,
    chunk_size: usize,
    pkg_id: u32,
    type_names: &[String],
    keys: &[String],
    global: &[String],
    out: &mut Vec<ArscResource>,
) {
    const TYPE_FIXED_HEADER: usize = 0x14;
    let type_id = bytes.get(chunk_off + 8).copied().unwrap_or(0);
    let flags = bytes.get(chunk_off + 9).copied().unwrap_or(0);
    let entry_count = rd_u32(bytes, chunk_off + 12).unwrap_or(0) as usize;
    let entries_start = rd_u32(bytes, chunk_off + 16).unwrap_or(0) as usize;
    if flags & 0x03 != 0 || entry_count == 0 {
        return;
    }
    let _ = TYPE_FIXED_HEADER;
    // ResTable_type.id 是 **1-based**，对应 typeStrings 池的 id-1（AOSP getTypeName）
    let type_name = if type_id == 0 {
        String::new()
    } else {
        type_names
            .get(type_id as usize - 1)
            .cloned()
            .unwrap_or_default()
    };
    // ★ 两处基址不同（AOSP ResTable_type）：
    //   偏移表紧跟 chunk 头（`headerSize`），条目数据基址才是 `entriesStart`；
    //   把偏移表也建在 entriesStart 上会读到条目内容（表现为 key 重复、值错乱）。
    let Some(index_base) = chunk_off.checked_add(header_size) else {
        return;
    };
    let Some(entry_base) = chunk_off.checked_add(entries_start) else {
        return;
    };
    let chunk_end = chunk_off.saturating_add(chunk_size);
    for i in 0..entry_count {
        let Some(rel) = rd_u32(bytes, index_base + i * 4) else {
            break;
        };
        if rel == 0xFFFF_FFFF {
            continue;
        }
        let Some(entry_off) = entry_base.checked_add(rel as usize) else {
            continue;
        };
        if entry_off >= chunk_end {
            continue;
        }
        let Some(entry_size) = rd_u16(bytes, entry_off) else {
            continue;
        };
        if entry_size < 8 {
            continue;
        }
        let entry_flags = rd_u16(bytes, entry_off + 2).unwrap_or(0);
        let key_idx = rd_u32(bytes, entry_off + 4).unwrap_or(0) as usize;
        let key = keys.get(key_idx).cloned().unwrap_or_default();
        let (value_kind, value) = if entry_flags & 0x0001 != 0 {
            // FLAG_COMPLEX：map / 数组等，值在后续 ResTable_map 里
            ("map".to_string(), "…".to_string())
        } else {
            let v_off = entry_off + entry_size as usize;
            let data_type = bytes.get(v_off + 3).copied().unwrap_or(0);
            let data = rd_u32(bytes, v_off + 4).unwrap_or(0);
            let (k, v, _) = render_value(data_type, data, global);
            (k, v)
        };
        out.push(ArscResource {
            id: (pkg_id << 24) | ((type_id as u32) << 16) | (i as u32),
            type_name: type_name.clone(),
            key,
            value_kind,
            value,
        });
    }
}

/// 浅解析 `resources.arsc`
pub fn parse_arsc(bytes: &[u8]) -> ArscInfo {
    let mut out = ArscInfo::default();
    let Some((ty, header_size, table_size)) = chunk_header(bytes, 0) else {
        return out;
    };
    if ty != RES_TABLE {
        return out;
    }
    let end = table_size.min(bytes.len());
    out.parsed = true;
    out.package_count = rd_u32(bytes, 8).unwrap_or(0) as usize;

    let mut cursor = header_size;
    let mut configs: Vec<String> = Vec::new();
    let mut global_strings: Vec<String> = Vec::new();
    while cursor + 8 <= end {
        let Some((cty, cheader, csize)) = chunk_header(bytes, cursor) else {
            break;
        };
        if csize == 0 {
            break;
        }
        match cty {
            RES_STRING_POOL => {
                // 全局字符串池：数量 + 字面量（string 型资源值需要）
                if let Some((count, strings)) = read_string_pool(bytes, cursor, true) {
                    out.global_string_count = count;
                    global_strings = strings;
                }
            }
            RES_TABLE_PACKAGE => {
                out.package_names.push(read_package_name(bytes, cursor + 12));
                let type_strings = rd_u32(bytes, cursor + 268).unwrap_or(0) as usize;
                let key_strings = rd_u32(bytes, cursor + 276).unwrap_or(0) as usize;

                // 类型名：包内 typeStrings 池
                let mut type_names_all: Vec<String> = Vec::new();
                if type_strings > 0 {
                    if let Some((count, names)) =
                        read_string_pool(bytes, cursor + type_strings, true)
                    {
                        out.type_count += count.min(names.len());
                        type_names_all = names.clone();
                        out.type_names.extend(names);
                    }
                }
                // 资源名：keyStrings 池（数量 + 字面量，资源级 diff 需要名字）
                let mut key_strings_pool: Vec<String> = Vec::new();
                if key_strings > 0 {
                    if let Some((count, names)) =
                        read_string_pool(bytes, cursor + key_strings, true)
                    {
                        out.key_count += count;
                        key_strings_pool = names;
                    }
                }
                let pkg_id = rd_u32(bytes, cursor + 8).unwrap_or(0) & 0xff;

                // 包内子 chunk：type / typeSpec
                let pkg_end = (cursor + csize).min(end);
                let mut inner = cursor + cheader;
                while inner + 8 <= pkg_end {
                    let Some((ity, _iheader, isize)) = chunk_header(bytes, inner) else {
                        break;
                    };
                    if isize == 0 {
                        break;
                    }
                    if ity == RES_TABLE_TYPE {
                        out.entry_instances += rd_u32(bytes, inner + 12).unwrap_or(0) as usize;
                        // ResTable_config 位于 type chunk 固定头之后（偏移 0x14）。
                        // 注意 headerSize **包含** config 长度，不能用 inner+headerSize。
                        const TYPE_FIXED_HEADER: usize = 0x14;
                        let locale = read_config_locale(bytes, inner + TYPE_FIXED_HEADER);
                        // "默认配置" = 除 size 外的限定符**全为 0**（只判 locale 为空会把
                        // 密度/night 等其它限定符的 chunk 也算进来，产生重复条目）
                        let cfg_off = inner + TYPE_FIXED_HEADER;
                        let cfg_size = rd_u32(bytes, cfg_off).unwrap_or(0) as usize;
                        let is_default = cfg_size >= 4
                            && cfg_off + cfg_size <= bytes.len()
                            && bytes[cfg_off + 4..cfg_off + cfg_size]
                                .iter()
                                .all(|b| *b == 0);
                        if configs.len() < MAX_CONFIGS && !configs.contains(&locale) {
                            configs.push(locale);
                        }
                        // 资源级清单：只取**默认配置**（语言/地区为空），避免同资源多配置重复
                        if is_default {
                            if out.resources.len() >= MAX_RESOURCES {
                                out.resources_truncated = true;
                            } else {
                                collect_type_resources(
                                    bytes,
                                    inner,
                                    _iheader,
                                    isize,
                                    pkg_id,
                                    &type_names_all,
                                    &key_strings_pool,
                                    &global_strings,
                                    &mut out.resources,
                                );
                            }
                        }
                    } else if ity != RES_TABLE_TYPE_SPEC {
                        // 其余子 chunk（如 overlayable）跳过
                    }
                    inner += isize;
                }
            }
            _ => {}
        }
        cursor += csize;
    }

    out.type_count = out.type_names.len();
    out.configs = configs;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── 字符串池构造器（UTF-8 池；`utf16` 时改用 UTF-16 池） ──
    fn pool_with(strings: &[&str], utf16: bool) -> Vec<u8> {
        let mut data: Vec<u8> = Vec::new();
        let mut offsets: Vec<u32> = Vec::new();
        for s in strings {
            offsets.push(data.len() as u32);
            if utf16 {
                // UTF-16 池：长度是 **u16** + UTF-16 码元 + NUL
                let units: Vec<u16> = s.encode_utf16().collect();
                data.extend_from_slice(&(units.len() as u16).to_le_bytes());
                for u in units {
                    data.extend_from_slice(&u.to_le_bytes());
                }
                data.extend_from_slice(&0u16.to_le_bytes());
            } else {
                let bytes = s.as_bytes();
                data.push(bytes.len() as u8);
                data.push(bytes.len() as u8);
                data.extend_from_slice(bytes);
                data.push(0);
            }
        }
        let header_size = 0x1Cusize;
        let strings_start = header_size + offsets.len() * 4;
        let total = strings_start + data.len();
        let mut buf = vec![0u8; total];
        buf[0..2].copy_from_slice(&RES_STRING_POOL.to_le_bytes());
        buf[2..4].copy_from_slice(&(header_size as u16).to_le_bytes());
        buf[4..8].copy_from_slice(&(total as u32).to_le_bytes());
        buf[8..12].copy_from_slice(&(strings.len() as u32).to_le_bytes()); // stringCount
        // flags：UTF8_FLAG = 1<<8（与 AOSP/真实 arsc 一致）
        buf[16..20].copy_from_slice(
            &(if utf16 { 0u32 } else { 0x100u32 }).to_le_bytes(),
        );
        buf[20..24].copy_from_slice(&(strings_start as u32).to_le_bytes());
        for (i, o) in offsets.iter().enumerate() {
            buf[header_size + i * 4..header_size + i * 4 + 4].copy_from_slice(&o.to_le_bytes());
        }
        buf[strings_start..].copy_from_slice(&data);
        buf
    }

    fn pool(strings: &[&str]) -> Vec<u8> {
        pool_with(strings, false)
    }

    /// 构造一个最小 `resources.arsc`：
    /// 表头 + 全局字符串池(2 条) + 包(typeStrings=[string]、keyStrings=[app_name]) + 一个 type chunk(zh-CN, 3 条)
    fn build_arsc() -> Vec<u8> {
        build_arsc_with_locale(b"zh", b"CN")
    }

    /// 可指定 locale 的构造器：`\0\0` 表示默认配置
    fn build_arsc_with_locale(lang: &[u8; 2], country: &[u8; 2]) -> Vec<u8> {
        let global = pool(&["hello", "world"]);
        let type_strings = pool(&["string"]);
        let key_strings = pool(&["app_name"]);

        // ── 包内 type chunk（含 zh-CN 配置 + 1 条真实条目，其余 2 个槽位为空） ──
        let type_header = 0x14usize + 0x40; // config 区按 0x40 留足
        // ★ 与真实 arsc 一致：偏移表紧跟 chunk 头（headerSize），
        //   条目数据基址（entriesStart）在偏移表之后 —— 两者**不相等**
        let index_base = type_header;
        let entries_start = type_header + 3 * 4;
        let entry_rel = 0usize; // 首条条目数据就在 entriesStart 处
        let entry_off = entries_start + entry_rel;
        let chunk_size = entry_off + 16; // entry(8) + Res_value(8)
        let mut type_chunk = vec![0u8; chunk_size];
        type_chunk[0..2].copy_from_slice(&RES_TABLE_TYPE.to_le_bytes());
        type_chunk[2..4].copy_from_slice(&(type_header as u16).to_le_bytes());
        type_chunk[4..8].copy_from_slice(&(chunk_size as u32).to_le_bytes());
        type_chunk[8] = 1; // id → type_names[1] = "string"
        type_chunk[12..16].copy_from_slice(&3u32.to_le_bytes()); // entryCount
        type_chunk[16..20].copy_from_slice(&(entries_start as u32).to_le_bytes());
        // config.locale：language="zh" country="CN"
        let cfg_base = 0x14usize; // ResTable_config 起始
        type_chunk[cfg_base..cfg_base + 4]
            .copy_from_slice(&0x40u32.to_le_bytes()); // config.size
        let cfg = cfg_base + LOCALE_OFFSET; // config 起始 + locale 偏移
        type_chunk[cfg + 0..cfg + 2].copy_from_slice(lang);
        type_chunk[cfg + 2..cfg + 4].copy_from_slice(country);
        // 偏移表：第 0 条有数据，第 1/2 条为 NO_ENTRY
        type_chunk[index_base..index_base + 4]
            .copy_from_slice(&(entry_rel as u32).to_le_bytes());
        type_chunk[index_base + 4..index_base + 8]
            .copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
        type_chunk[index_base + 8..index_base + 12]
            .copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
        // ResTable_entry：size=8 flags=0 key_idx=0
        type_chunk[entry_off..entry_off + 2].copy_from_slice(&8u16.to_le_bytes());
        // Res_value：size=8 res0=0 dataType=0x03(STRING) data=0 → 全局池 0 号
        type_chunk[entry_off + 8..entry_off + 10].copy_from_slice(&8u16.to_le_bytes());
        type_chunk[entry_off + 11] = 0x03;

        // ── 包 chunk ──
        let pkg_header = 0x120usize;
        let type_strings_off = pkg_header;
        let key_strings_off = type_strings_off + type_strings.len();
        let inner_off = key_strings_off + key_strings.len();
        let pkg_size = inner_off + type_chunk.len();

        let mut pkg = vec![0u8; pkg_size];
        pkg[0..2].copy_from_slice(&RES_TABLE_PACKAGE.to_le_bytes());
        pkg[2..4].copy_from_slice(&(pkg_header as u16).to_le_bytes());
        pkg[4..8].copy_from_slice(&(pkg_size as u32).to_le_bytes());
        pkg[8..12].copy_from_slice(&0x7Fu32.to_le_bytes()); // package id
        for (i, u) in "com.test".encode_utf16().enumerate() {
            pkg[12 + i * 2..12 + i * 2 + 2].copy_from_slice(&u.to_le_bytes());
        }
        pkg[268..272].copy_from_slice(&(type_strings_off as u32).to_le_bytes());
        pkg[276..280].copy_from_slice(&(key_strings_off as u32).to_le_bytes());
        pkg[type_strings_off..type_strings_off + type_strings.len()]
            .copy_from_slice(&type_strings);
        pkg[key_strings_off..key_strings_off + key_strings.len()].copy_from_slice(&key_strings);
        pkg[inner_off..].copy_from_slice(&type_chunk);

        // ── 表头 ──
        let table_header = 12usize;
        let mut table = vec![0u8; table_header];
        table[0..2].copy_from_slice(&RES_TABLE.to_le_bytes());
        table[2..4].copy_from_slice(&(table_header as u16).to_le_bytes());
        let total = table_header + global.len() + pkg.len();
        table[4..8].copy_from_slice(&(total as u32).to_le_bytes());
        table[8..12].copy_from_slice(&1u32.to_le_bytes()); // packageCount

        let mut out = table;
        out.extend_from_slice(&global);
        out.extend_from_slice(&pkg);
        out.truncate(total);
        out
    }

    #[test]
    fn parses_packages_types_and_locales() {
        let info = parse_arsc(&build_arsc());
        assert!(info.parsed);
        assert_eq!(info.package_count, 1);
        assert_eq!(info.package_names, vec!["com.test"]);
        assert_eq!(info.type_count, 1);
        assert_eq!(info.type_names, vec!["string"]);
        assert_eq!(info.global_string_count, 2);
        assert_eq!(info.key_count, 1);
        assert_eq!(info.entry_instances, 3);
        assert_eq!(info.configs, vec!["zh-CN"]);
    }

    #[test]
    fn decodes_utf16_pool_strings_with_u16_length() {
        // 真机里 typeStrings 常是 UTF-16 池：长度字段为 u16（不是变长编码）
        let bytes = pool_with(&["anim", "string"], true);
        let (count, names) = read_string_pool(&bytes, 0, true).unwrap();
        assert_eq!(count, 2);
        assert_eq!(names, vec!["anim", "string"]);
    }

    #[test]
    fn rejects_non_arsc_and_degrades() {
        assert!(!parse_arsc(b"").parsed);
        assert!(!parse_arsc(b"not an arsc at all").parsed);
        // 截断的表：不 panic，尽力解析
        let full = build_arsc();
        let info = parse_arsc(&full[..full.len() / 2]);
        assert!(info.package_count <= 1);
    }

    #[test]
    fn collects_default_config_resources() {
        let info = parse_arsc(&build_arsc_with_locale(b"\0\0", b"\0\0"));
        assert_eq!(info.resources.len(), 1, "只有第 0 条槽位有数据");
        let r = &info.resources[0];
        assert_eq!(r.id, (0x7fu32 << 24) | (1 << 16));
        assert_eq!(r.type_name, "string");
        assert_eq!(r.key, "app_name");
        assert_eq!(r.value_kind, "string");
        assert_eq!(r.value, "hello");
        assert!(!info.resources_truncated);
    }

    #[test]
    fn non_default_config_only_counts_locale() {
        // 非默认配置（zh-CN）的条目**不进入**资源级清单（避免同资源按语言重复），
        // 但语言仍要被记录，供"新增/移除语言"对比
        let info = parse_arsc(&build_arsc());
        assert_eq!(info.configs, vec!["zh-CN"]);
        assert!(info.resources.is_empty());
        // 默认配置才收集资源
        let default_info = parse_arsc(&build_arsc_with_locale(b"\0\0", b"\0\0"));
        assert_eq!(default_info.resources.len(), 1);
        assert_eq!(default_info.configs, vec!["默认"]);
    }

    #[test]
    fn reads_utf16_pool_strings() {
        // language="zh" country="TW" → "zh-TW"
        let mut arsc = build_arsc();
        let idx = arsc.windows(2).position(|w| w == b"CN").unwrap();
        arsc[idx..idx + 2].copy_from_slice(b"TW");
        assert_eq!(parse_arsc(&arsc).configs, vec!["zh-TW"]);
    }

}
