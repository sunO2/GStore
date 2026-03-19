// Flutter FFI Bridge - 暴露给 Dart 的接口
use flutter_rust_bridge::frb;
use super::models::*;
use super::repo::*;

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
