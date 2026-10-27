#!/usr/bin/env bash
# ARM64 device/emulator smoke test.
#
# Checks (all issued through `adb`):
#   install -> launch -> process alive -> channel list -> search -> detail ->
#   local pack -> env migration -> parity -> flags (see modes below).
#
# Three matrix modes (the flag check is mode-aware):
#   (default, pre-removal)   the legacy route is still reachable and the
#                            core-write guard must stay untouched:
#                              flags-off  core_writes rows == 0
#   --post-removal           the download/install cutover has happened.  The
#                            download+install flags are ON, the other four stay
#                            OFF, and the core mirror owns every live row:
#                              core-ownership  non-terminal download_task rows
#                                              exist and all carry
#                                              module_task_id; install attempts
#                                              carry install_session_id;
#                                              core_writes == {download,install}
#                              flags-on        core_writes has download+install
#                                              and none of
#                                              channel/catalog/update/js_channel
#   --closeout               the Wave 6 durable cutover has flipped all six
#                            domains; the closeout assertion is distinct from
#                            the pre-cutover `flags-on`:
#                              flags-on-closeout  core_writes domains ==
#                                                 {channel,js_channel,catalog,
#                                                  update,download,install}
#                                                 (exactly six rows)
#
# `flags-off` is deliberately NOT part of the post-removal/closeout sets (a
# post-removal device legitimately has core_writes rows), and `flags-on`
# deliberately keeps the pre-cutover two-domain contract, so the modes cannot
# contradict each other.
#
# Deep channel probes assert the debug CoreSmoke fixtures, never mere table
# existence:
#   channel-list    channels.key='smoke_github'                    >= 1
#   channel-search  channel_apps(smoke_github,'Smoke App')         >= 1
#   channel-detail  app_id == 'smoke/app' + columns app_id/name exist
#   local-pack      channel_packs.key='js_smoke'                   >= 1
#   env-migration   channel_env.channel_key='js_smoke'             >= 1
#   parity          PRAGMA user_version >= 1 and integrity_check = ok
#   flags-off       core_writes rows                                == 0
#   core-ownership  download_task/module_task_id/install_session_id + core_writes
#   flags-on        core_writes domains == {download,install}
#   flags-on-closeout  core_writes domains == all six (closeout mode only)
#
# Device-only probes (never part of --db / --self-test):
#   notification    drive a download, then
#                     adb shell dumpsys notification --noredact
#                   must contain a $PKG record with channel=download_progress
#                   and a foreground-service entry (channel=foreground_service
#                   or isForegroundService=true); then cancel
#                   (`adb shell am force-stop $PKG` or the in-app cancel) and
#                   assert every download/foreground marker is gone.
#   needs_restart   remove <files>/gstore_mods/download/download.db, relaunch,
#                   assert the previously non-terminal rows are `needs_restart`
#                   and the download center surfaces them (已暂停), then drive a
#                   fresh download and assert a new module_task_id appears.
#   statvfs         a production build cannot be forced full (FORCED_FREE_BYTES
#                   is cfg(test)-only, rust/gstore_core/src/db.rs:36-50), so this
#                   is BLOCKED (cannot force full disk) unless GSTORE_LOW_DISK=1
#                   on a genuinely low-disk device.
#   install_events  drive an install and assert the Dart subscriber receives the
#                   gstore/install_events EventChannel payload
#                   (`InstallManager: install_events 已上报` in logcat, or the
#                   core install row reaching installed with installed_at).
#
# A zero/missing row or column is FAIL (exit 1), never SKIP and never PASS
# (post-removal: zero non-terminal mirror rows and zero install attempts are
# failures, because the matrix has just downloaded and installed an app).
# BLOCKED/SKIP is reserved for genuinely unavailable probes (no adb/device,
# non-ARM64, release APK not debuggable, DB not found, host sqlite3 missing) and
# for the un-forceable statvfs case; a blocked check is never a pass.
#
# Deep channel probes use one of two adb-visible contracts:
#   1. --instrumentation PKG/RUNNER
#        adb shell am instrument -w -e check <name> <runner>
#        The runner must print `OK (<check>)` on success.
#   2. debug APK + `adb shell run-as` (fallback)
#        Pulls the app's gstore_core.db and checks the Wave 0/1 smoke rows with
#        the host sqlite3 binary.
#
# Test without a phone:
#   scripts/qa/device-smoke.sh --self-test
#       builds one valid and several broken sqlite fixtures in a temp dir and
#       asserts valid=PASS, broken=FAIL/exit 1.  The post-removal fixtures are
#       exercised with --post-removal semantics too.
#   scripts/qa/device-smoke.sh --db PATH
#       runs the same deep SQL checks against a local database file.
#   scripts/qa/device-smoke.sh --self-test --post-removal
#       self-test only the post-removal check set.
#   scripts/qa/device-smoke.sh --self-test --closeout
#       also exercise the closeout check set (flags-on-closeout).
#   --self-test also runs the notification matcher on a good and a bad simulated
#   dumpsys, proving the named probe can go red without a device.
#
# Notification probe, exact adb recipe (device attached):
#   adb shell am start -W -n com.suno2.gstore/.MainActivity
#   # start a download in the UI (search -> app -> download), then:
#   adb shell dumpsys notification --noredact \
#     | grep -E 'pkg=com.suno2.gstore|channel=download_progress|channel=foreground_service|isForegroundService'
#   # cancel: in-app cancel, or the script's deterministic fallback:
#   adb shell am force-stop com.suno2.gstore
#   adb shell dumpsys notification --noredact \
#     | grep -E 'channel=download_progress|channel=foreground_service' \
#     || echo 'no download notification (removed)'
#
# Exit-code contract (a blocked/skipped check is never a pass):
#   0  every check ran and passed
#   1  a check ran and failed (including zero/missing smoke rows)
#   3  BLOCKED/SKIPPED: no adb, no adb device, non-ARM64 device, or deep probes
#      genuinely unavailable (release build / instrumentation not provided)
#   2  usage error
#
# Usage:
#   scripts/qa/device-smoke.sh [--apk PATH] [--package PKG]
#       [--instrumentation PKG/RUNNER] [--timeout SECONDS] [--no-install]
#       [--post-removal | --closeout] [--db PATH | --self-test]
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

PKG="com.suno2.gstore"
APK=""
INSTRUMENTATION=""
TIMEOUT=120
DO_INSTALL=1
DB_PATH=""
SELFTEST=0
POST_REMOVAL=0
CLOSEOUT=0
MODE="pre"
NOTIFY_WAIT="${GSTORE_NOTIFY_WAIT:-60}"

