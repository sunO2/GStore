//! Per-request timeline model + bounded ring (Todo 1 of the request collector).
//!
//! This module is the **in-memory near-view** of the per-request timeline. The
//! durable, authoritative copy (SQLite, 7 days / ≤50k rows, cap-first) arrives
//! in a later todo; this file only owns the model, the bounded ring, the
//! monotonic cursor and the filter/snapshot contract.
//!
//! ## Model / store paradigm
//!
//! Mirrors [`crate::stats`] and [`crate::logging`]:
//!  * a `RequestStore` owns the data and a process-global instance backs the
//!    module; tests get a per-thread store so they never race the shipping one.
//!  * `record_id` is a **monotonic, never-reused** primary key. A reused
//!    `connId` (meow's per-connection id is **not** unique over time) mints a
//!    **new** record — it never overwrites an older one.
//!  * the ring is bounded by [`REQUEST_RING_CAP`]; over capacity the **oldest**
//!    record is evicted and the `recordId → deque index` map is kept in sync.
//!  * `nextCursor` is the **high-water mark** (the last `recordId` ever issued)
//!    and is deliberately **not reclaimed** by eviction or by a clear, so a
//!    polling client's cursor can never move backwards.
//!
//! ## Approximate timestamps
//!
//! meow's projection is a **diff sampled on a ticker** (500 ms), so
//! `closeTsMs`/`durationMs` are derived from sampling instants, not the exact
//! socket close time: they are APPROXIMATE by construction. Flows that open and
//! close between two ticks are invisible (an accepted, documented limitation).
#![allow(dead_code)] // T1 foundation: consumed by later todos (capture, dispatch, persist).

use std::collections::{HashMap, HashSet, VecDeque};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use gstore_contract::error::{ModuleError, StatusCode};
use serde::{Deserialize, Serialize};

use crate::conn::ConnRecord;

/// Hard cap on retained in-memory request records. Over capacity the oldest is
/// evicted first (deterministic: the deque is in insertion / `recordId` order).
pub(crate) const REQUEST_RING_CAP: usize = 4096;

/// Hard cap on the durable request timeline (`proxy_requests.db`). Prune is
/// **cap-first**: rows beyond this many are deleted oldest-`openTsMs`-first,
/// THEN rows older than [`REQUEST_RETENTION_MS`] are deleted.
pub(crate) const REQUEST_MAX_ROWS: usize = 50_000;
/// Rolling persistence window for the durable timeline (7 days).
pub(crate) const REQUEST_RETENTION_MS: u64 = 7 * 24 * 60 * 60 * 1000;
/// Durable flush spacing. Writes are batched in one transaction at most this
/// often — never per-close / per-packet.
pub(crate) const REQUEST_PERSIST_INTERVAL_MS: u64 = 5000;
/// Bound on the pending-flush queue. When a burst fills it the next flush
/// persists the whole (bounded) ring instead of only the queued records, so a
/// burst can never lose data *and* memory stays bounded.
pub(crate) const REQUEST_FLUSH_QUEUE_CAP: usize = 1024;
/// Explicit SQLite busy timeout: a concurrent writer waits instead of failing
/// immediately with `SQLITE_BUSY`.
const REQUEST_BUSY_TIMEOUT_MS: u64 = 5000;

/// `uidState` values (see `API.md`: three explicit states, never a bare `null`).
pub(crate) const UID_STATE_KNOWN: &str = "known";
pub(crate) const UID_STATE_PENDING: &str = "pending";
pub(crate) const UID_STATE_UNKNOWN: &str = "unknown";

/// `closeReason` values.
pub(crate) const CLOSE_REASON_OPEN: &str = "open";
pub(crate) const CLOSE_REASON_CLOSED: &str = "closed";
pub(crate) const CLOSE_REASON_STALE: &str = "stale";

/// Hard cap on the `stale_live` suppression set. Over capacity the entry with
/// the oldest `openTsMs` is evicted and `dropped` increments, so a long churn of
/// cap-evicted-yet-live flows can never grow memory without bound.
pub(crate) const STALE_LIVE_CAP: usize = 4096;

/// Minimum spacing between `proxy.request` dirty signals (≥1s throttle, same
/// paradigm as `proxy.stats`). The signal is payload-free: a client pulls
/// `requests.get` on receipt.
pub(crate) const MIN_EMIT_INTERVAL_MS: u64 = 1000;

/// How long a UID query may stay `pending` before TTL resolves it to `unknown`.
pub(crate) const UID_QUERY_TTL_MS: u64 = 30_000;
/// The only protocol the collector produces and the UID gate supports. UDP is
/// out of scope: meow's projection tracks TCP only.
pub(crate) const UID_PROTOCOL_TCP: &str = "tcp";
/// Module → host UID query event. Consumed by the host, never forwarded into the
/// Dart event ring (`API.md §4`).
pub(crate) const EVT_UID_QUERY: &str = "proxy.uid.query";

/// High-bit namespace reserved for capture-origin UID correlation ids. The host
/// echoes `recordId` opaquely (Kotlin/JNI never see it), so an id in this range
/// is partitioned to the capture registry instead of the request store.
pub(crate) const CAPTURE_UID_ID_BASE: u64 = 1 << 63;

/// Three-state UID attribution; the value is always explicit (never a bare null).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum UidState {
    Known,
    Pending,
    Unknown,
}

impl UidState {
    fn as_str(self) -> &'static str {
        match self {
            UidState::Known => UID_STATE_KNOWN,
            UidState::Pending => UID_STATE_PENDING,
            UidState::Unknown => UID_STATE_UNKNOWN,
        }
    }
}

/// One module → host UID query, mirroring the host's `UidQueryHost` wire shape.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct UidQuery {
    pub record_id: u64,
    pub protocol: String,
    pub src_ip: String,
    pub src_port: u16,
    pub dst_ip: String,
    pub dst_port: u16,
}

/// One host → module UID answer (`uid.result`). `uid == None` or a negative
/// value is a definitive `unknown`; a non-negative value is the resolved owner.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct UidAnswer {
    pub record_id: u64,
    #[serde(default)]
    pub uid: Option<i64>,
    #[serde(default)]
    pub packages: Vec<String>,
}

impl UidAnswer {
    pub(crate) fn resolved_uid(&self) -> Option<u32> {
        match self.uid {
            Some(v) if v >= 0 && v <= u32::MAX as i64 => Some(v as u32),
            _ => None,
        }
    }
}

/// Pluggable in-process UID resolver (default: none). Production relies on the
/// host (`proxy.uid.query` → `uid.result`); a registered resolver lets the
/// module resolve synchronously through the same backfill path.
pub(crate) trait UidResolver: Send + Sync {
    fn resolve(&self, reqs: &[UidQuery]) -> Vec<UidAnswer>;
}

static UID_RESOLVER: std::sync::OnceLock<std::sync::Mutex<Option<Box<dyn UidResolver>>>> =
    std::sync::OnceLock::new();

/// Install (or clear) the process-wide UID resolver seam. Default is none.
pub(crate) fn set_uid_resolver(resolver: Option<Box<dyn UidResolver>>) {
    *resolver_cell().lock().unwrap_or_else(|e| e.into_inner()) = resolver;
}

fn resolver_cell() -> &'static std::sync::Mutex<Option<Box<dyn UidResolver>>> {
    UID_RESOLVER.get_or_init(|| std::sync::Mutex::new(None))
}

fn with_resolver<R>(f: impl FnOnce(&dyn UidResolver) -> R) -> Option<R> {
    let guard = resolver_cell().lock().unwrap_or_else(|e| e.into_inner());
    guard.as_ref().map(|r| f(r.as_ref()))
}

// ── Capture-origin UID correlation (C3) ──────────────────────────────────────

/// Monotonic allocator for [`CAPTURE_UID_ID_BASE`]-rooted correlation ids. Ids
/// are never reused, so a stale answer can never alias a later query.
static NEXT_CAPTURE_UID_ID: AtomicU64 = AtomicU64::new(CAPTURE_UID_ID_BASE);

/// Bounded registry of in-flight capture UID lookups (`recordId → reply`). Full
/// means the lookup fails safe (`Unknown`) rather than growing or queueing.
static CAPTURE_UID_PENDING: OnceLock<Mutex<HashMap<u64, tokio::sync::oneshot::Sender<UidAnswer>>>> =
    OnceLock::new();

fn capture_uid_pending() -> &'static Mutex<HashMap<u64, tokio::sync::oneshot::Sender<UidAnswer>>> {
    CAPTURE_UID_PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Reserve a correlation id and its reply channel, or `None` when the bounded
/// registry is full. The id travels with the query and the host returns it
/// unchanged.
pub(crate) fn register_capture_uid() -> Option<(u64, tokio::sync::oneshot::Receiver<UidAnswer>)> {
    let mut guard = capture_uid_pending()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if guard.len() >= crate::limits::CAPTURE_UID_INFLIGHT_CAP {
        return None;
    }
    let record_id = NEXT_CAPTURE_UID_ID.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = tokio::sync::oneshot::channel();
    guard.insert(record_id, tx);
    Some((record_id, rx))
}

/// Release a capture correlation slot (timeout / abandoned future). A later
/// answer for the id then finds no sender and is dropped.
pub(crate) fn deregister_capture_uid(record_id: u64) {
    capture_uid_pending()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&record_id);
}

/// Emit one capture-origin query batch through the same host lane `tick` uses.
pub(crate) fn emit_capture_uid_query(instance_id: u64, query: &UidQuery) {
    emit_uid_query(instance_id, std::slice::from_ref(query));
}

/// A pending UID query keyed by `recordId`, with its TTL deadline.
#[derive(Clone, Debug)]
pub(crate) struct UidPendingEntry {
    query: UidQuery,
    deadline_ms: u64,
}

/// An answer that arrived before its record existed, with its TTL deadline.
#[derive(Clone, Debug)]
pub(crate) struct UidEarlyEntry {
    answer: UidAnswer,
    expires_ms: u64,
}

/// Best-effort split of a captured `"host:port"` string. Handles the bracketed
/// IPv6 form (`"[::1]:443"`), plain IPv4 (`"1.2.3.4:5555"`) and a bare IP
/// (port 0); an unparseable string is returned whole. Never panics.
fn split_host_port(raw: &str) -> (String, u16) {
    let raw = raw.trim();
    if raw.is_empty() {
        return (String::new(), 0);
    }
    if let Ok(addr) = raw.parse::<std::net::SocketAddr>() {
        return (addr.ip().to_string(), addr.port());
    }
    if let Ok(ip) = raw.parse::<std::net::IpAddr>() {
        return (ip.to_string(), 0);
    }
    (raw.to_string(), 0)
}

/// Fill a record from a UID answer: a resolved uid flips it `known`; a
/// null/negative uid is a definitive `unknown` (never a fabricated owner).
fn apply_answer(r: &mut RequestRecord, a: &UidAnswer) {
    match a.resolved_uid() {
        Some(uid) => {
            r.uid = Some(uid);
            r.packages = a.packages.clone();
            r.uid_state = UID_STATE_KNOWN.to_string();
        }
        None => {
            r.uid = None;
            r.packages.clear();
            r.uid_state = UID_STATE_UNKNOWN.to_string();
        }
    }
}

/// Why a request record is being taken out of its live window.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CloseReason {
    /// The flow truly left meow's live table: the single terminal transition.
    Closed,
    /// The flow left the bounded projection while still live in meow: NOT a
    /// close (no `closeTsMs`/`durationMs`), only a suppression marker.
    Stale,
}

impl CloseReason {
    fn as_str(self) -> &'static str {
        match self {
            CloseReason::Closed => CLOSE_REASON_CLOSED,
            CloseReason::Stale => CLOSE_REASON_STALE,
        }
    }
}

/// One bounded `stale_live` entry: the record left the projection but is still
/// live in meow. `open_ts_ms` orders eviction; `record_id` keeps the pairing.
#[derive(Clone, Debug)]
pub(crate) struct StaleEntry {
    pub(crate) record_id: u64,
    pub(crate) open_ts_ms: u64,
}

/// One request (flow) on the timeline.
///
/// Serialized with camelCase keys; the field names are part of the API contract
/// (`API.md`, Todo 5) and must stay stable.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RequestRecord {
    /// Monotonic, never reused. The ring key today and the DB primary key later.
    pub record_id: u64,
    /// meow's connection id. **Not unique**: one `connId` observed open/close
    /// twice yields two records with distinct `recordId`s (id reuse is a NEW
    /// record, never an overwrite).
    pub conn_id: String,
    pub open_ts_ms: u64,
    /// APPROXIMATE: derived from the sampling tick at which the close was
    /// observed, not the exact socket close instant. `null` while still open.
    pub close_ts_ms: Option<u64>,
    /// APPROXIMATE: `closeTsMs - openTsMs` when closed; `null` while still open.
    /// Derived from sampling ticks, so it carries up to one tick of error.
    pub duration_ms: Option<u64>,
    pub domain: String,
    /// `false` when the domain was unavailable; `domain` then holds the IP.
    pub domain_known: bool,
    pub dst_ip: String,
    pub dst_port: u16,
    pub src: String,
    pub network: String,
    pub uid: Option<u32>,
    pub packages: Vec<String>,
    /// `"known"` | `"pending"` | `"unknown"` ([`UID_STATE_KNOWN`] and friends).
    pub uid_state: String,
    pub rule: String,
    pub rule_payload: String,
    pub outbound: String,
    pub upload_bytes: u64,
    pub download_bytes: u64,
    /// `"closed"` | `"stale"` | `"open"` ([`CLOSE_REASON_OPEN`] and friends).
    pub close_reason: String,
}

/// Projection of a [`ConnRecord`] into a [`RequestRecord`] at the capture
/// chokepoint. `dstIp`/`dstPort`/`network` come straight from the captured
/// record (T3); domain attribution reuses [`crate::stats::resolve_domain`] so it
/// matches the stats aggregate exactly, and UID attribution lands in T11.
/// `openTsMs` is the flow's meow start time so `durationMs` approximates the
/// real lifetime (sampled on the tick).
fn project(rec: &ConnRecord, now_ms: u64) -> RequestRecord {
    let open_ts_ms = if rec.started_at_ms == 0 {
        now_ms
    } else {
        rec.started_at_ms
    };
    let (domain, domain_known) = crate::stats::resolve_domain(rec);
    RequestRecord {
        record_id: 0,
        conn_id: rec.id.clone(),
        open_ts_ms,
        close_ts_ms: None,
        duration_ms: None,
        domain_known,
        domain,
        dst_ip: rec.dst_ip.clone(),
        dst_port: rec.dst_port,
        src: rec.src.clone(),
        network: rec.network.clone(),
        uid: None,
        packages: Vec::new(),
        uid_state: UID_STATE_UNKNOWN.to_string(),
        rule: rec.rule.clone(),
        rule_payload: rec.rule_payload.clone(),
        outbound: rec.outbound.clone(),
        upload_bytes: rec.upload_bytes.max(0) as u64,
        download_bytes: rec.download_bytes.max(0) as u64,
        close_reason: CLOSE_REASON_OPEN.to_string(),
    }
}

/// Bounded in-memory ring of [`RequestRecord`]s plus its cursor bookkeeping.
pub(crate) struct RequestStore {
    pub(crate) records: VecDeque<RequestRecord>,
    /// `recordId → index within `records``. Rebuilt after an eviction so it can
    /// never go stale.
    pub(crate) by_record_id: HashMap<u64, usize>,
    /// Next `recordId` to assign. Starts at 1 and only moves forward.
    pub(crate) next_record_id: u64,
    /// Highest `recordId` ever issued (high-water mark). `requests.get` clients
    /// pass this back as `cursor`; it is never reclaimed by clear or eviction.
    pub(crate) next_cursor: u64,
    pub(crate) cap: usize,
    /// Records discarded before insertion (reserved for later todos).
    pub(crate) dropped: u64,
    /// Records dropped because the ring was over capacity.
    pub(crate) evicted: u64,
    /// `openTsMs` of the oldest retained record, or 0 when the ring is empty.
    pub(crate) window_start_ms: u64,
    /// `connId → recordId` of the record that currently represents this
    /// connection (open, or stale-but-still-live). Removed on the terminal
    /// transition so a reused `connId` mints a fresh record.
    pub(crate) active_by_conn: HashMap<String, u64>,
    /// Suppression set: `connId`s that left the bounded projection while still
    /// live in meow. Bounded by `stale_live_cap`.
    pub(crate) stale_live: HashMap<String, StaleEntry>,
    pub(crate) stale_live_cap: usize,
    /// Ids that re-entered the projection while still live (no new record).
    pub(crate) reentered: u64,
    /// `recordId`s created or changed since the last dirty-signal emit. Bounded
    /// by `cap`; beyond it `dirty_overflow` keeps counting so the signal still
    /// fires, without growing memory with connection churn.
    pub(crate) dirty: HashSet<u64>,
    pub(crate) dirty_overflow: u64,
    /// External (capture) changes folded into the same `proxy.request` signal.
    /// Bumped by [`crate::captures`]; the payload stays record-free.
    pub(crate) external_dirty: u64,
    /// `now_ms` of the last emitted `proxy.request` dirty signal.
    pub(crate) last_emit_ms: u64,
    /// Monotonic sequence number of the dirty signal (`seq`).
    pub(crate) emit_seq: u64,
    /// Durable timeline, when a data dir was configured. `None` is memory-only.
    pub(crate) db: Option<Persist>,
    /// Bounded queue of records created/changed since the last flush.
    pub(crate) pending: VecDeque<RequestRecord>,
    /// Set when `pending` overflowed its cap: the next flush persists the whole
    /// (bounded) ring so the burst cannot lose data.
    pub(crate) pending_overflow: bool,
    /// `now_ms` of the last durable flush (0 = never), for the 5s gate.
    pub(crate) last_persist_ms: u64,
    /// Count of records removed by a durable prune (cap-first or 7-day window).
    pub(crate) lost_records: u64,
    /// Effective read floor (`now - REQUEST_RETENTION_MS`) once the durable sink
    /// is configured; `windowStartMs` reports this boundary.
    pub(crate) retention_floor_ms: Option<u64>,
    /// `recordId → pending UID query` (bounded by `uid_pending_cap`, ~30s TTL).
    pub(crate) uid_pending: HashMap<u64, UidPendingEntry>,
    /// Newly opened record ids not yet gated by the mode/protocol rule.
    pub(crate) uid_unprocessed: VecDeque<u64>,
    /// UID answers that arrived before their record existed.
    pub(crate) uid_early: HashMap<u64, UidEarlyEntry>,
    /// FIFO order of `uid_early` keys, for bounded eviction.
    pub(crate) uid_early_order: VecDeque<u64>,
    pub(crate) uid_pending_cap: usize,
    pub(crate) uid_early_cap: usize,
}

impl RequestStore {
    pub(crate) fn fresh() -> Self {
        Self {
            records: VecDeque::with_capacity(REQUEST_RING_CAP),
            by_record_id: HashMap::new(),
            next_record_id: 1,
            next_cursor: 0,
            cap: REQUEST_RING_CAP,
            dropped: 0,
            evicted: 0,
            window_start_ms: 0,
            active_by_conn: HashMap::new(),
            stale_live: HashMap::new(),
            stale_live_cap: STALE_LIVE_CAP,
            reentered: 0,
            dirty: HashSet::new(),
            dirty_overflow: 0,
            external_dirty: 0,
            last_emit_ms: 0,
            emit_seq: 0,
            db: None,
            pending: VecDeque::new(),
            pending_overflow: false,
            last_persist_ms: 0,
            lost_records: 0,
            retention_floor_ms: None,
            uid_pending: HashMap::new(),
            uid_unprocessed: VecDeque::new(),
            uid_early: HashMap::new(),
            uid_early_order: VecDeque::new(),
            uid_pending_cap: crate::limits::UID_PENDING_CAP,
            uid_early_cap: crate::limits::UID_EARLY_RESULTS_CAP,
        }
    }

