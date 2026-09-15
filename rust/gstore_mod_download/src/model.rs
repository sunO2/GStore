//! 下载任务模型：状态机、分段、失败分类、对 Dart 的 DTO。
//!
//! 设计约束（与宿主/面板对接，改这里等于改契约）：
//! - [`TaskStatus`] 的判别值**必须与 Dart 侧 `DownloadStatusEnum` 的索引一一对应**
//!   （`queued=0, connecting=1, downloading=2, paused=3, completed=4, failed=5, cancelled=6`）。
//!   面板读的是 Dart 模型，错位会让状态显示张冠李戴。
//! - [`TaskDto`] 的 JSON 键名与 Dart `DownloadTask` 字段同名（camelCase），
//!   使 Dart 侧可以用同一套解析（`JsChannelDetailProxy` 式）直接消费。

use serde::{Deserialize, Serialize};

/// 任务状态机。
///
/// 判别值 = Dart `DownloadStatusEnum` 索引（顺序不可改，改了要同步 Dart）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    #[default]
    Queued = 0,
    Connecting = 1,
    Downloading = 2,
    Paused = 3,
    Completed = 4,
    Failed = 5,
    Cancelled = 6,
}

impl TaskStatus {
    pub fn as_i32(self) -> i32 {
        self as i32
    }

    pub fn from_i32(v: i32) -> Self {
        match v {
            0 => Self::Queued,
            1 => Self::Connecting,
            2 => Self::Downloading,
            3 => Self::Paused,
            4 => Self::Completed,
            5 => Self::Failed,
            6 => Self::Cancelled,
            _ => Self::Failed,
        }
    }

    /// 进行中（会被调度器计数、会被"防重复任务"判定命中）。
    /// 注意 `Paused` **不算**进行中：暂停的任务不占用并发额度。
    pub fn is_active(self) -> bool {
        matches!(self, Self::Queued | Self::Connecting | Self::Downloading)
    }

    /// 终态（不可再变更，除非显式 retry/force）。
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }
}

/// 失败分类。
///
/// 工业下载器必须能区分"该重试"和"重试也没用"：
/// - 可重试：5xx / 429 / 408 / 超时 / 连接失败 / DNS 抖动
/// - 不可重试：4xx（除上述）/ 磁盘满 / 校验失败 / 用户取消
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FailKind {
    /// HTTP 状态码错误（附码）
    Http { status: u16 },
    /// 传输层连接失败（reset/refused/unreachable）
    Connect,
    /// DNS 解析失败
    Dns,
    /// TLS 握手/证书失败
    Tls,
    /// 超时（连接或读）
    Timeout,
    /// 服务端文件已变更（ETag/Last-Modified 不匹配或长度变化）→ 需整体重下
    ServerChanged,
    /// 校验失败（sha256 或长度不符）
    Checksum,
    /// 磁盘错误（空间不足/写入失败）
    Disk,
    /// 取消（非错误，但要落到终态说明）
    Cancelled,
    /// 分段返回了不合预期的响应（如声明支持 Range 却给了 200）
    Protocol,
    Unknown,
}

impl FailKind {
    /// 是否值得自动重试。
    pub fn is_retryable(&self) -> bool {
        match self {
            FailKind::Http { status } => {
                *status == 408 || *status == 425 || *status == 429 || *status >= 500
            }
            FailKind::Connect | FailKind::Dns | FailKind::Tls | FailKind::Timeout => true,
            FailKind::ServerChanged => true, // 重试会走"整体重下"分支
            FailKind::Checksum => true,      // 重试会走"重新校验/重下分段"
            FailKind::Disk | FailKind::Cancelled | FailKind::Protocol | FailKind::Unknown => false,
        }
    }

    /// 给用户看的短标签（面板"失败分类"展示用）。
    pub fn label(&self) -> String {
        match self {
            FailKind::Http { status } => format!("HTTP {status}"),
            FailKind::Connect => "连接失败".into(),
            FailKind::Dns => "域名解析失败".into(),
            FailKind::Tls => "TLS 失败".into(),
            FailKind::Timeout => "超时".into(),
            FailKind::ServerChanged => "服务端文件已变更".into(),
            FailKind::Checksum => "校验失败".into(),
            FailKind::Disk => "磁盘错误".into(),
            FailKind::Cancelled => "已取消".into(),
            FailKind::Protocol => "响应不符合预期".into(),
            FailKind::Unknown => "未知错误".into(),
        }
    }
}

/// 分段状态：每段独立记录偏移与已完成量，是断点续传的最小持久化单位。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Segment {
    pub index: u32,
    /// 该段在整个文件中的起始偏移（含）
    pub start_byte: u64,
    /// 该段结束偏移（含）——HTTP Range 是闭区间
    pub end_byte: u64,
    /// 该段已落盘字节数（≤ end-start+1）
    pub received: u64,
    /// 该段是否已完成
    pub done: bool,
}

impl Segment {
    pub fn len(&self) -> u64 {
        self.end_byte.saturating_sub(self.start_byte) + 1
    }

    pub fn is_empty(&self) -> bool {
        self.end_byte < self.start_byte
    }
}

