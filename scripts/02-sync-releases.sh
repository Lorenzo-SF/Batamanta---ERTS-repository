#!/usr/bin/env bash
# =============================================================================
#  02-sync-releases.sh — release CRUD against GitHub.
# =============================================================================
#
#  Wraps the `gh` CLI with auth-aware variants. The rest of the build can
#  release / upload / list releases without knowing about token plumbing.
#
#  Public entry points:
#    * release_exists   <tag>
#    * asset_in_release <tag> <asset>
#    * create_release   <tag> <title> <notes>
#    * upload_asset     <tag> <asset_path>
#    * gh_with_auth_hint <cmd...> — runs the given gh command, printing a
#                                   single friendly hint on auth failure
# =============================================================================

release_exists() {
  # release_exists <tag> — true iff the release with that tag exists
  local tag="$1"
  gh release view "$tag" >/dev/null 2>&1
}

asset_in_release() {
  # asset_in_release <tag> <asset_name> — true iff the release has that asset
  local tag="$1" asset="$2"
  gh release view "$tag" --json assets -q '.assets[].name' 2>/dev/null \
    | grep -Fxq "$asset"
}

create_release() {
  # create_release <tag> <title> <notes>
  local tag="$1" title="$2" notes="$3"
  if release_exists "$tag"; then return 0; fi
  log "creating release $tag"
  # --target main: attach the release to the current tip of `main` instead
  # of requiring a pre-existing local tag. When the pipeline runs in CI
  # the tag is already on the remote, but in local execution `gh` would
  # create a stale local tag and refuse the upload. This flag is a no-op
  # in CI (where the tag already exists at that SHA) and a fix in local runs.
  gh release create "$tag" --title "$title" --notes "$notes" --target main
}

upload_asset() {
  # upload_asset <tag> <asset_path>
  local tag="$1" path="$2"
  gh release upload "$tag" "$path" --clobber
}

gh_with_auth_hint() {
  # gh_with_auth_hint <cmd...> — wraps a `gh` invocation so that an auth
  # failure prints a one-liner hint listing the four lines that fix it.
  # We intentionally do NOT do an upfront auth check; detecting the
  # difference between web OAuth and a fine-grained PAT is fragile, and
  # the fine-grained PAT path is painful to keep working. So: try, fail
  # loudly with the fix recipe, done.
  if "$@" 2>&1 | tee /tmp/.gh-err.$$ | grep -qE '(To get started with GitHub CLI|authentication .* failed|Bad credentials|Resource not accessible by integration)'; then
    cat /tmp/.gh-err.$$ >&2
    err ""
    err "GitHub auth failed. Run these four lines once and retry:"
    err "  unset GH_TOKEN"
    err "  unset GITHUB_TOKEN"
    err "  gh auth logout"
    err "  gh auth login"
    rm -f /tmp/.gh-err.$$
    return 1
  fi
  rm -f /tmp/.gh-err.$$
  return "${PIPESTATUS[0]}"
}

# -----------------------------------------------------------------------------
#  Sync releases (used by erts_gen auto)
# -----------------------------------------------------------------------------
# shellcheck source=01-detect.sh
list_upstream_versions() {
  # List every stable OTP-X.Y.Z we ship or plan to ship, sorted ascending.
  # Combines the pinned baseline + the upstream-discovered versions so the
  # CI can iterate without restarting the script for new OTP releases.
  {
    for v in "${OTP_VERSIONS[@]}"; do echo "$v"; done
    _discover_upstream_versions "${MIN_OTP_VERSION:-27.0}" 2>/dev/null
  } | sort -V | uniq
}

list_erlang_versions() {
  # Stable X.Y.Z versions upstream that we don't ship yet.
  # Used by erts_gen check / auto to know what to sync.
  _discover_upstream_versions "${MIN_OTP_VERSION:-27.0}"
}

list_local_versions() {
  # Stable X.Y.Z versions that already have a release tag in this repo.
  # Reads from `gh release list`.
  gh release list --repo "$REPO" --limit 200 --json tagName 2>/dev/null \
    | jq -r '.[].tagName' 2>/dev/null \
    | sed 's/^OTP-//' \
    | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    | sort -V
}

sync_releases() {
  # Create one empty release tag per missing stable version. Used by:
  #   * erts_gen auto (full pipeline)
  #   * .github/workflows/erts.yml:sync-releases
  # Idempotent: re-running picks up only the diff.
  local want have missing v tag title notes
  want=$(list_upstream_versions)
  have=$(list_local_versions)
  missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))

  if [[ -z "$missing" ]]; then
    log "==> sync_releases: nothing to do (every upstream version already has a tag)"
    return 0
  fi

  log "==> sync_releases: creating empty tags for ${missing//$'\n'/, }"
  for v in $missing; do
    [[ -z "$v" ]] && continue
    tag="OTP-$v"
    title="Erlang/OTP $v"
    notes="Automated build of the 6 supported ERTS targets (linux glibc + musl × amd64/arm64, darwin arm64, windows amd64) for Erlang/OTP $v.

This release is part of the [Batamanta](https://github.com/Lorenzo-SF/Batamanta) ERTS prebuilt bundle — visit that repo for the source, MANIFEST, and the batamanta Elixir library."
    if release_exists "$tag"; then
      log "  $tag already exists, skipping"
      continue
    fi
    gh_with_auth_hint gh release create "$tag" \
      --repo "$REPO" \
      --title "$title" \
      --notes "$notes" \
      --target main
  done
}

wipe_all_releases() {
  # DESTRUCTIVE: delete every OTP-* release in $REPO. Used by regen --force.
  # Caller MUST have asked for explicit confirmation already (the erts_gen
  # `regen` subcommand enforces this).
  log "==> wipe_all_releases: deleting every OTP-* release in $REPO"
  local tags
  tags=$(gh release list --repo "$REPO" --limit 300 --json tagName \
    | jq -r '.[].tagName' 2>/dev/null \
    | grep '^OTP-' || true)
  if [[ -z "$tags" ]]; then
    log "  no OTP-* releases to wipe"
    return 0
  fi
  for tag in $tags; do
    [[ -z "$tag" ]] && continue
    gh_with_auth_hint gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag
  done
  printf '{}\n' > "$MANIFEST"
  ok "  wiped; MANIFEST.json reset"
}
