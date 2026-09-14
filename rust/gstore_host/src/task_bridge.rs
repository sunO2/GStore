//! 长任务（Task）模型：把「长调用」从「同步请求/响应」升级为一等公民。
//!
//! ## 为什么需要
//!
//! 宿主暴露给 Dart 的函数都是**同步** `pub fn`，FRB 会把它们丢到任务池线程执行；
//! 模块契约是**同步 C ABI**，长任务（下载、LLM 生成）只能 `runtime.block_on` ——
//! 结果是一个长任务**占满一个 FRB 工作线程直到结束**：没有进度、无法取消，
//! 并发长任务还会把池耗尽。
//!
//! ## 模型（类比 HTTP/2 多路复用，而非「每任务一条连接」）
//!
//! - `start_task` 是**本地同步调用**，立即返回 `task_id`（无握手、无建连成本）
//! - 真正的工作跑在**宿主自有线程**（不再占用 FRB 池）
//! - 事件按 `task_id` 归属，`kind = started | progress | chunk | done | error | cancelled`
//! - `cancel_task` 转发模块 `cancel` 槽（**协作式**，无抢占）
//! - Dart 消费 `Stream<TaskEvent>`：**天然异步 marshal**（同步回调会重入死锁）
//!
//! ## 两步式（避免竞态）
//!
//! 1. `start_task(...) -> task_id`：立即返回；此时事件先入**有界缓冲**
//! 2. `watch_task(task_id, sink)`：订阅时**先补发缓冲**再转实时（与 event_bridge 同思路）
//!
//! 任务终态时槽位被移除 → `StreamSink` 被 drop → Dart 侧 Stream 自然 onDone。
//!
//! ## 锁序（重要）
//!
//! 注册表锁**只用于取 `Arc<TaskSlot>`，立即释放**；真正的 `sink.add` 只持有
//! slot 自己的 sink 锁。与 `event_bridge` / `broadcast_event` 的既有做法一致，
//! 避免"持注册表锁跨 FFI"造成的重入死锁。
//!
//! ## 模块零改动（关键）
//!
//! 任务线程上模块调用 `emit_event` 时，本模块用**线程局部**的「当前任务」标记归属；
//! 命中进任务流，未命中维持旧的全局事件总线行为 → **C ABI 零变更**。

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use gstore_contract::envelope::{EnvelopeRequest, EnvelopeResponse};

use crate::frb_generated::StreamSink;
use crate::manager::ModuleManager;

/// 任务事件（FRB 生成 Dart 侧同名类）
pub struct TaskEvent {
    /// 任务 id（≈ HTTP/2 的 stream id）
    pub task_id: String,
    /// `started` | `progress` | `chunk` | `done` | `error` | `cancelled`
    pub kind: String,
    /// 单任务内单调递增（**跨任务无序**）——供 Dart 侧重排序
    pub seq: u32,
    /// `done` 为结果字节；`progress`/`chunk` 为模块事件原始负载
    pub data: Vec<u8>,
    /// `error` 时的错误信息
    pub error: String,
    /// `error` 时的模块错误码（无则空）
    pub error_code: String,
}

/// 同时在跑的任务上限（等价于连接池上限，防任务泄漏耗尽资源）
const MAX_TASKS: usize = 16;

/// 未订阅期间的事件补发上限
const EVENT_BUFFER_CAP: usize = 128;

/// 单个任务的槽位。**sink 与 pending 各自独立加锁**，避免持注册表锁做 FFI。
struct TaskSlot {
    sink: Mutex<Option<StreamSink<TaskEvent>>>,
    pending: Mutex<VecDeque<TaskEvent>>,
    seq: AtomicU32,
    cancelled: AtomicBool,
    module_id: u64,
    instance: Option<u64>,
    request_id: String,
}

