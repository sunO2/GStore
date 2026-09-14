#!/bin/bash
# 生成模块清单 modules.json（供发布端随 GitHub Release 分发）
#
# 用法：./generate_modules_manifest.sh [模块目录]
# 默认读取 rust/release-modules/（build_android_rust.sh --module-qr 的输出）
# 输出：rust/release-modules/modules.json
#
# 结构（RustModuleLoader 的 ModuleManifestEntry 消费）：
# {
#   "version": 1,
#   "modules": {
#     "qr": {
#       "version": "0.1.0",
#       "abi": {
#         "arm64-v8a":  { "file_name": "libgstore_mod_qr.so", "sha256": "..." },
#         "armeabi-v7a": { "file_name": "libgstore_mod_qr.so", "sha256": "..." },
#         "x86":         { "file_name": "libgstore_mod_qr.so", "sha256": "..." },
#         "x86_64":      { "file_name": "libgstore_mod_qr.so", "sha256": "..." }
#       }
#     }
#   }
# }

set -e

MODULE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rust/release-modules}"

if [ ! -d "$MODULE_DIR" ]; then
    echo "ERROR: module dir not found: $MODULE_DIR" >&2
    echo "先运行 ./build_android_rust.sh --module-qr 构建模块" >&2
    exit 1
fi

MANIFEST="$MODULE_DIR/modules.json"

# 因上面的 awk 生成便于人工核对，改用 Python 生成规范 JSON 更可靠
python3 - "$MODULE_DIR" "$MANIFEST" << 'PYEOF'
import hashlib
import json
import os
import sys

module_dir, manifest_path = sys.argv[1], sys.argv[2]
abis = ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"]

modules = {}
for abi in abis:
    abi_dir = os.path.join(module_dir, abi)
    if not os.path.isdir(abi_dir):
        continue
    for f in sorted(os.listdir(abi_dir)):
        if not f.startswith("libgstore_mod_") or not f.endswith(".so"):
            continue
        stem = f[len("libgstore_mod_"):-len(".so")]
        # GPU 变体用文件名后缀区分（_opencl/_vulkan/_cpu）；剥离后归入同一模块，
        # 变体挂在 abi 条目的 variants 下；无后缀视为 cpu（base 条目）。
        module, variant = stem, "cpu"
        for tag in ("_opencl", "_vulkan", "_cpu"):
            if stem.endswith(tag) and len(stem) > len(tag):
                module, variant = stem[: -len(tag)], tag[1:]
                break
        so_path = os.path.join(abi_dir, f)
        sha = hashlib.sha256(open(so_path, "rb").read()).hexdigest()
        size = os.path.getsize(so_path)
        entry = modules.setdefault(module, {})
        abi_entry = entry.setdefault("abi", {}).setdefault(abi, {})
        if variant == "cpu":
            abi_entry.update({"file_name": f, "sha256": sha, "size": size})
        else:
            abi_entry.setdefault("variants", {})[variant] = {
                "file_name": f,
                "sha256": sha,
                "size": size,
            }

# 模块版本从 Cargo.toml 读取
for module in modules:
    cargo = os.path.join(module_dir, "..", f"gstore_mod_{module}", "Cargo.toml")
    version = "0.1.0"
    if os.path.isfile(cargo):
        for line in open(cargo):
            if line.strip().startswith("version"):
                version = line.split("=")[1].strip().strip('"')
                break
    modules[module]["version"] = version

manifest = {"version": 1, "modules": modules}
with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"✓ 清单已生成: {manifest_path}")
print(f"  模块: {', '.join(modules.keys()) or '(无)'}")
for module, data in modules.items():
    for abi in sorted(data.get("abi", {})):
        e = data["abi"][abi]
        line = f"  - {module}/{abi}: {e.get('file_name','-')} ({e.get('size',0)}B)"
        for v, ve in sorted(e.get("variants", {}).items()):
            line += f" + {v}:{ve['file_name']} ({ve['size']}B)"
        print(line)
PYEOF