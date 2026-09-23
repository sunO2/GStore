//! Central memory budget + host probes (Todo 27).
//!
//! Every accumulator in this module that can grow with traffic is capped at its
//! source (log ring, per-domain stats, connection projection, DNS rings, lwIP
//! channel depth, reader→ingress queue). This module is the one place that
//! re-exports those caps so a test can assert them against ceilings, and that
//! states a numeric worst-case byte budget instead of a promise.
//!
//! It also provides the RSS/CPU probes the local benchmark harness uses
//! (`bench/run.sh`, `tun::tests::bench_dataplane_reader_throughput`).
#![allow(dead_code)]

use crate::{conn, dns, logging, requests, stats, tun};

pub(crate) const LOG_RING_CAP: usize = logging::RING_CAPACITY;
pub(crate) const DOMAIN_CAP: usize = stats::DOMAIN_CAP;
pub(crate) const FLOW_CAP: usize = stats::FLOW_CAP;
pub(crate) const CONN_TRACK_CAP: usize = conn::CONN_TRACK_CAP;
pub(crate) const CONN_TOMBSTONE_CAP: usize = conn::CONN_TOMBSTONE_CAP;
pub(crate) const DNS_QUERY_RING_CAP: usize = dns::QUERY_RING_CAPACITY;
pub(crate) const DNS_MAPPING_RING_CAP: usize = dns::MAPPING_RING_CAPACITY;
pub(crate) const FAKEIP_STORE_CAP: usize = dns::FAKEIP_STORE_SIZE;
pub(crate) const LWIP_STACK_BUFFER_SIZE: usize = tun::STACK_BUFFER_SIZE;
pub(crate) const LWIP_UDP_BUFFER_SIZE: usize = tun::UDP_BUFFER_SIZE;
pub(crate) const TUN_READ_BUFFER_SIZE: usize = tun::READ_BUFFER_SIZE;
pub(crate) const TUN_INGRESS_CHANNEL: usize = tun::INGRESS_CHANNEL;

// Request-collector caps (Todo 9). The **cap counts** are re-exported from their
// owning module so there is exactly one source of truth (`requests.rs`); the
// per-record byte caps and the UID caps are owned here because this module is
// the single place that states the aggregate memory budget.
pub(crate) const REQUEST_RING_CAP: usize = requests::REQUEST_RING_CAP;
pub(crate) const REQUEST_FLUSH_QUEUE_CAP: usize = requests::REQUEST_FLUSH_QUEUE_CAP;
pub(crate) const STALE_LIVE_CAP: usize = requests::STALE_LIVE_CAP;
/// Bound on the in-flight UID-resolution map (`recordId → query`, ~30 s TTL).
pub(crate) const UID_PENDING_CAP: usize = 2048;
/// Bound on UID results that arrive before their record is inserted.
pub(crate) const UID_EARLY_RESULTS_CAP: usize = 2048;

/// Ceilings: a cap raised above one of these must be re-justified here, because
/// the memory test fails otherwise. This makes "bounded" a reviewed decision.
pub(crate) const MAX_LOG_RING: usize = 4096;
pub(crate) const MAX_DOMAINS: usize = 4096;
pub(crate) const MAX_FLOWS: usize = 4096;
pub(crate) const MAX_CONN_TRACK: usize = 4096;
pub(crate) const MAX_CONN_TOMBSTONE: usize = 4096;
pub(crate) const MAX_DNS_RING: usize = 4096;
pub(crate) const MAX_FAKEIP_STORE: usize = 65_536;
pub(crate) const MAX_LWIP_QUEUE_DEPTH: usize = 4096;
pub(crate) const MAX_TUN_READ_BUFFER: usize = 65_535;
pub(crate) const MAX_INGRESS_CHANNEL: usize = 1024;

