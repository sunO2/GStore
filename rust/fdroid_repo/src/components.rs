//! APK Manifest 组件枚举（LibChecker 组件规则检测的 Rust 实现）
//!
//! 输入：APK 路径。输出：AndroidManifest.xml（AXML）中四类组件的完整类名
//! （`android:name`），相对名（以 `.` 开头）按 Android 语义补全为
//! `<package><name>`；同时返回 minSdk/targetSdk 供详情展示。
//!
//! 与 LibChecker 的对齐说明：
//! - LibChecker 从 PackageManager 读取已安装应用的 services/activities/
//!   receivers/providers；本实现从 APK 文件（AXML）直接解析，二者来源一致
//!   （`getAllAttributeValues(tag, name)` 枚举全部同名标签，含 activity-alias）。
//! - 匹配语义对齐 `RuleStore.findRule(name, type, useRegex=true)`：
//!   先精确（name == rule.name），再对 isRegexRule=1 的规则做整串正则匹配。

use std::fs::File;
use std::io::Read;

use apk_info_axml::AXML;
use zip::ZipArchive;

/// Manifest 组件枚举结果
#[derive(Clone, Debug, Default)]
pub struct ApkComponents {
    /// 应用包名（manifest/package）
    pub package_name: String,
    /// minSdkVersion（uses-sdk）
    pub min_sdk: String,
    /// targetSdkVersion（uses-sdk）
    pub target_sdk: String,
    /// <service> 完整类名
    pub services: Vec<String>,
    /// <activity> + <activity-alias> 完整类名
    pub activities: Vec<String>,
    /// <receiver> 完整类名
    pub receivers: Vec<String>,
    /// <provider> 完整类名
    pub providers: Vec<String>,
}

/// 解析 APK 的 AndroidManifest.xml，枚举四类组件名与 SDK 版本。
pub fn parse_components(apk_path: &str) -> Result<ApkComponents, String> {
    let file = File::open(apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;

    let mut manifest_bytes = Vec::new();
    {
        let mut entry = archive
            .by_name("AndroidManifest.xml")
            .map_err(|e| format!("APK 缺少 AndroidManifest.xml: {e}"))?;
        entry
            .read_to_end(&mut manifest_bytes)
            .map_err(|e| e.to_string())?;
    }

    let mut slice = manifest_bytes.as_slice();
    let axml = AXML::new(&mut slice, None).map_err(|e| format!("解析 manifest 失败: {e}"))?;

    let package_name = axml
        .get_attribute_value("manifest", "package", None)
        .unwrap_or_default();
    let min_sdk = axml
        .get_attribute_value("uses-sdk", "minSdkVersion", None)
        .unwrap_or_default();
    let target_sdk = axml
        .get_attribute_value("uses-sdk", "targetSdkVersion", None)
        .unwrap_or_default();

    let resolve = |name: &str| resolve_component_name(name, &package_name);

    let mut services: Vec<String> = axml
        .get_all_attribute_values("service", "name")
        .map(resolve)
        .collect();
    let mut activities: Vec<String> = axml
        .get_all_attribute_values("activity", "name")
        .map(resolve)
        .collect();
    activities.extend(
        axml.get_all_attribute_values("activity-alias", "name")
            .map(resolve),
    );
    let mut receivers: Vec<String> = axml
        .get_all_attribute_values("receiver", "name")
        .map(resolve)
        .collect();
    let mut providers: Vec<String> = axml
        .get_all_attribute_values("provider", "name")
        .map(resolve)
        .collect();

    // 去重排序（AXML 枚举可能含重复/别名指向同一类名）
    dedup_sort(&mut services);
    dedup_sort(&mut activities);
    dedup_sort(&mut receivers);
    dedup_sort(&mut providers);

    Ok(ApkComponents {
        package_name,
        min_sdk,
        target_sdk,
        services,
        activities,
        receivers,
        providers,
    })
}

/// 相对类名（`.Foo`）补全为 `packageName.Foo`（Android 解析语义）；
/// 其余原样返回。
pub fn resolve_component_name(name: &str, package_name: &str) -> String {
    if let Some(rest) = name.strip_prefix('.') {
        if package_name.is_empty() {
            name.to_string()
        } else {
            format!("{package_name}.{rest}")
        }
    } else {
        name.to_string()
    }
}

fn dedup_sort(list: &mut Vec<String>) {
    list.sort();
    list.dedup();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_relative_names() {
        assert_eq!(
            resolve_component_name(".MainActivity", "com.example.demo"),
            "com.example.demo.MainActivity"
        );
        assert_eq!(
            resolve_component_name("com.tencent.smtt.X5Service", "com.example.demo"),
            "com.tencent.smtt.X5Service"
        );
        // 无包名时保留原样
        assert_eq!(resolve_component_name(".Foo", ""), ".Foo");
    }

    #[test]
    fn dedup_sorts() {
        let mut list = vec![
            "com.b.B".to_string(),
            "com.a.A".to_string(),
            "com.b.B".to_string(),
        ];
        dedup_sort(&mut list);
        assert_eq!(list, vec!["com.a.A", "com.b.B"]);
    }

    #[test]
    fn missing_manifest_errors() {
        let dir = std::env::temp_dir().join(format!(
            "gstore_components_test_{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).ok();
        let apk_path = dir.join("empty_test.apk");
        let file = File::create(&apk_path).ok();
        if let Some(file) = file {
            let mut zip = zip::ZipWriter::new(file);
            zip.start_file("classes.dex", zip::write::SimpleFileOptions::default())
                .ok();
            std::io::Write::write_all(&mut zip, &[0u8; 16]).ok();
            zip.finish().ok();
        }
        let err = parse_components(apk_path.to_str().unwrap()).unwrap_err();
        assert!(err.contains("AndroidManifest.xml"));
    }

    #[test]
    fn nonexistent_apk_errors() {
        let err = parse_components("/no/such/file.apk").unwrap_err();
        assert!(err.contains("无法打开 APK"));
    }
}
