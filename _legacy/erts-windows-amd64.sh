#!/usr/bin/env bash
# Build the Windows amd64 ERTS zip by downloading the official
# `otp_win64_<v>.zip` precompiled binary from `erlang/otp` releases and
# re-packaging it with the same clean layout as the Linux/macOS tarballs.
#
# Usage:
#   ./erts-windows-amd64.sh
#   ./erts-windows-amd64.sh 28.4 28.4.2

# Refuse to run on bash < 5 (macOS still ships 3.2 as /bin/bash). Sourced
# as the very first thing after the shebang so the failure is immediate.
. "$(dirname "${BASH_SOURCE[0]}")/_bash_guard.sh"

cd "$(dirname "$0")"
. ./_lib.sh

build_target windows-amd64 "$@"
