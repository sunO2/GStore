//! 分段传输引擎：探测 → 切段 → 多连接并发 → 续传 → 合并 → 校验 → 原子落盘。
//!
//! 相对既有 Dart 引擎（`dio_download_engine.dart`）补齐的工业能力：
//! - **服务器一致性校验**：续传前比对 ETag/Last-Modified/总长，不一致则整体重下
//!   （否则会把两个版本的文件拼在一起——静默损坏，比失败更糟）
//! - **分段级重试 + 指数退避 + 抖动**：单段失败不影响其它段
//! - **分段各自落盘 `.part{i}`**：续传的最小单位，不必重下已完成的段
//! - **磁盘空间预检**：开工前判断可用空间，避免跑到一半失败
//! - **合并期单遍算 sha256 + 原子 rename**：最终文件不会出现"半个 APK"
//! - **进度节流上报**：独立 ticker 采样，而不是每个 chunk 都跨 FFI

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{ACCEPT_RANGES, CONTENT_LENGTH, CONTENT_RANGE, ETAG, LAST_MODIFIED, RANGE};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};
use tokio::task::JoinSet;

use crate::model::{FailKind, Segment, ServerMeta};

/// 单段最小长度：太小会让连接开销吃掉收益（工业下载器通用做法）
const MIN_SEGMENT_SIZE: u64 = 1 << 20; // 1 MiB
/// 默认并发连接数（分段数上限）
pub const DEFAULT_CONNECTIONS: u32 = 4;
/// 单段最大重试次数
pub const DEFAULT_MAX_RETRIES: u32 = 4;
/// 读超时（连接由 client 统一配置）
const READ_TIMEOUT: Duration = Duration::from_secs(30);
/// 进度采样周期：合并上报，避免跨 FFI 风暴
/// 本段进度写回共享快照的步长（避免每个 chunk 都加锁）
const SEG_REPORT_STEP: u64 = 256 * 1024;

const PROGRESS_INTERVAL: Duration = Duration::from_millis(100);
/// 速率采样窗口：与既有 Dart 侧一致（3s 滚动窗口）
pub const SPEED_WINDOW: Duration = Duration::from_secs(3);

/// 探测结果：决定能否分段、总长、一致性指纹。
#[derive(Debug, Clone, Default)]
pub struct Probe {
    pub supports_range: bool,
    pub total: Option<u64>,
    pub meta: ServerMeta,
}

/// 进度回调（由调用方桥接到 C ABI 的 `emit_event`）。
pub trait ProgressSink: Send + Sync {
    /// `segments` 为 `Some` 时表示分段快照需要下发（分段完成状态变化时）。
    fn on_progress(&self, received: u64, total: u64, segments: Option<Vec<Segment>>);
    /// 带速率/ETA 的进度。默认退化为 `on_progress`，既有实现无需改动。
    fn on_progress_ex(
        &self,
        received: u64,
        total: u64,
        segments: Option<Vec<Segment>>,
        _speed_bps: u64,
        _eta_sec: Option<u64>,
    ) {
        self.on_progress(received, total, segments);
    }
    /// 状态流转（connecting → downloading 等）。
    fn on_status(&self, _status: crate::model::TaskStatus) {}
}

/// 速率采样：滚动窗口内取首尾差值算平均速率。
///
/// 用窗口平均而不是"上次 tick 到现在"的瞬时差值——分段并发下瞬时值抖动极大，
/// 面板上会看到速度乱跳。ETA 由 `(total - received) / speed` 得出。
pub struct SpeedSampler {
    window: Duration,
    samples: std::collections::VecDeque<(std::time::Instant, u64)>,
}

impl SpeedSampler {
    pub fn new(window: Duration) -> Self {
        Self {
            window,
            samples: std::collections::VecDeque::new(),
        }
    }

    pub fn sample(&mut self, received: u64, total: u64) -> (u64, Option<u64>) {
        self.sample_at(std::time::Instant::now(), received, total)
    }

    /// 显式时间版本（便于确定性测试）。
    pub fn sample_at(
        &mut self,
        now: std::time::Instant,
        received: u64,
        total: u64,
    ) -> (u64, Option<u64>) {
        self.samples.push_back((now, received));
        // 至少保留两个样本，否则算不出区间速率
        while self.samples.len() > 2 {
            let (t0, _) = self.samples[0];
            if now.saturating_duration_since(t0) > self.window {
                self.samples.pop_front();
            } else {
                break;
            }
        }
        let Some(&(t0, b0)) = self.samples.front() else {
            return (0, None);
        };
        let dt = now.saturating_duration_since(t0).as_secs_f64();
        if dt < 0.05 {
            return (0, None); // 采样间隔过短，读数无意义
        }
        let speed = ((received.saturating_sub(b0)) as f64 / dt).max(0.0) as u64;
        let eta = if speed > 0 && total > received {
            Some(((total - received) as f64 / speed as f64) as u64)
        } else {
            None
        };
        (speed, eta)
    }
}

/// 一次下载需要的全部输入。
#[derive(Debug, Clone)]
pub struct DownloadParams {
    pub url: String,
    /// 最终文件路径（合并后落这里）
    pub dest: String,
    pub headers: Vec<(String, String)>,
    pub connections: u32,
    pub expected_sha256: Option<String>,
    pub max_retries: u32,
    /// 每秒字节上限（None = 不限速）
    pub speed_limit_bps: Option<u64>,
    /// 已有分段（续传用；空 = 全新）
    pub segments: Vec<Segment>,
    /// 上次记录的服务端指纹（用于一致性校验）
    pub prev_meta: ServerMeta,
    /// 需要校验指纹（续传场景为 true）
    pub verify_server_consistency: bool,

    /// 调用方提供的共享分段容器（可选）。
    ///
    /// 提供时引擎直接复用它，调用方可在 run 结束后据此**落库**——
    /// 否则分段只存在于内存里，面板重新进入页面查询时看不到任何分段记录。
    pub segments_out: Option<Arc<tokio::sync::Mutex<Vec<Segment>>>>,
}

