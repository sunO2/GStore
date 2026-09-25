//! Build-time contract fingerprint for the shipped proxy module.
//!
//! The prebuilt `libgstore_mod_proxy.so` binaries are committed into the repo
//! (`android/app/src/main/jniLibs/<abi>/`) and packaged into the APK. They are
//! produced by a separate Android cross-compile (`./build_android_rust.sh
//! --module gstore_mod_proxy`), so a Rust contract change can silently ship a
//! stale module (exactly the B1 defect: `appScope` added to `CaptureConfig`
//! while the packaged `.so` predated it, causing
//! `422 PROXY_CAPTURE_CONFIG_INVALID: unknown field 'appScope'`).
//!
//! This build script hashes the frozen contract sources with **FNV-1a 64** and
//! injects the digest as the compile-time env `GS_PROXY_CONTRACT_FP`. The crate
//! embeds the same digest as a string literal (see `src/capture.rs`), so it
//! lands verbatim in the compiled `.so`.
//! `scripts/ci/assert_proxy_module_contract.sh` recomputes the same digest over
//! the same files and asserts every shipped ABI's embedded marker matches,
//! failing loudly on drift. **Keep the hashing byte-identical to that script.**

use std::path::PathBuf;

/// Contract sources whose bytes define the module's frozen contract. Order
/// matters: the bytes are concatenated in exactly this order.
/// The shell guard `scripts/ci/assert_proxy_module_contract.sh` MUST use the
/// same list and the same order.
///
/// `src/mitm.rs`, `src/dispatch.rs` and `src/limits.rs` are hashed too: the
/// D-wave fixes (fake-IP re-origination, per-stage timeouts, 32 in-flight /
/// 48 MiB budget) live there, and hashing only `lib.rs`/`capture.rs`/`API.md`
/// let a rebuilt-but-forgotten shipped module escape the guard (the B1
/// blind spot).
const CONTRACT_SOURCES: &[&str] = &[
    "src/lib.rs",
    "src/capture.rs",
    "src/mitm.rs",
    "src/dispatch.rs",
    "src/limits.rs",
    "API.md",
];

/// FNV-1a 64-bit hash over `bytes`.
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

fn main() {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let mut concat = Vec::new();

    for rel in CONTRACT_SOURCES {
        let path: PathBuf = PathBuf::from(manifest_dir).join(rel);
        // Only the concatenated bytes feed the digest; a missing contract source
        // is a hard build failure (the contract is not optional).
        let bytes = std::fs::read(&path)
            .unwrap_or_else(|e| panic!("build.rs: cannot read contract source {path:?}: {e}"));
        concat.extend_from_slice(&bytes);
        println!("cargo:rerun-if-changed={}", path.display());
    }

    let fp = fnv1a64(&concat);
    println!("cargo:rustc-env=GS_PROXY_CONTRACT_FP={fp:016x}");
}
