#!/usr/bin/env python3
"""模块签名工具：为 release-modules 下每个模块 .so 生成 Ed25519 签名。

用法：
    python3 sign_module.py <module_dir> <private_key.pem>

    # 或经环境变量提供私钥路径
    GSTORE_SIGNING_KEY=/path/to/key.pem python3 sign_module.py rust/release-modules

产出：
    1. 每个 .so 旁写入侧车文件 <abi>/<file>.sig（hex 签名）——宿主 dlopen 前校验用；
    2. 每个 .so 旁写入侧车文件 <abi>/<file>.meta（JSON: name/version/abi）；
    3. 更新 modules.json，为每条 abi 记录写入 "signature" 字段（远程清单消费）。

签名内容（必须与 rust/gstore_contract/src/security.rs::signing_payload 完全一致）：
    "GSTORE_MODULE_V1" \\0 <name> \\0 <version> \\0 <abi> \\0 <sha256_hex>

签名后端使用 openssl CLI（OpenSSL 1.1.1+，支持 Ed25519 -rawin），无需 Python 三方库。

打印公钥（用于填入宿主 trust.rs::MODULE_SIGNING_PUBKEY_HEX）：
    openssl pkey -in key.pem -pubout -outform DER | tail -c 32 | xxd -p -c 256
"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile


def build_payload(name: str, version: str, abi: str, sha256_hex: str) -> bytes:
    out = bytearray()
    out += b"GSTORE_MODULE_V1"
    out += b"\x00" + name.encode()
    out += b"\x00" + version.encode()
    out += b"\x00" + abi.encode()
    out += b"\x00" + sha256_hex.encode()
    return bytes(out)


def sign(private_key: str, payload: bytes) -> str:
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(payload)
        payload_path = f.name
    sig_path = payload_path + ".sig"
    try:
        subprocess.run(
            ["openssl", "pkeyutl", "-sign", "-inkey", private_key,
             "-rawin", "-in", payload_path, "-out", sig_path],
            check=True, capture_output=True,
        )
        return open(sig_path, "rb").read().hex()
    finally:
        for p in (payload_path, sig_path):
            try:
                os.unlink(p)
            except OSError:
                pass


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    module_dir = sys.argv[1]
    private_key = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("GSTORE_SIGNING_KEY", "")
    if not private_key:
        print("ERROR: 需要私钥路径（参数或 GSTORE_SIGNING_KEY 环境变量）", file=sys.stderr)
        return 2
    if not os.path.isfile(private_key):
        print(f"ERROR: 私钥不存在: {private_key}", file=sys.stderr)
        return 1

    manifest_path = os.path.join(module_dir, "modules.json")
    if not os.path.isfile(manifest_path):
        print(f"ERROR: 清单不存在，先运行 generate_modules_manifest.sh: {manifest_path}", file=sys.stderr)
        return 1

    manifest = json.load(open(manifest_path))
    signed = 0
    for name, mod in manifest.get("modules", {}).items():
        version = mod.get("version", "0.1.0")
        for abi, entry in mod.get("abi", {}).items():
            file_name = entry["file_name"]
            sha = entry["sha256"]
            so_path = os.path.join(module_dir, abi, file_name)
            if not os.path.isfile(so_path):
                print(f"  ! 跳过（缺文件）: {so_path}", file=sys.stderr)
                continue
            # 防呆：清单 sha256 与实际文件不一致时拒绝签名
            actual = hashlib.sha256(open(so_path, "rb").read()).hexdigest()
            if actual != sha:
                print(f"  ! sha256 不匹配，先重跑 generate_modules_manifest.sh: {so_path}", file=sys.stderr)
                continue

            payload = build_payload(name, version, abi, sha)
            sig_hex = sign(private_key, payload)

            # 侧车文件（宿主 dlopen 前校验）
            open(so_path + ".sig", "w").write(sig_hex + "\n")
            json.dump(
                {"name": name, "version": version, "abi": abi},
                open(so_path + ".meta", "w"),
            )
            # 清单内嵌签名（Dart 下载后写侧车，供宿主校验）
            entry["signature"] = sig_hex
            signed += 1
            print(f"  ✓ {name}/{abi}: {file_name}")

    json.dump(manifest, open(manifest_path, "w"), indent=2, ensure_ascii=False)
    open(manifest_path, "a").write("\n")
    print(f"✓ 已签名 {signed} 个模块产物；modules.json 已更新")
    return 0


if __name__ == "__main__":
    sys.exit(main())