PRE_CHECKS="channel-list channel-search channel-detail local-pack env-migration parity flags-off"
POST_CHECKS="channel-list channel-search channel-detail local-pack env-migration parity core-ownership flags-on"
CLOSEOUT_CHECKS="channel-list channel-search channel-detail local-pack env-migration parity core-ownership flags-on-closeout"

usage() {
  cat <<'EOF'
usage: scripts/qa/device-smoke.sh [options]

  --apk PATH                APK to install (default: search build outputs)
  --package PKG             app package (default: com.suno2.gstore)
  --instrumentation PKG/RUNNER
                            use `am instrument` deep probes instead of sqlite
  --timeout SECONDS         bound for each adb/sqlite call (default: 120)
  --no-install              skip the install step
  --post-removal            assert the post-cutover matrix: core ownership +
                            flags-on instead of flags-off (see header)
  --closeout                assert the Wave 6 cutover matrix: core ownership +
                            flags-on-closeout (all six domains; see header)
  --db PATH                 run only the deep SQL checks against a local DB
  --self-test               build valid/broken fixtures and assert PASS/FAIL
  -h, --help                show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --package) PKG="$2"; shift 2 ;;
    --instrumentation) INSTRUMENTATION="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --no-install) DO_INSTALL=0; shift ;;
    --post-removal) POST_REMOVAL=1; shift ;;
    --closeout) CLOSEOUT=1; shift ;;
    --db) DB_PATH="$2"; shift 2 ;;
    --self-test) SELFTEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$CLOSEOUT" -eq 1 ] && [ "$POST_REMOVAL" -eq 1 ]; then
  echo "ERROR: --post-removal and --closeout are mutually exclusive" >&2
  usage >&2
  exit 2
fi

if [ "$CLOSEOUT" -eq 1 ]; then
  MODE="closeout"
  DEEP_CHECKS="$CLOSEOUT_CHECKS"
elif [ "$POST_REMOVAL" -eq 1 ]; then
  MODE="post"
  DEEP_CHECKS="$POST_CHECKS"
else
  MODE="pre"
  DEEP_CHECKS="$PRE_CHECKS"
fi

if [ "$SELFTEST" -eq 1 ] && [ -n "$DB_PATH" ]; then
  echo "ERROR: --self-test and --db are mutually exclusive" >&2
  usage >&2
  exit 2
fi

PASSED=0
FAILED=0
SKIPPED=0
BLOCKED_COUNT=0

