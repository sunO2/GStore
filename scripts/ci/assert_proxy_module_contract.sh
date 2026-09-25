#!/usr/bin/env bash
# Anti-regression guard: the shipped proxy modules must have been built from the
# CURRENT frozen contract sources.
#
# `android/app/src/main/jniLibs/<abi>/libgstore_mod_proxy.so` are prebuilt
# binaries committed to the repo and packaged into the APK. They are produced
# by a separate Android cross-compile, so a Rust contract change silently ships
# a stale module unless somebody remembers to rebuild. That is exactly the B1
# defect: `CaptureConfig` gained `appScope` while the packaged `.so` still
# predated it, so the app got `422 PROXY_CAPTURE_CONFIG_INVALID: unknown field
# 'appScope'`.
#
# Mechanism (fully automatic, no version to remember):
#   * rust/gstore_mod_proxy/build.rs hashes `src/lib.rs` + `src/capture.rs` +
#     `API.md` with FNV-1a 64 and injects `GS_PROXY_CONTRACT_FP`.
#   * `src/capture.rs` embeds `GS_PROXY_CONTRACT_FP=<hex>` as a `#[used]`
#     `#[no_mangle]` literal, so the digest lands verbatim in each `.so`.
#   * This script recomputes the SAME digest over the SAME files (byte-for-byte;
#     keep the FNV-1a implementation identical to build.rs) and requires every
#     shipped ABI's embedded marker to equal it. Missing or mismatched marker =>
#     the shipped binary is stale => non-zero exit, naming the ABI.
#
# Usage:
#   scripts/ci/assert_proxy_module_contract.sh [jniLibs-dir]
#
# Exit codes:
#   0  every shipped ABI embeds the current contract fingerprint
#   1  a shipped ABI is missing its marker or carries a stale fingerprint
#   2  usage error / contract source missing / python3 unavailable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODULE="gstore_mod_proxy"
ABIS=(arm64-v8a armeabi-v7a x86 x86_64)
# Contract sources, concatenated in exactly this order (must match build.rs).
CONTRACT_SOURCES=(
  "rust/gstore_mod_proxy/src/lib.rs"
  "rust/gstore_mod_proxy/src/capture.rs"
  "rust/gstore_mod_proxy/API.md"
)
MARKER_PREFIX="GS_PROXY_CONTRACT_FP="

usage() {
  echo "usage: $(basename "$0") [jniLibs-dir]" >&2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

JNILIBS_DIR="${1:-${GSTORE_PROXY_JNILIBS_DIR:-$REPO_ROOT/android/app/src/main/jniLibs}}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 不可用，无法重算合约指纹" >&2
  exit 2
fi

for rel in "${CONTRACT_SOURCES[@]}"; do
  if [ ! -f "$REPO_ROOT/$rel" ]; then
    echo "ERROR: 合约源文件缺失: $REPO_ROOT/$rel" >&2
    exit 2
  fi
done

# Recompute FNV-1a 64 over the concatenated raw bytes of the contract sources.
EXPECTED="$(python3 - "$REPO_ROOT" "${CONTRACT_SOURCES[@]}" <<'PY'
import sys

root = sys.argv[1]
files = sys.argv[2:]
h = 0xCBF29CE484222325
for rel in files:
    with open(root + "/" + rel, "rb") as fh:
        for byte in fh.read():
            h ^= byte
            h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
sys.stdout.write(f"{h:016x}")
PY
)"

echo "== proxy module contract fingerprint guard =="
echo "   sources: ${CONTRACT_SOURCES[*]}"
echo "   expected: ${MARKER_PREFIX}${EXPECTED}"

failures=0
fail() {
  echo "FAIL  : $*" >&2
  echo "::error::$*"
}

for abi in "${ABIS[@]}"; do
  so="$JNILIBS_DIR/$abi/lib${MODULE}.so"
  if [ ! -s "$so" ]; then
    fail "[$abi] 随包模块缺失或为零字节: $so（期望指纹 ${MARKER_PREFIX}${EXPECTED}）"
    failures=$((failures + 1))
    continue
  fi

  found="$(grep -aoE "${MARKER_PREFIX}[0-9a-f]{16}" "$so" | head -n1 || true)"
  if [ -z "$found" ]; then
    fail "[$abi] 随包模块不含合约指纹（陈旧产物 / 未由当前源码构建）：$so"
    echo "       expected: ${MARKER_PREFIX}${EXPECTED}" >&2
    echo "       found   : <none>" >&2
    failures=$((failures + 1))
    continue
  fi
  if [ "$found" != "${MARKER_PREFIX}${EXPECTED}" ]; then
    fail "[$abi] 随包模块合约指纹不一致（陈旧随包模块）：$so"
    echo "       expected: ${MARKER_PREFIX}${EXPECTED}" >&2
    echo "       found   : $found" >&2
    failures=$((failures + 1))
    continue
  fi

  echo "OK    : [$abi] $found"
done

if [ "$failures" -gt 0 ]; then
  {
    echo "FAIL: proxy 合约指纹守卫失败（陈旧 ABI 数: $failures）"
    echo "      请重跑 ./build_android_rust.sh --module ${MODULE} 并更新随包 .so"
  } >&2
  exit 1
fi

echo "PASS: 4 ABI 随包模块均由当前合约源码构建（指纹 ${MARKER_PREFIX}${EXPECTED}）"
