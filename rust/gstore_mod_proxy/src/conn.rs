//! Active-connection tracking for `conn.list` / `conn.close` (Todo 10).
//!
//! meow owns the byte accounting and the connection lifecycle: every TCP flow
//! is inserted into `meow_tunnel::statistics::Statistics::connections` (a live
//! `DashMap<Uuid, ConnectionInfo>`) by `tcp::route_inbound_tcp`, its counters
//! are bumped by the relay, and its entry is removed when the `ConnectionGuard`
//! drops. This module does **not** reimplement any of that. It keeps a bounded
//! projection of the live table so `conn.list` returns a stable, capped list
//! with the fields the UI needs (start time included) and `conn.close` can
//! signal a flow.
//!
//! Bound policy: the projection is rebuilt from meow's live table on every
//! `conn.list`, reusing already-parsed start times, and is capped at
//! [`CONN_TRACK_CAP`]. If more than the cap are live, the **oldest-started**
//! entries are dropped from the projection (meow still accounts their bytes);
//! `conn.list` is therefore a bounded view, never unbounded memory.
//!
//! ## Todo 17 — list/close control contract
//!
//! * `conn.list` is **paginated** (`offset`/`limit`) and **filterable** by
//!   `domain` (case-insensitive substring) and `outbound` (case-insensitive
//!   exact). Order is stable: newest `startedAtMs` first, ties broken by `id`
//!   ascending, so a paged read never skips or duplicates a row.
//! * `conn.close(id)` is **idempotent**: a live id is signalled and reports
//!   `closed: true`; an id this module has already seen closed reports
//!   `closed: false, alreadyClosed: true` with no error; an id this module has
//!   never tracked is `PROXY_CONN_NOT_FOUND` (404). It never panics — the
//!   mechanism is meow's `Statistics::close_connection`, which only removes the
//!   entry and drops its counter guard (it cannot crash the relay loop).
//! * Connection ids are meow's opaque v4 **UUID strings** (`ConnectionInfo.id`).
//!   No raw pointers and no `&ConnectionInfo` are ever exposed across the ABI.
//! * Explicit `conn.close` / `conn.close_all` emit one `proxy.conn` event each
//!   (control-plane, user-triggered). The steady open/close stream is **not**
//!   streamed per connection: the host ring is only 128 entries; it is folded
//!   into the throttled `proxy.stats` snapshot ([`crate::stats`]) and the
//!   `log.get` ring instead.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Mutex, OnceLock};

use gstore_contract::error::{ModuleError, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::logging::{self, ConnectionLog, LogLevel};
use crate::nodes::ERR_NOT_CONFIGURED;

/// Hard cap on the projected connection list. Mirrors the host's 100-entry
/// event ring philosophy scaled for a live connection table.
pub(crate) const CONN_TRACK_CAP: usize = 1024;
/// Default page size for `conn.list` when no `limit` is supplied.
pub(crate) const DEFAULT_LIST_LIMIT: usize = 256;
/// Bound on the recently-closed id tombstone: enough to answer an idempotent
/// `conn.close` retry without growing memory with connection churn.
pub(crate) const CONN_TOMBSTONE_CAP: usize = 1024;
/// Domain error code for `conn.close` on an id this module has never tracked.
pub(crate) const ERR_CONN_NOT_FOUND: &str = "PROXY_CONN_NOT_FOUND";

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ConnRecord {
    pub id: String,
    pub src: String,
    pub dst: String,
    pub domain: String,
    pub network: String,
    pub rule: String,
    pub rule_payload: String,
    pub outbound: String,
    pub started_at_ms: u64,
    pub upload_bytes: i64,
    pub download_bytes: i64,
}

struct ConnStore {
    map: HashMap<String, ConnRecord>,
    closed: VecDeque<String>,
    closed_set: HashSet<String>,
}

impl ConnStore {
    fn fresh() -> Self {
        Self {
            map: HashMap::new(),
            closed: VecDeque::new(),
            closed_set: HashSet::new(),
        }
    }

    #[cfg(test)]
    fn clear(&mut self) {
        self.map.clear();
        self.closed.clear();
        self.closed_set.clear();
    }

    fn mark_closed(&mut self, id: &str) {
        if !self.closed_set.insert(id.to_string()) {
            return;
        }
        self.closed.push_back(id.to_string());
        while self.closed.len() > CONN_TOMBSTONE_CAP {
            if let Some(old) = self.closed.pop_front() {
                self.closed_set.remove(&old);
            }
        }
    }

    fn is_recently_closed(&self, id: &str) -> bool {
        self.closed_set.contains(id)
    }
}

static CONN_STORE: OnceLock<Mutex<ConnStore>> = OnceLock::new();

fn store() -> &'static Mutex<ConnStore> {
    CONN_STORE.get_or_init(|| Mutex::new(ConnStore::fresh()))
}