pass() { echo "PASS: $*"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP: $*"; SKIPPED=$((SKIPPED + 1)); }
blocked() { echo "BLOCKED: $*"; SKIPPED=$((SKIPPED + 1)); BLOCKED_COUNT=$((BLOCKED_COUNT + 1)); }
blocked_no_device() { echo "BLOCKED (no adb device): $*"; SKIPPED=$((SKIPPED + 1)); BLOCKED_COUNT=$((BLOCKED_COUNT + 1)); }

report_blocked_device_cases() {
  echo "BLOCKED (no adb device): notification probe -> adb shell dumpsys notification --noredact (then grep pkg=$PKG + download_progress/foreground_service)"
  echo "BLOCKED (no adb device): needs_restart -> adb shell run-as $PKG mv files/gstore_mods/download/download.db files/gstore_mods/download/download.db.smoke-bak && adb shell am start -W -n $PKG/.MainActivity"
  echo "BLOCKED (no adb device): statvfs -> adb shell df -k /data; adb logcat -d | grep CORE_E_SNAPSHOT_DISK"
  echo "BLOCKED (no adb device): install_events -> adb logcat -c; <install>; adb logcat -d | grep 'InstallManager: install_events 已上报'"
}

expected_write_domains() {
  if [ "$MODE" = "closeout" ]; then
    printf '%s' "catalog,channel,download,install,js_channel,update"
  else
    printf '%s' "download,install"
  fi
}

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

# ---------------------------------------------------------------------------
# Deep SQL checks (shared by the device DB path, --db, and --self-test).
# Every check prints the exact SQL and the value it got, then PASS/FAIL.
# ---------------------------------------------------------------------------

SQL_OUT=""
SQL_RC=0

sql_value() {
  local db="$1" sql="$2"
  printf 'SQL: %s\n' "$sql"
  set +e
  SQL_OUT="$(run_bounded sqlite3 "$db" "$sql" 2>&1)"
  SQL_RC=$?
  set -e
  printf 'value: %s\n' "${SQL_OUT:-<empty>}"
  printf 'sqlite_exit: %s\n' "$SQL_RC"
}

is_uint() { printf '%s' "$1" | grep -Eq '^[0-9]+$'; }

db_check_one() {
  local db="$1" check="$2"
  local sql cols cols_rc version version_rc integrity integrity_rc
  local nonterminal nonterminal_rc orphan orphan_rc
  local install_total install_rc install_orphan install_orphan_rc
  local domains domains_rc armed armed_rc other other_rc

  echo
  echo "== probe (sqlite): $check =="
  case "$check" in
    channel-list)
      sql="SELECT COUNT(*) FROM channels WHERE key='smoke_github';"
      sql_value "$db" "$sql"
      if [ "$SQL_RC" -eq 0 ] && is_uint "$SQL_OUT" && [ "$SQL_OUT" -ge 1 ]; then
        pass "channel list (channels key=smoke_github rows=$SQL_OUT)"
      else
        fail "channel list (expected key=smoke_github rows>=1; rc=$SQL_RC value='${SQL_OUT:-<empty>}')"
      fi
      ;;
    channel-search)
      sql="SELECT COUNT(*) FROM channel_apps WHERE channel_key='smoke_github' AND name='Smoke App';"
      sql_value "$db" "$sql"
      if [ "$SQL_RC" -eq 0 ] && is_uint "$SQL_OUT" && [ "$SQL_OUT" -ge 1 ]; then
        pass "channel search (channel_apps smoke_github/'Smoke App' rows=$SQL_OUT)"
      else
        fail "channel search (expected smoke_github/'Smoke App' rows>=1; rc=$SQL_RC value='${SQL_OUT:-<empty>}')"
      fi
      ;;
    channel-detail)
      sql="SELECT COUNT(*) FROM pragma_table_info('channel_apps') WHERE name IN ('app_id','name');"
      sql_value "$db" "$sql"
      cols="$SQL_OUT"
      cols_rc="$SQL_RC"
      sql="SELECT app_id FROM channel_apps WHERE channel_key='smoke_github' AND name='Smoke App';"
      sql_value "$db" "$sql"
      if [ "$cols_rc" -eq 0 ] && [ "$cols" = "2" ] && [ "$SQL_RC" -eq 0 ] && [ "$SQL_OUT" = "smoke/app" ]; then
        pass "channel detail (app_id=smoke/app; app_id+name columns present)"
      else
        fail "channel detail (expected app_id/name columns and app_id=smoke/app; columns='${cols:-<empty>}' col_rc=$cols_rc app_id='${SQL_OUT:-<empty>}' rc=$SQL_RC)"
      fi
      ;;
    local-pack)
      sql="SELECT COUNT(*) FROM channel_packs WHERE key='js_smoke';"
      sql_value "$db" "$sql"
      if [ "$SQL_RC" -eq 0 ] && is_uint "$SQL_OUT" && [ "$SQL_OUT" -ge 1 ]; then
        pass "local pack (channel_packs key=js_smoke rows=$SQL_OUT)"
      else
        fail "local pack (expected key=js_smoke rows>=1; rc=$SQL_RC value='${SQL_OUT:-<empty>}')"
      fi
      ;;
    env-migration)
      sql="SELECT COUNT(*) FROM channel_env WHERE channel_key='js_smoke';"
      sql_value "$db" "$sql"
      if [ "$SQL_RC" -eq 0 ] && is_uint "$SQL_OUT" && [ "$SQL_OUT" -ge 1 ]; then
        pass "env migration (channel_env channel_key=js_smoke rows=$SQL_OUT)"
      else
        fail "env migration (expected channel_key=js_smoke rows>=1; rc=$SQL_RC value='${SQL_OUT:-<empty>}')"
      fi
      ;;
    parity)
      sql="PRAGMA user_version;"
      sql_value "$db" "$sql"
      version="$SQL_OUT"
      version_rc="$SQL_RC"
      sql="PRAGMA integrity_check;"
      sql_value "$db" "$sql"
      integrity="$SQL_OUT"
      integrity_rc="$SQL_RC"
      if [ "$version_rc" -eq 0 ] && is_uint "$version" && [ "$version" -ge 1 ] \
        && [ "$integrity_rc" -eq 0 ] && [ "$integrity" = "ok" ]; then
        pass "parity (user_version=$version, integrity=ok)"
      else
        fail "parity (expected user_version>=1 and integrity=ok; version='${version:-<empty>}' rc=$version_rc integrity='${integrity:-<empty>}' rc=$integrity_rc)"
      fi
      ;;
    flags-off)
      sql="SELECT COUNT(*) FROM core_writes;"
      sql_value "$db" "$sql"
      if [ "$SQL_RC" -eq 0 ] && [ "$SQL_OUT" = "0" ]; then
        pass "flags-off (core_writes empty; legacy-write guard stays disabled)"
      else
        fail "flags-off (expected core_writes=0; rc=$SQL_RC value='${SQL_OUT:-<empty>}')"
      fi
      ;;
    core-ownership)
      sql="SELECT COUNT(*) FROM download_task WHERE status NOT IN ('completed','cancelled','removed','failed');"
      sql_value "$db" "$sql"
      nonterminal="$SQL_OUT"
      nonterminal_rc="$SQL_RC"
      sql="SELECT COUNT(*) FROM download_task WHERE status NOT IN ('completed','cancelled','removed','failed') AND (module_task_id IS NULL OR module_task_id='');"
      sql_value "$db" "$sql"
      orphan="$SQL_OUT"
      orphan_rc="$SQL_RC"
      sql="SELECT COUNT(*) FROM download_task WHERE install_status IN ('pending','installed');"
      sql_value "$db" "$sql"
      install_total="$SQL_OUT"
      install_rc="$SQL_RC"
      sql="SELECT COUNT(*) FROM download_task WHERE install_status IN ('pending','installed') AND (install_session_id IS NULL OR install_session_id='');"
      sql_value "$db" "$sql"
      install_orphan="$SQL_OUT"
      install_orphan_rc="$SQL_RC"
      sql="SELECT COALESCE(group_concat(domain, ','), '') FROM (SELECT domain FROM core_writes ORDER BY domain);"
      sql_value "$db" "$sql"
      domains="$SQL_OUT"
      domains_rc="$SQL_RC"
      domains_expected="$(expected_write_domains)"
      if [ "$nonterminal_rc" -eq 0 ] && is_uint "$nonterminal" && [ "$nonterminal" -ge 1 ] \
        && [ "$orphan_rc" -eq 0 ] && [ "$orphan" = "0" ] \
        && [ "$install_rc" -eq 0 ] && is_uint "$install_total" && [ "$install_total" -ge 1 ] \
        && [ "$install_orphan_rc" -eq 0 ] && [ "$install_orphan" = "0" ] \
        && [ "$domains_rc" -eq 0 ] && [ "$domains" = "$domains_expected" ]; then
        pass "core ownership (non-terminal=$nonterminal all module_task_id; install-attempts=$install_total all install_session_id; core_writes=$domains)"
      else
        fail "core ownership (need non-terminal>=1 with module_task_id, install-attempts>=1 with install_session_id, core_writes=$domains_expected; non-terminal='${nonterminal:-<empty>}' rc=$nonterminal_rc orphan='${orphan:-<empty>}' rc=$orphan_rc install='${install_total:-<empty>}' rc=$install_rc install-orphan='${install_orphan:-<empty>}' rc=$install_orphan_rc domains='${domains:-<empty>}' rc=$domains_rc)"
      fi
      ;;
    flags-on)
      sql="SELECT COUNT(*) FROM core_writes WHERE domain IN ('download','install');"
      sql_value "$db" "$sql"
      armed="$SQL_OUT"
      armed_rc="$SQL_RC"
      sql="SELECT COUNT(*) FROM core_writes WHERE domain IN ('channel','catalog','update','js_channel');"
      sql_value "$db" "$sql"
      other="$SQL_OUT"
      other_rc="$SQL_RC"
      if [ "$armed_rc" -eq 0 ] && [ "$armed" = "2" ] \
        && [ "$other_rc" -eq 0 ] && [ "$other" = "0" ]; then
        pass "flags-on (download+install armed; channel/catalog/update/js_channel off)"
      else
        fail "flags-on (expected download+install=2 and other-four=0; armed='${armed:-<empty>}' rc=$armed_rc other='${other:-<empty>}' rc=$other_rc)"
      fi
      ;;
    flags-on-closeout)
      sql="SELECT COUNT(*) FROM core_writes WHERE domain IN ('channel','js_channel','catalog','update','download','install');"
      sql_value "$db" "$sql"
      six="$SQL_OUT"
      six_rc="$SQL_RC"
      sql="SELECT COUNT(*) FROM core_writes;"
      sql_value "$db" "$sql"
      total="$SQL_OUT"
      total_rc="$SQL_RC"
      if [ "$six_rc" -eq 0 ] && [ "$six" = "6" ] \
        && [ "$total_rc" -eq 0 ] && [ "$total" = "6" ]; then
        pass "flags-on-closeout (all six domains armed: channel,js_channel,catalog,update,download,install)"
      else
        fail "flags-on-closeout (expected exactly six core_writes domains channel/js_channel/catalog/update/download/install; six='${six:-<empty>}' rc=$six_rc total='${total:-<empty>}' rc=$total_rc)"
      fi
      ;;
    *)
      fail "unknown deep check: $check"
      ;;
  esac
}

