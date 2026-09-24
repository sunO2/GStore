//! Bounded capture ring + rolling SQLite persistence (Todo 13 of the
//! proxy-http-capture plan).
//!
//! This module is the **store** behind the MITM capture surface: the bounded
//! in-memory ring of [`CaptureSummary`] records plus the durable, authoritative
//! copy in `<dataDir>/proxy_captures.db`. It deliberately mirrors
//! [`crate::requests`]: same ring/cursor/eviction paradigm, same WAL +
//! batched-single-transaction persistence, same cap-first-then-time-window prune
//! and the same *single* driver for the `proxy.request` dirty signal.
//!
//! ## Memory / disk split (hard)
//!
//! The ring holds **summaries only** — truncated url (≤
//! [`CAPTURE_URL_MAX_BYTES`](crate::limits::CAPTURE_URL_MAX_BYTES)), host,
//! ≤256 B/side previews and ≤512 B/side truncated headers. The **full** request
//! and response bodies (≤ [`CAPTURE_BODY_MAX_BYTES`](crate::limits::CAPTURE_BODY_MAX_BYTES)
//! each), the full url and the full headers are disk-only: they ride the
//! pending-flush queue and are written to SQLite in one transaction at most
//! every [`CAPTURE_PERSIST_INTERVAL_MS`]. The queue is bounded by both a record
//! cap and a byte cap, so a burst can never grow memory without bound.
//!
//! ## Dirty signal reuse
//!
//! A capture change **never** emits an event by itself. It bumps the shared
//! dirty counter in [`crate::requests`] (via
//! [`crate::requests::mark_external_dirty`]) and the one and only
//! `proxy.request` signal is still produced by [`crate::requests::tick`], whose
//! payload stays payload-free (`{seq,count,tsMs}`) — no record ever leaks onto
//! the host event ring.
#![allow(dead_code)] // T13 store: consumed by the dispatch contract (Todo 12).

use std::collections::{HashMap, VecDeque};
#[cfg(not(test))]
use std::sync::{Mutex, OnceLock};
use std::sync::Arc;
#[cfg(test)]
use std::cell::RefCell;

use gstore_contract::error::{ModuleError, StatusCode};
use serde::{Deserialize, Serialize};

use crate::limits::{CAPTURE_BODY_MAX_BYTES, CAPTURE_RING_CAP, CAPTURE_URL_MAX_BYTES};
use crate::mitm::{
    CaptureRecord, CaptureSink, CAPTURE_HEADERS_MAX_BYTES, CAPTURE_PREVIEW_MAX_BYTES,
};

// ==================== Todo 12: `captures.*` contract errors ====================

/// `captures.detail` asked for a `recordId` that is not retained (ring, pending
/// flush or disk). 404, `rust/ERROR_CODES.md`.
pub(crate) const ERR_CAPTURE_NOT_FOUND: &str = "PROXY_CAPTURE_NOT_FOUND";
/// `captures.get` was given a present-but-non-`u64` `cursor`. 422.
pub(crate) const ERR_CAPTURE_CURSOR_INVALID: &str = "PROXY_CAPTURE_CURSOR_INVALID";
/// A durable read/write failed. 500; the in-memory summary ring is untouched.
pub(crate) const ERR_CAPTURE_STORE_FAILED: &str = "PROXY_CAPTURE_STORE_FAILED";
/// Defensive guard: a `captures.detail` body exceeded the on-disk read cap.
/// 507 (resource exhausted).
pub(crate) const ERR_CAPTURE_BODY_TOO_LARGE: &str = "PROXY_CAPTURE_BODY_TOO_LARGE";

/// Default `captures.get` page size when `limit` is omitted.
pub(crate) const DEFAULT_CAPTURE_LIMIT: usize = 256;

/// Hard cap on the durable capture timeline (`proxy_captures.db`). Prune is
/// **cap-first**: rows beyond this many are deleted oldest-`finished_at_ms`-first,
/// THEN rows older than [`CAPTURE_RETENTION_MS`] are deleted.
pub(crate) const CAPTURE_MAX_ROWS: usize = 20_000;
/// Rolling persistence window for the durable capture timeline (7 days).
pub(crate) const CAPTURE_RETENTION_MS: u64 = 7 * 24 * 60 * 60 * 1000;
/// Durable flush spacing: bodies are batched into one transaction at most this
/// often, never written per-close / per-packet.
pub(crate) const CAPTURE_PERSIST_INTERVAL_MS: u64 = 5000;
/// Bound on the pending-flush queue (in records). Over capacity the **oldest**
/// queued full record is dropped and counted, so the sink can never grow memory
/// without bound during a burst between two flushes.
pub(crate) const CAPTURE_FLUSH_QUEUE_CAP: usize = CAPTURE_RING_CAP;
/// Bound on the pending-flush queue (in bytes). A handful of 1 MiB/side bodies
/// can otherwise dwarf the ring's RAM budget; the byte cap dominates it.
pub(crate) const CAPTURE_FLUSH_QUEUE_BYTES: usize = 8 * 1024 * 1024;
/// Explicit SQLite busy timeout: a concurrent writer waits instead of failing
/// immediately with `SQLITE_BUSY`.
const CAPTURE_BUSY_TIMEOUT_MS: u64 = 5000;

/// In-ring host bound (a DNS name is ≤253 bytes).
const CAPTURE_HOST_MAX_BYTES: usize = 253;
/// In-ring `contentType` bound (a long header cannot grow the ring unbounded).
const CAPTURE_CONTENT_TYPE_MAX_BYTES: usize = 128;
/// In-ring `connId` bound (meow connection ids are short; defensive).
const CAPTURE_CONN_ID_MAX_BYTES: usize = 64;

/// Preview/base64 wire codec: the ring would blow `CAPTURE_RECORD_MAX_BYTES` if a
/// `Vec<u8>` preview were serialized as a JSON number array (up to 4 B per byte),
/// so every byte string crosses the contract as a base64 string.
mod wire_bytes {
    use base64::Engine as _;
    use serde::{Deserialize, Deserializer, Serializer};

    pub(crate) fn serialize<S: Serializer>(v: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(v))
    }

    pub(crate) fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let encoded = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(serde::de::Error::custom)
    }
}

/// An absent/blank string filter matches everything (mirrors `requests.get`).
fn non_blank(v: &Option<String>) -> Option<&str> {
    v.as_deref().map(str::trim).filter(|s| !s.is_empty())
}

/// `captures.get` filters. Every field is optional; absent/blank string filters
/// are ignored. `requestRecordId: 0` is meaningful — it selects the orphan
/// captures whose flow never produced a `requests.*` record.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CaptureFilter {
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub status_class: Option<u16>,
    #[serde(default)]
    pub protocol: Option<String>,
    #[serde(default)]
    pub request_record_id: Option<u64>,
}

impl CaptureFilter {
    /// `host` is a case-insensitive substring; `method`/`protocol` are
    /// case-insensitive exact; `statusClass` is `statusCode / 100`; and
    /// `requestRecordId` is an exact link key.
    pub(crate) fn matches(&self, r: &CaptureSummary) -> bool {
        if let Some(h) = non_blank(&self.host) {
            if !r.host.to_ascii_lowercase().contains(&h.to_ascii_lowercase()) {
                return false;
            }
        }
        if let Some(m) = non_blank(&self.method) {
            if !r.method.eq_ignore_ascii_case(m) {
                return false;
            }
        }
        if let Some(sc) = self.status_class {
            if sc == 0 || r.status_code / 100 != sc {
                return false;
            }
        }
        if let Some(p) = non_blank(&self.protocol) {
            if !r.protocol.eq_ignore_ascii_case(p) {
                return false;
            }
        }
        if let Some(rid) = self.request_record_id {
            if r.request_record_id != rid {
                return false;
            }
        }
        true
    }
}

/// One recorded WebSocket frame in the contract (ring summary or full detail).
/// The payload preview crosses the wire base64-encoded and is bounded (≤
/// `WS_PREVIEW_MAX_BYTES` in the detail, further clipped in the ring).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CaptureWsFrame {
    /// `"clientToServer"` | `"serverToClient"`.
    pub direction: String,
    pub opcode: String,
    pub payload_len: u64,
    #[serde(with = "wire_bytes")]
    pub preview: Vec<u8>,
    pub truncated: bool,
    pub at_ms: u64,
}

