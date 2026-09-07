// Flutter FFI Bridge - 暴露给 Dart 的接口
use flutter_rust_bridge::frb;
use super::apk::*;
use super::models::*;
use super::repo::*;

/// APK 解析结果（结构体将自动生成 Dart 侧对应类）
pub use crate::models::ApkInfo;

/// Manifest 组件枚举结果（结构体将自动生成 Dart 侧对应类）
pub use crate::components::ApkComponents;

impl FdroidRepoManager {
    /// 解析 APK 文件，提取真实包名/版本/应用名等信息
    /// 在安装前调用，避免依赖安装结果判断包名
    pub fn parse_apk_info(&self, apk_path: String) -> Result<ApkInfo, String> {
        crate::apk::parse_apk_info(apk_path)
    }

    /// 扫描 APK 内所有 classes*.dex 的类名，与 class patterns 匹配
    ///
    /// patterns 为 LibChecker `matchesClassPattern` 语义：
    /// 以 `*` 结尾 → 前缀匹配（`androidx.lifecycle.*` 命中 `androidx.lifecycle.LiveData`）；
    /// 否则整串精确匹配。
    ///
    /// 规则 name 列（rules.db DEX 规则）为点分格式（如 `com.tencent.smtt`），
    /// 本函数返回的类名也已转换为点分格式，与规则直接可比。
    pub fn scan_dex_classes(
        &self,
        apk_path: String,
        patterns: Vec<String>,
    ) -> Result<Vec<String>, String> {
        crate::dex_scan::scan_dex_classes(&apk_path, &patterns)
    }

    /// 解析 APK 的 AndroidManifest.xml，枚举四类组件完整类名
    /// （activity 含 activity-alias）与 minSdk/targetSdk。
    ///
    /// 相对类名（`.Foo`）按 Android 语义补全为 `<package>.Foo`。
    /// 与 LibChecker 从 PackageManager 读已安装应用组件等价。
    pub fn parse_components(&self, apk_path: String) -> Result<ApkComponents, String> {
        crate::components::parse_components(&apk_path)
    }
}

/// F-Droid 仓库管理器
#[frb(opaque)]
pub struct FdroidRepoManager {
    pub manager: Option<RepoManager>,
}

impl FdroidRepoManager {
    /// 创建新实例（构造函数）
    #[frb(init)]
    pub fn new() -> Self {
        Self {
            manager: None,
        }
    }

    /// 初始化管理器
    pub fn initialize(&mut self, db_path: String) -> Result<(), String> {
        // 初始化 Android logger
        #[cfg(target_os = "android")]
        android_logger::init_once(
            android_logger::Config::default()
                .with_max_level(log::LevelFilter::Info)
                .with_tag("FdroidRust")
        );

        match RepoManager::new(&db_path) {
            Ok(manager) => {
                self.manager = Some(manager);
                Ok(())
            }
            Err(e) => Err(e.to_string()),
        }
    }

    /// 下载并解析 F-Droid 仓库（异步）
    pub async fn download_repo(&self, repo_url: String) -> Result<DownloadResult, String> {
        let manager = self.manager.as_ref().ok_or("Manager not initialized")?;
        manager.download_repo(&repo_url).await
    }

    /// 获取应用数量
    pub fn get_app_count(&self) -> Result<i32, String> {
        let manager = self.manager.as_ref().ok_or("Manager not initialized")?;
        manager.get_app_count().map_err(|e| e.to_string())
    }

    /// 搜索应用
    pub fn search_apps(&self, keyword: String, limit: i32) -> Result<Vec<AppInfo>, String> {
        let manager = self.manager.as_ref().ok_or("Manager not initialized")?;
        manager.search_apps(&keyword, limit).map_err(|e| e.to_string())
    }

    /// 清空所有应用数据
    pub fn clear_apps(&self) -> Result<i32, String> {
        let manager = self.manager.as_ref().ok_or("Manager not initialized")?;
        manager.clear_apps()
    }

    /// 获取一个应用（用于调试）
    pub fn get_one_app(&self) -> Result<Option<AppInfo>, String> {
        let manager = self.manager.as_ref().ok_or("Manager not initialized")?;
        manager.get_one_app()
    }

    /// 根据包名获取应用详情（包含 metadata 和 versions）
    pub fn get_app_detail(&self, package_name: String) -> Result<Option<AppInfo>, String> {
        let manager = self.manager.as_ref().ok_or("Manager not initialized")?;
        manager.get_app_by_package_name(&package_name)
    }
}

/// 进度回调（占位符，暂时不使用）
pub struct FlutterProgressCallback {}

impl FlutterProgressCallback {
    #[frb(init)]
    pub fn new() -> Self {
        Self {}
    }
}
