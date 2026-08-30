#!/usr/bin/env bash
# =============================================================================
#  _lib.sh — THIN LOADER that sources the numbered 00–10 files in order.
# =============================================================================
#
#  The actual code for each concern lives in a focused file:
#
#    00-utils.sh            logging, GH_TOKEN bootstrap, dry-run, helpers
#    01-detect.sh           upstream version detection + build planning
#    02-sync-releases.sh    GitHub release CRUD (gh wrappers)
#    03-build.sh            target catalog, locking, build_target() orchestrator
#    04-manifest.sh         MANIFEST.json regeneration + jq-first validation
#    10-targets/_helpers.sh shared build helpers (docker / native / zip)
#    10-targets/<target>.sh one `build_<target>()` per (os, arch) combo
#
#  Sourcing order matters: each file relies on the previous one's globals
#  (paths, env, associative arrays). Don't reorder.
#
#  If you extend the lib, ADD a new numbered file rather than growing an
#  existing one. setup.d-style.
# =============================================================================

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sibling guard first so the loader refuses bash 3.2 (macOS /bin/bash).
# shellcheck source=_bash_guard.sh
. "$_LIB_DIR/_bash_guard.sh"

# 00 — utils (paths, env defaults, logging, GH bootstrap). MUST be first
# so 01..04 can rely on $MANIFEST, $LIB_DIR, $REPO_ROOT, etc.
# shellcheck source=00-utils.sh
. "$_LIB_DIR/00-utils.sh"

# 01 — upstream detection + build planning
# shellcheck source=01-detect.sh
. "$_LIB_DIR/01-detect.sh"

# 02 — release CRUD against GitHub
# shellcheck source=02-sync-releases.sh
. "$_LIB_DIR/02-sync-releases.sh"

# 03 — target catalog + build orchestrator (depends on 00 + 01 + 02)
# shellcheck source=03-build.sh
. "$_LIB_DIR/03-build.sh"

# 04 — MANIFEST.json regeneration
# shellcheck source=04-manifest.sh
. "$_LIB_DIR/04-manifest.sh"

# 10 — per-target builders (auto-discovered, sorted lexicographically)
if [[ -d "$_LIB_DIR/10-targets" ]]; then
  for f in "$_LIB_DIR/10-targets"/_helpers.sh \
           "$_LIB_DIR/10-targets"/*.sh; do
    [[ -f "$f" ]] || continue
    # shellcheck source=/dev/null
    . "$f"
  done
fi

# Self-test: confirm the public surface that external entry points rely on.
for fn in log warn err ok build_target generate_manifest sync_releases \
         detect_new_versions verify_manifest release_exists create_release \
         upload_asset asset_in_release gh_with_auth_hint docker_build_linux \
         native_build_macos process_windows_zip download_source_tarball \
         download_precompiled upload_cell tag_to_version version_to_tag \
         list_local_versions list_upstream_versions list_assets_full_for \
         list_assets_for manifest_set_entry manifest_read manifest_has_entry; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    echo "ERROR: _lib.sh self-test failed: function '$fn' is not defined after sourcing 00-04 + 10-targets/*" >&2
    exit 1
  fi
done
