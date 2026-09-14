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

/// 读取可选取消标志（None 表示不可取消）
/// 增量合并的基线体积上限：合并是内存操作（全量下载同样是），基线过大就不折腾
const MAX_INCREMENTAL_BASELINE_BYTES: usize = 32 * 1024 * 1024;

/// 增量更新结果
enum IncrementalOutcome {
    /// 已把 diff 合并并落库
    Applied(Vec<AppInfo>, RepoMeta),
    /// 本地索引已是最新（无需下载）
    UpToDate,
    /// 需要回退全量下载（无基线 / 链不完整 / 校验失败 / 超体积）
    Fallback,
}

/// 进度上报节流：跨过下一个 5% 档位时返回该档位（避免逐块上报把事件流刷爆）
fn next_progress_mark(loaded: u64, total: u64, last_mark: u64) -> Option<u64> {
    if total == 0 { return None; }
    let pct = (loaded.saturating_mul(100)) / total;
    if pct >= last_mark + 5 { Some(pct - (pct % 5)) } else { None }
}

/// **流式下载**：边下边算 sha256、边报进度
///
/// 相比 `resp.bytes()`：
/// - sha256 与下载**同一次遍历**完成（不再二次扫描）
/// - 每跨 5% 档位 emit 一次进度（经 Task 流到达 Dart——大索引 8~33MB，进度对体验很关键）
async fn fetch_with_progress(
    client: &reqwest::Client,
    url: &str,
    instance_id: u64,
    cancel: Option<&std::sync::atomic::AtomicBool>,
) -> Result<(Vec<u8>, String), String> {
    use sha2::{Digest, Sha256};
    let mut resp = client.get(url).send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    let total = resp.content_length().unwrap_or(0);
    let mut hasher = Sha256::new();
    let mut buf: Vec<u8> = Vec::with_capacity(total as usize);
    let mut last_mark = 0u64;
    while let Some(chunk) = resp.chunk().await.map_err(|e| e.to_string())? {
        if is_cancelled(cancel) {
            return Err("cancelled".to_string());
        }
        hasher.update(&chunk);
        buf.extend_from_slice(&chunk);
        if let Some(mark) = next_progress_mark(buf.len() as u64, total, last_mark) {
            last_mark = mark;
            crate::emit_event(
                instance_id,
                "progress",
                format!(
                    r#"{{"phase":"index","loaded":{},"total":{},"percent":{}}}"#,
                    buf.len(), total, mark
                )
                .as_bytes(),
            );
        }
    }
    let hex: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
    Ok((buf, hex))
}

/// 简易 GET → bytes
async fn fetch_bytes(client: &reqwest::Client, url: &str) -> Result<Vec<u8>, String> {
    let resp = client.get(url).send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    resp.bytes().await.map(|b| b.to_vec()).map_err(|e| e.to_string())
}

fn is_cancelled(cancel: Option<&std::sync::atomic::AtomicBool>) -> bool {
    cancel
        .map(|c| c.load(std::sync::atomic::Ordering::SeqCst))
        .unwrap_or(false)
}


/// 下载规格：源地址 + 该源配置的镜像 + 是否优先走镜像。
///
/// 语义（对齐"源是身份、镜像是从属配置"）：
/// - `mirror_first=true`：先尝试镜像（国内用户默认，避免先卡在官方站超时）
/// - `mirror_first=false`：只把镜像作为回退
#[derive(Clone, Debug, Default)]
pub struct DownloadSpec {
    pub url: String,
    pub mirrors: Vec<String>,
    pub mirror_first: bool,
}

impl DownloadSpec {
    /// 解析 payload：兼容裸 URL（历史）与 JSON 规格
    pub fn parse(bytes: &[u8]) -> Self {
        let text = String::from_utf8_lossy(bytes);
        let trimmed = text.trim();
        if trimmed.starts_with('{') {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(trimmed) {
                return DownloadSpec {
                    url: v["url"].as_str().unwrap_or_default().to_string(),
                    mirrors: v["mirrors"]
                        .as_array()
                        .map(|a| {
                            a.iter()
                                .filter_map(|x| x.as_str().map(|s| s.to_string()))
                                .collect()
                        })
                        .unwrap_or_default(),
                    mirror_first: v["mirror_first"].as_bool().unwrap_or(false),
                };
            }
        }
        DownloadSpec {
            url: trimmed.to_string(),
            ..Default::default()
        }
    }
}

/// 由镜像 URL 生成候选仓库地址。
///
/// 已核实：`config/mirrors.yml` 里的 url 指向 **`.../fdroid` 目录**（如 `https://ftp.fau.de/fdroid`），
/// 而仓库索引在 `.../fdroid/repo/` 下，所以必须先补 `/repo`；再兜底尝试原样地址
/// （也兼容"镜像直接就是仓库根"的自建源）。
pub fn mirror_candidates(mirror: &str) -> Vec<String> {
    let m = mirror.trim().trim_end_matches('/');
    if m.is_empty() {
        return Vec::new();
    }
    // **顺序很重要**：索引声明的镜像 URL 往往**本身就是仓库根**
    // （如 https://mobileapp.bitwarden.com/fdroid/repo），而官方 mirrors.yml
    // 给的是 `.../fdroid`（需再补 `/repo`）。所以原样优先，再试补 /repo。
    // **顺序很重要，且两种形态都存在**：
    // - 索引声明的镜像多为**仓库根**（…/fdroid/repo，Bitwarden 源就是这样）→ 原样优先
    // - 官方 mirrors.yml 给的是 `…/fdroid`（需再补 `/repo`）→ 补 /repo 优先
    // 判据：剥掉 scheme 后路径段数 > 2 视为已是仓库根，否则补 /repo。
    let rest = m.trim_start_matches("https://").trim_start_matches("http://");
    let is_repo_root = m.ends_with("/repo") || rest.split('/').count() > 2;
    let mut out = if is_repo_root {
        vec![m.to_string(), format!("{m}/repo")]
    } else {
        vec![format!("{m}/repo"), m.to_string()]
    };
    out.extend(crate::fdroid_url::normalize_repo_urls(m));
    let mut seen = std::collections::HashSet::new();
    out.retain(|u| seen.insert(u.clone()));
    out
}

/// 仓库元信息（索引 `repo` 头部 + 镜像列表）
#[derive(Clone, Debug, Default)]
struct RepoMeta {
    /// 仓库签名指纹（从 JAR 签名提取；空 = 未取到）
    fingerprint: String,
    name: String,
    description: String,
    icon: String,
    timestamp: i64,
    mirrors: Vec<String>,
}

/// 解析仓库元信息：`repo.{name,description,icon,timestamp}` + `mirrors[].url`
/// （官方镜像列表就写在索引文件里；第三方源同样可能带镜像）
fn parse_repo_meta(json: &serde_json::Value) -> RepoMeta {
    let mut meta = RepoMeta::default();
    if let Some(repo) = json.get("repo") {
        meta.name = repo.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string();
        meta.description = repo
            .get("description")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        meta.icon = repo.get("icon").and_then(|v| v.as_str()).unwrap_or("").to_string();
        meta.timestamp = repo.get("timestamp").and_then(|v| v.as_i64()).unwrap_or(0);
    }
    if let Some(list) = json.get("mirrors").and_then(|v| v.as_array()) {
        for m in list {
            if let Some(url) = m.get("url").and_then(|v| v.as_str()) {
                if !url.is_empty() {
                    meta.mirrors.push(url.trim_end_matches('/').to_string());
                }
            }
        }
    }
    meta
}