impl TaskSlot {
    /// 发事件：有订阅者直接发，否则入有界缓冲（丢最旧）
    fn deliver(&self, task_id: &str, kind: &str, data: Vec<u8>, error: String, error_code: String) {
        let seq = self.seq.fetch_add(1, Ordering::SeqCst) + 1;
        let event = TaskEvent {
            task_id: task_id.to_string(),
            kind: kind.to_string(),
            seq,
            data,
            error,
            error_code,
        };
        let mut sink_guard = match self.sink.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        if let Some(sink) = sink_guard.as_ref() {
            // Dart 已取消订阅 → 标记取消，任务侧在检查点退出
            if sink.add(event).is_err() {
                self.cancelled.store(true, Ordering::SeqCst);
            }
            return;
        }
        drop(sink_guard);
        if let Ok(mut buf) = self.pending.lock() {
            if buf.len() >= EVENT_BUFFER_CAP {
                buf.pop_front();
            }
            buf.push_back(event);
        }
    }
}

static TASKS: OnceLock<Mutex<HashMap<String, Arc<TaskSlot>>>> = OnceLock::new();
static TASK_SEQ: AtomicU64 = AtomicU64::new(1);

fn tasks() -> &'static Mutex<HashMap<String, Arc<TaskSlot>>> {
    TASKS.get_or_init(|| Mutex::new(HashMap::new()))
}

thread_local! {
    /// 当前线程正在执行的任务（模块 `emit_event` 据此归属）
    static CURRENT_TASK: std::cell::RefCell<Option<String>> =
        const { std::cell::RefCell::new(None) };
}

/// 当前线程所属任务 id（供 event_bridge 归属判断）
pub fn current_task_id() -> Option<String> {
    CURRENT_TASK.with(|c| c.borrow().clone())
}

/// 取任务槽（先快照 `Arc` 再释放注册表锁）
fn slot_of(task_id: &str) -> Option<Arc<TaskSlot>> {
    tasks().lock().ok()?.get(task_id).cloned()
}

/// 事件投递入口（供 event_bridge 调用）：命中任务则消费，返回 true
pub fn emit_current_thread(event_type: &str, data: Vec<u8>) -> bool {
    let Some(task_id) = current_task_id() else {
        return false;
    };
    let Some(slot) = slot_of(&task_id) else {
        return false;
    };
    slot.deliver(&task_id, event_type, data, String::new(), String::new());
    true
}

fn emit_task_event(task_id: &str, kind: &str, data: Vec<u8>) {
    if let Some(slot) = slot_of(task_id) {
        slot.deliver(task_id, kind, data, String::new(), String::new());
    }
}

/// 结束任务：投递终态事件 → 从注册表移除（drop sink → Dart Stream onDone）
fn finish_task(task_id: &str, kind: &str, data: Vec<u8>, error: String, error_code: String) {
    let slot = {
        let mut guard = match tasks().lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        guard.remove(task_id)
    };
    if let Some(slot) = slot {
        slot.deliver(task_id, kind, data, error, error_code);
    }
}

fn is_cancelled(task_id: &str) -> bool {
    slot_of(task_id)
        .map(|s| s.cancelled.load(Ordering::SeqCst))
        .unwrap_or(true)
}

/// 启动长任务：**同步立即返回** task_id，工作在宿主自有线程执行。
///
/// [instance] 为实例句柄（静态调用传 None）；与 `callModule` 同语义，
/// 复用同一套信封路由与错误模型。
pub fn start_task(
    module: String,
    instance: Option<u64>,
    method: String,
    payload: Vec<u8>,
) -> Result<String, String> {
    let module_id = ModuleManager::global()
        .module_id_by_name(&module)
        .ok_or_else(|| format!("module not loaded: {module}"))?;

    let task_id = format!("task-{}", TASK_SEQ.fetch_add(1, Ordering::SeqCst));
    let request_id = task_id.clone();

    {
        let mut guard = tasks().lock().map_err(|_| "tasks lock poisoned".to_string())?;
        if guard.len() >= MAX_TASKS {
            return Err(format!("too many running tasks (max {MAX_TASKS})"));
        }
        guard.insert(
            task_id.clone(),
            Arc::new(TaskSlot {
                sink: Mutex::new(None),
                pending: Mutex::new(VecDeque::new()),
                seq: AtomicU32::new(0),
                cancelled: AtomicBool::new(false),
                module_id,
                instance,
                request_id: request_id.clone(),
            }),
        );
    }

    emit_task_event(&task_id, "started", Vec::new());

    let tid = task_id.clone();
    let spawned = std::thread::Builder::new()
        .name(format!("gstore-task-{tid}"))
        .spawn(move || {
            if is_cancelled(&tid) {
                finish_task(&tid, "cancelled", Vec::new(), String::new(), String::new());
                return;
            }
            // 本线程上模块的 emit_event 归属到该任务（模块零改动）
            CURRENT_TASK.with(|c| *c.borrow_mut() = Some(tid.clone()));

            let result = dispatch_envelope(&module, instance, &method, &payload, &tid);

            CURRENT_TASK.with(|c| *c.borrow_mut() = None);

            if is_cancelled(&tid) {
                finish_task(&tid, "cancelled", Vec::new(), String::new(), String::new());
                return;
            }
            match result {
                Ok(bytes) => finish_task(&tid, "done", bytes, String::new(), String::new()),
                Err((code, message)) => finish_task(&tid, "error", Vec::new(), message, code),
            }
        })
        .is_ok();

    if !spawned {
        finish_task(
            &task_id,
            "error",
            Vec::new(),
            "failed to spawn task thread".to_string(),
            String::new(),
        );
        return Err("failed to spawn task thread".to_string());
    }
    Ok(task_id)
}

