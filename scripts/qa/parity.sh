#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

FIXTURE_DIR="test/fixtures/parity"
DB="$FIXTURE_DIR/localdb.db"
SQL="$FIXTURE_DIR/localdb.sql"
EVIDENCE="target/spike-evidence"
DART_JSON="$EVIDENCE/parity-dart.json"
RUST_JSON="$EVIDENCE/parity-rust.json"

mkdir -p "$EVIDENCE"

# Always rebuild from the committed SQL so a stale or cached DB cannot mask drift.
rm -f "$DB"
sqlite3 "$DB" < "$SQL"

echo "== rust: gstore_core_parity =="
cargo run --quiet --manifest-path rust/gstore_core/Cargo.toml \
  --bin gstore_core_parity -- --db "$DB" --out "$RUST_JSON"

echo "== dart: dump_dart_parity_test =="
flutter test test/parity/dump_dart_parity_test.dart

echo "== dart JSON: $DART_JSON =="
cat "$DART_JSON"
echo
echo "== rust JSON: $RUST_JSON =="
cat "$RUST_JSON"
echo
echo "== normalizer =="
python3 scripts/qa/parity_normalize.py \
  --dart "$DART_JSON" --rust "$RUST_JSON" "$@"
