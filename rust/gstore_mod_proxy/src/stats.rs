//! Per-domain statistics + aggregate traffic (Todo 16).
//!
//! The dispatch path already feeds meow's live `Statistics::connections` table
//! (Todo 10); [`crate::conn`] projects it into a bounded connection list. This
//! module consumes the **same projection diff** and folds it into a per-domain
//! aggregate: connection count, up/down bytes, last-seen, matched rule and
//! outbound.
//!
//! ## Why pull + throttled snapshots
//!
//! There are **two independent channels**: the host task-stream ring holds
//! `EVENT_BUFFER_CAP = 128` (`rust/gstore_host/src/task_bridge.rs:65`) while the
//! module event ring holds `EVENT_BUFFER_CAP = 100`
//! (`rust/gstore_host/src/event_bridge.rs:21`), so per-connection events would
//! overflow the event lane instantly. Instead:
//!  * `stats.domain.get` / `stats.traffic.get` are the **primary, pull-based**
//!    paths, and
//!  * a single `proxy.stats` snapshot is emitted at most once per
//!    [`MIN_EMIT_INTERVAL_MS`], driven by the dispatch monitor ([`crate::dispatch`]).
//!
//! ## Bounds & determinism
//!
//! * At most [`DOMAIN_CAP`] distinct domains are retained in memory. When the
//!   cap is exceeded the entry with the **oldest `lastSeenMs`** is evicted;
//!   ties are broken **lexicographically by domain** (ascending) so eviction is
//!   fully deterministic. Every eviction is logged (warn).
//! * Per-live-flow byte deltas are tracked by [`FlowObs`], bounded by the
//!   connection projection cap, so byte accounting is O(flows) per tick.
//! * Persistence is a batched SQLite upsert on a ticker ([`PERSIST_INTERVAL_MS`]),
//!   never a per-packet write, with a rolling [`RETENTION_MS`] window.
//!
//! ## Domain availability
//!
//! A "domain" is unavailable for ECH/ESNI/QUIC-without-SNI and plain-IP flows
//! (see `API.md` §9.5). Those flows fall back to the destination IP and the
//! record is marked `domainKnown: false`. A DNS reverse mapping (fake-IP
//! allocation or the mapping ring) is consulted first; only when it misses do we
//! fall back to the raw IP.

use std::collections::HashMap;
use std::net::IpAddr;
#[cfg(not(test))]
use std::sync::{Mutex, OnceLock};

use gstore_contract::error::{ModuleError, StatusCode};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::conn::ConnRecord;

/// Hard cap on distinct domains kept in memory. Eviction is documented above.
pub(crate) const DOMAIN_CAP: usize = 2048;
/// Hard cap on per-flow byte-delta trackers. One entry exists per live flow;
/// without this cap the map grew with meow's (unbounded) live table. Over the
/// cap the flow with the oldest `lastSeenMs` is evicted (ties by id ascending),
/// which only loses that flow's exact delta accounting — the aggregate keeps
/// working (graceful degradation under connection pressure).
pub(crate) const FLOW_CAP: usize = 2048;
/// Minimum spacing between `proxy.stats` events: two independent channels exist
/// (host task-stream ring 128 — `task_bridge.rs:65`; module event ring 100 —
/// `event_bridge.rs:21`), so the event lane is throttled.
pub(crate) const MIN_EMIT_INTERVAL_MS: u64 = 1000;
/// Dispatch monitor tick. Aggregation runs every tick; emission is throttled.
#[cfg_attr(test, allow(dead_code))]
pub(crate) const STATS_TICK_MS: u64 = 500;
/// SQLite flush spacing. Reads happen every tick, writes at most this often.
pub(crate) const PERSIST_INTERVAL_MS: u64 = 5000;
/// Rolling persistence window; rows older than this are pruned on flush.
pub(crate) const RETENTION_MS: u64 = 24 * 60 * 60 * 1000;
/// Domains carried in each throttled `proxy.stats` snapshot.
pub(crate) const TOP_DOMAINS: usize = 5;
/// Default page size for `stats.domain.get`.
pub(crate) const DEFAULT_DOMAIN_LIMIT: usize = 100;

/// Domain error code for an unknown `stats.domain.get` sort key.
pub(crate) const ERR_STATS_SORT_INVALID: &str = "PROXY_STATS_SORT_INVALID";

/// One aggregated per-domain record.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DomainStat {
    pub domain: String,
    /// `false` when the domain was unavailable (plain IP / ECH / no SNI); the
    /// `domain` field then holds the destination IP.
    pub domain_known: bool,
    pub connections: u64,
    pub upload_bytes: i64,
    pub download_bytes: i64,
    pub last_seen_ms: u64,
    pub rule: String,
    pub rule_payload: String,
    pub outbound: String,
}

/// Last byte counters observed for one live flow, for delta accumulation.
struct FlowObs {
    key: String,
    upload: i64,
    download: i64,
    last_seen_ms: u64,
}

struct StatsStore {
    domains: HashMap<String, DomainStat>,
    flows: HashMap<String, FlowObs>,
    cap: usize,
    flow_cap: usize,
    evicted: u64,
    evicted_flows: u64,
    active: usize,
    total_up: i64,
    total_down: i64,
    up_bps: i64,
    down_bps: i64,
    last_emit_ms: u64,
    last_emit_up: i64,
    last_emit_down: i64,
    db: Option<Persist>,
    dirty: bool,
    last_persist_ms: u64,
}

