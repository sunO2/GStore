// gstore_mod_analyzer：APK 分析结果模型（模块内定义，序列化后经 C ABI 返回）
use serde::Serialize;

/// APK 元数据提取结果（安装前解析，避免依赖安装结果判断包名）
#[derive(Clone, Debug, Default, Serialize)]
pub struct ApkInfo {
    /// 真实包名（如 com.termux）
    pub package_name: String,
    /// 版本名（如 0.118.0）
    pub version_name: String,
    /// 版本码
    pub version_code: String,
    /// 应用名称
    pub app_name: String,
    /// 最低支持 SDK
    pub min_sdk: String,
    /// 主 Activity
    pub main_activity: String,
}