    /// Append `record`, assigning it the next monotonic `record_id` (the value
    /// already in `record.record_id` is ignored). When the ring is over
    /// capacity the oldest record is evicted and counted. Returns the assigned
    /// `record_id`.
    pub(crate) fn push(&mut self, mut record: RequestRecord) -> u64 {
        let id = self.next_record_id;
        self.next_record_id += 1;
        self.next_cursor = id;
        record.record_id = id;
        if let Some(early) = self.uid_early.remove(&id) {
            apply_answer(&mut record, &early.answer);
        }
        self.by_record_id.insert(id, self.records.len());
        self.records.push_back(record);
        while self.records.len() > self.cap {
            let Some(front) = self.records.pop_front() else {
                break;
            };
            self.by_record_id.remove(&front.record_id);
            self.evicted += 1;
            // The deque shifted, so every stored index is off by one.
            self.reindex();
        }
        self.window_start_ms = self.records.front().map(|r| r.open_ts_ms).unwrap_or(0);
        self.enqueue_uid_unprocessed(id);
        self.mark_dirty(id);
        id
    }

    /// Drop every retained record. The cursor and the id sequence stay monotonic
    /// (never reset), so a concurrent client cannot mistake a clear for a rewind.
    pub(crate) fn clear(&mut self) {
        self.records.clear();
        self.by_record_id.clear();
        self.active_by_conn.clear();
        self.stale_live.clear();
        self.dirty.clear();
        self.dirty_overflow = 0;
        self.external_dirty = 0;
        self.window_start_ms = 0;
        self.pending.clear();
        self.pending_overflow = false;
        self.uid_pending.clear();
        self.uid_unprocessed.clear();
        self.uid_early.clear();
        self.uid_early_order.clear();
    }

    /// Open (or revive) the record for `rec` at the capture chokepoint. A
    /// `connId` that already has a non-terminal record re-uses it — a stale flow
    /// re-entering the projection must not mint a duplicate open — and the
    /// re-entry is counted. Returns the record's `recordId`.
    pub(crate) fn open_record(&mut self, rec: &ConnRecord, now_ms: u64) -> u64 {
        if let Some(&rid) = self.active_by_conn.get(&rec.id) {
            if let Some(idx) = self.by_record_id.get(&rid).copied() {
                if self.records[idx].close_ts_ms.is_none() {
                    if self.records[idx].close_reason == CLOSE_REASON_STALE {
                        self.records[idx].close_reason = CLOSE_REASON_OPEN.to_string();
                        self.reentered += 1;
                        self.mark_dirty(rid);
                    }
                    return rid;
                }
            }
            self.active_by_conn.remove(&rec.id);
            self.stale_live.remove(&rec.id);
        }
        let record = project(rec, now_ms);
        let id = self.push(record);
        self.active_by_conn.insert(rec.id.clone(), id);
        id
    }

    /// Mark `conn_id`'s record stale: it left the projection but is still live in
    /// meow. NOT terminal — `closeTsMs`/`durationMs` stay `None`. Idempotent.
    pub(crate) fn mark_stale(&mut self, conn_id: &str) {
        let Some(&rid) = self.active_by_conn.get(conn_id) else {
            return;
        };
        let Some(idx) = self.by_record_id.get(&rid).copied() else {
            self.active_by_conn.remove(conn_id);
            return;
        };
        let r = &mut self.records[idx];
        if r.close_ts_ms.is_some() {
            return;
        }
        let changed = r.close_reason != CLOSE_REASON_STALE;
        if changed {
            r.close_reason = CLOSE_REASON_STALE.to_string();
        }
        let open_ts_ms = r.open_ts_ms;
        self.insert_stale(conn_id, rid, open_ts_ms);
        if changed {
            self.mark_dirty(rid);
        }
    }

    fn insert_stale(&mut self, conn_id: &str, record_id: u64, open_ts_ms: u64) {
        if self.stale_live.contains_key(conn_id) {
            return;
        }
        self.stale_live
            .insert(conn_id.to_string(), StaleEntry { record_id, open_ts_ms });
        while self.stale_live.len() > self.stale_live_cap {
            let Some(oldest) = self
                .stale_live
                .iter()
                .min_by_key(|(_, e)| e.open_ts_ms)
                .map(|(k, _)| k.clone())
            else {
                break;
            };
            self.stale_live.remove(&oldest);
            self.dropped += 1;
        }
    }

    /// Write the single terminal transition for `conn_id`'s record. A record that
    /// is already terminal (or no longer retained) is a no-op, so a repeated
    /// close can never overwrite time/duration.
    pub(crate) fn finalize(&mut self, conn_id: &str, now_ms: u64) -> bool {
        let Some(&rid) = self.active_by_conn.get(conn_id) else {
            return false;
        };
        let Some(idx) = self.by_record_id.get(&rid).copied() else {
            self.active_by_conn.remove(conn_id);
            self.stale_live.remove(conn_id);
            return false;
        };
        let r = &mut self.records[idx];
        if r.close_ts_ms.is_some() {
            self.active_by_conn.remove(conn_id);
            self.stale_live.remove(conn_id);
            return false;
        }
        r.close_ts_ms = Some(now_ms);
        r.duration_ms = Some(now_ms.saturating_sub(r.open_ts_ms));
        r.close_reason = CLOSE_REASON_CLOSED.to_string();
        self.active_by_conn.remove(conn_id);
        self.stale_live.remove(conn_id);
        self.mark_dirty(rid);
        true
    }

    /// Finalize every stale id that `is_live` reports as gone from meow's live
    /// table. Returns how many terminals were written.
    pub(crate) fn finalize_departed(
        &mut self,
        now_ms: u64,
        is_live: impl Fn(&str) -> bool,
    ) -> u64 {
        let departed: Vec<String> = self
            .stale_live
            .keys()
            .filter(|id| !is_live(id))
            .cloned()
            .collect();
        let mut closed = 0;
        for id in departed {
            if self.finalize(&id, now_ms) {
                closed += 1;
            }
        }
        closed
    }

    /// Finalize every active record (open and stale). `close_all` semantics.
    pub(crate) fn close_all_records(&mut self, now_ms: u64) -> u64 {
        let active: Vec<String> = self.active_by_conn.keys().cloned().collect();
        let mut closed = 0;
        for id in active {
            if self.finalize(&id, now_ms) {
                closed += 1;
            }
        }
        self.stale_live.clear();
        closed
    }

    fn set_uid_state(&mut self, id: u64, state: UidState) {
        let Some(idx) = self.by_record_id.get(&id).copied() else {
            return;
        };
        if self.records[idx].uid_state != state.as_str() {
            self.records[idx].uid_state = state.as_str().to_string();
            self.mark_dirty(id);
        }
    }

    fn enqueue_uid_unprocessed(&mut self, id: u64) {
        if self.uid_unprocessed.len() >= self.cap {
            self.uid_unprocessed.pop_front();
        }
        self.uid_unprocessed.push_back(id);
    }

    fn evict_oldest_pending(&mut self) {
        let Some(oldest) = self.uid_pending.keys().copied().min() else {
            return;
        };
        self.uid_pending.remove(&oldest);
        self.set_uid_state(oldest, UidState::Unknown);
    }

    /// Gate newly opened records by the mode/protocol rule and return every
    /// currently-pending query. Only `Mode::Vpn` + TCP becomes `pending`; every
    /// other mode or protocol stays `unknown` with no query. Expired pending
    /// entries resolve to `unknown`.
    pub(crate) fn gate_uid(&mut self, mode: crate::ProxyMode, now_ms: u64) -> Vec<UidQuery> {
        let expired: Vec<u64> = self
            .uid_pending
            .iter()
            .filter(|(_, e)| e.deadline_ms <= now_ms)
            .map(|(id, _)| *id)
            .collect();
        for id in expired {
            self.uid_pending.remove(&id);
            self.set_uid_state(id, UidState::Unknown);
        }
        self.prune_early(now_ms);

        let to_gate: Vec<u64> = self.uid_unprocessed.drain(..).collect();
        for id in to_gate {
            let Some(idx) = self.by_record_id.get(&id).copied() else {
                continue;
            };
            let (state, query) = {
                let r = &self.records[idx];
                let (src_ip, src_port) = split_host_port(&r.src);
                (
                    r.uid_state.clone(),
                    UidQuery {
                        record_id: r.record_id,
                        protocol: r.network.clone(),
                        src_ip,
                        src_port,
                        dst_ip: r.dst_ip.clone(),
                        dst_port: r.dst_port,
                    },
                )
            };
            if state != UID_STATE_UNKNOWN {
                continue;
            }
            if !matches!(mode, crate::ProxyMode::Vpn) || query.protocol != UID_PROTOCOL_TCP {
                continue;
            }
            if self.uid_pending.len() >= self.uid_pending_cap {
                self.evict_oldest_pending();
            }
            self.uid_pending.insert(
                id,
                UidPendingEntry {
                    query,
                    deadline_ms: now_ms.saturating_add(UID_QUERY_TTL_MS),
                },
            );
            self.set_uid_state(id, UidState::Pending);
        }

        self.uid_pending.values().map(|e| e.query.clone()).collect()
    }

    /// Apply UID answers: a matching retained record is filled and flips to
    /// `known`/`unknown`; an answer for a record that does not exist yet is
    /// buffered as an early result. Returns how many records were filled.
    pub(crate) fn apply_uid_answers(&mut self, answers: &[UidAnswer], now_ms: u64) -> usize {
        let mut applied = 0;
        for a in answers {
            match self.by_record_id.get(&a.record_id).copied() {
                Some(idx) => {
                    apply_answer(&mut self.records[idx], a);
                    self.uid_pending.remove(&a.record_id);
                    self.mark_dirty(a.record_id);
                    applied += 1;
                }
                None => self.buffer_early(a, now_ms),
            }
        }
        applied
    }

    fn buffer_early(&mut self, a: &UidAnswer, now_ms: u64) {
        let id = a.record_id;
        if self.uid_early.remove(&id).is_none() {
            self.uid_early_order.push_back(id);
            while self.uid_early.len() >= self.uid_early_cap {
                let Some(old) = self.uid_early_order.pop_front() else {
                    break;
                };
                if self.uid_early.remove(&old).is_some() {
                    break;
                }
            }
        }
        self.uid_early.insert(
            id,
            UidEarlyEntry {
                answer: a.clone(),
                expires_ms: now_ms.saturating_add(UID_QUERY_TTL_MS),
            },
        );
    }

    fn prune_early(&mut self, now_ms: u64) {
        let expired: Vec<u64> = self
            .uid_early
            .iter()
            .filter(|(_, e)| e.expires_ms <= now_ms)
            .map(|(id, _)| *id)
            .collect();
        for id in expired {
            self.uid_early.remove(&id);
        }
    }

    /// Rebuild the `recordId → index` map from the current deque.
    fn reindex(&mut self) {
        self.by_record_id.clear();
        for (i, r) in self.records.iter().enumerate() {
            self.by_record_id.insert(r.record_id, i);
        }
    }

    /// Record `id` as created-or-changed for the next dirty-signal emit. Bounded
    /// by `cap`; beyond it `dirty_overflow` still makes the signal fire.
    fn mark_dirty(&mut self, id: u64) {
        if self.dirty.len() < self.cap {
            self.dirty.insert(id);
        } else if !self.dirty.contains(&id) {
            self.dirty_overflow += 1;
        }
        self.enqueue_pending(id);
    }

    /// Fold an external producer's change (the capture store, Todo 13) into the
    /// same `proxy.request` signal without minting a new event type.
    fn mark_external_dirty(&mut self) {
        self.external_dirty = self.external_dirty.saturating_add(1);
    }

    /// Queue `id`'s current state for the next durable flush. No-op without a
    /// configured sink; over the queue cap the overflow flag makes the next
    /// flush persist the whole ring instead.
    fn enqueue_pending(&mut self, id: u64) {
        if self.db.is_none() {
            return;
        }
        let Some(idx) = self.by_record_id.get(&id).copied() else {
            return;
        };
        let Some(record) = self.records.get(idx).cloned() else {
            return;
        };
        if self.pending.len() >= REQUEST_FLUSH_QUEUE_CAP {
            self.pending_overflow = true;
        } else {
            self.pending.push_back(record);
        }
    }

    /// The actual durable write: one transaction that upserts the batch then
    /// prunes cap-first, then by the 7-day window. Returns rows pruned.
    fn do_flush(&mut self, now: u64) -> usize {
        if self.db.is_none() || (self.pending.is_empty() && !self.pending_overflow) {
            return 0;
        }
        let batch: Vec<RequestRecord> = if self.pending_overflow {
            self.records.iter().cloned().collect()
        } else {
            self.pending.drain(..).collect()
        };
        self.pending.clear();
        self.pending_overflow = false;
        let result = match self.db.as_mut() {
            Some(db) => db.upsert_batch(&batch, now),
            None => Ok(0),
        };
        match result {
            Ok(pruned) => {
                self.lost_records += pruned as u64;
                self.retention_floor_ms = Some(now.saturating_sub(REQUEST_RETENTION_MS));
                pruned
            }
            Err(e) => {
                crate::log_message(2, &format!("proxy.requests: flush failed: {e}"));
                self.pending_overflow = true;
                0
            }
        }
    }

    /// [`do_flush`](Self::do_flush) behind the 5s interval gate.
    fn maybe_flush(&mut self, now: u64) -> usize {
        if self.db.is_none() || (self.pending.is_empty() && !self.pending_overflow) {
            return 0;
        }
        if self.last_persist_ms != 0
            && now.saturating_sub(self.last_persist_ms) < REQUEST_PERSIST_INTERVAL_MS
        {
            return 0;
        }
        self.last_persist_ms = now;
        self.do_flush(now)
    }

    /// Replace the ring with the seeded window rows and restore cursor
    /// continuity: `nextRecordId = max(record_id)+1` over the whole table (1
    /// when empty), `nextCursor` = the DB high-water mark. Never restarts
    /// numbering from 0 after a restart.
    fn adopt_seed(&mut self, rows: Vec<RequestRecord>, db: &Persist) {
        self.records.clear();
        self.by_record_id.clear();
        self.active_by_conn.clear();
        self.stale_live.clear();
        self.dirty.clear();
        self.dirty_overflow = 0;
        self.external_dirty = 0;
        self.uid_pending.clear();
        self.uid_unprocessed.clear();
        self.uid_early.clear();
        self.uid_early_order.clear();
        for r in rows {
            let id = r.record_id;
            self.by_record_id.insert(id, self.records.len());
            self.records.push_back(r);
        }
        let max = db.max_record_id().unwrap_or(0);
        self.next_record_id = max + 1;
        self.next_cursor = max;
        self.window_start_ms = self.records.front().map(|r| r.open_ts_ms).unwrap_or(0);
    }

    /// Build the `proxy.request` dirty-signal payload if (a) there is
    /// new/changed data and (b) the ≥1s throttle window has elapsed. Draining is
    /// atomic with the check, so a suppressed tick leaves the dirty set intact
    /// for the next one.
    fn emit_pending(&mut self, now_ms: u64) -> Option<serde_json::Value> {
        let count = self.dirty.len() as u64 + self.dirty_overflow + self.external_dirty;
        if count == 0 || now_ms.saturating_sub(self.last_emit_ms) < MIN_EMIT_INTERVAL_MS {
            return None;
        }
        self.dirty.clear();
        self.dirty_overflow = 0;
        self.external_dirty = 0;
        self.last_emit_ms = now_ms;
        self.emit_seq += 1;
        Some(serde_json::json!({
            "seq": self.emit_seq,
            "count": count,
            "tsMs": now_ms,
        }))
    }

    /// Build a page of records newer than `since_record_id` that match `filters`.
    /// Ordered by `openTsMs` descending, ties by `recordId` ascending, then
    /// truncated to `limit`. **DB-authoritative**: when a durable sink is
    /// configured the page comes from SQLite (the window of ≤`REQUEST_MAX_ROWS`
    /// rows); the in-memory ring is only the fallback near-term view.
    pub(crate) fn snapshot(
        &self,
        since_record_id: u64,
        limit: usize,
        filters: &RequestFilter,
    ) -> RequestSnapshot {
        match &self.db {
            Some(db) => self.snapshot_from_db(db, since_record_id, limit, filters),
            None => self.snapshot_from_ring(since_record_id, limit, filters),
        }
    }

    fn snapshot_from_db(
        &self,
        db: &Persist,
        since_record_id: u64,
        limit: usize,
        filters: &RequestFilter,
    ) -> RequestSnapshot {
        let floor = self.retention_floor_ms.unwrap_or(0);
        let records = match db.load_page(floor, since_record_id, limit, filters) {
            Ok(rows) => rows,
            Err(e) => {
                crate::log_message(2, &format!("proxy.requests: read failed: {e}"));
                return self.snapshot_from_ring(since_record_id, limit, filters);
            }
        };
        let retained = db.count(floor).unwrap_or(0);
        let first_cursor = db.min_record_id(floor).unwrap_or(0);
        RequestSnapshot {
            records,
            next_cursor: self.next_cursor,
            first_cursor,
            retained,
            capacity: self.cap,
            dropped: self.dropped,
            evicted: self.evicted,
            window_start_ms: self
                .retention_floor_ms
                .unwrap_or_else(|| self.records.front().map(|r| r.open_ts_ms).unwrap_or(0)),
        }
    }

    fn snapshot_from_ring(
        &self,
        since_record_id: u64,
        limit: usize,
        filters: &RequestFilter,
    ) -> RequestSnapshot {
        let limit = limit.min(self.cap);
        let mut matched: Vec<RequestRecord> = self
            .records
            .iter()
            .filter(|r| r.record_id > since_record_id)
            .filter(|r| filters.matches(r))
            .cloned()
            .collect();
        matched.sort_by(|a, b| {
            b.open_ts_ms
                .cmp(&a.open_ts_ms)
                .then_with(|| a.record_id.cmp(&b.record_id))
        });
        matched.truncate(limit);
        RequestSnapshot {
            records: matched,
            next_cursor: self.next_cursor,
            first_cursor: self.records.front().map(|r| r.record_id).unwrap_or(0),
            retained: self.records.len(),
            capacity: self.cap,
            dropped: self.dropped,
            evicted: self.evicted,
            window_start_ms: self.window_start_ms,
        }
    }
}

/// Durable request timeline: WAL + batched single-transaction upserts + a
/// rolling cap-first / time-window prune.
pub(crate) struct Persist {
    conn: rusqlite::Connection,
    max_rows: usize,
}

impl Persist {
    fn open(path: &str) -> rusqlite::Result<Self> {
        Self::wrap(rusqlite::Connection::open(path)?)
    }

    #[cfg(test)]
    fn open_in_memory() -> rusqlite::Result<Self> {
        Self::wrap(rusqlite::Connection::open_in_memory()?)
    }

    fn wrap(conn: rusqlite::Connection) -> rusqlite::Result<Self> {
        conn.busy_timeout(std::time::Duration::from_millis(REQUEST_BUSY_TIMEOUT_MS))?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             PRAGMA busy_timeout=5000;
             CREATE TABLE IF NOT EXISTS request_records (
               record_id INTEGER PRIMARY KEY,
               conn_id TEXT NOT NULL,
               open_ts_ms INTEGER NOT NULL,
               close_ts_ms INTEGER,
               duration_ms INTEGER,
               domain TEXT NOT NULL,
               domain_known INTEGER NOT NULL,
               dst_ip TEXT NOT NULL,
               dst_port INTEGER NOT NULL,
               src TEXT NOT NULL,
               network TEXT NOT NULL,
               uid INTEGER,
               packages TEXT NOT NULL,
               uid_state TEXT NOT NULL,
               rule TEXT NOT NULL,
               rule_payload TEXT NOT NULL,
               outbound TEXT NOT NULL,
               upload_bytes INTEGER NOT NULL,
               download_bytes INTEGER NOT NULL,
               close_reason TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_request_open_ts
               ON request_records(open_ts_ms, record_id);",
        )?;
        Ok(Self {
            conn,
            max_rows: REQUEST_MAX_ROWS,
        })
    }

    #[cfg(test)]
    fn set_max_rows(&mut self, n: usize) {
        self.max_rows = n;
    }

