#!/usr/bin/env bash
# 确定性断言：Todo 18 文档更新。
#
# 断言：
#   1) 所列文档路径均存在（test -f）。
#   2) document/development/12-...md 含「Phase 2」与「已知风险」。
#   3) rust/STATUS.md 含「远程」。
#   4) 内置负向控制：把 doc 12 复制到 /tmp 并删掉「已知风险」后，
#      对应的 contains 断言必须失败（若误通过则本脚本非零退出）。
#
# 退出 0 = 全部通过；非零 = 失败并给出原因。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

IT_TOOLS_DOC="$REPO_ROOT/document/development/12-开发者工具箱-IT-Tools离线内嵌.md"
REMOTE_DOC="$REPO_ROOT/document/development/16-模块远程下载与发布流程.md"
STATUS_DOC="$REPO_ROOT/rust/STATUS.md"
DOC_INDEX="$REPO_ROOT/document/README.md"

FAIL=0
fail() { echo "[docs_assert] FAIL: $*" >&2; FAIL=1; }

# 1) 路径存在性
for path in "$IT_TOOLS_DOC" "$REMOTE_DOC" "$STATUS_DOC" "$DOC_INDEX"; do
  if [ ! -f "$path" ]; then
    fail "文档不存在: $path"
  else
    echo "[docs_assert] [ok] 存在: ${path#$REPO_ROOT/}"
  fi
done

# 2) 内容断言（对任意给定文件与字面量）
require_contains() { # <file> <literal> <label>
  local file="$1" literal="$2" label="$3"
  if [ ! -f "$file" ]; then
    fail "$label: 文件不存在: $file"
    return 1
  fi
  if grep -Fq -- "$literal" "$file"; then
    echo "[docs_assert] [ok] $label 含「$literal」"
    return 0
  fi
  fail "$label 缺「$literal」: $file"
  return 1
}

require_contains "$IT_TOOLS_DOC" "Phase 2" "doc/12"
require_contains "$IT_TOOLS_DOC" "已知风险" "doc/12"
require_contains "$REMOTE_DOC" "已知风险" "doc/16"
require_contains "$REMOTE_DOC" "Phase 2" "doc/16"
require_contains "$REMOTE_DOC" "libgstore_mod_<name>_<major.minor.patch>-<abi>.so" "doc/16 资产命名"
require_contains "$STATUS_DOC" "远程" "rust/STATUS.md"

# 3) 负向控制：删掉「已知风险」的副本必须让 contains 断言失败。
NEG_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gstore_docs_assert.XXXXXX")"
trap 'rm -rf "$NEG_TMP_DIR"' EXIT
NEG_COPY="$NEG_TMP_DIR/doc12_no_known_risk.md"
sed 's/已知风险/已过滤/g' "$IT_TOOLS_DOC" > "$NEG_COPY"

if grep -Fq -- "已知风险" "$NEG_COPY"; then
  fail "负向控制失效：副本仍含「已知风险」"
else
  echo "[docs_assert] [ok] 负向控制: 副本已移除「已知风险」，contains 断言正确判定为缺失"
fi

# 显式复核：contains 辅助函数在负向副本上应返回非零。
if (require_contains "$NEG_COPY" "已知风险" "negative-control" >/dev/null 2>&1); then
  fail "负向控制失效：对已移除「已知风险」的副本，断言误判为通过"
else
  echo "[docs_assert] [ok] 负向控制: 断言对缺失字面量返回非零（预期行为）"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "[docs_assert] FAILED" >&2
  exit 1
fi
echo "docs_assert: PASS"
