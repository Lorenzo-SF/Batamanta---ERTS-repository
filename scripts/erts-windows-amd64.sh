#!/usr/bin/env bash
# Build the Windows amd64 ERTS zip by downloading the official
# `otp_win64_<v>.zip` precompiled binary from `erlang/otp` releases and
# re-packaging it with the same clean layout as the Linux/macOS tarballs.
#
# Usage:
#   ./erts-windows-amd64.sh
#   ./erts-windows-amd64.sh 28.4 28.4.2

set -euo pipefail
cd "$(dirname "$0")"
. ./_lib.sh

build_target windows-amd64 "$@"
