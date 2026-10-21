#!/usr/bin/env bash
# ARM64 device/emulator smoke test.
#
# Checks (all issued through `adb`):
#   install -> launch -> process alive -> channel list -> search -> detail ->
#   local pack -> env migration -> parity -> flags-off (core_writes empty).
#
# Deep channel probes use one of two adb-visible contracts:
#   1. --instrumentation PKG/RUNNER
#        adb shell am instrument -w -e check <name> <runner>
#        The runner must print `OK (<check>)` on success.  This is the contract
#        used by the channel E2E instrumentation (landed with Todo 13/14).
#   2. debug APK + `adb shell run-as` (fallback)
#        Pulls the app's gstore_core.db and checks the Wave 0/1 schema/tables
#        with the host sqlite3 binary.  Release APKs are not debuggable, so this
#        path SKIPs cleanly unless a debug APK is installed.
#
# Exit-code contract (a skipped check is never a pass):
#   0  device present and every check ran and passed
#   1  a check ran and failed
#   3  SKIPPED: no adb, no device, non-ARM64 device, no APK, or deep probes
#      genuinely unavailable (release build / instrumentation not provided)
#   2  usage error
#
# Usage:
#   scripts/qa/device-smoke.sh [--apk PATH] [--package PKG]
#       [--instrumentation PKG/RUNNER] [--timeout SECONDS] [--no-install]
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

PKG="com.suno2.gstore"
APK=""
INSTRUMENTATION=""
TIMEOUT=120
DO_INSTALL=1

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --package) PKG="$2"; shift 2 ;;
    --instrumentation) INSTRUMENTATION="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --no-install) DO_INSTALL=0; shift ;;
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

adb_cmd() {
  run_bounded adb -s "$SERIAL" "$@"
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

deep_check_instrumentation() {
  local check="$1" out rc
  echo
  echo "== probe (instrumentation): $check =="
  set +e
  out="$(adb_cmd shell am instrument -w -e check "$check" "$INSTRUMENTATION" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "OK (.*$check.*)"; then
    pass "instrumentation check: $check"
  else
    fail "instrumentation check: $check (exit $rc)"
  fi
}

deep_checks_db() {
  local tmp db_path out
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gstore-device-smoke.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN

  if ! adb_cmd shell run-as "$PKG" true >/dev/null 2>&1; then
    skip "deep channel probes unavailable: $PKG is not debuggable (release APK); pass --instrumentation PKG/RUNNER"
    return 0
  fi

  set +e
  db_path="$(adb_cmd shell run-as "$PKG" find . -name gstore_core.db 2>/dev/null | tr -d '\r' | head -n 1)"
  set -e
  if [ -z "$db_path" ]; then
    skip "deep channel probes unavailable: gstore_core.db not found under the app data dir"
    return 0
  fi

  set +e
  adb_cmd exec-out run-as "$PKG" cat "$db_path" > "$tmp/core.db" 2>/dev/null
  local pull_rc=$?
  set -e
  if [ "$pull_rc" -ne 0 ] || [ ! -s "$tmp/core.db" ]; then
    skip "deep channel probes unavailable: could not pull $db_path"
    return 0
  fi

  if ! command -v sqlite3 >/dev/null 2>&1; then
    skip "deep channel probes unavailable: host sqlite3 not installed"
    return 0
  fi

  local check
  for check in channel-list channel-search channel-detail local-pack env-migration parity flags-off; do
    echo
    echo "== probe (sqlite): $check =="
    case "$check" in
      channel-list)
        out="$(sqlite3 "$tmp/core.db" "SELECT COUNT(*) FROM channels;" 2>&1)" || true
        if printf '%s' "$out" | grep -Eq '^[0-9]+$'; then
          pass "channel list (channels rows=$out)"
        else
          fail "channel list (channels table missing: $out)"
        fi
        ;;
      channel-search)
        out="$(sqlite3 "$tmp/core.db" "SELECT COUNT(*) FROM channel_apps;" 2>&1)" || true
        if printf '%s' "$out" | grep -Eq '^[0-9]+$'; then
          pass "channel search (channel_apps rows=$out)"
        else
          fail "channel search (channel_apps table missing: $out)"
        fi
        ;;
      channel-detail)
        out="$(sqlite3 "$tmp/core.db" "SELECT COUNT(*) FROM pragma_table_info('channel_apps') WHERE name IN ('app_id','name');" 2>&1)" || true
        if [ "$out" = "2" ]; then
          pass "channel detail (channel_apps app_id/name columns present)"
        else
          fail "channel detail (expected app_id+name columns, got: $out)"
        fi
        ;;
      local-pack)
        out="$(sqlite3 "$tmp/core.db" "SELECT COUNT(*) FROM channel_packs;" 2>&1)" || true
        if printf '%s' "$out" | grep -Eq '^[0-9]+$'; then
          pass "local pack (channel_packs rows=$out)"
        else
          fail "local pack (channel_packs table missing: $out)"
        fi
        ;;
      env-migration)
        out="$(sqlite3 "$tmp/core.db" "SELECT COUNT(*) FROM channel_env;" 2>&1)" || true
        if printf '%s' "$out" | grep -Eq '^[0-9]+$'; then
          pass "env migration (channel_env rows=$out)"
        else
          fail "env migration (channel_env table missing: $out)"
        fi
        ;;
      parity)
        local version integrity
        version="$(sqlite3 "$tmp/core.db" "PRAGMA user_version;" 2>&1)" || true
        integrity="$(sqlite3 "$tmp/core.db" "PRAGMA integrity_check;" 2>&1)" || true
        if printf '%s' "$version" | grep -Eq '^[0-9]+$' && [ "$version" -ge 1 ] && [ "$integrity" = "ok" ]; then
          pass "parity (schema version=$version, integrity=ok)"
        else
          fail "parity (schema version=$version, integrity=$integrity)"
        fi
        ;;
      flags-off)
        out="$(sqlite3 "$tmp/core.db" "SELECT COUNT(*) FROM core_writes;" 2>&1)" || true
        if [ "$out" = "0" ]; then
          pass "flags-off (core_writes empty; legacy-write guard stays disabled)"
        else
          fail "flags-off (expected core_writes=0, got: $out)"
        fi
        ;;
    esac
  done
}