/// 服务器元数据：用于「服务端文件是否变过」的一致性判断。
/// 续传前必须比对，否则会把两个版本的文件拼在一起（静默损坏）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerMeta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub etag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_modified: Option<String>,
    /// 探测到的总长度（`Content-Range` 的 total 或 `Content-Length`）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total: Option<u64>,
    /// 服务端是否支持 Range（206）
    #[serde(default)]
    pub supports_range: bool,
}

/// 任务实体（模块内的唯一真源）。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Task {
    pub id: u64,
    pub app_id: String,
    pub app_name: String,
    pub version: String,
    pub file_name: String,
    pub url: String,
    pub file_path: String,
    /// 期望总长度；0 = 未知
    pub total: u64,
    pub received: u64,
    pub status: TaskStatus,
    pub speed_bps: u64,
    pub eta_sec: Option<u64>,
    /// 面向用户的错误文案（已分类，见 [`FailKind`]）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fail_kind: Option<FailKind>,
    /// 已重试次数（面板可展示）
    #[serde(default)]
    pub retries: u32,
    pub segments: Vec<Segment>,
    #[serde(default)]
    pub server_meta: ServerMeta,
    /// 期望 sha256（可选；提供则下载后强校验）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_sha256: Option<String>,
    /// 实际算出的 sha256（完成后回填，供面板展示与排查）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actual_sha256: Option<String>,
    /// 优先级（越大越先调度）
    #[serde(default)]
    pub priority: i32,
    /// 排队原因（面板"为什么还没开始"展示用）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queue_reason: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    /// 逻辑唯一键（判重依据）：由调用方指定或按 [`crate::dedup`] 的规则派生。
    /// **不含展示字段**（app_name 随语言变化）、**不含 URL**（换镜像不该重复下载）。
    #[serde(default)]
    pub dedup_key: String,
    /// 资源类型：`app` / `model` / `asset` / `file` …（下载不只服务应用）
    #[serde(default = "default_kind")]
    pub kind: String,
    /// 资源在自身类型下的标识（app 的包名、模型的仓库名、资源的相对路径…）
    #[serde(default)]
    pub resource_id: String,
    #[serde(default)]
    pub resource_version: String,
    /// 发起下载时携带的请求头（GitHub/OPPO 等源需要；面板可展示）
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    /// 下载完成后是否自动安装（随任务持久化）
    #[serde(default)]
    pub install_after_download: bool,
    /// 最后一次开始时间（列表置顶依据）
    #[serde(default)]
    pub last_started_at: i64,
}

pub fn default_kind() -> String {
    "file".to_string()
}

impl Task {
    pub fn progress_ratio(&self) -> f64 {
        if self.total == 0 {
            0.0
        } else {
            (self.received as f64 / self.total as f64).clamp(0.0, 1.0)
        }
    }
}

/// 对 Dart 的扁平 DTO：键名与 Dart `DownloadTask` 字段同名。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskDto {
    pub id: i64,
    pub app_id: String,
    pub app_name: String,
    pub version: String,
    pub file_name: String,
    pub url: String,
    pub file_path: String,
    pub total: i64,
    pub received: i64,
    /// Dart `DownloadStatusEnum` 索引
    pub status: i32,
    pub speed_bps: i64,
    pub eta_sec: Option<i64>,
    pub error: Option<String>,
    pub fail_kind: Option<String>,
    pub retries: i32,
    pub segments: Vec<SegmentDto>,
    pub actual_sha256: Option<String>,
    pub queue_reason: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    /// 逻辑唯一键：Dart 侧可在不知道 id 的情况下按它查任务
    pub dedup_key: String,
    /// 资源类型（app/model/asset/file…），面板可用来分组展示
    pub kind: String,
    pub resource_id: String,
    pub resource_version: String,
    /// 发起下载时携带的请求头（面板展示用）
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    /// 下载完成后是否自动安装
    #[serde(default)]
    pub install_after_download: bool,
    /// 最后一次开始时间
    #[serde(default)]
    pub last_started_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SegmentDto {
    pub index: i32,
    pub start_byte: i64,
    pub end_byte: i64,
    pub received: i64,
}

impl From<&Task> for TaskDto {
    fn from(t: &Task) -> Self {
        Self {
            id: t.id as i64,
            app_id: t.app_id.clone(),
            app_name: t.app_name.clone(),
            version: t.version.clone(),
            file_name: t.file_name.clone(),
            url: t.url.clone(),
            file_path: t.file_path.clone(),
            total: t.total as i64,
            received: t.received as i64,
            status: t.status.as_i32(),
            speed_bps: t.speed_bps as i64,
            eta_sec: t.eta_sec.map(|v| v as i64),
            error: t.error.clone(),
            fail_kind: t.fail_kind.as_ref().map(|k| k.label()),
            retries: t.retries as i32,
            segments: t
                .segments
                .iter()
                .map(|s| SegmentDto {
                    index: s.index as i32,
                    start_byte: s.start_byte as i64,
                    end_byte: s.end_byte as i64,
                    received: s.received as i64,
                })
                .collect(),
            actual_sha256: t.actual_sha256.clone(),
            queue_reason: t.queue_reason.clone(),
            created_at: t.created_at,
            updated_at: t.updated_at,
            dedup_key: t.dedup_key.clone(),
            headers: t.headers.clone(),
        install_after_download: t.install_after_download,
        last_started_at: t.last_started_at,
            kind: t.kind.clone(),
            resource_id: t.resource_id.clone(),
            resource_version: t.resource_version.clone(),
        }
    }
}