    /// Upsert `records` and prune in one transaction: **cap-first** (keep the
    /// newest `max_rows` by `open_ts_ms`), then delete rows older than the
    /// 7-day window. Returns rows pruned.
    fn upsert_batch(&mut self, records: &[RequestRecord], now: u64) -> rusqlite::Result<usize> {
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO request_records
                   (record_id, conn_id, open_ts_ms, close_ts_ms, duration_ms, domain,
                    domain_known, dst_ip, dst_port, src, network, uid, packages,
                    uid_state, rule, rule_payload, outbound, upload_bytes,
                    download_bytes, close_reason)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                         ?14, ?15, ?16, ?17, ?18, ?19, ?20)
                 ON CONFLICT(record_id) DO UPDATE SET
                   conn_id=excluded.conn_id,
                   open_ts_ms=excluded.open_ts_ms,
                   close_ts_ms=excluded.close_ts_ms,
                   duration_ms=excluded.duration_ms,
                   domain=excluded.domain,
                   domain_known=excluded.domain_known,
                   dst_ip=excluded.dst_ip,
                   dst_port=excluded.dst_port,
                   src=excluded.src,
                   network=excluded.network,
                   uid=excluded.uid,
                   packages=excluded.packages,
                   uid_state=excluded.uid_state,
                   rule=excluded.rule,
                   rule_payload=excluded.rule_payload,
                   outbound=excluded.outbound,
                   upload_bytes=excluded.upload_bytes,
                   download_bytes=excluded.download_bytes,
                   close_reason=excluded.close_reason",
            )?;
            for r in records {
                let packages = serde_json::to_string(&r.packages).unwrap_or_else(|_| "[]".into());
                stmt.execute(rusqlite::params![
                    r.record_id as i64,
                    r.conn_id,
                    r.open_ts_ms as i64,
                    r.close_ts_ms.map(|v| v as i64),
                    r.duration_ms.map(|v| v as i64),
                    r.domain,
                    r.domain_known,
                    r.dst_ip,
                    r.dst_port as i64,
                    r.src,
                    r.network,
                    r.uid.map(|v| v as i64),
                    packages,
                    r.uid_state,
                    r.rule,
                    r.rule_payload,
                    r.outbound,
                    r.upload_bytes as i64,
                    r.download_bytes as i64,
                    r.close_reason,
                ])?;
            }
        }
        let mut pruned = 0usize;
        let total: i64 = tx.query_row("SELECT COUNT(*) FROM request_records", [], |r| r.get(0))?;
        let max_rows = self.max_rows as i64;
        if total > max_rows {
            let excess = total - max_rows;
            pruned += tx.execute(
                "DELETE FROM request_records WHERE record_id IN (
                   SELECT record_id FROM request_records
                   ORDER BY open_ts_ms ASC, record_id ASC LIMIT ?1
                 )",
                rusqlite::params![excess],
            )?;
        }
        let cutoff = now.saturating_sub(REQUEST_RETENTION_MS) as i64;
        pruned += tx.execute(
            "DELETE FROM request_records WHERE open_ts_ms < ?1",
            rusqlite::params![cutoff],
        )?;
        tx.commit()?;
        Ok(pruned)
    }

    /// Load the window rows (newest `cap`, oldest-first for the ring deque).
    fn seed(&self, now: u64, cap: usize) -> rusqlite::Result<Vec<RequestRecord>> {
        let cutoff = now.saturating_sub(REQUEST_RETENTION_MS) as i64;
        let sql = format!(
            "SELECT {SELECT_COLUMNS} FROM request_records
             WHERE open_ts_ms >= ?1 ORDER BY open_ts_ms DESC, record_id DESC LIMIT ?2"
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let mut rows = stmt
            .query_map(rusqlite::params![cutoff, cap as i64], row_to_record)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows.reverse();
        Ok(rows)
    }

    /// One page ordered `open_ts_ms DESC, record_id ASC`, filtered in SQL so a
    /// DB page never needs the (bounded) ring.
    fn load_page(
        &self,
        floor: u64,
        since: u64,
        limit: usize,
        f: &RequestFilter,
    ) -> rusqlite::Result<Vec<RequestRecord>> {
        let mut sql = format!(
            "SELECT {SELECT_COLUMNS} FROM request_records WHERE record_id > ? AND open_ts_ms >= ?"
        );
        let mut vals: Vec<rusqlite::types::Value> =
            vec![(since as i64).into(), (floor as i64).into()];
        if let Some(d) = non_blank(&f.domain) {
            sql.push_str(" AND instr(domain, ?) > 0");
            vals.push(d.to_string().into());
        }
        if let Some(uid) = f.uid {
            sql.push_str(" AND uid = ?");
            vals.push((uid as i64).into());
        }
        if let Some(n) = non_blank(&f.network) {
            sql.push_str(" AND network = ?");
            vals.push(n.to_string().into());
        }
        if let Some(o) = non_blank(&f.outbound) {
            sql.push_str(" AND outbound = ?");
            vals.push(o.to_string().into());
        }
        if let Some(s) = f.since_ms {
            sql.push_str(" AND open_ts_ms >= ?");
            vals.push((s as i64).into());
        }
        if let Some(u) = f.until_ms {
            sql.push_str(" AND open_ts_ms <= ?");
            vals.push((u as i64).into());
        }
        sql.push_str(" ORDER BY open_ts_ms DESC, record_id ASC LIMIT ?");
        vals.push((limit.min(REQUEST_MAX_ROWS) as i64).into());
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt
            .query_map(rusqlite::params_from_iter(vals.iter()), row_to_record)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    fn count(&self, floor: u64) -> rusqlite::Result<usize> {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM request_records WHERE open_ts_ms >= ?1",
                rusqlite::params![floor as i64],
                |r| r.get::<_, i64>(0),
            )
            .map(|n| n.max(0) as usize)
    }

    fn min_record_id(&self, floor: u64) -> rusqlite::Result<u64> {
        self.conn
            .query_row(
                "SELECT COALESCE(MIN(record_id),0) FROM request_records WHERE open_ts_ms >= ?1",
                rusqlite::params![floor as i64],
                |r| r.get::<_, i64>(0),
            )
            .map(|n| n.max(0) as u64)
    }

    fn max_record_id(&self) -> rusqlite::Result<u64> {
        self.conn
            .query_row(
                "SELECT COALESCE(MAX(record_id),0) FROM request_records",
                [],
                |r| r.get::<_, i64>(0),
            )
            .map(|n| n.max(0) as u64)
    }

    #[cfg(test)]
    fn all_record_ids(&self) -> rusqlite::Result<Vec<u64>> {
        let mut stmt = self
            .conn
            .prepare("SELECT record_id FROM request_records ORDER BY record_id ASC")?;
        let rows = stmt
            .query_map([], |r| r.get::<_, i64>(0))?
            .map(|n| n.map(|v| v.max(0) as u64))
            .collect();
        rows
    }

    fn clear(&self) -> rusqlite::Result<()> {
        self.conn.execute_batch("DELETE FROM request_records;")
    }
}

const SELECT_COLUMNS: &str = "record_id, conn_id, open_ts_ms, close_ts_ms, duration_ms, \
     domain, domain_known, dst_ip, dst_port, src, network, uid, packages, uid_state, \
     rule, rule_payload, outbound, upload_bytes, download_bytes, close_reason";

fn row_to_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<RequestRecord> {
    let packages: String = row.get(12)?;
    Ok(RequestRecord {
        record_id: row.get::<_, i64>(0)?.max(0) as u64,
        conn_id: row.get(1)?,
        open_ts_ms: row.get::<_, i64>(2)?.max(0) as u64,
        close_ts_ms: row.get::<_, Option<i64>>(3)?.map(|v| v.max(0) as u64),
        duration_ms: row.get::<_, Option<i64>>(4)?.map(|v| v.max(0) as u64),
        domain: row.get(5)?,
        domain_known: row.get::<_, i64>(6)? != 0,
        dst_ip: row.get(7)?,
        dst_port: row.get::<_, i64>(8)?.clamp(0, u16::MAX as i64) as u16,
        src: row.get(9)?,
        network: row.get(10)?,
        uid: row
            .get::<_, Option<i64>>(11)?
            .map(|v| v.clamp(0, u32::MAX as i64) as u32),
        packages: serde_json::from_str(&packages).unwrap_or_default(),
        uid_state: row.get(13)?,
        rule: row.get(14)?,
        rule_payload: row.get(15)?,
        outbound: row.get(16)?,
        upload_bytes: row.get::<_, i64>(17)?.max(0) as u64,
        download_bytes: row.get::<_, i64>(18)?.max(0) as u64,
        close_reason: row.get(19)?,
    })
}

#[cfg(not(test))]
static STORE: OnceLock<Mutex<RequestStore>> = OnceLock::new();

#[cfg(not(test))]
fn with_store<R>(f: impl FnOnce(&mut RequestStore) -> R) -> R {
    let mut guard = STORE
        .get_or_init(|| Mutex::new(RequestStore::fresh()))
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    f(&mut guard)
}

#[cfg(test)]
thread_local! {
    static TEST_STORE: std::cell::RefCell<RequestStore> = std::cell::RefCell::new(RequestStore::fresh());
}

/// Tests use a per-thread store so request-only tests never race the
/// process-global instance.
#[cfg(test)]
fn with_store<R>(f: impl FnOnce(&mut RequestStore) -> R) -> R {
    TEST_STORE.with(|s| f(&mut s.borrow_mut()))
}

/// `requests.get` snapshot over the process-global store (the primary,
/// pull-based path; the host event ring is never fed per-request).
pub(crate) fn snapshot(
    since_record_id: u64,
    limit: usize,
    filters: &RequestFilter,
) -> RequestSnapshot {
    with_store(|st| st.snapshot(since_record_id, limit, filters))
}

/// Drop every retained record (memory only). The cursor stays monotonic.
pub(crate) fn clear() {
    with_store(|st| st.clear());
}

/// Bump the shared `proxy.request` dirty counter on behalf of an external
/// producer (the capture store, Todo 13). The only emitter stays `tick`.
pub(crate) fn mark_external_dirty() {
    with_store(|st| st.mark_external_dirty());
}

/// The configured durable-sink directory (or `None` while memory-only). A plain
/// process-global so every engine path (VPN `start_engine`, LAN reconcile)
/// observes the same config, independent of the per-thread store in tests.
static CONFIGURED_DIR: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// Configure the durable request sink (`<dir>/proxy_requests.db`).
///
/// Opens (creating if needed) the rolling SQLite timeline, seeds the ring with
/// the window rows and restores cursor continuity from the DB. An empty/absent
/// `data_dir` is an explicit **in-memory-only** degrade (documented at the call
/// sites), never a silent drop of DB configuration and never a panic.
pub(crate) fn configure(data_dir: &str) {
    configure_at(data_dir, crate::now_ms());
}

/// [`configure`] with an explicit clock, so restart/retention tests are
/// deterministic.
pub(crate) fn configure_at(data_dir: &str, now: u64) {
    let dir = data_dir.trim();
    if dir.is_empty() {
        crate::log_message(
            1,
            "proxy.requests: no data dir, memory-only (persistence disabled)",
        );
        return;
    }
    let path = format!("{}/proxy_requests.db", dir.trim_end_matches('/'));
    with_store(|st| {
        st.do_flush(now);
        match Persist::open(&path) {
            Ok(persist) => {
                match persist.seed(now, st.cap) {
                    Ok(rows) => st.adopt_seed(rows, &persist),
                    Err(e) => crate::log_message(
                        2,
                        &format!("proxy.requests: seed {path} failed: {e}"),
                    ),
                }
                st.pending.clear();
                st.pending_overflow = false;
                st.last_persist_ms = 0;
                st.lost_records = 0;
                st.retention_floor_ms = Some(now.saturating_sub(REQUEST_RETENTION_MS));
                st.db = Some(persist);
                crate::log_message(1, &format!("proxy.requests: persistence enabled at {path}"));
            }
            Err(e) => crate::log_message(2, &format!("proxy.requests: open {path} failed: {e}")),
        }
    });
    *CONFIGURED_DIR.lock().unwrap_or_else(|e| e.into_inner()) = Some(dir.to_string());
}

/// Flush the bounded pending queue when the 5s interval has elapsed. Returns
/// rows pruned. A no-op without a configured sink or with nothing pending.
pub(crate) fn maybe_persist(now: u64) -> usize {
    with_store(|st| st.maybe_flush(now))
}

/// Flush the pending queue immediately (no interval gate). Test/diagnostic seam.
#[cfg(test)]
pub(crate) fn flush_for_tests(now: u64) -> usize {
    with_store(|st| st.do_flush(now))
}

/// Flush pending writes and drop the connection — simulates a process close in
/// the restart round-trip test.
#[cfg(test)]
pub(crate) fn close_for_tests(now: u64) {
    with_store(|st| {
        st.do_flush(now);
        st.db = None;
    });
}

#[cfg(test)]
pub(crate) fn db_configured_for_tests() -> bool {
    with_store(|st| st.db.is_some())
}

#[cfg(test)]
pub(crate) fn db_row_count_for_tests() -> Option<usize> {
    with_store(|st| st.db.as_ref().and_then(|db| db.count(0).ok()))
}

#[cfg(test)]
pub(crate) fn pending_len_for_tests() -> usize {
    with_store(|st| st.pending.len())
}

#[cfg(test)]
pub(crate) fn next_record_id_for_tests() -> u64 {
    with_store(|st| st.next_record_id)
}

#[cfg(test)]
pub(crate) fn next_cursor_for_tests() -> u64 {
    with_store(|st| st.next_cursor)
}

#[cfg(test)]
pub(crate) fn external_dirty_for_tests() -> u64 {
    with_store(|st| st.external_dirty)
}

#[cfg(test)]
pub(crate) fn lost_records_for_tests() -> u64 {
    with_store(|st| st.lost_records)
}

#[cfg(test)]
pub(crate) fn uid_pending_len_for_tests() -> usize {
    with_store(|st| st.uid_pending.len())
}

#[cfg(test)]
pub(crate) fn uid_early_len_for_tests() -> usize {
    with_store(|st| st.uid_early.len())
}

#[cfg(test)]
pub(crate) fn uid_state_for_tests(record_id: u64) -> Option<String> {
    with_store(|st| {
        st.by_record_id
            .get(&record_id)
            .map(|idx| st.records[*idx].uid_state.clone())
    })
}

/// The directory the request sink is configured against (test proof that the
/// VPN/LAN paths wired [`configure`] in).
#[cfg(test)]
pub(crate) fn configured_dir_for_tests() -> Option<String> {
    CONFIGURED_DIR
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// The ONLY emitter of the `proxy.request` dirty signal. Emits a payload-free
/// `{seq,count,tsMs}` at most once per [`MIN_EMIT_INTERVAL_MS`] and only when
/// records were created/changed since the previous emit. Returns whether an
/// event was emitted.
///
/// `mode` gates UID attribution: only `Mode::Vpn` + TCP flows become `pending`
/// and produce a `proxy.uid.query`; the LAN engine attach makes the tunnel live
/// too, so `active_tunnel().is_some()` is deliberately never consulted here.
pub(crate) fn tick(instance_id: u64, mode: crate::ProxyMode, now_ms: u64) -> bool {
    // Gate/collect the pending UID queries and fold the record changes into the
    // same dirty signal, all under one store lock; the lock is released before
    // resolving/emitting (never emit while the store lock is held).
    let (queries, payload) = with_store(|st| {
        st.maybe_flush(now_ms);
        let queries = st.gate_uid(mode, now_ms);
        let payload = st.emit_pending(now_ms);
        (queries, payload)
    });

    if !queries.is_empty() {
        if let Some(answers) = with_resolver(|r| r.resolve(&queries)) {
            if !answers.is_empty() {
                with_store(|st| st.apply_uid_answers(&answers, now_ms));
            }
        }
        emit_uid_query(instance_id, &queries);
    }

    let Some(value) = payload else { return false };
    let Ok(bytes) = serde_json::to_vec(&value) else {
        return false;
    };
    crate::emit_event(instance_id, crate::EVT_REQUEST, &bytes);
    true
}

fn emit_uid_query(instance_id: u64, queries: &[UidQuery]) {
    let value = serde_json::json!({ "queries": queries });
    if let Ok(bytes) = serde_json::to_vec(&value) {
        crate::emit_event(instance_id, EVT_UID_QUERY, &bytes);
    }
}

/// `on_event` body for the host's `uid.result` reply.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UidResultBody {
    #[serde(default)]
    results: Vec<UidAnswer>,
}

/// Apply a host `uid.result` payload (`{"results":[{recordId,uid,packages}]}`).
/// A malformed payload is a structured error, never a panic.
pub(crate) fn handle_uid_result(payload: &[u8]) -> Result<usize, ModuleError> {
    handle_uid_result_at(payload, crate::now_ms())
}

fn handle_uid_result_at(payload: &[u8], now_ms: u64) -> Result<usize, ModuleError> {
    let body: UidResultBody = serde_json::from_slice(payload).map_err(|e| {
        ModuleError::invalid_arg(format!("uid.result payload must be {{\"results\":[...]}}: {e}"))
    })?;
    // Capture-origin replies carry a reserved id: route them to their awaiting
    // resolver and NEVER to `apply_uid_answers`, so they cannot reach
    // `uid_early`. Everything else keeps the existing store backfill.
    let mut store_answers = Vec::with_capacity(body.results.len());
    for answer in body.results {
        if answer.record_id >= CAPTURE_UID_ID_BASE {
            route_capture_uid_answer(answer);
        } else {
            store_answers.push(answer);
        }
    }
    if store_answers.is_empty() {
        return Ok(0);
    }
    Ok(with_store(|st| st.apply_uid_answers(&store_answers, now_ms)))
}

/// Deliver one reserved-id answer to its awaiting resolver. A missing sender
/// (timed out / abandoned) and a dropped receiver (late answer) both discard
/// the answer without touching the request store.
fn route_capture_uid_answer(answer: UidAnswer) {
    let sender = capture_uid_pending()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&answer.record_id);
    if let Some(sender) = sender {
        let _ = sender.send(answer);
    }
}

/// Capture a request open at the single chokepoint. Returns the `recordId`; a
/// stale-but-live flow re-entering the projection reuses its existing record.
pub(crate) fn record_open(rec: &ConnRecord, now_ms: u64) -> u64 {
    with_store(|st| st.open_record(rec, now_ms))
}

/// Capture a close (or stale) transition at the single chokepoint. A terminal
/// record is left untouched by a second call (idempotent).
pub(crate) fn record_close(rec: &ConnRecord, now_ms: u64, reason: CloseReason) {
    with_store(|st| match reason {
        CloseReason::Closed => {
            st.finalize(&rec.id, now_ms);
        }
        CloseReason::Stale => st.mark_stale(&rec.id),
    });
}

/// Register a synthesized request record for a MITM flow at session start.
///
/// MITM flows are not tracked by meow's connection table, so the dispatch layer
/// synthesizes a [`ConnRecord`] from the bridged endpoints and projects it into
/// the same timeline through the existing [`RequestStore::open_record`]
/// chokepoint (dedupe/idempotency reused, never reimplemented). Returns the
/// assigned `recordId`, which the MITM path stores on its request context.
///
/// Crate-internal only: no ABI/JSON surface is touched.
pub(crate) fn open_mitm_flow(
    conn_id: &str,
    host: &str,
    src: SocketAddr,
    dst: SocketAddr,
    now_ms: u64,
) -> u64 {
    let rec = ConnRecord {
        id: conn_id.into(),
        src: src.to_string(),
        dst: format!("{}:{}", dst.ip(), dst.port()),
        dst_ip: dst.ip().to_string(),
        dst_port: dst.port(),
        domain: host.into(),
        network: "tcp".into(),
        rule: String::new(),
        rule_payload: String::new(),
        outbound: String::new(),
        started_at_ms: now_ms,
        upload_bytes: 0,
        download_bytes: 0,
    };
    with_store(|st| st.open_record(&rec, now_ms))
}

