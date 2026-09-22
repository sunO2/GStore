#!/usr/bin/env bash
# 设备侧「代理隧道冒烟」集成测试包装脚本。
#
# 用途：把 `integration_test/proxy_tunnel_test.dart`（本地回环 mock 代理返回已知
# marker，断言「流量确实经内核转发」+「域名统计记录了该域名」）跑在**已连接的 adb
# 设备**上，并在没有设备时以清晰信息非零退出，而不是让 `flutter test` 抛难懂错误。
#
# 用法：
#   scripts/ci/run_proxy_tunnel_device_test.sh [deviceId]
#     deviceId  目标设备序列号（缺省取 `$ANDROID_SERIAL`，再回退第一台在线设备）。
#
# 退出码：
#   0  设备测试通过且输出包含 marker 断言通过行
#   1  flutter test 失败 / 未发现 marker 断言通过行
#   2  NO DEVICE ATTACHED（adb devices 无在线设备，或指定设备不在线）
#   3  未找到 adb
#
# 环境变量：
#   ADB             adb 可执行文件（缺省 `adb`）
#   ANDROID_SERIAL  目标设备序列号（可被位置参数覆盖）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_FILE="integration_test/proxy_tunnel_test.dart"
MARKER_LINE="MARKER ASSERTION PASSED"

usage() {
  echo "usage: $(basename "$0") [deviceId]" >&2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -gt 1 ]; then
  echo "ERROR: 参数过多（期望 0 或 1 个设备序列号）" >&2
  usage
  exit 2
fi

ADB="${ADB:-adb}"
TARGET_DEVICE="${1:-${ANDROID_SERIAL:-}}"

if ! command -v "$ADB" >/dev/null 2>&1; then
  echo "NO DEVICE ATTACHED: 未找到 adb（ADB='$ADB'）；请安装 Android platform-tools。" >&2
  exit 3
fi

# 只接受状态为 `device`（已授权）的在线设备；unauthorized/offline 不算。
ONLINE_DEVICES="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }')"

if [ -z "$ONLINE_DEVICES" ]; then
  echo "NO DEVICE ATTACHED: \`adb devices\` 未发现任何已授权在线设备。" >&2
  echo "  请连接并授权一台 Android 设备后重试。" >&2
  "$ADB" devices >&2 || true
  exit 2
fi

if [ -z "$TARGET_DEVICE" ]; then
  TARGET_DEVICE="$(printf '%s\n' "$ONLINE_DEVICES" | head -n 1)"
fi

if ! printf '%s\n' "$ONLINE_DEVICES" | grep -qx -- "$TARGET_DEVICE"; then
  echo "NO DEVICE ATTACHED: 指定设备 '$TARGET_DEVICE' 不在线。" >&2
  echo "  在线设备：$(printf '%s' "$ONLINE_DEVICES" | tr '\n' ' ')" >&2
  exit 2
fi

echo "[proxy-tunnel] device=$TARGET_DEVICE target=$TEST_FILE"

LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/gstore_proxy_tunnel.XXXXXX.log")"
set +e
(
  cd "$REPO_ROOT"
  flutter test "$TEST_FILE" -d "$TARGET_DEVICE" 2>&1 | tee "$LOG_FILE"
)
STATUS="${PIPESTATUS[0]}"
set -e

if [ "$STATUS" -eq 0 ] && grep -Fq -- "$MARKER_LINE" "$LOG_FILE"; then
  echo "[proxy-tunnel] MARKER ASSERTION PASSED（GSTORE_TUNNEL_FIXTURE_MARKER）"
  exit 0
fi

echo "[proxy-tunnel] FAILED：flutter test 退出码=$STATUS（日志：$LOG_FILE）" >&2
if [ "$STATUS" -eq 0 ]; then
  echo "  测试进程成功但未发现 marker 断言通过行 —— 视为失败（断言未真正执行）。" >&2
fi
exit 1
