#!/usr/bin/env bash
# 确定性断言：CI 发布上传顺序、--clobber 策略与资产留存。
#
# 只读取 `.github/workflows/build.yml`（可用位置参数指定其它 YAML），不联网、
# 不调用真实 `gh`。校验（全部基于 YAML 解析后的步骤索引与 run 文本，不读注释）：
#   1) 本次各 ABI 新 .so 上传严格早于 modules.json 上传；
#   2) modules.json 上传后（且 .so 上传后）才允许删除旧模块资产；
#   3) 删除逻辑携带 TTL 与「本次 modules.json 引用」双重保护；
#   4) it-tools 资产（it-tools.zip / it_tools.json）豁免删除；
#   5) 模块 .so / modules.json 上传均带 --clobber；
#   6) 发布无条件上传模块资产（上传步骤无 if，且清单非空守卫存在）。
#
# 另含 clobber 行为性 dry-run：用 fake `gh` 模拟「同名资产已存在」，
# 执行 YAML 中真实的 `gh release upload` 命令行，断言带 --clobber 成功、
# 去掉 --clobber 则失败（证明策略而非注释）。
#
# 用法：
#   scripts/ci/assert_upload_order.sh [workflow.yml]
#
# 退出码：0 全部通过；1 任一断言失败；2 用法错误 / 缺少 PyYAML。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="${1:-$REPO_ROOT/.github/workflows/build.yml}"

if [ "$#" -gt 1 ]; then
  echo "ERROR: 参数过多（期望 0 或 1 个 workflow YAML 路径）" >&2
  echo "usage: $(basename "$0") [workflow.yml]" >&2
  exit 2
fi

if [ ! -f "$WORKFLOW" ]; then
  echo "ERROR: workflow 文件不存在: $WORKFLOW" >&2
  exit 1
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "ERROR: 需要 python3 + PyYAML（pip install pyyaml）" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ── 结构性断言（解析 YAML，输出真实步骤索引）──────────────────────────────
python3 - "$WORKFLOW" "$TMP_DIR" <<'PYEOF'
import re
import sys

import yaml

workflow_path, tmp_dir = sys.argv[1], sys.argv[2]

with open(workflow_path, encoding="utf-8") as f:
    doc = yaml.safe_load(f)

steps = []
for job in (doc.get("jobs") or {}).values():
    for step in job.get("steps") or []:
        steps.append(step)


def run_of(step):
    return step.get("run") or ""


def find(pred, label):
    for i, step in enumerate(steps):
        if pred(step):
            return i, step
    errors.append(f"缺少步骤: {label}")
    return None, None


errors = []

so_i, so_s = find(
    lambda s: "gh release upload" in run_of(s) and "libgstore_mod_" in run_of(s),
    "本轮新 .so 上传（版本化，--clobber）",
)
man_i, man_s = find(
    lambda s: "gh release upload" in run_of(s) and "modules.json#modules.json" in run_of(s),
    "modules.json 上传（提交标记）",
)
it_i, it_s = find(
    lambda s: "gh release upload" in run_of(s) and "it-tools.zip#it-tools.zip" in run_of(s),
    "it-tools 资产上传",
)
pr_i, pr_s = find(
    lambda s: "gh release delete-asset" in run_of(s),
    "旧模块资产删除（留存策略）",
)
gen_i, gen_s = find(
    lambda s: "generate_modules_manifest.sh" in run_of(s),
    "modules.json 生成",
)

# 1) 上传顺序：.so 严格早于 modules.json。
if so_i is not None and man_i is not None and not so_i < man_i:
    errors.append(
        f"顺序违例: .so 上传(步骤#{so_i}) 必须严格早于 modules.json(步骤#{man_i})"
    )

# 2) 删除必须在全部上传之后。
if pr_i is not None and man_i is not None and not man_i < pr_i:
    errors.append(
        f"顺序违例: modules.json 上传(步骤#{man_i}) 必须早于旧资产删除(步骤#{pr_i})"
    )
if pr_i is not None and so_i is not None and not so_i < pr_i:
    errors.append(
        f"顺序违例: .so 上传(步骤#{so_i}) 必须早于旧资产删除(步骤#{pr_i})"
    )

