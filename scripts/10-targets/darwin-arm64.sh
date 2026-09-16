#!/usr/bin/env bash
# =============================================================================
#  10-targets/darwin-arm64.sh — macOS aarch64 (Apple Silicon).
# =============================================================================
#
#  Built natively on a Mac with Homebrew openssl@3. Run via:
#
#      ./erts_gen regen --arm64
#  or
#      ./erts_gen auto --target=darwin-arm64
#  from a real macOS host (CI uses macos-latest = M1).
# =============================================================================

build_darwin_arm64() {
  # build_darwin_arm64 <version>
  local v="$1"
  local target="darwin-arm64"
  DARWIN_ARCH=arm64 out="$(native_build_macos "$target" "$v")" || return 1
  upload_cell "$target" "$v" "$out"
}
