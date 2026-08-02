#!/usr/bin/env bash
# =============================================================================
#  regenerate-windows-amd64.sh
# =============================================================================
#
#  Build (or rebuild) the Windows amd64 ERTS zip from your local Windows
#  machine. Wraps the same _lib.sh:build_target the CI uses, so the resulting
#  zip is byte-identical to what `gh workflow run erts.yml` would produce.
#
#  Prereqs (Windows):
#    * Git Bash (https://git-scm.com/download/win) — gives you `bash`,
#      `unzip` and `zip`, all of which this pipeline needs.
#    * `gh` CLI authenticated: `gh auth login --with-token < $env:GH_TOKEN`
#      (or use the `BATAMANTA_GITHUB_TOKEN` env var instead).
#
#  Usage:
#    # Build all pinned OTP versions that are missing windows-amd64:
#    ./scripts/local/regenerate-windows-amd64.sh
#
#    # Build a specific version (overrides the pinned list):
#    ./scripts/local/regenerate-windows-amd64.sh 28.4.2
#
#    # Force a rebuild even if the asset already exists:
#    BATAMANTA_FORCE=1 ./scripts/local/regenerate-windows-amd64.sh 28.4.2
#
#    # Dry run (print what would happen, don't actually do anything):
#    BATAMANTA_DRY_RUN=1 ./scripts/local/regenerate-windows-amd64.sh 28.4.2
#
#  After this script runs, run scripts/local/regenerate-manifest.py to make
#  sure MANIFEST.json lists the new assets.
# =============================================================================

set -euo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"

. ./scripts/_lib.sh

log "==> regenerate-windows-amd64.sh (host=$(uname -s))"

# Reject accidental runs on non-Windows hosts. The build is a
# download + repackage, but we still want a clean error instead of
# silently producing the wrong output if someone runs this on Linux.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) : ;;  # OK
  *) err "this script is meant for Windows (Git Bash). On Linux/macOS, run scripts/erts-windows-amd64.sh instead."; exit 2 ;;
esac

build_target windows-amd64 "$@"
