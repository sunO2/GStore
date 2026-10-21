#!/usr/bin/env bash
# Release APK size budget gate.
#
# The budget is documented in docs/qa-baseline.json under `apk_budget`
# (`arm64_release_bytes`, with the measured reference and rationale).  This
# script reports the actual size and fails when it exceeds the budget.
#
# Exit-code contract:
#   0  APK found and size <= budget
#   1  APK size regression (or the baseline budget is missing/invalid)
#   3  SKIPPED: no release APK found (pass --apk PATH)
#   2  usage error
#
# Usage:
#   scripts/qa/apk-budget.sh [--apk PATH] [--baseline PATH]
#       [--budget-bytes N] [--self-test]
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

BASELINE="$ROOT/docs/qa-baseline.json"
APK=""
BUDGET_OVERRIDE=""
SELF_TEST=0

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --budget-bytes) BUDGET_OVERRIDE="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

human_size() {
  awk -v b="$1" 'BEGIN { printf "%.1f MiB", b / 1048576 }'
}

find_apk() {
  if [ -n "$APK" ]; then
    printf '%s\n' "$APK"
    return 0
  fi
  local c
  for c in \
    "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" \
    "build/app/outputs/flutter-apk/app-release.apk" \
    "build/app/outputs/apk/release/app-arm64-v8a-release.apk" \
    "build/app/outputs/apk/release/app-release.apk" \
    "build/apk-release/GStore-arm64-v8a-release.apk"; do
    if [ -f "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

read_budget() {
  python3 - "$BASELINE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print("ERROR: cannot read baseline %s: %s" % (sys.argv[1], exc), file=sys.stderr)
    sys.exit(1)
budget = data.get("apk_budget") or {}
value = budget.get("arm64_release_bytes")
if not isinstance(value, int) or value <= 0:
    print("ERROR: missing/invalid apk_budget.arm64_release_bytes in %s" % sys.argv[1], file=sys.stderr)
    sys.exit(1)
ref = budget.get("measured_reference_bytes", "?")
print("%d\t%s" % (value, ref))
PY
}

check_apk() {
  local apk_path="$1" budget="$2" ref="$3" size
  if [ ! -f "$apk_path" ]; then
    echo "SKIP: release APK not found: $apk_path"
    return 3
  fi
  size="$(stat -c '%s' "$apk_path" 2>/dev/null || stat -f '%z' "$apk_path")"
  echo "apk:      $apk_path"
  echo "actual:   $size bytes ($(human_size "$size"))"
  echo "budget:   $budget bytes ($(human_size "$budget"))"
  echo "reference: $ref bytes ($([ "$ref" != "?" ] && human_size "$ref" || echo '-'))"
  if [ "$size" -gt "$budget" ]; then
    echo "FAIL: APK exceeds the documented budget by $((size - budget)) bytes"
    return 1
  fi
  echo "PASS: APK is within budget ($((budget - size)) bytes headroom)"
  return 0
}

if [ "$SELF_TEST" -eq 1 ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gstore-apk-budget.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  printf 'budget fixture\n' > "$tmp/with-budget.json"
  cat > "$tmp/with-budget.json" <<'JSON'
{"apk_budget": {"arm64_release_bytes": 1000, "measured_reference_bytes": 800}}
JSON
  dd if=/dev/zero of="$tmp/pass.apk" bs=1 count=800 >/dev/null 2>&1
  dd if=/dev/zero of="$tmp/fail.apk" bs=1 count=1001 >/dev/null 2>&1
  echo "== apk-budget self-test =="
  read -r budget ref < <(read_budget "$BASELINE" 2>/dev/null || true)
  if [ -z "${budget:-}" ]; then
    echo "SKIP: real baseline has no apk_budget; self-test needs it" >&2
    exit 3
  fi
  if check_apk "$tmp/pass.apk" 1000 800 >/dev/null; then
    echo "[PASS] under-budget fixture accepted"
  else
    echo "[FAIL] under-budget fixture rejected" >&2
    exit 1
  fi
  set +e
  check_apk "$tmp/fail.apk" 1000 800 >/dev/null
  rc=$?
  set -e
  if [ "$rc" -eq 1 ]; then
    echo "[PASS] over-budget fixture rejected (rc=1)"
  else
    echo "[FAIL] over-budget fixture accepted (rc=$rc)" >&2
    exit 1
  fi
  echo "SELF-TEST PASS"
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to read the budget" >&2
  exit 2
fi

if [ -n "$BUDGET_OVERRIDE" ]; then
  BUDGET="$BUDGET_OVERRIDE"
  REF="override"
else
  if [ ! -f "$BASELINE" ]; then
    echo "ERROR: baseline not found: $BASELINE" >&2
    exit 1
  fi
  budget_line="$(read_budget)" || exit 1
  BUDGET="${budget_line%%$'\t'*}"
  REF="${budget_line#*$'\t'}"
fi

echo "== apk budget =="
APK_PATH="$(find_apk || true)"
if [ -z "$APK_PATH" ]; then
  echo "SKIP: no release APK found (looked under build/; pass --apk PATH)"
  echo "RESULT: SKIP (a skipped check is not a pass)"
  exit 3
fi
check_apk "$APK_PATH" "$BUDGET" "$REF"
