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

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use gstore_contract::error::{ModuleError, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::logging::{self, ConnectionLog, LogLevel};
use crate::nodes::ERR_NOT_CONFIGURED;

/// Hard cap on the projected connection list. Mirrors the host's 100-entry
/// event ring philosophy scaled for a live connection table.
pub(crate) const CONN_TRACK_CAP: usize = 1024;

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
}

static CONN_STORE: OnceLock<Mutex<ConnStore>> = OnceLock::new();

fn store() -> &'static Mutex<ConnStore> {
    CONN_STORE.get_or_init(|| {
        Mutex::new(ConnStore {
            map: HashMap::new(),
        })
    })
}

#[cfg(test)]
pub(crate) fn reset_for_tests() {
    store().lock().unwrap_or_else(|e| e.into_inner()).map.clear();
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
        let mut out: Vec<ConnRecord> = store.map.values().cloned().collect();
        out.sort_by(|a, b| b.started_at_ms.cmp(&a.started_at_ms));
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

pub(crate) fn list_arm() -> Result<Vec<u8>, ModuleError> {
    let tunnel = active_tunnel()?;
    let records = sync(tunnel.statistics().as_ref());
    let count = records.len();
    crate::ok_data(json!({
        "connections": records,
        "count": count,
        "capacity": CONN_TRACK_CAP,
    }))
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct CloseRequest {
    id: String,
}

pub(crate) fn close_arm(payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
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
    let existed = stats.connection_counters(id).is_some();
    let record = store()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .map
        .get(&req.id)
        .cloned();
    stats.close_connection(id);
    store()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .map
        .remove(&req.id);
    if let Some(r) = record {
        let duration = crate::now_ms().saturating_sub(r.started_at_ms);
        logging::record_connection(
            LogLevel::Info,
            connection_log(&r, "in", duration, None),
            "close",
        );
    }
    crate::log_message(1, &format!("proxy: conn.close id={} existed={existed}", req.id));
    crate::ok_data(json!({ "ok": true, "id": req.id, "closed": existed }))
}

pub(crate) fn close_all_arm() -> Result<Vec<u8>, ModuleError> {
    let tunnel = active_tunnel()?;
    let records: Vec<ConnRecord> = store()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .map
        .values()
        .cloned()
        .collect();
    let closed = tunnel.statistics().close_all_connections_counted();
    store().lock().unwrap_or_else(|e| e.into_inner()).map.clear();
    let now = crate::now_ms();
    for r in &records {
        let duration = now.saturating_sub(r.started_at_ms);
        logging::record_connection(
            LogLevel::Info,
            connection_log(r, "in", duration, None),
            "close",
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
        stats.track_connection(
            fixture_metadata(host, "1.2.3.4", "10.10.0.2"),
            SmolStr::new("DOMAIN-SUFFIX"),
            SmolStr::new(host),
            SmallVec::from_vec(vec![Arc::<str>::from("proxy-a")]),
        )
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