/// One captured exchange as retained in the bounded in-memory ring: the summary
/// fields only. The full bodies/url/headers live in `proxy_captures.db` and are
/// fetched by `captures.detail` on demand (Todo 12) — never resident here.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CaptureSummary {
    pub record_id: u64,
    /// Foreign key into `requests.*`; `0` = no matching flow record.
    pub request_record_id: u64,
    pub conn_id: String,
    pub host: String,
    pub method: String,
    pub scheme: String,
    /// Truncated to [`CAPTURE_URL_MAX_BYTES`]; `truncated` records the clip.
    pub url: String,
    pub status_code: u16,
    pub protocol: String,
    pub req_headers: String,
    pub resp_headers: String,
    #[serde(with = "wire_bytes")]
    pub req_body_preview: Vec<u8>,
    #[serde(with = "wire_bytes")]
    pub resp_body_preview: Vec<u8>,
    pub req_bytes: u64,
    pub resp_bytes: u64,
    pub content_type: String,
    pub started_at_ms: u64,
    pub finished_at_ms: u64,
    pub duration_ms: u64,
    pub truncated: bool,
    pub mitm_failed: bool,
    /// WS frames attached to this exchange. Empty until the WS capture path
    /// emits a `"ws"` record; carried in the ring shape so `records` and
    /// `detail` share one contract.
    #[serde(default)]
    pub ws_frames: Vec<CaptureWsFrame>,
}

/// The full `captures.detail` record: the ring summary fields **plus** the full
/// request/response bodies, full url and full headers, and the full WS frame
/// list — read from `proxy_captures.db` (or the still-unflushed pending queue).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CaptureDetail {
    pub record_id: u64,
    pub request_record_id: u64,
    pub conn_id: String,
    pub host: String,
    pub method: String,
    pub scheme: String,
    pub url: String,
    pub status_code: u16,
    pub protocol: String,
    pub req_headers: String,
    pub resp_headers: String,
    #[serde(with = "wire_bytes")]
    pub req_body_preview: Vec<u8>,
    #[serde(with = "wire_bytes")]
    pub resp_body_preview: Vec<u8>,
    #[serde(with = "wire_bytes")]
    pub req_body: Vec<u8>,
    #[serde(with = "wire_bytes")]
    pub resp_body: Vec<u8>,
    pub req_bytes: u64,
    pub resp_bytes: u64,
    pub content_type: String,
    pub started_at_ms: u64,
    pub finished_at_ms: u64,
    pub duration_ms: u64,
    pub truncated: bool,
    pub mitm_failed: bool,
    pub ws_frames: Vec<CaptureWsFrame>,
}

impl CaptureDetail {
    /// Detail from a still-queued full record (before its 5s flush): the full
    /// bodies are resident in the pending queue, so no disk read is needed.
    fn from_full(r: &CaptureRecord) -> Self {
        Self {
            record_id: r.record_id,
            request_record_id: r.request_record_id,
            conn_id: r.conn_id.clone(),
            host: r.host.clone(),
            method: r.method.clone(),
            scheme: r.scheme.clone(),
            url: r.url.clone(),
            status_code: r.status_code,
            protocol: r.protocol.clone(),
            req_headers: r.req_headers.clone(),
            resp_headers: r.resp_headers.clone(),
            req_body_preview: r.req_body_preview.clone(),
            resp_body_preview: r.resp_body_preview.clone(),
            req_body: r.req_body.clone(),
            resp_body: r.resp_body.clone(),
            req_bytes: r.req_bytes,
            resp_bytes: r.resp_bytes,
            content_type: r.content_type.clone(),
            started_at_ms: r.started_at_ms,
            finished_at_ms: r.finished_at_ms,
            duration_ms: r.duration_ms,
            truncated: r.truncated,
            mitm_failed: r.mitm_failed,
            ws_frames: Vec::new(),
        }
    }

    /// Detail from a ring summary only (memory-only degrade): the full bodies
    /// were never persisted, so the preview stands in for them.
    fn from_summary(s: &CaptureSummary) -> Self {
        Self {
            record_id: s.record_id,
            request_record_id: s.request_record_id,
            conn_id: s.conn_id.clone(),
            host: s.host.clone(),
            method: s.method.clone(),
            scheme: s.scheme.clone(),
            url: s.url.clone(),
            status_code: s.status_code,
            protocol: s.protocol.clone(),
            req_headers: s.req_headers.clone(),
            resp_headers: s.resp_headers.clone(),
            req_body_preview: s.req_body_preview.clone(),
            resp_body_preview: s.resp_body_preview.clone(),
            req_body: s.req_body_preview.clone(),
            resp_body: s.resp_body_preview.clone(),
            req_bytes: s.req_bytes,
            resp_bytes: s.resp_bytes,
            content_type: s.content_type.clone(),
            started_at_ms: s.started_at_ms,
            finished_at_ms: s.finished_at_ms,
            duration_ms: s.duration_ms,
            truncated: s.truncated,
            mitm_failed: s.mitm_failed,
            ws_frames: s.ws_frames.clone(),
        }
    }
}

/// A page of the capture timeline (`captures.get`, Todo 12). `records` are
/// ordered `recordId` ascending (insertion order); `nextCursor` is the
/// high-water mark and is **never reclaimed** by eviction or a clear.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapturePage {
    pub records: Vec<CaptureSummary>,
    pub next_cursor: u64,
    pub first_cursor: u64,
    pub retained: usize,
    pub capacity: usize,
    pub dropped: u64,
    pub evicted: u64,
}

/// Bounded in-memory ring of [`CaptureSummary`]s plus its cursor bookkeeping and
/// the disk-bound pending queue.
pub(crate) struct CaptureStore {
    pub(crate) records: VecDeque<CaptureSummary>,
    /// `recordId → index within `records``. Rebuilt after an eviction.
    pub(crate) by_record_id: HashMap<u64, usize>,
    /// Next `recordId` to assign. Restored from the DB high-water mark on a
    /// restart so numbering never restarts from 0.
    pub(crate) next_record_id: u64,
    /// Highest `recordId` ever issued. Never reclaimed.
    pub(crate) next_cursor: u64,
    pub(crate) cap: usize,
    /// Full records dropped because the pending-flush queue hit its cap.
    pub(crate) dropped: u64,
    /// Ring records dropped because the ring was over capacity.
    pub(crate) evicted: u64,
    /// `startedAtMs` of the oldest retained record, or 0 when empty.
    pub(crate) window_start_ms: u64,
    /// Durable timeline, when a data dir was configured. `None` is memory-only.
    pub(crate) db: Option<Persist>,
    /// Bounded queue of full records awaiting the next durable flush.
    pub(crate) pending: VecDeque<CaptureRecord>,
    /// Running byte estimate of `pending` (the bodies dominate).
    pub(crate) pending_bytes: usize,
    /// `now_ms` of the last durable flush (0 = never), for the 5s gate.
    pub(crate) last_persist_ms: u64,
    /// Count of rows removed by a durable prune (cap-first or 7-day window).
    pub(crate) lost_records: u64,
    /// Effective read floor (`now - CAPTURE_RETENTION_MS`) once the durable sink
    /// is configured.
    pub(crate) retention_floor_ms: Option<u64>,
}

impl CaptureStore {
    pub(crate) fn fresh() -> Self {
        Self {
            records: VecDeque::with_capacity(CAPTURE_RING_CAP),
            by_record_id: HashMap::new(),
            next_record_id: 1,
            next_cursor: 0,
            cap: CAPTURE_RING_CAP,
            dropped: 0,
            evicted: 0,
            window_start_ms: 0,
            db: None,
            pending: VecDeque::new(),
            pending_bytes: 0,
            last_persist_ms: 0,
            lost_records: 0,
            retention_floor_ms: None,
        }
    }

