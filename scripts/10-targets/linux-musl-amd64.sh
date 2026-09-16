#!/usr/bin/env bash
# =============================================================================
#  10-targets/linux-musl-amd64.sh — Alpine 3.19 x86_64, musl.
# =============================================================================

build_linux_musl_amd64() {
  # build_linux_musl_amd64 <version> — entry point called by build_target().
  local v="$1"
  local target="linux-musl-amd64"
  local asset="${TARGET_ASSET[$target]}"
  local out tarball

  tarball="$(download_source_tarball "$v")" || return 1
  out="$(docker_build_linux "$target" "$v" "$tarball")" || return 1
  upload_cell "$target" "$v" "$out"
}