#[cfg(test)]
pub(crate) fn reset_for_tests() {
    store()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
}

fn parse_rfc3339_ms(start: &str) -> u64 {
    use time::format_description::well_known::Rfc3339;
    time::OffsetDateTime::parse(start, &Rfc3339)
        .ok()
        .map(|dt| (dt.unix_timestamp_nanos() / 1_000_000).max(0) as u64)
        .unwrap_or(0)
}

fn from_info(info: &meow_tunnel::statistics::ConnectionInfo, started_at_ms: u64) -> ConnRecord {
    let metadata = &info.metadata;
    let dst = match metadata.dst_ip {
        Some(ip) => format!("{ip}:{}", metadata.dst_port),
        None => metadata.remote_address().to_string(),
    };
    ConnRecord {
        id: info.id.to_string(),
        src: metadata.source_address().to_string(),
        dst,
        domain: metadata.rule_host().to_string(),
        network: "tcp".to_string(),
        rule: info.rule.to_string(),
        rule_payload: info.rule_payload.to_string(),
        outbound: info
            .chains
            .first()
            .map(ToString::to_string)
            .unwrap_or_else(|| "DIRECT".to_string()),
        started_at_ms,
        upload_bytes: info.counters.upload_bytes() as i64,
        download_bytes: info.counters.download_bytes() as i64,
    }
}

/// The projection diff produced by [`sync_full`]: the current bounded view plus
/// the connections that disappeared since the last sync.
pub(crate) struct SyncOutcome {
    pub live: Vec<ConnRecord>,
    pub closed: Vec<ConnRecord>,
}

/// Rebuild the bounded projection from meow's live connection table and return
/// the records together with the open/close transitions.
///
/// Todo 15: the transition diff is the connection-log source — a record that
/// appears is an `open`, one that disappeared is a `close` (duration from its
/// start time). Logging happens **after** the store lock is released. Todo 16
/// folds the same diff into its per-domain aggregate.
pub(crate) fn sync_full(stats: &meow_tunnel::Statistics) -> SyncOutcome {
    let (out, opened, closed) = {
        let mut store = store().lock().unwrap_or_else(|e| e.into_inner());
        let mut next: HashMap<String, ConnRecord> = HashMap::with_capacity(
            stats.connections.len().min(CONN_TRACK_CAP),
        );
        for entry in stats.connections.iter() {
            let info = entry.value();
            let id = info.id.to_string();
            let started_at_ms = store
                .map
                .get(&id)
                .map(|r| r.started_at_ms)
                .unwrap_or_else(|| parse_rfc3339_ms(&info.start));
            next.insert(id, from_info(info, started_at_ms));
        }
        if next.len() > CONN_TRACK_CAP {
            let mut ids: Vec<String> = next.keys().cloned().collect();
            ids.sort_by_key(|id| next[id].started_at_ms);
            for id in ids.iter().take(next.len() - CONN_TRACK_CAP) {
                next.remove(id);
            }
        }
        let opened: Vec<ConnRecord> = next
            .values()
            .filter(|r| !store.map.contains_key(&r.id))
            .cloned()
            .collect();
        let now = crate::now_ms();
        let closed: Vec<(ConnRecord, u64)> = store
            .map
            .values()
            .filter(|r| !next.contains_key(&r.id))
            .map(|r| (r.clone(), now.saturating_sub(r.started_at_ms)))
            .collect();
        store.map = next;
        for (record, _) in &closed {
            store.mark_closed(&record.id);
        }
        let mut out: Vec<ConnRecord> = store.map.values().cloned().collect();
        out.sort_by(|a, b| {
            b.started_at_ms
                .cmp(&a.started_at_ms)
                .then_with(|| a.id.cmp(&b.id))
        });
        (out, opened, closed)
    };
    for record in &opened {
        logging::record_connection(LogLevel::Info, connection_log(record, "in", 0, None), "open");
    }
    for (record, duration) in &closed {
        logging::record_connection(
            LogLevel::Info,
            connection_log(record, "in", *duration, None),
            "close",
        );
    }
    SyncOutcome {
        live: out,
        closed: closed.into_iter().map(|(r, _)| r).collect(),
    }
}

