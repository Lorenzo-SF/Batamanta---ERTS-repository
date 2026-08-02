#!/usr/bin/env bash
# =============================================================================
#  regenerate-linux-amd64.sh
# =============================================================================
#
#  Build (or rebuild) the two Linux x86_64 ERTS tarballs (glibc + musl)
#  from your local machine using Docker. Wraps the same _lib.sh:build_target
#  the CI uses, so the resulting tarballs are byte-identical to what
#  `gh workflow run erts.yml` would produce.
#
#  Prereqs:
#    * Docker Desktop (or any Docker engine that supports `--platform
#      linux/amd64`). On Windows: WSL2 backend recommended.
#    * `gh` CLI authenticated (or `BATAMANTA_GITHUB_TOKEN` env var set).
#
#  Why amd64 specifically: on an x86_64 host Docker runs `linux/amd64`
#  natively (no QEMU emulation), so this is roughly the same speed as the
#  CI ubuntu-latest runner. If you also want the arm64 variants, the CI
#  covers those — or you can run scripts/local/regenerate-linux-arm64.sh
#  (coming soon) which uses QEMU and is slower.
#
#  Usage:
#    # Build all pinned OTP versions that are missing linux-{glibc,musl}-amd64:
#    ./scripts/local/regenerate-linux-amd64.sh
#
#    # Build a specific version for both targets:
#    ./scripts/local/regenerate-linux-amd64.sh 28.4.2
#
#    # Force a rebuild even if the asset already exists:
#    BATAMANTA_FORCE=1 ./scripts/local/regenerate-linux-amd64.sh 28.4.2
#
#    # Dry run:
#    BATAMANTA_DRY_RUN=1 ./scripts/local/regenerate-linux-amd64.sh 28.4.2
#
#  After this script runs, run scripts/local/regenerate-manifest.py to make
#  sure MANIFEST.json lists the new assets.
# =============================================================================

set -euo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"

. ./scripts/_lib.sh

log "==> regenerate-linux-amd64.sh (host=$(uname -s))"

if ! command -v docker >/dev/null 2>&1; then
  err "docker not found in PATH. Install Docker Desktop from https://www.docker.com/products/docker-desktop/."
  exit 2
fi

# Build glibc first, then musl. The two are independent (different base
# images, different compilations) so they can be parallelised if you want
# to speed this up — open two terminals and run this script twice with
# different env vars. For simplicity, sequential here.
build_target linux-glibc-amd64 "$@"
build_target linux-musl-amd64  "$@"
