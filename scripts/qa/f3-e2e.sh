#!/usr/bin/env bash
# End-to-end test harness for the Wave 0/1 contract + channel surface.
#
# Default suite (Wave 0):
#   Rust: gstore_contract, gstore_core, gstore_host cargo test suites
#   Dart: test/core_api_test.dart, test/core_flags_test.dart,
#         test/migration_handoff_test.dart
#
# --channel (Wave 1 gate):
#   The same Rust suites, plus the named Dart channel tests
#   (test/channel_api_test.dart, test/channel_migration_test.dart, test/parity)
#   and scripts/qa/parity.sh --channel when its inputs are available.
#
# Exit-code contract (a skipped check is never a pass):
#   0  every selected check ran and passed
#   1  at least one selected check ran and failed
#   3  SKIPPED: a required component is genuinely absent (missing cargo/flutter,
#      or a channel test file that has not landed yet).  Successfully executed
#      checks still pass, but the overall verdict is SKIP, never PASS.
#   2  usage error
#
# Long steps are bounded by --timeout (default 1800s) when `timeout` exists.
#
# Usage:
#   scripts/qa/f3-e2e.sh [--channel] [--skip-rust] [--skip-dart]
#       [--timeout SECONDS] [--verbose]
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

CHANNEL=0
SKIP_RUST=0
SKIP_DART=0
TIMEOUT=1800
VERBOSE=0

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL=1; shift ;;
    --skip-rust) SKIP_RUST=1; shift ;;
    --skip-dart) SKIP_DART=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

PASSED=0
FAILED=0
SKIPPED=0

skip() {
  echo "SKIP: $*"
  SKIPPED=$((SKIPPED + 1))
}

fail() {
  echo "FAIL: $*" >&2
  FAILED=$((FAILED + 1))
}

pass() {
  echo "PASS: $*"
  PASSED=$((PASSED + 1))
}

run_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" "$@"
  else
    "$@"
  fi
}

run_step() {
  local name="$1"
  shift
  echo
  echo "== $name =="
  if [ "$VERBOSE" -eq 1 ]; then
    echo "+ $*"
  fi
  set +e
  run_bounded "$@"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    pass "$name"
  elif [ "$rc" -eq 124 ]; then
    fail "$name timed out after ${TIMEOUT}s"
  else
    fail "$name (exit $rc)"
  fi
  return 0
}

rust_suite() {
  if [ "$SKIP_RUST" -eq 1 ]; then
    skip "Rust suites disabled by --skip-rust"
    return 0
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    skip "cargo not found (required for the Rust core/host suites)"
    return 0
  fi
  local manifest
  for crate in gstore_contract gstore_core gstore_host; do
    manifest="$ROOT/rust/$crate/Cargo.toml"
    if [ ! -f "$manifest" ]; then
      skip "Rust crate manifest absent: rust/$crate/Cargo.toml"
      continue
    fi
    run_step "cargo test ($crate)" \
      cargo test --manifest-path "$manifest"
  done
}

dart_tests() {
  if [ "$SKIP_DART" -eq 1 ]; then
    skip "Dart tests disabled by --skip-dart"
    return 0
  fi
  if ! command -v flutter >/dev/null 2>&1; then
    skip "flutter not found (required for Dart channel tests)"
    return 0
  fi

  local tests=()
  if [ "$CHANNEL" -eq 1 ]; then
    tests=(
      "test/channel_api_test.dart"
      "test/channel_migration_test.dart"
      "test/parity"
    )
  else
    tests=(
      "test/core_api_test.dart"
      "test/core_flags_test.dart"
      "test/migration_handoff_test.dart"
    )
  fi

  local t
  for t in "${tests[@]}"; do
    if [ ! -e "$t" ]; then
      if [ "$CHANNEL" -eq 1 ]; then
        skip "channel test not present yet: $t (required from Todo 13/14)"
      else
        skip "Dart test not present: $t"
      fi
      continue
    fi
    run_step "flutter test ($t)" flutter test "$t"
  done

  if [ "$CHANNEL" -eq 1 ]; then
    if [ -f "scripts/qa/parity.sh" ]; then
      if command -v sqlite3 >/dev/null 2>&1; then
        run_step "LocalDb parity (--channel)" bash scripts/qa/parity.sh --channel
      else
        skip "sqlite3 not found; LocalDb parity needs it"
      fi
    else
      skip "scripts/qa/parity.sh not present"
    fi
  fi
}

echo "== f3 e2e =="
echo "root:    $ROOT"
echo "mode:    $([ "$CHANNEL" -eq 1 ] && echo channel || echo wave0)"
echo "timeout: ${TIMEOUT}s per step"

rust_suite
dart_tests

echo
echo "== summary =="
echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
if [ "$FAILED" -gt 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
  echo "RESULT: SKIP (a skipped check is not a pass)"
  exit 3
fi
echo "RESULT: PASS"
exit 0