# 5) 每个上传步骤都必须带 --clobber，且上传调用数 <= clobber 数。
for label, step in (
    ("新 .so 上传", so_s),
    ("modules.json 上传", man_s),
    ("it-tools 上传", it_s),
):
    if step is None:
        continue
    run = run_of(step)
    uploads = run.count("gh release upload")
    clobbers = run.count("--clobber")
    if uploads == 0:
        errors.append(f"{label} 未包含 gh release upload")
    if clobbers < uploads:
        errors.append(f"{label} 必须对每次 gh release upload 使用 --clobber")

# 6) 无条件上传模块资产 + 非空守卫。
if so_s is not None:
    if "if" in so_s:
        errors.append("新 .so 上传不得带 if 条件（每次发布都必须上传模块资产）")
    if so_s.get("continue-on-error"):
        errors.append("新 .so 上传不得 continue-on-error（失败必须让发布失败）")
    if "-s module_assets.tsv" not in run_of(so_s):
        errors.append("新 .so 上传缺少「清单非空」守卫（空 modules.json 必须拒绝发布）")
    so_run = run_of(so_s)
    if "sha256sum" not in so_run or "actual_sha" not in so_run:
        errors.append("新 .so 上传缺少 sha256 与清单比对守卫")
    if "actual_size" not in so_run:
        errors.append("新 .so 上传缺少 size 与清单比对守卫")

# 3+4) 删除步骤的守卫与豁免（基于 run 文本，不基于注释）。
if pr_s is not None:
    pr_run = run_of(pr_s)
    if "MODULE_MANIFEST_TTL" not in pr_run or "TTL_DAYS" not in pr_run:
        errors.append("删除步骤缺少 TTL 保护（MODULE_MANIFEST_TTL / TTL_DAYS）")
    if "age_days" not in pr_run or "-ge" not in pr_run:
        errors.append("删除步骤缺少「早于 TTL」的年龄比较")
    if "modules.json" not in pr_run or "referenced_assets" not in pr_run:
        errors.append("删除步骤缺少「本次 modules.json 引用」保护")
    if "grep -Fxq" not in pr_run:
        errors.append("删除步骤缺少引用集合精确匹配（grep -Fxq）")
    if "libgstore_mod_*.so" not in pr_run:
        errors.append("删除步骤必须限定仅模块 .so 资产可删除")
    exempt = re.search(r"it-tools\.zip\|it_tools\.json\)[\s\S]*?continue", pr_run)
    if not exempt:
        errors.append("it-tools 资产未被豁免删除（需 it-tools.zip|it_tools.json → continue）")
    allow_arm = re.search(r'case "\$name" in\s*\n([^\n]*libgstore_mod_\*\.so[^\n]*)', pr_run)
    if allow_arm and "it-tools" in allow_arm.group(1):
        errors.append("it-tools 资产不得出现在可删除白名单中")
    env_keys = pr_s.get("env") or {}
    if "GITHUB_TOKEN" not in env_keys and "GH_TOKEN" not in env_keys:
        errors.append("删除步骤缺少登录凭据（GITHUB_TOKEN / GH_TOKEN）")

if gen_i is None or so_s is None:
    errors.append("发布流程必须先生成、再上传模块资产")

if errors:
    for e in errors:
        print(f"[assert_upload_order] FAIL: {e}", file=sys.stderr)
    sys.exit(1)

# 导出真实上传命令行，供 bash 侧 dry-run 执行。
def first_upload_line(step):
    for line in run_of(step).splitlines():
        if "gh release upload" in line:
            return line.strip()
    return ""


with open(f"{tmp_dir}/so_cmd", "w", encoding="utf-8") as f:
    f.write(first_upload_line(so_s))
with open(f"{tmp_dir}/manifest_cmd", "w", encoding="utf-8") as f:
    f.write(first_upload_line(man_s))

print(f"[assert_upload_order] [ok] 顺序: .so#{so_i} < modules.json#{man_i} < 删除#{pr_i}")
print("[assert_upload_order] [ok] --clobber / TTL+引用守卫 / it-tools 豁免 均满足")
PYEOF

