#!/usr/bin/env bash
# =============================================================================
#  regenerate-linux-arm64.sh
# =============================================================================
#
#  Build the two Linux aarch64 ERTS tarballs (glibc + musl) from your local
#  machine using Docker with QEMU emulation (or natively on an aarch64 host).
#
#  Prereqs:
#    * Docker Desktop with QEMU support (or native arm64 host).
#    * `gh` CLI authenticated (or `BATAMANTA_GITHUB_TOKEN` env var set).
#
#  Note: aarch64 builds are SLOW under QEMU on an x86_64 host (~10-20x
#  slower than native). Prefer the CI runner for these unless you need
#  them locally.
#
#  Usage: same flags as regenerate-linux-amd64.sh
# =============================================================================


cd "$(cd "$(dirname "$0")/../.." && pwd)"

. ./scripts/_lib.sh

log "==> regenerate-linux-arm64.sh (host=$(uname -s)/$(uname -m))"

if ! command -v docker >/dev/null 2>&1; then
  err "docker not found in PATH."
  exit 2
fi

# Warn if we're emulating
if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
  warn "host is $(uname -m) — arm64 builds will run under QEMU emulation (very slow)"
fi

build_target linux-glibc-arm64 --auto "$@"
build_target linux-musl-arm64  --auto "$@"