    /// Append `record`, assigning it the next monotonic `record_id` (the value
    /// already in `record.record_id`, minted by the MITM layer for its own
    /// bookkeeping, is ignored — the store is the authority). The full record is
    /// queued for the next durable flush; only its summary enters the ring. Over
    /// capacity the oldest ring record is evicted and counted. Returns the
    /// assigned `record_id`.
    pub(crate) fn push_full(&mut self, mut record: CaptureRecord, _now: u64) -> u64 {
        let id = self.next_record_id;
        self.next_record_id += 1;
        self.next_cursor = id;
        record.record_id = id;
        let summary = summarize(&record);
        self.by_record_id.insert(id, self.records.len());
        self.records.push_back(summary);
        self.enqueue_pending(record);
        while self.records.len() > self.cap {
            let Some(front) = self.records.pop_front() else {
                break;
            };
            self.by_record_id.remove(&front.record_id);
            self.evicted += 1;
            self.reindex();
        }
        self.window_start_ms = self.records.front().map(|r| r.started_at_ms).unwrap_or(0);
        id
    }

    /// Queue `record` for the next durable flush, enforcing both the record and
    /// byte caps. The oldest queued record is dropped (and counted) first.
    fn enqueue_pending(&mut self, mut record: CaptureRecord) {
        if self.db.is_none() {
            return;
        }
        if record.req_body.len() > CAPTURE_BODY_MAX_BYTES {
            record.req_body.truncate(CAPTURE_BODY_MAX_BYTES);
        }
        if record.resp_body.len() > CAPTURE_BODY_MAX_BYTES {
            record.resp_body.truncate(CAPTURE_BODY_MAX_BYTES);
        }
        self.pending_bytes = self.pending_bytes.saturating_add(record_size(&record));
        self.pending.push_back(record);
        while self.pending.len() > CAPTURE_FLUSH_QUEUE_CAP
            || self.pending_bytes > CAPTURE_FLUSH_QUEUE_BYTES
        {
            let Some(front) = self.pending.pop_front() else {
                break;
            };
            self.pending_bytes = self.pending_bytes.saturating_sub(record_size(&front));
            self.dropped += 1;
        }
    }

    /// Rebuild `byRecordId` after a deque eviction shifted every index.
    fn reindex(&mut self) {
        self.by_record_id.clear();
        for (i, r) in self.records.iter().enumerate() {
            self.by_record_id.insert(r.record_id, i);
        }
    }

    /// The actual durable write: one transaction that upserts the pending full
    /// records then prunes cap-first, then by the 7-day window. Returns rows
    /// pruned.
    fn do_flush(&mut self, now: u64) -> usize {
        if self.db.is_none() || self.pending.is_empty() {
            return 0;
        }
        let batch: Vec<CaptureRecord> = self.pending.drain(..).collect();
        self.pending_bytes = 0;
        let result = match self.db.as_mut() {
            Some(db) => db.upsert_batch(&batch, now),
            None => Ok(0),
        };
        match result {
            Ok(pruned) => {
                self.lost_records += pruned as u64;
                self.retention_floor_ms = Some(now.saturating_sub(CAPTURE_RETENTION_MS));
                pruned
            }
            Err(e) => {
                crate::log_message(2, &format!("proxy.captures: flush failed: {e}"));
                // Keep the bodies bounded while retrying: re-queue what still fits.
                for r in batch {
                    self.enqueue_pending(r);
                }
                0
            }
        }
    }

    /// [`do_flush`](Self::do_flush) behind the 5s interval gate.
    fn maybe_flush(&mut self, now: u64) -> usize {
        if self.db.is_none() || self.pending.is_empty() {
            return 0;
        }
        if self.last_persist_ms != 0
            && now.saturating_sub(self.last_persist_ms) < CAPTURE_PERSIST_INTERVAL_MS
        {
            return 0;
        }
        self.last_persist_ms = now;
        self.do_flush(now)
    }

    /// Replace the ring with the seeded window rows and restore cursor
    /// continuity: `nextRecordId = max(record_id)+1` over the whole table (1
    /// when empty), `nextCursor` = the DB high-water mark.
    fn adopt_seed(&mut self, rows: Vec<CaptureSummary>, db: &Persist) {
        self.records.clear();
        self.by_record_id.clear();
        for r in rows {
            let id = r.record_id;
            self.by_record_id.insert(id, self.records.len());
            self.records.push_back(r);
        }
        let max = db.max_record_id().unwrap_or(0);
        self.next_record_id = max + 1;
        self.next_cursor = max;
        self.window_start_ms = self.records.front().map(|r| r.started_at_ms).unwrap_or(0);
    }

    /// One page ordered `recordId` ascending, `recordId > since`. DB-authoritative
    /// when a durable sink is configured; the ring is the near-term fallback.
    pub(crate) fn snapshot(&self, since: u64, limit: usize, filter: &CaptureFilter) -> CapturePage {
        match &self.db {
            Some(db) => self.snapshot_from_db(db, since, limit, filter),
            None => self.snapshot_from_ring(since, limit, filter),
        }
    }

    fn snapshot_from_db(
        &self,
        db: &Persist,
        since: u64,
        limit: usize,
        filter: &CaptureFilter,
    ) -> CapturePage {
        let floor = self.retention_floor_ms.unwrap_or(0);
        let records = match db.load_page(since, limit, floor, filter) {
            Ok(rows) => rows,
            Err(e) => {
                crate::log_message(2, &format!("proxy.captures: read failed: {e}"));
                return self.snapshot_from_ring(since, limit, filter);
            }
        };
        CapturePage {
            records,
            next_cursor: self.next_cursor,
            first_cursor: db.min_record_id(floor).unwrap_or(0),
            retained: db.count(floor).unwrap_or(0),
            capacity: self.cap,
            dropped: self.dropped,
            evicted: self.evicted,
        }
    }

    fn snapshot_from_ring(&self, since: u64, limit: usize, filter: &CaptureFilter) -> CapturePage {
        let limit = limit.min(self.cap.max(1));
        let mut matched: Vec<CaptureSummary> = self
            .records
            .iter()
            .filter(|r| r.record_id > since)
            .filter(|r| filter.matches(r))
            .cloned()
            .collect();
        matched.truncate(limit);
        CapturePage {
            records: matched,
            next_cursor: self.next_cursor,
            first_cursor: self.records.front().map(|r| r.record_id).unwrap_or(0),
            retained: self.records.len(),
            capacity: self.cap,
            dropped: self.dropped,
            evicted: self.evicted,
        }
    }

    /// One record by its captures `recordId`, with full bodies. The pending
    /// (unflushed) queue is checked first so a just-completed exchange is never
    /// a false `PROXY_CAPTURE_NOT_FOUND`; then the durable row; then the ring
    /// summary as the memory-only fallback.
    pub(crate) fn detail(&self, record_id: u64) -> Result<Option<CaptureDetail>, ModuleError> {
        if let Some(full) = self.pending.iter().find(|r| r.record_id == record_id) {
            return self.guard_body_size(CaptureDetail::from_full(full));
        }
        if let Some(db) = &self.db {
            let row = db.load_detail(record_id).map_err(store_failed)?;
            if let Some(detail) = row {
                return self.guard_body_size(detail);
            }
        }
        if let Some(idx) = self.by_record_id.get(&record_id) {
            return Ok(Some(CaptureDetail::from_summary(&self.records[*idx])));
        }
        Ok(None)
    }

    fn guard_body_size(&self, d: CaptureDetail) -> Result<Option<CaptureDetail>, ModuleError> {
        if d.req_body.len() > CAPTURE_BODY_MAX_BYTES || d.resp_body.len() > CAPTURE_BODY_MAX_BYTES {
            return Err(ModuleError::new(
                StatusCode::ResourceExhausted,
                ERR_CAPTURE_BODY_TOO_LARGE,
                format!(
                    "capture record {} body exceeds CAPTURE_BODY_MAX_BYTES",
                    d.record_id
                ),
            ));
        }
        Ok(Some(d))
    }

