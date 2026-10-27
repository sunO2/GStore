# v3 ABI fixture (immutable)

This directory holds the **frozen, immutable ABI v3 module fixture** that the
host handshake tests in `gstore_host` load as the "old" module. It is built
**once**, from the *unmodified* ABI v3 tree — before
`GSTORE_MODULE_ABI_VERSION` moves to 4 — and checked in, so the v3 module
bytecode keeps proving old-module behavior (including rejecting a v4 host
entry) forever.

## Provenance

- **Built by:** `scripts/dev/build_v3_fixture.sh`
- **Tree:** spike worktree `GStore-spike`, branch `spike/rust-core-contracts`
- **Base commit:** `9ec51320c0d2af107379744463325d36cdcd661c`
- **ABI constant at build time:** `GSTORE_MODULE_ABI_VERSION = 3`
  (`rust/gstore_contract/src/abi.rs`)
- **Module:** `gstore_mod_repo` (`rust/gstore_mod_repo`, `crate-type = ["cdylib", "rlib"]`).
  Its `gstore_mod_repo_register` export rejects any `e.abi_version != 3` with
  `ABI_ERR_ABI_MISMATCH` — the exact behavior the handshake tests depend on.
- **Host OS:** Linux x86_64 (directory `linux-x86_64/`)

## Contents

| File | Meaning |
| --- | --- |
| `linux-x86_64/libgstore_mod_repo.so` | the compiled v3 module |
| `linux-x86_64/libgstore_mod_repo.so.sha256` | `sha256sum -c`-compatible checksum |

## Rebuilding

The builder is **guarded**: it refuses to run unless `GSTORE_MODULE_ABI_VERSION`
in `rust/gstore_contract/src/abi.rs` is still `3`, so it cannot accidentally
overwrite this fixture from a v4 (or later) tree. Rebuild and verify with:

```bash
bash scripts/dev/build_v3_fixture.sh
cd rust/test-fixtures/v3/linux-x86_64 && sha256sum -c libgstore_mod_repo.so.sha256
```

## Do not regenerate after the ABI bump

The whole point of the fixture is that it is *old*. Once the ABI constant
changes, keep this directory untouched. If a fixture for a newer ABI is ever
needed, add a sibling `vN/` directory instead of replacing `v3/`.
