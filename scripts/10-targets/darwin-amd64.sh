#!/usr/bin/env bash
# =============================================================================
#  10-targets/darwin-amd64.sh — macOS x86_64 (Intel).
# =============================================================================
#
#  Build only when an Intel-Mac runner is reachable — GitHub-hosted
#  `macos-12` (Intel) requires a paid plan, so this target is **off by
#  default** in the CI matrix. To enable it:
#
#    1. Make sure `macos-12` is reachable (paid GitHub plan or a
#       self-hosted Intel Mac runner labelled `macos-12`).
#    2. Uncomment the darwin-amd64 / darwin-arm64 lines in
#       .github/workflows/erts.yml:detect (or add a workflow_dispatch
#       input that mentions darwin-amd64).
#    3. Run `./erts_gen regen --all --force` from the macOS-12 host
#       (or let CI do it).
# =============================================================================

build_darwin_amd64() {
  # build_darwin_amd64 <version>
  local v="$1"
  local target="darwin-amd64"
  DARWIN_ARCH=amd64 out="$(native_build_macos "$target" "$v")" || return 1
  upload_cell "$target" "$v" "$out"
}
