// 数据模型定义（repo 模块专属：AppInfo / DownloadResult）
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

/// 下载结果
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DownloadResult {
    pub total_apps: i32,
    pub download_time_ms: i32,
}
