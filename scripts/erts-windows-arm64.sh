#!/usr/bin/env bash
# Build the Windows arm64 ERTS zip.
#
# NOTE: As of 2026-08, `erlang/otp` does not yet publish official precompiled
# binaries for Windows arm64 (the upstream `otp_win64_*.zip` is x86_64 only).
# This script will fail with a clear error message until upstream starts
# shipping arm64 Windows binaries. As soon as they do, update
# `UPSTREAM_ASSET` in _lib.sh and re-implement `process_windows_zip` to
# handle the new asset (or add a `process_windows_arm64_zip` helper).
#
# Usage:
#   ./erts-windows-arm64.sh
#   ./erts-windows-arm64.sh 28.4 28.4.2

set -euo pipefail
cd "$(dirname "$0")"
. ./_lib.sh

build_target windows-arm64 "$@"
