//! APK 内容浏览器：按层枚举条目 + 按需导出单条内容
//!
//! 架构裁决见 `document/development/11-APK文件浏览器.md`：
//! **Rust 是 APK 内容的唯一出口**——解压、嵌套容器、zip64、安全上限都在这一层收口；
//! 宿主只拿「文件路径 + 元数据」，原始字节不跨 FFI 边界回传（大文件落缓存文件）。
//!
//! 两条 method（见 `lib.rs` 分发表）：
//! - `browse_apk_entries`：列一层（合成目录树 + 条目分类），不递归展开
//! - `export_apk_entry`：把某条内容解压到宿主指定的文件

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Cursor, Read, Seek, Write};

use serde::Serialize;
use zip::ZipArchive;

/// 嵌套容器链分隔符（如 `assets/pack.zip<SEP>res/a.json`）
///
/// 用控制字符而非 `!`：APK 内文件名实践中不会含 `\u{1}`，
/// 从而不会与「条目名里真有感叹号」互相歧义。
pub const CHAIN_SEP: char = '\u{1}';

/// 嵌套深度上限（防递归炸弹）
const MAX_NESTING: usize = 4;
/// 内层容器（zip 家族）解压上限
const MAX_NESTED_BYTES: u64 = 64 * 1024 * 1024;
/// 单条导出上限
const MAX_EXPORT_BYTES: u64 = 1024 * 1024 * 1024;
/// 单次列目录返回上限（超出由 UI 提示用搜索收窄）
const MAX_LIST_ENTRIES: usize = 5000;

/// 一条可浏览条目
#[derive(Clone, Debug, Serialize)]
pub struct BrowseEntry {
    /// 当前容器内的完整路径（如 `assets/models/x.tflite`）
    pub path: String,
    /// 末段名（如 `x.tflite`）
    pub name: String,
    /// 目录（合成节点：zip 未显式存储目录，由条目名前缀推导）
    pub is_dir: bool,
    /// 解压后字节数（目录为后代累计）
    pub size: u64,
    /// 压缩后字节数（目录为 0）
    pub compressed_size: u64,
    /// 条目 CRC32（目录为 0）
    pub crc32: u32,
    /// 是否以 STORED（不压缩）存放
    pub stored: bool,
    /// 类型标签：dir/zip/apk/jar/dex/so/image/text/json/font/cert/video/audio/binary…
    ///
    /// `cert` 覆盖证书与密钥库扩展名：PEM/DER 证书（`pem`/`der`/`crt`/`cer`）、
    /// PKCS#7（`p7b`/`p7c`/`p7s`）以及 keystore 容器
    /// （`p12`/`pfx`/`jks`/`bks`/`keystore`/`jceks`）。
    pub kind: String,
    /// 是否可进入（仅 zip 家族）
    pub browsable: bool,
    /// ZIP 条目修改时间（DOS 时间，`YYYY-MM-DD HH:MM:SS`，无时区，2 秒精度）；
    /// 未设置 / 非法 → `None`
    pub modified: Option<String>,
    /// 创建时间：来自 extra 时间戳（UT `0x5455` ctime 或 NTFS `0x000A` ctime）；
    /// 缺失 → `None`
    pub created: Option<String>,
    /// 访问时间：来自 extra 时间戳（UT `0x5455` atime 或 NTFS `0x000A` atime）；
    /// 缺失 → `None`
    pub accessed: Option<String>,
    /// 原始 unix 权限位（`ZipFile::unix_mode()`）；缺失 → `None`
    pub unix_mode: Option<u32>,
    /// 是否加密（`ZipFile::encrypted()`）
    pub encrypted: bool,
    /// 压缩方式（`stored` / `deflate` / …；目录为空串）
    pub compression: String,
}

/// 一层目录的列举结果
#[derive(Clone, Debug, Serialize)]
pub struct BrowseListing {
    /// 当前容器（空串 = APK 根；否则为嵌套容器链，`\u{1}` 分隔）
    pub container: String,
    /// 当前目录前缀（容器内）
    pub dir: String,
    /// 上一级目录（容器根为 ""）
    pub parent_dir: String,
    /// 是否还能往上层走（容器根 + 未嵌套时为 false）
    pub can_go_up: bool,
    /// 条目（先目录后文件，各自按名升序）
    pub entries: Vec<BrowseEntry>,
    /// 容器内条目总数（含未展示的）
    pub total_files: usize,
    /// 当前容器的字节数（APK 为文件大小；嵌套为解压后大小）
    pub container_size: u64,
    /// 是否因超过上限被截断
    pub truncated: bool,
}

