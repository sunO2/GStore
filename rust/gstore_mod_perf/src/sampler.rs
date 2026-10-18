//! 后台采样器：单驱动线程，按可配置间隔采样并上报 `perf.sample` 事件 + 写入实例采样环。
//!
//! 线程模式参照 `gstore_mod_proxy/src/stats_monitor.rs`：全局单驱动、`stop` 发送信号并 join、
//! 绝不让采样线程活过 `destroy`/`shutdown`。

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use crate::state::PerfInstance;

/// 默认采样间隔（毫秒）。
pub const DEFAULT_INTERVAL_MS: u64 = 2000;
/// 最小采样间隔（毫秒）。
pub const MIN_INTERVAL_MS: u64 = 200;
/// 最大采样间隔（毫秒）。
pub const MAX_INTERVAL_MS: u64 = 600_000;
/// 采样事件类型。
pub const EVT_SAMPLE: &str = "perf.sample";

struct Running {
    stop: Sender<()>,
    thread: std::thread::JoinHandle<()>,
    instance_id: u64,
    interval_ms: u64,
}

static RUNNING: OnceLock<Mutex<Option<Running>>> = OnceLock::new();
static COUNT: AtomicUsize = AtomicUsize::new(0);

fn cell() -> &'static Mutex<Option<Running>> {
    RUNNING.get_or_init(|| Mutex::new(None))
}

/// 间隔归一化到 `[MIN, MAX]`。
pub fn normalize_interval(ms: u64) -> u64 {
    ms.clamp(MIN_INTERVAL_MS, MAX_INTERVAL_MS)
}

/// 启动采样器（若已有则先停止并 join 再重启）。返回是否成功启动。
pub fn start(inst: Arc<PerfInstance>, interval_ms: u64) -> bool {
    let interval_ms = normalize_interval(interval_ms);
    let mut guard = cell().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(previous) = guard.take() {
        let _ = previous.stop.send(());
        let _ = previous.thread.join();
        COUNT.fetch_sub(1, Ordering::SeqCst);
    }
    let instance_id = inst.id;
    let (stop_tx, stop_rx) = channel::<()>();
    let spawned = std::thread::Builder::new()
        .name("gstore-perf-sampler".to_string())
        .spawn(move || run(inst, interval_ms, stop_rx));
    match spawned {
        Ok(thread) => {
            COUNT.fetch_add(1, Ordering::SeqCst);
            *guard = Some(Running {
                stop: stop_tx,
                thread,
                instance_id,
                interval_ms,
            });
            true
        }
        Err(e) => {
            crate::state::log_message(3, &format!("perf: sampler spawn failed: {e}"));
            false
        }
    }
}

/// 停止并 join 采样器。返回此前是否在运行。幂等。
pub fn stop() -> bool {
    let taken = cell().lock().unwrap_or_else(|e| e.into_inner()).take();
    match taken {
        Some(running) => {
            let _ = running.stop.send(());
            if running.thread.join().is_err() {
                crate::state::log_message(3, "perf: sampler thread panicked during teardown");
            }
            COUNT.fetch_sub(1, Ordering::SeqCst);
            true
        }
        None => false,
    }
}

pub fn is_running() -> bool {
    cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .map(|r| !r.thread.is_finished())
        .unwrap_or(false)
}

/// 正在运行的采样器线程数（`stop` 后应为 0）。
pub fn running_count() -> usize {
    COUNT.load(Ordering::SeqCst)
}

/// 运行中采样器的 `(instance_id, interval_ms)`。
pub fn status() -> Option<(u64, u64)> {
    cell()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .map(|r| (r.instance_id, r.interval_ms))
}

/// 线程体：立即采样一次，然后按间隔循环；收到停止信号或发送端断开即退出。
fn run(inst: Arc<PerfInstance>, interval_ms: u64, rx: Receiver<()>) {
    let interval = Duration::from_millis(interval_ms);
    loop {
        let data = crate::snapshot::tick_snapshot(&inst);
        inst.push_sample(data.clone());
        if let Ok(bytes) = serde_json::to_vec(&data) {
            crate::state::emit_event(inst.id, EVT_SAMPLE, &bytes);
        }
        match rx.recv_timeout(interval) {
            Ok(()) | Err(RecvTimeoutError::Disconnected) => break,
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gstore_contract::context::ModuleContext;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn normalize_interval_clamps_bounds() {
        assert_eq!(normalize_interval(0), MIN_INTERVAL_MS);
        assert_eq!(normalize_interval(100), MIN_INTERVAL_MS);
        assert_eq!(normalize_interval(2000), 2000);
        assert_eq!(normalize_interval(u64::MAX), MAX_INTERVAL_MS);
    }

    #[test]
    fn start_is_single_driver_and_stop_joins() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        stop();
        let inst = Arc::new(PerfInstance::new(u64::MAX, &ModuleContext::default()));
        assert!(start(inst.clone(), 300));
        assert!(is_running());
        assert_eq!(running_count(), 1);
        assert_eq!(status(), Some((u64::MAX, 300)));
        assert!(start(inst.clone(), 300), "restart replaces the driver");
        assert_eq!(running_count(), 1, "still exactly one driver");
        assert!(stop());
        assert!(!is_running());
        assert_eq!(running_count(), 0);
        assert!(!stop(), "second stop is a no-op");
        assert!(inst.sample_count() >= 1, "the sampler pushed at least one sample");
    }
}