    /// Drop every retained record (ring, pending flush and durable table) while
    /// keeping `recordId`/cursor numbering monotonic. Returns the count cleared.
    pub(crate) fn clear(&mut self) -> Result<u64, ModuleError> {
        let count = match &self.db {
            Some(db) => db.count(0).map_err(store_failed)? as u64,
            None => self.records.len() as u64,
        };
        self.records.clear();
        self.by_record_id.clear();
        self.pending.clear();
        self.pending_bytes = 0;
        self.window_start_ms = 0;
        if let Some(db) = &self.db {
            db.clear().map_err(store_failed)?;
        }
        Ok(count)
    }
}

/// A durable capture-store read/write failure (`PROXY_CAPTURE_STORE_FAILED`,
/// 500). The in-memory summary ring is left untouched.
fn store_failed(e: rusqlite::Error) -> ModuleError {
    ModuleError::new(
        StatusCode::InternalError,
        ERR_CAPTURE_STORE_FAILED,
        e.to_string(),
    )
}

/// Approximate resident cost of a full record (the two bodies dominate).
fn record_size(r: &CaptureRecord) -> usize {
    r.conn_id.len()
        + r.host.len()
        + r.method.len()
        + r.scheme.len()
        + r.url.len()
        + r.req_headers.len()
        + r.resp_headers.len()
        + r.content_type.len()
        + r.req_body_preview.len()
        + r.resp_body_preview.len()
        + r.req_body.len()
        + r.resp_body.len()
        + 64
}

/// Derive the bounded in-ring summary from a full record. Preview fields are
/// already capped by the MITM layer; every string is defensively re-clipped
/// here so the ring can never hold an unbounded field.
fn summarize(r: &CaptureRecord) -> CaptureSummary {
    let mut truncated = r.truncated;
    let url = clip_str(&r.url, CAPTURE_URL_MAX_BYTES, &mut truncated);
    CaptureSummary {
        record_id: r.record_id,
        request_record_id: r.request_record_id,
        conn_id: clip_plain(&r.conn_id, CAPTURE_CONN_ID_MAX_BYTES),
        host: clip_plain(&r.host, CAPTURE_HOST_MAX_BYTES),
        method: clip_plain(&r.method, 16),
        scheme: clip_plain(&r.scheme, 8),
        url,
        status_code: r.status_code,
        protocol: clip_plain(&r.protocol, 8),
        req_headers: clip_plain(&r.req_headers, CAPTURE_HEADERS_MAX_BYTES),
        resp_headers: clip_plain(&r.resp_headers, CAPTURE_HEADERS_MAX_BYTES),
        req_body_preview: clip_bytes(&r.req_body_preview, CAPTURE_PREVIEW_MAX_BYTES),
        resp_body_preview: clip_bytes(&r.resp_body_preview, CAPTURE_PREVIEW_MAX_BYTES),
        req_bytes: r.req_bytes,
        resp_bytes: r.resp_bytes,
        content_type: clip_plain(&r.content_type, CAPTURE_CONTENT_TYPE_MAX_BYTES),
        started_at_ms: r.started_at_ms,
        finished_at_ms: r.finished_at_ms,
        duration_ms: r.duration_ms,
        truncated,
        mitm_failed: r.mitm_failed,
        ws_frames: Vec::new(),
    }
}

/// Clip a UTF-8 string at a byte bound, honouring char boundaries.
fn clip_plain(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

/// [`clip_plain`] but records that a clip happened.
fn clip_str(s: &str, max: usize, flag: &mut bool) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    *flag = true;
    clip_plain(s, max)
}

fn clip_bytes(v: &[u8], max: usize) -> Vec<u8> {
    if v.len() <= max {
        v.to_vec()
    } else {
        v[..max].to_vec()
    }
}

/// Durable capture timeline: WAL + batched single-transaction upserts + a
/// rolling cap-first / time-window prune.
pub(crate) struct Persist {
    conn: rusqlite::Connection,
    max_rows: usize,
}

impl Persist {
    fn open(path: &str) -> rusqlite::Result<Self> {
        Self::wrap(rusqlite::Connection::open(path)?)
    }

    fn wrap(conn: rusqlite::Connection) -> rusqlite::Result<Self> {
        conn.busy_timeout(std::time::Duration::from_millis(CAPTURE_BUSY_TIMEOUT_MS))?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             PRAGMA busy_timeout=5000;
             CREATE TABLE IF NOT EXISTS capture_records (
               record_id INTEGER PRIMARY KEY,
               request_record_id INTEGER NOT NULL,
               conn_id TEXT NOT NULL,
               host TEXT NOT NULL,
               method TEXT NOT NULL,
               scheme TEXT NOT NULL,
               url TEXT NOT NULL,
               status_code INTEGER NOT NULL,
               protocol TEXT NOT NULL,
               req_headers TEXT NOT NULL,
               resp_headers TEXT NOT NULL,
               req_body_preview BLOB NOT NULL,
               resp_body_preview BLOB NOT NULL,
               req_body BLOB NOT NULL,
               resp_body BLOB NOT NULL,
               req_bytes INTEGER NOT NULL,
               resp_bytes INTEGER NOT NULL,
               content_type TEXT NOT NULL,
               started_at_ms INTEGER NOT NULL,
               finished_at_ms INTEGER NOT NULL,
               duration_ms INTEGER NOT NULL,
               truncated INTEGER NOT NULL,
               mitm_failed INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_capture_finished
               ON capture_records(finished_at_ms, record_id);",
        )?;
        Ok(Self {
            conn,
            max_rows: CAPTURE_MAX_ROWS,
        })
    }

    #[cfg(test)]
    fn set_max_rows(&mut self, n: usize) {
        self.max_rows = n;
    }