/// 仓库管理器 (简化版)
#[derive(Clone)]
pub struct RepoManager {
    db: Arc<Mutex<Connection>>,
    /// 库文件路径（基线索引缓存 `*.index.json.gz` 放在它旁边）
    db_path: String,
}

/// 仓库内相对路径归一化：统一取**最后一个 `/repo/` 之后**的部分
///
/// 真机形态很杂（`/repo/repo/com.x/…`、`/fdroid/repo/icons/x.png`、`/icons/x.png`、`x.png`），
/// 而基址本身已带 `/repo` —— 特判形态永远补不完，所以统一按「最后一个 /repo/ 之后」取。
pub fn normalize_asset_path(path: &str) -> String {
    let p = path.split('?').next().unwrap_or(path);
    if p.starts_with("http://") || p.starts_with("https://") {
        return p.to_string();
    }
    let p = match p.find("://") {
        Some(i) => {
            let rest = &p[i + 3..];
            match rest.find('/') { Some(j) => &rest[j..], None => "" }
        }
        None => p,
    };
    let p = match p.rfind("/repo/") { Some(i) => &p[i + 6..], None => p };
    p.trim_start_matches('/').to_string()
}

/// 基址 + 仓库内相对路径（两侧斜杠归一，避免 `…/repo//x`）
///
/// ★ 契约：`path` 若**已是绝对地址** → 原样返回。
///   必须与 [normalize_asset_path]（同样保留绝对地址）保持一致；两者契约不一致会出现
///   `https://镜像/https://第三方源/…` 的二次拼接（宿主侧同款 bug 已导致真机图标 404）。
pub fn join_repo_url(base: &str, path: &str) -> String {
    if path.starts_with("http://") || path.starts_with("https://") {
        return path.to_string();
    }
    let b = base.trim_end_matches('/');
    let p = path.trim_start_matches('/');
    if p.is_empty() { b.to_string() } else { format!("{b}/{p}") }
}

/// 把 metadata JSON 里的资源字段改成**绝对地址**（宿主就完全不需要 URL 逻辑）
fn rewrite_metadata_assets(base: &str, metadata: &str) -> String {
    let Ok(mut v) = serde_json::from_str::<serde_json::Value>(metadata) else {
        return metadata.to_string();
    };
    let Some(obj) = v.as_object_mut() else {
        return metadata.to_string();
    };
    for key in ["icon", "featureGraphic", "promoGraphic", "screenshots"] {
        if let Some(x) = obj.get_mut(key) {
            absolutize_asset_value(base, x);
        }
    }
    serde_json::to_string(&v).unwrap_or_else(|_| metadata.to_string())
}

/// **保持结构**地把资源路径换成绝对地址
///
/// 只改「路径值」，绝不改容器形状：`screenshots` 在索引里是 `{phone:{locale:路径}}`
/// 这类 Map，若被改成数组，宿主按 Map 解析就会抛类型错并回落到网络（真机踩过）。
fn absolutize_asset_value(base: &str, v: &mut serde_json::Value) {
    match v {
        serde_json::Value::String(s) => {
            if !s.is_empty() {
                *s = join_repo_url(base, &normalize_asset_path(s));
            }
        }
        serde_json::Value::Array(a) => {
            for x in a.iter_mut() {
                absolutize_asset_value(base, x);
            }
        }
        serde_json::Value::Object(o) => {
            // LocalizedFile：只改 name，保留 sha256/size 等其它键
            if let Some(n) = o.get_mut("name") {
                absolutize_asset_value(base, n);
                return;
            }
            for (_, x) in o.iter_mut() {
                absolutize_asset_value(base, x);
            }
        }
        _ => {}
    }
}