impl StatsStore {
    fn fresh() -> Self {
        Self {
            domains: HashMap::new(),
            flows: HashMap::new(),
            cap: DOMAIN_CAP,
            flow_cap: FLOW_CAP,
            evicted: 0,
            evicted_flows: 0,
            active: 0,
            total_up: 0,
            total_down: 0,
            up_bps: 0,
            down_bps: 0,
            last_emit_ms: 0,
            last_emit_up: 0,
            last_emit_down: 0,
            db: None,
            dirty: false,
            last_persist_ms: 0,
        }
    }
}

#[cfg(not(test))]
static STORE: OnceLock<Mutex<StatsStore>> = OnceLock::new();

#[cfg(not(test))]
fn with_store<R>(f: impl FnOnce(&mut StatsStore) -> R) -> R {
    let mut guard = STORE
        .get_or_init(|| Mutex::new(StatsStore::fresh()))
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    f(&mut guard)
}

#[cfg(test)]
thread_local! {
    static TEST_STORE: std::cell::RefCell<StatsStore> = std::cell::RefCell::new(StatsStore::fresh());
}

/// Tests use a per-thread store so Stats-only tests never race the process-global
/// connection projection or log ring (see the Todo 15 flaky-suite note).
#[cfg(test)]
fn with_store<R>(f: impl FnOnce(&mut StatsStore) -> R) -> R {
    TEST_STORE.with(|s| f(&mut s.borrow_mut()))
}