impl Default for DownloadParams {
    fn default() -> Self {
        Self {
            url: String::new(),
            dest: String::new(),
            headers: Vec::new(),
            connections: DEFAULT_CONNECTIONS,
            expected_sha256: None,
            max_retries: DEFAULT_MAX_RETRIES,
            speed_limit_bps: None,
            segments: Vec::new(),
            prev_meta: ServerMeta::default(),
            verify_server_consistency: false,

            segments_out: None,        }
    }
}

/// 终态结果。
#[derive(Debug)]
pub enum Outcome {
    Completed { total: u64, sha256: Option<String> },
    Cancelled,
    Failed { kind: FailKind, message: String },
}

/// 执行一次下载（阻塞到终态）。取消通过 `cancel` 协作式生效。
pub async fn run(
    client: &reqwest::Client,
    params: &DownloadParams,
    sink: Arc<dyn ProgressSink>,
    cancel: Arc<AtomicBool>,
) -> Outcome {
    // 1) 探测
    sink.on_status(crate::model::TaskStatus::Connecting);
    let probe = match probe(client, &params.url, &params.headers).await {
        Ok(p) => p,
        Err((k, m)) => return Outcome::Failed { kind: k, message: m },
    };

    let total = probe.total.unwrap_or(0);

    // 2) 服务器一致性：指纹变了就不能续传（否则拼接出损坏文件）
    if params.verify_server_consistency && !params.segments.is_empty() {
        if server_changed(&params.prev_meta, &probe) {
            // 注意必须 await：漏掉 await 会让清理变成空操作，残留旧段会拼接出脏文件
            let _ = cleanup_parts(&params.dest, &params.segments).await;
            return Outcome::Failed {
                kind: FailKind::ServerChanged,
                message: "服务端文件已变更，需要重新下载".into(),
            };
        }
    }

    // 3) 磁盘空间预检
    if total > 0 {
        if let Some(free) = available_bytes(parent_dir(&params.dest)) {
            // 预留 16 MiB 余量（元数据/对齐/合并期临时占用）
            if free < total + (16 << 20) {
                return Outcome::Failed {
                    kind: FailKind::Disk,
                    message: format!(
                        "磁盘空间不足：需要约 {}，可用 {}",
                        human(total + (16 << 20)),
                        human(free)
                    ),
                };
            }
        }
    }

    // 4) 切段（不支持 Range / 长度未知 → 单连接）
    let can_segment = probe.supports_range && total > 0;
    let mut segments = if can_segment {
        if params.segments.is_empty() {
            plan_segments(total, params.connections)
        } else {
            params.segments.clone()
        }
    } else {
        vec![Segment {
            index: 0,
            start_byte: 0,
            end_byte: total.saturating_sub(1),
            received: 0,
            done: false,
        }]
    };

    // 分段计划上报一次：面板要展示"分了多少段"以及每段区间。
    // Dart 侧合并进度时，segments 为空会保留该计划，所以只需报这一次。
    sink.on_progress_ex(0, total, Some(segments.clone()), 0, None);

    sink.on_status(crate::model::TaskStatus::Downloading);

    // 5) 分段并发下载
    // 续传时先按**落盘实际字节**校正每段进度，再据此初始化总进度。
    //
    // 旧实现是 `filter(|s| s.done).map(|s| s.len()).sum()` —— 只累加**整段下完**的段，
    // 于是「下到一半」的段其已有字节被整段漏算；resume 后总进度从这些小值重新开始，
    // 表现就是暂停/继续几轮后**进度倒退**。
    let seeded = seed_progress(&mut segments, &params.dest);
    let done_bytes: Arc<AtomicU64> = Arc::new(AtomicU64::new(seeded));
    let segments = match params.segments_out.clone() {
        Some(shared) => {
            *shared.lock().await = segments;
            shared
        }
        None => Arc::new(tokio::sync::Mutex::new(segments)),
    };

    // 进度 ticker（独立任务，节流上报）
    let ticker_stop = Arc::new(AtomicBool::new(false));
    let ticker = {
        let sink = sink.clone();
        let done_bytes = done_bytes.clone();
        let stop = ticker_stop.clone();
        let segs = segments.clone();
        tokio::spawn(async move {
            let mut sampler = SpeedSampler::new(SPEED_WINDOW);
            let mut last_snapshot: Option<Vec<Segment>> = None;
            loop {
                if stop.load(Ordering::SeqCst) {
                    break;
                }
                tokio::time::sleep(PROGRESS_INTERVAL).await;
                let r = done_bytes.load(Ordering::Relaxed);
                let (speed, eta) = sampler.sample(r, total);
                // 分段快照仅在变化时下发，避免每 tick 都传整段列表
                let snap = {
                    let g = segs.lock().await;
                    g.clone()
                };
                let changed = last_snapshot.as_ref().map_or(true, |prev| {
                    prev.len() != snap.len()
                        || prev
                            .iter()
                            .zip(snap.iter())
                            .any(|(a, b)| a.received != b.received || a.done != b.done)
                });
                let payload = if changed {
                    last_snapshot = Some(snap.clone());
                    Some(snap)
                } else {
                    None
                };
                sink.on_progress_ex(r, total, payload, speed, eta);
            }
        })
    };

    let mut set: JoinSet<Result<(u32, u64), (FailKind, String)>> = JoinSet::new();
    let seg_count = {
        let g = segments.lock().await;
        g.len()
    };
    for idx in 0..seg_count {
        let seg = {
            let g = segments.lock().await;
            g[idx].clone()
        };
        if seg.done {
            continue;
        }
        let client = client.clone();
        let url = params.url.clone();
        let headers = params.headers.clone();
        let dest = params.dest.clone();
        let cancel = cancel.clone();
        let done_bytes = done_bytes.clone();
        let segs = segments.clone();
        let sink2 = sink.clone();
        let max_retries = params.max_retries;
        let limit = params.speed_limit_bps;
        set.spawn(async move {
            let r = download_segment_with_retry(
                &client, &url, &headers, &dest, &seg, cancel.clone(), max_retries, limit,
                done_bytes.clone(), &segs,
            )
            .await;
            match r {
                Ok(()) => {
                    let snapshot = {
                        let mut g = segs.lock().await;
                        if let Some(s) = g.iter_mut().find(|s| s.index == seg.index) {
                            s.received = s.len();
                            s.done = true;
                        }
                        Some(g.clone())
                    };
                    sink2.on_progress(done_bytes.load(Ordering::Relaxed), total, snapshot);
                    Ok((seg.index, seg.len()))
                }
                Err(e) => Err(e),
            }
        });
    }

    let mut first_err: Option<(FailKind, String)> = None;
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                if first_err.is_none() {
                    first_err = Some(e);
                }
                cancel.store(true, Ordering::SeqCst); // 一段放弃 → 整体收敛，避免半成品
                set.abort_all();
                break;
            }
            Err(_) => {}
        }
    }

    ticker_stop.store(true, Ordering::SeqCst);
    ticker.abort();

    if cancel.load(Ordering::SeqCst) && first_err.is_none() {
        return Outcome::Cancelled;
    }
    if let Some((kind, message)) = first_err {
        // 段任务在检查点发现取消标志 → 这里必须归到 Cancelled，
        // 否则用户点"暂停/取消"会被显示成"失败"，且调度器不会走暂停分支
        if kind == FailKind::Cancelled {
            return Outcome::Cancelled;
        }
        return Outcome::Failed { kind, message };
    }

    // 6) 合并 + 校验 + 原子落盘
    let final_segments = { segments.lock().await.clone() };
    match finalize(&params.dest, &final_segments, params.expected_sha256.as_deref(), total).await {
        Ok(sha) => Outcome::Completed { total, sha256: sha },
        Err((k, m)) => Outcome::Failed { kind: k, message: m },
    }
}

