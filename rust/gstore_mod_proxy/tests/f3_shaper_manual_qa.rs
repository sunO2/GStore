//! F3 — host-equivalent manual-QA harness for the **weak-network shaper**.
//!
//! This is a **harness-level** QA driver, NOT on-hardware QA. It loads the real
//! `libgstore_mod_proxy.so` exactly as the host does (dlopen + the C ABI, the
//! same path `tests/host_dlopen.rs` and `tests/f3_manual_qa_host.rs` exercise)
//! and drives the real delivered datapath end to end:
//!
//!   `tun.set_fd` (mock `SOCK_DGRAM` pair) → `core.start {mode:vpn}` →
//!   `net.shaper.set` / `net.shaper.get` → **the real `tun_loop` reader** →
//!   **the real `ShapePump`** → the real `shaper::{DamageCore,ReleaseScheduler,
//!   ReleaseHeap}` and the real process-global `shaper::counters()`.
//!
//! Nothing in the product is mocked or rewritten. The only injected pieces are
//! the host-side `emit_event`/`protect_fd` callbacks every embedder must supply
//! and a host-side `UDP`-like mock fd (a Unix datagram pair, one frame per read,
//! exactly as the crate's own `tun.rs` tests use).
//!
//! ## Layer per evidence item (explicit)
//! * item 2 (preset slows / disable recovers) — **live ABI path**: real
//!   `tun_loop` + real `ShapePump` under the real `net.shaper.*` config, read
//!   back through the real `net.shaper.get` counters/gauges.
//! * item 3 (IPv6 exemption) — **live ABI path**: frames written to the real fd
//!   are classified by the real `shaper::is_damage_exempt` inside the real
//!   `DamageCore`; the observable is the real `lossDropped`/`upFramesShaped`
//!   counter split under a 100 %-loss uplink.
//! * item 5 (2 MiB / 512-frame bound) — **live ABI path**: the real
//!   `ReleaseHeap` occupancy gauges (`bufferedFrames`/`bufferedBytes`) and
//!   `bufferDropped` read via `net.shaper.get`.
//!
//! `is_damage_exempt`/`ShapePump`/`buffer_stats` are `pub(crate)`, so they can
//! NOT be called from an integration test; the live ABI path is the only
//! external surface that observes them, and that is what this harness uses.
//!
//! ## Run
//! ```text
//! cargo build -p gstore_mod_proxy
//! cargo test -p gstore_mod_proxy --test f3_shaper_manual_qa -- --ignored --nocapture --test-threads=1
//! ```
//! `--test-threads=1` is required: the module's shaper config/counters and the
//! TUN loop are process-global inside the loaded `.so`.

use std::ffi::{c_char, c_int, c_void, CString};
use std::io::ErrorKind;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use gstore_contract::abi::{
    ABI_OK, GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
};

type RegisterFn = extern "C" fn(*const GStoreModuleEntry, *mut GStoreModuleApi) -> c_int;
type CallFn =
    extern "C" fn(u64, *const c_char, *const u8, usize, *mut *mut u8, *mut usize) -> c_int;
type FreeFn = extern "C" fn(*mut c_void);
type EmitFn = extern "C" fn(u64, u64, *const u8, usize);

const BUFFER_BYTES_PER_DIRECTION: usize = 2 * 1024 * 1024;
const MAX_FRAMES: usize = 512;

static EVENTS: Mutex<Vec<String>> = Mutex::new(Vec::new());

extern "C" fn dummy_protect(_fd: c_int) -> c_int {
    0
}

extern "C" fn capture_event(_module_id: u64, _instance_id: u64, data: *const u8, len: usize) {
    if data.is_null() || len < 4 {
        return;
    }
    let raw = unsafe { std::slice::from_raw_parts(data, len) };
    let tlen = u32::from_le_bytes(raw[0..4].try_into().unwrap()) as usize;
    if raw.len() < 4 + tlen {
        return;
    }
    let kind = String::from_utf8_lossy(&raw[4..4 + tlen]).into_owned();
    EVENTS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push(kind);
}

