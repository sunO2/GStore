// 数据模型定义
use serde::{Deserialize, Serialize};

/// F-Droid 应用信息
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AppInfo {
    pub package_name: String,
    pub name: String,
    pub summary: String,
    pub icon: String,
    pub license: Option<String>,
    pub author_name: Option<String>,
    pub source_code: Option<String>,
    pub web_site: Option<String>,
    pub categories: Vec<String>,
    pub added: Option<i64>,
    pub last_updated: Option<i64>,
    /// 原始 metadata JSON 字符串
    pub metadata: Option<String>,
    /// 原始 versions JSON 字符串
    pub versions: Option<String>,
}

/// F-Droid 包信息
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PackageInfo {
    pub package_name: String,
    pub apk_name: String,
    pub version_name: String,
    pub version_code: i32,
    pub size: i64,
    pub hash: Option<String>,
    pub signer: Option<String>,
    pub min_sdk_version: Option<i32>,
    pub target_sdk_version: Option<i32>,
}

/// 下载结果
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DownloadResult {
    pub total_apps: i32,
    pub download_time_ms: i32,
}
