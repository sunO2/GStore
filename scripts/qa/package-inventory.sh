#!/usr/bin/env bash
# Todo 8 evidence: package inventory bridge contract + device instrumentation.
#
# Truthfulness rule: a device PASS requires a POSITIVE inventory-result marker —
# evidence that an actual PackageManager inventory query succeeded. A bare
# "PlatformHostBridge" line is only bridge INIT (the Kotlin class logs init in
# PlatformHostBridge.kt, and jni_bridge.rs logs RegisterNatives/context setup),
# so it is never sufficient. The shipped Kotlin inventory methods
# (listInstalledJson/getInstalledJson/...) log no success line today, therefore
# no shipped path emits the positive marker and a real device run truthfully
# ends DEFERRED (exit 3) instead of a false PASS. If product code later logs
#   "PlatformHostBridge: inventory_result count=<n>"
# (or CORE_E_PACKAGE_INVENTORY_OK / 清单查询成功) this same check turns PASS.
#
# Exit codes:
#   0 = Rust proof passed AND positive inventory evidence observed
#   1 = Rust proof failed
#   3 = BLOCKED/DEFERRED (no device, or no positive inventory evidence; never faked)
#   2 = usage error
#
# Deterministic logcat check (no adb/flutter, for tests/CI):
#   scripts/qa/package-inventory.sh --check-logcat <logcat-file>
#   PACKAGE_INVENTORY_LOGCAT_FILE=<file> scripts/qa/package-inventory.sh --check-logcat
#
# The check only reads the file passed in; the device path reads a fresh
# `logcat -d` dump into a unique temp file after `logcat -c`, so stale logs
# from a previous run are never reused.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVIDENCE="$ROOT/target/test-evidence"
MAIN="$EVIDENCE/67-package.txt"
DENIED="$EVIDENCE/67-package-denied.txt"
MANIFEST="$ROOT/rust/gstore_host/Cargo.toml"
ADB_TIMEOUT="${ADB_TIMEOUT:-10}"

# A positive marker is matched only when the bridge tag is accompanied by an
# inventory-RESULT token. Init lines such as "已缓存类引用（JNI 包清单就绪）" or
# "applicationContext 缓存完成" deliberately do not match.
POSITIVE_PATTERN='PlatformHostBridge.*(inventory_result count=[0-9]+|CORE_E_PACKAGE_INVENTORY_OK|清单查询成功)'

MODE="run"
LOGCAT_FILE="${PACKAGE_INVENTORY_LOGCAT_FILE:-}"

usage() {
  printf 'usage: %s [--check-logcat <logcat-file>]\n' "${BASH_SOURCE[0]}" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-logcat)
      MODE="check"
      if [ "$#" -ge 2 ]; then
        LOGCAT_FILE="$2"
        shift 2
      elif [ -n "$LOGCAT_FILE" ]; then
        shift
      else
        printf '%s\n' "--check-logcat requires a <logcat-file>" >&2
        exit 2
      fi
      ;;
    --check-logcat=*)
      MODE="check"
      LOGCAT_FILE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

# Env-only invocation also selects the deterministic mode.
if [ -n "$LOGCAT_FILE" ]; then
  MODE="check"
fi

mkdir -p "$EVIDENCE"
if [ "$MODE" = "run" ]; then
  : >"$MAIN"
  LOG_TARGET="$MAIN"
else
  # Deterministic mode must not clobber the Rust proof evidence file.
  LOG_TARGET=""
fi

log() {
  if [ -n "$LOG_TARGET" ]; then
    printf '%s\n' "$*" | tee -a "$LOG_TARGET"
  else
    printf '%s\n' "$*"
  fi
}

has_positive_inventory_evidence() {
  local file="$1"
  [ -f "$file" ] || return 1
  grep -Eq -- "$POSITIVE_PATTERN" "$file"
}

# Returns 0 only when the log file carries positive inventory-RESULT evidence.
# Kept side-effect free apart from logging so it is testable without adb.
inventory_verdict() {
  local file="$1"
  local matched
  if has_positive_inventory_evidence "$file"; then
    matched="$(grep -Eo -- "$POSITIVE_PATTERN" "$file" | head -n 1)"
    log "matched positive inventory evidence: $matched"
    log "RESULT: PASS (positive inventory result observed)"
    return 0
  fi
  log "RESULT: DEFERRED (no positive inventory evidence)"
  return 3
}

if [ "$MODE" = "check" ]; then
  log "== package inventory logcat check (deterministic, no adb) =="
  log "logcat input: $LOGCAT_FILE"
  inventory_verdict "$LOGCAT_FILE"
  exit $?
fi

run_rust() {
  local label="$1"
  shift
  log ""
  log "== $label =="
  "$@" 2>&1 | tee -a "$MAIN"
  return "${PIPESTATUS[0]}"
}

