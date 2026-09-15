//! 任务调度与生命周期：并发上限、优先级、防重复、暂停/恢复/取消/重试。
//!
//! 这一层是"任务管理"的归属地，也是**防重复任务**的正确位置：
//! 既有 Dart 实现只在"已完成且文件有效"时短路，任务在跑/排队时再点一次会**再起一个 run**
//! （上一轮排查出的缺口）。这里改为：同键任务处于活动态时**直接返回既有任务**，不新建 run。
//!
//! 并发额度的真源是 DB（`status IN (connecting, downloading)` 计数），
//! 不用内存计数器——避免崩溃恢复/异常路径导致计数漂移。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use gstore_contract::error::ModuleError;
use tokio::sync::Notify;

use crate::dedup::{self, ConflictPolicy};
use crate::engine::{self, DownloadParams, Outcome, ProgressSink};
use crate::model::{now_ms, FailKind, ProgressEvent, Segment, Task, TaskStatus};
use crate::store::{self, SharedConn};

/// 调度配置（面板可通过 `set_config` 调整并发/限速）。
#[derive(Debug, Clone)]
pub struct SchedulerConfig {
    /// 全局并发任务数上限
    pub max_concurrent: usize,
    /// 单任务默认并发连接数（分段数）
    pub default_connections: u32,
    /// 全局限速（None = 不限速）
    pub speed_limit_bps: Option<u64>,
    pub max_retries: u32,
}

impl Default for SchedulerConfig {
    fn default() -> Self {
        Self {
            max_concurrent: 3, // 与既有 Dart 侧 maxConcurrent 默认值一致
            default_connections: engine::DEFAULT_CONNECTIONS,
            speed_limit_bps: None,
            max_retries: engine::DEFAULT_MAX_RETRIES,
        }
    }
}

/// 事件出口：由 lib.rs 桥接到 `emit_event`；测试注入假实现。
pub trait TaskEmitter: Send + Sync {
    fn progress(&self, ev: ProgressEvent);
    fn terminal(&self, task: &Task);
    fn log(&self, msg: &str);
}

/// 新增任务的输入（来自 `host.native.call('download.start')`）。
/// 默认 User-Agent（客户端级）。
///
/// 必须始终发一个 UA：部分 CDN/Tengine 有 UA ACL，**空 UA 会被直接 403**。
/// 任务自带的 `User-Agent` 优先（请求层覆盖默认值），所以"默认 + 可追加、不覆盖自带"。
pub const DEFAULT_USER_AGENT: &str = "GStore/1.0 (+android)";

#[derive(Debug, Clone, Default)]
pub struct NewTask {
    /// 资源类型：app / model / asset / file …（下载不只服务应用）
    pub kind: String,
    /// 资源在自身类型下的标识（包名、模型仓库名、资源相对路径…）
    pub resource_id: String,
    pub resource_version: String,
    /// 调用方显式指定的判重键；留空则按 [`crate::dedup::derive_dedup_key`] 派生
    pub dedup_key: Option<String>,
    /// 撞键策略（keep / replace / append）
    pub conflict: ConflictPolicy,
    /// 严格判重：键相同但**来源 URL 不同**、且已有任务已完成时，报冲突而不是静默复用。
    ///
    /// 由调用方按来源语义决定：单源渠道（同版本可能存在多个**同名**构建）应开启；
    /// 镜像类源必须关闭——否则"换镜像重下"会被误报成冲突。
    pub strict_dedup: bool,

    /// 以下为**展示/来源**字段：参与展示与请求，**不参与判重**
    pub app_id: String,
    pub app_name: String,
    pub version: String,
    pub file_name: String,
    pub url: String,
    pub file_path: String,
    /// 下载完成后是否自动安装
    pub install_after_download: bool,

    pub headers: Vec<(String, String)>,
    pub expected_sha256: Option<String>,
    pub priority: i32,
    pub connections: Option<u32>,
}

struct Inner {
    conn: SharedConn,
    rt: tokio::runtime::Handle,
    cfg: Mutex<SchedulerConfig>,
    emitter: Mutex<Option<Arc<dyn TaskEmitter>>>,
    cancels: Mutex<HashMap<u64, Arc<AtomicBool>>>,
    /// 暂停意图：取消时据此区分"暂停"与"取消"（暂停要保留分段以便续传）
    pause_intent: Mutex<std::collections::HashSet<u64>>,
    /// 单任务运行期偏好：连接数与自定义请求头（不入库，进程内有效）
    task_connections: Mutex<HashMap<u64, u32>>,
    task_headers: Mutex<HashMap<u64, Vec<(String, String)>>>,
    notify: Notify,
    shutdown: AtomicBool,
    /// 测试用：记录同时在跑的峰值
    #[cfg(test)]
    peak_concurrent: std::sync::atomic::AtomicUsize,
    #[cfg(test)]
    running_now: std::sync::atomic::AtomicUsize,
}

pub struct Scheduler {
    inner: Arc<Inner>,
}

impl Scheduler {
    pub fn new(
        conn: SharedConn,
        rt: tokio::runtime::Handle,
        cfg: SchedulerConfig,
        emitter: Arc<dyn TaskEmitter>,
    ) -> Arc<Self> {
        Arc::new(Self {
            inner: Arc::new(Inner {
                conn,
                rt,
                cfg: Mutex::new(cfg),
                emitter: Mutex::new(Some(emitter)),
                cancels: Mutex::new(HashMap::new()),
                pause_intent: Mutex::new(std::collections::HashSet::new()),
                task_connections: Mutex::new(HashMap::new()),
                task_headers: Mutex::new(HashMap::new()),
                notify: Notify::new(),
                shutdown: AtomicBool::new(false),
                #[cfg(test)]
                peak_concurrent: std::sync::atomic::AtomicUsize::new(0),
                #[cfg(test)]
                running_now: std::sync::atomic::AtomicUsize::new(0),
            }),
        })
    }

