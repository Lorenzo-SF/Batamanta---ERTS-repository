#!/usr/bin/env bash
# sync-erts.sh — single entry point to keep Lorenzo-SF/Batamanta---ERTS-repository
# in sync with erlang/otp.
#
# What it does, in order:
#   1. Lists stable OTP versions on erlang/otp (>= MIN_OTP_VERSION) and
#      creates any missing empty release in our repo.
#   2. For each of the six supported targets (windows/darwin/linux glibc/musl
#      × amd64/arm64), finds releases that are missing the corresponding
#      asset, builds the asset locally if it's not already on disk, and
#      uploads it.
#   3. Rewrites MANIFEST.json from the live release set.
#
# This script is the same code that the CI runs (see .github/workflows/erts.yml).
# It is idempotent: re-running it picks up only the diff. To force a wipe
# of every release + MANIFEST, use the `regenerate-from-zero` subcommand.
#
# Auth: we intentionally DON'T do an upfront auth check. Detecting the
# difference between web OAuth and a fine-grained PAT is fragile, and the
# fine-grained PAT path is painful to keep working. Instead, every call to
# `gh release create` / `gh release upload` is wrapped in `gh_with_auth_hint`
# (in lib-sync.sh) which prints a single friendly hint on auth failures —
# just the four lines that fix it:
#
#     unset GH_TOKEN
#     unset GITHUB_TOKEN
#     gh auth logout
#     gh auth login
#
# Usage:
#   ./scripts/local/sync-erts.sh                 # full sync, all 6 targets
#   ./scripts/local/sync-erts.sh windows-amd64   # only one target
#   ./scripts/local/sync-erts.sh --no-build     # only upload (assets must exist locally)
#   ./scripts/local/sync-erts.sh --manifest-only  # only rewrite MANIFEST.json
#   ./scripts/local/sync-erts.sh --version=28.4.2 linux-glibc-amd64  # one (version, target)
#   ./scripts/local/sync-erts.sh regenerate-from-zero  # DESTRUCTIVE

# Refuse to run on bash < 5 (macOS still ships 3.2 as /bin/bash). Sourced
# as the very first thing after the shebang so the failure is immediate.
. "$(dirname "${BASH_SOURCE[0]}")/../_bash_guard.sh"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib-sync.sh
source "$SCRIPT_DIR/lib-sync.sh"

# ── Args ────────────────────────────────────────────────────────────────
ONLY_TARGETS=()
ONLY_VERSION=""
DO_BUILD=1
DO_MANIFEST=1
DO_RELEASE_SYNC=1
DO_TARGET_SYNC=1

usage() {
  cat <<EOF
Usage: $0 [options] [target...]

Targets (any combination, in any order; default = all six):
  windows-amd64
  darwin-arm64
  linux-glibc-amd64
  linux-glibc-arm64
  linux-musl-amd64
  linux-musl-arm64

Options:
  --no-build        Don't build any assets; only upload what's already in dist/.
                    Useful when a build was done on a different host.
  --no-upload       Build any missing assets but don't push them to GitHub.
                    Useful when the build host is different from the upload
                    host — you build on Linux/Mac/Windows, scp the dist/
                    tree to the upload host, then run with --no-build to
                    just push.
  --manifest-only   Only rewrite MANIFEST.json; skip release sync and asset sync.
  --no-manifest     Don't rewrite MANIFEST.json; only do release + asset sync.
  --releases-only   Only sync releases; skip asset sync and manifest.
  --assets-only     Only do the per-target asset sync; skip release sync + manifest.
  --version=V       Restrict the per-target sync to a single OTP version
                    (e.g. 28.4.2). Useful for CI matrix cells that own one
                    (target, version) pair.
  regenerate-from-zero
                    DESTRUCTIVE. Delete every release in the repo, then run
                    a full sync from scratch.

Environment:
  REPO                 full "owner/name" of the erts repo (default Lorenzo-SF/Batamanta---ERTS-repository)
  MIN_OTP_VERSION      minimum OTP version to consider (default 27.0)
  GH_TOKEN / GITHUB_TOKEN   must grant Contents: write on the repo
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-build) DO_BUILD=0; SYNC_BUILD=0; shift ;;
    --no-upload) DO_BUILD=1; SYNC_BUILD=1; SYNC_UPLOAD=0; shift ;;
    --manifest-only) DO_TARGET_SYNC=0; DO_RELEASE_SYNC=0; DO_MANIFEST=1; shift ;;
    --no-manifest) DO_MANIFEST=0; shift ;;
    --releases-only) DO_TARGET_SYNC=0; DO_MANIFEST=0; DO_RELEASE_SYNC=1; shift ;;
    --assets-only) DO_RELEASE_SYNC=0; DO_MANIFEST=0; DO_TARGET_SYNC=1; shift ;;
    --version=*) ONLY_VERSION="${1#--version=}"; shift ;;
    regenerate-from-zero)
      log ">> regenerate-from-zero: deleting every release in $REPO..."
      for tag in $(gh release list --repo "$REPO" --limit 200 --json tagName | jq -r '.[].tagName'); do
        log "  deleting $tag"
        gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag || true
      done
      printf '{}\n' > "$REPO_ROOT/MANIFEST.json"
      ok "  wiped; now run $0 to rebuild from scratch"
      exit 0
      ;;
    -*) err "unknown flag: $1"; usage; exit 2 ;;
    *)
      # Treat as target name; validate.
      ok=0
      for t in "${ALL_TARGETS[@]}"; do
        [[ "$1" == "$t" ]] && ok=1 && break
      done
      if (( !ok )); then
        err "unknown target: $1"
        usage
        exit 2
      fi
      ONLY_TARGETS+=("$1")
      shift
      ;;
  esac
done

# Default to all targets if none specified.
if [[ ${#ONLY_TARGETS[@]} -eq 0 ]]; then
  ONLY_TARGETS=("${ALL_TARGETS[@]}")
fi

# ── 1. Sync releases against erlang/otp ────────────────────────────────
if (( DO_RELEASE_SYNC )); then
  sync_releases
fi

# ── 2. Per-target asset sync ────────────────────────────────────────────
if (( DO_TARGET_SYNC )); then
  for t in "${ONLY_TARGETS[@]}"; do
    if [[ -n "$ONLY_VERSION" ]]; then
      sync_target_version "$t" "$ONLY_VERSION"
    elif (( DO_BUILD )); then
      sync_target "$t"
    else
      log ">> uploading existing assets for $t (no-build mode)"
      local_tag=""
      local_version=""
      local_file=""
      while read -r local_tag; do
        [[ -z "$local_tag" ]] && continue
        local_version="$(tag_to_version "$local_tag")"
        local_file="$(local_asset_path "$t" "$local_version")"
        if [[ -f "$local_file" ]]; then
          upload_asset "$t" "$local_version" || err "  upload failed for $local_tag"
        fi
      done < <(list_missing_for "$t")
    fi
  done
fi

# ── 3. Manifest (independent of any target) ────────────────────────────
if (( DO_MANIFEST )); then
  generate_manifest
fi

ok ">> done"
