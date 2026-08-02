#!/usr/bin/env bash
# Build the arm64 glibc ERTS tarball. See erts-linux-glibc-amd64.sh for usage.

set -euo pipefail
cd "$(dirname "$0")"
. ./_lib.sh

build_target linux-glibc-arm64 "$@"