/// The live bounded view (Todo 10 `conn.list`). See [`sync_full`].
pub(crate) fn sync(stats: &meow_tunnel::Statistics) -> Vec<ConnRecord> {
    sync_full(stats).live
}

/// Build the stable, secret-free connection log payload from a projection row.
fn connection_log(
    r: &ConnRecord,
    direction: &str,
    duration_ms: u64,
    error: Option<String>,
) -> ConnectionLog {
    ConnectionLog {
        id: r.id.clone(),
        direction: direction.to_string(),
        domain: r.domain.clone(),
        outbound: r.outbound.clone(),
        rule: r.rule.clone(),
        rule_payload: r.rule_payload.clone(),
        network: r.network.clone(),
        src: r.src.clone(),
        dst: r.dst.clone(),
        upload_bytes: r.upload_bytes,
        download_bytes: r.download_bytes,
        bytes: r.upload_bytes + r.download_bytes,
        duration_ms,
        error,
    }
}

fn active_tunnel() -> Result<std::sync::Arc<meow_tunnel::Tunnel>, ModuleError> {
    crate::rules::active_tunnel().ok_or_else(|| {
        ModuleError::new(
            StatusCode::InvalidArgument,
            ERR_NOT_CONFIGURED,
            "engine is not running; start the tunnel before listing connections",
        )
    })
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ListRequest {
    #[serde(default)]
    offset: Option<usize>,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    domain: Option<String>,
    #[serde(default)]
    outbound: Option<String>,
}

impl ListRequest {
    fn parse(payload: &[u8]) -> Result<Self, ModuleError> {
        if payload.is_empty() {
            return Ok(Self::default());
        }
        serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!("conn.list payload must be a JSON object: {e}"))
        })
    }

    fn limit(&self) -> usize {
        self.limit.unwrap_or(DEFAULT_LIST_LIMIT).clamp(1, CONN_TRACK_CAP)
    }

    fn offset(&self) -> usize {
        self.offset.unwrap_or(0)
    }

    fn matches(&self, r: &ConnRecord) -> bool {
        let domain_matches = self
            .domain
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|needle| r.domain.to_lowercase().contains(&needle.to_lowercase()))
            .unwrap_or(true);
        let outbound_matches = self
            .outbound
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|want| r.outbound.eq_ignore_ascii_case(want))
            .unwrap_or(true);
        domain_matches && outbound_matches
    }
}

/// Filter then page a pre-sorted projection. `count` is the number of rows that
/// matched the filters (before pagination).
fn page_records(records: &[ConnRecord], req: &ListRequest) -> (Vec<ConnRecord>, usize) {
    let matching: Vec<ConnRecord> = records
        .iter()
        .filter(|r| req.matches(r))
        .cloned()
        .collect();
    let count = matching.len();
    let page: Vec<ConnRecord> = matching
        .into_iter()
        .skip(req.offset().min(count))
        .take(req.limit())
        .collect();
    (page, count)
}

pub(crate) fn list_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let req = ListRequest::parse(payload)?;
    let tunnel = active_tunnel()?;
    let records = sync(tunnel.statistics().as_ref());
    let total = records.len();
    let (page, count) = page_records(&records, &req);
    let offset = req.offset().min(count);
    let returned = page.len();
    crate::ok_data(json!({
        "connections": page,
        "count": count,
        "returned": returned,
        "total": total,
        "offset": offset,
        "limit": req.limit(),
        "hasMore": offset + returned < count,
        "capacity": CONN_TRACK_CAP,
    }))
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct CloseRequest {
    id: String,
}

fn emit_conn_event(instance_id: u64, action: &str, id: &str, record: Option<&ConnRecord>) {
    let mut payload = json!({ "action": action, "id": id });
    if let Some(r) = record {
        payload["domain"] = json!(r.domain);
        payload["outbound"] = json!(r.outbound);
        payload["uploadBytes"] = json!(r.upload_bytes);
        payload["downloadBytes"] = json!(r.download_bytes);
    }
    crate::emit_json(instance_id, crate::EVT_CONN, &payload);
}

