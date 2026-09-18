#!/usr/bin/env bash
# 确定性断言：scripts/it_tools/build_bundle.sh 产出的 it_tools.json。
#   contentHash == zip 字节 sha256，size == 字节数，asset == "it-tools.zip"。
#
# 全程临时目录；使用 IT_TOOLS_MANIFEST_ONLY=1 对 zip fixture 发射清单，
# 不触发 clone/构建，也不写仓库 assets/。
# 退出 0 = 通过；非零 = 失败。脚本内含负向自检（缺清单/篡改哈希/篡改大小）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="$REPO_ROOT/scripts/it_tools/build_bundle.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gstore_it_tools_assert.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

ZIP="$TMP_DIR/it-tools-fixture.zip"
MANIFEST="$TMP_DIR/it_tools.json"

# 确定性 zip fixture（内容不必是真实前端产物）。
python3 - "$ZIP" << 'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.html", "<html><body>it-tools fixture</body></html>")
    z.writestr("assets/app.js", "console.log('fixture');")
PY

# 校验函数：zip manifest → 0 通过 / 非零 + stderr 原因。
validate() {
    python3 - "$1" "$2" << 'PY'
import hashlib
import json
import os
import sys

zip_path, manifest_path = sys.argv[1], sys.argv[2]
if not os.path.isfile(manifest_path):
    print(f"[it_tools_assert] 缺少清单文件: {manifest_path}", file=sys.stderr)
    sys.exit(1)
try:
    with open(manifest_path, encoding="utf-8") as f:
        m = json.load(f)
except Exception as e:  # noqa: BLE001
    print(f"[it_tools_assert] 清单非法 JSON: {e}", file=sys.stderr)
    sys.exit(1)

h = hashlib.sha256()
size = 0
with open(zip_path, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
        size += len(chunk)
expected_hash = h.hexdigest()

fail = []
if m.get("contentHash") != expected_hash:
    fail.append(f"contentHash 不符: 清单 {m.get('contentHash')} != 实际 {expected_hash}")
if m.get("size") != size:
    fail.append(f"size 不符: 清单 {m.get('size')} != 实际 {size}")
if m.get("asset") != "it-tools.zip":
    fail.append(f"asset 应为 it-tools.zip，实际 {m.get('asset')}")
if fail:
    for f in fail:
        print("[it_tools_assert] " + f, file=sys.stderr)
    sys.exit(1)
print(f"[it_tools_assert] [ok] contentHash/size 与 zip 字节一致 (size={size})")
PY
}

# happy path：经由 bundle 脚本的仅清单路径发射。
IT_TOOLS_MANIFEST_ONLY=1 OUT_ZIP="$ZIP" IT_TOOLS_MANIFEST_OUT="$MANIFEST" \
  bash "$BUNDLE"
[ -f "$MANIFEST" ] || { echo "[it_tools_assert] 未生成清单: $MANIFEST" >&2; exit 1; }
validate "$ZIP" "$MANIFEST"

# 负向 1：缺失 it_tools.json 必须失败
if validate "$ZIP" "$TMP_DIR/missing.json" 2>/dev/null; then
    echo "[it_tools_assert] FAIL: 缺失清单时断言未失败" >&2
    exit 1
fi
echo "[it_tools_assert] [ok] 负向：缺失 it_tools.json 正确判失败"

# 负向 2：contentHash 被篡改必须失败
python3 - "$MANIFEST" "$TMP_DIR/tampered-hash.json" << 'PY'
import json
import sys

m = json.load(open(sys.argv[1], encoding="utf-8"))
m["contentHash"] = "0" * 64
json.dump(m, open(sys.argv[2], "w", encoding="utf-8"))
PY
if validate "$ZIP" "$TMP_DIR/tampered-hash.json" 2>/dev/null; then
    echo "[it_tools_assert] FAIL: 篡改 contentHash 时断言未失败" >&2
    exit 1
fi
echo "[it_tools_assert] [ok] 负向：篡改 contentHash 正确判失败"

# 负向 3：size 被篡改必须失败
python3 - "$MANIFEST" "$TMP_DIR/tampered-size.json" << 'PY'
import json
import sys

m = json.load(open(sys.argv[1], encoding="utf-8"))
m["size"] = m["size"] + 1
json.dump(m, open(sys.argv[2], "w", encoding="utf-8"))
PY
if validate "$ZIP" "$TMP_DIR/tampered-size.json" 2>/dev/null; then
    echo "[it_tools_assert] FAIL: 篡改 size 时断言未失败" >&2
    exit 1
fi
echo "[it_tools_assert] [ok] 负向：篡改 size 正确判失败"

# 负向 4：zip fixture 缺失时，bundle 仅清单路径必须非零退出
if IT_TOOLS_MANIFEST_ONLY=1 OUT_ZIP="$TMP_DIR/no-such.zip" \
    IT_TOOLS_MANIFEST_OUT="$TMP_DIR/should-not-exist.json" \
    bash "$BUNDLE" >/dev/null 2>&1; then
    echo "[it_tools_assert] FAIL: 缺 zip 时 bundle 未失败" >&2
    exit 1
fi
echo "[it_tools_assert] [ok] 负向：缺 zip 时 bundle 正确判失败"

echo "it_tools_manifest_assert: PASS"
