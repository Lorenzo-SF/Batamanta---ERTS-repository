#!/usr/bin/env bash
# =============================================================================
#  regenerate-darwin.sh
# =============================================================================
#
#  Build (or rebuild) the macOS ERTS tarballs (arm64 by default, amd64 if
#  requested) on a real macOS host. Wraps the same _lib.sh:build_target
#  the CI uses, so the resulting tarballs are byte-identical to what
#  `gh workflow run erts.yml` would produce on a `macos-latest` runner.
#
#  Prereqs (macOS):
#    * Xcode Command Line Tools: `xcode-select --install`
#    * Homebrew openssl: `brew install openssl@3`
#    * `gh` CLI authenticated (or `BATAMANTA_GITHUB_TOKEN` env var set).
#
#  Why this isn't on CI by default: GitHub Actions' `macos-latest` runner
#  is a paid plan. This script is the free alternative — run it on your
#  own Mac whenever you need to (re)build the macOS tarballs.
#
#  Robustness: same as the Linux scripts — idempotent, interrupt-safe,
#  network-resilient. Safe to re-run.
#
#  Usage:
#    # Build all pinned OTP versions for darwin-arm64 (the default — most
#    # Macs in 2026 are Apple Silicon):
#    ./scripts/local/regenerate-darwin.sh
#
#    # Build darwin-amd64 instead (only meaningful on an Intel Mac; on
#    # Apple Silicon it would still work but compile via Rosetta and be slow):
#    DARWIN_ARCH=amd64 ./scripts/local/regenerate-darwin.sh
#
#    # Build both targets sequentially:
#    ./scripts/local/regenerate-darwin.sh
#    DARWIN_ARCH=amd64 ./scripts/local/regenerate-darwin.sh
#
#    # Build a specific version:
#    ./scripts/local/regenerate-darwin.sh 28.4.2
#
#    # Check status:
#    ./scripts/local/regenerate-darwin.sh --status
#
#    # Force a rebuild:
#    ./scripts/local/regenerate-darwin.sh --force
#
#  After this script runs, run scripts/local/regenerate-manifest.ps1 to make
#  sure MANIFEST.json lists the new assets.
# =============================================================================

set -euo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"

. ./scripts/_lib.sh

log "==> regenerate-darwin.sh (host=$(uname -s)/$(uname -m))"

# --status works on any host (doesn't actually need to be macOS)
if [[ "${1:-}" == "--status" ]]; then
  build_target darwin-arm64 "$@"
  build_target darwin-amd64 "$@"
  exit $?
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this script must be run on macOS. Detected: $(uname -s)."
  err "If you're on Linux/Windows, the CI will skip darwin-* targets —"
  err "you'll need to either run this on a real Mac, or use a paid CI plan."
  exit 2
fi

if [[ "$(uname -m)" == "arm64" && "${DARWIN_ARCH:-arm64}" == "amd64" ]]; then
  log "  NOTE: building darwin-amd64 on an Apple Silicon Mac — this will"
  log "  cross-compile (or use Rosetta) and be slower than on a real Intel Mac."
fi

# Allow DARWIN_ARCH env var to override the default (arm64).
case "${DARWIN_ARCH:-arm64}" in
  arm64) target="darwin-arm64" ;;
  amd64) target="darwin-amd64" ;;
  *)     err "DARWIN_ARCH must be 'arm64' or 'amd64' (got '${DARWIN_ARCH:-}')"; exit 2 ;;
esac

build_target "$target" "$@"
