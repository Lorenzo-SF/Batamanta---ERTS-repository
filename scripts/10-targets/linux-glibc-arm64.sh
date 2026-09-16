#!/usr/bin/env bash
# =============================================================================
#  10-targets/linux-glibc-arm64.sh — Ubuntu 22.04 aarch64, glibc.
# =============================================================================

build_linux_glibc_arm64() {
  # build_linux_glibc_arm64 <version> — entry point called by build_target().
  local v="$1"
  local target="linux-glibc-arm64"
  local asset="${TARGET_ASSET[$target]}"
  local out tarball

  tarball="$(download_source_tarball "$v")" || return 1
  out="$(docker_build_linux "$target" "$v" "$tarball")" || return 1
  upload_cell "$target" "$v" "$out"
}