/// Finalize the synthesized record for a MITM flow at session end.
///
/// Idempotent by construction: [`RequestStore::finalize`] leaves a terminal
/// record untouched, and a `conn_id` the bounded ring has already evicted (or
/// never saw) is a silent no-op — this helper must never panic.
pub(crate) fn close_mitm_flow(conn_id: &str, now_ms: u64) {
    with_store(|st| {
        st.finalize(conn_id, now_ms);
    });
}

/// Finalize every stale id that `is_live` reports as gone from meow's live table
/// — the only path that turns a stale record into a terminal `closed`.
pub(crate) fn finalize_departed_stale(now_ms: u64, is_live: impl Fn(&str) -> bool) -> u64 {
    with_store(|st| st.finalize_departed(now_ms, is_live))
}

/// Finalize every active record (`close_all` semantics).
pub(crate) fn finalize_all_active(now_ms: u64) -> u64 {
    with_store(|st| st.close_all_records(now_ms))
}

#[cfg(test)]
pub(crate) fn reset_for_tests() {
    with_store(|st| *st = RequestStore::fresh());
    capture_uid_pending()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
    NEXT_CAPTURE_UID_ID.store(CAPTURE_UID_ID_BASE, Ordering::SeqCst);
}

#[cfg(test)]
pub(crate) fn capture_uid_registry_len_for_tests() -> usize {
    capture_uid_pending()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .len()
}

#[cfg(test)]
pub(crate) fn stale_live_len() -> usize {
    with_store(|st| st.stale_live.len())
}

#[cfg(test)]
pub(crate) fn reentered_count() -> u64 {
    with_store(|st| st.reentered)
}

/// One `requests.get` page plus the ring's cursor/retention diagnostics.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RequestSnapshot {
    pub records: Vec<RequestRecord>,
    /// Global high-water mark (last issued `recordId`). Never reclaimed.
    pub next_cursor: u64,
    /// Oldest retained `recordId`, or 0 when the ring is empty. A caller whose
    /// `cursor` is below this has lost records to eviction.
    pub first_cursor: u64,
    pub retained: usize,
    pub capacity: usize,
    pub dropped: u64,
    pub evicted: u64,
    pub window_start_ms: u64,
}

/// `requests.get` filters. Every field is optional; absent/blank string filters
/// are ignored (so a malformed `{domain:""}` matches everything rather than
/// nothing).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RequestFilter {
    #[serde(default)]
    pub domain: Option<String>,
    #[serde(default)]
    pub uid: Option<u32>,
    #[serde(default)]
    pub network: Option<String>,
    #[serde(default)]
    pub outbound: Option<String>,
    #[serde(default)]
    pub since_ms: Option<u64>,
    #[serde(default)]
    pub until_ms: Option<u64>,
}

impl RequestFilter {
    /// `domain` is a case-sensitive substring; `network`/`outbound` are exact;
    /// `sinceMs`/`untilMs` bound `openTsMs` inclusively on both ends (a reversed
    /// range matches nothing, it never panics).
    pub(crate) fn matches(&self, r: &RequestRecord) -> bool {
        if let Some(d) = non_blank(&self.domain) {
            if !r.domain.contains(d) {
                return false;
            }
        }
        if let Some(uid) = self.uid {
            if r.uid != Some(uid) {
                return false;
            }
        }
        if let Some(n) = non_blank(&self.network) {
            if r.network != n {
                return false;
            }
        }
        if let Some(o) = non_blank(&self.outbound) {
            if r.outbound != o {
                return false;
            }
        }
        if let Some(since) = self.since_ms {
            if r.open_ts_ms < since {
                return false;
            }
        }
        if let Some(until) = self.until_ms {
            if r.open_ts_ms > until {
                return false;
            }
        }
        true
    }
}

fn non_blank(v: &Option<String>) -> Option<&str> {
    v.as_deref().map(str::trim).filter(|s| !s.is_empty())
}

/// Default `requests.get` page size when `limit` is omitted (clamped to the ring
/// cap by [`RequestStore::snapshot`]).
pub(crate) const DEFAULT_REQUEST_LIMIT: usize = 256;

/// `requests.get` request body:
/// `{ "cursor"?: recordId, "limit"?: number, "filter"?: { ... } }`.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RequestGetRequest {
    #[serde(default)]
    pub cursor: Option<u64>,
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub filter: RequestFilter,
}

/// `requests.get` dispatch arm. Parses the cursor/limit/filter body and returns
/// the serialized [`RequestSnapshot`] (`RequestPage`) inside the ok envelope. A
/// malformed body is a structured `INVALID_ARGUMENT` (422), never a panic.
pub(crate) fn get_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let req: RequestGetRequest = if payload.is_empty() {
        RequestGetRequest::default()
    } else {
        let value: serde_json::Value = serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!("requests.get payload must be a JSON object: {e}"))
        })?;
        // A present-but-non-numeric cursor is its own structured code
        // (`PROXY_REQUEST_CURSOR_INVALID`), not the generic payload error.
        if let Some(cursor) = value.get("cursor") {
            if cursor.as_u64().is_none() {
                return Err(ModuleError::new(
                    StatusCode::InvalidArgument,
                    ERR_REQUEST_CURSOR_INVALID,
                    format!("requests.get cursor must be a non-negative integer, got {cursor}"),
                ));
            }
        }
        serde_json::from_value(value).map_err(|e| {
            ModuleError::invalid_arg(format!("requests.get payload must be a JSON object: {e}"))
        })?
    };
    let cursor = req.cursor.unwrap_or(0);
    let limit = req.limit.unwrap_or(DEFAULT_REQUEST_LIMIT);
    let page = snapshot(cursor, limit, &req.filter);
    let data = serde_json::to_value(&page).map_err(|e| ModuleError::internal(e.to_string()))?;
    crate::ok_data(data)
}

/// `requests.reset` dispatch arm. Drops every retained in-memory record (the
/// cursor stays monotonic) and reports how many were cleared.
pub(crate) fn reset_arm() -> Result<Vec<u8>, ModuleError> {
    let cleared = with_store(|st| {
        let count = match &st.db {
            Some(db) => db.count(0).unwrap_or(st.records.len()),
            None => st.records.len(),
        };
        st.clear();
        st.lost_records = 0;
        st.last_persist_ms = 0;
        if let Some(db) = &st.db {
            if let Err(e) = db.clear() {
                crate::log_message(2, &format!("proxy.requests: reset persistence failed: {e}"));
            }
        }
        count
    });
    crate::log_message(1, &format!("proxy: requests.reset cleared={cleared}"));
    crate::ok_data(serde_json::json!({ "ok": true, "cleared": cleared }))
}

// --- Todo 10: `requests.export` (CSV + JSON) ---

/// Error code: a single export would exceed [`REQUEST_EXPORT_MAX_BYTES`].
pub(crate) const ERR_REQUEST_EXPORT_TOO_LARGE: &str = "PROXY_REQUEST_EXPORT_TOO_LARGE";
/// Error code: the export `filter` is not a valid [`RequestFilter`] object.
pub(crate) const ERR_REQUEST_EXPORT_FILTER_INVALID: &str = "PROXY_REQUEST_EXPORT_FILTER_INVALID";
/// Error code: a `requests.get` cursor is present but not a non-negative integer.
pub(crate) const ERR_REQUEST_CURSOR_INVALID: &str = "PROXY_REQUEST_CURSOR_INVALID";

/// Hard cap on the total bytes a single export may generate (CSV + JSON). A
/// larger export is rejected **before** any file is written, so no half file can
/// survive an over-cap attempt.
pub(crate) const REQUEST_EXPORT_MAX_BYTES: usize = 64 * 1024 * 1024;

/// Fixed CSV column order. Stable contract: the header row is exactly these
/// columns, in this order, so a consumer can depend on positions.
pub(crate) const EXPORT_CSV_COLUMNS: &[&str] = &[
    "recordId",
    "connId",
    "openTsMs",
    "closeTsMs",
    "durationMs",
    "domain",
    "domainKnown",
    "dstIp",
    "dstPort",
    "src",
    "network",
    "uid",
    "packages",
    "uidState",
    "rule",
    "rulePayload",
    "outbound",
    "uploadBytes",
    "downloadBytes",
    "closeReason",
];

/// Which artifact(s) an export should produce.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ExportFormat {
    Csv,
    Json,
    Both,
}

impl ExportFormat {
    fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "csv" => Some(Self::Csv),
            "json" => Some(Self::Json),
            "both" => Some(Self::Both),
            _ => None,
        }
    }

    fn wants_csv(self) -> bool {
        matches!(self, Self::Csv | Self::Both)
    }

    fn wants_json(self) -> bool {
        matches!(self, Self::Json | Self::Both)
    }
}

/// `requests.export` response. Paths are omitted when that artifact was not
/// requested (never `null`); the records themselves are **never** put in this
/// envelope — they live only in the written files.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RequestExportResult {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub csv_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub json_path: Option<String>,
    pub rows: usize,
    pub bytes: u64,
    pub generated_at_ms: u64,
}

/// The directory the request sink was configured against, or `None` while
/// memory-only. Export prefers it and degrades to the process temp dir.
pub(crate) fn export_dir() -> Option<String> {
    CONFIGURED_DIR
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// RFC4180: quote when the field contains a comma, quote, CR or LF; embedded
/// quotes are doubled. Everything else is emitted verbatim.
fn csv_escape(field: &str) -> String {
    if field.contains(',')
        || field.contains('"')
        || field.contains('\n')
        || field.contains('\r')
    {
        format!("\"{}\"", field.replace('"', "\"\""))
    } else {
        field.to_string()
    }
}

fn csv_field(r: &RequestRecord) -> Vec<String> {
    vec![
        r.record_id.to_string(),
        r.conn_id.clone(),
        r.open_ts_ms.to_string(),
        r.close_ts_ms.map(|v| v.to_string()).unwrap_or_default(),
        r.duration_ms.map(|v| v.to_string()).unwrap_or_default(),
        r.domain.clone(),
        r.domain_known.to_string(),
        r.dst_ip.clone(),
        r.dst_port.to_string(),
        r.src.clone(),
        r.network.clone(),
        r.uid.map(|v| v.to_string()).unwrap_or_default(),
        r.packages.join("|"),
        r.uid_state.clone(),
        r.rule.clone(),
        r.rule_payload.clone(),
        r.outbound.clone(),
        r.upload_bytes.to_string(),
        r.download_bytes.to_string(),
        r.close_reason.clone(),
    ]
}

/// Render the fixed-column, CRLF-terminated RFC4180 CSV. Always emits a header
/// row, so the row count is exactly `records.len() + 1` (for newline-free
/// fields). Columns are emitted positionally in [`EXPORT_CSV_COLUMNS`] order.
fn render_csv(records: &[RequestRecord]) -> String {
    let mut out = String::new();
    out.push_str(&EXPORT_CSV_COLUMNS.join(","));
    out.push_str("\r\n");
    for r in records {
        let line: Vec<String> = csv_field(r).iter().map(|f| csv_escape(f)).collect();
        out.push_str(&line.join(","));
        out.push_str("\r\n");
    }
    out
}

fn render_json(records: &[RequestRecord]) -> Vec<u8> {
    serde_json::to_vec(records).unwrap_or_else(|_| b"[]".to_vec())
}

struct ExportArtifacts {
    csv: Option<Vec<u8>>,
    json: Option<Vec<u8>>,
}

impl ExportArtifacts {
    fn build(records: &[RequestRecord], format: ExportFormat) -> Self {
        Self {
            csv: format.wants_csv().then(|| render_csv(records).into_bytes()),
            json: format.wants_json().then(|| render_json(records)),
        }
    }

    fn total_bytes(&self) -> usize {
        self.csv.as_ref().map_or(0, Vec::len) + self.json.as_ref().map_or(0, Vec::len)
    }
}

fn write_atomic(path: &str, bytes: &[u8]) -> Result<(), ModuleError> {
    let tmp = format!("{path}.tmp");
    std::fs::write(&tmp, bytes)
        .map_err(|e| ModuleError::internal(format!("requests.export write {tmp}: {e}")))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        ModuleError::internal(format!("requests.export rename {tmp} -> {path}: {e}"))
    })
}

/// Parse + snapshot + render + write. Split out so tests can inject a directory
/// and a tiny byte cap without racing the process-global configured dir.
fn export_impl(
    payload: &[u8],
    dir: Option<String>,
    max_bytes: usize,
) -> Result<Vec<u8>, ModuleError> {
    let value: serde_json::Value = if payload.is_empty() {
        serde_json::Value::Object(serde_json::Map::new())
    } else {
        serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!("requests.export payload must be a JSON object: {e}"))
        })?
    };
    let obj = value.as_object().ok_or_else(|| {
        ModuleError::invalid_arg("requests.export payload must be a JSON object")
    })?;

    let format = match obj.get("format") {
        None | Some(serde_json::Value::Null) => ExportFormat::Both,
        Some(serde_json::Value::String(raw)) => ExportFormat::parse(raw).ok_or_else(|| {
            ModuleError::invalid_arg(format!(
                "requests.export format must be one of csv|json|both, got {raw:?}"
            ))
        })?,
        Some(other) => {
            return Err(ModuleError::invalid_arg(format!(
                "requests.export format must be a string, got {other}"
            )))
        }
    };

    let filter: RequestFilter = match obj.get("filter") {
        None | Some(serde_json::Value::Null) => RequestFilter::default(),
        Some(raw) => serde_json::from_value(raw.clone()).map_err(|e| {
            ModuleError::new(
                StatusCode::InvalidArgument,
                ERR_REQUEST_EXPORT_FILTER_INVALID,
                format!("requests.export filter is invalid: {e}"),
            )
        })?,
    };

    // Snapshot under the store lock (consistent against concurrent record
    // writes / DB flushes), then render and write outside it so a large export
    // never blocks the ticker.
    let records = with_store(|st| st.snapshot(0, usize::MAX, &filter).records);
    let artifacts = ExportArtifacts::build(&records, format);
    let total = artifacts.total_bytes();
    if total > max_bytes {
        return Err(ModuleError::new(
            StatusCode::ResourceExhausted,
            ERR_REQUEST_EXPORT_TOO_LARGE,
            format!("requests.export would produce {total} bytes, over the {max_bytes} byte cap"),
        ));
    }

    let now = crate::now_ms();
    let dir = dir.unwrap_or_else(|| std::env::temp_dir().to_string_lossy().into_owned());
    std::fs::create_dir_all(&dir)
        .map_err(|e| ModuleError::internal(format!("requests.export mkdir {dir}: {e}")))?;
    let base = format!("proxy_requests_export_{now}");
    let mut csv_path = None;
    let mut json_path = None;
    if let Some(bytes) = &artifacts.csv {
        let path = format!("{}/{base}.csv", dir.trim_end_matches('/'));
        write_atomic(&path, bytes)?;
        csv_path = Some(path);
    }
    if let Some(bytes) = &artifacts.json {
        let path = format!("{}/{base}.json", dir.trim_end_matches('/'));
        if let Err(e) = write_atomic(&path, bytes) {
            if let Some(written) = &csv_path {
                let _ = std::fs::remove_file(written);
            }
            return Err(e);
        }
        json_path = Some(path);
    }

    let result = RequestExportResult {
        csv_path,
        json_path,
        rows: records.len(),
        bytes: total as u64,
        generated_at_ms: now,
    };
    crate::ok_data(serde_json::to_value(&result).map_err(|e| ModuleError::internal(e.to_string()))?)
}

/// `requests.export` dispatch arm. Generates CSV and/or JSON artifacts from a
/// consistent snapshot and returns their paths (the payload is never embedded).
pub(crate) fn export_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    export_impl(payload, export_dir(), REQUEST_EXPORT_MAX_BYTES)
}

