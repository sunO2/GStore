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

use serde::{Deserialize, Serialize};

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
        self.window_start_ms = 0;
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
}