    /// Upsert `records` and prune in one transaction: **cap-first** (keep the
    /// newest `max_rows` by `finished_at_ms`), then delete rows older than the
    /// 7-day window. Returns rows pruned.
    fn upsert_batch(&mut self, records: &[CaptureRecord], now: u64) -> rusqlite::Result<usize> {
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO capture_records
                   (record_id, request_record_id, conn_id, host, method, scheme, url,
                    status_code, protocol, req_headers, resp_headers, req_body_preview,
                    resp_body_preview, req_body, resp_body, req_bytes, resp_bytes,
                    content_type, started_at_ms, finished_at_ms, duration_ms, truncated,
                    mitm_failed)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                         ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23)
                 ON CONFLICT(record_id) DO UPDATE SET
                   request_record_id=excluded.request_record_id,
                   conn_id=excluded.conn_id,
                   host=excluded.host,
                   method=excluded.method,
                   scheme=excluded.scheme,
                   url=excluded.url,
                   status_code=excluded.status_code,
                   protocol=excluded.protocol,
                   req_headers=excluded.req_headers,
                   resp_headers=excluded.resp_headers,
                   req_body_preview=excluded.req_body_preview,
                   resp_body_preview=excluded.resp_body_preview,
                   req_body=excluded.req_body,
                   resp_body=excluded.resp_body,
                   req_bytes=excluded.req_bytes,
                   resp_bytes=excluded.resp_bytes,
                   content_type=excluded.content_type,
                   started_at_ms=excluded.started_at_ms,
                   finished_at_ms=excluded.finished_at_ms,
                   duration_ms=excluded.duration_ms,
                   truncated=excluded.truncated,
                   mitm_failed=excluded.mitm_failed",
            )?;
            for r in records {
                stmt.execute(rusqlite::params![
                    r.record_id as i64,
                    r.request_record_id as i64,
                    r.conn_id,
                    r.host,
                    r.method,
                    r.scheme,
                    r.url,
                    r.status_code as i64,
                    r.protocol,
                    r.req_headers,
                    r.resp_headers,
                    r.req_body_preview,
                    r.resp_body_preview,
                    r.req_body,
                    r.resp_body,
                    r.req_bytes as i64,
                    r.resp_bytes as i64,
                    r.content_type,
                    r.started_at_ms as i64,
                    r.finished_at_ms as i64,
                    r.duration_ms as i64,
                    r.truncated as i64,
                    r.mitm_failed as i64,
                ])?;
            }
        }
        let mut pruned = 0usize;
        let total: i64 =
            tx.query_row("SELECT COUNT(*) FROM capture_records", [], |r| r.get(0))?;
        let max_rows = self.max_rows as i64;
        if total > max_rows {
            let excess = total - max_rows;
            pruned += tx.execute(
                "DELETE FROM capture_records WHERE record_id IN (
                   SELECT record_id FROM capture_records
                   ORDER BY finished_at_ms ASC, record_id ASC LIMIT ?1
                 )",
                rusqlite::params![excess],
            )?;
        }
        let cutoff = now.saturating_sub(CAPTURE_RETENTION_MS) as i64;
        pruned += tx.execute(
            "DELETE FROM capture_records WHERE finished_at_ms < ?1",
            rusqlite::params![cutoff],
        )?;
        tx.commit()?;
        Ok(pruned)
    }

    /// Load the window rows (newest `cap`, oldest-first for the ring deque).
    fn seed(&self, now: u64, cap: usize) -> rusqlite::Result<Vec<CaptureSummary>> {
        let cutoff = now.saturating_sub(CAPTURE_RETENTION_MS) as i64;
        let sql = format!(
            "SELECT {SUMMARY_COLUMNS} FROM capture_records
             WHERE finished_at_ms >= ?1 ORDER BY finished_at_ms DESC, record_id DESC LIMIT ?2"
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let mut rows = stmt
            .query_map(rusqlite::params![cutoff, cap as i64], row_to_summary)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows.reverse();
        Ok(rows)
    }

    /// One page ordered `record_id ASC`, filtered in SQL so a DB page never needs
    /// the (bounded) ring.
    fn load_page(
        &self,
        since: u64,
        limit: usize,
        floor: u64,
        f: &CaptureFilter,
    ) -> rusqlite::Result<Vec<CaptureSummary>> {
        let mut sql = format!(
            "SELECT {SUMMARY_COLUMNS} FROM capture_records
             WHERE record_id > ? AND finished_at_ms >= ?"
        );
        let mut vals: Vec<rusqlite::types::Value> =
            vec![(since as i64).into(), (floor as i64).into()];
        if let Some(h) = non_blank(&f.host) {
            sql.push_str(" AND instr(lower(host), ?) > 0");
            vals.push(h.to_ascii_lowercase().into());
        }
        if let Some(m) = non_blank(&f.method) {
            sql.push_str(" AND lower(method) = ?");
            vals.push(m.to_ascii_lowercase().into());
        }
        if let Some(sc) = f.status_class {
            sql.push_str(" AND status_code / 100 = ?");
            vals.push((sc as i64).into());
        }
        if let Some(p) = non_blank(&f.protocol) {
            sql.push_str(" AND lower(protocol) = ?");
            vals.push(p.to_ascii_lowercase().into());
        }
        if let Some(rid) = f.request_record_id {
            sql.push_str(" AND request_record_id = ?");
            vals.push((rid as i64).into());
        }
        sql.push_str(" ORDER BY record_id ASC LIMIT ?");
        vals.push((limit.min(CAPTURE_MAX_ROWS) as i64).into());
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt
            .query_map(rusqlite::params_from_iter(vals.iter()), row_to_summary)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// The full record (bodies + full url/headers) for one `recordId`, or `None`
    /// when it is not retained.
    fn load_detail(&self, record_id: u64) -> rusqlite::Result<Option<CaptureDetail>> {
        let sql = format!(
            "SELECT {SUMMARY_COLUMNS}, req_body, resp_body FROM capture_records
             WHERE record_id = ?1"
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let mut rows = stmt.query_map(rusqlite::params![record_id as i64], |row| {
            let mut summary = row_to_summary(row)?;
            summary.ws_frames = Vec::new();
            let req_body: Vec<u8> = row.get(SUMMARY_COLUMN_COUNT)?;
            let resp_body: Vec<u8> = row.get(SUMMARY_COLUMN_COUNT + 1)?;
            let mut detail = CaptureDetail::from_summary(&summary);
            detail.req_body = req_body;
            detail.resp_body = resp_body;
            Ok(detail)
        })?;
        match rows.next() {
            Some(row) => Ok(Some(row?)),
            None => Ok(None),
        }
    }

    fn clear(&self) -> rusqlite::Result<()> {
        self.conn.execute_batch("DELETE FROM capture_records;")
    }

    fn count(&self, floor: u64) -> rusqlite::Result<usize> {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM capture_records WHERE finished_at_ms >= ?1",
                rusqlite::params![floor as i64],
                |r| r.get::<_, i64>(0),
            )
            .map(|n| n.max(0) as usize)
    }

    fn min_record_id(&self, floor: u64) -> rusqlite::Result<u64> {
        self.conn
            .query_row(
                "SELECT COALESCE(MIN(record_id),0) FROM capture_records WHERE finished_at_ms >= ?1",
                rusqlite::params![floor as i64],
                |r| r.get::<_, i64>(0),
            )
            .map(|n| n.max(0) as u64)
    }

    fn max_record_id(&self) -> rusqlite::Result<u64> {
        self.conn
            .query_row(
                "SELECT COALESCE(MAX(record_id),0) FROM capture_records",
                [],
                |r| r.get::<_, i64>(0),
            )
            .map(|n| n.max(0) as u64)
    }
}

const SUMMARY_COLUMNS: &str = "record_id, request_record_id, conn_id, host, method, scheme, url, \
     status_code, protocol, req_headers, resp_headers, req_body_preview, resp_body_preview, \
     req_bytes, resp_bytes, content_type, started_at_ms, finished_at_ms, duration_ms, \
     truncated, mitm_failed";

/// Number of columns in [`SUMMARY_COLUMNS`]; `load_detail`'s extra body columns
/// follow at this offset.
const SUMMARY_COLUMN_COUNT: usize = 21;

fn row_to_summary(row: &rusqlite::Row<'_>) -> rusqlite::Result<CaptureSummary> {
    Ok(CaptureSummary {
        record_id: row.get::<_, i64>(0)?.max(0) as u64,
        request_record_id: row.get::<_, i64>(1)?.max(0) as u64,
        conn_id: row.get(2)?,
        host: row.get(3)?,
        method: row.get(4)?,
        scheme: row.get(5)?,
        url: row.get(6)?,
        status_code: row.get::<_, i64>(7)?.max(0) as u16,
        protocol: row.get(8)?,
        req_headers: row.get(9)?,
        resp_headers: row.get(10)?,
        req_body_preview: row.get(11)?,
        resp_body_preview: row.get(12)?,
        req_bytes: row.get::<_, i64>(13)?.max(0) as u64,
        resp_bytes: row.get::<_, i64>(14)?.max(0) as u64,
        content_type: row.get(15)?,
        started_at_ms: row.get::<_, i64>(16)?.max(0) as u64,
        finished_at_ms: row.get::<_, i64>(17)?.max(0) as u64,
        duration_ms: row.get::<_, i64>(18)?.max(0) as u64,
        truncated: row.get::<_, i64>(19)? != 0,
        mitm_failed: row.get::<_, i64>(20)? != 0,
        ws_frames: Vec::new(),
    })
}

/// The capture sink the MITM layer pushes completed exchanges into. It only
/// ever queues a summary + a disk-bound full record — never emits an event and
/// never blocks the dataplane on a flush.
struct StoreSink;

impl CaptureSink for StoreSink {
    fn on_capture(&self, record: CaptureRecord) {
        ingest(record);
    }
}

/// Production sink entry: append a completed capture and bump the shared
/// `proxy.request` dirty counter (reused — no new event type).
pub(crate) fn ingest(record: CaptureRecord) {
    let now = crate::now_ms();
    with_store(|st| {
        st.push_full(record, now);
    });
    crate::requests::mark_external_dirty();
}

#[cfg(not(test))]
static STORE: OnceLock<Mutex<CaptureStore>> = OnceLock::new();

#[cfg(not(test))]
fn with_store<R>(f: impl FnOnce(&mut CaptureStore) -> R) -> R {
    let mut guard = STORE
        .get_or_init(|| Mutex::new(CaptureStore::fresh()))
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    f(&mut guard)
}

#[cfg(test)]
thread_local! {
    static TEST_STORE: RefCell<CaptureStore> = RefCell::new(CaptureStore::fresh());
}

/// Tests use a per-thread store so capture-only tests never race the
/// process-global instance.
#[cfg(test)]
fn with_store<R>(f: impl FnOnce(&mut CaptureStore) -> R) -> R {
    TEST_STORE.with(|s| f(&mut s.borrow_mut()))
}

/// The configured durable-sink directory (or `None` while memory-only).
static CONFIGURED_DIR: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// Configure the durable capture sink (`<dir>/proxy_captures.db`), seed the ring
/// with the window rows and restore `recordId` continuity. An empty/absent
/// `data_dir` is an explicit **in-memory-only** degrade, never a panic.
pub(crate) fn configure(data_dir: &str) {
    configure_at(data_dir, crate::now_ms());
}

/// [`configure`] with an explicit clock, so restart/retention tests are
/// deterministic.
pub(crate) fn configure_at(data_dir: &str, now: u64) {
    // Install the SQLite-backed sink for the shipping module (tests exercise
    // the sink directly, never through a process-global side effect).
    #[cfg(not(test))]
    crate::mitm::set_capture_sink(Arc::new(StoreSink));
    let dir = data_dir.trim();
    if dir.is_empty() {
        crate::log_message(
            1,
            "proxy.captures: no data dir, memory-only (persistence disabled)",
        );
        return;
    }
    let path = format!("{}/proxy_captures.db", dir.trim_end_matches('/'));
    with_store(|st| {
        st.do_flush(now);
        match Persist::open(&path) {
            Ok(persist) => {
                match persist.seed(now, st.cap) {
                    Ok(rows) => st.adopt_seed(rows, &persist),
                    Err(e) => {
                        crate::log_message(2, &format!("proxy.captures: seed {path} failed: {e}"))
                    }
                }
                st.pending.clear();
                st.pending_bytes = 0;
                st.last_persist_ms = 0;
                st.lost_records = 0;
                st.retention_floor_ms = Some(now.saturating_sub(CAPTURE_RETENTION_MS));
                st.db = Some(persist);
                crate::log_message(1, &format!("proxy.captures: persistence enabled at {path}"));
            }
            Err(e) => crate::log_message(2, &format!("proxy.captures: open {path} failed: {e}")),
        }
    });
    *CONFIGURED_DIR.lock().unwrap_or_else(|e| e.into_inner()) = Some(dir.to_string());
}

/// Flush the bounded pending queue when the 5s interval has elapsed. Returns
/// rows pruned. A no-op without a configured sink or with nothing pending.
pub(crate) fn maybe_persist(now: u64) -> usize {
    with_store(|st| st.maybe_flush(now))
}

/// One page of the capture timeline over the process-global store.
pub(crate) fn snapshot(since: u64, limit: usize, filter: &CaptureFilter) -> CapturePage {
    with_store(|st| st.snapshot(since, limit, filter))
}

/// One full record by `recordId` over the process-global store.
pub(crate) fn detail(record_id: u64) -> Result<Option<CaptureDetail>, ModuleError> {
    with_store(|st| st.detail(record_id))
}

// ==================== Todo 12: `captures.*` dispatch arms ====================

/// `captures.get` request body:
/// `{ "cursor"?: recordId, "limit"?: number, "filter"?: { ... } }`.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CaptureGetRequest {
    #[serde(default)]
    pub cursor: Option<u64>,
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub filter: CaptureFilter,
}

