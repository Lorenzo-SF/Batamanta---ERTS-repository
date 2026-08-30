#!/usr/bin/env bash
# Build the darwin-amd64 (Mac Intel) ERTS tarball natively on macOS.
#
# IMPORTANT: this script is meant to be run on a real macOS host with
# Homebrew and Xcode CLT installed. From any other host (Linux, Windows)
# you'll need a macOS Intel runner â€” see ../.github/workflows/erts.yml
# for the GitHub Actions matrix that does this. Note that Apple Silicon
# Macs running this via Rosetta 2 will work (the binary built is still
# x86_64) but compilation will be slower.
#
# Usage:
#   ./erts-darwin-amd64.sh
#   ./erts-darwin-amd64.sh 28.4 28.4.2


cd "$(dirname "$0")"
. ./_lib.sh

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "[batamanta-erts] darwin-amd64 must be built on macOS (got $(uname -s))" >&2
    echo "  Use the GitHub Actions workflow with macos-latest runner instead." >&2
    exit 2
fi
if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "[batamanta-erts] darwin-amd64 must be built on Intel Mac (got $(uname -m))" >&2
    echo "  On Apple Silicon you want darwin-arm64, not darwin-amd64." >&2
    exit 2
fi

build_target darwin-amd64 "$@"