/// Durable aggregate storage: WAL + batched upserts + rolling window.
struct Persist {
    conn: rusqlite::Connection,
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
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             CREATE TABLE IF NOT EXISTS domain_stats (
               domain TEXT PRIMARY KEY,
               domain_known INTEGER NOT NULL,
               connections INTEGER NOT NULL,
               upload_bytes INTEGER NOT NULL,
               download_bytes INTEGER NOT NULL,
               last_seen_ms INTEGER NOT NULL,
               rule TEXT NOT NULL,
               rule_payload TEXT NOT NULL,
               outbound TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS traffic_totals (
               id INTEGER PRIMARY KEY CHECK (id = 1),
               upload_bytes INTEGER NOT NULL,
               download_bytes INTEGER NOT NULL
             );",
        )?;
        Ok(Self { conn })
    }

    /// Upsert every known domain and the running totals in one transaction,
    /// then prune rows outside the rolling window. Returns rows pruned.
    fn flush(
        &mut self,
        rows: &[DomainStat],
        total_up: i64,
        total_down: i64,
        now: u64,
    ) -> rusqlite::Result<usize> {
        let cutoff = now.saturating_sub(RETENTION_MS) as i64;
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO domain_stats
                   (domain, domain_known, connections, upload_bytes, download_bytes,
                    last_seen_ms, rule, rule_payload, outbound)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(domain) DO UPDATE SET
                   domain_known=excluded.domain_known,
                   connections=excluded.connections,
                   upload_bytes=excluded.upload_bytes,
                   download_bytes=excluded.download_bytes,
                   last_seen_ms=excluded.last_seen_ms,
                   rule=excluded.rule,
                   rule_payload=excluded.rule_payload,
                   outbound=excluded.outbound",
            )?;
            for d in rows {
                stmt.execute(params![
                    d.domain,
                    d.domain_known,
                    d.connections as i64,
                    d.upload_bytes,
                    d.download_bytes,
                    d.last_seen_ms as i64,
                    d.rule,
                    d.rule_payload,
                    d.outbound,
                ])?;
            }
        }
        let pruned = tx.execute(
            "DELETE FROM domain_stats WHERE last_seen_ms < ?1",
            params![cutoff],
        )?;
        tx.execute(
            "INSERT INTO traffic_totals (id, upload_bytes, download_bytes) VALUES (1, ?1, ?2)
             ON CONFLICT(id) DO UPDATE SET
               upload_bytes=excluded.upload_bytes,
               download_bytes=excluded.download_bytes",
            params![total_up, total_down],
        )?;
        tx.commit()?;
        Ok(pruned)
    }

    /// Load aggregates still inside the rolling window, plus the saved totals.
    fn seed(&self, now: u64) -> rusqlite::Result<(Vec<DomainStat>, (i64, i64))> {
        let cutoff = now.saturating_sub(RETENTION_MS) as i64;
        let mut stmt = self.conn.prepare(
            "SELECT domain, domain_known, connections, upload_bytes, download_bytes,
                    last_seen_ms, rule, rule_payload, outbound
             FROM domain_stats WHERE last_seen_ms >= ?1",
        )?;
        let rows = stmt
            .query_map(params![cutoff], |row| {
                Ok(DomainStat {
                    domain: row.get(0)?,
                    domain_known: row.get::<_, i64>(1)? != 0,
                    connections: row.get::<_, i64>(2)?.max(0) as u64,
                    upload_bytes: row.get(3)?,
                    download_bytes: row.get(4)?,
                    last_seen_ms: row.get::<_, i64>(5)?.max(0) as u64,
                    rule: row.get(6)?,
                    rule_payload: row.get(7)?,
                    outbound: row.get(8)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let totals = self
            .conn
            .query_row(
                "SELECT upload_bytes, download_bytes FROM traffic_totals WHERE id = 1",
                [],
                |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)),
            )
            .optional()?
            .unwrap_or((0, 0));
        Ok((rows, totals))
    }

    fn clear(&self) -> rusqlite::Result<()> {
        self.conn
            .execute_batch("DELETE FROM domain_stats; DELETE FROM traffic_totals;")
    }
}

/// Check whether enough time has passed to emit another `proxy.stats` snapshot.
pub(crate) fn should_emit(now_ms: u64, last_emit_ms: u64) -> bool {
    now_ms.saturating_sub(last_emit_ms) >= MIN_EMIT_INTERVAL_MS
}

/// Resolve the statistics key for a flow.
///
/// Prefers the sniffed/rule host; treats an IP-shaped host as unknown and tries
/// a DNS reverse mapping; finally falls back to the destination IP with
/// `domainKnown=false`.
///
/// Shared with [`crate::requests`] so a flow's `stats` aggregate and its
/// `RequestRecord` are attributed identically (Todo 4).
pub(crate) fn resolve_domain(r: &ConnRecord) -> (String, bool) {
    let raw = r.domain.trim();
    if let Ok(ip) = raw.parse::<IpAddr>() {
        return reverse_or_ip(ip);
    }
    if !raw.is_empty() {
        return (raw.to_string(), true);
    }
    match dst_ip(&r.dst) {
        Some(ip) => reverse_or_ip(ip),
        None => (r.dst.clone(), false),
    }
}

fn reverse_or_ip(ip: IpAddr) -> (String, bool) {
    if let Some(engine) = crate::dns::engine() {
        if let Some(m) = engine.domain_for_ip(ip) {
            return (m.domain, m.domain_known);
        }
    }
    (ip.to_string(), false)
}

/// Extract the IP from a `host:port` / `[v6]:port` destination string.
fn dst_ip(dst: &str) -> Option<IpAddr> {
    let trimmed = dst.trim();
    if let Ok(ip) = trimmed.parse::<IpAddr>() {
        return Some(ip);
    }
    if trimmed.starts_with('[') {
        let end = trimmed.find(']')?;
        return trimmed[1..end].parse().ok();
    }
    let (host, _port) = trimmed.rsplit_once(':')?;
    host.parse().ok()
}

fn new_domain(key: &str, known: bool, r: &ConnRecord, now: u64) -> DomainStat {
    DomainStat {
        domain: key.to_string(),
        domain_known: known,
        connections: 0,
        upload_bytes: 0,
        download_bytes: 0,
        last_seen_ms: now,
        rule: r.rule.clone(),
        rule_payload: r.rule_payload.clone(),
        outbound: r.outbound.clone(),
    }
}

fn add_bytes(st: &mut StatsStore, key: &str, known: bool, up: i64, down: i64, r: &ConnRecord, now: u64) {
    let entry = st
        .domains
        .entry(key.to_string())
        .or_insert_with(|| new_domain(key, known, r, now));
    entry.upload_bytes += up;
    entry.download_bytes += down;
    entry.last_seen_ms = now;
    entry.rule = r.rule.clone();
    entry.rule_payload = r.rule_payload.clone();
    entry.outbound = r.outbound.clone();
    st.total_up += up;
    st.total_down += down;
    st.dirty = true;
}

/// Fold the current projection diff into the per-domain aggregate.
fn observe_into(
    st: &mut StatsStore,
    live: &[ConnRecord],
    closed: &[ConnRecord],
    now: u64,
) -> (Vec<String>, u64) {
    let mut evicted = Vec::new();
    for r in live {
        let (key, known) = resolve_domain(r);
        let observed = st.flows.get(&r.id).map(|o| (o.upload, o.download));
        match observed {
            Some((up, down)) => {
                let du = (r.upload_bytes - up).max(0);
                let dd = (r.download_bytes - down).max(0);
                if du > 0 || dd > 0 {
                    add_bytes(st, &key, known, du, dd, r, now);
                }
                if let Some(obs) = st.flows.get_mut(&r.id) {
                    obs.upload = r.upload_bytes;
                    obs.download = r.download_bytes;
                    obs.key = key;
                    obs.last_seen_ms = now;
                }
            }
            None => {
                if st.domains.contains_key(&key) {
                    if let Some(d) = st.domains.get_mut(&key) {
                        d.connections += 1;
                    }
                    add_bytes(st, &key, known, r.upload_bytes, r.download_bytes, r, now);
                } else {
                    let mut d = new_domain(&key, known, r, now);
                    d.connections = 1;
                    d.upload_bytes = r.upload_bytes;
                    d.download_bytes = r.download_bytes;
                    st.total_up += r.upload_bytes;
                    st.total_down += r.download_bytes;
                    st.dirty = true;
                    st.domains.insert(key.clone(), d);
                }
                st.flows.insert(
                    r.id.clone(),
                    FlowObs {
                        key,
                        upload: r.upload_bytes,
                        download: r.download_bytes,
                        last_seen_ms: now,
                    },
                );
            }
        }
    }
    for r in closed {
        if let Some(obs) = st.flows.remove(&r.id) {
            let du = (r.upload_bytes - obs.upload).max(0);
            let dd = (r.download_bytes - obs.download).max(0);
            if du > 0 || dd > 0 {
                add_bytes(st, &obs.key, true, du, dd, r, now);
            }
        }
    }
    st.active = live.len();
    while st.domains.len() > st.cap {
        let victim = st
            .domains
            .iter()
            .min_by(|a, b| {
                a.1.last_seen_ms
                    .cmp(&b.1.last_seen_ms)
                    .then_with(|| a.0.cmp(b.0))
            })
            .map(|(k, _)| k.clone());
        match victim {
            Some(k) => {
                st.domains.remove(&k);
                st.evicted += 1;
                evicted.push(k);
            }
            None => break,
        }
    }
    let flow_cap = st.flow_cap;
    let mut flow_evicted = 0u64;
    if st.flows.len() > flow_cap {
        // Evict down to half the cap so a sustained excess does not re-sort the
        // whole map on every tick (amortized O(1) per insert). Oldest
        // `lastSeenMs` first, ties by id ascending: deterministic.
        let target = flow_cap / 2;
        let mut victims: Vec<(u64, String)> = st
            .flows
            .iter()
            .map(|(id, obs)| (obs.last_seen_ms, id.clone()))
            .collect();
        victims.sort_unstable_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
        let excess = st.flows.len() - target;
        for (_, id) in victims.into_iter().take(excess) {
            if st.flows.remove(&id).is_some() {
                st.evicted_flows += 1;
                flow_evicted += 1;
            }
        }
    }
    (evicted, flow_evicted)
}

fn observe(live: &[ConnRecord], closed: &[ConnRecord], now: u64) {
    let (evicted, flow_evicted) = with_store(|st| observe_into(st, live, closed, now));
    for victim in &evicted {
        crate::log_message(
            2,
            &format!("proxy.stats: evicted domain '{victim}' (capacity {DOMAIN_CAP})"),
        );
    }
    if flow_evicted > 0 {
        crate::log_message(
            2,
            &format!("proxy.stats: evicted {flow_evicted} flow tracker(s) (capacity {FLOW_CAP})"),
        );
    }
}

/// One dispatch-monitor tick: project meow's live table, fold it into the
/// per-domain aggregate, then emit a throttled `proxy.stats` snapshot.
pub(crate) fn tick(stats: &meow_tunnel::Statistics, instance_id: u64, now: u64) {
    let outcome = crate::conn::sync_full(stats);
    observe(&outcome.live, &outcome.closed, now);
    maybe_emit(instance_id, now);
}

fn maybe_emit(instance_id: u64, now: u64) {
    let payload = with_store(|st| {
        if !should_emit(now, st.last_emit_ms) {
            return None;
        }
        let elapsed = now.saturating_sub(st.last_emit_ms).max(1);
        st.up_bps = (st.total_up - st.last_emit_up).max(0) * 1000 / elapsed as i64;
        st.down_bps = (st.total_down - st.last_emit_down).max(0) * 1000 / elapsed as i64;
        st.last_emit_ms = now;
        st.last_emit_up = st.total_up;
        st.last_emit_down = st.total_down;
        let mut top: Vec<DomainStat> = st.domains.values().cloned().collect();
        sort_domains(&mut top, SortKind::Bytes);
        top.truncate(TOP_DOMAINS);
        Some(serde_json::json!({
            "uploadBytes": st.total_up,
            "downloadBytes": st.total_down,
            "activeConns": st.active,
            "upBps": st.up_bps,
            "downBps": st.down_bps,
            "domainCount": st.domains.len(),
            "capacity": st.cap,
            "flowCount": st.flows.len(),
            "flowCapacity": st.flow_cap,
            "evictedFlows": st.evicted_flows,
            "topDomains": top,
        }))
    });
    if let Some(value) = payload {
        if let Ok(bytes) = serde_json::to_vec(&value) {
            crate::emit_event(instance_id, crate::EVT_STATS, &bytes);
        }
    }
}

/// Configure the optional SQLite sink and seed memory from the rolling window.
pub(crate) fn configure(data_dir: &str) {
    let dir = data_dir.trim();
    if dir.is_empty() {
        return;
    }
    let path = format!("{}/proxy_stats.db", dir.trim_end_matches('/'));
    with_store(|st| match Persist::open(&path) {
        Ok(persist) => {
            let now = crate::now_ms();
            match persist.seed(now) {
                Ok((rows, (up, down))) => {
                    st.domains.clear();
                    for d in rows {
                        st.domains.insert(d.domain.clone(), d);
                    }
                    st.total_up = up;
                    st.total_down = down;
                    st.last_emit_up = up;
                    st.last_emit_down = down;
                }
                Err(e) => crate::log_message(2, &format!("proxy.stats: seed {path} failed: {e}")),
            }
            evict_now(st);
            st.db = Some(persist);
            crate::log_message(1, &format!("proxy.stats: persistence enabled at {path}"));
        }
        Err(e) => crate::log_message(2, &format!("proxy.stats: open {path} failed: {e}")),
    });
}

fn evict_now(st: &mut StatsStore) {
    while st.domains.len() > st.cap {
        let victim = st
            .domains
            .iter()
            .min_by(|a, b| {
                a.1.last_seen_ms
                    .cmp(&b.1.last_seen_ms)
                    .then_with(|| a.0.cmp(b.0))
            })
            .map(|(k, _)| k.clone());
        match victim {
            Some(k) => {
                st.domains.remove(&k);
                st.evicted += 1;
            }
            None => break,
        }
    }
}

/// Flush the aggregate to SQLite when the persist interval has elapsed.
/// Returns the number of pruned rows. Never called per packet.
pub(crate) fn maybe_persist(now: u64) -> usize {
    with_store(|st| {
        if st.db.is_none() || !st.dirty {
            return 0;
        }
        if st.last_persist_ms != 0 && now.saturating_sub(st.last_persist_ms) < PERSIST_INTERVAL_MS {
            return 0;
        }
        st.last_persist_ms = now;
        st.dirty = false;
        let rows: Vec<DomainStat> = st.domains.values().cloned().collect();
        let (up, down) = (st.total_up, st.total_down);
        let result = match st.db.as_mut() {
            Some(db) => db.flush(&rows, up, down, now),
            None => return 0,
        };
        match result {
            Ok(pruned) => pruned,
            Err(e) => {
                st.dirty = true;
                crate::log_message(2, &format!("proxy.stats: flush failed: {e}"));
                0
            }
        }
    })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SortKind {
    Bytes,
    Connections,
    LastSeen,
    Domain,
}

impl SortKind {
    fn parse(raw: Option<&str>) -> Result<Self, ModuleError> {
        match raw.map(str::trim).filter(|s| !s.is_empty()) {
            None | Some("bytes") => Ok(SortKind::Bytes),
            Some("connections") => Ok(SortKind::Connections),
            Some("lastSeen") | Some("last-seen") | Some("lastSeenMs") => Ok(SortKind::LastSeen),
            Some("domain") | Some("name") => Ok(SortKind::Domain),
            Some(other) => Err(ModuleError::new(
                StatusCode::InvalidArgument,
                ERR_STATS_SORT_INVALID,
                format!(
                    "unknown stats.domain.get sort '{other}' (expected bytes|connections|lastSeen|domain)"
                ),
            )),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            SortKind::Bytes => "bytes",
            SortKind::Connections => "connections",
            SortKind::LastSeen => "lastSeen",
            SortKind::Domain => "domain",
        }
    }
}

fn sort_domains(rows: &mut [DomainStat], sort: SortKind) {
    match sort {
        SortKind::Bytes => rows.sort_by(|a, b| {
            (b.upload_bytes + b.download_bytes)
                .cmp(&(a.upload_bytes + a.download_bytes))
                .then_with(|| b.connections.cmp(&a.connections))
                .then_with(|| a.domain.cmp(&b.domain))
        }),
        SortKind::Connections => rows.sort_by(|a, b| {
            b.connections
                .cmp(&a.connections)
                .then_with(|| (b.upload_bytes + b.download_bytes).cmp(&(a.upload_bytes + a.download_bytes)))
                .then_with(|| a.domain.cmp(&b.domain))
        }),
        SortKind::LastSeen => rows.sort_by(|a, b| {
            b.last_seen_ms
                .cmp(&a.last_seen_ms)
                .then_with(|| a.domain.cmp(&b.domain))
        }),
        SortKind::Domain => rows.sort_by(|a, b| a.domain.cmp(&b.domain)),
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DomainGetRequest {
    #[serde(default)]
    pub range_ms: Option<u64>,
    #[serde(default)]
    pub sort: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
}

pub(crate) fn domain_get_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let req: DomainGetRequest = if payload.is_empty() {
        DomainGetRequest::default()
    } else {
        serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!("stats.domain.get payload must be a JSON object: {e}"))
        })?
    };
    let sort = SortKind::parse(req.sort.as_deref())?;
    let range = req.range_ms.unwrap_or(0);
    let limit = req.limit.unwrap_or(DEFAULT_DOMAIN_LIMIT).min(DOMAIN_CAP);
    let now = crate::now_ms();
    let (mut rows, evicted, cap) = with_store(|st| {
        let rows: Vec<DomainStat> = st
            .domains
            .values()
            .filter(|d| range == 0 || d.last_seen_ms.saturating_add(range) >= now)
            .cloned()
            .collect();
        (rows, st.evicted, st.cap)
    });
    sort_domains(&mut rows, sort);
    let count = rows.len();
    rows.truncate(limit);
    crate::ok_data(serde_json::json!({
        "domains": rows,
        "count": count,
        "returned": rows.len(),
        "capacity": cap,
        "evicted": evicted,
        "rangeMs": range,
        "sort": sort.as_str(),
        "domainCap": DOMAIN_CAP,
        "flowCap": FLOW_CAP,
    }))
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TrafficGetRequest {
    #[serde(default)]
    pub top_domains: Option<usize>,
}

impl TrafficGetRequest {
    fn parse(payload: &[u8]) -> Result<Self, ModuleError> {
        if payload.is_empty() {
            return Ok(Self::default());
        }
        serde_json::from_slice(payload).map_err(|e| {
            ModuleError::invalid_arg(format!(
                "stats.traffic.get payload must be a JSON object: {e}"
            ))
        })
    }

    fn top_limit(&self) -> usize {
        self.top_domains.unwrap_or(TOP_DOMAINS).min(DOMAIN_CAP)
    }
}

pub(crate) fn traffic_get_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
    let req = TrafficGetRequest::parse(payload)?;
    let (mut top, up, down, active, up_bps, down_bps, count, cap, evicted, flow_count, flow_cap, evicted_flows) =
        with_store(|st| {
            (
                st.domains.values().cloned().collect::<Vec<_>>(),
                st.total_up,
                st.total_down,
                st.active,
                st.up_bps,
                st.down_bps,
                st.domains.len(),
                st.cap,
                st.evicted,
                st.flows.len(),
                st.flow_cap,
                st.evicted_flows,
            )
        });
    sort_domains(&mut top, SortKind::Bytes);
    top.truncate(req.top_limit());
    crate::ok_data(serde_json::json!({
        "uploadBytes": up,
        "downloadBytes": down,
        "activeConns": active,
        "upBps": up_bps,
        "downBps": down_bps,
        "domainCount": count,
        "capacity": cap,
        "evicted": evicted,
        "flowCount": flow_count,
        "flowCapacity": flow_cap,
        "evictedFlows": evicted_flows,
        "topDomains": top,
    }))
}