/// 探测：`Range: bytes=0-0` 能拿到 206 才认为服务端支持分段。
pub async fn probe(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
) -> Result<Probe, (FailKind, String)> {
    // ---- 1) HEAD（不带 Range）拿**权威**总长 ----
    //
    // 为什么不能直接用后面 200 响应的 Content-Length：那只是"本次响应"的长度。
    // 实测某些 CDN（TencentEdgeOne）对 `Range: bytes=0-0` 回 **200** 且
    // `content-length: 1`，把它当文件大小会算出 1 字节 —— 整包只下 1 字节。
    let head = {
        let mut req = client.head(url);
        for (k, v) in headers {
            req = req.header(k.as_str(), v.as_str());
        }
        match req.send().await {
            Ok(r) if r.status().is_success() => Some(r),
            _ => None,
        }
    };
    let hv = |name: reqwest::header::HeaderName| -> Option<String> {
        head.as_ref()
            .and_then(|r| r.headers().get(name))
            .and_then(|v| v.to_str().ok())
            .map(str::to_string)
    };
    let head_total = hv(CONTENT_LENGTH).and_then(|s| s.trim().parse::<u64>().ok());
    let head_etag = hv(ETAG);
    let head_last_modified = hv(LAST_MODIFIED);

    // ---- 2) Range: bytes=0-0 探测是否**真的**按偏移返回 ----
    let mut req = client.get(url).header(RANGE, "bytes=0-0");
    for (k, v) in headers {
        req = req.header(k.as_str(), v.as_str());
    }
    let resp = req.send().await.map_err(classify_reqwest)?;
    let status = resp.status();

    if status.as_u16() == 206 {
        let h = resp.headers();
        // 标准 206：Content-Range 里的总长最权威，优先于 HEAD
        let total = h
            .get(CONTENT_RANGE)
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.rsplit('/').next())
            .and_then(|s| s.trim().parse::<u64>().ok())
            .or(head_total);
        let accept_ranges = h
            .get(ACCEPT_RANGES)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_ascii_lowercase().contains("bytes"))
            .unwrap_or(true);
        return Ok(Probe {
            supports_range: accept_ranges,
            total,
            meta: ServerMeta {
                etag: h
                    .get(ETAG)
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_string)
                    .or(head_etag),
                last_modified: h
                    .get(LAST_MODIFIED)
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_string)
                    .or(head_last_modified),
                total,
                supports_range: accept_ranges,
            },
        });
    }

    if !status.is_success() {
        return Err(classify_status(status.as_u16()));
    }

    // 200：可能"忽略了 Range"，也可能"按偏移正确返回了但用错了状态码"。
    // 判据只能是**实际收到的字节数**：请求 1 字节就只收到 1 字节 → 偏移被尊重。
    let got = count_body_prefix(resp, PROBE_BODY_CAP).await;
    let supports_range = got == 1;

    // 总长一律取 HEAD；HEAD 不可用时再打一次不带 Range 的 GET 读 Content-Length
    let total = match head_total {
        Some(t) => Some(t),
        None => plain_content_length(client, url, headers).await,
    };

    Ok(Probe {
        supports_range,
        total,
        meta: ServerMeta {
            etag: head_etag,
            last_modified: head_last_modified,
            total,
            supports_range,
        },
    })
}

/// 探测阶段最多读的响应体字节数。
///
/// 上限很重要：若服务端忽略了 Range 而回整个文件，不能在这里把整包拖下来。
const PROBE_BODY_CAP: u64 = 4096;

/// 读响应体开头的字节数（最多 [PROBE_BODY_CAP] 字节后主动放弃）。
async fn count_body_prefix(mut resp: reqwest::Response, cap: u64) -> u64 {
    let mut n = 0u64;
    while n < cap {
        match tokio::time::timeout(READ_TIMEOUT, resp.chunk()).await {
            Ok(Ok(Some(c))) => n += c.len() as u64,
            _ => break,
        }
    }
    n
}

