//! Module-internal bounded log ring + structured records (Todo 15).
//!
//! The module never owns a log transport. Every retained record is **also**
//! handed to the host through the ABI `log` callback captured in
//! [`crate::HOST_LOG`] — the exact function pointer
//! [`gstore_contract::logging::HostLogger`] wraps — which the host forwards to
//! Flutter's `LogManager` through the existing LogBridge
//! (`rust/ARCHITECTURE.md` §6.8, `rust/gstore_host/src/log_bridge.rs`).
//!
//! On top of that push channel this module adds the *pull* side: a bounded
//! in-process ring (the last [`RING_CAPACITY`] records) with a **monotonic
//! cursor** so `log.get(sinceCursor)` can paginate. It is intentionally a
//! side-channel only: the datapath never waits on it.
//!
//! Invariants (documented in `API.md` §2.8 / §14):
//!  * **Bounded** — at most [`RING_CAPACITY`] records are retained; the oldest
//!    are evicted first. Cursors are never reused (monotonic).
//!  * **Non-blocking** — a push is one mutex plus `VecDeque::push_back`, i.e.
//!    O(1) with no I/O and no `.await`. Nothing in the TUN/relay path blocks on
//!    logging; on contention the lock is a short critical section.
//!  * **Never fatal** — a disconnected host sink or a poisoned lock drops the
//!    record and the module keeps running (no panic). Records that could not be
//!    forwarded are counted in `sinkDropped`.
//!  * **No secrets** — [`ConnectionLog`] carries only the fields listed in
//!    `API.md`; there is deliberately no payload/credential/URL field. The
//!    module never logs node passwords/UUIDs or subscription URLs.

use std::collections::VecDeque;
use std::os::raw::c_int;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[cfg(not(test))]
use std::sync::{Mutex, OnceLock};

use gstore_contract::error::{ModuleError, StatusCode};
use serde::{Deserialize, Serialize};

use crate::dns::DnsQueryRecord;

/// Hard cap on retained records. `log.get` never returns more than this in
/// total; beyond it the oldest records are evicted.
pub(crate) const RING_CAPACITY: usize = 1000;
/// Default page size for `log.get` when the caller omits `limit`.
pub(crate) const DEFAULT_LIMIT: usize = 200;

/// Record kind tags (`LogRecord.kind`).
pub(crate) const KIND_MESSAGE: &str = "message";
pub(crate) const KIND_CONNECTION: &str = "connection";
pub(crate) const KIND_DNS: &str = "dns";

/// Domain error code for an unknown `log.set_level` / `log.get` level.
pub(crate) const ERR_LOG_LEVEL_INVALID: &str = "PROXY_LOG_LEVEL_INVALID";

/// Host-aligned log level: `0=debug,1=info,2=warn,3=error` (same encoding as
/// `gstore_contract::logging::level_to_int` and Dart `LogLevel`).
///
/// The derived ordering (`Debug < Info < Warn < Error`) is the retention
/// threshold comparison order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum LogLevel {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
}

impl LogLevel {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            LogLevel::Debug => "debug",
            LogLevel::Info => "info",
            LogLevel::Warn => "warn",
            LogLevel::Error => "error",
        }
    }

    /// Level int for the host `log` callback (see module docs).
    pub(crate) fn as_int(self) -> i32 {
        self as i32
    }

    /// Host int → level. Unknown values clamp to `Error` (never lose a line).
    pub(crate) fn from_int(v: i32) -> Self {
        match v {
            0 => LogLevel::Debug,
            1 => LogLevel::Info,
            2 => LogLevel::Warn,
            _ => LogLevel::Error,
        }
    }

    /// Case-insensitive parse; accepts `trace` as an alias of `debug`.
    pub(crate) fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "trace" | "debug" => Some(LogLevel::Debug),
            "info" => Some(LogLevel::Info),
            "warn" | "warning" => Some(LogLevel::Warn),
            "error" => Some(LogLevel::Error),
            _ => None,
        }
    }

    fn to_filter(self) -> log::LevelFilter {
        match self {
            LogLevel::Debug => log::LevelFilter::Debug,
            LogLevel::Info => log::LevelFilter::Info,
            LogLevel::Warn => log::LevelFilter::Warn,
            LogLevel::Error => log::LevelFilter::Error,
        }
    }
}