/// 订阅任务事件流：先补发缓冲，再转实时（bridge.rs 委托到此）
pub fn watch_task(task_id: String, sink: StreamSink<TaskEvent>) {
    let Some(slot) = slot_of(&task_id) else {
        // 任务不存在或已结束 → 立刻结束流（不 add 任何事件）
        return;
    };
    let pending: Vec<TaskEvent> = match slot.pending.lock() {
        Ok(mut buf) => buf.drain(..).collect(),
        Err(_) => Vec::new(),
    };
    let mut sink_guard = match slot.sink.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    for ev in pending {
        if sink.add(ev).is_err() {
            return;
        }
    }
    *sink_guard = Some(sink);
}

/// 取消任务：置位标记 + 转发模块 `cancel` 槽（协作式，不保证立即停止）
pub fn cancel_task(task_id: String) -> Result<(), String> {
    let slot = slot_of(&task_id).ok_or_else(|| format!("task not found: {task_id}"))?;
    slot.cancelled.store(true, Ordering::SeqCst);
    ModuleManager::global()
        .cancel(slot.module_id, slot.instance, &slot.request_id)
        .map_err(|e| e.to_string())?;
    emit_task_event(&task_id, "cancelled", Vec::new());
    Ok(())
}

/// 在跑任务数（诊断/测试）
pub fn running_task_count() -> usize {
    tasks().lock().map(|g| g.len()).unwrap_or(0)
}

/// 复用宿主同一套信封路由（与 Dart `callModule` 完全同语义）
fn dispatch_envelope(
    module: &str,
    instance: Option<u64>,
    method: &str,
    payload: &[u8],
    request_id: &str,
) -> Result<Vec<u8>, (String, String)> {
    let instance_str = instance.map(|v| v.to_string());
    let request = EnvelopeRequest::new(module, instance_str.as_deref(), method, payload.to_vec())
        .with_request_id(request_id);
    let Ok(req_bytes) = request.encode() else {
        return Err((String::new(), "encode envelope failed".to_string()));
    };
    let resp_bytes = ModuleManager::global().call_envelope(&req_bytes);
    let Ok(resp) = EnvelopeResponse::decode(&resp_bytes) else {
        return Err((String::new(), "decode envelope failed".to_string()));
    };
    if resp.is_ok() {
        Ok(resp.payload().to_vec())
    } else {
        Err((resp.error_code().to_string(), resp.error_message().to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emit_without_task_is_noop() {
        assert!(current_task_id().is_none());
        assert!(!emit_current_thread("progress", vec![]));
        assert_eq!(running_task_count(), 0);
    }

    #[test]
    fn start_task_rejects_unknown_module() {
        let err = start_task("not-a-module".into(), None, "ping".into(), vec![]).unwrap_err();
        assert!(err.contains("not loaded"), "unexpected: {err}");
    }

    #[test]
    fn cancel_missing_task_reports_error() {
        let err = cancel_task("task-nope".into()).unwrap_err();
        assert!(err.contains("not found"), "unexpected: {err}");
    }
}
