//! APK 结构清单：一次遍历 zip 中央目录，**不解压任何条目**
//!
//! 为什么需要它：宿主原先为了列 `.so` 清单，把整个 APK 读入内存并用
//! `ZipDecoder().decodeBytes` 全量解压，且 lib 清单 / assets .so / ABI 集合
//! 三处各自独立做了一遍 —— 大包上等于 3 次全量解压与 3 次整包内存占用。
//!
//! 本方法只依赖 zip 中央目录即可拿到：条目名 / 解压后大小 / 压缩后大小 /
//! 压缩方式 / CRC32 / 数据起始偏移（→ zip 对齐），零解压开销。
//!
//! 注意：**不含 ELF 内容解析**（页对齐、DT_NEEDED 等需要解压，见 `elf` 模块）。

use std::fs::File;
use std::io::Read;

use serde::Serialize;

use crate::arsc::ArscInfo;

/// `resources.arsc` 解析上限（防御异常包；正常资源表 1~2MB 级）
const MAX_ARSC_BYTES: u64 = 32 * 1024 * 1024;
use zip::ZipArchive;

/// 一个 `.so` 条目（只需中央目录信息）
#[derive(Clone, Debug, Serialize)]
pub struct SoEntry {
    /// 文件名（如 `libcrypto.so`）
    pub name: String,
    /// zip 内完整路径（如 `lib/arm64-v8a/libcrypto.so`）
    pub path: String,
    /// 解压后字节数
    pub size: u64,
    /// 压缩后字节数
    pub compressed_size: u64,
    /// 条目 CRC32
    pub crc32: u32,
    /// 是否以 STORED（不压缩）存放：只有 STORED 的数据偏移对齐才有意义
    pub stored: bool,
    /// STORED 条目数据起始偏移的最大 2 的幂因子（对齐 LibChecker `zipAlignment`）；
    /// 非 STORED 为 0
    pub zip_alignment: u64,
}

/// 单个 ABI 目录下的原生库
#[derive(Clone, Debug, Serialize)]
pub struct AbiLibs {
    /// ABI 目录名（如 `arm64-v8a`）
    pub abi: String,
    /// 该 ABI 下的库清单（按文件名排序）
    pub libs: Vec<SoEntry>,
    /// 该 ABI 下库的解压后总字节数
    pub total_size: u64,
}

/// 一个 `assets/**` 条目（只需中央目录信息）
///
/// `crc32` 是**解压后内容**的指纹 → "同名 asset 是否内容一致"可直接判定，
/// 无需解压（与 [`SoEntry`] 同一套零解压思路）。
#[derive(Clone, Debug, Serialize)]
pub struct AssetEntry {
    /// zip 内完整路径（如 `assets/models/x.tflite`）
    pub path: String,
    /// 相对 `assets/` 的路径（分组与改名检测用）
    pub name: String,
    /// 解压后字节数
    pub size: u64,
    /// 压缩后字节数
    pub compressed_size: u64,
    /// 条目 CRC32
    pub crc32: u32,
    /// 是否以 STORED（不压缩）存放
    pub stored: bool,
}

/// 一个 DEX 条目
#[derive(Clone, Debug, Serialize)]
pub struct DexFileEntry {
    /// 条目名（如 `classes2.dex`）
    pub name: String,
    /// 解压后字节数
    pub size: u64,
    /// 压缩后字节数
    pub compressed_size: u64,
    /// 条目 CRC32
    pub crc32: u32,
}

/// APK 结构清单
#[derive(Clone, Debug, Default, Serialize)]
pub struct ApkStructure {
    /// APK 文件本身大小（字节）
    pub file_size: u64,
    /// zip 条目总数
    pub entry_count: usize,
    /// 全部条目解压后总字节数
    pub total_uncompressed: u64,
    /// STORED（未压缩）条目数量：影响安装体积与页对齐判定
    pub stored_entry_count: usize,
    /// 按 ABI 分组的原生库（`lib/<abi>/*.so`）
    pub abis: Vec<AbiLibs>,
    /// `assets/**/*.so`（LibChecker 单列分组）
    pub assets_so: Vec<SoEntry>,
    /// `assets/**` 全量清单（含 `.so`；与 `assets_so` 语义不同）
    pub assets: Vec<AssetEntry>,
    /// DEX 文件清单（`classes*.dex`）
    pub dex_files: Vec<DexFileEntry>,
    /// `resources.arsc` 解压后大小（缺失为 0）
    pub resources_arsc_size: u64,
    /// `resources.arsc` 压缩后字节数（缺失为 0）
    pub resources_arsc_compressed_size: u64,
    /// `resources.arsc` 条目 CRC32（缺失为 0）
    pub resources_arsc_crc32: u32,
    /// `resources.arsc` 是否 STORED 存放
    pub resources_arsc_stored: bool,
    /// `resources.arsc` 浅解析（包名/类型/字符串池/配置维度）；解析失败为空
    pub arsc: ArscInfo,
    /// 是否含 `AndroidManifest.xml`
    pub has_manifest: bool,
}