SO_CMD="$(cat "$TMP_DIR/so_cmd")"
MANIFEST_CMD="$(cat "$TMP_DIR/manifest_cmd")"
if [ -z "$SO_CMD" ] || [ -z "$MANIFEST_CMD" ]; then
  echo "[assert_upload_order] FAIL: 未能从 YAML 提取上传命令行" >&2
  exit 1
fi

# ── clobber 行为性 dry-run（fake gh，无网络）───────────────────────────────
DRY_DIR="$TMP_DIR/dry"
FAKEBIN="$DRY_DIR/bin"
ASSET_STATE="$DRY_DIR/assets"
mkdir -p "$FAKEBIN" "$ASSET_STATE"
cat > "$FAKEBIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
# fake gh：模拟「同名资产已存在」的 gh release upload。
# 带 --clobber → 成功覆盖；不带 → 以「资产已存在」失败。
set -euo pipefail
state="${FAKE_GH_STATE:?FAKE_GH_STATE 未设置}"
if [ "${1:-}" = "release" ] && [ "${2:-}" = "upload" ]; then
  clobber=0
  rc=0
  for a in "$@"; do
    case "$a" in
      --clobber) clobber=1 ;;
    esac
  done
  for a in "$@"; do
    case "$a" in
      *"#"*)
        name="${a##*#}"
        if [ -f "$state/$name" ]; then
          if [ "$clobber" -eq 1 ]; then
            echo "fake-gh: clobbered existing asset: $name" >&2
          else
            echo "fake-gh: ERROR asset already exists (missing --clobber): $name" >&2
            rc=1
          fi
        else
          echo "fake-gh: uploaded new asset: $name" >&2
        fi
        ;;
    esac
  done
  exit "$rc"
fi
echo "fake-gh: 不支持的命令: $*" >&2
exit 2
FAKEGH
chmod +x "$FAKEBIN/gh"

export TAG="v0.0.0-test"
export GSTORE_MODULE_DIR="$DRY_DIR/modules"
mkdir -p "$GSTORE_MODULE_DIR"
: > "$GSTORE_MODULE_DIR/modules.json"
export src="$DRY_DIR/libgstore_mod_qr_0.1.0-arm64-v8a.so"
: > "$src"
export asset="libgstore_mod_qr_0.1.0-arm64-v8a.so"
export FAKE_GH_STATE="$ASSET_STATE"
# 预置同名资产，触发「已存在」分支。
: > "$ASSET_STATE/$asset"
: > "$ASSET_STATE/modules.json"

if ! PATH="$FAKEBIN:$PATH" bash -c "$SO_CMD" >/dev/null 2>"$DRY_DIR/so.ok.err"; then
  echo "[assert_upload_order] FAIL: dry-run .so 上传（--clobber）失败" >&2
  cat "$DRY_DIR/so.ok.err" >&2
  exit 1
fi
if ! grep -q "clobbered existing asset" "$DRY_DIR/so.ok.err"; then
  echo "[assert_upload_order] FAIL: dry-run 未真正走 clobber 分支（fake 未识别同名资产）" >&2
  cat "$DRY_DIR/so.ok.err" >&2
  exit 1
fi

if ! PATH="$FAKEBIN:$PATH" bash -c "$MANIFEST_CMD" >/dev/null 2>"$DRY_DIR/man.ok.err"; then
  echo "[assert_upload_order] FAIL: dry-run modules.json 上传（--clobber）失败" >&2
  cat "$DRY_DIR/man.ok.err" >&2
  exit 1
fi

if PATH="$FAKEBIN:$PATH" bash -c "${SO_CMD/--clobber/}" >/dev/null 2>"$DRY_DIR/so.bad.err"; then
  echo "[assert_upload_order] FAIL: 负向 dry-run：去掉 --clobber 仍成功（策略未生效）" >&2
  exit 1
fi
if ! grep -q "missing --clobber" "$DRY_DIR/so.bad.err"; then
  echo "[assert_upload_order] FAIL: 负向 dry-run 未以「同名资产已存在」失败" >&2
  cat "$DRY_DIR/so.bad.err" >&2
  exit 1
fi

echo "[assert_upload_order] [ok] dry-run: 同名资产 + --clobber 成功；去掉 --clobber 失败"
echo "assert_upload_order: PASS"
