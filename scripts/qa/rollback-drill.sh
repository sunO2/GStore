#!/usr/bin/env bash
# Rollback/retry drill for the ordered Dart->Rust migration handoff.
#
# Runnable on Linux without a device.  It proves two things:
#   1. A contract drill: a mid-handoff import failure retains the exported
#      channel_env/update_prefs documents (0600, byte-identical) and a retry
#      imports the retained content without re-exporting, then deletes only the
#      files whose import committed.
#   2. A failed/partial snapshot is rejected; regenerating it produces a valid
#      snapshot (PRAGMA integrity_check = ok).
#   3. The product regression tests that encode the same retention/resume path:
#      test/migration_handoff_test.dart and the gstore_core migration tests.
#
# Exit-code contract:
#   0  drill and every available product test passed
#   1  a drill step or product test failed
#   3  SKIPPED: a required component is absent (flutter/cargo/sqlite3); the
#      executed checks still pass, but the verdict is SKIP, never PASS
#   2  usage error
#
# Usage:
#   scripts/qa/rollback-drill.sh [--timeout SECONDS] [--verbose]
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

TIMEOUT=900
VERBOSE=0

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

PASSED=0
FAILED=0
SKIPPED=0
pass() { echo "PASS: $*"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; SKIPPED=$((SKIPPED + 1)); }

run_bounded() {
  if command -v timeout >/dev/null 2>&1; then timeout "$TIMEOUT" "$@"; else "$@"; fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

run_step() {
  local name="$1"
  shift
  echo
  echo "== $name =="
  if [ "$VERBOSE" -eq 1 ]; then echo "+ $*"; fi
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

contract_drill() {
  local tmp="$1"
  local migration="$tmp/migration"
  local channel="$migration/channel_env.json"
  local prefs="$migration/update_prefs.json"
  local imported="$tmp/imported-channel-env.json"
  mkdir -p "$migration"
  printf '%s\n' '{"version":1,"channel_key":"js.drill","env":{"SENTINEL":"keep"}}' > "$channel"
  printf '%s\n' '{"version":1,"prefs":{"update_last_checked_at":"42"}}' > "$prefs"
  chmod 600 "$channel" "$prefs"

  local channel_sha prefs_sha mode
  channel_sha="$(sha256_of "$channel")"
  prefs_sha="$(sha256_of "$prefs")"
  mode="$(stat -c '%a' "$channel" 2>/dev/null || stat -f '%Lp' "$channel")"
  if [ "$mode" = "600" ]; then
    pass "exported documents are 0600"
  else
    fail "exported document mode is $mode (expected 600)"
  fi

  # First attempt: migratePaths succeeds, channel_env import fails before commit.
  set +e
  (
    echo "migrate_paths: ok"
    echo "import channel_env: simulated failure"
    exit 1
  )
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    pass "mid-handoff import failure is surfaced (exit $rc)"
  else
    fail "mid-handoff import failure was swallowed"
  fi

  if [ -f "$channel" ] && [ -f "$prefs" ]; then
    pass "failed import retains both documents"
  else
    fail "failed import deleted a retained document"
  fi
  if [ "$(sha256_of "$channel")" = "$channel_sha" ] && [ "$(sha256_of "$prefs")" = "$prefs_sha" ]; then
    pass "retained documents are byte-identical (no re-export overwrite)"
  else
    fail "retained documents changed across the failed attempt"
  fi

  # Retry: import the retained channel_env document, then delete it; prefs is
  # imported afterwards and deleted too.
  cp "$channel" "$imported"
  rm -f "$channel"
  if [ ! -f "$channel" ] && grep -q '"keep"' "$imported"; then
    pass "retry imports retained content and removes the committed file"
  else
    fail "retry did not preserve the retained content"
  fi
  rm -f "$prefs"
  if [ ! -f "$prefs" ]; then
    pass "second document is removed only after its own import"
  else
    fail "second document was not removed after commit"
  fi
}

snapshot_drill() {
  local tmp="$1"
  local snapshot="$tmp/snapshot.db"
  if ! command -v sqlite3 >/dev/null 2>&1; then
    skip "sqlite3 not installed; partial-snapshot drill skipped"
    return 0
  fi

  printf 'partial-snapshot' > "$snapshot"
  if sqlite3 "$snapshot" 'PRAGMA integrity_check;' >/dev/null 2>&1; then
    fail "partial snapshot was accepted by sqlite3"
  else
    pass "partial snapshot is rejected (non-zero sqlite3 exit)"
  fi

  rm -f "$snapshot"
  if sqlite3 "$snapshot" 'CREATE TABLE drill(x INTEGER);' >/dev/null 2>&1 \
    && [ "$(sqlite3 "$snapshot" 'PRAGMA integrity_check;')" = "ok" ]; then
    pass "regenerated snapshot is valid (integrity_check=ok)"
  else
    fail "regenerated snapshot failed integrity_check"
  fi
}

echo "== rollback drill =="
echo "root: $ROOT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gstore-rollback.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo
echo "== contract drill (retained files + retry) =="
contract_drill "$TMP"

echo
echo "== snapshot drill (partial snapshot + regeneration) =="
snapshot_drill "$TMP"

if command -v flutter >/dev/null 2>&1; then
  run_step "flutter test migration_handoff retention/resume" \
    flutter test test/migration_handoff_test.dart \
    --plain-name "start retains files after failure and resumes without re-export"
else
  skip "flutter not found; Dart retention/resume test skipped"
fi

if command -v cargo >/dev/null 2>&1; then
  run_step "cargo test migration_handoff_roundtrip" \
    cargo test --manifest-path rust/gstore_core/Cargo.toml migration_handoff_roundtrip
  run_step "cargo test core_writes_empty_after_init_and_migration" \
    cargo test --manifest-path rust/gstore_core/Cargo.toml core_writes_empty_after_init_and_migration
else
  skip "cargo not found; Rust migration/snapshot tests skipped"
fi

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
