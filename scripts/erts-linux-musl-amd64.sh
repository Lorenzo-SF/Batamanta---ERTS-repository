#!/usr/bin/env bash
# Build the amd64 musl ERTS tarball (Alpine / Void / postmarketOS targets).
# See erts-linux-glibc-amd64.sh for usage.


cd "$(dirname "$0")"
. ./_lib.sh

build_target linux-musl-amd64 "$@"
