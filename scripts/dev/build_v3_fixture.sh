#!/usr/bin/env bash
# build_v3_fixture.sh — build and freeze the immutable ABI v3 module fixture.
#
# Purpose: the host handshake tests (gstore_host) load this exact .so as the
# "old" module. It MUST be built from the unmodified ABI v3 tree and then frozen,
# so this script refuses to run once GSTORE_MODULE_ABI_VERSION != 3. That makes
# "build the fixture before the ABI edit" a mechanical guard, not a convention.
#
# Outputs:
#   rust/test-fixtures/v3/linux-x86_64/libgstore_mod_repo.so
#   rust/test-fixtures/v3/linux-x86_64/libgstore_mod_repo.so.sha256  (sha256sum -c compatible)
#
# Overrides:
#   ABI_RS_PATH  — alternate path to abi.rs. Used by QA to exercise the guard
#                  against a sed-ed copy without touching the real file.
#
# See rust/test-fixtures/v3/README.md for provenance and rebuild instructions.

set -euo pipefail

# --- repo root, resolved from this script's own path (works from any cwd) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ABI_RS="${ABI_RS_PATH:-$ROOT/rust/gstore_contract/src/abi.rs}"

# --- guard: the fixture is only valid if the tree still speaks ABI v3 ---------
# Fail closed: missing/unparseable constant also aborts, never overwrites.
abi_ver="$(grep -E '^pub const GSTORE_MODULE_ABI_VERSION: u32 = ' "$ABI_RS" 2>/dev/null \
    | head -n1 | sed -E 's/.* = ([0-9]+);.*/\1/' || true)"
if [ -z "$abi_ver" ]; then
    echo "ERROR: cannot determine GSTORE_MODULE_ABI_VERSION from $ABI_RS" >&2
    exit 1
fi
if [ "$abi_ver" != "3" ]; then
    echo "ERROR: GSTORE_MODULE_ABI_VERSION is $abi_ver, but the v3 fixture must be built" >&2
    echo "       from the unmodified ABI v3 tree (GSTORE_MODULE_ABI_VERSION == 3)." >&2
    echo "       Refusing to overwrite the immutable v3 fixture." >&2
    exit 1
fi

# --- build the module for the host OS -----------------------------------------
echo "==> building gstore_mod_repo (host, release) at $ROOT"
cargo build --manifest-path "$ROOT/rust/gstore_mod_repo/Cargo.toml" --lib --release

target_dir="${CARGO_TARGET_DIR:-$ROOT/rust/gstore_mod_repo/target}"
src_so="$target_dir/release/libgstore_mod_repo.so"
if [ ! -f "$src_so" ]; then
    echo "ERROR: expected build output not found: $src_so" >&2
    exit 1
fi

# --- install the fixture -------------------------------------------------------
fixture_dir="$ROOT/rust/test-fixtures/v3/linux-x86_64"
fixture="$fixture_dir/libgstore_mod_repo.so"
mkdir -p "$fixture_dir"
cp -f "$src_so" "$fixture"

# --- assert the register symbol survives linking -------------------------------
echo "==> asserting nm -D exports gstore_mod_repo_register"
nm_symbols="$(nm -D "$fixture")"
if ! grep -q 'gstore_mod_repo_register' <<<"$nm_symbols"; then
    echo "ERROR: $fixture does not export gstore_mod_repo_register" >&2
    exit 1
fi

# --- deterministic sha256 (sha256sum -c compatible: checksum + two spaces + basename)
(cd "$fixture_dir" && sha256sum libgstore_mod_repo.so > libgstore_mod_repo.so.sha256)

# --- summary -------------------------------------------------------------------
size="$(stat -c %s "$fixture")"
sha="$(awk '{print $1}' "$fixture.sha256")"
echo ""
echo "Fixture  : $fixture"
echo "Size     : $size bytes"
echo "SHA256   : $sha"
echo "ABI const: GSTORE_MODULE_ABI_VERSION = $abi_ver"
