//! APK 特征识别（对齐 LibChecker `PackageInfoExtensions.getFeatures`）
//!
//! 每项特征都来自「可零成本或低成本获得」的证据：
//! - **zip 条目名**（只读中央目录）：`kotlin-tooling-metadata.json`、
//!   `kotlin/kotlin.kotlin_builtins`、`META-INF/xposed/module.prop`、
//!   `META-INF/*/app-metadata.properties`、`androidx.compose.*.version` 等；
//! - **AndroidManifest meta-data / 权限 / 组件**：Xposed（`xposedmodule`）、
//!   Play Signing（`com.android.stamp.*`）、PWA（`org.chromium.webapk.shell_apk*`）、
//!   KMP（Compose Multiplatform Provider）、即时更新通知权限；
//! - **DEX 类名**（需解压 dex，成本最高）：Kotlin / Compose / KMP 运行时痕迹。
//!
//! 核心判定 `detect_features` 是**纯函数**：manifest / dex 类名 / 条目名 / AGP 版本
//! 全部由调用方传入。这样聚合入口（`report.rs`）可以把这些只算一次后复用，
//! 不必为特征识别再各自解析一遍 manifest 与 DEX。
//!
//! `split_apks` 无法从单个 APK 判定（需要看是否有 split 文件），由宿主自行判断，
//! 这里恒为 false。

use std::fs::File;

use zip::ZipArchive;

use crate::build_versions::detect_build_versions_from;
use crate::dex_scan::scan_dex_classes_from;
use crate::manifest::{parse_manifest_from, ManifestInfo};

/// APK 特征
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct ApkFeatures {
    /// 是否使用 Kotlin（DEX 类 / kotlin 构建元数据 / kotlin_builtins）
    pub kotlin_used: bool,
    /// 是否使用 Jetpack Compose
    pub jetpack_compose: bool,
    /// 是否 Kotlin Multiplatform（Compose Multiplatform）
    pub kmp: bool,
    /// 是否 Xposed 模块
    pub xposed_module: bool,
    /// 是否 Google Play 签名（`com.android.stamp.*` meta-data）
    pub play_signing: bool,
    /// 是否 PWA（`org.chromium.webapk.shell_apk*` meta-data）
    pub pwa: bool,
    /// 是否声明了即时更新通知权限
    pub live_update_notification: bool,
    /// AGP 版本（`app-metadata.properties` 的 `androidGradlePluginVersion`；未知为空串）
    pub agp_version: String,
    /// 判定依据（诊断用，如 `["dex:kotlin.*","entry:kotlin-tooling-metadata.json"]`）
    pub evidence: Vec<String>,
}

/// 特征识别所需的 DEX 类前缀模式（Kotlin / Compose / KMP 运行时痕迹）。
///
/// 公开给聚合入口：与规则匹配的 pattern 求并集后**一次扫描** DEX。
pub const DEX_PATTERNS: [&str; 4] = [
    "kotlin.*",
    "kotlinx.*",
    "androidx.compose.*",
    "org.jetbrains.compose.*",
];

/// 识别 APK 特征（自带打开 APK；内部同样是「一次打开复用」）
pub fn scan_features(apk_path: &str) -> Result<ApkFeatures, String> {
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;

    let entry_names = collect_entry_names(&mut archive);
    let agp_version = detect_build_versions_from(&mut archive).agp_version;
    // manifest 解析失败不影响其余证据
    let manifest = parse_manifest_from(&mut archive).ok();
    let patterns: Vec<String> = DEX_PATTERNS.iter().map(|s| s.to_string()).collect();
    let dex_classes = scan_dex_classes_from(&mut archive, &patterns).unwrap_or_default();

    Ok(detect_features(
        manifest.as_ref(),
        &entry_names,
        &dex_classes,
        &agp_version,
    ))
}