/// `captures.detail` request body: `{ "recordId": recordId }`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CaptureDetailRequest {
    pub record_id: u64,
}

/// `captures.get` arm. A present-but-non-`u64` `cursor` is the structured
/// `PROXY_CAPTURE_CURSOR_INVALID` (422); any other malformed body is a generic
/// 422. Never a panic.
pub(crate) fn get_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let req: CaptureGetRequest = if payload.is_empty() {
        CaptureGetRequest::default()
    } else {
        let value: serde_json::Value = serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!("captures.get payload must be a JSON object: {e}"))
        })?;
        if let Some(cursor) = value.get("cursor") {
            if cursor.as_u64().is_none() {
                return Err(ModuleError::new(
                    StatusCode::InvalidArgument,
                    ERR_CAPTURE_CURSOR_INVALID,
                    format!("captures.get cursor must be a non-negative integer, got {cursor}"),
                ));
            }
        }
        serde_json::from_value(value).map_err(|e| {
            ModuleError::invalid_arg(format!("captures.get payload must be a JSON object: {e}"))
        })?
    };
    let cursor = req.cursor.unwrap_or(0);
    let limit = req.limit.unwrap_or(DEFAULT_CAPTURE_LIMIT);
    let page = snapshot(cursor, limit, &req.filter);
    let data = serde_json::to_value(&page).map_err(|e| ModuleError::internal(e.to_string()))?;
    crate::ok_data(data)
}

/// `captures.detail` arm. An unknown `recordId` is `PROXY_CAPTURE_NOT_FOUND`
/// (404); a durable read failure is `PROXY_CAPTURE_STORE_FAILED` (500).
pub(crate) fn detail_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let req: CaptureDetailRequest = serde_json::from_slice(payload).map_err(|e| {
        ModuleError::invalid_arg(format!("captures.detail payload must be a JSON object: {e}"))
    })?;
    match detail(req.record_id)? {
        Some(d) => {
            let data =
                serde_json::to_value(&d).map_err(|e| ModuleError::internal(e.to_string()))?;
            crate::ok_data(data)
        }
        None => Err(ModuleError::new(
            StatusCode::ModuleNotFound,
            ERR_CAPTURE_NOT_FOUND,
            format!("capture record not found: {}", req.record_id),
        )),
    }
}

/// `captures.reset` arm. Drops every retained record (the cursor stays
/// monotonic) and reports how many were cleared.
pub(crate) fn reset_arm() -> Result<Vec<u8>, ModuleError> {
    let cleared = with_store(|st| st.clear())?;
    crate::ok_data(serde_json::json!({ "ok": true, "cleared": cleared }))
}