/// Structured connection record embedded in a [`LogRecord`] (`kind:"connection"`).
///
/// Stable schema — see `API.md` §2.8. `bytes` is the total
/// (`uploadBytes + downloadBytes`). `error` is only populated when a failure is
/// known (e.g. a dial/protect failure); a clean close leaves it absent.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ConnectionLog {
    pub id: String,
    /// `"in"` = a flow entering from the TUN (client→proxy); `"out"` = the
    /// upstream leg dialled by an adapter. Todo 15 records the TUN side.
    pub direction: String,
    pub domain: String,
    pub outbound: String,
    pub rule: String,
    pub rule_payload: String,
    pub network: String,
    pub src: String,
    pub dst: String,
    pub upload_bytes: i64,
    pub download_bytes: i64,
    pub bytes: i64,
    pub duration_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// One retained log record. The generic envelope (cursor/ts/level/kind/message)
/// is stable for every kind; exactly one of `connection`/`dns` is present for
/// the structured kinds.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LogRecord {
    /// Monotonic, never reused. `log.get(sinceCursor)` returns `cursor > since`.
    pub cursor: u64,
    pub ts_ms: u64,
    pub level: String,
    pub kind: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connection: Option<ConnectionLog>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dns: Option<DnsQueryRecord>,
}

/// A page of records returned by `log.get`.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub records: Vec<LogRecord>,
    /// Global next-to-be-assigned cursor (diagnostic).
    pub cursor: u64,
    /// Pass as `sinceCursor` to fetch the following page; equals the last
    /// returned cursor, or `sinceCursor` when the page is empty.
    pub next_cursor: u64,
    /// Oldest retained cursor, or `0` when the ring is empty. A caller whose
    /// `sinceCursor` is below this has lost records to eviction.
    pub first_cursor: u64,
    pub retained: usize,
    pub capacity: usize,
    /// Records discarded because they were below the retention level.
    pub dropped: u64,
    /// Records retained but not delivered to the host sink (disconnected).
    pub sink_dropped: u64,
    pub level: String,
}

struct RingState {
    /// Next cursor to assign. Starts at 1; never reset by `log.clear`.
    next: u64,
    /// Retention threshold; records below it are dropped at the source.
    level: LogLevel,
    records: VecDeque<LogRecord>,
}

impl RingState {
    fn fresh() -> Self {
        Self {
            next: 1,
            level: LogLevel::Info,
            records: VecDeque::with_capacity(RING_CAPACITY),
        }
    }
}

#[cfg(not(test))]
static RING: OnceLock<Mutex<RingState>> = OnceLock::new();

#[cfg(not(test))]
fn ring() -> &'static Mutex<RingState> {
    RING.get_or_init(|| Mutex::new(RingState::fresh()))
}

/// Run `f` against the active ring. Shipping builds use one process-global ring.
#[cfg(not(test))]
fn with_ring<R>(f: impl FnOnce(&mut RingState) -> R) -> R {
    let mut guard = ring().lock().unwrap_or_else(|e| e.into_inner());
    f(&mut guard)
}

#[cfg(test)]
thread_local! {
    static TEST_RING: std::cell::RefCell<RingState> = std::cell::RefCell::new(RingState::fresh());
}

/// Tests use a per-thread ring. The process-global ring is written by tests that
/// do not take `TEST_SERIAL` (e.g. `profile::tests`), so cursor assertions on a
/// shared ring are scheduling-dependent under the default parallel runner.
#[cfg(test)]
fn with_ring<R>(f: impl FnOnce(&mut RingState) -> R) -> R {
    TEST_RING.with(|ring| f(&mut ring.borrow_mut()))
}