/// 导出结果
#[derive(Clone, Debug, Serialize)]
pub struct ExportedEntry {
    /// 容器内路径
    pub path: String,
    /// 实际写出字节数
    pub size: u64,
    /// 条目 CRC32（宿主可据此校验）
    pub crc32: u32,
    /// 落地文件路径
    pub out_path: String,
}

/// 可读可定位（统一 APK 文件与嵌套内存容器）
trait ReadSeek: Read + Seek {}
impl<T: Read + Seek> ReadSeek for T {}

/// 把 `\u{1}` 分隔的容器链拆成段
pub fn split_chain(chain: &str) -> Vec<String> {
    if chain.is_empty() {
        return Vec::new();
    }
    chain
        .split(CHAIN_SEP)
        .map(|s| s.to_string())
        .collect()
}

/// 打开目标容器（APK 根或某层嵌套 zip），返回 (archive, 容器字节数)
fn open_container(
    apk_path: &str,
    chain: &[String],
) -> Result<(ZipArchive<Box<dyn ReadSeek>>, u64), String> {
    if chain.len() > MAX_NESTING {
        return Err(format!("嵌套层级过深（上限 {MAX_NESTING} 层）"));
    }
    if chain.is_empty() {
        let len = std::fs::metadata(apk_path)
            .map_err(|e| format!("无法读取 APK 信息: {e}"))?
            .len();
        let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
        let archive = ZipArchive::new(Box::new(file) as Box<dyn ReadSeek>)
            .map_err(|e| format!("APK 不是有效 zip: {e}"))?;
        return Ok((archive, len));
    }

    let mut bytes = read_apk_entry(apk_path, &chain[0])?;
    for seg in &chain[1..] {
        bytes = read_zip_entry(&bytes, seg)?;
    }
    let size = bytes.len() as u64;
    let archive = ZipArchive::new(Box::new(Cursor::new(bytes)) as Box<dyn ReadSeek>)
        .map_err(|e| format!("内层容器不是有效 zip: {e}"))?;
    Ok((archive, size))
}

/// 从 APK 读取单条内容（用于进入嵌套容器）
fn read_apk_entry(apk_path: &str, name: &str) -> Result<Vec<u8>, String> {
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;
    let mut entry = archive
        .by_name(name)
        .map_err(|_| format!("容器不存在: {name}"))?;
    if entry.size() > MAX_NESTED_BYTES {
        return Err(format!("内层容器过大（{} 字节），超过上限", entry.size()));
    }
    let mut buf = Vec::new();
    entry
        .read_to_end(&mut buf)
        .map_err(|e| format!("读取 {name} 失败: {e}"))?;
    Ok(buf)
}

/// 从内存中的 zip 读取单条内容（嵌套层间跳转）
fn read_zip_entry(bytes: &[u8], name: &str) -> Result<Vec<u8>, String> {
    let mut archive =
        ZipArchive::new(Cursor::new(bytes.to_vec())).map_err(|e| format!("内层容器损坏: {e}"))?;
    let mut entry = archive
        .by_name(name)
        .map_err(|_| format!("内层容器不存在: {name}"))?;
    if entry.size() > MAX_NESTED_BYTES {
        return Err(format!("内层容器过大（{} 字节），超过上限", entry.size()));
    }
    let mut buf = Vec::new();
    entry
        .read_to_end(&mut buf)
        .map_err(|e| format!("读取 {name} 失败: {e}"))?;
    Ok(buf)
}

