#!/usr/bin/env bash
# 一键测试全部 Rust crate。
#
# 先构建各模块 .so（debug），再跑每个 crate 的 `cargo test`：
# host 的集成测试会 dlopen 模块 .so，缺失会 **fail**（不再静默跳过），
# 因此在 CI 中本脚本保证集成路径真的被执行。
#
# 用法：rust/test_all.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CRATES=(
  "gstore_contract"
  "gstore_mod_qr"
  "gstore_mod_analyzer"
  "gstore_mod_repo"
  "gstore_mod_llm"  # 默认 feature（无 llama.cpp）：验证 ABI/参数解析/降级路径
  "gstore_host"   # 最后：其集成测试依赖上面各模块的 .so
)

FAILED=0
for crate in "${CRATES[@]}"; do
    echo "==> testing $crate"
    if ! (cd "$ROOT/$crate" && cargo test); then
        echo "!! $crate tests failed"
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo "✗ some crate tests failed"
    exit 1
fi
echo "✓ all crate tests passed"