fn locate_so() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let candidates = [
        dir.join("target/debug/libgstore_mod_proxy.so"),
        dir.join("target/debug/deps/libgstore_mod_proxy.so"),
        dir.join("target/release/libgstore_mod_proxy.so"),
        dir.join("target/release/deps/libgstore_mod_proxy.so"),
    ];
    for c in &candidates {
        if c.exists() {
            return c.clone();
        }
    }
    panic!("libgstore_mod_proxy.so not built; run `cargo build -p gstore_mod_proxy` first");
}

/// Dispatch one method; return `(abi_code, json_value)` (never panics on bad JSON).
fn call(
    call_fn: CallFn,
    free_fn: FreeFn,
    inst: u64,
    method: &str,
    payload: &[u8],
) -> (c_int, serde_json::Value) {
    let m = CString::new(method).unwrap();
    let mut ptr: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    let code = call_fn(
        inst,
        m.as_ptr(),
        payload.as_ptr(),
        payload.len(),
        &mut ptr,
        &mut len,
    );
    let bytes = if ptr.is_null() {
        Vec::new()
    } else {
        let v = unsafe { std::slice::from_raw_parts(ptr, len).to_vec() };
        free_fn(ptr as *mut c_void);
        v
    };
    let value = if bytes.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null)
    };
    (code, value)
}

/// Dispatch and assert `ABI_OK` + `ok:true`; return the `data` object.
fn call_ok(
    call_fn: CallFn,
    free_fn: FreeFn,
    inst: u64,
    method: &str,
    payload: &[u8],
) -> serde_json::Value {
    let (code, v) = call(call_fn, free_fn, inst, method, payload);
    assert_eq!(
        code, ABI_OK,
        "{method} must succeed, got ABI code {code}: {v}"
    );
    assert_eq!(v["ok"], true, "{method} ok flag: {v}");
    v["data"].clone()
}

fn tmp_dir(tag: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("gstore-f3-shaper-{tag}-{nanos}"));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

// ---------------------------------------------------------------------------
// Frame fixtures (raw IP, no Ethernet — `frame[0]` is the IP version nibble)
// ---------------------------------------------------------------------------

/// A `len`-byte IPv4 frame the shaper treats as **non-exempt** data but lwIP
/// drops silently: `total_length` is 40 while IHL claims a 60-byte header.
/// Protocol 253 (experimental) is `IpProto::Other` → `is_damage_exempt == false`.
fn paced_frame(len: usize) -> Vec<u8> {
    let mut f = vec![0u8; len];
    f[0] = 0x4F; // IPv4, IHL 15 (claims 60-byte header)
    f[2..4].copy_from_slice(&40u16.to_be_bytes()); // total length 40 < IHL -> lwIP drops
    f[8] = 64; // TTL
    f[9] = 253; // experimental protocol: non-exempt
    f[12..16].copy_from_slice(&[10, 10, 0, 2]);
    f[16..20].copy_from_slice(&[10, 10, 0, 9]);
    f
}

/// IPv4 ICMP echo (proto 1) — exempt.
fn ipv4_icmp_frame() -> Vec<u8> {
    let mut f = vec![0u8; 28];
    f[0] = 0x45;
    f[2..4].copy_from_slice(&28u16.to_be_bytes());
    f[8] = 64;
    f[9] = 1; // ICMP
    f[12..16].copy_from_slice(&[10, 10, 0, 2]);
    f[16..20].copy_from_slice(&[10, 10, 0, 9]);
    f[20] = 8; // echo request
    f
}

/// A well-formed IPv6 header builder.
fn ipv6_header(next_header: u8, payload_len: u16) -> Vec<u8> {
    let mut f = vec![0u8; 40];
    f[0] = 0x60; // IPv6
    f[4..6].copy_from_slice(&payload_len.to_be_bytes());
    f[6] = next_header;
    f[7] = 64; // hop limit
    f[8..24].copy_from_slice(&[
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    ]);
    f[24..40].copy_from_slice(&[
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
    ]);
    f
}