/// The directory the capture sink is configured against (test proof).
#[cfg(test)]
pub(crate) fn configured_dir_for_tests() -> Option<String> {
    CONFIGURED_DIR
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

#[cfg(test)]
pub(crate) fn reset_for_tests() {
    with_store(|st| *st = CaptureStore::fresh());
}

/// Flush the pending queue immediately (no interval gate). Test seam.
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
pub(crate) fn next_record_id_for_tests() -> u64 {
    with_store(|st| st.next_record_id)
}

#[cfg(test)]
pub(crate) fn db_row_count_for_tests() -> Option<usize> {
    with_store(|st| st.db.as_ref().and_then(|db| db.count(0).ok()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A full record fixture: distinct url/host/preview per `seq` so a paged
    /// read can be checked field-by-field against what was written.
    fn fixture(seq: usize, now: u64) -> CaptureRecord {
        CaptureRecord {
            record_id: 0,
            request_record_id: seq as u64,
            conn_id: format!("conn-{seq}"),
            host: format!("h{seq}.example"),
            method: "GET".to_string(),
            scheme: "https".to_string(),
            url: format!("https://h{seq}.example/path/{seq}"),
            status_code: 200,
            protocol: "h1".to_string(),
            req_headers: format!("host: h{seq}.example\r\n"),
            resp_headers: "content-type: text/plain\r\n".to_string(),
            req_body_preview: vec![b'a'; 8],
            resp_body_preview: format!("body-{seq}").into_bytes(),
            req_body: vec![b'a'; 8],
            resp_body: format!("body-{seq}").into_bytes(),
            req_bytes: 8,
            resp_bytes: 7,
            content_type: "text/plain".to_string(),
            started_at_ms: now,
            finished_at_ms: now + 5,
            duration_ms: 5,
            truncated: false,
            mitm_failed: false,
        }
    }

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

    fn unique_temp_dir(tag: &str) -> std::path::PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("gstore_captures_{tag}_{nanos}"));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    /// Acceptance: write → paged read is consistent (every returned field equals
    /// what was written; the pages cover exactly the written records in order).
    #[test]
    fn captures_store_write_read_paged_consistent() {
        let mut st = CaptureStore::fresh();
        let mut ids = Vec::new();
        for i in 0..5 {
            ids.push(st.push_full(fixture(i, 1_000 + i as u64), 1_000 + i as u64));
        }

        let p1 = st.snapshot(0, 2, &CaptureFilter::default());
        assert_eq!(p1.records.len(), 2, "first page honors the limit");
        assert_eq!(p1.retained, 5);
        assert_eq!(p1.capacity, CAPTURE_RING_CAP);
        assert_eq!(p1.first_cursor, 1);
        assert_eq!(p1.next_cursor, 5, "high-water mark is the last issued id");
        let p2 = st.snapshot(p1.records.last().unwrap().record_id, 2, &CaptureFilter::default());
        assert_eq!(p2.records.len(), 2);
        let p3 = st.snapshot(p2.records.last().unwrap().record_id, 2, &CaptureFilter::default());
        assert_eq!(p3.records.len(), 1);

        let all: Vec<&CaptureSummary> = p1
            .records
            .iter()
            .chain(p2.records.iter())
            .chain(p3.records.iter())
            .collect();
        assert_eq!(all.len(), 5, "pages cover every written record exactly once");
        let mut seen: Vec<u64> = all.iter().map(|s| s.record_id).collect();
        seen.sort_unstable();
        assert_eq!(seen, ids, "recordId set matches the write order");

        for (i, s) in all.iter().enumerate() {
            let f = fixture(i, 1_000 + i as u64);
            assert_eq!(s.record_id, ids[i]);
            assert_eq!(s.request_record_id, f.request_record_id);
            assert_eq!(s.url, f.url);
            assert_eq!(s.host, f.host);
            assert_eq!(s.method, f.method);
            assert_eq!(s.status_code, f.status_code);
            assert_eq!(s.req_headers, f.req_headers);
            assert_eq!(s.resp_headers, f.resp_headers);
            assert_eq!(s.req_body_preview, f.req_body_preview);
            assert_eq!(s.resp_body_preview, f.resp_body_preview);
            assert_eq!(s.req_bytes, f.req_bytes);
            assert_eq!(s.resp_bytes, f.resp_bytes);
            assert_eq!(s.content_type, f.content_type);
            assert_eq!(s.started_at_ms, f.started_at_ms);
            assert_eq!(s.finished_at_ms, f.finished_at_ms);
            assert_eq!(s.duration_ms, f.duration_ms);
            assert!(!s.truncated && !s.mitm_failed);
        }
    }

    /// Acceptance: over cap the oldest is evicted first and the eviction is
    /// counted; the index never goes stale.
    #[test]
    fn captures_store_over_cap_evicts_oldest_and_counts() {
        let mut st = CaptureStore::fresh();
        for i in 0..(CAPTURE_RING_CAP + 1) {
            st.push_full(fixture(i, 1_000 + i as u64), 1_000 + i as u64);
        }
        assert_eq!(st.records.len(), CAPTURE_RING_CAP);
        assert_eq!(st.evicted, 1, "exactly the overflow was evicted");
        assert!(
            !st.by_record_id.contains_key(&1),
            "the oldest recordId is gone from the index"
        );
        assert_eq!(st.by_record_id.len(), CAPTURE_RING_CAP);

        let page = st.snapshot(0, CAPTURE_RING_CAP + 10, &CaptureFilter::default());
        assert_eq!(page.records.len(), CAPTURE_RING_CAP);
        assert_eq!(page.records.first().unwrap().record_id, 2, "oldest evicted");
        assert_eq!(
            page.records.last().unwrap().record_id,
            (CAPTURE_RING_CAP + 1) as u64
        );
        assert_eq!(page.evicted, 1);
        assert_eq!(page.first_cursor, 2, "firstCursor advanced past the eviction");
    }

    /// Acceptance: after a restart seed, `recordId` continues incrementing and
    /// the seeded page content equals what was written.
    #[test]
    fn captures_store_restart_seed_record_id_continues() {
        reset_for_tests();
        let dir = unique_temp_dir("restart");
        let dir_s = dir.to_str().unwrap().to_string();

        configure_at(&dir_s, 1_000);
        assert!(db_configured_for_tests());
        for i in 0..3 {
            with_store(|st| st.push_full(fixture(i, 1_000 + i as u64), 1_000 + i as u64));
        }
        assert_eq!(db_row_count_for_tests(), Some(0), "not flushed yet");
        assert_eq!(flush_for_tests(2_000), 0, "no prune below both caps");
        close_for_tests(2_000);

        // Restart: same dir, fresh seed.
        configure_at(&dir_s, 3_000);
        assert_eq!(next_record_id_for_tests(), 4, "numbering continues past the DB");
        let page = snapshot(0, 10, &CaptureFilter::default());
        assert_eq!(page.records.len(), 3, "seed restored the window rows");
        assert_eq!(page.next_cursor, 3);

        let next = with_store(|st| st.push_full(fixture(3, 4_000), 4_000));
        assert_eq!(next, 4, "post-restart id continues incrementing");
        assert_eq!(next_record_id_for_tests(), 5);
        flush_for_tests(4_000);
        assert_eq!(snapshot(0, 10, &CaptureFilter::default()).records.len(), 4, "the 4th row reached the DB");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Acceptance: a capture change bumps the shared dirty counter but never
    /// emits on its own; `requests::tick` emits the one payload-free
    /// `proxy.request` signal with no record data.
    #[test]
    fn captures_store_tick_emits_dirty_signal_without_records() {
        crate::requests::reset_for_tests();
        reset_for_tests();
        let _ = take_request_events();

        ingest(fixture(0, 1_000));
        assert_eq!(
            crate::requests::external_dirty_for_tests(),
            1,
            "a capture change bumps the shared dirty counter"
        );
        assert!(
            take_request_events().is_empty(),
            "captures must never emit a per-record event"
        );

        assert!(
            crate::requests::tick(7, crate::ProxyMode::Vpn, crate::now_ms()),
            "tick must emit because the capture dirty counter is set"
        );
        let events = take_request_events();
        for ev in &events {
            let obj = ev.as_object().unwrap();
            for leaked in ["records", "recordId", "url", "host", "reqBody"] {
                assert!(
                    obj.get(leaked).is_none(),
                    "proxy.request payload must not leak {leaked}"
                );
            }
        }
        assert!(events.len() <= 1, "tick emits at most one signal");
    }

    /// Acceptance (failure): an empty/blank data dir degrades to pure
    /// in-memory, never panics, and still captures.
    #[test]
    fn captures_store_empty_data_dir_is_memory_only_no_panic() {
        reset_for_tests();
        configure_at("", 1_000);
        configure_at("   ", 1_000);
        assert!(!db_configured_for_tests(), "blank dir means memory-only");

        ingest(fixture(0, 1_000));
        let page = snapshot(0, 10, &CaptureFilter::default());
        assert_eq!(page.records.len(), 1);
        assert_eq!(page.next_cursor, 1);
        assert_eq!(page.evicted, 0);
    }

    /// The ring summary is bounded even if the MITM layer ever handed in an
    /// unbounded url/header field: the clip is applied and flagged.
    #[test]
    fn captures_store_truncates_over_long_ring_fields() {
        let mut st = CaptureStore::fresh();
        let mut r = fixture(0, 1_000);
        r.url = format!("https://x.example/{}", "u".repeat(CAPTURE_URL_MAX_BYTES * 2));
        r.req_headers = "h".repeat(CAPTURE_HEADERS_MAX_BYTES * 2);
        r.content_type = "t".repeat(CAPTURE_CONTENT_TYPE_MAX_BYTES * 2);
        st.push_full(r, 1_000);
        let s = st.snapshot(0, 1, &CaptureFilter::default()).records.pop().unwrap();
        assert!(s.truncated, "url clip is flagged");
        assert!(s.url.len() <= CAPTURE_URL_MAX_BYTES);
        assert!(s.req_headers.len() <= CAPTURE_HEADERS_MAX_BYTES);
        assert!(s.content_type.len() <= CAPTURE_CONTENT_TYPE_MAX_BYTES);
    }

    /// A worst-case ring summary (every bounded field at its maximum) must fit
    /// `CAPTURE_RECORD_MAX_BYTES` once base64-encoded onto the wire.
    #[test]
    fn captures_worst_case_record_serializes_within_cap() {
        let s = CaptureSummary {
            record_id: u64::MAX,
            request_record_id: u64::MAX,
            conn_id: "c".repeat(CAPTURE_CONN_ID_MAX_BYTES),
            host: "h".repeat(CAPTURE_HOST_MAX_BYTES),
            method: "M".repeat(16),
            scheme: "https".to_string(),
            url: "u".repeat(CAPTURE_URL_MAX_BYTES),
            status_code: u16::MAX,
            protocol: "ws".to_string(),
            req_headers: "r".repeat(CAPTURE_HEADERS_MAX_BYTES),
            resp_headers: "s".repeat(CAPTURE_HEADERS_MAX_BYTES),
            req_body_preview: vec![0xFF; CAPTURE_PREVIEW_MAX_BYTES],
            resp_body_preview: vec![0xFF; CAPTURE_PREVIEW_MAX_BYTES],
            req_bytes: u64::MAX,
            resp_bytes: u64::MAX,
            content_type: "t".repeat(CAPTURE_CONTENT_TYPE_MAX_BYTES),
            started_at_ms: u64::MAX,
            finished_at_ms: u64::MAX,
            duration_ms: u64::MAX,
            truncated: true,
            mitm_failed: true,
            ws_frames: Vec::new(),
        };
        let bytes = serde_json::to_vec(&s).expect("serialize worst-case capture record");
        assert!(
            bytes.len() <= crate::limits::CAPTURE_RECORD_MAX_BYTES,
            "worst-case capture record {} B > cap {} B",
            bytes.len(),
            crate::limits::CAPTURE_RECORD_MAX_BYTES
        );
        assert!(
            bytes.len() > 3000,
            "not a real worst case: {} B",
            bytes.len()
        );
    }

    /// An IPv6 authority in `host`/`url` survives both the paged read and the
    /// detail read (the Dart side derives `path` from the bracketed url).
    #[test]
    fn captures_ipv6_host_round_trips_through_page_and_detail() {
        let mut st = CaptureStore::fresh();
        let mut r = fixture(0, 1_000);
        r.host = "[2001:db8::1]".to_string();
        r.url = "https://[2001:db8::1]:8443/v6?a=1".to_string();
        st.push_full(r, 1_000);

        let page = st.snapshot(0, 10, &CaptureFilter::default());
        assert_eq!(page.records[0].host, "[2001:db8::1]");
        assert!(page.records[0].url.starts_with("https://[2001:db8::1]:8443/"));

        let d = st.detail(page.records[0].record_id).unwrap().unwrap();
        assert_eq!(d.host, "[2001:db8::1]");
        assert_eq!(d.url, "https://[2001:db8::1]:8443/v6?a=1");
    }

    /// `requestRecordId == 0` (a short-lived cross-tick flow with no `requests.*`
    /// record) is a first-class row: retained, returned, and filterable.
    #[test]
    fn captures_orphan_request_record_id_zero_is_retained_and_filterable() {
        let mut st = CaptureStore::fresh();
        let mut orphan = fixture(0, 1_000);
        orphan.request_record_id = 0;
        let id = st.push_full(orphan, 1_000);
        st.push_full(fixture(1, 1_001), 1_001);

        let all = st.snapshot(0, 10, &CaptureFilter::default());
        assert_eq!(all.records.len(), 2, "orphan capture must not be dropped");
        assert_eq!(all.records[0].record_id, id);
        assert_eq!(all.records[0].request_record_id, 0);

        let orphans = st.snapshot(
            0,
            10,
            &CaptureFilter {
                request_record_id: Some(0),
                ..Default::default()
            },
        );
        assert_eq!(orphans.records.len(), 1);
        assert_eq!(orphans.records[0].record_id, id);
    }

    /// `captures.get` filters: case-insensitive host substring, exact method /
    /// protocol, and `statusClass`.
    #[test]
    fn captures_page_filter_matches_host_method_status_protocol() {
        let mut st = CaptureStore::fresh();
        let mut a = fixture(0, 1_000);
        a.host = "api.example.com".to_string();
        a.method = "POST".to_string();
        a.status_code = 404;
        a.protocol = "h2".to_string();
        st.push_full(a, 1_000);
        let mut b = fixture(1, 1_001);
        b.host = "cdn.example.com".to_string();
        b.method = "GET".to_string();
        b.status_code = 200;
        b.protocol = "h1".to_string();
        st.push_full(b, 1_001);

        let f = CaptureFilter {
            host: Some("API".into()),
            ..Default::default()
        };
        assert_eq!(st.snapshot(0, 10, &f).records.len(), 1);
        let f = CaptureFilter {
            method: Some("get".into()),
            ..Default::default()
        };
        assert_eq!(st.snapshot(0, 10, &f).records[0].host, "cdn.example.com");
        let f = CaptureFilter {
            status_class: Some(4),
            ..Default::default()
        };
        assert_eq!(st.snapshot(0, 10, &f).records[0].status_code, 404);
        let f = CaptureFilter {
            protocol: Some("H2".into()),
            ..Default::default()
        };
        assert_eq!(st.snapshot(0, 10, &f).records.len(), 1);
    }

    /// `captures.detail` returns the full body from the pending queue before the
    /// flush and from SQLite after it; an unknown id is `None`.
    #[test]
    fn captures_detail_reads_full_body_from_pending_and_db() {
        reset_for_tests();
        let dir = unique_temp_dir("detail");
        let dir_s = dir.to_str().unwrap().to_string();
        configure_at(&dir_s, 1_000);
        assert!(db_configured_for_tests());

        let mut r = fixture(0, 1_000);
        r.req_body = b"full-request-body".to_vec();
        r.resp_body = b"full-response-body".to_vec();
        let id = with_store(|st| st.push_full(r, 1_000));

        let pending = detail(id).unwrap().unwrap();
        assert_eq!(pending.req_body, b"full-request-body");
        assert_eq!(pending.resp_body, b"full-response-body");

        assert_eq!(flush_for_tests(2_000), 0);
        let durable = detail(id).unwrap().unwrap();
        assert_eq!(durable.req_body, b"full-request-body");
        assert_eq!(durable.resp_body, b"full-response-body");
        assert!(detail(999).unwrap().is_none(), "unknown record is None");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `captures.get` rejects a present-but-non-`u64` cursor with the frozen 422
    /// `PROXY_CAPTURE_CURSOR_INVALID`.
    #[test]
    fn captures_get_arm_rejects_invalid_cursor() {
        let err = get_arm(br#"{"cursor":"nope"}"#).unwrap_err();
        assert_eq!(err.status, StatusCode::InvalidArgument);
        assert_eq!(err.code, ERR_CAPTURE_CURSOR_INVALID);
    }

    /// `captures.detail` of an unknown id is `PROXY_CAPTURE_NOT_FOUND`.
    #[test]
    fn captures_detail_arm_unknown_is_not_found() {
        reset_for_tests();
        let err = detail_arm(br#"{"recordId":42}"#).unwrap_err();
        assert_eq!(err.status, StatusCode::ModuleNotFound);
        assert_eq!(err.code, ERR_CAPTURE_NOT_FOUND);
    }

    /// `captures.reset` clears every row but keeps the cursor monotonic, and a
    /// cleared record is no longer detail-able (never stale).
    #[test]
    fn captures_reset_clears_records_but_keeps_cursor_monotonic() {
        reset_for_tests();
        with_store(|st| {
            st.push_full(fixture(0, 1_000), 1_000);
            st.push_full(fixture(1, 1_001), 1_001);
        });
        let before = snapshot(0, 10, &CaptureFilter::default());
        assert_eq!(before.next_cursor, 2);
        let id = before.records[0].record_id;

        let out = reset_arm().unwrap();
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["cleared"], 2);

        let after = snapshot(0, 10, &CaptureFilter::default());
        assert!(after.records.is_empty());
        assert_eq!(after.next_cursor, 2, "cursor is never recycled");
        assert!(detail(id).unwrap().is_none(), "detail must not be stale");
    }
}