#[cfg(test)]
fn export_arm_to(payload: &[u8], dir: &str, max_bytes: usize) -> Result<Vec<u8>, ModuleError> {
    export_impl(payload, Some(dir.to_string()), max_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(conn_id: &str, open_ts_ms: u64) -> RequestRecord {
        RequestRecord {
            record_id: 0,
            conn_id: conn_id.to_string(),
            open_ts_ms,
            close_ts_ms: None,
            duration_ms: None,
            domain: "example.com".to_string(),
            domain_known: true,
            dst_ip: "1.2.3.4".to_string(),
            dst_port: 443,
            src: "10.0.0.2:5555".to_string(),
            network: "tcp".to_string(),
            uid: None,
            packages: Vec::new(),
            uid_state: UID_STATE_UNKNOWN.to_string(),
            rule: "MATCH".to_string(),
            rule_payload: String::new(),
            outbound: "DIRECT".to_string(),
            upload_bytes: 0,
            download_bytes: 0,
            close_reason: CLOSE_REASON_OPEN.to_string(),
        }
    }

    fn store_with_cap(cap: usize) -> RequestStore {
        let mut s = RequestStore::fresh();
        s.cap = cap;
        s
    }

    #[test]
    fn ring_cap_constant_matches_fresh_store() {
        assert_eq!(REQUEST_RING_CAP, 4096);
        assert_eq!(RequestStore::fresh().cap, REQUEST_RING_CAP);
    }

    /// (a) happy path: a reused `connId` is TWO records, never an overwrite.
    #[test]
    fn same_conn_id_twice_yields_two_distinct_records() {
        let mut s = RequestStore::fresh();
        let first = s.push(rec("conn-1", 100));
        let second = s.push(rec("conn-1", 200));
        assert_ne!(
            first, second,
            "id reuse must mint a new recordId, not overwrite the old record"
        );
        let page = s.snapshot(0, 100, &RequestFilter::default());
        assert_eq!(page.records.len(), 2);
        assert_eq!(
            page.records.iter().filter(|r| r.conn_id == "conn-1").count(),
            2
        );
        assert_eq!(page.retained, 2);
    }

    /// (b) cursor monotonic and NOT reclaimed by clear.
    #[test]
    fn cursor_is_monotonic_and_survives_clear() {
        let mut s = RequestStore::fresh();
        for i in 0..5u64 {
            s.push(rec("c", 100 + i));
        }
        assert_eq!(s.next_cursor, 5);
        s.clear();
        assert!(s.records.is_empty());
        assert_eq!(s.next_cursor, 5, "clear must not reclaim the cursor");
        assert_eq!(s.next_record_id, 6, "ids continue after clear");
        assert!(s.by_record_id.is_empty());

        let next = s.push(rec("c", 999));
        assert_eq!(next, 6, "ids are never reused after a clear");
        let page = s.snapshot(0, 100, &RequestFilter::default());
        assert_eq!(page.next_cursor, 6);
        assert_eq!(page.first_cursor, 6);
        assert_eq!(page.retained, 1);
    }

    /// (c) filters are exact/substring as specified and ordering is deterministic.
    #[test]
    fn snapshot_filters_and_orders_deterministically() {
        let mut s = RequestStore::fresh();
        let mut a = rec("c1", 100);
        a.domain = "alpha.example.com".to_string();
        a.uid = Some(1000);
        a.network = "tcp".to_string();
        a.outbound = "DIRECT".to_string();
        let mut b = rec("c2", 200);
        b.domain = "beta.example.com".to_string();
        b.uid = Some(2000);
        b.network = "tcp".to_string();
        b.outbound = "PROXY".to_string();
        let mut c = rec("c3", 150);
        c.domain = "alpha.test".to_string();
        c.uid = Some(1000);
        c.network = "udp".to_string();
        c.outbound = "DIRECT".to_string();
        let mut d = rec("c4", 150);
        d.domain = "alpha.other".to_string();
        d.uid = Some(1000);
        d.network = "tcp".to_string();
        d.outbound = "DIRECT".to_string();
        let id_a = s.push(a);
        let id_b = s.push(b);
        let id_c = s.push(c);
        let id_d = s.push(d);

        let alpha = RequestFilter {
            domain: Some("alpha".to_string()),
            ..Default::default()
        };
        let page = s.snapshot(0, 100, &alpha);
        let ids: Vec<u64> = page.records.iter().map(|r| r.record_id).collect();
        assert_eq!(
            ids,
            vec![id_c, id_d, id_a],
            "openTsMs desc, ties by recordId asc"
        );

        // Determinism: the same query twice serializes byte-identically.
        let again = s.snapshot(0, 100, &alpha);
        assert_eq!(
            serde_json::to_string(&page).unwrap(),
            serde_json::to_string(&again).unwrap()
        );

        let by_uid = RequestFilter {
            uid: Some(2000),
            ..Default::default()
        };
        let page = s.snapshot(0, 100, &by_uid);
        assert_eq!(
            page.records.iter().map(|r| r.record_id).collect::<Vec<_>>(),
            vec![id_b]
        );

        let by_net = RequestFilter {
            network: Some("udp".to_string()),
            ..Default::default()
        };
        let page = s.snapshot(0, 100, &by_net);
        assert_eq!(
            page.records.iter().map(|r| r.record_id).collect::<Vec<_>>(),
            vec![id_c]
        );

        let by_out = RequestFilter {
            outbound: Some("PROXY".to_string()),
            ..Default::default()
        };
        let page = s.snapshot(0, 100, &by_out);
        assert_eq!(
            page.records.iter().map(|r| r.record_id).collect::<Vec<_>>(),
            vec![id_b]
        );

        let window = RequestFilter {
            since_ms: Some(140),
            until_ms: Some(160),
            ..Default::default()
        };
        let page = s.snapshot(0, 100, &window);
        assert_eq!(
            page.records.iter().map(|r| r.record_id).collect::<Vec<_>>(),
            vec![id_c, id_d]
        );

        // Cursor semantics: only records strictly newer than `since`, ordered.
        let page = s.snapshot(id_a, 100, &RequestFilter::default());
        assert_eq!(
            page.records.iter().map(|r| r.record_id).collect::<Vec<_>>(),
            vec![id_b, id_c, id_d]
        );
    }

    /// (d) failure path: inserting past the cap evicts oldest, advances
    /// firstCursor, never reclaims nextCursor, and keeps the index in sync.
    #[test]
    fn over_cap_evicts_oldest_and_keeps_cursor_and_index() {
        let cap = 8usize;
        let mut s = store_with_cap(cap);
        for i in 0..20u64 {
            s.push(rec("c", 100 + i));
        }
        assert_eq!(s.records.len(), cap);
        let page = s.snapshot(0, 1000, &RequestFilter::default());
        assert_eq!(page.retained, cap, "retained must equal cap");
        assert_eq!(page.capacity, cap);
        assert_eq!(page.evicted, 12, "20 inserted, 8 retained");
        assert_eq!(
            page.first_cursor, 13,
            "firstCursor must advance past the 12 evicted records"
        );
        assert_eq!(
            page.next_cursor, 20,
            "nextCursor is the global high-water mark, not reclaimed"
        );
        assert_eq!(page.window_start_ms, 112, "oldest retained openTsMs");

        // byRecordId index must agree with the deque after eviction.
        assert_eq!(s.by_record_id.len(), s.records.len());
        for (i, r) in s.records.iter().enumerate() {
            assert_eq!(
                s.by_record_id.get(&r.record_id).copied(),
                Some(i),
                "index desync at position {i}"
            );
        }
    }

    /// (d) empty ring snapshot must not panic (local and global free function).
    #[test]
    fn empty_ring_snapshot_does_not_panic() {
        let s = RequestStore::fresh();
        let page = s.snapshot(0, 100, &RequestFilter::default());
        assert!(page.records.is_empty());
        assert_eq!(page.first_cursor, 0);
        assert_eq!(page.next_cursor, 0);
        assert_eq!(page.retained, 0);
        assert_eq!(page.window_start_ms, 0);

        clear();
        let global = snapshot(0, 100, &RequestFilter::default());
        assert!(global.records.is_empty());
        assert_eq!(global.first_cursor, 0);
    }

    /// Malformed / edge filter inputs must not panic.
    #[test]
    fn malformed_snapshot_inputs_do_not_panic() {
        let mut s = RequestStore::fresh();
        for i in 0..3u64 {
            s.push(rec("c", 100 + i));
        }
        // limit 0 -> empty page.
        assert!(s.snapshot(0, 0, &RequestFilter::default()).records.is_empty());
        // reversed time range -> nothing matches.
        let reversed = RequestFilter {
            since_ms: Some(500),
            until_ms: Some(100),
            ..Default::default()
        };
        assert!(s.snapshot(0, 100, &reversed).records.is_empty());
        // absurd cursor/limit -> no panic.
        assert!(s
            .snapshot(u64::MAX, usize::MAX, &RequestFilter::default())
            .records
            .is_empty());
        // blank string filters are ignored, not matched literally.
        let blank = RequestFilter {
            domain: Some("   ".to_string()),
            network: Some(String::new()),
            outbound: None,
            ..Default::default()
        };
        assert_eq!(s.snapshot(0, 100, &blank).records.len(), 3);
    }

    /// (e) `uidState` three-state camelCase serialization.
    #[test]
    fn uid_state_serializes_three_states() {
        let mut s = RequestStore::fresh();
        let mut known = rec("c", 1);
        known.uid = Some(10_123);
        known.uid_state = UID_STATE_KNOWN.to_string();
        let mut pending = rec("c", 2);
        pending.uid_state = UID_STATE_PENDING.to_string();
        let mut unknown = rec("c", 3);
        unknown.uid_state = UID_STATE_UNKNOWN.to_string();
        s.push(known);
        s.push(pending);
        s.push(unknown);

        let page = s.snapshot(0, 100, &RequestFilter::default());
        let json = serde_json::to_value(&page).unwrap();
        let arr = json["records"].as_array().unwrap();
        // openTsMs desc -> unknown(3), pending(2), known(1)
        assert_eq!(arr[0]["uidState"], "unknown");
        assert_eq!(arr[1]["uidState"], "pending");
        assert_eq!(arr[2]["uidState"], "known");

        // camelCase keys are stable and `Option` timestamps serialize as null.
        for key in [
            "recordId",
            "connId",
            "openTsMs",
            "closeTsMs",
            "durationMs",
            "domain",
            "domainKnown",
            "dstIp",
            "dstPort",
            "src",
            "network",
            "uid",
            "packages",
            "uidState",
            "rule",
            "rulePayload",
            "outbound",
            "uploadBytes",
            "downloadBytes",
            "closeReason",
        ] {
            assert!(arr[0].get(key).is_some(), "missing camelCase key {key}");
        }
        assert!(arr[2]["closeTsMs"].is_null());
        assert!(arr[2]["durationMs"].is_null());
    }

    /// The shipping cap is real: 4097 inserts retain exactly 4096.
    #[test]
    fn default_cap_retains_exactly_4096() {
        let mut s = RequestStore::fresh();
        for i in 0..(REQUEST_RING_CAP as u64 + 1) {
            s.push(rec("c", i));
        }
        assert_eq!(s.records.len(), REQUEST_RING_CAP);
        assert_eq!(s.evicted, 1);
        assert_eq!(s.snapshot(0, usize::MAX, &RequestFilter::default()).retained, REQUEST_RING_CAP);
    }

    // --- Todo 2: single-chokepoint capture + stale_live reconciliation ---

    use crate::conn::ConnRecord;

    fn conn_rec(id: &str, started_at_ms: u64) -> ConnRecord {
        ConnRecord {
            id: id.to_string(),
            src: "10.0.0.2:5555".to_string(),
            dst: "1.2.3.4:443".to_string(),
            dst_ip: "1.2.3.4".to_string(),
            dst_port: 443,
            domain: "req.example".to_string(),
            network: "tcp".to_string(),
            rule: "MATCH".to_string(),
            rule_payload: String::new(),
            outbound: "DIRECT".to_string(),
            started_at_ms,
            upload_bytes: 0,
            download_bytes: 0,
        }
    }

    /// A terminal record is closed exactly once: a second close is a no-op and
    /// must never overwrite `closeTsMs`/`durationMs`.
    #[test]
    fn record_close_is_terminal_and_idempotent_per_record_id() {
        let mut s = RequestStore::fresh();
        let c = conn_rec("c1", 1_000);
        let id = s.open_record(&c, 1_000);
        assert_eq!(id, 1);
        assert_eq!(s.records[0].close_reason, CLOSE_REASON_OPEN);

        assert!(s.finalize("c1", 1_500));
        assert_eq!(s.records[0].close_ts_ms, Some(1_500));
        assert_eq!(s.records[0].duration_ms, Some(500));
        assert_eq!(s.records[0].close_reason, CLOSE_REASON_CLOSED);

        assert!(!s.finalize("c1", 2_000), "second close is a no-op");
        assert_eq!(s.records[0].close_ts_ms, Some(1_500), "closeTs untouched");
        assert_eq!(s.records[0].duration_ms, Some(500), "duration untouched");
        assert!(s.active_by_conn.is_empty());
    }

    // --- MITM synthesized skeleton records (request-timeline registration) ---

    fn mitm_endpoints() -> (std::net::SocketAddr, std::net::SocketAddr) {
        (
            "10.0.0.2:41000".parse().unwrap(),
            "203.0.113.9:443".parse().unwrap(),
        )
    }

    fn row_by_id(page: &RequestSnapshot, id: u64) -> RequestRecord {
        page.records
            .iter()
            .find(|r| r.record_id == id)
            .cloned()
            .unwrap_or_else(|| panic!("record {id} missing from snapshot"))
    }

    /// Happy QA: `open_mitm_flow` mints an open skeleton record whose domain is
    /// the MITM host (known) and whose close fields are not yet terminal.
    #[test]
    fn open_mitm_flow_registers_open_skeleton_record() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let (src, dst) = mitm_endpoints();
        let rid = open_mitm_flow("mitm-open", "shop.example", src, dst, 5_000);

        let page = snapshot(0, 10, &RequestFilter::default());
        let r = row_by_id(&page, rid);
        assert_eq!(r.domain, "shop.example");
        assert!(r.domain_known);
        assert_eq!(r.close_reason, "open");
        assert_eq!(r.duration_ms, None);
        assert_eq!(r.close_ts_ms, None);
        assert_eq!(r.dst_ip, "203.0.113.9");
        assert_eq!(r.dst_port, 443);
        assert_eq!(r.network, "tcp");
    }

    /// `close_mitm_flow` writes the single terminal transition, and a repeated
    /// close never overwrites `closeTsMs`/`durationMs`.
    #[test]
    fn close_mitm_flow_finalizes_once_and_is_idempotent() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let (src, dst) = mitm_endpoints();
        let rid = open_mitm_flow("mitm-close", "shop.example", src, dst, 5_000);

        close_mitm_flow("mitm-close", 5_400);
        let first = row_by_id(&snapshot(0, 10, &RequestFilter::default()), rid);
        assert_eq!(first.close_reason, "closed");
        assert!(first.close_ts_ms.is_some());
        let duration = first.duration_ms;
        assert!(duration.is_some());
        assert_eq!(duration, Some(400));

        close_mitm_flow("mitm-close", 9_999);
        let second = row_by_id(&snapshot(0, 10, &RequestFilter::default()), rid);
        assert_eq!(second.duration_ms, duration, "second close is a no-op");
        assert_eq!(second.close_ts_ms, Some(5_400));
    }

    /// Failure QA: closing a `conn_id` that was never opened (or was already
    /// evicted) is a silent no-op and never fabricates a record.
    #[test]
    fn close_mitm_flow_unknown_conn_is_silent_noop() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        close_mitm_flow("never-opened", 1_000);
        let page = snapshot(0, 10, &RequestFilter::default());
        assert!(page.records.is_empty(), "no record is fabricated");
    }

    /// A stale record is NOT terminal: no `closeTsMs`, no `durationMs`. Only the
    /// real departure writes the single terminal `closed`.
    #[test]
    fn stale_is_non_terminal_and_finalize_writes_one_terminal() {
        let mut s = RequestStore::fresh();
        let c = conn_rec("c1", 1_000);
        let id = s.open_record(&c, 1_000);
        s.mark_stale("c1");
        assert_eq!(s.records[0].close_reason, CLOSE_REASON_STALE);
        assert_eq!(s.records[0].close_ts_ms, None, "stale is not terminal");
        assert_eq!(s.records[0].duration_ms, None, "stale carries no duration");
        assert_eq!(s.stale_live.len(), 1);

        assert!(s.finalize("c1", 1_800));
        assert_eq!(s.records[0].record_id, id);
        assert_eq!(s.records[0].close_reason, CLOSE_REASON_CLOSED);
        assert_eq!(s.records[0].close_ts_ms, Some(1_800));
        assert_eq!(s.records[0].duration_ms, Some(800));
        assert!(s.stale_live.is_empty(), "terminal removes the suppression");

        assert!(!s.finalize("c1", 2_500), "close after stale is a no-op");
        assert_eq!(s.records[0].close_ts_ms, Some(1_800));
        assert_eq!(s.records[0].duration_ms, Some(800));
    }

    /// A stale id that re-enters the projection must NOT mint a new record.
    #[test]
    fn reentering_stale_id_keeps_one_record_and_counts_reentered() {
        let mut s = RequestStore::fresh();
        let c = conn_rec("c1", 1_000);
        let first = s.open_record(&c, 1_000);
        s.mark_stale("c1");
        let again = s.open_record(&c, 1_200);
        assert_eq!(again, first, "re-entry must not mint a new recordId");
        assert_eq!(s.records.len(), 1);
        assert_eq!(s.reentered, 1);
        assert_eq!(s.records[0].close_reason, CLOSE_REASON_OPEN);
        assert_eq!(s.stale_live.len(), 1, "suppression persists until departure");
    }

    /// Id reuse after a terminal is a NEW record (never an overwrite).
    #[test]
    fn open_after_terminal_mints_a_new_record_id() {
        let mut s = RequestStore::fresh();
        let c = conn_rec("c1", 1_000);
        let first = s.open_record(&c, 1_000);
        s.finalize("c1", 1_100);
        let second = s.open_record(&c, 2_000);
        assert_ne!(first, second, "terminal reuse mints a fresh recordId");
        assert_eq!(s.records.len(), 2);
    }

    /// `stale_live` is bounded: over cap the oldest `openTsMs` is evicted and
    /// `dropped` increments (never unbounded growth).
    #[test]
    fn stale_live_over_cap_evicts_oldest_and_counts_dropped() {
        let mut s = RequestStore::fresh();
        s.stale_live_cap = 4;
        for i in 0..6u64 {
            let c = conn_rec(&format!("c{i}"), 1_000 + i);
            s.open_record(&c, 1_000 + i);
            s.mark_stale(&c.id);
        }
        assert_eq!(s.stale_live.len(), 4);
        assert_eq!(s.dropped, 2);
        for evicted in ["c0", "c1"] {
            assert!(!s.stale_live.contains_key(evicted), "{evicted} evicted");
        }
        for kept in ["c2", "c3", "c4", "c5"] {
            assert!(s.stale_live.contains_key(kept), "{kept} retained");
        }
        assert_eq!(STALE_LIVE_CAP, 4096);
    }

    /// Only ids absent from the meow live table are finalized as `closed`; ids
    /// still live stay stale.
    #[test]
    fn finalize_departed_only_closes_ids_absent_from_live_table() {
        let mut s = RequestStore::fresh();
        let a = conn_rec("c-a", 100);
        let b = conn_rec("c-b", 200);
        s.open_record(&a, 100);
        s.open_record(&b, 200);
        s.mark_stale("c-a");
        s.mark_stale("c-b");

        let closed = s.finalize_departed(300, |id| id == "c-b");
        assert_eq!(closed, 1);
        let rec_a = s.records.iter().find(|r| r.conn_id == "c-a").unwrap();
        assert_eq!(rec_a.close_reason, CLOSE_REASON_CLOSED);
        assert_eq!(rec_a.close_ts_ms, Some(300));
        let rec_b = s.records.iter().find(|r| r.conn_id == "c-b").unwrap();
        assert_eq!(rec_b.close_reason, CLOSE_REASON_STALE);
        assert_eq!(rec_b.close_ts_ms, None);
        assert_eq!(s.stale_live.len(), 1);
    }

    /// `close_all` terminalizes every active record exactly once.
    #[test]
    fn close_all_records_finalizes_every_active_once() {
        let mut s = RequestStore::fresh();
        for i in 0..3u64 {
            let c = conn_rec(&format!("c{i}"), 1_000 + i);
            s.open_record(&c, 1_000 + i);
        }
        s.mark_stale("c1");
        assert_eq!(s.close_all_records(2_000), 3);
        for r in &s.records {
            assert_eq!(r.close_reason, CLOSE_REASON_CLOSED);
            assert_eq!(r.close_ts_ms, Some(2_000));
        }
        assert!(s.active_by_conn.is_empty());
        assert!(s.stale_live.is_empty());
        assert_eq!(s.close_all_records(3_000), 0, "second close_all is a no-op");
    }

    /// T3: the structured destination and network captured by `from_info` are
    /// projected verbatim into the request record (no re-parse of `dst`).
    #[test]
    fn open_record_projects_structured_dst_and_network() {
        let mut s = RequestStore::fresh();
        let mut c = conn_rec("c1", 1_000);
        c.dst = "2001:db8::1:8443".to_string();
        c.dst_ip = "2001:db8::1".to_string();
        c.dst_port = 8443;
        c.network = "tcp".to_string();
        s.open_record(&c, 1_000);

        let r = &s.records[0];
        assert_eq!(r.dst_ip, "2001:db8::1", "bare IPv6, no brackets");
        assert_eq!(r.dst_port, 8443);
        assert_eq!(r.network, "tcp");
        // `dst` is never parsed or rewritten by the projection.
        assert_eq!(c.dst, "2001:db8::1:8443");
    }

    /// Malformed/blank structured inputs must not panic and must not be
    /// fabricated into fake values.
    #[test]
    fn open_record_with_blank_dst_ip_and_zero_port_does_not_panic() {
        let mut s = RequestStore::fresh();
        let mut c = conn_rec("c1", 1_000);
        c.dst = String::new();
        c.dst_ip = String::new();
        c.dst_port = 0;
        let id = s.open_record(&c, 1_000);
        assert_eq!(id, 1);
        let r = &s.records[0];
        assert_eq!(r.dst_ip, "");
        assert_eq!(r.dst_port, 0);
    }

    /// Stale-state probe: a flow re-entering the projection reuses its record and
    /// must not overwrite the structured dst captured at first open.
    #[test]
    fn reentry_reuses_structured_dst_without_overwrite() {
        let mut s = RequestStore::fresh();
        let mut first = conn_rec("c1", 1_000);
        first.dst_ip = "1.2.3.4".to_string();
        first.dst_port = 443;
        let id = s.open_record(&first, 1_000);
        s.mark_stale("c1");

        let mut second = conn_rec("c1", 1_200);
        second.dst_ip = "9.9.9.9".to_string();
        second.dst_port = 8443;
        let again = s.open_record(&second, 1_200);

        assert_eq!(again, id, "re-entry reuses the record");
        assert_eq!(s.records.len(), 1);
        assert_eq!(s.records[0].dst_ip, "1.2.3.4", "original dstIp preserved");
        assert_eq!(s.records[0].dst_port, 443, "original dstPort preserved");
    }

    // --- Todo 4: shared domain resolution with `stats::resolve_domain` ---

    use crate::dns::{DnsConfig, DnsModeKind};
    use crate::TEST_SERIAL as SERIAL;

    fn stats_domain(domain_key: &str) -> (String, bool) {
        let data = crate::stats::domain_get_arm(b"{}").unwrap();
        let json: serde_json::Value = serde_json::from_slice(&data).unwrap();
        let arr = json["data"]["domains"].as_array().unwrap();
        let d = arr
            .iter()
            .find(|d| d["domain"] == domain_key)
            .unwrap_or_else(|| panic!("stats domain '{domain_key}' missing: {arr:?}"));
        (
            d["domain"].as_str().unwrap().to_string(),
            d["domainKnown"].as_bool().unwrap(),
        )
    }

    fn install_fake_ip_engine() -> std::sync::Arc<crate::dns::DnsEngine> {
        let cfg = DnsConfig {
            mode: DnsModeKind::FakeIp,
            nameservers: vec!["127.0.0.1".to_string()],
            ..Default::default()
        };
        crate::dns::set_config(cfg).expect("fake-ip engine installs")
    }

    /// Happy QA: a plain-IP flow is `domainKnown=false` and the requests record
    /// carries the structured `dstIp` verbatim — and the stats aggregate agrees.
    #[test]
    fn plain_ip_flow_domain_matches_stats_and_target_ip() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        crate::stats::reset_for_tests();

        let mut c = conn_rec("c-plain", 1_000);
        c.domain = "203.0.113.7".to_string();
        c.dst = "203.0.113.7:443".to_string();
        c.dst_ip = "203.0.113.7".to_string();
        c.dst_port = 443;

        record_open(&c, 1_000);
        let page = snapshot(0, 100, &RequestFilter::default());
        let r = &page.records[0];
        assert_eq!(r.domain, "203.0.113.7", "exact string, not presence");
        assert!(!r.domain_known, "plain IP must be domainKnown=false");
        assert_eq!(r.domain, r.dst_ip, "unknown domain holds the target IP");

        crate::stats::observe_for_tests(std::slice::from_ref(&c), &[], 1_000);
        let (stat_domain, stat_known) = stats_domain("203.0.113.7");
        assert_eq!(stat_domain, "203.0.113.7");
        assert!(!stat_known);
        assert_eq!(r.domain, stat_domain, "requests and stats must agree");
    }

    /// Failure QA (adversarial): an empty domain falls back to the structured
    /// `dstIp`; no domain is ever fabricated.
    #[test]
    fn empty_domain_falls_back_to_dst_ip_not_fabricated() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let mut c = conn_rec("c-empty-domain", 1_000);
        c.domain = String::new();
        c.dst = "198.51.100.9:8443".to_string();
        c.dst_ip = "198.51.100.9".to_string();
        c.dst_port = 8443;

        record_open(&c, 1_000);
        let page = snapshot(0, 100, &RequestFilter::default());
        let r = &page.records[0];
        assert_eq!(r.domain, "198.51.100.9", "no fabricated domain; the IP is used");
        assert!(!r.domain_known);
        assert_eq!(r.domain, r.dst_ip);
    }

    /// Happy QA: a fake-IP mapping hit yields `domainKnown=true` and the SAME
    /// domain on the requests and stats paths.
    #[test]
    fn fake_ip_mapping_hit_marks_domain_known_and_agrees_with_stats() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        crate::stats::reset_for_tests();
        let engine = install_fake_ip_engine();
        let fake = engine
            .resolver()
            .fakeip_pool_over("198.18.0.0/16".parse().unwrap())
            .expect("v4 fake-ip pool installed")
            .lookup("fixture.example");
        assert!(engine.resolver().is_fake_ip(fake));
        assert!(engine.domain_for_ip(fake).is_some());

        let mut c = conn_rec("c-fake", 2_000);
        c.domain = fake.to_string();
        c.dst = format!("{fake}:443");
        c.dst_ip = fake.to_string();
        c.dst_port = 443;

        record_open(&c, 2_000);
        let page = snapshot(0, 100, &RequestFilter::default());
        let r = &page.records[0];
        assert_eq!(r.domain, "fixture.example");
        assert!(r.domain_known);

        crate::stats::observe_for_tests(std::slice::from_ref(&c), &[], 2_000);
        let (stat_domain, stat_known) = stats_domain("fixture.example");
        assert!(stat_known);
        assert_eq!(r.domain, stat_domain, "requests and stats must agree");
    }

    /// Adversarial stale_state: once the fake-IP mapping is flushed, the same
    /// target IP resolves to the IP — the earlier domain is never reused/cached.
    #[test]
    fn flushed_fake_ip_mapping_makes_domain_unknown_not_cached() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let engine = install_fake_ip_engine();
        let fake = engine
            .resolver()
            .fakeip_pool_over("198.18.0.0/16".parse().unwrap())
            .expect("v4 fake-ip pool installed")
            .lookup("stale.example");

        let mut c = conn_rec("c-stale", 3_000);
        c.domain = fake.to_string();
        c.dst = format!("{fake}:443");
        c.dst_ip = fake.to_string();
        c.dst_port = 443;

        record_open(&c, 3_000);
        let page = snapshot(0, 100, &RequestFilter::default());
        assert_eq!(page.records[0].domain, "stale.example");
        assert!(page.records[0].domain_known);

        engine.clear_cache();
        assert!(
            engine.domain_for_ip(fake).is_none(),
            "fake-IP mapping flushed before the second flow"
        );

        reset_for_tests();
        record_open(&c, 4_000);
        let page = snapshot(0, 100, &RequestFilter::default());
        let r = &page.records[0];
        assert_eq!(r.domain, fake.to_string(), "no stale/fabricated domain");
        assert!(!r.domain_known);
        assert_eq!(r.domain, r.dst_ip);
    }

    /// Boundary: a bare IPv6 target resolves to the IPv6 IP, never a fabricated
    /// domain, and equals the structured `dstIp`.
    #[test]
    fn ipv6_target_is_ip_not_fabricated_domain() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let mut c = conn_rec("c-v6", 5_000);
        c.domain = "2001:db8::1".to_string();
        c.dst = "2001:db8::1:443".to_string();
        c.dst_ip = "2001:db8::1".to_string();
        c.dst_port = 443;

        record_open(&c, 5_000);
        let page = snapshot(0, 100, &RequestFilter::default());
        let r = &page.records[0];
        assert_eq!(r.domain, "2001:db8::1");
        assert_eq!(r.domain, r.dst_ip);
        assert!(!r.domain_known);
    }

    /// Boundary: blank domain AND blank destination must not panic and must not
    /// invent a domain.
    #[test]
    fn blank_domain_and_blank_dst_do_not_fabricate_a_domain() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let mut c = conn_rec("c-blank", 6_000);
        c.domain = String::new();
        c.dst = String::new();
        c.dst_ip = String::new();
        c.dst_port = 0;

        record_open(&c, 6_000);
        let page = snapshot(0, 100, &RequestFilter::default());
        let r = &page.records[0];
        assert_eq!(r.domain, "", "nothing to resolve: never fabricated");
        assert!(!r.domain_known);
        assert_eq!(r.domain, r.dst_ip);
    }

    // --- Todo 5: `requests.get` / `requests.reset` dispatch arms ---

    fn arm_data(bytes: &[u8]) -> serde_json::Value {
        let v: serde_json::Value = serde_json::from_slice(bytes).unwrap();
        assert_eq!(v["ok"], true, "arm must return an ok envelope: {v}");
        v["data"].clone()
    }

    /// Happy: an empty payload yields the default `RequestPage` (ok envelope).
    #[test]
    fn requests_get_arm_empty_payload_returns_ok_page() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let data = arm_data(&get_arm(b"").unwrap());
        assert!(data["records"].as_array().unwrap().is_empty());
        assert_eq!(data["nextCursor"], 0);
        assert_eq!(data["firstCursor"], 0);
        assert_eq!(data["retained"], 0);
        assert_eq!(data["capacity"], REQUEST_RING_CAP);
    }

    /// Happy: cursor/limit/filter are applied over the shared store.
    #[test]
    fn requests_get_arm_applies_cursor_limit_and_filter() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let mut a = conn_rec("c1", 100);
        a.domain = "alpha.example.com".to_string();
        let mut b = conn_rec("c2", 200);
        b.domain = "beta.example.com".to_string();
        record_open(&a, 100);
        record_open(&b, 200);

        let payload = br#"{"cursor":0,"limit":1,"filter":{"domain":"example.com"}}"#;
        let data = arm_data(&get_arm(payload).unwrap());
        let arr = data["records"].as_array().unwrap();
        assert_eq!(arr.len(), 1, "limit must bound the page");
        assert_eq!(arr[0]["domain"], "beta.example.com", "openTsMs desc");
        assert_eq!(data["nextCursor"], 2);
        assert_eq!(data["retained"], 2);

        // cursor past the high-water mark -> empty page, cursor preserved.
        let data = arm_data(&get_arm(br#"{"cursor":2}"#).unwrap());
        assert!(data["records"].as_array().unwrap().is_empty());
        assert_eq!(data["nextCursor"], 2);
    }

    /// Malformed request bodies are a structured 422, never a panic.
    #[test]
    fn requests_get_arm_malformed_payload_is_invalid_arg() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        for bad in [
            &br#"{"cursor":"nope"}"#[..],
            &br#"{"cursor":"#[..],
            &br#"{"limit":true}"#[..],
            &br#"{"filter":42}"#[..],
        ] {
            let err = get_arm(bad).unwrap_err();
            assert_eq!(err.status as i32, 422, "payload {bad:?}");
        }
    }

    /// Boundary: cursor at `u64::MAX` and `limit:0` must not panic.
    #[test]
    fn requests_get_arm_boundary_cursor_max_and_limit_zero() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let c = conn_rec("c1", 1);
        record_open(&c, 1);
        let data = arm_data(
            &get_arm(format!(r#"{{"cursor":{}}}"#, u64::MAX).as_bytes()).unwrap(),
        );
        assert!(data["records"].as_array().unwrap().is_empty());
        let data = arm_data(&get_arm(br#"{"limit":0}"#).unwrap());
        assert!(data["records"].as_array().unwrap().is_empty());
        assert_eq!(data["retained"], 1);
    }

    /// `requests.reset` clears the ring, reports the count, and never reclaims
    /// the cursor (stale_state: a snapshot after reset is empty).
    #[test]
    fn requests_reset_arm_clears_ring_and_reports_count() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        record_open(&conn_rec("c1", 1), 1);
        record_open(&conn_rec("c2", 2), 2);

        let data = arm_data(&reset_arm().unwrap());
        assert_eq!(data["ok"], true);
        assert_eq!(data["cleared"], 2);
        let page = snapshot(0, 100, &RequestFilter::default());
        assert!(page.records.is_empty());
        assert_eq!(page.retained, 0);
        assert_eq!(page.next_cursor, 2, "reset must not reclaim the cursor");

        let data = arm_data(&get_arm(b"").unwrap());
        assert!(data["records"].as_array().unwrap().is_empty());
        assert_eq!(data["retained"], 0);
    }

    // --- Todo 6: `proxy.request` dirty signal (throttled, only via tick) ---

    fn take_request_events() -> Vec<serde_json::Value> {
        let drained = std::mem::take(
            &mut *crate::TEST_EMITTED
                .lock()
                .unwrap_or_else(|e| e.into_inner()),
        );
        drained
            .into_iter()
            .filter(|(kind, _)| kind == crate::EVT_REQUEST)
            .map(|(_, payload)| {
                serde_json::from_slice(&payload).expect("proxy.request payload must be JSON")
            })
            .collect()
    }

    /// Happy QA: one `tick` emits a payload-free `proxy.request` through the
    /// module event lane (`emit_event`), carrying only `{seq,count,tsMs}` — no
    /// per-record data ever leaks.
    #[test]
    fn tick_emits_payload_free_dirty_signal_on_the_module_event_bus() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let _ = take_request_events();

        record_open(&conn_rec("c1", 1_000), 1_000);
        assert!(tick(7, crate::ProxyMode::Vpn, 1_000), "a change at/after the window must emit");

        let events = take_request_events();
        assert_eq!(events.len(), 1, "exactly one proxy.request event");
        let obj = events[0].as_object().unwrap();
        let mut keys: Vec<&String> = obj.keys().collect();
        keys.sort();
        assert_eq!(keys, vec!["count", "seq", "tsMs"]);
        assert_eq!(events[0]["count"], 1);
        assert_eq!(events[0]["seq"], 1);
        assert_eq!(events[0]["tsMs"], 1_000);
        for leaked in ["records", "recordId", "connId", "domain", "dstIp", "src"] {
            assert!(
                obj.get(leaked).is_none(),
                "payload must not leak per-record key {leaked}"
            );
        }
    }

    /// The capture chokepoint marks data dirty but NEVER emits by itself; the
    /// dirty signal is only ever produced by `requests::tick`.
    #[test]
    fn capture_never_emits_per_record_only_tick_does() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let _ = take_request_events();

        record_open(&conn_rec("c1", 1_000), 1_000);
        record_open(&conn_rec("c2", 1_100), 1_100);
        record_close(&conn_rec("c1", 1_200), 1_200, CloseReason::Closed);
        assert!(
            take_request_events().is_empty(),
            "record_open/record_close must never emit a per-record event"
        );

        assert!(tick(7, crate::ProxyMode::Vpn, 1_500), "one tick flushes the accumulated changes");
        assert_eq!(take_request_events().len(), 1);
    }

    /// Failure QA: a second change within the 1s window is suppressed; the
    /// pending changes are carried into the next allowed emit.
    #[test]
    fn tick_suppresses_second_change_within_one_second() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let _ = take_request_events();

        record_open(&conn_rec("c1", 1_000), 1_000);
        assert!(tick(7, crate::ProxyMode::Vpn, 1_000));
        assert_eq!(take_request_events().len(), 1);

        record_open(&conn_rec("c2", 1_100), 1_100);
        assert!(!tick(7, crate::ProxyMode::Vpn, 1_100), "second change within 1s must be suppressed");
        assert!(take_request_events().is_empty(), "no event while throttled");

        record_open(&conn_rec("c3", 1_900), 1_900);
        assert!(tick(7, crate::ProxyMode::Vpn, 2_000), "after 1s the pending changes emit");
        let events = take_request_events();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["seq"], 2, "seq increments per emitted signal");
        assert!(
            events[0]["count"].as_u64().unwrap() >= 2,
            "count carries the changes suppressed by the throttle"
        );
    }

    /// Adversarial stale_state: `requests.reset` never emits, and `seq` stays
    /// monotonic across a reset.
    #[test]
    fn tick_emits_nothing_when_unchanged_and_seq_survives_reset() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let _ = take_request_events();

        assert!(!tick(7, crate::ProxyMode::Vpn, 5_000), "no change at all -> no signal");
        assert!(take_request_events().is_empty());

        record_open(&conn_rec("c1", 5_000), 5_000);
        assert!(tick(7, crate::ProxyMode::Vpn, 5_000));
        let first_seq = take_request_events()[0]["seq"].as_u64().unwrap();

        assert!(!tick(7, crate::ProxyMode::Vpn, 9_000), "unchanged -> still no signal");
        assert!(take_request_events().is_empty());

        clear();
        assert!(!tick(7, crate::ProxyMode::Vpn, 9_500), "reset itself must not emit");
        assert!(take_request_events().is_empty());

        record_open(&conn_rec("c2", 10_000), 10_000);
        assert!(tick(7, crate::ProxyMode::Vpn, 10_000));
        let events = take_request_events();
        assert_eq!(events.len(), 1);
        assert!(
            events[0]["seq"].as_u64().unwrap() > first_seq,
            "seq is monotonic across reset"
        );
    }

    /// Adversarial race: concurrent ticks sharing one store never panic and
    /// never mint a duplicate `seq`.
    #[test]
    fn concurrent_ticks_have_no_panic_and_no_duplicate_seq() {
        use std::sync::{Arc, Mutex};
        let store = Arc::new(Mutex::new(RequestStore::fresh()));
        {
            let mut s = store.lock().unwrap();
            s.open_record(&conn_rec("seed", 1_000), 1_000);
        }

        let mut handles = Vec::new();
        for t in 0..8u64 {
            let store = Arc::clone(&store);
            handles.push(std::thread::spawn(move || {
                let mut seqs = Vec::new();
                for i in 0..50u64 {
                    let mut s = store.lock().unwrap_or_else(|e| e.into_inner());
                    if i % 2 == 0 {
                        s.push(rec("c", 1_000 + i));
                    }
                    if let Some(v) = s.emit_pending(1_000 + t * 1_000 + i * 1_000) {
                        seqs.push(v["seq"].as_u64().unwrap());
                    }
                }
                seqs
            }));
        }

        let mut all: Vec<u64> = handles
            .into_iter()
            .flat_map(|h| h.join().expect("no thread may panic"))
            .collect();
        all.sort_unstable();
        let unique: std::collections::HashSet<u64> = all.iter().copied().collect();
        assert!(!all.is_empty(), "at least one concurrent emit happened");
        assert_eq!(all.len(), unique.len(), "no duplicate seq under concurrency");
        for pair in all.windows(2) {
            assert!(pair[0] < pair[1], "seq strictly monotonic under concurrency");
        }
    }

    // --- Todo 8: SQLite rolling persistence + DB-authoritative reads ---

    use std::sync::atomic::{AtomicU64 as SeqCounter, Ordering as SeqOrder};

    static TEMP_SEQ: SeqCounter = SeqCounter::new(0);

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let n = TEMP_SEQ.fetch_add(1, SeqOrder::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "gstore-req-{}-{}-{}",
            std::process::id(),
            tag,
            n
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn fixture_now() -> u64 {
        1_700_000_000_000
    }

    fn db_page(since: u64, limit: usize) -> RequestSnapshot {
        snapshot(since, limit, &RequestFilter::default())
    }

    fn ids_of(page: &RequestSnapshot) -> Vec<u64> {
        page.records.iter().map(|r| r.record_id).collect()
    }

    fn page_row(open_ts: u64, id: u64) -> RequestRecord {
        let mut r = rec(&format!("c{id}"), open_ts);
        r.record_id = id;
        r
    }

    #[test]
    fn persist_file_has_wal_and_busy_timeout() {
        let dir = temp_dir("wal");
        let path = dir.join("proxy_requests.db");
        let db = Persist::open(path.to_str().unwrap()).unwrap();
        let mode: String = db
            .conn
            .query_row("PRAGMA journal_mode", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode.to_lowercase(), "wal", "WAL must be enabled");
        let timeout: i64 = db
            .conn
            .query_row("PRAGMA busy_timeout", [], |r| r.get(0))
            .unwrap();
        assert!(timeout > 0, "explicit busy_timeout must be configured");
        assert_eq!(db.max_rows, REQUEST_MAX_ROWS);
        drop(db);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Cap-first: with `max_rows=3`, a 5-row batch keeps the 3 newest and the
    /// final set is provably cap-first (a time-first prune would keep id 4 too).
    #[test]
    fn prune_is_cap_first_not_time_first() {
        let now = fixture_now();
        let mut db = Persist::open_in_memory().unwrap();
        db.set_max_rows(3);
        let fresh: Vec<RequestRecord> = (1..=3).map(|i| page_row(now + i, i)).collect();
        db.upsert_batch(&fresh, now).unwrap();

        let edge = page_row(now - REQUEST_RETENTION_MS, 4);
        let stale = page_row(now - REQUEST_RETENTION_MS - 1, 5);
        let pruned = db.upsert_batch(&[edge, stale], now).unwrap();
        assert_eq!(pruned, 2, "cap-first evicts the 2 oldest, not the 2 stale");
        assert_eq!(
            db.all_record_ids().unwrap(),
            vec![1, 2, 3],
            "cap-first keeps the newest 3; time-first would have kept id 4"
        );
    }

    /// Time prune fires only when the cap is not exceeded; the 7-day boundary
    /// keeps a row exactly at the edge and drops one millisecond older.
    #[test]
    fn time_prune_boundary_at_exactly_seven_days() {
        let now = fixture_now();
        let mut db = Persist::open_in_memory().unwrap();
        db.set_max_rows(100);
        let edge = page_row(now - REQUEST_RETENTION_MS, 1);
        let stale = page_row(now - REQUEST_RETENTION_MS - 1, 2);
        let fresh = page_row(now, 3);
        let pruned = db.upsert_batch(&[edge, stale, fresh], now).unwrap();
        assert_eq!(pruned, 1, "only the sub-window row is time-pruned");
        assert_eq!(db.all_record_ids().unwrap(), vec![1, 3]);
    }

    #[test]
    fn cap_prunes_at_exactly_fifty_thousand() {
        assert_eq!(REQUEST_MAX_ROWS, 50_000);
        let now = fixture_now();
        let mut db = Persist::open_in_memory().unwrap();
        let rows: Vec<RequestRecord> = (0..REQUEST_MAX_ROWS as u64)
            .map(|i| page_row(now + i, i + 1))
            .collect();
        assert_eq!(
            db.upsert_batch(&rows, now).unwrap(),
            0,
            "exactly 50k rows: no prune"
        );
        assert_eq!(db.count(0).unwrap(), REQUEST_MAX_ROWS);

        let extra = page_row(now + REQUEST_MAX_ROWS as u64, REQUEST_MAX_ROWS as u64 + 1);
        assert_eq!(db.upsert_batch(&[extra], now).unwrap(), 1, "one over 50k prunes the oldest");
        assert_eq!(db.count(0).unwrap(), REQUEST_MAX_ROWS);
        let ids = db.all_record_ids().unwrap();
        assert_eq!(*ids.first().unwrap(), 2, "oldest (id 1) pruned");
        assert_eq!(*ids.last().unwrap(), REQUEST_MAX_ROWS as u64 + 1);
    }

    /// DB-authoritative read: the ring is capped at 3 yet all 10 rows are served.
    #[test]
    fn db_read_is_authoritative_beyond_the_ring_cap() {
        reset_for_tests();
        let dir = temp_dir("dbauth");
        let now = fixture_now();
        configure_at(dir.to_str().unwrap(), now);
        assert!(db_configured_for_tests());
        with_store(|st| st.cap = 3);

        for i in 0..10u64 {
            record_open(&conn_rec(&format!("c{i}"), now + i), now + i);
        }
        assert_eq!(with_store(|st| st.records.len()), 3, "ring stays bounded");
        assert_eq!(flush_for_tests(now), 0, "flush prunes nothing here");
        assert_eq!(db_row_count_for_tests(), Some(10), "all 10 rows are on disk");

        let page = db_page(0, 1000);
        assert_eq!(ids_of(&page), vec![10, 9, 8, 7, 6, 5, 4, 3, 2, 1]);
        assert_eq!(page.retained, 10, "retained is the DB count, not the ring");
        assert_eq!(page.first_cursor, 1);
        assert_eq!(page.next_cursor, 10);
        assert_eq!(page.capacity, 3, "capacity still reports the ring cap");
        assert_eq!(
            page.window_start_ms,
            now - REQUEST_RETENTION_MS,
            "windowStartMs reflects the 7-day boundary when persistent"
        );

        close_for_tests(now);
        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// DB prune advances `firstCursor` and counts `lost_records`; ring eviction
    /// never moves the DB cursor, and paging across both has no dup/loss.
    #[test]
    fn db_prune_advances_cursor_and_ring_eviction_does_not() {
        reset_for_tests();
        let dir = temp_dir("dbprune");
        let now = fixture_now();
        configure_at(dir.to_str().unwrap(), now);
        with_store(|st| st.db.as_mut().unwrap().max_rows = 3);

        for i in 0..6u64 {
            record_open(&conn_rec(&format!("c{i}"), now + i), now + i);
        }
        assert_eq!(flush_for_tests(now), 3, "cap-first pruned the 3 oldest");
        assert_eq!(db_row_count_for_tests(), Some(3));
        assert_eq!(lost_records_for_tests(), 3);

        let page = db_page(0, 100);
        assert_eq!(ids_of(&page), vec![6, 5, 4]);
        assert_eq!(page.first_cursor, 4, "firstCursor advanced past the pruned rows");

        let next = db_page(4, 100);
        assert_eq!(ids_of(&next), vec![6, 5], "cursor at the boundary: no dup");
        let mut union = ids_of(&page);
        union.extend(ids_of(&next));
        union.sort_unstable();
        union.dedup();
        assert_eq!(union, vec![4, 5, 6], "union is exactly the retained window");

        with_store(|st| st.cap = 1);
        record_open(&conn_rec("evict", now + 100), now + 100);
        assert_eq!(
            db_page(0, 100).records.len(),
            3,
            "ring eviction must not hide DB rows"
        );

        close_for_tests(now);
        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reset_clears_ring_and_db_rows() {
        reset_for_tests();
        let dir = temp_dir("reset");
        let now = fixture_now();
        configure_at(dir.to_str().unwrap(), now);
        record_open(&conn_rec("c1", now + 1), now + 1);
        record_open(&conn_rec("c2", now + 2), now + 2);
        flush_for_tests(now);
        assert_eq!(db_row_count_for_tests(), Some(2));

        let data = arm_data(&reset_arm().unwrap());
        assert_eq!(data["cleared"], 2);
        assert_eq!(db_row_count_for_tests(), Some(0), "DB rows cleared");
        assert_eq!(pending_len_for_tests(), 0, "pending queue cleared");
        let page = db_page(0, 100);
        assert!(page.records.is_empty());
        assert_eq!(page.retained, 0);
        assert_eq!(page.next_cursor, 2, "reset must not reclaim the cursor");

        close_for_tests(now);
        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Write N → close (flush) → re-configure → a new record gets `recordId > N`,
    /// and pulling with a pre-restart cursor yields no dup/loss.
    #[test]
    fn restart_round_trip_continues_record_ids_and_cursor() {
        reset_for_tests();
        let dir = temp_dir("restart");
        let d = dir.to_str().unwrap();
        let now = fixture_now();
        configure_at(d, now);
        assert_eq!(next_record_id_for_tests(), 1, "empty db starts at 1");
        assert_eq!(next_cursor_for_tests(), 0);

        for i in 1..=5u64 {
            record_open(&conn_rec(&format!("c{i}"), now + i), now + i);
        }
        flush_for_tests(now);
        assert_eq!(db_row_count_for_tests(), Some(5));
        close_for_tests(now);

        configure_at(d, now);
        assert_eq!(db_row_count_for_tests(), Some(5), "seed reads the window");
        assert_eq!(next_record_id_for_tests(), 6, "numbering continues after N");
        assert_eq!(next_cursor_for_tests(), 5);

        let id = record_open(&conn_rec("c6", now + 6), now + 6);
        assert_eq!(id, 6, "a new record after restart must have recordId > N");
        flush_for_tests(now + 6);

        let page = db_page(3, 100);
        let mut got = ids_of(&page);
        got.sort_unstable();
        assert_eq!(got, vec![4, 5, 6], "no dup, no loss across restart");
        assert_eq!(page.first_cursor, 1);
        assert_eq!(page.next_cursor, 6);

        close_for_tests(now + 6);
        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn empty_table_restart_starts_at_one() {
        reset_for_tests();
        let dir = temp_dir("empty-restart");
        let d = dir.to_str().unwrap();
        let now = fixture_now();
        configure_at(d, now);
        assert_eq!(next_record_id_for_tests(), 1);
        close_for_tests(now);
        configure_at(d, now);
        assert_eq!(next_record_id_for_tests(), 1, "empty table restart -> 1");
        assert_eq!(next_cursor_for_tests(), 0);
        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn five_second_gate_flushes_once() {
        reset_for_tests();
        let dir = temp_dir("gate");
        let d = dir.to_str().unwrap();
        configure_at(d, 10_000);
        record_open(&conn_rec("c1", 10_000), 10_000);
        assert_eq!(maybe_persist(10_000), 0, "first flush prunes nothing");
        assert_eq!(db_row_count_for_tests(), Some(1));

        record_open(&conn_rec("c2", 10_100), 10_100);
        assert_eq!(maybe_persist(10_499), 0, "within 5s: suppressed");
        assert_eq!(db_row_count_for_tests(), Some(1), "not flushed yet");
        assert_eq!(pending_len_for_tests(), 1, "change stays queued");

        assert_eq!(maybe_persist(15_000), 0, "flush runs at the interval");
        assert_eq!(db_row_count_for_tests(), Some(2), "flushed after 5s");
        assert_eq!(pending_len_for_tests(), 0);

        close_for_tests(15_000);
        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn seed_loads_only_window_rows_and_numbering_spans_the_table() {
        reset_for_tests();
        let dir = temp_dir("seed-window");
        let path = dir.join("proxy_requests.db");
        let base = fixture_now();
        {
            let mut db = Persist::open(path.to_str().unwrap()).unwrap();
            let rows = vec![
                page_row(base - REQUEST_RETENTION_MS, 1),
                page_row(base - 10, 2),
                page_row(base, 3),
            ];
            db.upsert_batch(&rows, base).unwrap();
            assert_eq!(db.count(0).unwrap(), 3);
        }
        let later = base + REQUEST_RETENTION_MS / 2;
        configure_at(dir.to_str().unwrap(), later);
        assert_eq!(
            db_row_count_for_tests(),
            Some(3),
            "the stale row is still on disk"
        );
        let page = db_page(0, 100);
        assert_eq!(ids_of(&page), vec![3, 2], "reads serve only the window");
        assert_eq!(page.retained, 2);
        assert_eq!(page.first_cursor, 2);
        assert_eq!(next_record_id_for_tests(), 4, "numbering spans the whole table");

        close_for_tests(later);
        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn configure_bad_path_and_corrupt_db_degrade_to_memory() {
        reset_for_tests();
        let dir = temp_dir("badpath");
        let file = dir.join("a_file");
        std::fs::write(&file, b"x").unwrap();
        configure_at(file.to_str().unwrap(), fixture_now());
        assert!(!db_configured_for_tests(), "a file path cannot open a db");

        let dir2 = temp_dir("corrupt");
        let db_path = dir2.join("proxy_requests.db");
        std::fs::write(&db_path, b"definitely not a sqlite database").unwrap();
        configure_at(dir2.to_str().unwrap(), fixture_now());
        assert!(!db_configured_for_tests(), "corrupt db degrades, never panics");
        assert_eq!(maybe_persist(fixture_now()), 0);

        record_open(&conn_rec("c1", fixture_now()), fixture_now());
        assert_eq!(db_page(0, 100).records.len(), 1, "memory view still works");

        reset_for_tests();
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&dir2);
    }

    #[test]
    fn configure_empty_dir_is_memory_only() {
        reset_for_tests();
        configure("");
        configure("   ");
        assert!(!db_configured_for_tests());
        record_open(&conn_rec("c1", fixture_now()), fixture_now());
        assert_eq!(db_page(0, 100).records.len(), 1);
        reset_for_tests();
    }

    #[test]
    fn large_volume_insert_stays_bounded_and_completes() {
        let now = fixture_now();
        let mut db = Persist::open_in_memory().unwrap();
        const N: u64 = 5_000;
        let rows: Vec<RequestRecord> = (0..N).map(|i| page_row(now + i, i + 1)).collect();
        assert_eq!(db.upsert_batch(&rows, now).unwrap(), 0);
        assert_eq!(db.count(0).unwrap(), N as usize);
    }

    // --- Todo 10: `requests.export` (CSV + JSON) ---

    fn cleanup(dir: &std::path::Path) {
        let _ = std::fs::remove_dir_all(dir);
    }

    fn export_data(dir: &std::path::Path, payload: &[u8]) -> serde_json::Value {
        arm_data(&export_arm_to(payload, dir.to_str().unwrap(), REQUEST_EXPORT_MAX_BYTES).unwrap())
    }

    /// The CSV's first column (`recordId`), in file order — the export's own
    /// record identity list, used to prove it matches a `requests.get` snapshot.
    fn csv_record_ids(csv: &str) -> Vec<u64> {
        csv.lines()
            .skip(1)
            .filter(|l| !l.is_empty())
            .filter_map(|l| l.split(',').next()?.parse::<u64>().ok())
            .collect()
    }

    /// Happy QA: `rows` equals the concurrent `requests.get` snapshot, the CSV
    /// holds header + one row per record, columns are in the fixed order and the
    /// rendering is byte-identical on repeat.
    #[test]
    fn export_rows_match_snapshot_with_fixed_columns() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let dir = temp_dir("export-rows");
        for i in 0..4u64 {
            let mut c = conn_rec(&format!("c{i}"), 1_000 + i);
            c.domain = format!("h{i}.example.com");
            record_open(&c, 1_000 + i);
        }

        let snap_ids = ids_of(&snapshot(0, usize::MAX, &RequestFilter::default()));
        let data = export_data(&dir, br#"{"format":"csv"}"#);
        assert_eq!(data["rows"], snap_ids.len());
        assert_eq!(data["rows"], 4);
        assert!(data["jsonPath"].is_null(), "csv-only export omits jsonPath");

        let csv_path = data["csvPath"].as_str().unwrap();
        let csv = std::fs::read_to_string(csv_path).unwrap();
        let header = EXPORT_CSV_COLUMNS.join(",");
        assert!(csv.starts_with(&format!("{header}\r\n")), "fixed column order");
        let lines: Vec<&str> = csv.trim_end_matches("\r\n").split("\r\n").collect();
        assert_eq!(lines.len(), snap_ids.len() + 1, "CSV row count == records + 1");
        assert_eq!(
            csv_record_ids(&csv),
            snap_ids,
            "export record identities and order must equal the snapshot"
        );

        let direct = render_csv(&snapshot(0, usize::MAX, &RequestFilter::default()).records);
        let again = render_csv(&snapshot(0, usize::MAX, &RequestFilter::default()).records);
        assert_eq!(direct, again, "CSV rendering must be deterministic");

        cleanup(&dir);
    }

    /// Failure/edge QA: a domain with a comma, a quote and a newline is escaped
    /// per RFC4180; a bare IPv6 `dstIp` is never bracketed.
    #[test]
    fn export_csv_escapes_rfc4180_and_uses_bare_ipv6() {
        let mut tricky = rec("c-tricky", 100);
        tricky.domain = "a,\"b\"\nc".to_string();
        let csv = render_csv(&[tricky]);
        assert!(
            csv.contains("\"a,\"\"b\"\"\nc\""),
            "comma/quote/newline must be quoted+escaped: {csv}"
        );
        let row = csv.trim_end_matches("\r\n").split("\r\n").nth(1).unwrap();
        assert!(row.contains("\n"), "the embedded newline stays inside the quoted field");

        let mut v6 = rec("c-v6", 200);
        v6.dst_ip = "2001:db8::1".to_string();
        let csv = render_csv(&[v6]);
        assert!(csv.contains("2001:db8::1"), "bare IPv6 in the file");
        assert!(!csv.contains("[2001:db8::1]"), "no brackets around IPv6");
    }

    /// Failure QA: an export over the byte cap returns the structured 507 and
    /// leaves **no** half-written file; a within-cap export succeeds and reports
    /// a byte total no larger than the cap.
    #[test]
    fn export_over_byte_cap_is_structured_and_leaves_no_file() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let dir = temp_dir("export-cap");
        record_open(&conn_rec("c1", 100), 100);
        record_open(&conn_rec("c2", 200), 200);

        let err = export_arm_to(br#"{"format":"both"}"#, dir.to_str().unwrap(), 1).unwrap_err();
        assert_eq!(err.status as i32, 507);
        assert_eq!(err.code, ERR_REQUEST_EXPORT_TOO_LARGE);
        let mut entries = std::fs::read_dir(&dir).unwrap();
        assert!(
            entries.next().is_none(),
            "an over-cap export must leave no csv/json (or tmp) file behind"
        );

        let data = export_data(&dir, br#"{"format":"both"}"#);
        assert!(data["bytes"].as_u64().unwrap() <= REQUEST_EXPORT_MAX_BYTES as u64);
        assert!(data["csvPath"].is_string() && data["jsonPath"].is_string());
        cleanup(&dir);
    }

    /// Failure QA: malformed payloads are structured, never a panic — a bad
    /// format or a non-object / wrongly-typed filter is a 422 (the filter has
    /// its own domain code), and a bad `requests.get` cursor is its own 422.
    #[test]
    fn export_and_cursor_malformed_inputs_are_structured() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let dir = temp_dir("export-malformed");
        let d = dir.to_str().unwrap();
        let cap = REQUEST_EXPORT_MAX_BYTES;

        assert_eq!(
            export_arm_to(br#"{"format":"xml"}"#, d, cap).unwrap_err().status as i32,
            422
        );
        let err = export_arm_to(br#"{"filter":42}"#, d, cap).unwrap_err();
        assert_eq!(err.status as i32, 422);
        assert_eq!(err.code, ERR_REQUEST_EXPORT_FILTER_INVALID);
        assert_eq!(
            export_arm_to(br#"{"filter":{"uid":"x"}}"#, d, cap).unwrap_err().code,
            ERR_REQUEST_EXPORT_FILTER_INVALID
        );
        assert_eq!(
            export_arm_to(br#"{"format":"#, d, cap).unwrap_err().status as i32,
            422
        );
        assert_eq!(
            export_arm_to(br#"{"format":7}"#, d, cap).unwrap_err().status as i32,
            422
        );

        let err = get_arm(br#"{"cursor":"nope"}"#).unwrap_err();
        assert_eq!(err.status as i32, 422);
        assert_eq!(err.code, ERR_REQUEST_CURSOR_INVALID);
        // A valid numeric cursor still works.
        assert!(get_arm(br#"{"cursor":3}"#).is_ok());

        cleanup(&dir);
    }

    /// The export applies the `filter` and honours `json`-only format; the JSON
    /// file is a bare record array (never the response envelope).
    #[test]
    fn export_applies_filter_and_writes_bare_json_array() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let dir = temp_dir("export-filter");
        for (name, domain) in [
            ("c1", "alpha.example.com"),
            ("c2", "alpha.test"),
            ("c3", "beta.example.com"),
        ] {
            let mut c = conn_rec(name, 1_000);
            c.domain = domain.to_string();
            record_open(&c, 1_000);
        }

        let data = export_data(
            &dir,
            br#"{"format":"json","filter":{"domain":"alpha"}}"#,
        );
        assert_eq!(data["rows"], 2);
        assert!(data["csvPath"].is_null(), "json-only export omits csvPath");
        let json_path = data["jsonPath"].as_str().unwrap();
        let bytes = std::fs::read(json_path).unwrap();
        let parsed: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        let arr = parsed.as_array().unwrap();
        assert_eq!(arr.len(), 2);
        assert!(arr.iter().all(|r| r["domain"].as_str().unwrap().contains("alpha")));
        assert!(
            parsed.get("ok").is_none() && parsed.get("data").is_none(),
            "the JSON file must be a bare array, never the response envelope"
        );

        cleanup(&dir);
    }

    /// Adversarial hung/long: a large-but-within-cap export completes, keeps
    /// `rows` correct and does not exceed the byte cap.
    #[test]
    fn export_large_within_cap_completes() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let dir = temp_dir("export-large");
        const N: u64 = 2_000;
        for i in 0..N {
            let mut c = conn_rec(&format!("c{i}"), 1_000 + i);
            c.domain = format!("host-{i}.example.com");
            record_open(&c, 1_000 + i);
        }
        let data = export_data(&dir, br#"{"format":"both"}"#);
        assert_eq!(data["rows"], N as usize);
        assert!(data["bytes"].as_u64().unwrap() <= REQUEST_EXPORT_MAX_BYTES as u64);
        let csv = std::fs::read_to_string(data["csvPath"].as_str().unwrap()).unwrap();
        assert_eq!(csv_record_ids(&csv).len(), N as usize);
        cleanup(&dir);
    }

    // --- Todo 11: pluggable UID resolution (pending/early-result backfill) ---

    /// One fabricated `UidAnswer`. `uid == None` means the host definitively
    /// could not resolve the owner (terminal `unknown`).
    fn answer(record_id: u64, uid: Option<i64>) -> UidAnswer {
        UidAnswer {
            record_id,
            uid,
            packages: uid
                .map(|_| vec![format!("pkg.{record_id}")])
                .unwrap_or_default(),
        }
    }

    /// A fake resolver that hands out prepared batches on successive `resolve`
    /// calls. An empty batch means "not resolved yet" (the record stays
    /// `pending`), which is exactly how a slow resolver behaves.
    struct FakeUidResolver {
        queue: std::sync::Mutex<VecDeque<Vec<UidAnswer>>>,
    }

    impl FakeUidResolver {
        fn new(batches: Vec<Vec<UidAnswer>>) -> Self {
            Self {
                queue: std::sync::Mutex::new(batches.into()),
            }
        }
    }

    impl UidResolver for FakeUidResolver {
        fn resolve(&self, _reqs: &[UidQuery]) -> Vec<UidAnswer> {
            self.queue
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .pop_front()
                .unwrap_or_default()
        }
    }

    fn install_resolver(batches: Vec<Vec<UidAnswer>>) {
        set_uid_resolver(Some(Box::new(FakeUidResolver::new(batches))));
    }

    fn clear_resolver() {
        set_uid_resolver(None);
    }

    fn take_uid_query_events() -> Vec<serde_json::Value> {
        let drained = std::mem::take(
            &mut *crate::TEST_EMITTED
                .lock()
                .unwrap_or_else(|e| e.into_inner()),
        );
        drained
            .into_iter()
            .filter(|(kind, _)| kind == EVT_UID_QUERY)
            .map(|(_, payload)| {
                serde_json::from_slice(&payload).expect("proxy.uid.query payload must be JSON")
            })
            .collect()
    }

    fn record_of(id: u64) -> Option<RequestRecord> {
        with_store(|st| st.records.iter().find(|r| r.record_id == id).cloned())
    }

    /// Prove (acceptance): a TCP flow in `Mode::Vpn` issues exactly one
    /// `proxy.uid.query` batch with the structured src/dst shape and goes
    /// `pending`; `Mode::LanProxy` and `Mode::Off` never query and stay
    /// `unknown`. UDP is out of scope.
    #[test]
    fn tcp_in_vpn_issues_uid_query_but_lan_and_off_do_not() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        clear_resolver();
        let _ = take_uid_query_events();

        let mut vpn = conn_rec("c-vpn", 1_000);
        vpn.src = "10.0.0.2:51000".to_string();
        vpn.dst_ip = "1.2.3.4".to_string();
        vpn.dst_port = 443;
        let id = record_open(&vpn, 1_000);
        tick(7, crate::ProxyMode::Vpn, 1_000);
        assert_eq!(
            uid_state_for_tests(id).as_deref(),
            Some(UID_STATE_PENDING),
            "a VPN TCP flow must be pending"
        );
        let events = take_uid_query_events();
        assert_eq!(events.len(), 1, "exactly one query batch");
        let q = &events[0]["queries"][0];
        assert_eq!(q["recordId"], id);
        assert_eq!(q["protocol"], "tcp");
        assert_eq!(q["srcIp"], "10.0.0.2");
        assert_eq!(q["srcPort"], 51000);
        assert_eq!(q["dstIp"], "1.2.3.4");
        assert_eq!(q["dstPort"], 443);

        for mode in [crate::ProxyMode::LanProxy, crate::ProxyMode::Off] {
            reset_for_tests();
            let _ = take_uid_query_events();
            let id = record_open(&conn_rec("c-x", 2_000), 2_000);
            tick(7, mode, 2_000);
            assert_eq!(
                uid_state_for_tests(id).as_deref(),
                Some(UID_STATE_UNKNOWN),
                "{mode:?} must resolve unknown immediately"
            );
            assert_eq!(uid_pending_len_for_tests(), 0);
            assert!(
                take_uid_query_events().is_empty(),
                "{mode:?} must never issue a uid query"
            );
        }

        // A UDP flow is unsupported: never pending, never queried.
        reset_for_tests();
        let _ = take_uid_query_events();
        let mut udp = conn_rec("c-udp", 3_000);
        udp.network = "udp".to_string();
        let id = record_open(&udp, 3_000);
        tick(7, crate::ProxyMode::Vpn, 3_000);
        assert_eq!(uid_state_for_tests(id).as_deref(), Some(UID_STATE_UNKNOWN));
        assert_eq!(uid_pending_len_for_tests(), 0);
        assert!(take_uid_query_events().is_empty(), "UDP is out of scope");
    }

    /// Scenario 1 (fast resolver): the answer lands in the same tick; the record
    /// is `known` with uid and packages and leaves the pending set.
    #[test]
    fn fast_resolver_marks_known_with_uid_and_packages() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        clear_resolver();
        let _ = take_uid_query_events();

        let id = record_open(&conn_rec("c1", 1_000), 1_000);
        install_resolver(vec![vec![answer(id, Some(10_042))]]);
        tick(7, crate::ProxyMode::Vpn, 1_000);

        let r = record_of(id).unwrap();
        assert_eq!(r.uid_state, UID_STATE_KNOWN);
        assert_eq!(r.uid, Some(10_042));
        assert_eq!(r.packages, vec![format!("pkg.{id}")]);
        assert_eq!(uid_pending_len_for_tests(), 0, "resolved leaves pending");
        clear_resolver();
    }

    /// Scenario 2 (slow resolver): the record is first `pending`, and a later
    /// tick with the answer flips it to `known`.
    #[test]
    fn slow_resolver_stays_pending_then_becomes_known() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        clear_resolver();

        let id = record_open(&conn_rec("c1", 1_000), 1_000);
        install_resolver(vec![Vec::new(), vec![answer(id, Some(7))]]);

        tick(7, crate::ProxyMode::Vpn, 1_000);
        assert_eq!(
            uid_state_for_tests(id).as_deref(),
            Some(UID_STATE_PENDING),
            "first (empty) resolution leaves it pending"
        );
        assert_eq!(uid_pending_len_for_tests(), 1);

        tick(7, crate::ProxyMode::Vpn, 1_100);
        assert_eq!(uid_state_for_tests(id).as_deref(), Some(UID_STATE_KNOWN));
        assert_eq!(record_of(id).unwrap().uid, Some(7));
        assert_eq!(uid_pending_len_for_tests(), 0);
        clear_resolver();
    }

    /// Scenario 3 (timeout): a resolver that never answers leaves the record
    /// pending only until the ~30s TTL, then it is `unknown`.
    #[test]
    fn resolver_timeout_expires_pending_to_unknown() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        clear_resolver();

        let id = record_open(&conn_rec("c1", 1_000), 1_000);
        install_resolver(vec![Vec::new()]);
        tick(7, crate::ProxyMode::Vpn, 1_000);
        assert_eq!(uid_state_for_tests(id).as_deref(), Some(UID_STATE_PENDING));

        tick(7, crate::ProxyMode::Vpn, 1_000 + UID_QUERY_TTL_MS + 1);
        assert_eq!(
            uid_state_for_tests(id).as_deref(),
            Some(UID_STATE_UNKNOWN),
            "TTL expiry must resolve unknown"
        );
        assert_eq!(uid_pending_len_for_tests(), 0);
        clear_resolver();
    }

    /// Scenario 4 (all-unknown): a definitive `uid:null` answer is terminal
    /// `unknown` and clears the pending entry.
    #[test]
    fn resolver_all_unknown_is_terminal_unknown() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        clear_resolver();

        let id = record_open(&conn_rec("c1", 1_000), 1_000);
        install_resolver(vec![vec![answer(id, None)]]);
        tick(7, crate::ProxyMode::Vpn, 1_000);

        let r = record_of(id).unwrap();
        assert_eq!(r.uid_state, UID_STATE_UNKNOWN);
        assert_eq!(r.uid, None);
        assert!(r.packages.is_empty());
        assert_eq!(uid_pending_len_for_tests(), 0);
        clear_resolver();
    }

    /// Scenario 5 (early result): a `uid.result` that arrives **before** its
    /// record is inserted is buffered, then applied the moment the record
    /// appears (no query is ever issued for it).
    #[test]
    fn early_result_before_insert_is_applied_on_insert() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        clear_resolver();
        let _ = take_uid_query_events();

        // Fresh store: the next record id is 1.
        let applied = handle_uid_result_at(
            br#"{"results":[{"recordId":1,"uid":42,"packages":["com.early"]}]}"#,
            1_000,
        )
        .unwrap();
        assert_eq!(applied, 0, "no record to apply to yet");
        assert_eq!(uid_early_len_for_tests(), 1, "buffered as an early result");

        let id = record_open(&conn_rec("c1", 1_000), 1_000);
        assert_eq!(id, 1);
        let r = record_of(id).unwrap();
        assert_eq!(r.uid_state, UID_STATE_KNOWN, "applied on insert");
        assert_eq!(r.uid, Some(42));
        assert_eq!(r.packages, vec!["com.early".to_string()]);
        assert_eq!(uid_early_len_for_tests(), 0, "consumed exactly once");

        tick(7, crate::ProxyMode::Vpn, 1_000);
        assert_eq!(uid_pending_len_for_tests(), 0, "known records are not queried");
        assert!(
            take_uid_query_events().is_empty(),
            "a resolved record must not emit a query"
        );
    }

    /// Scenario 6 (already-closed record): a late result for a record that has
    /// already been finalized is still applied to the retained record.
    #[test]
    fn late_result_for_closed_record_is_still_applied() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        clear_resolver();

        let c = conn_rec("c1", 1_000);
        let id = record_open(&c, 1_000);
        record_close(&c, 1_100, CloseReason::Closed);
        assert_eq!(record_of(id).unwrap().close_reason, CLOSE_REASON_CLOSED);

        let applied = handle_uid_result_at(
            format!(r#"{{"results":[{{"recordId":{id},"uid":7,"packages":[]}}]}}"#).as_bytes(),
            1_200,
        )
        .unwrap();
        assert_eq!(applied, 1);
        let r = record_of(id).unwrap();
        assert_eq!(r.uid_state, UID_STATE_KNOWN);
        assert_eq!(r.uid, Some(7));
        clear_resolver();
    }

    /// Adversarial stale_state: an early result for a record that never appears
    /// is bounded and dropped on TTL expiry; a negative uid means `unknown`.
    #[test]
    fn early_result_expires_and_negative_uid_is_unknown() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        clear_resolver();

        // A result for a record id this store will never mint is buffered...
        assert_eq!(
            handle_uid_result_at(
                br#"{"results":[{"recordId":999,"uid":5,"packages":[]}]}"#,
                1_000
            )
            .unwrap(),
            0
        );
        assert_eq!(uid_early_len_for_tests(), 1);

        // ...and a negative uid (`-1`) is a definitive unknown, never a huge uid.
        let id = record_open(&conn_rec("c1", 1_000), 1_000);
        assert_eq!(
            handle_uid_result_at(
                format!(r#"{{"results":[{{"recordId":{id},"uid":-1,"packages":[]}}]}}"#).as_bytes(),
                1_000
            )
            .unwrap(),
            1
        );
        let r = record_of(id).unwrap();
        assert_eq!(r.uid_state, UID_STATE_UNKNOWN);
        assert_eq!(r.uid, None);

        // TTL expiry drops the orphaned early result (bounded memory).
        tick(7, crate::ProxyMode::Vpn, 1_000 + UID_QUERY_TTL_MS + 1);
        assert_eq!(uid_early_len_for_tests(), 0, "early results expire");
        clear_resolver();
    }

    /// Adversarial malformed_input: a bad `uid.result` payload is a structured
    /// 422 (never a panic); an empty body is a well-formed no-op.
    #[test]
    fn malformed_uid_result_is_structured() {
        reset_for_tests();
        let err = handle_uid_result_at(b"not-json", 1_000).unwrap_err();
        assert_eq!(err.status as i32, 422);
        assert_eq!(
            handle_uid_result_at(br#"{"results":[]}"#, 1_000).unwrap(),
            0
        );
        assert_eq!(handle_uid_result_at(br#"{}"#, 1_000).unwrap(), 0);
        assert_eq!(
            handle_uid_result_at(br#"{"results":[{"uid":1}]}"#, 1_000)
                .unwrap_err()
                .status as i32,
            422,
            "a result without recordId is malformed"
        );
    }

    /// HARD INVARIANT + race: `resolve` (and the query emit) must run with the
    /// store lock **released**. The fake resolver deliberately re-enters the
    /// store; if the lock were held it would panic. Concurrent ticks then prove
    /// there is no deadlock.
    #[test]
    fn resolver_and_emit_run_outside_the_store_lock_without_deadlock() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();

        struct ReentrantResolver;
        impl UidResolver for ReentrantResolver {
            fn resolve(&self, _reqs: &[UidQuery]) -> Vec<UidAnswer> {
                // Must NOT be called while `with_store` holds the borrow.
                let n = with_store(|st| st.records.len());
                assert!(n >= 1, "resolver runs with no store lock held");
                Vec::new()
            }
        }

        record_open(&conn_rec("c1", 1_000), 1_000);
        set_uid_resolver(Some(Box::new(ReentrantResolver)));
        tick(7, crate::ProxyMode::Vpn, 1_000); // would panic/deadlock if unsafe
        set_uid_resolver(None);

        let mut handles = Vec::new();
        for t in 0..4u64 {
            handles.push(std::thread::spawn(move || {
                for i in 0..25u64 {
                    record_open(&conn_rec(&format!("t{t}-{i}"), 1_000 + i), 1_000 + i);
                    tick(t, crate::ProxyMode::Vpn, 1_000 + i);
                }
            }));
        }
        for h in handles {
            h.join().expect("no thread may panic or deadlock");
        }
    }

    /// Race: concurrent gating and opening on a shared store never deadlock and
    /// keep the pending map bounded (collect under the lock, emit after).
    #[test]
    fn concurrent_gate_uid_and_open_do_not_deadlock() {
        use std::sync::Arc;
        let store = Arc::new(std::sync::Mutex::new(RequestStore::fresh()));
        {
            let mut s = store.lock().unwrap_or_else(|e| e.into_inner());
            for i in 0..64u64 {
                s.open_record(&conn_rec(&format!("s{i}"), 1_000 + i), 1_000 + i);
            }
        }
        let mut handles = Vec::new();
        for t in 0..6u64 {
            let store = Arc::clone(&store);
            handles.push(std::thread::spawn(move || {
                for i in 0..200u64 {
                    let mut s = store.lock().unwrap_or_else(|e| e.into_inner());
                    if i % 3 == 0 {
                        s.open_record(&conn_rec(&format!("t{t}-{i}"), 2_000 + i), 2_000 + i);
                    }
                    // Collect under the lock, then emit AFTER dropping it.
                    let queries = s.gate_uid(crate::ProxyMode::Vpn, 2_000 + i);
                    drop(s);
                    let _ = queries.len();
                }
            }));
        }
        for h in handles {
            h.join().expect("no thread may deadlock");
        }
        let s = store.lock().unwrap_or_else(|e| e.into_inner());
        assert!(s.uid_pending.len() <= s.uid_pending_cap);
    }

    // --- C3: production host UID resolver (reuse the existing host UID lane) ---

    use crate::capture::{AppAttribution, AppUidResolver, HostUidAppResolver};
    use std::net::SocketAddr;
    use std::sync::Arc;

    fn capture_src_dst() -> (SocketAddr, SocketAddr) {
        (
            "10.0.0.2:51000".parse().unwrap(),
            "1.2.3.4:443".parse().unwrap(),
        )
    }

    /// The reserved capture id from the most recent query batch, or 0 when no
    /// capture-origin query was emitted.
    fn last_capture_query_id() -> u64 {
        take_uid_query_events()
            .iter()
            .filter_map(|ev| ev["queries"].as_array())
            .flatten()
            .filter_map(|q| q["recordId"].as_u64())
            .find(|id| *id >= CAPTURE_UID_ID_BASE)
            .unwrap_or(0)
    }

    fn uid_result_payload(record_id: u64, uid: i64, packages: &[&str]) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "results": [{ "recordId": record_id, "uid": uid, "packages": packages }]
        }))
        .expect("serialize uid.result")
    }

    /// Scenario 1 (round trip): the resolver emits a reserved-id query and the
    /// simulated host `uid.result` (routed by `handle_uid_result_at`) completes
    /// the future as `Known` — without ever touching the request store.
    #[tokio::test]
    async fn capture_resolver_round_trips_a_simulated_uid_result_to_known() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let _ = take_uid_query_events();

        let resolver = Arc::new(HostUidAppResolver::new(7));
        let (src, dst) = capture_src_dst();
        let r2 = Arc::clone(&resolver);
        let handle = tokio::spawn(async move { r2.resolve(src, dst).await });
        tokio::task::yield_now().await;

        let rid = last_capture_query_id();
        assert!(
            rid >= CAPTURE_UID_ID_BASE,
            "the resolver must emit a query in the reserved capture id namespace"
        );

        let payload = uid_result_payload(rid, 10_123, &["com.allowed"]);
        assert_eq!(
            handle_uid_result_at(&payload, 1_000).unwrap(),
            0,
            "a reserved-id answer must never be applied to the request store"
        );
        let attr = handle.await.expect("resolver task must not panic");
        assert_eq!(
            attr,
            AppAttribution::Known {
                uid: 10_123,
                packages: vec!["com.allowed".to_string()],
            }
        );
        assert_eq!(uid_early_len_for_tests(), 0, "reserved ids never enter uid_early");
        assert_eq!(capture_uid_registry_len_for_tests(), 0, "a reply consumes the slot");
    }

    /// Scenarios 2 + 4: an unanswered query times out to `Unknown` and releases
    /// its slot; a late answer for the abandoned id is dropped (no panic, no
    /// retro-authorization, no `uid_early` buffering).
    #[tokio::test]
    async fn capture_resolver_timeout_is_unknown_and_a_late_answer_is_dropped() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let _ = take_uid_query_events();

        let resolver = Arc::new(HostUidAppResolver::new(7));
        let (src, dst) = capture_src_dst();
        let r2 = Arc::clone(&resolver);
        let handle = tokio::spawn(async move { r2.resolve(src, dst).await });
        tokio::task::yield_now().await;

        let rid = last_capture_query_id();
        assert!(rid >= CAPTURE_UID_ID_BASE);

        let attr = handle.await.expect("resolver task must not panic");
        assert_eq!(attr, AppAttribution::Unknown, "timeout must fail safe");
        assert_eq!(capture_uid_registry_len_for_tests(), 0, "timeout releases the slot");

        // The host answers after the deadline: the slot is gone, so the answer
        // is dropped and can never be applied to the store or buffered early.
        let late = uid_result_payload(rid, 10_123, &["com.allowed"]);
        assert_eq!(handle_uid_result_at(&late, 1_200).unwrap(), 0);
        assert_eq!(uid_early_len_for_tests(), 0, "a reserved id can never be buffered");
    }

    /// Scenario 3: a saturated registry denies immediately and emits nothing, so
    /// a capture lookup can never stall the dataplane or starve the lane.
    #[tokio::test]
    async fn capture_resolver_registry_full_is_immediate_unknown() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let _ = take_uid_query_events();

        let mut held = Vec::new();
        for _ in 0..crate::limits::CAPTURE_UID_INFLIGHT_CAP {
            held.push(register_capture_uid().expect("registry has room"));
        }

        let resolver = HostUidAppResolver::new(7);
        let (src, dst) = capture_src_dst();
        let attr = resolver.resolve(src, dst).await;
        assert_eq!(attr, AppAttribution::Unknown, "a full registry denies");
        assert!(
            take_uid_query_events().is_empty(),
            "no query may be emitted when no slot was reserved"
        );

        for (id, _rx) in held {
            deregister_capture_uid(id);
        }
        assert_eq!(capture_uid_registry_len_for_tests(), 0);
    }

    /// Scenario 5 (partition): a reserved id is routed to the registry and NEVER
    /// reaches `uid_early`, while an ordinary orphan id keeps the existing
    /// early-buffer behavior byte for byte.
    #[test]
    fn reserved_capture_ids_are_partitioned_away_from_uid_early() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();

        let reserved = CAPTURE_UID_ID_BASE + 5;
        let payload = uid_result_payload(reserved, 9, &["com.x"]);
        assert_eq!(handle_uid_result_at(&payload, 1_000).unwrap(), 0);
        assert_eq!(uid_early_len_for_tests(), 0, "reserved ids never buffer");

        let orphan = uid_result_payload(4096, 9, &["com.x"]);
        assert_eq!(handle_uid_result_at(&orphan, 1_000).unwrap(), 0);
        assert_eq!(uid_early_len_for_tests(), 1, "ordinary orphans still buffer");
    }

    /// The A path (`appScope=routing`) must pay zero UID cost: the dispatcher
    /// consults `needs_app_resolution` before ever resolving.
    #[test]
    fn routing_scope_needs_no_app_resolution() {
        let routing = crate::capture::CaptureConfig {
            enabled: true,
            app_allowlist: vec!["com.allowed".to_string()],
            app_scope: crate::capture::AppScope::Routing,
            ..Default::default()
        };
        assert!(!crate::capture::needs_app_resolution(&routing, 443));
        let uid = crate::capture::CaptureConfig {
            app_scope: crate::capture::AppScope::Uid,
            ..routing
        };
        assert!(crate::capture::needs_app_resolution(&uid, 443));
    }
}
