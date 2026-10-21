#!/usr/bin/env bash
# ARM64 device/emulator smoke test.
#
# Checks (all issued through `adb`):
#   install -> launch -> process alive -> channel list -> search -> detail ->
#   local pack -> env migration -> parity -> flags-off (core_writes empty).
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
#
# A zero/missing row or column is FAIL (exit 1), never SKIP and never PASS.
# SKIP is reserved for genuinely unavailable probes (no adb/device, non-ARM64,
# release APK not debuggable, DB not found, host sqlite3 missing).
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
#       asserts valid=PASS, broken=FAIL/exit 1.
#   scripts/qa/device-smoke.sh --db PATH
#       runs the same deep SQL checks against a local database file.
#
# Exit-code contract (a skipped check is never a pass):
#   0  every check ran and passed
#   1  a check ran and failed (including zero/missing smoke rows)
#   3  SKIPPED: no adb, no device, non-ARM64 device, or deep probes genuinely
#      unavailable (release build / instrumentation not provided)
#   2  usage error
#
# Usage:
#   scripts/qa/device-smoke.sh [--apk PATH] [--package PKG]
#       [--instrumentation PKG/RUNNER] [--timeout SECONDS] [--no-install]
#       [--db PATH | --self-test]
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

DEEP_CHECKS="channel-list channel-search channel-detail local-pack env-migration parity flags-off"

usage() {
  cat <<'EOF'
usage: scripts/qa/device-smoke.sh [options]

  --apk PATH                APK to install (default: search build outputs)
  --package PKG             app package (default: com.suno2.gstore)
  --instrumentation PKG/RUNNER
                            use `am instrument` deep probes instead of sqlite
  --timeout SECONDS         bound for each adb/sqlite call (default: 120)
  --no-install              skip the install step
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
    --db) DB_PATH="$2"; shift 2 ;;
    --self-test) SELFTEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$SELFTEST" -eq 1 ] && [ -n "$DB_PATH" ]; then
  echo "ERROR: --self-test and --db are mutually exclusive" >&2
  usage >&2
  exit 2
fi

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

# selftest_expect <label> <db> <pass|fail>
selftest_expect() {
  local label="$1" db="$2" want="$3"
  local out rc verdict ok
  set +e
  out="$(
    PASSED=0
    FAILED=0
    SKIPPED=0
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
  echo "fixtures: $tmp"

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

  echo
  echo "== self-test summary =="
  rm -rf "$tmp"
  if [ "$st_failed" -ne 0 ]; then
    echo "RESULT: FAIL"
    return 1
  fi
  echo "RESULT: PASS (valid fixture passed; $broken_total broken fixtures failed)"
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
    for check in $DEEP_CHECKS; do
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
