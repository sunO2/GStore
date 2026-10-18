//! 模块实例状态与宿主回调注册表。

use std::collections::{HashMap, VecDeque};
use std::ffi::{c_char, c_int, CString};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use gstore_contract::error::ModuleError;

use crate::collectors::{cpu, network, processes, util};

/// 采样环最小/最大容量。
pub const RING_CAP: usize = 300;

/// 宿主注入的日志回调（可空）。
pub static HOST_LOG: OnceLock<extern "C" fn(c_int, *const c_char)> = OnceLock::new();
/// 宿主注入的事件回调（模块 → 宿主）；载荷约定：前 4 字节为事件类型长度（小端）。
pub static HOST_EMIT: OnceLock<extern "C" fn(u64, u64, *const u8, usize)> = OnceLock::new();
/// 握手时宿主上报的 ABI 版本（诊断用）。
pub static HOST_ABI: OnceLock<u32> = OnceLock::new();

/// 一条采样记录。
#[derive(Debug, Clone, serde::Serialize)]
pub struct SampleRecord {
    pub seq: u64,
    pub ts_ms: u64,
    pub data: serde_json::Value,
}

/// 单实例状态：上次样本（CPU/网络/进程增量）+ 采样环。
///
/// `created_at_ms`/`data_dir`/`cache_dir`/`abi`/`app_version` 来自标准上下文，
/// Phase 1 仅诊断保留，供 Phase 2+（持久化历史）使用。
#[allow(dead_code)]
pub struct PerfInstance {
    pub id: u64,
    pub created_at_ms: u64,
    pub data_dir: String,
    pub cache_dir: String,
    pub abi: String,
    pub app_version: String,
    pub cpu_prev: Mutex<Option<cpu::CpuStat>>,
    pub net_prev: Mutex<Option<network::NetSample>>,
    pub proc_prev: Mutex<Option<processes::ProcSample>>,
    pub ring: Mutex<VecDeque<SampleRecord>>,
    pub seq: AtomicU64,
}

impl PerfInstance {
    pub fn new(id: u64, ctx: &gstore_contract::context::ModuleContext) -> Self {
        Self {
            id,
            created_at_ms: util::now_ms(),
            data_dir: ctx.data_dir.clone(),
            cache_dir: ctx.cache_dir.clone(),
            abi: ctx.abi.clone(),
            app_version: ctx.app_version.clone(),
            cpu_prev: Mutex::new(None),
            net_prev: Mutex::new(None),
            proc_prev: Mutex::new(None),
            ring: Mutex::new(VecDeque::new()),
            seq: AtomicU64::new(1),
        }
    }

    /// 追加一条采样（超出容量丢弃最旧）。
    pub fn push_sample(&self, data: serde_json::Value) {
        let seq = self.seq.fetch_add(1, Ordering::SeqCst);
        let record = SampleRecord {
            seq,
            ts_ms: util::now_ms(),
            data,
        };
        let mut ring = self.ring.lock().unwrap_or_else(|e| e.into_inner());
        while ring.len() >= RING_CAP {
            ring.pop_front();
        }
        ring.push_back(record);
    }

    /// 最近 `limit` 条（`limit == 0` 表示全部），按时间升序。
    pub fn history(&self, limit: usize) -> Vec<SampleRecord> {
        let ring = self.ring.lock().unwrap_or_else(|e| e.into_inner());
        let take = if limit == 0 || limit > ring.len() { ring.len() } else { limit };
        ring.iter().skip(ring.len() - take).cloned().collect()
    }

    pub fn sample_count(&self) -> usize {
        self.ring.lock().unwrap_or_else(|e| e.into_inner()).len()
    }

    /// 清空采样环与全部增量基线。
    pub fn reset(&self) {
        self.ring.lock().unwrap_or_else(|e| e.into_inner()).clear();
        *self.cpu_prev.lock().unwrap_or_else(|e| e.into_inner()) = None;
        *self.net_prev.lock().unwrap_or_else(|e| e.into_inner()) = None;
        *self.proc_prev.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

static INSTANCES: OnceLock<Mutex<HashMap<u64, Arc<PerfInstance>>>> = OnceLock::new();
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);

pub fn instances() -> &'static Mutex<HashMap<u64, Arc<PerfInstance>>> {
    INSTANCES.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn next_instance_id() -> u64 {
    NEXT_INSTANCE.fetch_add(1, Ordering::SeqCst)
}

/// 取实例（不存在返回 `None`）。
pub fn instance_of(id: u64) -> Option<Arc<PerfInstance>> {
    instances()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&id)
        .cloned()
}

/// 取实例（不存在返回结构化 `INSTANCE_NOT_FOUND`）。
pub fn require_instance(id: u64) -> Result<Arc<PerfInstance>, ModuleError> {
    instance_of(id).ok_or_else(|| ModuleError::instance_not_found(id))
}

/// 写入宿主日志（无回调时静默丢弃）。
pub fn log_message(level: c_int, msg: &str) {
    if let Some(f) = HOST_LOG.get() {
        if let Ok(cmsg) = CString::new(msg) {
            f(level, cmsg.as_ptr());
        }
    }
}

/// 上报模块事件（宿主负载约定：前 4 字节为事件类型长度，小端）。
pub fn emit_event(instance_id: u64, event_type: &str, payload: &[u8]) {
    let Some(f) = HOST_EMIT.get() else {
        return;
    };
    let type_bytes = event_type.as_bytes();
    let mut buf = Vec::with_capacity(4 + type_bytes.len() + payload.len());
    buf.extend_from_slice(&(type_bytes.len() as u32).to_le_bytes());
    buf.extend_from_slice(type_bytes);
    buf.extend_from_slice(payload);
    f(0, instance_id, buf.as_ptr(), buf.len());
}
