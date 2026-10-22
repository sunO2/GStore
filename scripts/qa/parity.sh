#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Suite selector: exactly one of
#   --channel   raw LocalDbDriver against the fixture copy (default)
#   --catalog   import the fixture into a fresh core DB and drive CatalogService
#   --download  legacy Floor/module migration + on-disk part/merge/resume parity
# Every other argument (e.g. --inject-field-diff, --inject-path-diff) is passed
# to the normalizer unchanged. An unknown mode-like argument is never silently
# treated as --channel: only the three names above select a suite.
MODE=""
NORMALIZER_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --channel|--catalog|--download)
      selected="${arg#--}"
      if [[ -n "$MODE" && "$MODE" != "$selected" ]]; then
        echo "parity: choose exactly one suite (--channel, --catalog, --download)" >&2
        exit 2
      fi
      MODE="$selected"
      ;;
    --inject-field-diff|--inject-path-diff)
      NORMALIZER_ARGS+=("$arg")
      ;;
    *)
      echo "parity: unknown argument: $arg (expected --channel, --catalog, --download, --inject-field-diff, --inject-path-diff)" >&2
      exit 2
      ;;
  esac
done
MODE="${MODE:-channel}"
echo "$MODE parity suite selected"

EVIDENCE="target/spike-evidence"
mkdir -p "$EVIDENCE"

if [[ "$MODE" == "download" ]]; then
  DPI="$EVIDENCE/download-parity"
  DART_JSON="$EVIDENCE/download-parity-dart.json"
  RUST_JSON="$EVIDENCE/download-parity-rust.json"

  echo "== fixture: $DPI (Floor download_task.db + module/download.db + files/) =="
  python3 scripts/qa/gen_download_parity_fixture.py --out "$DPI"

  echo "== rust: gstore_core_parity --download (real migrators, twice) =="
  cargo run --quiet --manifest-path rust/gstore_core/Cargo.toml \
    --bin gstore_core_parity -- \
    --download \
    --legacy "$DPI/legacy/download_task.db" \
    --module "$DPI/module/download.db" \
    --files "$DPI/files" \
    --out "$RUST_JSON"

  echo "== dart: dump_dart_download_parity_test (real DownloadPaths + SQLite) =="
  flutter test test/parity/dump_dart_download_parity_test.dart

  echo "== normalizer (download) =="
  python3 scripts/qa/parity_normalize.py \
    --download --dart "$DART_JSON" --rust "$RUST_JSON" \
    ${NORMALIZER_ARGS[@]+"${NORMALIZER_ARGS[@]}"}
  exit 0
fi

ASSET="assets/app/db/apps.db"
FIXTURE_DIR="test/fixtures/parity"
DB="$FIXTURE_DIR/localdb.db"
SQL="$FIXTURE_DIR/localdb.sql"
DART_JSON="$EVIDENCE/parity-dart.json"
RUST_JSON="$EVIDENCE/parity-rust.json"
RUST_DB="$EVIDENCE/parity-rust-seed.db"
CORE_DB="$EVIDENCE/parity-catalog.db"

# Malformed/missing input must fail here, before either side can produce a
# misleading empty document.
if [[ ! -f "$ASSET" ]]; then
  echo "parity: seed asset missing: $ASSET" >&2
  exit 1
fi

# Derive the fixture from the shipped asset on every run.  The generator writes
# the committed SQL snapshot and rebuilds the DB; it refuses missing tables,
# failed integrity_check, empty apps/category, or an FTS/apps row mismatch.
echo "== seed: derive $DB from $ASSET =="
python3 scripts/qa/gen_parity_fixture.py \
  --asset "$ASSET" --sql "$SQL" --db "$DB"

if [[ "$MODE" == "catalog" ]]; then
  # Fresh imported core database every run: the importer replaces the catalog
  # atomically, but stale WAL/journal files would make a rerun ambiguous.
  rm -f "$CORE_DB" "$CORE_DB-wal" "$CORE_DB-shm" "$CORE_DB-journal"
  rm -f "$CORE_DB".bak-import-*

  echo "== import: core catalog at $CORE_DB =="
  cargo run --quiet --manifest-path rust/gstore_core/Cargo.toml \
    --bin gstore_core_import -- --db "$CORE_DB" --seed "$DB"
  # The importer always writes a timestamped VACUUM INTO backup; a fresh
  # catalog run does not need to keep it.
  rm -f "$CORE_DB".bak-import-*

  echo "== rust: gstore_core_parity --catalog (real CatalogService) =="
  cargo run --quiet --manifest-path rust/gstore_core/Cargo.toml \
    --bin gstore_core_parity -- --catalog --db "$CORE_DB" --out "$RUST_JSON"
else
  # Stale cached DB/copy guard: the Rust driver applies the core schema to its
  # own copy, so the committed fixture bytes stay deterministic (no diff after a
  # run).
  rm -f "$RUST_DB" "$RUST_DB-wal" "$RUST_DB-shm" "$RUST_DB-journal"
  cp "$DB" "$RUST_DB"

  echo "== rust: gstore_core_parity (real LocalDbDriver) =="
  cargo run --quiet --manifest-path rust/gstore_core/Cargo.toml \
    --bin gstore_core_parity -- --db "$RUST_DB" --out "$RUST_JSON"
fi

echo "== dart: dump_dart_parity_test (real Floor DAO + LocalDbChannel) =="
flutter test test/parity/dump_dart_parity_test.dart

echo "== dart JSON: $DART_JSON =="
cat "$DART_JSON"
echo
echo "== rust JSON: $RUST_JSON =="
cat "$RUST_JSON"
echo
echo "== normalizer =="
python3 scripts/qa/parity_normalize.py \
  --dart "$DART_JSON" --rust "$RUST_JSON" ${NORMALIZER_ARGS[@]+"${NORMALIZER_ARGS[@]}"}
