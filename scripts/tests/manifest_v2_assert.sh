#!/usr/bin/env bash
# 确定性断言：generate_modules_manifest.sh 产出的 Flat 清单 v2 + 内置清单。
#
# 全程在临时目录内产出（通过环境变量覆盖输出路径），绝不写仓库 assets/。
# 退出 0 表示全部通过；非零并在 stderr 给出清晰原因表示失败。
#
# 负向控制（用于验证断言确实会失败）：
#   FIXTURE_ABIS="arm64-v8a armeabi-v7a x86_64" bash scripts/tests/manifest_v2_assert.sh
#   → 缺 x86 目录，断言应为非零退出。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="$REPO_ROOT/generate_modules_manifest.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gstore_manifest_assert.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

EXPECTED_ABIS=(arm64-v8a armeabi-v7a x86 x86_64)
# 默认全部 ABI；可用 FIXTURE_ABIS 只造部分 ABI 做负向控制。
FIXTURE_ABIS="${FIXTURE_ABIS:-arm64-v8a armeabi-v7a x86 x86_64}"

MODULE_DIR="$TMP_DIR/release-modules"
OUT_DIR="$TMP_DIR/out"
mkdir -p "$OUT_DIR"

make_module() { # name version
  local name="$1" version="$2"
  mkdir -p "$TMP_DIR/gstore_mod_$name"
  printf 'version = "%s"\n' "$version" > "$TMP_DIR/gstore_mod_$name/Cargo.toml"
  local abi
  for abi in $FIXTURE_ABIS; do
    mkdir -p "$MODULE_DIR/$abi"
    printf '%s:%s:placeholder\n' "$name" "$abi" \
      > "$MODULE_DIR/$abi/libgstore_mod_$name.so"
  done
}

# qr: 带 +build 元数据 → 资产版本应为 1.2.3
make_module qr "1.2.3+7"
# repo: 4 段版本 → 截断为 2.0.1
make_module repo "2.0.1.9"
# 零字节 .so → 必须被跳过，不得进入清单
if [ -d "$MODULE_DIR/x86" ]; then
  : > "$MODULE_DIR/x86/libgstore_mod_zero.so"
fi

MODULES_MANIFEST_OUT="$OUT_DIR/modules.json" \
BUILTIN_MANIFEST_OUT="$OUT_DIR/modules_builtin.json" \
BUNDLED_MANIFEST_OUT="$OUT_DIR/modules_bundled.json" \
BUILTIN_MODULE_DIR="$MODULE_DIR" \
  bash "$GEN" "$MODULE_DIR"

echo "[manifest_v2_assert] 校验 v2 / 内置清单..."
python3 - "$OUT_DIR/modules.json" "$OUT_DIR/modules_builtin.json" "$MODULE_DIR" \
  "${EXPECTED_ABIS[*]}" \
  '{"qr":{"orig":"1.2.3+7","sanitized":"1.2.3"},"repo":{"orig":"2.0.1.9","sanitized":"2.0.1"}}' << 'PY'
import hashlib
import json
import os
import re
import sys

manifest_path, builtin_path, module_dir = sys.argv[1], sys.argv[2], sys.argv[3]
expected_abis = sys.argv[4].split()
spec = json.loads(sys.argv[5])

fail = []


def check(cond, msg):
    if not cond:
        fail.append(msg)


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:  # noqa: BLE001
        check(False, f"{path}: 非法 JSON: {e}")
        return None


manifest = load_json(manifest_path)
builtin = load_json(builtin_path)

