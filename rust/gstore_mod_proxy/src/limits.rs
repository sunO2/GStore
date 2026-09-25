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

use crate::{conn, dns, logging, requests, shaper, stats, tun};

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

// Weak-network shaper release-heap caps (Todo 6). Re-exported from `shaper.rs`
// (single source of truth); the byte cap dominates the frame cap for MTU-sized
// frames, so the budget charges the byte cap once per direction (two total).
pub(crate) const SHAPER_BUFFER_BYTES_PER_DIRECTION: usize = shaper::BUFFER_BYTES_PER_DIRECTION;
pub(crate) const SHAPER_MAX_FRAMES: usize = shaper::MAX_FRAMES;

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
/// Bound on the in-flight capture-origin UID registry (`recordId → oneshot`).
/// Equal to the host's `UID_BATCH_MAX` so capture lookups can never starve a
/// request batch on the same lane.
pub(crate) const CAPTURE_UID_INFLIGHT_CAP: usize = 64;

// MITM termination, capture ring and rewrite-rule caps (Todo 4). `mitm.rs` and
// `captures.rs` do not exist yet, so — unlike the `requests.rs`/`shaper.rs` caps
// this module re-exports — these are declared HERE, the one module that owns the
// aggregate memory budget, until each owning module lands and becomes the single
// source of truth. The per-record byte caps are owned here regardless.
/// Leaf-certificate cache: per-host `Arc<rustls::ServerConfig>`, oldest evicted.
pub(crate) const MITM_CERT_CACHE_CAP: usize = 64;
/// Per-entry ceiling for the leaf cache. We only ever cache our own single
/// self-signed ECDSA leaf (estimated entry ≈ host(≤253) + DER(~0.5 KiB) + 1 KiB
/// fixed overhead ≈ 1.8 KiB), so 4 KiB stays >2× conservative while leaving the
/// budget room to charge the WebSocket open-session accumulation below.
pub(crate) const MITM_CERT_ENTRY_MAX_BYTES: usize = 4 * 1024;
/// Capture-record ring. Holds summaries only; full payloads are disk-resident.
pub(crate) const CAPTURE_RING_CAP: usize = 256;
/// Must dominate the in-ring summary fields (url ≤1 KiB, host ≤253, connId 36,
/// 2×256 previews, 2×512 truncated headers, 512 WS preview, scalars/keys) —
/// asserted by `capture_record_cap_dominates_ring_fields`, not assumed.
pub(crate) const CAPTURE_RECORD_MAX_BYTES: usize = 4096;
/// Rewrite-rule table: bounded, oldest eviction by the owning captures module.
pub(crate) const CAPTURE_RULE_CAP: usize = 128;
pub(crate) const CAPTURE_RULE_ENTRY_MAX_BYTES: usize = 2048;
/// Capture pending-flush queue byte bound. Re-exported from `captures.rs` (the
/// single source of truth); it is the only structure that holds not-yet-flushed
/// bodies in RAM, so it is charged against the memory budget.
pub(crate) const CAPTURE_FLUSH_QUEUE_BYTES: usize = crate::captures::CAPTURE_FLUSH_QUEUE_BYTES;
/// Streaming-decode scratch per in-flight MITM session: the bounded 8 KiB read
/// chunk plus decoder state. The decoded body itself is charged via the pending
/// queue term; this covers the transient held beyond it while a body decodes.
pub(crate) const CAPTURE_DECODE_TRANSIENT_BYTES: usize = 8 * 1024;
/// At most this many MITM sessions in flight; the (N+1)th is a **direct
/// pass-through** — never queued, never buffered.
///
/// Raised from 7 to 32 (device defect 2), then 32 to 64 (device defect 7): app-
/// scoped capture gates *all* TLS from the selected apps, and one page opens
/// many concurrent TLS connections, so 7 starved real browsing and 32 briefly
/// tripped `inflight cap reached` on device. At 64 the recomputed worst case is
/// 73,082,879 B against the 96 MiB budget below (27,580,417 B headroom), with the
/// per-slot charge now 651,264 B (`MITM_SESSION_BUFFER_MAX_BYTES` 606,208 +
/// `CAPTURE_DECODE_TRANSIENT_BYTES` 8,192 + WS share 64×576 = 36,864).
pub(crate) const MITM_MAX_INFLIGHT: usize = 64;
/// Hard per-session instant buffer, enforced by every protocol knob (Todo 9):
/// WS + rustls (plaintext/TLS) + hyper h1 read/write + hyper h2 windows.
///
/// Tightened to the **true** knob sum for device defect 7. The previously
/// generous 640 KiB (raised for device defect 5) is replaced by the exact
/// `mitm::MITM_SESSION_BUDGET_BYTES` = 606,208 B: WS two sides 106,496 + rustls
/// two conns 32,768 + h1 two conns 262,144 (2×2×64 KiB) + h2 two conns 204,800
/// (2 × {stream 16 KiB + conn 16 KiB + send buf 4 KiB + header list 64 KiB}).
/// The `const` assertion in `mitm.rs` still proves the real sum fits this cap;
/// its equality is pinned by a test here so the charge can never be a stale,
/// larger constant.
pub(crate) const MITM_SESSION_BUFFER_MAX_BYTES: usize = 606_208;
/// CA + leaf certificate PEM buffer ceiling.
pub(crate) const MITM_PEM_BUFFER_MAX_BYTES: usize = 64 * 1024;
/// One recorded WebSocket frame retained in an open session: the bounded payload
/// preview plus the [`crate::mitm::WsFrameRecord`] header. Pinned to the real
/// struct size so the charge can never under-count the per-frame record.
pub(crate) const WS_FRAME_RECORD_MAX_BYTES: usize =
    crate::mitm::WS_PREVIEW_MAX_BYTES + std::mem::size_of::<crate::mitm::WsFrameRecord>();
