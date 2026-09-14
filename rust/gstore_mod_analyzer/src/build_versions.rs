//! 构建版本检测（Kotlin / Gradle / Java / Compose / AGP）
//!
//! 对齐 LibChecker 的 `BuildMetadataEntries` / `readAgpVersion` / `readKotlinModuleVersions`：
//! - 主路径：根目录 `kotlin-tooling-metadata.json`
//! - 降级：`META-INF/*.kotlin_module` 二进制版本推断（仅当恰好一种 distinct 版本时采用）
//! - Compose：`META-INF/androidx.compose.*.version` 首行
//! - AGP：`META-INF/com/android/build/gradle/app-metadata.properties` 的
//!   `androidGradlePluginVersion`，兜底 `META-INF/MANIFEST.MF` 的 `Created-By: Android Gradle`
//!
//! 关键：条目清单来自**中央目录**，内容只解压上面这几个小文件——不做整包解压。

use std::fs::File;
use std::io::Read;

use serde::Deserialize;
use zip::ZipArchive;

/// Kotlin Android 插件名（LibChecker KOTLIN_ANDROID_PLUGIN）
const KOTLIN_ANDROID_PLUGIN: &str =
    "org.jetbrains.kotlin.gradle.plugin.KotlinAndroidPluginWrapper";

/// Kotlin Android target 名（LibChecker KOTLIN_ANDROID_TARGET）
const KOTLIN_ANDROID_TARGET: &str =
    "org.jetbrains.kotlin.gradle.plugin.mpp.KotlinAndroidTarget";

/// Gradle 构建系统名
const GRADLE_BUILD_SYSTEM: &str = "Gradle";

/// kotlin-tooling-metadata.json 条目名
const TOOLING_METADATA_ENTRY: &str = "kotlin-tooling-metadata.json";

/// AGP 元数据条目的后缀（LibChecker：`META-INF/*app-metadata.properties`）
const APP_METADATA_SUFFIX: &str = "app-metadata.properties";

/// MANIFEST.MF（AGP 兜底）
const MANIFEST_ENTRY: &str = "META-INF/MANIFEST.MF";

/// kotlin_module 版本分量的合法区间
const MIN_VERSION_COMPONENTS: i32 = 2;
const MAX_VERSION_COMPONENTS: i32 = 16;
const MIN_VERSION_NUMBER: i32 = 0;
const MAX_VERSION_NUMBER: i32 = 99;

/// 构建版本信息（全部为原始字符串，未识别为 ""）
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct BuildVersions {
    pub kotlin_version: String,
    pub gradle_version: String,
    pub java_version: String,
    pub compose_version: String,
    pub agp_version: String,
}

/// 从已打开的 APK 归档检测构建版本（只解压少量小条目）
pub fn detect_build_versions_from(archive: &mut ZipArchive<File>) -> BuildVersions {
    // 1) 中央目录遍历：只挑出候选条目名，不解压
    let mut tooling: Option<String> = None;
    let mut compose: Option<String> = None;
    let mut app_metadata: Option<String> = None;
    let mut manifest: Option<String> = None;
    let mut kotlin_modules: Vec<String> = Vec::new();

    for index in 0..archive.len() {
        let Ok(entry) = archive.by_index(index) else {
            continue;
        };
        if entry.is_dir() {
            continue;
        }
        let name = entry.name().to_string();
        if name == TOOLING_METADATA_ENTRY {
            tooling = Some(name);
        } else if compose.is_none()
            && name.starts_with("META-INF/androidx.compose.")
            && name.ends_with(".version")
        {
            compose = Some(name);
        } else if app_metadata.is_none()
            && name.starts_with("META-INF/")
            && name.ends_with(APP_METADATA_SUFFIX)
        {
            app_metadata = Some(name);
        } else if manifest.is_none() && name == MANIFEST_ENTRY {
            manifest = Some(name);
        } else if name.starts_with("META-INF/") && name.ends_with(".kotlin_module") {
            kotlin_modules.push(name);
        }
    }

    // 2) 只解压这几个候选条目
    let mut result = BuildVersions::default();

    if let Some(name) = compose.as_deref() {
        if let Some(text) = read_entry_text(archive, name) {
            result.compose_version = text.lines().next().unwrap_or("").trim().to_string();
        }
    }
    if let Some(name) = app_metadata.as_deref() {
        if let Some(text) = read_entry_text(archive, name) {
            result.agp_version = property_value(&text, "androidGradlePluginVersion=")
                .unwrap_or_default();
        }
    }
    if result.agp_version.is_empty() {
        if let Some(name) = manifest.as_deref() {
            if let Some(text) = read_entry_text(archive, name) {
                result.agp_version =
                    property_value(&text, "Created-By: Android Gradle ").unwrap_or_default();
            }
        }
    }

    // 主路径：kotlin-tooling-metadata.json
    if let Some(name) = tooling.as_deref() {
        if let Some(bytes) = read_entry_bytes(archive, name) {
            let tooling_versions = parse_tooling_metadata(&bytes);
            result.kotlin_version = tooling_versions.kotlin_version;
            result.gradle_version = tooling_versions.gradle_version;
            result.java_version = tooling_versions.java_version;
        }
    }

    // 降级：*.kotlin_module 二进制版本推断（仅当恰好一种 distinct 版本）
    if result.kotlin_version.is_empty() {
        let mut versions: Vec<String> = Vec::new();
        for name in &kotlin_modules {
            if let Some(bytes) = read_entry_bytes(archive, name) {
                if let Some(v) = kotlin_module_version(&bytes) {
                    if !versions.contains(&v) {
                        versions.push(v);
                    }
                    if versions.len() > 1 {
                        break; // 多于一种即不采用，无需继续
                    }
                }
            }
        }
        if versions.len() == 1 {
            result.kotlin_version = versions.remove(0);
        }
    }

    result
}

