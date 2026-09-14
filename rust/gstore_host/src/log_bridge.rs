// LogBridge：Rust 日志 → FRB Stream → Flutter LogManager（架构文档 6.8）
//
// 通道宿主一份：模块经 GStoreModuleEntry.log 回调把日志交给宿主，
// 宿主在此收集（环形缓冲）并通过 logs_stream 推给 Dart。

use std::os::raw::{c_char, c_int};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::frb_generated::StreamSink;

/// 日志消息（FRB 生成 Dart 侧类，LogManager 消费）
pub struct LogMessage {
    pub level: i32,        // 0=debug 1=info 2=warn 3=error
    pub message: String,
    pub module: String,
    pub timestamp_ms: i64,
}

/// 环形缓冲上限（未订阅期间的日志补发量）
const RING_BUFFER_CAP: usize = 200;

pub(crate) struct LogBridgeInner {
    sink: Mutex<Option<StreamSink<LogMessage>>>,
    buffer: Mutex<Vec<LogMessage>>, // 环形缓冲：Dart 订阅前暂存
}

impl LogBridgeInner {
    fn push(&self, msg: LogMessage) {
        // 无条件入环形缓冲（供订阅补发）
        let mut buf = self.buffer.lock().unwrap();
        buf.push(msg.clone());
        if buf.len() > RING_BUFFER_CAP {
            buf.remove(0);
        }
        drop(buf);
        // 已订阅则实时推送
        if let Some(sink) = self.sink.lock().unwrap().as_ref() {
            let _ = sink.add(msg);
        }
    }
}

impl Clone for LogMessage {
    fn clone(&self) -> Self {
        Self {
            level: self.level,
            message: self.message.clone(),
            module: self.module.clone(),
            timestamp_ms: self.timestamp_ms,
        }
    }
}

/// 全局日志桥（唯一实例）
static LOG_BRIDGE: OnceLock<Arc<LogBridgeInner>> = OnceLock::new();

pub(crate) fn global() -> Arc<LogBridgeInner> {
    LOG_BRIDGE
        .get_or_init(|| {
            Arc::new(LogBridgeInner {
                sink: Mutex::new(None),
                buffer: Mutex::new(Vec::new()),
            })
        })
        .clone()
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 宿主注入给模块的 log 回调（extern "C" 签名，供 GStoreModuleEntry.log 使用）
pub extern "C" fn host_log(level: c_int, msg: *const c_char) {
    if msg.is_null() {
        return;
    }
    let message = unsafe { std::ffi::CStr::from_ptr(msg) }
        .to_string_lossy()
        .into_owned();
    global().push(LogMessage {
        level,
        message,
        module: "rust".to_string(),
        timestamp_ms: now_ms(),
    });
}

/// 订阅日志流（bridge.rs 的 LogBridge::logs_stream 委托到此）。
/// 首次订阅时补发环形缓冲中的历史日志。
pub fn subscribe(sink: StreamSink<LogMessage>) {
    let bridge = global();
    {
        let mut guard = bridge.sink.lock().unwrap();
        *guard = Some(sink);
    }
    // 补发缓冲历史
    let history = bridge.buffer.lock().unwrap().clone();
    let sink_guard = bridge.sink.lock().unwrap();
    if let Some(sink) = sink_guard.as_ref() {
        for msg in history {
            let _ = sink.add(msg);
        }
    }
}

/// 清空订阅 sink。引擎被销毁并在同进程内重建时，宿主仍持有指向上一个 Dart
/// isolate 的 StreamSink（端口已失效）；新 isolate 订阅前调用本函数丢弃它，
/// 避免向已销毁端口推送（二次启动崩溃的次因之一）。
pub fn clear_sink() {
    let bridge = global();
    let _ = bridge.sink.lock().unwrap().take();
}

/// 写入一条宿主日志（内部辅助：bridge 层方法调用，供宿主自身代码记录日志）
pub fn push_host_log(level: c_int, message: String) {
    global().push(LogMessage {
        level,
        message,
        module: "rust".to_string(),
        timestamp_ms: now_ms(),
    });
}