# Runs all deep checks against one sqlite file. Returns 1 if any check failed.
run_db_checks() {
  local db="$1" check
  for check in $DEEP_CHECKS; do
    db_check_one "$db" "$check"
  done
  [ "$FAILED" -eq 0 ]
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
  local tmp db_path pull_rc
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gstore-device-smoke.XXXXXX")"

  if ! command -v sqlite3 >/dev/null 2>&1; then
    rm -rf "$tmp"
    skip "deep channel probes unavailable: host sqlite3 not installed"
    return 0
  fi

  if ! adb_cmd shell run-as "$PKG" true >/dev/null 2>&1; then
    rm -rf "$tmp"
    skip "deep channel probes unavailable: $PKG is not debuggable (release APK); pass --instrumentation PKG/RUNNER"
    return 0
  fi

  set +e
  db_path="$(adb_cmd shell run-as "$PKG" find . -name gstore_core.db 2>/dev/null | tr -d '\r' | head -n 1)"
  set -e
  if [ -z "$db_path" ]; then
    rm -rf "$tmp"
    skip "deep channel probes unavailable: gstore_core.db not found under the app data dir"
    return 0
  fi

  set +e
  adb_cmd exec-out run-as "$PKG" cat "$db_path" > "$tmp/core.db" 2>/dev/null
  pull_rc=$?
  set -e
  if [ "$pull_rc" -ne 0 ] || [ ! -s "$tmp/core.db" ]; then
    rm -rf "$tmp"
    skip "deep channel probes unavailable: could not pull $db_path"
    return 0
  fi

  run_db_checks "$tmp/core.db" || true
  rm -rf "$tmp"
}

pull_core_db() {
  local dest="$1" db_path pull_rc
  set +e
  db_path="$(adb_cmd shell run-as "$PKG" find . -name gstore_core.db 2>/dev/null | tr -d '\r' | head -n 1)"
  if [ -n "$db_path" ]; then
    adb_cmd exec-out run-as "$PKG" cat "$db_path" > "$dest" 2>/dev/null
    pull_rc=$?
  else
    pull_rc=1
  fi
  set -e
  [ "$pull_rc" -eq 0 ] && [ -s "$dest" ]
}

notification_dump() {
  adb_cmd shell dumpsys notification --noredact 2>/dev/null || true
}

device_notification_probe() {
  local dump="" i=0
  echo
  echo "== probe (device-only): download notifications + foreground service =="
  echo "operator: start a download in $PKG; waiting up to ${NOTIFY_WAIT}s for channel=download_progress"
  while [ "$i" -lt "$NOTIFY_WAIT" ]; do
    dump="$(notification_dump)"
    if printf '%s\n' "$dump" | notification_scope_pkg | grep -Fq 'download_progress'; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  notification_eval_present "$dump" || true

  echo "cancel: in-app cancel, or the deterministic fallback: adb shell am force-stop $PKG"
  adb_cmd shell am force-stop "$PKG" >/dev/null 2>&1 || true
  i=0
  while [ "$i" -lt 10 ]; do
    dump="$(notification_dump)"
    if ! printf '%s\n' "$dump" | notification_scope_pkg | grep -Eq 'download_progress|foreground_service|isForegroundService=true'; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  notification_eval_removed "$dump" || true
}