/// 把 versions JSON 里每个版本的 `file.name` 改成**绝对下载地址**
///
/// 与 metadata 资源同理：下载地址也只能有一个产出方。出口一次绝对化后，
/// 宿主侧不再需要「基址 + 相对文件名」的拼接（拼错源/二次前缀都由此杜绝）。
/// 兼容 map（key=versionCode）与数组两种形态。
fn rewrite_versions_assets(base: &str, versions: &str) -> String {
    let Ok(mut v) = serde_json::from_str::<serde_json::Value>(versions) else {
        return versions.to_string();
    };
    let mut absolutize_version = |entry: &mut serde_json::Value| {
        let Some(ver) = entry.as_object_mut() else { return };
        let Some(file) = ver.get_mut("file") else { return };
        if let Some(name) = file.get_mut("name") {
            absolutize_asset_value(base, name);
        }
    };
    match v.as_object_mut() {
        Some(obj) => {
            for (_, entry) in obj.iter_mut() {
                absolutize_version(entry);
            }
        }
        None => {
            if let Some(arr) = v.as_array_mut() {
                for entry in arr.iter_mut() {
                    absolutize_version(entry);
                }
            }
        }
    }
    serde_json::to_string(&v).unwrap_or_else(|_| versions.to_string())
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
            db_path: db_path.to_string(),
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
    #[allow(dead_code)] // 供模块单测/调用方使用；宿主路径走可取消版本
    pub async fn download_repo(&self, repo_url: &str) -> Result<DownloadResult, String> {
        self.download_repo_cancellable(&DownloadSpec { url: repo_url.to_string(), ..Default::default() }, 0, None)
            .await
    }

    /// 可取消的下载：在每个检查点读取 [cancel] 标志，置位即提前返回
    /// （不中断在途 HTTP，仅在阶段边界生效）
    pub async fn download_repo_cancellable(
        &self,
        spec: &DownloadSpec,
        instance_id: u64,
        cancel: Option<&std::sync::atomic::AtomicBool>,
    ) -> Result<DownloadResult, String> {
        let repo_url = spec.url.as_str();
        let start = std::time::Instant::now();
        if is_cancelled(cancel) {
            return Err("cancelled".to_string());
        }

        debug_print!("Starting download from: {}", repo_url);

        let client = reqwest::Client::builder()
            .build()
            .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

        // 候选地址按序尝试：主机名 → /fdroid/repo 自动发现（第三方源与独立应用私有源依赖此约定），
        // 深链 fdroidrepos:// 由 normalize_repo_urls 归一化为 https
        let mut primary = crate::fdroid_url::normalize_repo_urls(repo_url);
        if primary.is_empty() {
            return Err("仓库地址为空".to_string());
        }
        // 源上配置的镜像（用户可增删/禁用；这里是已启用的部分）
        let mut configured: Vec<String> = Vec::new();
        for m in &spec.mirrors {
            configured.extend(mirror_candidates(m));
        }
        // 索引声明并缓存的镜像（自动发现，作为回退）
        let cached_mirrors = self.load_cached_mirrors();
        let mut cached: Vec<String> = Vec::new();
        for m in &cached_mirrors {
            cached.extend(mirror_candidates(m));
        }
        let mut candidates = if spec.mirror_first {
            // 优先镜像：国内网络下避免先卡在官方站
            let mut c = configured.clone();
            c.append(&mut primary);
            c.append(&mut cached);
            c
        } else {
            let mut c = primary;
            c.append(&mut configured);
            c.append(&mut cached);
            c
        };
        let mut seen = std::collections::HashSet::new();
        candidates.retain(|u| seen.insert(u.clone()));
        if candidates.len() > 1 {
            debug_print!(
                "候选地址 {} 个（含缓存镜像 {} 个）",
                candidates.len(),
                cached_mirrors.len()
            );
        }

        let mut last_err = String::new();
        let mut fetched: Option<(Vec<AppInfo>, RepoMeta, bool, String)> = None;
        let mut up_to_date_url: Option<String> = None;
        let mut is_incremental = false;
        for base in &candidates {
            if is_cancelled(cancel) {
                return Err("cancelled".to_string());
            }
            debug_print!("trying repo candidate: {}", base);
            // ① 增量优先：只下 diff（官方实测约全量的 1%）
            match self.try_incremental(&client, base, instance_id).await {
                IncrementalOutcome::Applied(apps, meta) => {
                    fetched = Some((apps, meta, true, base.clone()));
                    is_incremental = true;
                    break;
                }
                IncrementalOutcome::UpToDate => {
                    up_to_date_url = Some(base.clone());
                    break;
                }
                IncrementalOutcome::Fallback => {}
            }
            // ② 全量
            match self.fetch_index_from(&client, base, instance_id).await {
                Ok((apps, meta, verified)) => {
                    fetched = Some((apps, meta, verified, base.clone()));
                    break;
                }
                Err(e) => {
                    debug_print!("candidate failed: {} -> {}", base, e);
                    last_err = format!("{base} -> {e}");
                }
            }
        }
        if let Some(url) = up_to_date_url {
            self.reset_fail_count();
            let count = self.get_app_count().unwrap_or(0);
            debug_print!("索引已是最新，跳过下载（{count} 个应用）");
            return Ok(DownloadResult {
                total_apps: count,
                download_time_ms: start.elapsed().as_millis() as i32,
                resolved_url: url,
                verified: false,
                mirror_count: 0,
                repo_name: String::new(),
                signer_fingerprint: String::new(),
                incremental: true,
            });
        }

        let (apps, meta, verified, resolved_url) = match fetched {
            Some(v) => v,
            None => {
                // 全部候选失败 → 记一次连续失败（供界面提示"此源可能已失效"）
                self.bump_fail_count(&last_err);
                return Err(format!("所有候选地址均失败: {last_err}"));
            }
        };

        if is_cancelled(cancel) {
            return Err("cancelled".to_string());
        }

        // 保存到数据库
        let count = self.save_apps(&apps)?;
        self.save_repo_meta(&meta, &resolved_url, verified)?;
        self.reset_fail_count();

        let elapsed = start.elapsed();

        debug_print!(
            "Download complete: {} apps in {}ms (verified={}, mirrors={})",
            count,
            elapsed.as_millis(),
            verified,
            meta.mirrors.len()
        );

        Ok(DownloadResult {
            total_apps: count,
            download_time_ms: elapsed.as_millis() as i32,
            resolved_url,
            verified,
            mirror_count: meta.mirrors.len() as i32,
            repo_name: meta.name.clone(),
            signer_fingerprint: meta.fingerprint.clone(),
            incremental: is_incremental,
        })
    }

    /// 从单个 base URL 拉取索引。
    ///
    /// 顺序：`entry.json`（v2 入口，带索引 sha256 → **可校验**）→ `index-v2.json`（裸 JSON）
    /// → `index-v1.jar`（旧格式回退，格式已由 fdroidserver 保留）。
    /// 返回 (应用列表, 仓库元信息, 是否通过完整性校验)。
    async fn fetch_index_from(
        &self,
        client: &reqwest::Client,
        base: &str,
        instance_id: u64,
    ) -> Result<(Vec<AppInfo>, RepoMeta, bool), String> {
        // 1) entry.json：v2 的入口，列出索引文件名与 sha256
        let entry = match client
            .get(format!("{base}/entry.json"))
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => match resp.bytes().await {
                Ok(b) => crate::fdroid_url::parse_entry(&b),
                Err(_) => None,
            },
            _ => None,
        };

        let index_name = entry
            .as_ref()
            .and_then(|e| e.index.as_ref())
            .map(|i| i.name.clone())
            .unwrap_or_else(|| "index-v2.json".to_string());
        let expected_sha256 = entry
            .as_ref()
            .and_then(|e| e.index.as_ref())
            .map(|i| i.sha256.clone())
            .unwrap_or_default();

        // 2) 索引本体（默认 index-v2.json）
        let index_url = crate::fdroid_url::join_repo(base, &index_name);
        match fetch_with_progress(client, &index_url, instance_id, None).await {
            Ok((bytes, streamed_sha)) => {
                // 完整性校验：用**下载时同趟算出**的 sha256（不再二次扫描）
                if !expected_sha256.is_empty()
                    && !streamed_sha.eq_ignore_ascii_case(&expected_sha256)
                {
                    return Err(format!("{index_name} 的 SHA-256 与 entry.json 不一致"));
                }
                let verified = !expected_sha256.is_empty();
                // 顺带取 entry.jar（JAR 签名）提取**仓库真实指纹**：
                // 仓库身份是签名密钥，不是地址——有了它才能判断"不同地址其实是同一个源"。
                // 只解析证书 DER 后取 SHA-256，不做密码学校验（不引入密码学库）。
                let mut signer_fingerprint = String::new();
                if let Ok(resp_jar) = client.get(format!("{base}/entry.jar")).send().await {
                    if resp_jar.status().is_success() {
                        if let Ok(jar_bytes) = resp_jar.bytes().await {
                            if let Some(fp) = crate::fingerprint::fingerprint_from_jar(&jar_bytes) {
                                debug_print!("{base}: 仓库指纹 {fp}");
                                signer_fingerprint = fp;
                            }
                        }
                    }
                }
                // 仓库头（只需 repo / mirrors 两个小字段）——单独轻量解出，不必建整份 Value
                let head = crate::index_parse::parse_index_head(&bytes);
                let mut meta = parse_repo_meta(&head);
                meta.fingerprint = signer_fingerprint;
                // **逐包流式解析**：不建整份索引的 Value 树（峰值内存 ≈ 单个包）
                let apps =
                    crate::index_parse::parse_index_v2_reader(std::io::Cursor::new(&bytes))?;
                // 存下基线索引（原始字节）+ 版本号：下次可走 entry.json 的 diff 做增量更新
                if self.save_index_baseline_bytes(&bytes).is_ok() {
                    if let Some(v) = entry.as_ref().map(|e| e.timestamp) {
                        let _ = self.set_index_timestamp(v);
                    }
                }
                return Ok((apps, meta, verified));
            }
            // 索引拉取/校验失败 → 继续尝试旧格式（index-v1.jar）
            Err(e) => { debug_print!("{base}: 索引拉取失败 {e}"); }
        }

        // 3) 旧格式回退
        debug_print!("{base}: index-v2 不可用，回退 index-v1.jar");
        let resp_v1 = client
            .get(format!("{base}/index-v1.jar"))
            .send()
            .await
            .map_err(|e| format!("请求 index-v1.jar 失败: {e}"))?;
        if !resp_v1.status().is_success() {
            return Err(format!("index-v1.jar 状态 {}", resp_v1.status()));
        }
        let jar_bytes = resp_v1
            .bytes()
            .await
            .map_err(|e| format!("读取 index-v1.jar 失败: {e}"))?;
        // 同一份 index-v1.jar 就能提指纹（它本身就是 JAR 签名文件）
        let v1_fp = crate::fingerprint::fingerprint_from_jar(&jar_bytes).unwrap_or_default();
        let apps = self.parse_index_v1_jar(&jar_bytes)?;
        let mut meta = RepoMeta::default();
        meta.fingerprint = v1_fp;
        Ok((apps, meta, false))
    }

    /// 写入仓库元信息与镜像列表（kv 表：缓存性质，可随时重建）
    fn save_repo_meta(
        &self,
        meta: &RepoMeta,
        resolved_url: &str,
        verified: bool,
    ) -> Result<(), String> {
        let conn = self
            .db
            .lock()
            .map_err(|e| format!("Failed to lock database: {e}"))?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS repo_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)",
        )
        .map_err(|e| format!("创建 repo_meta 失败: {e}"))?;
        let mirrors_json = serde_json::to_string(&meta.mirrors).unwrap_or_else(|_| "[]".into());
        let rows = [
            ("resolved_url", resolved_url.to_string()),
            ("name", meta.name.clone()),
            ("description", meta.description.clone()),
            ("icon", meta.icon.clone()),
            ("timestamp", meta.timestamp.to_string()),
            ("mirrors", mirrors_json),
            ("verified", if verified { "1" } else { "0" }.to_string()),
            // 仓库真实指纹（签名密钥）→ 供 Dart 侧自动回填与"同源判定"
            ("fingerprint", meta.fingerprint.clone()),
        ];
        for (k, v) in rows {
            conn.execute(
                "INSERT INTO repo_meta (k, v) VALUES (?1, ?2)
                 ON CONFLICT(k) DO UPDATE SET v = excluded.v",
                rusqlite::params![k, v],
            )
            .map_err(|e| format!("写入 repo_meta 失败: {e}"))?;
        }
        Ok(())
    }

    /// 读取仓库元信息（含镜像列表与完整性校验结果）
    pub fn get_repo_meta(&self) -> Result<serde_json::Value, String> {
        let conn = self
            .db
            .lock()
            .map_err(|e| format!("Failed to lock database: {e}"))?;
        let mut map = serde_json::Map::new();
        let Ok(mut stmt) = conn.prepare("SELECT k, v FROM repo_meta") else {
            return Ok(serde_json::Value::Object(map));
        };
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
            .map_err(|e| format!("读取 repo_meta 失败: {e}"))?;
        for row in rows.flatten() {
            let (k, v) = row;
            if k == "mirrors" {
                // 先按 JSON 解析（mirrors 是数组），失败则保留原始字符串
                // （name/description/fingerprint 都是普通字符串，不能被吞成 []）
                map.insert(
                    k,
                    serde_json::from_str(&v).unwrap_or(serde_json::Value::String(v.clone())),
                );
            } else if k == "timestamp" {
                map.insert(k, serde_json::json!(v.parse::<i64>().unwrap_or(0)));
            } else if k == "fail_count" {
                map.insert(k, serde_json::json!(v.parse::<i64>().unwrap_or(0)));
            } else if k == "verified" {
                map.insert(k, serde_json::json!(v == "1"));
            } else {
                map.insert(k, serde_json::json!(v));
            }
        }
        Ok(serde_json::Value::Object(map))
    }

    /// 读取上次成功记录下来的镜像列表（repo_meta.mirrors）
    fn load_cached_mirrors(&self) -> Vec<String> {
        let Ok(conn) = self.db.lock() else {
            return Vec::new();
        };
        let Ok(mut stmt) = conn.prepare("SELECT v FROM repo_meta WHERE k = 'mirrors'") else {
            return Vec::new();
        };
        let list: Option<String> = stmt.query_row([], |r| r.get(0)).ok();
        list.and_then(|v| serde_json::from_str::<Vec<String>>(&v).ok())
            .unwrap_or_default()
    }

    /// 连续失败 +1（并记录最后一次错误摘要）
    fn bump_fail_count(&self, err: &str) {
        let Ok(conn) = self.db.lock() else { return };
        let _ = conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS repo_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)",
        );
        let cur: i64 = conn
            .prepare("SELECT v FROM repo_meta WHERE k = 'fail_count'")
            .and_then(|mut s| s.query_row([], |r| r.get::<_, String>(0)))
            .ok()
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(0);
        let summary: String = err.chars().take(200).collect();
        let _ = conn.execute(
            "INSERT INTO repo_meta (k, v) VALUES ('fail_count', ?1)
             ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            rusqlite::params![(cur + 1).to_string()],
        );
        let _ = conn.execute(
            "INSERT INTO repo_meta (k, v) VALUES ('last_error', ?1)
             ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            rusqlite::params![summary],
        );
    }

    /// 成功后清零连续失败计数
    fn reset_fail_count(&self) {
        let Ok(conn) = self.db.lock() else { return };
        let _ = conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS repo_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)",
        );
        let _ = conn.execute(
            "INSERT INTO repo_meta (k, v) VALUES ('fail_count', '0')
             ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            [],
        );
    }

    /// 从索引 JSON 提取仓库元信息（repo 头部 + 镜像列表）
    fn parse_index_v2_value(&self, json: &serde_json::Value) -> Result<Vec<AppInfo>, String> {
        let mut apps = Vec::new();
        if let Some(packages) = json.get("packages").and_then(|v| v.as_object()) {
            for (package_name, package_data) in packages {
                if let Ok(app_info) = AppInfo::from_json_value_v2(package_name, package_data) {
                    apps.push(app_info);
                }
            }
        }
        Ok(apps)
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

    /// 解析 index-v1 XML 内容
    ///
    /// 流式 XML 解析（quick-xml），正确处理任意布局（紧凑单行/多行缩进/混合），
    /// 替代旧的手写字符串切片解析——后者在 `</id>` 先于 `<id>` 出现的行上会
    /// 触发 slice 越界 panic（begin > end），panic hook 符号化在 Android 上
    /// 二次崩溃为 SIGSEGV（真机崩溃根因）。
    pub(crate) fn parse_index_v1_xml_simple(&self, xml: &str) -> Result<Vec<AppInfo>, String> {
        debug_print!("Parsing index-v1 XML, length: {}", xml.len());

        let mut reader = quick_xml::Reader::from_str(xml);
        let mut buf = Vec::new();

        let mut apps: Vec<AppInfo> = Vec::new();
        let mut pkg_name = String::new();
        let mut name = String::new();
        let mut summary = String::new();
        let mut icon = String::new();
        let mut license: Option<String> = None;
        let mut source: Option<String> = None;
        let mut web: Option<String> = None;
        let mut added: Option<i64> = None;
        let mut categories: Vec<String> = Vec::new();
        let mut in_application = false;
        // F-Droid index-v1 里 <name>/<summary>/<icon> 等字段可能嵌在 <localized> 里，
        // 只在 application 直接子节点收集，localized 内跳过（避免多语言互相覆盖）。
        let mut in_localized = false;
        let mut text = String::new();

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(quick_xml::events::Event::Start(e)) => {
                    let tag = String::from_utf8_lossy(e.name().as_ref()).into_owned();
                    match tag.as_str() {
                        "application" => {
                            in_application = true;
                            pkg_name.clear(); name.clear(); summary.clear(); icon.clear();
                            license = None; source = None; web = None; added = None;
                            categories.clear();
                        }
                        "localized" => { if in_application { in_localized = true; } }
                        "id" | "name" | "summary" | "icon" | "license" | "source" | "web"
                        | "added" | "category" if in_application && !in_localized => {
                            text.clear();
                        }
                        _ => {}
                    }
                }
                Ok(quick_xml::events::Event::Text(t)) => {
                    if in_application && !in_localized {
                        if let Ok(s) = t.unescape() {
                            let s = s.trim();
                            if !s.is_empty() { text = s.to_string(); }
                        }
                    }
                }
                Ok(quick_xml::events::Event::End(e)) => {
                    let tag = String::from_utf8_lossy(e.name().as_ref()).into_owned();
                    match tag.as_str() {
                        "application" => {
                            if in_application {
                                if !pkg_name.is_empty() {
                                    apps.push(AppInfo {
                                        package_name: pkg_name.clone(),
                                        name: name.clone(),
                                        summary: summary.clone(),
                                        icon: icon.clone(),
                                        license: license.clone(),
                                        author_name: None,
                                        source_code: source.clone(),
                                        web_site: web.clone(),
                                        categories: categories.clone(),
                                        added,
                                        last_updated: None,
                                        metadata: None,
                                        versions: None,
                                    });
                                }
                                in_application = false;
                                pkg_name.clear(); name.clear(); summary.clear(); icon.clear();
                                license = None; source = None; web = None; added = None;
                                categories.clear();
                            }
                        }
                        "localized" => { in_localized = false; }
                        "id" if in_application && !in_localized => { pkg_name = text.clone(); }
                        "name" if in_application && !in_localized => { name = text.clone(); }
                        "summary" if in_application && !in_localized => { summary = text.clone(); }
                        "icon" if in_application && !in_localized => { icon = text.clone(); }
                        "license" if in_application && !in_localized => { license = Some(text.clone()); }
                        "source" if in_application && !in_localized => { source = Some(text.clone()); }
                        "web" if in_application && !in_localized => { web = Some(text.clone()); }
                        "added" if in_application && !in_localized => {
                            if let Ok(ts) = text.trim().parse::<i64>() { added = Some(ts); }
                        }
                        "category" if in_application && !in_localized => {
                            let cat = text.trim().to_string();
                            if !cat.is_empty() { categories.push(cat); }
                        }
                        _ => {}
                    }
                }
                Ok(quick_xml::events::Event::Eof) => {
                    // 容错：畸形 XML 可能丢失 </application> End 事件，EOF 时 flush
                    if in_application && !pkg_name.is_empty() {
                        apps.push(AppInfo {
                            package_name: pkg_name.clone(),
                            name: name.clone(),
                            summary: summary.clone(),
                            icon: icon.clone(),
                            license: license.clone(),
                            author_name: None,
                            source_code: source.clone(),
                            web_site: web.clone(),
                            categories: categories.clone(),
                            added,
                            last_updated: None,
                            metadata: None,
                            versions: None,
                        });
                    }
                    break;
                }
                Err(e) => {
                    debug_print!("index-v1 XML event error: {e}");
                    buf.clear();
                    continue;
                }
                _ => {}
            }
            buf.clear();
        }

        debug_print!("Parsed {} apps from index-v1", apps.len());
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

    /// 资源基址：**镜像优先后真正生效的地址**（下载时记录为 resolved_url）
    ///
    /// 所有网络资源（索引/图标/截图）都必须与索引走同一个可达地址：
    /// 国内直连 f-droid.org 会连接超时，只有镜像可达。
    fn asset_base(&self) -> String {
        if let Ok(meta) = self.get_repo_meta() {
            if let Some(v) = meta.get("resolved_url").and_then(|v| v.as_str()) {
                if !v.is_empty() {
                    return v.trim_end_matches('/').to_string();
                }
            }
        }
        String::new()
    }

    /// 搜索应用
    pub fn search_apps(&self, keyword: &str, limit: i32) -> Result<Vec<AppInfo>, String> {
        // ★ 必须在**锁外**取资源基址：asset_base() 内部同样会 self.db.lock()，
        //   而 std::sync::Mutex 不可重入 —— 持锁调用会**自死锁**
        //   （真机表现：搜索一直转圈、后续流程全卡住）
        let base = self.asset_base();

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

        let mut apps = stmt
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

        // ★ 出口统一处理：icon / metadata 资源 / versions 里的 APK 文件名 → 绝对地址
        //   在**读取时**解析而非写库时，因为镜像偏好会变（基址=resolved_url，随下载更新）
        if !base.is_empty() {
            for a in apps.iter_mut() {
                if !a.icon.is_empty() {
                    a.icon = join_repo_url(&base, &normalize_asset_path(&a.icon));
                }
                if let Some(meta) = a.metadata.clone() {
                    a.metadata = Some(rewrite_metadata_assets(&base, &meta));
                }
                if let Some(vs) = a.versions.clone() {
                    a.versions = Some(rewrite_versions_assets(&base, &vs));
                }
            }
        }

        Ok(apps)
    }

    /// 清空所有应用数据
    // ══ 增量更新（index-v2 entry.json + RFC 7396 diff）══

    /// 基线索引缓存文件（gzip；与库文件同目录）
    fn baseline_path(&self) -> String {
        format!("{}.index.json.gz", self.db_path)
    }

    /// 读取本地基线索引（解压 + 解析）；不存在/损坏返回 None
    fn load_index_baseline(&self) -> Option<serde_json::Value> {
        let raw = std::fs::read(self.baseline_path()).ok()?;
        let mut decoder = flate2::read::GzDecoder::new(&raw[..]);
        let mut out = Vec::new();
        std::io::Read::read_to_end(&mut decoder, &mut out).ok()?;
        serde_json::from_slice(&out).ok()
    }

    /// 写回基线索引（**直接用下载到的原始字节** gzip 落盘）
    ///
    /// 相比 `save_index_baseline(&Value)`：省掉「Value 序列化回字节」这一份全量内存拷贝。
    /// 两种写法的**内容等价**（都是同一份索引 JSON），RFC 7396 合并对格式不敏感。
    fn save_index_baseline_bytes(&self, bytes: &[u8]) -> Result<(), String> {
        use flate2::write::GzEncoder;
        use flate2::Compression;
        let mut enc = GzEncoder::new(Vec::new(), Compression::fast());
        std::io::Write::write_all(&mut enc, bytes).map_err(|e| format!("压缩索引失败: {e}"))?;
        let gz = enc.finish().map_err(|e| format!("压缩索引失败: {e}"))?;
        std::fs::write(self.baseline_path(), gz).map_err(|e| format!("写入基线索引失败: {e}"))
    }

    /// 写回基线索引（gzip 存盘，供下次增量更新使用）
    fn save_index_baseline(&self, index: &serde_json::Value) -> Result<(), String> {
        use flate2::write::GzEncoder;
        use flate2::Compression;
        let bytes = serde_json::to_vec(index).map_err(|e| format!("序列化索引失败: {e}"))?;
        let mut enc = GzEncoder::new(Vec::new(), Compression::fast());
        std::io::Write::write_all(&mut enc, &bytes).map_err(|e| format!("压缩索引失败: {e}"))?;
        let gz = enc.finish().map_err(|e| format!("压缩索引失败: {e}"))?;
        std::fs::write(self.baseline_path(), gz).map_err(|e| format!("写入基线索引失败: {e}"))
    }

    /// 本地已应用的索引版本（0 = 无基线）
    fn index_timestamp(&self) -> i64 {
        self.get_repo_meta()
            .ok()
            .and_then(|v| v.get("index_timestamp").and_then(|x| x.as_i64()))
            .unwrap_or(0)
    }

    fn set_index_timestamp(&self, timestamp: i64) -> Result<(), String> {
        let conn = self.db.lock().map_err(|e| format!("锁失败: {e}"))?;
        conn.execute(
            "INSERT INTO repo_meta (k, v) VALUES (?1, ?2)
             ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            rusqlite::params!["index_timestamp", timestamp.to_string()],
        )
        .map_err(|e| format!("写入索引版本失败: {e}"))?;
        Ok(())
    }

    /// 尝试增量更新：用 `entry.json` 的单级 diff 把本地基线索引补到最新。
    ///
    /// 关键事实（真机 `entry.json` 实测，别再按直觉写）：
    /// - `entry.version` 是**索引格式版本**（恒为 20002），**不是**仓库单调版本
    /// - `diffs` 的键是**上一个索引的 timestamp** → 基线应为本地已应用索引的 timestamp
    /// - `entry.index.name` / `diffs[].name` 带前导 `/` → 用 `join_repo` 拼接
    ///
    /// 返回 `Fallback` 表示"需要回退全量下载"（无基线 / 无匹配 diff / 校验失败 / 超体积保护）。
    async fn try_incremental(
        &self,
        client: &reqwest::Client,
        base: &str,
        instance_id: u64,
    ) -> IncrementalOutcome {
        let baseline_ts = self.index_timestamp();
        if baseline_ts <= 0 {
            return IncrementalOutcome::Fallback; // 无基线：只能全量
        }

        let entry_url = crate::fdroid_url::join_repo(base, "entry.json");
        let entry_bytes = match fetch_bytes(client, &entry_url).await {
            Ok(b) => b,
            Err(_) => return IncrementalOutcome::Fallback,
        };
        let Some(entry) = crate::fdroid_url::parse_entry(&entry_bytes) else {
            return IncrementalOutcome::Fallback;
        };
        // 已是最新：本地时间戳与 entry 一致 → 不下载、不重写数据
        if entry.timestamp != 0 && entry.timestamp == baseline_ts {
            return IncrementalOutcome::UpToDate;
        }
        // 用本地 timestamp 去 diffs 里找**单级**差异（不是按版本号逐级链）
        let Some((_, diff_ref)) = pick_diff(baseline_ts, &entry) else {
            return IncrementalOutcome::Fallback;
        };
        let diff_url = crate::fdroid_url::join_repo(base, &diff_ref.name);

        let Some(mut index) = self.load_index_baseline() else {
            return IncrementalOutcome::Fallback; // 本地无基线索引
        };
        let baseline_bytes = serde_json::to_vec(&index).map(|v| v.len()).unwrap_or(0);
        if baseline_bytes > MAX_INCREMENTAL_BASELINE_BYTES {
            debug_print!(
                "增量：基线索引过大（{}MB），回退全量",
                baseline_bytes / 1024 / 1024
            );
            return IncrementalOutcome::Fallback;
        }

        let (diff_bytes, diff_sha) =
            match fetch_with_progress(client, &diff_url, instance_id, None).await {
                Ok(v) => v,
                Err(e) => {
                    debug_print!("增量：拉取 diff 失败 {diff_url} -> {e}");
                    return IncrementalOutcome::Fallback;
                }
            };
        if !diff_ref.sha256.is_empty() && !diff_sha.eq_ignore_ascii_case(&diff_ref.sha256) {
            debug_print!("增量：diff 校验失败 {diff_url}");
            return IncrementalOutcome::Fallback;
        }
        let patch: serde_json::Value = match serde_json::from_slice(&diff_bytes) {
            Ok(v) => v,
            Err(e) => {
                debug_print!("增量：diff 解析失败 -> {e}");
                return IncrementalOutcome::Fallback;
            }
        };
        crate::merge_patch::apply(&mut index, &patch);

        // 合并后的索引是完整视图：省的是**带宽**，CPU 与全量一致
        let apps = match self.parse_index_v2_value(&index) {
            Ok(a) => a,
            Err(e) => {
                debug_print!("增量：合并索引解析失败 -> {e}");
                return IncrementalOutcome::Fallback;
            }
        };
        let meta = parse_repo_meta(&index);
        let count = match self.save_apps(&apps) {
            Ok(c) => c,
            Err(e) => {
                debug_print!("增量：入库失败 -> {e}");
                return IncrementalOutcome::Fallback;
            }
        };
        // 基线换成 entry 的 timestamp：下次就靠它找 diff
        let new_baseline = if entry.timestamp != 0 { entry.timestamp } else { baseline_ts };
        if self.save_index_baseline(&index).is_err()
            || self.set_index_timestamp(new_baseline).is_err()
        {
            return IncrementalOutcome::Fallback;
        }
        self.reset_fail_count();

        debug_print!(
            "增量更新成功：ts {} → {}（1 级 diff，{} 个应用）",
            baseline_ts,
            new_baseline,
            count
        );
        IncrementalOutcome::Applied(apps, meta)
    }

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
}


