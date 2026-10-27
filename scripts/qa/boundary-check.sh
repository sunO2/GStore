#!/usr/bin/env bash
# Core boundary guard — ADR 0001 (`rust/docs/adr/0001-core-boundary.md`).
#
# `gstore_core` is a data service: facts in, decisions out.  It must never call
# platform code.  This guard fails when the de-platformed core re-acquires a
# platform edge, when a deleted platform-adapter file comes back, or when the
# host grows a `JavaVM` dependency outside the four allowlisted files.
#
# Source trees only: build artifacts (`target/`, `.git/`) are skipped.  Compiled
# rlibs/objects keep historical symbol names, so grepping them either fails
# spuriously or (worse) invites a `| grep -v` that passes vacuously.
#
# Every rule distinguishes three states: match (FAIL), no match (PASS), scan
# error / missing target (FAIL).  A missing path or a grep failure can never be
# reported as PASS, and grep's exit code is captured explicitly — no `|| true`.
#
# Usage:  bash scripts/qa/boundary-check.sh        (works from any cwd)
# Exit:   0 = boundary intact, 1 = violation or unusable scan target, 2 = usage.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

CORE_SRC="rust/gstore_core/src"
HOST_SRC="rust/gstore_host/src"

# Files deleted in Plan-Todo 3.  If one is back, the boundary regressed even if
# nothing greps for its symbols yet.
DELETED_HOST_FILES=(
  platform_host
  platform_context
  installer_host
  notification_host
  battery_bridge
  shizuku_bridge
  device_state_bridge
  frame_metrics_bridge
)

# The only host files allowed to mention `JavaVM` / `protect_fd`.
JVM_ALLOWED_FILES=(jvm.rs jni_bridge.rs tun_bridge.rs dl_adapter.rs)

# Layout guard: a missing tree must fail loudly, never scan "nothing" and pass.
for d in "$CORE_SRC" "$HOST_SRC"; do
  if [ ! -d "$d" ]; then
    echo "boundary-check: ERROR: expected source directory is missing: $d" >&2
    echo "boundary-check: (run this script from a GStore checkout; repo root = $REPO_ROOT)" >&2
    echo "boundary-check: FAIL"
    exit 1
  fi
done

FAILED=0
ROWS=()

record() { # status|id|label|detail
  ROWS+=("$1|$2|$3|$4")
  if [ "$1" = "FAIL" ]; then FAILED=1; fi
}

# search <extended-pattern> <path>
#   0 = match (lines on stdout), 1 = no match, 2 = unusable (missing path / grep error)
search() {
  local pattern="$1" path="$2" rc=0
  if [ ! -e "$path" ]; then
    echo "boundary-check: scan target does not exist: $path" >&2
    return 2
  fi
  set +e
  grep -RInE -I --exclude-dir=target --exclude-dir=.git -- "$pattern" "$path"
  rc=$?
  set -e
  if [ "$rc" -gt 1 ]; then
    echo "boundary-check: grep failed (rc=$rc) scanning $path" >&2
    return 2
  fi
  return "$rc"
}

shorten() {
  local s="$1"
  s="${s//$'\n'/; }"
  if [ "${#s}" -gt 400 ]; then s="${s:0:400}..."; fi
  printf '%s' "$s"
}

# rule_no_match <id> <label> <pattern> <path>
rule_no_match() {
  local id="$1" label="$2" pattern="$3" path="$4" out="" rc=0
  set +e
  out="$(search "$pattern" "$path")"
  rc=$?
  set -e
  case "$rc" in
    0) record FAIL "$id" "$label" "matched /$pattern/ -> $(shorten "$out")" ;;
    1) record PASS "$id" "$label" "no match for /$pattern/ in $path" ;;
    *) record FAIL "$id" "$label" "scan unusable (missing target or grep error): $path" ;;
  esac
}

# ---- rule 1: no platform symbols inside the core ----
rule_no_match 1 "core has no platform symbols" \
  'PlatformHost|InstallerPort|Capability::|jni::' "$CORE_SRC"

# ---- rule 2: deleted platform-adapter files stay deleted ----
present=()
for f in "${DELETED_HOST_FILES[@]}"; do
  [ -e "$HOST_SRC/$f.rs" ] && present+=("$HOST_SRC/$f.rs")
done
if [ "${#present[@]}" -eq 0 ]; then
  record PASS 2 "deleted platform adapters absent" \
    "none of the ${#DELETED_HOST_FILES[@]} deleted files exists under $HOST_SRC"
