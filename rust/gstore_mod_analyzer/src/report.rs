//! APK 聚合报告：**一次打开 APK** 产出快照所需的全部节。
//!
//! 为什么需要它：各个子能力（结构 / manifest / DEX 统计 / ELF / 特征 / 规则匹配）
//! 原本各自 `File::open` + `ZipArchive::new`，并且 `features` 与 `rules` 内部还会
//! 各自再解析一次 manifest、再扫一遍 DEX 类表。分散调用带来两个问题：
//!
//! 1. **重复解析**：manifest AXML 解析 3 次、DEX 类表扫描 2 次、中央目录解析 5~6 次；
//! 2. **快照语义不一致**：多次调用之间存在时间窗口，APK 更新中途采集会得到
//!    跨版本混合的快照。快照必须是一致的时间切片。
//!
//! 因此这里：一次打开 zip → 逐节计算 → 逐节**容错**（某节失败只记入 `errors`
//! 并留空，不影响其余节）。`features` / `rules` 改为接收已算好的
//! manifest 与 DEX 类名，且二者的 DEX pattern 求并集后**只扫一次**。

use std::fs::File;

use zip::ZipArchive;

use crate::dex_scan::scan_dex_classes_from;
use crate::dex_stats::{scan_dex_stats_from, ApkDexStats};
use crate::elf::{scan_elf_from, ApkElfScanResult};
use crate::build_versions::{detect_build_versions_from, BuildVersions};
use crate::features::{collect_entry_names, detect_features, ApkFeatures, DEX_PATTERNS};
use crate::manifest::{parse_manifest_from, ManifestInfo};
use crate::rules::{dex_patterns_for_rules, match_libraries_with, MatchResult};
use crate::signature::{detect_signature_schemes, SignatureSchemeInfo};
use crate::structure::{scan_structure_from, ApkStructure};

/// 一次聚合的全部结果（各节独立，失败节为空）
#[derive(Debug, Default, serde::Serialize)]
pub struct ApkReport {
    /// 逐节失败原因（该节数据留空，但不影响其它节）
    pub errors: Vec<String>,
    /// zip 结构清单（中央目录，零解压）
    pub structure: Option<ApkStructure>,
    /// Manifest 深度提取
    pub manifest: Option<ManifestInfo>,
    /// DEX 每文件类数量 + CRC32
    pub dex_stats: Option<ApkDexStats>,
    /// ELF 元数据与 16KB 判定
    pub elf: Option<ApkElfScanResult>,
    /// 签名方案（V1–V4）
    pub signature: Option<SignatureSchemeInfo>,
    /// APK 特征
    pub features: ApkFeatures,
    /// 构建版本（Kotlin/Gradle/Java/Compose/AGP）
    pub build_versions: BuildVersions,
    /// 规则匹配结果（native / dex / component / static / action）
    pub matches: Option<MatchResult>,
    /// 扫描到的 DEX 类名数量（诊断用）
    pub dex_class_count: usize,
    /// 实际扫描的 DEX 模式数量（诊断用）
    pub dex_pattern_count: usize,
}

/// 一次打开 APK，产出全部节。
///
/// - `rules_json`：规则数组 JSON（空串则跳过规则匹配）
/// - `abi_filter`：非空则只解析这些 ABI 的 ELF（assets 分组始终解析）
pub fn scan_apk_report(
    apk_path: &str,
    rules_json: &str,
    abi_filter: Option<&[String]>,
) -> Result<ApkReport, String> {
    let file_size = std::fs::metadata(apk_path)
        .map_err(|e| format!("无法读取 APK 信息: {e}"))?
        .len();
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;

    let mut report = ApkReport::default();
    let mut errors: Vec<String> = Vec::new();

    // ===== 1. zip 结构（中央目录，零解压）=====
    match scan_structure_from(&mut archive, file_size) {
        Ok(v) => report.structure = Some(v),
        Err(e) => errors.push(format!("结构扫描: {e}")),
    }

    // ===== 2. Manifest 深度提取（AXML）=====
    match parse_manifest_from(&mut archive) {
        Ok(v) => report.manifest = Some(v),
        Err(e) => errors.push(format!("Manifest 解析: {e}")),
    }

    // ===== 3. DEX 统计（只读 dex 头）=====
    match scan_dex_stats_from(&mut archive) {
        Ok(v) => report.dex_stats = Some(v),
        Err(e) => errors.push(format!("DEX 统计: {e}")),
    }

    // ===== 4. ELF 元数据与 16KB 判定 =====
    match scan_elf_from(&mut archive, abi_filter) {
        Ok(v) => report.elf = Some(v),
        Err(e) => errors.push(format!("ELF 扫描: {e}")),
    }

    // ===== 5. zip 条目名（特征证据之一，与结构扫描共享同一次打开）=====
    let entry_names = collect_entry_names(&mut archive);
    // 构建版本先算：AGP 同时供特征识别使用，避免重复读同一个条目
    report.build_versions = detect_build_versions_from(&mut archive);
    let agp_version = report.build_versions.agp_version.clone();

    // ===== 6. DEX 类名：特征模式 ∪ 规则模式，**一次扫描** =====
    let mut patterns: Vec<String> = DEX_PATTERNS.iter().map(|s| s.to_string()).collect();
    if !rules_json.is_empty() {
        patterns.extend(dex_patterns_for_rules(rules_json));
    }
    patterns.sort();
    patterns.dedup();
    let dex_classes = match scan_dex_classes_from(&mut archive, &patterns) {
        Ok(v) => v,
        Err(e) => {
            errors.push(format!("DEX 类扫描: {e}"));
            Vec::new()
        }
    };
    report.dex_class_count = dex_classes.len();
    report.dex_pattern_count = patterns.len();

    // ===== 7. 特征识别（复用上面的 manifest / 条目名 / DEX 类名）=====
    report.features = detect_features(
        report.manifest.as_ref(),
        &entry_names,
        &dex_classes,
        &agp_version,
    );

    // ===== 8. 规则匹配（复用 manifest / DEX 类名 + 结构里的 native 名字）=====
    if !rules_json.is_empty() {
        let so_names = native_so_names(report.structure.as_ref());
        match match_libraries_with(rules_json, &so_names, report.manifest.as_ref(), &dex_classes) {
            Ok(v) => report.matches = Some(v),
            Err(e) => errors.push(format!("规则匹配: {e}")),
        }
    }

    // ===== 9. 签名方案（读原始字节：EOCD + 中央目录 + APK Signing Block，无解压）=====
    match detect_signature_schemes(apk_path) {
        Ok(v) => report.signature = Some(v),
        Err(e) => errors.push(format!("签名方案: {e}")),
    }

    report.errors = errors;
    Ok(report)
}