if manifest is not None:
    check(manifest.get("version") == 2,
          f"manifest.version != 2: {manifest.get('version')}")
    mods = manifest.get("modules") or {}
    assets = []
    for name, spec_v in spec.items():
        entry = mods.get(name)
        check(entry is not None, f"清单缺模块 {name}")
        if entry is None:
            continue
        check(entry.get("version") == spec_v["orig"],
              f"{name}: version 应为原始值 {spec_v['orig']}，实际 {entry.get('version')}")
        check(isinstance(entry.get("min_host_abi"), str) and entry["min_host_abi"],
              f"{name}: min_host_abi 缺失/为空")
        abi_map = entry.get("abi") or {}
        for abi in expected_abis:
            a = abi_map.get(abi)
            check(a is not None, f"{name}: 清单缺 ABI {abi}")
            if not a:
                continue
            asset = a.get("asset", "")
            expected_asset = f"libgstore_mod_{name}_{spec_v['sanitized']}-{abi}.so"
            check(asset == expected_asset,
                  f"{name}/{abi}: asset 应为 {expected_asset}，实际 {asset}")
            check(asset.endswith(f"-{abi}.so"),
                  f"{name}/{abi}: asset 未以 -{abi}.so 结尾: {asset}")
            check("+" not in asset, f"{name}/{abi}: asset 含 + 元数据: {asset}")
            m = re.search(r"_(\d+\.\d+\.\d+)-[^/]+\.so$", asset)
            check(bool(m and m.group(1) == spec_v["sanitized"]),
                  f"{name}/{abi}: asset 版本非三段数字或值不符: {asset}")
            assets.append(asset)
            so_path = os.path.join(module_dir, abi, f"libgstore_mod_{name}.so")
            data = open(so_path, "rb").read()
            check(a.get("sha256") == hashlib.sha256(data).hexdigest(),
                  f"{name}/{abi}: sha256 与占位文件字节不符")
            check(a.get("size") == len(data),
                  f"{name}/{abi}: size 不符 ({a.get('size')} != {len(data)})")
    check(len(assets) == len(set(assets)), f"asset 不唯一: {sorted(assets)}")
    check("zero" not in mods, "零字节 .so 不应进入清单")

if builtin is not None:
    for name, spec_v in spec.items():
        b = builtin.get(name)
        check(b is not None, f"modules_builtin 缺模块 {name}")
        if b is None:
            continue
        check(b.get("version") == spec_v["orig"],
              f"builtin/{name}: version 应为 {spec_v['orig']}，实际 {b.get('version')}")
        b_abi = b.get("abi") or {}
        for abi in expected_abis:
            check(b_abi.get(abi) == spec_v["orig"],
                  f"builtin/{name}/{abi}: 应为 {spec_v['orig']}，实际 {b_abi.get(abi)}")

if fail:
    print("[manifest_v2_assert] FAIL:", file=sys.stderr)
    for f in fail:
        print("  - " + f, file=sys.stderr)
    sys.exit(1)

print(f"[manifest_v2_assert] [ok] {len(spec)} 个模块、{len(assets)} 个资产、内置清单均通过")
PY

# 随包副本必须与发布清单逐字节一致（同一序列化结果落盘，禁止二次序列化）。
cmp "$OUT_DIR/modules.json" "$OUT_DIR/modules_bundled.json"
echo "[manifest_v2_assert] [ok] 随包 modules.json 副本与发布清单逐字节一致"

# 确定性：同一输入重复生成必须字节一致。
cp "$OUT_DIR/modules.json" "$TMP_DIR/modules.first.json"
cp "$OUT_DIR/modules_builtin.json" "$TMP_DIR/builtin.first.json"
cp "$OUT_DIR/modules_bundled.json" "$TMP_DIR/bundled.first.json"
MODULES_MANIFEST_OUT="$OUT_DIR/modules.json" \
BUILTIN_MANIFEST_OUT="$OUT_DIR/modules_builtin.json" \
BUNDLED_MANIFEST_OUT="$OUT_DIR/modules_bundled.json" \
BUILTIN_MODULE_DIR="$MODULE_DIR" \
  bash "$GEN" "$MODULE_DIR" >/dev/null 2>&1
diff -q "$TMP_DIR/modules.first.json" "$OUT_DIR/modules.json" >/dev/null
diff -q "$TMP_DIR/builtin.first.json" "$OUT_DIR/modules_builtin.json" >/dev/null
diff -q "$TMP_DIR/bundled.first.json" "$OUT_DIR/modules_bundled.json" >/dev/null
echo "[manifest_v2_assert] [ok] 重复生成字节一致（确定性）"

echo "manifest_v2_assert: PASS"