/// Per-entry ceilings for the worst-case accounting. These are generous upper
/// bounds; real records are far smaller.
const LOG_RECORD_MAX_BYTES: usize = 4 * 1024;
const DOMAIN_RECORD_MAX_BYTES: usize = 1024;
const FLOW_RECORD_MAX_BYTES: usize = 256;
const CONN_RECORD_MAX_BYTES: usize = 1024;
const TOMBSTONE_MAX_BYTES: usize = 64;
const DNS_RECORD_MAX_BYTES: usize = 1024;
const FAKEIP_ENTRY_MAX_BYTES: usize = 64;
/// Per-entry ceilings for the request collector (Todo 9). `REQUEST_RECORD_MAX_BYTES`
/// must dominate the true worst-case serialized record: every field is bounded
/// (domain ≤253, 8 packages ×128, bare dst IP ≤45, src ≤49, UUID connId 36,
/// rule ≤64, rulePayload ≤128, outbound ≤64) and the numeric/camelCase-JSON
/// overhead is covered by the practical value ranges asserted in
/// `worst_case_request_record_fits_its_cap`.
pub(crate) const REQUEST_RECORD_MAX_BYTES: usize = 2048;
pub(crate) const REQUEST_FLUSH_RECORD_MAX_BYTES: usize = 2048;
pub(crate) const STALE_LIVE_RECORD_MAX_BYTES: usize = 512;
pub(crate) const UID_QUERY_MAX_BYTES: usize = 256;
pub(crate) const UID_ANSWER_MAX_BYTES: usize = 256;
/// Assumed frame size for the bounded packet queues (TUN MTU is 1500).
const FRAME_BYTES: usize = 1500;

/// Upper bound on bytes the bounded accumulators may retain at once. A test
/// asserts the computed [`worst_case_bytes`] stays under this; raise it only
/// with a measured justification.
pub(crate) const WORST_CASE_BUDGET_BYTES: usize = 32 * 1024 * 1024;

/// Worst-case retained bytes across all capped accumulators, assuming
/// MTU-sized frames for the packet queues.
pub(crate) fn worst_case_bytes() -> usize {
    LOG_RING_CAP * LOG_RECORD_MAX_BYTES
        + DOMAIN_CAP * DOMAIN_RECORD_MAX_BYTES
        + FLOW_CAP * FLOW_RECORD_MAX_BYTES
        + CONN_TRACK_CAP * CONN_RECORD_MAX_BYTES
        + CONN_TOMBSTONE_CAP * TOMBSTONE_MAX_BYTES
        + DNS_QUERY_RING_CAP * DNS_RECORD_MAX_BYTES
        + DNS_MAPPING_RING_CAP * DNS_RECORD_MAX_BYTES
        + FAKEIP_STORE_CAP * FAKEIP_ENTRY_MAX_BYTES
        + TUN_READ_BUFFER_SIZE
        + TUN_INGRESS_CHANNEL * FRAME_BYTES
        + LWIP_STACK_BUFFER_SIZE * FRAME_BYTES
        + LWIP_UDP_BUFFER_SIZE * FRAME_BYTES
        // Request collector (Todo 9). SQLite rows are deliberately EXCLUDED:
        // `proxy_requests.db` is disk-resident and does not count against RSS.
        // Only the in-memory ring, the bounded flush queue, the `stale_live`
        // suppression set and the bounded UID `pending`/`earlyResults` maps.
        + (REQUEST_RING_CAP + REQUEST_FLUSH_QUEUE_CAP) * REQUEST_RECORD_MAX_BYTES
        + STALE_LIVE_CAP * STALE_LIVE_RECORD_MAX_BYTES
        + UID_PENDING_CAP * UID_QUERY_MAX_BYTES
        + UID_EARLY_RESULTS_CAP * UID_ANSWER_MAX_BYTES
}

#[cfg(target_os = "linux")]
fn page_size_kb() -> u64 {
    let size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if size <= 0 {
        4
    } else {
        size as u64 / 1024
    }
}

