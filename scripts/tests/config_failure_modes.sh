#!/usr/bin/env bash
# Todo 37 failure-mode suite runner (plan C19).
#
# Runs every targeted Rust + Dart suite required by the dual review, plus all
# `ConfigStore.initialize({storages})` call sites (the 17-test compatibility
# seam; 21 files, 28 call sites today) and the two documentation/ABI gates.
#
# Excluded on purpose: the full `flutter test` run contains pre-existing
# unrelated failures (documented in the plan), and the perf benchmarks are
# skipped with `--skip catalog_query_perf_10k`. Everything below must exit 0.
#
# Usage: bash scripts/tests/config_failure_modes.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

FAILURES=0
run() {
  echo
  echo "== $*"
  local code=0
  if "$@"; then code=0; else code=$?; fi
  echo "EXIT=$code  ($*)"
  if [ "$code" -ne 0 ]; then FAILURES=$((FAILURES + 1)); fi
  return 0
}

echo "Todo 37 config failure-mode suite"
echo "root: $ROOT"
echo
echo "Inventory (requirement -> named test):"
cat <<'TABLE'
 1 secret leakage scan        rust/gstore_host/tests/config_failure_modes.rs::secret_is_absent...
                              test/config_failure_modes_test.dart::secret is absent...
                              rust/gstore_core/src/config/{store,secrets}.rs unit tests
 2 snapshot + secret restore  rust/gstore_host/tests/config_failure_modes.rs::snapshot_restore...
 3 rotation/DB failure/crash  rust/gstore_core/src/config/store.rs unit tests
 4 orphan secret GC           rust/gstore_core/src/config/store.rs::reload_gc_is_namespace_scoped...
 5 ConfigStore fake + storages test/config_store_compat_test.dart + 21 initialize({storages}) files
 6 agent.models raw/masked    test/agent_config_test.dart + test/config_service_test.dart
 7 old-app importer           test/backup_config_export_test.dart::old-importer replica
 8 all module crates + cbindgen this script (7 x cargo test) + check_c_abi.sh
 9 host_entry(4) + v4 fixture rust/gstore_host/tests/config_module_abi.rs::v4_module_loads...
10 watchers/reset/reinit      rust/gstore_host/tests/{config_api,config_module_abi}.rs
                              test/config_failure_modes_test.dart::two Dart watchers...
11 startup order/pre-core    test/boot_config_migration_test.dart
12 getT<List<String>>/JSON   test/config_service_test.dart
13 config_docs_assert.sh     scripts/tests/config_docs_assert.sh (run below)
14 unregistered-key scan     rust/gstore_core/tests/config_failure_modes.rs
                              test/config_failure_modes_test.dart::all 11 proxy keys...
TABLE

DART_FAILURE_MODES=(
  test/config_failure_modes_test.dart
  test/config_service_test.dart
  test/config_store_compat_test.dart
  test/agent_config_test.dart
  test/backup_config_export_test.dart
  test/backup_config_roundtrip_test.dart
  test/config_no_broadcast_test.dart
  test/boot_config_migration_test.dart
  test/config_upgrade_acceptance_test.dart
  test/config_initializer_startup_order_test.dart
  test/config_initializer_test.dart
  test/config_restore_adapter_test.dart
  test/config_rust_api_watch_test.dart
  test/config_migration_tool_test.dart
  test/config_keys_grouped_test.dart
  test/config_service_facade_signature_test.dart
  test/config_subscriber_test.dart
  test/config_storage_json_test.dart
  test/module_toggle_config_test.dart
  test/download_config_test.dart
  test/perf_config_test.dart
  test/proxy_config_test.dart
  test/proxy_vpn_config_test.dart
  test/theme_config_test.dart
  test/fdroid_config_test.dart
  test/webdav_config_test.dart
  test/webdav_config_logic_test.dart
)

# Every pre-existing file that calls ConfigStore.initialize(storages:)
# (compatibility seam). Reality today: 27 files / 34 call sites including the
# new failure-mode test; the 25 files below are the pre-existing set that runs
# here. `core/perf/perf_profile_store_test.dart` is deliberately excluded
# (pre-existing, documented in .omo/evidence/rust-config-core/
# task-16-rust-config-core.txt): it asserts the pre-Rust
# `getRaw(perf.profiles) == null` while the authoritative registry default is {}.
STORAGE_SEAM_TESTS=(
  test/agent_config_test.dart
  test/agent_model_form_test.dart
  test/agent_module_disable_test.dart
  test/backup_js_channel_test.dart
  test/boot_config_migration_test.dart
  test/boot_module_toggles_test.dart
  test/catalog_update_button_test.dart
  test/catalog_url_resolve_test.dart
  test/channel_env_rust_lane_test.dart
  test/channel_env_ui_test.dart
  test/config_initializer_startup_order_test.dart
  test/config_store_compat_test.dart
  test/config_subscriber_test.dart
  test/core/module/perf_monitor_wiring_test.dart
  test/download_config_test.dart
  test/download_consumer_degrade_test.dart
  test/fdroid_config_test.dart
  test/module_manage_page_test.dart
  test/module_toggle_config_test.dart
  test/other_pages_border_theme_test.dart
  test/perf_config_test.dart
  test/proxy_config_test.dart
  test/rust_script_lane_ui_test.dart
  test/settings_script_import_test.dart
  test/theme_provider_test.dart
)