/// Open WebSocket-session accumulation (`captures.rs::ws_sessions`): at most one
/// session per in-flight MITM slot, each retaining `CAPTURE_WS_FRAMES_MAX` bounded
/// frame records until close. This is the only structure besides the pending
/// flush queue that holds WS payload bytes in RAM, so it is charged explicitly.
pub(crate) const MITM_WS_SESSION_BYTES: usize =
    MITM_MAX_INFLIGHT * crate::captures::CAPTURE_WS_FRAMES_MAX * WS_FRAME_RECORD_MAX_BYTES;

/// In-ring URL truncation bound. The full URL is disk-resident; this is a field
/// *inside* [`CAPTURE_RECORD_MAX_BYTES`], not an additional memory term.
pub(crate) const CAPTURE_URL_MAX_BYTES: usize = 1024;
/// Disk-only body ceiling (SQLite). Deliberately NOT charged to the memory
/// budget — assert it stays out of [`worst_case_bytes`].
pub(crate) const CAPTURE_BODY_MAX_BYTES: usize = 1024 * 1024;

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
pub(crate) const MAX_SHAPER_BUFFER_BYTES_PER_DIRECTION: usize = 2 * 1024 * 1024;
pub(crate) const MAX_SHAPER_MAX_FRAMES: usize = 512;
pub(crate) const MAX_MITM_CERT_CACHE: usize = 64;
pub(crate) const MAX_CAPTURE_RING: usize = 256;
pub(crate) const MAX_CAPTURE_RULE: usize = 128;
pub(crate) const MAX_MITM_MAX_INFLIGHT: usize = 64;

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
/// Per-entry ceiling for the capture UID registry: one bounded query plus the
/// bounded answer delivered through its oneshot.
const CAPTURE_UID_ENTRY_MAX_BYTES: usize = UID_QUERY_MAX_BYTES + UID_ANSWER_MAX_BYTES;
/// Assumed frame size for the bounded packet queues (TUN MTU is 1500).
const FRAME_BYTES: usize = 1500;