pub(crate) fn reset_arm() -> Result<Vec<u8>, ModuleError> {
    let cleared = with_store(|st| {
        let cleared = st.domains.len();
        st.domains.clear();
        st.flows.clear();
        st.total_up = 0;
        st.total_down = 0;
        st.active = 0;
        st.up_bps = 0;
        st.down_bps = 0;
        st.evicted = 0;
        st.evicted_flows = 0;
        st.last_emit_up = 0;
        st.last_emit_down = 0;
        st.dirty = false;
        if let Some(db) = &st.db {
            if let Err(e) = db.clear() {
                crate::log_message(2, &format!("proxy.stats: reset persistence failed: {e}"));
            }
        }
        cleared
    });
    crate::log_message(1, &format!("proxy: stats.domain.reset cleared={cleared}"));
    crate::ok_data(serde_json::json!({ "ok": true, "cleared": cleared }))
}

#[cfg(test)]
pub(crate) fn reset_for_tests() {
    with_store(|st| *st = StatsStore::fresh());
}

#[cfg(test)]
pub(crate) fn set_cap_for_tests(cap: usize) {
    with_store(|st| st.cap = cap);
}

#[cfg(test)]
pub(crate) fn set_flow_cap_for_tests(cap: usize) {
    with_store(|st| st.flow_cap = cap);
}

