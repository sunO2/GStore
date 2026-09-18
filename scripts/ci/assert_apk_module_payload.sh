#!/usr/bin/env bash
# 确定性断言：完整包 / 精简包 APK 内可下载模块 .so 的取舍。
#
# 背景：CI 同一次运行产出两类 APK——
#   完整包 GStore-<abi>-release.apk      内置全部可下载模块 .so（离线可用）
#   精简包 GStore-slim-<abi>-release.apk 排除 libgstore_mod_*.so（仅保留 libgstore_host.so），
#                                        运行时经远程下载→校验→安装→挂载。
# 本脚本用 `unzip -l` 直接检查 APK 载荷，杜绝「Gradle exclude 未生效 / 误删 host」
# 之类的静默回归。
#
# 断言（顺序固定，保证输出确定）：
#   完整包：同一 <abi> 下必须列出 lib/<abi>/libgstore_host.so
#           且列出 4 个 lib/<abi>/libgstore_mod_<name>.so
#           （name ∈ qr analyzer repo download）
#   精简包：同一 <abi> 下必须列出 lib/<abi>/libgstore_host.so
#           且**不得**列出任何 lib/<abi>/libgstore_mod_*.so
#
# 用法：
#   scripts/ci/assert_apk_module_payload.sh <apk-dir>
#     apk-dir  含 GStore-<abi>-release.apk 与 GStore-slim-<abi>-release.apk 的目录
#              （CI 中为重命名后的暂存目录；测试时可传 fixture 目录）。
#
# 退出码：
#   0  全部断言通过
#   1  任一 APK 缺失 / 非 zip / 载荷不符
#   2  用法错误或目录不存在
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <apk-dir>" >&2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  echo "ERROR: 需要且仅需要 1 个参数（APK 目录）" >&2
  usage
  exit 2
fi

APK_DIR="$1"
if [ ! -d "$APK_DIR" ]; then
  echo "ERROR: APK 目录不存在: $APK_DIR" >&2
  exit 2
fi

# 顺序固定，保证输出/判定确定。
ABIS=(arm64-v8a armeabi-v7a x86_64)
MODULES=(qr analyzer repo download)

failures=0
checked=0

# 打印 APK 的条目列表；非 zip / 读取失败返回非零。
apk_listing() {
  unzip -l "$1" 2>/dev/null
}

# 断言单个 ABI/变体的载荷。参数：<label> <apk> <abi> <full|slim>
check_apk() {
  local label="$1" apk="$2" abi="$3" kind="$4"
  local listing

  if [ ! -f "$apk" ]; then
    echo "FAIL  : [$label] 缺少 APK: $apk" >&2
    failures=$((failures + 1))
    return
  fi
  if ! listing="$(apk_listing "$apk")"; then
    echo "FAIL  : [$label] 不是有效 zip/APK: $apk" >&2
    failures=$((failures + 1))
    return
  fi

  local ok=1
  local host_entry="lib/${abi}/libgstore_host.so"

  if ! printf '%s\n' "$listing" | grep -qF "$host_entry"; then
    echo "FAIL  : [$label] 缺少 FFI 宿主: $host_entry" >&2
    ok=0
  fi

  if [ "$kind" = "full" ]; then
    local module
    for module in "${MODULES[@]}"; do
      local entry="lib/${abi}/libgstore_mod_${module}.so"
      if ! printf '%s\n' "$listing" | grep -qF "$entry"; then
        echo "FAIL  : [$label] 缺少内置模块: $entry" >&2
        ok=0
      fi
    done
  else
    if printf '%s\n' "$listing" | grep -Eq 'lib/[^/]+/libgstore_mod_[^/]+\.so'; then
      echo "FAIL  : [$label] 精简包不得包含任何模块 .so:" >&2
      printf '%s\n' "$listing" | grep -E 'lib/[^/]+/libgstore_mod_[^/]+\.so' >&2 || true
      ok=0
    fi
  fi

  checked=$((checked + 1))
  if [ "$ok" -eq 1 ]; then
    echo "OK    : [$label] $apk"
  else
    failures=$((failures + 1))
  fi
}

for abi in "${ABIS[@]}"; do
  check_apk "full/$abi" "$APK_DIR/GStore-${abi}-release.apk" "$abi" full
  check_apk "slim/$abi" "$APK_DIR/GStore-slim-${abi}-release.apk" "$abi" slim
done

if [ "$failures" -gt 0 ]; then
  {
    echo "FAIL: APK 载荷断言失败（检查 $checked 个，问题 $failures 个）"
    echo "      目录: $APK_DIR"
  } >&2
  exit 1
fi

echo "PASS: $checked 个 APK 载荷断言全部通过（完整包含模块 .so，精简仅 host；目录: $APK_DIR）"
