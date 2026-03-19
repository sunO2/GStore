// F-Droid 仓库管理器实现
use rusqlite::{Connection, Result as SqliteResult, ToSql};
use std::sync::{Arc, Mutex};
use crate::models::*;

// 调试打印宏
macro_rules! debug_print {
    ($($arg:tt)*) => {
        #[cfg(target_os = "android")]
        log::info!($($arg)*);

        #[cfg(not(target_os = "android"))]
        println!($($arg)*);
    };
}

/// 仓库管理器 (简化版)
pub struct RepoManager {
    db: Arc<Mutex<Connection>>,
}

impl RepoManager {
    /// 创建新的管理器
    pub fn new(db_path: &str) -> Result<Self, String> {
        let conn = Connection::open(db_path)
            .map_err(|e| format!("Failed to open database: {}", e))?;

        // 创建表
        Self::init_database(&conn)
            .map_err(|e| format!("Failed to init database: {}", e))?;

        Ok(RepoManager {
            db: Arc::new(Mutex::new(conn)),
        })
    }

    /// 初始化数据库表
    fn init_database(conn: &Connection) -> SqliteResult<()> {
        // 仓库索引表（所有应用，用于搜索）
        conn.execute(
            "CREATE TABLE IF NOT EXISTS apps (
                package_name TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                summary TEXT,
                icon TEXT,
                license TEXT,
                author_name TEXT,
                source_code TEXT,
                web_site TEXT,
                categories TEXT,
                added INTEGER,
                last_updated INTEGER,
                metadata TEXT,
                versions TEXT
            )",
            [],
        )?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_apps_name ON apps(name)",
            [],
        )?;

        conn.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS apps_fts USING fts5(name, summary)",
            [],
        )?;

        Ok(())
    }

    /// 下载并解析 F-Droid 仓库索引
    pub async fn download_repo(&self, repo_url: &str) -> Result<DownloadResult, String> {
        let start = std::time::Instant::now();

        debug_print!("Starting download from: {}", repo_url);

        let client = reqwest::Client::builder()
            .build()
            .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

        // 首先尝试 index-v2.json (新版格式 - 纯JSON)
        let index_v2_url = format!("{}/index-v2.json", repo_url.trim_end_matches('/'));
        debug_print!("Trying index-v2.json: {}", index_v2_url);

        let result_v2 = client.get(&index_v2_url).send().await;

        let apps = if let Ok(resp) = result_v2 {
            if resp.status().is_success() {
                debug_print!("Found index-v2.json, using JSON format");
                let json_bytes = resp.bytes().await
                    .map_err(|e| format!("Failed to read index-v2.json: {}", e))?;
                self.parse_index_v2_json(&json_bytes)?
            } else {
                debug_print!("index-v2.json not found ({}), trying index-v1.jar", resp.status());
                // index-v2 不存在，尝试 index-v1
                let index_v1_url = format!("{}/index-v1.jar", repo_url.trim_end_matches('/'));
                debug_print!("Downloading index-v1.jar: {}", index_v1_url);

                let resp_v1 = client.get(&index_v1_url).send().await
                    .map_err(|e| format!("Failed to download index-v1.jar: {}", e))?;

                if !resp_v1.status().is_success() {
                    return Err(format!("Both index-v2.json and index-v1.jar failed: v2={}, v1={}",
                        resp.status(), resp_v1.status()));
                }

                let jar_bytes = resp_v1.bytes().await
                    .map_err(|e| format!("Failed to read index-v1.jar: {}", e))?;
                self.parse_index_v1_jar(&jar_bytes)?
            }
        } else {
            // 请求失败，尝试 index-v1
            debug_print!("Failed to request index-v2.json, trying index-v1.jar");
            let index_v1_url = format!("{}/index-v1.jar", repo_url.trim_end_matches('/'));
            debug_print!("Downloading index-v1.jar: {}", index_v1_url);

            let resp_v1 = client.get(&index_v1_url).send().await
                .map_err(|e| format!("Failed to download index-v1.jar: {}", e))?;

            if !resp_v1.status().is_success() {
                return Err(format!("index-v1.jar failed: {}", resp_v1.status()));
            }

            let jar_bytes = resp_v1.bytes().await
                .map_err(|e| format!("Failed to read index-v1.jar: {}", e))?;
            self.parse_index_v1_jar(&jar_bytes)?
        };

        // 保存到数据库
        let count = self.save_apps(&apps)?;

        let elapsed = start.elapsed();

        debug_print!("Download complete: {} apps in {}ms", count, elapsed.as_millis());

        Ok(DownloadResult {
            total_apps: count,
            download_time_ms: elapsed.as_millis() as i32,
        })
    }

    /// 解析 index-v1.jar 文件 (XML 格式)
    fn parse_index_v1_jar(&self, jar_bytes: &[u8]) -> Result<Vec<AppInfo>, String> {
        use std::io::Read;

        debug_print!("Parsing index-v1.jar (XML format)");

        let mut zip_archive = zip::ZipArchive::new(std::io::Cursor::new(jar_bytes))
            .map_err(|e| format!("Failed to parse JAR: {}", e))?;

        // 查找 index.xml - 先检查哪个文件存在
        let xml_path = if zip_archive.by_name("index.xml").is_ok() {
            debug_print!("Found XML file: index.xml");
            "index.xml"
        } else {
            debug_print!("index.xml not found, trying src/index.xml");
            if zip_archive.by_name("src/index.xml").is_ok() {
                debug_print!("Found XML file: src/index.xml");
                "src/index.xml"
            } else {
                return Err("XML file not found in JAR".to_string());
            }
        };

        // 现在重新打开文件以读取内容
        let mut entry_file = zip_archive.by_name(xml_path)
            .map_err(|e| format!("Failed to open {}: {}", xml_path, e))?;

        let mut xml_bytes = Vec::new();
        entry_file.read_to_end(&mut xml_bytes)
            .map_err(|e| format!("Failed to read XML: {}", e))?;

        // 解析 XML
        let xml_str = std::str::from_utf8(&xml_bytes)
            .map_err(|e| format!("Failed to parse XML UTF-8: {}", e))?;

        self.parse_index_v1_xml_simple(xml_str)
    }

    /// 解析 index-v1 XML 内容（简化版）
    fn parse_index_v1_xml_simple(&self, xml: &str) -> Result<Vec<AppInfo>, String> {
        debug_print!("Parsing index-v1 XML, length: {}", xml.len());

        let mut apps = Vec::new();
        let lines = xml.lines();

        let mut current_pkg_name = String::new();
        let mut current_name = String::new();
        let mut current_summary = String::new();
        let mut current_icon = String::new();
        let mut current_license: Option<String> = None;
        let mut current_source: Option<String> = None;
        let mut current_web: Option<String> = None;
        let mut current_added: Option<i64> = None;
        let mut current_categories: Vec<String> = Vec::new();

        for line in lines {
            let line = line.trim();

            if line.contains("<application") {
                // 开始新的应用
                current_pkg_name.clear();
                current_name.clear();
                current_summary.clear();
                current_icon.clear();
                current_license = None;
                current_source = None;
                current_web = None;
                current_added = None;
                current_categories.clear();
            } else if line.contains("</application>") {
                // 应用结束，保存
                if !current_pkg_name.is_empty() {
                    apps.push(AppInfo {
                        package_name: current_pkg_name.clone(),
                        name: current_name.clone(),
                        summary: current_summary.clone(),
                        icon: current_icon.clone(),
                        license: current_license.take(),
                        author_name: None, // v1 格式中没有
                        source_code: current_source.take(),
                        web_site: current_web.take(),
                        categories: current_categories.clone(),
                        added: current_added,
                        last_updated: None, // v1 格式中没有
                        metadata: None,     // v1 格式中没有
                        versions: None,     // v1 格式中没有
                    });
                }
            } else {
                // 解析字段
                if let Some(start) = line.find("<id>") {
                    if let Some(end) = line.find("</id>") {
                        current_pkg_name = line[start + 4..end].trim().to_string();
                    }
                } else if let Some(start) = line.find("<name>") {
                    if let Some(end) = line.find("</name>") {
                        current_name = line[start + 6..end].trim().to_string();
                    }
                } else if let Some(start) = line.find("<summary>") {
                    if let Some(end) = line.find("</summary>") {
                        current_summary = line[start + 10..end].trim().to_string();
                    }
                } else if let Some(start) = line.find("<icon>") {
                    if let Some(end) = line.find("</icon>") {
                        current_icon = line[start + 7..end].trim().to_string();
                    }
                } else if let Some(start) = line.find("<license>") {
                    if let Some(end) = line.find("</license>") {
                        current_license = Some(line[start + 10..end].trim().to_string());
                    }
                } else if let Some(start) = line.find("<source>") {
                    if let Some(end) = line.find("</source>") {
                        current_source = Some(line[start + 9..end].trim().to_string());
                    }
                } else if let Some(start) = line.find("<web>") {
                    if let Some(end) = line.find("</web>") {
                        current_web = Some(line[start + 6..end].trim().to_string());
                    }
                } else if let Some(start) = line.find("<added>") {
                    if let Some(end) = line.find("</added>") {
                        let ts = line[start + 7..end].trim();
                        if let Ok(ts) = ts.parse::<i64>() {
                            current_added = Some(ts);
                        }
                    }
                } else if line.contains("<category>") {
                    // category 标签格式：<category>Category Name</category>
                    if let Some(start) = line.find(">") {
                        if let Some(end) = line.find("</category>") {
                            let cat = line[start + 1..end].trim();
                            if !cat.is_empty() {
                                current_categories.push(cat.to_string());
                            }
                        }
                    }
                }
            }
        }

        debug_print!("Parsed {} apps from index-v1", apps.len());
        Ok(apps)
    }

    /// 解析 index-v2.json 文件 (纯JSON格式)
    fn parse_index_v2_json(&self, json_bytes: &[u8]) -> Result<Vec<AppInfo>, String> {
        debug_print!("Parsing index-v2.json (pure JSON format)");

        // 直接解析JSON（不需要解压JAR）
        let json: serde_json::Value = serde_json::from_slice(json_bytes)
            .map_err(|e| format!("Failed to parse index-v2.json: {}", e))?;

        // 提取应用列表
        let mut apps = Vec::new();

        if let Some(packages) = json.get("packages").and_then(|v| v.as_object()) {
            for (package_name, package_data) in packages {
                // 传递完整的 package_data，包含 metadata 和 versions
                if let Ok(app_info) = AppInfo::from_json_value_v2(package_name, package_data) {
                    apps.push(app_info);
                }
            }
        }

        debug_print!("Parsed {} apps from index-v2", apps.len());
        Ok(apps)
    }
    pub fn save_apps(&self, apps: &[AppInfo]) -> Result<i32, String> {
        let conn = self.db.lock()
            .map_err(|e| format!("Failed to lock database: {}", e))?;

        let tx = conn.unchecked_transaction()
            .map_err(|e| format!("Failed to begin transaction: {}", e))?;

        let mut count = 0;

        for app in apps {
            match self.insert_app(&tx, app) {
                Ok(_) => count += 1,
                Err(e) => {
                    eprintln!("Warning: Failed to insert app {}: {}", app.package_name, e);
                }
            }
        }

        tx.commit()
            .map_err(|e| format!("Failed to commit: {}", e))?;

        Ok(count)
    }

    /// 插入单个应用到数据库
    fn insert_app(&self, tx: &Connection, app: &AppInfo) -> SqliteResult<()> {
        tx.execute(
            "INSERT OR REPLACE INTO apps (
                package_name, name, summary, icon, license, author_name,
                source_code, web_site, categories, added, last_updated,
                metadata, versions
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            [
                &app.package_name as &dyn ToSql,
                &app.name as &dyn ToSql,
                &app.summary as &dyn ToSql,
                &app.icon as &dyn ToSql,
                &app.license.as_deref() as &dyn ToSql,
                &app.author_name.as_deref() as &dyn ToSql,
                &app.source_code.as_deref() as &dyn ToSql,
                &app.web_site.as_deref() as &dyn ToSql,
                &app.categories.join(",") as &dyn ToSql,
                &app.added as &dyn ToSql,
                &app.last_updated as &dyn ToSql,
                &app.metadata.as_deref() as &dyn ToSql,
                &app.versions.as_deref() as &dyn ToSql,
            ],
        )?;
        Ok(())
    }

    /// 获取应用数量
    pub fn get_app_count(&self) -> Result<i32, String> {
        let conn = self.db.lock()
            .map_err(|e| format!("Failed to lock database: {}", e))?;

        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM apps",
            [],
            |row| row.get(0),
        ).map_err(|e| format!("Query failed: {}", e))?;

        Ok(count as i32)
    }

    /// 搜索应用
    pub fn search_apps(&self, keyword: &str, limit: i32) -> Result<Vec<AppInfo>, String> {
        let conn = self.db.lock()
            .map_err(|e| format!("Failed to lock database: {}", e))?;

        let pattern = format!("%{}%", keyword);

        let mut stmt = conn.prepare(
            "SELECT package_name, name, summary, icon, license, author_name,
                    source_code, web_site, categories, added, last_updated,
                    metadata, versions
             FROM apps
             WHERE name LIKE ?1 OR summary LIKE ?1 OR package_name LIKE ?1
             ORDER BY name ASC
             LIMIT ?2"
        ).map_err(|e| format!("Failed to prepare query: {}", e))?;

        let apps = stmt
            .query_map(
                [&pattern, &limit.to_string()],
                |row| -> SqliteResult<AppInfo> {
                    Ok(AppInfo {
                        package_name: row.get(0)?,
                        name: row.get(1)?,
                        summary: row.get(2)?,
                        icon: row.get(3)?,
                        license: row.get(4)?,
                        author_name: row.get(5)?,
                        source_code: row.get(6)?,
                        web_site: row.get(7)?,
                        categories: row.get::<_, String>(8)?
                            .split(',')
                            .filter(|s| !s.is_empty())
                            .map(|s| s.to_string())
                            .collect(),
                        added: row.get(9)?,
                        last_updated: row.get(10)?,
                        metadata: row.get(11)?,
                        versions: row.get(12)?,
                    })
                },
            )
            .map_err(|e| format!("Query failed: {}", e))?
            .collect::<SqliteResult<Vec<_>>>()
            .map_err(|e| format!("Failed to collect results: {}", e))?;

        Ok(apps)
    }

    /// 清空所有应用数据
    pub fn clear_apps(&self) -> Result<i32, String> {
        let conn = self.db.lock()
            .map_err(|e| format!("Failed to lock database: {}", e))?;

        let count = conn.execute("DELETE FROM apps", [])
            .map_err(|e| format!("Failed to clear apps: {}", e))?;

        Ok(count as i32)
    }

    /// 获取一个应用（用于调试）
    pub fn get_one_app(&self) -> Result<Option<AppInfo>, String> {
        let conn = self.db.lock()
            .map_err(|e| format!("Failed to lock database: {}", e))?;

        let mut stmt = conn.prepare(
            "SELECT package_name, name, summary, icon, license, author_name,
                    source_code, web_site, categories, added, last_updated,
                    metadata, versions
             FROM apps
             LIMIT 1"
        ).map_err(|e| format!("Failed to prepare query: {}", e))?;

        let mut apps = stmt.query_map([], |row| -> SqliteResult<AppInfo> {
            Ok(AppInfo {
                package_name: row.get(0)?,
                name: row.get(1)?,
                summary: row.get(2)?,
                icon: row.get(3)?,
                license: row.get(4)?,
                author_name: row.get(5)?,
                source_code: row.get(6)?,
                web_site: row.get(7)?,
                categories: row.get::<_, String>(8)?
                    .split(',')
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string())
                    .collect(),
                added: row.get(9)?,
                last_updated: row.get(10)?,
                metadata: row.get(11)?,
                versions: row.get(12)?,
            })
        }).map_err(|e| format!("Query failed: {}", e))?;

        match apps.next() {
            Some(Ok(app)) => Ok(Some(app)),
            Some(Err(e)) => Err(format!("Failed to get app: {}", e)),
            None => Ok(None),
        }
    }

    /// 根据包名获取应用详情（包含 metadata 和 versions）
    pub fn get_app_by_package_name(&self, package_name: &str) -> Result<Option<AppInfo>, String> {
        let conn = self.db.lock()
            .map_err(|e| format!("Failed to lock database: {}", e))?;

        let mut stmt = conn.prepare(
            "SELECT package_name, name, summary, icon, license, author_name,
                    source_code, web_site, categories, added, last_updated,
                    metadata, versions
             FROM apps
             WHERE package_name = ?1"
        ).map_err(|e| format!("Failed to prepare query: {}", e))?;

        let mut apps = stmt.query_map(
            [&package_name],
            |row| -> SqliteResult<AppInfo> {
                Ok(AppInfo {
                    package_name: row.get(0)?,
                    name: row.get(1)?,
                    summary: row.get(2)?,
                    icon: row.get(3)?,
                    license: row.get(4)?,
                    author_name: row.get(5)?,
                    source_code: row.get(6)?,
                    web_site: row.get(7)?,
                    categories: row.get::<_, String>(8)?
                        .split(',')
                        .filter(|s| !s.is_empty())
                        .map(|s| s.to_string())
                        .collect(),
                    added: row.get(9)?,
                    last_updated: row.get(10)?,
                    metadata: row.get(11)?,
                    versions: row.get(12)?,
                })
            }
        ).map_err(|e| format!("Failed to query: {}", e))?;

        match apps.next() {
            Some(Ok(app)) => Ok(Some(app)),
            Some(Err(e)) => Err(format!("Failed to get app: {}", e)),
            None => Ok(None),
        }
    }
}