/// 纯函数版特征判定：全部输入由调用方提供
pub fn detect_features(
    manifest: Option<&ManifestInfo>,
    entry_names: &[String],
    dex_classes: &[String],
    agp_version: &str,
) -> ApkFeatures {
    let mut features = ApkFeatures::default();

    // ===== 1. zip 条目名证据（零解压）=====
    let mut compose_version_entry = false;
    for name in entry_names {
        if name == "kotlin-tooling-metadata.json"
            || name == "kotlin/kotlin.kotlin_builtins"
            || name.starts_with("META-INF/services/kotlinx")
        {
            features.kotlin_used = true;
            features.evidence.push(format!("entry:{name}"));
        }
        if name == "META-INF/xposed/module.prop" {
            features.xposed_module = true;
            features.evidence.push(format!("entry:{name}"));
        }
        // androidx.compose.ui.version / androidx.compose.material.version …
        if name.starts_with("androidx.compose.") && name.ends_with(".version") {
            compose_version_entry = true;
        }
    }
    if compose_version_entry {
        features.jetpack_compose = true;
        features.evidence.push("entry:androidx.compose.*.version".to_string());
    }
    if !agp_version.is_empty() {
        features.evidence.push(format!("agp:{agp_version}"));
        features.agp_version = agp_version.to_string();
    }

    // ===== 2. Manifest 证据（meta-data / 组件 / 权限）=====
    if let Some(manifest) = manifest {
        for meta in &manifest.meta_data {
            let lower = meta.name.to_ascii_lowercase();
            if lower == "xposedmodule" || lower == "xposedminversion" {
                features.xposed_module = true;
                features.evidence.push(format!("meta-data:{}", meta.name));
            }
            if meta.name.starts_with("com.android.stamp.") {
                features.play_signing = true;
                features.evidence.push(format!("meta-data:{}", meta.name));
            }
            if meta.name.starts_with("org.chromium.webapk.shell_apk") {
                features.pwa = true;
                features.evidence.push(format!("meta-data:{}", meta.name));
            }
        }
        // KMP：Compose Multiplatform 的资源 Provider
        if manifest
            .components
            .iter()
            .any(|c| c.name == "org.jetbrains.compose.resources.AndroidContextProvider")
        {
            features.kmp = true;
            features.evidence.push(
                "component:org.jetbrains.compose.resources.AndroidContextProvider".into(),
            );
        }
        if manifest
            .permissions
            .iter()
            .any(|p| p.name == "android.permission.POST_PROMOTED_NOTIFICATIONS")
        {
            features.live_update_notification = true;
            features.evidence.push(
                "permission:android.permission.POST_PROMOTED_NOTIFICATIONS".into(),
            );
        }
    }

    // ===== 3. DEX 类证据（成本最高）=====
    for class_name in dex_classes {
        if (class_name.starts_with("kotlin.") || class_name.starts_with("kotlinx."))
            && !features.kotlin_used
        {
            features.kotlin_used = true;
            features.evidence.push(format!("dex:{class_name}"));
        }
        if class_name.starts_with("androidx.compose.") && !features.jetpack_compose {
            features.jetpack_compose = true;
            features.evidence.push(format!("dex:{class_name}"));
        }
        if class_name.starts_with("org.jetbrains.compose.") && !features.kmp {
            features.kmp = true;
            features.evidence.push(format!("dex:{class_name}"));
        }
    }

    features.evidence.sort();
    features.evidence.dedup();
    features
}

