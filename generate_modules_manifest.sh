#!/bin/bash
# 生成模块清单 v2 modules.json 与内置模块清单 modules_builtin.json
# （供发布端随 GitHub Release 分发 / 应用内置兜底）
#
# 用法：./generate_modules_manifest.sh [模块目录]
# 默认读取 rust/release-modules/（build_android_rust.sh 的输出）
#
# 输出：
#   <模块目录>/modules.json                    Flat 清单 v2（发布上传）
#   assets/app/modules_builtin.json            内置模块版本清单（随 APK 打包）
#
# 环境变量覆盖（便于测试在临时目录产出、绝不污染仓库 assets/）：
#   MODULES_IN_DIR         模块输入目录（等价于位置参数 $1）
#   MODULES_OUT_DIR        输出目录（同时作为下面两个默认值）
#   MODULES_MANIFEST_OUT   modules.json 完整路径（优先于 MODULES_OUT_DIR）
#   BUILTIN_MANIFEST_OUT   modules_builtin.json 完整路径（优先于 MODULES_OUT_DIR）
#   BUILTIN_MODULE_DIR     内置 .so 目录，默认 android/app/src/main/jniLibs
#   MIN_HOST_ABI           覆盖 min_host_abi（默认取 gstore_contract ABI 版本）
#
# 清单 v2 结构（Dart `ModuleManifestV2.fromJson` 消费）：
# {
#   "version": 2,
#   "modules": {
#     "qr": {
#       "version": "0.1.0",                 # 原始版本（保留 +build / pre-release）
#       "min_host_abi": "2",                # 宿主最低 ABI 版本
#       "abi": {
#         "arm64-v8a": {
#           "asset": "libgstore_mod_qr_0.1.0-arm64-v8a.so",
#           "sha256": "<hex>",
#           "size": <bytes>
#         }
#       }
#     }
#   }
# }
#
# 资产名规则：libgstore_mod_<name>_<sanitizedVersion>-<abi>.so
#   sanitizedVersion = 三段纯数字 major.minor.patch：
#     剥离 +build 与 -pre-release 元数据；不足三段补 0，超过三段截断。
# 本地落盘文件名仍由宿主决定（libgstore_mod_<name>_<major.minor.patch>.so），
# 清单中的 asset 是 Release 资产名，绝不复用本地文件名。
#
# 内置清单结构（顶层 key 即模块名）：
# {
#   "qr": { "version": "0.1.0", "abi": { "arm64-v8a": "0.1.0", ... } }
# }
# GPU 变体（_opencl/_vulkan/_cpu）不进入 Flat 清单，零字节 .so 跳过并告警。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="${1:-${MODULES_IN_DIR:-$SCRIPT_DIR/rust/release-modules}}"
BUILTIN_MODULE_DIR="${BUILTIN_MODULE_DIR:-$SCRIPT_DIR/android/app/src/main/jniLibs}"
MODULES_OUT_DIR="${MODULES_OUT_DIR:-}"

MODULES_MANIFEST_OUT="${MODULES_MANIFEST_OUT:-${MODULES_OUT_DIR:+$MODULES_OUT_DIR/modules.json}}"
MODULES_MANIFEST_OUT="${MODULES_MANIFEST_OUT:-$MODULE_DIR/modules.json}"
BUILTIN_MANIFEST_OUT="${BUILTIN_MANIFEST_OUT:-${MODULES_OUT_DIR:+$MODULES_OUT_DIR/modules_builtin.json}}"
BUILTIN_MANIFEST_OUT="${BUILTIN_MANIFEST_OUT:-$SCRIPT_DIR/assets/app/modules_builtin.json}"

if [ ! -d "$MODULE_DIR" ]; then
    echo "ERROR: module dir not found: $MODULE_DIR" >&2
    echo "先运行 ./build_android_rust.sh --module <name> 构建模块" >&2
    exit 1
fi

python3 - "$MODULE_DIR" "$MODULES_MANIFEST_OUT" "$BUILTIN_MODULE_DIR" \
    "$BUILTIN_MANIFEST_OUT" "$SCRIPT_DIR" "${MIN_HOST_ABI:-}" << 'PYEOF'
import hashlib
import json
import os
import re
import sys

(module_dir, manifest_path, builtin_dir, builtin_path, repo_root,
 min_abi_override) = sys.argv[1:7]