#[cfg(test)]
pub(crate) fn flow_stats_for_tests() -> (usize, usize, u64) {
    with_store(|st| (st.flows.len(), st.flow_cap, st.evicted_flows))
}

#[cfg(test)]
pub(crate) fn last_emit_for_tests() -> u64 {
    with_store(|st| st.last_emit_ms)
}

#[cfg(test)]
pub(crate) fn observe_for_tests(live: &[ConnRecord], closed: &[ConnRecord], now: u64) {
    observe(live, closed, now);
}

#[cfg(test)]
pub(crate) fn maybe_emit_for_tests(instance_id: u64, now: u64) {
    maybe_emit(instance_id, now);
}

#[cfg(test)]
pub(crate) fn flush_for_tests(now: u64) -> usize {
    maybe_persist(now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TEST_SERIAL as SERIAL;

    fn rec(id: &str, domain: &str, up: i64, down: i64) -> ConnRecord {
        ConnRecord {
            id: id.into(),
            src: "10.10.0.2:40000".into(),
            dst: "1.2.3.4:443".into(),
            dst_ip: "1.2.3.4".into(),
            dst_port: 443,
            domain: domain.into(),
            network: "tcp".into(),
            rule: "DOMAIN-SUFFIX".into(),
            rule_payload: domain.into(),
            outbound: "proxy-a".into(),
            started_at_ms: 1_700_000_000_000,
            upload_bytes: up,
            download_bytes: down,
        }
    }

    /// Happy QA: two domains accumulate counts/bytes across flows and a running
    /// flow's growth is captured by the periodic delta.
    #[test]
    fn accumulation_across_flows_and_periodic_deltas() {
        reset_for_tests();
        observe_for_tests(&[rec("1", "a.example", 10, 20)], &[], 1_000);
        observe_for_tests(
            &[rec("1", "a.example", 30, 50), rec("2", "b.example", 5, 0)],
            &[],
            2_000,
        );
        let (rows, up, down, active) = with_store(|st| {
            (
                st.domains.values().cloned().collect::<Vec<_>>(),
                st.total_up,
                st.total_down,
                st.active,
            )
        });
        assert_eq!(active, 2);
        assert_eq!(up, 35);
        assert_eq!(down, 50);
        let a = rows.iter().find(|d| d.domain == "a.example").unwrap();
        assert_eq!(a.connections, 1);
        assert_eq!((a.upload_bytes, a.download_bytes), (30, 50));
        assert_eq!(a.last_seen_ms, 2_000);
        let b = rows.iter().find(|d| d.domain == "b.example").unwrap();
        assert_eq!(b.connections, 1);
        assert_eq!((b.upload_bytes, b.download_bytes), (5, 0));

        let data = traffic_get_arm(b"").unwrap();
        let json: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(json["data"]["domainCount"], 2);
        assert_eq!(
            json["data"]["topDomains"][0]["domain"], "a.example",
            "top domains ordered by total bytes"
        );

        observe_for_tests(&[], &[rec("1", "a.example", 30, 50)], 3_000);
        let after_close = with_store(|st| {
            (
                st.domains.get("a.example").map(|d| d.upload_bytes),
                st.active,
            )
        });
        assert_eq!(after_close.0, Some(30), "close does not double-count bytes");
        assert_eq!(after_close.1, 0);
    }

    /// A second flow to the same domain increments `connections`.
    #[test]
    fn repeated_flows_increment_connection_count() {
        reset_for_tests();
        observe_for_tests(&[rec("1", "a.example", 0, 0)], &[], 10);
        observe_for_tests(
            &[rec("1", "a.example", 1, 1), rec("2", "a.example", 0, 0)],
            &[],
            20,
        );
        let count = with_store(|st| st.domains.get("a.example").map(|d| d.connections));
        assert_eq!(count, Some(2));
    }

    /// Failure QA: opening more than the cap keeps memory bounded, evicts the
    /// oldest `lastSeenMs` deterministically, and counts the eviction.
    #[test]
    fn eviction_at_cap_is_deterministic_and_logged() {
        reset_for_tests();
        set_cap_for_tests(2);
        observe_for_tests(&[rec("1", "old.example", 1, 0)], &[], 100);
        observe_for_tests(&[rec("2", "mid.example", 1, 0)], &[], 200);
        observe_for_tests(&[rec("3", "new.example", 1, 0)], &[], 300);
        let (keys, evicted) = with_store(|st| {
            let mut k: Vec<String> = st.domains.keys().cloned().collect();
            k.sort();
            (k, st.evicted)
        });
        assert_eq!(keys, vec!["mid.example", "new.example"]);
        assert_eq!(evicted, 1, "oldest last-seen evicted exactly once");
        let snap = crate::logging::snapshot(0, 200, None);
        assert!(
            snap.records
                .iter()
                .any(|r| r.message.contains("evicted domain 'old.example'")),
            "eviction must be logged: {:?}",
            snap.records.iter().map(|r| &r.message).collect::<Vec<_>>()
        );

        // Deterministic tie-break: equal last-seen evicts the lexicographically
        // smallest domain first.
        reset_for_tests();
        set_cap_for_tests(1);
        observe_for_tests(&[rec("1", "b.example", 1, 0)], &[], 500);
        observe_for_tests(&[rec("1", "b.example", 2, 0), rec("2", "a.example", 0, 0)], &[], 500);
        let remaining = with_store(|st| st.domains.keys().cloned().collect::<Vec<_>>());
        assert_eq!(remaining, vec!["b.example"], "tie broken by domain asc");
    }

    /// `stats.domain.reset` clears aggregates, totals, active count and evictions.
    #[test]
    fn reset_clears_aggregate() {
        reset_for_tests();
        observe_for_tests(&[rec("1", "a.example", 7, 9)], &[], 100);
        assert!(with_store(|st| !st.domains.is_empty()));
        let data = reset_arm().unwrap();
        let json: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(json["data"]["cleared"], 1);
        let (len, up, active, evicted) = with_store(|st| {
            (st.domains.len(), st.total_up, st.active, st.evicted)
        });
        assert_eq!((len, up, active, evicted), (0, 0, 0, 0));
    }

    /// The event throttle is a hard interval bound (>= 1000 ms).
    #[test]
    fn event_throttle_interval_bound() {
        assert!(!should_emit(0, 0), "no emit before the interval");
        assert!(!should_emit(999, 0));
        assert!(should_emit(1000, 0));
        assert!(!should_emit(1999, 1000));
        assert!(should_emit(2000, 1000));

        reset_for_tests();
        observe_for_tests(&[rec("1", "a.example", 1, 1)], &[], 10_000);
        maybe_emit_for_tests(7, 10_000);
        assert_eq!(last_emit_for_tests(), 10_000);
        maybe_emit_for_tests(7, 10_500);
        assert_eq!(last_emit_for_tests(), 10_000, "second tick within 1s suppressed");
        maybe_emit_for_tests(7, 11_000);
        assert_eq!(last_emit_for_tests(), 11_000, "emit resumes at the interval");
    }

    /// Plain-IP flows are recorded under the IP with `domainKnown:false`.
    #[test]
    fn plain_ip_flow_is_marked_domain_unknown() {
        reset_for_tests();
        observe_for_tests(&[rec("1", "203.0.113.7", 1, 1)], &[], 100);
        let (key, known) = with_store(|st| {
            let d = st.domains.values().next().unwrap();
            (d.domain.clone(), d.domain_known)
        });
        assert_eq!(key, "203.0.113.7");
        assert!(!known, "plain-IP flow must be flagged domainKnown=false");
    }

    /// `stats.domain.get` sorts deterministically and rejects unknown sorts.
    #[test]
    fn domain_get_sorts_and_validates() {
        reset_for_tests();
        observe_for_tests(
            &[
                rec("1", "small.example", 1, 0),
                rec("2", "big.example", 100, 100),
            ],
            &[],
            100,
        );
        let by_bytes = domain_get_arm(b"{}").unwrap();
        let json: serde_json::Value = serde_json::from_slice(&by_bytes).unwrap();
        assert_eq!(json["data"]["domains"][0]["domain"], "big.example");
        assert_eq!(json["data"]["domains"][1]["domain"], "small.example");

        let by_name = domain_get_arm(br#"{"sort":"domain","limit":1}"#).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&by_name).unwrap();
        assert_eq!(json["data"]["domains"][0]["domain"], "big.example");
        assert_eq!(json["data"]["returned"], 1);

        let err = domain_get_arm(br#"{"sort":"bogus"}"#).unwrap_err();
        let payload: serde_json::Value = serde_json::from_slice(&err.to_payload()).unwrap();
        assert_eq!(payload["code"], ERR_STATS_SORT_INVALID);
    }

    /// `stats.traffic.get` reports live aggregates after a projection tick.
    #[test]
    fn tick_aggregates_from_meow_statistics() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_tests();
        crate::conn::reset_for_tests();
        let stats = meow_tunnel::Statistics::new();
        let id = stats.track_connection(
            fixture_metadata("tick.example"),
            smol_str::SmolStr::new("DOMAIN-SUFFIX"),
            smol_str::SmolStr::new("tick.example"),
            smallvec::SmallVec::from_vec(vec![std::sync::Arc::<str>::from("proxy-a")]),
        );
        tick(&stats, 3, 1_000);
        let counters = stats.connection_counters(id).expect("counters");
        stats.record_upload(&counters, 64);
        stats.record_download(&counters, 128);
        tick(&stats, 3, 2_000);
        let data = traffic_get_arm(b"").unwrap();
        let json: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(json["data"]["uploadBytes"], 64);
        assert_eq!(json["data"]["downloadBytes"], 128);
        assert_eq!(json["data"]["activeConns"], 1);
        assert_eq!(json["data"]["topDomains"][0]["domain"], "tick.example");
        crate::conn::reset_for_tests();
        reset_for_tests();
    }

    fn fixture_metadata(host: &str) -> meow_common::Metadata {
        meow_common::Metadata {
            network: meow_common::Network::Tcp,
            conn_type: meow_common::ConnType::Tun,
            host: host.into(),
            dst_ip: Some("1.2.3.4".parse().unwrap()),
            dst_port: 443,
            src_ip: Some("10.10.0.2".parse().unwrap()),
            src_port: 40000,
            ..Default::default()
        }
    }

    /// SQLite persistence: batched upsert, deterministic re-read, rolling-window
    /// prune, and clear.
    #[test]
    fn persistence_round_trip_and_prune() {
        let mut db = Persist::open_in_memory().unwrap();
        let now = 1_700_000_000_000u64;
        let rows = vec![
            DomainStat {
                domain: "recent.example".into(),
                domain_known: true,
                connections: 2,
                upload_bytes: 11,
                download_bytes: 22,
                last_seen_ms: now,
                rule: "DOMAIN-SUFFIX".into(),
                rule_payload: "recent.example".into(),
                outbound: "proxy-a".into(),
            },
            DomainStat {
                domain: "stale.example".into(),
                domain_known: false,
                connections: 1,
                upload_bytes: 5,
                download_bytes: 5,
                last_seen_ms: now - RETENTION_MS - 1,
                rule: "Final".into(),
                rule_payload: String::new(),
                outbound: "DIRECT".into(),
            },
        ];
        let pruned = db.flush(&rows, 16, 27, now).unwrap();
        assert_eq!(pruned, 1, "row outside the rolling window pruned");

        let (seeded, totals) = db.seed(now).unwrap();
        assert_eq!(seeded.len(), 1);
        assert_eq!(seeded[0].domain, "recent.example");
        assert_eq!((seeded[0].upload_bytes, seeded[0].download_bytes), (11, 22));
        assert_eq!(totals, (16, 27));

        db.clear().unwrap();
        let (empty, zero) = db.seed(now).unwrap();
        assert!(empty.is_empty() && zero == (0, 0));
    }

    /// Failure QA (Todo 27): more live flows than `FLOW_CAP` must stay bounded
    /// and the aggregate must keep answering (graceful degradation) instead of
    /// growing with meow's live connection table.
    #[test]
    fn flow_trackers_are_bounded_under_connection_pressure() {
        reset_for_tests();
        set_flow_cap_for_tests(64);
        set_cap_for_tests(DOMAIN_CAP);
        const FLOWS: usize = 5000;
        for i in 0..FLOWS {
            let r = rec(&format!("id{i}"), &format!("d{}.example", i % 512), 1, 1);
            observe_for_tests(std::slice::from_ref(&r), &[], 100 + i as u64);
        }
        let (flows, cap, evicted) = flow_stats_for_tests();
        assert_eq!(cap, 64);
        assert!(flows <= 64, "flow trackers must stay bounded to the cap");
        assert!(
            flows >= 32,
            "batch eviction must not empty the tracker map ({flows})"
        );
        assert_eq!(
            evicted,
            (FLOWS - flows) as u64,
            "evicted = inserted - retained"
        );

        let data = traffic_get_arm(b"").unwrap();
        let json: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(json["data"]["flowCapacity"], 64);
        assert!(
            json["data"]["domainCount"].as_u64().unwrap() > 0,
            "aggregate still reports after flow pressure"
        );
        reset_for_tests();
    }

    /// Manual local benchmark (Todo 27). Drives many live flows across more
    /// domains than `DOMAIN_CAP` and reports ingest throughput + RSS/CPU deltas.
    /// Not run by default; `bench/run.sh` drives it.
    #[test]
    #[ignore = "manual local benchmark: cargo test -p gstore_mod_proxy bench_stats -- --ignored --nocapture --test-threads=1"]
    fn bench_stats_ingest_throughput() {
        const OPS: usize = 100_000;
        const DOMAINS: usize = 4096;
        reset_for_tests();
        set_cap_for_tests(DOMAIN_CAP);
        let rss0 = crate::limits::rss_kb();
        let cpu0 = crate::limits::cpu_ms();
        let t0 = std::time::Instant::now();
        for i in 0..OPS {
            let domain = format!("d{}.example", i % DOMAINS);
            let rec = rec(&format!("id{i}"), &domain, 64, 128);
            observe_for_tests(std::slice::from_ref(&rec), &[], (i as u64) * 10 + 1);
        }
        let elapsed = t0.elapsed();
        let cpu = crate::limits::cpu_ms().saturating_sub(cpu0);
        let rss = crate::limits::rss_kb();
        let (domains, evicted, flows) =
            with_store(|st| (st.domains.len(), st.evicted, st.flows.len()));
        crate::limits::bench_line(
            "stats_ingest",
            &[
                ("ops", OPS as u128),
                ("elapsed_ms", elapsed.as_millis()),
                (
                    "ops_per_sec",
                    OPS as u128 * 1000 / elapsed.as_millis().max(1),
                ),
                ("rss_kb", rss as u128),
                ("rss_delta_kb", rss.saturating_sub(rss0) as u128),
                ("cpu_ms", cpu as u128),
                ("domains", domains as u128),
                ("domain_cap", DOMAIN_CAP as u128),
                ("evicted", evicted as u128),
                ("flows", flows as u128),
            ],
        );
        reset_for_tests();
    }

    /// `maybe_persist` no-ops without a configured db and never panics.
    #[test]
    fn persist_without_db_is_noop() {
        reset_for_tests();
        observe_for_tests(&[rec("1", "a.example", 1, 1)], &[], 100);
        assert_eq!(flush_for_tests(5_000), 0);
    }
}