/// 扫描 APK 结构（只读中央目录，不解压）
pub fn scan_apk_structure(apk_path: &str) -> Result<ApkStructure, String> {
    let file_size = std::fs::metadata(apk_path)
        .map_err(|e| format!("无法读取 APK 信息: {e}"))?
        .len();
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;
    scan_structure_from(&mut archive, file_size)
}

/// 复用已打开的 archive（聚合入口用：一次打开产出全部节）
pub fn scan_structure_from(
    archive: &mut ZipArchive<File>,
    file_size: u64,
) -> Result<ApkStructure, String> {
    let entry_count = archive.len();

    let mut abi_map: std::collections::BTreeMap<String, Vec<SoEntry>> = Default::default();
    let mut assets_so: Vec<SoEntry> = Vec::new();
    let mut assets: Vec<AssetEntry> = Vec::new();
    let mut dex_files: Vec<DexFileEntry> = Vec::new();
    let mut arsc_info = ArscInfo::default();
    let mut resources_arsc_size = 0u64;
    let mut resources_arsc_compressed_size = 0u64;
    let mut resources_arsc_crc32 = 0u32;
    let mut resources_arsc_stored = false;
    let mut stored_entry_count = 0usize;
    let mut has_manifest = false;
    let mut total_uncompressed = 0u64;

    for index in 0..entry_count {
        // 单个条目元信息读取失败只跳过它，不中断整包扫描
        let Ok(mut entry) = archive.by_index(index) else {
            continue;
        };
        let path = entry.name().to_string();
        let size = entry.size();
        let compressed_size = entry.compressed_size();
        let crc32 = entry.crc32();
        let stored = entry.compression() == zip::CompressionMethod::Stored;
        total_uncompressed = total_uncompressed.saturating_add(size);
        if stored {
            stored_entry_count += 1;
        }

        // assets/** 全量清单：在分类之前收集（后面 path 会被 move 进 SoEntry）
        if let Some(rel) = path.strip_prefix("assets/") {
            if !rel.is_empty() && !rel.ends_with('/') {
                assets.push(AssetEntry {
                    path: path.clone(),
                    name: rel.to_string(),
                    size,
                    compressed_size,
                    crc32,
                    stored,
                });
            }
        }

        if path == "AndroidManifest.xml" {
            has_manifest = true;
            continue;
        }
        if path == "resources.arsc" {
            resources_arsc_size = size;
            resources_arsc_compressed_size = compressed_size;
            resources_arsc_crc32 = crc32;
            resources_arsc_stored = stored;
            // 浅解析：只读头 + 字符串池 + 类型表（不解每条资源）
            if size <= MAX_ARSC_BYTES {
                let mut data = Vec::with_capacity(size as usize);
                if entry.read_to_end(&mut data).is_ok() {
                    arsc_info = crate::arsc::parse_arsc(&data);
                }
            }
            continue;
        }
        if is_dex_entry(&path) {
            dex_files.push(DexFileEntry {
                name: path,
                size,
                compressed_size,
                crc32,
            });
            continue;
        }

        // .so：lib/<abi>/<name>.so 或 assets/**/*.so
        if let Some((abi, name)) = parse_lib_path(&path) {
            let zip_alignment = if stored {
                zip_alignment(entry.data_start())
            } else {
                0
            };
            abi_map.entry(abi).or_default().push(SoEntry {
                name,
                path,
                size,
                compressed_size,
                crc32,
                stored,
                zip_alignment,
            });
        } else if is_assets_so(&path) {
            let zip_alignment = if stored {
                zip_alignment(entry.data_start())
            } else {
                0
            };
            let name = path.rsplit('/').next().unwrap_or(&path).to_string();
            assets_so.push(SoEntry {
                name,
                path,
                size,
                compressed_size,
                crc32,
                stored,
                zip_alignment,
            });
        }
    }

    let mut abis: Vec<AbiLibs> = abi_map
        .into_iter()
        .map(|(abi, mut libs)| {
            libs.sort_by(|a, b| a.name.cmp(&b.name));
            let total_size = libs.iter().map(|l| l.size).sum();
            AbiLibs {
                abi,
                libs,
                total_size,
            }
        })
        .collect();
    abis.sort_by(|a, b| a.abi.cmp(&b.abi));
    assets_so.sort_by(|a, b| a.name.cmp(&b.name));
    assets.sort_by(|a, b| a.name.cmp(&b.name));
    dex_files.sort_by(|a, b| a.name.cmp(&b.name));

    Ok(ApkStructure {
        file_size,
        entry_count,
        total_uncompressed,
        stored_entry_count,
        abis,
        assets_so,
        assets,
        dex_files,
        resources_arsc_size,
        resources_arsc_compressed_size,
        resources_arsc_crc32,
        resources_arsc_stored,
        arsc: arsc_info,
        has_manifest,
    })
}