/// IPv6 ICMPv6 (next header 58) — a Router Advertisement (type 134), i.e. an
/// NDP/RA control frame. Exempt by protocol.
fn ipv6_icmp6_ndp_ra_frame() -> Vec<u8> {
    let mut f = ipv6_header(58, 16);
    f.resize(56, 0); // 40-byte IPv6 header + 16-byte ICMPv6 body
    // ICMPv6 header + minimal RA body (16 bytes total payload)
    f[40] = 134; // Router Advertisement
    f[41] = 0; // code
    f[42..44].copy_from_slice(&0u16.to_be_bytes()); // checksum
    f[44] = 64; // cur hop limit
    f
}

/// IPv6 TCP **pure ACK** (next header 6, ACK only, no payload). Exempt.
fn ipv6_tcp_pure_ack_frame() -> Vec<u8> {
    let mut f = ipv6_header(6, 20);
    f.resize(60, 0); // 40-byte IPv6 header + 20-byte TCP header
    // TCP header at offset 40
    f[40..42].copy_from_slice(&443u16.to_be_bytes()); // src port
    f[42..44].copy_from_slice(&55000u16.to_be_bytes()); // dst port
    f[44..48].copy_from_slice(&1u32.to_be_bytes()); // seq
    f[48..52].copy_from_slice(&1u32.to_be_bytes()); // ack
    f[52] = 0x50; // data offset 5
    f[53] = 0x10; // ACK only
    f[54..56].copy_from_slice(&65535u16.to_be_bytes()); // window
    f
}

/// IPv6 **fragment** (next header 44 → Fragment extension header). Exempt
/// regardless of transport.
fn ipv6_fragment_frame() -> Vec<u8> {
    let mut f = ipv6_header(44, 16); // 8-byte frag header + 8-byte UDP
    f.resize(56, 0);
    // Fragment header at offset 40
    f[40] = 17; // next header = UDP
    f[41] = 0; // reserved
    f[42..44].copy_from_slice(&1u16.to_be_bytes()); // offset=0, M=1
    f[44..48].copy_from_slice(&0xABCDu32.to_be_bytes()); // identification
    // UDP header
    f[48..50].copy_from_slice(&12345u16.to_be_bytes());
    f[50..52].copy_from_slice(&443u16.to_be_bytes());
    f[52..54].copy_from_slice(&8u16.to_be_bytes());
    f
}

// ---------------------------------------------------------------------------
// Mock-fd datagram I/O
// ---------------------------------------------------------------------------

/// Send `count` datagrams with a bounded retry on `WouldBlock`; returns the
/// wall-clock send time. Each datagram is one frame (SOCK_DGRAM, one per read,
/// exactly like the crate's own `tun.rs` tests).
fn send_datagrams(peer: &UnixDatagram, frame: &[u8], count: usize) -> Duration {
    let started = Instant::now();
    let mut sent = 0usize;
    let mut spins = 0u32;
    while sent < count {
        match peer.send(frame) {
            Ok(_) => sent += 1,
            Err(e) if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::TimedOut => {
                spins += 1;
                assert!(spins < 2_000_000, "peer write kept blocking after {sent} frames");
                std::thread::sleep(Duration::from_micros(200));
            }
            Err(e) => panic!("datagram send failed: {e}"),
        }
    }
    started.elapsed()
}

fn counters(data: &serde_json::Value) -> serde_json::Value {
    data["counters"].clone()
}

fn counter_u64(c: &serde_json::Value, key: &str) -> u64 {
    c[key].as_u64().unwrap_or(0)
}

fn delta_u64(before: &serde_json::Value, after: &serde_json::Value, key: &str) -> i64 {
    counter_u64(after, key) as i64 - counter_u64(before, key) as i64
}

/// Poll `f` every 5 ms until it returns true or the timeout elapses.
fn poll_until(timeout: Duration, mut f: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if f() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    f()
}