    /// 启动调度循环（实例创建时调用一次）。
    pub fn start(self: &Arc<Self>) {
        let inner = self.inner.clone();
        let rt = inner.rt.clone();
        rt.spawn(async move {
            loop {
                inner.notify.notified().await;
                if inner.shutdown.load(Ordering::SeqCst) {
                    break;
                }
                Self::dispatch_once(&inner).await;
            }
        });
    }

    pub fn shutdown(&self) {
        self.inner.shutdown.store(true, Ordering::SeqCst);
        // 唤醒并让所有在跑任务尽快收敛
        for (_, c) in self.inner.cancels.lock().unwrap().iter() {
            c.store(true, Ordering::SeqCst);
        }
        self.inner.notify.notify_waiters();
    }

    pub fn set_config(&self, cfg: SchedulerConfig) {
        *self.inner.cfg.lock().unwrap() = cfg;
        self.inner.notify.notify_one();
    }

    pub fn config(&self) -> SchedulerConfig {
        self.inner.cfg.lock().unwrap().clone()
    }

    /// 新增下载。
    ///
    /// **防重复**：同 `(app_id, version, file_name)` 已有活动任务 → 直接返回它，
    /// 不再起第二个 run（既有实现缺的正是这一条）。
    /// 已完成且文件仍在 → 也直接复用（不重复下载）。
    pub fn add(self: &Arc<Self>, spec: NewTask) -> Result<Task, ModuleError> {
        if spec.url.trim().is_empty() {
            return Err(ModuleError::invalid_arg("url 不能为空"));
        }
        if spec.file_path.trim().is_empty() {
            return Err(ModuleError::invalid_arg("file_path 不能为空"));
        }

        // ---- 判重：逻辑键 + 调用方策略 ----
        // id 是代理键（DB 自增，Rust 生成并管理）；dedup_key 才是"什么算同一个下载"。
        let base_key = dedup::derive_dedup_key(&dedup::DedupInput {
            explicit_key: spec.dedup_key.clone(),
            kind: spec.kind.clone(),
            resource_id: spec.resource_id.clone(),
            resource_version: spec.resource_version.clone(),
            file_name: spec.file_name.clone(),
            url: spec.url.clone(),
            dest_path: spec.file_path.clone(),
        });

        // 先把"可能要复用的那条"找出来，再做落盘路径检查 ——
        // 顺序反了会把"自己"算成冲突（同一个任务当然占着自己的目标路径）。
        let mut key = base_key.clone();
        let mut existing = store::find_by_dedup_key(&self.inner.conn, &key)
            .map_err(ModuleError::internal)?;
        let mut reset_progress = false;

        match spec.conflict {
            ConflictPolicy::Keep => {
                if let Some(prev) = existing.as_ref() {
                    if prev.status.is_active() {
                        // ★ 防重复任务：直接复用，不新建 run
                        self.log(&format!(
                            "download: 任务已存在（id={} status={:?} key={}），复用而不重复创建",
                            prev.id, prev.status, prev.dedup_key
                        ));
                        return Ok(prev.clone());
                    }
                    if prev.status == TaskStatus::Completed
                        && std::path::Path::new(&prev.file_path).exists()
                    {
                        // 严格判重：同名同版本但来源不同 → 可疑碰撞（如两个同名构建）。
                        // 报出来让调用方决定，不静默覆盖。
                        if spec.strict_dedup && !prev.url.is_empty() && prev.url != spec.url {
                            return Err(ModuleError::invalid_arg(&format!(
                                "已存在同名任务但来源不同（id={}）：已有 {} ，本次 {} 。\
                                 如确认是两个不同的下载，请显式指定 dedupKey，或用 conflict=append 另存一份",
                                prev.id, prev.url, spec.url
                            )));
                        }
                        self.log(&format!("download: 任务已完成且文件有效（id={}），跳过", prev.id));
                        return Ok(prev.clone());
                    }
                }
            }
            ConflictPolicy::Replace => {
                if let Some(prev) = existing.as_ref() {
                    // 沿用同一行、同一 id（外部持有的 id 与取消 token 都不作废），只清进度
                    store::clear_segments(&self.inner.conn, prev.id)
                        .map_err(ModuleError::internal)?;
                    reset_progress = true;
                    self.log(&format!("download: 按 replace 策略重下（id={}）", prev.id));
                }
            }
            ConflictPolicy::Append => {
                if existing.is_some() {
                    let mut n = 2u32;
                    loop {
                        let cand = dedup::with_suffix(&base_key, n);
                        let taken = store::find_by_dedup_key(&self.inner.conn, &cand)
                            .map_err(ModuleError::internal)?
                            .is_some();
                        if !taken {
                            key = cand;
                            existing = None;
                            break;
                        }
                        n += 1;
                        if n > 999 {
                            return Err(ModuleError::internal("append 唯一后缀已达上限"));
                        }
                    }
                    self.log(&format!("download: 按 append 策略另建任务（key={}）", key));
                }
            }
        }

        // 正确性兜底：同一落盘路径不允许两个**活动**任务（两个 writer 必然互相破坏）。
        // schema 层有 `ux_download_task_active_dest` 兜底，这里是为了给出可读错误。
        // 注意排除"将要复用的自身"。
        if let Some(other) = store::find_active_by_dest(
            &self.inner.conn,
            &spec.file_path,
            existing.as_ref().map(|t| t.id),
        )
        .map_err(ModuleError::internal)?
        {
            return Err(ModuleError::invalid_arg(&format!(
                "目标路径已被活动任务占用（id={}，key={}）：{}",
                other.id, other.dedup_key, spec.file_path
            )));
        }

        let now = now_ms();
        let keep = existing.as_ref();

        // 把「最终生效的 UA」并入任务 headers 再落库。
        //
        // 默认 UA 是 client 级设置（reqwest 自动附加），原本不进任务记录，
        // 于是面板看不到"这次到底发了什么 UA"——而它恰恰常是关键
        // （ModelScope 那类 CDN 有 UA ACL，空 UA 直接 403）。
        // 调用方自带 UA（如 Vivo）时**保留其值**，不覆盖。
        let mut headers = spec.headers.clone();
        if !headers.iter().any(|(k, _)| k.eq_ignore_ascii_case("user-agent")) {
            headers.push(("User-Agent".to_string(), DEFAULT_USER_AGENT.to_string()));
        }

        let task = Task {
            id: 0,
            dedup_key: key.clone(),
            headers,
            install_after_download: spec.install_after_download,
            last_started_at: now,
            kind: spec.kind.clone(),
            resource_id: spec.resource_id.clone(),
            resource_version: spec.resource_version.clone(),
            app_id: spec.app_id.clone(),
            app_name: spec.app_name.clone(),
            version: spec.version.clone(),
            file_name: spec.file_name.clone(),
            url: spec.url.clone(),
            file_path: spec.file_path.clone(),
            total: if reset_progress { 0 } else { keep.map(|t| t.total).unwrap_or(0) },
            received: if reset_progress { 0 } else { keep.map(|t| t.received).unwrap_or(0) },
            status: TaskStatus::Queued,
            speed_bps: 0,
            eta_sec: None,
            error: None,
            fail_kind: None,
            retries: 0,
            segments: if reset_progress {
                Vec::new()
            } else {
                keep.map(|t| t.segments.clone()).unwrap_or_default()
            },
            server_meta: if reset_progress {
                Default::default()
            } else {
                keep.map(|t| t.server_meta.clone()).unwrap_or_default()
            },
            expected_sha256: spec.expected_sha256.clone(),
            actual_sha256: None,
            priority: spec.priority,
            queue_reason: None,
            created_at: keep.map(|t| t.created_at).unwrap_or(now),
            updated_at: now,
        };

        let id = store::upsert_task(&self.inner.conn, &task).map_err(ModuleError::internal)?;
        // 单任务连接数等 per-task 配置随 extras 传给运行时（存 DB 无意义，属运行时偏好）
        if let Some(c) = spec.connections {
            self.inner
                .task_connections
                .lock()
                .unwrap()
                .insert(id, c);
        }
        if !spec.headers.is_empty() {
            self.inner
                .task_headers
                .lock()
                .unwrap()
                .insert(id, spec.headers.clone());
        }

        let saved = store::get_task(&self.inner.conn, id)
            .map_err(ModuleError::internal)?
            .ok_or_else(|| ModuleError::internal("任务写入后读取失败"))?;
        self.inner.notify.notify_one();
        Ok(saved)
    }