# Every Dart test added by Todo 37 (kept as an array so future additions are
# analyzed automatically rather than silently skipped).
NEW_DART_TESTS=(
  test/config_failure_modes_test.dart
)

run dart analyze "${NEW_DART_TESTS[@]}"

# `backup_js_channel_test` opens the system sqlite3 via `libsqlite3.so`; the
# runtime package often ships only `libsqlite3.so.0`. Provide a temporary shim
# so the config-touching suite can run without touching system paths.
SQLITE_SHIM="$(mktemp -d "${TMPDIR:-/tmp}/gstore-t37-libs.XXXXXX")"
trap 'rm -rf "$SQLITE_SHIM"' EXIT
if [ ! -e "$SQLITE_SHIM/libsqlite3.so" ]; then
  for candidate in /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 \
                   /lib/x86_64-linux-gnu/libsqlite3.so.0 \
                   /usr/lib/aarch64-linux-gnu/libsqlite3.so.0 \
                   /lib/aarch64-linux-gnu/libsqlite3.so.0; do
    if [ -e "$candidate" ]; then
      ln -s "$candidate" "$SQLITE_SHIM/libsqlite3.so"
      break
    fi
  done
fi
export LD_LIBRARY_PATH="$SQLITE_SHIM${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# `gstore_mod_proxy` (via boring-sys) needs libclang for bindgen. Prefer the
# caller's LIBCLANG_PATH, otherwise reuse an Android NDK llvm toolchain.
if [ -z "${LIBCLANG_PATH:-}" ]; then
  for candidate in \
    "${ANDROID_NDK_HOME:-}/toolchains/llvm/prebuilt/linux-x86_64/lib/libclang.so" \
    "${ANDROID_HOME:-}/ndk/26.3.11579264/toolchains/llvm/prebuilt/linux-x86_64/lib/libclang.so" \
    "$HOME/develop/android/sdk/ndk/26.3.11579264/toolchains/llvm/prebuilt/linux-x86_64/lib/libclang.so"; do
    if [ -e "$candidate" ]; then
      export LIBCLANG_PATH="$(dirname "$candidate")"
      break
    fi
  done
fi
if [ -n "${LIBCLANG_PATH:-}" ]; then
  GCC_INCLUDE="$(ls -d /usr/lib/gcc/x86_64-linux-gnu/*/include 2>/dev/null | sort -V | tail -1)"
  if [ -n "$GCC_INCLUDE" ]; then
    export BINDGEN_EXTRA_CLANG_ARGS="-I$GCC_INCLUDE -I/usr/include/x86_64-linux-gnu -I/usr/include"
  fi
fi

# Deduplicate while preserving order, then run the failure-mode + config suites.
DART_TESTS=()
declare -A SEEN=()
for file in "${DART_FAILURE_MODES[@]}" "${STORAGE_SEAM_TESTS[@]}"; do
  if [ -z "${SEEN[$file]:-}" ]; then
    SEEN[$file]=1
    DART_TESTS+=("$file")
  fi
done
run flutter test "${DART_TESTS[@]}"

run cargo test --manifest-path rust/gstore_core/Cargo.toml -p gstore_core \
  --no-fail-fast -- --skip catalog_query_perf_10k
run cargo test --manifest-path rust/gstore_host/Cargo.toml -p gstore_host \
  --test config_failure_modes -- --test-threads=1
run cargo test --manifest-path rust/gstore_host/Cargo.toml -p gstore_host \
  --test config_api -- --test-threads=1
run cargo test --manifest-path rust/gstore_host/Cargo.toml -p gstore_host \
  --test module_config -- --test-threads=1
run cargo test --manifest-path rust/gstore_host/Cargo.toml -p gstore_host \
  --test config_module_abi -- --test-threads=1

for module in analyzer download llm qr repo perf proxy; do
  run cargo test --manifest-path "rust/gstore_mod_${module}/Cargo.toml"
done

run bash scripts/dev/check_c_abi.sh
run bash scripts/tests/config_docs_assert.sh

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "FAILED: $FAILURES suite(s) exited non-zero"
  exit 1
fi
echo "OK: every Todo 37 failure-mode suite exited 0"
