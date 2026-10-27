#!/usr/bin/env bash
# C ABI 检查：
#   1. 重新生成头文件并与签入版本逐字节 diff（漂移 = 失败）；
#   2. 用严格 C99 编译 consumer 并运行（调用 vtable 的 free_buf）；
#   3. --inject-wrong-offset：故意注入错误偏移，断言编译必须失败。
#
# 用法：
#   scripts/dev/check_c_abi.sh
#   scripts/dev/check_c_abi.sh --inject-wrong-offset
#
# 可从任意 cwd 调用；仓库根目录由脚本自身位置推导。
#
# Windows 等价命令（仅文档，不在本脚本执行）：
#   cl.exe /nologo /std:c11 /W4 /WX /I test\c_abi test\c_abi\consumer.c /Fe:target\c_abi\consumer.exe
#   target\c_abi\consumer.exe
#   注入失败验证：
#   cl.exe /nologo /std:c11 /W4 /WX /DSPIKE_INJECT_WRONG_OFFSET /I test\c_abi test\c_abi\consumer.c /Fe:target\c_abi\consumer_bad.exe
#   clang-cl /nologo /std:c11 /W4 /WX /DSPIKE_INJECT_WRONG_OFFSET /I test\c_abi test\c_abi\consumer.c /Fe:target\c_abi\consumer_bad.exe
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

HEADER="$REPO_ROOT/test/c_abi/gstore_platform.h"
CONSUMER="$REPO_ROOT/test/c_abi/consumer.c"
INCLUDE_DIR="$REPO_ROOT/test/c_abi"
OUT_DIR="$REPO_ROOT/target/c_abi"
BIN="$OUT_DIR/consumer"
CC_BIN="${CC:-cc}"
CFLAGS=(-std=c99 -Wall -Wextra -Werror)

INJECT_WRONG_OFFSET=0
for arg in "$@"; do
  case "$arg" in
    --inject-wrong-offset) INJECT_WRONG_OFFSET=1 ;;
    *)
      echo "error: unknown argument: $arg" >&2
      echo "usage: $0 [--inject-wrong-offset]" >&2
      exit 2
      ;;
  esac
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gstore-c-abi.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "== regenerate header =="
"$SCRIPT_DIR/generate_c_header.sh" "$TMP_DIR/gstore_platform.h"

echo "== drift check: checked-in header vs regenerated =="
if diff -u "$HEADER" "$TMP_DIR/gstore_platform.h"; then
  echo "header drift check: OK (byte-identical)"
else
  echo "error: test/c_abi/gstore_platform.h 与 cbindgen 输出不一致（stale header）。" >&2
  echo "      请运行 scripts/dev/generate_c_header.sh 重新生成后再提交。" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

if [[ "$INJECT_WRONG_OFFSET" -eq 1 ]]; then
  echo "== deliberate-failure compile (-DSPIKE_INJECT_WRONG_OFFSET) =="
  set +e
  "$CC_BIN" "${CFLAGS[@]}" -DSPIKE_INJECT_WRONG_OFFSET -I "$INCLUDE_DIR" \
    "$CONSUMER" -o "$TMP_DIR/consumer_bad"
  bad_rc=$?
  set -e
  echo "deliberate compile exit code: $bad_rc"
  if [[ "$bad_rc" -eq 0 ]]; then
    echo "error: 注入错误偏移后编译竟然成功，编译期布局断言失效！" >&2
    exit 1
  fi
  echo "inject-wrong-offset: OK (wrong offset rejected with non-zero compiler exit)"
  exit 0
fi

echo "== compile consumer =="
"$CC_BIN" "${CFLAGS[@]}" -I "$INCLUDE_DIR" "$CONSUMER" -o "$BIN"
compile_rc=$?
echo "compile exit code: $compile_rc"

echo "== run consumer =="
set +e
"$BIN"
run_rc=$?
set -e
echo "run exit code: $run_rc"
if [[ "$run_rc" -ne 0 ]]; then
  echo "error: consumer 运行失败" >&2
  exit "$run_rc"
fi

echo "c_abi_check_ok"
