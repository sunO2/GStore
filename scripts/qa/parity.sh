#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# `--channel` selects the channel parity suite (the only suite today).  It is a
# harness selector, not a normalizer flag, so consume it here and pass every
# other argument (e.g. --inject-field-diff) through unchanged.
CHANNEL=0
NORMALIZER_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --channel) CHANNEL=1 ;;
    *) NORMALIZER_ARGS+=("$arg") ;;
  esac
done
if [[ "$CHANNEL" -eq 1 ]]; then
  echo "channel parity suite selected"
fi

ASSET="assets/app/db/apps.db"
FIXTURE_DIR="test/fixtures/parity"
DB="$FIXTURE_DIR/localdb.db"
SQL="$FIXTURE_DIR/localdb.sql"
EVIDENCE="target/spike-evidence"
DART_JSON="$EVIDENCE/parity-dart.json"
RUST_JSON="$EVIDENCE/parity-rust.json"
RUST_DB="$EVIDENCE/parity-rust-seed.db"

mkdir -p "$EVIDENCE"

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

# Stale cached DB/copy guard: the Rust driver applies the core schema to its own
# copy, so the committed fixture bytes stay deterministic (no diff after a run).
rm -f "$RUST_DB" "$RUST_DB-wal" "$RUST_DB-shm" "$RUST_DB-journal"
cp "$DB" "$RUST_DB"

echo "== rust: gstore_core_parity (real LocalDbDriver) =="
cargo run --quiet --manifest-path rust/gstore_core/Cargo.toml \
  --bin gstore_core_parity -- --db "$RUST_DB" --out "$RUST_JSON"

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