/// 全部 zip 条目名（只读中央目录，零解压）
pub fn collect_entry_names(archive: &mut ZipArchive<File>) -> Vec<String> {
    let mut names = Vec::with_capacity(archive.len());
    for i in 0..archive.len() {
        if let Ok(entry) = archive.by_index(i) {
            names.push(entry.name().to_string());
        }
    }
    names
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{ComponentInfo, MetaDataItem, PermissionInfo};

    fn tmp_apk(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "gstore_features_{}_{tag}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).ok();
        dir.join("t.apk")
    }

    /// 合成 DEX：class_defs 中含指定点分类名，用于验证 DEX 证据
    fn fake_dex_with_classes(classes: &[&str]) -> Vec<u8> {
        // 布局：header(0x70) | string_ids | type_ids | class_defs | 字符串数据
        let n = classes.len();
        let header = 0x70usize;
        let string_ids_off = header;
        let type_ids_off = string_ids_off + n * 4;
        let class_defs_off = type_ids_off + n * 4;
        let data_off = class_defs_off + n * 32;
        let mut data = Vec::new();
        let mut string_offsets = Vec::new();
        for c in classes {
            string_offsets.push(data_off + data.len());
            data.push(c.len() as u8); // ULEB128（长度 < 128）
            data.extend_from_slice(c.as_bytes());
            data.push(0);
        }
        let total = data_off + data.len();
        let mut v = vec![0u8; total];
        v[0..8].copy_from_slice(b"dex\n035\0");
        v[0x20..0x24].copy_from_slice(&(total as u32).to_le_bytes()); // file_size
        v[0x38..0x3C].copy_from_slice(&(n as u32).to_le_bytes()); // string_ids_size
        v[0x3C..0x40].copy_from_slice(&(string_ids_off as u32).to_le_bytes());
        v[0x40..0x44].copy_from_slice(&(n as u32).to_le_bytes()); // type_ids_size
        v[0x44..0x48].copy_from_slice(&(type_ids_off as u32).to_le_bytes());
        v[0x60..0x64].copy_from_slice(&(n as u32).to_le_bytes()); // class_defs_size
        v[0x64..0x68].copy_from_slice(&(class_defs_off as u32).to_le_bytes());
        for (i, off) in string_offsets.iter().enumerate() {
            v[string_ids_off + i * 4..string_ids_off + i * 4 + 4]
                .copy_from_slice(&(*off as u32).to_le_bytes());
            // type_ids[i].descriptor_idx = i
            v[type_ids_off + i * 4..type_ids_off + i * 4 + 4]
                .copy_from_slice(&(i as u32).to_le_bytes());
            // class_defs[i].class_idx = i
            v[class_defs_off + i * 32..class_defs_off + i * 32 + 4]
                .copy_from_slice(&(i as u32).to_le_bytes());
        }
        v[data_off..].copy_from_slice(&data);
        v
    }

    #[test]
    fn detects_kotlin_and_compose_from_dex() {
        let apk = tmp_apk("dex");
        {
            let f = File::create(&apk).unwrap();
            let mut zip = zip::ZipWriter::new(f);
            let opts = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip.start_file("classes.dex", opts).unwrap();
            std::io::Write::write_all(
                &mut zip,
                &fake_dex_with_classes(&[
                    "Lkotlin/jvm/functions/Function1;",
                    "Landroidx/compose/ui/Modifier;",
                ]),
            )
            .unwrap();
            zip.finish().unwrap();
        }
        let f = scan_features(apk.to_str().unwrap()).unwrap();
        assert!(f.kotlin_used, "应识别 Kotlin");
        assert!(f.jetpack_compose, "应识别 Compose");
        assert!(!f.kmp);
        assert!(f.evidence.iter().any(|e| e.starts_with("dex:kotlin.")));
    }

    #[test]
    fn detects_from_zip_entries_without_dex() {
        let apk = tmp_apk("entries");
        {
            let f = File::create(&apk).unwrap();
            let mut zip = zip::ZipWriter::new(f);
            let opts = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip.start_file("kotlin-tooling-metadata.json", opts).unwrap();
            std::io::Write::write_all(&mut zip, b"{}").unwrap();
            zip.start_file("META-INF/xposed/module.prop", opts).unwrap();
            std::io::Write::write_all(&mut zip, b"name=X").unwrap();
            zip.start_file("androidx.compose.ui.version", opts).unwrap();
            std::io::Write::write_all(&mut zip, b"1.6.0").unwrap();
            zip.finish().unwrap();
        }
        let f = scan_features(apk.to_str().unwrap()).unwrap();
        assert!(f.kotlin_used);
        assert!(f.jetpack_compose);
        assert!(f.xposed_module);
    }

    #[test]
    fn reads_agp_version_from_app_metadata() {
        let apk = tmp_apk("agp");
        {
            let f = File::create(&apk).unwrap();
            let mut zip = zip::ZipWriter::new(f);
            let opts = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip.start_file("META-INF/com.example_app-metadata.properties", opts)
                .unwrap();
            std::io::Write::write_all(
                &mut zip,
                b"androidGradlePluginVersion=8.5.2\nother=1\n",
            )
            .unwrap();
            zip.finish().unwrap();
        }
        let f = scan_features(apk.to_str().unwrap()).unwrap();
        assert_eq!(f.agp_version, "8.5.2");
    }

    #[test]
    fn plain_apk_has_no_features() {
        let apk = tmp_apk("plain");
        {
            let f = File::create(&apk).unwrap();
            let mut zip = zip::ZipWriter::new(f);
            zip.start_file("classes.dex", zip::write::SimpleFileOptions::default())
                .unwrap();
            std::io::Write::write_all(&mut zip, &[0u8; 16]).unwrap();
            zip.finish().unwrap();
        }
        let f = scan_features(apk.to_str().unwrap()).unwrap();
        assert!(!f.kotlin_used);
        assert!(!f.jetpack_compose);
        assert!(!f.kmp);
        assert!(!f.xposed_module);
        assert!(!f.play_signing);
        assert!(!f.pwa);
        assert!(f.agp_version.is_empty());
    }

    #[test]
    fn malformed_dex_does_not_abort() {
        let apk = tmp_apk("badex");
        {
            let f = File::create(&apk).unwrap();
            let mut zip = zip::ZipWriter::new(f);
            let opts = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip.start_file("classes.dex", opts).unwrap();
            std::io::Write::write_all(&mut zip, &[0u8; 8]).unwrap();
            zip.start_file("kotlin-tooling-metadata.json", opts).unwrap();
            std::io::Write::write_all(&mut zip, b"{}").unwrap();
            zip.finish().unwrap();
        }
        // dex 解析失败只跳过，zip 证据仍应生效
        let f = scan_features(apk.to_str().unwrap()).unwrap();
        assert!(f.kotlin_used);
    }

    // ===== 纯函数版（聚合入口复用）=====

    #[test]
    fn detect_from_inputs_zip_entries() {
        let entries = vec![
            "kotlin-tooling-metadata.json".to_string(),
            "META-INF/xposed/module.prop".to_string(),
            "androidx.compose.ui.version".to_string(),
        ];
        let f = detect_features(None, &entries, &[], "");
        assert!(f.kotlin_used);
        assert!(f.xposed_module);
        assert!(f.jetpack_compose);
        assert!(!f.pwa);
    }

    #[test]
    fn detect_from_inputs_manifest_and_dex() {
        let manifest = ManifestInfo {
            meta_data: vec![
                MetaDataItem {
                    name: "com.android.stamp.source".into(),
                    value: "x".into(),
                },
                MetaDataItem {
                    name: "org.chromium.webapk.shell_apk.version".into(),
                    value: "1".into(),
                },
            ],
            permissions: vec![PermissionInfo {
                name: "android.permission.POST_PROMOTED_NOTIFICATIONS".into(),
                max_sdk_version: String::new(),
            }],
            components: vec![ComponentInfo {
                kind: "provider".into(),
                name: "org.jetbrains.compose.resources.AndroidContextProvider".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let dex = vec!["kotlin.jvm.functions.Function1".to_string()];
        let f = detect_features(Some(&manifest), &[], &dex, "8.7.2");
        assert!(f.play_signing);
        assert!(f.pwa);
        assert!(f.kmp);
        assert!(f.live_update_notification);
        assert!(f.kotlin_used);
        assert_eq!(f.agp_version, "8.7.2");
        assert!(f.evidence.contains(&"agp:8.7.2".to_string()));
    }

    #[test]
    fn detect_from_inputs_empty_is_all_false() {
        let f = detect_features(None, &[], &[], "");
        assert!(!f.kotlin_used);
        assert!(!f.jetpack_compose);
        assert!(!f.kmp);
        assert!(!f.xposed_module);
        assert!(!f.play_signing);
        assert!(!f.pwa);
        assert!(!f.live_update_notification);
        assert!(f.agp_version.is_empty());
        assert!(f.evidence.is_empty());
    }
}