fn now_ms() -> u64 {
    crate::now_ms()
}

static DROPPED: AtomicU64 = AtomicU64::new(0);
static SINK_DROPPED: AtomicU64 = AtomicU64::new(0);
/// True once the host has injected its `log` callback (register). Cleared to
/// simulate a disconnected sink; the ring keeps serving either way.
static SINK_ATTACHED: AtomicBool = AtomicBool::new(false);

/// Tell the ring whether the host sink is reachable. `register` sets it when
/// the ABI entry carries a `log` callback.
pub(crate) fn set_sink_attached(attached: bool) {
    SINK_ATTACHED.store(attached, Ordering::Relaxed);
}

pub(crate) fn sink_attached() -> bool {
    SINK_ATTACHED.load(Ordering::Relaxed)
}

/// Set the retention level. Below-threshold records are dropped at the source
/// (counted in `dropped`) and never reach the ring or the host sink.
pub(crate) fn set_level(new_level: LogLevel) {
    with_ring(|ring| ring.level = new_level);
    // Keep the `log::` macro path (HostLogger) aligned with the ring.
    log::set_max_level(new_level.to_filter());
}

/// Drop every retained record. The cursor stays monotonic (never reset) so a
/// concurrent `log.get` client cannot mistake a clear for a rewind.
pub(crate) fn clear() {
    with_ring(|ring| ring.records.clear());
}

fn forward(level: LogLevel, line: &str) {
    if !sink_attached() {
        SINK_DROPPED.fetch_add(1, Ordering::Relaxed);
        return;
    }
    let Some(f) = crate::HOST_LOG.get() else {
        return;
    };
    if let Ok(cmsg) = std::ffi::CString::new(line) {
        f(level.as_int(), cmsg.as_ptr());
    }
}

/// Core record push: level-filter, assign cursor, retain, and forward.
fn record(
    level: LogLevel,
    kind: &str,
    message: String,
    host_line: String,
    connection: Option<ConnectionLog>,
    dns: Option<DnsQueryRecord>,
) -> Option<u64> {
    let cursor = with_ring(|ring| {
        if level < ring.level {
            return None;
        }
        let cursor = ring.next;
        ring.next += 1;
        ring.records.push_back(LogRecord {
            cursor,
            ts_ms: now_ms(),
            level: level.as_str().to_string(),
            kind: kind.to_string(),
            message,
            connection,
            dns,
        });
        if ring.records.len() > RING_CAPACITY {
            ring.records.pop_front();
        }
        Some(cursor)
    });
    match cursor {
        Some(c) => {
            forward(level, &host_line);
            Some(c)
        }
        None => {
            DROPPED.fetch_add(1, Ordering::Relaxed);
            None
        }
    }
}

/// Record a plain module log line (used by [`crate::log_message`]).
pub(crate) fn record_message_int(level: c_int, msg: &str) {
    let level = LogLevel::from_int(level);
    let _ = record(
        level,
        KIND_MESSAGE,
        msg.to_string(),
        msg.to_string(),
        None,
        None,
    );
}

/// Record a Todo 8 DNS query record (`kind:"dns"`). The host line is the same
/// `proxy.dns.query` / `proxy.dns.failure` text the Dart side already parses.
pub(crate) fn record_dns(level: LogLevel, rec: &DnsQueryRecord) {
    let json = serde_json::to_string(rec).unwrap_or_default();
    let line = if rec.ok {
        format!("proxy.dns.query {json}")
    } else {
        format!("proxy.dns.failure {json}")
    };
    let message = format!(
        "dns {} {} {} rcode={} resolver={} latencyMs={}",
        rec.domain,
        rec.qtype,
        if rec.ok { "ok" } else { "failed" },
        rec.rcode,
        rec.resolver,
        rec.latency_ms
    );
    let _ = record(level, KIND_DNS, message, line, None, Some(rec.clone()));
}

