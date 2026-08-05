#!/usr/bin/env bash
# Build the arm64 musl ERTS tarball. See erts-linux-glibc-amd64.sh for usage.


cd "$(dirname "$0")"
. ./_lib.sh

build_target linux-musl-arm64 "$@"