device_needs_restart_case() {
  local tmp module_db core_db before_ids before_total after_ids after_total=0
  local all_ok=1 id waited=0 window_ok=0
  echo
  echo "== matrix case (device-only): needs_restart one-way door =="
  echo "adb: adb shell run-as $PKG mv files/gstore_mods/download/download.db files/gstore_mods/download/download.db.smoke-bak"
  echo "adb: adb shell am force-stop $PKG && adb shell am start -W -n $PKG/.MainActivity"
  echo "adb: adb exec-out run-as $PKG cat files/gstore_core.db > core.db"
  if ! command -v sqlite3 >/dev/null 2>&1; then
    blocked "needs_restart case needs host sqlite3"
    return
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gstore-needs-restart.XXXXXX")"
  module_db="files/gstore_mods/download/download.db"
  core_db="$tmp/core.db"
  if ! adb_cmd shell run-as "$PKG" test -f "$module_db" >/dev/null 2>&1; then
    blocked "module DB $module_db not found; start a download before the matrix"
    rm -rf "$tmp"
    return
  fi
  if ! pull_core_db "$core_db"; then
    blocked "could not pull gstore_core.db"
    rm -rf "$tmp"
    return
  fi
  before_ids="$(sqlite3 "$core_db" "SELECT COALESCE(group_concat(module_task_id, ','), '') FROM download_task WHERE status NOT IN ('completed','cancelled','removed','failed') AND module_task_id IS NOT NULL AND module_task_id <> '';" 2>/dev/null || true)"
  before_total="$(sqlite3 "$core_db" "SELECT COUNT(*) FROM download_task WHERE module_task_id IS NOT NULL AND module_task_id <> '';" 2>/dev/null || true)"
  if [ -z "$before_ids" ] || ! is_uint "$before_total"; then
    blocked "no non-terminal download_task rows to drive the one-way door"
    rm -rf "$tmp"
    return
  fi

  adb_cmd shell run-as "$PKG" mv "$module_db" "$module_db.smoke-bak" >/dev/null 2>&1 || true
  adb_cmd shell am force-stop "$PKG" >/dev/null 2>&1 || true
  adb_cmd shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1 || true
  sleep 3
  if ! pull_core_db "$core_db"; then
    blocked "could not pull gstore_core.db after the module DB was removed"
    rm -rf "$tmp"
    return
  fi
  after_ids="$(sqlite3 "$core_db" "SELECT COALESCE(group_concat(module_task_id, ','), '') FROM download_task WHERE status='needs_restart';" 2>/dev/null || true)"
  for id in ${before_ids//,/ }; do
    case ",$after_ids," in
      *",$id,"*) ;;
      *) all_ok=0 ;;
    esac
  done
  if [ "$all_ok" -eq 1 ]; then
    pass "needs_restart one-way door (previously non-terminal rows now status=needs_restart: $before_ids)"
  else
    fail "needs_restart one-way door (expected $before_ids in status=needs_restart; got '${after_ids:-<empty>}')"
  fi

  adb_cmd shell uiautomator dump /sdcard/gstore-window.xml >/dev/null 2>&1 || true
  if adb_cmd pull /sdcard/gstore-window.xml "$tmp/window.xml" >/dev/null 2>&1 && [ -s "$tmp/window.xml" ]; then
    window_ok=1
  fi
  if [ "$window_ok" -eq 1 ] && grep -Fq '已暂停' "$tmp/window.xml"; then
    pass "needs_restart surfaced in the download center (已暂停)"
  elif [ "$window_ok" -eq 1 ]; then
    fail "needs_restart not surfaced in the download center (no 已暂停 in the UI dump)"
  else
    blocked "UI dump unavailable; open the download center and rerun to assert needs_restart is surfaced"
  fi

  echo "operator: start a fresh download now; waiting up to ${NOTIFY_WAIT}s for a new module_task_id"
  while [ "$waited" -lt "$NOTIFY_WAIT" ]; do
    sleep 2
    waited=$((waited + 2))
    if ! pull_core_db "$core_db"; then
      continue
    fi
    after_total="$(sqlite3 "$core_db" "SELECT COUNT(*) FROM download_task WHERE module_task_id IS NOT NULL AND module_task_id <> '';" 2>/dev/null || true)"
    if is_uint "$after_total" && [ "$after_total" -gt "$before_total" ]; then
      pass "fresh download created a new task after needs_restart ($before_total -> $after_total)"
      break
    fi
  done
  if ! is_uint "$after_total" || [ "$after_total" -le "$before_total" ]; then
    blocked "fresh download not observed within ${NOTIFY_WAIT}s; drive one and rerun"
  fi

  if adb_cmd shell run-as "$PKG" test -f "$module_db" >/dev/null 2>&1; then
    adb_cmd shell run-as "$PKG" rm "$module_db.smoke-bak" >/dev/null 2>&1 || true
  else
    adb_cmd shell run-as "$PKG" mv "$module_db.smoke-bak" "$module_db" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}

device_statvfs_case() {
  local free_kb waited=0
  echo
  echo "== matrix case (device-only): on-device statvfs preflight =="
  echo "adb: adb shell df -k /data"
  if [ "${GSTORE_LOW_DISK:-0}" != "1" ]; then
    blocked "cannot force full disk (FORCED_FREE_BYTES is cfg(test)-only; set GSTORE_LOW_DISK=1 only on a genuinely low-disk device)"
    return
  fi
  free_kb="$(adb_cmd shell df -k /data 2>/dev/null | awk 'NR==2 {print $4}' | tr -d '\r' || true)"
  if ! is_uint "$free_kb"; then
    blocked "cannot read free KiB from df -k /data"
    return
  fi
  if [ "$free_kb" -gt 65536 ]; then
    blocked "device has ${free_kb}KiB free; not a low-disk device"
    return
  fi
  echo "adb: adb logcat -c; <trigger a snapshot restore/import>; adb logcat -d | grep CORE_E_SNAPSHOT_DISK"
  adb_cmd logcat -c >/dev/null 2>&1 || true
  while [ "$waited" -lt "$NOTIFY_WAIT" ]; do
    if adb_cmd logcat -d 2>/dev/null | grep -Fq 'CORE_E_SNAPSHOT_DISK'; then
      pass "statvfs preflight rejected the restore with CORE_E_SNAPSHOT_DISK (free=${free_kb}KiB)"
      return
    fi
    sleep 2
    waited=$((waited + 2))
  done
  fail "statvfs preflight did not report CORE_E_SNAPSHOT_DISK (free=${free_kb}KiB)"
}

device_install_events_case() {
  local tmp dump waited=0 saw
  echo
  echo "== matrix case (device-only): install_events EventChannel =="
  echo "adb: adb logcat -c; <install an app>; adb logcat -d | grep 'InstallManager: install_events 已上报'"
  adb_cmd logcat -c >/dev/null 2>&1 || true
  while [ "$waited" -lt "$NOTIFY_WAIT" ]; do
    dump="$(adb_cmd logcat -d 2>/dev/null || true)"
    if printf '%s' "$dump" | grep -Fq 'install_events 已上报'; then
      pass "install_events delivered to Dart (InstallManager: install_events 已上报)"
      return
    fi
    sleep 2
    waited=$((waited + 2))
  done
  if command -v sqlite3 >/dev/null 2>&1; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/gstore-install-events.XXXXXX")"
    if pull_core_db "$tmp/core.db"; then
      saw="$(sqlite3 "$tmp/core.db" "SELECT COUNT(*) FROM download_task WHERE install_status='installed' AND installed_at IS NOT NULL;" 2>/dev/null || true)"
      rm -rf "$tmp"
      if is_uint "$saw" && [ "$saw" -ge 1 ]; then
        pass "install_events delivered to Dart (core install row installed + installed_at=$saw)"
        return
      fi
    else
      rm -rf "$tmp"
    fi
  fi
  fail "install_events not observed on the Dart side (no logcat line and no completed install row)"
}

device_matrix_cases() {
  device_needs_restart_case
  device_statvfs_case
  device_install_events_case
}

# ---------------------------------------------------------------------------
# Fixtures for --self-test / --db (no phone required).
# ---------------------------------------------------------------------------