    pub fn pause(&self, id: u64) -> Result<(), ModuleError> {
        let t = self.require(id)?;
        if t.status.is_terminal() {
            return Ok(()); // 终态无需暂停
        }
        self.inner.pause_intent.lock().unwrap().insert(id);
        if let Some(c) = self.inner.cancels.lock().unwrap().get(&id) {
            c.store(true, Ordering::SeqCst);
        }
        // 还在排队没开跑 → 直接落暂停态（否则调度器会把它捞起来）
        if t.status == TaskStatus::Queued {
            self.set_status(id, TaskStatus::Paused, Some("已暂停"))?;
            self.inner.pause_intent.lock().unwrap().remove(&id);
        }
        Ok(())
    }

    pub fn resume(self: &Arc<Self>, id: u64) -> Result<(), ModuleError> {
        let t = self.require(id)?;
        if !matches!(t.status, TaskStatus::Paused | TaskStatus::Failed | TaskStatus::Cancelled) {
            return Ok(());
        }
        self.set_status(id, TaskStatus::Queued, None)?;
        self.inner.notify.notify_one();
        Ok(())
    }

    /// 取消：不保留"可续传"语义（用户明确不要了），但**不删已下载数据**，
    /// 由 UI 决定是否同时清理文件（`remove` 才删）。
    pub fn cancel(&self, id: u64) -> Result<(), ModuleError> {
        let _ = self.require(id)?;
        self.inner.pause_intent.lock().unwrap().remove(&id);
        if let Some(c) = self.inner.cancels.lock().unwrap().get(&id) {
            c.store(true, Ordering::SeqCst);
        }
        self.set_status(id, TaskStatus::Cancelled, Some("已取消"))?;
        self.inner.notify.notify_one();
        Ok(())
    }

    /// 刷新「最后开始时间」：重试/继续/重新下载都算"重新开始"，列表据此置顶。
    fn touch_started_at(&self, id: u64) {
        let conn = self.inner.conn.clone();
        let _ = store::touch_last_started_at(&conn, id, now_ms());
    }