ABIS = ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"]
# GPU 变体后缀（Flat 清单不输出 variants）
VARIANT_SUFFIXES = ("_opencl", "_vulkan", "_cpu")
ASSET_RE = re.compile(r"^\d+\.\d+\.\d+$")


def sha256_size(path):
    h = hashlib.sha256()
    size = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size


def sanitize_version(raw):
    """三段纯数字 major.minor.patch（剥离 +build / -pre-release）。"""
    base = raw.split("+", 1)[0].split("-", 1)[0]
    nums = re.findall(r"\d+", base)[:3]
    while len(nums) < 3:
        nums.append("0")
    return ".".join(str(int(n)) for n in nums)


def module_version(module):
    """模块版本：优先模块目录相邻的 Cargo.toml，回退仓库 rust/。"""
    candidates = [
        os.path.join(module_dir, "..", f"gstore_mod_{module}", "Cargo.toml"),
        os.path.join(repo_root, "rust", f"gstore_mod_{module}", "Cargo.toml"),
    ]
    for cargo in candidates:
        if os.path.isfile(cargo):
            with open(cargo, encoding="utf-8") as f:
                for line in f:
                    m = re.match(r'^version\s*=\s*"([^"]+)"', line.strip())
                    if m:
                        return m.group(1)
    return "0.1.0"


def host_abi_version():
    if min_abi_override:
        return str(min_abi_override)
    abi_rs = os.path.join(repo_root, "rust", "gstore_contract", "src", "abi.rs")
    if os.path.isfile(abi_rs):
        with open(abi_rs, encoding="utf-8") as f:
            m = re.search(
                r"GSTORE_MODULE_ABI_VERSION\s*:\s*u32\s*=\s*(\d+)", f.read()
            )
        if m:
            return m.group(1)
    return "2"


def scan_so(source_dir):
    """扫描 <dir>/<abi>/libgstore_mod_*.so → {module: {abi: path}}。"""
    found = {}
    for abi in ABIS:
        abi_dir = os.path.join(source_dir, abi)
        if not os.path.isdir(abi_dir):
            continue
        for f in sorted(os.listdir(abi_dir)):
            if not (f.startswith("libgstore_mod_") and f.endswith(".so")):
                continue
            stem = f[len("libgstore_mod_"):-len(".so")]
            if stem.endswith(VARIANT_SUFFIXES):
                continue  # GPU 变体不进 Flat 清单
            so_path = os.path.join(abi_dir, f)
            if os.path.getsize(so_path) == 0:
                print(
                    f"[warn] 跳过零字节 .so: {so_path}",
                    file=sys.stderr,
                )
                continue
            found.setdefault(stem, {})[abi] = so_path
    return found


def write_json(path, payload):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
        f.write("\n")


min_abi = host_abi_version()
modules = {}
for name, abis in sorted(scan_so(module_dir).items()):
    version = module_version(name)
    sanitized = sanitize_version(version)
    if not ASSET_RE.match(sanitized):
        raise SystemExit(f"ERROR: sanitized version invalid: {version!r} -> {sanitized!r}")
    entry = {"version": version, "min_host_abi": min_abi, "abi": {}}
    for abi in sorted(abis):
        asset = f"libgstore_mod_{name}_{sanitized}-{abi}.so"
        sha, size = sha256_size(abis[abi])
        entry["abi"][abi] = {"asset": asset, "sha256": sha, "size": size}
    modules[name] = entry

manifest = {"version": 2, "modules": modules}
write_json(manifest_path, manifest)

# 内置清单：版本取自同一 module_version；abi 值为该模块版本。
builtin = {}
for name, abis in sorted(scan_so(builtin_dir).items()):
    version = module_version(name)
    builtin[name] = {"version": version, "abi": {abi: version for abi in sorted(abis)}}
write_json(builtin_path, builtin)

print(f"✓ v2 清单已生成: {manifest_path}")
print(f"  模块: {', '.join(modules.keys()) or '(无)'}  min_host_abi={min_abi}")
for name, data in modules.items():
    for abi in sorted(data.get("abi", {})):
        e = data["abi"][abi]
        print(f"  - {name}/{abi}: {e['asset']} ({e['size']}B)")
print(f"✓ 内置清单已生成: {builtin_path}")
print(f"  内置模块: {', '.join(builtin.keys()) or '(无)'}")
PYEOF
