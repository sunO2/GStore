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

/// Rebuild the bounded projection from meow's live connection table and return
/// the records, newest first.
pub(crate) fn sync(stats: &meow_tunnel::Statistics) -> Vec<ConnRecord> {
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
    store.map = next;
    let mut out: Vec<ConnRecord> = store.map.values().cloned().collect();
    out.sort_by(|a, b| b.started_at_ms.cmp(&a.started_at_ms));
    out
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
    stats.close_connection(id);
    store()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .map
        .remove(&req.id);
    crate::log_message(1, &format!("proxy: conn.close id={} existed={existed}", req.id));
    crate::ok_data(json!({ "ok": true, "id": req.id, "closed": existed }))
}

pub(crate) fn close_all_arm() -> Result<Vec<u8>, ModuleError> {
    let tunnel = active_tunnel()?;
    let closed = tunnel.statistics().close_all_connections_counted();
    store().lock().unwrap_or_else(|e| e.into_inner()).map.clear();
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
        let _g = SERIAL.lock().unwrap();
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
        let _g = SERIAL.lock().unwrap();
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
        let _g = SERIAL.lock().unwrap();
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
        let _g = SERIAL.lock().unwrap();
        reset_for_tests();
        let stats = meow_tunnel::Statistics::new();
        track(&stats, "a.example");
        track(&stats, "b.example");
        assert_eq!(sync(&stats).len(), 2);

        let closed = stats.close_all_connections_counted();
        assert_eq!(closed, 2);
        store().lock().unwrap().map.clear();
        assert!(sync(&stats).is_empty());
        reset_for_tests();
    }
}