    /// 「重新下载」：清掉落盘分段与进度，**从 0 开始**。
    ///
    /// 与 [Self::resume] / [Self::retry] 的区别：那两者保留已下分段（续传）；
    /// 这里删除 `.part*`、重置进度与服务端元数据，用于文件损坏、源变更等需要真正重来的场景。
    pub fn restart(self: &Arc<Self>, id: u64) -> Result<(), ModuleError> {
        self.touch_started_at(id);
        let mut t = store::get_task(&self.inner.conn, id)
            .map_err(ModuleError::internal)?
            .ok_or_else(|| ModuleError::invalid_arg("任务不存在"))?;

        if t.status.is_active() {
            let _ = self.cancel(id);
        }
        // 删除落盘分段（扫一遍编号，避免残留脏数据被续传捡起）
        for i in 0..128u32 {
            let _ = std::fs::remove_file(format!("{}.part{}", t.file_path, i));
        }
        store::clear_segments(&self.inner.conn, id).map_err(ModuleError::internal)?;

        t.segments = Vec::new();
        t.received = 0;
        t.total = 0;
        t.speed_bps = 0;
        t.eta_sec = None;
        t.error = None;
        t.fail_kind = None;
        t.server_meta = Default::default();
        t.status = TaskStatus::Queued;
        t.queue_reason = None;
        t.updated_at = now_ms();

        store::upsert_task(&self.inner.conn, &t).map_err(ModuleError::internal)?;
        self.log(&format!("download: 重新下载（已清分段与进度）id={id}"));
        self.inner.notify.notify_one();
        Ok(())
    }

    /// 重试：保留分段（等价于续传），清掉失败信息重新排队。
    pub fn retry(self: &Arc<Self>, id: u64) -> Result<(), ModuleError> {
        self.touch_started_at(id);
        let _ = self.require(id)?;
        let mut t = store::get_task(&self.inner.conn, id)
            .map_err(ModuleError::internal)?
            .ok_or_else(|| ModuleError::instance_not_found(id))?;
        t.error = None;
        t.fail_kind = None;
        t.status = TaskStatus::Queued;
        t.queue_reason = None;
        // 关键：必须清掉上一轮的进度。
        // 否则面板会沿用旧的 received(== total) 先显示 100%，等首个进度事件到了再回落
        // —— 就是"重新下载从 100 开始然后才显示真正进度"的现象。
        // 分段/总长由引擎重新探测后上报，这里一律清零。
        t.received = 0;
        t.total = 0;
        t.speed_bps = 0;
        t.eta_sec = None;
        t.segments = Vec::new();
        t.updated_at = now_ms();
        store::upsert_task(&self.inner.conn, &t).map_err(ModuleError::internal)?;
        self.inner.notify.notify_one();
        Ok(())
    }

    /// 删除任务（含分段与已下载的临时文件）。
    pub fn remove(&self, id: u64) -> Result<(), ModuleError> {
        if let Some(c) = self.inner.cancels.lock().unwrap().get(&id) {
            c.store(true, Ordering::SeqCst);
        }
        if let Some(t) = store::get_task(&self.inner.conn, id).map_err(ModuleError::internal)? {
            let segs = if t.segments.is_empty() {
                vec![Segment { index: 0, start_byte: 0, end_byte: 0, received: 0, done: false }]
            } else {
                t.segments.clone()
            };
            // 同步清理：删除是用户显式动作，允许阻塞
            let _ = std::fs::remove_file(format!("{}.merge", t.file_path));
            for s in segs {
                let _ = std::fs::remove_file(format!("{}.part{}", t.file_path, s.index));
            }
            if let Some(p) = self.inner.task_headers.lock().unwrap().remove(&id) {
                drop(p);
            }
            self.inner.task_connections.lock().unwrap().remove(&id);
        }
        store::delete_task(&self.inner.conn, id).map_err(ModuleError::internal)
    }

    pub fn get(&self, id: u64) -> Result<Option<Task>, ModuleError> {
        store::get_task(&self.inner.conn, id).map_err(ModuleError::internal)
    }

    pub fn list(&self, filter: &[TaskStatus]) -> Result<Vec<Task>, ModuleError> {
        store::list_tasks(&self.inner.conn, filter).map_err(ModuleError::internal)
    }

    /// 调度一轮：按优先级取排队任务，直到并发额度用满。
    async fn dispatch_once(inner: &Arc<Inner>) {
        let max = inner.cfg.lock().unwrap().max_concurrent.max(1);
        loop {
            let active = Self::active_count(&inner.conn);
            if active >= max {
                // 排队中的任务标注"为什么还没开始"，面板可直接展示
                let _ = Self::mark_waiting(&inner.conn, active, max);
                return;
            }
            let next = match Self::pick_next(&inner.conn) {
                Ok(Some(t)) => t,
                Ok(None) => return,
                Err(e) => {
                    Self::log_inner(inner, &format!("dispatch 查询失败: {e}"));
                    return;
                }
            };
            let id = next.id;
            if Self::set_status_inner(&inner.conn, id, TaskStatus::Connecting, None).is_err() {
                continue;
            }
            let inner2 = inner.clone();
            inner.rt.spawn(async move {
                Self::run_task(inner2, id).await;
            });
        }
    }

    /// 并发额度真源：DB 里处于 connecting/downloading 的行数。
    fn active_count(conn: &SharedConn) -> usize {
        let Ok(c) = conn.lock() else { return 0 };
        c.query_row(
            "SELECT COUNT(*) FROM download_task WHERE status IN (?1, ?2)",
            rusqlite::params![
                TaskStatus::Connecting.as_i32(),
                TaskStatus::Downloading.as_i32()
            ],
            |r| r.get::<_, i64>(0),
        )
        .unwrap_or(0) as usize
    }

    /// 取下一个待调度任务：优先级降序，同优先级按创建顺序（FIFO，避免饿死）。
    fn pick_next(conn: &SharedConn) -> Result<Option<Task>, String> {
        let id: Option<i64> = {
            let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
            c.query_row(
                "SELECT id FROM download_task WHERE status=?1 ORDER BY priority DESC, id ASC LIMIT 1",
                rusqlite::params![TaskStatus::Queued.as_i32()],
                |r| r.get(0),
            )
            .ok()
        };
        match id {
            Some(id) => store::get_task(conn, id as u64),
            None => Ok(None),
        }
    }