/// Resident set size of the current process in KiB (Linux `/proc`; 0 elsewhere).
#[cfg(target_os = "linux")]
pub(crate) fn rss_kb() -> u64 {
    let Ok(statm) = std::fs::read_to_string("/proc/self/statm") else {
        return 0;
    };
    statm
        .split_whitespace()
        .nth(1)
        .and_then(|pages| pages.parse::<u64>().ok())
        .map(|pages| pages * page_size_kb())
        .unwrap_or(0)
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn rss_kb() -> u64 {
    0
}

/// Consumed CPU time (user+system) of the current process in ms (0 elsewhere).
#[cfg(target_os = "linux")]
pub(crate) fn cpu_ms() -> u64 {
    let Ok(stat) = std::fs::read_to_string("/proc/self/stat") else {
        return 0;
    };
    let Some((_, rest)) = stat.rsplit_once(')') else {
        return 0;
    };
    let fields: Vec<&str> = rest.split_whitespace().collect();
    let ticks = fields
        .get(11)
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0)
        + fields
            .get(12)
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0);
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let hz = if hz <= 0 { 100 } else { hz as u64 };
    ticks * 1000 / hz
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn cpu_ms() -> u64 {
    0
}

/// Print one machine-greppable benchmark line (the harness greps `GSTORE_BENCH`).
pub(crate) fn bench_line(name: &str, fields: &[(&str, u128)]) {
    let body = fields
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join(" ");
    println!("GSTORE_BENCH {name} {body}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_accumulator_cap_is_within_its_ceiling() {
        assert!(LOG_RING_CAP <= MAX_LOG_RING, "log ring cap {LOG_RING_CAP}");
        assert!(DOMAIN_CAP <= MAX_DOMAINS, "domain cap {DOMAIN_CAP}");
        assert!(FLOW_CAP <= MAX_FLOWS, "flow cap {FLOW_CAP}");
        assert!(CONN_TRACK_CAP <= MAX_CONN_TRACK, "conn cap {CONN_TRACK_CAP}");
        assert!(
            CONN_TOMBSTONE_CAP <= MAX_CONN_TOMBSTONE,
            "tombstone cap {CONN_TOMBSTONE_CAP}"
        );
        assert!(DNS_QUERY_RING_CAP <= MAX_DNS_RING);
        assert!(DNS_MAPPING_RING_CAP <= MAX_DNS_RING);
        assert!(FAKEIP_STORE_CAP <= MAX_FAKEIP_STORE);
        assert!(LWIP_STACK_BUFFER_SIZE <= MAX_LWIP_QUEUE_DEPTH);
        assert!(LWIP_UDP_BUFFER_SIZE <= MAX_LWIP_QUEUE_DEPTH);
        assert!(TUN_INGRESS_CHANNEL <= MAX_INGRESS_CHANNEL);
        assert!(TUN_READ_BUFFER_SIZE <= MAX_TUN_READ_BUFFER);
    }

    #[test]
    fn worst_case_memory_budget_is_bounded() {
        // Baseline before the request collector (Todo 9): must not drift.
        let baseline = LOG_RING_CAP * LOG_RECORD_MAX_BYTES
            + DOMAIN_CAP * DOMAIN_RECORD_MAX_BYTES
            + FLOW_CAP * FLOW_RECORD_MAX_BYTES
            + CONN_TRACK_CAP * CONN_RECORD_MAX_BYTES
            + CONN_TOMBSTONE_CAP * TOMBSTONE_MAX_BYTES
            + DNS_QUERY_RING_CAP * DNS_RECORD_MAX_BYTES
            + DNS_MAPPING_RING_CAP * DNS_RECORD_MAX_BYTES
            + FAKEIP_STORE_CAP * FAKEIP_ENTRY_MAX_BYTES
            + TUN_READ_BUFFER_SIZE
            + TUN_INGRESS_CHANNEL * FRAME_BYTES
            + LWIP_STACK_BUFFER_SIZE * FRAME_BYTES
            + LWIP_UDP_BUFFER_SIZE * FRAME_BYTES;
        assert_eq!(baseline, 11_773_951, "baseline accounting drifted");

        // Request-collector additions: in-memory ring + bounded flush queue +
        // `stale_live` suppression set + UID `pending`/`earlyResults`. Computed
        // from the ACTUAL caps, never the `MAX_*` ceilings (which would grossly
        // overstate the budget). SQLite rows are excluded — disk-resident, not
        // RSS.
        let request_additions = (REQUEST_RING_CAP + REQUEST_FLUSH_QUEUE_CAP)
            * REQUEST_RECORD_MAX_BYTES
            + STALE_LIVE_CAP * STALE_LIVE_RECORD_MAX_BYTES
            + UID_PENDING_CAP * UID_QUERY_MAX_BYTES
            + UID_EARLY_RESULTS_CAP * UID_ANSWER_MAX_BYTES;
        assert_eq!(request_additions, 13_631_488, "request accounting drifted");

        let worst = worst_case_bytes();
        assert_eq!(
            worst,
            baseline + request_additions,
            "worst_case_bytes must equal baseline + the four request accumulators"
        );
        assert_eq!(worst, 25_405_439, "worst-case budget drifted");
        assert!(
            worst <= WORST_CASE_BUDGET_BYTES,
            "worst-case {worst} B exceeds budget {WORST_CASE_BUDGET_BYTES} B"
        );
        // The two packet queues dominate; make that explicit so a future bump
        // is visible in the test, not just in a comment.
        let queues = TUN_INGRESS_CHANNEL * FRAME_BYTES
            + LWIP_STACK_BUFFER_SIZE * FRAME_BYTES
            + LWIP_UDP_BUFFER_SIZE * FRAME_BYTES;
        assert!(queues <= worst);
    }

    /// `REQUEST_RECORD_MAX_BYTES` must dominate the true worst-case serialized
    /// request: every content field at its cap plus serde's camelCase framing
    /// and the collector's practical numeric ranges. A cap below a real record
    /// would silently under-count the budget, so this is asserted, not assumed.
    #[test]
    fn worst_case_request_record_fits_its_cap() {
        use crate::requests::{RequestRecord, CLOSE_REASON_CLOSED, UID_STATE_KNOWN};

        let domain = "d".repeat(253);
        let packages: Vec<String> = (0..8).map(|_| "p".repeat(128)).collect();
        let record = RequestRecord {
            record_id: 4_294_967_295,
            conn_id: "c".repeat(36),
            open_ts_ms: 4_102_444_800_000,
            close_ts_ms: Some(4_102_444_800_000),
            duration_ms: Some(86_400_000),
            domain,
            domain_known: true,
            dst_ip: "f".repeat(45),
            dst_port: u16::MAX,
            src: "s".repeat(49),
            network: "tcp".to_string(),
            uid: Some(u32::MAX),
            packages,
            uid_state: UID_STATE_KNOWN.to_string(),
            rule: "r".repeat(64),
            rule_payload: "y".repeat(128),
            outbound: "o".repeat(64),
            upload_bytes: 9_999_999_999,
            download_bytes: 9_999_999_999,
            close_reason: CLOSE_REASON_CLOSED.to_string(),
        };
        let serialized = serde_json::to_string(&record).expect("serialize worst-case record");
        assert!(
            serialized.len() <= REQUEST_RECORD_MAX_BYTES,
            "worst-case request record is {} B > cap {} B",
            serialized.len(),
            REQUEST_RECORD_MAX_BYTES
        );
        // Prove the record really is a worst case, not a trivially small one.
        let content_bounds = 253 + 8 * 128 + 45 + 49 + 36 + 64 + 128 + 64;
        assert!(
            serialized.len() >= content_bounds,
            "worst-case framing lost: {} B < content bounds {} B",
            serialized.len(),
            content_bounds
        );
    }

    #[test]
    fn probes_return_plausible_values() {
        if cfg!(target_os = "linux") {
            assert!(rss_kb() > 0, "RSS probe must read /proc");
            // CPU may be 0 only if this test thread has not accumulated a tick.
            let _ = cpu_ms();
        }
    }
}
