#!/usr/bin/env bash
# Deep deterministic assertion for the download-only `gstore_mod_proxy` module.
#
# The proxy module is distributed as a GitHub Release asset (consumed by
# ModuleBootstrap), NOT bundled in the full/slim APK (see
# rust/gstore_mod_proxy/API.md §6). scripts/ci/assert_module_artifacts.sh only
# proves "present and non-zero"; this script adds the packaging-safety checks
# that matter for a native module:
#
#   1. per-ABI .so present and non-zero
#   2. DT_NEEDED is Android-system-only (no libstdc++.so, no libgstore_*.so) -
#      a cross-module/host DT_NEEDED would silently couple module load order
#   3. every PT_LOAD is 16 KB aligned (p_align >= 0x4000) - Android 15+ 16 KB
#      page-size devices refuse to load 4 KB-only shared objects
#   4. stripped release: no .debug_* sections, but .dynsym + unwind
#      (.eh_frame or .ARM.exidx) retained so panic=unwind / catch_unwind works
#   5. modules.json carries a proxy entry for all four ABIs with asset names of
#      the standard form libgstore_mod_proxy_<x.y.z>-<abi>.so and sha256/size
#      matching the on-disk artifacts (the release-upload step relies on this)
#   6. assets/app/modules.json (bundled fallback copy) is byte-identical to the
#      release manifest; modules_builtin.json must NOT list proxy (download-only)
#
# Usage:
#   scripts/ci/assert_proxy_module_artifacts.sh [fixture-dir]
#
# Exit codes:
#   0  all deep assertions pass
#   1  any assertion failed
#   2  usage error / fixture dir or readelf unavailable
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
if [ ! -d "$FIXTURE_DIR" ]; then
  echo "ERROR: 产物目录不存在: $FIXTURE_DIR" >&2
  exit 2
fi

MODULE="gstore_mod_proxy"
NAME="proxy"
ABIS=(arm64-v8a armeabi-v7a x86 x86_64)
# Proxy may only depend on Android system libraries. Anything else (notably
# libstdc++.so, a host-only lib, or another gstore module) is unexpected.
ALLOWED_NEEDED=(libc.so libdl.so libm.so libc++_shared.so liblog.so libandroid.so libz.so)

resolve_readelf() {
  if command -v readelf >/dev/null 2>&1; then
    command -v readelf
    return 0
  fi
  if command -v llvm-readelf >/dev/null 2>&1; then
    command -v llvm-readelf
    return 0
  fi
  if [ -n "${GSTORE_NDK_PATH:-}" ]; then
    local cand
    cand="$(ls "$GSTORE_NDK_PATH"/toolchains/llvm/prebuilt/*/bin/llvm-readelf 2>/dev/null | head -n1 || true)"
    if [ -n "$cand" ]; then
      echo "$cand"
      return 0
    fi
  fi
  return 1
}

READELF="$(resolve_readelf || true)"
if [ -z "$READELF" ]; then
  echo "ERROR: readelf/llvm-readelf 不可用，无法做 DT_NEEDED/对齐断言" >&2
  exit 2
fi

failures=0
fail() {
  echo "FAIL  : $*" >&2
  echo "::error::$*"
}

is_allowed_needed() {
  local needle="$1" allowed
  for allowed in "${ALLOWED_NEEDED[@]}"; do
    [ "$needle" = "$allowed" ] && return 0
  done
  return 1
}

# readelf -d prints e.g. " 0x... (NEEDED)  Shared library: [libc.so]" (locale
# dependent label, so match on the [bracketed] soname only).
so_needed() {
  "$READELF" -d "$1" | grep -oE '\[[^]]+\.so[0-9.]*\]' | tr -d '[]' || true
}

# Returns every PT_LOAD p_align as a decimal integer (readelf -lW keeps the
# Align column on the LOAD line regardless of arch).
so_load_aligns() {
  "$READELF" -lW "$1" | awk '$1 == "LOAD" { print $NF }'
}

has_section() {
  "$READELF" -SW "$1" | grep -qE "[[:space:]]$2[[:space:]]"
}

echo "== deep proxy artifact assertions (readelf: $READELF) =="
echo "   dir: $FIXTURE_DIR"