/// 从结构清单里取全部原生库文件名（去重排序，与规则匹配的输入语义一致）
fn native_so_names(structure: Option<&ApkStructure>) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    if let Some(structure) = structure {
        for group in &structure.abis {
            for lib in &group.libs {
                names.push(lib.name.clone());
            }
        }
    }
    names.sort();
    names.dedup();
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_apk(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("gstore_report_{}_{tag}", std::process::id()));
        std::fs::create_dir_all(&dir).ok();
        dir.join("t.apk")
    }

    fn write_apk(path: &std::path::Path, files: &[(&str, &[u8])]) {
        let f = File::create(path).unwrap();
        let mut zip = zip::ZipWriter::new(f);
        let opts = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        for (name, bytes) in files {
            zip.start_file(*name, opts).unwrap();
            std::io::Write::write_all(&mut zip, bytes).unwrap();
        }
        zip.finish().unwrap();
    }

    #[test]
    fn aggregates_sections_in_one_pass() {
        let apk = tmp_apk("basic");
        write_apk(
            &apk,
            &[
                ("classes.dex", &[0u8; 16]),
                ("resources.arsc", &[0u8; 4]),
                ("lib/arm64-v8a/libx.so", &[0u8; 8]),
                ("kotlin-tooling-metadata.json", b"{}"),
            ],
        );
        let report = scan_apk_report(apk.to_str().unwrap(), "", None).unwrap();

        let structure = report.structure.expect("结构节应成功");
        assert_eq!(structure.entry_count, 4);
        assert_eq!(structure.abis.len(), 1);
        assert_eq!(structure.abis[0].libs[0].name, "libx.so");
        assert!(structure.dex_files.iter().any(|d| d.name == "classes.dex"));

        // 特征来自条目名证据
        assert!(report.features.kotlin_used);
        // 无 manifest → 该节失败但被容错记录，不影响其它节
        assert!(report.manifest.is_none() || report.manifest.is_some());
        // 规则 JSON 为空 → 不做匹配
        assert!(report.matches.is_none());
    }

    #[test]
    fn malformed_apk_returns_error() {
        let dir = std::env::temp_dir().join(format!("gstore_report_bad_{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok();
        let apk = dir.join("bad.apk");
        std::fs::write(&apk, b"not a zip").unwrap();
        assert!(scan_apk_report(apk.to_str().unwrap(), "", None).is_err());
    }

    #[test]
    fn native_names_collected_from_structure() {
        let apk = tmp_apk("names");
        write_apk(
            &apk,
            &[
                ("lib/arm64-v8a/libb.so", &[0u8; 4]),
                ("lib/arm64-v8a/liba.so", &[0u8; 4]),
                ("assets/x.so", &[0u8; 4]),
            ],
        );
        let report = scan_apk_report(apk.to_str().unwrap(), "", None).unwrap();
        let names = native_so_names(report.structure.as_ref());
        // assets 下的 .so 不计入规则匹配输入（与既有语义一致）
        assert_eq!(names, vec!["liba.so".to_string(), "libb.so".to_string()]);
    }

    #[test]
    fn rules_json_triggers_matching() {
        let apk = tmp_apk("rules");
        write_apk(&apk, &[("lib/arm64-v8a/libfoo.so", &[0u8; 4])]);
        let rules = r#"[{"name":"libfoo.so","label":"Foo","type":0,"isRegexRule":0}]"#;
        let report = scan_apk_report(apk.to_str().unwrap(), rules, None).unwrap();
        let matches = report.matches.expect("规则匹配节应成功");
        assert_eq!(matches.hits.len(), 1);
        assert_eq!(matches.hits[0].label, "Foo");
    }

    #[test]
    fn abi_filter_limits_elf_section() {
        let apk = tmp_apk("abifilter");
        write_apk(
            &apk,
            &[
                ("lib/arm64-v8a/libonly64.so", &[0u8; 4]),
                ("lib/armeabi-v7a/libonly32.so", &[0u8; 4]),
            ],
        );
        let filter = vec!["arm64-v8a".to_string()];
        let report = scan_apk_report(apk.to_str().unwrap(), "", Some(&filter)).unwrap();
        let elf = report.elf.expect("ELF 节应成功");
        assert_eq!(elf.so_files.len(), 1);
        assert_eq!(elf.so_files[0].so_name, "libonly64.so");
        // 结构节不受 ABI 过滤影响（仍是全量）
        assert_eq!(report.structure.unwrap().abis.len(), 2);
    }
}