# Bound every adb call so a wedged adb server cannot hang CI. `timeout` is
# required on the supported Linux/macOS CI hosts; if it is missing we say so
# rather than silently running unbounded.
adb_t() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$ADB_TIMEOUT" adb "$@"
  else
    adb "$@"
  fi
}

log "== GStore package inventory (Plan-Todo 8) =="
log "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "worktree: $ROOT"
log "rust: $(rustc --version 2>&1)"
log "cargo: $(cargo --version 2>&1)"

if ! run_rust "cargo build gstore_host (libgstore_host.so)" \
  cargo build --manifest-path "$MANIFEST"; then
  log "RESULT: FAIL (cargo build)"
  exit 1
fi

if ! run_rust "cargo test package_inventory_contract" \
  cargo test --manifest-path "$MANIFEST" package_inventory_contract -- --nocapture; then
  log "RESULT: FAIL (contract tests)"
  exit 1
fi

if ! run_rust "cargo test package_inventory_visibility_denied" \
  cargo test --manifest-path "$MANIFEST" package_inventory_visibility_denied -- --nocapture; then
  log "RESULT: FAIL (visibility denied tests)"
  exit 1
fi

{
  printf '%s\n' "== package inventory visibility denial (Plan-Todo 8) =="
  printf '%s\n' "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cargo test --manifest-path "$MANIFEST" package_inventory_visibility_denied -- --nocapture 2>&1
} | tee "$DENIED"
DENIED_RC="${PIPESTATUS[0]}"
if [ "$DENIED_RC" -ne 0 ]; then
  log "RESULT: FAIL (denied mapping evidence)"
  exit 1
fi
log ""
log "denied mapping evidence: $DENIED"

log ""
log "== adb devices =="
DEVICE=""
if command -v adb >/dev/null 2>&1; then
  if ! command -v timeout >/dev/null 2>&1; then
    log "timeout: not found (adb calls are NOT bounded on this host)"
  fi
  DEVICES_OUT="$(adb_t devices 2>&1)"
  ADB_RC=$?
  printf '%s\n' "$DEVICES_OUT" | tee -a "$MAIN"
  if [ "$ADB_RC" -ne 0 ]; then
    log "adb devices failed or timed out (rc=$ADB_RC)"
  fi
  DEVICE="$(printf '%s\n' "$DEVICES_OUT" | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
else
  log "adb: not found"
fi

if [ -z "${DEVICE:-}" ]; then
  log "RESULT: BLOCKED (no device)"
  exit 3
fi

log ""
log "device: $DEVICE"
log "== flutter build apk --debug =="
if ! (cd "$ROOT" && flutter build apk --debug) 2>&1 | tee -a "$MAIN"; then
  log "RESULT: FAIL (debug APK build)"
  exit 1
fi

APK="$ROOT/build/app/outputs/flutter-apk/app-debug.apk"
if [ ! -f "$APK" ]; then
  log "RESULT: FAIL (missing $APK)"
  exit 1
fi

log ""
log "== install + launch =="
if ! adb_t -s "$DEVICE" install -r "$APK" 2>&1 | tee -a "$MAIN"; then
  log "RESULT: FAIL (adb install)"
  exit 1
fi
adb_t -s "$DEVICE" shell am force-stop com.suno2.gstore >/dev/null 2>&1
if ! adb_t -s "$DEVICE" logcat -c >/dev/null 2>&1; then
  log "RESULT: DEFERRED (logcat clear failed; refusing to trust stale logs)"
  exit 3
fi
adb_t -s "$DEVICE" shell monkey -p com.suno2.gstore 1 >/dev/null 2>&1
sleep 5

log ""
log "== adb shell dumpsys package com.suno2.gstore =="
adb_t -s "$DEVICE" shell dumpsys package com.suno2.gstore 2>&1 | tee -a "$MAIN"

# Fresh, unique dump captured after `logcat -c`: no cached/previous logcat is
# ever consulted on the device path.
LOGCAT_DUMP="$(mktemp "${TMPDIR:-/tmp}/gstore-logcat.XXXXXX")"
cleanup() {
  rm -f "$LOGCAT_DUMP"
}
trap cleanup EXIT
if ! adb_t -s "$DEVICE" logcat -d >"$LOGCAT_DUMP" 2>&1; then
  log "logcat -d failed or timed out (rc=$?)"
fi

log ""
log "== logcat (filtered; init-only lines never pass) =="
grep -E "PlatformHostBridge|PlatformHost|CORE_E_PACKAGE" "$LOGCAT_DUMP" | tee -a "$MAIN"

inventory_verdict "$LOGCAT_DUMP"
exit $?