/// 不带 Range 请求一次，只取响应头里的 Content-Length（不读 body）。
async fn plain_content_length(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
) -> Option<u64> {
    let mut req = client.get(url);
    for (k, v) in headers {
        req = req.header(k.as_str(), v.as_str());
    }
    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.headers()
        .get(CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<u64>().ok())
}

/// 按总长与期望连接数切段；受 [`MIN_SEGMENT_SIZE`] 约束，避免切出大量极小段。
/// 用**落盘实际字节**校正每段进度，并返回起跑时的总已下字节。
///
/// 必须对所有段求和（含"下到一半"的段）：早期实现只累加 `done == true` 的整段，
/// 部分下完的段其已有字节被整段漏算 —— 表现为暂停/继续几轮后**进度倒退**。
/// 以分段文件长度为准（而非 DB 里的 received），因为写库是节流的、进程被杀时会更旧。
pub fn seed_progress(segments: &mut [Segment], dest: &str) -> u64 {
    for s in segments.iter_mut() {
        let have = std::fs::metadata(part_path(dest, s.index))
            .map(|m| m.len())
            .unwrap_or(0)
            .min(s.len());
        s.received = have;
        s.done = have >= s.len();
    }
    segments.iter().map(|s| s.received).sum()
}

pub fn plan_segments(total: u64, connections: u32) -> Vec<Segment> {
    if total == 0 {
        return vec![Segment { index: 0, start_byte: 0, end_byte: 0, received: 0, done: false }];
    }
    let max_by_size = (total / MIN_SEGMENT_SIZE).max(1) as u32;
    let n = connections.max(1).min(max_by_size).max(1);
    let mut out = Vec::with_capacity(n as usize);
    let base = total / n as u64;
    let mut start = 0u64;
    for i in 0..n {
        let mut len = base;
        if i == n - 1 {
            len = total - start; // 最后一段吃掉余数，保证无缝覆盖
        }
        let end = start + len - 1;
        out.push(Segment { index: i, start_byte: start, end_byte: end, received: 0, done: false });
        start = end + 1;
    }
    out
}

/// 服务器是否变过：任一指纹不一致即认为变了（保守优先，避免拼接损坏）。
pub fn server_changed(prev: &ServerMeta, now: &Probe) -> bool {
    if let (Some(a), Some(b)) = (&prev.etag, &now.meta.etag) {
        if a != b {
            return true;
        }
    }
    if let (Some(a), Some(b)) = (&prev.last_modified, &now.meta.last_modified) {
        if a != b {
            return true;
        }
    }
    if let (Some(a), Some(b)) = (prev.total, now.total) {
        if a != b {
            return true;
        }
    }
    false
}

fn part_path(dest: &str, index: u32) -> PathBuf {
    PathBuf::from(format!("{dest}.part{index}"))
}

fn temp_path(dest: &str) -> PathBuf {
    PathBuf::from(format!("{dest}.merge"))
}

fn parent_dir(dest: &str) -> &str {
    Path::new(dest).parent().and_then(|p| p.to_str()).unwrap_or("/")
}

/// 单段下载（含续传），失败按退避策略重试。
async fn download_segment_with_retry(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
    dest: &str,
    seg: &Segment,
    cancel: Arc<AtomicBool>,
    max_retries: u32,
    limit: Option<u64>,
    done_bytes: Arc<AtomicU64>,
    segs: &Arc<tokio::sync::Mutex<Vec<Segment>>>,
) -> Result<(), (FailKind, String)> {
    let mut attempt = 0u32;
    loop {
        if cancel.load(Ordering::SeqCst) {
            return Err((FailKind::Cancelled, "已取消".into()));
        }
        match download_segment_once(client, url, headers, dest, seg, cancel.clone(), limit, done_bytes.clone(), segs).await {
            Ok(()) => return Ok(()),
            Err((kind, msg)) => {
                if kind == FailKind::Cancelled {
                    return Err((kind, msg));
                }
                if attempt >= max_retries || !kind.is_retryable() {
                    return Err((kind, msg));
                }
                attempt += 1;
                tokio::time::sleep(backoff_delay(attempt, seg.index)).await;
            }
        }
    }
}

/// 指数退避 + 抖动（抖动由段号参与，避免所有段同时重试打爆服务端）。
pub fn backoff_delay(attempt: u32, salt: u32) -> Duration {
    let base = 300u64.saturating_mul(1u64 << attempt.min(6)); // 300ms → 19.2s
    let jitter = ((salt as u64 * 2654435761) % 250) as u64; // 确定性抖动，便于测试
    Duration::from_millis(base + jitter)
}

