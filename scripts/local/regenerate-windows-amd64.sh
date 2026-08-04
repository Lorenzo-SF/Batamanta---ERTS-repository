#!/usr/bin/env bash
# =============================================================================
#  regenerate-windows-amd64.sh
# =============================================================================
#
#  Build the Windows x86_64 ERTS zip from your local machine. Unlike
#  Linux/musl/darwin, this doesn't use Docker — it downloads the
#  precompiled zip from erlang/otp and repackages it (stripping docs,
#  fixing the ROOTDIR sed, etc).
#
#  Prereqs:
#    * `gh` CLI authenticated (or `BATAMANTA_GITHUB_TOKEN` env var set).
#    * `unzip` (or the bundled PowerShell Expand-Archive).
#
#  Usage: same flags as regenerate-linux-amd64.sh
# =============================================================================

set -euo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"

. ./scripts/_lib.sh

log "==> regenerate-windows-amd64.sh (host=$(uname -s))"

build_target windows-amd64 --auto "$@"