/// 列一层目录：条目树由「条目名前缀」合成，**不递归**展开嵌套容器
pub fn browse_entries(
    apk_path: &str,
    chain_text: &str,
    dir: &str,
) -> Result<BrowseListing, String> {
    let chain = split_chain(chain_text);
    let normalized = dir.trim_matches('/');
    let prefix = if normalized.is_empty() {
        String::new()
    } else {
        format!("{normalized}/")
    };

    let (mut archive, container_size) = open_container(apk_path, &chain)?;
    let total_files = archive.len();

    let mut dir_sizes: BTreeMap<String, u64> = BTreeMap::new();
    let mut files: Vec<BrowseEntry> = Vec::new();
    let mut truncated = false;

    for index in 0..total_files {
        // 单个条目元信息失败只跳过它，不中断整层列举
        let Ok(entry) = archive.by_index(index) else {
            continue;
        };
        let path = entry.name().to_string();
        let size = entry.size();
        let compressed_size = entry.compressed_size();
        let crc32 = entry.crc32();
        let stored = entry.compression() == zip::CompressionMethod::Stored;
        // ZIP 条目元数据（缺失字段 → None/缺省）；extra 引用须在 drop(entry) 前用完
        let (modified, created, accessed, unix_mode, encrypted, compression) = {
            let extra: Vec<&zip::ExtraField> = entry.extra_data_fields().collect();
            (
                entry.last_modified().and_then(|dt| format_zip_datetime(&dt)),
                extra_created(&extra),
                extra_accessed(&extra),
                entry.unix_mode(),
                entry.encrypted(),
                entry.compression().to_string().to_ascii_lowercase(),
            )
        };
        drop(entry);

        let Some(rest) = path.strip_prefix(prefix.as_str()) else {
            continue;
        };
        if rest.is_empty() {
            continue;
        }

        match rest.find('/') {
            // 还有下一级 → 计入最近的子目录（累加后代体积）
            Some(slash) => {
                let sub = rest[..slash].to_string();
                *dir_sizes.entry(sub).or_insert(0) += size;
            }
            None => {
                let kind = classify(&path);
                files.push(BrowseEntry {
                    path: path.clone(),
                    name: rest.to_string(),
                    is_dir: false,
                    size,
                    compressed_size,
                    crc32,
                    stored,
                    browsable: is_browsable(&kind),
                    kind: kind.to_string(),
                    modified,
                    created,
                    accessed,
                    unix_mode,
                    encrypted,
                    compression,
                });
                if files.len() + dir_sizes.len() >= MAX_LIST_ENTRIES {
                    truncated = true;
                    break;
                }
            }
        }
    }

    files.sort_by(|a, b| a.name.cmp(&b.name));

    let mut entries: Vec<BrowseEntry> = dir_sizes
        .into_iter()
        .map(|(name, size)| BrowseEntry {
            path: format!("{prefix}{name}"),
            name,
            is_dir: true,
            size,
            compressed_size: 0,
            crc32: 0,
            stored: false,
            kind: "dir".to_string(),
            browsable: false,
            modified: None,
            created: None,
            accessed: None,
            unix_mode: None,
            encrypted: false,
            compression: String::new(),
        })
        .collect();
    if entries.len() + files.len() > MAX_LIST_ENTRIES {
        entries.truncate(MAX_LIST_ENTRIES.saturating_sub(files.len()));
        truncated = true;
    }
    entries.extend(files);

    let parent_dir = match normalized.rfind('/') {
        Some(pos) => normalized[..pos].to_string(),
        None => String::new(),
    };

    Ok(BrowseListing {
        container: chain_text.to_string(),
        dir: normalized.to_string(),
        parent_dir,
        can_go_up: !(normalized.is_empty() && chain.is_empty()),
        entries,
        total_files,
        container_size,
        truncated,
    })
}

