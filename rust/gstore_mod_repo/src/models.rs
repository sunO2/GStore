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
    /// 实际生效的仓库地址（可能是自动发现得到的 `<host>/fdroid/repo`）
    #[serde(default)]
    pub resolved_url: String,
    /// 是否通过 entry.json 的 SHA-256 完整性校验
    #[serde(default)]
    pub verified: bool,
    /// 索引内声明的镜像数量
    #[serde(default)]
    pub mirror_count: i32,
    /// 索引 `repo` 头部给出的仓库名称（可自动回填，不必手填配置）
    #[serde(default)]
    pub repo_name: String,
    /// 仓库签名指纹（从 JAR 签名提取；空 = 未取到）
    pub signer_fingerprint: String,
    /// 本次是否走了**增量更新**（entry.json + diff 合并）
    #[serde(default)]
    pub incremental: bool,
}
