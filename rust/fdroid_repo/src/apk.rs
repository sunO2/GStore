use std::fs::File;
use std::io::Read;

use apk_info_axml::AXML;
use zip::ZipArchive;

use crate::models::ApkInfo;

/// 解析 APK 文件，提取真实包名/版本等信息
/// 在安装前调用，避免依赖安装结果判断包名
/// 实现：用 zip 读 APK 内 AndroidManifest.xml（二进制 AXML），用 apk-info-axml 解析
pub fn parse_apk_info(apk_path: String) -> Result<ApkInfo, String> {
    let file = File::open(&apk_path).map_err(|e| format!("无法打开 APK: {e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("APK 不是有效 zip: {e}"))?;

    let mut manifest_bytes = Vec::new();
    {
        let mut entry = archive
            .by_name("AndroidManifest.xml")
            .map_err(|e| format!("APK 缺少 AndroidManifest.xml: {e}"))?;
        entry.read_to_end(&mut manifest_bytes).map_err(|e| e.to_string())?;
    }

    let mut slice = manifest_bytes.as_slice();
    let axml = AXML::new(&mut slice, None).map_err(|e| format!("解析 manifest 失败: {e}"))?;

    let package_name = axml
        .get_attribute_value("manifest", "package", None)
        .unwrap_or_default();
    let version_name = axml
        .get_attribute_value("manifest", "versionName", None)
        .unwrap_or_default();
    let version_code = axml
        .get_attribute_value("manifest", "versionCode", None)
        .unwrap_or_default();
    let min_sdk = axml
        .get_attribute_value("uses-sdk", "minSdkVersion", None)
        .unwrap_or_default();
    let main_activity = axml
        .get_attribute_value("activity", "name", None)
        .unwrap_or_default();
    // label 可能是 @string 引用，无资源表时返回原始引用或空，兜底为空
    let app_name = axml
        .get_attribute_value("application", "label", None)
        .unwrap_or_default();

    Ok(ApkInfo {
        package_name,
        version_name,
        version_code,
        app_name,
        min_sdk,
        main_activity,
    })
}
