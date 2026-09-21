#!/usr/bin/env bash
# Todo 27 local benchmark harness (host, debug build; relative comparison only).
#
# Usage: rust/gstore_mod_proxy/bench/run.sh [frames]
#   frames  data-plane frames to push (default 20000)
#
# Prints one `GSTORE_BENCH <name> ...` line per benchmark (grep-friendly).
# Does not run as part of `cargo test` gates (both benches are #[ignore]).
set -uo pipefail

cd "$(dirname "$0")/.."
frames="${1:-20000}"

echo "# gstore_mod_proxy local benchmark"
echo "# date=$(date -u +%FT%TZ) rustc=$(rustc --version 2>/dev/null | awk '{print $2}') frames=$frames"

GSTORE_BENCH_FRAMES="$frames" cargo test -p gstore_mod_proxy bench_ -- \
  --ignored --nocapture --test-threads=1 2>&1 | grep -E "GSTORE_BENCH" || true
