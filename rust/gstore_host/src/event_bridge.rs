// EventBridge：模块事件 → FRB Stream → Flutter（架构文档 6.8 事件通道）
//
// 与日志通道共用宿主→Dart 单向管道基础设施（FRB StreamSink + 环形缓冲），
// 但消息类型独立（ModuleEvent，含 module/instance 路由信息）。
// 模块经 GStoreModuleEntry.emit_event 回调把事件推给宿主。

use std::sync::{Arc, Mutex, OnceLock};

use crate::frb_generated::StreamSink;

/// 模块事件（FRB 生成 Dart 侧类；模块经 emit_event 推送，Dart 订阅 events_stream 消费）
pub struct ModuleEvent {
    pub module_id: u64,
    pub instance_id: u64,
    pub event_type: String,  // 事件类型（如 "progress" / "stream" / "status"）
    pub data: Vec<u8>,       // 事件负载（域 schema 编码）
    pub timestamp_ms: i64,
}

/// 环形缓冲上限（未订阅期间的事件补发量）
const EVENT_BUFFER_CAP: usize = 100;

pub(crate) struct EventBridgeInner {
    sink: Mutex<Option<StreamSink<ModuleEvent>>>,
    buffer: Mutex<Vec<ModuleEvent>>,
}

impl EventBridgeInner {
    fn push(&self, event: ModuleEvent) {
        let mut buf = self.buffer.lock().unwrap();
        buf.push(event.clone());
        if buf.len() > EVENT_BUFFER_CAP {
            buf.remove(0);
        }
        drop(buf);
        if let Some(sink) = self.sink.lock().unwrap().as_ref() {
            let _ = sink.add(event);
        }
    }
}

impl Clone for ModuleEvent {
    fn clone(&self) -> Self {
        Self {
            module_id: self.module_id,
            instance_id: self.instance_id,
            event_type: self.event_type.clone(),
            data: self.data.clone(),
            timestamp_ms: self.timestamp_ms,
        }
    }
}

/// 全局事件桥（唯一实例）
static EVENT_BRIDGE: OnceLock<Arc<EventBridgeInner>> = OnceLock::new();

pub(crate) fn global() -> Arc<EventBridgeInner> {
    EVENT_BRIDGE
        .get_or_init(|| {
            Arc::new(EventBridgeInner {
                sink: Mutex::new(None),
                buffer: Mutex::new(Vec::new()),
            })
        })
        .clone()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 宿主注入给模块的 emit_event 回调（extern "C" 签名，供 GStoreModuleEntry.emit_event 使用）
///
/// 模块在 register 握手中收到此函数指针。事件负载约定：
/// 前 4 字节为 event_type 长度（小端），后续为 event_type 字节串 + data。
pub extern "C" fn host_emit_event(
    module_id: u64,
    instance_id: u64,
    data: *const u8,
    len: usize,
) {
    // 事件负载：前 4 字节为 event_type 长度（小端），后续为 event_type 字节串 + data
    if data.is_null() || len == 0 {
        return;
    }
    let raw = unsafe { std::slice::from_raw_parts(data, len) };
    let (type_len, rest) = if raw.len() >= 4 {
        (u32::from_le_bytes(raw[0..4].try_into().unwrap()) as usize, &raw[4..])
    } else {
        return;
    };
    let (type_bytes, payload) = if rest.len() >= type_len {
        (&rest[..type_len], &rest[type_len..])
    } else {
        return;
    };
    let event_type = String::from_utf8_lossy(type_bytes).into_owned();
    global().push(ModuleEvent {
        module_id,
        instance_id,
        event_type,
        data: payload.to_vec(),
        timestamp_ms: now_ms(),
    });
}

/// 订阅事件流（bridge.rs 的 EventBridge::events_stream 委托到此）。
/// 首次订阅时补发环形缓冲中的历史事件。
pub fn subscribe(sink: StreamSink<ModuleEvent>) {
    let bridge = global();
    {
        let mut guard = bridge.sink.lock().unwrap();
        *guard = Some(sink);
    }
    let history = bridge.buffer.lock().unwrap().clone();
    let sink_guard = bridge.sink.lock().unwrap();
    if let Some(sink) = sink_guard.as_ref() {
        for event in history {
            let _ = sink.add(event);
        }
    }
}

/// 便捷：宿主内部推送一条模块事件（供 Rust 侧测试/内嵌模块使用）
pub fn push_event(module_id: u64, instance_id: u64, event_type: &str, data: Vec<u8>) {
    global().push(ModuleEvent {
        module_id,
        instance_id,
        event_type: event_type.to_string(),
        data,
        timestamp_ms: now_ms(),
    });
}

/// C ABI 兼容入口（无 context 版本，供未来模块直接调用；当前经 handshake 注入 host_emit_event）
pub extern "C" fn host_emit_event_simple(
    module_id: u64,
    instance_id: u64,
    data: *const u8,
    len: usize,
) {
    host_emit_event(module_id, instance_id, data, len);
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_roundtrip_via_buffer() {
        // 模拟模块推送事件（未订阅时入环形缓冲）
        let payload = b"progress payload".to_vec();
        let event_type = "progress".to_string();
        let data = event_bridge_data(&event_type, &payload);
        // 直接经 host_emit_event 模拟 C ABI 推送
        host_emit_event(1, 42, data.as_ptr(), data.len());
        let bridge = global();
        let buf = bridge.buffer.lock().unwrap();
        assert!(!buf.is_empty());
        let last = buf.last().unwrap();
        assert_eq!(last.module_id, 1);
        assert_eq!(last.instance_id, 42);
        assert_eq!(last.event_type, "progress");
        assert_eq!(last.data, payload);
    }

    /// 构造与模块约定一致的负载（前 4 字节 type 长度 + type + data）
    fn event_bridge_data(event_type: &str, data: &[u8]) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(&(event_type.len() as u32).to_le_bytes());
        v.extend_from_slice(event_type.as_bytes());
        v.extend_from_slice(data);
        v
    }
}
