#!/usr/bin/env bash
# 用「上游 it-tools + 本项目补丁」构建离线包，产出 assets/it_tools/it-tools.zip
#
# 为什么用补丁而不是整包 fork：
#   1) 可复现、可审计——上游任何一次提交都能重放，diff 只有改动本身
#   2) 体积小，不把上游几万行源码塞进本仓库
#   3) 这是 GPLv3 下「修改版分发」最规范的形式：上游 + 你的改动 + 构建脚本
#
# 本地用法（在仓库根目录）：
#   bash scripts/it_tools/build_bundle.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/CorentinTh/it-tools.git}"
# 补丁对应的上游基线；换基线时必须重做补丁（见文件头 diff 行）
UPSTREAM_COMMIT="${UPSTREAM_COMMIT:-d505845f918e946ec300af7b36efc107e2f66e9e}"
PATCH_FILE="${PATCH_FILE:-$REPO_ROOT/scripts/it_tools/it-tools-modifications.patch}"
OUT_ZIP="${OUT_ZIP:-$REPO_ROOT/assets/it_tools/it-tools.zip}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"

echo "[it-tools] 上游 ${UPSTREAM_REPO} @ ${UPSTREAM_COMMIT:0:7}"
git clone --filter=blob:none --no-checkout "$UPSTREAM_REPO" "$WORK_DIR/it-tools" >/dev/null
git -C "$WORK_DIR/it-tools" checkout -q "$UPSTREAM_COMMIT"

echo "[it-tools] 应用补丁 $(basename "$PATCH_FILE")"
git -C "$WORK_DIR/it-tools" apply -p1 "$PATCH_FILE"

echo "[it-tools] 安装依赖 + 构建离线包"
cd "$WORK_DIR/it-tools"
command -v pnpm >/dev/null || corepack enable
# 强制装 devDependencies：若环境里存在 NODE_ENV=production（本地常见、CI 不一定），
# pnpm 会跳过 devDeps，导致 vite/vue-tsc 缺失、构建直接失败。
NODE_ENV=development pnpm install --frozen-lockfile

# 刻意不走 `pnpm build:embed`（= vue-tsc + 打包）：全新 checkout 里
# vue-tsc 会拉到与上游锁文件匹配的版本，类型检查对 lib/target 很敏感，
# 容易在 CI 上以无关的 TS 报错中断发布。
# 发布产物只需要打包器（vite 转译不做类型检查），类型门禁留给开发期。
node scripts/build-embed.mjs

mkdir -p "$(dirname "$OUT_ZIP")"
cp dist-embed.zip "$OUT_ZIP"
echo "[it-tools] 产出: $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1))"