echo "== device smoke =="
echo "package: $PKG"

if ! command -v adb >/dev/null 2>&1; then
  skip "adb not found; no device checks were run"
  echo
  echo "== summary =="
  echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
  echo "RESULT: SKIP"
  exit 3
fi

set +e
devices_out="$(adb devices 2>&1)"
devices_rc=$?
set -e
printf '%s\n' "$devices_out"
if [ "$devices_rc" -ne 0 ]; then
  skip "adb devices failed (exit $devices_rc); no device checks were run"
  echo
  echo "== summary =="
  echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
  echo "RESULT: SKIP"
  exit 3
fi

SERIAL="$(printf '%s\n' "$devices_out" | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
if [ -z "$SERIAL" ]; then
  skip "no adb device in state 'device'; start an ARM64 emulator or connect a device"
  echo
  echo "== summary =="
  echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
  echo "RESULT: SKIP"
  exit 3
fi
echo "serial:  $SERIAL"

ABI="$(adb_cmd shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r' || true)"
echo "abi:     ${ABI:-unknown}"
if ! printf '%s' "$ABI" | grep -q '^arm64'; then
  skip "device ABI is '${ABI:-unknown}', not arm64-v8a"
  echo
  echo "== summary =="
  echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
  echo "RESULT: SKIP"
  exit 3
fi

APK_PATH="$(find_apk || true)"
if [ -z "$APK_PATH" ]; then
  skip "no release APK found (pass --apk PATH)"
else
  echo "apk:     $APK_PATH"
  if [ "$DO_INSTALL" -eq 1 ]; then
    echo
    echo "== install =="
    set +e
    install_out="$(adb_cmd install -r -t "$APK_PATH" 2>&1)"
    install_rc=$?
    set -e
    printf '%s\n' "$install_out"
    if [ "$install_rc" -eq 0 ] && printf '%s' "$install_out" | grep -q 'Success'; then
      pass "install"
    else
      fail "install (exit $install_rc)"
    fi
  fi

  echo
  echo "== launch =="
  adb_cmd logcat -c >/dev/null 2>&1 || true
  adb_cmd shell am force-stop "$PKG" >/dev/null 2>&1 || true
  set +e
  launch_out="$(adb_cmd shell am start -W -n "$PKG/.MainActivity" 2>&1)"
  launch_rc=$?
  set -e
  printf '%s\n' "$launch_out"
  if [ "$launch_rc" -eq 0 ] && printf '%s' "$launch_out" | grep -Eq 'Status: ok|Complete'; then
    pass "launch"
  else
    fail "launch (exit $launch_rc)"
  fi

  sleep 3
  echo
  echo "== process =="
  pid="$(adb_cmd shell pidof "$PKG" 2>/dev/null | tr -d '\r' || true)"
  if [ -n "$pid" ]; then
    pass "process alive (pid=$pid)"
  else
    fail "process is not running after launch"
  fi

  echo
  echo "== crash log =="
  crash="$(adb_cmd logcat -d -b crash 2>/dev/null || true)"
  if printf '%s' "$crash" | grep -q "FATAL EXCEPTION"; then
    printf '%s\n' "$crash" | tail -n 40
    fail "crash log contains FATAL EXCEPTION"
  else
    pass "no FATAL EXCEPTION in the crash buffer"
  fi

  if [ -n "$INSTRUMENTATION" ]; then
    for check in channel-list channel-search channel-detail local-pack env-migration parity flags-off; do
      deep_check_instrumentation "$check"
    done
  else
    deep_checks_db
  fi
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
