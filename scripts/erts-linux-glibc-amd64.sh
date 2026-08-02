#!/usr/bin/env bash
# Build the amd64 glibc ERTS tarball for every pinned OTP version that's
# missing from the current manifest (or for the versions passed on the CLI).
#
# Usage:
#   ./erts-linux-glibc-amd64.sh              # all pinned versions
#   ./erts-linux-glibc-amd64.sh 28.4 28.4.2  # specific versions only
#
# This is a thin wrapper around _lib.sh::build_target â€” all the actual logic
# lives there.

set -euo pipefail
cd "$(dirname "$0")"
. ./_lib.sh

build_target linux-glibc-amd64 "$@"