/// 导出单条内容到调用方指定的文件（不按条目名落盘 → 不构成 zip slip）
pub fn export_entry(
    apk_path: &str,
    chain_text: &str,
    entry_path: &str,
    out_path: &str,
) -> Result<ExportedEntry, String> {
    if entry_path.is_empty() {
        return Err("缺少条目路径".to_string());
    }
    if out_path.is_empty() {
        return Err("缺少输出路径".to_string());
    }
    let chain = split_chain(chain_text);
    let (mut archive, _) = open_container(apk_path, &chain)?;

    let (size, crc32, is_dir) = {
        let entry = archive
            .by_name(entry_path)
            .map_err(|_| format!("条目不存在: {entry_path}"))?;
        (entry.size(), entry.crc32(), entry.is_dir())
    };
    if is_dir {
        return Err(format!("目标是目录，无法导出: {entry_path}"));
    }
    if size > MAX_EXPORT_BYTES {
        return Err(format!("条目过大（{size} 字节），超过导出上限"));
    }

    let mut buf = Vec::new();
    {
        let mut entry = archive
            .by_name(entry_path)
            .map_err(|_| format!("条目不存在: {entry_path}"))?;
        entry
            .read_to_end(&mut buf)
            .map_err(|e| format!("读取 {entry_path} 失败: {e}"))?;
    }

    if let Some(parent) = std::path::Path::new(out_path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建输出目录失败: {e}"))?;
    }
    let mut file = File::create(out_path).map_err(|e| format!("创建输出文件失败: {e}"))?;
    file.write_all(&buf)
        .map_err(|e| format!("写出文件失败: {e}"))?;

    Ok(ExportedEntry {
        path: entry_path.to_string(),
        size: buf.len() as u64,
        crc32,
        out_path: out_path.to_string(),
    })
}

/// zip 家族：可进入下一层
fn is_browsable(kind: &str) -> bool {
    matches!(kind, "zip" | "apk" | "jar" | "aar")
}

/// zip DOS 时间 → `YYYY-MM-DD HH:MM:SS`（无时区，2 秒精度）；非法值返回 None。
///
/// zip 中央目录里的 DOS 时间字段可能未设置（月/日为 0），故显式校验。
fn format_zip_datetime(dt: &zip::DateTime) -> Option<String> {
    let (year, month, day) = (dt.year(), dt.month(), dt.day());
    let (hour, minute, second) = (dt.hour(), dt.minute(), dt.second());
    if month == 0 || month > 12 || day == 0 || day > 31 || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    Some(format!(
        "{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02}"
    ))
}

/// Unix 纪元秒 → `YYYY-MM-DD HH:MM:SS`（UTC，无时区）；负值返回 None。
///
/// 不能依赖 `zip` 的 `time` feature（未启用），故手工做 civil-from-days 换算。
fn format_unix_secs(secs: i64) -> Option<String> {
    if secs < 0 {
        return None;
    }
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let (hour, minute, second) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    if !(0..=9999).contains(&year) {
        return None;
    }
    Some(format!(
        "{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02}"
    ))
}

/// Howard Hinnant `civil_from_days`：自 1970-01-01 起的天数 → (年, 月, 日)
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (y + if month <= 2 { 1 } else { 0 }, month, day)
}

/// NTFS FILETIME（100ns，自 1601-01-01 UTC）→ Unix 纪元秒；0 / 越界返回 None。
fn ntfs_filetime_secs(filetime: u64) -> Option<i64> {
    // 1601-01-01 到 1970-01-01 之间的秒数
    const EPOCH_DIFF_SECS: i64 = 11_644_473_600;
    if filetime == 0 {
        return None;
    }
    let secs = (filetime / 10_000_000) as i64 - EPOCH_DIFF_SECS;
    if secs < 0 {
        return None;
    }
    Some(secs)
}

/// 创建时间：优先 UT `0x5455` ctime，其次 NTFS `0x000A` ctime；均无 → None
fn extra_created(fields: &[&zip::ExtraField]) -> Option<String> {
    for f in fields {
        if let zip::ExtraField::ExtendedTimestamp(ts) = f {
            if let Some(v) = ts.cr_time() {
                return format_unix_secs(v as i64);
            }
        }
    }
    for f in fields {
        if let zip::ExtraField::Ntfs(n) = f {
            if let Some(v) = ntfs_filetime_secs(n.ctime()) {
                return format_unix_secs(v);
            }
        }
    }
    None
}

/// 访问时间：优先 UT `0x5455` atime，其次 NTFS `0x000A` atime；均无 → None
fn extra_accessed(fields: &[&zip::ExtraField]) -> Option<String> {
    for f in fields {
        if let zip::ExtraField::ExtendedTimestamp(ts) = f {
            if let Some(v) = ts.ac_time() {
                return format_unix_secs(v as i64);
            }
        }
    }
    for f in fields {
        if let zip::ExtraField::Ntfs(n) = f {
            if let Some(v) = ntfs_filetime_secs(n.atime()) {
                return format_unix_secs(v);
            }
        }
    }
    None
}

