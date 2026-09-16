# `scripts/` — ERTS mirror pipeline

This directory holds every executable that builds, uploads, and
maintains the [`Batamanta---ERTS-repository`][repo] mirror. Both the
GitHub Actions CI and the manual on-host entry point resolve scripts
from here.

[repo]: https://github.com/Lorenzo-SF/Batamanta---ERTS-repository

## Quick reference

| Path                                  | What it is                                              |
|---------------------------------------|---------------------------------------------------------|
| `local/sync-erts.sh`                  | **Entry point** — used by CI + by humans on macOS/CachyOS |
| `local/regenerate-linux-amd64.sh`     | Per-target manual rebuild (linux glibc + musl, amd64)    |
| `local/regenerate-linux-arm64.sh`     | Per-target manual rebuild (linux glibc + musl, arm64)    |
| `local/regenerate-darwin.sh`          | Per-target manual rebuild (macOS arm64 / amd64)          |
| `local/regenerate-windows-amd64.sh`   | Per-target manual rebuild (windows amd64)                |
| `local/lib-sync.sh`                   | GitHub-side helpers (auth, sync_releases, etc.)          |
| `local/regenerate-manifest.py`/`.ps1` | Standalone MANIFEST regen tools (used by the cross-platform helpers) |
| `_lib.sh`                             | Core library: target matrix, build_target, manifest I/O  |
| `detect-versions.sh`                  | List the latest stable OTP versions upstream             |
| `_bash_guard.sh`                      | Refuses to source `_lib.sh` on bash < 5 (macOS 3.2)      |
| `_legacy/`                            | Archived scripts — see `_legacy/README.md`               |

## Current vs. future

The pipeline is being incrementally reorganised into a numbered,
`setup.d`-style layout (00-utils, 01-detect, 02-sync-releases,
03-build, 04-manifest, 10-targets/<target>.sh, 99-entry). Until
that refactor lands, the canonical entry points are:

- **CI** (`../.github/workflows/erts.yml`) calls
  `./scripts/local/sync-erts.sh --manifest-only` and
  `--version=V <target>`.
- **Manual** (macOS, CachyOS, etc.) — start with
  `./scripts/local/sync-erts.sh --help` to see the full command
  surface, or just `./scripts/local/sync-erts.sh` (no flags) for the
  interactive "ask wipe?, then build what this host can" path.

## Why a numbered structure?

The numbered layout is borrowed from
[`bitacora/Entorno/msi/setup/setup.d/`][setupd] — every step loads
in lexicographic order with no surprises. When the files grow past
a couple of hundred lines each, splitting `lib-sync.sh` + `_lib.sh`
into focused pieces makes the pipeline easier to navigate and
_individually_ unit-testable. Until that lands, scripts are kept
where the existing CI expects them.

[setupd]: ../../../bitacora/Entorno/msi/setup/setup.d/

## How an end-to-end build works today

```
schedule (Monday 06:00 UTC)
   │
   ▼
sync-releases  ─ creates empty releases for new OTP versions
   │
   ▼
detect         ─ computes (target × version) matrix from live releases
   │
   ▼
build         ─ one job per cell; calls sync-erts.sh --version=V <target>
   │
   ▼
manifest-commit ─ regenerates MANIFEST.json from assets, commits + pushes
```

The `manifest-commit` job uses the `jq`-first MANIFEST validator
patch: even on hosts where `python3` resolves to an asdf shim
without `.tool-versions`, the regeneration no longer aborts
spuriously on "JSON invalid".

## How a manual build works

From a host with the right toolchain (Xcode CLT on macOS, Docker on
Linux, etc.):

```bash
cd scripts/
./local/sync-erts.sh --help
./local/sync-erts.sh                       # interactive
./local/sync-erts.sh linux-glibc-arm64    # only that target
./local/sync-erts.sh 28.4.2               # only that version
./local/regenerate-linux-amd64.sh         # more focused entry
```

Prereqs vary by target — see the doc-comment at the top of each
`regenerate-*.sh` script.
