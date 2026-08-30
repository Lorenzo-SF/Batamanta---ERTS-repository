#!/usr/bin/env bash
# Build the arm64 glibc ERTS tarball. See erts-linux-glibc-amd64.sh for usage.

# Refuse to run on bash < 5 (macOS still ships 3.2 as /bin/bash). Sourced
# as the very first thing after the shebang so the failure is immediate.
. "$(dirname "${BASH_SOURCE[0]}")/_bash_guard.sh"

cd "$(dirname "$0")"
. ./_lib.sh

build_target linux-glibc-arm64 "$@"