impl AppInfo {
    /// 从 JSON 值创建应用信息（index-v1 格式）
    pub fn from_json_value(package_name: &str, data: &serde_json::Value) -> Result<Self, String> {
        // 辅助函数：从多语言对象中提取字符串值，优先使用 en-US
        fn get_localized_string(value: &serde_json::Value, default: &str) -> String {
            if let Some(obj) = value.as_object() {
                // 优先使用 en-US
                if let Some(v) = obj.get("en-US").and_then(|v| v.as_str()) {
                    return v.to_string();
                }
                // 如果没有 en-US，使用第一个可用的值
                if let Some(v) = obj.values().next() {
                    if let Some(s) = v.as_str() {
                        return s.to_string();
                    }
                }
            }
            // 如果不是对象，尝试直接作为字符串
            value.as_str().unwrap_or(default).to_string()
        }

        // 处理 name 字段（多语言对象）
        let name = get_localized_string(
            &data.get("name").unwrap_or(&serde_json::Value::String(package_name.to_string())),
            package_name
        );

        // 处理 summary 字段（多语言对象）
        let summary = get_localized_string(
            &data.get("summary").unwrap_or(&serde_json::Value::String(String::new())),
            ""
        );

        // 处理 icon 字段 - index-v2.json 格式中 icon 是嵌套对象
        let icon = if let Some(icon_obj) = data.get("icon").and_then(|v| v.as_object()) {
            // 尝试获取 en-US 的 icon，如果没有则使用第一个可用的 locale
            if let Some(icon_data) = icon_obj.get("en-US").or_else(|| icon_obj.values().next()) {
                icon_data.get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&format!("{}.png", package_name))
                    .to_string()
            } else {
                format!("{}.png", package_name)
            }
        } else if let Some(icon_str) = data.get("icon").and_then(|v| v.as_str()) {
            // v1 格式中 icon 是字符串
            icon_str.to_string()
        } else {
            format!("{}.png", package_name)
        };