/// Record a structured connection event (`kind:"connection"`). The host line is
/// `proxy.conn {json}` so the Dart side can parse the schema.
pub(crate) fn record_connection(level: LogLevel, conn: ConnectionLog, action: &str) {
    let json = serde_json::to_string(&conn).unwrap_or_default();
    let line = format!("proxy.conn {json}");
    let message = format!(
        "conn {} {} {} -> {} rule={} bytes={} durationMs={}",
        action, conn.direction, conn.domain, conn.outbound, conn.rule, conn.bytes, conn.duration_ms
    );
    let _ = record(level, KIND_CONNECTION, message, line, Some(conn), None);
}

/// Build a `log.get` page. `since_cursor=0` starts from the oldest retained
/// record. `level_filter` (optional) only returns records at or above it.
pub(crate) fn snapshot(since_cursor: u64, limit: usize, level_filter: Option<LogLevel>) -> Snapshot {
    with_ring(|ring| {
        let limit = limit.min(RING_CAPACITY);
        let records: Vec<LogRecord> = ring
            .records
            .iter()
            .filter(|r| r.cursor > since_cursor)
            .filter(|r| match level_filter {
                None => true,
                Some(min) => LogLevel::parse(&r.level).map(|l| l >= min).unwrap_or(true),
            })
            .take(limit)
            .cloned()
            .collect();
        let next_cursor = records.last().map(|r| r.cursor).unwrap_or(since_cursor);
        let first_cursor = ring.records.front().map(|r| r.cursor).unwrap_or(0);
        Snapshot {
            records,
            cursor: ring.next,
            next_cursor,
            first_cursor,
            retained: ring.records.len(),
            capacity: RING_CAPACITY,
            dropped: DROPPED.load(Ordering::Relaxed),
            sink_dropped: SINK_DROPPED.load(Ordering::Relaxed),
            level: ring.level.as_str().to_string(),
        }
    })
}

/// `log.get` request. Skeleton's `sinceMs` is intentionally replaced by a
/// **cursor** (the task contract).
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GetRequest {
    #[serde(default)]
    pub since_cursor: Option<u64>,
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub level: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SetLevelRequest {
    pub level: String,
}

fn level_error(raw: &str) -> ModuleError {
    ModuleError::new(
        StatusCode::InvalidArgument,
        ERR_LOG_LEVEL_INVALID,
        format!("unknown log level '{raw}' (expected debug|info|warn|error)"),
    )
}

pub(crate) fn get_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let req: GetRequest = if payload.is_empty() {
        GetRequest::default()
    } else {
        serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!("log.get payload must be a JSON object: {e}"))
        })?
    };
    let limit = req.limit.unwrap_or(DEFAULT_LIMIT).min(RING_CAPACITY);
    let level_filter = match req.level.as_deref() {
        None => None,
        Some(s) => Some(LogLevel::parse(s).ok_or_else(|| level_error(s))?),
    };
    let snap = snapshot(req.since_cursor.unwrap_or(0), limit, level_filter);
    crate::ok_data(
        serde_json::to_value(&snap).map_err(|e| ModuleError::internal(e.to_string()))?,
    )
}

pub(crate) fn set_level_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let req: SetLevelRequest = serde_json::from_slice(payload)
        .map_err(|e| ModuleError::invalid_arg(format!("log.set_level requires {{\"level\"}}: {e}")))?;
    let new_level = LogLevel::parse(&req.level).ok_or_else(|| level_error(&req.level))?;
    set_level(new_level);
    crate::ok_data(serde_json::json!({ "ok": true, "level": new_level.as_str() }))
}

pub(crate) fn clear_arm() -> Result<Vec<u8>, ModuleError> {
    clear();
    crate::ok_data(serde_json::json!({ "ok": true }))
}

