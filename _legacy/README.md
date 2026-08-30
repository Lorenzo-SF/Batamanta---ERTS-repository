# `_legacy/` — scripts archived, kept for archaeology only

These scripts shipped in earlier versions of the ERTS mirror pipeline.
They're preserved here so:

- Old CI runs (and any external tooling that referenced them) keep
  resolving their imports.
- The git history of the working scripts (now under
  `../local/`) stays traceable to where these lived.

**They are not used by the current pipeline.** The current CI
(`../.github/workflows/erts.yml`) and the manual entry point
(`../local/sync-erts.sh`) only reference files that live in `../`
or `../local/`. Nothing in `_legacy/` is sourced automatically.

## Contents

### `erts-*.sh` (deprecated thin wrappers)

The `erts-<target>.sh` family used to be one-script-per-target
wrappers called by an even older version of the CI. They were
superseded by `regenerate-*.sh` (now `scripts/local/regenerate-*.sh`)
and the unified `scripts/local/sync-erts.sh` entry point, which both
build the asset and upload it to GitHub in one call.

If you're looking for "how do I rebuild release OTP-X.Y for
linux-glibc-amd64 from my laptop", see
[`scripts/local/sync-erts.sh`](../local/sync-erts.sh) or one of the
`regenerate-*.sh` per-target scripts in `scripts/local/`.

### `deprecated/` (Fish scripts from 2024-era macOS tooling)

Pre-bash-rewrite tools. macOS used to ship Fish as the friendly
default shell for some users; these scripts predate the move to bash
5+. Replaced by the `regenerate-*.sh` family.

## How to remove this directory

When you're confident nothing references these files any more, you
can delete `_legacy/` outright. Recommended steps:

1. Add a CI check that greps `erts-*.sh` and the deprecated/ paths
   out of workflows + scripts (should return zero).
2. `git rm -r _legacy/`.
3. Update any external tooling that cached paths under it.
