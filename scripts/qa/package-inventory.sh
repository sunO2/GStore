#!/usr/bin/env bash
# Todo 8 evidence: package inventory bridge contract + device instrumentation.
#
# Exit codes: 0 = Rust proof passed and a device run passed; 1 = Rust proof
# failed; 3 = BLOCKED (no Android device attached; never faked).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVIDENCE="$ROOT/target/test-evidence"
MAIN="$EVIDENCE/67-package.txt"
DENIED="$EVIDENCE/67-package-denied.txt"
MANIFEST="$ROOT/rust/gstore_host/Cargo.toml"
mkdir -p "$EVIDENCE"
: >"$MAIN"

log() {
  printf '%s\n' "$*" | tee -a "$MAIN"
}

run_rust() {
  local label="$1"
  shift
  log ""
  log "== $label =="
  "$@" 2>&1 | tee -a "$MAIN"
  return "${PIPESTATUS[0]}"
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
if command -v adb >/dev/null 2>&1; then
  adb devices | tee -a "$MAIN"
  DEVICE="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
else
  log "adb: not found"
  DEVICE=""
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
if ! adb -s "$DEVICE" install -r "$APK" 2>&1 | tee -a "$MAIN"; then
  log "RESULT: FAIL (adb install)"
  exit 1
fi
adb -s "$DEVICE" shell am force-stop com.suno2.gstore >/dev/null 2>&1
adb -s "$DEVICE" logcat -c >/dev/null 2>&1
adb -s "$DEVICE" shell monkey -p com.suno2.gstore 1 >/dev/null 2>&1
sleep 5

log ""
log "== adb shell dumpsys package com.suno2.gstore =="
adb -s "$DEVICE" shell dumpsys package com.suno2.gstore 2>&1 | tee -a "$MAIN"

log ""
log "== logcat PlatformHostBridge init =="
adb -s "$DEVICE" logcat -d 2>&1 | grep -E "PlatformHostBridge|PlatformHost|CORE_E_PACKAGE" | tee -a "$MAIN"

if adb -s "$DEVICE" logcat -d 2>&1 | grep -q "PlatformHostBridge"; then
  log "RESULT: PASS (device bridge init observed)"
  exit 0
fi

log "RESULT: BLOCKED (device attached but bridge init log not observed)"
exit 3
