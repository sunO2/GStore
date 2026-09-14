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
  "gstore_host"
  "gstore_mod_qr"
  "gstore_mod_analyzer"
  "gstore_mod_repo"
)

for crate in "${CRATES[@]}"; do
    echo "==> building $crate ${PROFILE}"
    (cd "$ROOT/$crate" && cargo build "${CARGO_ARGS[@]}")
done

echo "✓ all crates built"