impl AppInfo {
    /// 从 JSON 值创建应用信息（index-v1 格式）
    pub fn from_json_value(package_name: &str, data: &serde_json::Value) -> Result<Self, String> {
        // 辅助函数：从多语言对象中提取字符串值，优先使用 en-US
        /// 取本地化字段的字符串值。
        ///
        /// 索引 v2 里同一位置有**三种形态**（真机 Bitwarden 源上踩到过）：
        /// - 直接字符串
        /// - LocalizedText：`{"en-US": "文本"}`
        /// - **LocalizedFile：`{"en-US": {"name": "/icons/x.png", "sha256":…, "size":…}}`**
        ///   旧实现只认字符串，遇到对象就返回默认值 → `icon` 为空 → 没有图标地址。
        fn get_localized_string(value: &serde_json::Value, default: &str) -> String {
            match value {
                serde_json::Value::String(s) => s.clone(),
                serde_json::Value::Object(obj) => {
                    // LocalizedFile 本体：{name, sha256, size} → 只取 name
                    if let Some(n) = obj.get("name") {
                        if !n.is_null() {
                            let s = get_localized_string(n, "");
                            if !s.is_empty() {
                                return s;
                            }
                        }
                    }
                    // LocalizedText / LocalizedFile 包装：按语言优先，再退首个非空
                    for key in ["en-US", "en", "zh-CN", "zh"] {
                        if let Some(v) = obj.get(key) {
                            let s = get_localized_string(v, "");
                            if !s.is_empty() {
                                return s;
                            }
                        }
                    }
                    for v in obj.values() {
                        let s = get_localized_string(v, "");
                        if !s.is_empty() {
                            return s;
                        }
                    }
                    default.to_string()
                }
                _ => default.to_string(),
            }
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

/// 规划从 `baseline` 到 `target` 的差异链（**纯函数**，便于单测）。
///
/// F-Droid 的 diff 是**逐版本增量**（diff/<version>.json 把 (version-1) 变成 version），
/// 所以要逐级回放。任一级缺失 → 返回 None（调用方回退全量下载）。
/// 选择要应用的差异文件（**纯函数**，便于单测）。
///
/// 关键事实（真机 `entry.json` 实测）：`entry.version` 是**索引格式版本**（恒为 20002），
/// 不是仓库的单调版本；而 `diffs` 的键是**上一个索引的 timestamp**。
/// 所以正确做法是：拿本地已应用索引的 timestamp 去 `diffs` 里找**单级** diff，
/// 找到就用，找不到就回退全量——而不是按 "baseline+1..target" 逐级链。
pub fn pick_diff<'a>(
    baseline_timestamp: i64,
    entry: &'a crate::fdroid_url::EntryInfo,
) -> Option<(i64, &'a crate::fdroid_url::IndexRef)> {
    if baseline_timestamp <= 0 {
        return None;
    }
    entry
        .diffs
        .get(&baseline_timestamp)
        .map(|r| (baseline_timestamp, r))
}

#[cfg(test)]
mod repo_meta_tests {
    use super::*;

    #[test]
    fn parses_repo_header_and_mirrors() {
        let json: serde_json::Value = serde_json::from_str(
            r#"{
                "repo": {"name":"My Repo","description":"desc","icon":"i.png","timestamp":1234567},
                "mirrors": [{"url":"https://m1.example.com/fdroid/repo/"},{"url":"https://m2.example.com"}]
            }"#,
        )
        .unwrap();
        let meta = parse_repo_meta(&json);
        assert_eq!(meta.name, "My Repo");
        assert_eq!(meta.description, "desc");
        assert_eq!(meta.icon, "i.png");
        assert_eq!(meta.timestamp, 1234567);
        // 镜像 URL 去尾斜杠，便于后续拼接
        assert_eq!(
            meta.mirrors,
            vec!["https://m1.example.com/fdroid/repo", "https://m2.example.com"]
        );
    }

    #[test]
    fn progress_mark_is_throttled_to_five_percent() {
        // 32MB 总量：每 5% 才报一次
        let total = 32 * 1024 * 1024u64;
        assert_eq!(super::next_progress_mark(total / 100, total, 0), None); // 1% → 不报
        assert_eq!(super::next_progress_mark(total * 6 / 100, total, 0), Some(5));
        assert_eq!(super::next_progress_mark(total * 7 / 100, total, 5), None); // 档位未跨
        assert_eq!(super::next_progress_mark(total * 12 / 100, total, 5), Some(10));
        assert_eq!(super::next_progress_mark(total, total, 95), Some(100));
        // 无 content-length 时不上报（避免除零/乱报）
        assert_eq!(super::next_progress_mark(1024, 0, 0), None);
    }

    #[test]
    fn versions_assets_are_absolutized_at_output() {
        const BASE: &str = "https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo";
        // map 形态（索引 v2：key = versionCode）
        let versions = r#"{"1000":{"file":{"name":"com.termux_1000.apk","size":9},
            "manifest":{"versionCode":1000},"added":1700000000}}"#;
        let out = super::rewrite_versions_assets(BASE, versions);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(
            v["1000"]["file"]["name"],
            serde_json::json!(format!("{BASE}/com.termux_1000.apk"))
        );
        // 其余字段形状不变（宿主直接按原结构解析）
        assert_eq!(v["1000"]["file"]["size"], serde_json::json!(9));
        assert_eq!(v["1000"]["manifest"]["versionCode"], serde_json::json!(1000));
    }

    #[test]
    fn join_repo_url_never_double_prefixes_absolute_paths() {
        const BASE: &str = "https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo";
        const ABS: &str = "https://mobileapp.bitwarden.com/fdroid/repo/com.x8bit.bitwarden/en-US/icon_x=.png";
        // 真机图标 404 根因：绝对地址被二次前缀（normalize 保留 → join 必须也保留）
        assert_eq!(
            super::join_repo_url(BASE, &super::normalize_asset_path(ABS)),
            ABS
        );
        assert!(!super::join_repo_url(BASE, ABS).contains("/https://"));
        // 相对路径照常拼接
        assert_eq!(
            super::join_repo_url(
                BASE,
                &super::normalize_asset_path("/fdroid/repo/com.x/en-US/icon_a=.png")
            ),
            format!("{BASE}/com.x/en-US/icon_a=.png")
        );
    }

    #[test]
    fn versions_assets_absolutization_is_idempotent_and_handles_arrays() {
        const BASE: &str = "https://mobileapp.bitwarden.com/fdroid/repo";
        // 数组形态 + 已是绝对地址（源切换后重复出口不得二次前缀）
        let abs = "https://mobileapp.bitwarden.com/fdroid/repo/com.x8bit.bitwarden_1.apk";
        let versions = format!(r#"[{{"file":{{"name":"{abs}"}}}}]"#);
        let out = super::rewrite_versions_assets(BASE, &versions);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v[0]["file"]["name"], serde_json::json!(abs));
        assert!(!out.contains("/https://"));
        // 非法 JSON 原样返回（不因出口改写丢数据）
        assert_eq!(super::rewrite_versions_assets(BASE, "not json"), "not json");
    }

    fn parse_repo_meta_tolerates_missing_fields() {
        let json: serde_json::Value = serde_json::from_str(r#"{"packages":{}}"#).unwrap();
        let meta = parse_repo_meta(&json);
        assert!(meta.name.is_empty());
        assert!(meta.mirrors.is_empty());
    }

    #[test]
    fn mirror_candidates_appends_repo_first() {
        // 已核实 mirrors.yml 的 url 指向 .../fdroid 目录 → 必须先补 /repo
        let c = super::mirror_candidates("https://ftp.fau.de/fdroid");
        assert_eq!(c.first().map(|s| s.as_str()), Some("https://ftp.fau.de/fdroid/repo"));
        assert!(c.contains(&"https://ftp.fau.de/fdroid".to_string()));
        let c2 = super::mirror_candidates("https://ftp.fau.de/fdroid/");
        assert_eq!(c2.first().map(|s| s.as_str()), Some("https://ftp.fau.de/fdroid/repo"));
        assert!(super::mirror_candidates("  ").is_empty());
    }

    fn mirror_candidates_keeps_repo_root_first() {
        // 真机形态（Bitwarden 源）：镜像 URL 本身就是仓库根 → 原样优先，避免先打一次 404
        let c = super::mirror_candidates("https://mobileapp.bitwarden.com/fdroid/repo");
        assert_eq!(c.first().map(|s| s.as_str()), Some("https://mobileapp.bitwarden.com/fdroid/repo"));
        let c2 = super::mirror_candidates("https://raw.githubusercontent.com/bitwarden/f-droid/main/fdroid/repo");
        assert_eq!(c2.first().map(|s| s.as_str()),
            Some("https://raw.githubusercontent.com/bitwarden/f-droid/main/fdroid/repo"));
    }

    #[test]
    fn fail_count_bumps_and_resets() {
        let rm = fresh_manager("mirror_health");
        rm.reset_fail_count();
        rm.bump_fail_count("connection refused: xyz");
        rm.bump_fail_count("timeout");
        let v = rm.get_repo_meta().unwrap();
        assert_eq!(v["fail_count"], serde_json::json!(2));
        assert_eq!(v["last_error"], serde_json::json!("timeout"));
        rm.reset_fail_count();
        assert_eq!(rm.get_repo_meta().unwrap()["fail_count"], serde_json::json!(0));
    }

    #[test]
    fn cached_mirrors_roundtrip() {
        let rm = fresh_manager("mirror_cache");
        assert!(rm.load_cached_mirrors().is_empty());
        let meta = super::RepoMeta {
            mirrors: vec!["https://a.example/fdroid".into(), "https://b.example/fdroid".into()],
            ..Default::default()
        };
        rm.save_repo_meta(&meta, "https://x/entry.json", true).unwrap();
        let got = rm.load_cached_mirrors();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0], "https://a.example/fdroid");
    }

    /// 独立库名的临时 RepoManager（各测试互不干扰）
    fn fresh_manager(tag: &str) -> RepoManager {
        let dir = std::env::temp_dir().join(format!("gstore_{tag}_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("repo.db");
        RepoManager::new(db.to_str().unwrap()).unwrap()
    }

    #[test]
    fn download_spec_parses_raw_url_and_json() {
        // 历史格式：裸 URL
        let raw = super::DownloadSpec::parse(b"https://f-droid.org/repo");
        assert_eq!(raw.url, "https://f-droid.org/repo");
        assert!(raw.mirrors.is_empty());
        assert!(!raw.mirror_first);
        // 新格式：源 + 镜像 + 优先镜像
        let json = br#"{"url":"https://f-droid.org/repo","mirrors":["https://mirror.a/fdroid"],"mirror_first":true}"#;
        let spec = super::DownloadSpec::parse(json);
        assert_eq!(spec.url, "https://f-droid.org/repo");
        assert_eq!(spec.mirrors, vec!["https://mirror.a/fdroid".to_string()]);
        assert!(spec.mirror_first);
        // 空/坏 JSON → 退化为普通 URL（不 panic）
        let bad = super::DownloadSpec::parse(b"{not json");
        assert_eq!(bad.url, "{not json");
    }

    #[test]
    fn repo_meta_roundtrip_through_db() {
        let mgr = RepoManager::new("file:repo_meta_t?mode=memory&cache=shared").unwrap();
        let meta = RepoMeta {
            fingerprint: String::new(),
            name: "R".into(),
            description: "D".into(),
            icon: "I".into(),
            timestamp: 42,
            mirrors: vec!["https://m.example.com".into()],
        };
        mgr.save_repo_meta(&meta, "https://r.example.com/fdroid/repo", true)
            .unwrap();
        let got = mgr.get_repo_meta().unwrap();
        assert_eq!(got["resolved_url"], "https://r.example.com/fdroid/repo");
        assert_eq!(got["name"], "R");
        assert_eq!(got["timestamp"], 42); // 数字类型还原，不是字符串
        assert_eq!(got["verified"], true);
        assert_eq!(got["mirrors"][0], "https://m.example.com");
    }

    /// 差异选择：按本地 timestamp **单级**匹配（真机 entry.json 的 diffs 键=上一个索引的 timestamp）
    #[test]
    fn pick_diff_matches_baseline_timestamp() {
        use crate::fdroid_url::{EntryInfo, IndexRef};
        let mut entry = EntryInfo {
            version: 20002,
            timestamp: 1_787_541_131_000,
            ..Default::default()
        };
        entry.diffs.insert(
            1_787_541_127_000,
            IndexRef { name: "/diff/1787541127000.json".into(), sha256: "aa".into(), size: 256 },
        );
        let picked = super::pick_diff(1_787_541_127_000, &entry);
        assert_eq!(picked.unwrap().1.name, "/diff/1787541127000.json");
        assert!(super::pick_diff(0, &entry).is_none());          // 无基线 → 回退全量
        assert!(super::pick_diff(1_787_541_000_000, &entry).is_none()); // 不匹配 → 回退全量
    }

    /// 真机形态（Bitwarden 源）：`icon` 是 **LocalizedFile 对象**而不是字符串
    /// → 必须取到 `name`，否则 icon 为空、详情页永远没有图标地址
    #[test]
    fn icon_from_localized_file_object() {
        let data: serde_json::Value = serde_json::from_str(
            r#"{
                "name": {"en-US": "Bitwarden"},
                "icon": {"en-US": {"name": "/com.x8bit.bitwarden/en-US/icon_x=.png",
                                   "sha256": "a07b", "size": 13229}}
            }"#,
        )
        .unwrap();
        let app = AppInfo::from_json_value("com.x8bit.bitwarden", &data).unwrap();
        assert_eq!(app.icon, "/com.x8bit.bitwarden/en-US/icon_x=.png");
        assert_eq!(app.name, "Bitwarden");
    }

    #[test]
    fn asset_path_normalization_covers_real_shapes() {
        // 真机：库里出现过 /repo/repo/... 的脏路径
        assert_eq!(
            super::normalize_asset_path("/repo/repo/com.kgurgul.cpuinfo/en-US/icon_x=.png"),
            "com.kgurgul.cpuinfo/en-US/icon_x=.png"
        );
        assert_eq!(super::normalize_asset_path("/fdroid/repo/icons/a.png"), "icons/a.png");
        assert_eq!(super::normalize_asset_path("/icons/a.png"), "icons/a.png");
        assert_eq!(super::normalize_asset_path("a.png"), "a.png");
        assert_eq!(
            super::normalize_asset_path("https://cdn.example.com/a.png"),
            "https://cdn.example.com/a.png"
        );
        // 绝对地址**原样保留**：仓库显式声明了完整 URL，不该被我们改写成镜像
        assert_eq!(
            super::normalize_asset_path("https://host/x/repo/a.png?v=1"),
            "https://host/x/repo/a.png"
        );
    }

    #[test]
    fn asset_url_join_never_doubles_repo() {
        let url = super::join_repo_url(
            "https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo",
            &super::normalize_asset_path("/repo/repo/com.x/en-US/icon_a=.png"),
        );
        assert_eq!(
            url,
            "https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo/com.x/en-US/icon_a=.png"
        );
        assert!(!url.contains("/repo/repo/"));
    }

    #[test]
    fn metadata_assets_are_absolutized_at_output() {
        // 真机形态：LocalizedFile 对象 + screenshots 为 {locale: [..]}
        let meta = r#"{"name":{"en-US":"CPU Info"},
            "featureGraphic":{"en-US":{"name":"/com.x/en-US/featureGraphic_a=.png","sha256":"x","size":1}},
            "screenshots":{"en-US":["/com.x/en-US/a.png","/com.x/en-US/b.png"]}}"#;
        let out = super::rewrite_metadata_assets("https://mirror/fdroid/repo", meta);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();

        // ★ 结构保持：LocalizedFile 只改内层 name，sha256/size 原样
        assert_eq!(
            v["featureGraphic"]["en-US"]["name"],
            "https://mirror/fdroid/repo/com.x/en-US/featureGraphic_a=.png"
        );
        assert_eq!(v["featureGraphic"]["en-US"]["sha256"], "x");
        assert_eq!(v["featureGraphic"]["en-US"]["size"], 1);
        // ★ screenshots 仍是 {locale: [..]}，只是路径绝对化
        assert_eq!(
            v["screenshots"]["en-US"][0],
            "https://mirror/fdroid/repo/com.x/en-US/a.png"
        );
        assert_eq!(
            v["screenshots"]["en-US"][1],
            "https://mirror/fdroid/repo/com.x/en-US/b.png"
        );
        // 非资源字段不动
        assert_eq!(v["name"]["en-US"], "CPU Info");
    }


    /// 回归：search_apps 不得在持 db 锁时再取资源基址（不可重入锁 → 自死锁）
    ///
    /// 该用例若失败会**挂住**（死锁），这正是真机"搜索一直卡住"的形态。
    #[test]
    fn search_apps_does_not_self_deadlock_with_repo_meta() {
        let dir = std::env::temp_dir().join(format!("gstore_lock_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("a.db");
        let mgr = RepoManager::new(db.to_str().unwrap()).unwrap();
        // 先写入 resolved_url（有基址 → 出口会做绝对化，即踩到那条路径）
        mgr.save_repo_meta(&RepoMeta::default(), "https://mirror.example.com/fdroid/repo", true)
            .unwrap();
        mgr.save_apps(&[AppInfo {
            package_name: "com.x".into(),
            name: "X".into(),
            summary: String::new(),
            icon: "/com.x/en-US/icon_a=.png".into(),
            license: None,
            author_name: None,
            source_code: None,
            web_site: None,
            categories: vec![],
            added: None,
            last_updated: None,
            metadata: None,
            versions: None,
        }])
        .unwrap();
        let apps = mgr.search_apps("com.x", 10).unwrap();   // ← 死锁则永久挂住
        assert_eq!(apps.len(), 1);
        assert_eq!(
            apps[0].icon,
            "https://mirror.example.com/fdroid/repo/com.x/en-US/icon_a=.png"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
    /// 回归：`screenshots` 是 Map（f-droid 官方形态）时**不得被改成数组**
    /// —— 否则宿主按 Map 解析抛类型错并回落到不可达的 API（真机踩过）
    #[test]
    fn metadata_screenshots_keep_map_shape() {
        let meta = r#"{"screenshots":{"phone":{"en-US":"/com.x/en-US/a.png"}}}"#;
        let out = super::rewrite_metadata_assets("https://mirror/fdroid/repo", meta);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert!(v["screenshots"].is_object(), "screenshots 必须仍是对象");
        assert_eq!(
            v["screenshots"]["phone"]["en-US"],
            "https://mirror/fdroid/repo/com.x/en-US/a.png"
        );
    }

}
