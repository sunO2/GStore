#!/usr/bin/env bash
# 从 gstore_contract 的 Rust ABI 定义生成 C 头文件。
#
# 用法：
#   scripts/dev/generate_c_header.sh                 # 写入 test/c_abi/gstore_platform.h
#   scripts/dev/generate_c_header.sh /abs/out.h      # 写入指定路径（漂移校验用）
#
# 可从任意 cwd 调用；仓库根目录由脚本自身位置推导。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

CRATE_DIR="$REPO_ROOT/rust/gstore_contract"
CONFIG="$CRATE_DIR/cbindgen.toml"
OUT="${1:-$REPO_ROOT/test/c_abi/gstore_platform.h}"

if ! command -v cbindgen >/dev/null 2>&1; then
  echo "error: cbindgen not found in PATH (需要 cbindgen 0.29.x)" >&2
  exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "error: cbindgen config not found: $CONFIG" >&2
  exit 1
fi

mkdir -p "$(dirname -- "$OUT")"

# cbindgen 的 positional 参数是 crate 目录；--config 用绝对路径，
# 因此不依赖调用者的 cwd。
cbindgen "$CRATE_DIR" --config "$CONFIG" --output "$OUT" --quiet

echo "generated: $OUT"