/// 独立入口：自行打开 APK
pub fn detect_build_versions(apk_path: &str) -> Result<BuildVersions, String> {
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive =
        ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;
    Ok(detect_build_versions_from(&mut archive))
}

// ===== 内部工具 =====

fn read_entry_bytes(archive: &mut ZipArchive<File>, name: &str) -> Option<Vec<u8>> {
    let mut entry = archive.by_name(name).ok()?;
    let mut buf = Vec::new();
    entry.read_to_end(&mut buf).ok()?;
    Some(buf)
}

fn read_entry_text(archive: &mut ZipArchive<File>, name: &str) -> Option<String> {
    let bytes = read_entry_bytes(archive, name)?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

/// 逐行找 `prefix` 开头的属性，返回其后的值（空值 → None）
fn property_value(text: &str, prefix: &str) -> Option<String> {
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix(prefix) {
            let value = rest.trim();
            return if value.is_empty() {
                None
            } else {
                Some(value.to_string())
            };
        }
    }
    None
}

#[derive(Deserialize, Default)]
struct ToolingMetadata {
    #[serde(rename = "buildSystem", default)]
    build_system: String,
    #[serde(rename = "buildSystemVersion", default)]
    build_system_version: String,
    #[serde(rename = "buildPlugin", default)]
    build_plugin: String,
    #[serde(rename = "buildPluginVersion", default)]
    build_plugin_version: String,
    #[serde(rename = "projectTargets", default)]
    project_targets: Vec<ToolingTarget>,
}

#[derive(Deserialize, Default)]
struct ToolingTarget {
    #[serde(default)]
    target: String,
    #[serde(default)]
    extras: Option<ToolingExtras>,
}

#[derive(Deserialize, Default)]
struct ToolingExtras {
    #[serde(default)]
    android: Option<ToolingAndroid>,
}

#[derive(Deserialize, Default)]
struct ToolingAndroid {
    #[serde(rename = "sourceCompatibility", default)]
    source_compatibility: String,
}

/// 解析 kotlin-tooling-metadata.json（与 Dart/LibChecker 语义一致）
fn parse_tooling_metadata(bytes: &[u8]) -> BuildVersions {
    let Ok(meta) = serde_json::from_slice::<ToolingMetadata>(bytes) else {
        return BuildVersions::default();
    };

    // 只取首个 KotlinAndroidTarget
    let mut has_android_target = false;
    let mut source_compatibility = String::new();
    for target in &meta.project_targets {
        if target.target != KOTLIN_ANDROID_TARGET {
            continue;
        }
        has_android_target = true;
        if let Some(android) = target.extras.as_ref().and_then(|e| e.android.as_ref()) {
            source_compatibility = android.source_compatibility.clone();
        }
        break;
    }

    let kotlin_version = if !meta.build_plugin_version.is_empty()
        && (meta.build_plugin == KOTLIN_ANDROID_PLUGIN || has_android_target)
    {
        meta.build_plugin_version
    } else {
        String::new()
    };
    let gradle_version =
        if meta.build_system == GRADLE_BUILD_SYSTEM && !meta.build_system_version.is_empty() {
            meta.build_system_version
        } else {
            String::new()
        };
    let java_version = if !source_compatibility.is_empty() && is_all_digits(&source_compatibility) {
        source_compatibility
    } else {
        String::new()
    };

    BuildVersions {
        kotlin_version,
        gradle_version,
        java_version,
        ..Default::default()
    }
}