else
  record FAIL 2 "deleted platform adapters absent" \
    "stale file(s) present: ${present[*]}"
fi

# ---- rule 3: JavaVM only in the four allowlisted host files ----
jvm_out=""
jvm_rc=0
set +e
jvm_out="$(search 'JavaVM' "$HOST_SRC")"
jvm_rc=$?
set -e
case "$jvm_rc" in
  1)
    record PASS 3 "JavaVM confined to allowlist" \
      "no JavaVM reference under $HOST_SRC"
    ;;
  2)
    record FAIL 3 "JavaVM confined to allowlist" \
      "scan unusable (missing target or grep error): $HOST_SRC"
    ;;
  0)
    bad=()
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      file="${line%%:*}"
      base="$(basename "$file")"
      allowed=0
      for a in "${JVM_ALLOWED_FILES[@]}"; do
        if [ "$base" = "$a" ]; then allowed=1; break; fi
      done
      [ "$allowed" -eq 0 ] && bad+=("$line")
    done <<< "$jvm_out"
    if [ "${#bad[@]}" -eq 0 ]; then
      record PASS 3 "JavaVM confined to allowlist" \
        "matches only in {${JVM_ALLOWED_FILES[*]}}"
    else
      record FAIL 3 "JavaVM confined to allowlist" \
        "outside {${JVM_ALLOWED_FILES[*]}} -> $(shorten "$(printf '%s\n' "${bad[@]}")")"
    fi
    ;;
esac

# ---- rule 4: no installer entrypoint left on the host ----
rule_no_match 4 "no begin_install() anywhere in rust/" 'begin_install\(' rust

# ---- rule 5: the deleted platform context module is gone ----
rule_no_match 5 "no platform_context reference in rust/" 'platform_context' rust

# ---- informational: protect_fd is a module-ABI primitive, not a core one ----
# Non-fatal by design.  Module crates (gstore_mod_*) legitimately implement the
# ABI slot, and docs/tests mention it by name, so a fatal "only these files"
# assertion could only be satisfied by weakening the check.  What matters for
# the boundary is that `gstore_core` never sees it; any core hit is reported.
protect_out=""
protect_rc=0
set +e
protect_out="$(search 'protect_fd' rust)"
protect_rc=$?
set -e
case "$protect_rc" in
  1)
    record PASS 6 "protect_fd stays outside the core (informational)" \
      "no protect_fd reference under rust/"
    ;;
  2)
    record NOTE 6 "protect_fd stays outside the core (informational)" \
      "scan skipped: rust/ unusable"
    ;;
  0)
    core_hits=()
    other_hits=()
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      file="${line%%:*}"
      base="$(basename "$file")"
      case "$file" in
        rust/gstore_core/*) core_hits+=("$line") ;;
        rust/gstore_contract/*) ;;
        rust/gstore_host/src/*)
          keep=0
          for a in "${JVM_ALLOWED_FILES[@]}"; do
            if [ "$base" = "$a" ]; then keep=1; break; fi
          done
          [ "$keep" -eq 0 ] && other_hits+=("$line")
          ;;
        *) other_hits+=("$line") ;;
      esac
    done <<< "$protect_out"
    if [ "${#core_hits[@]}" -gt 0 ]; then
      record FAIL 6 "protect_fd stays outside the core (informational)" \
        "core references protect_fd -> $(shorten "$(printf '%s\n' "${core_hits[@]}")")"
    elif [ "${#other_hits[@]}" -eq 0 ]; then
      record PASS 6 "protect_fd stays outside the core (informational)" \
        "only gstore_contract + {${JVM_ALLOWED_FILES[*]}}"
    else
      record NOTE 6 "protect_fd stays outside the core (informational)" \
        "expected module-ABI/docs sites, core clean: $(shorten "$(printf '%s\n' "${other_hits[@]}")")"
    fi
    ;;
esac

# ---- report ----
printf '\n%-5s %-5s %s\n' "rule" "state" "check"
printf '%s\n' "------------------------------------------------------------------------"
for r in "${ROWS[@]}"; do
  IFS='|' read -r status id label detail <<< "$r"
  printf '%-5s %-5s %s\n' "$id" "$status" "$label"
  printf '            %s\n' "$detail"
done
printf '%s\n' "------------------------------------------------------------------------"

if [ "$FAILED" -ne 0 ]; then
  echo "boundary-check: FAIL (core boundary violated; see rules marked FAIL)"
  exit 1
fi
echo "boundary-check: OK"