/// Boot a fresh real datapath on a new mock `SOCK_DGRAM` fd: `tun.set_fd` then
/// `core.start {mode:vpn}`. A fresh loop resets the shaper counters and the
/// per-pump scheduler state, so each QA item starts clean.
fn boot_datapath(call_fn: CallFn, free_fn: FreeFn, inst: u64) -> (UnixDatagram, UnixDatagram) {
    let (loop_end, peer) = UnixDatagram::pair().unwrap();
    peer.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
    let fd_payload = format!(r#"{{"fd":{}}}"#, loop_end.as_raw_fd());
    let installed = call_ok(call_fn, free_fn, inst, "tun.set_fd", fd_payload.as_bytes());
    assert_eq!(
        installed["nonblocking"], true,
        "mock fd must be O_NONBLOCK: {installed}"
    );
    let started = call_ok(call_fn, free_fn, inst, "core.start", br#"{"mode":"vpn"}"#);
    assert_eq!(started["state"], "running", "core.start: {started}");
    println!("BOOT core.start={started}");
    std::thread::sleep(Duration::from_millis(300));
    (loop_end, peer)
}

#[test]
#[ignore = "host QA harness: dlopen + real tun_loop/ShapePump + mock fd; run with --ignored --nocapture --test-threads=1"]
fn f3_shaper_manual_qa() {
    println!("=== F3 host-equivalent weak-network shaper QA (harness-level, NOT on-hardware) ===");

    let so = locate_so();
    println!("so={}", so.display());
    let lib = unsafe { libloading::Library::new(&so) }.expect("dlopen proxy module");
    let register: libloading::Symbol<RegisterFn> = unsafe { lib.get(b"gstore_mod_proxy_register\0") }
        .expect("register symbol");

    let entry = GStoreModuleEntry {
        abi_version: GSTORE_MODULE_ABI_VERSION,
        entry_size: std::mem::size_of::<GStoreModuleEntry>() as u32,
        log: None,
        alloc: None,
        free: None,
        emit_event: Some::<EmitFn>(capture_event),
        context: std::ptr::null_mut(),
        protect_fd: Some(dummy_protect),
    };
    let mut api_uninit = std::mem::MaybeUninit::<GStoreModuleApi>::zeroed();
    let code = register(&entry, api_uninit.as_mut_ptr());
    assert_eq!(code, ABI_OK, "register handshake");
    let api = unsafe { api_uninit.assume_init() };
    let create = api.create.unwrap();
    let call_fn = api.call.unwrap();
    let destroy = api.destroy.unwrap();
    let free_fn = api.free.unwrap();
    let shutdown = api.shutdown;

    let dir = tmp_dir("qa");
    let dir_str = dir.display().to_string();
    let cfg = serde_json::to_vec(&serde_json::json!({
        "data_dir": dir_str,
        "cache_dir": dir_str,
    }))
    .unwrap();
    let mut inst: u64 = 0;
    assert_eq!(create(cfg.as_ptr(), cfg.len(), &mut inst), ABI_OK, "create instance");
    assert!(inst > 0);

    // ---- boot the real datapath on a mock fd --------------------------------
    let (mut loop_end, mut peer) = boot_datapath(call_fn, free_fn, inst);

    let get = |method_payload: &str| -> serde_json::Value {
        if method_payload.is_empty() {
            call_ok(call_fn, free_fn, inst, "net.shaper.get", &[])
        } else {
            call_ok(call_fn, free_fn, inst, "net.shaper.set", method_payload.as_bytes())
        }
    };

    // A config that fully disables simulation.
    let cfg_disabled = serde_json::json!({
        "enabled": false, "seed": 0xF3F3,
        "uplink": {"rateBps": 0, "delayMs": 0, "lossPct": 0.0, "lossModel": "none"},
        "downlink": {"rateBps": 0, "delayMs": 0}
    });
    let apply_disabled = || {
        let d = get(&cfg_disabled.to_string());
        assert_eq!(d["applied"], false);
        d
    };

    // =====================================================================
    // ITEM 2 — baseline (disabled) vs weak preset vs hot-disable recovery
    // =====================================================================
    println!("--- ITEM 2: preset slows traffic, disable recovers (live ABI path) ---");
    let base0 = get("");
    assert_eq!(base0["engineRunning"], true, "engine must be running");
    let _ = apply_disabled();

    // --- baseline (disabled): 64 x 1500 B non-exempt frames ----------------
    let n = 64usize;
    let frame = paced_frame(1500);
    {
        let before = counters(&get(""));
        let send_ms = send_datagrams(&peer, &frame, n).as_millis() as u64;
        std::thread::sleep(Duration::from_millis(300));
        // Switch to a huge-delay shape. If the disabled reader had not already
        // consumed the burst, the still-queued frames would now park in the
        // shape heap. Occupancy 0 proves prompt delivery in the disabled path.
        let parked_probe = get(
            &serde_json::json!({
                "enabled": true, "seed": 0xF3F3,
                "uplink": {"rateBps": 0, "delayMs": 60000, "lossPct": 0.0, "lossModel": "none"},
                "downlink": {"rateBps": 0, "delayMs": 0}
            })
            .to_string(),
        );
        std::thread::sleep(Duration::from_millis(200));
        let after = counters(&parked_probe);
        let occ = after["bufferedFrames"].as_u64().unwrap_or(0);
        println!(
            "ITEM2 baseline(disabled): frames={n} send_ms={send_ms} post_switch_occupancy={occ} \
             upFramesShaped_delta={} upBytesShaped_delta={} lossDropped_delta={} \
             bufferDropped_delta={} bufferedFrames_delta={}",
            delta_u64(&before, &after, "upFramesShaped"),
            delta_u64(&before, &after, "upBytesShaped"),
            delta_u64(&before, &after, "lossDropped"),
            delta_u64(&before, &after, "bufferDropped"),
            delta_u64(&before, &after, "bufferedFrames"),
        );
        assert_eq!(occ, 0, "disabled path must have delivered the whole burst before the switch");
        assert_eq!(
            delta_u64(&before, &after, "upFramesShaped"),
            0,
            "disabled identity path must not shape"
        );
        assert_eq!(delta_u64(&before, &after, "lossDropped"), 0, "disabled adds no loss");
        assert_eq!(delta_u64(&before, &after, "bufferDropped"), 0, "disabled adds no buffer drop");
    }

    // --- weak preset (25000 B/s... rateBps is bytes/s in the pacer) --------
    let preset = serde_json::json!({
        "enabled": true, "seed": 0xF3F3,
        "uplink": {"rateBps": 25000, "delayMs": 0, "burstBytes": 1500,
                   "lossPct": 0.0, "lossModel": "none"},
        "downlink": {"rateBps": 0, "delayMs": 0}
    });
    {
        let applied = get(&preset.to_string());
        assert_eq!(applied["applied"], true, "preset must apply: {applied}");
        let before = counters(&applied);
        let t0 = Instant::now();
        let send_ms = send_datagrams(&peer, &frame, n).as_millis() as u64;
        // Wait until every frame has been accepted by the shaper...
        let all_in = poll_until(Duration::from_secs(5), || {
            let d = get("");
            counter_u64(&counters(&d), "upFramesShaped") - counter_u64(&before, "upFramesShaped")
                >= n as u64
        });
        let accepted_ms = t0.elapsed().as_millis() as u64;
        // ... then measure how long the paced heap takes to fully drain.
        let mut peak_frames = 0u64;
        let mut peak_bytes = 0u64;
        let drained = poll_until(Duration::from_secs(30), || {
            let d = get("");
            let c = counters(&d);
            peak_frames = peak_frames.max(counter_u64(&c, "bufferedFrames"));
            peak_bytes = peak_bytes.max(counter_u64(&c, "bufferedBytes"));
            all_in && counter_u64(&c, "bufferedFrames") == 0 && counter_u64(&c, "upFramesShaped") - counter_u64(&before, "upFramesShaped") >= n as u64
        });
        let drain_ms = t0.elapsed().as_millis() as u64;
        let after = counters(&get(""));
        let d_frames = delta_u64(&before, &after, "upFramesShaped");
        let d_bytes = delta_u64(&before, &after, "upBytesShaped");
        let throughput_bps = if drain_ms > 0 {
            (d_bytes.max(0) as f64 * 8.0) / (drain_ms as f64 / 1000.0)
        } else {
            0.0
        };
        println!(
            "ITEM2 preset(enabled rateBps=25000): frames={n} send_ms={send_ms} accepted_ms={accepted_ms} \
             drained={drained} drain_ms={drain_ms} peak_bufferedFrames={peak_frames} \
             peak_bufferedBytes={peak_bytes} upFramesShaped_delta={d_frames} \
             upBytesShaped_delta={d_bytes} lossDropped_delta={} bufferDropped_delta={} \
             effective_bytes_per_sec={:.1}",
            delta_u64(&before, &after, "lossDropped"),
            delta_u64(&before, &after, "bufferDropped"),
            throughput_bps / 8.0,
        );
        assert!(drained, "the paced heap must fully drain");
        assert_eq!(d_frames, n as i64, "every frame must be shaped");
        assert!(drain_ms > 700, "a 25000 B/s uplink must be materially slower than the disabled baseline; drain_ms={drain_ms}");
        assert!(peak_frames > 0, "the preset must actually buffer frames");

        // --- recovery: hot-disable must release the pending heap < 250 ms ---
        let park = serde_json::json!({
            "enabled": true, "seed": 0xF3F3,
            "uplink": {"rateBps": 0, "delayMs": 60000, "lossPct": 0.0, "lossModel": "none"},
            "downlink": {"rateBps": 0, "delayMs": 0}
        });
        let _ = get(&park.to_string());
        let _ = send_datagrams(&peer, &frame, 8);
        assert!(
            poll_until(Duration::from_secs(3), || {
                counter_u64(&counters(&get("")), "bufferedFrames") >= 1
            }),
            "frames must park behind the 60 s delay"
        );
        let parked = counter_u64(&counters(&get("")), "bufferedFrames");
        let t0 = Instant::now();
        let off = get(&serde_json::json!({"enabled": false}).to_string());
        assert_eq!(off["applied"], false);
        let released = poll_until(Duration::from_secs(3), || {
            counter_u64(&counters(&get("")), "bufferedFrames") == 0
        });
        let release_ms = t0.elapsed().as_millis() as u64;
        println!(
            "ITEM2 recovery(hot-disable): parked_frames={parked} released={released} release_ms={release_ms}"
        );
        assert!(released, "hot-disable must release the pending frames");
        assert!(
            release_ms < 250,
            "pending frames must be released < 250 ms after hot-disable (got {release_ms} ms)"
        );
    }

    // =====================================================================
    // ITEM 3 — IPv6 (and IPv4 control) exempt from loss under 100% loss
    // =====================================================================
    // A fresh loop isolates this item from item 2's scheduler carry-over.
    let _ = call(call_fn, free_fn, inst, "core.stop", &[]);
    {
        let (new_loop, new_peer) = boot_datapath(call_fn, free_fn, inst);
        peer = new_peer;
        loop_end = new_loop;
    }
    println!("--- ITEM 3: ICMPv6/NDP, IPv6 pure-ACK, IPv6-fragment exempt from loss (live path) ---");
    {
        let lossy = serde_json::json!({
            "enabled": true, "seed": 0xF3F3,
            "uplink": {"rateBps": 0, "delayMs": 0, "lossPct": 100.0, "lossModel": "random"},
            "downlink": {"rateBps": 0, "delayMs": 0}
        });
        let applied = get(&lossy.to_string());
        assert_eq!(applied["applied"], true);
        let before = counters(&applied);

        let droppable = paced_frame(1500);
        let exempt: Vec<(&str, Vec<u8>)> = vec![
            ("ipv4_icmp", ipv4_icmp_frame()),
            ("ipv6_icmp6_ndp_ra", ipv6_icmp6_ndp_ra_frame()),
            ("ipv6_tcp_pure_ack", ipv6_tcp_pure_ack_frame()),
            ("ipv6_fragment", ipv6_fragment_frame()),
        ];

        // 8 non-exempt frames: every one must be lost.
        let _ = send_datagrams(&peer, &droppable, 8);
        assert!(
            poll_until(Duration::from_secs(3), || {
                delta_u64(&before, &counters(&get("")), "lossDropped") >= 8
            }),
            "non-exempt frames must be dropped under lossPct=100"
        );

        // One copy of each exempt frame: every one must be forwarded (shaped).
        // A dropped non-exempt frame is never shaped, so `upFramesShaped` grows
        // by exactly the number of exempt frames sent so far.
        for (i, (name, f)) in exempt.iter().enumerate() {
            let _ = send_datagrams(&peer, f, 1);
            let expected = i as i64 + 1;
            assert!(
                poll_until(Duration::from_secs(3), || {
                    delta_u64(&before, &counters(&get("")), "upFramesShaped") >= expected
                }),
                "exempt frame `{name}` was not forwarded under lossPct=100"
            );
        }
        let _ = poll_until(Duration::from_secs(1), || {
            counter_u64(&counters(&get("")), "bufferedFrames") == 0
        });
        let after = counters(&get(""));
        let d_shaped = delta_u64(&before, &after, "upFramesShaped");
        let d_loss = delta_u64(&before, &after, "lossDropped");
        let d_shaped_bytes = delta_u64(&before, &after, "upBytesShaped");
        println!(
            "ITEM3 lossPct=100: non_exempt_sent=8 exempt_sent={} upFramesShaped_delta={d_shaped} \
             upBytesShaped_delta={d_shaped_bytes} lossDropped_delta={d_loss} counters={after}",
            exempt.len(),
        );
        assert_eq!(
            d_loss, 8,
            "exactly the 8 non-exempt frames may be lost; exempt frames must not be"
        );
        assert_eq!(
            d_shaped,
            exempt.len() as i64,
            "every exempt frame must still be forwarded (shaped) despite 100% loss"
        );
    }

    // =====================================================================
    // ITEM 5 — 2 MiB BDP bound at high rate + high delay (frame & byte caps)
    // =====================================================================
    let _ = call(call_fn, free_fn, inst, "core.stop", &[]);
    {
        let (new_loop, new_peer) = boot_datapath(call_fn, free_fn, inst);
        peer = new_peer;
        loop_end = new_loop;
    }
    println!("--- ITEM 5: 2 MiB / 512-frame release-heap bound with drop-newest (live path) ---");
    {
        let high = serde_json::json!({
            "enabled": true, "seed": 0xF3F3,
            "uplink": {"rateBps": 1000000000, "delayMs": 60000, "burstBytes": 65535,
                       "lossPct": 0.0, "lossModel": "none"},
            "downlink": {"rateBps": 0, "delayMs": 0}
        });

        // --- 5a: small frames saturate the 512-frame cap -------------------
        let applied = get(&high.to_string());
        assert_eq!(applied["applied"], true);
        let before = counters(&applied);
        let small = paced_frame(1500);
        let _ = send_datagrams(&peer, &small, 700);
        let settle = |tracked: &mut (u64, u64)| {
            let d = get("");
            let c = counters(&d);
            let f = counter_u64(&c, "bufferedFrames");
            let b = counter_u64(&c, "bufferedBytes");
            tracked.0 = tracked.0.max(f);
            tracked.1 = tracked.1.max(b);
        };
        let mut peak_small = (0u64, 0u64);
        let _ = poll_until(Duration::from_secs(5), || {
            settle(&mut peak_small);
            counter_u64(&counters(&get("")), "bufferDropped") - counter_u64(&before, "bufferDropped") > 0
        });
        std::thread::sleep(Duration::from_millis(200));
        settle(&mut peak_small);
        let after_small = counters(&get(""));
        let small_occ_frames = counter_u64(&after_small, "bufferedFrames");
        let small_occ_bytes = counter_u64(&after_small, "bufferedBytes");
        let small_dropped = delta_u64(&before, &after_small, "bufferDropped");
        println!(
            "ITEM5a frame-cap: sent=700 frame_len=1500 bufferedFrames={small_occ_frames} \
             bufferedBytes={small_occ_bytes} peak_bufferedFrames={} peak_bufferedBytes={} \
             bufferDropped_delta={small_dropped} MAX_FRAMES={MAX_FRAMES}",
            peak_small.0, peak_small.1
        );
        assert!(small_occ_frames <= MAX_FRAMES as u64, "frame cap must hold");
        assert_eq!(small_occ_frames, MAX_FRAMES as u64, "512-frame cap must saturate");
        assert!(small_occ_bytes <= BUFFER_BYTES_PER_DIRECTION as u64);
        assert!(small_dropped > 0, "drop-newest must fire once the frame cap is reached");
        // drain + reset the watermark path
        let _ = get(&serde_json::json!({"enabled": false}).to_string());
        assert!(
            poll_until(Duration::from_secs(5), || counter_u64(
                &counters(&get("")),
                "bufferedFrames"
            ) == 0),
            "heap must drain after hot-disable"
        );

        // --- 5b: large frames saturate the 2 MiB byte cap before 512 frames ---
        let applied = get(&high.to_string());
        assert_eq!(applied["applied"], true);
        let before = counters(&applied);
        let big = paced_frame(8000);
        let _ = send_datagrams(&peer, &big, 700);
        let mut peak_big = (0u64, 0u64);
        let _ = poll_until(Duration::from_secs(5), || {
            settle(&mut peak_big);
            counter_u64(&counters(&get("")), "bufferDropped") - counter_u64(&before, "bufferDropped") > 0
        });
        std::thread::sleep(Duration::from_millis(200));
        settle(&mut peak_big);
        let after_big = counters(&get(""));
        let big_occ_frames = counter_u64(&after_big, "bufferedFrames");
        let big_occ_bytes = counter_u64(&after_big, "bufferedBytes");
        let big_dropped = delta_u64(&before, &after_big, "bufferDropped");
        println!(
            "ITEM5b byte-cap: sent=700 frame_len=8000 bufferedFrames={big_occ_frames} \
             bufferedBytes={big_occ_bytes} peak_bufferedFrames={} peak_bufferedBytes={} \
             bufferDropped_delta={big_dropped} BUFFER_BYTES_PER_DIRECTION={BUFFER_BYTES_PER_DIRECTION}",
            peak_big.0, peak_big.1
        );
        assert!(
            big_occ_bytes <= BUFFER_BYTES_PER_DIRECTION as u64,
            "2 MiB byte cap must hold"
        );
        assert!(
            big_occ_frames < MAX_FRAMES as u64,
            "the 2 MiB byte cap must bind before the 512-frame cap for 8000 B frames \
             (got {big_occ_frames} frames)"
        );
        assert!(
            big_occ_bytes > BUFFER_BYTES_PER_DIRECTION as u64 - 8000,
            "the byte cap must be saturated (got {big_occ_bytes} bytes)"
        );
        assert!(big_dropped > 0, "drop-newest must fire once the byte cap is reached");

        let _ = get(&serde_json::json!({"enabled": false}).to_string());
        assert!(
            poll_until(Duration::from_secs(5), || counter_u64(
                &counters(&get("")),
                "bufferedFrames"
            ) == 0),
            "heap must drain after hot-disable"
        );
    }

    // ---- teardown / cleanup receipt ----------------------------------------
    let _ = apply_disabled();
    let _ = call(call_fn, free_fn, inst, "core.stop", &[]);
    assert_eq!(destroy(inst), ABI_OK, "destroy");
    if let Some(s) = shutdown {
        let _ = s();
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert!(!dir.exists(), "temp dir removed");
    drop(peer);
    drop(loop_end);
    println!("CLEANUP temp_dir_removed={} events_captured={}", !dir.exists(), EVENTS.lock().unwrap().len());
    println!("=== F3 weak-network shaper QA complete ===");
}