fn is_all_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// `META-INF/*.kotlin_module` 头部版本推断（**大端** int32，与 DataInputStream 一致）
fn kotlin_module_version(bytes: &[u8]) -> Option<String> {
    if bytes.len() < 4 {
        return None;
    }
    let component_count = i32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    if !(MIN_VERSION_COMPONENTS..=MAX_VERSION_COMPONENTS).contains(&component_count) {
        return None;
    }
    let needed = 4 + (component_count as usize) * 4;
    if bytes.len() < needed {
        return None;
    }
    let mut components = Vec::with_capacity(component_count as usize);
    for i in 0..component_count as usize {
        let off = 4 + i * 4;
        let value = i32::from_be_bytes([bytes[off], bytes[off + 1], bytes[off + 2], bytes[off + 3]]);
        if !(MIN_VERSION_NUMBER..=MAX_VERSION_NUMBER).contains(&value) {
            return None;
        }
        components.push(value);
    }
    if components.len() < 2 {
        return None;
    }
    Some(format!("{}.{}.x", components[0], components[1]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tooling_metadata_full_match() {
        let json = serde_json::json!({
            "buildSystem": "Gradle",
            "buildSystemVersion": "8.7",
            "buildPlugin": KOTLIN_ANDROID_PLUGIN,
            "buildPluginVersion": "2.0.21",
            "projectTargets": [{
                "target": KOTLIN_ANDROID_TARGET,
                "extras": {"android": {"sourceCompatibility": "17"}}
            }]
        })
        .to_string();
        let v = parse_tooling_metadata(json.as_bytes());
        assert_eq!(v.kotlin_version, "2.0.21");
        assert_eq!(v.gradle_version, "8.7");
        assert_eq!(v.java_version, "17");
    }

    #[test]
    fn tooling_metadata_rejects_mismatched_system() {
        let json = serde_json::json!({
            "buildSystem": "Maven",
            "buildSystemVersion": "3.9",
            "buildPlugin": "other",
            "buildPluginVersion": "1.2.3"
        })
        .to_string();
        let v = parse_tooling_metadata(json.as_bytes());
        assert!(v.kotlin_version.is_empty()); // 插件不匹配
        assert!(v.gradle_version.is_empty()); // 非 Gradle
    }

    #[test]
    fn tooling_metadata_android_target_accepts_unknown_plugin() {
        let json = serde_json::json!({
            "buildPlugin": "some.other.plugin",
            "buildPluginVersion": "1.9.0",
            "projectTargets": [{"target": KOTLIN_ANDROID_TARGET}]
        })
        .to_string();
        let v = parse_tooling_metadata(json.as_bytes());
        assert_eq!(v.kotlin_version, "1.9.0"); // 有 Android target 即接受
    }

    #[test]
    fn source_compatibility_must_be_numeric() {
        let json = serde_json::json!({
            "projectTargets": [{
                "target": KOTLIN_ANDROID_TARGET,
                "extras": {"android": {"sourceCompatibility": "VERSION_17"}}
            }]
        })
        .to_string();
        let v = parse_tooling_metadata(json.as_bytes());
        assert!(v.java_version.is_empty());
    }

    #[test]
    fn property_value_reads_first_match() {
        let text = "# comment\nandroidGradlePluginVersion=8.5.2\nother=1\n";
        assert_eq!(
            property_value(text, "androidGradlePluginVersion=").as_deref(),
            Some("8.5.2")
        );
        assert_eq!(property_value(text, "missing="), None);
    }

    #[test]
    fn created_by_fallback() {
        let text = "Manifest-Version: 1.0\nCreated-By: Android Gradle 8.1.0\n";
        assert_eq!(
            property_value(text, "Created-By: Android Gradle ").as_deref(),
            Some("8.1.0")
        );
    }

    #[test]
    fn kotlin_module_version_reads_big_endian() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&3i32.to_be_bytes()); // 3 段
        bytes.extend_from_slice(&1i32.to_be_bytes());
        bytes.extend_from_slice(&9i32.to_be_bytes());
        bytes.extend_from_slice(&0i32.to_be_bytes());
        assert_eq!(kotlin_module_version(&bytes).as_deref(), Some("1.9.x"));
    }

    #[test]
    fn kotlin_module_version_rejects_out_of_range() {
        // 段数超界
        let mut too_many = Vec::new();
        too_many.extend_from_slice(&20i32.to_be_bytes());
        too_many.extend_from_slice(&[0u8; 4 * 20]);
        assert!(kotlin_module_version(&too_many).is_none());

        // 分量超界（>99）
        let mut bad_value = Vec::new();
        bad_value.extend_from_slice(&2i32.to_be_bytes());
        bad_value.extend_from_slice(&1i32.to_be_bytes());
        bad_value.extend_from_slice(&100i32.to_be_bytes());
        assert!(kotlin_module_version(&bad_value).is_none());

        // 长度不足
        assert!(kotlin_module_version(&[0, 0, 0]).is_none());
    }
}