/// 进度事件载荷（模块 → 宿主 → Dart 任务流）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgressEvent {
    pub task_id: i64,
    pub status: i32,
    pub total: i64,
    pub received: i64,
    pub speed_bps: i64,
    pub eta_sec: Option<i64>,
    /// 分段快照（面板画分段进度条用；仅在分段变化时下发以压体积）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub segments: Option<Vec<SegmentDto>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fail_kind: Option<String>,
}

pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_discriminants_match_dart_enum_indices() {
        // 这些数值与 lib/core/download/model/download_task.dart 的 DownloadStatusEnum 顺序绑定
        assert_eq!(TaskStatus::Queued.as_i32(), 0);
        assert_eq!(TaskStatus::Connecting.as_i32(), 1);
        assert_eq!(TaskStatus::Downloading.as_i32(), 2);
        assert_eq!(TaskStatus::Paused.as_i32(), 3);
        assert_eq!(TaskStatus::Completed.as_i32(), 4);
        assert_eq!(TaskStatus::Failed.as_i32(), 5);
        assert_eq!(TaskStatus::Cancelled.as_i32(), 6);
    }

    #[test]
    fn paused_is_not_active_but_queued_is() {
        assert!(TaskStatus::Queued.is_active());
        assert!(TaskStatus::Downloading.is_active());
        // 暂停不占并发额度
        assert!(!TaskStatus::Paused.is_active());
        assert!(!TaskStatus::Completed.is_active());
    }

    #[test]
    fn retryable_classification_is_conservative() {
        // 可重试
        assert!(FailKind::Http { status: 500 }.is_retryable());
        assert!(FailKind::Http { status: 429 }.is_retryable());
        assert!(FailKind::Http { status: 408 }.is_retryable());
        assert!(FailKind::Timeout.is_retryable());
        assert!(FailKind::Connect.is_retryable());
        // 不可重试（重试也没用或不该自动做）
        assert!(!FailKind::Http { status: 403 }.is_retryable());
        assert!(!FailKind::Http { status: 404 }.is_retryable());
        assert!(!FailKind::Disk.is_retryable());
        assert!(!FailKind::Cancelled.is_retryable());
    }

    #[test]
    fn segment_len_is_inclusive() {
        let s = Segment { index: 0, start_byte: 0, end_byte: 99, received: 0, done: false };
        assert_eq!(s.len(), 100, "HTTP Range 是闭区间，0-99 是 100 字节");
    }

    #[test]
    fn dto_uses_dart_field_names_and_status_index() {
        let t = Task {
            id: 7,
            app_id: "a".into(),
            app_name: "n".into(),
            version: "1".into(),
            file_name: "f.apk".into(),
            url: "http://x/f.apk".into(),
            file_path: "/tmp/f.apk".into(),
            total: 200,
            received: 50,
            status: TaskStatus::Downloading,
            speed_bps: 10,
            eta_sec: Some(15),
            error: None,
            fail_kind: None,
            retries: 0,
            segments: vec![Segment { index: 0, start_byte: 0, end_byte: 199, received: 50, done: false }],
            server_meta: ServerMeta::default(),
            expected_sha256: None,
            actual_sha256: None,
            priority: 0,
            queue_reason: None,
            created_at: 1,
            updated_at: 2,
            ..Default::default()
        };
        let v = serde_json::to_value(TaskDto::from(&t)).unwrap();
        // 键名必须与 Dart DownloadTask 一致
        for k in ["appId", "appName", "fileName", "filePath", "speedBps", "etaSec", "createdAt", "updatedAt"] {
            assert!(v.get(k).is_some(), "DTO 缺少 Dart 侧字段: {k}");
        }
        assert_eq!(v["status"], 2, "status 必须是 Dart 枚举索引");
        assert_eq!(v["segments"][0]["startByte"], 0);
    }

    #[test]
    fn progress_ratio_handles_unknown_total() {
        let mut t = Task {
            id: 1, app_id: String::new(), app_name: String::new(), version: String::new(),
            file_name: String::new(), url: String::new(), file_path: String::new(),
            total: 0, received: 123, status: TaskStatus::Downloading, speed_bps: 0,
            eta_sec: None, error: None, fail_kind: None, retries: 0, segments: vec![],
            server_meta: ServerMeta::default(), expected_sha256: None, actual_sha256: None,
            priority: 0, queue_reason: None, created_at: 0, updated_at: 0,
            ..Default::default()
        };
        assert_eq!(t.progress_ratio(), 0.0, "总长未知时不应出现 NaN/越界");
        t.total = 100;
        assert_eq!(t.progress_ratio(), 1.0, "进度需 clamp 到 1.0");
    }
}
