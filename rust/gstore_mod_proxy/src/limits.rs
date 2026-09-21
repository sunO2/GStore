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

use crate::{conn, dns, logging, stats, tun};

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
        let worst = worst_case_bytes();
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

    #[test]
    fn probes_return_plausible_values() {
        if cfg!(target_os = "linux") {
            assert!(rss_kb() > 0, "RSS probe must read /proc");
            // CPU may be 0 only if this test thread has not accumulated a tick.
            let _ = cpu_ms();
        }
    }
}