/// 数据起始偏移 → 最大 2 的幂因子（对齐 LibChecker `zipAlignment` 语义）。
/// 0 偏移视为未知（返回 0，不参与对齐判定）。
fn zip_alignment(data_start: u64) -> u64 {
    if data_start == 0 {
        return 0;
    }
    1u64 << data_start.trailing_zeros()
}

/// `lib/<abi>/<name>.so` → Some((abi, name))；其余返回 None
fn parse_lib_path(path: &str) -> Option<(String, String)> {
    let mut parts = path.split('/');
    let (lib, abi, name) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() || lib != "lib" || abi.is_empty() || !name.ends_with(".so") {
        return None;
    }
    Some((abi.to_string(), name.to_string()))
}

/// `assets/**/*.so`（要求确有非空文件名，排除 `assets/.so` 这类退化路径）
fn is_assets_so(path: &str) -> bool {
    let Some(name) = path.strip_prefix("assets/") else {
        return false;
    };
    let Some(stem) = name.strip_suffix(".so") else {
        return false;
    };
    !stem.is_empty()
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

    const MANIFEST: usize = 64;
    const ARSC: usize = 128;
    const DEX1: usize = 256;
    const DEX2: usize = 32;
    const SO_A64_FOO: usize = 512;
    const SO_A64_BAR: usize = 64;
    const SO_V7A_FOO: usize = 256;
    const ASSETS_SO: usize = 16;
    const XML: usize = 4;

    fn write_test_apk(path: &std::path::Path) {
        let file = File::create(path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let deflated = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        let stored = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);

        let add = |zip: &mut zip::ZipWriter<File>,
                       name: &str,
                       opts: zip::write::SimpleFileOptions,
                       len: usize| {
            zip.start_file(name, opts).unwrap();
            std::io::Write::write_all(zip, &vec![0x5au8; len]).unwrap();
        };

        add(&mut zip, "AndroidManifest.xml", deflated, MANIFEST);
        add(&mut zip, "resources.arsc", deflated, ARSC);
        add(&mut zip, "classes.dex", deflated, DEX1);
        add(&mut zip, "classes2.dex", deflated, DEX2);
        add(&mut zip, "lib/arm64-v8a/libfoo.so", stored, SO_A64_FOO);
        add(&mut zip, "lib/arm64-v8a/libbar.so", deflated, SO_A64_BAR);
        add(&mut zip, "lib/armeabi-v7a/libfoo.so", stored, SO_V7A_FOO);
        add(&mut zip, "assets/embedded.so", deflated, ASSETS_SO);
        add(&mut zip, "res/xml/config.xml", deflated, XML);
        zip.finish().unwrap();
    }

    fn tmp_apk(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "gstore_structure_test_{}_{tag}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).ok();
        dir.join("t.apk")
    }

    #[test]
    fn groups_libs_by_abi_and_ignores_others() {
        let path = tmp_apk("group");
        write_test_apk(&path);
        let s = scan_apk_structure(path.to_str().unwrap()).unwrap();

        assert!(s.has_manifest);
        assert_eq!(s.resources_arsc_size, ARSC as u64);
        assert_eq!(s.dex_files.len(), 2);
        assert_eq!(s.dex_files[0].name, "classes.dex");
        assert_eq!(s.dex_files[0].size, DEX1 as u64);
        assert_eq!(s.dex_files[1].name, "classes2.dex");

        // ABI 按名排序：arm64-v8a 在 armeabi-v7a 前
        assert_eq!(s.abis.len(), 2);
        assert_eq!(s.abis[0].abi, "arm64-v8a");
        assert_eq!(s.abis[1].abi, "armeabi-v7a");

        let arm64 = &s.abis[0];
        assert_eq!(arm64.libs.len(), 2);
        assert_eq!(arm64.libs[0].name, "libbar.so");
        assert_eq!(arm64.libs[1].name, "libfoo.so");
        assert_eq!(arm64.total_size, (SO_A64_FOO + SO_A64_BAR) as u64);
        assert_eq!(arm64.libs[1].path, "lib/arm64-v8a/libfoo.so");
        assert!(arm64.libs[1].stored, "用 STORED 写入的条目应标记 stored");
        assert!(!arm64.libs[0].stored, "Deflated 条目不参与对齐判定");
        assert_eq!(arm64.libs[0].zip_alignment, 0);

        assert_eq!(s.assets_so.len(), 1);
        assert_eq!(s.assets_so[0].name, "embedded.so");
        assert_eq!(s.assets_so[0].path, "assets/embedded.so");
        // res/xml/config.xml 不应被当成 .so 收录
        assert!(s
            .abis
            .iter()
            .all(|a| a.libs.iter().all(|l| !l.path.ends_with(".xml"))));
    }

    #[test]
    fn stored_entry_alignment_is_power_of_two() {
        let path = tmp_apk("align");
        write_test_apk(&path);
        let s = scan_apk_structure(path.to_str().unwrap()).unwrap();
        let lib = s.abis[0]
            .libs
            .iter()
            .find(|l| l.name == "libfoo.so")
            .unwrap();
        assert!(lib.zip_alignment > 0, "STORED 条目应能算出数据偏移对齐");
        assert!(
            lib.zip_alignment.is_power_of_two(),
            "对齐值必须是 2 的幂（实际 {}）",
            lib.zip_alignment
        );
    }

    #[test]
    fn collects_assets_inventory_and_arsc_fingerprint() {
        let path = tmp_apk("assets");
        write_test_apk(&path);
        let s = scan_apk_structure(path.to_str().unwrap()).unwrap();

        // assets 全量清单：含 .so，但不含 res/、AndroidManifest.xml
        let names: Vec<&str> = s.assets.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(names, vec!["embedded.so"]);
        assert_eq!(s.assets[0].path, "assets/embedded.so");
        assert_eq!(s.assets[0].size, ASSETS_SO as u64);
        assert!(!s.assets[0].stored, "测试里 assets 是 deflate 写入的");
        // 与 assets_so 语义区分：后者是"原生库"分组，前者是"资源清单"
        assert_eq!(s.assets_so.len(), 1);

        // resources.arsc 指纹（内容级对比的输入）
        assert_eq!(s.resources_arsc_size, ARSC as u64);
        assert!(!s.resources_arsc_stored);

        // STORED 计数：测试包只有 libfoo.so 的两个 ABI 是 STORED
        assert_eq!(s.stored_entry_count, 2);
    }

    #[test]
    fn entry_count_and_total_size() {
        let path = tmp_apk("totals");
        write_test_apk(&path);
        let s = scan_apk_structure(path.to_str().unwrap()).unwrap();
        assert_eq!(s.entry_count, 9);
        let expected =
            (MANIFEST + ARSC + DEX1 + DEX2 + SO_A64_FOO + SO_A64_BAR + SO_V7A_FOO + ASSETS_SO + XML)
                as u64;
        assert_eq!(s.total_uncompressed, expected);
        assert!(s.file_size > 0);
    }

    #[test]
    fn path_classification() {
        assert_eq!(
            parse_lib_path("lib/arm64-v8a/libx.so"),
            Some(("arm64-v8a".to_string(), "libx.so".to_string()))
        );
        assert_eq!(parse_lib_path("lib/arm64-v8a/x.so.txt"), None);
        assert_eq!(parse_lib_path("lib//libx.so"), None);
        assert_eq!(parse_lib_path("lib/a/b/libx.so"), None);
        assert_eq!(parse_lib_path("assets/libx.so"), None);

        assert!(is_assets_so("assets/a/b/libx.so"));
        assert!(!is_assets_so("assets/libx.so.txt"));
        assert!(!is_assets_so("assets/.so"));

        assert!(is_dex_entry("classes.dex"));
        assert!(is_dex_entry("classes12.dex"));
        assert!(!is_dex_entry("classesx.dex"));
        assert!(!is_dex_entry("classes.dex.bak"));
    }

    #[test]
    fn zip_alignment_semantics() {
        assert_eq!(zip_alignment(0), 0);
        assert_eq!(zip_alignment(1), 1);
        assert_eq!(zip_alignment(0x1000), 0x1000);
        assert_eq!(zip_alignment(0x4000), 0x4000);
        assert_eq!(zip_alignment(0x6000), 0x2000);
    }

    #[test]
    fn nonexistent_apk_errors() {
        let err = scan_apk_structure("/no/such/file.apk").unwrap_err();
        assert!(err.contains("无法读取 APK 信息"));
    }
}