    fn mark_waiting(conn: &SharedConn, active: usize, max: usize) -> Result<(), String> {
        let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
        c.execute(
            "UPDATE download_task SET queue_reason=?1 WHERE status=?2",
            rusqlite::params![
                format!("等待并发额度（{active}/{max} 进行中）"),
                TaskStatus::Queued.as_i32()
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    fn set_status(
        &self,
        id: u64,
        status: TaskStatus,
        reason: Option<&str>,
    ) -> Result<(), ModuleError> {
        Self::set_status_inner(&self.inner.conn, id, status, reason).map_err(ModuleError::internal)
    }

    fn set_status_inner(
        conn: &SharedConn,
        id: u64,
        status: TaskStatus,
        reason: Option<&str>,
    ) -> Result<(), String> {
        let c = conn.lock().map_err(|_| "db lock poisoned".to_string())?;
        c.execute(
            "UPDATE download_task SET status=?2, queue_reason=?3, updated_at=?4 WHERE id=?1",
            rusqlite::params![id as i64, status.as_i32(), reason, now_ms()],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    fn require(&self, id: u64) -> Result<Task, ModuleError> {
        store::get_task(&self.inner.conn, id)
            .map_err(ModuleError::internal)?
            .ok_or_else(|| ModuleError::instance_not_found(id))
    }

    fn log(&self, msg: &str) {
        Self::log_inner(&self.inner, msg);
    }

    fn log_inner(inner: &Arc<Inner>, msg: &str) {
        if let Some(e) = inner.emitter.lock().unwrap().as_ref() {
            e.log(msg);
        }
    }

    /// 真正执行一个任务：建参数 → 跑引擎 → 落终态 → 释放额度。
    async fn run_task(inner: Arc<Inner>, id: u64) {
        let cancel = Arc::new(AtomicBool::new(false));
        inner.cancels.lock().unwrap().insert(id, cancel.clone());
        #[cfg(test)]
        {
            let n = inner.running_now.fetch_add(1, Ordering::SeqCst) + 1;
            inner.peak_concurrent.fetch_max(n, Ordering::SeqCst);
        }

        let task = match store::get_task(&inner.conn, id) {
            Ok(Some(t)) => t,
            _ => {
                inner.cancels.lock().unwrap().remove(&id);
                return;
            }
        };

        let cfg = inner.cfg.lock().unwrap().clone();
        let headers = inner
            .task_headers
            .lock()
            .unwrap()
            .get(&id)
            .cloned()
            .unwrap_or_default();
        let connections = inner
            .task_connections
            .lock()
            .unwrap()
            .get(&id)
            .copied()
            .unwrap_or(cfg.default_connections);

        // 分段容器交给引擎复用；run 结束后由这里落库，
        // 这样面板重新进入页面查询时仍能看到分段明细
        let shared_segments: Arc<tokio::sync::Mutex<Vec<Segment>>> =
            Arc::new(tokio::sync::Mutex::new(Vec::new()));

        let params = DownloadParams {
            url: task.url.clone(),
            dest: task.file_path.clone(),
            headers,
            connections,
            expected_sha256: task.expected_sha256.clone(),
            max_retries: cfg.max_retries,
            speed_limit_bps: cfg.speed_limit_bps,
            segments: task.segments.clone(),
            prev_meta: task.server_meta.clone(),
            // 有历史分段才需要一致性校验（全新下载无需比对）
            verify_server_consistency: !task.segments.is_empty(),
            segments_out: Some(shared_segments.clone()),
        };

        let sink: Arc<dyn ProgressSink> = Arc::new(SchedulerSink {
            conn: inner.conn.clone(),
            emitter: inner.emitter.lock().unwrap().clone(),
            task_id: id,
            last_segments: Mutex::new(Vec::new()),
        });

        // 默认 User-Agent：部分 CDN 有 UA ACL，**空 UA 直接 403**
        //（实测 ModelScope/Tengine：`denied by UA ACL = blacklist`）。
        // 注意这里是**客户端默认值**：任务自带的 `User-Agent` 会在请求层覆盖它，
        // 所以不会影响需要特定 UA 的源（如 Vivo）。其余任务头照常追加。
        let client = reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(20))
            .user_agent(DEFAULT_USER_AGENT)
            .build()
            .unwrap_or_default();

        let outcome = engine::run(&client, &params, sink, cancel.clone()).await;

        // 分段明细落库（无论成败）：分段之前只活在内存里，导致面板重新进入页面
        // 查询时看不到任何分段记录。
        {
            let snap = shared_segments.lock().await.clone();
            if !snap.is_empty() {
                let _ = store::save_segments(&inner.conn, id, &snap);
            }
        }

        // 落终态
        let mut t = match store::get_task(&inner.conn, id) {
            Ok(Some(t)) => t,
            _ => {
                inner.cancels.lock().unwrap().remove(&id);
                return;
            }
        };
        let paused_intent = inner.pause_intent.lock().unwrap().remove(&id);

        match outcome {
            Outcome::Completed { total, sha256 } => {
                t.status = TaskStatus::Completed;
                t.total = total.max(t.total);
                t.received = t.total;
                t.speed_bps = 0;
                t.eta_sec = None;
                t.error = None;
                t.fail_kind = None;
                t.actual_sha256 = sha256;
                t.queue_reason = None;
                t.segments.clear();
            }
            Outcome::Cancelled => {
                if paused_intent {
                    t.status = TaskStatus::Paused;
                    t.queue_reason = Some("已暂停（分段已保留，可继续）".into());
                    // 暂停要保留分段，续传才有意义
                    t.segments = load_segments_after_cancel(&inner.conn, id).await;
                } else {
                    t.status = TaskStatus::Cancelled;
                    t.queue_reason = Some("已取消".into());
                }
                t.speed_bps = 0;
                t.eta_sec = None;
            }
            Outcome::Failed { kind, message } => {
                if paused_intent {
                    // 暂停过程中恰好失败，按暂停处理更贴近用户预期
                    t.status = TaskStatus::Paused;
                    t.queue_reason = Some("已暂停（分段已保留，可继续）".into());
                } else {
                    t.status = TaskStatus::Failed;
                    t.error = Some(message);
                    t.fail_kind = Some(kind);
                }
                t.speed_bps = 0;
                t.eta_sec = None;
            }
        }
        t.updated_at = now_ms();
        let _ = store::upsert_task(&inner.conn, &t);
        if let Some(e) = inner.emitter.lock().unwrap().as_ref() {
            e.terminal(&t);
        }

        inner.cancels.lock().unwrap().remove(&id);
        #[cfg(test)]
        {
            inner.running_now.fetch_sub(1, Ordering::SeqCst);
        }
        // 让出额度后立刻尝试调度下一个
        inner.notify.notify_one();
    }
}

/// 取消后把"已落盘多少"尽量补回 DB，供续传使用。
async fn load_segments_after_cancel(conn: &SharedConn, id: u64) -> Vec<Segment> {
    let Ok(Some(t)) = store::get_task(conn, id) else {
        return Vec::new();
    };
    if t.segments.is_empty() {
        return Vec::new();
    }
    let mut out = t.segments.clone();
    for s in out.iter_mut() {
        let p = format!("{}.part{}", t.file_path, s.index);
        if let Ok(m) = tokio::fs::metadata(&p).await {
            s.received = m.len().min(s.len());
            s.done = s.received == s.len();
        }
    }
    out
}

/// 进度出口：窄更新 DB + 节流上报事件。
struct SchedulerSink {
    conn: SharedConn,
    emitter: Option<Arc<dyn TaskEmitter>>,
    task_id: u64,
    last_segments: Mutex<Vec<Segment>>,
}

impl ProgressSink for SchedulerSink {
    fn on_progress(&self, received: u64, total: u64, segments: Option<Vec<Segment>>) {
        self.on_progress_ex(received, total, segments, 0, None);
    }

    fn on_progress_ex(
        &self,
        received: u64,
        total: u64,
        segments: Option<Vec<Segment>>,
        speed_bps: u64,
        eta_sec: Option<u64>,
    ) {
        let _ = store::update_progress(
            &self.conn,
            self.task_id,
            received,
            total,
            speed_bps,
            eta_sec,
            TaskStatus::Downloading,
            now_ms(),
        );
        // 分段快照只在变化时下发（压体积）
        let segs_dto = if let Some(segs) = segments {
            let changed = {
                let mut last = self.last_segments.lock().unwrap();
                let changed = *last != segs;
                if changed {
                    *last = segs.clone();
                }
                changed
            };
            if changed {
                Some(
                    segs.iter()
                        .map(|s| crate::model::SegmentDto {
                            index: s.index as i32,
                            start_byte: s.start_byte as i64,
                            end_byte: s.end_byte as i64,
                            received: s.received as i64,
                        })
                        .collect(),
                )
            } else {
                None
            }
        } else {
            None
        };
        if let Some(e) = self.emitter.as_ref() {
            e.progress(ProgressEvent {
                task_id: self.task_id as i64,
                status: TaskStatus::Downloading.as_i32(),
                total: total as i64,
                received: received as i64,
                speed_bps: speed_bps as i64,
                eta_sec: eta_sec.map(|v| v as i64),
                segments: segs_dto,
                error: None,
                fail_kind: None,
            });
        }
    }

    fn on_status(&self, status: TaskStatus) {
        let _ = Scheduler::set_status_inner(&self.conn, self.task_id, status, None);
    }
}

/// 便捷：把失败分类转成面板文案（lib.rs 组装响应时用）。
pub fn fail_label(k: &FailKind) -> String {
    k.label()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store;
    use crate::test_support::*;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;

    /// 严格判重：同键但来源 URL 不同、且已有任务已完成 → 报冲突，不静默覆盖。
    /// 非严格（镜像类源）→ 仍复用，保证"换镜像不产生重复任务"。
    #[test]
    fn strict_dedup_reports_conflict_instead_of_overwriting() {
        let h = harness(SchedulerConfig::default());
        h.rt.block_on(async {
            let mut first = spec("https://src-a/app.apk", "/tmp/sd/app.apk", "sd", 0);
            first.dedup_key = Some("app:sd:1.0".into());
            let t1 = h.sched.add(first).unwrap();

            // 造一条「已完成」且文件存在的同键任务
            let mut done = store::get_task(&h.conn, t1.id).unwrap().unwrap();
            done.status = TaskStatus::Completed;
            store::upsert_task(&h.conn, &done).unwrap();
            std::fs::create_dir_all(std::path::Path::new(&done.file_path).parent().unwrap()).ok();
            std::fs::write(&done.file_path, b"payload").unwrap();

            // 非严格：来源 URL 不同也复用（镜像场景）
            let mut lenient = spec("https://src-b/app.apk", "/tmp/sd/app.apk", "sd", 0);
            lenient.dedup_key = Some("app:sd:1.0".into());
            lenient.strict_dedup = false;
            let t2 = h.sched.add(lenient).unwrap();
            assert_eq!(t2.id, t1.id, "非严格模式应复用同一行");

            // 严格：必须报冲突
            let mut strict = spec("https://src-b/app.apk", "/tmp/sd/app.apk", "sd", 0);
            strict.dedup_key = Some("app:sd:1.0".into());
            strict.strict_dedup = true;
            let err = h.sched.add(strict).unwrap_err();
            let msg = format!("{err:?}");
            assert!(msg.contains("同名"), "严格模式应报同名冲突，实际：{msg}");
        });
    }

    struct Recorder {
        progress: AtomicUsize,
        done: AtomicUsize,
    }

    impl TaskEmitter for Recorder {
        fn progress(&self, _ev: ProgressEvent) {
            self.progress.fetch_add(1, Ordering::Relaxed);
        }
        fn terminal(&self, _t: &Task) {
            self.done.fetch_add(1, Ordering::Relaxed);
        }
        fn log(&self, _m: &str) {}
    }

    struct Harness {
        sched: Arc<Scheduler>,
        conn: SharedConn,
        rec: Arc<Recorder>,
        rt: tokio::runtime::Runtime,
    }

    fn harness(cfg: SchedulerConfig) -> Harness {
        let conn = store::open(":memory:").unwrap();
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let rec = Arc::new(Recorder {
            progress: AtomicUsize::new(0),
            done: AtomicUsize::new(0),
        });
        let sched = Scheduler::new(conn.clone(), rt.handle().clone(), cfg, rec.clone());
        sched.start();
        Harness { sched, conn, rec, rt }
    }

    fn spec(url: &str, dest: &str, key: &str, priority: i32) -> NewTask {
        NewTask {
            app_id: format!("app.{key}"),
            app_name: key.into(),
            version: "1.0".into(),
            file_name: format!("{key}.bin"),
            url: url.into(),
            file_path: dest.into(),
            priority,
            ..Default::default()
        }
    }

    /// 轮询等待任务到达期望状态（超时返回最后一次快照，便于断言时看到真实状态）。
    async fn wait_status(conn: &SharedConn, id: u64, want: TaskStatus, ms: u64) -> Task {
        let deadline = std::time::Instant::now() + Duration::from_millis(ms);
        loop {
            let t = store::get_task(conn, id).unwrap().unwrap();
            if t.status == want || std::time::Instant::now() > deadline {
                return t;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// ★ 防重复任务：任务在跑时再点一次，必须复用同一任务、不新建 run。
    ///
    /// 这正是既有 Dart 实现缺失的一条（只在"已完成且文件有效"时短路，
    /// 活动态会再起一个 run，导致同一文件两个并发 writer）。
    #[test]
    fn duplicate_add_reuses_active_task_and_starts_no_second_run() {
        let h = harness(SchedulerConfig { max_concurrent: 1, ..Default::default() });
        let url = spawn_range_server_delayed(make_body(512 * 1024), "\"v1\"", 300);
        let dir = tmpdir("dedup");
        let dest = dir.join("dup.bin").to_string_lossy().to_string();

        h.rt.block_on(async {
            let a = h.sched.add(spec(&url, &dest, "dup", 0)).unwrap();
            // 第一次 add 后任务应已进入活动态
            let active = wait_status(&h.conn, a.id, TaskStatus::Downloading, 2000).await;
            assert!(active.status.is_active(), "任务应处于活动态，实际 {:?}", active.status);

            // 再点一次（完全相同的 key）
            let b = h.sched.add(spec(&url, &dest, "dup", 0)).unwrap();
            assert_eq!(a.id, b.id, "同键任务必须复用同一行，而不是新建");
            assert!(
                b.status.is_active(),
                "第二次 add 不得把活动任务重置为排队（那会再起一个 run），实际 {:?}",
                b.status
            );

            let done = wait_status(&h.conn, a.id, TaskStatus::Completed, 5000).await;
            assert_eq!(done.status, TaskStatus::Completed, "应正常完成");
            assert_eq!(
                h.rec.done.load(Ordering::Relaxed),
                1,
                "只能有一个终态事件——第二个 run 会再发一次"
            );
            assert_eq!(h.sched.list(&[]).unwrap().len(), 1, "库里只能有一条任务");
            #[cfg(test)]
            assert_eq!(
                h.sched.inner.peak_concurrent.load(Ordering::SeqCst),
                1,
                "峰值并发应为 1"
            );
            assert!(std::path::Path::new(&dest).exists());
        });
    }

    #[test]
    fn concurrency_limit_serializes_tasks() {
        let h = harness(SchedulerConfig { max_concurrent: 1, ..Default::default() });
        let url = spawn_range_server_delayed(make_body(256 * 1024), "\"v1\"", 200);

        h.rt.block_on(async {
            let a = h.sched.add(spec(&url, &tmp(&"a"), "a", 0)).unwrap();
            let b = h.sched.add(spec(&url, &tmp(&"b"), "b", 0)).unwrap();

            // b 必须排队，并且能看到"为什么在排队"
            tokio::time::sleep(Duration::from_millis(120)).await;
            let bt = store::get_task(&h.conn, b.id).unwrap().unwrap();
            assert_eq!(bt.status, TaskStatus::Queued);
            assert!(
                bt.queue_reason.as_deref().unwrap_or("").contains("并发额度"),
                "排队原因应说明额度不足，实际 {:?}",
                bt.queue_reason
            );

            wait_status(&h.conn, a.id, TaskStatus::Completed, 5000).await;
            wait_status(&h.conn, b.id, TaskStatus::Completed, 5000).await;
            assert_eq!(h.sched.inner.peak_concurrent.load(Ordering::SeqCst), 1);
        });
    }

    #[test]
    fn completes_with_sha256_verification() {
        let h = harness(SchedulerConfig { max_concurrent: 2, ..Default::default() });
        let body = make_body(1024 * 1024);
        let expect = sha256_of(&body);
        let url = spawn_range_server(body, "\"v1\"");
        let dir = tmpdir("sha");
        let dest = dir.join("x.bin").to_string_lossy().to_string();

        h.rt.block_on(async {
            let mut s = spec(&url, &dest, "sha", 0);
            s.expected_sha256 = Some(expect.clone());
            let t = h.sched.add(s).unwrap();
            let done = wait_status(&h.conn, t.id, TaskStatus::Completed, 8000).await;
            assert_eq!(done.status, TaskStatus::Completed, "err={:?}", done.error);
            assert_eq!(done.actual_sha256.as_deref(), Some(expect.as_str()));
            assert_eq!(done.received, done.total);
            assert!(!done.segments.is_empty(), "完成后应保留分段记录（面板回看用）");
        });
    }

    #[test]
    fn pause_queued_then_resume_keeps_going() {
        let h = harness(SchedulerConfig { max_concurrent: 1, ..Default::default() });
        let url = spawn_range_server_delayed(make_body(256 * 1024), "\"v1\"", 250);

        h.rt.block_on(async {
            let _a = h.sched.add(spec(&url, &tmp(&"pa"), "pa", 0)).unwrap();
            let b = h.sched.add(spec(&url, &tmp(&"pb"), "pb", 0)).unwrap();
            tokio::time::sleep(Duration::from_millis(80)).await;

            h.sched.pause(b.id).unwrap();
            let p = wait_status(&h.conn, b.id, TaskStatus::Paused, 2000).await;
            assert_eq!(p.status, TaskStatus::Paused);

            // 暂停态不应被调度器偷偷捞起来
            tokio::time::sleep(Duration::from_millis(150)).await;
            assert_eq!(
                store::get_task(&h.conn, b.id).unwrap().unwrap().status,
                TaskStatus::Paused
            );

            h.sched.resume(b.id).unwrap();
            let done = wait_status(&h.conn, b.id, TaskStatus::Completed, 8000).await;
            assert_eq!(done.status, TaskStatus::Completed, "err={:?}", done.error);
        });
    }

    #[test]
    fn cancel_queued_marks_cancelled() {
        let h = harness(SchedulerConfig { max_concurrent: 1, ..Default::default() });
        let url = spawn_range_server_delayed(make_body(256 * 1024), "\"v1\"", 300);

        h.rt.block_on(async {
            let _a = h.sched.add(spec(&url, &tmp(&"ca"), "ca", 0)).unwrap();
            let b = h.sched.add(spec(&url, &tmp(&"cb"), "cb", 0)).unwrap();
            tokio::time::sleep(Duration::from_millis(80)).await;

            h.sched.cancel(b.id).unwrap();
            let c = wait_status(&h.conn, b.id, TaskStatus::Cancelled, 2000).await;
            assert_eq!(c.status, TaskStatus::Cancelled);

            // 取消后不得再被调度执行
            tokio::time::sleep(Duration::from_millis(200)).await;
            assert_eq!(
                store::get_task(&h.conn, b.id).unwrap().unwrap().status,
                TaskStatus::Cancelled
            );
        });
    }

    #[test]
    fn higher_priority_dispatched_first() {
        let h = harness(SchedulerConfig { max_concurrent: 1, ..Default::default() });
        let url = spawn_range_server_delayed(make_body(128 * 1024), "\"v1\"", 150);

        h.rt.block_on(async {
            // 先占住唯一的额度
            let _blocker = h.sched.add(spec(&url, &tmp(&"blk"), "blk", 0)).unwrap();
            tokio::time::sleep(Duration::from_millis(60)).await;

            let low = h.sched.add(spec(&url, &tmp(&"low"), "low", 1)).unwrap();
            let high = h.sched.add(spec(&url, &tmp(&"high"), "high", 9)).unwrap();

            // 等 blocker 让出额度后，应先跑 high
            let _ = wait_status(&h.conn, high.id, TaskStatus::Completed, 8000).await;
            let lh = store::get_task(&h.conn, low.id).unwrap().unwrap();
            assert!(
                lh.status != TaskStatus::Completed,
                "低优先级不应先完成（高优先级必须被优先调度）"
            );
        });
    }

    #[test]
    fn recover_after_restart_pauses_stale_active_tasks() {
        let conn = store::open(":memory:").unwrap();
        let mut t = Task {
            id: 0,
            app_id: "a".into(),
            app_name: "a".into(),
            version: "1".into(),
            file_name: "a.bin".into(),
            url: "http://x/y".into(),
            file_path: "/tmp/a.bin".into(),
            total: 100,
            received: 50,
            status: TaskStatus::Downloading,
            speed_bps: 999,
            eta_sec: Some(3),
            error: None,
            fail_kind: None,
            retries: 0,
            segments: vec![],
            server_meta: Default::default(),
            expected_sha256: None,
            actual_sha256: None,
            priority: 0,
            queue_reason: None,
            created_at: now_ms(),
            updated_at: now_ms(),
            ..Default::default()
        };
        let id = store::upsert_task(&conn, &t).unwrap();
        let (paused, _) = store::recover_after_restart(&conn).unwrap();
        assert_eq!(paused, 1, "重启时在途任务应被降级为暂停");
        t = store::get_task(&conn, id).unwrap().unwrap();
        assert_eq!(t.status, TaskStatus::Paused);
        assert!(
            t.queue_reason.as_deref().unwrap_or("").contains("暂停"),
            "应说明为什么变成暂停，实际 {:?}",
            t.queue_reason
        );
    }

    /// 测试用目标路径
    fn tmp(key: &str) -> String {
        let d = tmpdir(&format!("sched_{key}"));
        d.join(format!("{key}.bin")).to_string_lossy().to_string()
    }
}