/// 单次分段传输。续传时从 `start + 已落盘` 继续，而不是整段重下。
async fn download_segment_once(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
    dest: &str,
    seg: &Segment,
    cancel: Arc<AtomicBool>,
    limit: Option<u64>,
    done_bytes: Arc<AtomicU64>,
    segs: &Arc<tokio::sync::Mutex<Vec<Segment>>>,
) -> Result<(), (FailKind, String)> {
    let path = part_path(dest, seg.index);
    if let Some(dir) = path.parent() {
        tokio::fs::create_dir_all(dir).await.map_err(io_err)?;
    }

    // 已落盘长度：不能超过本段长度（超过说明是脏数据，整段重下）
    let mut have = tokio::fs::metadata(&path).await.map(|m| m.len()).unwrap_or(0);
    if have > seg.len() {
        let _ = tokio::fs::remove_file(&path).await;
        have = 0;
    }
    if have == seg.len() {
        return Ok(()); // 该段其实已完成（崩溃后重启的常见情形）
    }

    let start = seg.start_byte + have;
    let range = format!("bytes={start}-{}", seg.end_byte);

    let mut req = client.get(url).header(RANGE, range);
    for (k, v) in headers {
        req = req.header(k.as_str(), v.as_str());
    }
    let resp = req.send().await.map_err(classify_reqwest)?;
    let status = resp.status().as_u16();
    if !(status == 206 || status == 200) {
        return Err(classify_status(status));
    }

    let mut resp = resp;
    let mut file = tokio::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open(&path)
        .await
        .map_err(io_err)?;
    file.seek(std::io::SeekFrom::Start(have)).await.map_err(io_err)?;

    let mut written_in_call = 0u64;
    let mut last_reported = 0u64;
    let mut throttle = RateLimiter::new(limit);
    loop {
        if cancel.load(Ordering::SeqCst) {
            let _ = file.flush().await;
            return Err((FailKind::Cancelled, "已取消".into()));
        }
        let chunk = match tokio::time::timeout(READ_TIMEOUT, resp.chunk()).await {
            Err(_) => return Err((FailKind::Timeout, "读取超时".into())),
            Ok(Err(e)) => return Err(classify_reqwest(e)),
            Ok(Ok(None)) => break,
            Ok(Ok(Some(c))) => c,
        };
        if chunk.is_empty() {
            continue;
        }
        file.write_all(&chunk).await.map_err(io_err)?;
        written_in_call += chunk.len() as u64;
        // 总进度按**字节**累加（原先只在整段完成时加，导致进度条按段跳）
        done_bytes.fetch_add(chunk.len() as u64, Ordering::Relaxed);
        // 本段已下多少：每 SEG_REPORT_STEP 更新一次共享快照（每 chunk 加锁会拖慢下载）
        if written_in_call - last_reported >= SEG_REPORT_STEP {
            last_reported = written_in_call;
            let mut g = segs.lock().await;
            if let Some(s) = g.iter_mut().find(|s| s.index == seg.index) {
                s.received = have + written_in_call;
            }
        }
        if let Some(d) = throttle.consume(chunk.len() as u64) {
            tokio::time::sleep(d).await;
        }
    }
    file.flush().await.map_err(io_err)?;
    drop(file);

    // 校验本段落盘长度：不足说明服务端提前断流 → 交给上层重试
    let got = tokio::fs::metadata(&path).await.map(|m| m.len()).unwrap_or(0);
    if got < seg.len() {
        return Err((
            FailKind::Connect,
            format!("分段 {} 传输不完整：{got}/{}", seg.index, seg.len()),
        ));
    }
    let _ = written_in_call;
    Ok(())
}

/// 合并分段 → 单遍算 sha256 → 原子 rename 到目标路径。
async fn finalize(
    dest: &str,
    segments: &[Segment],
    expected_sha256: Option<&str>,
    total: u64,
) -> Result<Option<String>, (FailKind, String)> {
    let mut ordered: Vec<&Segment> = segments.iter().collect();
    ordered.sort_by_key(|s| s.index);

    let tmp = temp_path(dest);
    if let Some(dir) = tmp.parent() {
        tokio::fs::create_dir_all(dir).await.map_err(io_err)?;
    }
    let mut out = tokio::fs::File::create(&tmp).await.map_err(io_err)?;
    let mut hasher = Sha256::new();
    let mut written = 0u64;

    for s in ordered {
        let p = part_path(dest, s.index);
        let mut f = match tokio::fs::File::open(&p).await {
            Ok(f) => f,
            Err(e) => {
                return Err((FailKind::Disk, format!("分段文件缺失 {}: {e}", p.display())));
            }
        };
        let mut buf = vec![0u8; 256 * 1024];
        loop {
            use tokio::io::AsyncReadExt;
            let n = f.read(&mut buf).await.map_err(io_err)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            out.write_all(&buf[..n]).await.map_err(io_err)?;
            written += n as u64;
        }
    }
    out.flush().await.map_err(io_err)?;
    drop(out);

    let actual = hex::encode(hasher.finalize());

    if total > 0 && written != total {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err((
            FailKind::Checksum,
            format!("长度不符：期望 {total}，实际 {written}"),
        ));
    }
    if let Some(exp) = expected_sha256 {
        if !exp.eq_ignore_ascii_case(&actual) {
            let _ = tokio::fs::remove_file(&tmp).await;
            return Err((
                FailKind::Checksum,
                format!("sha256 不符：期望 {exp}，实际 {actual}"),
            ));
        }
    }

    // 原子替换：同目录 rename，读到的是"完整文件"或"旧文件"，不会是半个
    tokio::fs::rename(&tmp, dest).await.map_err(io_err)?;
    // 清掉分段残留
    for s in segments {
        let _ = tokio::fs::remove_file(part_path(dest, s.index)).await;
    }
    Ok(Some(actual))
}

/// 清理所有分段残留（服务器变更 / 整体重下时用）。
pub async fn cleanup_parts(dest: &str, segments: &[Segment]) -> Result<(), String> {
    for s in segments {
        let _ = tokio::fs::remove_file(part_path(dest, s.index)).await;
    }
    let _ = tokio::fs::remove_file(temp_path(dest)).await;
    Ok(())
}

/// 简单令牌桶限速：返回需要 sleep 的时长（None = 不需要等待）。
struct RateLimiter {
    limit: Option<u64>,
    window_start: std::time::Instant,
    window_bytes: u64,
}

impl RateLimiter {
    fn new(limit: Option<u64>) -> Self {
        Self {
            limit,
            window_start: std::time::Instant::now(),
            window_bytes: 0,
        }
    }

    fn consume(&mut self, bytes: u64) -> Option<Duration> {
        let limit = self.limit?;
        if limit == 0 {
            return None;
        }
        self.window_bytes += bytes;
        let elapsed = self.window_start.elapsed().as_secs_f64();
        let expected = self.window_bytes as f64 / limit as f64;
        if expected > elapsed {
            let d = Duration::from_secs_f64(expected - elapsed);
            self.window_start = std::time::Instant::now();
            self.window_bytes = 0;
            Some(d)
        } else if elapsed > 1.0 {
            self.window_start = std::time::Instant::now();
            self.window_bytes = 0;
            None
        } else {
            None
        }
    }
}

fn io_err(e: std::io::Error) -> (FailKind, String) {
    let kind = match e.kind() {
        std::io::ErrorKind::StorageFull => FailKind::Disk,
        _ => FailKind::Disk,
    };
    (kind, e.to_string())
}