make_valid_fixture() {
  local db="$1"
  rm -f "$db"
  run_bounded sqlite3 "$db" <<'SQL'
CREATE TABLE channels(
    key TEXT NOT NULL PRIMARY KEY,
    kind TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    priority INTEGER NOT NULL DEFAULT 0,
    support_offline INTEGER NOT NULL DEFAULT 0 CHECK(support_offline IN (0,1)),
    last_update_time INTEGER,
    version TEXT,
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE channel_apps(
    channel_key TEXT NOT NULL,
    app_id TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    user TEXT NOT NULL DEFAULT '',
    repositories TEXT NOT NULL DEFAULT '',
    apprepo TEXT,
    icon TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    category TEXT,
    add_time INTEGER NOT NULL DEFAULT 0,
    source_id TEXT,
    extra TEXT,
    PRIMARY KEY(channel_key, app_id)
);
CREATE TABLE channel_packs(
    key TEXT NOT NULL PRIMARY KEY,
    pack_hash TEXT NOT NULL,
    meta_json TEXT NOT NULL DEFAULT '{}',
    installed_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE channel_env(
    channel_key TEXT NOT NULL PRIMARY KEY,
    env_json TEXT NOT NULL,
    imported_at INTEGER NOT NULL
);
CREATE TABLE core_writes(
    domain TEXT NOT NULL PRIMARY KEY,
    first_write_at INTEGER NOT NULL,
    snapshot_id TEXT
);
INSERT INTO channels(key, kind, name, enabled, priority) VALUES
    ('github',       'github',   'GitHub',       1, 10),
    ('fdroid',       'fdroid',   'F-Droid',      1, 20),
    ('vivo',         'vivo',     'Vivo',         1, 30),
    ('coolapk',      'coolapk',  'Coolapk',      0, 40),
    ('smoke_github', 'github',   'Smoke GitHub', 1,  1),
    ('js_smoke',     'js_local', 'Smoke JS Pack',0,  0);
INSERT INTO channel_apps(channel_key, app_id, name) VALUES
    ('smoke_github', 'smoke/app', 'Smoke App');
INSERT INTO channel_packs(key, pack_hash) VALUES
    ('js_smoke', 'deadbeef');
INSERT INTO channel_env(channel_key, env_json, imported_at) VALUES
    ('js_smoke', '{"SMOKE":"1"}', 1);
PRAGMA user_version = 1;
SQL
}

make_post_removal_fixture() {
  local db="$1"
  make_valid_fixture "$db"
  run_bounded sqlite3 "$db" <<'SQL'
CREATE TABLE download_task(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    module_task_id TEXT UNIQUE,
    dedup_key TEXT,
    app_id TEXT,
    app_name TEXT,
    version TEXT,
    file_name TEXT,
    kind TEXT,
    resource_id TEXT,
    resource_version TEXT,
    url TEXT,
    dest_path TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    bytes_done INTEGER NOT NULL DEFAULT 0,
    total INTEGER NOT NULL DEFAULT 0,
    speed_bps INTEGER NOT NULL DEFAULT 0,
    eta_sec INTEGER,
    segments_json TEXT,
    retries INTEGER NOT NULL DEFAULT 0,
    server_meta TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    headers_json TEXT,
    expected_sha256 TEXT,
    install_after_download INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    last_started_at INTEGER,
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    install_status TEXT NOT NULL DEFAULT 'none',
    install_method TEXT,
    install_session_id TEXT,
    install_error TEXT,
    installed_at INTEGER,
    installed_version TEXT
);
INSERT INTO download_task(module_task_id, app_id, status, install_status, install_session_id, installed_at)
    VALUES ('mod-completed', 'com.example.one', 'completed', 'installed', 'sess-1', 100);
INSERT INTO download_task(module_task_id, app_id, status, install_status)
    VALUES ('mod-live', 'com.example.two', 'downloading', 'none');
INSERT INTO download_task(module_task_id, app_id, status, install_status, install_session_id)
    VALUES ('mod-pending', 'com.example.three', 'completed', 'pending', 'sess-2');
INSERT INTO core_writes(domain, first_write_at) VALUES
    ('download', 10),
    ('install', 20);
PRAGMA user_version = 4;
SQL
}

make_closeout_fixture() {
  local db="$1"
  make_post_removal_fixture "$db"
  run_bounded sqlite3 "$db" <<'SQL'
INSERT INTO core_writes(domain, first_write_at) VALUES
    ('channel', 30),
    ('js_channel', 40),
    ('catalog', 50),
    ('update', 60);
PRAGMA user_version = 6;
SQL
}

notification_scope_pkg() {
  awk -v pkg="pkg=$PKG" '
    /^[[:space:]]*NotificationRecord[(\{]/ {
      inblk = index($0, pkg) > 0
      if (inblk) print
      next
    }
    inblk && /^[[:space:]]/ { print; next }
    { inblk = 0 }
  '
}

notification_eval_present() {
  local dump="$1" scoped rc=0
  scoped="$(printf '%s\n' "$dump" | notification_scope_pkg)"
  if printf '%s' "$scoped" | grep -Fq 'download_progress'; then
    pass "notification: $PKG download notification present (download_progress)"
  else
    fail "notification: $PKG download notification missing (expected download_progress in dumpsys notification --noredact)"
    rc=1
  fi
  if printf '%s' "$scoped" | grep -Eq 'foreground_service|isForegroundService=true'; then
    pass "notification: $PKG foreground-service entry present"
  else
    fail "notification: $PKG foreground-service entry missing (expected foreground_service or isForegroundService=true)"
    rc=1
  fi
  return "$rc"
}

notification_eval_removed() {
  local dump="$1" scoped leftover
  scoped="$(printf '%s\n' "$dump" | notification_scope_pkg)"
  leftover="$(printf '%s' "$scoped" | grep -Ec 'download_progress|foreground_service|isForegroundService=true' || true)"
  [ -n "$leftover" ] || leftover=0
  if [ "$leftover" -eq 0 ]; then
    pass "notification: download + foreground-service notifications removed after cancel"
    return 0
  fi
  fail "notification: $leftover download/foreground-service marker(s) still present after cancel"
  return 1
}

notification_probe_case() {
  local label="$1" dump="$2" want="$3" out rc_line got_rc
  set +e
  out="$(
    PASSED=0
    FAILED=0
    notification_eval_present "$dump"
    rc=$?
    printf 'probe_rc=%s failed=%s\n' "$rc" "$FAILED"
  )" 2>&1
  set -e
  printf '%s\n' "$out"
  rc_line="$(printf '%s\n' "$out" | grep -E '^probe_rc=' | tail -n 1 || true)"
  got_rc="${rc_line#probe_rc=}"
  got_rc="${got_rc%% *}"
  if [ "$got_rc" = "$want" ]; then
    echo "SELFTEST PASS: $label"
    return 0
  fi
  echo "SELFTEST FAIL: $label (want probe_rc=$want got '${rc_line:-<missing>}')"
  return 1
}

notification_removed_case() {
  local label="$1" dump="$2" want="$3" out rc_line got_rc
  set +e
  out="$(
    PASSED=0
    FAILED=0
    notification_eval_removed "$dump"
    rc=$?
    printf 'probe_rc=%s failed=%s\n' "$rc" "$FAILED"
  )" 2>&1
  set -e
  printf '%s\n' "$out"
  rc_line="$(printf '%s\n' "$out" | grep -E '^probe_rc=' | tail -n 1 || true)"
  got_rc="${rc_line#probe_rc=}"
  got_rc="${got_rc%% *}"
  if [ "$got_rc" = "$want" ]; then
    echo "SELFTEST PASS: $label"
    return 0
  fi
  echo "SELFTEST FAIL: $label (want probe_rc=$want got '${rc_line:-<missing>}')"
  return 1
}

run_notification_probe_selftest() {
  local good bad_absent bad_other good_removed bad_removed st_failed=0
  good='NotificationRecord{0x1 pkg=com.suno2.gstore uid=10001}
  channel=download_progress
  isForegroundService=false
NotificationRecord{0x2 pkg=com.suno2.gstore uid=10001}
  channel=foreground_service
  isForegroundService=true'
  bad_absent='NotificationRecord{0x3 pkg=com.suno2.gstore uid=10001}
  channel=foreground_service
  isForegroundService=true'
  bad_other='NotificationRecord{0x4 pkg=com.other.app uid=10002}
  channel=download_progress
  isForegroundService=true'
  good_removed='NotificationRecord{0x5 pkg=com.other.app uid=10002}
  channel=other_channel'
  bad_removed='NotificationRecord{0x6 pkg=com.suno2.gstore uid=10001}
  channel=download_progress'

  echo
  echo "== notification probe self-test (simulated dumpsys; no device) =="
  notification_probe_case "notification probe accepts a download+FGS dump" "$good" 0 || st_failed=1
  notification_probe_case "notification probe goes red when the download notification is absent" "$bad_absent" 1 || st_failed=1
  notification_probe_case "notification probe ignores another package's notification" "$bad_other" 1 || st_failed=1
  notification_removed_case "notification removal check accepts an empty package dump" "$good_removed" 0 || st_failed=1
  notification_removed_case "notification removal check goes red while a download stays posted" "$bad_removed" 1 || st_failed=1
  return "$st_failed"
}

# selftest_expect <label> <db> <pass|fail> [pre|post|closeout]
selftest_expect() {
  local label="$1" db="$2" want="$3" mode="${4:-pre}"
  local out rc verdict ok
  set +e
  out="$(
    PASSED=0
    FAILED=0
    SKIPPED=0
    MODE="$mode"
    if [ "$mode" = "post" ]; then
      DEEP_CHECKS="$POST_CHECKS"
    elif [ "$mode" = "closeout" ]; then
      DEEP_CHECKS="$CLOSEOUT_CHECKS"
    else
      DEEP_CHECKS="$PRE_CHECKS"
    fi
    run_db_checks "$db"
  )" 2>&1
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [ "$want" = "pass" ]; then
    if [ "$rc" -eq 0 ]; then ok=1; verdict="PASS"; else ok=0; verdict="FAIL"; fi
  else
    if [ "$rc" -ne 0 ]; then ok=1; verdict="PASS"; else ok=0; verdict="FAIL"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    echo "SELFTEST PASS: $label (expected deep checks to $want, exit=$rc)"
  else
    echo "SELFTEST FAIL: $label (expected deep checks to $want, exit=$rc)"
  fi
  [ "$ok" -eq 1 ]
}

run_self_test() {
  local tmp st_failed=0 broken_total=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gstore-device-smoke-selftest.XXXXXX")"
  echo "== device-smoke self-test =="
  if [ "$CLOSEOUT" -eq 1 ]; then
    echo "mode: closeout"
  elif [ "$POST_REMOVAL" -eq 1 ]; then
    echo "mode: post-removal"
  else
    echo "mode: pre-removal+post-removal+closeout"
  fi
  echo "fixtures: $tmp"

  if [ "$POST_REMOVAL" -eq 0 ]; then
    make_valid_fixture "$tmp/valid.db"
    selftest_expect "valid smoke DB" "$tmp/valid.db" pass || st_failed=1

    make_valid_fixture "$tmp/missing-row.db"
    run_bounded sqlite3 "$tmp/missing-row.db" \
      "DELETE FROM channel_apps WHERE channel_key='smoke_github';"
    broken_total=$((broken_total + 1))
    selftest_expect "missing smoke row (table exists, row gone)" \
      "$tmp/missing-row.db" fail || st_failed=1

    make_valid_fixture "$tmp/renamed-table.db"
    run_bounded sqlite3 "$tmp/renamed-table.db" \
      "ALTER TABLE channel_packs RENAME TO channel_packs_renamed;"
    broken_total=$((broken_total + 1))
    selftest_expect "renamed channel_packs table" "$tmp/renamed-table.db" fail || st_failed=1

    make_valid_fixture "$tmp/missing-column.db"
    run_bounded sqlite3 "$tmp/missing-column.db" \
      "ALTER TABLE channel_apps RENAME COLUMN name TO label;"
    broken_total=$((broken_total + 1))
    selftest_expect "missing channel_apps.name column" "$tmp/missing-column.db" fail || st_failed=1

    make_valid_fixture "$tmp/null-app-id.db"
    run_bounded sqlite3 "$tmp/null-app-id.db" <<'SQL'
ALTER TABLE channel_apps RENAME TO channel_apps_old;
CREATE TABLE channel_apps(
    channel_key TEXT,
    app_id TEXT,
    name TEXT NOT NULL DEFAULT ''
);
INSERT INTO channel_apps(channel_key, app_id, name) VALUES
    ('smoke_github', NULL, 'Smoke App');
DROP TABLE channel_apps_old;
SQL
    broken_total=$((broken_total + 1))
    selftest_expect "NULL app_id row" "$tmp/null-app-id.db" fail || st_failed=1

    make_valid_fixture "$tmp/stale-schema.db"
    run_bounded sqlite3 "$tmp/stale-schema.db" "PRAGMA user_version = 0;"
    broken_total=$((broken_total + 1))
    selftest_expect "stale schema (user_version=0)" "$tmp/stale-schema.db" fail || st_failed=1

    make_valid_fixture "$tmp/dirty-writes.db"
    run_bounded sqlite3 "$tmp/dirty-writes.db" \
      "INSERT INTO core_writes(domain, first_write_at) VALUES('apps', 1);"
    broken_total=$((broken_total + 1))
    selftest_expect "dirty core_writes row" "$tmp/dirty-writes.db" fail || st_failed=1

    printf 'this is not a sqlite database\n' > "$tmp/corrupt.db"
    broken_total=$((broken_total + 1))
    selftest_expect "corrupt database file" "$tmp/corrupt.db" fail || st_failed=1
  fi

  make_post_removal_fixture "$tmp/post-valid.db"
  selftest_expect "valid post-removal DB (core ownership + flags-on)" \
    "$tmp/post-valid.db" pass post || st_failed=1

  make_post_removal_fixture "$tmp/post-missing-module-id.db"
  run_bounded sqlite3 "$tmp/post-missing-module-id.db" \
    "UPDATE download_task SET module_task_id=NULL WHERE module_task_id='mod-live';"
  broken_total=$((broken_total + 1))
  selftest_expect "post-removal non-terminal row without module_task_id" \
    "$tmp/post-missing-module-id.db" fail post || st_failed=1

  make_post_removal_fixture "$tmp/post-missing-session.db"
  run_bounded sqlite3 "$tmp/post-missing-session.db" \
    "UPDATE download_task SET install_session_id=NULL WHERE module_task_id='mod-completed';"
  broken_total=$((broken_total + 1))
  selftest_expect "post-removal install without install_session_id" \
    "$tmp/post-missing-session.db" fail post || st_failed=1

  make_post_removal_fixture "$tmp/post-wrong-writes.db"
  run_bounded sqlite3 "$tmp/post-wrong-writes.db" \
    "INSERT INTO core_writes(domain, first_write_at) VALUES('channel', 30);"
  broken_total=$((broken_total + 1))
  selftest_expect "post-removal core_writes with a non-flipped domain" \
    "$tmp/post-wrong-writes.db" fail post || st_failed=1

  make_post_removal_fixture "$tmp/post-no-install-columns.db"
  run_bounded sqlite3 "$tmp/post-no-install-columns.db" <<'SQL'
ALTER TABLE download_task RENAME TO download_task_old;
CREATE TABLE download_task(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    module_task_id TEXT,
    status TEXT NOT NULL DEFAULT 'queued'
);
INSERT INTO download_task(module_task_id, status) VALUES ('mod-live', 'downloading');
DROP TABLE download_task_old;
SQL
  broken_total=$((broken_total + 1))
  selftest_expect "post-removal DB missing install ownership columns" \
    "$tmp/post-no-install-columns.db" fail post || st_failed=1

  make_closeout_fixture "$tmp/closeout-valid.db"
  selftest_expect "valid closeout DB (core ownership + flags-on-closeout)" \
    "$tmp/closeout-valid.db" pass closeout || st_failed=1

  make_closeout_fixture "$tmp/closeout-missing-js.db"
  run_bounded sqlite3 "$tmp/closeout-missing-js.db" \
    "DELETE FROM core_writes WHERE domain='js_channel';"
  broken_total=$((broken_total + 1))
  selftest_expect "closeout DB missing one of the six domains" \
    "$tmp/closeout-missing-js.db" fail closeout || st_failed=1

  broken_total=$((broken_total + 1))
  selftest_expect "closeout DB is not a pre-cutover flags-on DB" \
    "$tmp/closeout-valid.db" fail post || st_failed=1

  run_notification_probe_selftest || st_failed=1

  echo
  echo "== self-test summary =="
  rm -rf "$tmp"
  if [ "$st_failed" -ne 0 ]; then
    echo "RESULT: FAIL"
    return 1
  fi
  echo "RESULT: PASS (valid fixtures passed; $broken_total broken fixtures failed)"
  return 0
}

# ---------------------------------------------------------------------------
# Local modes: no adb involved.
# ---------------------------------------------------------------------------

if [ "$SELFTEST" -eq 1 ]; then
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "ERROR: --self-test requires host sqlite3" >&2
    exit 1
  fi
  if run_self_test; then
    exit 0
  fi
  exit 1
fi

if [ -n "$DB_PATH" ]; then
  echo "== device smoke (local DB) =="
  echo "mode: $MODE"
  echo "db: $DB_PATH"
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "ERROR: --db requires host sqlite3" >&2
    exit 1
  fi
  if [ ! -f "$DB_PATH" ]; then
    echo "FAIL: database not found: $DB_PATH" >&2
    echo "RESULT: FAIL"
    exit 1
  fi
  PASSED=0
  FAILED=0
  SKIPPED=0
  run_db_checks "$DB_PATH" || true
  echo
  echo "== summary =="
  echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
  if [ "$FAILED" -gt 0 ]; then
    echo "RESULT: FAIL"
    exit 1
  fi
  echo "RESULT: PASS"
  exit 0
fi

echo "== device smoke =="
echo "mode:    $MODE"
echo "package: $PKG"

if ! command -v adb >/dev/null 2>&1; then
  blocked_no_device "adb not found; no device checks were run"
  report_blocked_device_cases
  echo
  echo "== summary =="
  echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
  echo "RESULT: BLOCKED (no adb device)"
  exit 3
fi

set +e
devices_out="$(adb devices 2>&1)"
devices_rc=$?
set -e
printf '%s\n' "$devices_out"
if [ "$devices_rc" -ne 0 ]; then
  blocked_no_device "adb devices failed (exit $devices_rc); no device checks were run"
  echo
  echo "== summary =="
  echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
  echo "RESULT: BLOCKED (no adb device)"
  exit 3
fi

SERIAL="$(printf '%s\n' "$devices_out" | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
if [ -z "$SERIAL" ]; then
  blocked_no_device "no adb device in state 'device'; start an ARM64 emulator or connect a device"
  report_blocked_device_cases
  echo
  echo "== summary =="
  echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
  echo "RESULT: BLOCKED (no adb device)"
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

  device_notification_probe

  if [ -n "$INSTRUMENTATION" ]; then
    for check in $DEEP_CHECKS; do
      deep_check_instrumentation "$check"
    done
  else
    deep_checks_db
  fi

  device_matrix_cases
fi

echo
echo "== summary =="
echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
if [ "$FAILED" -gt 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
if [ "$BLOCKED_COUNT" -gt 0 ]; then
  echo "RESULT: BLOCKED (a blocked check is not a pass)"
  exit 3
fi
if [ "$SKIPPED" -gt 0 ]; then
  echo "RESULT: SKIP (a skipped check is not a pass)"
  exit 3
fi
echo "RESULT: PASS"
exit 0