pub(crate) fn close_arm(instance_id: u64, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let req: CloseRequest = if payload.is_empty() {
        return Err(ModuleError::invalid_arg("conn.close requires {id}"));
    } else {
        serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!("conn.close payload must be a JSON object: {e}"))
        })?
    };
    let id = uuid::Uuid::parse_str(req.id.trim()).map_err(|e| {
        ModuleError::invalid_arg(format!("conn.close id '{}' is not a UUID: {e}", req.id))
    })?;
    let tunnel = active_tunnel()?;
    let stats = tunnel.statistics();

    let live_record = stats
        .connections
        .get(&id)
        .map(|entry| from_info(entry.value(), parse_rfc3339_ms(&entry.value().start)));
    let (projected, known) = {
        let store = store().lock().unwrap_or_else(|e| e.into_inner());
        (
            store.map.get(&req.id).cloned(),
            store.map.contains_key(&req.id) || store.is_recently_closed(&req.id),
        )
    };
    let was_live = live_record.is_some();

    if !was_live && !known {
        return Err(ModuleError::new(
            StatusCode::ModuleNotFound,
            ERR_CONN_NOT_FOUND,
            format!("connection '{}' is not tracked", req.id),
        ));
    }

    if was_live {
        stats.close_connection(id);
    }
    let record = projected.or(live_record);
    {
        let mut store = store().lock().unwrap_or_else(|e| e.into_inner());
        store.map.remove(&req.id);
        store.mark_closed(&req.id);
    }

    if was_live {
        if let Some(r) = &record {
            let duration = crate::now_ms().saturating_sub(r.started_at_ms);
            logging::record_connection(
                LogLevel::Info,
                connection_log(r, "in", duration, None),
                "close",
            );
        }
        emit_conn_event(instance_id, "close", &req.id, record.as_ref());
    }
    crate::log_message(
        1,
        &format!(
            "proxy: conn.close id={} live={was_live} alreadyClosed={}",
            req.id,
            !was_live
        ),
    );
    crate::ok_data(json!({
        "ok": true,
        "id": req.id,
        "closed": was_live,
        "alreadyClosed": !was_live,
    }))
}