/// 按扩展名归类（展示层据此选预览器）
fn classify(path: &str) -> &'static str {
    let name = path.rsplit('/').next().unwrap_or(path);
    let lower = name.to_ascii_lowercase();
    if lower == "androidmanifest.xml" {
        return "manifest";
    }
    let ext = match lower.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => ext,
        _ => "",
    };
    match ext {
        "zip" => "zip",
        "apk" => "apk",
        "jar" => "jar",
        "aar" => "aar",
        "dex" => "dex",
        "so" => "so",
        "arsc" => "arsc",
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "ico" | "svg" | "heic"
        | "avif" => "image",
        "ttf" | "otf" | "ttc" | "woff" | "woff2" => "font",
        "pem" | "der" | "crt" | "cer" | "p12" | "pfx" | "jks" | "bks" | "p7b" | "p7c"
        | "p7s" | "keystore" | "jceks" => "cert",
        "mp4" | "webm" | "mkv" | "3gp" | "mov" | "avi" | "flv" | "m4v" | "ts" => "video",
        "mp3" | "ogg" | "wav" | "m4a" | "aac" | "flac" | "opus" | "mid" | "midi" => "audio",
        "json" => "json",
        "txt" | "xml" | "html" | "htm" | "md" | "js" | "css" | "yml" | "yaml"
        | "properties" | "cfg" | "ini" | "log" | "csv" | "kt" | "java" | "gradle"
        | "pro" | "toml" | "smali" | "sh" | "bat" => "text",
        _ => "binary",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEXT: &str = "hello-browser";
    const IMG: usize = 37;
    const SO: usize = 512;
    const INNER_TXT: &str = "inside-nested";

    /// 造一个带嵌套 zip 的测试 APK
    fn write_apk(path: &std::path::Path) {
        let file = File::create(path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let deflated = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        let stored = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);

        // 内层容器（assets/plugins/pack.zip）
        let inner = {
            let mut buf = Vec::new();
            {
                let mut z = zip::ZipWriter::new(Cursor::new(&mut buf));
                z.start_file("res/raw/inner.txt", deflated).unwrap();
                z.write_all(INNER_TXT.as_bytes()).unwrap();
                z.start_file("res/logo.png", deflated).unwrap();
                z.write_all(&vec![0x11u8; IMG]).unwrap();
                z.finish().unwrap();
            }
            buf
        };

        let put = |zip: &mut zip::ZipWriter<File>,
                   name: &str,
                   opts: zip::write::SimpleFileOptions,
                   data: &[u8]| {
            zip.start_file(name, opts).unwrap();
            zip.write_all(data).unwrap();
        };

        put(&mut zip, "AndroidManifest.xml", deflated, b"<manifest/>");
        put(&mut zip, "classes.dex", deflated, &vec![0x64u8; 128]);
        put(&mut zip, "lib/arm64-v8a/libx.so", stored, &vec![0x7fu8; SO]);
        put(&mut zip, "assets/config.json", deflated, b"{\"a\":1}");
        put(&mut zip, "assets/notes.txt", deflated, TEXT.as_bytes());
        put(&mut zip, "assets/plugins/pack.zip", stored, &inner);
        put(&mut zip, "res/drawable/icon.png", deflated, &vec![0x22u8; IMG]);
        zip.finish().unwrap();
    }

    fn tmp_apk(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "gstore_browser_test_{}_{tag}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).ok();
        dir.join("t.apk")
    }

    fn names(l: &BrowseListing) -> Vec<String> {
        l.entries.iter().map(|e| e.name.clone()).collect()
    }

    #[test]
    fn lists_root_with_synth_dirs_first() {
        let path = tmp_apk("root");
        write_apk(&path);
        let l = browse_entries(path.to_str().unwrap(), "", "").unwrap();

        // 目录在前（按名升序），文件在后
        assert_eq!(names(&l), vec!["assets", "lib", "res", "AndroidManifest.xml", "classes.dex"]);
        assert!(l.entries[0].is_dir);
        // 目录体积 = 后代条目解压后体积之和
        assert!(l.entries[0].size >= (b"{\"a\":1}".len() + TEXT.len()) as u64);
        let lib = l.entries.iter().find(|e| e.name == "lib").unwrap();
        assert_eq!(lib.size, SO as u64);
        let res = l.entries.iter().find(|e| e.name == "res").unwrap();
        assert_eq!(res.size, IMG as u64);
        assert_eq!(l.entries[3].kind, "manifest");
        assert_eq!(l.entries[4].kind, "dex");
        assert!(!l.can_go_up, "APK 根不能再往上");
        assert!(l.container_size > 0);
        assert!(!l.truncated);
    }

    #[test]
    fn lists_assets_and_marks_nested_zip_browsable() {
        let path = tmp_apk("assets");
        write_apk(&path);
        let l = browse_entries(path.to_str().unwrap(), "", "assets").unwrap();

        assert_eq!(names(&l), vec!["plugins", "config.json", "notes.txt"]);
        assert_eq!(l.parent_dir, "");
        assert!(l.can_go_up);
        let plugins = &l.entries[0];
        assert!(plugins.is_dir);
        assert_eq!(plugins.path, "assets/plugins");
    }

    #[test]
    fn nested_container_is_browsable_and_listed() {
        let path = tmp_apk("nested");
        write_apk(&path);
        let outer = browse_entries(path.to_str().unwrap(), "", "assets/plugins").unwrap();
        let pack = &outer.entries[0];
        assert_eq!(pack.name, "pack.zip");
        assert!(pack.browsable, "zip 家族应标记为可进入");
        assert_eq!(pack.kind, "zip");

        // 进入内层容器
        let chain = "assets/plugins/pack.zip";
        let inner = browse_entries(path.to_str().unwrap(), chain, "").unwrap();
        assert_eq!(names(&inner), vec!["res"]);
        assert_eq!(inner.container, chain);
        assert!(inner.can_go_up);

        let raw = browse_entries(path.to_str().unwrap(), &chain, "res/raw").unwrap();
        assert_eq!(names(&raw), vec!["inner.txt"]);
        assert_eq!(raw.entries[0].kind, "text");
        assert!(!raw.entries[0].browsable);
    }

    #[test]
    fn classifies_common_types() {
        let path = tmp_apk("kinds");
        write_apk(&path);
        let l = browse_entries(path.to_str().unwrap(), "", "").unwrap();
        let lib = l.entries.iter().find(|e| e.name == "lib").unwrap();
        assert!(lib.is_dir);

        let assets = browse_entries(path.to_str().unwrap(), "", "assets").unwrap();
        let json = assets.entries.iter().find(|e| e.name == "config.json").unwrap();
        assert_eq!(json.kind, "json");
        let txt = assets.entries.iter().find(|e| e.name == "notes.txt").unwrap();
        assert_eq!(txt.kind, "text");

        let res = browse_entries(path.to_str().unwrap(), "", "res/drawable").unwrap();
        assert_eq!(res.entries[0].kind, "image");

        let libs = browse_entries(path.to_str().unwrap(), "", "lib/arm64-v8a").unwrap();
        assert_eq!(libs.entries[0].kind, "so");
        assert!(libs.entries[0].stored);
    }

    #[test]
    fn exposes_entry_metadata() {
        let path = tmp_apk("meta");
        {
            let file = File::create(&path).unwrap();
            let mut zip = zip::ZipWriter::new(file);
            let when = zip::DateTime::from_date_and_time(2021, 3, 5, 12, 34, 56).unwrap();
            let deflated = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated)
                .last_modified_time(when);
            let stored = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Stored)
                .last_modified_time(when);
            zip.start_file("assets/meta.txt", deflated).unwrap();
            zip.write_all(b"meta").unwrap();
            zip.start_file("assets/raw.bin", stored).unwrap();
            zip.write_all(b"raw").unwrap();
            zip.finish().unwrap();
        }

        let l = browse_entries(path.to_str().unwrap(), "", "assets").unwrap();

        let meta = l.entries.iter().find(|e| e.name == "meta.txt").unwrap();
        assert_eq!(meta.modified.as_deref(), Some("2021-03-05 12:34:56"));
        assert_eq!(meta.compression, "deflated");
        assert!(!meta.encrypted);
        assert_eq!(meta.created, None, "无 extra 时间戳应为 None");
        assert_eq!(meta.accessed, None, "无 extra 时间戳应为 None");
        assert_eq!(meta.unix_mode, Some(0o100644), "写入器默认权限位 S_IFREG|0644");

        let raw = l.entries.iter().find(|e| e.name == "raw.bin").unwrap();
        assert_eq!(raw.modified.as_deref(), Some("2021-03-05 12:34:56"));
        assert_eq!(raw.compression, "stored");
        assert!(raw.stored);
        assert_eq!(raw.encrypted, meta.encrypted);
    }

    #[test]
    fn exports_entry_to_file() {
        let path = tmp_apk("export");
        write_apk(&path);
        let out = path.parent().unwrap().join("notes.txt.out");
        let r = export_entry(
            path.to_str().unwrap(),
            "",
            "assets/notes.txt",
            out.to_str().unwrap(),
        )
        .unwrap();
        assert_eq!(r.size, TEXT.len() as u64);
        assert_eq!(std::fs::read_to_string(&out).unwrap(), TEXT);
    }

    #[test]
    fn exports_entry_from_nested_container() {
        let path = tmp_apk("export_nested");
        write_apk(&path);
        let out = path.parent().unwrap().join("inner.txt.out");
        let r = export_entry(
            path.to_str().unwrap(),
            "assets/plugins/pack.zip",
            "res/raw/inner.txt",
            out.to_str().unwrap(),
        )
        .unwrap();
        assert_eq!(r.size, INNER_TXT.len() as u64);
        assert_eq!(std::fs::read_to_string(&out).unwrap(), INNER_TXT);
    }

    #[test]
    fn missing_entry_and_dir_export_error() {
        let path = tmp_apk("errors");
        write_apk(&path);
        let out = path.parent().unwrap().join("x.out");
        let err = export_entry(path.to_str().unwrap(), "", "assets/nope.txt", out.to_str().unwrap())
            .unwrap_err();
        assert!(err.contains("条目不存在"), "实际: {err}");

        // 显式目录条目（zip 允许以 / 结尾的目录记录）不可导出
        let dir_apk = path.parent().unwrap().join("dirs.apk");
        {
            let file = File::create(&dir_apk).unwrap();
            let mut zip = zip::ZipWriter::new(file);
            let opts = zip::write::SimpleFileOptions::default();
            zip.add_directory("assets/empty/", opts).unwrap();
            zip.finish().unwrap();
        }
        let err = export_entry(dir_apk.to_str().unwrap(), "", "assets/empty/", out.to_str().unwrap())
            .unwrap_err();
        assert!(err.contains("目录"), "实际: {err}");

        // 空条目路径前置校验
        let err = export_entry(path.to_str().unwrap(), "", "", out.to_str().unwrap()).unwrap_err();
        assert!(err.contains("缺少条目路径"), "实际: {err}");
    }

    #[test]
    fn nesting_depth_is_capped() {
        let path = tmp_apk("depth");
        write_apk(&path);
        let chain = vec!["a.zip"; MAX_NESTING + 1].join(&CHAIN_SEP.to_string());
        let err = browse_entries(path.to_str().unwrap(), &chain, "").unwrap_err();
        assert!(err.contains("嵌套层级过深"), "实际: {err}");
    }

    #[test]
    fn split_chain_handles_empty_and_multi() {
        assert!(split_chain("").is_empty());
        assert_eq!(split_chain("a.zip").len(), 1);
        assert_eq!(split_chain("a.zip\u{1}b/c.zip").len(), 2);
    }

    #[test]
    fn classify_cert_exts() {
        assert_eq!(classify("x.p7b"), "cert");
        assert_eq!(classify("x.p7c"), "cert");
        assert_eq!(classify("x.p7s"), "cert");
        assert_eq!(classify("x.keystore"), "cert");
        assert_eq!(classify("x.jceks"), "cert");
        assert_eq!(classify("x.bin"), "binary");
    }
}