fn classify_status(status: u16) -> (FailKind, String) {
    (FailKind::Http { status }, format!("HTTP {status}"))
}

/// reqwest 错误 → 失败分类（区分该重试与不该重试）。
pub fn classify_reqwest(e: reqwest::Error) -> (FailKind, String) {
    let msg = e.to_string();
    if e.is_timeout() {
        return (FailKind::Timeout, msg);
    }
    let lower = msg.to_ascii_lowercase();
    if lower.contains("dns") || lower.contains("name or service not known") || lower.contains("failed to lookup") {
        return (FailKind::Dns, msg);
    }
    if lower.contains("certificate") || lower.contains("tls") || lower.contains("handshake") {
        return (FailKind::Tls, msg);
    }
    if e.is_connect() {
        return (FailKind::Connect, msg);
    }
    (FailKind::Unknown, msg)
}

/// 可用磁盘空间（字节）。用 `statvfs`，不引入额外依赖。
pub fn available_bytes(path: &str) -> Option<u64> {
    use std::ffi::CString;
    let c = CString::new(path).ok()?;
    unsafe {
        let mut st: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c.as_ptr(), &mut st) != 0 {
            return None;
        }
        Some(st.f_bavail as u64 * st.f_frsize as u64)
    }
}

fn human(bytes: u64) -> String {
    const U: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    format!("{v:.1}{}", U[i])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::TaskStatus;
    use std::sync::atomic::AtomicUsize;

    struct NoopSink;
    impl ProgressSink for NoopSink {
        fn on_progress(&self, _r: u64, _t: u64, _s: Option<Vec<Segment>>) {}
    }

    struct CountingSink {
        calls: AtomicUsize,
    }
    impl ProgressSink for CountingSink {
        fn on_progress(&self, _r: u64, _t: u64, _s: Option<Vec<Segment>>) {
            self.calls.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// 起一个支持 Range 的本地 HTTP 服务（与 repo 模块测试同一套路）。
    fn spawn_range_server(body: Vec<u8>, etag: &'static str) -> String {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut sock) = stream else { continue };
                let body = body.clone();
                std::thread::spawn(move || {
                    let mut buf = [0u8; 8192];
                    let n = sock.read(&mut buf).unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]).to_string();
                    let range = req.lines().find_map(|l| {
                        let l = l.to_ascii_lowercase();
                        l.strip_prefix("range: bytes=").map(|v| v.trim().to_string())
                    });
                    match range {
                        Some(r) => {
                            let (a, b) = r.split_once('-').unwrap_or(("0", ""));
                            let start: usize = a.parse().unwrap_or(0);
                            let end: usize = if b.is_empty() {
                                body.len().saturating_sub(1)
                            } else {
                                b.parse().unwrap_or(body.len() - 1)
                            };
                            let end = end.min(body.len().saturating_sub(1));
                            if start > end {
                                let _ = sock.write_all(b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                                return;
                            }
                            let slice = &body[start..=end];
                            let head = format!(
                                "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nAccept-Ranges: bytes\r\nETag: {}\r\nConnection: close\r\n\r\n",
                                slice.len(), start, end, body.len(), etag
                            );
                            let _ = sock.write_all(head.as_bytes());
                            let _ = sock.write_all(slice);
                        }
                        None => {
                            let head = format!(
                                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nETag: {}\r\nConnection: close\r\n\r\n",
                                body.len(), etag
                            );
                            let _ = sock.write_all(head.as_bytes());
                            let _ = sock.write_all(&body);
                        }
                    }
                });
            }
        });
        format!("http://{addr}/file.bin")
    }

    fn tmpdir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("dl_test_{tag}_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&p);
        p
    }

    #[test]
    fn plan_segments_covers_whole_file_without_gap_or_overlap() {
        let segs = plan_segments(10 * 1024 * 1024, 4);
        assert_eq!(segs.len(), 4);
        assert_eq!(segs[0].start_byte, 0);
        assert_eq!(segs.last().unwrap().end_byte, 10 * 1024 * 1024 - 1);
        for w in segs.windows(2) {
            assert_eq!(w[0].end_byte + 1, w[1].start_byte, "分段必须无缝衔接");
        }
        let sum: u64 = segs.iter().map(|s| s.len()).sum();
        assert_eq!(sum, 10 * 1024 * 1024, "分段总长必须等于文件长度");
    }

    #[test]
    fn plan_segments_respects_min_size() {
        // 2 MiB 只够切 2 段（MIN_SEGMENT_SIZE = 1 MiB），请求 8 连接也不能切更多
        let segs = plan_segments(2 * 1024 * 1024, 8);
        assert_eq!(segs.len(), 2);
        // 极小文件退化为单段
        let segs = plan_segments(1000, 4);
        assert_eq!(segs.len(), 1);
    }

    #[test]
    fn plan_segments_handles_zero_and_odd_sizes() {
        assert_eq!(plan_segments(0, 4).len(), 1);
        let segs = plan_segments(3 * 1024 * 1024 + 7, 3);
        let sum: u64 = segs.iter().map(|s| s.len()).sum();
        assert_eq!(sum, 3 * 1024 * 1024 + 7, "余数必须被最后一段吃掉");
        assert_eq!(segs.last().unwrap().end_byte, 3 * 1024 * 1024 + 6);
    }

    #[test]
    fn server_changed_detects_etag_and_size_drift() {
        let prev = ServerMeta {
            etag: Some("\"v1\"".into()),
            last_modified: None,
            total: Some(100),
            supports_range: true,
        };
        let same = Probe { supports_range: true, total: Some(100), meta: ServerMeta { etag: Some("\"v1\"".into()), total: Some(100), ..Default::default() } };
        assert!(!server_changed(&prev, &same));

        let etag_drift = Probe { supports_range: true, total: Some(100), meta: ServerMeta { etag: Some("\"v2\"".into()), total: Some(100), ..Default::default() } };
        assert!(server_changed(&prev, &etag_drift), "ETag 变了必须判定为变更");

        let size_drift = Probe { supports_range: true, total: Some(200), meta: ServerMeta { etag: Some("\"v1\"".into()), total: Some(200), ..Default::default() } };
        assert!(server_changed(&prev, &size_drift), "长度变了必须判定为变更");
    }

    #[test]
    fn backoff_is_exponential_and_bounded() {
        let a = backoff_delay(1, 0).as_millis();
        let b = backoff_delay(2, 0).as_millis();
        let c = backoff_delay(3, 0).as_millis();
        assert!(a < b && b < c, "退避必须递增");
        assert!(backoff_delay(30, 0).as_millis() <= 20_000, "退避必须有上界");
        // 抖动确定性（便于测试复现）
        assert_eq!(backoff_delay(1, 7), backoff_delay(1, 7));
    }

    #[test]
    fn available_bytes_returns_something_for_tmp() {
        // 不对具体数值断言（环境相关），只要求不 panic 且能取到
        let v = available_bytes("/tmp");
        assert!(v.is_none() || v.unwrap() > 0);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn downloads_multi_segment_and_verifies_sha256() {
        let body: Vec<u8> = (0..(3 * 1024 * 1024u32)).map(|i| (i % 251) as u8).collect();
        let expect = {
            let mut h = Sha256::new();
            h.update(&body);
            hex::encode(h.finalize())
        };
        let url = spawn_range_server(body.clone(), "\"v1\"");
        let dir = tmpdir("ok");
        let dest = dir.join("out.bin").to_string_lossy().to_string();

        let client = reqwest::Client::builder().build().unwrap();
        let params = DownloadParams {
            url,
            dest: dest.clone(),
            connections: 4,
            expected_sha256: Some(expect.clone()),
            ..Default::default()
        };
        let sink: Arc<dyn ProgressSink> = Arc::new(NoopSink);
        let out = run(&client, &params, sink, Arc::new(AtomicBool::new(false))).await;
        match out {
            Outcome::Completed { total, sha256 } => {
                assert_eq!(total, body.len() as u64);
                assert_eq!(sha256.as_deref(), Some(expect.as_str()));
            }
            other => panic!("应完成，实际 {other:?}"),
        }
        let written = std::fs::read(&dest).unwrap();
        assert_eq!(written, body, "合并后的文件必须与源逐字节相同");
        // 分段残留必须清掉
        assert!(!std::path::Path::new(&format!("{dest}.part0")).exists());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn checksum_mismatch_fails_and_leaves_no_final_file() {
        let body = vec![7u8; 2 * 1024 * 1024];
        let url = spawn_range_server(body, "\"v1\"");
        let dir = tmpdir("bad_sha");
        let dest = dir.join("out.bin").to_string_lossy().to_string();
        // 先确保残留不干扰
        let _ = std::fs::remove_file(&dest);

        let client = reqwest::Client::builder().build().unwrap();
        let params = DownloadParams {
            url,
            dest: dest.clone(),
            connections: 2,
            expected_sha256: Some("deadbeef".into()),
            ..Default::default()
        };
        let sink: Arc<dyn ProgressSink> = Arc::new(NoopSink);
        let out = run(&client, &params, sink, Arc::new(AtomicBool::new(false))).await;
        match out {
            Outcome::Failed { kind, .. } => assert_eq!(kind, FailKind::Checksum),
            other => panic!("应校验失败，实际 {other:?}"),
        }
        assert!(!std::path::Path::new(&dest).exists(), "校验失败不得留下最终文件");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn server_changed_aborts_resume_and_cleans_parts() {
        let body = vec![1u8; 2 * 1024 * 1024];
        let url = spawn_range_server(body, "\"v2\"");
        let dir = tmpdir("changed");
        let dest = dir.join("out.bin").to_string_lossy().to_string();
        // 造一个"上次下载"的段残留
        std::fs::write(format!("{dest}.part0"), vec![0u8; 1024]).unwrap();

        let client = reqwest::Client::builder().build().unwrap();
        let params = DownloadParams {
            url,
            dest: dest.clone(),
            connections: 2,
            segments: vec![Segment { index: 0, start_byte: 0, end_byte: 2 * 1024 * 1024 - 1, received: 1024, done: false }],
            prev_meta: ServerMeta { etag: Some("\"v1\"".into()), total: Some(2 * 1024 * 1024), supports_range: true, last_modified: None },
            verify_server_consistency: true,

            segments_out: None,            ..Default::default()
        };
        let sink: Arc<dyn ProgressSink> = Arc::new(NoopSink);
        let out = run(&client, &params, sink, Arc::new(AtomicBool::new(false))).await;
        match out {
            Outcome::Failed { kind, .. } => assert_eq!(kind, FailKind::ServerChanged),
            other => panic!("应判定服务端变更，实际 {other:?}"),
        }
        assert!(!std::path::Path::new(&format!("{dest}.part0")).exists(), "变更后必须清理旧段，避免脏拼接");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn cancel_stops_download() {
        let body = vec![3u8; 8 * 1024 * 1024];
        let url = spawn_range_server(body, "\"v1\"");
        let dir = tmpdir("cancel");
        let dest = dir.join("out.bin").to_string_lossy().to_string();
        let cancel = Arc::new(AtomicBool::new(true)); // 一开始就置位

        let client = reqwest::Client::builder().build().unwrap();
        let params = DownloadParams { url, dest: dest.clone(), connections: 2, ..Default::default() };
        let sink: Arc<dyn ProgressSink> = Arc::new(NoopSink);
        let out = run(&client, &params, sink, cancel).await;
        assert!(matches!(out, Outcome::Cancelled), "已取消时应返回 Cancelled");
        assert!(!std::path::Path::new(&dest).exists());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn progress_is_reported_via_ticker_not_per_chunk() {
        let body = vec![9u8; 4096];
        let url = spawn_range_server(body, "\"v1\"");
        let dir = tmpdir("progress");
        let dest = dir.join("out.bin").to_string_lossy().to_string();
        let sink = Arc::new(CountingSink { calls: AtomicUsize::new(0) });
        let sink_trait: Arc<dyn ProgressSink> = sink.clone();

        let client = reqwest::Client::builder().build().unwrap();
        let params = DownloadParams { url, dest, connections: 1, ..Default::default() };
        let _ = run(&client, &params, sink_trait, Arc::new(AtomicBool::new(false))).await;
        // 4KiB 单段下载远快于 200ms 采样周期 → 进度回调次数应极少（不是每 chunk 一次）
        assert!(
            sink.calls.load(Ordering::Relaxed) <= 4,
            "进度必须节流，不能每个 chunk 都跨 FFI"
        );
    }

    #[test]
    fn speed_sampler_computes_rate_and_eta_with_rolling_window() {
        let t0 = std::time::Instant::now();
        let mut s = SpeedSampler::new(Duration::from_secs(3));

        // 单样本：算不出区间速率
        assert_eq!(s.sample_at(t0, 0, 10_000_000), (0, None));

        // 1 秒收了 1 MB → 1 MB/s；剩 9 MB → ETA 9 秒
        let (sp, eta) = s.sample_at(t0 + Duration::from_secs(1), 1_000_000, 10_000_000);
        assert_eq!(sp, 1_000_000);
        assert_eq!(eta, Some(9));

        // 越过 3s 窗口后窗口滑动：首样本被丢弃，按新窗口首尾重算
        let (sp2, _) = s.sample_at(t0 + Duration::from_secs(4), 3_000_000, 10_000_000);
        assert!(sp2 > 600_000 && sp2 < 700_000, "窗口滑动后速率应约 2MB/3s，实际 {sp2}");

        // 已收满 → 不再给 ETA
        let (_, eta2) = s.sample_at(t0 + Duration::from_secs(5), 10_000_000, 10_000_000);
        assert_eq!(eta2, None);
    }

    #[test]
    fn drain_status_and_rate_limiter_helpers() {
        // on_status 默认实现不应阻止 sink 使用
        let s = NoopSink;
        s.on_status(TaskStatus::Connecting);
        // 无限速时 consume 不返回等待
        let mut rl = RateLimiter::new(None);
        assert!(rl.consume(1 << 20).is_none());
        // 限速时大块数据应算出等待
        let mut rl = RateLimiter::new(Some(1024));
        assert!(rl.consume(4096).is_some());
    }
}

#[cfg(test)]
mod probe_regression_tests {
    use super::*;

    /// 起跑进度必须包含「下到一半」的分段。
    ///
    /// 旧实现只累加 `done == true` 的整段，部分下完的段被整段漏算 →
    /// 这个断言在旧实现下**必然失败**（seeded 会是 0）。
    #[test]
    fn seed_progress_counts_partially_downloaded_segments() {
        let dest = std::env::temp_dir().join(format!("seed-{}.bin", std::process::id()));
        let dest = dest.to_string_lossy().to_string();
        let _ = std::fs::remove_file(format!("{dest}.part0"));

        // 预置：第 0 段（区间 0..256K）已落盘 128K，即"下到一半"
        std::fs::write(format!("{dest}.part0"), vec![7u8; 128 * 1024]).unwrap();

        let mut segs = plan_segments(1024 * 1024, 4);
        let seeded = seed_progress(&mut segs, &dest);

        assert_eq!(segs[0].received, 128 * 1024, "应按分段文件长度校正每段进度");
        assert!(!segs[0].done, "只下了一半，不能算完成");
        assert_eq!(seeded, 128 * 1024, "起跑总进度必须含部分段，实际 {seeded}");

        let _ = std::fs::remove_file(format!("{dest}.part0"));
    }
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// 复刻现场 CDN 的非标准行为：
    /// - HEAD → 正确的完整 Content-Length
    /// - 带 Range 的 GET → **200**（不是 206）、**无 Content-Range**、
    ///   Content-Length 只是本次响应的长度
    ///
    /// 旧实现会把那个"本次响应长度"(=1) 当成文件总长 → 整包只下 1 字节。
    #[tokio::test]
    async fn probe_prefers_head_size_when_range_returns_200() {
        const FULL: usize = 65536;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        tokio::spawn(async move {
            loop {
                let (mut sock, _) = match listener.accept().await {
                    Ok(v) => v,
                    Err(_) => break,
                };
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 4096];
                    let n = match sock.read(&mut buf).await {
                        Ok(n) if n > 0 => n,
                        _ => return,
                    };
                    let req = String::from_utf8_lossy(&buf[..n]).to_string();
                    let is_head = req.starts_with("HEAD");
                    let range = req
                        .lines()
                        .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                        .and_then(|l| l.split('=').nth(1))
                        .and_then(|s| {
                            let mut it = s.trim().split('-');
                            let a: usize = it.next()?.trim().parse().ok()?;
                            let b: usize = it.next()?.trim().parse().ok()?;
                            Some((a, b))
                        });

                    // HEAD / 无 Range：声明完整长度但不发 body
                    // 带 Range：只发请求的那一段，状态码仍写 200（关键：不回 206、不带 Content-Range）
                    let (len, body) = match (is_head, range) {
                        (true, _) | (_, None) => (FULL, Vec::new()),
                        (false, Some((a, b))) => (b - a + 1, vec![7u8; b - a + 1]),
                    };

                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {len}\r\nAccept-Ranges: bytes\r\n\r\n"
                    );
                    let _ = sock.write_all(head.as_bytes()).await;
                    if !body.is_empty() {
                        let _ = sock.write_all(&body).await;
                    }
                });
            }
        });

        let client = reqwest::Client::new();
        let p = probe(&client, &format!("http://{addr}/x.apk"), &[])
            .await
            .expect("探测应成功");

        assert_eq!(
            p.total,
            Some(FULL as u64),
            "总长必须取自 HEAD，而不是 200 响应的 Content-Length"
        );
        assert!(
            p.supports_range,
            "实测只回了请求的 1 字节 → 偏移被尊重，应判定支持分段"
        );
    }
}