        Ok(AppInfo {
            package_name: package_name.to_string(),
            name,
            summary,
            icon,
            license: data.get("license")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string()),
            author_name: data.get("authorName")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string()),
            source_code: data.get("sourceCode")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string()),
            web_site: data.get("webSite")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string()),
            categories: data.get("categories")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str())
                        .map(|s| s.to_string())
                        .collect()
                })
                .unwrap_or_default(),
            // index-v2.json 中 added 和 lastUpdated 是数字（毫秒时间戳）
            // 需要转换为秒（Unix timestamp）
            added: data.get("added")
                .and_then(|v| {
                    // 优先尝试作为数字（毫秒时间戳）
                    if let Some(ms) = v.as_i64() {
                        Some(ms / 1000)
                    } else if let Some(ms) = v.as_str().and_then(|s| s.parse::<i64>().ok()) {
                        Some(ms / 1000)
                    } else {
                        None
                    }
                }),
            last_updated: data.get("lastUpdated")
                .and_then(|v| {
                    // 优先尝试作为数字（毫秒时间戳）
                    if let Some(ms) = v.as_i64() {
                        Some(ms / 1000)
                    } else if let Some(ms) = v.as_str().and_then(|s| s.parse::<i64>().ok()) {
                        Some(ms / 1000)
                    } else {
                        None
                    }
                }),
            metadata: None,  // 由 from_json_value_v2 填充
            versions: None,  // 由 from_json_value_v2 填充
        })
    }

    /// 从 JSON 值创建应用信息（index-v2 格式，包含完整 metadata 和 versions）
    pub fn from_json_value_v2(
        package_name: &str,
        package_data: &serde_json::Value,
    ) -> Result<Self, String> {
        // 提取 metadata 和 versions 的原始 JSON 字符串
        let metadata_json = package_data
            .get("metadata")
            .and_then(|v| serde_json::to_string(v).ok());
        let versions_json = package_data
            .get("versions")
            .and_then(|v| serde_json::to_string(v).ok());

        // 获取 metadata 对象用于解析字段
        let data = package_data
            .get("metadata")
            .ok_or("Missing metadata field")?;

        // 使用现有的解析逻辑
        let mut app_info = Self::from_json_value(package_name, data)?;

        // 添加原始 JSON 数据
        app_info.metadata = metadata_json;
        app_info.versions = versions_json;

        Ok(app_info)
    }
}
