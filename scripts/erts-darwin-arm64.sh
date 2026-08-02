#!/usr/bin/env bash
# Build the darwin-arm64 ERTS tarball natively on macOS (Apple Silicon).
#
# IMPORTANT: this script is meant to be run on a real macOS host with
# Homebrew and Xcode CLT installed. From any other host (Linux, Windows)
# you'll need a macOS runner — see ../.github/workflows/erts.yml for the
# GitHub Actions matrix that does this.
#
# Usage:
#   ./erts-darwin-arm64.sh
#   ./erts-darwin-arm64.sh 28.4 28.4.2

set -euo pipefail
cd "$(dirname "$0")"
. ./_lib.sh

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "[batamanta-erts] darwin-arm64 must be built on macOS (got $(uname -s))" >&2
    echo "  Use the GitHub Actions workflow with macos-latest runner instead." >&2
    exit 2
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "[batamanta-erts] darwin-arm64 must be built on Apple Silicon (got $(uname -m))" >&2
    echo "  Intel Mac builds are not supported by this script." >&2
    exit 2
fi

build_target darwin-arm64 "$@"
