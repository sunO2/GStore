#!/usr/bin/env bash
# 一键构建全部 Rust crate（contract → host → 三个模块）。
#
# 为什么不是一个 Cargo workspace：
#   host 必须 panic=abort（避免 unwind 越过 FRB/FFI 边界），模块必须 panic=unwind
#   （边界 catch_unwind 隔离模块 panic）。Cargo 不允许在 [profile.*.package.*] 覆盖
#   panic（"panic may not be specified in a package profile"），故无法用单一 workspace
#   表达混合 panic 策略 —— 各 crate 保持独立，由本脚本统一编排。
#
# 用法：
#   rust/build_all.sh            # 构建全部 crate（debug，供本地测试）
#   rust/build_all.sh --release  # release 构建
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-}"
CARGO_ARGS=()
if [ "$PROFILE" = "--release" ]; then
    CARGO_ARGS+=(--release)
fi

CRATES=(
  "gstore_contract"
  # Wave 5 leaf crate: member of the rust/ workspace (see rust/Cargo.toml).
  "gstore_script"
  "gstore_core"
  "gstore_host"
  "gstore_mod_qr"
  "gstore_mod_analyzer"
  "gstore_mod_repo"
  "gstore_mod_download"
  "gstore_mod_perf"
)
# 本地只重建部分 crate：GSTORE_CRATES="gstore_core gstore_host"
if [ -n "${GSTORE_CRATES:-}" ]; then
    read -r -a CRATES <<<"$GSTORE_CRATES"
fi

# 各 crate 有独立 target，互不依赖构建顺序；并行可显著缩短本地/CI 全量构建。
BUILD_JOBS="${GSTORE_BUILD_JOBS:-}"
if [ -z "$BUILD_JOBS" ]; then
    if [ -n "${CI:-}" ]; then
        BUILD_JOBS=2
    else
        _ncpu="$(nproc 2>/dev/null || echo 4)"
        BUILD_JOBS=$(( _ncpu > 4 ? 4 : _ncpu ))
    fi
fi
if ! [[ "$BUILD_JOBS" =~ ^[0-9]+$ ]] || [ "$BUILD_JOBS" -lt 1 ]; then
    BUILD_JOBS=1
fi
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# 本地装了 sccache 就自动启用（CI 由 workflow 注入 RUSTC_WRAPPER）。
if [ -z "${RUSTC_WRAPPER:-}" ] && command -v sccache >/dev/null 2>&1; then
    export RUSTC_WRAPPER=sccache
    export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-10G}"
fi

FAILED=0
for ((i = 0; i < ${#CRATES[@]}; i += BUILD_JOBS)); do
    pids=()
    names=()
    for crate in "${CRATES[@]:i:BUILD_JOBS}"; do
        log="$LOG_DIR/$crate.log"
        (cd "$ROOT/$crate" && cargo build "${CARGO_ARGS[@]}") >"$log" 2>&1 &
        pids+=("$!")
        names+=("$crate")
    done
    for idx in "${!pids[@]}"; do
        status=0
        wait "${pids[$idx]}" || status=$?
        echo "==> building ${names[$idx]} ${PROFILE}"
        cat "$LOG_DIR/${names[$idx]}.log"
        if [ "$status" -ne 0 ]; then
            echo "ERROR: crate build failed: ${names[$idx]}" >&2
            FAILED=1
        fi
    done
done

if [ "$FAILED" -ne 0 ]; then
    echo "✗ some crates failed" >&2
    exit 1
fi
echo "✓ all crates built"