for abi in "${ABIS[@]}"; do
  artifact="$FIXTURE_DIR/$abi/lib${MODULE}.so"
  label="proxy/$abi"

  if [ ! -s "$artifact" ]; then
    fail "[$label] 缺少或零字节产物: $artifact"
    failures=$((failures + 1))
    continue
  fi

  while IFS= read -r needed; do
    [ -n "$needed" ] || continue
    if ! is_allowed_needed "$needed"; then
      fail "[$label] 非预期 DT_NEEDED: $needed（允许: ${ALLOWED_NEEDED[*]}）"
      failures=$((failures + 1))
    fi
    if [[ "$needed" == libgstore_* ]]; then
      fail "[$label] 模块不得依赖宿主/其它模块: $needed"
      failures=$((failures + 1))
    fi
  done < <(so_needed "$artifact")

  if ! has_section "$artifact" '\.dynsym'; then
    fail "[$label] 缺少 .dynsym（C ABI 导出表被 strip 破坏了）"
    failures=$((failures + 1))
  fi
  if ! has_section "$artifact" '\.debug_info'; then
    : # expected: stripped, no debug info
  else
    fail "[$label] 含 .debug_info：release 产物不得带调试符号"
    failures=$((failures + 1))
  fi
  if ! has_section "$artifact" '\.eh_frame' && ! has_section "$artifact" '\.ARM.exidx'; then
    fail "[$label] 缺少 unwind 表（.eh_frame/.ARM.exidx）：panic=unwind 将无法展开"
    failures=$((failures + 1))
  fi

  saw_load=0
  while IFS= read -r align; do
    [ -n "$align" ] || continue
    saw_load=1
    if [ "$((align))" -lt 16384 ]; then
      fail "[$label] PT_LOAD p_align=$align < 0x4000（16 KB 对齐缺失）"
      failures=$((failures + 1))
    fi
  done < <(so_load_aligns "$artifact")
  if [ "$saw_load" -eq 0 ]; then
    fail "[$label] 未解析到任何 PT_LOAD（readelf 输出异常）"
    failures=$((failures + 1))
  fi

  echo "OK    : [$label] $(stat -c%s "$artifact") bytes, DT_NEEDED=[$(so_needed "$artifact" | tr '\n' ' ')]"
done

# ── manifest assertions ─────────────────────────────────────────────────────
MANIFEST="$FIXTURE_DIR/modules.json"
BUNDLED="$REPO_ROOT/assets/app/modules.json"
BUILTIN="$REPO_ROOT/assets/app/modules_builtin.json"

if [ ! -s "$MANIFEST" ]; then
  fail "缺少发布清单: $MANIFEST（先运行 ./generate_modules_manifest.sh）"
  failures=$((failures + 1))
else
  if ! python3 - "$MANIFEST" "$FIXTURE_DIR" "$NAME" "${ABIS[@]}" <<'PY'
import hashlib
import json
import os
import re
import sys

manifest_path, fixture_dir, name = sys.argv[1], sys.argv[2], sys.argv[3]
abis = sys.argv[4:]
manifest = json.load(open(manifest_path, encoding="utf-8"))
mod = manifest.get("modules", {}).get(name)
if mod is None:
    raise SystemExit(f"modules.json 缺少 '{name}' 条目")
if str(mod.get("min_host_abi", "")) != "3":
    raise SystemExit(f"{name}.min_host_abi={mod.get('min_host_abi')!r}，期望 '3'（ABI v3）")
entry_abis = mod.get("abi", {})
missing = [a for a in abis if a not in entry_abis]
if missing:
    raise SystemExit(f"{name} 缺少 ABI: {missing}")
asset_re = re.compile(rf"^libgstore_mod_{name}_\d+\.\d+\.\d+-({'|'.join(map(re.escape, abis))})\.so$")
for abi in abis:
    e = entry_abis[abi]
    asset = e.get("asset", "")
    if not asset_re.match(asset):
        raise SystemExit(f"{name}/{abi} 资产名不符合约定: {asset!r}")
    so = os.path.join(fixture_dir, abi, f"libgstore_mod_{name}.so")
    h = hashlib.sha256(open(so, "rb").read()).hexdigest()
    size = os.path.getsize(so)
    if e.get("sha256") != h:
        raise SystemExit(f"{name}/{abi} sha256 与产物不符: manifest={e.get('sha256')} actual={h}")
    if int(e.get("size", -1)) != size:
        raise SystemExit(f"{name}/{abi} size 与产物不符: manifest={e.get('size')} actual={size}")
print(f"OK    : modules.json '{name}' {len(abis)} ABIs, asset 命名+sha256+size 一致")
PY
  then
    fail "modules.json 中 '$NAME' 校验失败（见上方 python 错误）"
    failures=$((failures + 1))
  fi
fi

if [ -s "$BUNDLED" ] && [ -s "$MANIFEST" ]; then
  if cmp -s "$BUNDLED" "$MANIFEST"; then
    echo "OK    : 随包清单 assets/app/modules.json == 发布清单"
  else
    fail "随包清单与发布清单不一致: $BUNDLED != $MANIFEST"
    failures=$((failures + 1))
  fi
elif [ ! -e "$BUNDLED" ]; then
  echo "WARN  : 随包清单不存在（$BUNDLED），跳过 byte-equality（可能未执行 generate）"
fi

if [ -s "$BUILTIN" ]; then
  if python3 -c "import json,sys; sys.exit(0 if 'proxy' in json.load(open(sys.argv[1])).get('modules', {}) else 1)" "$BUILTIN" 2>/dev/null; then
    fail "download-only 模块不得进入 modules_builtin.json: $BUILTIN"
    failures=$((failures + 1))
  else
    echo "OK    : modules_builtin.json 不含 proxy（download-only）"
  fi
fi

if [ "$failures" -gt 0 ]; then
  {
    echo "FAIL: proxy 深度产物断言失败（问题 $failures 个）"
    echo "      目录: $FIXTURE_DIR"
  } >&2
  exit 1
fi

echo "PASS: proxy 深度产物断言全部通过（4 ABI + 清单 + 命名，目录: $FIXTURE_DIR）"
