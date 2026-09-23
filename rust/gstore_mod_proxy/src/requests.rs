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

use std::collections::{HashMap, VecDeque};
#[cfg(not(test))]
use std::sync::{Mutex, OnceLock};

use gstore_contract::error::ModuleError;
use serde::{Deserialize, Serialize};

use crate::conn::ConnRecord;

/// Hard cap on retained in-memory request records. Over capacity the oldest is
/// evicted first (deterministic: the deque is in insertion / `recordId` order).
pub(crate) const REQUEST_RING_CAP: usize = 4096;

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
        id
    }

    /// Drop every retained record. The cursor and the id sequence stay monotonic
    /// (never reset), so a concurrent client cannot mistake a clear for a rewind.
    pub(crate) fn clear(&mut self) {
        self.records.clear();
        self.by_record_id.clear();
        self.active_by_conn.clear();
        self.stale_live.clear();
        self.window_start_ms = 0;
    }

    /// Open (or revive) the record for `rec` at the capture chokepoint. A
    /// `connId` that already has a non-terminal record re-uses it — a stale flow
    /// re-entering the projection must not mint a duplicate open — and the
    /// re-entry is counted. Returns the record's `recordId`.
    pub(crate) fn open_record(&mut self, rec: &ConnRecord, now_ms: u64) -> u64 {
        if let Some(&rid) = self.active_by_conn.get(&rec.id) {
            if let Some(idx) = self.by_record_id.get(&rid).copied() {
                let r = &mut self.records[idx];
                if r.close_ts_ms.is_none() {
                    if r.close_reason == CLOSE_REASON_STALE {
                        r.close_reason = CLOSE_REASON_OPEN.to_string();
                        self.reentered += 1;
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
        if r.close_reason != CLOSE_REASON_STALE {
            r.close_reason = CLOSE_REASON_STALE.to_string();
        }
        let open_ts_ms = r.open_ts_ms;
        self.insert_stale(conn_id, rid, open_ts_ms);
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

    /// Rebuild the `recordId → index` map from the current deque.
    fn reindex(&mut self) {
        self.by_record_id.clear();
        for (i, r) in self.records.iter().enumerate() {
            self.by_record_id.insert(r.record_id, i);
        }
    }

    /// Build a page of records newer than `since_record_id` that match `filters`.
    /// Ordered by `openTsMs` descending, ties by `recordId` ascending, then
    /// truncated to `limit`.
    pub(crate) fn snapshot(
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
        serde_json::from_slice(payload).map_err(|e| {
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
        let n = st.records.len();
        st.clear();
        n
    });
    crate::ok_data(serde_json::json!({ "ok": true, "cleared": cleared }))
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
}