/// Test-only reset of the ring used by the current test thread.
#[cfg(test)]
pub(crate) fn reset_for_tests() {
    with_ring(|ring| {
        ring.records.clear();
        ring.next = 1;
        ring.level = LogLevel::Info;
    });
    DROPPED.store(0, Ordering::Relaxed);
    SINK_DROPPED.store(0, Ordering::Relaxed);
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::ffi::CStr;
    use std::os::raw::c_char;
    use std::sync::Mutex;

    use crate::TEST_SERIAL as SERIAL;

    static CAPTURED: Mutex<Vec<(i32, String)>> = Mutex::new(Vec::new());

    extern "C" fn capture(level: c_int, msg: *const c_char) {
        if msg.is_null() {
            return;
        }
        let s = unsafe { CStr::from_ptr(msg) }.to_string_lossy().into_owned();
        if let Ok(mut v) = CAPTURED.lock() {
            v.push((level, s));
        }
    }

    fn captured() -> Vec<(i32, String)> {
        CAPTURED.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn cursors(snap: &Snapshot) -> Vec<u64> {
        snap.records.iter().map(|r| r.cursor).collect()
    }

    /// Happy QA: emit > N records → the buffer keeps exactly the last N and the
    /// cursors stay monotonic.
    #[test]
    fn ring_keeps_last_n_with_monotonic_cursors() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        set_level(LogLevel::Debug);
        let total = RING_CAPACITY + 50;
        for i in 0..total {
            record_message_int(1, &format!("m{i}"));
        }
        let snap = snapshot(0, RING_CAPACITY, None);
        assert_eq!(snap.retained, RING_CAPACITY, "buffer is bounded to N");
        assert_eq!(snap.records.len(), RING_CAPACITY);
        assert_eq!(snap.first_cursor, 51, "oldest 50 evicted");
        assert_eq!(snap.records.first().unwrap().cursor, 51);
        assert_eq!(snap.records.last().unwrap().cursor, total as u64);
        assert_eq!(snap.cursor, total as u64 + 1, "next cursor never reused");
        for w in snap.records.windows(2) {
            assert!(w[0].cursor < w[1].cursor, "cursors must increase");
        }
        reset_for_tests();
    }

    /// Happy QA: `log.get` paginates by cursor and a drained page returns the
    /// same cursor back (no rewind).
    #[test]
    fn get_paginates_by_cursor() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        set_level(LogLevel::Debug);
        for i in 0..10 {
            record_message_int(1, &format!("p{i}"));
        }
        let page1 = snapshot(0, 3, None);
        assert_eq!(cursors(&page1), vec![1, 2, 3]);
        assert_eq!(page1.next_cursor, 3);

        let page2 = snapshot(page1.next_cursor, 3, None);
        assert_eq!(cursors(&page2), vec![4, 5, 6]);

        let page3 = snapshot(page2.next_cursor, 100, None);
        assert_eq!(cursors(&page3), vec![7, 8, 9, 10]);
        assert_eq!(page3.next_cursor, 10);

        let page4 = snapshot(page3.next_cursor, 100, None);
        assert!(page4.records.is_empty());
        assert_eq!(page4.next_cursor, 10, "drained page does not rewind");
        reset_for_tests();
    }

    /// `log.set_level` filters both retention and `log.get(level=...)`.
    #[test]
    fn set_level_filters_records() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        set_level(LogLevel::Warn);
        record_message_int(0, "debug-drop");
        record_message_int(1, "info-drop");
        record_message_int(2, "warn-keep");
        record_message_int(3, "error-keep");

        let snap = snapshot(0, 100, None);
        assert_eq!(snap.records.len(), 2);
        assert_eq!(snap.records[0].level, "warn");
        assert_eq!(snap.records[1].level, "error");
        assert!(snap.dropped >= 2, "below-threshold records counted");

        let only_err = snapshot(0, 100, Some(LogLevel::Error));
        assert_eq!(only_err.records.len(), 1);
        assert_eq!(only_err.records[0].message, "error-keep");

        set_level(LogLevel::Debug);
        record_message_int(0, "debug-keep");
        assert!(snapshot(0, 100, None)
            .records
            .iter()
            .any(|r| r.message == "debug-keep"));
        reset_for_tests();
    }

    /// A `connection` record is structured and carries no secret fields.
    #[test]
    fn connection_record_is_structured_and_has_no_secrets() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        set_level(LogLevel::Debug);
        let conn = ConnectionLog {
            id: "c1".into(),
            direction: "in".into(),
            domain: "example.com".into(),
            outbound: "proxy-a".into(),
            rule: "DOMAIN-SUFFIX".into(),
            rule_payload: "example.com".into(),
            network: "tcp".into(),
            src: "10.10.0.2:40000".into(),
            dst: "93.184.216.34:443".into(),
            upload_bytes: 10,
            download_bytes: 20,
            bytes: 30,
            duration_ms: 5,
            error: None,
        };
        record_connection(LogLevel::Info, conn, "close");
        let snap = snapshot(0, 10, None);
        assert_eq!(snap.records.len(), 1);
        let rec = &snap.records[0];
        assert_eq!(rec.kind, "connection");
        let c = rec.connection.as_ref().expect("structured connection payload");
        assert_eq!(c.bytes, 30);
        assert_eq!(c.rule_payload, "example.com");
        assert_eq!(c.upload_bytes + c.download_bytes, c.bytes);
        let json = serde_json::to_string(rec).unwrap().to_ascii_lowercase();
        for forbidden in ["password", "uuid", "secret", "passwd", "token", "psk", "://"] {
            assert!(
                !json.contains(forbidden),
                "connection records must not leak '{forbidden}': {json}"
            );
        }
        reset_for_tests();
    }

    /// Failure QA: when the host sink goes away, logs are dropped (counted) but
    /// the module keeps running, the ring still serves `log.get`, and nothing
    /// panics.
    #[test]
    fn disconnected_sink_drops_logs_without_panicking() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        set_level(LogLevel::Debug);
        // Wire the exact callback the ABI passes in GStoreModuleEntry.log.
        let _ = crate::HOST_LOG.set(capture);
        set_sink_attached(true);
        CAPTURED.lock().unwrap_or_else(|e| e.into_inner()).clear();

        record_message_int(1, "while-connected");
        assert!(
            captured().iter().any(|(_, m)| m == "while-connected"),
            "connected sink receives the line"
        );

        let before = snapshot(0, RING_CAPACITY, None).sink_dropped;
        set_sink_attached(false); // simulate a disconnected LogBridge sink
        record_message_int(1, "while-disconnected");
        let snap = snapshot(0, RING_CAPACITY, None);
        assert!(
            snap.records.iter().any(|r| r.message == "while-disconnected"),
            "ring keeps serving after the sink is gone"
        );
        assert!(snap.sink_dropped > before, "dropped records are counted");
        assert!(
            !captured().iter().any(|(_, m)| m == "while-disconnected"),
            "nothing forwarded to a disconnected sink"
        );
        set_sink_attached(true);
        reset_for_tests();
    }

    /// The module's `log::` macros reach the host through
    /// `gstore_contract::logging::attach_host_logger` (architecture §6.8).
    #[test]
    fn gstore_contract_host_logger_forwards_log_macro() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let entry = crate::GStoreModuleEntry {
            abi_version: crate::GSTORE_MODULE_ABI_VERSION,
            entry_size: std::mem::size_of::<crate::GStoreModuleEntry>() as u32,
            log: Some(capture),
            alloc: None,
            free: None,
            emit_event: None,
            context: std::ptr::null_mut(),
            protect_fd: None,
        };
        let _ = gstore_contract::logging::attach_host_logger(
            &entry,
            log::LevelFilter::Debug,
        );
        CAPTURED.lock().unwrap_or_else(|e| e.into_inner()).clear();
        log::info!("proxy log macro line");
        assert!(
            captured()
                .iter()
                .any(|(level, m)| *level == 1 && m.contains("proxy log macro line")),
            "log! macro line must reach the host callback"
        );
    }
}