pub(crate) fn close_all_arm(instance_id: u64) -> Result<Vec<u8>, ModuleError> {
    let tunnel = active_tunnel()?;
    let records: Vec<ConnRecord> = {
        let store = store().lock().unwrap_or_else(|e| e.into_inner());
        store.map.values().cloned().collect()
    };
    let closed = tunnel.statistics().close_all_connections_counted();
    {
        let mut store = store().lock().unwrap_or_else(|e| e.into_inner());
        for r in &records {
            store.mark_closed(&r.id);
        }
        store.map.clear();
    }
    let now = crate::now_ms();
    for r in &records {
        let duration = now.saturating_sub(r.started_at_ms);
        logging::record_connection(
            LogLevel::Info,
            connection_log(r, "in", duration, None),
            "close",
        );
    }
    if closed > 0 {
        crate::emit_json(
            instance_id,
            crate::EVT_CONN,
            &json!({ "action": "close_all", "closed": closed }),
        );
    }
    crate::log_message(1, &format!("proxy: conn.close_all closed={closed}"));
    crate::ok_data(json!({ "ok": true, "closed": closed }))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use meow_common::{ConnType, Metadata, Network};
    use smallvec::SmallVec;
    use smol_str::SmolStr;
    use std::sync::Arc;

    use crate::TEST_SERIAL as SERIAL;

    fn fixture_metadata(host: &str, dst: &str, src: &str) -> Metadata {
        Metadata {
            network: Network::Tcp,
            conn_type: ConnType::Tun,
            host: host.into(),
            dst_ip: Some(dst.parse().unwrap()),
            dst_port: 443,
            src_ip: Some(src.parse().unwrap()),
            src_port: 40000,
            ..Default::default()
        }
    }

    fn track(stats: &meow_tunnel::Statistics, host: &str) -> uuid::Uuid {
        track_out(stats, host, "proxy-a")
    }

    fn track_out(stats: &meow_tunnel::Statistics, host: &str, outbound: &str) -> uuid::Uuid {
        stats.track_connection(
            fixture_metadata(host, "1.2.3.4", "10.10.0.2"),
            SmolStr::new("DOMAIN-SUFFIX"),
            SmolStr::new(host),
            SmallVec::from_vec(vec![Arc::<str>::from(outbound)]),
        )
    }

    fn fixture_tunnel() -> Arc<meow_tunnel::Tunnel> {
        crate::rules::reset_for_tests();
        let resolver = Arc::new(meow_dns::Resolver::new(
            Vec::new(),
            Vec::new(),
            meow_common::DnsMode::Normal,
            meow_trie::DomainTrie::new(),
            false,
            false,
        ));
        let _ = crate::dispatch::build_engine(resolver);
        crate::rules::active_tunnel().expect("engine attached")
    }

    fn rec(id: &str, domain: &str, outbound: &str, started_at_ms: u64) -> ConnRecord {
        ConnRecord {
            id: id.into(),
            src: "10.10.0.2:40000".into(),
            dst: "1.2.3.4:443".into(),
            domain: domain.into(),
            network: "tcp".into(),
            rule: "DOMAIN-SUFFIX".into(),
            rule_payload: domain.into(),
            outbound: outbound.into(),
            started_at_ms,
            upload_bytes: 0,
            download_bytes: 0,
        }
    }

    #[test]
    fn page_records_filters_and_paginates() {
        let records = vec![
            rec("id-1", "a.example", "proxy-a", 300),
            rec("id-2", "b.example", "proxy-b", 200),
            rec("id-3", "a.example", "DIRECT", 100),
        ];

        let req = ListRequest::parse(b"").unwrap();
        let (page, count) = page_records(&records, &req);
        assert_eq!((count, page.len()), (3, 3), "no filter returns everything");

        let req = ListRequest::parse(br#"{"domain":"A.EXAMPLE"}"#).unwrap();
        let (page, count) = page_records(&records, &req);
        assert_eq!(count, 2, "domain filter is a case-insensitive substring");
        assert!(page.iter().all(|r| r.domain == "a.example"));

        let req = ListRequest::parse(br#"{"outbound":"proxy-b"}"#).unwrap();
        let (page, count) = page_records(&records, &req);
        assert_eq!((count, page.len()), (1, 1));
        assert_eq!(page[0].outbound, "proxy-b");

        let req = ListRequest::parse(br#"{"outbound":"proxy"}"#).unwrap();
        let (_, count) = page_records(&records, &req);
        assert_eq!(count, 0, "outbound filter is exact, not a substring");

        let (page, count) = {
            let req = ListRequest::parse(br#"{"limit":2,"offset":0}"#).unwrap();
            page_records(&records, &req)
        };
        assert_eq!((count, page.len()), (3, 2));
        assert_eq!(page[0].id, "id-1");

        let (page, _) = {
            let req = ListRequest::parse(br#"{"limit":2,"offset":2}"#).unwrap();
            page_records(&records, &req)
        };
        assert_eq!(page.len(), 1);
        assert_eq!(page[0].id, "id-3");

        let (page, _) = {
            let req = ListRequest::parse(br#"{"limit":2,"offset":99}"#).unwrap();
            page_records(&records, &req)
        };
        assert!(page.is_empty(), "offset past the end is an empty page, no panic");
    }

    #[test]
    fn sync_order_is_stable_across_calls_for_pagination() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let stats = meow_tunnel::Statistics::new();
        for i in 0..8 {
            track_out(&stats, &format!("h{i}.example"), &format!("proxy-{i}"));
        }
        let first: Vec<String> = sync(&stats).into_iter().map(|r| r.id).collect();
        let second: Vec<String> = sync(&stats).into_iter().map(|r| r.id).collect();
        assert_eq!(first, second, "projection order must be deterministic");
        assert_eq!(first.len(), 8);
        reset_for_tests();
    }

    #[test]
    fn close_is_idempotent_and_unknown_is_not_found() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let tunnel = fixture_tunnel();
        let stats = tunnel.statistics();
        let id = track_out(stats.as_ref(), "close.example", "proxy-a");
        assert_eq!(sync(stats.as_ref()).len(), 1);

        let payload = format!(r#"{{"id":"{id}"}}"#);
        let data = close_arm(7, payload.as_bytes()).unwrap();
        let v: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(v["data"]["closed"], true);
        assert_eq!(v["data"]["alreadyClosed"], false);
        assert!(stats.connection_counters(id).is_none(), "live connection signalled");
        assert!(sync(stats.as_ref()).is_empty(), "closed connection leaves the projection");

        let data = close_arm(7, payload.as_bytes()).unwrap();
        let v: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(v["data"]["closed"], false, "second close is a no-op");
        assert_eq!(v["data"]["alreadyClosed"], true);

        let unknown = uuid::Uuid::new_v4();
        let payload = format!(r#"{{"id":"{unknown}"}}"#);
        let err = close_arm(7, payload.as_bytes()).unwrap_err();
        assert_eq!(err.code, ERR_CONN_NOT_FOUND);
        assert_eq!(err.status, StatusCode::ModuleNotFound);
        assert_eq!(err.status as i32, 404);

        let malformed = close_arm(7, br#"{"id":"not-a-uuid"}"#).unwrap_err();
        assert_eq!(malformed.status, StatusCode::InvalidArgument);

        crate::rules::reset_for_tests();
        reset_for_tests();
    }

    #[test]
    fn sync_returns_fixture_connections_with_all_fields() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let stats = meow_tunnel::Statistics::new();
        let id = track(&stats, "example.com");

        let records = sync(&stats);
        assert_eq!(records.len(), 1);
        let r = &records[0];
        assert_eq!(r.id, id.to_string());
        assert_eq!(r.domain, "example.com");
        assert_eq!(r.dst, "1.2.3.4:443");
        assert_eq!(r.src, "10.10.0.2:40000");
        assert_eq!(r.network, "tcp");
        assert_eq!(r.rule, "DOMAIN-SUFFIX");
        assert_eq!(r.rule_payload, "example.com");
        assert_eq!(r.outbound, "proxy-a");
        assert!(r.started_at_ms > 1_600_000_000_000, "start parsed to epoch ms");
        assert_eq!(r.upload_bytes, 0);
        assert_eq!(r.download_bytes, 0);

        reset_for_tests();
    }

    #[test]
    fn closed_connections_leave_the_projection() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let stats = meow_tunnel::Statistics::new();
        let id = track(&stats, "a.example");
        assert_eq!(sync(&stats).len(), 1);
        stats.close_connection(id);
        assert!(sync(&stats).is_empty());
        reset_for_tests();
    }

    #[test]
    fn projection_is_bounded_by_cap() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let stats = meow_tunnel::Statistics::new();
        // The DashMap itself is unbounded for this synthetic fixture, so the
        // module's projection must clamp to CONN_TRACK_CAP.
        let extra = 8;
        for i in 0..CONN_TRACK_CAP + extra {
            track(&stats, &format!("h{i}.example"));
        }
        let records = sync(&stats);
        assert_eq!(records.len(), CONN_TRACK_CAP);
        reset_for_tests();
    }

    #[test]
    fn close_all_clears_stats_and_projection() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        let stats = meow_tunnel::Statistics::new();
        track(&stats, "a.example");
        track(&stats, "b.example");
        assert_eq!(sync(&stats).len(), 2);

        let closed = stats.close_all_connections_counted();
        assert_eq!(closed, 2);
        store().lock().unwrap_or_else(|e| e.into_inner()).map.clear();
        assert!(sync(&stats).is_empty());
        reset_for_tests();
    }

    /// Todo 15: projection transitions become structured connection log records.
    #[test]
    fn sync_emits_connection_open_and_close_logs() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::logging::reset_for_tests();
        crate::logging::set_level(crate::logging::LogLevel::Debug);
        reset_for_tests();
        let stats = meow_tunnel::Statistics::new();
        let id = track(&stats, "logged.example");

        let _ = sync(&stats);
        stats.close_connection(id);
        let _ = sync(&stats);

        let snap = crate::logging::snapshot(0, 100, None);
        let conns: Vec<_> = snap
            .records
            .iter()
            .filter(|r| r.kind == "connection")
            .collect();
        assert_eq!(conns.len(), 2, "open + close recorded: {snap:?}");
        assert!(conns.iter().any(|r| {
            r.message.contains("open")
                && r.connection
                    .as_ref()
                    .map(|c| c.domain == "logged.example" && c.direction == "in")
                    .unwrap_or(false)
        }));
        assert!(conns.iter().any(|r| r.message.contains("close")));

        crate::logging::reset_for_tests();
        reset_for_tests();
    }
}
