#!/usr/bin/env bash
# 确定性断言：Rust 可下载模块（qr / analyzer / repo / download）的每个 ABI 产物
# 均存在且**非零字节**。
#
# 用途：CI 在 `build_android_rust.sh` 之后调用本脚本，任何缺失或零字节产物都会
# 让作业失败（不得静默通过）。LLM 模块（gstore_mod_llm）为可选、仅 arm64，**不在**
# 本脚本的断言范围内。
#
# 用法：
#   scripts/ci/assert_module_artifacts.sh [fixture-dir]
#     fixture-dir  含 `<abi>/lib<module>.so` 的产物根目录。
#                  缺省为 $GSTORE_MODULE_DIR，再回退到仓库 `rust/release-modules`。
#
# 退出码：
#   0  所有期望产物存在且非零字节
#   1  任一产物缺失 / 非普通文件 / 零字节
#   2  用法错误或 fixture 目录不存在
#
# 预期产物（4 模块 × 4 ABI = 16 个）：
#   <dir>/<abi>/libgstore_mod_<name>.so
#   abi   ∈ arm64-v8a armeabi-v7a x86 x86_64
#   name  ∈ qr analyzer repo download
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  echo "usage: $(basename "$0") [fixture-dir]" >&2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -gt 1 ]; then
  echo "ERROR: 参数过多（期望 0 或 1 个 fixture 目录）" >&2
  usage
  exit 2
fi

FIXTURE_DIR="${1:-${GSTORE_MODULE_DIR:-$REPO_ROOT/rust/release-modules}}"

# 顺序固定，保证输出/判定确定。
MODULES=(gstore_mod_qr gstore_mod_analyzer gstore_mod_repo gstore_mod_download)
ABIS=(arm64-v8a armeabi-v7a x86 x86_64)

if [ ! -d "$FIXTURE_DIR" ]; then
  echo "ERROR: 产物目录不存在: $FIXTURE_DIR" >&2
  exit 2
fi

total=0
missing=0
not_file=0
zero=0

for module in "${MODULES[@]}"; do
  for abi in "${ABIS[@]}"; do
    total=$((total + 1))
    artifact="$FIXTURE_DIR/$abi/lib${module}.so"

    if [ ! -e "$artifact" ]; then
      echo "MISSING   : $artifact" >&2
      missing=$((missing + 1))
      continue
    fi
    if [ ! -f "$artifact" ]; then
      echo "NOT_FILE  : $artifact（存在但不是普通文件）" >&2
      not_file=$((not_file + 1))
      continue
    fi

    # stat -c%s 在 Linux/GNU coreutils 上可用；无法读取时回退 wc -c。
    size="$(stat -c%s "$artifact" 2>/dev/null || wc -c < "$artifact")"
    if [ -z "$size" ] || [ "$size" -eq 0 ]; then
      echo "ZERO_BYTE : $artifact（0 字节）" >&2
      zero=$((zero + 1))
      continue
    fi

    echo "OK        : $artifact（${size} bytes）"
  done
done

failures=$((missing + not_file + zero))
if [ "$failures" -gt 0 ]; then
  {
    echo "FAIL: 期望 $total 个产物，问题总数 $failures"
    echo "      缺失=$missing 非普通文件=$not_file 零字节=$zero"
    echo "      目录: $FIXTURE_DIR"
  } >&2
  exit 1
fi

echo "PASS: $total 个产物全部存在且非零字节（目录: $FIXTURE_DIR）"
