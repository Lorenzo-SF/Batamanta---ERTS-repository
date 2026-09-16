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
#  Robustness:
#    * Idempotent — re-run picks up where it left off (state in
#      .build-state.json). Already-uploaded assets are skipped.
#    * Interrupt-safe — Ctrl-C kills running containers and releases
#      locks so the next run can resume.
#    * Network-resilient — downloads retry with exponential backoff.
#
#  Usage:
#    # Build all pinned OTP versions that are missing linux-{glibc,musl}-amd64:
#    ./scripts/local/regenerate-linux-amd64.sh
#
#    # Build specific versions:
#    ./scripts/local/regenerate-linux-amd64.sh 28.4.2 28.4.3
#
#    # Build only one of the two targets:
#    ./scripts/local/regenerate-linux-amd64.sh --target=linux-glibc-amd64
#
#    # Force a rebuild even if the asset already exists:
#    ./scripts/local/regenerate-linux-amd64.sh --force
#
#    # Check status without building:
#    ./scripts/local/regenerate-linux-amd64.sh --status
#
#    # Dry run (just print commands, don't execute):
#    BATAMANTA_DRY_RUN=1 ./scripts/local/regenerate-linux-amd64.sh 28.4.2
#
#    # Build but don't upload to GitHub:
#    ./scripts/local/regenerate-linux-amd64.sh --no-upload
#
#  After this script runs, run scripts/local/regenerate-manifest.ps1 to make
#  sure MANIFEST.json lists the new assets.
# =============================================================================


cd "$(cd "$(dirname "$0")/../.." && pwd)"

. ./scripts/_lib.sh

log "==> regenerate-linux-amd64.sh (host=$(uname -s))"

if ! command -v docker >/dev/null 2>&1; then
  err "docker not found in PATH. Install Docker Desktop from https://www.docker.com/products/docker-desktop/."
  exit 2
fi

# --status short-circuits the docker check, so handle it first
if [[ "${1:-}" == "--status" ]]; then
  build_target linux-glibc-amd64 "$@"
  build_target linux-musl-amd64  "$@"
  exit $?
fi

# Build glibc first, then musl. The two are independent (different base
# images, different compilations) so they can be parallelised if you want
# to speed this up — open two terminals and run this script twice with
# different env vars. For simplicity, sequential here.
# --auto: only build what's missing on the release (idempotent).
build_target linux-glibc-amd64 --auto "$@"
build_target linux-musl-amd64  --auto "$@"