/// Upper bound on bytes the bounded accumulators may retain at once. A test
/// asserts the computed [`worst_case_bytes`] stays under this; raise it only
/// with a measured justification.
///
/// Raised 32 MiB → 48 MiB for the 32-slot MITM cap (device defect 2), then
/// 48 MiB → 64 MiB when the MITM h1/h2 head limits moved to 64 KiB and the
/// per-session buffer cap to 640 KiB (device defect 5), then 64 MiB → 96 MiB for
/// the 64-slot MITM cap (device defect 7). The 64-slot documented worst case is
/// 73,082,879 B, i.e. 27,580,417 B of headroom.
pub(crate) const WORST_CASE_BUDGET_BYTES: usize = 96 * 1024 * 1024;

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
        // Capture-origin UID registry (C3): bounded in-flight lookups.
        + CAPTURE_UID_INFLIGHT_CAP * CAPTURE_UID_ENTRY_MAX_BYTES
        // Shaper release heaps (Todo 6): one bounded heap per direction, billed
        // by actual frame length, so each holds at most this many bytes.
        + 2 * SHAPER_BUFFER_BYTES_PER_DIRECTION
        // MITM/capture accumulators (Todo 4): the bounded caches and one in-flight
        // session batch. `CAPTURE_URL_MAX_BYTES` is a field inside a capture
        // record (already covered) and `CAPTURE_BODY_MAX_BYTES` is disk-only
        // (SQLite), so neither is charged here.
        + MITM_CERT_CACHE_CAP * MITM_CERT_ENTRY_MAX_BYTES
        + CAPTURE_RING_CAP * CAPTURE_RECORD_MAX_BYTES
        + CAPTURE_RULE_CAP * CAPTURE_RULE_ENTRY_MAX_BYTES
        + MITM_MAX_INFLIGHT * MITM_SESSION_BUFFER_MAX_BYTES
        + MITM_PEM_BUFFER_MAX_BYTES
        // Capture pending-flush queue (the only structure holding not-yet-flushed
        // bodies in RAM) plus the streaming-decode scratch of each in-flight
        // session. Previously omitted, which understated the real worst case.
        + CAPTURE_FLUSH_QUEUE_BYTES
        + MITM_MAX_INFLIGHT * CAPTURE_DECODE_TRANSIENT_BYTES
        // Open WebSocket-session accumulation: at most one session per in-flight
        // MITM slot, each holding `CAPTURE_WS_FRAMES_MAX` bounded frame records.
        + MITM_WS_SESSION_BYTES
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
        assert!(
            SHAPER_BUFFER_BYTES_PER_DIRECTION <= MAX_SHAPER_BUFFER_BYTES_PER_DIRECTION,
            "shaper byte cap {SHAPER_BUFFER_BYTES_PER_DIRECTION}"
        );
        assert!(
            SHAPER_MAX_FRAMES <= MAX_SHAPER_MAX_FRAMES,
            "shaper frame cap {SHAPER_MAX_FRAMES}"
        );
        assert!(MITM_CERT_CACHE_CAP <= MAX_MITM_CERT_CACHE);
        assert!(CAPTURE_RING_CAP <= MAX_CAPTURE_RING);
        assert!(CAPTURE_RULE_CAP <= MAX_CAPTURE_RULE);
        assert!(MITM_MAX_INFLIGHT <= MAX_MITM_MAX_INFLIGHT);
        assert!(
            CAPTURE_FLUSH_QUEUE_BYTES <= CAPTURE_BODY_MAX_BYTES,
            "queue cap {CAPTURE_FLUSH_QUEUE_BYTES} exceeds the body cap"
        );
        assert!(CAPTURE_DECODE_TRANSIENT_BYTES > 0);
        assert!(MITM_WS_SESSION_BYTES > 0);
        assert!(WS_FRAME_RECORD_MAX_BYTES > crate::mitm::WS_PREVIEW_MAX_BYTES);
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

        // Shaper release heaps (Todo 6): both directions' byte caps, computed
        // from the ACTUAL caps, not the `MAX_*` ceilings.
        let shaper_additions = 2 * SHAPER_BUFFER_BYTES_PER_DIRECTION;
        assert_eq!(shaper_additions, 4_194_304, "shaper accounting drifted");

        // MITM/capture accumulators (Todo 4), computed from the ACTUAL caps. The
        // in-ring URL bound is a field inside `CAPTURE_RECORD_MAX_BYTES`, and the
        // body bound is disk-only, so neither appears as its own term.
        let capture_additions = MITM_CERT_CACHE_CAP * MITM_CERT_ENTRY_MAX_BYTES
            + CAPTURE_RING_CAP * CAPTURE_RECORD_MAX_BYTES
            + CAPTURE_RULE_CAP * CAPTURE_RULE_ENTRY_MAX_BYTES
            + MITM_MAX_INFLIGHT * MITM_SESSION_BUFFER_MAX_BYTES
            + MITM_PEM_BUFFER_MAX_BYTES;
        assert_eq!(capture_additions, 40_435_712, "capture accounting drifted");
        assert!(
            capture_additions <= 71_063_553,
            "capture additions {capture_additions} B exceed the 96 MiB-budget headroom 71_063_553 B"
        );

        // Capture pending-flush queue + streaming-decode transient. These were
        // previously uncharged, which understated the real worst case.
        let capture_queue_additions =
            CAPTURE_FLUSH_QUEUE_BYTES + MITM_MAX_INFLIGHT * CAPTURE_DECODE_TRANSIENT_BYTES;
        assert_eq!(
            capture_queue_additions, 655_360,
            "capture queue/decode accounting drifted"
        );

        // Open WebSocket-session accumulation (R6). Charged from the ACTUAL caps:
        // one bounded frame record per frame, one session per in-flight slot.
        let ws_session_additions = MITM_WS_SESSION_BYTES;
        assert_eq!(
            ws_session_additions, 2_359_296,
            "WS-session accounting drifted"
        );
        assert_eq!(
            WS_FRAME_RECORD_MAX_BYTES,
            crate::mitm::WS_PREVIEW_MAX_BYTES + std::mem::size_of::<crate::mitm::WsFrameRecord>(),
            "WS frame charge must dominate the real record"
        );
        assert!(
            capture_additions + capture_queue_additions + ws_session_additions <= 71_063_553,
            "capture total {} B exceeds the 96 MiB-budget headroom 71_063_553 B",
            capture_additions + capture_queue_additions + ws_session_additions
        );

        // Capture-origin UID registry (C3): bounded in-flight lookups, computed
        // from the ACTUAL cap.
        let capture_uid_additions = CAPTURE_UID_INFLIGHT_CAP * CAPTURE_UID_ENTRY_MAX_BYTES;
        assert_eq!(
            capture_uid_additions, 32_768,
            "capture UID registry accounting drifted"
        );
        assert!(
            capture_additions
                + capture_queue_additions
                + ws_session_additions
                + capture_uid_additions
                <= 71_063_553,
            "capture total {} B exceeds the 96 MiB-budget headroom 71_063_553 B",
            capture_additions
                + capture_queue_additions
                + ws_session_additions
                + capture_uid_additions
        );

        let worst = worst_case_bytes();
        assert_eq!(
            worst,
            baseline + request_additions + shaper_additions + capture_additions + capture_queue_additions + ws_session_additions + capture_uid_additions,
            "worst_case_bytes must equal baseline + request + shaper + capture + queue + WS-session + capture-uid accumulators"
        );
        assert_eq!(worst, 73_082_879, "worst-case budget drifted");
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
    fn worst_case_counts_the_shaper_buffer_exactly_twice() {
        let shaper_term = 2 * SHAPER_BUFFER_BYTES_PER_DIRECTION;
        assert_eq!(shaper_term, 4_194_304, "shaper memory term drifted");

        // Removing the shaper term must leave exactly the pre-shaper worst case
        // — i.e. `worst_case_bytes()` includes exactly
        // `2 × SHAPER_BUFFER_BYTES_PER_DIRECTION` for the heaps, no more.
        let without_shaper = worst_case_bytes() - shaper_term;
        assert_eq!(without_shaper, 68_888_575, "shaper term is not exactly 2 × the per-direction cap");

        // The cap must equal the module's own source of truth.
        assert_eq!(SHAPER_BUFFER_BYTES_PER_DIRECTION, shaper::BUFFER_BYTES_PER_DIRECTION);
        assert_eq!(SHAPER_MAX_FRAMES, shaper::MAX_FRAMES);
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
    fn capture_record_cap_dominates_ring_fields() {
        // In-ring summary fields, each truncated at its own bound. The record cap
        // must dominate their sum so the budget never under-counts a record.
        let url = CAPTURE_URL_MAX_BYTES;
        let host = 253;
        let conn_id = 36;
        let previews = 2 * 256;
        let headers = 2 * 512;
        let ws_preview = 512;
        let scalars_keys = 300;
        let fields = url + host + conn_id + previews + headers + ws_preview + scalars_keys;
        assert_eq!(fields, 3661);
        assert_eq!(CAPTURE_RECORD_MAX_BYTES, 4096);
        assert!(
            CAPTURE_RECORD_MAX_BYTES >= fields,
            "capture record cap {CAPTURE_RECORD_MAX_BYTES} B < field bounds {fields} B"
        );
    }

    #[test]
    fn capture_memory_budget_excludes_bulk_payloads_and_disk_side() {
        // The only terms the MITM/capture budget may charge are the four bounded
        // caches plus the PEM buffer. Recomputing that sum must reproduce
        // `worst_case_bytes()`'s additions exactly: a full-body, full-URL,
        // full-header or WS-payload term would break this equality.
        let memory = MITM_CERT_CACHE_CAP * MITM_CERT_ENTRY_MAX_BYTES
            + CAPTURE_RING_CAP * CAPTURE_RECORD_MAX_BYTES
            + CAPTURE_RULE_CAP * CAPTURE_RULE_ENTRY_MAX_BYTES
            + MITM_MAX_INFLIGHT * MITM_SESSION_BUFFER_MAX_BYTES
            + MITM_PEM_BUFFER_MAX_BYTES
            + CAPTURE_FLUSH_QUEUE_BYTES
            + MITM_MAX_INFLIGHT * CAPTURE_DECODE_TRANSIENT_BYTES
            + MITM_WS_SESSION_BYTES
            + CAPTURE_UID_INFLIGHT_CAP * CAPTURE_UID_ENTRY_MAX_BYTES;
        assert_eq!(memory, 43_483_136, "in-memory capture additions drifted");

        const PRIOR_BASELINE: usize = 29_599_743;
        assert_eq!(worst_case_bytes() - PRIOR_BASELINE, memory);

        // The 1 MiB disk-only body must NOT be part of the charged additions.
        // The equality above already pins the additions to `memory` (which
        // excludes the body); assert the negative case explicitly so a future
        // accidental charge is caught here rather than smuggled past the sum.
        // (The raised 64 MiB budget means headroom exhaustion can no longer
        // prove exclusion, so exclusion is proven structurally instead.)
        assert_eq!(CAPTURE_BODY_MAX_BYTES, 1024 * 1024);
        assert_ne!(
            worst_case_bytes() - PRIOR_BASELINE,
            memory + CAPTURE_BODY_MAX_BYTES,
            "the disk-only body must not be charged to the memory budget"
        );
        // The capture additions (still excluding the body) must fit the
        // budget-minus-baseline headroom.
        const HEADROOM: usize = 71_063_553;
        assert_eq!(WORST_CASE_BUDGET_BYTES - PRIOR_BASELINE, HEADROOM);
        assert!(
            memory <= HEADROOM,
            "capture additions {memory} B exceed the pre-capture headroom {HEADROOM} B"
        );
        assert_eq!(CAPTURE_URL_MAX_BYTES, 1024);
    }

    #[test]
    fn mitm_inflight_cap_is_a_pass_through_policy() {
        // Policy assertion (the enforcement mechanism lives in the MITM
        // dispatcher todo): the cap exists here so the gate can count in-flight
        // sessions and let the (MITM_MAX_INFLIGHT + 1)th take the direct
        // pass-through path instead of queueing or buffering. Pin the number.
        assert_eq!(MITM_MAX_INFLIGHT, 64);
        assert!(MITM_MAX_INFLIGHT > 0);
        // The per-session cap must be the true knob sum, not a stale/larger
        // constant: pin it to the owning module's summed budget. `mitm.rs`'s own
        // `const` assertion proves the sum fits; this equality proves the charge
        // is not looser than the sum (which would overstate the budget).
        assert_eq!(
            MITM_SESSION_BUFFER_MAX_BYTES,
            crate::mitm::MITM_SESSION_BUDGET_BYTES
        );
        assert_eq!(
            MITM_MAX_INFLIGHT * MITM_SESSION_BUFFER_MAX_BYTES,
            38_797_312,
            "in-flight session batch accounting drifted"
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
