#!/usr/bin/env bash
# =============================================================================
#  10-targets/windows-amd64.sh — Windows x86_64.
# =============================================================================
#
#  Builds by repackaging the upstream precompiled zip — we don't compile
#  from source on Windows. Requires a `windows-latest` runner or any
#  Windows host with `unzip` + PowerShell's Compress-Archive available.
# =============================================================================

build_windows_amd64() {
  # build_windows_amd64 <version>
  local v="$1"
  local target="windows-amd64"
  local out
  out="$(process_windows_zip "$target" "$v")" || return 1
  upload_cell "$target" "$v" "$out"
}
